# frozen_string_literal: true

require "stringio"
require_relative "git_contract/observations"

# Apply-only adaptation of finite GitContract observations to CommandResult.
# Stdin and process grouping are exact request fields, never interpreted Git
# commands. Native exit/signal facts are retained; no status is manufactured.
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

  # Replays exact environment/argv/stdin/cwd/pgroup through the strict matcher.
  # A callback supplies only the reviewed fixture file effect at an exact request.
  class Transport
    # Takes finite CommandResult records, with optional per-request file effects.
    # Invalid observations raise; no native fallback is available.
    def initialize(records, &effect)
      @records = records
      @position = 0
      @effect = effect
      @replay = GitContract::Replay.new(records.map do |record|
        result = record.fetch(:result)
        raise ArgumentError, "apply observation requires CommandResult" unless result.is_a?(AgentCodingTool::CommandResult)
        GitContract::Observation.new(argv: [record.fetch(:env), *record.fetch(:argv), record.fetch(:input),
          { "pgroup" => record.fetch(:pgroup) }], cwd: record.fetch(:cwd),
          result: [result.stdout, result.stderr, result.success? == true])
      end)
    end

    # Returns the original CommandResult after exact matching; the legacy
    # matcher's boolean is not a result adapter. Wrong, duplicate, reordered or
    # extra requests raise UnexpectedObservation before any fixture effect.
    def call(argv, cwd:, env:, input:, pgroup:)
      @replay.capture(env, *argv, input, { "pgroup" => pgroup }, chdir: cwd)
      record = @records.fetch(@position)
      @position += 1
      @effect&.call(record)
      record.fetch(:result)
    end

    # Rejects omitted requests after success or a production refusal.
    def verify! = @replay.verify!
  end
end
