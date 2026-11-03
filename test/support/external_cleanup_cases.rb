# frozen_string_literal: true

require "json"
require "yaml"
require "digest"
require "stringio"
require "minitest/mock"

# Shared public-entry acceptance cases. Runners supply either real disposable Git
# or the suite's finite Git world; only provider and liveness are external fakes.
module ExternalCleanupCases
  REMOTE = "git@github.com:dtnorris/agent-coding-tool.git"
  URL = "https://github.com/dtnorris/agent-coding-tool/pull/38"

  # Returns declared external observations and permits deterministic boundary drift.
  class Provider
    attr_accessor :result, :before_query

    # Binds a merged PR observation; no network or publication occurs.
    def initialize(head, merged)
      @result = { "merged" => true, "head" => head, "base" => "main", "merge_commit_sha" => merged }
    end

    # Returns fresh provider evidence only for the exact expected authority/URL.
    # Unknown calls raise rather than silently matching another repository.
    def integration(remote, url)
      raise "unexpected external query" unless remote == REMOTE && url == URL
      @before_query&.call
      @result.dup
    end
  end

  # Models only the external process observation, including active/unknown refusal.
  class Liveness
    attr_accessor :status, :before_check

    # Starts at a declared terminal, unused worktree observation.
    def initialize = @status = :clear

    # Returns the current external observation without mutating task evidence.
    def check(_report, inventory)
      @before_check&.call(inventory)
      @status
    end
  end

  # Runs one command through the runner's Git transport; setup failures raise.
  def git(path, *arguments)
    result = @transport.call(["git", *arguments], cwd: path)
    raise "fixture Git failed: #{result.stderr}" unless result.success?
    result.stdout.strip
  end

  # Creates a completed owned worktree manually advanced beyond its original base.
  # Evidence, refs and lifecycle are real files; no managed delivery is fabricated.
  def fixture
    Dir.mktmpdir("act-external-cleanup-") do |temporary|
      @root = File.realpath(temporary)
      previous_tmpdir = ENV["TMPDIR"]
      ENV["TMPDIR"] = @root
      with_git_world(@root) do
        @data = File.join(@root, "data")
        @visible = File.join(@root, "worktrees")
        @run = File.join("#{@data}-runs", "TASK", "attempt-1")
        [File.join(@data, "tasks"), File.join(@data, "state"), @run].each { |path| FileUtils.mkdir_p(path) }
        File.chmod(0o700, "#{@data}-runs")
        File.write(File.join(@data, "config.yml"), YAML.dump("worktree_root" => @visible))
        @parent, base = build_repository(@root)
        snapshot = { "repo" => { "path" => @parent, "remote" => "origin", "remote_url" => REMOTE,
                                "branch" => "main", "pushed_sha" => base } }
        task = { "id" => "TASK", "title" => "External cleanup", "depends_on" => [],
                 "repositories" => { "repo" => { "access" => "write" } } }
        File.write(File.join(@data, "tasks", "TASK.yml"), YAML.dump(task))
        AgentCodingTool::StateStore.new(File.join(@data, "state")).write("TASK",
          { "id" => "TASK", "snapshot" => snapshot, "result" => { "outcome" => "complete" } })
        inventory = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: File.join(@run, "worktrees.json"),
          attempt_paths: true, transport: @transport).create(task_id: "TASK", attempt: 1, task: task, snapshot: snapshot)
        @workspace = inventory.fetch("entries").first.fetch("path")
        report = { "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "TASK", "attempt" => 1,
          "status" => "exited", "ended_at" => "2026-01-01T00:00:00Z", "child_pid" => 999999,
          "preparation" => snapshot, "worktrees" => inventory, "worktrees_path" => File.join(@run, "worktrees.json") }
        File.write(File.join(@run, "handoff.json"), JSON.generate(report))
        %w[checkpoint.json gate.json original.log].each { |name| File.binwrite(File.join(@run, name), "original\x00\xff".b) }
        File.write(File.join(@workspace, "file.txt"), "manual change\n")
        git(@workspace, "add", "--", "file.txt")
        git(@workspace, "commit", "-m", "manual feature commit")
        @head = git(@workspace, "rev-parse", "HEAD")
        File.write(File.join(@parent, "file.txt"), "manual change\n")
        git(@parent, "add", "--", "file.txt")
        git(@parent, "commit", "-m", "manual squash merge")
        @provider = Provider.new(@head, git(@parent, "rev-parse", "HEAD"))
        @liveness = Liveness.new
        yield
      end
    ensure
      ENV["TMPDIR"] = previous_tmpdir
    end
  end

  # Constructs a fresh cleanup owner, enabling cold retry without cached evidence.
  def manager(**options)
    AgentCodingTool::CleanupManager.new(data_root: @data, provider: @provider, liveness: @liveness,
      transport: @transport, **options)
  end

  # Invokes the public CLI with fakes only at external observation boundaries.
  # Returns status, stdout and stderr for exact refusal assertions.
  def cli(*arguments, handler: manager)
    output, errors = StringIO.new, StringIO.new
    status = AgentCodingTool::CleanupManager.stub(:new, handler) do
      AgentCodingTool::CLI.new(root: @root, data_root: @data, out: output, err: errors,
        transport: @transport).run(["cleanup", "TASK", *arguments])
    end
    [status, output.string, errors.string]
  end

  # Captures file bytes including native Git administration and refs; dry-run must
  # preserve the complete snapshot. Directories are recorded to catch new resources.
  def bytes
    Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
      [path, File.directory?(path) ? :directory : File.binread(path)]
    end
  end

  # Asserts one public CLI refusal and preservation of the owned native worktree.
  def refuses(message, *arguments, handler: manager)
    status, _output, errors = cli(*arguments, handler: handler)
    assert_equal 2, status, errors
    assert_includes errors, message
    assert File.directory?(@workspace)
    assert_equal @head, git(@workspace, "rev-parse", "HEAD")
  end

  # Proves real/public manual delivery cleanup, case-insensitive short references,
  # dry-run byte preservation, and survival of original evidence/lifecycle/refs.
  def test_external_pr_public_cleanup_and_dry_run
    ["ACT-38", "act-38", URL].each do |reference|
      fixture do
        before = bytes
        status, output, errors = cli("--pr", "act-38", "--dry-run")
        assert_equal 0, status, errors
        refute JSON.parse(output).fetch("blocked")
        assert_equal before, bytes
        refuses("HEAD changed")
        refute_includes cli.last, "foreign task path entries"
        preserved = before.select { |path, _value| path.start_with?(@run + "/") || path.start_with?(@data + "/") }
          .reject { |path, _value| path.end_with?("/worktrees.json") }
        status, _output, errors = cli("--pr", reference)
        assert_equal 0, status, errors
        refute File.exist?(@workspace)
        preserved.each { |path, value| assert_equal value, File.directory?(path) ? :directory : File.binread(path) }
        assert_equal @head, git(@parent, "rev-parse", "refs/heads/act/TASK/attempt-1")
        receipt = File.binread(File.join(@run, "external-delivery-repo.json"))
        assert_equal 0, cli.first
        assert_equal receipt, File.binread(File.join(@run, "external-delivery-repo.json"))
      end
    end
  end

  # Exercises full URL resolution and each provider identity/integration refusal.
  # Restoring a required observation is necessary for the positive dry-run.
  def test_external_pr_identity_negative_controls
    fixture do
      %w[ACT-0 ACT--1 AC-38 NOPE-38 ACT-38x].each { |reference| refuses("cleanup:", "--pr", reference) }
      refuses("exactly one", "--pr", "https://github.com/other/repo/pull/38")
      original = @provider.result.dup
      { "merged" => false, "base" => "release", "head" => "f" * 40,
        "merge_commit_sha" => "e" * 40 }.each do |key, value|
        @provider.result = original.merge(key => value)
        expected = key == "head" ? "HEAD changed" : key == "merge_commit_sha" ? "not integrated" : "not verifiably merged"
        refuses(expected, "--pr", URL)
      end
      @provider.result = original
      assert_equal 0, cli("--dry-run", "--pr", URL).first
      assert_empty Dir.glob(File.join(@run, "external-delivery*"))
    end
  end

  # Keeps existing completion, ignored-file cleanliness, foreign-path and liveness
  # gates mandatory even when the external PR is otherwise valid.
  def test_external_pr_safety_gates
    fixture do
      %i[active unknown].each do |status|
        @liveness.status = status
        refuses("worker liveness #{status}", "--pr", "ACT-38")
      end
      @liveness.status = :clear
      File.write(File.join(@workspace, "ignored"), "keep")
      refuses("worktree contains changes", "--pr", "ACT-38")
      File.unlink(File.join(@workspace, "ignored"))
      foreign = File.join(File.dirname(@workspace), "foreign")
      File.write(foreign, "keep")
      refuses("foreign task path entries", "--pr", "ACT-38")
      File.unlink(foreign)
      state_path = File.join(@data, "state", "TASK.yml")
      state = YAML.safe_load_file(state_path)
      state["result"]["outcome"] = "candidate_complete"
      File.write(state_path, YAML.dump(state))
      refuses("task outcome is candidate_complete", "--pr", "ACT-38")
      assert_empty Dir.glob(File.join(@run, "external-delivery*"))
    end
  end

  # Conflicting managed/receipt evidence cannot be overwritten or authorize removal.
  def test_external_pr_conflicting_evidence
    fixture do
      delivery = File.join(@run, "delivery.json")
      File.write(delivery, JSON.generate("stage" => "committed", "commit_sha" => @head))
      refuses("conflicting existing delivery", "--pr", "ACT-38")
      File.unlink(delivery)
      receipt = manager.preflight("TASK", pr: "ACT-38").fetch("external_deliveries").first
      receipt.fetch("receipt")["attempt"] = 2
      File.write(receipt.fetch("path"), JSON.generate(receipt.fetch("receipt")))
      before = File.binread(receipt.fetch("path"))
      refuses("conflicting external-delivery receipt", "--pr", "ACT-38")
      refuses("conflicting external-delivery receipt")
      assert_equal before, File.binread(receipt.fetch("path"))
    end
  end

  # An additional recorded attempt for the same remote is ambiguous even if its
  # native identity is damaged; no receipt may be published for either attempt.
  def test_external_pr_ambiguous_attempt
    fixture do
      other = File.join(File.dirname(@run), "attempt-2")
      FileUtils.mkdir_p(other)
      report = JSON.parse(File.read(File.join(@run, "handoff.json")))
      task = YAML.safe_load_file(File.join(@data, "tasks", "TASK.yml"))
      record = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: File.join(other, "worktrees.json"),
        attempt_paths: true, transport: @transport).create(task_id: "TASK", attempt: 2, task: task, snapshot: report.fetch("preparation"))
      report["attempt"] = 2
      report["worktrees"] = record
      report["worktrees_path"] = File.join(other, "worktrees.json")
      File.write(File.join(other, "handoff.json"), JSON.generate(report))
      refuses("exactly one", "--pr", "ACT-38")
      assert_empty Dir.glob(File.join(@run, "external-delivery*"))
    end
  end

  # Failing receipt publication cannot begin native removal. A cold retry after
  # successful publication uses the durable receipt with fresh external checks.
  def test_external_pr_receipt_failure_and_cold_retry
    fixture do
      File.stub(:link, proc { |*_arguments| raise Errno::EACCES, "fixture receipt failure" }) do
        refuses("receipt write failed", "--pr", "ACT-38")
      end
      assert_empty Dir.glob(File.join(@run, "external-delivery*"))
      item = manager.preflight("TASK", pr: "ACT-38").fetch("external_deliveries").first
      manager.send(:publish_receipt!, item.fetch("path"), item.fetch("receipt"))
      receipt = File.binread(item.fetch("path"))
      @provider.result["merged"] = false
      refuses("not verifiably merged")
      @provider.result["merged"] = true
      assert_equal 0, cli.first
      refute File.exist?(@workspace)
      assert_equal receipt, File.binread(item.fetch("path"))
      FileUtils.mkdir_p(@workspace)
      File.write(File.join(@workspace, "new-resource"), "keep")
      assert_equal 2, cli.first
      assert_equal "keep", File.read(File.join(@workspace, "new-resource"))
    end
  end

  # Rechecks provider/liveness at the native mutation boundary, after publication;
  # partial removal markers and the receipt safely support a new cleanup owner.
  def test_external_pr_boundary_drift_and_partial_removal
    fixture do
      @liveness.before_check = proc do |inventory|
        @liveness.status = :active if inventory.fetch("entries").any? { |entry| entry["state"] == "removing" }
      end
      refuses("worker liveness active", "--pr", "ACT-38")
      @liveness.before_check = nil
      @liveness.status = :clear
      receipt = File.binread(File.join(@run, "external-delivery-repo.json"))
      handler = manager(after_removal: proc { |_entry| raise AgentCodingTool::InvalidState, "fixture interruption" })
      assert_equal 2, cli(handler: handler).first
      refute File.exist?(@workspace)
      assert_equal 0, cli.first
      assert_equal receipt, File.binread(File.join(@run, "external-delivery-repo.json"))
    end
  end

  # Rejects malformed CLI arguments and foreign receipt/native ownership evidence.
  # Existing receipts and worktrees remain intact for inspection.
  def test_external_pr_malformed_and_foreign_inputs
    fixture do
      [["--pr"], ["--pr", "ACT-38", "--pr", "ACT-38"], ["--force"],
       ["--dry-run", "--dry-run"]].each { |arguments| refuses("usage:", *arguments) }
      path = File.join(@run, "external-delivery-repo.json")
      File.write(path, "[]")
      refuses("malformed external-delivery receipt", "--pr", "ACT-38")
      File.unlink(path)
      File.symlink(File.join(@run, "original.log"), path)
      refuses("foreign external-delivery receipt", "--pr", "ACT-38")
      File.unlink(path)
      pointer = File.join(@workspace, ".git")
      original = File.binread(pointer)
      File.unlink(pointer)
      File.symlink(File.join(@run, "original.log"), pointer)
      assert_equal 2, cli("--pr", "ACT-38").first
      File.unlink(pointer)
      File.binwrite(pointer, original)
      assert_equal 0, cli("--dry-run", "--pr", "ACT-38").first
    end
  end

  # A valid-looking evidence edit between preflight and mutation is still drift.
  # The bound source bytes must remain stable, not merely pass semantic checks.
  def test_external_pr_evidence_drift_refuses
    fixture do
      changed = false
      @provider.before_query = proc do
        unless changed
          changed = true
          path = File.join(@data, "tasks", "TASK.yml")
          File.write(path, File.read(path) + "# concurrent edit\n")
        end
      end
      refuses("evidence changed before receipt publication", "--pr", "ACT-38")
      assert_empty Dir.glob(File.join(@run, "external-delivery*"))
    end
  end

  # External observation can race the earlier ownership check. Exact native HEAD
  # must be checked again after provider/liveness calls and before Git removal.
  def test_external_pr_head_drift_at_native_boundary
    fixture do
      changed = false
      @liveness.before_check = proc do |inventory|
        if !changed && inventory.fetch("entries").any? { |entry| entry["state"] == "removing" }
          changed = true
          File.write(File.join(@workspace, "file.txt"), "concurrent commit\n")
          git(@workspace, "add", "--", "file.txt")
          git(@workspace, "commit", "-m", "concurrent feature change")
        end
      end
      status, _output, errors = cli("--pr", "ACT-38")
      assert_equal 2, status, errors
      assert_includes errors, "HEAD changed"
      assert File.directory?(@workspace)
      refute_equal @head, git(@workspace, "rev-parse", "HEAD")
      receipt = JSON.parse(File.read(File.join(@run, "external-delivery-repo.json")))
      assert_equal @head, receipt.fetch("commit_sha")
    end
  end
end
