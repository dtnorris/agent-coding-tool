# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class StatusNextSummaryTest < Minitest::Test
  include TestHelpers

  class ProbeInspector < FakeInspector
    attr_reader :snapshot_calls, :head_batches

    def snapshot(name, spec)
      (@snapshot_calls ||= []) << name
      super
    end

    def pushed_heads(references)
      (@head_batches ||= []) << references
      super
    end

    def reset_counts
      @snapshot_calls = []
      @head_batches = []
    end
  end

  class TTYOutput < StringIO
    def initialize(width)
      @width = width
      super()
    end

    def tty? = true
    def winsize = [24, @width]
  end

  def test_status_and_next_select_same_priority_preserving_parallel_set_without_extra_probes
    with_workspace do |dir|
      write_task(dir, id: "A", repositories: repo("alpha"))
      write_task(dir, id: "B", repositories: repo("beta"))
      write_task(dir, id: "C", repositories: repo("alias"))
      write_task(dir, id: "D", repositories: repo("prepared"))
      inspector = ProbeInspector.new(heads: { "prepared" => "a" * 40 },
                                    remote_urls: { "alias" => remote("alpha") })
      coordinator = coordinator_for_inspector(dir, inspector)
      coordinator.prepare("D")
      inspector.reset_counts
      before = state_bytes(dir)

      dashboard = output_for(dir, coordinator, %w[status])
      refute_match(/^NEXT:/, dashboard)
      assert_match(/^A: READY \(NEXT\) — Task$/, dashboard)
      assert_match(/^B: READY — Task$/, dashboard)
      assert_match(/^C: READY — Task$/, dashboard)
      assert_match(/^D: PREPARED — Task$/, dashboard)
      assert_equal 1, dashboard.scan("(NEXT)").length
      assert_equal 1, inspector.head_batches.length
      assert_empty inspector.snapshot_calls
      assert_equal before, state_bytes(dir)

      next_output = output_for(dir, coordinator, %w[next])
      assert_equal %w[A B D], next_output.lines.filter_map { |line| line[/^  ([A-Z]) \((?:READY|PREPARED)\) —/, 1] }
      assert_includes next_output, "C (READY): A (SELECTED)"
      assert_equal 2, inspector.head_batches.length
      assert_empty inspector.snapshot_calls
      assert_equal dashboard, output_for(dir, coordinator, %w[status])
      assert_equal before, state_bytes(dir)
    end
  end

  def test_prepared_task_gets_start_action_without_reprepare
    with_workspace do |dir|
      write_task(dir, id: "A")
      coordinator = coordinator_for_inspector(dir, ProbeInspector.new(heads: { "alpha" => "a" * 40 }))
      coordinator.prepare("A")

      assert_match(/^A: PREPARED \(NEXT\) — Task$/,
                   output_for(dir, coordinator, %w[status]))
      assert_includes output_for(dir, coordinator, %w[next]), "    act start A"
    end
  end

  def test_candidate_review_and_occupied_capacity_are_not_presented_as_completion
    with_workspace do |dir|
      write_task(dir, id: "A-CANDIDATE", repositories: repo("candidate"))
      write_task(dir, id: "B-WAIT", repositories: repo("alias"))
      inspector = ProbeInspector.new(heads: { "candidate" => "a" * 40 },
                                    remote_urls: { "alias" => remote("candidate") })
      coordinator = coordinator_for_inspector(dir, inspector)
      coordinator.prepare("A-CANDIDATE")
      coordinator.record("A-CANDIDATE", outcome: "candidate_complete")

      dashboard = output_for(dir, coordinator, %w[status])
      refute_match(/^NEXT:/, dashboard)
      assert_match(/^A-CANDIDATE: CANDIDATE \(NEXT\) — Task$/, dashboard)
      assert_match(/^B-WAIT: READY — Task$/, dashboard)
      assert_includes output_for(dir, coordinator, %w[next]), "Waiting for write capacity:"
      refute_includes dashboard, "act finish"
    end
  end

  def test_running_writer_and_judgment_each_explain_no_available_start
    with_workspace do |dir|
      write_task(dir, id: "A-RUN", repositories: repo("run"))
      write_task(dir, id: "B-WAIT", repositories: repo("alias"))
      inspector = ProbeInspector.new(heads: { "run" => "a" * 40 },
                                    remote_urls: { "alias" => remote("run") })
      coordinator = coordinator_for_inspector(dir, inspector)
      coordinator.prepare("A-RUN")
      coordinator.start("A-RUN")
      assert_match(/^B-WAIT: READY \(NEXT\) — Task$/,
                   output_for(dir, coordinator, %w[status]))
    end

    with_workspace do |dir|
      write_task(dir, id: "A-JUDGMENT")
      coordinator = coordinator_for_inspector(dir, ProbeInspector.new(heads: { "alpha" => "a" * 40 }))
      coordinator.prepare("A-JUDGMENT")
      coordinator.record("A-JUDGMENT", outcome: "needs_judgment", summary: "choose scope",
                         next_action: "ask operator")
      dashboard = output_for(dir, coordinator, %w[status])
      assert_match(/^A-JUDGMENT: NEEDS_JUDGMENT \(NEXT\) — Task$/, dashboard)
      assert_includes dashboard, "ask operator"
      assert_includes dashboard, "resume: act prepare A-JUDGMENT --retry"
    end
  end

  def test_stale_preparation_and_dependency_wait_are_truthful
    with_workspace do |dir|
      write_task(dir, id: "A-STALE")
      heads = { "alpha" => "a" * 40 }
      coordinator = coordinator_for_inspector(dir, ProbeInspector.new(heads:))
      coordinator.prepare("A-STALE")
      heads["alpha"] = "b" * 40
      assert_match(/^A-STALE: STALE \(NEXT\) — Task$/,
                   output_for(dir, coordinator, %w[status]))
    end

    with_workspace do |dir|
      write_task(dir, id: "A", depends_on: ["B"])
      write_task(dir, id: "B", depends_on: ["A"])
      coordinator = coordinator_for_inspector(dir, ProbeInspector.new(heads: {}))
      dashboard = output_for(dir, coordinator, %w[status])
      refute_match(/^NEXT:/, dashboard)
      refute_includes dashboard, "(NEXT)"
    end
  end

  def test_width_color_no_color_and_explicit_status_behavior
    with_workspace do |dir|
      write_task(dir, id: "A")
      coordinator = coordinator_for_inspector(dir, ProbeInspector.new(heads: {}))
      previous = ENV.delete("NO_COLOR")
      begin
        [12, 20, 38].each do |width|
          out = TTYOutput.new(width)
          dashboard = output_for(dir, coordinator, %w[status], out:)
          first = dashboard.lines.first.chomp
          assert_operator AgentCodingTool::CLI.allocate.send(:display_width, first), :<=, width
          refute_includes dashboard, "NEXT:"
        end
        colored = output_for(dir, coordinator, %w[status], out: TTYOutput.new(80))
        assert_match(/A: \e\[\d+mREADY\e\[0m \(NEXT\) — Task/, colored.lines.first)
        assert_equal 1, colored.scan("(NEXT)").length
        ENV["NO_COLOR"] = "1"
        plain = output_for(dir, coordinator, %w[status], out: TTYOutput.new(80))
        refute_match(/\e\[/, plain)
        assert_match(/^A: READY \(NEXT\) — Task$/, plain)
        explicit = output_for(dir, coordinator, %w[status A])
        refute_includes explicit, "(NEXT)"
        assert_match(/\AA: READY/, explicit)
      ensure
        previous ? ENV["NO_COLOR"] = previous : ENV.delete("NO_COLOR")
      end
    end
  end

  private

  def repo(name) = { name => { "access" => "write" } }
  def remote(name) = "git@github.com:example/#{name}.git"

  def coordinator_for_inspector(dir, inspector)
    AgentCodingTool::Coordinator.new(
      task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
      state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
      repo_inspector: inspector,
      prompt_renderer: AgentCodingTool::PromptRenderer.new,
      prompt_root: File.join(dir, "state", "prompts")
    )
  end

  def output_for(dir, coordinator, args, out: StringIO.new)
    err = StringIO.new
    cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err:)
    cli.instance_variable_set(:@coordinator, coordinator)
    assert_equal 0, cli.run(args), err.string
    assert_empty err.string
    out.string
  end

  def state_bytes(dir)
    Dir.glob(File.join(dir, "state", "*.yml")).sort.to_h { |path| [File.basename(path), File.binread(path)] }
  end
end
