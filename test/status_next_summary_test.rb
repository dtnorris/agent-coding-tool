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
      assert_includes output_for(dir, coordinator, %w[next]), "Additional manual parallel work:"
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

  # Public dashboards must separate stale starts while preserving prepared,
  # candidate, terminal and dependency semantics; CLI failures fail assertions.
  def test_stale_preparation_and_dependency_wait_are_truthful
    assert_stale_in_flight_groups

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

  # Drives real CLI preparation/start/status/next handoffs with only pushed Git
  # observations faked. Checks lifecycle, multiple identities, narrow/color output
  # and byte-preserved persisted evidence; unexpected command failures fail tests.
  def test_started_stale_source_is_visible_without_changing_eligibility_or_state
    with_workspace do |dir|
      write_task(dir, id: "A", repositories: repo("alpha").merge(repo("beta")))
      heads = { "alpha" => "a" * 40, "beta" => "c" * 40 }
      inspector = ProbeInspector.new(heads:)
      coordinator = coordinator_for_inspector(dir, inspector)
      output_for(dir, coordinator, %w[prepare A])
      output_for(dir, coordinator, %w[start A])
      clean = output_for(dir, coordinator, %w[status A])
      assert_match(/^A: IN_FLIGHT — Task$/, clean)
      refute_includes clean, "STALE"

      # Retained metadata need not be independently valid to prove status reads
      # preserve its exact bytes. This is not host checkpoint verification.
      store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      state = store.load("A")
      state["checkpoint"] = { "status" => "verified", "attempt" => "fixture" }
      state["history"] = [{ "summary" => "prior evidence" }]
      store.write("A", state)
      before = Dir.glob(File.join(dir, "state", "**", "*")).select { |path| File.file?(path) }
                  .to_h { |path| [path, File.binread(path)] }
      heads.merge!("alpha" => "b" * 40, "beta" => "d" * 40)
      inspector.reset_counts

      dashboards = [%w[status], %w[status --all], %w[status --fam A]].map do |args|
        output_for(dir, coordinator, args)
      end
      explicit = output_for(dir, coordinator, %w[status A])
      dashboards.each do |output|
        assert_match(/^A: IN_FLIGHT \(STALE\)/, output)
        assert_equal 2, output.lines.grep(/^    /).length
        assert_includes output, "2 changed; act stat A; alpha: aaaaaaaa -> bbbbbbbb (main changed)"
        assert_includes output, "reconcile before delivery; liveness unknown; isolation unverified"
        refute_match(/git@|[a-f0-9]{40}|pushed branch changed|execution:/, output)
      end
      assert_includes explicit, "reconcile writable source and renew validation before delivery"
      assert_includes explicit, "isolation unverified; liveness unknown"
      %w[alpha beta].each do |name|
        assert_includes explicit, "source #{name}: #{remote(name)} [main]"
        assert_includes explicit, "prepared pushed: #{state.fetch('snapshot').fetch(name).fetch('pushed_sha')}"
        assert_includes explicit, "current pushed:  #{heads.fetch(name)}"
      end
      assert_equal 4, inspector.head_batches.length
      assert_empty inspector.snapshot_calls

      previous = ENV.delete("NO_COLOR")
      begin
        [false, true].each do |no_color|
          no_color ? ENV["NO_COLOR"] = "1" : ENV.delete("NO_COLOR")
          [1, 2, 3, 12, 20, 38, 80, 100, 160].each do |width|
            output = output_for(dir, coordinator, %w[status], out: TTYOutput.new(width))
            lines = output.lines.first(3).map(&:chomp)
            assert_equal 3, lines.length
            lines.each do |line|
              assert_operator AgentCodingTool::CLI.allocate.send(:display_width, line), :<=, width
            end
            assert_includes lines.first, "STALE" if width >= 12
            assert_includes lines[1], "2 changed" if width >= 38
            assert_includes lines[2], "reconcile before delivery" if width >= 38
            assert_includes lines[2], "liveness unknown" if width >= 80
            refute_match(/git@|[a-f0-9]{40}|pushed branch changed|execution:/, output)
            if no_color
              refute_match(/\e\[/, output)
            elsif width == 80
              assert_includes output, "\e[31mIN_FLIGHT (STALE)\e[0m"
            end
          end
        end
      ensure
        previous ? ENV["NO_COLOR"] = previous : ENV.delete("NO_COLOR")
      end

      status = coordinator.status("A")
      assert_equal "STALE", status.fetch("status")
      assert_equal "IN_FLIGHT", status.fetch("lifecycle_status")
      assert_equal %w[alpha beta], status.fetch("writable_source_changes").map { |row| row.fetch("repository") }
      assert_includes output_for(dir, coordinator, %w[next]), "A (IN_FLIGHT (STALE))"
      document = JSON.parse(output_for(dir, coordinator, %w[next --json]))
      assert_empty document.dig("recommendations", "starts")
      assert_empty document.dig("facts", "reservations")
      assert_equal "STALE", document.dig("facts", "tasks", 0, "status")
      assert_equal before, before.keys.to_h { |path| [path, File.binread(path)] }
      assert_equal state, store.load("A")

      # These persisted observations exercise historical launch/overlap wording,
      # without launching a worker or asserting that the observations are current.
      state["write_collision_override"] = { "launch" => { "attempt" => "historical" },
                                            "conflicts" => [{ "task_id" => "PEER" }] }
      state["write_overlap"] = { "basis" => "manual override", "observed_at" => "2026-01-01T00:00:00Z",
                                 "conflicts" => [{ "task_id" => "PEER", "status" => "IN_FLIGHT" }] }
      store.write("A", state)
      historical = output_for(dir, coordinator, %w[status])
      assert_equal 2, historical.lines.grep(/^    /).length
      assert_includes historical, "liveness unknown; isolation last verified at launch"
      refute_includes historical, "overlap:"
      explicit = output_for(dir, coordinator, %w[status A])
      assert_includes explicit, "last verified ACT launch; current liveness unavailable"
      assert_includes explicit, "manual override with PEER (IN_FLIGHT); observed 2026-01-01T00:00:00Z; not a live isolation check"
      state["write_collision_override"]["launch"]["unverified_manual_conflicts"] = true
      store.write("A", state)
      assert_includes output_for(dir, coordinator, %w[status]), "liveness unknown; isolation unverified"

      output_for(dir, coordinator, %w[external report A --reporter fixture --kind fake-worker])
      external_before = state_bytes("#{dir}-runs")
      external = output_for(dir, coordinator, %w[status --all], terminal_width: 38)
      # Independent activity warnings intentionally retain their full contract,
      # including lines wider than this terminal; the stale details stay bounded.
      assert_includes external, "EXTERNAL WORK REPORTED: unmanaged; unauthorized by ACT"
      assert_includes external, "isolation unverified; containment unverified; liveness unknown"
      assert_includes external, "CONFLICT: managed execution also recorded"
      assert_equal 1, external.scan("source:").length
      assert_equal 1, external.scan("next:").length
      assert_equal external_before, state_bytes("#{dir}-runs")
    end
  end

  # Exercises configured/detected widths and color with real CLI projections;
  # explicit inspection keeps its established untruncated details.
  def test_width_color_no_color_and_explicit_status_behavior
    assert_unusual_stale_widths

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

  # Uses public CLI transitions and real projection/sorting/rendering with only
  # Git observations faked. Reads must preserve all evidence bytes and next JSON;
  # unexpected command failures fail assertions rather than being ignored.
  def assert_stale_in_flight_groups
    with_workspace do |dir|
      ids = (1..11).map { |number| "ACT-%02d" % number }
      ids.each { |id| write_task(dir, id:, repositories: repo(id)) }
      heads = ids.to_h { |id| [id, "a" * 40] }
      inspector = ProbeInspector.new(heads:, remote_urls: { "ACT-03" => remote("ACT-02") })
      coordinator = coordinator_for_inspector(dir, inspector)
      (ids - ["ACT-03"]).each { |id| output_for(dir, coordinator, ["prepare", id]) }
      %w[ACT-02 ACT-04 ACT-06 ACT-08].each { |id| output_for(dir, coordinator, ["start", id]) }
      { "ACT-01" => "complete", "ACT-05" => "needs_judgment",
        "ACT-09" => "candidate_complete", "ACT-10" => "failed",
        "ACT-11" => "candidate_complete" }.each do |id, outcome|
        output_for(dir, coordinator, ["record", id, outcome, "--summary", "operator evidence"])
      end
      %w[ACT-02 ACT-06 ACT-07 ACT-09].each { |id| heads[id] = "b" * 40 }
      before = state_bytes(dir)
      facts = coordinator.statuses
      next_before = output_for(dir, coordinator, %w[next --json])
      document = JSON.parse(next_before)
      assert_equal ["ACT-03"], document.dig("recommendations", "starts").map { |row| row.fetch("id") }
      refute document.dig("facts", "reservations").any? { |row| %w[ACT-02 ACT-06].include?(row.fetch("id")) }
      inspector.reset_counts
      dashboards = [%w[status], %w[status --all], %w[status --fam ACT], %w[status --all --fam ACT]].map do |args|
        output_for(dir, coordinator, args)
      end
      dashboards.each do |dashboard|
        assert_equal %w[ACT-01 ACT-11 ACT-05 ACT-04 ACT-08 ACT-02 ACT-06 ACT-03 ACT-09 ACT-07 ACT-10],
                     dashboard.lines.filter_map { |line| line[/^(ACT-\d+):/, 1] }
        assert_includes dashboard, "    execution: isolation unverified; liveness unknown\n\nACT-02: IN_FLIGHT (STALE)"
        assert_match(/ACT-06: IN_FLIGHT \(STALE\).*\n    [^\n]+\n    [^\n]+\n\nACT-03: READY/, dashboard)
        %w[ACT-02 ACT-06].each do |id|
          assert_includes dashboard, "#{id}: aaaaaaaa -> bbbbbbbb (main changed)"
        end
        refute_match(/ACT-(?:0[179]|11): IN_FLIGHT \(STALE\)/, dashboard)
      end
      assert_equal 4, inspector.head_batches.length
      assert_empty inspector.snapshot_calls
      assert_equal facts, coordinator.statuses
      assert_equal next_before, output_for(dir, coordinator, %w[next --json])
      assert_equal before, state_bytes(dir)
    end
  end

  # Checks a real single-source stale projection with unusual names/titles at
  # configured and detected widths. ANSI/Unicode use ACT's own width measure;
  # fixture command failures propagate as assertions. No live probes are added.
  def assert_unusual_stale_widths
    with_workspace do |dir|
      id = "ACT-" + "1234567890" * 5
      name = "\e[35m界e\u0301\e[0m\n" + "long-source" * 10
      write_task(dir, id:, title: "界e\u0301\n" * 40, repositories: repo(name))
      heads = { name => "a" * 40 }
      coordinator = coordinator_for_inspector(dir, ProbeInspector.new(heads:, remote_urls: { name => remote("safe") }))
      output_for(dir, coordinator, ["prepare", id])
      output_for(dir, coordinator, ["start", id])
      heads[name] = "b" * 40
      previous = ENV.delete("NO_COLOR")
      begin
        [false, true].each do |no_color|
          no_color ? ENV["NO_COLOR"] = "1" : ENV.delete("NO_COLOR")
          [1, 2, 3, 8, 20, 38, 80, 100, 160, 240].each do |width|
            [nil, width].each do |configured|
              out = configured ? StringIO.new : TTYOutput.new(width)
              dashboard = output_for(dir, coordinator, %w[status --all], out:, terminal_width: configured)
              lines = dashboard.lines.map(&:chomp)
              assert_equal 3, lines.length
              lines.each do |line|
                assert_operator AgentCodingTool::CLI.allocate.send(:display_width, line), :<=, width
                plain = line.gsub(AgentCodingTool::CLI::ANSI_SEQUENCE, "")
                refute_includes plain, "\e"
                assert_match(/\e\[0m\.\.\.\z/, line) if line.include?("\e[") && line.end_with?("...")
              end
              assert_includes lines.first, "STALE" if width >= 8
              assert_includes lines[2], "reconcile before delivery" if width >= 38
              assert_includes lines[2], "liveness unknown; isolation unverified" if width >= 80
              if width == 240
                assert_includes lines[1], "aaaaaaaa -> bbbbbbbb (main changed)"
                refute_includes lines[1], "2 changed"
              end
              refute_match(/git@|[a-f0-9]{40}|execution:|pushed branch changed/, lines.drop(1).join)
            end
          end
        end
      ensure
        previous ? ENV["NO_COLOR"] = previous : ENV.delete("NO_COLOR")
      end
    end
  end

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

  # Runs public CLI arguments against the fixture coordinator and optional output
  # width, returning stdout. Nonzero exit/stderr fail with command diagnostics.
  def output_for(dir, coordinator, args, out: StringIO.new, terminal_width: nil)
    err = StringIO.new
    cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err:, terminal_width:)
    cli.instance_variable_set(:@coordinator, coordinator)
    assert_equal 0, cli.run(args), err.string
    assert_empty err.string
    out.string
  end

  # Returns every fixture file's exact bytes, including hidden run evidence.
  # Filesystem errors propagate; this reads without creating or rewriting files.
  def state_bytes(dir)
    Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
       .sort.to_h { |path| [path, File.binread(path)] }
  end
end
