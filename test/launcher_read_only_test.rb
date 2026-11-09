# frozen_string_literal: true

require_relative "test_helper"
require_relative "launcher_support"

# Real ACT orchestration with modeled Git and Codex external boundaries. Native
# Git/public CLI and physical sandbox acceptance remain separate manual gates.
class LauncherReadOnlyTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Reads this fixture's exact latest durable handoff; missing evidence raises.
  def report
    Dir.glob("#{@data}-runs/T/*/handoff.json").map { |path| JSON.parse(File.binread(path)) }.max_by { |record| record.fetch("attempt") }
  end

  # Registers an exempt inspection task using existing fixture repositories.
  # Returns the task; invalid registrations fail through the production loader.
  def read_only_task
    path = File.join(@data, "tasks", "T.yml")
    task = YAML.safe_load_file(path)
    task.fetch("repositories").each_value { |spec| spec["access"] = "read_only" }
    task["checkpoint"] = { "mode" => "exempt", "category" => "inspection", "reason" => "Report only." }
    File.write(path, YAML.dump(task))
    task
  end

  # Exercises normal preparation, detached worktree creation, a real foreground
  # process and lossless report inspection, retaining the public evidence contract.
  def test_report_journey_has_no_writer_authority
    fixture(git: true, process: true) do
      read_only_task
      write_fake("read-only-success")
      assert_equal 0, launcher(real_sandbox_probe: true).launch("T", reasoning: "high"), @err.string
      record = report
      assert_equal [], record.fetch("writable_repositories")
      assert_equal({}, record.fetch("writable_authorities"))
      assert_nil record.fetch("writable_repository")
      assert_nil record.fetch("writable_authority")
      assert_equal({}, record.fetch("workspaces"))
      scratch = record.fetch("fixture").fetch("path")
      assert_equal scratch, record.fetch("workspace")
      assert_equal scratch, record.fetch("scratch_path")
      assert_equal "Pinned inspection: base\n\n", File.binread(File.join(scratch, "report.txt"))
      assert record.fetch("worktrees").fetch("entries").all? { |entry| entry["branch"].nil? }
      assert_includes record.fetch("argv"), "--skip-git-repo-check"
      assert_includes record.fetch("argv"), "sandbox_workspace_write.writable_roots=#{JSON.generate([scratch])}"
      input = File.binread(record.fetch("stdin_path"))
      assert_includes input, "Return the report and evidence locations"
      refute_includes input, "Return a local patch"
      refute_includes input, "After focused checks, export"
      identity = record.slice(*AgentCodingTool::RunEvidenceReader::IDENTITIES)
      config = AgentCodingTool::RunEvidenceStore.new(@data).select(identity, artifacts: ["final", "candidate"], manager: "operator")
      assert_nil config.fetch("binding").fetch("repository")
      assert_equal record.fetch("preparation"), config.fetch("binding").fetch("read_only_inputs")
      reader = AgentCodingTool::RunEvidenceReader.new(**config.transform_keys(&:to_sym))
      manifest = reader.call(identity.merge("operation" => "manifest", "revision" => nil), caller: "operator")
      assert_equal "exited", manifest.fetch("launch_status")
      assert_equal 0, manifest.fetch("worker_exit_status")
      assert_equal "missing", config.fetch("approvals").fetch("candidate").fetch("status")
      result = reader.call(identity.merge("operation" => "read", "revision" => manifest.fetch("revision"), "artifact" => "final", "offset" => 0, "length" => 1024), caller: "operator")
      assert_equal File.binread(File.join(scratch, "report.txt")), result.fetch("data").unpack1("m0")
      assert_equal "IN_FLIGHT", @coordinator.status("T").fetch("status")
      refute @store.load("T")["result"]
    end
  end

  # The same public journey detects missing pinned-input and final-evidence
  # handoffs, rather than passing based only on a fake worker start marker.
  def test_broken_handoffs_do_not_establish_a_report_journey
    %w[read-only-missing-input read-only-missing-report].each do |mode|
      fixture(git: true, process: true) do
        read_only_task
        write_fake(mode)
        status = launcher(real_sandbox_probe: true).launch("T")
        record = report
        if mode == "read-only-missing-input"
          assert_equal 1, status
          assert_equal 1, record.fetch("exit_status")
          refute File.exist?(File.join(record.fetch("workspace"), "report.txt"))
        else
          assert_equal 0, status
          assert_equal "invalid_final", record.fetch("status")
          refute record.fetch("final_valid")
        end
        assert @store.load("T")["started_at"]
        refute @store.load("T")["result"]
      end
    end
  end

  # Preserves checkpoint policy and nonempty repository validation, and refuses
  # installed CLIs without explicit support for execution outside a repository.
  def test_required_checkpoints_and_missing_capability_refuse_before_worker
    fixture(git: true) do
      task = read_only_task
      task.delete("checkpoint")
      File.write(File.join(@data, "tasks", "T.yml"), YAML.dump(task))
      error = assert_raises(AgentCodingTool::InvalidTask) { launcher.launch("T") }
      assert_match(/read-only launch requires an existing valid checkpoint exemption/, error.message)
      refute @store.load("T")["started_at"]
      refute File.exist?(File.join(@root, "argv"))
      task["repositories"] = {}
      File.write(File.join(@data, "tasks", "T.yml"), YAML.dump(task))
      assert_raises(AgentCodingTool::InvalidTask) { launcher.launch("T") }
    end
    fixture(git: true) do
      read_only_task
      @fake_help = @fake_help.delete_suffix(" --skip-git-repo-check")
      error = assert_raises(AgentCodingTool::Error) { launcher.launch("T") }
      assert_match(/lacks --skip-git-repo-check/, error.message)
      refute @store.load("T")["started_at"]
      refute File.exist?(File.join(@root, "argv"))
    end
  end

  # Models physical probe failures only to prove orchestration fails closed.
  # No modeled response is evidence that the host enforces these permissions.
  def test_failed_probe_and_replaced_scratch_never_start_worker
    %w[leaky fixture_denied fixture_parent_leaky].each do |mode|
      fixture(git: true) do
        read_only_task
        write_fake(mode)
        error = assert_raises(AgentCodingTool::InvalidState) { launcher(real_sandbox_probe: true).launch("T") }
        assert_match(/sandbox boundary unverified/, error.message)
        refute @store.load("T")["started_at"]
        refute File.exist?(File.join(@root, "argv"))
      end
    end
    fixture(git: true) do
      read_only_task
      worker = launcher
      worker.define_singleton_method(:sandbox_probe!) do |_inventory, _workspace, _run_dir|
        path = @report.fetch("fixture").fetch("path")
        File.rename(path, "#{path}-preserved")
        Dir.mkdir(path, 0o700)
      end
      error = assert_raises(AgentCodingTool::InvalidState) { worker.launch("T") }
      assert_match(/fixture directory identity changed/, error.message)
      refute @store.load("T")["started_at"]
      refute File.exist?(File.join(@root, "argv"))
    end
    fixture(git: true) do
      read_only_task
      File.symlink(@ordinary, "#{@data}-fixtures")
      assert_raises(AgentCodingTool::InvalidState) { launcher.launch("T") }
      assert File.symlink?("#{@data}-fixtures")
      refute @store.load("T")["started_at"]
      refute File.exist?(File.join(@root, "argv"))
    end
  end

  # A private delivery contract never changes read-only launch semantics. Explicit
  # delivery refuses before writing locks, candidates or publication evidence.
  def test_read_only_run_never_delivers_even_with_a_contract
    fixture(git: true, process: true) do
      read_only_task
      write_fake("read-only-success")
      FileUtils.mkdir_p("#{@data}-validation")
      File.write(File.join("#{@data}-validation", "T.yml"), "malformed contract deliberately not consumed")
      assert_equal 0, launcher(real_sandbox_probe: true).launch("T")
      run = File.dirname(Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0))
      before = Dir.glob(File.join(run, "**", "*")).to_h { |path| [path, File.file?(path) ? File.binread(path) : nil] }
      error = assert_raises(AgentCodingTool::InvalidState) do
        AgentCodingTool::DeliveryManager.new(data_root: @data, coordinator: @coordinator).deliver("T", run_dir: run)
      end
      assert_match(/read-only runs produce reports/, error.message)
      after = Dir.glob(File.join(run, "**", "*")).to_h { |path| [path, File.file?(path) ? File.binread(path) : nil] }
      assert_equal before, after
      refute @store.load("T")["result"]
    end
  end

  # Exercises recovery/cleanup decisions with an explicitly clear host-liveness
  # boundary. Actual process exit is asserted; native host closeout is a separate
  # gate because restricted workers cannot observe the host's boot identity.
  def test_failure_retry_and_ownership_checked_cleanup_retain_reports
    fixture(git: true, process: true) do
      read_only_task
      write_fake("read-only-failure")
      assert_equal 7, launcher(real_sandbox_probe: true).launch("T")
      first = report
      retained = File.join(first.fetch("scratch_path"), "report.txt")
      bytes = File.binread(retained)
      assert_raises(Errno::ESRCH) { Process.kill(0, first.fetch("child_pid")) }
      assert_raises(AgentCodingTool::InvalidState) { launcher.launch("T") }
      @coordinator.record("T", outcome: "failed", summary: "Synthetic failure")
      liveness = Object.new
      liveness.define_singleton_method(:check) { |_report, _inventory| :clear }
      AgentCodingTool::RetryLiveness.stub(:new, liveness) do
        recovery = AgentCodingTool::AttemptRecovery.new(data_root: @data)
        assert_raises(AgentCodingTool::InvalidState) { @coordinator.prepare("T", retry_result: true) }
        recovery.close("T")
        @coordinator.prepare("T", retry_result: true)
        write_fake("read-only-success")
        assert_equal 0, launcher(real_sandbox_probe: true).launch("T")
        second = report
        assert_equal 2, second.fetch("attempt")
        refute_equal first.fetch("scratch_path"), second.fetch("scratch_path")
        assert_equal bytes, File.binread(retained)
        @coordinator.record("T", outcome: "complete", summary: "Synthetic report reviewed")
        cleanup = AgentCodingTool::CleanupManager.new(data_root: @data, liveness: liveness)
        refute cleanup.preflight("T").fetch("blocked")
        cleanup.remove("T")
        assert_equal bytes, File.binread(retained)
        assert File.file?(File.join(second.fetch("scratch_path"), "report.txt"))
        assert Dir.glob("#{@data}-runs/T/*/worktrees.json").all? { |path|
          JSON.parse(File.binread(path)).fetch("entries").all? { |entry| entry["state"] == "removed" } }
      end
    end
  end

  # Retains an interrupted foreground report and permits ownership-checked
  # cleanup only after explicit exempt-task completion and clear process use.
  def test_interrupted_read_only_attempt_can_be_reviewed_and_cleaned
    fixture(git: true, process: true) do
      read_only_task
      write_fake("read-only-interrupt")
      sender = Thread.new do
        Timeout.timeout(5) { sleep 0.01 until File.file?(File.join(@root, "worker-ready")) }
        Process.kill("INT", Process.pid)
      end
      begin
        assert_equal 130, launcher(real_sandbox_probe: true).launch("T")
        sender.value
      ensure
        sender.kill if sender.alive?
        sender.join
      end
      record = report
      assert_equal "interrupted", record.fetch("status")
      assert_raises(Errno::ESRCH) { Process.kill(0, record.fetch("child_pid")) }
      assert_equal :clear, AgentCodingTool::CleanupLiveness.new.check(record, record.fetch("worktrees"))
      refute AgentCodingTool::CleanupLiveness.new.check(record.merge("writable_repositories" => ["repo"]), record.fetch("worktrees")) == :clear
      cleanup = AgentCodingTool::CleanupManager.new(data_root: @data)
      assert cleanup.preflight("T").fetch("blocked")
      @coordinator.record("T", outcome: "complete", summary: "Synthetic partial report reviewed")
      refute cleanup.preflight("T").fetch("blocked")
      retained = File.join(record.fetch("scratch_path"), "report.txt")
      bytes = File.binread(retained)
      cleanup.remove("T")
      assert_equal bytes, File.binread(retained)
    end
  end
end
