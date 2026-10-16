# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Opt-in characterization of ACT-16's fixed-path retry and termination-evidence
# blockers on b0101cf4. Passing means the defects were reproduced, not repaired.
# All repositories, refs, processes and lifecycle writes belong to the fixture.
class TerminalAttemptReproduction < Minitest::Test
  include TestHelpers

  TASK = "ACT16-REPRO"

  # Runs Git only in disposable repositories; returns stdout or raises on error.
  def git(*arguments, directory:)
    output, error, status = Open3.capture3("git", *arguments, chdir: directory)
    raise "fixture Git failed: #{error}" unless status.success?

    output.strip
  end

  # Builds a writer and optional readers from the existing immutable fixture
  # seed. Yields private CLI/data roots; removes only this disposable fixture.
  def fixture(readers: 0)
    Dir.mktmpdir("act16-reproduction-") do |directory|
      @fixture = File.realpath(directory)
      @data = File.join(@fixture, "data")
      @source = File.join(@fixture, "source")
      @visible = File.join(@fixture, "worktrees")
      FileUtils.mkdir_p([@source, File.join(@data, "tasks")])
      seed = TestHelpers.git_seed
      @base = seed.fetch(:base)
      repositories = (["writer"] + (1..readers).map { |number| "reader#{number}" }).to_h do |name|
        ordinary = File.join(@fixture, name)
        FileUtils.cp_r(File.join(seed.fetch(:root), "ordinary"), ordinary)
        remote = File.join(@fixture, "#{name}.git")
        FileUtils.cp_r(File.join(seed.fetch(:root), "remote.git"), remote)
        git("remote", "set-url", "origin", remote, directory: ordinary)
        [name, { "access" => name == "writer" ? "write" : "read_only", "path" => ordinary }]
      end
      write_task(@data, id: TASK, repositories: repositories)
      File.write(File.join(@data, "config.yml"), YAML.dump(
        "repo_root" => @fixture, "worktree_root" => @visible))
      @states = AgentCodingTool::StateStore.new(File.join(@data, "state"))
      @coordinator = AgentCodingTool::Coordinator.new(
        task_store: AgentCodingTool::TaskStore.new(File.join(@data, "tasks")),
        state_store: @states,
        repo_inspector: AgentCodingTool::RepoInspector.new(
          AgentCodingTool::Config.load(File.join(@data, "config.yml"))),
        prompt_renderer: AgentCodingTool::PromptRenderer.new,
        prompt_root: File.join(@data, "state", "prompts"))
      fake_codex
      previous_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{@fixture}:#{previous_path}"
      begin
        yield
      ensure
        ENV["PATH"] = previous_path
      end
    end
  end

  # Writes an offline executable implementing the pinned CLI's external
  # interface. Sandbox results are simulated; no real sandbox or inference runs.
  # An optional finite helper process leaves the worker group to test evidence.
  def fake_codex
    executable = File.join(@fixture, "codex")
    File.write(executable, <<~'RUBY'.sub("RUBY_EXECUTABLE", RbConfig.ruby))
      #!RUBY_EXECUTABLE
      require "json"
      require "rbconfig"
      case ARGV
      when ["--version"]
        puts "codex-cli 0.162.1"
      when ["exec", "--help"]
        puts "--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model"
      when ["login", "--help"]
        puts "status"
      when ["login", "status"]
        puts "Logged in using ChatGPT"
      when ["sandbox", "--help"]
        puts "Usage: codex sandbox [OPTIONS] [COMMAND]..."
      else
        if ARGV.include?("sandbox")
          ARGV.drop(ARGV.index("act-probe") + 1).each do |path|
            allowed = path.start_with?(Dir.pwd + "/")
            File.write(path, "breach") if allowed
            puts(allowed ? "1" : "0")
          end
        else
          abort "unexpected command" unless ARGV.first == "exec"
          root = File.dirname(File.realpath(__FILE__))
          if File.exist?(File.join(root, "escape"))
            # Pipes, cwd and process group no longer connect the helper to the
            # worktree/worker. Its own deadline survives a failed test runner.
            pid = Process.spawn(RbConfig.ruby, "-e", "sleep 10", pgroup: true,
                                chdir: root, in: File::NULL, out: File::NULL, err: File::NULL)
            File.write(File.join(root, "descendant.json"), JSON.generate(
              "pid" => pid, "worker" => Process.pid, "group" => Process.getpgid(pid)))
          end
          STDIN.read
          puts JSON.generate("type" => "thread.started", "thread_id" => "offline-fixture")
          File.write(ARGV.fetch(ARGV.index("--output-last-message") + 1), "Blocked: no implementation.\n")
        end
      end
    RUBY
    File.chmod(0o755, executable)
  end

  # Executes a public CLI command against fixture data and returns its exit,
  # stdout and stderr. ACT errors remain public CLI diagnostics, not exceptions.
  def cli(*arguments)
    output, error = StringIO.new, StringIO.new
    status = AgentCodingTool::CLI.new(root: @source, data_root: @data,
                                     out: output, err: error).run(arguments)
    [status, output.string, error.string]
  end

  # Loads historical reports in attempt order; malformed fixture evidence raises.
  def reports
    Dir.glob(File.join("#{@data}-runs", TASK, "*", "handoff.json")).map do |path|
      [path, JSON.parse(File.binread(path))]
    end.sort_by { |_path, report| report.fetch("attempt") }
  end

  # Captures exact fixture bytes without changing any ACT evidence. The returned
  # mapping permits byte comparisons including reports, original prompt and logs.
  def bytes(paths)
    paths.to_h { |path| [path, File.binread(path)] }
  end

  # Advances only the preparation clock to avoid a sleep and timestamp reuse.
  # Restores Time.now on every exit; no report or lifecycle file is edited.
  def fresh_retry
    original_now = Time.method(:now)
    timestamp = original_now.call + 2
    Time.define_singleton_method(:now) { timestamp }
    cli("prepare", TASK, "--retry")
  ensure
    Time.define_singleton_method(:now, original_now) if original_now
  end

  # Reproduces the reported order through public CLI commands with eight real
  # native worktrees. Asserts the valid first inventory survives the second
  # attempt's pre-inventory collision and that current inspection/recovery wedge.
  def test_terminal_worker_then_retry_collides_before_inventory_and_wedges_inspection
    fixture(readers: 7) do
      result = cli("launch", TASK, "--codex", "--reasoning", "high")
      assert_equal 0, result.first, result.last
      original_path, original = reports.fetch(0)
      assert_equal [1, "exited", 0, true, "fresh_at_exit"],
                   original.values_at("attempt", "status", "exit_status", "final_valid", "writable_freshness")
      assert_equal "IN_FLIGHT", @coordinator.status(TASK).fetch("status")
      refute @states.load(TASK)["checkpoint"]
      inventory = AgentCodingTool::WorktreeManager.new(
        root: @visible, record_path: original.fetch("worktrees_path")).inspect!
      assert_equal 8, inventory.fetch("entries").length
      inventory.fetch("entries").each do |entry|
        assert_equal @base, git("rev-parse", "HEAD", directory: entry.fetch("path"))
        assert_equal "", git("status", "--porcelain", "--untracked-files=all", directory: entry.fetch("path"))
        branch = git("rev-parse", "--abbrev-ref", "HEAD", directory: entry.fetch("path"))
        assert_equal(entry["access"] == "write" ? "act/#{TASK}/attempt-1" : "HEAD", branch)
      end
      assert_equal 0, cli("worktrees", TASK).first
      original_bytes = bytes([original_path, original.fetch("worktrees_path"),
                              *original.fetch("artifacts").map { |artifact| artifact.fetch("path") }])
      original.fetch("artifacts").each do |artifact|
        content = original_bytes.fetch(artifact.fetch("path"))
        assert_equal artifact.fetch("bytes"), content.bytesize
        assert_equal artifact.fetch("sha256"), Digest::SHA256.hexdigest(content)
      end
      assert_equal 0, cli("record", TASK, "blocked", "--summary", "No code or candidate.",
                          "--next", "Inspect and explicitly recover before retry.").first
      assert_equal 0, fresh_retry.first
      retry_state = @states.load(TASK)
      status, _output, error = cli("launch", TASK, "--codex", "--reasoning", "high")
      assert_equal 2, status
      assert_includes error, "occupied path"
      _second_path, second = reports.fetch(1)
      assert_equal [2, "preflight_failed", nil, nil], second.values_at("attempt", "status", "workspace", "child_pid")
      refute File.exist?(second.fetch("worktrees_path"))
      assert_equal retry_state, @states.load(TASK)
      assert_equal "PREPARED", @coordinator.status(TASK).fetch("status")
      assert_equal 2, cli("worktrees", TASK).first
      assert_equal 2, cli("abandon-preflight", TASK, "--dry-run").first
      assert_equal 2, cli("cleanup", TASK).first
      assert_equal 2, cli("launch", TASK, "--codex").first
      assert_equal 2, reports.length
      assert_equal original_bytes, bytes(original_bytes.keys)
      assert_equal inventory, AgentCodingTool::WorktreeManager.new(
        root: @visible, record_path: original.fetch("worktrees_path")).inspect!
    end
  end

  # Demonstrates the process-group evidence gap without invoking any recovery.
  # A real finite fixture descendant outlives a valid terminal report and leaves
  # the worker group. CleanupLiveness has no parameter identifying that child.
  def test_terminal_report_does_not_prove_descendant_termination
    fixture do
      helper = nil
      begin
        File.write(File.join(@fixture, "escape"), "finite fixture helper")
        assert_equal 0, cli("launch", TASK, "--codex").first
        _report_path, report = reports.fetch(0)
        helper = JSON.parse(File.binread(File.join(@fixture, "descendant.json")))
        assert_equal "exited", report.fetch("status")
        assert_equal 0, report.fetch("exit_status")
        assert report.fetch("final_valid")
        assert_equal report.fetch("child_pid"), helper.fetch("worker")
        assert_equal helper.fetch("pid"), helper.fetch("group")
        refute_equal report.fetch("child_pid"), helper.fetch("group")
        assert_raises(Errno::ESRCH) { Process.kill(0, -report.fetch("child_pid")) }
        assert_equal 1, Process.kill(0, helper.fetch("pid"))
        assert_equal Process.pid, report.fetch("host_pid")
        assert_equal 1, Process.kill(0, report.fetch("host_pid"))
        refute report.key?("descendants")
        refute report.key?("host_identity")
        refute report.key?("host_process_started_at")
        # Model an available lsof reporting no open files in the worktree.
        # This is a deterministic decision probe, not real Mac liveness proof.
        lsof = File.join(@fixture, "lsof")
        File.write(lsof, "#!/bin/sh\nexit 1\n")
        File.chmod(0o755, lsof)
        assert_equal :clear, AgentCodingTool::CleanupLiveness.new.check(report, report.fetch("worktrees"))
        assert_equal 1, Process.kill(0, helper.fetch("pid"))
      ensure
        # Only the PID created by this fixture is signalled. No production
        # recovery is called and no shell/shared process group is targeted.
        Process.kill("TERM", helper.fetch("pid")) if helper
      end
    end
  end
end
