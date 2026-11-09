# frozen_string_literal: true

require "json"
require "open3"
require "digest"

module AgentCodingTool
  # Read-only preflight first; native Git removals only after every candidate
  # has passed. Evidence and feature refs survive removal.
  class CleanupManager
    SHA = /\A[0-9a-f]{40}\z/
    EXTERNAL_SCHEMA = "agent-coding-tool-external-delivery/v1"

    def initialize(data_root:, provider: nil, liveness: nil, after_removal: nil, transport: NativeCommandTransport.new)
      @data_root = File.realpath(data_root)
      @transport = transport
      @provider = provider || GitHubDeliveryProvider.new(transport: transport)
      @liveness = liveness || CleanupLiveness.new
      @after_removal = after_removal
    end

    # Returns all removal targets and blockers for one task without mutation.
    # Both recorded layouts require native ownership, terminal use and existing
    # completion/integration gates; invalid task/evidence roots raise InvalidState.
    def preflight(id, pr: nil)
      raise InvalidTask, "cleanup: unsafe task ID" unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      root = File.join("#{@data_root}-runs", id)
      raise InvalidState, "cleanup: missing/foreign task evidence" unless File.directory?(root) && !File.symlink?(root)
      state = StateStore.new(File.join(@data_root, "state")).load(id)
      task = TaskStore.new(File.join(@data_root, "tasks")).load(id)
      outcome = state.dig("result", "outcome")
      rows = []
      owned_paths = []
      config = Config.load(File.join(@data_root, "config.yml"))
      pr_url = config.pull_request_url(pr) if pr
      matches = 0
      receipts = []
      run_dirs = IncidentalMetadata.children(root).sort.map { |entry| File.join(root, entry) }
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
                                record_path: record_path, transport: @transport).inspect!
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
          manager = WorktreeManager.new(root: config.worktree_root, record_path: record_path, transport: @transport)
          details, overrides = {}, {}
          inventory = manager.inspect!(head_overrides: overrides) do |recorded|
            owned_paths.concat(recorded.fetch("entries").map { |entry| entry.fetch("path") })
            recorded.fetch("entries").each do |entry|
              next unless entry["access"] == "write"
              selected = pr_url && matches_repository?(entry, pr_url)
              matches += 1 if selected
              detail = cleanup_detail(run_dir, entry, recorded, selected ? pr_url : nil)
              if detail && detail["schema"] == EXTERNAL_SCHEMA
                receipts << { "path" => external_receipt_path(run_dir, entry), "receipt" => detail }
              end
              details[entry.fetch("name")] = detail
              overrides[entry.fetch("name")] = detail["commit_sha"] if detail && detail["commit_sha"].to_s.match?(SHA)
            end
          end
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
              dirty = !IncidentalMetadata.git_status(path, ignored: true) { |*args| git(path, *args) }.empty?
              blockers << "worktree contains changes" if dirty
            end
            if entry["access"] == "write"
              detail = details[name]
              blockers.concat(publication_blockers(entry, detail))
            end
            rows << { "attempt" => inventory.fetch("attempt"), "repository" => name,
                      "path" => path, "state" => entry.fetch("state"), "blockers" => blockers }
          end
        rescue Error, JSON::ParserError, KeyError, TypeError, SystemCallError => e
          rows << { "path" => run_dir, "blockers" => [e.message] }
        end
      end
      if pr_url && matches != 1
        rows << { "path" => root, "blockers" => ["PR must match exactly one owned writable repository/attempt (matched #{matches})"] }
      end
      # A task directory may contain only the exact active paths in the
      # ownership records. Unknown files cannot be treated as disposable.
      visible = Config.load(File.join(@data_root, "config.yml")).worktree_root
      begin
        retired = TaskReset.new(data_root: @data_root, transport: @transport).retired_paths(id)
        foreign = WorktreeManager.foreign_task_paths(root: visible, task_id: id, paths: owned_paths + retired)
        rows << { "path" => File.join(visible, id), "blockers" => ["foreign task path entries: #{foreign.join(', ')}"] } unless foreign.empty?
      rescue InvalidState => error
        rows << { "path" => File.join(visible, id), "blockers" => [error.message] }
      end
      { "task_id" => id, "dry_run" => true, "attempts" => rows, "external_deliveries" => receipts,
        "blocked" => rows.any? { |row| !row.fetch("blockers").empty? } }
    end

    # Publishes verified external receipts only after task-wide preflight, then
    # reuses serialized non-forced removal. Changed/unavailable evidence raises;
    # receipts and existing partial-removal markers survive an interrupted retry.
    def remove(id, pr: nil, reservation_lock: nil)
      unless reservation_lock
        return ReservationLock.synchronize(@data_root) { |lock| remove(id, pr: pr, reservation_lock: lock) }
      end
      ReservationLock.synchronize(@data_root, held: reservation_lock) { nil }
      TaskReset.new(data_root: @data_root, transport: @transport).assert_admission!(id)
      identity = evidence_identity(id)
      inventory = preflight(id, pr: pr)
      assert_clear!(inventory)
      raise InvalidState, "cleanup: evidence changed before receipt publication" unless identity == evidence_identity(id)
      inventory.fetch("external_deliveries").each { |item| publish_receipt!(item.fetch("path"), item.fetch("receipt")) }
      raise InvalidState, "cleanup: evidence changed before receipt publication" unless identity == evidence_identity(id)
      identity = evidence_identity(id, receipts: true)
      recheck = proc do
        TaskReset.new(data_root: @data_root, transport: @transport).assert_admission!(id)
        assert_clear!(preflight(id))
        raise InvalidState, "cleanup: evidence changed before removal" unless identity == evidence_identity(id, receipts: true)
      end
      recheck.call
      root = File.join("#{@data_root}-runs", id)
      IncidentalMetadata.children(root).sort.each do |attempt|
        run_dir = File.join(root, attempt)
        record_path = File.join(run_dir, "worktrees.json")
        manager = WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root,
                                      record_path: record_path, transport: @transport)
        record = JSON.parse(File.binread(record_path))
        overrides = record.fetch("entries").filter_map do |entry|
          next unless entry["access"] == "write"
          detail = cleanup_detail(run_dir, entry, record, nil)
          [entry.fetch("name"), detail.fetch("commit_sha")] if detail && detail["commit_sha"].to_s.match?(SHA)
        end.to_h
        record.fetch("entries").each do |entry|
          next if entry["state"] == "removed"
          recheck.call
          manager.remove_entry!(entry.fetch("name"), head_overrides: overrides, &recheck)
          @after_removal&.call(entry)
        end
      end
      preflight(id)
    end

    private

    # Raises one actionable refusal for a blocked task-wide inventory.
    def assert_clear!(inventory)
      return unless inventory.fetch("blocked")
      raise InvalidState, "cleanup: #{inventory.fetch('attempts').flat_map { |row| row.fetch('blockers') }.uniq.join('; ')}"
    end

    # Captures immutable evidence consumed by cleanup. Only normal ownership
    # state transitions are excluded. Missing/foreign evidence raises; no writes.
    def evidence_identity(id, receipts: false)
      paths = [File.join(@data_root, "config.yml"), File.join(@data_root, "tasks", "#{id}.yml"),
               File.join(@data_root, "state", "#{id}.yml")]
      root = File.join("#{@data_root}-runs", id)
      IncidentalMetadata.children(root).sort.each do |attempt|
        run = File.join(root, attempt)
        paths.concat([File.join(run, "handoff.json"), File.join(run, "worktrees.json")])
        paths.concat(Dir.glob(File.join(run, "**", "delivery.json")))
        paths.concat(Dir.glob(File.join(run, "external-delivery-*.json"))) if receipts
      end
      paths.to_h do |path|
        next [path, nil] if path == File.join(@data_root, "config.yml") && !File.exist?(path) && !File.symlink?(path)
        raise InvalidState, "cleanup: missing/foreign evidence #{path}" unless File.file?(path) && !File.symlink?(path)
        bytes = File.binread(path)
        bytes = JSON.generate(immutable_inventory(JSON.parse(bytes))) if File.basename(path) == "worktrees.json"
        [path, Digest::SHA256.hexdigest(bytes)]
      end
    end

    # Compares the PR name with recorded remote authority; unsupported remotes
    # cannot match. Aliases never supply authority or ownership.
    def matches_repository?(entry, url)
      repository = GitHubDeliveryProvider.repository!(entry.fetch("remote_url"))
      url.start_with?("https://github.com/#{repository}/pull/")
    rescue InvalidState
      false
    end

    # Returns a private per-repository receipt path, refusing unsafe record keys.
    def external_receipt_path(run_dir, entry)
      name = entry.fetch("name")
      raise InvalidState, "cleanup: unsafe repository key" unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      File.join(run_dir, "external-delivery-#{name}.json")
    end

    # Returns managed delivery or freshly verified external evidence. Existing
    # receipts must exactly match their current task, attempt, native identities
    # and provider result; conflicts and unavailable evidence raise before removal.
    def cleanup_detail(run_dir, entry, inventory, url)
      managed = delivery_detail(run_dir, entry.fetch("name"), inventory)
      path = external_receipt_path(run_dir, entry)
      receipt_present = File.exist?(path) || File.symlink?(path)
      existing = if receipt_present
                   raise InvalidState, "cleanup: foreign external-delivery receipt" unless File.file?(path) && !File.symlink?(path)
                   JSON.parse(File.binread(path))
                 end
      return managed unless url || receipt_present
      if receipt_present && !(existing.is_a?(Hash) && existing["pr"].is_a?(Hash) && existing.dig("pr", "url").is_a?(String))
        raise InvalidState, "cleanup: malformed external-delivery receipt"
      end
      url ||= existing.fetch("pr").fetch("url")
      raise InvalidState, "cleanup: PR repository does not match recorded authority" unless matches_repository?(entry, url)
      integration = @provider.integration(entry.fetch("remote_url"), url)
      unless integration.is_a?(Hash) && integration["merged"] == true && integration["head"].to_s.match?(SHA) &&
             integration["base"] == entry["source_branch"] && integration["merge_commit_sha"].to_s.match?(SHA)
        raise InvalidState, "cleanup: PR not verifiably merged into authorized target"
      end
      detail = { "schema" => EXTERNAL_SCHEMA, "stage" => "external_pr", "task_id" => entry.fetch("task_id"),
        "attempt" => entry.fetch("attempt"), "repository" => entry.fetch("name"), "workspace" => entry.fetch("path"),
        "parent" => entry.fetch("parent"), "remote_url" => entry.fetch("remote_url"), "branch" => entry.fetch("branch"),
        "base_sha" => entry.fetch("base_sha"), "commit_sha" => integration.fetch("head"),
        "merge_commit_sha" => integration.fetch("merge_commit_sha"),
        "pr" => { "url" => url, "head" => integration.fetch("head"), "base" => integration.fetch("base") } }
      raise InvalidState, "cleanup: conflicting external-delivery receipt" if existing && existing != detail
      raise InvalidState, "cleanup: external delivery requires an existing owned worktree" if !existing && entry["state"] != "ready"
      if managed && (managed["commit_sha"] != detail["commit_sha"] || managed.dig("pr", "url") != url ||
                     !publication_blockers(entry, managed).empty?)
        raise InvalidState, "cleanup: conflicting existing delivery evidence"
      end
      detail
    end

    # Atomically installs a small receipt without replacing prior evidence.
    # Write/fsync/link failures raise before removal; a published receipt survives.
    def publish_receipt!(path, detail)
      if File.exist?(path) || File.symlink?(path)
        raise InvalidState, "cleanup: conflicting external-delivery receipt" unless
          File.file?(path) && !File.symlink?(path) && JSON.parse(File.binread(path)) == detail
        File.open(File.dirname(path)) { |directory| directory.fsync }
        return
      end
      Tempfile.create([".external-delivery-", ".json"], File.dirname(path)) do |temporary|
        temporary.write(JSON.pretty_generate(detail) + "\n")
        temporary.flush
        temporary.fsync
        File.link(temporary.path, path)
      end
      File.open(File.dirname(path)) { |directory| directory.fsync }
    rescue SystemCallError, IOError => error
      raise InvalidState, "cleanup: external-delivery receipt write failed: #{error.message}"
    end

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
      return nil unless File.exist?(path) || File.symlink?(path)
      raise InvalidState, "cleanup: foreign delivery evidence" unless File.file?(path) && !File.symlink?(path)
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
      verified_schema = (detail["schema"] == DeliveryManager::SCHEMA && detail["stage"] == "draft_pr") ||
                        (detail["schema"] == EXTERNAL_SCHEMA && detail["stage"] == "external_pr")
      unless verified_schema &&
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
             integration["base"] == entry["source_branch"] && integration["merge_commit_sha"].to_s.match?(SHA) &&
             (detail["schema"] != EXTERNAL_SCHEMA || detail["merge_commit_sha"] == integration["merge_commit_sha"])
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
      stdout, stderr, status = @transport.call(["git", *args], cwd: path)
      raise RepositoryError, "cleanup: git #{args.first} failed: #{stderr.strip}" unless status.success?
      args.include?("-z") ? stdout : stdout.strip
    end

    def system_git(path, *args)
      @transport.call(["git", *args], cwd: path).success?
    end
  end

  class CleanupLiveness
    # Returns clear/active/unknown from terminal process and open-file checks.
    # Read-only interrupted reports may be reviewed without implementation
    # delivery; writer interruption retains its existing refusal. Tool failures
    # return unknown and never authorize removal.
    def check(report, inventory)
      terminal = report["status"] == "exited" ||
        (report["writable_repositories"] == [] && report["status"] == "interrupted")
      return :unknown unless terminal && report["ended_at"] && report["child_pid"].is_a?(Integer)
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
