# frozen_string_literal: true

require_relative "test_helper"
require_relative "recovery_observations"
require "minitest/mock"

# Broad process/host decision cases stay deterministic. No process enumeration,
# signal delivery, shell termination, sandbox execution or real lsof is needed.
class RetryLivenessTest < Minitest::Test
  include RecoveryObservations

  # Supplies a complete terminal report and one existing directory to exercise
  # all observed PID/group/tool checks without creating a real worker.
  def setup
    @identity = { "hostname" => "fixture", "boot" => "boot", "uid" => 123 }
    @report = { "status" => "exited", "host_identity" => @identity, "host_pid" => 100,
                "child_pid" => 101, "child_started_at" => "2026-01-01T00:00:00Z",
                "ended_at" => "2026-01-01T00:00:02Z", "heartbeat_at" => "2026-01-01T00:00:01Z", "heartbeat_child_pid" => 101 }
    @inventory = { "entries" => [{ "path" => Dir.pwd }] }
  end

  # Evaluates production decisions with exact expected signal probes and lsof
  # bytes/status/exception. Returns the classification; unexpected or omitted
  # observations fail loudly. No signal is delivered and lsof is never launched.
  def check(active: nil, denied: false, pids: [100, 101, -101], tool: ["".b, "".b, 1])
    expected_pids = pids.dup
    signal = lambda { |number, pid|
      assert_equal [0, expected_pids.shift], [number, pid]
      raise Errno::EPERM if denied
      raise Errno::ESRCH unless pid == active
      1
    }
    observations = if tool.is_a?(Exception)
      [GitContract::Observation.new(argv: ["lsof", "-n", "-P", "+D", Dir.pwd], cwd: nil, exception: tool)]
    elsif tool
      [recovery_observation(nil, "lsof", "-n", "-P", "+D", Dir.pwd,
        stdout: tool[0], stderr: tool[1], exit_code: tool[2])]
    else
      []
    end
    result = with_recovery_observations(observations) do
      AgentCodingTool::RetryLiveness.stub(:host_identity, @identity) do
        Process.stub(:kill, signal) do
          AgentCodingTool::RetryLiveness.new.check(@report, @inventory)
        end
      end
    end
    assert_empty expected_pids
    result
  end

  # Clear observations do not override active host, reused worker PID or live
  # group; unavailable tools/permissions/identity and contradictions refuse.
  def test_negative_host_pid_group_heartbeat_and_tool_matrix
    assert_equal :clear, check
    [100, 101, -101].each_with_index do |pid, index|
      assert_equal :active, check(active: pid, pids: [100, 101, -101].take(index + 1), tool: nil)
    end
    assert_equal :unknown, check(denied: true, pids: [100], tool: nil)
    assert_equal :unknown, check(tool: Errno::ENOENT.new)
    assert_equal :unknown, check(tool: ["".b, "permission denied".b, 1])
    assert_equal :active, check(tool: ["fixture process\x00\xff".b, "".b, 0])
    assert_equal :unknown, check(tool: ["".b, "".b, 2])
    original = @report.dup
    [{ "host_identity" => nil }, { "host_identity" => { "boot" => "other" } },
     { "heartbeat_child_pid" => 999 }, { "heartbeat_at" => "2027-01-01T00:00:00Z" },
     { "child_started_at" => "bad timestamp" }, { "host_pid" => 0 }, { "status" => "running" }].each do |changes|
      @report = original.merge(changes)
      assert_equal :unknown, check(pids: [], tool: nil), changes.inspect
    end
  end
end
