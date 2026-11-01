# frozen_string_literal: true

require_relative "git_contract/observations"
require_relative "support/child_processes"

# Manual-overlap decisions share memory Git and retain bounded real writer processes.
# Only four fixed external Codex capability/authentication reads are replayed.
module ManualOverlapSupport
  PREFLIGHT = [["--version"], ["exec", "--help"], ["login", "--help"], ["login", "status"]].freeze
  # Declares exact capability/auth responses without executing a fake CLI.
  # Each invocation owns its observations; no mutable or process-status cache.
  def manual_preflight_observations
    environment = %w[HOME PATH TMPDIR CODEX_HOME LANG LC_ALL].to_h { |key| [key, ENV[key]] }.compact
    executable = File.realpath(@fake)
    responses = [[@fake_version, "", 0], [@fake_help, "", 0],
                 ["status Show login status", "", 0], ["", @fake_auth, @fake_auth.empty? ? 1 : 0]]
    PREFLIGHT.zip(responses).map do |arguments, (stdout, stderr, code)|
      result = if @native_fixture
                 NativeTestCapture.call(environment, executable, *arguments, unsetenv_others: true)
               else
                 AgentCodingTool::CommandResult.new(stdout: stdout, stderr: stderr, exitstatus: code).to_ary
               end
      GitContract::Observation.new(argv: [environment, executable, *arguments], cwd: nil, result: result)
    end
  end

  # Replays four exact declared observations in order, checking the environment
  # clearing option Replay does not model. Other calls use declared adapters. Missing,
  # duplicate or changed reads fail, including after an expected launch refusal.
  def with_manual_preflight(expected: true, native_capture: nil)
    replay = GitContract::Replay.new(expected ? manual_preflight_observations : [])
    external = native_capture || method(:unit_capture)
    executable = File.realpath(@fake)
    capture = lambda do |*argv, **options|
      if argv[1] == executable && !argv.include?("sandbox")
        raise GitContract::UnexpectedObservation, "manual-overlap preflight options changed" unless options == { unsetenv_others: true }
        replay.capture3(*argv)
      else
        external.call(*argv, **options)
      end
    end
    MemoryGit::Session.with_capture(capture) { yield }
  ensure
    replay&.verify!
  end

  # Runs the complete production launch path: memory worktree ownership, probe,
  # reservation, process and durable reports. Returns its exit code; production
  # exceptions and observation mismatches propagate without coercion.
  def overlap_launch(instance: nil, preflight: true, native_capture: nil, **options)
    raise "manual-overlap requires memory Git and process fixtures" unless @real_git && @real_process
    instance ||= launcher(real_sandbox_probe: true)
    with_manual_preflight(expected: preflight, native_capture: native_capture) { instance.launch(@target, **options) }
  end

  # Prepares a distinct target in one memory manual-worker world. Failed attempt
  # evidence stays intact; another matrix row needs no product reset or recovery.
  def prepare_overlap_target(id, readers: {})
    @target = id
    write_task(@data, id: id, repositories: {
      "repo" => { "access" => "write", "path" => @ordinary }, **readers
    })
    @coordinator.prepare(id)
  end

  # Returns exact bytes and permission bits for a protected regular candidate or
  # evidence file. Missing/unreadable files raise instead of disappearing.
  def overlap_file_identity(path)
    [File.binread(path), File.stat(path).mode & 0o777]
  end

  # Starts an owned writer and yields its PID/reaping record after its first
  # write. Explicit release replaces guessed lifetimes; a child-side lease also
  # survives parent failure. Cleanup only signals this owned process group.
  def with_manual_worker(path, lease: 20)
    release_read, release_write = IO.pipe
    ready_read, ready_write = IO.pipe
    worker = { reaped: false }
    null = File.open(File::NULL, "w")
    if ENV['ACT_NATIVE_SUITE'] == '1' && ENV['ACT_ORDINARY_SUITE'] != '1'
      script = File.expand_path('support/fixtures/manual_worker.rb', __dir__)
      worker[:pid] = Process.spawn(RbConfig.ruby, script, path, lease.to_s, pgroup: true,
        in: release_read, out: ready_write, err: null)
    else
      approval = ChildProcesses.permit("manual_worker", arguments: [path, lease.to_s], options: { pgroup: true })
      worker[:pid] = NoGitExecution.with_permit(approval) do
        Process.spawn(approval.environment, *approval.argv, **approval.options,
          in: release_read, out: ready_write, err: null)
      end
    end
    null.close
    release_read.close
    ready_write.close
    assert_equal "ready\n", Timeout.timeout(5) { ready_read.gets }
    yield worker
  ensure
    begin
      if worker && worker[:pid] && !worker[:reaped]
        begin
          release_write.write("R")
          release_write.close
          waited = Timeout.timeout(2) do
            loop do
              result = Process.waitpid2(worker.fetch(:pid), Process::WNOHANG)
              break result if result
              sleep 0.01
            end
          end
          worker[:reaped] = true
          assert waited.last.success?, "manual worker exited #{waited.last.inspect}"
        ensure
          unless worker[:reaped]
            Process.kill("KILL", -worker.fetch(:pid)) rescue Errno::ESRCH
            Timeout.timeout(2) { Process.waitpid(worker.fetch(:pid)) } rescue Errno::ECHILD
          end
        end
      end
    ensure
      [release_read, release_write, ready_read, ready_write, null].compact.each { |pipe| pipe.close unless pipe.closed? }
    end
  end

  # Checks waitpid rather than kill(0), which also accepts zombies. Records reaping
  # before failing on early exit so cleanup never signals a recycled child PID.
  def assert_manual_worker_active(worker)
    exited = Process.waitpid2(worker.fetch(:pid), Process::WNOHANG)
    worker[:reaped] = true if exited
    assert_nil exited, "manual worker exited before the asserted handoff boundary"
  end
end
