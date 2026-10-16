# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

# Broad process/host decision cases stay deterministic. No process enumeration,
# signal delivery, shell termination, sandbox execution or real lsof is needed.
class RetryLivenessTest < Minitest::Test
  Status = Struct.new(:exitstatus)

  # Supplies a complete terminal report and one existing directory to exercise
  # all observed PID/group/tool checks without creating a real worker.
  def setup
    @identity = { "hostname" => "fixture", "boot" => "boot", "uid" => 123 }
    @report = { "status" => "exited", "host_identity" => @identity, "host_pid" => 100,
                "child_pid" => 101, "child_started_at" => "2026-01-01T00:00:00Z",
                "ended_at" => "2026-01-01T00:00:02Z", "heartbeat_at" => "2026-01-01T00:00:01Z", "heartbeat_child_pid" => 101 }
    @inventory = { "entries" => [{ "path" => Dir.pwd }] }
  end

  # Evaluates production decisions with fake OS boundaries; no actual signal or
  # lsof execution occurs. Missing, active and permission cases remain distinct.
  def check(active: nil, denied: false, tool: ["", "", Status.new(1)])
    signal = lambda { |_number, pid|
      raise Errno::EPERM if denied
      raise Errno::ESRCH unless pid == active
      1
    }
    AgentCodingTool::RetryLiveness.stub(:host_identity, @identity) do
      Process.stub(:kill, signal) do
        Open3.stub(:capture3, ->(*) { tool.is_a?(Exception) ? raise(tool) : tool }) do
          AgentCodingTool::RetryLiveness.new.check(@report, @inventory)
        end
      end
    end
  end

  # Clear observations do not override active host, reused worker PID or live
  # group; unavailable tools/permissions/identity and contradictions refuse.
  def test_negative_host_pid_group_heartbeat_and_tool_matrix
    assert_equal :clear, check
    [100, 101, -101].each { |pid| assert_equal :active, check(active: pid) }
    assert_equal :unknown, check(denied: true)
    assert_equal :unknown, check(tool: Errno::ENOENT.new)
    assert_equal :unknown, check(tool: ["", "permission denied", Status.new(1)])
    assert_equal :active, check(tool: ["fixture process", "", Status.new(0)])
    assert_equal :unknown, check(tool: ["", "", Status.new(2)])
    original = @report.dup
    [{ "host_identity" => nil }, { "host_identity" => { "boot" => "other" } },
     { "heartbeat_child_pid" => 999 }, { "heartbeat_at" => "2027-01-01T00:00:00Z" },
     { "child_started_at" => "bad timestamp" }, { "host_pid" => 0 }, { "status" => "running" }].each do |changes|
      @report = original.merge(changes)
      assert_equal :unknown, check, changes.inspect
    end
  end
end
