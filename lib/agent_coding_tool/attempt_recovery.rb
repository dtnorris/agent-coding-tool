# frozen_string_literal: true

require "digest"
require "json"
require "socket"

module AgentCodingTool
  # Preserves unsuccessful attempts in place. Closeout grants only eligibility
  # for explicit fresh preparation, never deletion, acceptance or publication.
  class AttemptRecovery
    SCHEMA = "agent-coding-tool-closeout/v1"
    OUTCOMES = %w[blocked failed needs_judgment].freeze
    STATUSES = %w[exited invalid_final interrupted child_start_failed preflight_failed].freeze

    # Uses private ACT evidence and optional deterministic liveness/fault seams.
    def initialize(data_root:, liveness: RetryLiveness.new, before_write: nil, after_write: nil)
      @data = File.realpath(data_root)
      @root = "#{@data}-runs"
      @config = Config.load(File.join(@data, "config.yml"))
      @liveness, @before_write, @after_write = liveness, before_write, after_write
    end

    # Returns independent historical rows, retaining valid inventories when a
    # sibling attempt is damaged. Inspection writes nothing; blockers are data.
    def inspect(id)
      TaskStore.new(File.join(@data, "tasks")).load(id)
      directories(id).map do |directory|
        begin
          inspect_attempt(id, directory)
        rescue Error, KeyError, TypeError, NoMethodError, ArgumentError, SystemCallError, JSON::ParserError => error
          { "run_dir" => directory, "classification" => "unverified", "blockers" => [error.message] }
        end
      end.sort_by { |row| [row.fetch("attempt", 1 << 30), row.fetch("run_dir")] }
    end

    # Plans closeout without locks or writes. Refuses uncertain ownership,
    # unpreserved changes, delivery, active/unknown processes and missing outcome.
    def preflight(id)
      state = StateStore.new(File.join(@data, "state")).load(id)
      raise InvalidState, "close-attempt: record blocked, failed or needs_judgment first" unless
        OUTCOMES.include?(state.dig("result", "outcome")) && !state["started_at"]
      rows = inspect(id)
      raise InvalidState, "close-attempt: #{rows.flat_map { |row| row.fetch('blockers') }.join('; ')}" if
        rows.any? { |row| !row.fetch("blockers").empty? }
      raise InvalidState, "close-attempt: missing or conflicting attempt sequence" unless
        !rows.empty? && rows.map { |row| row["attempt"] } == (1..rows.length).to_a
      rows.each do |row|
        next if row["legacy_abandoned"]
        directory = row.fetch("run_dir")
        report = read_json(File.join(directory, "handoff.json"))
        raise InvalidState, "close-attempt: execution is not terminal" unless STATUSES.include?(report["status"])
        raise InvalidState, "close-attempt: delivery/publication requires its existing recovery path" if
          Dir.glob(File.join(directory, "**", "{delivery,validation}.json")).any?
        inventory = row["inventory"] || { "entries" => [] }
        verify_clean!(inventory)
        unless @liveness.check(report, inventory) == :clear
          raise InvalidState, "close-attempt: active or unknown host/worker/worktree use; preserve and inspect"
        end
        verify_checkpoint!(id, report, row.fetch("checkpoint"), attempt: row.fetch("attempt")) if row["checkpoint"]
        next if row["closed"]
        # A newer preparation cannot stand in for the original checkpoint or
        # outcome. Historical unresolved preparations remain an explicit blocker.
        unless report.values_at("prepared_at", "preparation") == state.values_at("prepared_at", "snapshot")
          raise InvalidState, "close-attempt: original outcome/checkpoint context unavailable; do not infer it from current state"
        end
        if state["checkpoint"]
          verify_checkpoint!(id, report, state.fetch("checkpoint"))
        end
      end
      verify_task_paths!(id, rows)
      { "task_id" => id, "dry_run" => true, "attempts" => rows, "state" => state }
    end

    # Publishes one immutable closeout per attempt under the launch lock. No
    # resources or lifecycle state change. Rechecks before each durable write;
    # interruption leaves prior closeouts truthful and supports a cold repeat.
    def close(id)
      private_root!
      lock_path = File.join(@root, "launch.lock")
      raise InvalidState, "close-attempt: missing or foreign reservation lock" unless
        File.file?(lock_path) && !File.symlink?(lock_path) && File.stat(lock_path).uid == Process.uid &&
        (File.stat(lock_path).mode & 0o077).zero?
      File.open(lock_path, File::RDWR) do |lock|
        raise InvalidState, "close-attempt: launch/recovery reservation busy" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        plan = preflight(id)
        plan.fetch("attempts").each do |row|
          next if row["closed"] || row["legacy_abandoned"]
          @before_write&.call(row)
          current = preflight(id)
          raise InvalidState, "close-attempt: evidence or state changed during closeout" unless current == plan
          directory = row.fetch("run_dir")
          report = read_json(File.join(directory, "handoff.json"))
          original = report.fetch("execution_state", report.fetch("preparation_state", {})).merge(
            "id" => id, "prepared_at" => report.fetch("prepared_at"), "snapshot" => report.fetch("preparation"),
            "result" => plan.fetch("state").fetch("result"))
          original["checkpoint"] = plan.fetch("state")["checkpoint"] if plan.fetch("state")["checkpoint"]
          value = { "schema" => SCHEMA, "task_id" => id, "attempt" => row.fetch("attempt"),
                    "invocation_id" => report.fetch("invocation_id"), "closed_at" => Time.now.utc.iso8601(6),
                    "state" => original, "evidence" => evidence_hashes(directory),
                    "operation" => "preserve_for_retry" }
          atomic_write(File.join(directory, "closeout.json"), value)
          @after_write&.call(row)
          plan = preflight(id)
        end
        plan.merge("dry_run" => false)
      end
    end

    # Refuses retry until each managed attempt has a valid explicit closeout (or
    # legacy pre-worker abandonment). Revalidates protected resources and use;
    # choosing an unused path alone is never an ownership/liveness bypass.
    def retry_ready!(id, current_run: nil)
      all_rows = inspect(id)
      rows = all_rows
      rows = rows.reject { |row| row["run_dir"] == current_run } if current_run
      return if rows.empty?
      raise InvalidState, "#{id}: #{rows.flat_map { |row| row.fetch('blockers') }.join('; ')}" if
        rows.any? { |row| !row.fetch("blockers").empty? }
      raise InvalidState, "#{id}: conflicting attempt sequence" unless rows.map { |row| row["attempt"] } == (1..rows.length).to_a
      rows.each do |row|
        next if row["legacy_abandoned"]
        raise InvalidState, "#{id}: explicit close-attempt required before fresh preparation/relaunch" unless row["closed"]
        report = read_json(File.join(row.fetch("run_dir"), "handoff.json"))
        verify_clean!(row["inventory"] || { "entries" => [] })
        if row["checkpoint"]
          verify_checkpoint!(id, report, row.fetch("checkpoint"), attempt: row.fetch("attempt"))
        end
        raise InvalidState, "#{id}: historical worker use active or unknown" unless
          @liveness.check(report, row["inventory"] || { "entries" => [] }) == :clear
      end
      verify_task_paths!(id, all_rows)
    end

    # Lists prior owned paths for the next attempt's sandbox deny probes. The
    # caller already holds the launch lock and has passed retry_ready!.
    def protected_paths(id, before_attempt:)
      directories(id).filter_map do |directory|
        report = read_json(File.join(directory, "handoff.json"))
        next unless report.fetch("attempt") < before_attempt
        record = File.join(directory, "worktrees.json")
        WorktreeManager.new(root: @config.worktree_root, record_path: record)
                       .inspect!(allow_partial: report["status"] == "preflight_failed") if File.file?(record)
      end.flat_map { |inventory| inventory.fetch("entries") }
                 .filter_map { |entry| entry.fetch("path") if File.directory?(entry.fetch("path")) }
    end

    # Returns the preserved original context for checkpoint inspection/recovery.
    # Invalid hashes or ambiguous identity raise rather than using current state.
    def closed_state(id, attempt)
      row = inspect(id).find { |item| item["attempt"] == attempt }
      raise InvalidState, "checkpoint: no verified historical closeout" unless row && row["closed"] && row.fetch("blockers").empty?
      read_json(File.join(row.fetch("run_dir"), "closeout.json")).fetch("state")
        .merge("launch_invocation" => row.fetch("invocation_id"))
    end

    private

    # Requires verified preservation bound to this exact execution, independently
    # of the current policy/pointers. Wrong/stale checkpoint identity refuses.
    def verify_checkpoint!(id, report, checkpoint, attempt: nil)
      original = report["execution_state"]
      expected = Digest::SHA256.hexdigest(JSON.generate(original.values_at("prepared_at", "started_at", "snapshot")))[0, 32] if original.is_a?(Hash)
      unless checkpoint.is_a?(Hash) && checkpoint["status"] == "verified" &&
             original.is_a?(Hash) && original["started_at"] && checkpoint["attempt"] == expected
        raise InvalidState, "close-attempt: stale checkpoint or original execution identity unavailable"
      end
      evidence = Checkpoint.new(data_root: @data).verify(id, attempt: attempt)
      unless evidence["status"] == "verified" && evidence.fetch("record")["launch_invocation"] == report.fetch("invocation_id")
        raise InvalidState, "close-attempt: checkpoint belongs to another invocation"
      end
    end

    # Refuses every tracked, staged, untracked or ignored change, even when a
    # patch exists. Preservation is not permission to discard or reuse code.
    def verify_clean!(inventory)
      inventory.fetch("entries").each do |entry|
        next unless File.directory?(entry.fetch("path"))
        output, error, status = Open3.capture3("git", "--no-optional-locks", "status", "--porcelain",
                                             "--untracked-files=all", "--ignored", chdir: entry.fetch("path"))
        raise InvalidState, "close-attempt: dirty or unreadable worktree #{entry['path']}: #{error}" unless
          status.success? && output.empty?
      end
    end

    # Validates task/evidence ancestry and privacy, returning attempt directories.
    # No absent evidence directory is created by this read-only operation.
    def directories(id)
      raise InvalidTask, "close-attempt: unsafe task ID" unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      return [] unless File.exist?(@root) || File.symlink?(@root)
      private_root!
      path = File.join(@root, id)
      return [] unless File.exist?(path) || File.symlink?(path)
      safe_directory!(path)
      Dir.children(path).sort.map { |name| safe_directory!(File.join(path, name)) }
    end

    # Verifies one report against its own original preparation and native Git
    # inventory, never the task's newer state. Returns discoverable references.
    def inspect_attempt(id, directory)
      if Dir.children(directory).any? { |name| name.end_with?(".tmp", ".pending") }
        raise InvalidState, "history: interrupted evidence publication; preserve temporary records for judgment"
      end
      report_path = File.join(directory, "handoff.json")
      report = read_json(report_path)
      record = File.join(directory, "worktrees.json")
      unless report["schema_version"] == Launcher::SCHEMA && report["task_id"] == id &&
             report["attempt"].is_a?(Integer) && report["attempt"].positive? &&
             report["worktrees_path"] == record && report["preparation"].is_a?(Hash) &&
             !report["preparation"].empty?
        raise InvalidState, "history: task/attempt/original preparation identity mismatch"
      end
      row = report.slice("task_id", "attempt", "invocation_id", "status", "prepared_at", "preparation", "artifacts")
                  .merge("run_dir" => directory, "blockers" => [], "closed" => false)
      if report["preparation_state"] && report.fetch("preparation_state").values_at("id", "prepared_at", "snapshot") !=
         [id, report.fetch("prepared_at"), report.fetch("preparation")]
        raise InvalidState, "history: original preparation snapshot changed"
      end
      if report["execution_state"] &&
         (!report.fetch("execution_state").is_a?(Hash) ||
          report.fetch("execution_state").values_at("id", "prepared_at", "snapshot") != [id, report.fetch("prepared_at"), report.fetch("preparation")] ||
          !report.dig("execution_state", "started_at").is_a?(String))
        raise InvalidState, "history: original execution snapshot changed"
      end
      if File.exist?(record) || File.symlink?(record)
        inventory = WorktreeManager.new(root: @config.worktree_root, record_path: record)
                                   .inspect!(allow_partial: report["status"] == "preflight_failed")
        unless inventory.values_at("task_id", "attempt") == report.values_at("task_id", "attempt") &&
               (!inventory["invocation_id"] || inventory["invocation_id"] == report["invocation_id"]) &&
               inventory.fetch("entries").map { |entry| entry.fetch("name") }.sort == report.fetch("preparation").keys.sort
          raise InvalidState, "history: inventory identity mismatch"
        end
        if report["worktrees"] && immutable(report.fetch("worktrees")) != immutable(inventory)
          raise InvalidState, "history: inventory differs from original report"
        end
        inventory.fetch("entries").each do |entry|
          prepared = report.fetch("preparation").fetch(entry.fetch("name"))
          unless prepared.values_at("path", "remote", "remote_url", "branch", "pushed_sha") ==
                   entry.values_at("parent", "remote", "remote_url", "source_branch", "base_sha")
            raise InvalidState, "history: original repository/access/base identity mismatch"
          end
        end
        row["inventory"] = inventory
        row["entries"] = inventory.fetch("entries")
        row["classification"] = inventory.fetch("entries").any? { |entry| %w[pending creating].include?(entry["state"]) } ? "partial_creation" : "owned"
        if report["status"] == "preflight_abandoned"
          unless report["preflight_abandoned_at"].is_a?(String) && Time.iso8601(report.fetch("preflight_abandoned_at")) &&
                 report["worktrees"].is_a?(Hash) && report["invocation_id"].is_a?(String) && !report["invocation_id"].empty? &&
                 report["host_pid"].is_a?(Integer) && report["host_pid"].positive? &&
                 report["error"].is_a?(String) && !report["error"].empty? &&
                 %w[argv child_pid child_started_at started_at session_id ended_at execution_state artifacts exit_status final_valid heartbeat_at heartbeat_child_pid].all? { |key| report[key].nil? } &&
                 inventory.fetch("entries").all? { |entry| entry["state"] == "removed" }
            raise InvalidState, "history: abandoned preflight has unverified pre-worker evidence"
          end
          row["legacy_abandoned"] = true
        end
      else
        verify_no_creation!(id, report)
        row["classification"] = "verified_precreation_failure"
      end
      verify_artifacts!(report, directory)
      verify_original_contract!(report, directory, row.fetch("inventory")) if row["inventory"]
      closeout_path = File.join(directory, "closeout.json")
      if File.exist?(closeout_path) || File.symlink?(closeout_path)
        closeout = read_json(closeout_path)
        original = report.fetch("execution_state", report.fetch("preparation_state", {})).merge(
          "id" => id, "prepared_at" => report.fetch("prepared_at"), "snapshot" => report.fetch("preparation"))
        unless closeout["schema"] == SCHEMA && closeout["operation"] == "preserve_for_retry" &&
               closeout.values_at("task_id", "attempt", "invocation_id") == report.values_at("task_id", "attempt", "invocation_id") &&
               closeout["evidence"] == evidence_hashes(directory) &&
               closeout.fetch("state").values_at("prepared_at", "snapshot") == report.values_at("prepared_at", "preparation") &&
               closeout.fetch("state").reject { |key, _| %w[result checkpoint].include?(key) } ==
                 original.reject { |key, _| %w[result checkpoint].include?(key) } &&
               OUTCOMES.include?(closeout.dig("state", "result", "outcome"))
          raise InvalidState, "history: closeout evidence changed or has foreign identity"
        end
        row["closed"] = true
        row["checkpoint"] = closeout.dig("state", "checkpoint")
      end
      row["closeout_blockers"] = []
      begin
        verify_clean!(row["inventory"] || { "entries" => [] })
      rescue InvalidState => error
        row.fetch("closeout_blockers") << error.message
      end
      row.fetch("closeout_blockers") << "host/boot identity unavailable" unless report["host_identity"] || row["legacy_abandoned"]
      row["liveness"] = "not checked; use close-attempt --dry-run"
      row["next_action"] = row["closed"] || row["legacy_abandoned"] ? "explicit prepare --retry, then launch" : "record non-complete outcome; close-attempt --dry-run"
      row
    end

    # Corroborates historical names, bases and access with the original prompt,
    # whose bytes must already pass verify_artifacts!. The report/inventory alone
    # cannot authorize access. Returns nil; missing or inconsistent bindings raise
    # InvalidState. Legacy runs may bind the prompt through their artifact list.
    def verify_original_contract!(report, directory, inventory)
      path = File.join(directory, "prompt.txt")
      unless report["prompt_sha256"] || report.fetch("artifacts", []).any? { |artifact| artifact["path"] == path }
        raise InvalidState, "history: original repository contract is not bound to prompt evidence"
      end
      prompt = checked_file(path)
      sources = report.fetch("preparation").map do |name, prepared|
        "- #{name}\n" + %w[path remote_url branch pushed_sha].map do |field|
          "  - #{field}: #{prepared.fetch(field)}\n"
        end.join
      end.join
      access = { "write" => "Writable repositories", "read_only" => "Read-only repositories" }.map do |mode, title|
        names = inventory.fetch("entries").filter_map { |entry| entry.fetch("name") if entry["access"] == mode }
        "## #{title}\n\n#{names.map { |name| "- #{name}\n" }.join}\n" unless names.empty?
      end.join
      access += "Only the repositories designated writable above may be modified for this task. Other connected repositories, including the task-data repository, may be read when needed; reading one does not grant write authority.\n"
      unless prompt.scan(/^#{Regexp.escape((sources + "\n" + access).b)}/n).length == 1
        raise InvalidState, "history: original repository/access/base contract differs from bound prompt"
      end
    end

    # Missing inventory is harmless only before any mutation: prove all planned
    # paths/branches absent, or legacy paths exactly owned by earlier inventories.
    # Registry/ref checks catch a deleted ownership file after native addition.
    def verify_no_creation!(id, report)
      if report["worktree_layout"] == "attempt" && report["worktree_creation"] != "not_started"
        raise InvalidState, "history: unaccounted mutation; ownership missing after inventory publication"
      end
      unless report["status"] == "preflight_failed" && report["workspace"].nil? && report["worktrees"].nil? &&
             %w[argv child_pid child_started_at started_at ended_at].all? { |key| report[key].nil? }
        raise InvalidState, "history: missing ownership after possible mutation"
      end
      root = WorktreeManager.canonical_system_path(@config.worktree_root)
      report.fetch("preparation").each do |name, prepared|
        path = File.join(root, id, *(report["worktree_layout"] == "attempt" ? ["attempt-#{report.fetch('attempt')}"] : []), name)
        manager = WorktreeManager.new(root: root, record_path: report.fetch("worktrees_path"))
        manager.send(:parent_identity!, prepared, name)
        manager.send(:safe_path!, path)
        parent = prepared.fetch("path")
        branch = "refs/heads/act/#{id}/attempt-#{report.fetch('attempt')}"
        _output, _error, status = Open3.capture3("git", "show-ref", "--verify", "--quiet", branch, chdir: parent)
        raise InvalidState, "history: unaccounted attempt branch; missing ownership after mutation" unless status.exitstatus == 1
        registry, error, status = Open3.capture3("git", "worktree", "list", "--porcelain", "-z", chdir: parent)
        raise InvalidState, "history: unreadable registry: #{error}" unless status.success?
        if File.exist?(path) || File.symlink?(path) || registry.split("\0").include?("worktree #{path}")
          prior = directories(id).filter_map do |directory|
            record = File.join(directory, "worktrees.json")
            next unless File.file?(record) && !File.symlink?(record)
            inventory = WorktreeManager.new(root: root, record_path: record).inspect!
            next unless inventory["task_id"] == id && inventory["attempt"] < report.fetch("attempt")
            inventory.fetch("entries").find { |entry| entry["path"] == path && entry["name"] == name &&
              entry.values_at("parent", "remote", "remote_url", "source_branch", "base_sha") ==
                prepared.values_at("path", "remote", "remote_url", "branch", "pushed_sha") }
          end
          raise InvalidState, "history: unaccounted worktree; missing ownership after mutation" unless prior.length == 1 && report["worktree_layout"].nil?
        end
      end
    end

    # Refuses unknown children at either layout depth without touching siblings.
    def verify_task_paths!(id, rows)
      entries = rows.flat_map { |row| row.dig("inventory", "entries") || [] }
      foreign = WorktreeManager.foreign_task_paths(root: @config.worktree_root, task_id: id,
                                                   paths: entries.map { |entry| entry.fetch("path") })
      raise InvalidState, "close-attempt: foreign task path entries" unless foreign.empty?
    end

    # Verifies recorded log/prompt hashes and canonical attempt-local locations.
    def verify_artifacts!(report, directory)
      if report["prompt_sha256"]
        prompt = checked_file(File.join(directory, "prompt.txt"))
        raise InvalidState, "history: original prompt checksum/length mismatch" unless
          Digest::SHA256.hexdigest(prompt) == report.fetch("prompt_sha256") && prompt.bytesize == report.fetch("prompt_bytes")
      end
      if report["child_pid"]
        expected = %w[prompt_path stdin_path jsonl_path stderr_path final_path].filter_map do |key|
          path = report.fetch(key)
          raise InvalidState, "history: foreign artifact path" unless File.dirname(path) == directory
          path if File.file?(path)
        end
        unless report["artifacts"].is_a?(Array) && report.fetch("artifacts").map { |artifact| artifact.fetch("path") }.sort == expected.sort
          raise InvalidState, "history: missing or conflicting artifact inventory"
        end
      end
      report.fetch("artifacts", []).each do |artifact|
        path = artifact.fetch("path")
        raise InvalidState, "history: foreign artifact" unless File.dirname(path) == directory
        bytes = checked_file(path)
        raise InvalidState, "history: artifact checksum/length mismatch" unless
          bytes.bytesize == artifact.fetch("bytes") && Digest::SHA256.hexdigest(bytes) == artifact.fetch("sha256")
      end
    end

    # Binds every immutable run artifact, including partial operation markers.
    # Closeout is separate and excluded; unexpected entries refuse, not disappear.
    def evidence_hashes(directory)
      Dir.children(directory).sort.reject { |name| name == "closeout.json" }.to_h do |name|
        path = File.join(directory, name)
        [name, Digest::SHA256.hexdigest(checked_file(path))]
      end
    end

    # Removes only mutable cleanup state fields for original-inventory comparison.
    def immutable(inventory)
      inventory.merge("entries" => inventory.fetch("entries").map { |entry| entry.reject { |key, _| key == "state" } })
    end

    # Reads a plain evidence file; symlinks, missing files and bad JSON refuse.
    def checked_file(path)
      raise InvalidState, "history: missing/foreign evidence #{path}" unless File.file?(path) && !File.symlink?(path)
      File.binread(path)
    end

    # Returns parsed host evidence, propagating malformed JSON to the caller.
    def read_json(path) = JSON.parse(checked_file(path))

    # Verifies every ancestor and operator ownership without creating directories.
    def safe_directory!(path)
      cursor = path
      loop do
        raise InvalidState, "history: symlinked evidence/resource ancestor" if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)
        cursor = File.dirname(cursor)
      end
      raise InvalidState, "history: missing/foreign directory" unless File.directory?(path) && File.stat(path).uid == Process.uid
      path
    end

    # Enforces the existing private sibling evidence-root contract read-only.
    def private_root!
      safe_directory!(@root)
      raise InvalidState, "history: evidence root is not private" unless (File.stat(@root).mode & 0o077).zero?
    end

    # Syncs and publishes a new immutable closeout. Stale temporary evidence
    # blocks future recovery; post-publication failures never erase the record.
    def atomic_write(path, value)
      temporary = "#{path}.pending"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        file.write(JSON.pretty_generate(value) + "\n")
        file.flush
        file.fsync
      end
      raise InvalidState, "close-attempt: closeout appeared during publication" if File.exist?(path) || File.symlink?(path)
      File.rename(temporary, path)
      File.open(File.dirname(path)) { |directory| directory.fsync }
    end
  end

  # Conservative observations for non-destructive retry only. This does not
  # prove escaped/reparented descendants terminated and grants no cleanup right;
  # safety also requires the per-attempt sandbox and protected shared Git admin.
  class RetryLiveness
    # Returns local host/boot identity, or nil when it cannot be verified. No ps,
    # nested sandbox, worker, process enumeration or network access is performed.
    def self.host_identity
      boot = if RbConfig::CONFIG.fetch("host_os").match?(/darwin/)
               output, error, status = Open3.capture3("/usr/sbin/sysctl", "-n", "kern.bootsessionuuid")
               output.strip if status.success? && error.empty?
             else
               File.read("/proc/sys/kernel/random/boot_id").strip
             end
      return nil unless boot&.match?(/\A[0-9a-fA-F-]{36}\z/)
      { "hostname" => Socket.gethostname, "boot" => boot, "uid" => Process.uid }
    rescue SystemCallError
      nil
    end

    # Hostname may change within one boot; only a complete boot UUID and UID
    # match permits that exception. Exact historical matches remain supported.
    def self.same_boot_and_user?(recorded, current)
      keys = %w[boot hostname uid]
      return false unless recorded.is_a?(Hash) && current.is_a?(Hash) &&
        recorded.keys.sort == keys && current.keys.sort == keys
      return false unless [recorded, current].all? { |value|
        value["hostname"].is_a?(String) && !value["hostname"].empty? &&
          value["boot"].is_a?(String) &&
          value["boot"].match?(/\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z/) &&
          value["uid"].is_a?(Integer) && value["uid"] >= 0
      }
      recorded.values_at("boot", "uid") == current.values_at("boot", "uid")
    end

    # Only the exact three-line warning for a separate macOS Time Machine SMB
    # volume is ignorable. A warning about the inspected volume still refuses.
    def unrelated_time_machine_warning?(error, path)
      pattern = %r{\Alsof: WARNING: can't stat\(\) smbfs file system /Volumes/\.timemachine/[^/\r\n]+/[0-9a-fA-F-]{36}/[^/\r\n]+\n {6}Output information may be incomplete\.\n {6}assuming "dev=[0-9a-fA-F]+" from mount table\n?\z}
      return false unless error.match?(pattern)
      actual = File.realpath(path)
      actual != "/Volumes/.timemachine" && !actual.start_with?("/Volumes/.timemachine/")
    end

    # Refuses active/reused PIDs, groups, contradictory evidence and unavailable
    # tools. :clear means these bounded observations passed, not containment.
    def check(report, inventory)
      identity = self.class.host_identity
      return :unknown unless identity && (report["host_identity"] == identity ||
        self.class.same_boot_and_user?(report["host_identity"], identity))
      return :unknown unless AttemptRecovery::STATUSES.include?(report["status"]) && report["host_pid"].is_a?(Integer) && report["host_pid"].positive?
      child = report["child_pid"]
      if child
        return :unknown unless child.is_a?(Integer) && child.positive? && report["child_started_at"] &&
          report["ended_at"] && report["heartbeat_child_pid"] == child && report["heartbeat_at"] &&
          Time.iso8601(report.fetch("ended_at")) <= Time.now.utc + 1 &&
          Time.iso8601(report.fetch("heartbeat_at")) <= Time.iso8601(report.fetch("ended_at")) + 1 &&
          Time.iso8601(report.fetch("heartbeat_at")) >= Time.iso8601(report.fetch("child_started_at")) &&
          Time.iso8601(report.fetch("child_started_at")) <= Time.iso8601(report.fetch("ended_at"))
      elsif !%w[preflight_failed child_start_failed].include?(report["status"])
        return :unknown
      elsif %w[child_started_at heartbeat_at heartbeat_child_pid ended_at].any? { |key| report[key] }
        return :unknown
      end
      [report.fetch("host_pid"), child, child && -child].compact.each do |pid|
        begin
          Process.kill(0, pid)
          return :active
        rescue Errno::ESRCH
          nil
        rescue Errno::EPERM
          return :unknown
        end
      end
      inventory.fetch("entries").each do |entry|
        next unless File.directory?(entry.fetch("path"))
        output, error, status = Open3.capture3("lsof", "-n", "-P", "+D", entry.fetch("path"))
        return :active if status.exitstatus == 0 && !output.strip.empty?
        return :unknown unless status.exitstatus == 1 && output.empty?
        next if error.empty?
        return :unknown unless unrelated_time_machine_warning?(error, entry.fetch("path"))
        warn "act liveness: unrelated Time Machine SMB warning for #{entry.fetch('path')}:\n#{error}"
      end
      :clear
    rescue SystemCallError, IOError, KeyError, TypeError, ArgumentError
      :unknown
    end
  end
end
