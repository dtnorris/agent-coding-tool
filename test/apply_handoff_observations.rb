# frozen_string_literal: true

require "stringio"
require_relative "git_contract/observations"

# Apply-only adaptation of finite GitContract observations to the integer-code
# process boundary. Stdin is part of the exact request, never an interpreted Git
# command. Codes come from native captures; no Process::Status is manufactured.
module ApplyHandoffObservations
  # Supplies invocation-local terminal responses at the real confirmation calls.
  class Input
    # Copies answers and optionally observes each read; callbacks may change real
    # fixture files after preview. Missing answers raise outside product rescues.
    def initialize(answers, &before_read)
      @answers = answers.dup
      @before_read = before_read
    end

    # Declares terminal capability for policy tests; real PTY proof stays native.
    def tty? = true

    # Returns the next response or callback result. Extra reads fail closed.
    def gets
      raise GitContract::UnexpectedObservation, "unexpected consent read" if @answers.empty?
      @before_read&.call
      answer = @answers.shift
      answer.respond_to?(:call) ? answer.call : answer
    end

    # Requires every supplied response to have been requested exactly once.
    def verify!
      raise GitContract::UnexpectedObservation, "unconsumed consent" unless @answers.empty?
      true
    end
  end

  # Replays exact environment/argv/stdin/cwd through the existing strict matcher.
  # A callback supplies only the reviewed fixture file effect at an exact request.
  class Transport
    # Takes finite native record hashes, with optional per-request file effects.
    # Invalid observations raise; no native fallback is available.
    def initialize(records, &effect)
      @records = records
      @position = 0
      @effect = effect
      @replay = GitContract::Replay.new(records.map do |record|
        GitContract::Observation.new(argv: [record.fetch(:env), *record.fetch(:argv), record.fetch(:input)],
          cwd: record.fetch(:cwd), result: [*record.fetch(:result).first(2), record.fetch(:result).last.zero?])
      end)
    end

    # Returns raw streams and the recorded native integer exit code. Wrong,
    # duplicate, reordered or extra requests raise UnexpectedObservation.
    def call(argv, cwd:, env:, input:)
      stdout, stderr, _success = @replay.capture(env, *argv, input, chdir: cwd)
      record = @records.fetch(@position)
      @position += 1
      @effect&.call(record)
      [stdout, stderr, record.fetch(:result).last]
    end

    # Rejects omitted requests after success or a production refusal.
    def verify! = @replay.verify!
  end
end
