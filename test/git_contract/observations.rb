# frozen_string_literal: true

require "open3"
require "thread"
require_relative "../../lib/agent_coding_tool/command_transport"

# Strict external observations shared by behavioral tests; never interprets Git.
module GitContract
  # A mismatch is a test failure, never an ordinary command failure to swallow.
  class UnexpectedObservation < Exception; end

  # Immutable command input and raw output, or an exceptional execution outcome.
  class Observation
    attr_reader :argv, :cwd, :stdin_data, :stdout, :stderr, :status, :exception, :timeout, :options

    # Accepts exact argv (including a leading environment hash), cwd and a
    # capture3/capture tuple or an exception. Environment/stdin strings are copied;
    # an omitted environment and an empty leading environment hash are equivalent.
    # Raises ArgumentError for an ambiguous or incompatible outcome.
    def initialize(argv:, cwd:, stdin_data: "", result: nil, exception: nil, timeout: nil, options: {})
      raise ArgumentError, "observation stdin must be a String" unless stdin_data.is_a?(String)
      unless (result.nil? != exception.nil?) &&
             (result.nil? || (result.size == 3 && result[0].is_a?(String) &&
              result[1].is_a?(String) && (result[2] == true || result[2] == false ||
              result[2].is_a?(Process::Status) || result[2].is_a?(AgentCodingTool::CommandResult))))
        raise ArgumentError, "provide a capture3 result or an exception"
      end
      argv = argv.drop(1) if argv.first == {}
      @argv = argv.map do |argument|
        argument.is_a?(Hash) ? argument.to_h { |key, value| [key.dup.freeze, value&.dup&.freeze] }.freeze : argument.dup.freeze
      end.freeze
      @cwd = cwd&.dup&.freeze
      @stdin_data = stdin_data.dup.freeze
      @timeout = timeout
      @options = options.dup.freeze
      @stdout, @stderr, @status = result
      @stdout = @stdout&.dup&.freeze
      @stderr = @stderr&.dup&.freeze
      @exception = exception
      freeze
    end

    # Returns fresh streams and original native status or modeled CommandResult.
    # Boolean-only legacy records cannot supply termination facts and raise.
    def capture3
      raise exception if exception
      raise ArgumentError, "capture3 requires termination facts" unless status.is_a?(Process::Status) || status.is_a?(AgentCodingTool::CommandResult)

      [stdout.dup, stderr.dup, status]
    end

    # Returns CommandRunner's raw bytes and boolean success, or raises the
    # recorded exception. Boolean fixtures require no native process setup.
    def capture
      raise exception if exception

      [stdout.dup, stderr.dup, status.respond_to?(:success?) ? status.success? : status]
    end

    # Adapts raw termination facts to the production transport value. Boolean
    # observations lack those facts and raise; recorded exceptions stay exact.
    def command_result
      output, error, termination = capture3
      AgentCodingTool::CommandResult.new(stdout: output, stderr: error,
        exitstatus: termination.exitstatus, termsig: termination.termsig)
    end
  end

  # Finite, thread-safe observations. Ordering may be relaxed only for independent
  # concurrent requests; every declared observation must still be consumed once.
  class Replay
    # Accepts Observation instances; ordered defaults to sequential consumption.
    # Returns a runner, without executing commands or interpreting their output.
    def initialize(observations, ordered: true)
      @remaining = observations.dup
      @ordered = ordered
      @mutex = Mutex.new
    end

    # Matches exact argv/cwd/stdin and returns raw capture3 output or raises its
    # exception. Unexpected, duplicate, or out-of-order requests fail loudly.
    def capture3(*argv, chdir: nil, stdin_data: "")
      take(argv, chdir, stdin_data).capture3
    end

    # Implements CommandRunner's boolean-success boundary, preserving exceptions
    # and byte strings. Accepts exact argv, optional cwd and binary stdin.
    def capture(*argv, chdir: nil, stdin_data: "")
      take(argv, chdir, stdin_data).capture
    end

    # Implements the full shared transport envelope without smuggling process
    # fields into argv. Every declared option/timeout is exact; no native fallback.
    def call(argv, cwd: nil, env: {}, input: "", timeout: nil, **options)
      command = env.empty? ? argv : [env, *argv]
      take(command, cwd, input, timeout, options).command_result
    end

    # Returns true after complete consumption; raises for missing observations.
    def verify!
      @mutex.synchronize do
        raise UnexpectedObservation, "#{@remaining.size} missing observations" unless @remaining.empty?
      end
      true
    end

    private

    # Consumes one exact request atomically; returns its Observation or raises
    # UnexpectedObservation without consuming an unmatched expectation.
    def take(argv, cwd, stdin_data, timeout = nil, options = {})
      argv = argv.drop(1) if argv.first == {}
      @mutex.synchronize do
        index = @ordered ? 0 : @remaining.index { |item| item.argv == argv && item.cwd == cwd && item.stdin_data == stdin_data && item.timeout == timeout && item.options == options }
        expected = index && @remaining[index]
        unless expected && expected.argv == argv && expected.cwd == cwd && expected.stdin_data == stdin_data && expected.timeout == timeout && expected.options == options
          raise UnexpectedObservation, "unexpected argv=#{argv.inspect} cwd=#{cwd.inspect}; remaining=#{@remaining.map { |item| [item.argv, item.cwd] }.inspect}"
        end
        @remaining.delete_at(index)
      end
    end
  end

  # Records genuine local processes with binary pipes and an independently
  # enforced per-process deadline. Intended only for disposable contract fixtures.
  class Native
    attr_reader :observations

    # Accepts an isolated child environment and positive seconds per command;
    # returns a recorder. Raises ArgumentError for an invalid deadline.
    def initialize(environment: {}, seconds: 2)
      raise ArgumentError, "positive finite deadline required" unless seconds.positive? && seconds.finite?

      @environment = environment
      @seconds = seconds
      @observations = []
      @mutex = Mutex.new
    end

    # Runs exact argv/cwd in a new owned process group. Returns raw bytes and a
    # real status, records exact binary stdin/spawn exceptions, and raises on
    # deadline expiration, including a child that refuses to consume its stdin.
    def capture3(*argv, chdir: nil, stdin_data: "")
      raise ArgumentError, "native stdin must be a String" unless stdin_data.is_a?(String)
      stdin_data = stdin_data.dup.freeze
      options = { pgroup: true }
      options[:chdir] = chdir if chdir
      command = argv.dup
      environment = @environment.merge(command.first.is_a?(Hash) ? command.shift : {})
      result = Open3.popen3(environment, *command, **options) do |input, output, error, waiter|
        input.binmode
        output.binmode
        error.binmode
        readers = [output, error].map { |pipe| Thread.new { pipe.read } }
        timer_lock = Mutex.new
        timer_signal = ConditionVariable.new
        finished = false
        expired = false
        watchdog = Thread.new do
          timer_lock.synchronize do
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @seconds
            until finished
              remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
              break if remaining <= 0

              timer_signal.wait(timer_lock, remaining)
            end
            unless finished
              expired = true
              begin
                Process.kill("KILL", -waiter.pid)
              rescue Errno::ESRCH
                # The owned group exited between the deadline and the signal.
              end
            end
          end
        end
        begin
          begin
            input.write(stdin_data)
          rescue Errno::EPIPE
            # A rejecting child still owns its diagnostic and exit status.
          ensure
            input.close
          end
          values = readers.map(&:value)
          status = waiter.value
          raise IOError, "fixture command exceeded #{@seconds}s: #{argv.inspect}" if expired

          [*values, status]
        ensure
          timer_lock.synchronize { finished = true; timer_signal.broadcast }
          watchdog.join
          readers.each(&:join)
        end
      end
      observation = Observation.new(argv: argv, cwd: chdir, stdin_data: stdin_data, result: result)
      @mutex.synchronize { @observations << observation }
      result
    rescue SystemCallError => exception
      @mutex.synchronize { @observations << Observation.new(argv: argv, cwd: chdir, stdin_data: stdin_data, exception: exception) }
      raise
    end

    # Implements the capture boundary; accepts exact argv/cwd and
    # preserves binary stdin/stdout/stderr and exceptional execution behavior.
    def capture(*argv, chdir: nil, stdin_data: "")
      stdout, stderr, status = capture3(*argv, chdir: chdir, stdin_data: stdin_data)
      [stdout, stderr, status.success?]
    end
  end
end
