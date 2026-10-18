# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "open3"
require "rbconfig"
require "tmpdir"

module AgentCodingTool
  # Execution evidence is deliberately separate from canonical lifecycle state.
  class Launcher
    SCHEMA = "agent-coding-tool-run/v1"
    TERMINAL = %w[exited invalid_final interrupted child_start_failed preflight_failed preflight_abandoned].freeze
    REASONING = %w[minimal low medium high xhigh].freeze

    def initialize(coordinator:, data_root:, source_root:, out: $stdout, err: $stderr,
                   codex: "codex", spawner: Process.method(:spawn))
      @coordinator, @data_root, @source_root = coordinator, File.realpath(data_root), File.realpath(source_root)
      @out, @err, @codex, @spawner = out, err, codex, spawner
      @run_root = "#{@data_root}-runs"
    end

    def launch(id, model: nil, reasoning: nil, allow_write_collision: false)
      raise InvalidTask, "launch: unsafe task ID" unless id&.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      @manual_conflicts = []
      safe_root!
      external_activity.with_lock do |lock|
        run_locked(id, model, reasoning, lock, allow_write_collision)
      end
    rescue Psych::Exception, KeyError, TypeError, ArgumentError => e
      raise InvalidTask, "launch: malformed task/preparation: #{e.message}"
    rescue SystemCallError => e
      raise Error, "launch: #{e.class}: #{e.message}"
    end

    # Rechecks overlapping reservations under the caller's shared reservation lock.
    # Inputs identify a host run; returns verified sibling identities, or raises
    # InvalidState for unknown workers, incompatible pins or ambiguous ownership.
    # This grants neither publication authority nor current integration approval.
    def verify_delivery_overlap!(id, run_dir)
      safe_root!
      external_activity.assert_clear!(id)
      task = TaskStore.new(File.join(@data_root, "tasks")).load(id)
      store = StateStore.new(File.join(@data_root, "state"))
      state = store.load(id)
      bases = task.fetch("repositories").filter_map { |name, spec|
        state.fetch("snapshot").fetch(name) if spec.fetch("access") == "write" }
      @report = JSON.parse(File.binread(File.join(run_dir, "handoff.json")))
      if @report.dig("collision_authorization", "unverified_manual_conflicts") ||
         state.dig("write_collision_override", "launch", "unverified_manual_conflicts")
        raise InvalidState, "delivery: unverified manual overlap at launch; managed delivery disabled for this attempt; preserve the patch for separate operator review"
      end
      @collisions = TaskStore.new(File.join(@data_root, "tasks")).all.filter_map do |other|
        next if other.fetch("id") == id
        other_state = store.load(other.fetch("id"))
        next unless other_state["snapshot"] && (other_state["started_at"] ||
          other_state.dig("result", "outcome") == "candidate_complete")
        shared = shared_writers(other, other_state.fetch("snapshot"), bases)
        next if shared.empty?
        { "task_id" => other.fetch("id"), "status" => other_state["started_at"] ? "IN_FLIGHT" : "CANDIDATE",
          "repositories" => shared }
      end
      verified = reject_unknown_reservations!(id, bases, allow_write_collision: true)
      return verified if verified.empty?

      own = verify_conflicting_worker!(task, state,
        @report.merge("_report_path" => File.join(run_dir, "handoff.json")),
        task.fetch("repositories").filter_map { |name, spec| name if spec.fetch("access") == "write" }, bases)
      rows = [own, *verified]
      reports.each do |report|
        next unless rows.any? { |row| row["task_id"] == report["task_id"] }
        report.dig("collision_authorization", "verified_conflicts")&.each do |previous|
          current = rows.find { |row| row["task_id"] == previous["task_id"] }
          if current && current.values_at("task_id", "attempt", "invocation_id") != previous.values_at("task_id", "attempt", "invocation_id")
            raise InvalidState, "delivery: sibling invocation changed since verified launch"
          end
        end
      end
      rows.each do |row|
        paths = row.fetch("all_worktrees")
        others = rows.reject { |other| other.equal?(row) }.flat_map { |other| other.fetch("all_worktrees") }
        if paths.any? { |path| others.any? { |other| path == other || path.start_with?("#{other}/") || other.start_with?("#{path}/") } }
          raise InvalidState, "delivery: overlapping execution roots"
        end
      end
      rows.map { |row| row.slice("task_id", "attempt", "invocation_id", "workspaces", "authorities") }
    rescue KeyError, TypeError, JSON::ParserError => e
      raise InvalidState, "delivery: incomplete overlap evidence: #{e.class}"
    end

    private

    # Uses configured stores independently of lightweight delivery coordinators.
    # Initialization is read-only; no-observation checks make no Git/process calls.
    def external_activity
      @external_activity ||= @coordinator.respond_to?(:external_activity) ? @coordinator.external_activity :
        ExternalActivity.new(data_root: @data_root,
          task_store: TaskStore.new(File.join(@data_root, "tasks")),
          state_store: StateStore.new(File.join(@data_root, "state")),
          repo_inspector: RepoInspector.new(Config.load(File.join(@data_root, "config.yml"))))
    end

    def safe_root!
      # Refuse symlinked evidence paths, including ancestors; never repair them.
      current = @run_root
      loop do
        raise InvalidState, "launch: symlinked evidence path: #{current}" if File.symlink?(current)
        break if current == File.dirname(current)
        current = File.dirname(current)
      end
      if @run_root == @source_root || @run_root.start_with?("#{@source_root}/")
        raise InvalidState, "launch: evidence must live outside public source"
      end
      FileUtils.mkdir_p(@run_root, mode: 0o700)
      raise InvalidState, "launch: evidence root must be private and owned by the operator" unless
        File.stat(@run_root).uid == Process.uid && (File.stat(@run_root).mode & 0o077).zero?
    end

    # Runs one task under the reservation lock and optionally delivers its exact
    # host-validated result. Returns worker status; preflight errors retain evidence.
    def run_locked(id, model, reasoning, lock, allow_write_collision)
      task = TaskStore.new(File.join(@data_root, "tasks")).load(id)
      validate_task!(id, task)
      state_store = StateStore.new(File.join(@data_root, "state"))
      state = state_store.load(id)
      raise InvalidState, "#{id}: malformed state" unless state.is_a?(Hash)
      prior_runs!(id, state)
      external_activity.assert_clear!(id)
      preflight_codex!(model, reasoning)
      raise InvalidState, "#{id}: already in flight; operator judgment required" if state["started_at"]
      raise InvalidState, "#{id}: recorded outcome; explicit prepare --retry required" if state["result"]
      if state["snapshot"]
        validate_preparation!(task, state)
      else
        raise InvalidState, "#{id}: partial preparation; operator judgment required" unless state.empty? || state == { "id" => id }
        state = @coordinator.prepare(id).fetch("state")
      end
      validate_preparation!(task, state)
      checked_status!(id, allow_write_collision: allow_write_collision)
      prompt = File.binread(state.fetch("prompt_path"))
      raise InvalidState, "#{id}: generated prompt changed; explicitly prepare again" unless prompt == @coordinator.launch_prompt(id).b
      names = task.fetch("repositories").filter_map { |key, spec| key if spec.fetch("access") == "write" }
      bases = names.map { |name| state.fetch("snapshot").fetch(name) }
      validate_authorities!(task, state)
      verified_conflicts = reject_unknown_reservations!(id, bases,
                                                         allow_write_collision: allow_write_collision, allow_manual_overlap: true)
      manual_conflicts = @manual_conflicts
      config = Config.load(File.join(@data_root, "config.yml"))
      root = WorktreeManager.canonical_system_path(config.worktree_root)
      [@source_root, @data_root, @run_root].map { |path| WorktreeManager.canonical_system_path(path) }.each do |protected|
        if root == protected || root.start_with?("#{protected}/") || protected.start_with?("#{root}/")
          raise InvalidState, "launch: worktree root overlaps source or private task data"
        end
      end
      task_root = File.join(@run_root, id)
      raise InvalidState, "#{id}: symlinked task evidence" if File.symlink?(task_root)
      FileUtils.mkdir_p(task_root, mode: 0o700)
      attempt = Dir.children(task_root).length + 1
      run_dir = File.join(task_root, "#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(6)}")
      Dir.mkdir(run_dir, 0o700)
      @report_path = File.join(run_dir, "handoff.json")
      invocation_id = SecureRandom.uuid
      manager = WorktreeManager.new(root: config.worktree_root, record_path: File.join(run_dir, "worktrees.json"),
                                    attempt_paths: true, invocation_id: invocation_id,
                                    inventory_written: -> { @report["worktree_creation"] = "inventory_persisted"; save_report })
      @report = {
        "schema_version" => SCHEMA, "task_id" => id, "attempt" => attempt,
        "invocation_id" => invocation_id, "host_pid" => Process.pid,
        "created_at" => Time.now.utc.iso8601, "prepared_at" => state.fetch("prepared_at"),
        "preparation" => state.fetch("snapshot"), "preparation_state" => state,
        "host_identity" => RetryLiveness.host_identity, "worktree_layout" => "attempt",
        "worktree_creation" => "not_started", "workspace" => nil,
        "worktrees_path" => File.join(run_dir, "worktrees.json"), "worktrees" => nil,
        "writable_repository" => names.first,
        "writable_authority" => bases.first.slice("remote_url", "branch", "pushed_sha"),
        "writable_repositories" => names,
        "writable_authorities" => names.to_h { |name| [name, state.fetch("snapshot").fetch(name).slice("remote_url", "branch", "pushed_sha")] },
        "status" => "preflight", "session_id" => nil, "session_transcript_path" => nil,
        "jsonl_path" => File.join(run_dir, "stdout.jsonl"),
        "stderr_path" => File.join(run_dir, "stderr.txt"),
        "final_path" => File.join(run_dir, "final.txt"),
        "prompt_path" => File.join(run_dir, "prompt.txt"), "stdin_path" => File.join(run_dir, "stdin.txt"),
        "prompt_sha256" => Digest::SHA256.hexdigest(prompt), "prompt_bytes" => prompt.bytesize,
        "codex" => @codex, "model" => model, "reasoning" => reasoning,
        "codex_executable_sha256" => @codex_digest, "exec_help_sha256" => @help_digest,
        "worker_recommendation" => task["worker_recommendation"],
        "freshness_source" => "host git ls-remote; CLI has no connected GitHub integration"
      }
      save_report
      begin
        raise InvalidState, "launch: task/preparation changed before creation" unless
          state_store.load(id) == state && TaskStore.new(File.join(@data_root, "tasks")).load(id) == task
        File.binwrite(@report.fetch("prompt_path"), prompt)
        inventory = manager.create(task_id: id, attempt: attempt, task: task, snapshot: state.fetch("snapshot"))
        @report["worktrees"] = inventory
        workspaces = inventory.fetch("entries").select { |entry| entry.fetch("access") == "write" }.to_h { |entry| [entry.fetch("name"), entry.fetch("path")] }
        workspace = workspaces.fetch(names.first)
        @report["workspace"] = workspace
        @report["workspaces"] = workspaces
        save_report
        names.each { |name| verify_checkout!(workspaces.fetch(name), state.fetch("snapshot").fetch(name)) }
        heads = checked_status!(id, allow_write_collision: allow_write_collision)
        @report["launch_checked_at"] = Time.now.utc.iso8601
        @report["launch_heads"] = heads
        changed_write!(task, state, @report.fetch("launch_heads"))
        manager.inspect!
        current_conflicts = reject_unknown_reservations!(id, bases,
                                                         allow_write_collision: allow_write_collision, allow_manual_overlap: true)
        identity = ->(rows) { rows.map { |row| row.values_at("task_id", "attempt", "invocation_id", "all_worktrees") } }
        unless identity.call(current_conflicts) == identity.call(verified_conflicts) && @manual_conflicts == manual_conflicts
          raise InvalidState, "launch: parallel worker set changed during worktree setup; inspect and retry"
        end
        verified_conflicts = current_conflicts
        @parallel_roots = verified_conflicts.flat_map { |row| row.fetch("all_worktrees") } +
          AttemptRecovery.new(data_root: @data_root).protected_paths(id, before_attempt: attempt)
        sandbox_probe!(inventory, workspace, run_dir)
        heads = checked_status!(id, allow_write_collision: allow_write_collision)
        changed_write!(task, state, heads)
        current_conflicts = reject_unknown_reservations!(id, bases,
                                                         allow_write_collision: allow_write_collision, allow_manual_overlap: true)
        unless identity.call(current_conflicts) == identity.call(verified_conflicts) && @manual_conflicts == manual_conflicts
          raise InvalidState, "launch: parallel worker set changed during sandbox probe; inspect and retry"
        end
        verified_conflicts = current_conflicts
        @report["launch_checked_at"] = Time.now.utc.iso8601
        @report["launch_heads"] = heads
        envelope = execution_envelope(workspaces, @report.fetch("launch_heads"))
        File.binwrite(@report.fetch("stdin_path"), prompt + envelope)
        command = codex_command(workspace, model, reasoning, extra_roots: workspaces.values.drop(1))
        @report["argv"] = command
        if @collisions.any? || manual_conflicts.any?
          @report["collision_authorization"] = {
            "task_id" => id, "attempt" => attempt, "invocation_id" => @report.fetch("invocation_id"),
            "prepared_at" => state.fetch("prepared_at"), "conflicts" => @collisions,
            "authorities" => @report.fetch("writable_authorities"),
            "verified_conflicts" => verified_conflicts
          }
          if manual_conflicts.any?
            @report["collision_authorization"]["unverified_manual_conflicts"] = manual_conflicts
            @err.puts "PARALLEL DEVELOPMENT: operator authorized; new worker isolation verified by worktree/sandbox checks; external worker isolation and activity are unverified; managed delivery disabled."
          end
        end
        AttemptRecovery.new(data_root: @data_root).retry_ready!(id, current_run: run_dir) if attempt > 1
        raise InvalidState, "launch: task/preparation changed before reservation" unless
          state_store.load(id) == state && TaskStore.new(File.join(@data_root, "tasks")).load(id) == task &&
          File.binread(state.fetch("prompt_path")) == prompt && @coordinator.launch_prompt(id).b == prompt
        validate_authorities!(task, state)
        manager.inspect!
        final_conflicts = reject_unknown_reservations!(id, bases,
          allow_write_collision: allow_write_collision, allow_manual_overlap: true)
        unless identity.call(final_conflicts) == identity.call(verified_conflicts) && @manual_conflicts == manual_conflicts
          raise InvalidState, "launch: parallel worker set changed before reservation; inspect and retry"
        end
        @report["status"] = "reserving"
        save_report
        @coordinator.start(id, allow_write_collision: allow_write_collision,
                           expected_collisions: @collisions,
                           launch_authorization: @report["collision_authorization"])
        @report["execution_state"] = state_store.load(id)
        @report["status"] = "reserved"
        save_report
        result = execute(command, lock)
        if result == 0 && @report["status"] == "exited"
          delivery = DeliveryManager.new(data_root: @data_root, coordinator: @coordinator)
          if manual_conflicts.any?
            @err.puts "DELIVERY DEFERRED: unverified manual overlap; managed delivery disabled for this attempt; preserve candidate for operator review"
          elsif delivery.configured?(id) && !lock.flock(File::LOCK_EX | File::LOCK_NB)
            @err.puts "DELIVERY DEFERRED: another launch holds the reservation lock; review separately"
          elsif delivery.configured?(id)
            begin
              delivered = delivery.deliver(id, run_dir: run_dir, reservation_lock: lock)
              urls = delivered["prs"] ? delivered.fetch("prs").values.map { |pr| pr.fetch("url") } :
                                          [delivered.fetch("pr").fetch("url")]
              @out.puts "Draft PR#{delivered["prs"] ? "s" : ""}: #{urls.join(', ')} (CANDIDATE)"
            rescue StandardError => e
              @err.puts "DELIVERY BLOCKED: #{e.class}: #{e.message}; implementation and evidence retained"
              return 2
            end
          end
        end
        result
      rescue StandardError => e
        @report["status"] = @report["status"] == "preflight" ? "preflight_failed" : "judgment_required"
        @report["error"] = "#{e.class}: #{e.message}"
        save_report
        raise
      ensure
        @err.puts "Run evidence: #{@report_path} (#{@report['status']}); ACT lifecycle requires human review."
      end
    end

    def validate_task!(id, task)
      raise InvalidTask, "#{id}: task identity mismatch" unless task.fetch("id") == id
      writes = task.fetch("repositories").count { |_name, spec| spec.fetch("access") == "write" }
      raise InvalidTask, "#{id}: launch requires a writable repository" unless writes.positive?
      %w[depends_on constraints acceptance].each do |key|
        raise InvalidTask, "#{id}: #{key} must contain strings" unless task.fetch(key, []).all? { |value| value.is_a?(String) }
      end
      task.fetch("repositories").each_value do |spec|
        %w[path remote branch].each do |field|
          raise InvalidTask, "#{id}: invalid repository #{field}" if spec.key?(field) && (!spec[field].is_a?(String) || spec[field].empty?)
        end
        branch = spec.fetch("branch", Config.load(File.join(@data_root, "config.yml")).default_branch)
        raise InvalidTask, "#{id}: unsupported branch (requires main)" unless branch == "main"
      end
    end

    def validate_preparation!(task, state)
      snapshot = state["snapshot"]
      unless snapshot.is_a?(Hash) && snapshot.keys.sort == task.fetch("repositories").keys.sort &&
             state["id"] == task.fetch("id") && state["prepared_at"].is_a?(String) && state["prompt_path"].is_a?(String)
        raise InvalidState, "launch: incompatible preparation"
      end
      begin
        Time.iso8601(state.fetch("prepared_at"))
      rescue ArgumentError
        raise InvalidState, "launch: incompatible preparation timestamp"
      end
      snapshot.each_value do |repo|
        unless repo.is_a?(Hash) && %w[remote_url branch path].all? { |key| repo[key].is_a?(String) && !repo[key].empty? } &&
               repo["pushed_sha"].is_a?(String) && repo["pushed_sha"].match?(/\A[0-9a-f]{40}\z/)
          raise InvalidState, "launch: missing repository identity/base"
        end
        # V1's authoritative branch contract is main. URL credentials cannot enter evidence.
        raise InvalidState, "launch: unsupported branch (requires main)" unless repo["branch"] == "main"
        remote = repo.fetch("remote_url")
        unless remote.match?(/\Agit@github\.com:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\.git\z/) ||
               remote.match?(/\Ahttps:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?\z/) ||
               remote.start_with?("/")
          raise InvalidState, "launch: unsupported or ambiguous repository remote"
        end
      end
      path = state.fetch("prompt_path")
      expected = File.join(@data_root, "state", "prompts")
      unless File.file?(path) && !File.symlink?(path) && File.realpath(path).start_with?("#{File.realpath(expected)}/")
        raise InvalidState, "launch: missing/foreign prompt artifact"
      end
    end

    def validate_authorities!(task, state)
      config = Config.load(File.join(@data_root, "config.yml"))
      inspector = RepoInspector.new(config)
      task.fetch("repositories").each do |name, spec|
        old = state.fetch("snapshot").fetch(name)
        unless inspector.repository_authority(name, spec) == [old.fetch("remote_url"), old.fetch("branch")]
          raise InvalidState, "#{name}: repository authority changed since preparation"
        end
      end
      writers = state.fetch("snapshot").select { |name, _repo| task.fetch("repositories").fetch(name).fetch("access") == "write" }.values
      readers = state.fetch("snapshot").reject { |name, _repo| task.fetch("repositories").fetch(name).fetch("access") == "write" }.values
      if readers.any? { |repo| writers.any? { |writer| repo.values_at("remote_url", "branch") == writer.values_at("remote_url", "branch") } }
        raise InvalidState, "launch: ambiguous read/write repository aliases"
      end
      if writers.map { |repo| repo.values_at("remote_url", "branch") }.uniq.length != writers.length
        raise InvalidState, "launch: ambiguous writable repository aliases"
      end
    end

    def checked_status!(id, allow_write_collision: false)
      external_activity.assert_clear!(id)
      heads = nil
      status = @coordinator.statuses([id], strict_freshness: true) { |observed| heads = observed }.first
      raise InvalidState, "#{id}: launch blocked: #{status['status']} #{status['reason']}" unless status.fetch("status") == "PREPARED"
      @collisions = status.fetch("write_collisions", [])
      raise InvalidState, "#{id}: unresolved write collision" if @collisions.any? && !allow_write_collision
      status.fetch("state").fetch("snapshot").to_h do |name, repo|
        [name, repo.slice("remote_url", "branch").merge("pushed_sha" => heads.fetch(repo.values_at("remote_url", "branch")))]
      end
    end

    # Reads strict managed evidence, recognizing only the validated private
    # external namespace. Unknown/foreign/malformed managed entries still refuse.
    def reports
      entries = Dir.children(@run_root).reject do |entry|
        entry == "launch.lock" ||
          (entry == ".DS_Store" && File.lstat(File.join(@run_root, entry)).file?)
      end
      if entries.include?(ExternalActivity::NAMESPACE)
        external_activity.records
        entries.delete(ExternalActivity::NAMESPACE)
      end
      if entries.include?("checkpoints")
        checkpoint_root = File.join(@run_root, "checkpoints")
        unless File.directory?(checkpoint_root) && !File.symlink?(checkpoint_root) &&
               File.stat(checkpoint_root).uid == Process.uid && (File.stat(checkpoint_root).mode & 0o077).zero?
          raise InvalidState, "launch: foreign checkpoint evidence; operator judgment required"
        end
        entries.delete("checkpoints")
      end
      paths = entries.flat_map do |task_id|
        task_path = File.join(@run_root, task_id)
        unless task_id != ".DS_Store" && File.directory?(task_path) && !File.symlink?(task_path)
          raise InvalidState, "launch: foreign evidence entry; operator judgment required"
        end
        Dir.children(task_path).map do |entry|
          run_path = File.join(task_path, entry)
          path = File.join(run_path, "handoff.json")
          unless File.directory?(run_path) && !File.symlink?(run_path) && File.file?(path)
            raise InvalidState, "launch: partial/foreign run artifacts; operator judgment required"
          end
          path
        end
      end
      paths.map do |path|
        raise InvalidState, "launch: foreign/symlinked evidence" if File.symlink?(path)
        report = JSON.parse(File.read(path))
        unless report.is_a?(Hash) && report["schema_version"] == SCHEMA && report["task_id"].is_a?(String) &&
               report["preparation"].is_a?(Hash) && report["status"].is_a?(String)
          raise InvalidState, "launch: unknown/malformed evidence schema"
        end
        report.merge("_report_path" => path)
      end
    rescue JSON::ParserError
      raise InvalidState, "launch: partial evidence; operator judgment required"
    end

    # Refuses unknown history, unclosed failures or reused preparation before a
    # new run directory or native resource exists. Historical closeout is checked
    # against original evidence rather than the current task's snapshot.
    def prior_runs!(id, state)
      task_root = File.join(@run_root, id)
      if File.exist?(task_root)
        raise InvalidState, "#{id}: foreign/symlinked task evidence" if File.symlink?(task_root) || !File.directory?(task_root)
        Dir.children(task_root).each do |entry|
          path = File.join(task_root, entry)
          unless File.directory?(path) && !File.symlink?(path) && File.file?(File.join(path, "handoff.json"))
            raise InvalidState, "#{id}: partial/foreign run artifacts; operator judgment required"
          end
        end
      end
      AttemptRecovery.new(data_root: @data_root).retry_ready!(id)
      reports.select { |report| report["task_id"] == id }.each do |report|
        unless TERMINAL.include?(report["status"])
          raise InvalidState, "#{id}: previous run liveness unknown; operator judgment required"
        end
        if report["status"] == "preflight_failed" &&
           !File.file?(File.join(File.dirname(report.fetch("_report_path")), "closeout.json"))
          raise InvalidState, "#{id}: failed preflight requires explicit abandonment before launch"
        end
        if report["prepared_at"] == state["prepared_at"]
          raise InvalidState, "#{id}: preparation already attempted; explicit operator recovery required"
        end
      end
    end

    # Returns verified managed siblings and separately records manual reservations.
    # Launch may admit a no-run IN_FLIGHT reservation with explicit permission;
    # delivery never may. Damaged/partial managed evidence still raises InvalidState.
    def reject_unknown_reservations!(id, bases, allow_write_collision:, allow_manual_overlap: false)
      external_activity.assert_clear!(id)
      # Coordinator reports fresh IN_FLIGHT/CANDIDATE conflicts. This additional
      # pass also sees stale manual starts and orphaned host evidence. Historical
      # source movement never erases a reservation or repairs managed evidence.
      store = StateStore.new(File.join(@data_root, "state"))
      all_reports = reports
      verified = []
      @manual_conflicts = []
      TaskStore.new(File.join(@data_root, "tasks")).all.each do |other|
        other_id = other.fetch("id")
        next if other_id == id
        other_state = store.load(other_id)
        next unless other_state.is_a?(Hash) && other_state["snapshot"].is_a?(Hash)
        shared = shared_writers(other, other_state.fetch("snapshot"), bases)
        next if shared.empty?
        next unless other_state["started_at"] || other_state.dig("result", "outcome") == "candidate_complete"

        if allow_manual_overlap && allow_write_collision && other_state["started_at"] && !other_state["result"] &&
           all_reports.none? { |report| report["task_id"] == other_id } &&
           !File.exist?(File.join(@run_root, other_id)) && !File.symlink?(File.join(@run_root, other_id)) &&
           !other_state.dig("write_collision_override", "launch")
          target = store.load(id).fetch("snapshot")
          repositories = target.keys.select { |name| bases.include?(target.fetch(name)) &&
            shared.any? { |key| other_state.fetch("snapshot").fetch(key).values_at("remote_url", "branch") ==
              target.fetch(name).values_at("remote_url", "branch") } }.sort
          @manual_conflicts << {
            "task_id" => other_id, "status" => shared.all? { |name| bases.any? { |base|
              base.values_at("remote_url", "branch", "pushed_sha") == other_state.fetch("snapshot").fetch(name).values_at("remote_url", "branch", "pushed_sha") } } ? "IN_FLIGHT" : "STALE",
            "repositories" => repositories,
            "task_sha256" => Digest::SHA256.hexdigest(JSON.generate(other)),
            "state_sha256" => Digest::SHA256.hexdigest(JSON.generate(other_state))
          }
          next
        end

        if allow_write_collision && shared.any? { |name|
          previous = other_state.fetch("snapshot").fetch(name)
          bases.none? { |base| base.values_at("remote_url", "branch", "pushed_sha") ==
            previous.values_at("remote_url", "branch", "pushed_sha") }
        }
          raise InvalidState, "launch: #{other_id} has an incompatible prepared baseline; reconcile before parallel launch"
        end

        collision = @collisions.find { |row| row.fetch("task_id") == other_id }
        unless allow_write_collision && collision && %w[IN_FLIGHT CANDIDATE].include?(collision.fetch("status"))
          raise InvalidState, "launch: #{other_id} has an unresolved in-flight reservation or candidate write reservation; operator judgment required"
        end
        matching = all_reports.select { |row| row["task_id"] == other_id &&
          row["prepared_at"] == other_state["prepared_at"] && row["preparation"] == other_state["snapshot"] }
        unless matching.length == 1
          raise InvalidState, "launch: #{other_id} has no unique ACT-owned worker evidence; manual worker isolation and activity are unverified. Review its worker/worktree before retrying"
        end
        verified << verify_conflicting_worker!(other, other_state, matching.first, shared, bases)
      end
      all_reports.each do |report|
        next if TERMINAL.include?(report["status"])
        next if report["task_id"] == id && @report && report["invocation_id"] == @report["invocation_id"]
        next if verified.any? { |row| row["invocation_id"] == report["invocation_id"] }
        if report_writes_overlap?(report, bases)
          raise InvalidState, "launch: #{report['task_id']} has partial, interrupted or unknown execution evidence; inspect #{report['_report_path']} and confirm liveness before recovery"
        end
      end
      verified.sort_by { |row| row.fetch("task_id") }
    end

    def shared_writers(task, snapshot, bases)
      task.fetch("repositories").filter_map do |name, spec|
        next unless spec.fetch("access") == "write"
        repo = snapshot.fetch(name)
        name if bases.any? { |base| repo.values_at("remote_url", "branch") == base.values_at("remote_url", "branch") }
      end
    end

    def report_writes_overlap?(report, bases)
      names = report.fetch("writable_repositories", [report["writable_repository"]]).compact
      names = report.fetch("preparation").keys if names.empty?
      names.any? do |name|
        repo = report.fetch("preparation").fetch(name)
        bases.any? { |base| repo.values_at("remote_url", "branch") == base.values_at("remote_url", "branch") }
      end
    rescue KeyError, TypeError
      raise InvalidState, "launch: malformed worker write authority; inspect #{report['_report_path']}"
    end

    # Verifies a sibling's task/state/run and shared pinned authorities, returning
    # owned roots/identity. Unverified HEAD movement, sandbox or process state raises.
    def verify_conflicting_worker!(task, state, report, names, bases)
      other_id = task.fetch("id")
      path = report.fetch("_report_path")
      run_dir = File.dirname(path)
      record_path = File.join(run_dir, "worktrees.json")
      unless report["schema_version"] == SCHEMA && report["worktrees_path"] == record_path &&
             report["attempt"].is_a?(Integer) && report["attempt"].positive? &&
             report["invocation_id"].is_a?(String) && report["prepared_at"] == state["prepared_at"] &&
             report["writable_repositories"] == task.fetch("repositories").filter_map { |name, spec| name if spec.fetch("access") == "write" } &&
             report["writable_authorities"] == report.fetch("writable_repositories", []).to_h { |name|
               [name, state.fetch("snapshot").fetch(name).slice("remote_url", "branch", "pushed_sha")] }
        raise InvalidState, "launch: #{other_id} has foreign or partial task/attempt evidence at #{path}"
      end
      if (authorization = state.dig("write_collision_override", "launch"))
        unless report["collision_authorization"] == authorization &&
               authorization.values_at("task_id", "attempt", "invocation_id", "prepared_at") ==
                 report.values_at("task_id", "attempt", "invocation_id", "prepared_at")
          raise InvalidState, "launch: #{other_id} invocation differs from its verified start"
        end
      end
      names.each do |name|
        previous = state.fetch("snapshot").fetch(name)
        unless bases.any? { |base| base.values_at("remote_url", "branch", "pushed_sha") ==
          previous.values_at("remote_url", "branch", "pushed_sha") }
          raise InvalidState, "launch: #{other_id}/#{name} has an incompatible prepared baseline; reconcile before parallel launch"
        end
      end
      root = Config.load(File.join(@data_root, "config.yml")).worktree_root
      manager = WorktreeManager.new(root: root, record_path: record_path)
      # Only host-validated exact candidate commits may replace the prepared HEAD.
      overrides = DeliveryManager.new(data_root: @data_root, coordinator: @coordinator)
                                 .verified_delivery_heads(other_id, report, run_dir)
      inventory = manager.inspect!(head_overrides: overrides)
      unless report["worktrees"].is_a?(Hash) &&
             immutable_inventory(report.fetch("worktrees")) == immutable_inventory(inventory) &&
             inventory["task_id"] == other_id && inventory["attempt"] == report["attempt"] &&
             inventory.fetch("entries").map { |entry| entry.fetch("name") }.sort == task.fetch("repositories").keys.sort
        raise InvalidState, "launch: #{other_id} worktree ownership differs from private attempt evidence"
      end
      inventory.fetch("entries").each do |entry|
        previous = state.fetch("snapshot").fetch(entry.fetch("name"))
        unless entry["state"] == "ready" && entry.fetch("access") == task.fetch("repositories").fetch(entry.fetch("name")).fetch("access") &&
               previous.values_at("path", "remote_url", "branch", "pushed_sha") ==
                 entry.values_at("parent", "remote_url", "source_branch", "base_sha")
          raise InvalidState, "launch: #{other_id} worktree authority changed; inspect #{record_path}"
        end
      end
      writers = inventory.fetch("entries").select { |entry| entry.fetch("access") == "write" }
      workspaces = writers.to_h { |entry| [entry.fetch("name"), entry.fetch("path")] }
      unless report["workspaces"] == workspaces && report["workspace"] == writers.first.fetch("path") &&
             report.fetch("launch_heads").keys.sort == state.fetch("snapshot").keys.sort &&
             writers.all? { |entry|
               name = entry.fetch("name")
               report.fetch("launch_heads").fetch(name).values_at("remote_url", "branch", "pushed_sha") ==
                 state.fetch("snapshot").fetch(name).values_at("remote_url", "branch", "pushed_sha") }
        raise InvalidState, "launch: #{other_id} launch roots or pinned heads are unverified"
      end
      unless report["sandbox_probe"].is_a?(Hash) && report.dig("sandbox_probe", "checked_at")
        raise InvalidState, "launch: #{other_id} sandbox verification is unavailable"
      end
      case report.fetch("status")
      when "running"
        verify_running_process!(report)
      when "exited"
        unless CleanupLiveness.new.check(report, inventory) == :clear
          raise InvalidState, "launch: #{other_id} terminal worker liveness is uncertain; inspect before retrying"
        end
      else
        raise InvalidState, "launch: #{other_id} has #{report['status']} execution evidence; operator recovery required"
      end
      { "task_id" => other_id, "attempt" => report.fetch("attempt"),
        "invocation_id" => report.fetch("invocation_id"), "status" => report.fetch("status"),
        "workspaces" => workspaces,
        "all_worktrees" => inventory.fetch("entries").map { |entry| entry.fetch("path") },
        "authorities" => names.to_h { |name|
          [name, state.fetch("snapshot").fetch(name).slice("remote_url", "branch", "pushed_sha")] } }
    rescue KeyError, TypeError, NoMethodError, JSON::ParserError => e
      raise InvalidState, "launch: #{other_id} partial or malformed ownership: #{e.message}; inspect #{path}"
    end

    def immutable_inventory(inventory)
      inventory.reject { |key, _| key == "entries" }.merge(
        "entries" => inventory.fetch("entries").map { |entry| entry.reject { |key, _| key == "state" } })
    end

    def verify_running_process!(report)
      child, host = report.values_at("child_pid", "host_pid")
      unless child.is_a?(Integer) && child.positive? && host.is_a?(Integer) && host.positive? &&
             report["child_started_at"] && report["sandbox_probe"].is_a?(Hash) &&
             report["heartbeat_child_pid"] == child && report["heartbeat_at"].is_a?(String)
        raise InvalidState, "launch: #{report['task_id']} worker ownership or sandbox probe is missing"
      end
      age = Time.now.utc - Time.iso8601(report.fetch("heartbeat_at"))
      unless age >= 0 && age <= 3
        raise InvalidState, "launch: #{report['task_id']} host heartbeat is stale; inspect before retrying"
      end
      Process.kill(0, host)
      Process.kill(0, -child)
      unless Process.getpgid(child) == child
        raise InvalidState, "launch: #{report['task_id']} worker process group changed; inspect before retrying"
      end
      if RbConfig::CONFIG.fetch("host_os").match?(/darwin/)
        output, _error, status = Open3.capture3("ps", "-o", "ppid=", "-o", "pgid=", "-p", child.to_s)
        unless status.success? && output.split.map(&:to_i) == [host, child]
          raise InvalidState, "launch: #{report['task_id']} worker process parent/group changed; inspect before retrying"
        end
      end
    rescue ArgumentError, Errno::ESRCH, Errno::EPERM, SystemCallError
      raise InvalidState, "launch: #{report['task_id']} worker liveness is unknown; inspect before retrying"
    end

    def preflight_codex!(model, reasoning)
      raise InvalidTask, "launch: invalid explicit model" if model && !model.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/)
      raise InvalidTask, "launch: unsupported reasoning" if reasoning && !REASONING.include?(reasoning)
      candidate = if @codex.include?(File::SEPARATOR)
                    @codex
                  else
                    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |directory| File.join(directory, @codex) }
                       .find { |path| File.file?(path) && File.executable?(path) }
                  end
      raise Errno::ENOENT unless candidate && File.file?(candidate) && File.executable?(candidate)
      @codex = File.realpath(candidate)
      @codex_digest = Digest::SHA256.file(@codex).hexdigest
      version, _version_error, version_status = Open3.capture3(worker_env, @codex, "--version", unsetenv_others: true)
      raise Error, "launch: unsupported Codex sandbox version (requires 0.162.1)" unless
        version_status.success? && version.strip.match?(/\Acodex(?:-cli)? 0\.162\.1\z/)
      help, stderr, status = Open3.capture3(worker_env, @codex, "exec", "--help", unsetenv_others: true)
      unless status.success? && %w[--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model].all? { |flag| help.include?(flag) }
        raise Error, "launch: installed Codex lacks required safe exec flags"
      end
      @help_digest = Digest::SHA256.hexdigest(help)
      login_text, _err, login_help = Open3.capture3(worker_env, @codex, "login", "--help", unsetenv_others: true)
      raise Error, "launch: unsupported Codex login command" unless login_help.success? && login_text.include?("status")
      stdout, stderr, status = Open3.capture3(worker_env, @codex, "login", "status", unsetenv_others: true)
      unless status.success? && (stdout + stderr).lines.any? { |line| line.strip == "Logged in using ChatGPT" }
        raise Error, "launch: locally authenticated ChatGPT account required; run codex login (API-key login unsupported)"
      end
    rescue Errno::ENOENT
      raise Error, "launch: Codex CLI missing; install/authenticate locally before launch"
    end

    def worker_env
      %w[HOME PATH TMPDIR CODEX_HOME LANG LC_ALL].to_h { |key| [key, ENV[key]] }.compact
    end

    def codex_command(workspace, model, reasoning, extra_roots: [])
      command = [@codex, "exec", "--ignore-user-config", "--ignore-rules", "--sandbox", "workspace-write",
                 "-c", "approval_policy=never", "-c", 'model_provider="openai"', "-c", 'forced_login_method="chatgpt"',
                 "-c", "sandbox_workspace_write.network_access=false", "-c", "sandbox_workspace_write.writable_roots=#{JSON.generate(extra_roots)}",
                 "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true", "-c", "sandbox_workspace_write.exclude_slash_tmp=true",
                 "-c", "features.multi_agent=false", "--json", "--output-last-message", @report.fetch("final_path")]
      command += ["--model", model] if model
      command += ["-c", "model_reasoning_effort=#{reasoning}"] if reasoning
      command << "-"
    end

    def execution_envelope(workspaces, heads)
      notice = @manual_conflicts&.any? ? "Parallel development is operator-authorized. Older external isolation/activity are unverified; ACT cannot confine an external process. Managed delivery is disabled for this attempt.\n" : ""
      "\n\n--- ACT LOCAL CLI EXECUTION ENVELOPE ---\n" \
        "The exact ACT prompt above retains task authority. Writable worktrees: #{JSON.generate(workspaces)}. Original paths are observations, not writable roots.\n" \
        "Verified worktrees: #{JSON.generate(@report.fetch('worktrees').fetch('entries').map { |entry| entry.slice('name', 'path', 'access', 'branch', 'base_sha', 'remote_url') })}. Read-only worktrees and shared Git administration are outside the writable sandbox.\n" \
        "Concurrent ACT worktrees are outside this worker's writable sandbox: #{JSON.generate(@parallel_roots || [])}. Collision permission grants no integration authority.\n" \
        "#{notice}" \
        "Host verified remote_url/branch using git ls-remote before launch: #{JSON.generate(heads)}. This is host evidence, not a CLI refresh.\n" \
        "This CLI has no ChatGPT connected GitHub integration. Shell network is disabled; approvals are never allowed. Do not escalate or enable network.\n" \
        "If required external reads, prerequisites or final freshness cannot be established, stop and report that limitation. Do not claim refreshed GitHub refs.\n" \
        "Run one foreground worker only. Do not delegate, commit, stage, push, publish, or change ACT lifecycle/task data. Return a local patch and review handoff.\n" \
        "--- END ACT LOCAL CLI EXECUTION ENVELOPE ---\n"
    end

    def sandbox_probe!(inventory, workspace, run_dir)
      platform = RbConfig::CONFIG.fetch("host_os").match?(/darwin/) ? "macos" :
                 RbConfig::CONFIG.fetch("host_os").match?(/linux/) ? "linux" : nil
      raise InvalidState, "launch: unsupported sandbox platform" unless platform
      help, _stderr, status = Open3.capture3(worker_env, @codex, "sandbox", "--help", unsetenv_others: true)
      raise InvalidState, "launch: installed CLI lacks flat sandbox probe" unless
        status.success? && help.include?("codex sandbox") && help.include?("[COMMAND]") &&
        !help.include?("--full-auto")
      marker = "ACT sandbox probe #{SecureRandom.hex(12)}"
      targets = [[File.join(run_dir, "sandbox-deny-#{SecureRandom.hex(6)}"), false]]
      targets << [File.join(@data_root, ".act-probe-#{SecureRandom.hex(6)}"), false] if @manual_conflicts&.any?
      inventory.fetch("entries").each do |entry|
        targets << [File.join(entry.fetch("path"), ".act-probe-#{SecureRandom.hex(6)}"), entry.fetch("access") == "write"]
        targets << [File.join(entry.fetch("parent"), ".act-probe-#{SecureRandom.hex(6)}"), false]
        if @manual_conflicts&.any?
          admin = git!("rev-parse", "--absolute-git-dir", chdir: entry.fetch("path"))
          targets << [File.join(admin, "act-probe-#{SecureRandom.hex(6)}"), false]
        end
      end
      (@parallel_roots || []).each do |path|
        targets << [File.join(path, ".act-probe-#{SecureRandom.hex(6)}"), false]
      end
      inventory.fetch("entries").map { |entry| entry.fetch("parent") }.uniq.each do |parent|
        admin = git!("rev-parse", "--path-format=absolute", "--git-common-dir", chdir: parent)
        targets << [File.join(admin, "act-probe-#{SecureRandom.hex(6)}"), false]
      end
      begin
        created = []
        targets.each do |path, _allowed|
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(marker) }
          created << path
        end
        # `sandbox` has no --ignore-user-config; a fresh private CODEX_HOME
        # prevents operator config from changing the probe's permissions.
        stdout, result = Dir.mktmpdir("act-sandbox-config-") do |isolated_home|
          output, _stderr, status = Open3.capture3(
            worker_env.merge("CODEX_HOME" => isolated_home), @codex,
            "-c", 'sandbox_mode="workspace-write"',
            "-c", "sandbox_workspace_write.network_access=false",
            "-c", "sandbox_workspace_write.writable_roots=#{JSON.generate(inventory.fetch('entries').select { |entry| entry['access'] == 'write' }.map { |entry| entry.fetch('path') }.drop(1))}",
            "-c", "sandbox_workspace_write.exclude_tmpdir_env_var=true",
            "-c", "sandbox_workspace_write.exclude_slash_tmp=true",
            "sandbox", "--",
            "/bin/sh", "-c", 'for path; do if printf breach > "$path" 2>/dev/null; then printf "1\\n"; else printf "0\\n"; fi; done',
            "act-probe", *targets.map(&:first),
            chdir: workspace, unsetenv_others: true
          )
          [output, status]
        end
        results = stdout.lines.map(&:strip)
        targets.each_with_index do |(path, allowed), index|
          actual = File.binread(path)
          unless result.success? && results.length == targets.length &&
                 results[index] == (allowed ? "1" : "0") && actual == (allowed ? "breach" : marker)
            raise InvalidState, "launch: sandbox boundary unverified for #{path}; worker not started"
          end
        end
      ensure
        created.each { |path| File.unlink(path) if File.file?(path) && !File.symlink?(path) }
      end
      @report["sandbox_probe"] = { "platform" => platform, "checked_at" => Time.now.utc.iso8601,
                                   "protected_paths" => targets.count { |_path, allowed| !allowed } }
      save_report
    end

    def git!(*args, chdir: nil)
      stdout, stderr, status = Open3.capture3("git", *args, **(chdir ? { chdir: chdir } : {}))
      raise RepositoryError, "launch git failed: #{stderr.strip}" unless status.success?
      stdout.strip
    end

    def verify_checkout!(workspace, base)
      unless git!("remote", "get-url", base.fetch("remote"), chdir: workspace) == base.fetch("remote_url") &&
             git!("rev-parse", "HEAD", chdir: workspace) == base.fetch("pushed_sha") &&
             git!("status", "--porcelain", "--untracked-files=all", chdir: workspace).empty?
        raise InvalidState, "launch: unsafe checkout identity/state"
      end
      _stdout, _stderr, status = Open3.capture3("git", "symbolic-ref", "-q", "HEAD", chdir: workspace)
      raise InvalidState, "launch: workspace must have a dedicated feature branch" unless status.success?
      directory = workspace
      loop do
        # HOME/.codex is the normal authentication store, not project configuration.
        if directory != File.expand_path(ENV.fetch("HOME", "/nonexistent")) && File.exist?(File.join(directory, ".codex"))
          raise InvalidState, "launch: project/ancestor Codex configuration requires operator judgment"
        end
        break if directory == File.dirname(directory)
        directory = File.dirname(directory)
      end
      if File.exist?(File.join(workspace, ".gitmodules"))
        raise InvalidState, "launch: project Codex configuration or submodules require operator judgment"
      end
    end

    def changed_write!(task, state, heads)
      task.fetch("repositories").each do |name, spec|
        next unless spec.fetch("access") == "write"
        raise InvalidState, "#{name}: STALE INPUT" unless heads.fetch(name).fetch("pushed_sha") == state.fetch("snapshot").fetch(name).fetch("pushed_sha")
      end
    end

    def save_report
      temporary = "#{@report_path}.tmp"
      File.open(temporary, "w", 0o600) { |file| file.write(JSON.pretty_generate(@report) + "\n"); file.flush; file.fsync }
      File.rename(temporary, @report_path)
    end

    def execute(command, lock)
      input_r, input_w = IO.pipe
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe
      pid = nil
      interrupted = nil
      old_traps = {}
      begin
        %w[INT TERM HUP].each do |signal|
          old_traps[signal] = Signal.trap(signal) do
            interrupted ||= signal
            Process.kill(signal, -pid) if pid
          rescue Errno::ESRCH
            nil
          end
        end
        begin
          pid = @spawner.call(worker_env, *command, chdir: @report.fetch("workspace"),
                              in: input_r, out: stdout_w, err: stderr_w, pgroup: true, unsetenv_others: true)
        rescue SystemCallError => e
          @report.merge!("status" => "child_start_failed", "exit_status" => 127, "error" => e.message)
          save_report
          @err.puts "ERROR: child failed to start; reservation retained, operator recovery required"
          return 127
        end
        [input_r, stdout_w, stderr_w].each(&:close)
        @report.merge!("status" => "running", "child_pid" => pid, "child_started_at" => Time.now.utc.iso8601,
                       "heartbeat_at" => Time.now.utc.iso8601(6), "heartbeat_child_pid" => pid)
        Process.kill(interrupted, -pid) if interrupted
        save_report
        lock.flock(File::LOCK_UN)
        writer = Thread.new do
          IO.copy_stream(@report.fetch("stdin_path"), input_w)
        rescue Errno::EPIPE, IOError
          nil
        ensure
          input_w.close unless input_w.closed?
        end
        streams = [
          Thread.new { capture_stream(stdout_r, @report.fetch("jsonl_path"), @out) },
          Thread.new { capture_stream(stderr_r, @report.fetch("stderr_path"), @err) }
        ]
        deadline = nil
        next_heartbeat = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        loop do
          waited = Process.waitpid2(pid, Process::WNOHANG)
          if waited
            @report["exit_status"] = waited.last.exitstatus || 128 + waited.last.termsig
            @report["signal"] = waited.last.termsig
            break
          end
          deadline ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3 if interrupted
          if deadline && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            Process.kill("KILL", -pid) rescue Errno::ESRCH
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= next_heartbeat
            @report["heartbeat_at"] = Time.now.utc.iso8601(6)
            save_report
            next_heartbeat = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
          end
          sleep 0.02
        end
        # Kill surviving descendants before draining pipes; never leave detached work.
        Process.kill("KILL", -pid) rescue Errno::ESRCH
        writer.join
        streams.each(&:value)
        final = File.file?(@report.fetch("final_path")) ? File.binread(@report.fetch("final_path")).force_encoding("UTF-8") : nil
        valid = final && final.valid_encoding? && !final.strip.empty?
        @report["final_valid"] = !!valid
        @report["status"] = interrupted ? "interrupted" : valid ? "exited" : "invalid_final"
        @err.puts "ERROR: worker produced missing/invalid final output" unless valid
        @out.puts final if valid
        @report["ended_at"] = Time.now.utc.iso8601
        File.foreach(@report.fetch("jsonl_path")) do |line|
          event = JSON.parse(line) rescue nil
          @report["session_id"] ||= event["thread_id"] if event.is_a?(Hash) && event["type"] == "thread.started"
        end
        @report["artifacts"] = %w[prompt_path stdin_path jsonl_path stderr_path final_path].filter_map do |key|
          path = @report.fetch(key)
          { "path" => path, "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path) } if File.file?(path)
        end
        begin
          @report["exit_heads"] = @coordinator.launch_heads(@report.fetch("task_id"))
          @report["exit_checked_at"] = Time.now.utc.iso8601
          changed = @report.fetch("preparation").keys.select do |name|
            @report.fetch("preparation").fetch(name).fetch("pushed_sha") != @report.fetch("exit_heads").fetch(name).fetch("pushed_sha")
          end
          @report["exit_changed_repositories"] = changed
          @report["writable_freshness"] = (changed & @report.fetch("writable_repositories")).empty? ? "fresh_at_exit" : "stale"
          @err.puts "STALE INPUT: writable pushed head moved during execution; review exit provenance" if @report["writable_freshness"] == "stale"
        rescue Error => e
          @report["exit_freshness_error"] = e.message
          @report["writable_freshness"] = "unavailable"
          @err.puts "ERROR: host exit freshness unavailable: #{e.message}"
        end
        save_report
        @report.fetch("exit_status")
      ensure
        old_traps.each { |signal, old| Signal.trap(signal, old) }
        [input_r, input_w, stdout_r, stdout_w, stderr_r, stderr_w].each { |io| io.close unless io.closed? }
        if pid
          Process.kill("KILL", -pid) rescue Errno::ESRCH
          Process.waitpid(pid) rescue Errno::ECHILD
        end
      end
    end

    def capture_stream(stream, path, terminal)
      File.open(path, "wb", 0o600) do |file|
        loop do
          bytes = stream.readpartial(4096)
          file.write(bytes)
          file.flush
          terminal.write(bytes)
          terminal.flush if terminal.respond_to?(:flush)
        end
      rescue EOFError
        nil
      end
    end
  end
end
