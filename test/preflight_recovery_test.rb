# frozen_string_literal: true

require_relative "test_helper"
require_relative "launcher_support"
require "stringio"

class PreflightRecoveryTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

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
      assert_equal result, recovery.abandon("T")
      assert_raises(AgentCodingTool::InvalidState) { launcher.launch("T") }
      Time.stub(:now, Time.now + 2) { @coordinator.prepare("T", retry_result: true) }
      write_fake("success")
      assert_equal 0, launcher.launch("T")
      @coordinator.record("T", outcome: "complete")
      cleanup = AgentCodingTool::CleanupManager.new(data_root: @data).preflight("T")
      assert_equal [], cleanup.fetch("attempts").find { |row| row["state"] == "preflight_abandoned" }.fetch("blockers")
      assert cleanup.fetch("blocked") # the later worker has not met normal delivery/liveness gates
    end
  end

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
      count = 0
      interrupted = recovery(after_removal: ->(*) { count += 1; raise "interrupted" if count == 1 })
      assert_raises(RuntimeError) { interrupted.abandon("T") }
      assert_equal "preflight_failed", JSON.parse(File.binread(Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0))).fetch("status")
      assert recovery.abandon("T").fetch("abandoned")
      refute File.exist?(report.fetch("workspace"))
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
      git("commit", "--allow-empty", "-m", "changed", chdir: path)
      assert_raises(AgentCodingTool::InvalidState) { recovery.abandon("T") }
    end
    fixture(git: true) do
      report = failed_attempt
      FileUtils.mkdir_p(File.join(@root, "worktrees", "T", "foreign"))
      assert_raises(AgentCodingTool::InvalidState) { recovery.abandon("T") }
      assert File.directory?(report.fetch("workspace"))
    end
    fixture(git: true) do
      report = failed_attempt
      path = Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)
      report["child_pid"] = 12345
      File.write(path, JSON.pretty_generate(report))
      assert_raises(AgentCodingTool::InvalidState) { recovery.abandon("T") }
      assert File.directory?(report.fetch("workspace"))
    end
  end
end
