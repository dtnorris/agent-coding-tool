# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/status_scale"
require "minitest/mock"
require "stringio"

# Exercises the public advisory journey against the uncached implementation,
# including a deterministic work budget independent of host/network timing.
class StatusReadViewTest < Minitest::Test
  include TestHelpers

  # Renders one real CLI command using the given coordinator; returns raw streams
  # and exit code. No Git/process or lifecycle writer is substituted into the CLI.
  def render(coordinator, root, arguments)
    output, error = StringIO.new, StringIO.new
    cli = AgentCodingTool::CLI.new(root: root, data_root: root, out: output, err: error, terminal_width: 100)
    cli.instance_variable_set(:@coordinator, coordinator)
    code = cli.run(arguments.dup)
    [output.string, error.string, code]
  end

  # Counts actual task/state YAML parses while preserving exact parsing/errors.
  # Returns [command result, count]; restoration also occurs on refusal.
  def count_yaml
    count = 0
    original = YAML.method(:safe_load_file)
    result = YAML.stub(:safe_load_file, lambda { |*args, **options|
      count += 1
      original.call(*args, **options)
    }) { yield }
    [result, count]
  end

  # The same work budget rejects restored repeated scans with identical output.
  # Representative complete/READY/blocked/prepared/active/candidate/Icebox rows
  # also traverse the shared production ranking and NEXT planner.
  def test_public_dashboard_equivalence_and_repeated_scan_negative_control
    Dir.mktmpdir do |parent|
      root = File.join(parent, "data")
      count = 200
      StatusScale.generate(root, count: count)
      coordinator = coordinator_for(root, 7.times.to_h { |index| ["repo#{index}", StatusScale::SHA] })
      old_result, old_reads = coordinator.stub(:read_view, coordinator) do
        count_yaml { render(coordinator, root, %w[status --full]) }
      end
      result, reads = count_yaml { render(coordinator, root, %w[status --full]) }
      assert_equal 0, result.last
      assert_equal old_result, result
      assert_operator reads, :<=, 2 * count
      assert_operator old_reads, :>, 2 * count
      %w[--all --active --icebox --min].each do |flag|
        arguments = ["status", flag]
        expected = coordinator.stub(:read_view, coordinator) { render(coordinator, root, arguments) }
        assert_equal expected, render(coordinator, root, arguments)
      end
      [%w[status --fam F0 --full], %w[status F0-00098 --full], %w[next], %w[next --json]].each do |arguments|
        expected = coordinator.stub(:read_view, coordinator) { render(coordinator, root, arguments) }
        actual = render(coordinator, root, arguments)
        assert_equal 0, actual.last
        assert_equal expected, actual
      end
    end
  end

  # Replacement retains the first per-file observation only inside one view.
  # A subsequent view sees changed task/state bytes, including a new state file.
  def test_replacement_and_absence_are_scoped_to_one_invocation
    with_workspace do |root|
      write_task(root, id: "A", title: "Original")
      coordinator = coordinator_for(root, {})
      view = coordinator.read_view
      assert_equal "Original", view.tasks.first.fetch("title")
      assert_equal "READY", view.status("A").fetch("status")
      write_task(root, id: "A", title: "Replacement")
      AgentCodingTool::StateStore.new(File.join(root, "state")).write("A", { "result" => { "outcome" => "complete" } })
      assert_equal "READY", view.status("A").fetch("status")
      assert_equal "Original", view.tasks.first.fetch("title")
      assert_equal "COMPLETE", coordinator.read_view.status("A").fetch("status")
      assert_equal "Replacement", coordinator.read_view.tasks.first.fetch("title")
      assert_equal "COMPLETE", coordinator.status("A").fetch("status")
    end
  end

  # Malformed first reads refuse and are never cached as missing/valid evidence.
  # Later invocation and ordinary writer admission still use independent reads.
  def test_malformed_reads_and_writer_store_remain_independent
    with_workspace do |root|
      write_task(root, id: "A")
      path = File.join(root, "state", "A.yml")
      File.write(path, "[broken")
      coordinator = coordinator_for(root, {})
      view = coordinator.read_view
      assert_raises(AgentCodingTool::InvalidState) { view.status("A") }
      File.write(path, YAML.dump("icebox" => { "at" => "2026-01-01T00:00:00Z" }))
      assert_equal "ICEBOX", view.status("A").fetch("status")
      assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("A") }
      File.write(path, YAML.dump("result" => { "outcome" => "complete" }))
      assert_equal "COMPLETE", coordinator.status("A").fetch("status")
      assert_equal "ICEBOX", view.status("A").fetch("status")
      File.write(File.join(root, "tasks", "A.yml"), "[broken")
      assert_raises(Psych::Exception) { coordinator.read_view.status("A") }
    end
  end

  # Authority caching uses effective path/remote/branch and only one read view.
  # Live pushed heads are never reused, even within that view.
  def test_authority_and_remote_movement_are_not_persistently_cached
    config = AgentCodingTool::Config.new(AgentCodingTool::Config::DEFAULTS.merge("repo_root" => "/repos"), base_dir: "/")
    calls = []
    remote = "https://github.com/example/one.git"
    head = "a" * 40
    runner = Object.new
    runner.define_singleton_method(:capture) do |*arguments, chdir: nil|
      calls << [chdir, arguments]
      case arguments[1]
      when "rev-parse" then [".git", "", true]
      when "remote" then [remote, "", true]
      when "ls-remote" then ["#{head}\trefs/heads/main\n", "", true]
      else raise "unexpected command"
      end
    end
    inspector = AgentCodingTool::RepoInspector.new(config, runner: runner)
    view = inspector.read_view
    spec = { "path" => "/repos/shared" }
    assert_equal [remote, "main"], view.repository_authority("one", spec)
    assert_equal [remote, "main"], view.repository_authority("alias", spec)
    assert_equal 2, calls.length
    remote = "https://github.com/example/two.git"
    assert_equal [remote, "main"], inspector.read_view.repository_authority("alias", spec)
    references = [{ "name" => "one", "remote_url" => remote, "branch" => "main" }]
    assert_equal head, view.pushed_heads(references).fetch([remote, "main"])
    head = "b" * 40
    assert_equal head, view.pushed_heads(references).fetch([remote, "main"])
    assert_equal 2, calls.count { |_cwd, arguments| arguments[1] == "ls-remote" }
  end
end
