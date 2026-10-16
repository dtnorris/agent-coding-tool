# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

class WriteCollisionTest < Minitest::Test
  include TestHelpers

  # Multiple conflict warnings identify only the authorities shared with that task.
  def test_cli_overlap_warnings_bind_each_conflict_to_its_own_authority
    with_workspace do |dir|
      write_task(dir, id: "A", repositories: { "alpha" => { "access" => "write" } })
      write_task(dir, id: "C", repositories: { "beta" => { "access" => "write" } })
      write_task(dir, id: "B", repositories: { "alpha" => { "access" => "write" }, "beta" => { "access" => "write" } })
      coordinator = coordinator_for(dir, "alpha" => "a" * 40, "beta" => "b" * 40)
      %w[A B C].each { |id| coordinator.prepare(id) }
      %w[A C].each { |id| coordinator.start(id) }
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err: StringIO.new)
      cli.instance_variable_set(:@coordinator, coordinator)
      assert_equal 0, cli.run(%w[start B])
      alpha = out.string.lines.find { |line| line.include?("overlaps A") }
      beta = out.string.lines.find { |line| line.include?("overlaps C") }
      assert_includes alpha, "example/alpha.git [main]"
      refute_includes alpha, "example/beta.git"
      assert_includes beta, "example/beta.git [main]"
      refute_includes beta, "example/alpha.git"
    end
  end

  # Ordinary CLI starts warn with effective authority; the legacy flag is optional.
  def test_ordinary_cli_start_warns_and_records_unverified_overlap
    with_workspace do |dir|
      %w[A B].each { |id| write_task(dir, id:) }
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      %w[A B].each { |id| coordinator.prepare(id) }
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: dir, data_root: dir, out:, err: StringIO.new)
      cli.instance_variable_set(:@coordinator, coordinator)
      assert_equal 0, cli.run(%w[start A])
      assert_equal 0, cli.run(%w[start B])
      assert_includes out.string, "B overlaps A (IN_FLIGHT)"
      assert_includes out.string, "git@github.com:example/alpha.git [main]"
      assert_equal "manual_unverified", coordinator.status("B").dig("state", "write_overlap", "basis")
      refute coordinator.status("B").fetch("state").key?("write_collision_override")
    end
  end

  # Dependency, freshness and preparation refusals preserve every task/prompt byte.
  def test_manual_start_rechecks_dependencies_freshness_and_preparation_without_partial_writes
    %w[dependency stale malformed missing_prompt timestamp result].each do |scenario|
      with_workspace do |dir|
        write_task(dir, id: "DEP")
        write_task(dir, id: "T", depends_on: ["DEP"])
        heads = { "alpha" => "a" * 40 }
        coordinator = coordinator_for(dir, heads)
        coordinator.record("DEP", outcome: "complete")
        coordinator.prepare("T")
        store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
        state = store.load("T")
        case scenario
        when "dependency" then coordinator.reset("DEP")
        when "stale" then heads["alpha"] = "b" * 40
        when "malformed" then state["snapshot"]["alpha"].delete("pushed_sha"); store.write("T", state)
        when "missing_prompt" then File.unlink(state.fetch("prompt_path"))
        when "timestamp" then state["prepared_at"] = "invalid"; store.write("T", state)
        when "result" then state["result"] = "damaged"; store.write("T", state)
        end
        paths = Dir.glob(File.join(dir, "**", "*")).select { |path| File.file?(path) }
        before = paths.to_h { |path| [path, File.binread(path)] }
        assert_raises(AgentCodingTool::Error) { coordinator.start("T") }
        assert_equal before, paths.to_h { |path| [path, File.binread(path)] }, scenario
      end
    end
  end

  def test_manual_overlap_starts_independently_without_mutating_sibling_or_prompt
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("A")
      coordinator.prepare("B")
      coordinator.start("A")
      sibling = File.binread(File.join(dir, "state", "A.yml"))
      prompt_path = coordinator.status("B").dig("state", "prompt_path")
      prompt = File.binread(prompt_path)

      state = coordinator.start("B")

      assert_equal "manual_unverified", state.dig("write_overlap", "basis")
      assert_equal ["A"], state.dig("write_overlap", "conflicts").map { |row| row.fetch("task_id") }
      assert_equal [{ "remote_url" => "git@github.com:example/alpha.git", "branch" => "main" }], state.dig("write_overlap", "authorities")
      refute state.key?("write_collision_override")
      assert_equal sibling, File.binread(File.join(dir, "state", "A.yml"))
      assert_equal prompt, File.binread(prompt_path)
      assert_equal %w[IN_FLIGHT IN_FLIGHT], coordinator.statuses.map { |row| row.fetch("status") }
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

  def test_fresh_candidate_warns_and_stale_candidate_remains_recoverable
    with_workspace do |dir|
      write_task(dir, id: "A")
      write_task(dir, id: "B")
      heads = { "alpha" => "a" * 40 }
      coordinator = coordinator_for(dir, heads)
      coordinator.prepare("A")
      coordinator.start("A")
      coordinator.record("A", outcome: "candidate_complete")
      coordinator.prepare("B")

      state = coordinator.start("B")
      assert_equal "CANDIDATE", state.dig("write_overlap", "conflicts").first.fetch("status")

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

      state = coordinator.start("B")
      assert_equal ["alias"], state.dig("write_overlap", "conflicts").first.fetch("repositories")
      assert_equal [{ "remote_url" => remote, "branch" => "main" }], state.dig("write_overlap", "authorities")
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
      assert_includes out.string, "Started B: IN_FLIGHT\n"
      assert_includes out.string, "A (IN_FLIGHT)"
      assert_includes out.string, "git@github.com:example/alpha.git [main]"
      assert_includes out.string, "isolation and worker liveness unverified"
      assert_empty err.string
      assert coordinator.status("B").fetch("state").key?("write_collision_override")
    end
  end
end
