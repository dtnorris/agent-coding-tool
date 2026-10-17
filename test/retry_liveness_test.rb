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
    @identity = { "hostname" => "fixture", "boot" => "01234567-89AB-CDEF-0123-456789ABCDEF", "uid" => 123 }
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

  # Renames are harmless only with complete matching boot/UID provenance.
  def test_hostname_rename_requires_same_boot_and_user
    recorded = @identity.merge("hostname" => "former-host")
    @report = @report.merge("host_identity" => recorded)
    assert_equal :clear, check
    assert_equal :active, check(active: 101)
    [
      recorded.merge("boot" => "11111111-2222-3333-4444-555555555555"),
      recorded.merge("uid" => 124),
      recorded.merge("boot" => nil),
      recorded.merge("hostname" => nil),
      recorded.reject { |key, _| key == "uid" },
      recorded.merge("unexpected" => true)
    ].each do |identity|
      @report = @report.merge("host_identity" => identity)
      assert_equal :unknown, check, identity.inspect
    end
  end

  # Accept the exact unrelated SMB diagnostic, not incomplete or relevant lsof
  # probes. The warning remains visible on stderr for the operator.
  def test_time_machine_warning_is_scoped_and_diagnostic
    warning = <<~WARNING
      lsof: WARNING: can't stat() smbfs file system /Volumes/.timemachine/backup._smb._tcp.local./201021BB-1BF9-4D95-848D-B5F87C8D4143/DavidMacProBackup
            Output information may be incomplete.
            assuming "dev=36000007" from mount table
    WARNING
    tool = ["", warning, Status.new(1)]
    _, stderr = capture_io { assert_equal :clear, check(tool: tool) }
    assert_includes stderr, warning
    assert_equal :active, check(active: 100, tool: tool)
    [
      ["", warning.sub(/^ {6}(?=Output|assuming)/, ""), Status.new(1)],
      ["", "permission denied", Status.new(1)],
      ["", warning + "extra warning\n", Status.new(1)],
      ["", warning.sub("/Volumes/.timemachine/", "/Volumes/other/"), Status.new(1)],
      ["", warning, Status.new(2)],
      ["unexpected data", warning, Status.new(1)],
      ["", warning, Status.new(0)]
    ].each { |response| assert_equal :unknown, check(tool: response), response.inspect }
    File.stub(:realpath, "/Volumes/.timemachine/backup/worktree") do
      assert_equal :unknown, check(tool: tool)
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
