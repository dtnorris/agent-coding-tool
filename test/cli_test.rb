# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class CLITest < Minitest::Test
  include TestHelpers

  class TTYOutput < StringIO
    def initialize(width)
      @width = width
      super()
    end

    def tty? = true
    def winsize = [24, @width]
  end

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

  def test_received_records_candidate_with_metadata_and_preserves_staleness
    with_workspace do |dir|
      write_task(dir, id: "T1")
      heads = { "alpha" => "a" * 40 }
      coordinator = coordinator_for(dir, heads)
      coordinator.prepare("T1")
      coordinator.start("T1")
      out = StringIO.new
      err = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err:)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run([
        "received", "T1", "--summary", "review ready", "--artifact", "T1.patch",
        "--test", "focused=pass", "--test", "rake=pass"
      ])
      state = coordinator.status("T1").fetch("state")
      assert_equal "Received T1: CANDIDATE\n", out.string
      assert_empty err.string
      assert_equal "candidate_complete", state.dig("result", "outcome")
      assert_equal "review ready", state.dig("result", "summary")
      assert_equal "T1.patch", state.dig("result", "artifact")
      assert_equal %w[focused=pass rake=pass], state.dig("result", "tests")
      refute state.key?("started_at")
      assert_equal "CANDIDATE", coordinator.status("T1").fetch("status")

      heads["alpha"] = "b" * 40
      assert_equal "STALE_CANDIDATE", coordinator.status("T1").fetch("status")
    end
  end

  def test_finish_records_complete_with_metadata_snapshot_and_unblocks_dependents
    with_workspace do |dir|
      write_task(dir, id: "T1")
      write_task(dir, id: "T2", depends_on: ["T1"])
      heads = { "alpha" => "a" * 40 }
      coordinator = coordinator_for(dir, heads)
      coordinator.prepare("T1")
      coordinator.start("T1")
      heads["alpha"] = "b" * 40
      out = StringIO.new
      err = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err:)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run([
        "finish", "T1", "--summary", "landed", "--artifact", "T1.patch",
        "--test", "focused=pass", "--test", "rake=pass"
      ])
      state = coordinator.status("T1").fetch("state")
      assert_equal "Finished T1: COMPLETE\n", out.string
      assert_empty err.string
      assert_equal "complete", state.dig("result", "outcome")
      assert_equal "landed", state.dig("result", "summary")
      assert_equal "T1.patch", state.dig("result", "artifact")
      assert_equal %w[focused=pass rake=pass], state.dig("result", "tests")
      assert_equal "b" * 40, state.dig("completion_snapshot", "alpha", "pushed_sha")
      refute state.key?("started_at")
      assert_equal "COMPLETE", coordinator.status("T1").fetch("status")
      assert_equal "READY", coordinator.status("T2").fetch("status")

      assert_equal 2, cli.run(%w[start T1])
      assert_includes err.string, "already complete"
    end
  end

  def test_received_and_finish_require_exactly_one_task
    {
      "received" => "agent-coding-tool received TASK",
      "finish" => "agent-coding-tool finish TASK"
    }.each do |command, usage|
      [[], %w[T1 extra]].each do |arguments|
        err = StringIO.new
        cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out: StringIO.new, err:)

        assert_equal 2, cli.run([command, *arguments])
        assert_includes err.string, "usage: #{usage}"
      end
    end
  end

  def test_record_remains_backward_compatible_for_every_outcome
    with_workspace do |dir|
      outcomes = %w[candidate_complete complete blocked needs_judgment failed]
      outcomes.each { |outcome| write_task(dir, id: outcome) }
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      outcomes.each { |outcome| coordinator.prepare(outcome) }

      outcomes.each do |outcome|
        out = StringIO.new
        err = StringIO.new
        cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err:)
        cli.instance_variable_set(:@coordinator, coordinator)

        assert_equal 0, cli.run(["record", outcome, outcome])
        assert_equal "Recorded #{outcome}: #{outcome}\n", out.string
        assert_empty err.string
        assert_equal outcome, coordinator.status(outcome).dig("state", "result", "outcome")
      end
    end
  end

  def test_help_documents_received_finish_and_generic_record
    out = StringIO.new

    assert_equal 0, AgentCodingTool::CLI.run(["help"], out:)
    assert_includes out.string, "received TASK [--summary TEXT] [--artifact PATH] [--test RESULT]"
    assert_includes out.string, "worker result is ready for human review/application"
    assert_includes out.string, "finish TASK [--summary TEXT] [--artifact PATH] [--test RESULT]"
    assert_includes out.string, "landed task is complete on authoritative pushed state"
    assert_includes out.string, "record TASK OUTCOME [--summary TEXT] [--artifact PATH] [--test RESULT]"
    assert_includes out.string, "generic/manual outcome primitive"
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
      "F1: IN_FLIGHT — Running task",
      "",
      "R1: READY — Ready task",
      "    downstream: 0 levels / 0 tasks",
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
      "F1: IN_FLIGHT — Still running",
      "",
      "R1: READY — Ready one",
      "    downstream: 0 levels / 0 tasks",
      "R2: READY — Ready two",
      "    downstream: 0 levels / 0 tasks"
    ], lines
  end

  def test_status_wraps_dashboard_titles_and_reasons_with_deliberate_indentation
    statuses = [
      { "id" => "B1", "status" => "BLOCKED",
        "title" => "A blocked title with enough words to wrap cleanly",
        "reason" => "dependencies incomplete: R1, R2, R3, R4" },
      { "id" => "R1", "status" => "READY",
        "title" => "A ready title with enough words to wrap cleanly" },
      { "id" => "F1", "status" => "IN_FLIGHT",
        "title" => "An in flight title with enough words to wrap cleanly",
        "reason" => "A long diagnostic that remains visibly subordinate when wrapped" }
    ]
    coordinator = fake_status_coordinator(statuses)
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new,
                                   terminal_width: 42)
    cli.instance_variable_set(:@coordinator, coordinator)

    assert_equal 0, cli.run(%w[status])
    assert_equal [
      "F1: IN_FLIGHT — An in flight title with e…",
      "    A long diagnostic that remains visibly",
      "    subordinate when wrapped",
      "",
      "R1: READY — A ready title with enough",
      "            words to wrap cleanly",
      "    downstream: 0 levels / 0 tasks",
      "",
      "B1: BLOCKED — A blocked title with enough",
      "              words to wrap cleanly",
      "    waiting on: R1, R2, R3, R4"
    ], out.string.lines.map(&:chomp)
    in_flight_line = out.string.lines.find { |line| line.start_with?("F1: IN_FLIGHT") }
    assert_equal 1, out.string.lines.count { |line| line.start_with?("F1: IN_FLIGHT") }
    assert in_flight_line.chomp.end_with?("…")
    assert_operator in_flight_line.chomp.length, :<=, 42
  end

  def test_status_wraps_colored_output_by_visible_width
    status = { "id" => "R1", "status" => "READY",
               "title" => "A colored title that should wrap at the same visible width" }
    coordinator = fake_status_coordinator([status])
    plain = StringIO.new
    plain_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out: plain, err: StringIO.new,
                                         terminal_width: 36)
    plain_cli.instance_variable_set(:@coordinator, coordinator)
    tty = TTYOutput.new(36)
    color_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out: tty, err: StringIO.new)
    color_cli.instance_variable_set(:@coordinator, coordinator)
    previous_no_color = ENV.delete("NO_COLOR")

    assert_equal 0, plain_cli.run(%w[status])
    assert_equal 0, color_cli.run(%w[status])
    assert_includes tty.string, "\e[92mREADY\e[0m"
    assert_equal plain.string, tty.string.gsub(/\e\[[0-9;]*m/, "")
  ensure
    ENV["NO_COLOR"] = previous_no_color if previous_no_color
  end

  def test_status_truncates_colored_in_flight_title_at_same_visible_location_as_plain_output
    status = { "id" => "F1", "status" => "IN_FLIGHT",
               "title" => "A long in flight title that must stay on one physical line" }
    coordinator = fake_status_coordinator([status])
    plain = StringIO.new
    plain_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out: plain, err: StringIO.new,
                                         terminal_width: 36)
    plain_cli.instance_variable_set(:@coordinator, coordinator)
    tty = TTYOutput.new(36)
    color_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out: tty, err: StringIO.new)
    color_cli.instance_variable_set(:@coordinator, coordinator)
    previous_no_color = ENV.delete("NO_COLOR")

    assert_equal 0, plain_cli.run(%w[status])
    assert_equal 0, color_cli.run(%w[status])
    assert_equal 1, plain.string.lines.length
    assert plain.string.chomp.end_with?("…")
    assert_operator plain.string.chomp.length, :<=, 36
    assert_includes tty.string, "\e[36mIN_FLIGHT\e[0m"
    assert_equal plain.string, tty.string.gsub(/\e\[[0-9;]*m/, "")
  ensure
    ENV["NO_COLOR"] = previous_no_color if previous_no_color
  end

  def test_status_preserves_in_flight_prefix_when_terminal_is_too_narrow_for_a_title
    status = { "id" => "F1", "status" => "IN_FLIGHT", "title" => "Running task" }
    coordinator = fake_status_coordinator([status])
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new,
                                   terminal_width: 12)
    cli.instance_variable_set(:@coordinator, coordinator)

    assert_equal 0, cli.run(%w[status])
    assert_equal ["F1: IN_FLIGHT — "], out.string.lines.map(&:chomp)
  end

  def test_status_uses_columns_for_non_tty_output_and_honors_no_color
    status = { "id" => "K1", "status" => "CANDIDATE",
               "title" => "A candidate title that wraps predictably" }
    coordinator = fake_status_coordinator([status])
    previous_columns = ENV["COLUMNS"]
    previous_no_color = ENV["NO_COLOR"]
    ENV["COLUMNS"] = "34"
    ENV["NO_COLOR"] = "1"
    out = TTYOutput.new(0)
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, coordinator)

    assert_equal 0, cli.run(%w[status])
    refute_includes out.string, "\e["
    assert_equal [
      "K1: CANDIDATE — A candidate title",
      "                that wraps",
      "                predictably"
    ], out.string.lines.map(&:chomp)
  ensure
    previous_columns ? ENV["COLUMNS"] = previous_columns : ENV.delete("COLUMNS")
    previous_no_color ? ENV["NO_COLOR"] = previous_no_color : ENV.delete("NO_COLOR")
  end

  def test_status_ranks_ready_tasks_by_downstream_depth_then_distinct_count_then_stable_order
    statuses = [
      { "id" => "R-STABLE-B", "status" => "READY", "title" => "Stable B" },
      { "id" => "B", "status" => "BLOCKED", "title" => "Blocked",
        "reason" => "dependencies incomplete: R-DEEP" },
      { "id" => "R-WIDE", "status" => "READY", "title" => "Wide" },
      { "id" => "R-LESS", "status" => "READY", "title" => "Less" },
      { "id" => "F", "status" => "IN_FLIGHT", "title" => "Running" },
      { "id" => "R-DIAMOND", "status" => "READY", "title" => "Diamond" },
      { "id" => "R-DEEP", "status" => "READY", "title" => "Deep" },
      { "id" => "R-CYCLE", "status" => "READY", "title" => "Cycle" },
      { "id" => "R-STABLE-A", "status" => "READY", "title" => "Stable A" },
      { "id" => "K", "status" => "CANDIDATE", "title" => "Candidate" }
    ]
    tasks = [
      task_definition("R-DEEP"), task_definition("D1", ["R-DEEP"]),
      task_definition("D2", ["D1"]), task_definition("D3", ["D2"]),
      task_definition("D4", ["D3"]),
      task_definition("R-WIDE"), task_definition("W1", ["R-WIDE"]),
      task_definition("W2", ["R-WIDE"]), task_definition("W3", ["R-WIDE"]),
      task_definition("R-DIAMOND"), task_definition("DB", ["R-DIAMOND"]),
      task_definition("DC", ["R-DIAMOND"]), task_definition("DD", ["DB", "DC"]),
      task_definition("R-LESS"), task_definition("L1", ["R-LESS"]),
      task_definition("L2", ["L1"]),
      task_definition("R-STABLE-B"), task_definition("R-STABLE-A"),
      task_definition("R-CYCLE", ["CYCLE-CHILD"]),
      task_definition("CYCLE-CHILD", ["R-CYCLE"])
    ]
    coordinator = fake_status_coordinator(statuses, tasks:)
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, coordinator)

    assert_equal 0, cli.run(%w[status --active])

    visible_ready = out.string.lines.filter_map { |line| line[/\A(R-[^:]+): READY/, 1] }
    assert_equal %w[R-DEEP R-DIAMOND R-LESS R-WIDE R-CYCLE R-STABLE-B R-STABLE-A], visible_ready
    assert_includes out.string, "R-DEEP: READY — Deep\n    downstream: 4 levels / 4 tasks\n"
    assert_includes out.string, "R-DIAMOND: READY — Diamond\n    downstream: 2 levels / 3 tasks\n"
    assert_includes out.string, "R-CYCLE: READY — Cycle\n    downstream: 1 level / 1 task\n"
    assert_operator out.string.index("K: CANDIDATE"), :<, out.string.index("F: IN_FLIGHT")
    assert_operator out.string.index("F: IN_FLIGHT"), :<, out.string.index("R-DEEP: READY")
    assert_operator out.string.index("R-STABLE-A: READY"), :<, out.string.index("B: BLOCKED")
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
      "F1: IN_FLIGHT — Running with refresh",
      "    read-only refresh/reconcile: af-data-pipeline, af-workloads",
      "F2: IN_FLIGHT — Running without refresh"
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

  def test_status_limits_blocked_tasks_to_three_ranked_by_incomplete_dependency_count
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
    fake_coordinator = fake_status_coordinator(statuses)
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, fake_coordinator)

    assert_equal 0, cli.run(%w[status])

    visible_blocked = out.string.lines.filter_map { |line| line[/\A([^:]+): BLOCKED/, 1] }
    assert_equal %w[B1A B1B B1C], visible_blocked
    refute_includes out.string, "B2: BLOCKED"
    refute_includes out.string, "B3: BLOCKED"
    refute_includes out.string, "B4: BLOCKED"
    refute_includes out.string, "B5: BLOCKED"
    refute_includes out.string, "MANUAL: BLOCKED"

    active_out = StringIO.new
    active_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd,
                                          out: active_out, err: StringIO.new)
    active_cli.instance_variable_set(:@coordinator, fake_coordinator)
    assert_equal 0, active_cli.run(%w[status --active])
    active_blocked = active_out.string.lines.filter_map { |line| line[/\A([^:]+): BLOCKED/, 1] }
    assert_equal %w[B1A B1B B1C], active_blocked

    explicit_out = StringIO.new
    explicit_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd,
                                            out: explicit_out, err: StringIO.new)
    explicit_cli.instance_variable_set(:@coordinator, fake_coordinator)
    assert_equal 0, explicit_cli.run(%w[status B5])
    assert_includes explicit_out.string, "B5: BLOCKED — Five blockers"
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

  def fake_status_coordinator(statuses, tasks: [])
    coordinator = Object.new
    coordinator.define_singleton_method(:statuses) do |ids = nil, **_kwargs|
      ids ? statuses.select { |status| ids.include?(status.fetch("id")) } : statuses
    end
    coordinator.define_singleton_method(:tasks) { tasks }
    coordinator
  end

  def task_definition(id, depends_on = [])
    { "id" => id, "depends_on" => depends_on }
  end

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
