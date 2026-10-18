# frozen_string_literal: true

require_relative "test_helper"
require_relative "launcher_support"
require "stringio"
require "timeout"

class ParallelLaunchTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  def handoff(id)
    JSON.parse(File.binread(Dir.glob("#{@data}-runs/#{id}/*/handoff.json").fetch(0)))
  end

  def git(*args, chdir:)
    output, error, status = Open3.capture3("git", *args, chdir: chdir)
    assert status.success?, error
    output.strip
  end

  def wait_for_running(id)
    Timeout.timeout(8) do
      loop do
        paths = Dir.glob("#{@data}-runs/#{id}/*/handoff.json")
        return handoff(id) if paths.length == 1 && handoff(id)["status"] == "running" &&
          File.file?(File.join(@root, "stdin")) && File.file?(File.join(@root, "worker-pid"))
        sleep 0.01
      end
    end
  rescue Timeout::Error
    flunk "worker did not start: #{File.read(File.join(@root, 'first-err')) if File.file?(File.join(@root, 'first-err'))}"
  end

  def spawn_cli_worker(id)
    Process.spawn(
      { "PATH" => "#{@root}:#{ENV.fetch('PATH')}", "AGENT_CODING_TOOL_DATA_DIR" => @data },
      RbConfig.ruby, File.join(Dir.pwd, "bin", "agent-coding-tool"), "launch", id, "--codex",
      chdir: Dir.pwd, out: File.join(@root, "first-out"), err: File.join(@root, "first-err")
    )
  end

  def stop_cli_worker(host, child)
    Process.kill("TERM", -child) rescue Errno::ESRCH if child
    return unless host

    Timeout.timeout(5) { Process.waitpid(host) }
  rescue Timeout::Error
    Process.kill("TERM", host) rescue Errno::ESRCH
    Process.waitpid(host) rescue Errno::ECHILD
  rescue Errno::ECHILD
    nil
  end

  def test_explicit_parallel_launch_owns_distinct_roots_and_preserves_stale_checkpoint
    fixture(git: true, process: true, mutable_remote: true) do
      write_task(@data, id: "B", repositories: { "alias" => { "access" => "write", "path" => @ordinary } })
      @coordinator.prepare("T")
      @coordinator.prepare("B")
      write_fake("sleep")
      first_host = spawn_cli_worker("T")
      first_pid = nil
      begin
        running = wait_for_running("T")
        first_pid = running.fetch("child_pid")
        write_fake("success")
        assert_equal 0, Timeout.timeout(20) {
          launcher(real_sandbox_probe: true).launch("B", allow_write_collision: true)
        }

        second = handoff("B")
        assert_equal "running", handoff("T").fetch("status")
        assert_equal %w[IN_FLIGHT IN_FLIGHT], %w[B T].map { |id| @coordinator.status(id).fetch("status") }
        refute_equal running.fetch("workspace"), second.fetch("workspace")
        assert_equal @base, git("rev-parse", "HEAD", chdir: second.fetch("workspace"))
        assert_equal "act/T/attempt-1", git("branch", "--show-current", chdir: running.fetch("workspace"))
        assert_equal "act/B/attempt-1", git("branch", "--show-current", chdir: second.fetch("workspace"))
        assert_equal "", git("status", "--porcelain", chdir: @ordinary)
        refute_includes second.fetch("argv"), running.fetch("workspace")
        assert_includes File.binread(second.fetch("stdin_path")), running.fetch("workspace")
        authorization = second.fetch("collision_authorization")
        assert_equal "B", authorization.fetch("task_id")
        assert_equal 1, authorization.fetch("attempt")
        assert_equal ["T"], authorization.fetch("verified_conflicts").map { |row| row.fetch("task_id") }
        assert_equal running.fetch("invocation_id"), authorization.fetch("verified_conflicts").first.fetch("invocation_id")
        assert_equal authorization, @store.load("B").fetch("write_collision_override").fetch("launch")

        checkpoint = AgentCodingTool::Checkpoint.new(data_root: @data)
        preserved = checkpoint.record("B", workspace: second.fetch("workspace"))
        assert_equal second.fetch("invocation_id"), preserved.fetch("launch_invocation")

        Process.kill("TERM", -first_pid)
        Timeout.timeout(5) { Process.waitpid2(first_host) }
        first_host = nil
        first_pid = nil
        assert File.file?(File.join(running.fetch("workspace"), "worker-change.txt"))
        assert_equal "exited", handoff("B").fetch("status")
        assert_equal "verified", checkpoint.verify("B", workspace: second.fetch("workspace")).fetch("status")

        File.write(File.join(@ordinary, "file.txt"), "integrated later\n")
        git("commit", "-am", "advance main", chdir: @ordinary)
        git("push", "origin", "main", chdir: @ordinary)
        assert_equal "STALE", @coordinator.status("B").fetch("status")
        assert_equal "verified", checkpoint.verify("B").fetch("status")
        assert_equal @base, handoff("B").fetch("preparation").fetch("alias").fetch("pushed_sha")
      ensure
        stop_cli_worker(first_host, first_pid)
      end
    end
  end

  def test_foreign_sibling_worktree_record_blocks_without_disturbing_first_worker
    fixture(git: true, process: true) do
      write_task(@data, id: "B", repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      @coordinator.prepare("T")
      @coordinator.prepare("B")
      write_fake("sleep")
      host = spawn_cli_worker("T")
      child = nil
      begin
        child = wait_for_running("T").fetch("child_pid")
        record_path = handoff("T").fetch("worktrees_path")
        record = JSON.parse(File.binread(record_path))
        record.fetch("entries").first["path"] = @ordinary
        File.binwrite(record_path, JSON.generate(record))
        error = assert_raises(AgentCodingTool::InvalidState) {
          launcher.launch("B", allow_write_collision: true)
        }
        assert_match(/partial or conflicting ownership/, error.message)
        assert_equal "running", handoff("T").fetch("status")
        refute @store.load("B")["started_at"]
      ensure
        stop_cli_worker(host, child)
      end
    end
  end

  def test_advanced_main_makes_parallel_prepared_baselines_incompatible
    fixture(git: true, process: true, mutable_remote: true) do
      write_task(@data, id: "B", repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      @coordinator.prepare("T")
      write_fake("sleep")
      host = spawn_cli_worker("T")
      child = nil
      begin
        child = wait_for_running("T").fetch("child_pid")
        File.write(File.join(@ordinary, "file.txt"), "new main\n")
        git("commit", "-am", "advance main", chdir: @ordinary)
        git("push", "origin", "main", chdir: @ordinary)
        @coordinator.prepare("B")
        error = assert_raises(AgentCodingTool::InvalidState) {
          launcher.launch("B", allow_write_collision: true)
        }
        assert_match(/incompatible prepared baseline/, error.message)
        assert_equal "STALE", @coordinator.status("T").fetch("status")
        refute @store.load("B")["started_at"]
      ensure
        stop_cli_worker(host, child)
      end
    end
  end

  # A manual reservation permits isolated development, never verified siblings.
  def test_manual_in_flight_worker_remains_unverified_with_launch_flag
    fixture(git: true, process: true) do
      write_task(@data, id: "IG-18C", repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      write_task(@data, id: "AFTEST-01", repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      @coordinator.prepare("IG-18C")
      @coordinator.start("IG-18C", allow_write_collision: true)
      @coordinator.prepare("AFTEST-01")
      assert_equal 0, launcher(real_sandbox_probe: true).launch("AFTEST-01", allow_write_collision: true)
      assert_empty handoff("AFTEST-01").fetch("collision_authorization").fetch("verified_conflicts")
      assert_equal ["IG-18C"], handoff("AFTEST-01").fetch("collision_authorization").fetch("unverified_manual_conflicts").map { |row| row.fetch("task_id") }
      assert @store.load("AFTEST-01")["started_at"]
      assert @store.load("IG-18C")["started_at"]
    end
  end

  def test_manual_start_waits_for_launch_reservation_boundary
    fixture(git: true) do
      @coordinator.prepare("T")
      root = "#{@data}-runs"
      FileUtils.mkdir_p(root, mode: 0o700)
      out, err = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: @data, out: out, err: err)
      File.open(File.join(root, "launch.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        assert_equal 2, cli.run(%w[start T])
        assert_match(/reservation: launch\/recovery reservation busy/, err.string)
        refute @store.load("T")["started_at"]
      end
      assert_equal 0, cli.run(%w[start T])
      assert @store.load("T")["started_at"]
    end
  end
end
