# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "json"
require "open3"
require "rbconfig"

class DeliveryManagerTest < Minitest::Test
  class Provider
    attr_reader :pushes, :creations, :body
    attr_accessor :fail_after_push, :fail_after_pr

    def initialize
      @refs, @prs, @pushes, @creations = {}, {}, [], []
    end

    def branch(_remote, name) = @refs[name]
    def set_branch(name, sha) = @refs[name] = sha

    def push(_workspace, _remote, name, sha)
      @pushes << name
      @refs[name] = sha
      raise AgentCodingTool::RepositoryError, "simulated lost push response" if @fail_after_push
    end

    def pull_requests(_remote, name) = @prs.fetch(name, [])

    def create_draft(_remote, name, base, title, body)
      @body = body
      @creations << name
      @prs[name] = [{ "url" => "https://example.invalid/pull/1", "state" => "open",
                      "draft" => true, "head" => @refs.fetch(name), "base" => base }]
      raise AgentCodingTool::RepositoryError, "simulated lost PR response" if @fail_after_pr
    end
  end

  class Guard
    attr_reader :checks
    def initialize = @checks = []
    def verify!(_policy, _remote, stage, _commit) = @checks << stage
  end

  class Coordinator
    attr_accessor :head
    def initialize(data, remote, head)
      @data, @remote, @head = data, remote, head
    end

    def launch_heads(_id)
      { "repo" => { "remote_url" => @remote, "branch" => "main", "pushed_sha" => @head } }
    end

    # Records synthetic candidate details using the delivery-owned reservation.
    # Returns bytes written; invalid/busy borrowed locks raise InvalidState.
    def record(id, outcome:, summary:, artifact:, tests:, reservation_lock:)
      AgentCodingTool::ReservationLock.synchronize(@data, held: reservation_lock) do
        store = AgentCodingTool::StateStore.new(File.join(@data, "state"))
        state = store.load(id)
        state["result"] = { "outcome" => outcome, "summary" => summary,
                            "artifact" => artifact, "tests" => tests }
        state.delete("started_at")
        store.write(id, state)
      end
    end
  end

  def fixture(output: "2 tests, 3 assertions, 0 failures, 0 errors, 0 skips", allowed: ["file.txt"])
    Dir.mktmpdir do |temporary_root|
      # Launcher canonicalizes data_root before recording handoff paths. On
      # macOS, Dir.mktmpdir may return /var while realpath uses /private/var.
      root = File.realpath(temporary_root)
      ordinary = File.join(root, "ordinary")
      remote = File.join(root, "remote.git")
      data = File.join(root, "data")
      worktrees = File.join(root, "worktrees")
      run_dir = File.join("#{data}-runs", "TASK", "run")
      [ordinary, data, File.join(data, "tasks"), File.join(data, "state"),
       "#{data}-validation", run_dir].each { |p| FileUtils.mkdir_p(p) }
      File.chmod(0o700, "#{data}-validation")
      File.chmod(0o700, "#{data}-runs")
      git(root, "init", "-q", "--bare", remote)
      git(root, "init", "-q", "-b", "main", ordinary)
      git(ordinary, "config", "user.name", "Test")
      git(ordinary, "config", "user.email", "test@example.invalid")
      File.write(File.join(ordinary, "file.txt"), "baseline\n")
      git(ordinary, "add", "file.txt")
      git(ordinary, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base")
      base = git(ordinary, "rev-parse", "HEAD").strip
      git(ordinary, "remote", "add", "origin", remote)
      git(ordinary, "push", "-q", "origin", "main")
      File.write(File.join(data, "config.yml"), YAML.dump("worktree_root" => worktrees))
      File.write(File.join(data, "tasks", "TASK.yml"), YAML.dump(
        "id" => "TASK", "title" => "Change file", "repositories" => { "repo" => { "access" => "write" } }))
      snapshot = { "repo" => { "path" => ordinary, "remote" => "origin", "remote_url" => remote,
                               "branch" => "main", "pushed_sha" => base } }
      state = { "id" => "TASK", "snapshot" => snapshot, "started_at" => Time.now.utc.iso8601 }
      AgentCodingTool::StateStore.new(File.join(data, "state")).write("TASK", state)
      contract = { "allowed_paths" => allowed, "base_branch" => "main",
                   "commands" => [["ruby", "-e", "puts #{output.inspect}"]],
                   "max_seconds" => 30, "min_tests" => 2, "min_assertions" => 3,
                   "publication_guard" => { "lease_check" => "/unused-in-fake",
                                            "trigger_assessment" => "fixture has no paid hooks" } }
      File.write(File.join("#{data}-validation", "TASK.yml"), YAML.dump(contract))
      inventory = AgentCodingTool::WorktreeManager.new(root: worktrees,
        record_path: File.join(run_dir, "worktrees.json")).create(
          task_id: "TASK", attempt: 1,
          task: { "repositories" => { "repo" => { "access" => "write" } } }, snapshot: snapshot)
      workspace = inventory.fetch("entries").first.fetch("path")
      File.write(File.join(workspace, "file.txt"), "changed\n")
      report = { "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "TASK",
                 "attempt" => 1, "status" => "exited", "exit_status" => 0, "final_valid" => true,
                 "writable_freshness" => "fresh_at_exit", "writable_repository" => "repo",
                 "preparation" => snapshot, "worktrees" => inventory, "workspace" => workspace,
                 "worktrees_path" => File.join(run_dir, "worktrees.json") }
      report["artifacts"] = %w[prompt_path stdin_path jsonl_path stderr_path final_path].map do |key|
        path = File.join(run_dir, key)
        File.write(path, "host evidence\n")
        report[key] = path
        { "path" => path, "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path) }
      end
      File.write(File.join(run_dir, "handoff.json"), JSON.generate(report))
      provider, guard = Provider.new, Guard.new
      coordinator = Coordinator.new(data, remote, base)
      manager = AgentCodingTool::DeliveryManager.new(data_root: data, coordinator: coordinator,
                                                      provider: provider, guard: guard)
      yield manager, provider, guard, coordinator, workspace, run_dir, data
    end
  end

  def git(path, *args)
    out, err, status = Open3.capture3("git", *args, chdir: path)
    raise err unless status.success?
    out
  end

  def test_validates_exact_bytes_then_commits_pushes_once_and_opens_draft
    fixture do |manager, provider, guard, _coordinator, workspace, run_dir, data|
      result = manager.deliver("TASK", run_dir: run_dir)
      assert_equal "draft_pr", result["stage"]
      assert_equal ["act/TASK/attempt-1"], provider.pushes
      assert_equal provider.pushes, provider.creations
      assert_equal [:push, :pr], guard.checks
      assert_equal "changed\n", git(workspace, "show", "HEAD:file.txt")
      assert_match(/## Validation Evidence/, provider.body)
      assert_match(/2 tests, 3 assertions, 0 failures, 0 errors, 0 skips/, provider.body)
      assert_equal "candidate_complete", AgentCodingTool::StateStore.new(File.join(data, "state")).load("TASK").dig("result", "outcome")
      assert_equal result, manager.deliver("TASK", run_dir: run_dir)
      assert_equal 1, provider.pushes.length
      assert_equal 1, provider.creations.length
      output = StringIO.new
      assert_equal 0, AgentCodingTool::CLI.run(["worktrees", "TASK"], root: workspace,
        data_root: data, out: output, err: StringIO.new)
      assert_match(/act\/TASK\/attempt-1/, output.string)
    end
  end

  # Fresh and resumed deliveries recheck the same external envelope before any
  # candidate/state/ref mutation; independently recorded reality remains visible.
  def test_external_observation_blocks_fresh_and_resumed_delivery
    [false, true].each do |resumed|
      fixture do |manager, provider, _guard, _coordinator, workspace, run_dir, data|
        if resumed
          provider.fail_after_push = true
          assert_raises(AgentCodingTool::RepositoryError) { manager.deliver("TASK", run_dir: run_dir) }
          provider.fail_after_push = false
        end
        activity = AgentCodingTool::ExternalActivity.new(data_root: data,
          task_store: AgentCodingTool::TaskStore.new(File.join(data, "tasks")),
          state_store: AgentCodingTool::StateStore.new(File.join(data, "state")),
          repo_inspector: AgentCodingTool::RepoInspector.new(AgentCodingTool::Config.load(File.join(data, "config.yml"))))
        document = activity.report("TASK", reporter: "operator", kind: "external-fake")
        before = Dir.glob(File.join(File.dirname(data), "**", "*"), File::FNM_DOTMATCH)
                    .select { |path| File.file?(path) }.to_h { |path| [path, File.binread(path)] }
        error = assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run_dir) }
        assert_includes error.message, "external activity conflict"
        output, diagnostic = StringIO.new, StringIO.new
        assert_equal 2, AgentCodingTool::CLI.run(["deliver", "TASK"], root: Dir.pwd, data_root: data, out: output, err: diagnostic)
        assert_includes diagnostic.string, "external activity conflict"
        assert_equal before, before.keys.to_h { |path| [path, File.binread(path)] }
        assert_equal(resumed ? 1 : 0, provider.pushes.length)
        assert_equal document.fetch("active").fetch("observation_id"), activity.show("TASK").fetch("active").fetch("observation_id")
      end
    end
  end

  def test_symlinked_temporary_root_matches_launcher_path_contract
    Dir.mktmpdir("act-delivery-alias-") do |temporary_root|
      real = File.join(File.realpath(temporary_root), "real")
      alias_path = File.join(File.realpath(temporary_root), "alias")
      FileUtils.mkdir_p(real)
      File.symlink(real, alias_path)
      original_tmpdir = ENV["TMPDIR"]
      begin
        ENV["TMPDIR"] = alias_path
        fixture do |manager, provider, _guard, _coordinator, _workspace, run_dir, _data|
          assert_equal File.realpath(run_dir), run_dir
          assert_equal "draft_pr", manager.deliver("TASK", run_dir: run_dir)["stage"]
          assert_equal 1, provider.pushes.length
        end
      ensure
        ENV["TMPDIR"] = original_tmpdir
      end
    end
  end

  def test_fails_closed_on_skipped_or_missing_evidence_and_unauthorized_paths
    ["2 tests, 3 assertions, 0 failures, 0 errors, 1 skips", "not a test summary"].each do |output|
      fixture(output: output) do |manager, provider, _guard, _coordinator, _workspace, run_dir, _data|
        assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run_dir) }
        assert_empty provider.pushes
      end
    end
    fixture(allowed: ["different.txt"]) do |manager, provider, _guard, _coordinator, _workspace, run_dir, _data|
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run_dir) }
      assert_empty provider.pushes
    end
  end

  def test_crash_after_remote_push_or_pr_recovers_without_duplicates
    [:fail_after_push, :fail_after_pr].each do |stage|
      fixture do |manager, provider, _guard, _coordinator, _workspace, run_dir, _data|
        provider.public_send("#{stage}=", true)
        assert_raises(AgentCodingTool::RepositoryError) { manager.deliver("TASK", run_dir: run_dir) }
        provider.public_send("#{stage}=", false)
        assert_equal "draft_pr", manager.deliver("TASK", run_dir: run_dir)["stage"]
        assert_equal 1, provider.pushes.length
        assert_equal 1, provider.creations.length
      end
    end
  end

  def test_private_output_blocks_publication_but_retains_local_commit_and_logs
    fixture(output: "token ghp_secret 2 tests, 3 assertions, 0 failures, 0 errors, 0 skips") do |manager, provider, _guard, _coordinator, workspace, run_dir, _data|
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run_dir) }
      assert_empty provider.pushes
      refute_empty git(workspace, "log", "-1", "--format=%s")
      assert_match(/ghp_secret/, File.read(File.join(run_dir, "validation-0.stdout")))
    end
  end

  def test_tampering_with_log_or_source_blocks_recovery
    fixture do |manager, provider, _guard, _coordinator, workspace, run_dir, _data|
      provider.fail_after_push = true
      assert_raises(AgentCodingTool::RepositoryError) { manager.deliver("TASK", run_dir: run_dir) }
      File.write(File.join(run_dir, "validation-0.stdout"), "forged")
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run_dir) }
    end
    fixture do |manager, provider, _guard, _coordinator, workspace, run_dir, _data|
      provider.fail_after_push = true
      assert_raises(AgentCodingTool::RepositoryError) { manager.deliver("TASK", run_dir: run_dir) }
      File.write(File.join(workspace, "file.txt"), "changed again")
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run_dir) }
    end
  end

  def test_stale_main_competing_feature_ref_and_forged_worker_artifact_block
    fixture do |manager, provider, _guard, coordinator, _workspace, run_dir, _data|
      coordinator.head = "a" * 40
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run_dir) }
      assert_empty provider.pushes
    end
    fixture do |manager, provider, _guard, _coordinator, _workspace, run_dir, _data|
      provider.set_branch("act/TASK/attempt-1", "b" * 40)
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run_dir) }
      assert_empty provider.pushes
    end
    fixture do |manager, provider, _guard, _coordinator, _workspace, run_dir, _data|
      File.write(File.join(run_dir, "final_path"), "worker changed this")
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run_dir) }
      assert_empty provider.pushes
    end
  end

  def test_coverage_floor_is_host_enforced
    fixture(output: "2 tests, 3 assertions, 0 failures, 0 errors, 0 skips; Coverage: 89.9%") do |manager, provider, _guard, _coordinator, _workspace, run_dir, data|
      path = File.join("#{data}-validation", "TASK.yml")
      contract = YAML.safe_load_file(path)
      contract["coverage_min_percent"] = 90
      File.write(path, YAML.dump(contract))
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run_dir) }
      assert_empty provider.pushes
    end
  end

  def test_live_git_push_adapter_creates_only_absent_feature_ref
    fixture do |_manager, _provider, _guard, coordinator, workspace, _run_dir, _data|
      remote = git(workspace, "remote", "get-url", "origin").strip
      base = coordinator.head
      adapter = AgentCodingTool::GitHubDeliveryProvider.new
      adapter.push(workspace, "origin", "act/TASK/attempt-1", base)
      assert_equal base, git(workspace, "ls-remote", remote, "refs/heads/act/TASK/attempt-1").split.first
      git(workspace, "commit", "-qam", "different feature commit")
      changed = git(workspace, "rev-parse", "HEAD").strip
      assert_raises(AgentCodingTool::RepositoryError) do
        adapter.push(workspace, "origin", "act/TASK/attempt-1", changed)
      end
      assert_equal base, git(workspace, "ls-remote", remote, "refs/heads/main").split.first
    end
  end

  def test_live_guard_rejects_unbounded_or_unclassified_publication
    Dir.mktmpdir do |root|
      checker = File.join(root, "check")
      payload = { "independently_enforced" => true, "triggers_classified" => true,
                  "crash_surviving" => true, "assessment" => "reviewed exact triggers",
                  "commit_sha" => "a" * 40, "remaining_usd" => 5,
                  "maximum_additional_loss_usd" => 4, "expected_cost_usd" => 1,
                  "maximum_hourly_rate_usd" => 2, "maximum_runtime_seconds" => 3600,
                  "expires_at" => (Time.now.utc + 3600).iso8601 }
      File.write(checker, "#!/bin/sh\nprintf '%s\\n' '#{JSON.generate(payload)}'\n")
      File.chmod(0o700, checker)
      policy = { "trigger_assessment" => "reviewed exact triggers", "lease_check" => [checker] }
      guard = AgentCodingTool::ExternalPublicationGuard.new
      guard.verify!(policy, "git@github.com:owner/repo.git", :push, "a" * 40)
      assert_raises(AgentCodingTool::InvalidState) do
        guard.verify!(policy, "git@github.com:owner/repo.git", :push, "b" * 40)
      end
      payload["maximum_additional_loss_usd"] = 100
      File.write(checker, "#!/bin/sh\nprintf '%s\\n' '#{JSON.generate(payload)}'\n")
      assert_raises(AgentCodingTool::InvalidState) do
        guard.verify!(policy, "git@github.com:owner/repo.git", :push, "a" * 40)
      end
    end
  end
end
