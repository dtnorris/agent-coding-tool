# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class CLITest < Minitest::Test
  include TestHelpers

  def test_start_command_and_status
    with_workspace do |dir|
      write_task(dir, id: "T1")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("T1")
      out = StringIO.new
      err = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out: out, err: err)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run(%w[start T1])
      assert_includes out.string, "Started T1: IN_FLIGHT"
      assert_equal 0, cli.run(%w[status T1])
      assert_includes out.string, "T1: IN_FLIGHT"
      assert_empty err.string
      assert_equal 2, cli.run(%w[start T1])
      assert_includes err.string, "already in flight"
      assert_equal 0, cli.run(%w[prepare T1 --retry])
      assert_equal "PREPARED", coordinator.status("T1").fetch("status")
    end
  end

  def test_start_command_errors
    with_workspace do |dir|
      write_task(dir, id: "T1")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      [%w[start], %w[start T1 extra], %w[start T1], %w[start missing]].each do |args|
        err = StringIO.new
        cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out: StringIO.new, err: err)
        cli.instance_variable_set(:@coordinator, coordinator)
        assert_equal 2, cli.run(args)
        assert_match(/ERROR:/, err.string)
      end
    end
  end

  def test_help_lists_start
    out = StringIO.new
    assert_equal 0, AgentCodingTool::CLI.run(["help"], out: out)
    assert_includes out.string, "start TASK"
    assert_includes out.string, "human assertion"
  end

  def test_status_completion_filters_and_explicit_lookup
    with_workspace do |dir|
      (1..6).each { |index| write_task(dir, id: "C#{index}") }
      write_task(dir, id: "READY")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      (1..6).each { |index| coordinator.record("C#{index}", outcome: "complete") }

      default_out = run_status(dir, coordinator, %w[status])
      refute_includes default_out, "C1: COMPLETE"
      assert_includes default_out, "C6: COMPLETE"
      assert_includes default_out, "READY: READY"

      all_out = run_status(dir, coordinator, %w[status --all])
      assert_includes all_out, "C1: COMPLETE"

      active_out = run_status(dir, coordinator, %w[status --active])
      refute_includes active_out, "COMPLETE"
      assert_includes active_out, "READY: READY"

      explicit_out = run_status(dir, coordinator, %w[status C1])
      assert_includes explicit_out, "C1: COMPLETE"
    end
  end

  def test_status_orders_for_scanability_and_formats_dependency_reasons
    statuses = [
      { "id" => "B1", "status" => "BLOCKED", "title" => "Blocked task",
        "reason" => "dependencies incomplete: R1" },
      { "id" => "P1", "status" => "PREPARED", "title" => "Prepared task" },
      { "id" => "R1", "status" => "READY", "title" => "Ready task" },
      { "id" => "F1", "status" => "IN_FLIGHT", "title" => "Running task" },
      { "id" => "C1", "status" => "COMPLETE", "title" => "Complete task" }
    ]
    fake_coordinator = Object.new
    fake_coordinator.define_singleton_method(:statuses) { |*_args, **_kwargs| statuses }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, fake_coordinator)

    assert_equal 0, cli.run(%w[status])

    lines = out.string.lines.map(&:chomp)
    assert_equal [
      "C1: COMPLETE — Complete task",
      "",
      "F1: IN_FLIGHT — Running task",
      "",
      "R1: READY — Ready task",
      "",
      "P1: PREPARED — Prepared task",
      "",
      "B1: BLOCKED — Blocked task",
      "    waiting on: R1"
    ], lines
  end

  def test_status_preserves_single_task_lookup_without_dashboard_spacing
    status = {
      "id" => "B1",
      "status" => "BLOCKED",
      "title" => "Blocked task",
      "reason" => "dependencies incomplete: R1"
    }
    fake_coordinator = Object.new
    fake_coordinator.define_singleton_method(:statuses) { |*_args, **_kwargs| [status] }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, fake_coordinator)

    assert_equal 0, cli.run(%w[status B1])
    assert_equal "B1: BLOCKED — Blocked task\n    waiting on: R1\n", out.string
  end

  def test_status_rejects_conflicting_completion_filters
    with_workspace do |dir|
      write_task(dir, id: "T1")
      err = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out: StringIO.new, err: err)
      cli.instance_variable_set(:@coordinator, coordinator_for(dir, "alpha" => "a" * 40))

      assert_equal 2, cli.run(%w[status --all --active])
      assert_includes err.string, "mutually exclusive"
    end
  end

  def test_help_documents_status_completion_filters
    out = StringIO.new
    assert_equal 0, AgentCodingTool::CLI.run(["help"], out: out)
    assert_includes out.string, "status [TASK] [--all | --active]"
  end

  def test_default_data_root_is_sibling_named_after_tool_checkout
    root = "/code/agent-coding-tool"

    assert_equal "/code/agent-coding-tool-data", AgentCodingTool::CLI.default_data_root(root, env: {})
  end

  def test_data_root_environment_override_wins
    root = "/code/agent-coding-tool"

    assert_equal "/private/act-data",
                 AgentCodingTool::CLI.default_data_root(root, env: { "AGENT_CODING_TOOL_DATA_DIR" => "/private/act-data" })
  end

  def test_cli_fails_closed_when_data_directory_is_missing
    Dir.mktmpdir do |dir|
      out = StringIO.new
      err = StringIO.new

      status = AgentCodingTool::CLI.run(["status"], root: dir, data_root: File.join(dir, "missing"), out: out, err: err)

      assert_equal 2, status
      assert_match(/data directory does not exist/, err.string)
    end
  end

  private

  def run_status(dir, coordinator, argv)
    out = StringIO.new
    err = StringIO.new
    cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out: out, err: err)
    cli.instance_variable_set(:@coordinator, coordinator)
    assert_equal 0, cli.run(argv)
    assert_empty err.string
    out.string
  end
end
