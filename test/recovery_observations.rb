# frozen_string_literal: true

require "rbconfig"
require_relative "git_contract/observations"

# Declared external observations for recovery decisions, never an ownership oracle.
# Native administration and filesystem mutations remain in the original journeys.
module RecoveryObservations
  # Returns a genuine cached Process::Status for an explicit exit code. The local
  # Ruby child has the contract observer's two-second owned-process deadline;
  # spawn errors or timeouts propagate instead of fabricating a process result.
  def self.status(exit_code)
    @statuses ||= {}
    @statuses[exit_code] ||= GitContract::Native.new.capture3(
      RbConfig.ruby, "-e", "exit Integer(ARGV.fetch(0))", exit_code.to_s
    ).last
  end

  # Builds one exact command/cwd observation with raw byte streams and a real
  # exit status. Invalid observations and status-child failures propagate.
  def recovery_observation(cwd, *argv, stdout: "".b, stderr: "".b, exit_code: 0)
    GitContract::Observation.new(argv: argv, cwd: cwd,
      result: [stdout, stderr, RecoveryObservations.status(exit_code)])
  end

  # Runs the supplied production operation with finite external observations.
  # Returns its result; unexpected or unconsumed commands fail the test, including
  # refusals asserted inside the block. Filesystem operations are not replaced.
  def with_recovery_observations(observations)
    replay = GitContract::Replay.new(observations)
    result = Open3.stub(:capture3, replay.method(:capture3)) { yield }
    assert replay.verify!
    result
  end
end
