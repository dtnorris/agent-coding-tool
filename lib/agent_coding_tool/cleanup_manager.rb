# frozen_string_literal: true

require "json"
require "open3"

module AgentCodingTool
  # Read-only preflight first; native Git removals only after every candidate
  # has passed. Evidence and feature refs survive removal.
  class CleanupManager
    SHA = /\A[0-9a-f]{40}\z/

    def initialize(data_root:, provider: nil, liveness: nil, after_removal: nil)
      @data_root = File.realpath(data_root)
      @provider = provider || GitHubDeliveryProvider.new
      @liveness = liveness || CleanupLiveness.new
      @after_removal = after_removal
    end

    # Returns all removal targets and blockers for one task without mutation.
    # Both recorded layouts require native ownership, terminal use and existing
    # completion/integration gates; invalid task/evidence roots raise InvalidState.
    def preflight(id)
      raise InvalidTask, "cleanup: unsafe task ID" unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      root = File.join("#{@data_root}-runs", id)
      raise InvalidState, "cleanup: missing/foreign task evidence" unless File.directory?(root) && !File.symlink?(root)
      state = StateStore.new(File.join(@data_root, "state")).load(id)
      task = TaskStore.new(File.join(@data_root, "tasks")).load(id)
      outcome = state.dig("result", "outcome")
      rows = []
      owned_paths = []
      run_dirs = Dir.children(root).sort.map { |entry| File.join(root, entry) }
      raise InvalidState, "cleanup: no task attempts" if run_dirs.empty?
      run_dirs.each do |run_dir|
        unless File.directory?(run_dir) && !File.symlink?(run_dir)
          rows << { "path" => run_dir, "blockers" => ["foreign attempt evidence"] }
          next
        end
        report_path = File.join(run_dir, "handoff.json")
        record_path = File.join(run_dir, "worktrees.json")
        if [report_path, record_path].any? { |path| !File.file?(path) || File.symlink?(path) }
          rows << { "path" => run_dir, "blockers" => ["missing or foreign run record"] }
          next
        end
        begin
          report = JSON.parse(File.binread(report_path))
          inventory_raw = JSON.parse(File.binread(record_path))
          if report["status"] == "preflight_abandoned"
            unless abandoned_preflight?(id, report, inventory_raw, record_path, task)
              raise InvalidState, "cleanup: unverified abandoned preflight"
            end
            WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root,
                                record_path: record_path).inspect!
            owned_paths.concat(inventory_raw.fetch("entries").map { |entry| entry.fetch("path") })
            blockers = outcome == "complete" ? [] : ["task outcome is #{outcome || 'unfinished'}"]
            rows << { "attempt" => report.fetch("attempt"), "path" => run_dir,
                      "state" => "preflight_abandoned", "blockers" => blockers }
            next
          end
          unless report["schema_version"] == Launcher::SCHEMA && report["task_id"] == id &&
                 report["worktrees_path"] == record_path &&
                 immutable_inventory(report["worktrees"]) == immutable_inventory(inventory_raw) &&
                 report["attempt"] == inventory_raw["attempt"] && inventory_raw["task_id"] == id &&
                 report["preparation"].is_a?(Hash) && state["snapshot"] == report["preparation"] &&
                 report["preparation"].keys.sort == task.fetch("repositories").keys.sort
            raise InvalidState, "cleanup: task/attempt identity changed"
          end
          config = Config.load(File.join(@data_root, "config.yml"))
          manager = WorktreeManager.new(root: config.worktree_root, record_path: record_path)
          overrides = inventory_raw.fetch("entries").filter_map do |entry|
            next unless entry["access"] == "write"
            detail = delivery_detail(run_dir, entry.fetch("name"), inventory_raw)
            [entry.fetch("name"), detail.fetch("commit_sha")] if detail && detail["commit_sha"].to_s.match?(SHA)
          end.to_h
          inventory = manager.inspect!(head_overrides: overrides)
          names = inventory.fetch("entries").map { |entry| entry.fetch("name") }
          raise InvalidState, "cleanup: repository set changed" unless names.sort == task.fetch("repositories").keys.sort
          liveness = @liveness.check(report, inventory)
          inventory.fetch("entries").each do |entry|
            name, path = entry.values_at("name", "path")
            owned_paths << path
            blockers = []
            blockers << "task outcome is #{outcome || 'unfinished'}" unless outcome == "complete"
            blockers << "worker liveness #{liveness}" unless liveness == :clear
            prepared = report.fetch("preparation").fetch(name)
            blockers << "task access changed" unless task.fetch("repositories").fetch(name).fetch("access") == entry.fetch("access")
            unless prepared.values_at("path", "remote_url", "branch", "pushed_sha") ==
                   [entry.fetch("parent"), entry.fetch("remote_url"), entry.fetch("source_branch"), entry.fetch("base_sha")]
              blockers << "prepared identity changed"
            end
            if entry["state"] != "removed" && File.directory?(path)
              dirty = !git(path, "--no-optional-locks", "status", "--porcelain", "--untracked-files=all").empty?
              blockers << "worktree contains changes" if dirty
            end
            if entry["access"] == "write"
              detail = delivery_detail(run_dir, name, inventory)
              blockers.concat(publication_blockers(entry, detail))
            end
            rows << { "attempt" => inventory.fetch("attempt"), "repository" => name,
                      "path" => path, "state" => entry.fetch("state"), "blockers" => blockers }
          end
        rescue Error, JSON::ParserError, KeyError, TypeError, SystemCallError => e
          rows << { "path" => run_dir, "blockers" => [e.message] }
        end
      end
      # A task directory may contain only the exact active paths in the
      # ownership records. Unknown files cannot be treated as disposable.
      visible = Config.load(File.join(@data_root, "config.yml")).worktree_root
      begin
        foreign = WorktreeManager.foreign_task_paths(root: visible, task_id: id, paths: owned_paths)
        rows << { "path" => File.join(visible, id), "blockers" => ["foreign task path entries: #{foreign.join(', ')}"] } unless foreign.empty?
      rescue InvalidState => error
        rows << { "path" => File.join(visible, id), "blockers" => [error.message] }
      end
      { "task_id" => id, "dry_run" => true, "attempts" => rows, "blocked" => rows.any? { |row| !row.fetch("blockers").empty? } }
    end

    def remove(id)
      inventory = preflight(id)
      raise InvalidState, "cleanup: #{inventory.fetch('attempts').flat_map { |row| row.fetch('blockers') }.uniq.join('; ')}" if inventory.fetch("blocked")
      root = File.join("#{@data_root}-runs", id)
      Dir.children(root).sort.each do |attempt|
        run_dir = File.join(root, attempt)
        record_path = File.join(run_dir, "worktrees.json")
        manager = WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root,
                                      record_path: record_path)
        record = JSON.parse(File.binread(record_path))
        overrides = record.fetch("entries").filter_map do |entry|
          next unless entry["access"] == "write"
          detail = delivery_detail(run_dir, entry.fetch("name"), record)
          [entry.fetch("name"), detail.fetch("commit_sha")] if detail && detail["commit_sha"].to_s.match?(SHA)
        end.to_h
        record.fetch("entries").each do |entry|
          next if entry["state"] == "removed"
          manager.remove_entry!(entry.fetch("name"), head_overrides: overrides)
          @after_removal&.call(entry)
        end
      end
      preflight(id)
    end

    private

    def immutable_inventory(inventory)
      return nil unless inventory.is_a?(Hash) && inventory["entries"].is_a?(Array)
      inventory.reject { |key, _value| key == "entries" }.merge(
        "entries" => inventory.fetch("entries").map { |entry|
          entry.reject { |key, _value| key == "state" } })
    end

    def abandoned_preflight?(id, report, inventory, record_path, task)
      return false unless report["schema_version"] == Launcher::SCHEMA && report["task_id"] == id &&
        report["preflight_abandoned_at"] && report["error"].is_a?(String) &&
        report["worktrees_path"] == record_path && report["attempt"] == inventory["attempt"] &&
        inventory["schema_version"] == WorktreeManager::SCHEMA && inventory["task_id"] == id &&
        immutable_inventory(report["worktrees"]) == immutable_inventory(inventory) &&
        report["preparation"].is_a?(Hash) && report["preparation"].keys.sort == task.fetch("repositories").keys.sort &&
        %w[argv child_pid child_started_at started_at session_id ended_at].all? { |key| report[key].nil? }
      entries = inventory.fetch("entries")
      return false unless entries.is_a?(Array) && entries.map { |entry| entry.fetch("name") }.sort == task.fetch("repositories").keys.sort
      entries.all? do |entry|
        prepared = report.fetch("preparation").fetch(entry.fetch("name"))
        entry["state"] == "removed" &&
          task.fetch("repositories").fetch(entry.fetch("name")).fetch("access") == entry["access"] &&
          prepared.values_at("path", "remote_url", "branch", "pushed_sha") ==
            entry.values_at("parent", "remote_url", "source_branch", "base_sha")
      end
    rescue KeyError, TypeError
      false
    end

    def delivery_detail(run_dir, name, inventory)
      writers = inventory.fetch("entries").count { |entry| entry["access"] == "write" }
      path = if writers == 1
               File.join(run_dir, "delivery.json")
             else
               File.join(run_dir, "repositories", name, "delivery.json")
             end
      return nil unless File.file?(path) && !File.symlink?(path)
      JSON.parse(File.binread(path))
    end

    def publication_blockers(entry, detail)
      return ["missing verified PR delivery"] unless detail.is_a?(Hash)
      if detail["stage"] == "unchanged"
        return ["unverified unchanged repository"] unless
          detail["schema"] == DeliveryManager::SCHEMA && detail["task_id"] == entry["task_id"] &&
          (detail["repository"].nil? || detail["repository"] == entry["name"]) &&
          detail["base_sha"] == entry["base_sha"] && detail["workspace"] == entry["path"] &&
          system_git(entry.fetch("parent"), "merge-base", "--is-ancestor", entry.fetch("base_sha"), "HEAD")
        return []
      end
      commit = detail["commit_sha"]
      unless detail["schema"] == DeliveryManager::SCHEMA && detail["stage"] == "draft_pr" &&
             detail["task_id"] == entry["task_id"] && detail["base_sha"] == entry["base_sha"] &&
             (detail["repository"].nil? || detail["repository"] == entry["name"]) &&
             detail["workspace"] == entry["path"] && commit.to_s.match?(SHA)
        return ["unverified or partial delivery"]
      end
      pr = detail["pr"]
      return ["missing PR identity"] unless pr.is_a?(Hash) && pr["url"].is_a?(String) &&
        pr["head"] == commit && pr["base"] == entry["source_branch"]
      integration = @provider.integration(entry.fetch("remote_url"), pr.fetch("url"))
      unless integration && integration["merged"] == true && integration["head"] == commit &&
             integration["base"] == entry["source_branch"] && integration["merge_commit_sha"].to_s.match?(SHA)
        return ["PR not verifiably merged into authorized target"]
      end
      checkout = entry.fetch("parent")
      merged = integration.fetch("merge_commit_sha")
      return ["ordinary checkout has not integrated PR result"] unless
        system_git(checkout, "merge-base", "--is-ancestor", merged, "HEAD")
      []
    rescue Error, KeyError, TypeError
      ["PR integration evidence unavailable"]
    end

    def git(path, *args)
      stdout, stderr, status = Open3.capture3("git", *args, chdir: path)
      raise RepositoryError, "cleanup: git #{args.first} failed: #{stderr.strip}" unless status.success?
      stdout.strip
    end

    def system_git(path, *args)
      Open3.capture3("git", *args, chdir: path).last.success?
    end
  end

  class CleanupLiveness
    def check(report, inventory)
      return :unknown unless report["status"] == "exited" && report["ended_at"] && report["child_pid"].is_a?(Integer)
      begin
        Process.kill(0, -report.fetch("child_pid"))
        return :active
      rescue Errno::ESRCH
        nil
      rescue Errno::EPERM
        return :unknown
      end
      inventory.fetch("entries").each do |entry|
        next if entry["state"] == "removed"
        output, _err, status = Open3.capture3("lsof", "-n", "-P", "+D", entry.fetch("path"))
        return :active if status.exitstatus == 0 && !output.strip.empty?
        return :unknown unless status.exitstatus == 1
      end
      :clear
    rescue Errno::ENOENT, SystemCallError
      :unknown
    end
  end
end
