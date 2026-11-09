# frozen_string_literal: true

# Focused offline public-CLI acceptance with native disposable Git repositories.
# Only Codex is fake. This is separate from zero-Git suites and native isolation.
require "minitest/autorun"
require "tmpdir"
require "open3"
require "fileutils"
require "yaml"
require "timeout"
require_relative "../../lib/agent_coding_tool"

class ManualReadOnlyLaunchTest < Minitest::Test
  # Creates only attempt-private Git/task fixtures. Returns no value; setup
  # failures raise, and teardown removes only this test's disposable directory.
  def setup
    @root = File.realpath(Dir.mktmpdir("act-ro-"))
    @data = File.join(@root, "data")
    FileUtils.mkdir_p(File.join(@data, "tasks"))
    @repositories = {}
    @before = {}
    add_repository("one")
    File.write(File.join(@data, "config.yml"), YAML.dump("repo_root" => @root, "worktree_root" => File.join(@root, "worktrees")))
    File.symlink(File.expand_path("../support/fixtures/launcher_worker.rb", __dir__), File.join(@root, "codex"))
    File.write(File.join(@root, "fake-settings.json"), JSON.generate("mode" => "read-only-success"))
    @environment = { "AGENT_CODING_TOOL_DATA_DIR" => @data, "PATH" => "#{@root}:#{ENV.fetch('PATH')}" }
    write_task
  end

  # Removes the exact disposable fixture after all foreground children are reaped.
  def teardown
    FileUtils.remove_entry(@root) if @root
    @root = nil
  end

  # Adds a real ordinary repository and local bare upstream with known bytes;
  # records source/index/ref identity. Failed Git commands raise immediately.
  def add_repository(name)
    path = File.join(@root, name)
    FileUtils.mkdir_p(path)
    git(path, "init", "-b", "main")
    File.write(File.join(path, "file.txt"), "pinned #{name}")
    git(path, "add", "file.txt")
    git(path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false", "commit", "-m", "fixture")
    remote = File.join(@root, "#{name}.git")
    git(@root, "clone", "--bare", path, remote)
    git(path, "remote", "add", "origin", remote)
    @repositories[name] = { "access" => "read_only", "path" => path }
    @before[name] = source_identity(path)
  end

  # Writes a checkpoint-exempt inspection registration, never real ACTD data.
  def write_task(checkpoint: true)
    task = { "id" => "INSPECT", "title" => "Inspect pinned inputs", "repositories" => @repositories,
      "depends_on" => [], "goal" => "Read file.txt from each input and write report.txt in scratch.",
      "constraints" => ["Do not modify repositories."], "acceptance" => ["Return the report bytes in the final response."] }
    task["checkpoint"] = { "mode" => "exempt", "category" => "inspection", "reason" => "Report only; no implementation." } if checkpoint
    File.write(File.join(@data, "tasks", "INSPECT.yml"), YAML.dump(task))
  end

  # Runs the real public executable with the fixture Codex on PATH. Returns raw
  # stdout/stderr and status; each caller asserts its exact expected outcome.
  def cli(*arguments)
    Open3.capture3(@environment, RbConfig.ruby, File.expand_path("../../bin/agent-coding-tool", __dir__), *arguments)
  end

  # Runs only local fixture Git, returning stdout or raising on failure.
  def git(path, *arguments)
    output, error, status = Open3.capture3("git", "-C", path, *arguments)
    raise error unless status.success?
    output
  end

  # Captures ordinary source/index and refs, excluding expected host worktree
  # administration. Returns comparable bytes, with no writes to source.
  def source_identity(path)
    [File.binread(File.join(path, "file.txt")), File.binread(File.join(path, ".git", "index")),
      git(path, "show-ref"), git(path, "status", "--porcelain")]
  end

  # Returns the exact latest native handoff; missing evidence raises.
  def report
    Dir.glob("#{@data}-runs/INSPECT/*/handoff.json").map { |path| JSON.parse(File.binread(path)) }.max_by { |record| record.fetch("attempt") }
  end

  # Proves preparation, real worktree creation, foreground worker, retained report
  # and existing evidence reader as one journey, for one and multiple readers.
  def test_public_read_only_report_journey
    [1, 2].each do |count|
      add_repository("two") if count == 2
      write_task
      output, error, status = cli("launch", "INSPECT", "--codex", "--reasoning", "high")
      assert status.success?, "#{output}\n#{error}"
      record = report
      assert_equal "exited", record.fetch("status")
      assert_equal 0, record.fetch("exit_status")
      assert_equal [], record.fetch("writable_repositories")
      assert_equal({}, record.fetch("writable_authorities"))
      assert_nil record.fetch("writable_repository")
      assert_nil record.fetch("writable_authority")
      assert_equal({}, record.fetch("workspaces"))
      scratch = record.fetch("fixture").fetch("path")
      assert_equal scratch, record.fetch("workspace")
      assert_equal "Pinned inspection: #{@repositories.keys.map { |name| "pinned #{name}" }.join(', ')}\n", File.binread(File.join(scratch, "report.txt"))
      assert record.fetch("worktrees").fetch("entries").all? { |entry| entry["branch"].nil? && entry["access"] == "read_only" }
      record.fetch("worktrees").fetch("entries").each do |entry|
        assert_equal entry.fetch("base_sha"), git(entry.fetch("path"), "rev-parse", "HEAD").strip
        assert_empty git(entry.fetch("path"), "branch", "--show-current")
        assert_empty git(entry.fetch("path"), "status", "--porcelain")
      end
      @repositories.each { |name, spec| assert_equal @before.fetch(name), source_identity(spec.fetch("path")) }
      identity = record.slice(*AgentCodingTool::RunEvidenceReader::IDENTITIES)
      config = AgentCodingTool::RunEvidenceStore.new(@data).select(identity, artifacts: ["final"], manager: "operator")
      reader = AgentCodingTool::RunEvidenceReader.new(**config.transform_keys(&:to_sym))
      manifest = reader.call(identity.merge("operation" => "manifest", "revision" => nil), caller: "operator")
      assert_equal 0, manifest.fetch("worker_exit_status")
      result = reader.call(identity.merge("operation" => "read", "revision" => manifest.fetch("revision"), "artifact" => "final", "offset" => 0, "length" => 1024), caller: "operator")
      assert_equal File.binread(File.join(scratch, "report.txt")), result.fetch("data").unpack1("m0")
      # A second independent fixture keeps normal same-task admission intact.
      teardown
      setup if count == 1
    end
  end

  # The real CLI preserves failed/interrupted reports, refuses same-task reuse,
  # and uses explicit closeout/retry/finish/ownership-checked cleanup unchanged.
  def test_public_failure_retry_and_cleanup
    File.write(File.join(@root, "fake-settings.json"), JSON.generate("mode" => "read-only-failure"))
    _output, error, status = cli("launch", "INSPECT", "--codex")
    assert_equal 7, status.exitstatus, error
    first = report
    retained = File.join(first.fetch("scratch_path"), "report.txt")
    bytes = File.binread(retained)
    _output, error, status = cli("launch", "INSPECT", "--codex")
    assert_equal 2, status.exitstatus, error
    assert_equal first, report
    %w[status worktrees].each do |command|
      _output, error, status = cli(command, "INSPECT")
      assert status.success?, error
    end
    [["record", "INSPECT", "failed", "--summary", "Synthetic worker exited 7"],
     ["close-attempt", "INSPECT"], ["prepare", "INSPECT", "--retry"]].each do |arguments|
      output, error, status = cli(*arguments)
      assert status.success?, "#{arguments.inspect}: #{output}\n#{error}"
    end
    File.write(File.join(@root, "fake-settings.json"), JSON.generate("mode" => "read-only-success"))
    output, error, status = cli("launch", "INSPECT", "--codex")
    assert status.success?, "#{output}\n#{error}"
    second = report
    refute_equal first.fetch("scratch_path"), second.fetch("scratch_path")
    assert_equal 2, second.fetch("attempt")
    assert_equal bytes, File.binread(retained)
    [["finish", "INSPECT", "--summary", "Synthetic report reviewed"],
     ["cleanup", "INSPECT", "--dry-run"], ["cleanup", "INSPECT"]].each do |arguments|
      output, error, status = cli(*arguments)
      assert status.success?, "#{arguments.inspect}: #{output}\n#{error}"
    end
    assert_equal bytes, File.binread(retained)
    assert File.file?(File.join(second.fetch("scratch_path"), "report.txt"))
    @repositories.each { |name, spec| assert_equal @before.fetch(name), source_identity(spec.fetch("path")) }
    assert Dir.glob("#{@data}-runs/INSPECT/*/worktrees.json").all? { |path|
      JSON.parse(File.binread(path)).fetch("entries").all? { |entry| entry["state"] == "removed" } }
  end

  # Interrupts a genuine foreground CLI process after report creation and checks
  # that its child is reaped while report, streams and ownership remain inspectable.
  def test_public_interrupt_retains_report
    File.write(File.join(@root, "fake-settings.json"), JSON.generate("mode" => "read-only-interrupt"))
    Open3.popen3(@environment, RbConfig.ruby, File.expand_path("../../bin/agent-coding-tool", __dir__),
      "launch", "INSPECT", "--codex") do |input, output, error, waiter|
      input.close
      begin
        Timeout.timeout(5) { sleep 0.01 until File.file?(File.join(@root, "worker-ready")) }
        Process.kill("INT", waiter.pid)
        assert waiter.join(6), "CLI did not reap interrupted worker"
        assert_equal 130, waiter.value.exitstatus, error.read
        record = report
        assert_equal "interrupted", record.fetch("status")
        assert_equal 130, record.fetch("exit_status")
        assert File.file?(File.join(record.fetch("scratch_path"), "report.txt"))
        assert File.file?(record.fetch("jsonl_path"))
        assert_raises(Errno::ESRCH) { Process.kill(0, record.fetch("child_pid")) }
        _stdout, diagnostic, status = cli("worktrees", "INSPECT")
        assert status.success?, diagnostic
      ensure
        if waiter.alive?
          Process.kill("KILL", waiter.pid)
          waiter.join
        end
      end
      output.read
    end
  end

  # Broken external handoffs fail the same report/exit assertions used by the
  # positive journey, even though the normal orchestration reached the worker.
  def test_public_broken_handoffs
    %w[read-only-missing-input read-only-missing-report].each_with_index do |mode, index|
      File.write(File.join(@root, "fake-settings.json"), JSON.generate("mode" => mode))
      _output, _error, status = cli("launch", "INSPECT", "--codex")
      record = report
      if mode == "read-only-missing-input"
        refute status.success?
        refute File.exist?(File.join(record.fetch("scratch_path"), "report.txt"))
      else
        assert status.success?
        assert_equal "invalid_final", record.fetch("status")
        refute record.fetch("final_valid")
      end
      teardown
      setup if index.zero?
    end
  end
end
