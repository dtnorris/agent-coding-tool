# frozen_string_literal: true

# Standalone component gate: guards apply before dependencies, helper and product.
# This fixed inventory is additive; full-suite migration remains with TST-45.
require_relative "../no_git_execution"
require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "stringio"
require_relative "../../test_helper"
require_relative "broker"
require_relative "../child_processes"
require_relative "../source_identity"
require_relative "../../launcher_support"
require_relative "../../manual_overlap_support"
require_relative "../../apply_handoff_support"
require_relative "../../apply_handoff_observations"
require_relative "../../retry_decision_support"
require_relative "../../publisher_observations"
require_relative "../../skill_observations"
require_relative "../../feedback_coverage"
Minitest::Assertions.diff = nil

# Shared launcher/manual-overlap fixtures retain actual production decisions.
class SharedLauncherAdapterVerifier < Minitest::Test
  include TestHelpers
  include LauncherSupport
  include ManualOverlapSupport

  # Memory setup, real inspection/worktree ownership and exact preflight replay
  # compose without native Git or per-preflight process creation.
  def test_launcher_and_manual_preflight_adapter_contract
    fixture(git: true) do
      before = NoGitExecution.audit
      prepared = @coordinator.prepare("T")
      assert_equal @base, prepared.fetch("state").fetch("snapshot").fetch("repo").fetch("pushed_sha")
      instance = launcher
      with_manual_preflight { instance.send(:preflight_codex!, nil, nil) }
      assert_raises(GitContract::UnexpectedObservation) { with_manual_preflight {} }
      12.times do
        out, err = StringIO.new, StringIO.new
        assert_equal 0, AgentCodingTool::CLI.run(%w[status T], root: @root, data_root: @data, out: out, err: err)
        assert_includes out.string, "PREPARED"
      end
      manager = AgentCodingTool::WorktreeManager.new(root: File.join(@root, "owned"), record_path: File.join(@root, "inventory.json"))
      inventory = manager.create(task_id: "T", attempt: 1, task: prepared.fetch("task"), snapshot: prepared.fetch("state").fetch("snapshot"))
      assert manager.inspect!
      assert_equal "base\n", File.binread(File.join(inventory.fetch("entries").first.fetch("path"), "file.txt"))
      assert_equal before, NoGitExecution.audit
    end
  end

  # The shared manual writer still supplies an actual live PID and native reaping;
  # its release/deadline cleanup preserves a changed candidate independently.
  def test_manual_worker_ready_release_and_lease
    fixture(git: true, process: true) do
      path = File.join(@root, "external")
      with_manual_worker(path, lease: 2) do |worker|
        assert_manual_worker_active(worker)
        assert_equal "external work", File.binread(path)
      end
      assert_equal "external work", File.binread(path)
    end
  end

  # Real launch orchestration still owns streams, locks, reservation and reaping.
  # Only Git and Codex capability responses are adapted; the worker is an actual
  # guarded Ruby child and its file mutation remains visible to parent inspection.
  def test_launcher_real_worker_boundary_and_reaped_status
    fixture(git: true, process: true) do
      @coordinator.prepare("T")
      assert_equal 0, launcher.launch("T"), @err.string
      report_path = Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)
      report = JSON.parse(File.binread(report_path))
      assert_equal "exited", report.fetch("status")
      assert_equal 0, report.fetch("exit_status")
      assert_raises(Errno::ECHILD) { Process.waitpid(report.fetch("child_pid"), Process::WNOHANG) }
      assert_equal "worker", File.binread(File.join(report.fetch("workspace"), "worker-change.txt"))
      assert_includes @out.string, "Final worker response"
      assert @store.load("T")["started_at"]
    end
  end
end

# Apply-family fixture conversion retains staged/unstaged/ignored physical state.
class SharedApplyAdapterVerifier < Minitest::Test
  include ApplyHandoffFixtures

  # Both ordinary authorities are fresh; raw byte/mode snapshots remain outside
  # model getters. Unknown setup cannot launch a process or invent success.
  def test_apply_fixture_dirty_state_copy_and_config_adapters
    fixture(nonportable: true) do
      before = NoGitExecution.audit
      assert_equal "base\n", File.binread(File.join(@a, "file.txt"))
      dirty_repositories
      assert_equal "staged version\n", git(@a, "show", ":file.txt")
      assert_equal "different worktree version\n", File.binread(File.join(@a, "file.txt"))
      assert_equal 0o755, File.stat(File.join(@a, "file.txt")).mode & 0o777
      assert_equal "ignored\0\xfe".b, File.binread(File.join(@a, IGNORED_PATH))
      refute_includes git(@a, "status", "--porcelain=v1", "-z", "--untracked-files=all"), IGNORED_PATH.b
      copy = @memory_world.copy(@apply_checkouts.fetch(@a), path: "copy")
      @memory_world.configure(copy, "remote.origin.url", "separate-upstream")
      assert_equal "separate-upstream\n", git(copy.path, "remote", "get-url", "origin")
      assert_equal "#{@a}.git\n", git(@a, "remote", "get-url", "origin")
      assert_raises(MemoryGit::Mismatch) { git(@a, "unknown-operation") }
      assert_equal before, NoGitExecution.audit
    end
  end

  # Existing exact apply transport preserves byte/status fields and detects an
  # omitted request without a dummy status process or loose boolean translation.
  def test_apply_observation_protocol_and_missing_handoff
    response = AgentCodingTool::CommandResult.new(stdout: "\0\xff".b, stderr: "\xfe".b, termsig: 15)
    record = { argv: %w[git apply], cwd: "/case", env: {}, input: "patch\0\xff".b, pgroup: true, result: response }
    replay = ApplyHandoffObservations::Transport.new([record])
    assert_raises(GitContract::UnexpectedObservation) { replay.verify! }
    assert_same response, replay.call(record.fetch(:argv), **record.slice(:cwd, :env, :input, :pgroup))
    assert replay.verify!
    assert_raises(GitContract::UnexpectedObservation) { replay.call(%w[git apply], **record.slice(:cwd, :env, :input, :pgroup)) }
  end
