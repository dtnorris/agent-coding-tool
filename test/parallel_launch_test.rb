# frozen_string_literal: true

require_relative "test_helper"
require_relative "launcher_support"
require_relative "support/checkpoint_processes"
require "stringio"
require "timeout"

# Exercises simultaneous guarded launchers against shared modeled Git authority.
class ParallelLaunchTest < Minitest::Test
  include TestHelpers
  include LauncherSupport
  include CheckpointProcesses

  # Runs the public parser and workflow with captured output; returns CLI status
  # and streams. Only finite Git/provider/process boundaries are modeled.
  def public_cli(*arguments)
    output, error = StringIO.new, StringIO.new
    code = AgentCodingTool::CLI.run(arguments, root: File.expand_path('..', __dir__),
      data_root: @data, out: output, err: error)
    [code, output.string, error.string]
  end

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

  # Starts the public launch against shared authority; caller reaps the real host.
  def spawn_cli_worker(id)
    start_cold_launcher("launch", id, "--codex", stdout: File.join(@root, "first-out"),
      stderr: File.join(@root, "first-err"))
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

  # Cold public prepare/launch must admit a verified active sibling by default.
  # Cold guarded CLIs share main's modeled Git authority and retain real workers.
  def test_default_parallel_launch_owns_distinct_roots_and_preserves_stale_checkpoint
    fixture(git: true, process: true, mutable_remote: true) do
      write_task(@data, id: "B", repositories: { "alias" => { "access" => "write", "path" => @ordinary } })
      %w[T B].each do |id|
        _output, error, status = cold_launcher("prepare", id)
        assert status.success?, error
      end
      write_fake("sleep")
      first_host = spawn_cli_worker("T")
      first_pid = nil
      begin
        running = wait_for_running("T")
        first_pid = running.fetch("child_pid")
        # The ps adapter consumes the child's own observations, independently
        # of the handoff whose parent/group production will compare on macOS.
        query = ['ps', '-o', 'ppid=', '-o', 'pgid=', '-p', first_pid.to_s]
        output, error, status = Open3.capture3(*query)
        assert status.success?, error
        assert_equal [first_host, first_pid], output.split.map(&:to_i)
        assert_raises(GitContract::UnexpectedObservation) { Open3.capture3(*query, chdir: @root) }
        assert_raises(GitContract::UnexpectedObservation) { Open3.capture3(*query[0...-1], Process.pid.to_s) }
        # A live but wrong host must not be replaced with expected report data.
        if RbConfig::CONFIG.fetch('host_os').match?(/darwin/)
          error = assert_raises(AgentCodingTool::InvalidState) {
            launcher.send(:verify_running_process!, running.merge('host_pid' => Process.pid))
          }
          assert_match(/worker process parent\/group changed/, error.message)
        end
        write_fake("success")
        _output, error, status = Timeout.timeout(20) {
          cold_launcher("launch", "B", "--codex")
        }
        assert status.success?, error
        assert_includes error, "verified ACT-managed overlap at launch (default_verified_managed)"

        second = handoff("B")
        assert_equal "running", handoff("T").fetch("status")
        assert_equal %w[IN_FLIGHT IN_FLIGHT], %w[B T].map { |id| @coordinator.status(id).fetch("status") }
        refute_equal running.fetch("workspace"), second.fetch("workspace")
        assert_equal @base, git("rev-parse", "HEAD", chdir: second.fetch("workspace"))
        assert_equal "act/T/attempt-1", git("symbolic-ref", "--short", "HEAD", chdir: running.fetch("workspace"))
        assert_equal "act/B/attempt-1", git("symbolic-ref", "--short", "HEAD", chdir: second.fetch("workspace"))
        assert_equal "", git("status", "--porcelain=v1", "--untracked-files=all", chdir: @ordinary)
        refute_includes second.fetch("argv"), running.fetch("workspace")
        assert_includes File.binread(second.fetch("stdin_path")), running.fetch("workspace")
        authorization = second.fetch("collision_authorization")
        assert_equal "default_verified_managed", authorization.fetch("admission_basis")
        refute authorization.key?("unverified_manual_conflicts")
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
        git("add", "-A", chdir: @ordinary)
      git("commit", "-m", "advance main", chdir: @ordinary)
        git("push", "origin", "HEAD:refs/heads/main", chdir: @ordinary)
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
        [false, true].each do |explicit|
          error = assert_raises(AgentCodingTool::InvalidState) {
            launcher.launch("B", allow_write_collision: explicit)
          }
          assert_match(/partial or conflicting ownership/, error.message)
        end
        assert_equal "running", handoff("T").fetch("status")
        refute @store.load("B")["started_at"]
      ensure
        stop_cli_worker(host, child)
      end
    end
  end

  # Fresh public launches keep older running, exited and candidate reservations
  # intact. Real workers, locks, sandbox decisions and checkpoint gates remain;
  # the synchronous CLI shares modeled Git without requiring a socket broker.
  def test_cross_baseline_launch_preserves_managed_reservations
    fixture(git: true, process: true, mutable_remote: true) do
      %w[E C B D].each do |id|
        write_task(@data, id: id, repositories: { "alias" => { "access" => "write", "path" => @ordinary } })
      end
      constructor = AgentCodingTool::Launcher.method(:new)
      factory = ->(**options) { constructor.call(**options, codex: @fake, spawner: method(:spawn_fake_worker)) }
      AgentCodingTool::Launcher.stub(:new, factory) do
        %w[E C T].each { |id| assert_equal 0, public_cli("prepare", id).first }
        %w[E C].each do |id|
          code, _output, error = public_cli("launch", id, "--codex")
          assert_equal 0, code, error
        end
        checkpoint = AgentCodingTool::Checkpoint.new(data_root: @data)
        %w[E C].each { |id| checkpoint.record(id, workspace: handoff(id).fetch("workspace")) }
        @coordinator.record("C", outcome: "candidate_complete", artifact: "fixture candidate")
        write_fake("sleep")
        host = Thread.new { public_cli("launch", "T", "--codex") }
        begin
          running = wait_for_running("T")
          Timeout.timeout(5) do
            sleep 0.01 until File.file?(File.join(@root, "worker-ready")) &&
              File.binread(File.join(@root, "worker-ready")).to_i == running.fetch("child_pid")
          end
          refute File.exist?(running.fetch("final_path")), "running workers need no final artifact"
          File.write(File.join(@ordinary, "file.txt"), "new main\n")
          setup_git("add", "-A", chdir: @ordinary)
          setup_git("commit", "-m", "advance main", chdir: @ordinary)
          setup_git("push", "origin", "HEAD:refs/heads/main", chdir: @ordinary)
          fresh = setup_git("rev-parse", "HEAD", chdir: @ordinary)
          assert_equal %w[STALE STALE STALE_CANDIDATE], %w[T E C].map { |id| @coordinator.status(id).fetch("status") }
          assert_equal 0, public_cli("prepare", "B").first

          # Admission must retain fail-closed ownership/sandbox/liveness checks
          # even though every old reservation is absent from the fresh projection.
          report_path = Dir.glob("#{@data}-runs/E/*/handoff.json").fetch(0)
          original = File.binread(report_path)
          before_spawn = Dir.glob(File.join(@root, "worker-process-*")).sort
          mutations = [
            [/worktree ownership differs/, ->(row) { row["attempt"] = 99 }],
            [/invocation differs from its owned attempt/, ->(row) { row["invocation_id"] = "foreign" }],
            [/sandbox verification is unavailable/, ->(row) { row.delete("sandbox_probe") }],
            [/launch roots or pinned heads are unverified/, ->(row) { row["workspace"] = running.fetch("workspace") }],
            [/terminal worker liveness is uncertain/, ->(row) { row.delete("ended_at") }],
            [/judgment_required execution evidence/, ->(row) { row["status"] = "judgment_required" }]
          ]
          mutations.each do |message, mutate|
            altered = JSON.parse(original)
            mutate.call(altered)
            File.binwrite(report_path, JSON.generate(altered))
            code, _output, error = public_cli("launch", "B", "--codex", "--allow-write-collision")
            assert_equal 2, code
            assert_match message, error
            refute @store.load("B")["started_at"]
            assert_equal before_spawn, Dir.glob(File.join(@root, "worker-process-*")).sort
          ensure
            File.binwrite(report_path, original)
          end

          final_path = handoff("E").fetch("final_path")
          final_bytes = File.binread(final_path)
          begin
            File.binwrite(final_path, "altered terminal output")
            code, _output, error = public_cli("launch", "B", "--codex", "--allow-write-collision")
            assert_equal 2, code
            assert_match(/missing\/altered worker artifact/, error)
            assert_equal before_spawn, Dir.glob(File.join(@root, "worker-process-*")).sort
          ensure
            File.binwrite(final_path, final_bytes)
          end

          # A different live HEAD needs verified candidate evidence, even when
          # the older preparation and worktree registration remain authentic.
          sibling_ref = "refs/heads/act/E/attempt-1"
          begin
            @memory_checkout.repository.refs[sibling_ref] = fresh
            code, _output, error = public_cli("launch", "B", "--codex", "--allow-write-collision")
            assert_equal 2, code
            assert_match(/delivery: missing\/private contract directory/, error)
            assert_equal before_spawn, Dir.glob(File.join(@root, "worker-process-*")).sort
          ensure
            @memory_checkout.repository.refs[sibling_ref] = @base
          end

          preserved_paths = %w[T E C].flat_map do |id|
            state = @store.load(id)
            report = handoff(id)
            [@store.state_path(id), state.fetch("prompt_path"), report.fetch("worktrees_path"),
             File.join(report.fetch("workspace"), "worker-change.txt")]
          end + %w[E C].flat_map { |id|
            Dir.glob("#{@data}-runs/#{id}/**/*").select { |path| File.file?(path) }
          } + Dir.glob("#{@data}-runs/checkpoints/**/*").select { |path| File.file?(path) }
          preserved = preserved_paths.to_h { |path| [path, File.binread(path)] }
          write_fake("success")
          [["B", ["--allow-write-collision"], "explicit_permission"],
           ["D", [], "default_verified_managed"]].each do |id, flags, basis|
            assert_equal 0, public_cli("prepare", id).first if id == "D"
            before = Dir.glob(File.join(@root, "worker-process-*")).length
            code, _output, error = public_cli("launch", id, "--codex", "--reasoning", "high", *flags)
            assert_equal 0, code, error
            assert_equal before + 1, Dir.glob(File.join(@root, "worker-process-*")).length
            admitted = handoff(id)
            assert_equal basis, admitted.dig("collision_authorization", "admission_basis")
            conflicts = admitted.dig("collision_authorization", "conflicts").to_h { |row| row.values_at("task_id", "status") }
            assert_equal({ "T" => "STALE", "E" => "STALE", "C" => "STALE_CANDIDATE" }, conflicts.slice("T", "E", "C"))
            assert_equal fresh, setup_git("rev-parse", "HEAD", chdir: admitted.fetch("workspace"))
            siblings = admitted.dig("collision_authorization", "verified_conflicts")
            %w[T E C].each do |sibling|
              row = siblings.find { |entry| entry.fetch("task_id") == sibling }
              assert_equal @base, row.fetch("authorities").values.first.fetch("pushed_sha")
              assert_equal handoff(sibling).fetch("invocation_id"), row.fetch("invocation_id")
              assert_equal @base, setup_git("rev-parse", "HEAD", chdir: handoff(sibling).fetch("workspace"))
            end
            assert_equal preserved, preserved_paths.to_h { |path| [path, File.binread(path)] }
            error = assert_raises(AgentCodingTool::InvalidState) {
              factory.call(coordinator: @coordinator, data_root: @data, source_root: Dir.pwd)
                .verify_delivery_overlap!(id, File.dirname(Dir.glob("#{@data}-runs/#{id}/*/handoff.json").fetch(0)))
            }
            assert_match(/incompatible prepared baseline/, error.message)
          end
          roots = %w[T E C B D].map { |id| handoff(id).fetch("workspace") }
          assert_equal 5, roots.uniq.length
          assert roots.all? { |path| roots.none? { |other| path != other && path.start_with?(other + "/") } }
          assert @store.load("T")["started_at"]
          assert @store.load("E")["started_at"]
          assert_equal "candidate_complete", @store.load("C").dig("result", "outcome")
          assert_equal "running", handoff("T").fetch("status")
          # Ordinary checkpoint operations remain eligible for the exited
          # IN_FLIGHT sibling without a forced lifecycle exception.
          workspace = handoff("E").fetch("workspace")
          checkpoint.record("E", workspace: workspace)
          assert_equal "verified", checkpoint.verify("E", workspace: workspace).fetch("status")
          assert_equal 0, checkpoint.gate("E", workspace: workspace, command: gate_command("exit", "0"))
          assert_equal "STALE", @coordinator.status("E").fetch("status")
        ensure
          File.write(File.join(@root, "worker-release"), "release")
          assert_equal 0, Timeout.timeout(5) { host.value }.first
        end
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
        assert_match(/reservation lock: launch\/recovery reservation busy/, err.string)
        refute @store.load("T")["started_at"]
      end
      assert_equal 0, cli.run(%w[start T])
      assert @store.load("T")["started_at"]
    end
  end
end
