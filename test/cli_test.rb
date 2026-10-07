# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class CLITest < Minitest::Test
  include TestHelpers

  def test_prepare_prints_worker_recommendation_once_after_complete_prompt_and_keeps_prompt_file_clean
    with_workspace do |dir|
      write_task(dir, id: "T1", worker_recommendation: {
                   "model" => "GPT-5.6 Sol", "thinking" => "High"
                 })
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err: StringIO.new)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run(%w[prepare T1])
      prompt_path = Dir[File.join(dir, "state/prompts/T1-*.txt")].fetch(0)
      prompt = File.read(prompt_path)
      output = out.string
      recommendation = "Recommended worker model: GPT-5.6 Sol\nThinking level: High\n"

      assert_includes output, "#{prompt}\n#{recommendation}"
      assert_operator output.index(recommendation), :>=, output.index(prompt) + prompt.length
      assert_equal ["Recommended worker model: GPT-5.6 Sol", "Thinking level: High"],
                   output.lines.map(&:chomp).reject(&:empty?).last(2)
      assert_equal 1, output.scan("Recommended worker model:").length
      assert_equal 1, output.scan("Thinking level:").length
      refute_includes prompt, "Recommended worker model:"
      refute_includes prompt, "Thinking level:"
      assert_equal prompt, File.read(prompt_path)
    end
  end

  def test_prepare_prints_astra_recommendation_at_bottom
    with_workspace do |dir|
      write_task(dir, id: "T1", worker_recommendation: {
                   "model" => "GPT-6 Astra", "thinking" => "Medium"
                 })
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err: StringIO.new)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run(%w[prepare T1])
      assert_equal ["Recommended worker model: GPT-6 Astra", "Thinking level: Medium"],
                   out.string.lines.map(&:chomp).reject(&:empty?).last(2)
    end
  end

  def test_prepare_without_worker_recommendation_preserves_existing_output
    with_workspace do |dir|
      write_task(dir, id: "T1")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err: StringIO.new)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run(%w[prepare T1])
      assert_includes out.string, "  alpha: #{'a' * 40} (local matches)\nPrompt: "
      refute_includes out.string, "Recommended worker model:"
      refute_includes out.string, "Thinking level:"
    end
  end

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
      { "id" => "K1", "status" => "CANDIDATE", "title" => "Candidate task" },
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
      "K1: CANDIDATE — Candidate task",
      "",
      "F1: IN_FLIGHT",
      "    Running task",
      "",
      "R1: READY — Ready task",
      "",
      "P1: PREPARED — Prepared task",
      "",
      "B1: BLOCKED — Blocked task",
      "    waiting on: R1"
    ], lines
  end

  def test_candidate_moves_above_in_flight_and_multiple_ready_tasks
    statuses = [
      { "id" => "R1", "status" => "READY", "title" => "Ready one" },
      { "id" => "F1", "status" => "IN_FLIGHT", "title" => "Still running" },
      { "id" => "R2", "status" => "READY", "title" => "Ready two" },
      { "id" => "F2", "status" => "CANDIDATE", "title" => "Was in flight" }
    ]
    fake_coordinator = Object.new
    fake_coordinator.define_singleton_method(:statuses) { |*_args, **_kwargs| statuses }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, fake_coordinator)

    assert_equal 0, cli.run(%w[status --active])

    lines = out.string.lines.map(&:chomp)
    assert_equal [
      "F2: CANDIDATE — Was in flight",
      "",
      "F1: IN_FLIGHT",
      "    Still running",
      "",
      "R1: READY — Ready one",
      "R2: READY — Ready two"
    ], lines
  end

  def test_status_formats_broad_in_flight_tasks_and_compacts_read_only_freshness
    full_reason =
      "read-only pushed branch changed; refresh and reconcile materially affected findings before finalizing: " \
      "af-data-pipeline, af-workloads"
    statuses = [
      { "id" => "F1", "status" => "IN_FLIGHT", "title" => "Running with refresh", "reason" => full_reason },
      { "id" => "F2", "status" => "IN_FLIGHT", "title" => "Running without refresh" }
    ]
    fake_coordinator = Object.new
    fake_coordinator.define_singleton_method(:statuses) { |*_args, **_kwargs| statuses }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, fake_coordinator)

    assert_equal 0, cli.run(%w[status])
    assert_equal [
      "F1: IN_FLIGHT",
      "    Running with refresh",
      "    read-only refresh/reconcile: af-data-pipeline, af-workloads",
      "F2: IN_FLIGHT",
      "    Running without refresh"
    ], out.string.lines.map(&:chomp)
  end

  def test_status_preserves_full_in_flight_freshness_reason_for_explicit_lookup
    full_reason =
      "read-only pushed branch changed; refresh and reconcile materially affected findings before finalizing: " \
      "af-data-pipeline"
    status = { "id" => "F1", "status" => "IN_FLIGHT", "title" => "Running task", "reason" => full_reason }
    fake_coordinator = Object.new
    fake_coordinator.define_singleton_method(:statuses) { |*_args, **_kwargs| [status] }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, fake_coordinator)

    assert_equal 0, cli.run(%w[status F1])
    assert_equal "F1: IN_FLIGHT — Running task\n    #{full_reason}\n", out.string
  end

  def test_status_limits_blocked_tasks_to_five_ranked_by_incomplete_dependency_count
    statuses = [
      { "id" => "B3", "status" => "BLOCKED", "title" => "Three blockers",
        "reason" => "dependencies incomplete: A, B, C" },
      { "id" => "B1A", "status" => "BLOCKED", "title" => "One blocker A",
        "reason" => "dependencies incomplete: A" },
      { "id" => "B4", "status" => "BLOCKED", "title" => "Four blockers",
        "reason" => "dependencies incomplete: A, B, C, D" },
      { "id" => "B2", "status" => "BLOCKED", "title" => "Two blockers",
        "reason" => "dependencies incomplete: A, B" },
      { "id" => "MANUAL", "status" => "BLOCKED", "title" => "Manual blocker",
        "reason" => "waiting for external decision" },
      { "id" => "B1B", "status" => "BLOCKED", "title" => "One blocker B",
        "reason" => "dependencies incomplete: B" },
      { "id" => "B5", "status" => "BLOCKED", "title" => "Five blockers",
        "reason" => "dependencies incomplete: A, B, C, D, E" },
      { "id" => "B1C", "status" => "BLOCKED", "title" => "One blocker C",
        "reason" => "dependencies incomplete: C" }
    ]
    fake_coordinator = Object.new
    fake_coordinator.define_singleton_method(:statuses) { |*_args, **_kwargs| statuses }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, fake_coordinator)

    assert_equal 0, cli.run(%w[status])

    visible_blocked = out.string.lines.filter_map { |line| line[/\A([^:]+): BLOCKED/, 1] }
    assert_equal %w[B1A B1B B1C B2 B3], visible_blocked
    refute_includes out.string, "B4: BLOCKED"
    refute_includes out.string, "B5: BLOCKED"
    refute_includes out.string, "MANUAL: BLOCKED"
  end

  def test_status_all_keeps_every_blocked_task
    statuses = (1..6).map do |index|
      {
        "id" => "B#{index}",
        "status" => "BLOCKED",
        "title" => "Blocked #{index}",
        "reason" => "dependencies incomplete: D#{index}"
      }
    end
    fake_coordinator = Object.new
    fake_coordinator.define_singleton_method(:statuses) { |*_args, **_kwargs| statuses }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, fake_coordinator)

    assert_equal 0, cli.run(%w[status --all])

    visible_blocked = out.string.lines.filter_map { |line| line[/\A([^:]+): BLOCKED/, 1] }
    assert_equal %w[B1 B2 B3 B4 B5 B6], visible_blocked
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
