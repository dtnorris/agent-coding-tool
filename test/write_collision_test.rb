# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class WriteCollisionTest < Minitest::Test
  include TestHelpers

  def test_in_flight_write_collision_blocks_start_without_mutating_prepared_task
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("A")
      coordinator.prepare("B")
      coordinator.start("A")
      before = coordinator.status("B").fetch("state")

      error = assert_raises(AgentCodingTool::InvalidState) { coordinator.start("B") }

      assert_includes error.message, "A (IN_FLIGHT)"
      assert_includes error.message, "shared writable repositories: alpha"
      assert_includes error.message, "--allow-write-collision"
      assert_equal before, coordinator.status("B").fetch("state")
      refute coordinator.status("B").fetch("state").key?("started_at")
      assert_equal "PREPARED", coordinator.status("B").fetch("status")
      assert_equal "IN_FLIGHT", coordinator.status("A").fetch("status")
    end
  end

  def test_explicit_override_starts_and_records_collision
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("A")
      coordinator.prepare("B")
      coordinator.start("A")

      state = coordinator.start("B", allow_write_collision: true)

      assert_equal "IN_FLIGHT", coordinator.status("B").fetch("status")
      override = state.fetch("write_collision_override")
      assert Time.iso8601(override.fetch("allowed_at")).utc?
      assert_equal [{
        "task_id" => "A", "status" => "IN_FLIGHT", "repositories" => ["alpha"]
      }], override.fetch("conflicts")
    end
  end

  def test_prepare_remains_allowed_and_cli_warns_about_in_flight_writer
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("A")
      coordinator.start("A")
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err: StringIO.new)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run(%w[prepare B])

      assert_equal "PREPARED", coordinator.status("B").fetch("status")
      assert_includes out.string, "WARNING: B shares writable repository alpha with A (IN_FLIGHT)."
      assert_includes out.string, "Starting both concurrently is likely to make one stale when the other lands."
    end
  end

  def test_different_writable_repositories_can_run_together
    with_workspace do |dir|
      write_task(dir, id: "A", repositories: { "alpha" => { "access" => "write" } })
      write_task(dir, id: "B", repositories: { "beta" => { "access" => "write" } })
      coordinator = coordinator_for(dir, "alpha" => "a" * 40, "beta" => "b" * 40)
      coordinator.prepare("A")
      coordinator.prepare("B")

      coordinator.start("A")
      coordinator.start("B")

      assert_equal %w[IN_FLIGHT IN_FLIGHT], coordinator.statuses.map { |status| status.fetch("status") }
    end
  end

  def test_writer_and_reader_can_run_together
    with_workspace do |dir|
      write_task(dir, id: "WRITER", repositories: { "alpha" => { "access" => "write" } })
      write_task(dir, id: "READER", repositories: { "alpha" => { "access" => "read_only" } })
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("WRITER")
      coordinator.prepare("READER")

      coordinator.start("WRITER")
      coordinator.start("READER")

      assert_equal "IN_FLIGHT", coordinator.status("WRITER").fetch("status")
      assert_equal "IN_FLIGHT", coordinator.status("READER").fetch("status")
    end
  end

  def test_two_readers_can_run_together
    with_workspace do |dir|
      repositories = { "alpha" => { "access" => "read_only" } }
      write_task(dir, id: "A", repositories:)
      write_task(dir, id: "B", repositories:)
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("A")
      coordinator.prepare("B")

      coordinator.start("A")
      coordinator.start("B")

      assert_equal %w[IN_FLIGHT IN_FLIGHT], coordinator.statuses.map { |status| status.fetch("status") }
    end
  end

  def test_stale_in_flight_task_does_not_reserve_repository
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      heads = { "alpha" => "a" * 40 }
      coordinator = coordinator_for(dir, heads)
      coordinator.prepare("A")
      coordinator.start("A")
      heads["alpha"] = "b" * 40
      coordinator.prepare("B")

      assert_equal "STALE", coordinator.status("A").fetch("status")
      coordinator.start("B")
      assert_equal "IN_FLIGHT", coordinator.status("B").fetch("status")
    end
  end

  def test_terminal_non_candidate_states_do_not_block
    %w[complete failed blocked needs_judgment].each do |outcome|
      with_workspace do |dir|
        write_task(dir, id: "A")
        write_task(dir, id: "B")
        coordinator = coordinator_for(dir, "alpha" => "a" * 40)
        coordinator.prepare("A") unless outcome == "complete"
        coordinator.record("A", outcome:)
        coordinator.prepare("B")

        coordinator.start("B")

        assert_equal "IN_FLIGHT", coordinator.status("B").fetch("status"), outcome
      end
    end
  end

  def test_fresh_candidate_blocks_but_stale_candidate_does_not
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      heads = { "alpha" => "a" * 40 }
      coordinator = coordinator_for(dir, heads)
      coordinator.prepare("A")
      coordinator.start("A")
      coordinator.record("A", outcome: "candidate_complete")
      coordinator.prepare("B")

      error = assert_raises(AgentCodingTool::InvalidState) { coordinator.start("B") }
      assert_includes error.message, "A (CANDIDATE)"

      heads["alpha"] = "b" * 40
      assert_equal "STALE_CANDIDATE", coordinator.status("A").fetch("status")
      coordinator.prepare("B")
      coordinator.start("B")
      assert_equal "IN_FLIGHT", coordinator.status("B").fetch("status")
    end
  end

  def test_prepared_tasks_warn_but_do_not_block_first_start
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("A")
      prepared = coordinator.prepare("B")

      assert_equal [{
        "task_id" => "A", "status" => "PREPARED", "repositories" => ["alpha"]
      }], prepared.fetch("write_collisions")
      coordinator.start("B")
      assert_equal "IN_FLIGHT", coordinator.status("B").fetch("status")
    end
  end

  def test_repository_aliases_collide_by_snapshot_remote_and_branch
    with_workspace do |dir|
      write_task(dir, id: "A", repositories: { "primary" => { "access" => "write" } })
      write_task(dir, id: "B", repositories: { "alias" => { "access" => "write" } })
      remote = "git@github.com:example/shared.git"
      inspector = FakeInspector.new(
        heads: { "primary" => "a" * 40, "alias" => "a" * 40 },
        remote_urls: { "primary" => remote, "alias" => remote }
      )
      coordinator = AgentCodingTool::Coordinator.new(
        task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
        state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
        repo_inspector: inspector,
        prompt_renderer: AgentCodingTool::PromptRenderer.new,
        prompt_root: File.join(dir, "state", "prompts")
      )
      coordinator.prepare("A")
      coordinator.prepare("B")
      coordinator.start("A")

      error = assert_raises(AgentCodingTool::InvalidState) { coordinator.start("B") }

      assert_includes error.message, "A (IN_FLIGHT)"
      assert_includes error.message, "shared writable repositories: alias"
    end
  end

  def test_cli_override_flag_allows_collision
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("A")
      coordinator.prepare("B")
      coordinator.start("A")
      out = StringIO.new
      err = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err:)
      cli.instance_variable_set(:@coordinator, coordinator)

      assert_equal 0, cli.run(%w[start B --allow-write-collision])
      assert_equal "Started B: IN_FLIGHT\n", out.string
      assert_empty err.string
      assert coordinator.status("B").fetch("state").key?("write_collision_override")
    end
  end
end
