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

      assert_includes prompt, "alpha: #{'a' * 40}"
      assert_includes prompt, "beta: #{'b' * 40}"
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
