# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/native_pilot_processes"
require_relative "feedback_runtime"
require_relative "../lib/agent_coding_tool/native_pilot_executor"

# Production budget/supervisor tests with an explicit deterministic sandbox and
# inference substitute. Native confinement and real model continuity are host gates.
class NativePilotExecutorTest < Minitest::Test
  include TestHelpers
  EXECUTOR = AgentCodingTool::NativePilotExecutor

  # Builds one fresh private pilot with only fixed harmless commands. Role
  # substitutions happen before any native sandbox attempt, never as a retry.
  def fixture(mode: "binary", seconds: 10, turn: 2)
    Dir.mktmpdir do |temporary|
      root = File.realpath(temporary)
      directory = File.join(root, "control")
      Dir.mkdir(directory, 0o700)
      workspace = File.join(root, "worktrees", "T", "repo")
      FileUtils.mkdir_p(workspace)
      profile = File.join(root, "modeled.sb")
      File.write(profile, "deterministic sandbox boundary; never sent to sandbox-exec")
      ruby = File.realpath(RbConfig.ruby)
      @config = { "executable" => ruby, "pins" => { profile => Digest::SHA256.file(profile).hexdigest, ruby => Digest::SHA256.file(ruby).hexdigest },
        "profiles" => %w[manager worker gate].to_h { |role| [role, profile] },
        "environments" => %w[manager worker gate].to_h { |role| [role, { "PATH" => "/usr/bin:/bin" }] },
        "manager_cwd" => workspace, "worktree_root" => File.join(root, "worktrees"), "run_root" => File.join(root, "runs"),
        "worker_home" => root, "gate_argv" => [ruby, mode], "turn_seconds" => turn, "gate_seconds" => turn,
        "inference_prefixes" => { "manager" => [ruby, mode], "worker" => [ruby, mode] } }
      NativePilotProcesses.with_boundary do
        executor = EXECUTOR.create(directory, @config, seconds: seconds)
        begin
          yield executor, directory, workspace, profile
        ensure
          preserve_native_receipt(directory)
        end
      end
    end
  end

  # Preserves private focused claims before fixture cleanup. Full control JSON
  # and bounded stream prefixes retain failure facts without unbounded evidence.
  def preserve_native_receipt(directory)
    destination = ENV["ACT_WAC04_NATIVE_EVIDENCE"]
    return unless destination
    stat = File.stat(destination)
    raise "unsafe evidence directory" unless File.realpath(destination) == destination && stat.uid == Process.uid && (stat.mode & 0o077).zero?
    @receipt_number = (@receipt_number || 0) + 1
    files = Dir.children(directory).sort.filter_map do |name|
      path = File.join(directory, name)
      next unless File.file?(path) && !File.symlink?(path)
      bytes = File.binread(path)
      limit = name.end_with?(".json") ? 1024 * 1024 : 4096
      spec = { "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes), "base64" => [bytes.byteslice(0, limit)].pack("m0"), "prefix_only" => bytes.bytesize > limit }
      if name.end_with?(".stdout", ".stderr")
        retained = "#{self.name}-#{@receipt_number}-#{name}.bin"
        File.write(File.join(destination, retained), bytes, mode: "wx", perm: 0o600)
        spec["complete_capture"] = retained
      end
      [name, spec]
    end.to_h
    File.write(File.join(destination, "#{self.name}-#{@receipt_number}.json"), JSON.generate("scope" => "production supervision; sandbox/boot/inference observations modeled", "files" => files), mode: "wx", perm: 0o600)
  end

  # Reads inert durable native control facts without interpreting model output.
  def read(directory, name = "ledger.json")
    JSON.parse(File.binread(File.join(directory, name)))
  end

  # Binary stdout/stderr and nonzero target status survive the production fork,
  # independent supervisor and reaping boundary; retry is durably over budget.
  def test_native_binary_status_and_gate_budget_survive_restart
    fixture do |executor, directory, workspace, _profile|
      result = executor.capture("gate", @config.fetch("gate_argv"), input: "", cwd: workspace)
      assert_equal "checked\x00\xff".b, result.stdout
      assert_equal "diagnostic\x00\xfe".b, result.stderr
      assert_equal 7, result.exitstatus
      assert_equal 21, read(directory).fetch("bytes")
      restarted = EXECUTOR.new(directory)
      assert_raises(AgentCodingTool::InvalidState) { restarted.capture("gate", @config.fetch("gate_argv"), input: "", cwd: workspace) }
      assert_equal 1, read(directory).fetch("counts").fetch("gate")
      assert_nil read(directory)["active"]
    end
  end

  # Failed/expired turns consume capacity; expired enclosing leases cannot be
  # renewed by object reconstruction or replacement of the mutable wall clock.
  def test_independent_turn_expiry_and_absolute_lease
    fixture(mode: "sleep", turn: 0.1) do |executor, directory, workspace, _profile|
      error = assert_raises(AgentCodingTool::InvalidState) { executor.capture("gate", @config.fetch("gate_argv"), input: "", cwd: workspace) }
      assert_includes error.message, "expired"
      assert read(directory)["held"]
      started = read(directory, File.basename(Dir.glob(File.join(directory, "*.started.json")).fetch(0)))
      assert_nil FeedbackRuntime.identity(started.fetch("child"))
      assert_raises(AgentCodingTool::InvalidState) { EXECUTOR.new(directory).capture("gate", @config.fetch("gate_argv"), input: "", cwd: workspace) }
    end
    fixture(mode: "empty", seconds: 0.05) do |_executor, directory, _workspace, _profile|
      sleep 0.06
      assert_raises(AgentCodingTool::InvalidState) { EXECUTOR.new(directory) }
      assert_equal 0, read(directory).fetch("counts").fetch("gate")
    end
  end

  # Two manager invocations share a 4MiB output ceiling across restart. Bounded
  # prefixes and actual termination remain retained and all later effects hold.
  def test_cumulative_output_and_two_turn_admission
    fixture(mode: "emit") do |executor, directory, _workspace, _profile|
      adapter = executor.manager_adapter
      first = adapter.call(session: nil, prompt: "inert")
      assert_equal 2 * 1024 * 1024 + 1, first.fetch("stdout_base64").unpack1("m0").bytesize
      restarted = EXECUTOR.new(directory)
      assert_raises(AgentCodingTool::InvalidState) { restarted.manager_adapter.call(session: "saved-session", prompt: "inert") }
      assert_equal EXECUTOR::OUTPUT_LIMIT, read(directory).fetch("bytes")
      assert_equal 2, read(directory).fetch("counts").fetch("manager")
      assert read(directory)["held"]
      outputs = Dir.glob(File.join(directory, "*.stdout"))
      assert_equal EXECUTOR::OUTPUT_LIMIT, outputs.sum { |path| File.size(path) }
      assert_raises(AgentCodingTool::InvalidState) { restarted.manager_adapter.call(session: "saved-session", prompt: "inert") }
    end
    fixture(mode: "empty") do |executor, directory, _workspace, _profile|
      2.times { executor.manager_adapter.call(session: nil, prompt: "inert") }
      assert_raises(AgentCodingTool::InvalidState) { EXECUTOR.new(directory).manager_adapter.call(session: nil, prompt: "inert") }
      assert_equal 2, read(directory).fetch("counts").fetch("manager")
    end
  end

  # An independently running turn cannot outlive the shorter enclosing lease;
  # worker admission also consumes its sole slot across executor reconstruction.
  def test_active_enclosing_expiry_worker_limit_and_declared_caps
    fixture(mode: "sleep", seconds: 0.15, turn: 2) do |executor, directory, workspace, _profile|
      assert_raises(AgentCodingTool::InvalidState) { executor.capture("gate", @config.fetch("gate_argv"), input: "", cwd: workspace) }
      assert_includes read(directory).fetch("held"), "expired"
      result = read(directory, File.basename(Dir.glob(File.join(directory, "*.started.json")).fetch(0)).sub(".started.json", ".json"))
      refute result.fetch("lease_overrun")
      assert_operator result.fetch("stopped_monotonic"), :<=, read(directory, "config.json").fetch("monotonic_deadline")
    end
    fixture(mode: "empty") do |executor, directory, workspace, _profile|
      worker = [@config.fetch("executable"), "exec", "--sandbox", "workspace-write", "-"]
      assert executor.capture("worker", worker, input: "", cwd: workspace).success?
      assert_raises(AgentCodingTool::InvalidState) { EXECUTOR.new(directory).capture("worker", worker, input: "", cwd: workspace) }
      assert_equal 1, read(directory).fetch("counts").fetch("worker")
      assert_raises(AgentCodingTool::InvalidState) { EXECUTOR.create(directory, @config, seconds: 901) }
      assert_raises(AgentCodingTool::InvalidState) { EXECUTOR.create(directory, @config.merge("turn_seconds" => 301)) }
      assert_raises(AgentCodingTool::InvalidState) { EXECUTOR.create(directory, @config.merge("gate_seconds" => 121)) }
    end
  end

  # A reviewed controller dies immediately after spawn. The supervisor still
  # stops/reaps its child, writes a hold and never signals the test/host group.
  def test_controller_death_owned_teardown_and_concurrent_resume
    fixture(mode: "sleep") do |_executor, directory, workspace, _profile|
      stdout = File.open(File.join(directory, "controller.stdout"), "wx", 0o600)
      stderr = File.open(File.join(directory, "controller.stderr"), "wx", 0o600)
      approval = ChildProcesses.permit("native_pilot_controller", arguments: [directory], options: { pgroup: true })
      controller = NoGitExecution.with_permit(approval) { Process.spawn(approval.environment, *approval.argv, **approval.options, out: stdout, err: stderr) }
      stdout.close
      stderr.close
      begin
        started = nil
        deadline = EXECUTOR.clock + 2
        until started
          started = Dir.glob(File.join(directory, "*.started.json")).first
          raise "missing native spawn handoff" if EXECUTOR.clock >= deadline
          sleep 0.005 unless started
        end
        ownership = read(directory, File.basename(started))
        assert_equal controller, ownership.fetch("controller")
        assert_raises(AgentCodingTool::InvalidState) { EXECUTOR.new(directory).capture("gate", @config.fetch("gate_argv"), input: "", cwd: workspace) }
        Process.kill("KILL", controller)
        Process.waitpid(controller)
        controller = nil
        result = started.sub(".started.json", ".json")
        until File.exist?(result)
          raise "death teardown did not finish" if EXECUTOR.clock >= deadline
          sleep 0.005
        end
        while read(directory)["active"]
          raise "native hold did not become durable" if EXECUTOR.clock >= deadline
          sleep 0.005
        end
        assert_includes read(directory, File.basename(result)).fetch("failure"), "controller died"
        assert_nil FeedbackRuntime.identity(ownership.fetch("child"))
        assert_equal 1, read(directory).fetch("counts").fetch("gate")
        assert_raises(AgentCodingTool::InvalidState) { EXECUTOR.new(directory).capture("gate", @config.fetch("gate_argv"), input: "", cwd: workspace) }
      ensure
        if controller
          Process.kill("KILL", controller) rescue Errno::ESRCH
          Process.waitpid(controller) rescue Errno::ECHILD
        end
      end
    end
  end

  # Changed executable/profile/config, symlinked ledger, foreign gate and an
  # occupied pilot all refuse; none may silently replace the original budget.
  def test_pins_paths_commands_and_occupied_control_refuse
    fixture(mode: "empty") do |executor, directory, workspace, profile|
      assert_raises(AgentCodingTool::InvalidState) { executor.capture("gate", ["/usr/bin/true"], input: "", cwd: workspace) }
      assert_equal 0, read(directory).fetch("counts").fetch("gate")
      assert_raises(Errno::EEXIST) { EXECUTOR.create(directory, @config) }
      File.write(profile, "changed")
      assert_raises(AgentCodingTool::InvalidState) { EXECUTOR.new(directory) }
    end
    fixture(mode: "empty") do |executor, directory, workspace, _profile|
      File.rename(File.join(directory, "ledger.json"), File.join(directory, "prior.json"))
      File.symlink(File.join(directory, "prior.json"), File.join(directory, "ledger.json"))
      assert_raises(Errno::ELOOP) { executor.capture("gate", @config.fetch("gate_argv"), input: "", cwd: workspace) }
    end
  end
end
