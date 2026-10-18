# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../launcher_support"
require "timeout"

# Public CLI journeys use native disposable Git and finite fake Codex processes.
# The fake sandbox models the external CLI boundary; native acceptance is separate.
class ManualParallelLaunchTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Runs the actual public CLI in a fresh process; returns captured bytes/status.
  # Timeout is a test failure, never permission to proceed with an unknown worker.
  def cli(*args)
    Timeout.timeout(20) do
      Open3.capture3({ "PATH" => "#{@root}:#{ENV.fetch('PATH')}", "AGENT_CODING_TOOL_DATA_DIR" => @data },
                     RbConfig.ruby, File.join(Dir.pwd, "bin/agent-coding-tool"), *args)
    end
  end

  # Asserts one public command succeeds and returns stdout; failure includes stderr.
  def cli!(*args)
    output, error, status = cli(*args)
    assert status.success?, "#{args.inspect}: #{error}"
    output
  end

  # Starts A manually, preserving staged/unstaged, binary, untracked and ignored
  # work in its legitimate external worktree. Optional main movement ages only A.
  # Only source movement needs an earlier T preparation to refresh. Native Git
  # errors fail setup; no managed A execution evidence is manufactured.
  def manual_pair(advance: false, checkpoint: false)
    write_task(@data, id: "A", repositories: { "alias" => { "access" => "write", "path" => @ordinary } })
    cli!("prepare", "A")
    cli!("prepare", "T") if advance
    cli!("start", "A")
    @external = File.join(@root, "external-A")
    setup_git("worktree", "add", "-b", "external-A", @external, @base, chdir: @ordinary)
    if checkpoint
      File.write(File.join(@external, "file.txt"), "earlier checkpoint candidate\n")
      cli!("checkpoint", "record", "A", "--workspace", @external)
    end
    File.binwrite(File.join(@external, "file.txt"), "staged\n")
    setup_git("add", "file.txt", chdir: @external)
    File.binwrite(File.join(@external, "file.txt"), "unfinished\n")
    File.binwrite(File.join(@external, "candidate.bin"), "\x00\xffkeep".b)
    File.write(File.join(@external, ".gitignore"), "ignored\n")
    File.binwrite(File.join(@external, "ignored"), "ignored candidate\n")
    if advance
      File.write(File.join(@ordinary, "file.txt"), "new main\n")
      setup_git("commit", "-am", "advance main", chdir: @ordinary)
      setup_git("push", "origin", "main", chdir: @ordinary)
    end
    cli!("prepare", "T")
    @target_base = @store.load("T").fetch("snapshot").fetch("repo").fetch("pushed_sha")
  end

  # Captures exact older candidate, native index/HEAD, task/prompt and artifacts.
  # This deliberately excludes shared Git registry additions for the new worker.
  def older_bytes
    paths = Dir.glob(File.join(@external, "**/*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
    admin = setup_git("rev-parse", "--absolute-git-dir", chdir: @external)
    paths += %w[index HEAD].map { |name| File.join(admin, name) }
    paths += Dir.glob(File.join(@data, "**/*")).select { |path| File.file?(path) && !path.include?("/T") }
    paths += Dir.glob("#{@data}-runs/A/**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) }
    paths += Dir.glob("#{@data}-runs/checkpoints/A/**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) }
    paths.sort.to_h { |path| [path, File.binread(path)] }
  end

  # Returns the one target attempt and its directory; ambiguity fails the test.
  def target_run
    path = Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)
    [JSON.parse(File.binread(path)), File.dirname(path)]
  end

  # Stopped/unknown and actively writing external workers need no attestation.
  # Only the declared fake sandbox is simulated; all lifecycle/Git handoffs run.
  def test_public_cli_manual_overlap_preserves_candidates_with_active_and_historical_variants
    [false, true].product([false, true]).each do |active, advance|
      fixture(git: true, process: true, mutable_remote: true) do
        manual_pair(advance: advance, checkpoint: true)
        preserved = older_bytes
        child = nil
        if active
          ready = File.join(@root, "external-ready")
          script = 'File.write(ARGV[1], "ready"); 200.times { File.write(ARGV[0], "external work"); sleep 0.025 }'
          child = Process.spawn(RbConfig.ruby, "-e", script, File.join(@external, "active.txt"), ready)
          Timeout.timeout(5) { sleep 0.01 until File.file?(ready) && File.file?(File.join(@external, "active.txt")) }
        end
        _output, error, status = cli("launch", "T", "--codex", "--allow-write-collision", "--reasoning", "high")
        assert status.success?, error
        assert_includes error, "external worker isolation and activity are unverified"
        report, run_dir = target_run
        assert_equal "exited", report.fetch("status")
        assert_equal @target_base, setup_git("rev-parse", "HEAD", chdir: report.fetch("workspace"))
        assert_equal "act/T/attempt-1", setup_git("branch", "--show-current", chdir: report.fetch("workspace"))
        refute_equal @external, report.fetch("workspace")
        assert_equal "worker", File.binread(File.join(report.fetch("workspace"), "worker-change.txt"))
        cli!("checkpoint", "record", "T", "--workspace", report.fetch("workspace"))
        cli!("checkpoint", "verify", "T", "--workspace", report.fetch("workspace"))
        assert_equal [], report.fetch("collision_authorization").fetch("verified_conflicts")
        assert_equal ["A"], report.fetch("collision_authorization").fetch("unverified_manual_conflicts").map { |row| row.fetch("task_id") }
        assert_equal "operator_authorized_manual_overlap", @store.load("T").dig("write_overlap", "basis")
        assert_equal preserved, preserved.to_h { |path, _| [path, File.binread(path)] }
        assert_equal "external-A", setup_git("branch", "--show-current", chdir: @external)
        assert @store.load("A")["started_at"]
        assert @store.load("T")["started_at"]
        assert_nil @store.load("T")["result"]
        assert_nil @store.load("A")["result"]
        assert_empty Dir.glob("#{@data}-runs/A/*")
        assert_empty Dir.glob("#{run_dir}/delivery*")
        cli_output = cli!("status", "T")
        assert_includes cli_output, "external isolation/liveness unverified"
        assert_includes cli_output, "managed delivery disabled"
        if child
          Process.kill(0, child) # Still active while B has already completed.
          assert_equal "external work", File.binread(File.join(@external, "active.txt"))
        end
      ensure
        Process.waitpid(child) if child # Finite, fixture-owned process only.
      end
    end
  end

  # Removing explicit permission breaks the same public journey before handoff.
  def test_public_cli_without_override_refuses_before_worker_handoff
    fixture(git: true, process: true) do
      manual_pair
      before = older_bytes
      _output, error, status = cli("launch", "T", "--codex")
      assert_equal 2, status.exitstatus
      assert_match(/write collision/, error)
      refute File.exist?(File.join(@root, "worker-pid"))
      refute @store.load("T")["started_at"]
      assert_equal before, older_bytes
    end
  end

  # A native external checkout cannot contain the new execution root. Unknown
  # external liveness is allowed; overlapping filesystems are still refused.
  def test_new_worktree_cannot_be_nested_inside_external_checkout
    fixture(git: true, process: true) do
      manual_pair
      config = YAML.safe_load_file(File.join(@data, "config.yml"))
      config["worktree_root"] = File.join(@external, "nested-workers")
      File.write(File.join(@data, "config.yml"), YAML.dump(config))
      _output, error, status = cli("launch", "T", "--codex", "--allow-write-collision")
      assert_equal 2, status.exitstatus, error
      assert_match(/overlaps.*checkout/, error)
      refute File.exist?(File.join(@root, "worker-pid"))
    end
  end

  # Reversible pre-creation refusals share one manual candidate. Staleness runs
  # last because it advances native refs; creation failures keep separate roots
  # and retained failed-attempt evidence. Every launch remains a cold public CLI.
  def test_refusal_matrix_preserves_manual_candidate
    groups = [
      %w[prompt dependency partial malformed missing contradictory managed_state stale],
      %w[occupied], %w[symlink], %w[branch]
    ]
    reasons = {
      "stale" => /launch blocked: STALE/, "prompt" => /generated prompt changed/,
      "dependency" => /BLOCKED dependencies incomplete: DEP/,
      "occupied" => /occupied attempt container/, "symlink" => /symlinked ancestor/,
      "branch" => /conflicting branch/, "partial" => /partial\/foreign run artifacts/,
      "malformed" => /partial evidence/, "missing" => /foreign or partial task\/attempt evidence/,
      "contradictory" => /no unique ACT-owned worker evidence/,
      "managed_state" => /no unique ACT-owned worker evidence/
    }
    groups.each do |scenarios|
      fixture(git: true, process: true, mutable_remote: true) do
        manual_pair
        paths = [File.join(@data, "tasks/T.yml"), @store.state_path("A"),
                 @store.state_path("T"), @store.load("T").fetch("prompt_path")]
        originals = paths.to_h { |path| [path, File.binread(path)] }
        preserved = older_bytes
        scenarios.each do |scenario|
          assert_equal originals, paths.to_h { |path| [path, File.binread(path)] }, scenario
          case scenario
          when "stale"
            File.write(File.join(@ordinary, "file.txt"), "moved\n")
            setup_git("commit", "-am", "move", chdir: @ordinary)
            setup_git("push", "origin", "main", chdir: @ordinary)
          when "prompt"
            File.write(@store.load("T").fetch("prompt_path"), "changed")
          when "dependency"
            write_task(@data, id: "DEP")
            write_task(@data, id: "T", depends_on: ["DEP"], repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
          when "occupied", "symlink"
            path = File.join(@root, "worktrees/T/attempt-1")
            FileUtils.mkdir_p(File.dirname(path))
            scenario == "symlink" ? File.symlink(@external, path) : FileUtils.mkdir_p(path)
          when "branch"
            setup_git("branch", "act/T/attempt-1", @base, chdir: @ordinary)
          when "partial", "malformed", "missing", "contradictory"
            directory = "#{@data}-runs/A/partial"
            FileUtils.mkdir_p(directory, mode: 0o700)
            unless scenario == "partial"
              state = @store.load("A")
              report = { "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "A",
                         "prepared_at" => state.fetch("prepared_at"), "preparation" => state.fetch("snapshot"), "status" => "running" }
              report["preparation"] = {} if scenario == "contradictory"
              File.write(File.join(directory, "handoff.json"), scenario == "malformed" ? "broken" : JSON.generate(report))
            end
          when "managed_state"
            state = @store.load("A")
            state["write_collision_override"] = { "launch" => { "invocation_id" => "missing managed run" } }
            @store.write("A", state)
          end
          before = older_bytes
          _output, error, status = cli("launch", "T", "--codex", "--allow-write-collision")
          assert_equal 2, status.exitstatus, "#{scenario}: #{error}"
          assert_match reasons.fetch(scenario), error, scenario
          refute File.exist?(File.join(@root, "worker-pid")), scenario
          refute @store.load("T")["started_at"], scenario
          assert_equal originals.fetch(@store.state_path("T")), File.binread(@store.state_path("T")), scenario
          assert_equal before, before.to_h { |path, _| [path, File.binread(path)] }, scenario
          assert_empty Dir.glob("#{@data}-runs/T/*"), scenario if scenarios.length > 1

          # Restore only this row's fixture-authored task/prompt/state bytes and
          # synthetic sibling evidence. No product recovery or Git reset is used.
          originals.each { |path, bytes| File.binwrite(path, bytes) }
          File.unlink(File.join(@data, "tasks/DEP.yml")) if scenario == "dependency"
          if %w[partial malformed missing contradictory].include?(scenario)
            FileUtils.remove_entry("#{@data}-runs/A")
          end
          assert_equal preserved, older_bytes, scenario
        end
      end
    end
  end

  # A simulated permission leak at each protected boundary is a hard blocker.
  # Targets are selected from the real production probe, not hardcoded outcomes.
  def test_each_forbidden_sandbox_write_refuses
    %w[ordinary reader common worker_admin evidence].each do |leak|
      fixture(git: true, process: true) do
        manual_pair
        reader = File.join(@root, "reader")
        FileUtils.cp_r(@ordinary, reader)
        reader_remote = File.join(@root, "reader.git")
        setup_git("clone", "--bare", reader, reader_remote)
        setup_git("remote", "set-url", "origin", reader_remote, chdir: reader)
        write_task(@data, id: "T", repositories: {
          "repo" => { "access" => "write", "path" => @ordinary },
          "reader" => { "access" => "read_only", "path" => reader }
        })
        @coordinator.prepare("T")
        before = older_bytes
        original = Open3.method(:capture3)
        capture = lambda do |*args, **options|
          output, error, status = original.call(*args, **options)
          if args.include?("act-probe")
            targets = args.drop(args.index("act-probe") + 1)
            selected = targets.index do |path|
              case leak
              when "ordinary" then File.dirname(path) == @ordinary
              when "reader" then path.include?("/attempt-1/reader/")
              when "common" then File.dirname(path) == File.join(@ordinary, ".git")
              when "worker_admin" then path.include?("/.git/worktrees/")
              when "evidence" then path.include?("/data-runs/")
              end
            end
            raise "missing probe target #{leak}" unless selected
            File.binwrite(targets.fetch(selected), "breach")
            lines = output.lines; lines[selected] = "1\n"; output = lines.join
          end
          [output, error, status]
        end
        error = Open3.stub(:capture3, capture) do
          assert_raises(AgentCodingTool::InvalidState) { launcher(real_sandbox_probe: true).launch("T", allow_write_collision: true) }
        end
        assert_match(/sandbox boundary unverified/, error.message)
        refute @store.load("T")["started_at"]
        assert_equal before, before.to_h { |path, _| [path, File.binread(path)] }
      end
    end
  end

  # Changes after worktree creation/probe cannot authorize a different identity,
  # saved prompt, authority or manual reservation at the final handoff gate.
  def test_preflight_races_refuse_before_reservation
    %w[identity prompt authority manual_state].each do |scenario|
      fixture(git: true, process: true) do
        manual_pair
        instance = launcher(real_sandbox_probe: true)
        probe = instance.method(:sandbox_probe!)
        states, ordinary, data = @store, @ordinary, @data
        instance.define_singleton_method(:sandbox_probe!) do |*args|
          probe.call(*args)
          case scenario
          when "identity"
            path = File.join(data, "tasks/T.yml")
            task = YAML.safe_load_file(path); task["title"] = "changed"; File.write(path, YAML.dump(task))
          when "prompt" then File.write(states.load("T").fetch("prompt_path"), "changed during probe")
          when "authority" then Open3.capture3("git", "remote", "set-url", "origin", File.join(data, "other.git"), chdir: ordinary)
          when "manual_state"
            state = states.load("A"); state["started_at"] = "2000-01-01T00:00:00Z"; states.write("A", state)
          end
        end
        assert_raises(AgentCodingTool::Error) { instance.launch("T", allow_write_collision: true) }
        refute @store.load("T")["started_at"]
        refute File.exist?(File.join(@root, "worker-pid"))
      end
    end
  end

  # The attempt's development-only restriction survives ending the manual task
  # and cold explicit delivery, even with a configured host validation contract.
  def test_automatic_and_explicit_delivery_remain_disabled
    fixture(git: true, process: true) do
      manual_pair
      directory = "#{@data}-validation"
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.write(File.join(directory, "T.yml"), "invalid on purpose: must never execute\n")
      _output, error, status = cli("launch", "T", "--codex", "--allow-write-collision")
      assert status.success?, error
      assert_includes error, "DELIVERY DEFERRED"
      report, run_dir = target_run
      before = older_bytes
      original_candidate = File.binread(File.join(report.fetch("workspace"), "worker-change.txt"))
      2.times do |index|
        @coordinator.record("A", outcome: "blocked") if index == 1
        _out, refusal, result = cli("deliver", "T")
        assert_equal 2, result.exitstatus
        assert_includes refusal, "managed delivery disabled for this attempt"
        assert_empty Dir.glob(File.join(run_dir, "delivery*"))
        assert_equal @target_base, setup_git("rev-parse", "HEAD", chdir: report.fetch("workspace"))
        assert_equal original_candidate, File.binread(File.join(report.fetch("workspace"), "worker-change.txt"))
        assert_nil @store.load("T")["result"]
        assert_equal before, older_bytes if index.zero?
      end
    end
  end

  # Candidate reservations are not no-run IN_FLIGHT exceptions. Noncandidate
  # terminal manual outcomes retain the pre-existing nonblocking behavior.
  def test_manual_candidate_refuses_and_terminal_non_candidate_remains_nonblocking
    %w[candidate_complete blocked].each do |outcome|
      fixture(git: true, process: true) do
        manual_pair
        state = @store.load("A")
        state.delete("started_at")
        state["result"] = { "outcome" => outcome }
        @store.write("A", state)
        before = older_bytes
        _output, error, status = cli("launch", "T", "--codex", "--allow-write-collision")
        assert_equal outcome == "blocked" ? 0 : 2, status.exitstatus, error
        assert_equal before, before.to_h { |path, _| [path, File.binread(path)] }
      end
    end
  end

  # Source movement after spawn retains both candidates and reports stale exit
  # provenance. No main change is silently adopted into the new worker's base.
  def test_manual_overlap_retains_candidate_when_source_moves_during_execution
    fixture(git: true, process: true, mutable_remote: true) do
      manual_pair
      before = older_bytes
      ordinary = @ordinary
      spawning = lambda do |*args, **options|
        child = Process.spawn(*args, **options)
        File.write(File.join(ordinary, "file.txt"), "new main\n")
        setup_git("commit", "-am", "move while worker executes", chdir: ordinary)
        setup_git("push", "origin", "main", chdir: ordinary)
        child
      end
      assert_equal 0, launcher(real_sandbox_probe: true, spawner: spawning).launch("T", allow_write_collision: true)
      report, = target_run
      assert_equal "stale", report.fetch("writable_freshness")
      assert_equal @target_base, report.fetch("preparation").fetch("repo").fetch("pushed_sha")
      assert_equal @target_base, setup_git("rev-parse", "HEAD", chdir: report.fetch("workspace"))
      assert File.file?(File.join(report.fetch("workspace"), "worker-change.txt"))
      assert_nil @store.load("T")["result"]
      assert_equal before, before.to_h { |path, _| [path, File.binread(path)] }
    end
  end
end
