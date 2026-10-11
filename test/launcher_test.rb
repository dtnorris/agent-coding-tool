# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "rbconfig"
require "timeout"
require_relative "launcher_support"

class LauncherTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  def report
    JSON.parse(File.read(Dir.glob("#{@data}-runs/T/*/handoff.json").last))
  end

  def git(*args, chdir: nil)
    stdout, stderr, status = Open3.capture3("git", *args, **(chdir ? { chdir: chdir } : {}))
    assert status.success?, stderr
    stdout.strip
  end

  def assert_preflight_failure(pattern)
    old_pid = File.exist?(File.join(@root, "worker-pid")) ? File.read(File.join(@root, "worker-pid")) : nil
    error = assert_raises(AgentCodingTool::Error) { launcher.launch("T") }
    assert_match pattern, error.message
    refute @store.load("T")["started_at"]
    current_pid = File.exist?(File.join(@root, "worker-pid")) ? File.read(File.join(@root, "worker-pid")) : nil
    old_pid ? assert_equal(old_pid, current_pid) : assert_nil(current_pid)
  end

  def test_launch_binds_pushed_base_independent_of_dirty_divergent_ordinary_checkout
    fixture(git: true, process: true) do
      File.write(File.join(@ordinary, "file.txt"), "local\n")
      git("commit", "-am", "local divergent", chdir: @ordinary)
      File.write(File.join(@ordinary, "untracked"), "untouched")
      before = git("status", "--porcelain", chdir: @ordinary)
      assert_equal 0, launcher.launch("T", model: "explicit-model", reasoning: "high")
      state = @store.load("T")
      assert state["started_at"]
      refute state["result"]
      evidence = report
      worker = JSON.parse(File.read(File.join(@root, 'worker-process')))
      assert_equal evidence.fetch('child_pid'), worker.fetch('pid')
      assert_equal Process.pid, worker.fetch('parent')
      assert_equal worker.fetch('pid'), worker.fetch('group')
      assert_equal evidence.fetch('workspace'), worker.fetch('cwd')
      assert_equal @base, git("rev-parse", "HEAD", chdir: evidence.fetch("workspace"))
      assert_equal @remote, git("remote", "get-url", "origin", chdir: evidence.fetch("workspace"))
      assert_equal before, git("status", "--porcelain", chdir: @ordinary)
      prompt = File.binread(state.fetch("prompt_path"))
      consumed = File.binread(File.join(@root, "stdin"))
      assert consumed.start_with?(prompt + "\n\n--- ACT LOCAL CLI EXECUTION ENVELOPE ---")
      assert_includes consumed, "no ChatGPT connected GitHub integration"
      assert_includes consumed, "not a CLI refresh"
      assert_includes @out.string, "progress"
      assert_includes @err.string, "stderr progress"
      assert_equal "Final worker response", File.read(evidence.fetch("final_path"))
      assert_equal "fixture-session", evidence.fetch("session_id")
      assert_nil evidence.fetch("session_transcript_path")
      assert_equal "exited", evidence.fetch("status")
      assert_equal 0, evidence.fetch("exit_status")
      assert evidence.fetch("final_valid")
      assert_equal @base, evidence.fetch("launch_heads").fetch("repo").fetch("pushed_sha")
      assert_equal @remote, evidence.fetch("writable_authority").fetch("remote_url")
      assert_equal 5, evidence.fetch("artifacts").length
      evidence.fetch("artifacts").each do |artifact|
        assert_equal Digest::SHA256.file(artifact.fetch("path")).hexdigest, artifact.fetch("sha256")
      end
      args = JSON.parse(File.read(File.join(@root, "argv")))
      assert_equal ['exec', '--ignore-user-config', '--ignore-rules', '--sandbox', 'workspace-write'], args.first(5)
      %w[approval_policy=never forced_login_method="chatgpt" model_provider="openai" sandbox_workspace_write.network_access=false features.multi_agent=false].each { |arg| assert_includes args, arg }
      assert_equal '-', args.last
      assert_includes args, 'model_reasoning_effort=high'
      refute JSON.parse(File.read(File.join(@root, 'envkeys'))).include?('OPENAI_API_KEY')
      assert_equal "IN_FLIGHT", @coordinator.status("T").fetch("status")
      assert_raises(AgentCodingTool::InvalidState) { launcher.launch("T") }
    end
  end

  def test_prepared_prompt_is_consumed_without_reprepare_and_recommendation_is_advisory
    fixture do
      task_path = File.join(@data, "tasks", "T.yml")
      task = YAML.safe_load_file(task_path)
      task['worker_recommendation'] = { 'model' => 'Human UI Model', 'thinking' => 'ultra' }
      File.write(task_path, YAML.dump(task))
      prepared = @coordinator.prepare('T').fetch('state')
      prompt = File.binread(prepared.fetch('prompt_path'))
      @coordinator.define_singleton_method(:prepare) { |*| raise 'unexpected reprepare' }
      assert_equal 0, launcher.launch('T')
      assert_equal prepared['prepared_at'], @store.load('T')['prepared_at']
      assert_equal prompt, File.binread(report.fetch('prompt_path'))
      assert File.binread(report.fetch('stdin_path')).start_with?(prompt + "\n\n--- ACT LOCAL CLI EXECUTION ENVELOPE ---")
      refute JSON.parse(File.read(File.join(@root, 'argv'))).include?('--model')
    end
  end

  def test_dependency_blockers_and_previous_outcomes_do_not_get_erased
    fixture do
      write_task(@data, id: 'D', repositories: { 'repo' => { 'access' => 'read_only', 'path' => @ordinary } })
      task_path = File.join(@data, 'tasks', 'T.yml')
      task = YAML.safe_load_file(task_path)
      task['depends_on'] = ['D']
      File.write(task_path, YAML.dump(task))
      assert_preflight_failure(/dependencies incomplete/)
      @coordinator.record('D', outcome: 'complete')
      @coordinator.prepare('T')
      @coordinator.record('T', outcome: 'needs_judgment', summary: 'keep decision')
      before = File.binread(@store.state_path('T'))
      assert_preflight_failure(/recorded outcome/)
      assert_equal before, File.binread(@store.state_path('T'))
    end
  end

  def test_dependencies_are_rechecked_after_preparation
    fixture do
      write_task(@data, id: 'D', repositories: { 'repo' => { 'access' => 'read_only', 'path' => @ordinary } })
      @coordinator.record('D', outcome: 'complete')
      write_task(@data, id: 'T', depends_on: ['D'], repositories: { 'repo' => { 'access' => 'write', 'path' => @ordinary } })
      @coordinator.prepare('T')
      @coordinator.reset('D')
      assert_preflight_failure(/BLOCKED/)
    end
  end

  def test_stale_input_and_changed_remote_authority_fail_closed
    fixture(git: true) do
      @coordinator.prepare('T')
      File.write(File.join(@ordinary, 'file.txt'), "new\n")
      git('commit', '-am', 'new', chdir: @ordinary)
      git('push', 'origin', 'main', chdir: @ordinary)
      assert_preflight_failure(/STALE/)
    end
    fixture(git: true) do
      @coordinator.prepare('T')
      second = File.join(@root, 'second.git')
      git('clone', '--bare', @remote, second)
      git('remote', 'set-url', 'origin', second, chdir: @ordinary)
      assert_preflight_failure(/authority changed/)
    end
  end

  def test_collision_is_not_implicitly_overridden
    fixture do
      write_task(@data, id: 'OTHER', repositories: { 'alias' => { 'access' => 'write', 'path' => @ordinary } })
      @coordinator.prepare('OTHER')
      @coordinator.start('OTHER')
      assert_preflight_failure(/write collision/)
      refute @store.load('T')['write_collision_override']
    end
  end

  def test_stale_manual_in_flight_reservation_requires_judgment
    fixture do
      write_task(@data, id: 'OTHER', repositories: { 'alias' => { 'access' => 'write', 'path' => @ordinary } })
      @coordinator.prepare('OTHER')
      @coordinator.start('OTHER')
      File.write(File.join(@ordinary, 'file.txt'), 'pushed movement')
      @inspector.heads['repo'] = 'b' * 40
      assert_equal 'STALE', @coordinator.status('OTHER')['status']
      assert_preflight_failure(/unresolved in-flight reservation/)
      assert @store.load('OTHER')['started_at']
    end
  end

  def test_missing_binary_auth_and_unsupported_help_fail_without_preparation
    fixture do
      File.unlink(@fake)
      assert_preflight_failure(/CLI missing/)
      assert_empty @store.load('T')
    end
    ['', 'Logged in using an API key', 'unknown authentication'].each do |auth|
      fixture do
        write_fake(auth: auth)
        assert_preflight_failure(/ChatGPT account required/)
        assert_empty @store.load('T')
      end
    end
    fixture do
      write_fake(help: false)
      assert_preflight_failure(/safe exec flags/)
    end
  end

  def test_zero_multiple_writers_malformed_task_and_unsupported_branch
    [ {}, { 'repo' => { 'access' => 'read_only', 'path' => nil } },
      { 'repo' => { 'access' => 'write' }, 'other' => { 'access' => 'write' } } ].each do |repos|
      fixture do
        write_task(@data, id: 'T', repositories: repos)
        assert_preflight_failure(/non-empty mapping|exactly one writable/)
      end
    end
    fixture do
      File.write(File.join(@data, 'tasks', 'T.yml'), "--- [unterminated")
      assert_preflight_failure(/malformed/)
    end
    fixture do
      @coordinator.prepare('T')
      state = @store.load('T')
      state['snapshot']['repo']['branch'] = 'release'
      @store.write('T', state)
      assert_preflight_failure(/unsupported branch/)
    end
  end

  def test_prompt_tampering_and_missing_freshness
    fixture do
      @coordinator.prepare('T')
      File.write(@store.load('T')['prompt_path'], 'tampered')
      assert_preflight_failure(/prompt changed/)
    end
    fixture do
      @coordinator.prepare('T')
      FileUtils.mv(@remote, "#{@remote}-offline")
      assert_preflight_failure(/cannot resolve pushed/)
    end
  end

  def test_foreign_dirty_partial_or_symlinked_evidence_is_never_repaired
    fixture do
      target = "#{@data}-runs/T/foreign/checkout"
      FileUtils.mkdir_p(target)
      File.chmod(0o700, "#{@data}-runs")
      File.write(File.join(target, 'untracked'), 'keep')
      assert_preflight_failure(/partial\/foreign/)
      assert_equal 'keep', File.read(File.join(target, 'untracked'))
    end
    fixture do
      File.symlink(@ordinary, "#{@data}-runs")
      assert_preflight_failure(/symlinked evidence/)
      assert File.symlink?("#{@data}-runs")
    end
  end

  def test_process_failure_and_invalid_final_preserve_real_exit_and_reservation
    %w[failure missing invalid].each do |mode|
      fixture(process: true) do
        write_fake(mode)
        assert_equal(mode == 'failure' ? 7 : 0, launcher.launch('T'))
        assert @store.load('T')['started_at']
        refute @store.load('T')['result']
        assert_equal(mode == 'failure' ? 'exited' : 'invalid_final', report['status'])
        assert File.file?(report['jsonl_path'])
        assert_includes @err.string, 'missing/invalid final' unless mode == 'failure'
      end
    end
  end

  def test_child_start_failure_retains_recoverable_evidence
    fixture(process: true) do
      failing_spawn = ->(*) { raise Errno::ENOENT, 'simulated child start failure' }
      assert_equal 127, launcher(spawner: failing_spawn).launch('T')
      assert_equal 'child_start_failed', report['status']
      assert @store.load('T')['started_at']
      refute @store.load('T')['result']
      assert File.file?(report['stdin_path'])
      refute File.exist?(File.join(@root, 'worker-pid'))
    end
  end

  def test_ctrl_c_targets_child_group_preserves_status_and_does_not_orphan
    fixture(process: true) do
      write_fake('sleep')
      sender = Thread.new do
        Timeout.timeout(5) { sleep 0.01 until File.exist?(File.join(@root, 'stdin')) }
        Process.kill('INT', Process.pid)
      end
      assert_equal 130, launcher.launch('T')
      sender.value
      assert_equal 'INT', File.read(File.join(@root, 'interrupted'))
      assert_equal 'interrupted', report['status']
      assert_raises(Errno::ESRCH) { Process.kill(0, report['child_pid']) }
      assert @store.load('T')['started_at']
    end
  end

  def test_simulated_host_crash_blocks_relaunch_even_after_manual_prepare_erases_marker
    fixture(process: true) do
      assert_equal 0, launcher.launch('T')
      path = Dir.glob("#{@data}-runs/T/*/handoff.json").last
      evidence = JSON.parse(File.read(path))
      evidence['status'] = 'running'
      evidence['child_pid'] = 99999999
      File.write(path, JSON.generate(evidence))
      @coordinator.prepare('T')
      before = File.binread(path)
      assert_preflight_failure(/liveness unknown/)
      assert_equal before, File.binread(path)
    end
  end

  def test_cli_requires_opt_in_and_rejects_provider_sandbox_and_collision_overrides
    fixture do
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: @data, out: @out, err: @err)
      [%w[launch T], %w[launch T --other], %w[launch T --codex --sandbox danger-full-access],
       %w[launch T --codex --allow-write-collision], %w[launch T --codex --provider api]].each do |args|
        assert_equal 2, cli.run(args)
      end
      refute @store.load('T')['started_at']
      assert_raises(AgentCodingTool::InvalidTask) { launcher.launch('T', reasoning: 'ultra') }
      assert_raises(AgentCodingTool::InvalidTask) { launcher.launch('../T') }
    end
  end

  def test_exit_provenance_exposes_midflight_head_movement_without_rewriting_preparation
    fixture(process: true) do
      @coordinator.prepare('T')
      File.write(File.join(@ordinary, 'file.txt'), 'later pushed version')
      later = 'b' * 40
      spawning = lambda do |*args, **options|
        pid = Process.spawn(*args, **options)
        @inspector.heads['repo'] = later
        pid
      end
      assert_equal 0, launcher(spawner: spawning).launch('T')
      evidence = report
      assert_equal @base, evidence['preparation']['repo']['pushed_sha']
      assert_equal @base, evidence['launch_heads']['repo']['pushed_sha']
      assert_equal later, evidence['exit_heads']['repo']['pushed_sha']
      assert_equal 'stale', evidence['writable_freshness']
      assert_includes @err.string, 'STALE INPUT'
      assert_equal 'STALE', @coordinator.status('T')['status']
      refute @store.load('T')['result']
    end
  end

  def test_exit_freshness_unavailable_is_reported_without_losing_worker_status
    fixture(process: true) do
      spawning = lambda do |*args, **options|
        pid = Process.spawn(*args, **options)
        FileUtils.mv(@remote, "#{@remote}-offline")
        pid
      end
      assert_equal 0, launcher(spawner: spawning).launch('T')
      assert_match(/cannot resolve pushed/, report.fetch('exit_freshness_error'))
      refute report.key?('exit_heads')
      assert @store.load('T')['started_at']
    end
  end

  def test_read_only_movement_preserves_original_snapshot_and_discloses_refreshed_heads
    fixture(process: true) do
      reader = File.join(@root, 'reader.git')
      reader_checkout = File.join(@root, 'reader')
      FileUtils.mkdir_p([reader, reader_checkout])
      @inspector.heads['reader'] = @base
      @inspector.remote_urls['reader'] = reader
      write_task(@data, id: 'T', repositories: {
        'repo' => { 'access' => 'write', 'path' => @ordinary },
        'reader' => { 'access' => 'read_only', 'path' => reader_checkout }
      })
      @coordinator.prepare('T')
      File.write(File.join(@ordinary, 'file.txt'), 'reader later')
      later = @inspector.heads['reader'] = 'b' * 40
      assert_equal 0, launcher.launch('T')
      assert_equal @base, report['preparation']['reader']['pushed_sha']
      assert_equal later, report['launch_heads']['reader']['pushed_sha']
      assert_includes File.read(report['stdin_path']), later
      assert_equal 'IN_FLIGHT', @coordinator.status('T')['status']
    end
  end

  def test_start_gate_failure_never_delivers_prompt_or_starts_child
    fixture do
      @coordinator.define_singleton_method(:start) { |_id| raise AgentCodingTool::InvalidState, 'start gate rejected' }
      assert_preflight_failure(/start gate rejected/)
      assert_equal 'judgment_required', report['status']
      assert File.file?(report['stdin_path'])
      refute File.exist?(File.join(@root, 'stdin'))
    end
  end

  def test_incompatible_snapshot_and_foreign_project_configuration_block_worker
    fixture do
      @coordinator.prepare('T')
      state = @store.load('T')
      state['snapshot']['repo'].delete('remote_url')
      @store.write('T', state)
      assert_preflight_failure(/missing repository identity/)
    end
    fixture(git: true) do
      FileUtils.mkdir_p(File.join(@ordinary, '.codex'))
      File.write(File.join(@ordinary, '.codex', 'config.toml'), 'sandbox_mode="danger-full-access"')
      git('add', '.codex', chdir: @ordinary)
      git('commit', '-m', 'unsafe config', chdir: @ordinary)
      git('push', 'origin', 'main', chdir: @ordinary)
      assert_preflight_failure(/Codex configuration/)
      assert_equal 'preflight_failed', report['status']
    end
  end

  def test_cli_returns_real_nonzero_worker_code_using_fake_path
    fixture(git: true, process: true) do
      write_fake('failure')
      stdout, stderr, status = Open3.capture3(
        { 'PATH' => "#{@root}:#{ENV.fetch('PATH')}", 'AGENT_CODING_TOOL_DATA_DIR' => @data },
        RbConfig.ruby, File.join(Dir.pwd, 'bin', 'agent-coding-tool'), 'launch', 'T', '--codex')
      assert_equal 7, status.exitstatus
      assert_includes stdout, 'progress'
      assert_includes stderr, 'Run evidence:'
      assert_equal 'exited', report['status']
      assert_equal "linux", report.fetch("sandbox_probe").fetch("platform") if RUBY_PLATFORM.include?("linux")
      refute @store.load('T')['result']
    end
  end

  def test_launch_fails_before_reservation_if_sandbox_can_write_private_evidence
    fixture do
      write_fake('leaky')
      error = assert_raises(AgentCodingTool::InvalidState) { launcher(real_sandbox_probe: true).launch("T") }
      assert_includes error.message, "sandbox boundary unverified"
      refute @store.load("T")["started_at"]
      assert_nil report["sandbox_probe"]
      refute File.exist?(File.join(@root, "worker-pid"))
      assert_equal "preflight_failed", report.fetch("status")
    end
  end

  def test_launch_handoff_pins_read_only_dependency_and_probes_its_boundary
    fixture do
      @dep_ordinary = File.join(@root, "reader")
      dep_remote = File.join(@root, "dep.git")
      FileUtils.mkdir_p([@dep_ordinary, dep_remote])
      File.write(File.join(@dep_ordinary, "file.txt"), "dependency")
      dep_base = "b" * 40
      @inspector.heads["dep"] = dep_base
      @inspector.remote_urls["dep"] = dep_remote
      task_path = File.join(@data, "tasks", "T.yml")
      task = YAML.safe_load_file(task_path)
      task["repositories"]["dep"] = { "access" => "read_only", "path" => @dep_ordinary }
      File.write(task_path, YAML.dump(task))
      assert_equal 0, launcher(real_sandbox_probe: true).launch("T")
      dependency = report.fetch("worktrees").fetch("entries").find { |entry| entry["name"] == "dep" }
      assert_equal dep_base, dependency.fetch("base_sha")
      assert_equal dep_base, report.fetch("preparation").fetch("dep").fetch("pushed_sha")
      assert_nil dependency.fetch("branch")
      assert_equal dep_remote, dependency.fetch("remote_url")
      assert_equal File.join(@root, "worktrees", "T", "dep"), dependency.fetch("path")
      assert_includes File.binread(report.fetch("stdin_path")), dependency.fetch("path")
      assert_equal 4, report.fetch("sandbox_probe").fetch("protected_paths")
      assert_equal "exited", report.fetch("status")
    end
  end
end
