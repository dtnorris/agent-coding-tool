# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "time"

module AgentCodingTool
  # Only a terminal launch failure before ACT's start reservation can be abandoned.
  # The run directory and feature branches remain as historical evidence.
  class PreflightRecovery
    def initialize(data_root:, liveness: nil, after_removal: nil)
      @data_root = File.realpath(data_root)
      @liveness = liveness || method(:clear_liveness?)
      @after_removal = after_removal
    end

    def preflight(id)
      raise InvalidTask, "abandon-preflight: unsafe task ID" unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      run_root = "#{@data_root}-runs"
      task_root = File.join(run_root, id)
      [run_root, task_root].each { |path| directory!(path) }
      raise InvalidState, "abandon-preflight: evidence root is not private" unless
        File.stat(run_root).uid == Process.uid && (File.stat(run_root).mode & 0o077).zero?
      attempts = Dir.children(task_root).map do |name|
        directory = File.join(task_root, name)
        directory!(directory)
        report_file = File.join(directory, "handoff.json")
        raise InvalidState, "abandon-preflight: missing attempt evidence" unless File.file?(report_file) && !File.symlink?(report_file)
        [name, JSON.parse(File.binread(report_file)).fetch("attempt")]
      end.sort_by { |_name, number| number }
      raise InvalidState, "abandon-preflight: missing or conflicting attempts" unless
        attempts.map(&:last) == (1..attempts.length).to_a
      attempts[0...-1].each do |name, _number|
        older = File.join(task_root, name)
        directory!(older)
        old_report = File.join(older, "handoff.json")
        old_record = File.join(older, "worktrees.json")
        raise InvalidState, "abandon-preflight: earlier attempt is unverified" unless
          [old_report, old_record].all? { |path| File.file?(path) && !File.symlink?(path) }
        history = JSON.parse(File.binread(old_report))
        raise InvalidState, "abandon-preflight: earlier attempt reached worker execution or is uncertain" unless
          history["schema_version"] == Launcher::SCHEMA && history["task_id"] == id &&
          history["status"] == "preflight_abandoned" && history["preflight_abandoned_at"]
        old_inventory = JSON.parse(File.binread(old_record))
        raise InvalidState, "abandon-preflight: earlier worktrees remain" unless
          history["worktrees_path"] == old_record && old_inventory["schema_version"] == WorktreeManager::SCHEMA &&
          old_inventory["task_id"] == id && old_inventory["attempt"] == history["attempt"] &&
          immutable(history["worktrees"]) == immutable(old_inventory) &&
          old_inventory.fetch("entries").all? { |entry| entry["state"] == "removed" }
      end
      run_dir = File.join(task_root, attempts.fetch(-1).first)
      directory!(run_dir)
      report_path = File.join(run_dir, "handoff.json")
      record_path = File.join(run_dir, "worktrees.json")
      [report_path, record_path].each do |path|
        raise InvalidState, "abandon-preflight: missing or foreign evidence" unless File.file?(path) && !File.symlink?(path)
      end
      report = JSON.parse(File.binread(report_path))
      raw = JSON.parse(File.binread(record_path))
      task = TaskStore.new(File.join(@data_root, "tasks")).load(id)
      state = StateStore.new(File.join(@data_root, "state")).load(id)
      unless report["schema_version"] == Launcher::SCHEMA && report["task_id"] == id &&
             report["attempt"].is_a?(Integer) && report["attempt"] == attempts.length &&
             report["worktrees_path"] == record_path &&
             report["preparation"] == state["snapshot"] && report["prepared_at"] == state["prepared_at"] &&
             report["preparation"].is_a?(Hash) &&
             report["preparation"].keys.sort == task.fetch("repositories").keys.sort &&
             raw["schema_version"] == WorktreeManager::SCHEMA && raw["task_id"] == id &&
             raw["attempt"] == report["attempt"] && immutable(report["worktrees"]) == immutable(raw) &&
             !state["started_at"] && [nil, "failed"].include?(state.dig("result", "outcome")) &&
             %w[preflight_failed preflight_abandoned].include?(report["status"]) &&
             report["error"].is_a?(String) && !report["error"].empty? &&
             report["invocation_id"].is_a?(String) && report["host_pid"].is_a?(Integer) &&
             report["workspace"].is_a?(String) &&
             %w[argv child_pid child_started_at started_at session_id ended_at].all? { |key| report[key].nil? }
        raise InvalidState, "abandon-preflight: pre-worker identity or lifecycle is unverified"
      end
      raise InvalidState, "abandon-preflight: missing explicit recovery marker" if
        report["status"] == "preflight_abandoned" && !report["preflight_abandoned_at"]
      manager = WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root,
                                    record_path: record_path)
      inventory = manager.inspect!
      entries = inventory.fetch("entries")
      raise InvalidState, "abandon-preflight: repository set changed" unless
        entries.map { |entry| entry.fetch("name") }.sort == task.fetch("repositories").keys.sort &&
        entries.any? { |entry| entry["access"] == "write" } &&
        report["workspace"] == entries.find { |entry| entry["access"] == "write" }.fetch("path")
      entries.each do |entry|
        prepared = report.fetch("preparation").fetch(entry.fetch("name"))
        unless task.fetch("repositories").fetch(entry.fetch("name")).fetch("access") == entry["access"] &&
               prepared.values_at("path", "remote_url", "branch", "pushed_sha") ==
                 entry.values_at("parent", "remote_url", "source_branch", "base_sha")
          raise InvalidState, "abandon-preflight: prepared repository identity changed"
        end
      end
      paths = entries.filter_map { |entry| entry.fetch("path") unless entry["state"] == "removed" }
      task_path = File.join(WorktreeManager.canonical_system_path(Config.load(File.join(@data_root, "config.yml")).worktree_root), id)
      if File.directory?(task_path) && !File.symlink?(task_path)
        raise InvalidState, "abandon-preflight: foreign task path" unless
          (Dir.children(task_path).map { |name| File.join(task_path, name) } - paths).empty?
      elsif File.exist?(task_path) || File.symlink?(task_path)
        raise InvalidState, "abandon-preflight: foreign task path"
      end
      checks = manager.cleanup_preflight
      raise InvalidState, "abandon-preflight: dirty worktree" if checks.any? { |row| row["dirty"] || !row.fetch("blockers").empty? }
      raise InvalidState, "abandon-preflight: active or uncertain process" unless @liveness.call(report, inventory)
      { "task_id" => id, "run_dir" => run_dir, "report_path" => report_path,
        "record_path" => record_path, "entries" => entries, "abandoned" => report["status"] == "preflight_abandoned" }
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError, SystemCallError => e
      raise InvalidState, "abandon-preflight: malformed or inaccessible evidence: #{e.message}"
    end

    def abandon(id)
      raise InvalidTask, "abandon-preflight: unsafe task ID" unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      run_root = "#{@data_root}-runs"
      directory!(run_root)
      raise InvalidState, "abandon-preflight: evidence root is not private" unless
        File.stat(run_root).uid == Process.uid && (File.stat(run_root).mode & 0o077).zero?
      lock_path = File.join(run_root, "launch.lock")
      raise InvalidState, "abandon-preflight: foreign lock" if File.symlink?(lock_path)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        raise InvalidState, "abandon-preflight: launcher active" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        result = preflight(id)
        manager = WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root,
                                      record_path: result.fetch("record_path"))
        result.fetch("entries").each do |entry|
          next if entry["state"] == "removed"
          manager.remove_entry!(entry.fetch("name"))
          @after_removal&.call(entry)
        end
        report = JSON.parse(File.binread(result.fetch("report_path")))
        unless report["status"] == "preflight_abandoned"
          report["status"] = "preflight_abandoned"
          report["preflight_abandoned_at"] = Time.now.utc.iso8601
          atomic_write(result.fetch("report_path"), report)
        end
        state_store = StateStore.new(File.join(@data_root, "state"))
        state = state_store.load(id)
        raise InvalidState, "abandon-preflight: state changed during removal" unless
          state["snapshot"] == report["preparation"] && state["prepared_at"] == report["prepared_at"] &&
          !state["started_at"] && [nil, "failed"].include?(state.dig("result", "outcome"))
        unless state["result"]
          state["result"] = { "outcome" => "failed", "recorded_at" => Time.now.utc.iso8601,
                              "summary" => "Verified pre-worker launch abandoned; see #{result.fetch('report_path')}" }
          state_store.write(id, state)
        end
        preflight(id).merge("abandoned" => true)
      end
    end

    private

    def directory!(path)
      raise InvalidState, "abandon-preflight: missing or foreign evidence path" unless File.directory?(path) && !File.symlink?(path)
    end

    def immutable(inventory)
      return nil unless inventory.is_a?(Hash) && inventory["entries"].is_a?(Array)
      inventory.reject { |key, _| key == "entries" }.merge(
        "entries" => inventory.fetch("entries").map { |entry| entry.reject { |key, _| key == "state" } })
    end

    def clear_liveness?(report, inventory)
      begin
        Process.kill(0, report.fetch("host_pid"))
        return false
      rescue Errno::ESRCH
        nil
      rescue Errno::EPERM
        return false
      end
      inventory.fetch("entries").each do |entry|
        next if entry["state"] == "removed"
        stdout, _stderr, status = Open3.capture3("lsof", "-n", "-P", "+D", entry.fetch("path"))
        return false unless status.exitstatus == 1 && stdout.strip.empty?
      end
      true
    rescue SystemCallError
      false
    end

    def atomic_write(path, value)
      temp = "#{path}.tmp-#{SecureRandom.hex(8)}"
      raise InvalidState, "abandon-preflight: foreign temporary evidence" if File.exist?(temp) || File.symlink?(temp)
      File.open(temp, "w", 0o600) { |file| file.write(JSON.pretty_generate(value) + "\n"); file.flush; file.fsync }
      File.rename(temp, path)
    end
  end
end
