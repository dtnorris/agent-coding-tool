# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class NextTest < Minitest::Test
  include TestHelpers

  class ProbeInspector < FakeInspector
    attr_reader :snapshot_calls, :head_batches, :authority_calls
    attr_accessor :head_result

    def snapshot(name, spec)
      (@snapshot_calls ||= []) << name
      super
    end

    def pushed_heads(references)
      (@head_batches ||= []) << references
      head_result || super
    end

    def repository_authority(name, spec)
      (@authority_calls ||= []) << name
      super
    end

    def reset_counts
      @snapshot_calls = []
      @head_batches = []
      @authority_calls = []
    end
  end

  def test_ready_parallel_set_and_priority_over_maximum_cardinality
    with_workspace do |dir|
      write_task(dir, id: "A-BRIDGE", repositories: repos("x", "y"),
                 worker_recommendation: { "model" => "GPT-6 Sol", "thinking" => "High" })
      write_task(dir, id: "B-LEFT", repositories: repos("left"))
      write_task(dir, id: "C-RIGHT", repositories: repos("right"))
      write_task(dir, id: "D-FREE", repositories: repos("free"))
      write_task(dir, id: "E-CHILD", depends_on: ["A-BRIDGE"], repositories: repos("child"))
      remote_urls = { "left" => remote("x"), "right" => remote("y") }
      inspector = ProbeInspector.new(heads: {}, remote_urls:)
      coordinator = coordinator_with(dir, inspector)
      inspector.reset_counts
      before = state_bytes(dir)

      output = next_output(dir, coordinator)

      assert_equal ["A-BRIDGE", "D-FREE"], section_ids(output, "Next safe parallel starts")
      assert_equal ["B-LEFT", "C-RIGHT"], section_ids(output, "Waiting for write capacity")
      assert_includes output, "act prepare A-BRIDGE\n    act start A-BRIDGE"
      assert_includes output, "worker: GPT-6 Sol / High"
      assert_includes output, "expected immediate unlocks: 1 tasks / 1 parallel (conditional)"
      assert_includes output, "A-BRIDGE (SELECTED) on #{remote('x')} [main]"
      refute_includes output, "--allow-write-collision"
      assert_equal before, state_bytes(dir)
      assert_empty inspector.snapshot_calls
      assert_empty inspector.head_batches
      assert_operator inspector.authority_calls.length, :<=, 6
      assert_equal output, next_output(dir, coordinator)
    end
  end

  def test_fresh_prepared_and_occupied_writers_leave_only_safe_starts
    with_workspace do |dir|
      write_task(dir, id: "A-RUN", repositories: repos("run"))
      write_task(dir, id: "B-CANDIDATE", repositories: repos("candidate"))
      write_task(dir, id: "C-PREPARED", repositories: repos("free"))
      write_task(dir, id: "D-ALIAS", repositories: repos("alias"))
      write_task(dir, id: "E-READER", repositories: repos("read", access: "read_only"))
      write_task(dir, id: "F-COLLISION", repositories: repos("collision"))
      shared = remote("occupied")
      inspector = ProbeInspector.new(
        heads: %w[run candidate free alias read collision].to_h { |name| [name, "a" * 40] },
        remote_urls: { "run" => shared, "alias" => shared, "candidate" => remote("candidate"),
                       "collision" => remote("candidate"), "read" => shared }
      )
      coordinator = coordinator_with(dir, inspector)
      %w[A-RUN B-CANDIDATE C-PREPARED].each { |id| coordinator.prepare(id) }
      coordinator.start("A-RUN")
      coordinator.record("B-CANDIDATE", outcome: "candidate_complete", artifact: "candidate.patch")
      inspector.reset_counts
      before = state_bytes(dir)

      output = next_output(dir, coordinator)

      assert_equal %w[D-ALIAS F-COLLISION], section_ids(output, "Waiting for write capacity")
      assert_equal %w[E-READER C-PREPARED], section_ids(output, "Next safe parallel starts")
      assert_includes output, "C-PREPARED (PREPARED)"
      assert_includes output, "    act start C-PREPARED"
      refute_includes output, "act prepare C-PREPARED"
      assert_includes output, "A-RUN (IN_FLIGHT) on #{shared} [main]"
      assert_includes output, "B-CANDIDATE (CANDIDATE) on #{remote('candidate')} [main]"
      assert_includes output, "artifact: candidate.patch"
      assert_includes output, "completion is not inferred"
      refute_includes output, "act finish B-CANDIDATE"
      assert_equal before, state_bytes(dir)
      assert_empty inspector.snapshot_calls
      assert_equal 1, inspector.head_batches.length
    end
  end

  def test_stale_and_terminal_writers_do_not_reserve_and_outcomes_keep_recorded_actions
    with_workspace do |dir|
      write_task(dir, id: "A-STALE", repositories: repos("stale"))
      write_task(dir, id: "B-STALE-CANDIDATE", repositories: repos("stale_candidate"))
      write_task(dir, id: "C-FAILED", repositories: repos("failed"))
      write_task(dir, id: "D-JUDGMENT", repositories: repos("judgment"))
      write_task(dir, id: "E-READY", repositories: repos("ready"))
      shared = remote("shared")
      heads = %w[stale stale_candidate failed judgment ready].to_h { |name| [name, "a" * 40] }
      inspector = ProbeInspector.new(heads:, remote_urls: heads.keys.to_h { |name| [name, shared] })
      coordinator = coordinator_with(dir, inspector)
      %w[A-STALE B-STALE-CANDIDATE C-FAILED D-JUDGMENT].each { |id| coordinator.prepare(id) }
      coordinator.start("A-STALE")
      coordinator.record("B-STALE-CANDIDATE", outcome: "candidate_complete")
      coordinator.record("C-FAILED", outcome: "failed", summary: "test failed", next_action: "inspect logs")
      coordinator.record("D-JUDGMENT", outcome: "needs_judgment", summary: "choose scope", next_action: "ask David")
      heads.keys.each { |name| heads[name] = "b" * 40 }

      output = next_output(dir, coordinator)

      assert_equal ["E-READY"], section_ids(output, "Next safe parallel starts")
      assert_includes output, "A-STALE (STALE): pushed branch changed"
      assert_includes output, "B-STALE-CANDIDATE (STALE_CANDIDATE): pushed branch changed"
      assert_includes output, "C-FAILED (FAILED): test failed"
      assert_includes output, "recorded next: inspect logs"
      assert_includes output, "D-JUDGMENT (NEEDS_JUDGMENT): choose scope"
      assert_includes output, "recorded next: ask David"
      refute_includes output, "--retry"
    end
  end

  def test_distinct_branches_and_read_only_overlap_are_independent
    with_workspace do |dir|
      write_task(dir, id: "A-MAIN", repositories: repos("main"))
      write_task(dir, id: "B-RELEASE", repositories: { "release" => { "access" => "write", "branch" => "release" } })
      write_task(dir, id: "C-READ", repositories: repos("reader", access: "read_only"))
      inspector = ProbeInspector.new(heads: {}, remote_urls: %w[main release reader].to_h { |name| [name, remote("shared")] })
      output = next_output(dir, coordinator_with(dir, inspector))

      assert_equal %w[A-MAIN B-RELEASE C-READ], section_ids(output, "Next safe parallel starts")
      refute_includes output, "Waiting for write capacity"
    end
  end

  def test_stale_prepared_is_diagnostic_and_blocked_outcome_keeps_its_next_action
    with_workspace do |dir|
      write_task(dir, id: "A-PREPARED")
      write_task(dir, id: "B-BLOCKED")
      write_task(dir, id: "C-DEPENDENT", depends_on: ["B-BLOCKED"])
      heads = { "alpha" => "a" * 40 }
      coordinator = coordinator_with(dir, ProbeInspector.new(heads:))
      coordinator.prepare("A-PREPARED")
      coordinator.prepare("B-BLOCKED")
      coordinator.record("B-BLOCKED", outcome: "blocked", summary: "missing contract",
                         next_action: "request owner decision")
      heads["alpha"] = "b" * 40

      output = next_output(dir, coordinator)

      assert_empty section_ids(output, "Next safe parallel starts")
      assert_includes output, "A-PREPARED (STALE): pushed branch changed"
      assert_includes output, "B-BLOCKED (BLOCKED): missing contract"
      assert_includes output, "recorded next: request owner decision"
      assert_includes output, "C-DEPENDENT: waiting on: B-BLOCKED"
      refute_includes output, "act start A-PREPARED"
    end
  end

  def test_missing_or_malformed_remote_freshness_fails_closed_in_one_batch
    [ {}, { [remote("alpha"), "main"] => "not-a-sha" } ].each do |result|
      with_workspace do |dir|
        write_task(dir, id: "A")
        inspector = ProbeInspector.new(heads: { "alpha" => "a" * 40 })
        coordinator = coordinator_with(dir, inspector)
        coordinator.prepare("A")
        inspector.reset_counts
        inspector.head_result = result
        before = state_bytes(dir)
        output = StringIO.new
        errors = StringIO.new
        cli = cli_for(dir, coordinator, out: output, err: errors)

        assert_equal 2, cli.run(["next"])
        assert_empty output.string
        assert_match(/pushed-head evidence is missing or malformed/, errors.string)
        assert_equal 1, inspector.head_batches.length
        assert_empty inspector.snapshot_calls
        assert_equal before, state_bytes(dir)
      end
    end
  end

  def test_missing_preparation_provenance_fails_before_remote_lookup
    with_workspace do |dir|
      write_task(dir, id: "A")
      inspector = ProbeInspector.new(heads: { "alpha" => "a" * 40 })
      coordinator = coordinator_with(dir, inspector)
      coordinator.prepare("A")
      state_store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      state = state_store.load("A")
      state.fetch("snapshot").fetch("alpha").delete("remote_url")
      state_store.write("A", state)
      inspector.reset_counts
      output = StringIO.new
      errors = StringIO.new

      assert_equal 2, cli_for(dir, coordinator, out: output, err: errors).run(["next"])
      assert_empty output.string
      assert_match(/prepared snapshot lacks remote URL or branch|prepared freshness provenance/, errors.string)
      assert_empty inspector.head_batches
      assert_empty inspector.snapshot_calls
    end
  end

  def test_no_state_directory_is_created_by_read_only_next
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tasks"))
      write_task(dir, id: "A")
      output = StringIO.new
      errors = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out: output, err: errors)
      inspector = ProbeInspector.new(heads: {})
      cli.instance_variable_set(:@coordinator, coordinator_with(dir, inspector))

      assert_equal 0, cli.run(["next"])
      assert_includes output.string, "act prepare A"
      refute Dir.exist?(File.join(dir, "state"))
      assert_empty errors.string
    end
  end

  def test_json_empty_plan_and_stable_priority_match_human_next
    with_workspace do |dir|
      inspector = ProbeInspector.new(heads: {})
      coordinator = coordinator_with(dir, inspector)
      empty = json_next(dir, coordinator)
      assert_equal "agent-coding-tool-next/v0.1", empty.fetch("schema_version")
      assert_equal true, empty.fetch("advisory")
      assert_empty empty.dig("facts", "tasks")
      assert empty.fetch("recommendations").values.all?(&:empty?)

      write_task(dir, id: "A-BRIDGE", repositories: repos("x", "y"),
                 worker_recommendation: { "model" => "GPT-6 Sol", "thinking" => "High" })
      write_task(dir, id: "B-LEFT", repositories: repos("left"))
      write_task(dir, id: "C-FREE", repositories: repos("free"))
      write_task(dir, id: "D-CHILD", depends_on: ["A-BRIDGE"], repositories: repos("child"))
      inspector = ProbeInspector.new(heads: {}, remote_urls: { "left" => remote("x") })
      coordinator = coordinator_with(dir, inspector)
      before = state_bytes(dir)
      document = json_next(dir, coordinator)
      human = next_output(dir, coordinator)
      starts = document.dig("recommendations", "starts")
      waits = document.dig("recommendations", "waiting_capacity")

      assert_equal section_ids(human, "Next safe parallel starts"), starts.map { |row| row.fetch("id") }
      assert_equal section_ids(human, "Waiting for write capacity"), waits.map { |row| row.fetch("id") }
      assert_equal %w[A-BRIDGE C-FREE], starts.map { |row| row.fetch("id") }
      assert_equal ["act prepare A-BRIDGE", "act start A-BRIDGE"], starts.first.fetch("commands")
      assert_equal({ "model" => "GPT-6 Sol", "thinking" => "High" }, starts.first.fetch("worker_recommendation"))
      assert_equal "SELECTED", waits.first.fetch("conflicts").first.fetch("status")
      assert_equal remote("x"), starts.first.fetch("authorities").first.fetch("remote_url")
      assert_equal "main", starts.first.fetch("authorities").first.fetch("branch")
      assert_equal 1, starts.first.dig("downstream", "immediate_unlock_count")
      assert_equal document, json_next(dir, coordinator)
      assert_equal before, state_bytes(dir)
    end
  end

  def test_json_separates_reservations_candidate_review_and_interventions
    with_workspace do |dir|
      %w[A-RUN B-CANDIDATE C-PREPARED D-COLLISION E-JUDGMENT F-CHILD].each do |id|
        write_task(dir, id:, repositories: repos(id.downcase),
                   depends_on: id == "F-CHILD" ? ["E-JUDGMENT"] : [])
      end
      heads = %w[a-run b-candidate c-prepared d-collision e-judgment f-child]
              .to_h { |name| [name, "a" * 40] }
      inspector = ProbeInspector.new(heads:, remote_urls: {
        "d-collision" => remote("a-run")
      })
      coordinator = coordinator_with(dir, inspector)
      %w[A-RUN B-CANDIDATE C-PREPARED E-JUDGMENT].each { |id| coordinator.prepare(id) }
      coordinator.start("A-RUN")
      coordinator.record("B-CANDIDATE", outcome: "candidate_complete", artifact: "candidate.patch")
      coordinator.record("E-JUDGMENT", outcome: "needs_judgment", summary: "choose scope",
                         next_action: "request decision")
      before = state_bytes(dir)
      document = json_next(dir, coordinator)
      recommendations = document.fetch("recommendations")

      assert_equal ["C-PREPARED"], recommendations.fetch("starts").map { |row| row.fetch("id") }
      assert_equal ["act start C-PREPARED"], recommendations.fetch("starts").first.fetch("commands")
      assert_equal ["D-COLLISION"], recommendations.fetch("waiting_capacity").map { |row| row.fetch("id") }
      assert_equal %w[A-RUN B-CANDIDATE], document.dig("facts", "reservations").map { |row| row.fetch("id") }
      assert_equal ["B-CANDIDATE"], recommendations.fetch("candidate_review").map { |row| row.fetch("id") }
      assert_equal "candidate.patch", recommendations.fetch("candidate_review").first.fetch("artifact")
      assert_equal "request decision", recommendations.fetch("interventions").first.fetch("next_action")
      assert_equal ["F-CHILD"], recommendations.fetch("waiting_dependencies").map { |row| row.fetch("id") }
      refute recommendations.to_s.include?("--allow-write-collision")
      assert_equal before, state_bytes(dir)
    end
  end

  def test_json_freshness_failure_and_bad_arguments_leave_stdout_empty
    with_workspace do |dir|
      write_task(dir, id: "A")
      inspector = ProbeInspector.new(heads: { "alpha" => "a" * 40 })
      coordinator = coordinator_with(dir, inspector)
      coordinator.prepare("A")
      inspector.head_result = {}
      before = state_bytes(dir)
      output = StringIO.new
      errors = StringIO.new
      assert_equal 2, cli_for(dir, coordinator, out: output, err: errors).run(%w[next --json])
      assert_empty output.string
      assert_match(/pushed-head evidence is missing or malformed/, errors.string)
      assert_equal before, state_bytes(dir)

      output = StringIO.new
      errors = StringIO.new
      assert_equal 2, cli_for(dir, coordinator, out: output, err: errors).run(%w[next --json TASK])
      assert_empty output.string
      assert_match(/usage: agent-coding-tool next/, errors.string)
    end
  end

  def test_json_stale_work_is_intervention_without_start_authority
    with_workspace do |dir|
      write_task(dir, id: "A-STALE")
      write_task(dir, id: "B-READY")
      heads = { "alpha" => "a" * 40 }
      inspector = ProbeInspector.new(heads:)
      coordinator = coordinator_with(dir, inspector)
      coordinator.prepare("A-STALE")
      heads["alpha"] = "b" * 40

      document = json_next(dir, coordinator)
      assert_equal ["B-READY"], document.dig("recommendations", "starts").map { |row| row.fetch("id") }
      stale = document.dig("recommendations", "interventions").first
      assert_equal "A-STALE", stale.fetch("id")
      assert_equal "STALE", stale.fetch("status")
      assert_match(/pushed branch changed/, stale.fetch("reason"))
      fact = document.dig("facts", "tasks").find { |row| row.fetch("id") == "A-STALE" }
      assert_equal "changed_writable_head", fact.dig("freshness", "state")
      assert_equal "a" * 40, fact.dig("freshness", "prepared_repositories", 0, "prepared_pushed_sha")
      refute document.to_s.include?("act start A-STALE")
    end
  end

  def test_next_rejects_arguments_without_reading_or_changing_state
    output = StringIO.new
    errors = StringIO.new
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: "/missing", out: output, err: errors)

    assert_equal 2, cli.run(%w[next TASK])
    assert_empty output.string
    assert_includes errors.string, "usage: agent-coding-tool next"
  end

  private

  def remote(name) = "git@github.com:example/#{name}.git"

  def repos(*names, access: "write")
    names.to_h { |name| [name, { "access" => access }] }
  end

  def coordinator_with(dir, inspector)
    AgentCodingTool::Coordinator.new(
      task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
      state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
      repo_inspector: inspector,
      prompt_renderer: AgentCodingTool::PromptRenderer.new,
      prompt_root: File.join(dir, "state", "prompts")
    )
  end

  def cli_for(dir, coordinator, out: StringIO.new, err: StringIO.new)
    cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err:)
    cli.instance_variable_set(:@coordinator, coordinator)
    cli
  end

  def next_output(dir, coordinator)
    output = StringIO.new
    errors = StringIO.new
    assert_equal 0, cli_for(dir, coordinator, out: output, err: errors).run(["next"]), errors.string
    assert_empty errors.string
    output.string
  end

  def json_next(dir, coordinator)
    output = StringIO.new
    errors = StringIO.new
    assert_equal 0, cli_for(dir, coordinator, out: output, err: errors).run(%w[next --json]), errors.string
    assert_empty errors.string
    JSON.parse(output.string)
  end

  def state_bytes(dir)
    Dir.glob(File.join(dir, "state", "**", "*"), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .to_h { |path| [path.delete_prefix(dir), File.binread(path)] }
  end

  def section_ids(output, title)
    lines = output.lines.drop_while { |line| !line.start_with?(title) }.drop(1)
    lines.take_while { |line| !line.strip.empty? }
         .filter_map { |line| line[/\A  ([A-Z][A-Z0-9-]+) \(/, 1] }
  end
end
