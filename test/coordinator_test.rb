# frozen_string_literal: true

require_relative "test_helper"

class CoordinatorTest < Minitest::Test
  include TestHelpers

  class InstrumentedInspector
    attr_reader :snapshot_calls, :head_batches

    def initialize(heads)
      @heads = heads
      reset_counts
    end

    def snapshot(name, _spec)
      @snapshot_calls << name
      sha = @heads.fetch(name)
      {
        "path" => "/repos/#{name}",
        "remote" => "origin",
        "remote_url" => "git@github.com:example/#{name}.git",
        "branch" => "main",
        "pushed_sha" => sha,
        "local_head" => sha,
        "local_dirty" => false
      }
    end

    def pushed_heads(references)
      @head_batches << references.map(&:dup)
      references.each_with_object({}) do |reference, heads|
        repository = reference.fetch("name").split("/", 2).last
        key = [reference.fetch("remote_url"), reference.fetch("branch")]
        heads[key] = @heads.fetch(repository)
      end
    end

    def reset_counts
      @snapshot_calls = []
      @head_batches = []
    end
  end

  def test_start_preserves_preparation_and_rejects_double_start
    with_workspace do |dir|
      write_task(dir, id: "T1")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      prepared = coordinator.prepare("T1").fetch("state")
      prompt = File.read(prepared.fetch("prompt_path"))
      assert_equal "PREPARED", coordinator.status("T1").fetch("status")

      started = coordinator.start("T1")
      assert_equal prepared, started.reject { |key, _| key == "started_at" }
      assert Time.iso8601(started.fetch("started_at")).utc?
      assert_equal prompt, File.read(started.fetch("prompt_path"))
      assert_equal "IN_FLIGHT", coordinator.status("T1").fetch("status")
      error = assert_raises(AgentCodingTool::InvalidState) { coordinator.start("T1") }
      assert_match(/already in flight/, error.message)
      assert_equal started, coordinator.status("T1").fetch("state")
    end
  end

  def test_start_requires_existing_prepared_task
    with_workspace do |dir|
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      assert_raises(AgentCodingTool::Error) { coordinator.start("missing") }
      write_task(dir, id: "T1")
      error = assert_raises(AgentCodingTool::InvalidState) { coordinator.start("T1") }
      assert_match(/prepare the task before starting/, error.message)
      assert_equal "READY", coordinator.status("T1").fetch("status")
    end
  end

  def test_every_result_ends_in_flight_and_prevents_start
    AgentCodingTool::Coordinator::OUTCOMES.each do |outcome|
      with_workspace do |dir|
        write_task(dir, id: "T1")
        coordinator = coordinator_for(dir, "alpha" => "a" * 40)
        coordinator.prepare("T1")
        coordinator.start("T1")
        result = coordinator.record("T1", outcome: outcome)
        refute result.key?("started_at")
        label = outcome == "candidate_complete" ? "CANDIDATE" : outcome.upcase
        assert_equal label, coordinator.status("T1").fetch("status")
        error = assert_raises(AgentCodingTool::InvalidState) { coordinator.start("T1") }
        assert_match(outcome == "complete" ? /already complete/ : /use prepare --retry/, error.message)
        assert_equal result, coordinator.status("T1").fetch("state")
      end
    end
  end

  def test_fresh_preparation_clears_in_flight_with_or_without_retry
    [false, true].each do |retry_result|
      with_workspace do |dir|
        write_task(dir, id: "T1")
        coordinator = coordinator_for(dir, "alpha" => "a" * 40)
        coordinator.prepare("T1")
        coordinator.start("T1")
        prepared = coordinator.prepare("T1", retry_result: retry_result)
        refute prepared.fetch("state").key?("started_at")
        assert_equal "PREPARED", coordinator.status("T1").fetch("status")
      end
    end
  end

  def test_retry_clears_result_and_any_retained_in_flight_marker
    with_workspace do |dir|
      write_task(dir, id: "T1")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("T1")
      started = coordinator.start("T1")
      result = coordinator.record("T1", outcome: "blocked")
      store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      store.write("T1", result.merge("started_at" => started.fetch("started_at")))

      prepared = coordinator.prepare("T1", retry_result: true).fetch("state")
      refute prepared.key?("result")
      refute prepared.key?("started_at")
      assert_equal "PREPARED", coordinator.status("T1").fetch("status")
      coordinator.start("T1")
      assert_equal "IN_FLIGHT", coordinator.status("T1").fetch("status")
    end
  end

  def test_reset_clears_in_flight
    with_workspace do |dir|
      write_task(dir, id: "T1")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("T1")
      coordinator.start("T1")
      coordinator.reset("T1")
      assert_equal({ "id" => "T1" }, coordinator.status("T1").fetch("state"))
      assert_equal "READY", coordinator.status("T1").fetch("status")
    end
  end

  def test_in_flight_preserves_read_only_reconciliation_and_writable_staleness
    [false, true].each do |mixed|
      with_workspace do |dir|
        repos = { "reference" => { "access" => "read_only" } }
        repos["alpha"] = { "access" => "write" } if mixed
        write_task(dir, id: "T1", repositories: repos)
        heads = { "alpha" => "a" * 40, "reference" => "b" * 40 }
        coordinator = coordinator_for(dir, heads)
        coordinator.prepare("T1")
        started = coordinator.start("T1")
        heads["reference"] = "c" * 40
        status = coordinator.status("T1")
        assert_equal "IN_FLIGHT", status.fetch("status")
        assert_includes status.fetch("reason"), "refresh and reconcile materially affected findings before finalizing: reference"
        assert_equal started, status.fetch("state")
        next unless mixed

        heads["alpha"] = "d" * 40
        assert_equal "STALE", coordinator.status("T1").fetch("status")
        assert_equal "pushed branch changed: alpha", coordinator.status("T1").fetch("reason")
        assert_equal started, coordinator.status("T1").fetch("state")
      end
    end
  end

  def test_incomplete_dependencies_take_precedence_over_in_flight
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B", depends_on: ["A"])
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.record("A", outcome: "complete")
      coordinator.prepare("B")
      coordinator.start("B")
      coordinator.reset("A")
      assert_equal "BLOCKED", coordinator.status("B").fetch("status")
      assert_equal "dependencies incomplete: A", coordinator.status("B").fetch("reason")
    end
  end

  def test_new_task_is_ready
    with_workspace do |dir|
      write_task(dir, id: "T1")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)

      assert_equal "READY", coordinator.status("T1").fetch("status")
    end
  end

  def test_dependency_must_be_complete_before_prepare
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B", depends_on: ["A"])
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)

      error = assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("B") }
      assert_match(/dependencies incomplete: A/, error.message)

      coordinator.record("A", outcome: "complete", summary: "landed")
      prepared = coordinator.prepare("B")
      assert_equal "a" * 40, prepared.dig("state", "snapshot", "alpha", "pushed_sha")
    end
  end

  def test_prepare_renders_exact_pushed_heads_and_scope
    with_workspace do |dir|
      repos = {
        "alpha" => { "access" => "write" },
        "beta" => { "access" => "read_only" }
      }
      write_task(dir, id: "T1", repositories: repos, title: "Narrow change")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40, "beta" => "b" * 40)

      result = coordinator.prepare("T1")
      prompt = result.fetch("prompt")

      %w[alpha beta].each do |name|
        assert_includes prompt, <<~BLOCK
          - #{name}
            - path: /repos/#{name}
            - remote_url: git@github.com:example/#{name}.git
            - branch: main
            - pushed_sha: #{name[0] * 40}
        BLOCK
      end
      assert_includes prompt, "## Writable repositories"
      assert_includes prompt, "## Read-only repositories"
      assert_includes prompt, "report STALE INPUT"
      assert_includes prompt, "Do not broaden repository scope"
      assert File.file?(result.dig("state", "prompt_path"))
    end
  end

  def test_prepared_task_becomes_stale_when_pushed_main_moves
    with_workspace do |dir|
      write_task(dir, id: "T1")
      heads = { "alpha" => "a" * 40 }
      inspector = FakeInspector.new(heads: heads)
      coordinator = AgentCodingTool::Coordinator.new(
        task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
        state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
        repo_inspector: inspector,
        prompt_renderer: AgentCodingTool::PromptRenderer.new,
        prompt_root: File.join(dir, "state", "prompts")
      )

      coordinator.prepare("T1")
      assert_equal "PREPARED", coordinator.status("T1").fetch("status")

      heads["alpha"] = "b" * 40
      status = coordinator.status("T1")
      assert_equal "STALE", status.fetch("status")
      assert_match(/alpha/, status.fetch("reason"))
    end
  end

  def test_candidate_can_be_recorded_and_staleness_remains_fail_closed
    with_workspace do |dir|
      write_task(dir, id: "T1")
      heads = { "alpha" => "a" * 40 }
      inspector = FakeInspector.new(heads: heads)
      coordinator = AgentCodingTool::Coordinator.new(
        task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
        state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
        repo_inspector: inspector,
        prompt_renderer: AgentCodingTool::PromptRenderer.new,
        prompt_root: File.join(dir, "state", "prompts")
      )

      coordinator.prepare("T1")
      coordinator.record(
        "T1",
        outcome: "candidate_complete",
        summary: "focused and full suites passed",
        artifact: "T1.patch",
        tests: ["rake=pass"]
      )
      assert_equal "CANDIDATE", coordinator.status("T1").fetch("status")

      heads["alpha"] = "c" * 40
      assert_equal "STALE_CANDIDATE", coordinator.status("T1").fetch("status")
    end
  end

  def test_needs_judgment_is_a_first_class_status
    with_workspace do |dir|
      write_task(dir, id: "T1")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)

      coordinator.prepare("T1")
      coordinator.record("T1", outcome: "needs_judgment", summary: "owner boundary is unresolved")
      status = coordinator.status("T1")

      assert_equal "NEEDS_JUDGMENT", status.fetch("status")
      assert_equal "owner boundary is unresolved", status.fetch("reason")
    end
  end

  def test_read_only_movement_requires_reconciliation_without_invalidating_prepared_or_candidate_tasks
    [false, true].each do |mixed|
      with_workspace do |dir|
        repos = { "reference" => { "access" => "read_only" } }
        repos["alpha"] = { "access" => "write" } if mixed
        write_task(dir, id: "T1", repositories: repos)
        heads = { "reference" => "a" * 40, "alpha" => "b" * 40 }
        coordinator = coordinator_for(dir, heads)
        prepared = coordinator.prepare("T1")
        state_path = AgentCodingTool::StateStore.new(File.join(dir, "state")).state_path("T1")
        original_state = File.read(state_path)

        assert_equal "a" * 40, prepared.dig("state", "snapshot", "reference", "pushed_sha")
        assert_nil coordinator.status("T1").fetch("reason")
        heads["reference"] = "c" * 40
        status = coordinator.status("T1")
        assert_equal "PREPARED", status.fetch("status")
        assert_includes status.fetch("reason"), "refresh and reconcile materially affected findings before finalizing: reference"
        assert_equal prepared.fetch("state").fetch("snapshot"), status.dig("state", "snapshot")
        assert_equal original_state, File.read(state_path)

        coordinator.record("T1", outcome: "candidate_complete", summary: "review ready")
        status = coordinator.status("T1")
        assert_equal "CANDIDATE", status.fetch("status")
        assert_includes status.fetch("reason"), "reference"
        assert_equal "a" * 40, status.dig("state", "snapshot", "reference", "pushed_sha")
        assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("T1") }
      end
    end
  end

  def test_mixed_movement_is_hard_stale_because_of_writable_repository
    with_workspace do |dir|
      write_task(dir, id: "T1", repositories: {
        "alpha" => { "access" => "write" }, "reference" => { "access" => "read_only" }
      })
      heads = { "alpha" => "a" * 40, "reference" => "b" * 40 }
      coordinator = coordinator_for(dir, heads)
      coordinator.prepare("T1")
      heads["alpha"] = "c" * 40
      heads["reference"] = "d" * 40

      assert_equal "STALE", coordinator.status("T1").fetch("status")
      assert_equal "pushed branch changed: alpha", coordinator.status("T1").fetch("reason")
      coordinator.record("T1", outcome: "candidate_complete")
      assert_equal "STALE_CANDIDATE", coordinator.status("T1").fetch("status")
      assert_equal "pushed branch changed: alpha", coordinator.status("T1").fetch("reason")
    end
  end

  def test_explicit_outcomes_keep_precedence_over_head_movement
    %w[blocked needs_judgment failed complete].each do |outcome|
      with_workspace do |dir|
        write_task(dir, id: "T1", repositories: {
          "alpha" => { "access" => "write" }, "reference" => { "access" => "read_only" }
        })
        heads = { "alpha" => "a" * 40, "reference" => "b" * 40 }
        coordinator = coordinator_for(dir, heads)
        coordinator.prepare("T1")
        heads["reference"] = "c" * 40
        coordinator.record("T1", outcome: outcome, summary: "explicit result")
        heads["alpha"] = "d" * 40
        status = coordinator.status("T1")

        assert_equal outcome.upcase, status.fetch("status")
        assert_equal "b" * 40, status.dig("state", "snapshot", "reference", "pushed_sha")
        if outcome == "complete"
          assert_equal "c" * 40, status.dig("state", "completion_snapshot", "reference", "pushed_sha")
        else
          assert_equal "explicit result", status.fetch("reason")
        end
      end
    end
  end

  def test_missing_read_only_preparation_snapshot_still_fails_closed
    with_workspace do |dir|
      write_task(dir, id: "T1")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40, "reference" => "b" * 40)
      coordinator.prepare("T1")
      write_task(dir, id: "T1", repositories: {
        "alpha" => { "access" => "write" }, "reference" => { "access" => "read_only" }
      })

      assert_equal "STALE", coordinator.status("T1").fetch("status")
      assert_includes coordinator.status("T1").fetch("reason"), "reference"
    end
  end

  def test_retry_is_explicit_after_non_complete_result
    with_workspace do |dir|
      write_task(dir, id: "T1")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)

      coordinator.prepare("T1")
      coordinator.record("T1", outcome: "blocked", summary: "missing interface")
      assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("T1") }

      result = coordinator.prepare("T1", retry_result: true)
      refute result.fetch("state").key?("result")
      assert_equal "PREPARED", coordinator.status("T1").fetch("status")
    end
  end

  def test_broad_status_batches_freshness_without_full_repository_snapshots
    with_workspace do |dir|
      shared = (1..4).to_h { |index| ["shared#{index}", { "access" => "read_only" }] }
      first_only = (1..4).to_h { |index| ["first#{index}", { "access" => "read_only" }] }
      second_only = (1..4).to_h { |index| ["second#{index}", { "access" => "read_only" }] }
      write_task(dir, id: "T1", repositories: shared.merge(first_only))
      write_task(dir, id: "T2", repositories: shared.merge(second_only))
      names = shared.keys + first_only.keys + second_only.keys
      inspector = InstrumentedInspector.new(names.to_h { |name| [name, name[0] * 40] })
      coordinator = coordinator_with_inspector(dir, inspector)
      coordinator.prepare("T1")
      coordinator.start("T1")
      coordinator.prepare("T2")
      inspector.reset_counts

      statuses = coordinator.statuses

      assert_equal %w[IN_FLIGHT PREPARED], statuses.map { |status| status.fetch("status") }
      assert_empty inspector.snapshot_calls
      assert_equal 1, inspector.head_batches.length
      references = inspector.head_batches.first
      assert_equal 16, references.length
      assert_equal 12, references.map { |reference| [reference.fetch("remote_url"), reference.fetch("branch")] }.uniq.length
    end
  end

  def test_single_task_status_uses_optimized_freshness_path
    with_workspace do |dir|
      write_task(dir, id: "T1")
      inspector = InstrumentedInspector.new("alpha" => "a" * 40)
      coordinator = coordinator_with_inspector(dir, inspector)
      coordinator.prepare("T1")
      inspector.reset_counts

      assert_equal "PREPARED", coordinator.status("T1").fetch("status")
      assert_empty inspector.snapshot_calls
      assert_equal 1, inspector.head_batches.length
      assert_equal ["T1/alpha"], inspector.head_batches.first.map { |reference| reference.fetch("name") }
    end
  end

  def test_terminal_ready_and_dependency_blocked_tasks_skip_freshness_work
    with_workspace do |dir|
      %w[COMPLETE BLOCKED FAILED NEEDS].each { |id| write_task(dir, id:) }
      write_task(dir, id: "READY")
      write_task(dir, id: "DEPENDENT", depends_on: ["READY"])
      inspector = InstrumentedInspector.new("alpha" => "a" * 40)
      coordinator = coordinator_with_inspector(dir, inspector)
      coordinator.record("COMPLETE", outcome: "complete")
      {
        "BLOCKED" => "blocked",
        "FAILED" => "failed",
        "NEEDS" => "needs_judgment"
      }.each do |id, outcome|
        coordinator.prepare(id)
        coordinator.record(id, outcome:, summary: outcome)
      end
      inspector.reset_counts

      statuses = coordinator.statuses.to_h { |status| [status.fetch("id"), status.fetch("status")] }

      assert_equal "COMPLETE", statuses.fetch("COMPLETE")
      assert_equal "BLOCKED", statuses.fetch("BLOCKED")
      assert_equal "FAILED", statuses.fetch("FAILED")
      assert_equal "NEEDS_JUDGMENT", statuses.fetch("NEEDS")
      assert_equal "READY", statuses.fetch("READY")
      assert_equal "BLOCKED", statuses.fetch("DEPENDENT")
      assert_empty inspector.snapshot_calls
      assert_empty inspector.head_batches
    end
  end

  def test_recent_completion_filter_keeps_five_newest_in_task_store_order
    with_workspace do |dir|
      timestamps = {
        "C1" => "2026-10-05T18:00:00Z",
        "C2" => "2026-10-05T12:00:00Z",
        "C3" => "2026-10-05T17:00:00Z",
        "C4" => "2026-10-05T16:00:00Z",
        "C5" => "2026-10-05T11:00:00Z",
        "C6" => "2026-10-05T15:00:00Z",
        "C7" => "2026-10-05T14:00:00Z"
      }
      timestamps.each_key { |id| write_task(dir, id:) }
      write_task(dir, id: "READY")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      timestamps.each { |id, timestamp| record_complete_at(dir, coordinator, id, timestamp) }

      statuses = coordinator.statuses(completion_filter: :recent)

      assert_equal %w[C1 C3 C4 C6 C7 READY], statuses.map { |status| status.fetch("id") }
      assert_equal ["COMPLETE"] * 5 + ["READY"], statuses.map { |status| status.fetch("status") }
    end
  end

  def test_recent_completion_filter_keeps_all_when_five_or_fewer_are_complete
    with_workspace do |dir|
      (1..5).each { |index| write_task(dir, id: "C#{index}") }
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      (1..5).each do |index|
        record_complete_at(dir, coordinator, "C#{index}", "2026-10-05T#{format('%02d', index)}:00:00Z")
      end

      assert_equal %w[C1 C2 C3 C4 C5],
                   coordinator.statuses(completion_filter: :recent).map { |status| status.fetch("id") }
    end
  end

  def test_recent_completion_filter_keeps_unrankable_completions_visible
    with_workspace do |dir|
      (1..7).each { |index| write_task(dir, id: "C#{index}") }
      write_task(dir, id: "MALFORMED")
      write_task(dir, id: "MISSING")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      (1..7).each do |index|
        record_complete_at(dir, coordinator, "C#{index}", "2026-10-05T#{format('%02d', index)}:00:00Z")
      end
      record_complete_at(dir, coordinator, "MALFORMED", "not-a-time")
      record_complete_at(dir, coordinator, "MISSING", nil)

      ids = coordinator.statuses(completion_filter: :recent).map { |status| status.fetch("id") }

      assert_equal %w[C3 C4 C5 C6 C7 MALFORMED MISSING], ids
    end
  end

  def test_all_and_active_completion_filters_preserve_selected_order
    with_workspace do |dir|
      %w[A B C].each { |id| write_task(dir, id:) }
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      record_complete_at(dir, coordinator, "A", "2026-10-05T10:00:00Z")
      coordinator.prepare("B")
      coordinator.record("B", outcome: "blocked", summary: "blocked")

      assert_equal %w[A B C], coordinator.statuses(completion_filter: :all).map { |status| status.fetch("id") }
      assert_equal %w[B C], coordinator.statuses(completion_filter: :active).map { |status| status.fetch("id") }
    end
  end

  def test_hidden_complete_dependency_still_unblocks_visible_task
    with_workspace do |dir|
      (1..6).each { |index| write_task(dir, id: "C#{index}") }
      write_task(dir, id: "DEPENDENT", depends_on: ["C1"])
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      (1..6).each do |index|
        record_complete_at(dir, coordinator, "C#{index}", "2026-10-05T#{format('%02d', index)}:00:00Z")
      end

      statuses = coordinator.statuses(completion_filter: :recent)

      refute_includes statuses.map { |status| status.fetch("id") }, "C1"
      assert_equal "READY", statuses.find { |status| status.fetch("id") == "DEPENDENT" }.fetch("status")
    end
  end

  def test_recent_filter_does_not_add_freshness_work_for_hidden_completions
    with_workspace do |dir|
      (1..6).each { |index| write_task(dir, id: "C#{index}") }
      write_task(dir, id: "ACTIVE")
      inspector = InstrumentedInspector.new("alpha" => "a" * 40)
      coordinator = coordinator_with_inspector(dir, inspector)
      (1..6).each do |index|
        record_complete_at(dir, coordinator, "C#{index}", "2026-10-05T#{format('%02d', index)}:00:00Z")
      end
      coordinator.prepare("ACTIVE")
      inspector.reset_counts

      statuses = coordinator.statuses(completion_filter: :recent)

      assert_equal 6, statuses.length
      assert_empty inspector.snapshot_calls
      assert_equal 1, inspector.head_batches.length
      assert_equal ["ACTIVE/alpha"], inspector.head_batches.first.map { |reference| reference.fetch("name") }
    end
  end

  private

  def coordinator_with_inspector(dir, inspector)
    AgentCodingTool::Coordinator.new(
      task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
      state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
      repo_inspector: inspector,
      prompt_renderer: AgentCodingTool::PromptRenderer.new,
      prompt_root: File.join(dir, "state", "prompts")
    )
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
end
