# frozen_string_literal: true

require_relative "git_contract/observations"

# Manual-overlap decisions retain native Git, sandbox validation and execution.
# Only four fixed external Codex capability/authentication reads are replayed.
module ManualOverlapSupport
  PREFLIGHT = [["--version"], ["exec", "--help"], ["login", "--help"], ["login", "status"]].freeze
  WORKER = <<~'CHILD'
    path, lease = ARGV
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(lease)
    File.write(path, "external work")
    STDOUT.puts("ready")
    STDOUT.flush
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      exit 75 unless remaining.positive?
      if IO.select([STDIN], nil, nil, [remaining, 0.025].min)
        exit(STDIN.read(1) == "R" ? 0 : 76)
      end
      File.write(path, "external work")
    end
  CHILD

  # Records actual fake-CLI responses once per interpreter, including genuine
  # statuses. Exact argv/environment remain inputs; no status child or production
  # validator is substituted. Native failures raise rather than populate cache.
  def manual_preflight_observations
    environment = %w[HOME PATH TMPDIR CODEX_HOME LANG LC_ALL].to_h { |key| [key, ENV[key]] }.compact
    executable = File.realpath(@fake)
    key = [environment, executable]
    cache = ManualOverlapSupport.instance_variable_get(:@preflight)
    unless cache
      cache = {}
      ManualOverlapSupport.instance_variable_set(:@preflight, cache)
    end
    cache[key] ||= PREFLIGHT.map do |arguments|
      argv = [environment, executable, *arguments]
      result = Open3.capture3(*argv, unsetenv_others: true)
      raise "manual-overlap native preflight failed: #{arguments.inspect}" unless result.last.success?
      GitContract::Observation.new(argv: argv, cwd: nil, result: result)
    end
  end

  # Replays four exact native observations in order, checking the environment
  # clearing option Replay does not model. Sandbox/Git calls stay native. Missing,
  # duplicate or changed reads fail, including after an expected launch refusal.
  def with_manual_preflight(expected: true, native_capture: nil)
    replay = GitContract::Replay.new(expected ? manual_preflight_observations : [])
    original = native_capture || Open3.method(:capture3)
    executable = File.realpath(@fake)
    capture = lambda do |*argv, **options|
      if argv[1] == executable && !argv.include?("sandbox")
        raise GitContract::UnexpectedObservation, "manual-overlap preflight options changed" unless options == { unsetenv_others: true }
        replay.capture3(*argv)
      else
        original.call(*argv, **options)
      end
    end
    Open3.stub(:capture3, capture) { yield }
  ensure
    replay&.verify!
  end

  # Runs the complete production launch path: native worktree ownership, probe,
  # reservation, process and durable reports. Returns its exit code; production
  # exceptions and observation mismatches propagate without coercion.
  def overlap_launch(instance: nil, preflight: true, native_capture: nil, **options)
    raise "manual-overlap requires native fixtures" unless @real_git && @real_process
    instance ||= launcher(real_sandbox_probe: true)
    with_manual_preflight(expected: preflight, native_capture: native_capture) { instance.launch(@target, **options) }
  end

  # Prepares a distinct target in one native manual-worker world. Failed attempt
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
    worker[:pid] = Process.spawn(RbConfig.ruby, "-e", WORKER, path, lease.to_s,
                                 in: release_read, out: ready_write, err: File::NULL, pgroup: true)
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
      [release_read, release_write, ready_read, ready_write].compact.each { |pipe| pipe.close unless pipe.closed? }
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
