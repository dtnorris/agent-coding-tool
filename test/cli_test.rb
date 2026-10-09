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

  def test_prepare_writes_and_prints_one_documentation_section_for_spec_and_source_only_tasks
    with_workspace do |dir|
      write_task(dir, id: "SPEC", repositories: { "spec" => { "access" => "write" } })
      write_task(dir, id: "SOURCE", repositories: { "source" => { "access" => "write" } })
      path = File.join(dir, "tasks", "SPEC.yml")
      spec = YAML.safe_load_file(path)
      spec["constraints"] << "Create VERSIONED_SPEC.md as the authoritative v0.1 contract."
      File.write(path, YAML.dump(spec))
      inspector = Class.new(TestHelpers::FakeInspector) do
        attr_reader :snapshots, :head_batches

        def snapshot(name, spec)
          @snapshots = (@snapshots || 0) + 1
          super
        end

        def pushed_heads(references)
          @head_batches = (@head_batches || 0) + 1
          super
        end
      end.new(heads: { "spec" => "a" * 40, "source" => "b" * 40 })
      coordinator = AgentCodingTool::Coordinator.new(
        task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
        state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
        repo_inspector: inspector, prompt_renderer: AgentCodingTool::PromptRenderer.new,
        prompt_root: File.join(dir, "state", "prompts")
      )

      %w[SPEC SOURCE].each do |id|
        out = StringIO.new
        cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err: StringIO.new)
        cli.instance_variable_set(:@coordinator, coordinator)
        assert_equal 0, cli.run(["prepare", id])
        prompt = File.read(Dir[File.join(dir, "state", "prompts", "#{id}-*.txt")].fetch(0))
        assert_includes out.string, prompt
        assert_equal 1, prompt.scan(/^## Documentation discipline$/).length
        assert_equal 1, out.string.scan(/^## Documentation discipline$/).length
        assert_includes prompt, "## Goal\n\nDo the bounded thing.\n"
        assert_includes prompt, "## Acceptance\n\n- Focused tests pass.\n"
        assert_includes prompt, "git@github.com:example/#{id.downcase}.git"
        assert_includes prompt, "Only the repositories designated writable above may be modified"
        assert_includes prompt, "- Create VERSIONED_SPEC.md" if id == "SPEC"
        refute_includes prompt, "VERSIONED_SPEC.md" if id == "SOURCE"
      end
      assert_equal 2, inspector.snapshots
      assert_nil inspector.head_batches
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

  def test_record_persists_next_action_and_rejects_it_for_successful_outcomes
    with_workspace do |dir|
      %w[JUDGMENT CANDIDATE COMPLETE].each { |id| write_task(dir, id:) }
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      %w[JUDGMENT CANDIDATE COMPLETE].each { |id| coordinator.prepare(id) }
      action = "Land IG-05C4, then retry IG-09C."

      out = StringIO.new
      err = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err:)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run(["record", "JUDGMENT", "needs_judgment", "--summary", "Missing authority.",
                               "--next", action])
      assert_equal action, coordinator.status("JUDGMENT").dig("state", "result", "next_action")

      %w[CANDIDATE COMPLETE].zip(%w[candidate_complete complete]).each do |id, outcome|
        assert_equal 2, cli.run(["record", id, outcome, "--next", "not valid"])
      end
      assert_equal 2, err.string.scan("--next is only supported").length
    end
  end

  def test_help_documents_received_finish_and_generic_record
    out = StringIO.new

    assert_equal 0, AgentCodingTool::CLI.run(["help"], out:)
    assert_includes out.string, "received TASK [--summary TEXT] [--artifact PATH] [--test RESULT]"
    assert_includes out.string, "worker result is ready for human review/application"
    assert_includes out.string, "finish TASK [--summary TEXT] [--artifact PATH] [--test RESULT]"
    assert_includes out.string, "landed task is complete on authoritative pushed state"
    assert_includes out.string, "record TASK OUTCOME [--summary TEXT] [--next TEXT] [--artifact PATH] [--test RESULT]"
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
      { "id" => "N1", "status" => "NEEDS_JUDGMENT", "title" => "Needs judgment",
        "reason" => "Operator decision required",
        "state" => { "result" => { "outcome" => "needs_judgment" } } },
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
      "    downstream: 0 levels / 0 tasks; unlocks: 0 tasks / 0 parallel",
      "",
      "N1: NEEDS_JUDGMENT — Needs judgment",
      "    reason: Operator decision required",
      "    resume: act prepare N1 --retry",
      "",
      "F1: IN_FLIGHT — Running task",
      "",
      "R1: READY — Ready task",
      "    downstream: 0 levels / 0 tasks; unlocks: 0 tasks / 0 parallel",
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
      "    downstream: 0 levels / 0 tasks; unlocks: 0 tasks / 0 parallel",
      "",
      "F1: IN_FLIGHT — Still running",
      "",
      "R1: READY — Ready one",
      "    downstream: 0 levels / 0 tasks; unlocks: 0 tasks / 0 parallel",
      "R2: READY — Ready two",
      "    downstream: 0 levels / 0 tasks; unlocks: 0 tasks / 0 parallel"
    ], lines
  end

  def test_status_truncates_dashboard_headlines_and_wraps_reasons_with_deliberate_indentation
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
      "F1: IN_FLIGHT — An in flight title with...",
      "    A long diagnostic that remains visibly",
      "    subordinate when wrapped",
      "",
      "R1: READY — A ready title with enough w...",
      "    downstream: 0 levels / 0 tasks;",
      "    unlocks: 0 tasks / 0 parallel",
      "",
      "B1: BLOCKED — A blocked title with enou...",
      "    waiting on: R1, R2, R3, R4"
    ], out.string.lines.map(&:chomp)
    in_flight_line = out.string.lines.find { |line| line.start_with?("F1: IN_FLIGHT") }
    assert_equal 1, out.string.lines.count { |line| line.start_with?("F1: IN_FLIGHT") }
    assert in_flight_line.chomp.end_with?("...")
    assert_operator visible_width(in_flight_line.chomp), :<=, 42
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

  def test_every_broad_status_uses_the_same_single_line_headline_rule
    statuses = %w[
      COMPLETE CANDIDATE NEEDS_JUDGMENT IN_FLIGHT READY PREPARED STALE
      STALE_CANDIDATE BLOCKED FAILED
    ]
    statuses.each do |status|
      item = {
        "id" => "T1",
        "status" => status,
        "title" => "A very long\nheadline\twith repeated   whitespace and TRAILINGTITLEWORD"
      }
      case status
      when "NEEDS_JUDGMENT", "FAILED"
        item["reason"] = "Short reason"
        item["next_action"] = "Take the next action" if status == "NEEDS_JUDGMENT"
        item["state"] = { "result" => { "outcome" => status.downcase } }
      when "IN_FLIGHT"
        item["reason"] = "In-flight diagnostic remains subordinate"
      when "STALE", "STALE_CANDIDATE"
        item["reason"] = "pushed branch changed: alpha"
      when "BLOCKED"
        item["reason"] = "dependencies incomplete: A"
      end
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new,
                                     terminal_width: 44)
      cli.instance_variable_set(:@coordinator, fake_status_coordinator([item]))

      assert_equal 0, cli.run(%w[status --all]), status
      headline, *details = out.string.lines.map(&:chomp)
      assert headline.end_with?("..."), status
      assert_operator visible_width(headline), :<=, 44, status
      refute_includes headline, "\n", status
      refute_includes headline, "\t", status
      refute details.any? { |line| line.include?("TRAILINGTITLEWORD") }, status
    end
  end

  def test_headline_truncation_adapts_to_three_terminal_widths_and_preserves_fitting_titles
    long_status = {
      "id" => "P1", "status" => "PREPARED",
      "title" => "A prepared headline whose final words must never wrap onto another line"
    }
    headlines = [72, 46, 24].map do |width|
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new,
                                     terminal_width: width)
      cli.instance_variable_set(:@coordinator, fake_status_coordinator([long_status]))

      assert_equal 0, cli.run(%w[status])
      assert_equal 1, out.string.lines.length
      headline = out.string.chomp
      assert headline.end_with?("...")
      assert_operator visible_width(headline), :<=, width
      headline
    end
    assert_equal 3, headlines.uniq.length

    fitting = { "id" => "S1", "status" => "STALE", "title" => "Short title" }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new,
                                   terminal_width: 80)
    cli.instance_variable_set(:@coordinator, fake_status_coordinator([fitting]))
    assert_equal 0, cli.run(%w[status])
    assert_equal "S1: STALE — Short title\n", out.string
    refute_includes out.string, "..."
  end

  def test_headline_truncation_handles_ansi_wide_unicode_and_combining_graphemes
    title = "\e[35m#{("界e\u0301" * 20)}\e[0m"
    status = { "id" => "R1", "status" => "READY", "title" => title }
    coordinator = fake_status_coordinator([status])
    plain = StringIO.new
    plain_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out: plain, err: StringIO.new,
                                         terminal_width: 37)
    plain_cli.instance_variable_set(:@coordinator, coordinator)
    tty = TTYOutput.new(37)
    color_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out: tty, err: StringIO.new)
    color_cli.instance_variable_set(:@coordinator, coordinator)
    previous_no_color = ENV.delete("NO_COLOR")

    assert_equal 0, plain_cli.run(%w[status])
    assert_equal 0, color_cli.run(%w[status])
    plain_headline = plain.string.lines.first.chomp
    color_headline = tty.string.lines.first.chomp
    assert plain_headline.end_with?("...")
    assert_operator visible_width(plain_headline), :<=, 37
    assert_operator visible_width(color_headline), :<=, 37
    assert_includes plain_headline, "\e[0m..."
    assert_equal strip_ansi(plain_headline), strip_ansi(color_headline)
    final_cluster = strip_ansi(plain_headline.delete_suffix("...")).scan(/\X/).last
    refute final_cluster.match?(/\A\p{M}/)
  ensure
    ENV["NO_COLOR"] = previous_no_color if previous_no_color
  end

  def test_explicit_status_preserves_full_title_and_diagnostic
    title = "A complete original title that is much wider than the requested dashboard width"
    reason = "pushed branch changed: alpha"
    status = { "id" => "S1", "status" => "STALE", "title" => title, "reason" => reason }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new,
                                   terminal_width: 20)
    cli.instance_variable_set(:@coordinator, fake_status_coordinator([status]))

    assert_equal 0, cli.run(%w[status S1])
    assert_equal "S1: STALE — #{title}\n    #{reason}\n", out.string
  end

  def test_status_compacts_needs_judgment_handoff_at_dynamic_widths
    status = {
      "id" => "IG-09C",
      "status" => "NEEDS_JUDGMENT",
      "title" => "Successor boundary",
      "reason" => "Missing authoritative successor-version binding.\nAdditional\t evidence   remains unresolved.",
      "next_action" => "Land IG-05C4, then retry IG-09C after the authoritative binding is available.",
      "state" => { "result" => { "outcome" => "needs_judgment" } }
    }
    coordinator = fake_status_coordinator([status])
    rendered = [76, 52, 32].to_h do |width|
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new,
                                     terminal_width: width)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run(%w[status --all])
      detail_lines = out.string.lines.map(&:chomp).select do |line|
        line.match?(/\A    (?:reason|next|resume):/)
      end
      assert_equal 3, detail_lines.length
      assert_equal 1, detail_lines.count { |line| line.start_with?("    reason: ") }
      assert_equal 1, detail_lines.count { |line| line.start_with?("    next: ") }
      assert detail_lines.first.end_with?("...")
      assert detail_lines.fetch(1).end_with?("...")
      detail_lines.each { |line| assert_operator visible_width(line), :<=, width }
      refute_includes out.string, "Additional\n"
      [width, detail_lines]
    end

    assert_equal 3, rendered.values.map { |lines| lines.first }.uniq.length
  end

  def test_status_keeps_fitting_needs_judgment_reason_and_omits_missing_next_action
    status = {
      "id" => "J1", "status" => "NEEDS_JUDGMENT", "title" => "Judgment",
      "reason" => "Short reason.",
      "state" => { "result" => { "outcome" => "needs_judgment" } }
    }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new,
                                   terminal_width: 80)
    cli.instance_variable_set(:@coordinator, fake_status_coordinator([status]))

    assert_equal 0, cli.run(%w[status])
    assert_includes out.string, "    reason: Short reason.\n"
    refute_includes out.string, "    next:"
    refute_includes out.string.lines.find { |line| line.include?("reason:") }, "..."
  end

  def test_status_bounds_needs_judgment_details_for_extreme_widths_and_ansi_unicode
    status = {
      "id" => "J1", "status" => "NEEDS_JUDGMENT", "title" => "J",
      "reason" => "\e[31m界界界界界界\e[0m unresolved authority",
      "next_action" => "retry after owner approval",
      "state" => { "result" => { "outcome" => "needs_judgment" } }
    }
    coordinator = fake_status_coordinator([status])

    [1, 2, 3, 8, 18].each do |width|
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new,
                                     terminal_width: width)
      cli.instance_variable_set(:@coordinator, coordinator)
      assert_equal 0, cli.run(%w[status])

      assert_operator visible_width(out.string.lines.first.chomp), :<=, width
      out.string.lines.map(&:chomp).last(3).each do |line|
        assert_operator visible_width(line), :<=, width
      end
    end

    tty = TTYOutput.new(30)
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out: tty, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, coordinator)
    previous_no_color = ENV.delete("NO_COLOR")
    assert_equal 0, cli.run(%w[status])
    reason = tty.string.lines.find { |line| line.include?("reason:") }
    assert reason.chomp.end_with?("...")
    assert_operator visible_width(reason.chomp), :<=, 30
    assert_includes tty.string, "\e[33mNEEDS_JUDGMENT\e[0m"
  ensure
    ENV["NO_COLOR"] = previous_no_color if previous_no_color
  end

  def test_needs_judgment_broad_status_truncates_but_explicit_status_preserves_full_details
    with_workspace do |dir|
      write_task(dir, id: "IG-09C", title: "Successor boundary")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("IG-09C")
      summary = "Missing authoritative successor-version binding. " \
                "This legacy-style explanation contains all evidence and must remain stored."
      next_action = "Land IG-05C4, then retry IG-09C.\nConfirm the authoritative binding first."
      coordinator.record("IG-09C", outcome: "needs_judgment", summary:, next_action:)
      state_path = AgentCodingTool::StateStore.new(File.join(dir, "state")).state_path("IG-09C")
      stored_state = File.binread(state_path)

      broad = StringIO.new
      broad_cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out: broad, err: StringIO.new,
                                           terminal_width: 54)
      broad_cli.instance_variable_set(:@coordinator, coordinator)
      assert_equal 0, broad_cli.run(%w[status --all])
      assert broad.string.lines.find { |line| line.include?("reason:") }.chomp.end_with?("...")
      refute_includes broad.string, summary

      explicit = run_status(dir, coordinator, %w[status IG-09C])
      assert_includes explicit, "    reason: #{summary}\n"
      assert_includes explicit, "    next: Land IG-05C4, then retry IG-09C.\n"
      assert_includes explicit, "          Confirm the authoritative binding first.\n"
      assert_includes explicit, "    resume: act prepare IG-09C --retry\n"
      state = coordinator.status("IG-09C").fetch("state")
      assert_equal summary, state.dig("result", "summary")
      assert_equal next_action, state.dig("result", "next_action")
      assert_equal stored_state, File.binread(state_path)
    end
  end

  def test_dependency_only_blocked_status_does_not_show_retry_guidance
    status = {
      "id" => "B1", "status" => "BLOCKED", "title" => "Waiting",
      "reason" => "dependencies incomplete: A", "state" => {}
    }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, fake_status_coordinator([status]))

    assert_equal 0, cli.run(%w[status --all])
    assert_includes out.string, "    waiting on: A\n"
    refute_includes out.string, "resume:"
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
    assert plain.string.chomp.end_with?("...")
    assert_operator visible_width(plain.string.chomp), :<=, 36
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
    assert_equal ["F1: IN_FL..."], out.string.lines.map(&:chomp)
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
      "K1: CANDIDATE — A candidate tit...",
      "    downstream: 0 levels / 0",
      "    tasks; unlocks: 0 tasks / 0",
      "    parallel"
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
    assert_includes out.string,
                    "R-DEEP: READY — Deep\n    downstream: 4 levels / 4 tasks; unlocks: 0 tasks / 0 parallel\n"
    assert_includes out.string,
                    "R-DIAMOND: READY — Diamond\n    downstream: 2 levels / 3 tasks; unlocks: 0 tasks / 0 parallel\n"
    assert_includes out.string,
                    "R-CYCLE: READY — Cycle\n    downstream: 1 level / 1 task; unlocks: 0 tasks / 0 parallel\n"
    assert_operator out.string.index("K: CANDIDATE"), :<, out.string.index("F: IN_FLIGHT")
    assert_operator out.string.index("F: IN_FLIGHT"), :<, out.string.index("R-DEEP: READY")
    assert_operator out.string.index("R-STABLE-A: READY"), :<, out.string.index("B: BLOCKED")
  end

  def test_status_displays_completion_metrics_for_fresh_candidates_without_reordering_them
    statuses = [
      { "id" => "K2", "status" => "CANDIDATE", "title" => "Second candidate" },
      { "id" => "S1", "status" => "STALE_CANDIDATE", "title" => "Stale candidate" },
      { "id" => "K1", "status" => "CANDIDATE", "title" => "First candidate" },
      { "id" => "R1", "status" => "READY", "title" => "Ready" }
    ]
    tasks = [
      task_definition("K1"), task_definition("D1", ["K1"]), task_definition("D2", ["D1"]),
      task_definition("K2"), task_definition("S1"), task_definition("R1")
    ]
    unlock_metrics = {
      "K1" => { "unlock_count" => 1, "parallel_width" => 1 },
      "K2" => { "unlock_count" => 0, "parallel_width" => 0 },
      "R1" => { "unlock_count" => 0, "parallel_width" => 0 }
    }
    coordinator = fake_status_coordinator(statuses, tasks:, unlock_metrics:)
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, coordinator)

    assert_equal 0, cli.run(%w[status --active])

    candidate_ids = out.string.lines.filter_map { |line| line[/\A([^:]+): CANDIDATE/, 1] }
    assert_equal %w[K2 K1], candidate_ids
    assert_includes out.string,
                    "K2: CANDIDATE — Second candidate\n" \
                    "    downstream: 0 levels / 0 tasks; unlocks: 0 tasks / 0 parallel\n"
    assert_includes out.string,
                    "K1: CANDIDATE — First candidate\n" \
                    "    downstream: 2 levels / 2 tasks; unlocks: 1 task / 1 parallel\n"
    assert_includes out.string, "S1: STALE_CANDIDATE — Stale candidate\n"
    refute_includes out.string,
                    "S1: STALE_CANDIDATE — Stale candidate\n    downstream:"
  end

  def test_status_ranks_ready_tasks_by_parallel_width_then_unlock_count_before_downstream_metrics
    statuses = [
      { "id" => "R-DEEP", "status" => "READY", "title" => "Deep" },
      { "id" => "R-WIDTH", "status" => "READY", "title" => "Parallel width" },
      { "id" => "R-COUNT", "status" => "READY", "title" => "Unlock count" }
    ]
    tasks = [
      task_definition("R-DEEP"), task_definition("D1", ["R-DEEP"]),
      task_definition("D2", ["D1"]), task_definition("D3", ["D2"]),
      task_definition("R-WIDTH"), task_definition("R-COUNT")
    ]
    unlock_metrics = {
      "R-DEEP" => { "unlock_count" => 1, "parallel_width" => 1 },
      "R-WIDTH" => { "unlock_count" => 2, "parallel_width" => 2 },
      "R-COUNT" => { "unlock_count" => 4, "parallel_width" => 1 }
    }
    coordinator = fake_status_coordinator(statuses, tasks:, unlock_metrics:)
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
    cli.instance_variable_set(:@coordinator, coordinator)

    assert_equal 0, cli.run(%w[status --active])

    visible_ready = out.string.lines.filter_map { |line| line[/\A(R-[^:]+): READY/, 1] }
    assert_equal %w[R-WIDTH R-COUNT R-DEEP], visible_ready
    assert_includes out.string,
                    "R-WIDTH: READY — Parallel width\n" \
                    "    downstream: 0 levels / 0 tasks; unlocks: 2 tasks / 2 parallel\n"
    assert_includes out.string,
                    "R-COUNT: READY — Unlock count\n" \
                    "    downstream: 0 levels / 0 tasks; unlocks: 4 tasks / 1 parallel\n"
    assert_includes out.string,
                    "R-DEEP: READY — Deep\n" \
                    "    downstream: 3 levels / 3 tasks; unlocks: 1 task / 1 parallel\n"
  end

  def test_status_displays_retained_completions_oldest_to_newest_after_unrankable_rows
    with_workspace do |dir|
      timestamps = {
        "C1" => "2026-10-07T15:00:00Z",
        "C2" => "2026-10-07T10:00:00Z",
        "C3" => "2026-10-07T14:00:00Z",
        "C4" => "2026-10-07T11:00:00Z",
        "C5" => "2026-10-07T13:00:00Z",
        "C6" => "2026-10-07T12:00:00Z"
      }
      timestamps.each_key { |id| write_task(dir, id:) }
      write_task(dir, id: "MALFORMED")
      write_task(dir, id: "MISSING")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      timestamps.each { |id, timestamp| record_complete_at(dir, coordinator, id, timestamp) }
      record_complete_at(dir, coordinator, "MALFORMED", "not-a-time")
      record_complete_at(dir, coordinator, "MISSING", nil)

      default_ids = complete_ids(run_status(dir, coordinator, %w[status]))
      all_ids = complete_ids(run_status(dir, coordinator, %w[status --all]))
      active_out = run_status(dir, coordinator, %w[status --active])

      assert_equal %w[MALFORMED MISSING C4 C6 C5 C3 C1], default_ids
      refute_includes default_ids, "C2"
      assert_equal "C1", default_ids.last
      assert_equal %w[MALFORMED MISSING C2 C4 C6 C5 C3 C1], all_ids
      refute_includes active_out, "COMPLETE"
    end
  end

  def test_status_orders_five_or_fewer_timestamped_completions_oldest_to_newest
    with_workspace do |dir|
      timestamps = {
        "C1" => "2026-10-07T12:00:00Z",
        "C2" => "2026-10-07T10:00:00Z",
        "C3" => "2026-10-07T11:00:00Z"
      }
      timestamps.each_key { |id| write_task(dir, id:) }
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      timestamps.each { |id, timestamp| record_complete_at(dir, coordinator, id, timestamp) }

      assert_equal %w[C2 C3 C1], complete_ids(run_status(dir, coordinator, %w[status]))
    end
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

  def test_status_dashboards_show_live_blocker_without_treating_prepared_tasks_as_blockers
    with_workspace do |dir|
      %w[IG-09C IG-07A IG-11C].each { |id| write_task(dir, id:, title: "Pipeline work") }
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      %w[IG-09C IG-07A IG-11C].each { |id| coordinator.prepare(id) }
      coordinator.start("IG-09C")

      [%w[status], %w[status --active], %w[status --all]].each do |argv|
        output = run_status(dir, coordinator, argv)
        assert_includes output,
                        "IG-07A: PREPARED (NEXT) — Pipeline work\n" \
                        "    reason: cannot start; IG-09C (IN_FLIGHT) writes alpha\n"
        assert_includes output,
                        "IG-11C: PREPARED — Pipeline work\n" \
                        "    reason: cannot start; IG-09C (IN_FLIGHT) writes alpha\n"
        refute_includes output, "cannot start; IG-07A"
        refute_includes output, "cannot start; IG-11C"
      end
    end
  end

  def test_collision_reason_is_width_bounded_and_unicode_and_ansi_aware
    status = {
      "id" => "P1", "status" => "PREPARED", "title" => "Prepared work",
      "write_collisions" => [{
        "task_id" => "RUNNER", "status" => "IN_FLIGHT",
        "repositories" => ["\e[31m界界界界界\e[0m-repository"]
      }]
    }
    coordinator = fake_status_coordinator([status])
    saw_ansi_repository = false

    [34, 52, 84].each do |width|
      out = TTYOutput.new(width)
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run(%w[status --all])
      reason = out.string.lines.find { |line| strip_ansi(line).include?("reason:") }.chomp
      assert_operator visible_width(reason), :<=, width
      assert_equal 1, out.string.lines.count { |line| strip_ansi(line).include?("reason:") }
      assert reason.end_with?("...") if width < 84
      if reason.include?("\e[31m")
        saw_ansi_repository = true
        assert_includes reason, "\e[0m"
      end
    end
    assert saw_ansi_repository
  end

  def test_multiple_blockers_are_counted_in_broad_status_and_complete_in_explicit_status
    status = {
      "id" => "P1", "status" => "PREPARED", "title" => "Prepared work",
      "write_collisions" => [
        { "task_id" => "A", "status" => "IN_FLIGHT", "repositories" => %w[alpha beta] },
        { "task_id" => "C", "status" => "CANDIDATE", "repositories" => ["gamma"] }
      ]
    }
    coordinator = fake_status_coordinator([status])
    broad = StringIO.new
    broad_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out: broad, err: StringIO.new,
                                         terminal_width: 58)
    broad_cli.instance_variable_set(:@coordinator, coordinator)

    assert_equal 0, broad_cli.run(%w[status --all])
    reason = broad.string.lines.find { |line| line.include?("reason:") }.chomp
    assert_includes reason, "cannot start; 2 blockers:"
    assert reason.end_with?("...")
    assert_operator visible_width(reason), :<=, 58

    explicit = StringIO.new
    explicit_cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out: explicit, err: StringIO.new,
                                            terminal_width: 20)
    explicit_cli.instance_variable_set(:@coordinator, coordinator)
    assert_equal 0, explicit_cli.run(%w[status P1])
    assert_includes explicit.string, "    reason: cannot start; A (IN_FLIGHT) writes alpha, beta\n"
    assert_includes explicit.string, "    reason: cannot start; C (CANDIDATE) writes gamma\n"
  end

  def test_read_only_refresh_and_collision_are_distinct_dashboard_diagnostics
    status = {
      "id" => "P1", "status" => "PREPARED", "title" => "Prepared work",
      "reason" => "read-only pushed branch changed; refresh and reconcile materially affected findings before finalizing: docs",
      "write_collisions" => [{
        "task_id" => "A", "status" => "IN_FLIGHT", "repositories" => ["pipeline"]
      }]
    }
    out = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: Dir.pwd, out:, err: StringIO.new,
                                   terminal_width: 100)
    cli.instance_variable_set(:@coordinator, fake_status_coordinator([status]))

    assert_equal 0, cli.run(%w[status --all])
    assert_includes out.string, "read-only pushed branch changed"
    assert_includes out.string, "    reason: cannot start; A (IN_FLIGHT) writes pipeline\n"
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

  def fake_status_coordinator(statuses, tasks: [], unlock_metrics: {})
    coordinator = Object.new
    coordinator.define_singleton_method(:statuses) do |ids = nil, **_kwargs|
      ids ? statuses.select { |status| ids.include?(status.fetch("id")) } : statuses
    end
    coordinator.define_singleton_method(:tasks) { tasks }
    coordinator.define_singleton_method(:completion_unlock_metrics) { |_statuses| unlock_metrics }
    coordinator
  end

  def visible_width(text)
    AgentCodingTool::CLI.allocate.send(:display_width, text)
  end

  def strip_ansi(text)
    text.gsub(/\e\[[0-?]*[ -\/]*[@-~]/, "")
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

  def record_complete_at(dir, coordinator, id, timestamp)
    coordinator.record(id, outcome: "complete")
    store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
    state = store.load(id)
    if timestamp
      state.fetch("result")["recorded_at"] = timestamp
    else
      state.fetch("result").delete("recorded_at")
    end
    store.write(id, state)
  end

  def complete_ids(output)
    output.lines.filter_map { |line| line[/\A([^:]+): COMPLETE/, 1] }
  end
end
