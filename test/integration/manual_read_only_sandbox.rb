# frozen_string_literal: true

# Host-only physical gate. Run with --name test_native_read_only_boundary and
# ACT_NATIVE_CODEX set to the installed executable. No inference/authentication.
require_relative "manual_read_only_launch"

class ManualReadOnlyLaunchTest
  # Exercises the production probe and identical worker filesystem policy with
  # real Codex. Checks source/admin/evidence/sibling/parent denial and scratch
  # file lifecycle. Unsupported or nested sandboxes fail, never model a pass.
  def test_native_read_only_boundary
    codex = File.realpath(ENV.fetch("ACT_NATIVE_CODEX"))
    version, error, status = Open3.capture3(codex, "--version")
    assert status.success?, error
    assert_match(/\Acodex-cli (?:0\.162\.1|0\.166\.0)\s*\z/, version)
    _output, error, status = cli("prepare", "INSPECT")
    assert status.success?, error
    state = AgentCodingTool::StateStore.new(File.join(@data, "state")).load("INSPECT")
    run = File.join("#{@data}-runs", "INSPECT", "native-probe")
    FileUtils.mkdir_p(run, mode: 0o700)
    config = AgentCodingTool::Config.load(File.join(@data, "config.yml"))
    manager = AgentCodingTool::WorktreeManager.new(root: config.worktree_root,
      record_path: File.join(run, "worktrees.json"), attempt_paths: true)
    task = AgentCodingTool::TaskStore.new(File.join(@data, "tasks")).load("INSPECT")
    inventory = manager.create(task_id: "INSPECT", attempt: 1, task: task, snapshot: state.fetch("snapshot"))
    sibling = File.join(@root, "sibling-attempt")
    Dir.mkdir(sibling, 0o700)
    launcher = AgentCodingTool::Launcher.new(coordinator: nil, data_root: @data,
      source_root: File.expand_path("../..", __dir__), codex: codex)
    record = { "invocation_id" => SecureRandom.uuid, "writable_repositories" => [],
      "worktrees" => inventory, "preparation" => state.fetch("snapshot"),
      "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "INSPECT", "status" => "preflight" }
    launcher.instance_variable_set(:@report, record)
    launcher.instance_variable_set(:@report_path, File.join(run, "handoff.json"))
    launcher.instance_variable_set(:@parallel_roots, [sibling])
    launcher.send(:provision_fixture!, inventory)
    scratch = record.fetch("fixture").fetch("path")
    record.merge!("workspace" => scratch, "scratch_path" => scratch, "final_path" => File.join(run, "final.txt"))
    sibling_scratch = File.join(File.dirname(scratch), "sibling-attempt")
    Dir.mkdir(sibling_scratch, 0o700)
    sibling_evidence = File.join("#{@data}-runs", "SIBLING", "probe")
    FileUtils.mkdir_p(sibling_evidence, mode: 0o700)
    File.write(File.join(sibling_evidence, "handoff.json"), JSON.generate(
      "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "SIBLING",
      "preparation" => state.fetch("snapshot"), "status" => "exited",
      "fixture" => launcher.send(:fixture_identity!, sibling_scratch).merge("path" => sibling_scratch)))
    launcher.send(:sandbox_probe!, inventory, scratch, run)
    assert_equal scratch, record.fetch("sandbox_probe").fetch("cwd")
    policy = launcher.send(:sandbox_configuration, extra_roots: [])
    argv = launcher.send(:codex_command, scratch, nil, nil)
    assert_equal policy, argv.slice(argv.index("-c"), policy.length)
    input = inventory.fetch("entries").first.fetch("path")
    admin = git(input, "rev-parse", "--absolute-git-dir").strip
    source = File.join(input, "file.txt")
    File.symlink(input, File.join(scratch, "input-link"))
    original = File.join(@repositories.fetch("one").fetch("path"), "file.txt")
    protected = [source, original, File.join(admin, "HEAD"), File.join(@data, "deny"),
      File.join(run, "deny"), File.join(sibling, "deny"), File.join(sibling_scratch, "deny"),
      File.join(scratch, "input-link", "file.txt"),
      File.join(File.dirname(scratch), "deny"), File.join(@root, "deny")]
    before = protected.to_h { |path| [path, File.file?(path) ? File.binread(path) : nil] }
    script = 'set -eu; mkdir "$TMPDIR/lifecycle"; printf report > report.txt; printf temp > "$TMPDIR/lifecycle/tmp"; test "$(cat report.txt)" = report; rm "$TMPDIR/lifecycle/tmp"; rmdir "$TMPDIR/lifecycle"; for path; do if printf breach > "$path" 2>/dev/null; then exit 1; fi; done; printf verified'
    Dir.mktmpdir("native-config-", @root) do |home|
      output, error, status = Open3.capture3(launcher.send(:worker_env, fixture: true).merge("CODEX_HOME" => home),
        codex, "-c", 'sandbox_mode="workspace-write"', *policy, "sandbox", "--",
        "/bin/sh", "-c", script, "act-native-read-only", *protected,
        chdir: scratch, unsetenv_others: true)
      assert status.success?, "#{output}\n#{error}"
      assert_equal "verified", output
    end
    assert_equal before, protected.to_h { |path| [path, File.file?(path) ? File.binread(path) : nil] }
    @repositories.each { |name, spec| assert_equal @before.fetch(name), source_identity(spec.fetch("path")) }
  end
end
