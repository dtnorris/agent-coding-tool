# frozen_string_literal: true

require_relative "test_helper"

class ReadyUnlockMetricsTest < Minitest::Test
  include TestHelpers

  def test_immediate_unlocks_require_the_ready_task_to_be_the_final_missing_dependency
    with_workspace do |dir|
      write_task(dir, id: "EMPTY", repositories: repository("empty"))
      write_task(dir, id: "OTHER", repositories: repository("other"))
      write_task(dir, id: "PARENT", repositories: repository("parent"))
      write_task(dir, id: "ONE", depends_on: ["PARENT"], repositories: repository("one"))
      write_task(dir, id: "LEVEL1", depends_on: ["PARENT"], repositories: repository("level1"))
      write_task(dir, id: "LEVEL2", depends_on: ["LEVEL1"], repositories: repository("level2"))
      write_task(dir, id: "OTHER-MISSING", depends_on: %w[PARENT OTHER],
                       repositories: repository("other_missing"))
      write_task(dir, id: "PREPARED", depends_on: ["PARENT"], repositories: repository("prepared"))
      write_task(dir, id: "IN-FLIGHT", depends_on: ["PARENT"], repositories: repository("in_flight"))
      write_task(dir, id: "CANDIDATE", depends_on: ["PARENT"], repositories: repository("candidate"))
      %w[complete failed blocked needs_judgment].each do |outcome|
        write_task(
          dir,
          id: "TERMINAL-#{outcome}",
          depends_on: ["PARENT"],
          repositories: repository("terminal_#{outcome}")
        )
      end
      coordinator = coordinator_for(dir, {})
      store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      store.write("PREPARED", {
                    "id" => "PREPARED",
                    "snapshot" => snapshot("prepared")
                  })
      store.write("IN-FLIGHT", {
                    "id" => "IN-FLIGHT",
                    "snapshot" => snapshot("in_flight"),
                    "started_at" => "2026-10-07T10:00:00Z"
                  })
      store.write("CANDIDATE", {
                    "id" => "CANDIDATE",
                    "snapshot" => snapshot("candidate"),
                    "result" => {
                      "outcome" => "candidate_complete",
                      "recorded_at" => "2026-10-07T10:00:00Z"
                    }
                  })
      %w[complete failed blocked needs_judgment].each do |outcome|
        store.write("TERMINAL-#{outcome}", {
                      "id" => "TERMINAL-#{outcome}",
                      "result" => {
                        "outcome" => outcome,
                        "recorded_at" => "2026-10-07T10:00:00Z"
                      }
                    })
      end

      metrics = unlock_metrics(coordinator)

      assert_equal({ "unlock_count" => 0, "parallel_width" => 0 }, metrics.fetch("EMPTY"))
      assert_equal({ "unlock_count" => 2, "parallel_width" => 2 }, metrics.fetch("PARENT"))
      assert_equal({ "unlock_count" => 0, "parallel_width" => 0 }, metrics.fetch("OTHER"))
    end
  end

  def test_parallel_width_uses_exact_remote_and_branch_write_authorities
    with_workspace do |dir|
      write_task(dir, id: "P-DISTINCT", repositories: repository("parent_distinct"))
      write_task(dir, id: "D1", depends_on: ["P-DISTINCT"], repositories: repository("distinct1"))
      write_task(dir, id: "D2", depends_on: ["P-DISTINCT"], repositories: repository("distinct2"))

      write_task(dir, id: "P-ALIAS", repositories: repository("parent_alias"))
      write_task(dir, id: "A1", depends_on: ["P-ALIAS"], repositories: repository("alias1"))
      write_task(dir, id: "A2", depends_on: ["P-ALIAS"], repositories: repository("alias2"))

      write_task(dir, id: "P-BRANCH", repositories: repository("parent_branch"))
      write_task(dir, id: "B1", depends_on: ["P-BRANCH"], repositories: repository("branch1", branch: "main"))
      write_task(dir, id: "B2", depends_on: ["P-BRANCH"],
                       repositories: repository("branch2", branch: "release"))

      write_task(dir, id: "P-READ", repositories: repository("parent_read"))
      write_task(dir, id: "R1", depends_on: ["P-READ"], repositories: repository("read", access: "read_only"))
      write_task(dir, id: "R2", depends_on: ["P-READ"], repositories: repository("write"))

      shared = "git@github.com:example/shared.git"
      remote_urls = {
        "alias1" => shared,
        "alias2" => shared,
        "branch1" => shared,
        "branch2" => shared,
        "read" => shared,
        "write" => shared
      }
      coordinator = coordinator_with_inspector(
        dir,
        FakeInspector.new(heads: {}, remote_urls:)
      )

      metrics = unlock_metrics(coordinator)

      assert_equal({ "unlock_count" => 2, "parallel_width" => 2 }, metrics.fetch("P-DISTINCT"))
      assert_equal({ "unlock_count" => 2, "parallel_width" => 1 }, metrics.fetch("P-ALIAS"))
      assert_equal({ "unlock_count" => 2, "parallel_width" => 2 }, metrics.fetch("P-BRANCH"))
      assert_equal({ "unlock_count" => 2, "parallel_width" => 2 }, metrics.fetch("P-READ"))
    end
  end

  def test_parallel_width_respects_fresh_in_flight_and_candidate_reservations
    with_workspace do |dir|
      write_task(dir, id: "PARENT", repositories: repository("parent"))
      write_task(dir, id: "U-ALPHA", depends_on: ["PARENT"], repositories: repository("alpha"))
      write_task(dir, id: "U-BETA", depends_on: ["PARENT"], repositories: repository("beta"))
      write_task(dir, id: "U-GAMMA", depends_on: ["PARENT"], repositories: repository("gamma"))
      write_task(dir, id: "ACTIVE", repositories: repository("active"))
      write_task(dir, id: "CANDIDATE", repositories: repository("candidate"))
      remote_urls = {
        "active" => "git@github.com:example/alpha.git",
        "alpha" => "git@github.com:example/alpha.git",
        "candidate" => "git@github.com:example/gamma.git",
        "gamma" => "git@github.com:example/gamma.git"
      }
      inspector = FakeInspector.new(
        heads: { "active" => "a" * 40, "candidate" => "c" * 40 },
        remote_urls:
      )
      coordinator = coordinator_with_inspector(dir, inspector)
      coordinator.prepare("ACTIVE")
      coordinator.start("ACTIVE")
      coordinator.prepare("CANDIDATE")
      coordinator.record("CANDIDATE", outcome: "candidate_complete")

      metrics = unlock_metrics(coordinator).fetch("PARENT")

      assert_equal 3, metrics.fetch("unlock_count")
      assert_equal 1, metrics.fetch("parallel_width")
    end
  end

  def test_stale_and_terminal_work_do_not_reserve_writable_capacity
    with_workspace do |dir|
      write_task(dir, id: "PARENT", repositories: repository("parent"))
      write_task(dir, id: "U-ALPHA", depends_on: ["PARENT"], repositories: repository("alpha"))
      write_task(dir, id: "U-BETA", depends_on: ["PARENT"], repositories: repository("beta"))
      write_task(dir, id: "STALE", repositories: repository("stale"))
      write_task(dir, id: "FAILED", repositories: repository("failed"))
      remote_urls = {
        "stale" => "git@github.com:example/alpha.git",
        "alpha" => "git@github.com:example/alpha.git",
        "failed" => "git@github.com:example/beta.git",
        "beta" => "git@github.com:example/beta.git"
      }
      heads = { "stale" => "a" * 40, "failed" => "b" * 40 }
      coordinator = coordinator_with_inspector(dir, FakeInspector.new(heads:, remote_urls:))
      coordinator.prepare("STALE")
      coordinator.start("STALE")
      heads["stale"] = "c" * 40
      coordinator.prepare("FAILED")
      coordinator.record("FAILED", outcome: "failed")

      metrics = unlock_metrics(coordinator).fetch("PARENT")

      assert_equal({ "unlock_count" => 2, "parallel_width" => 2 }, metrics)
    end
  end

  def test_exact_search_finds_maximum_compatible_subset_instead_of_greedy_result
    with_workspace do |dir|
      write_task(dir, id: "PARENT", repositories: repository("parent"))
      write_task(
        dir,
        id: "A-BRIDGE",
        depends_on: ["PARENT"],
        repositories: repository("x").merge(repository("y"))
      )
      write_task(dir, id: "B-LEFT", depends_on: ["PARENT"], repositories: repository("left"))
      write_task(dir, id: "C-RIGHT", depends_on: ["PARENT"], repositories: repository("right"))
      remote_urls = {
        "x" => "git@github.com:example/x.git",
        "left" => "git@github.com:example/x.git",
        "y" => "git@github.com:example/y.git",
        "right" => "git@github.com:example/y.git"
      }
      coordinator = coordinator_with_inspector(
        dir,
        FakeInspector.new(heads: {}, remote_urls:)
      )

      metrics = unlock_metrics(coordinator).fetch("PARENT")

      assert_equal({ "unlock_count" => 3, "parallel_width" => 2 }, metrics)
    end
  end

  private

  def repository(name, access: "write", branch: nil)
    spec = { "access" => access }
    spec["branch"] = branch if branch
    { name => spec }
  end

  def snapshot(name)
    {
      name => {
        "remote_url" => "git@github.com:example/#{name}.git",
        "branch" => "main",
        "pushed_sha" => "a" * 40
      }
    }
  end

  def coordinator_with_inspector(dir, inspector)
    AgentCodingTool::Coordinator.new(
      task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
      state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
      repo_inspector: inspector,
      prompt_renderer: AgentCodingTool::PromptRenderer.new,
      prompt_root: File.join(dir, "state", "prompts")
    )
  end

  def unlock_metrics(coordinator)
    statuses = coordinator.statuses(completion_filter: :all)
    coordinator.ready_unlock_metrics(statuses)
  end
end
