# frozen_string_literal: true

require_relative "test_helper"

class CoordinatorTest < Minitest::Test
  include TestHelpers

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
end
