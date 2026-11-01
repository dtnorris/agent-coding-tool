# frozen_string_literal: true

require "rbconfig"
require_relative "git_contract/observations"
require_relative "support/child_processes"

# Declared external observations for recovery decisions, never an ownership oracle.
# Native administration and filesystem mutations remain in the original journeys.
module RecoveryObservations
  # Returns a fresh genuine reaped status only when its PID proves liveness.
  # The fixed Ruby child has a two-second deadline and propagated coverage/guard.
  def self.status(exit_code)
    ChildProcesses.capture("status", arguments: [exit_code.to_s]).last
  end

  # Builds one exact command/cwd observation with raw byte streams and a real
  # result. No process starts for a modeled exit; liveness uses status separately.
  def recovery_observation(cwd, *argv, stdout: "".b, stderr: "".b, exit_code: 0)
    GitContract::Observation.new(argv: argv, cwd: cwd,
      result: [stdout, stderr, AgentCodingTool::CommandResult.new(stdout: stdout, stderr: stderr, exitstatus: exit_code)])
  end

  # Runs the supplied production operation with finite external observations.
  # Returns its result; unexpected or unconsumed commands fail the test, including
  # refusals asserted inside the block. Filesystem operations are not replaced.
  def with_recovery_observations(observations)
    replay = GitContract::Replay.new(observations)
    result = MemoryGit::Session.with_capture(replay.method(:capture3)) { yield }
    assert replay.verify!
    result
  end
end
