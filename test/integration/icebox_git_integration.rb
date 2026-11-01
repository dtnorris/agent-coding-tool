# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../launcher_support"
require_relative "../git_contract/observations"
require "timeout"

# Cold public CLI proof with disposable Git authorities and a finite fake Codex.
# The fake executable models only the external worker/sandbox boundary.
class IceboxGitIntegrationTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Proves deferral, factual inventory, refusal without side effects and explicit
  # restoration continuously, using a fresh process for every public command.
  def test_public_cli_journey
    journey_fixture do
      before = definition_bytes
      initial = JSON.parse(cli!("next", "--json"))
      assert_equal %w[TST-A TST-B], initial.dig("recommendations", "starts").map { |row| row.fetch("id") }
      assert_equal 1, initial.dig("recommendations", "starts", 0, "downstream", "immediate_unlock_count")

      cli!("icebox", "TST-A", "--reason", "Revisit after profiling")
      state = @store.load("TST-A")
      details = cli!("status", "TST-A", "--full")
      assert_includes details, "TST-A: ICEBOX"
      assert_includes details, "Revisit after profiling"
      assert_includes details, "act unicebox TST-A"
      assert_includes cli!("status", "--icebox", "--full"), "TST-A: ICEBOX"
      document = JSON.parse(cli!("next", "--json"))
      assert_equal "agent-coding-tool-next/v0.1", document.fetch("schema_version")
      deferred = document.dig("facts", "tasks").find { |row| row.fetch("id") == "TST-A" }
      assert_equal "ICEBOX", deferred.fetch("status")
      assert_equal "READY", deferred.fetch("lifecycle_status")
      assert_equal state.fetch("icebox"), deferred.fetch("icebox")
      assert_equal ["TST-B"], document.dig("recommendations", "starts").map { |row| row.fetch("id") }
      assert_empty document.dig("recommendations", "waiting_capacity")
      blocked = document.dig("facts", "tasks").find { |row| row.fetch("id") == "TST-C" }
      assert_equal "BLOCKED", blocked.fetch("status")
      assert_includes blocked.fetch("reason"), "TST-A"
      human_next = cli!("next")
      refute_includes human_next, "act prepare TST-A"
      refute_includes human_next, "act start TST-A"
      assert_includes human_next, "act prepare TST-B"

      [%w[prepare TST-A], %w[launch TST-A --codex]].each do |args|
        _output, error, status = cli(*args)
        assert_equal 2, status.exitstatus, "Icebox guard missing for #{args.inspect}: #{error}"
        assert_includes error, "ICEBOX"
        assert_equal state, @store.load("TST-A")
        assert_empty Dir.glob(File.join(@data, "state/prompts/*"))
        refute File.exist?("#{@data}-runs/TST-A")
        refute File.exist?(File.join(@root, "worker-pid"))
      end
      dashboard = cli!("status", "--full")
      refute_match(/^TST-A:/, dashboard)
      assert_equal "1 Icebox task from families (TST)\n", dashboard.lines.last
      assert_equal 1, dashboard.scan(/^\d+ Icebox/).length
      minimal = cli!("status", "--min")
      assert_equal minimal, cli!("status")
      assert_equal ["TST-B: READY (NEXT)  Task\n", "TST-C: BLOCKED       Task\n"], minimal.lines
      all = cli!("status", "--all", "--full")
      assert_operator all.index("TST-C: BLOCKED"), :<, all.index("TST-A: ICEBOX")

      # Report reality while deliberately deferred: every public projection
      # retains both facts, and ending a report never restores scheduling.
      report = JSON.parse(cli!("external", "report", "TST-A", "--reporter", "operator",
                               "--kind", "fake-codex", "--scope-complete"))
      observation = report.fetch("active").fetch("observation_id")
      [%w[status --full], %w[next]].each do |command|
        view = cli!(*command)
        assert_includes view, "EXTERNAL WORK REPORTED"
        assert_includes view, "unauthorized by ACT"
        assert_includes view, "liveness unknown"
      end
      assert_includes cli!("status", "--full"), "TST-A: ICEBOX"
      minimal = cli!("status", "--icebox", "--min")
      assert_equal minimal, cli!("status", "--icebox")
      assert_equal "TST-A: ICEBOX [external repor..  Task\n".b, minimal
      assert_includes cli!("next"), "TST-A (ICEBOX)"
      assert_includes cli!("next"), "act unicebox TST-A"
      reported = JSON.parse(cli!("next", "--json"))
      fact = reported.dig("facts", "tasks").find { |row| row["id"] == "TST-A" }
      assert_equal ["ICEBOX", "READY", state.fetch("icebox"), observation],
                   [fact["status"], fact["lifecycle_status"], fact["icebox"], fact.dig("external_activity", "observation_id")]
      assert_nil fact["execution_evidence"]
      refute_includes reported.dig("recommendations", "starts").map { |row| row["id"] }, "TST-A"
      cli!("external", "end", "TST-A", observation, "--disposition", "ended")
      assert_equal state, @store.load("TST-A")
      refute_match(/^TST-A:/, cli!("status", "--full"))

      cli!("unicebox", "TST-A")
      assert_equal "READY", JSON.parse(cli!("next", "--json")).dig("facts", "tasks").find { |row| row["id"] == "TST-A" }.fetch("status")
      cli!("prepare", "TST-A")
      assert @store.load("TST-A")["snapshot"]
      report = JSON.parse(cli!("external", "report", "TST-A", "--reporter", "operator", "--kind", "fake-codex"))
      retained = @store.load("TST-A")
      [%w[start TST-A --allow-write-collision], %w[launch TST-A --codex --allow-write-collision]].each do |args|
        _output, error, status = cli(*args)
        assert_equal 2, status.exitstatus, error
        assert_includes error, "external activity conflict"
        assert_equal retained, @store.load("TST-A")
        refute File.exist?(File.join(@root, "worker-pid"))
      end
      cli!("external", "end", "TST-A", report.fetch("active").fetch("observation_id"), "--disposition", "ended")
      cli!("start", "TST-A")
      assert @store.load("TST-A")["started_at"]
      assert_equal before, definition_bytes
      # This positive control traverses the same automatic preparation path
      # and fake worker boundary the deferred launch must never reach.
      cli!("launch", "TST-B", "--codex", "--reasoning", "high")
      assert File.file?(File.join(@root, "worker-pid"))
      assert @store.load("TST-B")["started_at"]
    end
  end

  # Removing the preparation guard makes the very same journey fail at its
  # safety assertion, proving a refusal cannot pass due to an unready fixture.
  def test_guard_removal_negative_control
    output, error, status = ChildProcesses.capture('icebox_control',
      environment: { 'ACT19_REMOVE_PREPARE_GUARD' => '1' }, seconds: 20)
    refute status.success?, error
    assert_includes output, "Icebox guard missing", "negative-control exit #{status.exitstatus}; stderr: #{error}"
    assert_includes output, "1 failures"
    assert_includes output, "0 errors"
  end

  # Qualifies exact binary/text streams and real status for the reused observer.
  def test_process_observer_preserves_bytes_and_status
    output, error, status = ChildProcesses.capture('process_probe', arguments: ['icebox_bytes'])
    assert_equal "text\n".b + [0, 255].pack("C*"), output
    assert_equal [254, 0].pack("C*"), error
    assert_equal 7, status.exitstatus
  end

  # File barriers pause a real state writer while it holds the shared launch
  # reservation. Both Icebox/preparation and Icebox/automatic-launch orders have
  # one winner; the losing cold CLI cannot produce a task reservation or worker.
  def test_cli_preparation_and_auto_launch_races
    %w[icebox prepare launch].each do |first|
      journey_fixture do
        barrier = File.join(@root, "barrier")
        command = [first, "TST-A"]
        command << "--codex" if first == "launch"
        worker = Thread.new { cli(*command, environment: { "ACT19_BARRIER" => barrier }) }
        Timeout.timeout(10) { sleep 0.005 until File.file?("#{barrier}.entered") }
        opponents = first == "icebox" ? [%w[prepare TST-A], %w[launch TST-A --codex]] : [%w[icebox TST-A]]
        opponents.each do |opponent|
          _output, error, status = cli(*opponent)
          assert_equal 2, status.exitstatus, error
          assert_includes error, "reservation busy"
          refute File.exist?(File.join(@root, "worker-pid"))
        end
        File.write("#{barrier}.release", "release")
        _output, error, status = Timeout.timeout(20) { worker.value }
        assert status.success?, error
        state = @store.load("TST-A")
        if first == "icebox"
          assert state["icebox"]
          refute state["snapshot"]
        else
          assert state["snapshot"]
          refute state["icebox"]
        end
        assert_equal first == "launch", !!state["started_at"]
        assert_equal first == "launch", File.exist?(File.join(@root, "worker-pid"))
        assert_equal first == "launch", File.directory?("#{@data}-runs/TST-A")
      ensure
        File.write("#{barrier}.release", "release") if barrier
        worker&.join(20)
      end
    end
  end

  private

  # Builds independent modeled authorities for cold public commands. The shared
  # launcher bootstrap keeps source identity at the admitted candidate; test data
  # and mutable stores remain private to this case.
  def journey_fixture
    fixture(git: true, process: true) do
      File.unlink(File.join(@data, "tasks/T.yml"))
      # B has an independent local authority, so A's preparation cannot reserve it.
      second = File.join(@root, "second")
      second_remote = File.join(@root, "second.git")
      memory_repository(@memory_world, path: second, remote: second_remote)
      write_task(@data, id: "TST-A", repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      write_task(@data, id: "TST-B", repositories: { "repo" => { "access" => "write", "path" => second } })
      write_task(@data, id: "TST-C", depends_on: ["TST-A"], repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      yield
    end
  end

  # Invokes the public binary through the shared guarded launcher with raw bytes
  # and its 15-second owned-group deadline. Codex remains the finite worker.
  def cli(*args, environment: {})
    controls = { 'ACT19_REMOVE_PREPARE_GUARD' => ENV['ACT19_REMOVE_PREPARE_GUARD'] }.merge(environment)
    cold_launcher(*args, fixture: 'icebox_cli', environment: controls)
  end

  # Asserts public success and returns raw stdout, retaining diagnostic stderr.
  def cli!(*args)
    output, error, status = cli(*args)
    assert status.success?, "#{args.inspect}: #{error}"
    output
  end

  # Returns exact task-definition bytes for preservation assertions.
  def definition_bytes
    Dir.glob(File.join(@data, "tasks/*.yml")).to_h { |path| [path, File.binread(path)] }
  end
end
