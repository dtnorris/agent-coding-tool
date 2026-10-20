# frozen_string_literal: true

require_relative "test_helper"
require_relative "launcher_support"
require_relative "recovery_observations"
require "stringio"

# Native pre-worker abandonment, with real evidence, ownership and removal;
# strict empty observations verify lifecycle refusals precede external commands.
class PreflightRecoveryTest < Minitest::Test
  include TestHelpers
  include LauncherSupport
  include RecoveryObservations

  def git(*args, chdir:)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: chdir)
    assert status.success?, stderr
    stdout.strip
  end

  def failed_attempt
    write_fake("leaky")
    error = assert_raises(AgentCodingTool::InvalidState) { launcher(real_sandbox_probe: true).launch("T") }
    assert_match(/sandbox boundary unverified/, error.message)
    JSON.parse(File.binread(Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)))
  end

  def recovery(**options)
    AgentCodingTool::PreflightRecovery.new(data_root: @data, liveness: ->(*) { true }, **options)
  end

  def test_explicit_abandonment_removes_only_clean_owned_worktrees_and_preserves_evidence
    fixture(git: true) do
      report = failed_attempt
      path = report.fetch("workspace")
      fixture_path = report.fetch("fixture").fetch("path")
      File.binwrite(File.join(fixture_path, "retained.bin"), "\x00\xfffixture".b)
      File.symlink(@data, File.join(fixture_path, "protected-link"))
      assert_equal "preflight_failed", report.fetch("status")
      refute @store.load("T")["started_at"]
      assert File.directory?(path)
      assert_equal false, recovery.preflight("T").fetch("abandoned")
      result = recovery.abandon("T")
      assert result.fetch("abandoned")
      refute File.exist?(path)
      assert_equal "failed", @store.load("T").dig("result", "outcome")
      assert_equal "preflight_abandoned", JSON.parse(File.binread(File.join(result.fetch("run_dir"), "handoff.json"))).fetch("status")
      assert File.file?(result.fetch("record_path"))
      assert_equal "\x00\xfffixture".b, File.binread(File.join(fixture_path, "retained.bin"))
      assert File.symlink?(File.join(fixture_path, "protected-link"))
      assert_equal result, recovery.abandon("T")
      assert_raises(AgentCodingTool::InvalidState) { launcher.launch("T") }
      checkpoint = File.join("#{@data}-runs", "checkpoints", "NC-02D", "attempt")
      FileUtils.mkdir_p(checkpoint, mode: 0o700)
      File.write(File.join(checkpoint, "current.json"), '{"preserved":true}')
      Time.stub(:now, Time.now + 2) { @coordinator.prepare("T", retry_result: true) }
      write_fake("success")
      assert_equal 0, launcher.launch("T")
      later = Dir.glob("#{@data}-runs/T/*/handoff.json").map { |record| JSON.parse(File.binread(record)) }.find { |record| record["attempt"] == 2 }
      refute_equal fixture_path, later.fetch("fixture").fetch("path")
      assert_equal "\x00\xfffixture".b, File.binread(File.join(fixture_path, "retained.bin"))
      assert_equal '{"preserved":true}', File.binread(File.join(checkpoint, "current.json"))
      @coordinator.record("T", outcome: "complete")
      cleanup = AgentCodingTool::CleanupManager.new(data_root: @data).preflight("T")
      assert_equal [], cleanup.fetch("attempts").find { |row| row["state"] == "preflight_abandoned" }.fetch("blockers")
      assert cleanup.fetch("blocked") # the later worker has not met normal delivery/liveness gates
    end
  end

  # Interrupts after the first owned removal, checks retained evidence and the
  # remaining native resource, then requires a successful production resume.
  def test_recovery_resumes_after_one_native_removal_without_erasing_evidence
    fixture(git: true) do
      reader = File.join(@root, "reader")
      reader_remote = File.join(@root, "reader.git")
      git("clone", "--bare", @remote, reader_remote, chdir: @root)
      git("clone", reader_remote, reader, chdir: @root)
      task_path = File.join(@data, "tasks", "T.yml")
      task = YAML.safe_load_file(task_path)
      task.fetch("repositories")["reader"] = { "access" => "read_only", "path" => reader }
      File.write(task_path, YAML.dump(task))
      report = failed_attempt
      report_path = Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)
      original_report = File.binread(report_path)
      original_state = @store.load("T")
      count = 0
      interrupted = recovery(after_removal: ->(*) { count += 1; raise "interrupted" if count == 1 })
      assert_raises(RuntimeError) { interrupted.abandon("T") }
      assert_equal original_report, File.binread(report_path)
      assert_equal original_state, @store.load("T")
      inventory = JSON.parse(File.binread(report.fetch("worktrees_path")))
      assert_equal %w[removed ready], inventory.fetch("entries").map { |entry| entry.fetch("state") }
      refute File.exist?(inventory.fetch("entries").first.fetch("path"))
      assert File.directory?(inventory.fetch("entries").last.fetch("path"))
      assert recovery.abandon("T").fetch("abandoned")
      refute File.exist?(report.fetch("workspace"))
      assert_equal ["removed"], JSON.parse(File.binread(report.fetch("worktrees_path"))).fetch("entries").map { |entry| entry.fetch("state") }.uniq
    end
  end

  def test_second_failed_preflight_can_be_abandoned_after_fresh_preparation
    fixture(git: true) do
      failed_attempt
      assert recovery.abandon("T").fetch("abandoned")
      Time.stub(:now, Time.now + 2) { @coordinator.prepare("T", retry_result: true) }
      failed_attempt
      assert_equal 2, Dir.glob("#{@data}-runs/T/*/handoff.json").length
      assert recovery.abandon("T").fetch("abandoned")
    end
  end

  # Reuses one native failed attempt across independent refusal controls. Each
  # reversible mutation is restored before the next control; foreign bytes stay.
  def test_dirty_foreign_changed_active_and_worker_started_attempts_refuse_removal
    fixture(git: true) do
      report = failed_attempt
      path = report.fetch("workspace")
      File.write(File.join(path, "keep.txt"), "operator work")
      assert_raises(AgentCodingTool::InvalidState) { recovery.abandon("T") }
      assert File.file?(File.join(path, "keep.txt"))
      File.unlink(File.join(path, "keep.txt"))
      assert_raises(AgentCodingTool::InvalidState) do
        AgentCodingTool::PreflightRecovery.new(data_root: @data, liveness: ->(*) { false }).abandon("T")
      end
      assert File.directory?(path)
      foreign = File.join(@root, "worktrees", "T", "foreign")
      FileUtils.mkdir_p(foreign)
      File.binwrite(File.join(foreign, "keep"), "operator\x00\xff".b)
      assert_raises(AgentCodingTool::InvalidState) { recovery.abandon("T") }
      assert File.directory?(report.fetch("workspace"))
      assert_equal "operator\x00\xff".b, File.binread(File.join(foreign, "keep"))
      File.unlink(File.join(foreign, "keep"))
      Dir.rmdir(foreign)

      report_path = Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)
      original_report = File.binread(report_path)
      original_inventory = File.binread(report.fetch("worktrees_path"))
      original_state = @store.load("T")
      begin
        File.write(report_path, JSON.pretty_generate(report.merge("child_pid" => 12345)))
        changed_report = File.binread(report_path)
        with_recovery_observations([]) do
          error = assert_raises(AgentCodingTool::InvalidState) { recovery.abandon("T") }
          assert_includes error.message, "pre-worker identity or lifecycle is unverified"
        end
        assert_equal changed_report, File.binread(report_path)
        assert_equal original_inventory, File.binread(report.fetch("worktrees_path"))
        assert_equal original_state, @store.load("T")
        assert File.directory?(path)
      ensure
        File.binwrite(report_path, original_report)
      end
      refute recovery.preflight("T").fetch("abandoned")
      git("commit", "--allow-empty", "-m", "changed", chdir: path)
      assert_raises(AgentCodingTool::InvalidState) { recovery.abandon("T") }
      assert_equal original_inventory, File.binread(report.fetch("worktrees_path"))
    end
  end
end
