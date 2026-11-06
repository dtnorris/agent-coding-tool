# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "rbconfig"
require "fiddle"
require_relative "command_transport"
require_relative "errors"

module AgentCodingTool
  # Trusted host embedding for the WAC-04 slice, not a scheduler or model grant.
  # Every effect consumes the same private, restart-stable pilot ledger. A forked
  # supervisor owns each child, watches controller death and enforces deadlines.
  class NativePilotExecutor
    SCHEMA = "agent-coding-tool-native-pilot/v1"
    LIMITS = { "manager" => 2, "worker" => 1, "gate" => 1 }.freeze
    OUTPUT_LIMIT = 4 * 1024 * 1024

    # Creates an exclusive host-owned ledger in existing checkpoint storage.
    # Config binds exact commands/profiles/environment/source and absolute lease;
    # caller must qualify confinement before constructing a live pilot. Raises
    # InvalidState/IO errors on unsafe storage, invalid limits or occupied files.
    def self.create(directory, config, seconds: 900)
      raise InvalidState, "pilot: invalid lease" unless seconds.positive? && seconds <= 900
      directory = File.realpath(directory)
      raise InvalidState, "pilot: invalid turn limits" unless config.fetch("turn_seconds", 300).between?(0.01, 300) && config.fetch("gate_seconds", 120).between?(0.01, 120)
      config = config.merge("schema" => SCHEMA, "directory" => directory,
        "deadline" => [Time.now.to_f + seconds, config.dig("enclosing_lease", "deadline") || Float::INFINITY].min,
        "monotonic_deadline" => [clock + seconds, config.dig("enclosing_lease", "monotonic_deadline") || Float::INFINITY].min,
        "boot" => boot, "limits" => LIMITS, "output_limit" => OUTPUT_LIMIT)
      private_directory!(directory)
      File.open(File.join(directory, "config.json"), "wx", 0o600) { |file| file.write(JSON.generate(config)); file.flush; file.fsync }
      save(directory, "ledger.json", { "counts" => LIMITS.transform_values { 0 }, "bytes" => 0, "active" => nil, "held" => nil })
      new(directory)
    end

    # Loads a trusted host pilot; no environment variable enables execution.
    # Unsafe storage, schema/boot/source/profile/runtime drift raises InvalidState.
    def initialize(directory)
      @directory = File.realpath(directory)
      raise InvalidState, "pilot: aliased storage" unless File.expand_path(directory) == @directory
      self.class.private_directory!(@directory)
      @config = read("config.json")
      raise InvalidState, "pilot: invalid config" unless @config["schema"] == SCHEMA &&
        @config["directory"] == @directory && @config["limits"] == LIMITS && @config["output_limit"] == OUTPUT_LIMIT
      verify!
    end

    # Returns immutable config identity for ACT's manager record; budgets and
    # deadlines are bound, while mutable counters remain private control truth.
    def identity
      { "executor" => SCHEMA, "config_sha256" => Digest::SHA256.file(File.join(@directory, "config.json")).hexdigest,
        "deadline" => @config.fetch("deadline"), "source" => @config.fetch("pins") }
    end

    # Returns the pinned executable for existing Launcher preflight; no process
    # is started and model output cannot replace this host-selected identity.
    def executable = @config.fetch("executable")

    # Builds the sole inference adapter from trusted runtime/source identities.
    # There is no alternate model, paid provider or permission fallback.
    def manager_adapter
      require_relative "codex_manager_adapter"
      CodexManagerAdapter.new(executable: executable, identity: identity, executor: method(:call),
        guidance: @config["manager_skill"] && File.binread(@config.fetch("manager_skill")))
    end

    # Constructs an outer deny-default macOS policy, independently of Codex's
    # own sandbox. Inference has backend networking and its own history writes;
    # tools cannot fork, read control/credentials beyond the auth file, or write
    # outside their role home and (worker only) disposable candidate directory.
    # Host qualification must prove this installed policy before live inference.
    def self.policy(role:, reads:, home:, workspace:, executables:, auth: nil)
      lines = ["(version 1)", "(deny default)", "(allow file-read-metadata)",
        '(allow file-read-data (literal "/"))', '(allow sysctl-read)',
        '(allow signal (target self))', '(allow process-info* (target self))',
        '(allow file-read* file-write-data (literal "/dev/null"))',
        '(allow file-read* (literal "/dev/random") (literal "/dev/urandom"))']
      (reads + %w[/System/Library /usr/lib /usr/share /private/var/db/dyld]).uniq.each do |path|
        lines << "(allow file-read* file-map-executable (subpath #{path.dump}))"
      end
      executables.each { |path| lines << "(allow process-exec file-read* file-map-executable (literal #{path.dump}))" }
      lines << "(allow file-read* (literal #{auth.dump}))" if auth
      lines << "(allow file-read* file-write* (subpath #{home.dump}))"
      if role == "worker"
        lines << "(allow file-read* file-write* (subpath #{workspace.dump}))"
        lines << "(deny file-read* file-write* (subpath #{File.join(workspace, '.git').dump}))"
      end
      lines << '(deny file-read* file-write* (regex #".*/[.]git(/|$)"))'
      # No process-fork grant: disabled shell/agent/app/plugin tools cannot
      # create children, escape process groups, or reach a local control channel.
      lines << "(allow network*)" unless role == "gate"
      lines.join("\n") + "\n"
    end

    # Runs the fixed manager command, preserving exact bytes and real status.
    # The prompt is data on stdin. Command drift or consumed/held budgets refuse.
    def call(argv, prompt)
      capture("manager", argv, input: prompt, cwd: @config.fetch("manager_cwd"))
    end

    # Launcher-compatible process boundary. Only the declared workspace and CLI
    # shape are accepted; final output is written to a model-owned staging path,
    # then copied by the supervisor into private evidence after size/type checks.
    # Returns an owned supervisor PID for Launcher's ordinary lifecycle handling.
    def spawn(environment, *argv, **options)
      cwd = File.realpath(options.fetch(:chdir))
      raise InvalidState, "pilot: aliased worker cwd" unless options.fetch(:chdir) == cwd
      raise InvalidState, "pilot: foreign worker cwd" unless cwd.start_with?(@config.fetch("worktree_root") + "/T/")
      final_index = argv.index("--output-last-message")
      raise InvalidState, "pilot: missing worker final" unless final_index
      final = argv.fetch(final_index + 1)
      raise InvalidState, "pilot: foreign evidence final" unless final.start_with?(@config.fetch("run_root") + "/T/") && File.basename(final) == "final.txt" &&
        File.expand_path(final) == final && File.realpath(File.dirname(final)) == File.dirname(final)
      command = argv.dup
      staged = File.join(@config.fetch("worker_home"), "final.txt")
      raise InvalidState, "pilot: occupied worker final" if File.exist?(staged) || File.symlink?(staged)
      command[final_index + 1] = staged
      command.insert(-2, "--skip-git-repo-check", "-c", "features.shell_tool=false", "-c", "features.apps=false", "-c", "features.plugins=false", "-c", 'web_search="disabled"', "-c", 'model_reasoning_effort="high"')
      launch("worker", command, input: options.fetch(:in), output: options.fetch(:out), error: options.fetch(:err), cwd: cwd,
        final: [staged, final])
    end

    # Checkpoint-compatible fixed independent gate. Streams are copied into the
    # existing GateCapture writers; actual target status is returned as data.
    def gate(argv, cwd:, out:, err:)
      capture("gate", argv, input: "", cwd: cwd, output: out, error: err)
    end

    # Captures one admitted command through the same production supervisor used
    # by Launcher. Reaping never resets counters; uncertain results stay held.
    def capture(role, argv, input:, cwd:, output: nil, error: nil)
      token = SecureRandom.uuid
      paths = %w[stdin stdout stderr].to_h { |name| [name, File.join(@directory, "#{token}.#{name}")] }
      File.open(paths.fetch("stdin"), "wx", 0o600) { |file| file.write(input) }
      handles = paths.transform_values { |path| File.open(path, path.end_with?("stdin") ? "rb" : "wx", 0o600) }
      pid = launch(role, argv, input: handles.fetch("stdin"), output: handles.fetch("stdout"), error: handles.fetch("stderr"), cwd: cwd, token: token)
      Process.waitpid(pid)
      reaped = true
      receipt = read("#{token}.json")
      stdout, stderr = %w[stdout stderr].map { |name| File.binread(paths.fetch(name)) }
      output&.write(stdout)
      error&.write(stderr)
      raise InvalidState, "pilot: #{receipt['failure']}" if receipt["failure"]
      CommandResult.new(stdout: stdout, stderr: stderr, exitstatus: receipt.fetch("exit_status"), termsig: receipt.fetch("signal"))
    ensure
      if pid && !reaped
        begin
          Process.kill("TERM", pid)
          Process.waitpid(pid)
        rescue Errno::ESRCH, Errno::ECHILD
          # Unknown spawn/result still retains its durable reservation.
        end
      end
      handles&.each_value { |handle| handle.close unless handle.closed? }
    end

    # Returns a monotonic clock that is persisted with a boot identity. Wall time
    # is an additional fail-closed bound; reboot cannot renew an expired lease.
    def self.clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Darwin boot identity without launching a command. Other hosts refuse live
    # pilots; deterministic tests may bind the explicitly supplied fixture boot.
    def self.boot
      require "fiddle"
      @sysctl ||= Fiddle::Function.new(Fiddle::Handle::DEFAULT["sysctlbyname"],
        [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_SIZE_T], Fiddle::TYPE_INT)
      value = Fiddle::Pointer.malloc(16)
      length = [16].pack("Q")
      raise InvalidState, "pilot: boot identity unavailable" unless @sysctl.call("kern.boottime", value, length, nil, 0).zero?
      # timeval padding is not identity; retain only its initialized fields.
      value.to_s(12).unpack("q<l<").join(":")
    end

    # Requires a real, private operator directory; never repairs foreign modes.
    def self.private_directory!(path)
      stat = File.lstat(path)
      raise InvalidState, "pilot: unsafe storage" unless stat.directory? && stat.uid == Process.uid &&
        (stat.mode & 0o077).zero? && File.realpath(path) == path
    end

    # Atomic synced JSON publication used only by the trusted executor. Returns
    # path; filesystem errors propagate and leave the reservation consumed.
    def self.save(directory, name, value)
      path = File.join(directory, name)
      raise InvalidState, "pilot: symlinked control" if File.symlink?(path)
      temporary = "#{path}.#{SecureRandom.hex(8)}"
      File.open(temporary, "wx", 0o600) { |file| file.write(JSON.generate(value)); file.flush; file.fsync }
      File.rename(temporary, path)
      File.open(directory, &:fsync)
      path
    end

    private

    # Reads bounded private regular single-link control bytes, rejecting aliases
    # and races. Returns JSON; malformed state never creates a fresh budget.
    def read(name)
      path = File.join(@directory, name)
      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        stat = file.stat
        raise InvalidState, "pilot: unsafe control file" unless stat.file? && stat.uid == Process.uid &&
          stat.nlink == 1 && (stat.mode & 0o077).zero? && stat.size <= 4 * 1024 * 1024 &&
          [stat.dev, stat.ino] == [File.lstat(path).dev, File.lstat(path).ino]
        RunEvidenceStore.parse(file.read)
      end
    end

    # Checks pinned inputs at check-before-effect and each supervision tick.
    # No fetch, rebase, credentials fallback or relaxed sandbox retry is possible.
    def verify!
      raise InvalidState, "pilot: config changed" if @config != read("config.json")
      raise InvalidState, "pilot: expired or rebooted" unless @config.fetch("boot") == self.class.boot &&
        Time.now.to_f < @config.fetch("deadline") && self.class.clock < @config.fetch("monotonic_deadline")
      @config.fetch("pins").each do |path, sha|
        raise InvalidState, "pilot: changed input #{path}" unless File.realpath(path) == path && Digest::SHA256.file(path).hexdigest == sha
      end
    end

    # Serializes the durable cumulative ledger independently of ACT's launch
    # lock (which is already held at inference admission). Busy calls refuse.
    def ledger
      File.open(File.join(@directory, "budget.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        stat = lock.stat
        actual = File.lstat(File.join(@directory, "budget.lock"))
        raise InvalidState, "pilot: unsafe budget lock" unless stat.file? && stat.uid == Process.uid && stat.nlink == 1 &&
          (stat.mode & 0o077).zero? && [stat.dev, stat.ino] == [actual.dev, actual.ino]
        raise InvalidState, "pilot: busy" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        state = read("ledger.json")
        raise InvalidState, "pilot: corrupt budget" unless state.is_a?(Hash) && state["counts"].is_a?(Hash) &&
          state["counts"].keys.sort == LIMITS.keys.sort && LIMITS.all? { |role, cap| state["counts"][role].is_a?(Integer) && state["counts"][role].between?(0, cap) } &&
          state["bytes"].is_a?(Integer) && state["bytes"].between?(0, OUTPUT_LIMIT)
        yield state
        self.class.save(@directory, "ledger.json", state)
      end
    end

    # Admits only fixed direct argv. Manager sessions must be explicit, worker
    # comes solely from Launcher, and validation is an exact host declaration.
    def command!(role, argv, cwd)
      executable = @config.fetch("executable")
      raise InvalidState, "pilot: aliased cwd" unless File.expand_path(cwd) == cwd && File.realpath(cwd) == cwd
      valid = case role
              when "manager"
                require_relative "codex_manager_adapter"
                adapter = CodexManagerAdapter.new(executable: executable, identity: {})
                session = argv[2] == "resume" ? argv[-2] : nil
                cwd == @config.fetch("manager_cwd") && argv == adapter.argv(session)
              when "worker"
                cwd.start_with?(@config.fetch("worktree_root") + "/T/") &&
                  argv.take(2) == [executable, "exec"] && argv.last == "-" && !argv.include?("--model") &&
                  argv.include?("--sandbox") && argv[argv.index("--sandbox") + 1] == "workspace-write"
              when "gate"
                argv == @config.fetch("gate_argv") && File.realpath(cwd).start_with?(@config.fetch("worktree_root") + "/T/")
              end
      raise InvalidState, "pilot: command refused" unless valid
    end

    # Reserves invocation/concurrency before fork. The child supervisor is a
    # sibling of model/tool processes, outside their confinement. Unknown fork
    # outcome remains active/held across every restart, never auto-replayed.
    def launch(role, argv, input:, output:, error:, cwd:, token: SecureRandom.uuid, final: nil)
      verify!
      command!(role, argv, cwd)
      ledger do |state|
        raise InvalidState, "pilot: held or active invocation" if state["held"] || state["active"]
        raise InvalidState, "pilot: invocation/output limit" unless state.fetch("counts").fetch(role) < LIMITS.fetch(role) && state.fetch("bytes") < OUTPUT_LIMIT
        state.fetch("counts")[role] += 1
        state["active"] = token
      end
      owner = Process.pid
      Process.fork do
        # Do not inherit controller-held ACT locks or unrelated IO into tools.
        keep = [0, 1, 2, input.fileno, output.fileno, error.fileno]
        ObjectSpace.each_object(IO) do |stream|
          stream.close unless stream.closed? || keep.include?(stream.fileno)
        end
        Process.setpgrp
        supervise(role, argv, cwd, input, output, error, owner, token, final)
      end
    end

    # Darwin waitid(WNOWAIT) observes an exited direct child without releasing
    # ownership. Returns boolean; inspection failure refuses and triggers teardown.
    def self.exited?(pid)
      @waitid ||= Fiddle::Function.new(Fiddle::Handle::DEFAULT["waitid"],
        [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      info = Fiddle::Pointer.malloc(104)
      info[0, 104] = "\0" * 104
      raise InvalidState, "pilot: waitid unavailable" unless @waitid.call(1, pid, info, 0x25).zero?
      info.to_s(104).byteslice(12, 4).unpack1("i") == pid
    end

    # Refuses controller loss, cancellation or either original deadline. Called
    # during pipe backpressure too: a frozen controller cannot freeze its lease.
    def supervision_check!(owner, deadline)
      raise InvalidState, "controller died" if Process.ppid != owner
      raise InvalidState, "invocation stopped" if @stopped
      raise InvalidState, "turn/lease expired" if self.class.clock >= deadline || Time.now.to_f >= @config.fetch("deadline")
    end

    # Drains a ready bounded chunk, charging before retention/delivery. Worker
    # bytes are independently archived before forwarding; nonblocking forwarding
    # keeps controller backpressure inside the independent deadline. EOF removes
    # only this owned stream; failure leaves all consumed bytes in the ledger.
    def drain(streams, logs, owner, deadline)
      IO.select(streams.keys, nil, nil, 0.01)&.first&.each do |stream|
        begin
          bytes = stream.read_nonblock(16_384)
          retained = 0
          ledger do |state|
            retained = [OUTPUT_LIMIT - state.fetch("bytes"), bytes.bytesize].min
            state["bytes"] += retained
          end
          destination = streams.fetch(stream)
          prefix = bytes.byteslice(0, retained)
          logs[destination]&.write(prefix)
          until prefix.empty?
            supervision_check!(owner, deadline)
            begin
              written = destination.write_nonblock(prefix)
              prefix = prefix.byteslice(written..)
            rescue IO::WaitWritable
              IO.select(nil, [destination], nil, 0.01)
            end
          end
          raise InvalidState, "cumulative output limit" if retained < bytes.bytesize
        rescue IO::WaitReadable
          next
        rescue EOFError
          streams.delete(stream)
          stream.close
        end
      end
    end

    # Independently enforces absolute/turn deadlines, parent death and byte caps.
    # Keeps the direct child waitable until group teardown, preventing PID/group
    # reuse. Profiles forbid process-group escape executables; descendant signal
    # rights never extend to the host shell. Partial bytes/status remain private.
    def supervise(role, argv, cwd, input, output, error, owner, token, final)
      target = nil
      status = nil
      failure = nil
      read_out, write_out = IO.pipe
      read_err, write_err = IO.pipe
      available = [@config.fetch("monotonic_deadline") - self.class.clock,
        @config.fetch(role == "gate" ? "gate_seconds" : "turn_seconds", role == "gate" ? 120 : 300)].min
      # Maximum grants include teardown. Stop work early enough to leave one
      # second for cleanup (half the budget for tighter qualification grants).
      deadline = self.class.clock + available - [1.0, available / 2].min
      logs = role == "worker" ? {
        output => File.open(File.join(@directory, "#{token}.worker.stdout"), "wx", 0o600),
        error => File.open(File.join(@directory, "#{token}.worker.stderr"), "wx", 0o600) } : {}
      @stopped = false
      %w[TERM INT HUP].each { |signal| Signal.trap(signal) { @stopped = true } }
      begin
        verify!
        profile = @config.fetch("profiles").fetch(role)
        environment = @config.fetch("environments").fetch(role)
        prefix = @config.fetch("inference_prefixes", {})[role]
        executed = prefix ? [*prefix, *argv.drop(1)] : argv
        supervision_check!(owner, deadline)
        target = Process.spawn(environment, "/usr/bin/sandbox-exec", "-f", profile, *executed,
          chdir: cwd, in: input, out: write_out, err: write_err, pgroup: true, unsetenv_others: true, close_others: true)
        [write_out, write_err].each(&:close)
        self.class.save(@directory, "#{token}.started.json", { "supervisor" => Process.pid, "controller" => owner, "child" => target, "deadline" => deadline, "role" => role })
        streams = { read_out => output, read_err => error }
        loop do
          supervision_check!(owner, deadline)
          drain(streams, logs, owner, deadline)
          # Inspect without reaping: the owned group cannot be recycled before
          # teardown. Confinement denies fork for every inference/gate role.
          if self.class.exited?(target)
            Process.kill("KILL", -target) rescue Errno::ESRCH
            _pid, status = Process.waitpid2(target)
            target = nil
            # EOF is now guaranteed by no-fork confinement. Continue draining
            # bounded pipes before publishing status and releasing concurrency.
            until streams.empty?
              supervision_check!(owner, deadline)
              drain(streams, logs, owner, deadline)
            end
            break
          end
        end
        if final
          stat = File.lstat(final.first)
          raise InvalidState, "invalid worker final" unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.size <= 65_536
          bytes = File.binread(final.first)
          ledger do |state|
            raise InvalidState, "cumulative output limit" if state.fetch("bytes") + bytes.bytesize > OUTPUT_LIMIT
            state["bytes"] += bytes.bytesize
          end
          File.open(final.last, "wx", 0o600) { |file| file.write(bytes); file.flush; file.fsync }
        end
      rescue Exception => exception
        failure = "#{exception.class}: #{exception.message}"
      ensure
        if target
          Process.kill("KILL", -target) rescue Errno::ESRCH
          _pid, status = Process.waitpid2(target)
        end
        stopped_at = self.class.clock
        lease_overrun = stopped_at > @config.fetch("monotonic_deadline") || Time.now.to_f > @config.fetch("deadline")
        failure ||= "owned-child teardown exceeded lease" if lease_overrun
        [read_out, write_out, read_err, write_err].each { |stream| stream.close unless stream.closed? }
        begin
          logs.each_value { |file| file.flush; file.fsync; file.close }
          [output, error].each { |stream| stream.flush; stream.fsync if stream.stat.file? }
        rescue IOError, SystemCallError => exception
          failure ||= "output persistence: #{exception.class}: #{exception.message}"
        end
        self.class.save(@directory, "#{token}.json", { "exit_status" => status&.exitstatus, "signal" => status&.termsig,
          "failure" => failure, "truncated" => !!failure&.include?("output limit"), "role" => role,
          "stopped_monotonic" => stopped_at, "lease_overrun" => lease_overrun })
        ledger do |state|
          state["held"] = failure if failure
          state["active"] = nil
        end
      end
      exit! failure ? 125 : status.exitstatus || 128 + status.termsig
    end
  end
end