end

# Recovery's genuine liveness PID stays distinct from modeled command facts.
class SharedRecoveryAdapterVerifier < Minitest::Test
  include TestHelpers
  include RetryDecisionSupport

  # Real production worktree creation and recovery report agree on shared fields;
  # the PID was actually reaped. Modeled lsof failures require no extra process.
  def test_retry_fixture_and_genuine_reaped_pid
    before = NoGitExecution.audit.count { |row| row["decision"] == "ALLOW" }
    with_retry_decision(liveness_checks: 0) do |_recovery, report|
      assert_retry_failure_report(report)
      assert_raises(Errno::ECHILD) { Process.waitpid(report.fetch("host_pid"), Process::WNOHANG) }
      assert_equal 2, report.fetch("worktrees").fetch("entries").length
      response = recovery_observation(nil, "lsof", "-n", exit_code: 1)
      assert_instance_of AgentCodingTool::CommandResult, response.status
      assert_equal 1, response.capture3.last.exitstatus
      assert_equal before + 1, NoGitExecution.audit.count { |row| row["decision"] == "ALLOW" }
    end
  end

  # Generic replay preserves genuine and modeled signal/nonzero/binary outcomes;
  # boolean-only legacy observations still cannot claim raw termination facts.
  def test_replay_result_bytes_exit_signal_and_exception_adaptation
    [AgentCodingTool::CommandResult.new(stdout: "\0\xff".b, stderr: "\xfe".b, exitstatus: 7),
     AgentCodingTool::CommandResult.new(stdout: "", stderr: "", termsig: 15)].each do |result|
      observation = GitContract::Observation.new(argv: %w[git exact], cwd: "/case", result: result.to_ary)
      replay = GitContract::Replay.new([observation])
      assert_raises(GitContract::UnexpectedObservation) { replay.capture3("git", "wrong", chdir: "/case") }
      assert_same result, replay.capture3("git", "exact", chdir: "/case").last
      assert replay.verify!
      result.signaled? ? assert_nil(observation.capture.last) : assert_equal(result.success?, observation.capture.last)
      transport_record = GitContract::Observation.new(argv: [{ "GIT_PAGER" => "cat" }, "git", "exact"], cwd: "/case",
        stdin_data: "\0\xfe".b, result: result.to_ary, timeout: 0.5, options: { pgroup: true })
      transport = GitContract::Replay.new([transport_record])
      fields = { cwd: "/case", env: { "GIT_PAGER" => "cat" }, input: "\0\xfe".b, timeout: 0.5, pgroup: true }
      assert_raises(GitContract::UnexpectedObservation) { transport.call(%w[git exact], **fields.merge(timeout: nil)) }
      adapted = transport.call(%w[git exact], **fields)
      assert_equal [result.stdout, result.stderr, result.exitstatus, result.termsig], [adapted.stdout, adapted.stderr, adapted.exitstatus, adapted.termsig]
      assert transport.verify!
    end
    exception = Errno::ENOENT.new("declared absent source")
    observation = GitContract::Observation.new(argv: %w[git absent], cwd: nil, exception: exception)
    assert_same exception, assert_raises(Errno::ENOENT) { observation.capture3 }
    boolean = GitContract::Observation.new(argv: %w[git exact], cwd: nil, result: ["", "", true])
    assert_raises(ArgumentError) { boolean.capture3 }
  end
end

# Immutable source and publisher observations use the common result contract.
class SharedSourceAdapterVerifier < Minitest::Test
  include PublisherObservations

  # Default source snapshots remain read-only and hash-checked by real rendering;
  # changed requests/refusals cannot fall back to a live source checkout.
  def test_skill_snapshot_and_finite_source_observations
    before = NoGitExecution.audit
    renderer = AgentCodingTool::PromptRenderer
    task = { "id" => "T", "title" => "Shared source", "repositories" => {}, "planning_guidance" => "required" }
    prompt = renderer.new.render(task, {})
    assert_includes prompt, CodingSkillSupport::TEXT
    assert_includes prompt, CodingSkillSupport::PLANNING_TEXT
    reads = SkillObservations.defaults(%w[coding planning])
    repeated = renderer.new(runner: reads).render(task, {})
    assert_equal prompt, repeated
    assert reads.verify!
    assert_raises(MemoryGit::Mismatch) { MemoryGit::Session.skill_transport.call(%w[git status]) }
    assert_equal before, NoGitExecution.audit
  end

  # Publisher's shared transcript supplies real result facts to capture3 and the
  # same boolean protocol to CommandRunner, without an executable/status factory.
  def test_publisher_observation_result_and_consumption
    @root = "/case"
    observation = git_observation(%w[rev-parse HEAD], "#{BASE}\n")
    assert_instance_of AgentCodingTool::CommandResult, observation.status
    replay = GitContract::Replay.new([observation])
    assert_equal ["#{BASE}\n".b, "".b, true], replay.capture("git", "rev-parse", "HEAD", chdir: @root)
    assert replay.verify!
    assert_raises(GitContract::UnexpectedObservation) { replay.capture("git", "rev-parse", "HEAD", chdir: @root) }
    failed = git_observation(%w[push origin], "", stderr: "lease refused", success: false)
    assert_equal 1, failed.capture3.last.exitstatus
  end
end
