# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../launcher_support"

# Non-inference host acceptance: real installed Codex sandbox, disposable Git,
# no login, model request, worker launch, publication or operator task data.
class ManualParallelNativeSandboxTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Invokes production sandbox_probe! with a real Codex executable. It checks
  # the new writer, reader, ordinary checkouts, shared Git admin, ACTD evidence
  # and known active external workspace. Unsupported hosts fail, never skip.
  def test_native_new_worker_boundary
    assert_match(/darwin/, RUBY_PLATFORM, "NOT RUN: requires native macOS")
    codex = ENV.fetch("ACT_NATIVE_CODEX")
    assert File.file?(codex) && File.executable?(codex), "ACT_NATIVE_CODEX must name the installed executable"
    version, error, status = Open3.capture3(codex, "--version")
    assert status.success?, error
    assert_match(/\Acodex(?:-cli)? 0\.162\.1\s*\z/, version)
    fixture(git: true, process: true) do
      external = File.join(@root, "external-A")
      setup_git("worktree", "add", "-b", "external-A", external, @base, chdir: @ordinary)
      File.binwrite(File.join(external, "candidate.bin"), "\x00\xffpreserved".b)
      reader = File.join(@root, "reader")
      reader_remote = File.join(@root, "reader.git")
      FileUtils.cp_r(@ordinary, reader)
      setup_git("clone", "--bare", reader, reader_remote)
      setup_git("remote", "set-url", "origin", reader_remote, chdir: reader)
      write_task(@data, id: "T", repositories: {
        "repo" => { "access" => "write", "path" => @ordinary },
        "reader" => { "access" => "read_only", "path" => reader }
      })
      state = @coordinator.prepare("T").fetch("state")
      run_dir = File.join(@root, "probe-evidence")
      Dir.mkdir(run_dir, 0o700)
      manager = AgentCodingTool::WorktreeManager.new(root: @config.worktree_root,
        record_path: File.join(run_dir, "worktrees.json"), attempt_paths: true)
      inventory = manager.create(task_id: "T", attempt: 1,
        task: AgentCodingTool::TaskStore.new(File.join(@data, "tasks")).load("T"), snapshot: state.fetch("snapshot"))
      writer = inventory.fetch("entries").find { |entry| entry.fetch("access") == "write" }.fetch("path")
      launcher = AgentCodingTool::Launcher.new(coordinator: @coordinator, data_root: @data,
        source_root: Dir.pwd, codex: File.realpath(codex))
      launcher.instance_variable_set(:@parallel_roots, [external, @data])
      launcher.instance_variable_set(:@manual_conflicts, [{ "task_id" => "A" }])
      launcher.instance_variable_set(:@report, {})
      launcher.instance_variable_set(:@report_path, File.join(run_dir, "handoff.json"))
      ready = File.join(@root, "ready")
      child = Process.spawn(RbConfig.ruby, "-e",
        'File.write(ARGV[1], "ready"); 200.times { File.write(ARGV[0], "active"); sleep 0.025 }',
        File.join(external, "active.txt"), ready)
      require "timeout"
      Timeout.timeout(5) { sleep 0.01 until File.file?(ready) }
      launcher.send(:sandbox_probe!, inventory, writer, run_dir)
      Process.kill(0, child)
      assert_equal "\x00\xffpreserved".b, File.binread(File.join(external, "candidate.bin"))
      assert_equal "macos", JSON.parse(File.binread(File.join(run_dir, "handoff.json"))).fetch("sandbox_probe").fetch("platform")
    ensure
      Process.waitpid(child) if child
    end
  end
end
