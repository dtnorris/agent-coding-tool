# frozen_string_literal: true

require_relative "test_helper"

class LiveWriteCollisionStatusTest < Minitest::Test
  include TestHelpers

  def test_three_task_status_reports_only_the_in_flight_writer_as_a_blocker
    with_workspace do |dir|
      %w[IG-09C IG-07A IG-11C].each { |id| write_task(dir, id:) }
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      %w[IG-09C IG-07A IG-11C].each { |id| coordinator.prepare(id) }
      coordinator.start("IG-09C")

      statuses = coordinator.statuses.to_h { |status| [status.fetch("id"), status] }
      expected = [{
        "task_id" => "IG-09C", "status" => "IN_FLIGHT", "repositories" => ["alpha"]
      }]

      assert_equal expected, statuses.fetch("IG-07A").fetch("write_collisions")
      assert_equal expected, statuses.fetch("IG-11C").fetch("write_collisions")
      refute_includes statuses.fetch("IG-07A").fetch("write_collisions").map { |item| item["task_id"] }, "IG-11C"
      refute_includes statuses.fetch("IG-11C").fetch("write_collisions").map { |item| item["task_id"] }, "IG-07A"
    end
  end

  def test_candidate_writer_blocks_and_terminal_outcomes_clear_the_diagnostic
    %w[complete failed blocked needs_judgment].each do |outcome|
      with_workspace do |dir|
        write_task(dir, id: "A")
        write_task(dir, id: "B")
        coordinator = coordinator_for(dir, "alpha" => "a" * 40)
        coordinator.prepare("A")
        coordinator.start("A")
        coordinator.record("A", outcome: "candidate_complete")
        coordinator.prepare("B")

        assert_equal "CANDIDATE", coordinator.status("B").dig("write_collisions", 0, "status")

        coordinator.record("A", outcome:)
        refute coordinator.status("B").key?("write_collisions"), outcome
      end
    end
  end

  def test_stale_in_flight_and_stale_candidate_writers_do_not_block
    [nil, "candidate_complete"].each do |outcome|
      with_workspace do |dir|
        write_task(dir, id: "A")
        write_task(dir, id: "B")
        heads = { "alpha" => "a" * 40 }
        coordinator = coordinator_for(dir, heads)
        coordinator.prepare("A")
        coordinator.start("A")
        coordinator.record("A", outcome:) if outcome
        heads["alpha"] = "b" * 40
        coordinator.prepare("B")

        assert_includes %w[STALE STALE_CANDIDATE], coordinator.status("A").fetch("status")
        refute coordinator.status("B").key?("write_collisions")
      end
    end
  end

  def test_prepared_distinct_and_read_only_tasks_do_not_block
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      write_task(dir, id: "DISTINCT", repositories: { "beta" => { "access" => "write" } })
      write_task(dir, id: "READER", repositories: { "alpha" => { "access" => "read_only" } })
      coordinator = coordinator_for(dir, "alpha" => "a" * 40, "beta" => "b" * 40)
      %w[A B DISTINCT READER].each { |id| coordinator.prepare(id) }

      refute coordinator.status("B").key?("write_collisions")
      coordinator.start("A")
      refute coordinator.status("DISTINCT").key?("write_collisions")
      refute coordinator.status("READER").key?("write_collisions")
    end
  end

  def test_aliases_collide_by_remote_and_branch_and_report_the_target_repository_name
    with_workspace do |dir|
      write_task(dir, id: "A", repositories: { "primary" => { "access" => "write" } })
      write_task(dir, id: "B", repositories: { "alias" => { "access" => "write" } })
      remote = "git@github.com:example/shared.git"
      inspector = FakeInspector.new(
        heads: { "primary" => "a" * 40, "alias" => "a" * 40 },
        remote_urls: { "primary" => remote, "alias" => remote }
      )
      coordinator = build_coordinator(dir, inspector)
      coordinator.prepare("A")
      coordinator.prepare("B")
      coordinator.start("A")

      assert_equal [{
        "task_id" => "A", "status" => "IN_FLIGHT", "repositories" => ["alias"]
      }], coordinator.status("B").fetch("write_collisions")
    end
  end

  def test_same_remote_on_distinct_branches_does_not_block
    with_workspace do |dir|
      write_task(dir, id: "A", repositories: { "alpha" => { "access" => "write" } })
      write_task(dir, id: "B", repositories: { "alpha" => { "access" => "write" } })
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("A")
      coordinator.prepare("B")
      store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      state = store.load("B")
      state.fetch("snapshot").fetch("alpha")["branch"] = "feature"
      store.write("B", state)
      coordinator.start("A")

      refute coordinator.status("B").key?("write_collisions")
    end
  end

  def test_multiple_blockers_and_repository_overlaps_are_deterministic
    with_workspace do |dir|
      repositories = {
        "alpha" => { "access" => "write" },
        "beta" => { "access" => "write" }
      }
      write_task(dir, id: "A", repositories:)
      write_task(dir, id: "B", repositories: { "beta" => { "access" => "write" } })
      write_task(dir, id: "TARGET", repositories:)
      coordinator = coordinator_for(dir, "alpha" => "a" * 40, "beta" => "b" * 40)
      %w[A B TARGET].each { |id| coordinator.prepare(id) }
      coordinator.start("A")
      coordinator.start("B", allow_write_collision: true)

      assert_equal [
        { "task_id" => "A", "status" => "IN_FLIGHT", "repositories" => %w[alpha beta] },
        { "task_id" => "B", "status" => "IN_FLIGHT", "repositories" => ["beta"] }
      ], coordinator.status("TARGET").fetch("write_collisions")
    end
  end

  def test_stale_target_keeps_freshness_reason_instead_of_prepared_collision
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      heads = { "alpha" => "a" * 40 }
      coordinator = coordinator_for(dir, heads)
      coordinator.prepare("A")
      coordinator.prepare("B")
      coordinator.start("A")
      heads["alpha"] = "b" * 40

      status = coordinator.status("B")

      assert_equal "STALE", status.fetch("status")
      assert_equal "pushed branch changed: alpha", status.fetch("reason")
      refute status.key?("write_collisions")
    end
  end

  def test_read_only_refresh_warning_survives_alongside_collision
    with_workspace do |dir|
      write_task(dir, id: "A", repositories: { "alpha" => { "access" => "write" } })
      write_task(dir, id: "B", repositories: {
                   "alpha" => { "access" => "write" },
                   "reference" => { "access" => "read_only" }
                 })
      heads = { "alpha" => "a" * 40, "reference" => "r" * 40 }
      coordinator = coordinator_for(dir, heads)
      coordinator.prepare("A")
      coordinator.prepare("B")
      coordinator.start("A")
      heads["reference"] = "s" * 40

      status = coordinator.status("B")

      assert_equal "PREPARED", status.fetch("status")
      assert_includes status.fetch("reason"), "reference"
      assert_equal "A", status.dig("write_collisions", 0, "task_id")
    end
  end

  def test_status_batches_freshness_and_does_not_mutate_runtime_state
    with_workspace do |dir|
      %w[A B C].each { |id| write_task(dir, id:) }
      inspector = FakeInspector.new(heads: { "alpha" => "a" * 40 })
      calls = []
      inspector.define_singleton_method(:pushed_heads) do |references|
        calls << references
        super(references)
      end
      coordinator = build_coordinator(dir, inspector)
      %w[A B C].each { |id| coordinator.prepare(id) }
      coordinator.start("A")
      calls.clear
      state_paths = %w[A B C].to_h do |id|
        path = File.join(dir, "state", "#{id}.yml")
        [path, File.binread(path)]
      end

      statuses = coordinator.statuses(["B", "C"])

      assert_equal 1, calls.length
      assert_equal %w[A B C], calls.first.map { |reference| reference.fetch("name").split("/").first }.sort
      assert statuses.all? { |status| status.fetch("write_collisions").length == 1 }
      state_paths.each { |path, content| assert_equal content, File.binread(path) }
    end
  end

  private

  def build_coordinator(dir, inspector)
    AgentCodingTool::Coordinator.new(
      task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
      state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
      repo_inspector: inspector,
      prompt_renderer: AgentCodingTool::PromptRenderer.new,
      prompt_root: File.join(dir, "state", "prompts")
    )
  end
end
