# frozen_string_literal: true

require "open3"
require "timeout"

module AgentCodingTool
  # Raw command output and termination facts, independent of Process::Status.
  # Streams retain their bytes and encoding; signal termination is not an exit.
  class CommandResult
    attr_reader :stdout, :stderr, :exitstatus, :termsig

    # Accepts raw String streams and exactly one nonnegative exit or positive
    # signal number. Invalid termination facts raise ArgumentError.
    def initialize(stdout:, stderr:, exitstatus: nil, termsig: nil)
      unless stdout.is_a?(String) && stderr.is_a?(String) &&
             ((exitstatus.is_a?(Integer) && exitstatus >= 0 && termsig.nil?) ||
              (termsig.is_a?(Integer) && termsig > 0 && exitstatus.nil?))
        raise ArgumentError, "command result requires streams and one exit status or signal"
      end
      @stdout, @stderr, @exitstatus, @termsig = stdout, stderr, exitstatus, termsig
      freeze
    end

    # Returns whether the command exited normally, including nonzero exits.
    def exited? = !@exitstatus.nil?

    # Returns whether a signal terminated the command.
    def signaled? = !@termsig.nil?

    # Matches native success semantics: true/false for exits, nil for signals.
    def success? = exited? ? @exitstatus.zero? : nil

    # Returns the conventional shell code only at a CLI/reporting boundary.
    def shell_status = exited? ? @exitstatus : 128 + @termsig

    # Supports existing raw stdout/stderr/status destructuring without requiring
    # a native status, a fabricated PID or a child launched only for status.
    def to_ary = [@stdout, @stderr, self]
  end

  # Native external-command boundary. Git callers construct/parse their commands;
  # this class supplies only process IO and termination, never product decisions.
  class NativeCommandTransport
    # Optional streams receive partial output on interrupt for ApplyHandoff's
    # interactive workflow. Construction performs no IO and raises no spawn error.
    def initialize(interrupt_out: nil, interrupt_err: nil)
      @interrupt_out, @interrupt_err = interrupt_out, interrupt_err
    end

    # Executes direct argv with explicit environment, cwd, stdin and Open3 options.
    # Returns CommandResult; native spawn/option errors propagate. A timeout raises
    # Timeout::Error after killing/reaping the owned group. Interrupt does likewise
    # and replays captured output to the configured streams before propagating.
    # Untimed calls preserve capture3 behavior; grouped/timed calls drain binary IO.
    def call(argv, cwd: nil, env: {}, input: "", timeout: nil, **options)
      unless timeout.nil? || (timeout.is_a?(Numeric) && timeout.real? && timeout.positive? && timeout.finite?)
        raise ArgumentError, "command timeout must be a positive finite number"
      end
      options = options.merge(chdir: cwd) if cwd
      if timeout || options[:pgroup]
        capture_process(argv, env, input, timeout, options)
      else
        stdout, stderr, status = Open3.capture3(env, *argv, stdin_data: input, **options)
        result(stdout, stderr, status)
      end
    end

    private

    # Adapts a genuine reaped native status once, preserving signal nil-success.
    # Returns the transport value object; invalid native facts raise ArgumentError.
    def result(stdout, stderr, status)
      CommandResult.new(stdout: stdout, stderr: stderr,
        exitstatus: status.exitstatus, termsig: status.termsig)
    end

    # Owns concurrent pipe drains and group cleanup for grouped/timed commands.
    # Returns CommandResult; timeout, interrupt, pipe and spawn exceptions propagate.
    def capture_process(argv, env, input, timeout, options)
      options = { pgroup: true }.merge(options)
      options.delete(:binmode) # Grouped IO is always binary, as in ApplyHandoff.
      Open3.popen3(env, *argv, **options) do |stdin, stdout, stderr, child|
        [stdin, stdout, stderr].each(&:binmode)
        readers = [stdout, stderr].map { |stream| Thread.new { stream.read } }
        begin
          Timeout.timeout(timeout) do
            begin
              stdin.write(input)
            rescue Errno::EPIPE
              # Retain diagnostics/status when a rejecting child closes input.
            ensure
              stdin.close
            end
            result(readers[0].value, readers[1].value, child.value)
          end
        rescue Interrupt, Timeout::Error => error
          begin
            Process.kill("KILL", options[:pgroup] == true ? -child.pid : child.pid)
          rescue Errno::ESRCH
            # The child may have exited immediately before interruption.
          end
          child.value
          output, diagnostic = readers.map(&:value)
          if error.is_a?(Interrupt)
            @interrupt_out&.write(output)
            @interrupt_err&.write(diagnostic)
          end
          raise
        ensure
          stdin.close unless stdin.closed?
        end
      end
    end
  end
end
