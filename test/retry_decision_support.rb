# frozen_string_literal: true

require_relative "recovery_observations"

# Minimal recovery input with native Git ownership. This is not a launcher or
# sandbox fixture; the retained cold child-start journey checks its report shape.
module RetryDecisionSupport
  include RecoveryObservations

  # Returns the recovery fields of a reserved child-start failure, using original
  # preparation/execution states and an actually created inventory. No worker is
  # claimed. Callers persist prompt/report bytes; missing input keys raise.
  def retry_failure_report(preparation:, execution:, inventory:, directory:, invocation:, host_pid:, host_identity:)
    prompt = File.binread(File.join(directory, "prompt.txt"))
    { "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "T", "attempt" => 1,
      "invocation_id" => invocation, "status" => "child_start_failed", "host_pid" => host_pid,
      "host_identity" => host_identity, "prepared_at" => preparation.fetch("prepared_at"),
      "preparation" => preparation.fetch("snapshot"), "preparation_state" => preparation,
      "execution_state" => execution, "worktree_layout" => "attempt", "worktree_creation" => "inventory_persisted",
      "worktrees_path" => File.join(directory, "worktrees.json"), "worktrees" => inventory,
      "workspace" => inventory.fetch("entries").find { |entry| entry.fetch("access") == "write" }.fetch("path"),
      "prompt_sha256" => Digest::SHA256.hexdigest(prompt), "prompt_bytes" => prompt.bytesize }
  end

  # Independently checks the minimal input against a real cold launch producer.
  # Every recovery field must agree with the producer's independently read bytes.
  # Assertion failures expose producer/schema drift instead of blessing fixtures.
  def assert_retry_failure_report(report)
    expected = retry_failure_report(preparation: report.fetch("preparation_state"), execution: report.fetch("execution_state"),
      inventory: report.fetch("worktrees"), directory: File.dirname(report.fetch("worktrees_path")),
      invocation: report.fetch("invocation_id"), host_pid: report.fetch("host_pid"), host_identity: report.fetch("host_identity"))
    expected.each do |key, value|
      assert_equal value, report.fetch(key), key
    end
  end

  # Yields real prepared/started lifecycle, native writer/reader worktrees, private
  # prompt/report/lock files and a reaped host PID. Host boot identity is declared
  # as in the cold journey; lsof uses an exact finite transcript at capture3.
  # The caller declares the number of full liveness checks; under/overconsumption
  # fails. Setup and teardown are included in costs;
  # native Git failures raise, and all writes stay in this disposable world.
  def with_retry_decision(liveness_checks:)
    Dir.mktmpdir("act-retry-decision-") do |temporary|
      @decision_root = File.realpath(temporary)
      @decision_data = File.join(@decision_root, "data")
      FileUtils.mkdir_p(File.join(@decision_data, "tasks"))
      seed = TestHelpers.git_seed
      repositories = %w[writer reader].to_h do |name|
        parent = File.join(@decision_root, name)
        remote = File.join(@decision_root, "#{name}.git")
        FileUtils.cp_r(File.join(seed.fetch(:root), "ordinary"), parent)
        FileUtils.cp_r(File.join(seed.fetch(:root), "remote.git"), remote)
        output, error, status = Open3.capture3("git", "remote", "set-url", "origin", remote, chdir: parent)
        raise "retry fixture remote: #{output}#{error}" unless status.success?
        [name, { "path" => parent, "access" => name == "writer" ? "write" : "read_only" }]
      end
      write_task(@decision_data, id: "T", repositories: repositories)
      visible = File.join(@decision_root, "worktrees")
      File.write(File.join(@decision_data, "config.yml"), YAML.dump("repo_root" => @decision_root, "worktree_root" => visible))
      @decision_states = AgentCodingTool::StateStore.new(File.join(@decision_data, "state"))
      @decision_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: @decision_data, out: StringIO.new, err: StringIO.new)
      @decision_coordinator = @decision_cli.send(:coordinator)
      prepared = @decision_coordinator.prepare("T")
      @decision_directory = File.join("#{@decision_data}-runs", "T", "decision")
      FileUtils.mkdir_p(@decision_directory, mode: 0o700)
      File.binwrite(File.join(@decision_directory, "prompt.txt"), prepared.fetch("prompt"))
      inventory = AgentCodingTool::WorktreeManager.new(root: visible, record_path: File.join(@decision_directory, "worktrees.json"),
        attempt_paths: true, invocation_id: "retry-decision").create(task_id: "T", attempt: 1,
          task: prepared.fetch("task"), snapshot: prepared.fetch("state").fetch("snapshot"))
      @decision_coordinator.start("T")
      report = retry_failure_report(preparation: prepared.fetch("state"), execution: @decision_states.load("T"),
        inventory: inventory, directory: @decision_directory, invocation: "retry-decision",
        host_pid: RecoveryObservations.status(0).pid, host_identity: { "fixture_boot" => "deterministic external identity" })
      File.write(File.join(@decision_directory, "handoff.json"), JSON.generate(report))
      observations = inventory.fetch("entries").map do |entry|
        recovery_observation(nil, "lsof", "-n", "-P", "+D", entry.fetch("path"), exit_code: 1)
      end
      lsof = GitContract::Replay.new(observations * liveness_checks)
      @decision_liveness = AgentCodingTool::RetryLiveness.new(capture: lsof)
      begin
        AgentCodingTool::RetryLiveness.stub(:host_identity, report.fetch("host_identity")) do
          yield AgentCodingTool::AttemptRecovery.new(data_root: @decision_data, liveness: @decision_liveness), report
        end
      ensure
        assert lsof.verify!
      end
    end
  end

  # Returns all substantive fixture file bytes and permission bits, including
  # native administration and private evidence. Symlinks are never followed.
  def retry_decision_bytes
    Dir.glob(File.join(@decision_root, "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) && !File.symlink?(path) }
       .to_h { |path| [path, [File.binread(path), File.stat(path).mode & 0o777]] }
  end
end
