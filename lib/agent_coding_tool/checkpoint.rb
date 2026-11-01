# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "shellwords"
require "tempfile"
require "tmpdir"
require "time"

module AgentCodingTool
  module CheckpointPolicy
    def self.required?(task)
      task.fetch("checkpoint", {}).fetch("mode", "required") == "required"
    end
  end

  # A checkpoint belongs to an attempt, not to the lifecycle outcome. All
  # artifacts and manifests live in the operator's private run-evidence root.
  class Checkpoint
    SCHEMA = "agent-coding-tool-checkpoint/v1"
    GATE_SCHEMA = "agent-coding-tool-checkpoint-gate/v1"
    OBSERVATION_SCHEMA = "agent-coding-tool-gate-observation/v1"
    INVOCATION_SETTINGS = %w[TMPDIR TMP TEMP SEED TESTOPTS].freeze

    # Binds the operator-owned task/evidence roots and receipt diagnostics stream;
    # construction performs no I/O. Filesystem failures arise at operation time.
    def initialize(data_root:, err: $stderr, transport: NativeCommandTransport.new)
      @data_root = File.expand_path(data_root)
      @tasks = TaskStore.new(File.join(@data_root, "tasks"))
      @states = StateStore.new(File.join(@data_root, "state"))
      @root = "#{@data_root}-runs"
      @err = err
      @transport = transport
    end

    # Exports canonical bytes without reading/writing host task/run state. Inputs
    # declare task, local baseline, remote and an absent artifact outside workspace.
    # Returns checked artifact identity and shell-safe operator commands; invalid,
    # empty, changing or inapplicable candidates raise. This is not a checkpoint,
    # a prepared-authority/freshness check, or evidence that tests passed.
    def export(id, workspace:, base_sha:, artifact:, remote: "origin")
      raise InvalidTask, "checkpoint: unsafe task ID" unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      raise InvalidState, "checkpoint: exact baseline SHA required" unless base_sha.match?(/\A[0-9a-f]{40}\z/)
      base = { "pushed_sha" => base_sha, "remote" => remote,
               "remote_url" => git!(workspace, "remote", "get-url", remote) }
      workspace = workspace!(workspace, base)
      artifact = File.expand_path(artifact)
      unless !File.exist?(artifact) && !File.symlink?(artifact) &&
             File.realpath(File.dirname(artifact)) == File.dirname(artifact) &&
             artifact != workspace && !artifact.start_with?("#{workspace}/")
        raise InvalidState, "checkpoint: export requires an absent artifact outside workspace with real parent"
      end
      bytes, inventory = implementation(workspace, base_sha)
      raise InvalidState, "checkpoint: empty implementation" if bytes.empty? || inventory.empty?
      write_once!(artifact, bytes)
      verify_patch!(artifact, bytes, inventory, workspace, base)
      latest, latest_inventory = implementation(workspace!(workspace, base), base_sha)
      raise InvalidState, "checkpoint: implementation changed during export" unless latest == bytes && latest_inventory == inventory
      prefix = ["env", "AGENT_CODING_TOOL_DATA_DIR=#{@data_root}", "act", "checkpoint"]
      target = [id, "--workspace", workspace]
      { "status" => "canonical_format_checked", "task_id" => id, "workspace" => workspace,
        "base_sha" => base_sha, "artifact" => artifact, "sha256" => Digest::SHA256.hexdigest(bytes),
        "bytes" => bytes.bytesize, "changed_files" => inventory, "host_checkpoint" => "pending",
        "worker_checks" => "not attested; report actual focused commands and results separately",
        "next_owner" => "operator",
        "host_commands" => {
          "record" => Shellwords.join(prefix + ["record", *target, "--artifact", artifact]),
          "verify" => Shellwords.join(prefix + ["verify", *target]),
          "gate_prefix" => Shellwords.join(prefix + ["gate", *target, "--"]) },
        "remaining" => "host record/verify, required gated tests, freshness, integration, acceptance and publication; no authority granted" }
    end

    def record(id, workspace:, artifact: nil, reservation_lock: nil)
      reservation_lock ||= gate_reservation
      ReservationLock.synchronize(@data_root, held: reservation_lock) { nil } if reservation_lock
      task, state, name, base = context!(id, require_in_flight: true)
      raise InvalidState, "#{id}: checkpoint exempt" unless CheckpointPolicy.required?(task)
      workspace = workspace!(workspace, base)
      launch = launch_binding!(id, state, name, base, workspace)
      unless reservation_lock
        return ReservationLock.synchronize(@data_root) do |lock|
          record(id, workspace: workspace, artifact: artifact, reservation_lock: lock)
        end
      end
      expected, inventory = implementation(workspace, base.fetch("pushed_sha"))
      raise InvalidState, "checkpoint: empty implementation" if inventory.empty? || expected.empty?
      if artifact
        raise InvalidState, "checkpoint: symlinked/absent artifact" if File.symlink?(artifact) || !File.file?(artifact)
        raise InvalidState, "checkpoint: artifact differs from complete implementation" unless File.binread(artifact) == expected
      end
      directory = directory!(id, state)
      raise InvalidState, "checkpoint: evidence overlaps disposable workspace" if
        directory == workspace || directory.start_with?("#{workspace}/")
      previous = current_record(directory, id, state, name, base, optional: true)
      token = SecureRandom.uuid
      filename = "#{token}.patch"
      path = File.join(directory, filename)
      write_once!(path, expected)
      begin
        verify_patch!(path, expected, inventory, workspace, base)
        latest, latest_inventory = implementation(workspace!(workspace, base), base.fetch("pushed_sha"))
        raise InvalidState, "checkpoint: implementation changed during preservation" unless
          latest == expected && latest_inventory == inventory
        now = Time.now.utc.iso8601(6)
        record = {
          "schema_version" => SCHEMA, "task_id" => id,
          "attempt" => attempt(state), "repository" => name,
          "launch_invocation" => launch && launch.fetch("invocation_id"),
          "authority" => base.slice("remote_url", "branch", "pushed_sha"),
          "changed_files" => inventory, "artifact_type" => "git-binary-patch",
          "artifact" => filename, "bytes" => expected.bytesize,
          "sha256" => Digest::SHA256.hexdigest(expected),
          "implementation_sha256" => Digest::SHA256.hexdigest(expected),
          "created_at" => now, "verified_at" => Time.now.utc.iso8601(6),
          "previous_record" => previous && previous.fetch("record_file")
        }
        record_name = "#{token}.json"
        write_once!(File.join(directory, record_name), JSON.pretty_generate(record) + "\n")
        # The old pointer and its immutable artifact survive an interrupted refresh.
        atomic!(File.join(directory, "current.json"), JSON.pretty_generate(
          "record_file" => record_name,
          "sha256" => Digest::SHA256.file(File.join(directory, record_name)).hexdigest
        ) + "\n")
        state["checkpoint"] = { "attempt" => attempt(state), "status" => "verified",
                                "record_path" => File.join(directory, "current.json"),
                                "verified_at" => record.fetch("verified_at") }
        save_state!(id, state)
        record.merge("record_file" => record_name, "path" => path)
      rescue StandardError
        # Never change the authoritative pointer or destroy the previous artifact.
        raise
      end
    end

    # Verifies current or explicitly selected closed-attempt evidence against its
    # original base. Historical verification is read-only and accepts no workspace.
    def verify(id, workspace: nil, attempt: nil, read_only: false, reservation_lock: nil)
      reservation_lock ||= gate_reservation
      ReservationLock.synchronize(@data_root, held: reservation_lock) { nil } if reservation_lock
      raise InvalidState, "checkpoint: historical verification accepts no workspace" if attempt && workspace
      historical = AttemptRecovery.new(data_root: @data_root, transport: @transport).closed_state(id, attempt) if attempt
      task, state, name, base = context!(id, historical: historical)
      return { "status" => "exempt" } unless CheckpointPolicy.required?(task) || historical || state["checkpoint"]
      directory = directory!(id, state, create: false)
      record = current_record(directory, id, state, name, base)
      if historical && record["launch_invocation"] != historical.fetch("launch_invocation")
        raise InvalidState, "checkpoint: historical invocation mismatch"
      end
      path = File.join(directory, record.fetch("artifact"))
      bytes = checked_file!(path)
      raise InvalidState, "checkpoint: checksum/length mismatch" unless
        bytes.bytesize == record.fetch("bytes") && Digest::SHA256.hexdigest(bytes) == record.fetch("sha256")
      if workspace && !read_only && !reservation_lock
        return ReservationLock.synchronize(@data_root) do |lock|
          verify(id, workspace: workspace, read_only: false, reservation_lock: lock)
        end
      end
      if workspace
        workspace = workspace!(workspace, base)
        launch_binding!(id, state, name, base, workspace)
        actual, inventory = implementation(workspace, base.fetch("pushed_sha"), preserved_paths: record.fetch("changed_files").map { |entry| entry.fetch("path") })
        unless actual == bytes && inventory == record.fetch("changed_files")
          state["checkpoint"] = { "attempt" => attempt(state), "status" => "stale",
                                  "record_path" => File.join(directory, "current.json") }
          save_state!(id, state) unless read_only
          raise InvalidState, "checkpoint: stale implementation; refresh before validation or handoff"
        end
      end
      verify_patch!(path, bytes, record.fetch("changed_files"), nil, base)
      if workspace && state.dig("checkpoint", "status") != "verified"
        state["checkpoint"] = { "attempt" => attempt(state), "status" => "verified",
                                "record_path" => File.join(directory, "current.json"),
                                "verified_at" => record.fetch("verified_at") }
        save_state!(id, state) unless read_only
      end
      { "status" => "verified", "record" => record, "path" => path,
        "workspace_checked" => !!workspace }
    end

    # Runs the unchanged inherited-environment system call between candidate
    # checks, returning its exit code or propagating the original failure.
    # Optional requested settings are declarations, never command overrides.
    # A fresh private observation file may report supported facts; receipts are
    # best effort and persistence failures warn without replacing primary errors.
    def gate(id, workspace:, command:, requested: {}, observations: nil, force: false, reason: nil, reservation_lock: nil)
      ReservationLock.synchronize(@data_root, held: reservation_lock) { nil } if reservation_lock
      raise InvalidState, "checkpoint: validation command required" if command.empty?
      raise InvalidState, "checkpoint: --reason requires --force" if reason && !force
      task, initial_state, = context!(id, require_in_flight: !force)
      # Preserve the existing evidence-path diagnostic before lock acquisition.
      # Exempt manual commands have no candidate/evidence requirement.
      if CheckpointPolicy.required?(task) || initial_state["checkpoint"]
        cursor = @root
        loop do
          raise InvalidState, "checkpoint: symlinked evidence path" if File.symlink?(cursor)
          break if cursor == File.dirname(cursor)
          cursor = File.dirname(cursor)
        end
      end
      unless reservation_lock || unavailable_manual_exempt_storage?(id, task, initial_state, force)
        return ReservationLock.synchronize(@data_root) do |lock|
          with_gate_reservation(lock) do
            gate(id, workspace: workspace, command: command, requested: requested, observations: observations,
              force: force, reason: reason, reservation_lock: lock)
          end
        end
      end
      _task, state, name, base = context!(id, require_in_flight: !force)
      raise InvalidState, "checkpoint: task state identity mismatch" if force && state["id"] != id
      original_state = File.binread(@states.state_path(id)) if force
      if force
        ExternalActivity.new(data_root: @data_root, task_store: @tasks, state_store: @states,
          repo_inspector: RepoInspector.new(Config.load(File.join(@data_root, "config.yml")), transport: @transport)).assert_clear!(id)
        preserved_writers_clear!(id)
      end
      directory = force ? directory!(id, state, create: false) : gate_directory(id, state, workspace)
      record = directory && current_record(directory, id, state, name, base, optional: !force)
      token = SecureRandom.uuid
      receipt = {
        "schema_version" => GATE_SCHEMA, "invocation_id" => token,
        "task_id" => id, "attempt" => attempt(state), "repository" => name,
        "authority" => base.slice("remote_url", "branch", "pushed_sha"),
        "candidate" => record && record.slice("record_file", "sha256", "implementation_sha256", "artifact", "launch_invocation"),
        "workspace_argument" => workspace, "cwd" => nil, "argv" => command,
        "settings" => INVOCATION_SETTINGS.to_h { |key| [key, ENV[key]] },
        "requested" => { "source" => "operator_declaration", "seed" => requested[:seed], "selection" => requested[:selection] },
        "observed" => { "status" => "not_observed", "seed" => nil, "selection" => nil, "summary" => nil },
        "output" => { "status" => "not_captured" },
        "started_at" => Time.now.utc.iso8601(6), "finished_at" => nil,
        "pre_check" => "not_checked", "post_check" => "not_checked",
        "receipt_phase" => "started", "command_outcome" => { "status" => "incomplete_or_unknown" }, "candidate_validation" => "unknown"
      }
      if force
        receipt["lifecycle_exception"] = { "consent" => "invocation_local_force", "reason" => reason,
          "outcome" => state.dig("result", "outcome"), "started_at" => state["started_at"],
          "state_sha256" => Digest::SHA256.hexdigest(original_state), "rule" => "requires_in_flight" }
      end
      persist_gate(directory, "gate-#{token}.started.json", receipt, required: force)
      receipt["command_outcome"] = { "status" => "not_run" }
      phase = "pre_check"
      begin
        before = verify(id, workspace: workspace, read_only: force, reservation_lock: reservation_lock)
        # Receipt setup is optional; verification still supplies the binding when
        # storage setup failed, and the post-check must match that exact record.
        record = before["record"] unless directory
        verify_gate_binding!(before, record)
        receipt["pre_check"] = "verified"
        phase = "observation_input"
        observation_path!(observations, directory) if observations
        receipt["cwd"] = File.realpath(workspace)
        if force
          launch = launch_binding!(id, state, name, base, receipt.fetch("cwd"))
          if launch
            manager = WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root,
              record_path: launch.fetch("worktrees_path"), transport: @transport)
            unless RetryLiveness.new.check(launch, manager.inspect!) == :clear
              raise InvalidState, "checkpoint: active or unknown writer; force admits lifecycle only"
            end
          end
        end
        phase = "command"
        receipt["command_outcome"] = { "status" => "incomplete_or_unknown" }
        success = system(*command, chdir: workspace)
        status = $?
        exit_code = status.exitstatus if status
        receipt["command_outcome"] = {
          "status" => success.nil? ? "failed_to_start" : status&.signaled? ? "signal" : status&.exited? ? "exited" : "incomplete_or_unknown",
          "success" => success, "exit_code" => exit_code, "signal" => status&.termsig
        }
        if force
          receipt["receipt_phase"] = "command_finished"
          persist_gate(directory, "gate-#{token}.command.json", receipt, required: true)
        end
        phase = "post_check"
        after = verify(id, workspace: workspace, read_only: force, reservation_lock: reservation_lock)
        verify_gate_binding!(after, record)
        receipt["post_check"] = "verified"
        receipt["candidate_validation"] = success ? (record ? "passed" : "not_applicable") : "failed"
        phase = "complete"
        raise InvalidState, "checkpoint: validation command failed (#{exit_code || 'unavailable'})" unless success || force
        exit_code || (status&.signaled? ? 128 + status.termsig : 127)
      rescue Exception => error # Also retain evidence for Interrupt; never swallow it.
        receipt[phase] = "failed" if %w[pre_check post_check].include?(phase)
        receipt["command_outcome"]["status"] = "failed_to_start" if phase == "command" && error.is_a?(SystemCallError)
        receipt["exception_class"] = error.class.name
        receipt["failure_phase"] = phase
        receipt["candidate_validation"] = "failed"
        raise
      ensure
        receipt["observed"] = gate_observations(observations, id, state) if observations && receipt["command_outcome"]["status"] != "not_run"
        receipt["receipt_phase"] = "finished"
        receipt["finished_at"] = Time.now.utc.iso8601(6)
        if force && File.binread(@states.state_path(id)) != original_state
          receipt["lifecycle_bytes"] = "changed_during_validation"
          persist_gate(directory, "gate-#{token}.finished.json", receipt, required: true)
          raise InvalidState, "checkpoint: lifecycle bytes changed during validation; inspect receipt"
        end
        persist_gate(directory, "gate-#{token}.finished.json", receipt, required: force)
      end
    end

    # Reconstructs current or closed-attempt bytes in a new independent clone;
    # explicit disconnected-worker judgment grants no acceptance/publication.
    def recover(id, destination:, confirm_disconnected: false, attempt: nil)
      raise InvalidState, "checkpoint: explicit disconnected-worker judgment required" unless confirm_disconnected
      historical = AttemptRecovery.new(data_root: @data_root, transport: @transport).closed_state(id, attempt) if attempt
      _task, state, _name, base = context!(id, historical: historical)
      evidence = verify(id, attempt: attempt)
      raise InvalidState, "checkpoint: exempt task has no recovery artifact" if evidence["status"] == "exempt"
      raise InvalidState, "checkpoint: destination occupied" if File.exist?(destination) || File.symlink?(destination)
      path = File.expand_path(destination)
      source = base.fetch("path")
      source_identity!(source, base)
      begin
        git!(nil, "clone", "--no-local", "--no-hardlinks", "--no-checkout", "--", source, path)
        git!(path, "checkout", "--detach", base.fetch("pushed_sha"))
        git!(path, "apply", "--check", "--binary", evidence.fetch("path"))
        git!(path, "apply", "--binary", evidence.fetch("path"))
        record = evidence.fetch("record")
        actual, inventory = implementation(path, base.fetch("pushed_sha"), preserved_paths: record.fetch("changed_files").map { |entry| entry.fetch("path") })
        raise InvalidState, "checkpoint: reconstructed implementation differs" unless
          Digest::SHA256.hexdigest(actual) == record.fetch("implementation_sha256") &&
          inventory == record.fetch("changed_files")
      rescue StandardError
        # Preserve a partial checkout for operator diagnosis.
        raise
      end
      { "path" => path, "task_id" => id, "attempt" => attempt(state), "status" => "reconstructed" }
    end

    private

    # Retains the old best-effort command path only for an exempt manual attempt
    # with no checkpoint/managed resources and a regular file occupying the run
    # root. Hard reset cannot enter this namespace and independently refuses the
    # manual reservation. Busy locks and unsafe managed evidence never fall back.
    def unavailable_manual_exempt_storage?(id, task, state, force)
      root = "#{File.realpath(@data_root)}-runs"
      !force && !CheckpointPolicy.required?(task) && !state["checkpoint"] &&
        state["started_at"].is_a?(String) && !File.symlink?(root) && File.file?(root) &&
        !File.exist?(File.join(root, id))
    end

    # Borrows a checkpoint gate's same-thread lock for synchronous nested
    # checkpoint operations. Other threads/processes still acquire/refuse their
    # own lock; ReservationLock revalidates every borrowed token and path.
    def gate_reservation
      Thread.current[:act_checkpoint_gate_reservations]&.fetch(File.realpath(@data_root), nil)
    end

    # Holds the physical lock across the command and checks, restoring the prior
    # same-thread context even on exceptions. This grants no other writer access.
    def with_gate_reservation(lock)
      locks = Thread.current[:act_checkpoint_gate_reservations] ||= {}
      root = File.realpath(@data_root)
      previous = locks[root]
      locks[root] = lock
      yield
    ensure
      previous ? locks[root] = previous : locks.delete(root)
    end

    # Qualifies retained managed ownership and inactivity for forced validation.
    # Manual attempts have no managed report; external reports are checked by the
    # caller. Unknown, active or damaged managed evidence raises without mutation.
    def preserved_writers_clear!(id)
      path = File.join(@root, id)
      return unless File.exist?(path) || File.symlink?(path)
      rows = AttemptRecovery.new(data_root: @data_root, transport: @transport).inspect(id)
      rows.each do |row|
        unless row.fetch("blockers").empty? && row["inventory"]
          raise InvalidState, "checkpoint: managed writer ownership unverified"
        end
        report = JSON.parse(checked_file!(File.join(row.fetch("run_dir"), "handoff.json")))
        unless RetryLiveness.new.check(report, row.fetch("inventory")) == :clear
          raise InvalidState, "checkpoint: active or unknown writer; force admits lifecycle only"
        end
      end
    end

    # Ensures both checks used this invocation's checkpoint, including its record
    # identity. Exempt checks have no candidate; pointer replacement raises.
    def verify_gate_binding!(verification, record)
      raise InvalidState, "checkpoint: candidate changed during validation" unless verification["record"] == record
    end

    # Accepts only a new direct child of the private attempt directory. Returns
    # its absolute path; reused files, symlinks and foreign locations raise.
    def observation_path!(path, directory)
      absolute = File.expand_path(path)
      unless path == absolute && File.dirname(absolute) == directory && File.basename(absolute).match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*\.observation\.json\z/) &&
             !File.exist?(absolute) && !File.symlink?(absolute)
        raise InvalidState, "checkpoint: observations require a fresh NAME.observation.json in the private attempt directory"
      end
      absolute
    end

    # Reads a bounded, private, command-reported JSON sidecar without inspecting
    # console output or shell internals. Returns explicit unknowns on unavailable
    # or invalid data; no report or observation error changes command success.
    def gate_observations(path, id, state)
      unknown = { "status" => "unavailable_or_invalid", "seed" => nil, "selection" => nil, "summary" => nil,
                  "source" => { "kind" => "command_report", "path" => File.expand_path(path) } }
      return unknown unless File.dirname(path) == directory!(id, state, create: false)
      bytes = File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        stat = file.stat
        return unknown unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? && stat.size <= 8192
        file.binmode.read(8193)
      end
      return unknown unless bytes && bytes.bytesize <= 8192
      report = JSON.parse(bytes)
      return unknown unless report.is_a?(Hash) && report["schema_version"] == OBSERVATION_SCHEMA &&
        (report.keys - %w[schema_version seed selection summary]).empty? &&
        (report["seed"].nil? || report["seed"].is_a?(Integer)) &&
        (report["selection"].nil? || (report["selection"].is_a?(String) && report["selection"].bytesize <= 1024))
      summary = report["summary"]
      return unknown unless summary.nil? || (summary.is_a?(Hash) && !summary.empty? &&
        (summary.keys - %w[tests assertions failures errors skips]).empty? &&
        summary.values.all? { |value| value.is_a?(Integer) && value >= 0 })
      unknown.merge("status" => "reported", "seed" => report["seed"], "selection" => report["selection"], "summary" => summary,
                    "source" => unknown.fetch("source").merge("sha256" => Digest::SHA256.hexdigest(bytes)))
    rescue StandardError
      unknown
    end

    # Prepares private receipt storage for an invocation, returning nil with a
    # durability warning on failure. Mandatory verification remains in gate;
    # unsafe paths are never canonicalized to bypass evidence ancestry checks.
    def gate_directory(id, state, workspace)
      directory = directory!(id, state)
      raise InvalidState, "checkpoint: evidence overlaps disposable workspace" if
        directory == File.expand_path(workspace) || directory.start_with?("#{File.expand_path(workspace)}/")
      directory
    rescue StandardError, NotImplementedError => error
      @err.puts "Checkpoint gate receipt setup failed (#{error.class}); crash durability unconfirmed; inspect private evidence before retrying"
      nil
    end

    # Writes immutable invocation evidence through the checkpoint's existing
    # sync boundary, rechecking private ancestry. Returns a path on success;
    # failures report crash-durability uncertainty without masking gate errors.
    def persist_gate(directory, filename, receipt, required: false)
      return unless directory
      _task, state, = context!(receipt.fetch("task_id"))
      raise InvalidState, "checkpoint: attempt changed during validation" unless
        directory!(receipt.fetch("task_id"), state, create: false) == directory
      path = File.join(directory, filename)
      write_once!(path, JSON.pretty_generate(receipt) + "\n")
      @err.puts "Checkpoint gate receipt: #{path}"
      path
    rescue StandardError, NotImplementedError => error
      @err.puts "Checkpoint gate receipt write failed (#{error.class}); crash durability unconfirmed; inspect private evidence before retrying"
      if required
        raise InvalidState, "checkpoint: required receipt failed (#{error.class}); child result: #{receipt.fetch('command_outcome').inspect}; audit durability unconfirmed"
      end
      nil
    end

    # Resolves current or explicitly bound original task/state/writer/base context.
    # Unsupported writer counts, missing preparation or execution identity raise
    # InvalidState; this helper does not change lifecycle or evidence.
    def context!(id, require_in_flight: false, historical: nil)
      raise InvalidTask, "checkpoint: unsafe task ID" unless id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      TaskReset.new(data_root: File.realpath(@data_root), transport: @transport).assert_admission!(id)
      task = @tasks.load(id)
      state = historical || @states.load(id)
      raise InvalidState, "#{id}: checkpoint requires an in-flight attempt" unless
        state.is_a?(Hash) && (!require_in_flight ||
          (state["started_at"].is_a?(String) && !state["result"])) &&
        (state["started_at"].is_a?(String) || state.dig("checkpoint", "attempt")&.match?(/\A[0-9a-f]{32}\z/))
      writes = task.fetch("repositories").select { |_name, spec| spec.fetch("access") == "write" }
      raise InvalidState, "checkpoint: exactly one writable repository supported" unless writes.length == 1
      name = writes.keys.first
      base = state.fetch("snapshot").fetch(name)
      unless base.is_a?(Hash) && base["pushed_sha"]&.match?(/\A[0-9a-f]{40}\z/) &&
             %w[path remote remote_url branch].all? { |key| base[key].is_a?(String) && !base[key].empty? }
        raise InvalidState, "checkpoint: incomplete baseline identity"
      end
      [task, state, name, base]
    rescue KeyError, NoMethodError
      raise InvalidState, "checkpoint: incomplete preparation"
    end

    def attempt(state)
      return state.fetch("checkpoint").fetch("attempt") unless state["started_at"]

      Digest::SHA256.hexdigest(JSON.generate(state.values_at("prepared_at", "started_at", "snapshot")))[0, 32]
    end

    def directory!(id, state, create: true)
      directory = File.join(@root, "checkpoints", id, attempt(state))
      cursor = directory
      loop do
        raise InvalidState, "checkpoint: symlinked evidence path" if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)
        cursor = File.dirname(cursor)
      end
      FileUtils.mkdir_p(directory, mode: 0o700) if create
      raise InvalidState, "checkpoint: no preserved evidence" unless File.directory?(directory)
      [@root, File.join(@root, "checkpoints"), File.join(@root, "checkpoints", id), directory].each do |path|
        raise InvalidState, "checkpoint: evidence root must be private and operator owned" unless
          File.directory?(path) && File.stat(path).uid == Process.uid && (File.stat(path).mode & 0o077).zero?
      end
      directory
    end

    def current_record(directory, id, state, name, base, optional: false)
      pointer_path = File.join(directory, "current.json")
      return nil if optional && !File.exist?(pointer_path)
      pointer = JSON.parse(checked_file!(pointer_path))
      record_name = pointer.fetch("record_file")
      raise InvalidState, "checkpoint: unsafe record name" unless record_name.match?(/\A[0-9a-f-]+\.json\z/)
      record_bytes = checked_file!(File.join(directory, record_name))
      raise InvalidState, "checkpoint: record checksum mismatch" unless
        Digest::SHA256.hexdigest(record_bytes) == pointer.fetch("sha256")
      record = JSON.parse(record_bytes)
      unless record["schema_version"] == SCHEMA && record["task_id"] == id &&
             record["attempt"] == attempt(state) && record["repository"] == name &&
             record["authority"] == base.slice("remote_url", "branch", "pushed_sha") &&
             record["changed_files"].is_a?(Array) && !record["changed_files"].empty? &&
             record["bytes"].is_a?(Integer) && record["bytes"].positive? &&
             record["sha256"]&.match?(/\A[0-9a-f]{64}\z/) &&
             record["implementation_sha256"] == record["sha256"] &&
             record["artifact_type"] == "git-binary-patch" &&
             record["artifact"]&.match?(/\A[0-9a-f-]+\.patch\z/) &&
             %w[created_at verified_at].all? { |field| Time.iso8601(record.fetch(field)) }
        raise InvalidState, "checkpoint: foreign or malformed evidence"
      end
      record.merge("record_file" => record_name)
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError
      raise InvalidState, "checkpoint: malformed evidence"
    end

    def checked_file!(path)
      raise InvalidState, "checkpoint: missing/symlinked evidence" if File.symlink?(path) || !File.file?(path)
      File.binread(path)
    end

    def source_identity!(source, base)
      raise InvalidState, "checkpoint: source must be an ordinary repository" unless
        File.directory?(source) && !File.symlink?(source) &&
        File.realpath(source) == File.expand_path(source) &&
        git!(source, "rev-parse", "--show-toplevel") == source &&
        git!(source, "remote", "get-url", base.fetch("remote")) == base.fetch("remote_url") &&
        git!(source, "cat-file", "-t", base.fetch("pushed_sha")) == "commit"
    end

    def launch_binding!(id, state, name, base, workspace)
      task_root = File.join(@root, id)
      return nil unless File.directory?(task_root)
      raise InvalidState, "checkpoint: symlinked run evidence" if File.symlink?(task_root)
      reports = IncidentalMetadata.children(task_root).filter_map do |entry|
        run_dir = File.join(task_root, entry)
        raise InvalidState, "checkpoint: partial/foreign run evidence" if
          File.symlink?(run_dir) || !File.directory?(run_dir)
        path = File.join(run_dir, "handoff.json")
        report = JSON.parse(checked_file!(path))
        report if report["task_id"] == id && report["prepared_at"] == state["prepared_at"]
      end
      raise InvalidState, "checkpoint: ambiguous launch attempt" if reports.length > 1
      report = reports.first
      return nil unless report
      unless report["schema_version"] == Launcher::SCHEMA && report["workspace"] == workspace &&
             report["writable_repository"] == name &&
             report["writable_authority"] == base.slice("remote_url", "branch", "pushed_sha") &&
             report["invocation_id"].is_a?(String) && !report["invocation_id"].empty?
        raise InvalidState, "checkpoint: workspace differs from launch ownership"
      end
      manager = WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root,
                                    record_path: report.fetch("worktrees_path"), transport: @transport)
      inventory = manager.inspect!
      unless inventory.fetch("task_id") == id &&
             inventory.fetch("entries").any? { |entry| entry["name"] == name && entry["path"] == workspace &&
               entry["access"] == "write" && entry["base_sha"] == base.fetch("pushed_sha") }
        raise InvalidState, "checkpoint: launch worktree identity mismatch"
      end
      report
    rescue JSON::ParserError, KeyError
      raise InvalidState, "checkpoint: malformed run ownership evidence"
    end

    def workspace!(path, base)
      path = File.expand_path(path)
      raise InvalidState, "checkpoint: symlinked workspace" unless File.directory?(path) && File.realpath(path) == path
      raise InvalidState, "checkpoint: workspace HEAD differs from prepared baseline" unless
        git!(path, "rev-parse", "HEAD") == base.fetch("pushed_sha")
      raise InvalidState, "checkpoint: workspace remote differs from prepared authority" unless
        git!(path, "remote", "get-url", base.fetch("remote")) == base.fetch("remote_url")
      path
    end

    # Returns canonical binary patch bytes and a complete status/path inventory
    # against sha, including untracked files, using disposable index/objects.
    # Checked historical inventories may preserve explicitly recorded metadata;
    # new candidates never supply preserved_paths. Staged changes, unsafe files
    # and failed Git operations raise InvalidState.
    def implementation(workspace, sha, preserved_paths: [])
      unless preserved_paths.all? { |path| path.is_a?(String) && !path.empty? && !path.start_with?("/") && !path.split("/").include?("..") }
        raise InvalidState, "checkpoint: unsafe preserved path"
      end
      IncidentalMetadata.check_repository!(workspace) { |*args| git!(workspace, *args, strip: false) }
      _staged, _error, staged = @transport.call(["git", "diff", "--cached", "--quiet", sha], cwd: workspace)
      raise InvalidState, "checkpoint: staged-only changes require operator judgment" unless staged.success?
      # Objects and index are disposable too: a confined worker must not write
      # shared Git administration when hashing untracked/changed content.
      Dir.mktmpdir("act-checkpoint-objects-") do |objects|
        Tempfile.create("act-checkpoint-index-") do |index|
          env = { "GIT_INDEX_FILE" => index.path, "GIT_OBJECT_DIRECTORY" => objects,
                  "GIT_ALTERNATE_OBJECT_DIRECTORIES" => git!(workspace, "rev-parse", "--path-format=absolute", "--git-path", "objects") }
          File.unlink(index.path)
          git!(workspace, "read-tree", sha, env: env)
          git!(workspace, "add", "-A", env: env)
          preserved_paths.each do |path|
            absolute = File.join(workspace, path)
            next unless File.basename(path) == ".DS_Store" && (File.exist?(absolute) || File.symlink?(absolute)) && IncidentalMetadata.file?(absolute)
            git!(workspace, "--literal-pathspecs", "add", "-f", "--", path, env: env)
          end
          names = git!(workspace, "diff", "--cached", "--name-status", "-z", "--no-renames", sha, env: env, strip: false).split("\0")
          inventory = names.each_slice(2).map { |status, path| { "status" => status, "path" => path } }
          raise InvalidState, "checkpoint: malformed changed-file inventory" unless
            inventory.all? { |row| %w[A M D T].include?(row["status"]) &&
              row["path"] && !row["path"].empty? && !row["path"].start_with?("../", "/") }
          inventory.reject! do |entry|
            path = entry.fetch("path")
            next false unless entry.fetch("status") == "A" && !preserved_paths.include?(path) &&
              IncidentalMetadata.untracked?(workspace, path) { |*args| git!(workspace, *args, strip: false) }
            git!(workspace, "update-index", "--force-remove", "--", path, env: env)
            true
          end
          inventory.each do |entry|
            next if entry.fetch("status") == "D"
            path = File.join(workspace, entry.fetch("path"))
            raise InvalidState, "checkpoint: symlinked/foreign changed file" unless File.file?(path) && !File.symlink?(path)
          end
          patch = git!(workspace, "diff", "--cached", "--binary", "--full-index",
                       "--no-ext-diff", "--no-renames", sha, env: env, strip: false)
          [patch.b, inventory]
        end
      end
    end

    def verify_patch!(path, bytes, inventory, source, base)
      raise InvalidState, "checkpoint: empty or altered artifact" if bytes.empty? || checked_file!(path) != bytes
      source ||= base.fetch("path")
      source_identity!(source, base)
      Dir.mktmpdir("act-checkpoint-verify-") do |root|
        # macOS may spell the system temporary root through /var. Canonicalize
        # this ACT-created directory before applying strict ancestor checks.
        clean = File.join(File.realpath(root), "clean")
        # Temporary applicability check can borrow immutable Git objects; the
        # durable patch remains independent of this disposable reconstruction.
        git!(nil, "clone", "--shared", "--no-checkout", "--", source, clean)
        git!(clean, "checkout", "--detach", base.fetch("pushed_sha"))
        git!(clean, "apply", "--check", "--binary", path)
        git!(clean, "apply", "--binary", path)
        actual, actual_inventory = implementation(clean, base.fetch("pushed_sha"), preserved_paths: inventory.map { |entry| entry.fetch("path") })
        raise InvalidState, "checkpoint: incomplete or inapplicable artifact" unless
          actual == bytes && actual_inventory == inventory
      end
    end

    def write_once!(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.open(File.dirname(path)) { |directory| directory.fsync }
    end

    def atomic!(path, bytes)
      temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
      write_once!(temporary, bytes)
      File.rename(temporary, path)
      File.open(File.dirname(path)) { |directory| directory.fsync }
    end

    def save_state!(id, state)
      path = @states.state_path(id)
      raise InvalidState, "checkpoint: symlinked task state" if File.symlink?(path)
      atomic!(path, YAML.dump(state))
    end

    def git!(dir, *args, env: {}, strip: true)
      out, err, status = @transport.call(["git", *args], cwd: dir, env: env)
      raise InvalidState, "checkpoint: git #{args.first} failed: #{err.strip}" unless status.success?
      strip ? out.strip : out
    end
  end
end
