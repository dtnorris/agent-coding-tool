# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "open3"

class MultiDeliveryGitIntegration < Minitest::Test
  class Provider
    attr_reader :pushes, :prs
    attr_accessor :fail_remote, :integrations

    def initialize
      @refs, @prs, @pushes, @integrations = {}, {}, [], {}
    end

    def branch(remote, branch) = @refs[[remote, branch]]
    def set_branch(remote, branch, sha) = @refs[[remote, branch]] = sha
    def push(workspace, remote_name, branch, sha)
      remote, _err, status = Open3.capture3("git", "remote", "get-url", remote_name, chdir: workspace)
      raise "missing fixture remote" unless status.success?
      remote = remote.strip
      @refs[[remote, branch]] = sha
      @pushes << remote
      raise AgentCodingTool::RepositoryError, "lost push response" if remote == @fail_remote
    end
    def pull_requests(remote, branch) = @prs.fetch([remote, branch], [])
    def create_draft(remote, branch, base, _title, body)
      number = @prs.length + 1
      @prs[[remote, branch]] = [{ "url" => "https://github.com/example/repo#{number}/pull/#{number}",
        "state" => "open", "draft" => true, "head" => branch_sha(remote, branch),
        "base" => base, "body" => body }]
    end
    def update_body(remote, url, body)
      pr = @prs.values.flatten.find { |item| item["url"] == url }
      pr["body"] = body
    end
    def branch_sha(remote, branch) = @refs.fetch([remote, branch])
    def integration(_remote, url) = @integrations[url]
  end

  class Guard
    attr_reader :checks
    def initialize = @checks = []
    def verify!(_policy, remote, stage, commit) = @checks << [remote, stage, commit]
  end

  class Coordinator
    attr_accessor :heads
    def initialize(data, snapshot) = (@data, @snapshot = data, snapshot)
    def launch_heads(_id) = heads || @snapshot.transform_values { |repo| repo.slice("remote_url", "branch", "pushed_sha") }
    # Records synthetic candidate details using the delivery-owned reservation.
    # Returns bytes written; invalid/busy borrowed locks raise InvalidState.
    def record(id, outcome:, summary:, artifact:, tests:, reservation_lock:)
      AgentCodingTool::ReservationLock.synchronize(@data, held: reservation_lock) do
        store = AgentCodingTool::StateStore.new(File.join(@data, "state"))
        state = store.load(id)
        state["result"] = { "outcome" => outcome, "summary" => summary, "artifact" => artifact, "tests" => tests }
        state.delete("started_at")
        store.write(id, state)
      end
    end
  end

  class ClearLiveness
    def check(_report, _inventory) = :clear
  end

  class UnknownLiveness
    def check(_report, _inventory) = :unknown
  end

  def git(directory, *args)
    output, err, status = Open3.capture3("git", *args, chdir: directory)
    raise "fixture Git: #{err}" unless status.success?
    output.strip
  end

  def fixture(fail_second: false, change_beta: true)
    Dir.mktmpdir("act-multi-delivery-") do |temporary|
      root = File.realpath(temporary)
      data = File.join(root, "data")
      run = File.join("#{data}-runs", "TASK", "attempt")
      validation = "#{data}-validation"
      [File.join(data, "tasks"), File.join(data, "state"), run, validation].each { |path| FileUtils.mkdir_p(path) }
      File.chmod(0o700, validation)
      File.chmod(0o700, "#{data}-runs")
      visible = File.join(root, "ACT-Worktrees")
      File.write(File.join(data, "config.yml"), YAML.dump("worktree_root" => visible))
      repositories, snapshot = {}, {}
      %w[alpha beta reader].each do |name|
        ordinary = File.join(root, name)
        remote = File.join(root, "#{name}.git")
        git(root, "init", "-q", "--bare", remote)
        git(root, "init", "-q", "-b", "main", ordinary)
        git(ordinary, "config", "user.name", "Test")
        git(ordinary, "config", "user.email", "test@example.invalid")
        File.write(File.join(ordinary, "file.txt"), "before\n")
        git(ordinary, "add", "file.txt")
        git(ordinary, "commit", "-qm", "base")
        base = git(ordinary, "rev-parse", "HEAD")
        git(ordinary, "remote", "add", "origin", remote)
        git(ordinary, "push", "-q", "origin", "main")
        repositories[name] = { "access" => name == "reader" ? "read_only" : "write" }
        snapshot[name] = { "path" => ordinary, "remote" => "origin", "remote_url" => remote,
                           "branch" => "main", "pushed_sha" => base }
      end
      task = { "id" => "TASK", "title" => "Coordinated change", "repositories" => repositories }
      File.write(File.join(data, "tasks", "TASK.yml"), YAML.dump(task))
      AgentCodingTool::StateStore.new(File.join(data, "state")).write("TASK",
        { "id" => "TASK", "snapshot" => snapshot, "started_at" => Time.now.utc.iso8601 })
      policy = %w[alpha beta].to_h do |name|
        command = name == "beta" && fail_second ? ["ruby", "-e", "exit 1"] :
          ["ruby", "-e", "puts '2 tests, 3 assertions, 0 failures, 0 errors, 0 skips'"]
        [name, { "allowed_paths" => ["file.txt"], "base_branch" => "main",
                 "commands" => [command], "max_seconds" => 30, "min_tests" => 2,
                 "min_assertions" => 3, "publication_guard" => { "lease_check" => "/fake",
                   "trigger_assessment" => "fixture" } }]
      end
      contract = { "repositories" => policy,
                   "cross_repository_checks" => [
                     { "cwd" => "alpha", "argv" => ["ruby", "-e",
                       "puts '2 tests, 3 assertions, 0 failures, 0 errors, 0 skips'",
                       "{worktree:reader}"] }] }
      File.write(File.join(validation, "TASK.yml"), YAML.dump(contract))
      inventory = AgentCodingTool::WorktreeManager.new(root: visible,
        record_path: File.join(run, "worktrees.json")).create(
          task_id: "TASK", attempt: 1, task: task, snapshot: snapshot)
      paths = inventory.fetch("entries").select { |entry| entry["access"] == "write" }.to_h {
        |entry| [entry.fetch("name"), entry.fetch("path")] }
      paths.each do |name, path|
        File.write(File.join(path, "file.txt"), "changed #{name}\n") if name != "beta" || change_beta
      end
      report = { "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "TASK",
        "attempt" => 1, "status" => "exited", "exit_status" => 0, "final_valid" => true,
        "writable_freshness" => "fresh_at_exit", "writable_repository" => "alpha",
        "writable_repositories" => %w[alpha beta], "workspaces" => paths,
        "workspace" => paths.fetch("alpha"), "preparation" => snapshot,
        "worktrees" => inventory, "worktrees_path" => File.join(run, "worktrees.json") }
      report["artifacts"] = %w[prompt_path stdin_path jsonl_path stderr_path final_path].map do |key|
        path = File.join(run, key)
        File.write(path, "host evidence\n")
        report[key] = path
        { "path" => path, "sha256" => Digest::SHA256.file(path).hexdigest, "bytes" => File.size(path) }
      end
      File.write(File.join(run, "handoff.json"), JSON.generate(report))
      provider = Provider.new
      guard = Guard.new
      manager = AgentCodingTool::DeliveryManager.new(data_root: data,
        coordinator: Coordinator.new(data, snapshot), provider: provider, guard: guard)
      yield manager, provider, data, run, paths, snapshot, guard
    end
  end

  def test_two_writers_validate_publish_cross_link_and_resume
    fixture do |manager, provider, data, run, paths, snapshot, guard|
      result = manager.deliver("TASK", run_dir: run)
      assert_equal "draft_pr", result.fetch("stage")
      assert_equal %w[alpha beta].sort, result.fetch("prs").keys.sort
      assert_equal 2, provider.pushes.length
      assert_equal 2, guard.checks.count { |_remote, stage, _commit| stage == :push }
      assert_equal 4, guard.checks.count { |_remote, stage, _commit| stage == :pr }
      assert_equal 2, guard.checks.select { |_remote, stage, _commit| stage == :push }.map(&:first).uniq.length
      assert_equal snapshot.fetch("reader").fetch("pushed_sha"),
                   git(File.join(File.dirname(paths.fetch("alpha")), "reader"), "rev-parse", "HEAD")
      urls = result.fetch("prs").values.map { |pr| pr.fetch("url") }
      assert urls.all? { |url| provider.prs.values.flatten.find { |pr| pr["url"] != url && pr["body"].include?(url) } }
      assert_equal "candidate_complete", AgentCodingTool::StateStore.new(File.join(data, "state")).load("TASK").dig("result", "outcome")
      assert_equal result, manager.deliver("TASK", run_dir: run)
      assert_equal 2, provider.pushes.length
      assert_equal "changed beta", git(paths.fetch("beta"), "show", "HEAD:file.txt")
      report = JSON.parse(File.binread(File.join(run, "handoff.json")))
      expected_heads = paths.transform_values { |path| git(path, "rev-parse", "HEAD") }
      assert_equal expected_heads, manager.verified_delivery_heads("TASK", report, run)
      log = File.join(run, "cross-repository", "validation-0.stdout")
      original = File.binread(log)
      begin
        File.binwrite(log, "altered cross-check")
        assert_raises(AgentCodingTool::InvalidState) { manager.verified_delivery_heads("TASK", report, run) }
        assert_equal 2, provider.pushes.length
      ensure
        File.binwrite(log, original)
      end
    end
  end

  def test_second_validation_failure_publishes_nothing
    fixture(fail_second: true) do |manager, provider, _data, run, _paths, _snapshot|
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run) }
      assert_empty provider.pushes
      assert_empty provider.prs
    end
  end

  def test_unchanged_writer_requires_no_pr_and_can_be_cleaned
    fixture(change_beta: false) do |manager, provider, data, run, paths, snapshot|
      delivered = manager.deliver("TASK", run_dir: run)
      assert_equal ["alpha"], delivered.fetch("prs").keys
      assert_equal "unchanged", JSON.parse(File.binread(File.join(run, "repositories", "beta", "delivery.json"))).fetch("stage")
      state_store = AgentCodingTool::StateStore.new(File.join(data, "state"))
      state = state_store.load("TASK")
      state["result"]["outcome"] = "complete"
      state_store.write("TASK", state)
      ordinary = snapshot.fetch("alpha").fetch("path")
      File.write(File.join(ordinary, "file.txt"), File.binread(File.join(paths.fetch("alpha"), "file.txt")))
      git(ordinary, "add", "file.txt")
      git(ordinary, "commit", "-qm", "squash")
      pr = delivered.fetch("prs").fetch("alpha")
      provider.integrations[pr.fetch("url")] = { "merged" => true, "head" => pr.fetch("head"),
        "base" => "main", "merge_commit_sha" => git(ordinary, "rev-parse", "HEAD") }
      handler = AgentCodingTool::CleanupManager.new(data_root: data, provider: provider, liveness: ClearLiveness.new)
      assert_equal false, handler.preflight("TASK").fetch("blocked")
      assert_equal false, handler.remove("TASK").fetch("blocked")
      assert_equal false, File.exist?(paths.fetch("beta"))
    end
  end

  def test_lost_push_response_recovers_without_duplicate_push
    fixture do |manager, provider, data, run, _paths, snapshot|
      provider.fail_remote = snapshot.fetch("beta").fetch("remote_url")
      assert_raises(AgentCodingTool::RepositoryError) { manager.deliver("TASK", run_dir: run) }
      assert_equal 2, provider.pushes.length
      assert_nil AgentCodingTool::StateStore.new(File.join(data, "state")).load("TASK")["result"]
      provider.fail_remote = nil
      assert_equal "draft_pr", manager.deliver("TASK", run_dir: run).fetch("stage")
      assert_equal 2, provider.pushes.length
    end
  end

  def test_moved_authority_and_competing_feature_ref_block_publication
    fixture do |manager, provider, _data, run, _paths, snapshot|
      coordinator = manager.instance_variable_get(:@coordinator)
      heads = coordinator.launch_heads("TASK")
      heads.fetch("beta")["pushed_sha"] = "f" * 40
      coordinator.heads = heads
      error = assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run) }
      assert_includes error.message, "STALE INPUT"
      assert_empty provider.pushes
    end
    fixture do |manager, provider, _data, run, _paths, snapshot|
      provider.set_branch(snapshot.fetch("alpha").fetch("remote_url"), "act/TASK/attempt-1", "f" * 40)
      error = assert_raises(AgentCodingTool::InvalidState) { manager.deliver("TASK", run_dir: run) }
      assert_includes error.message, "competing feature ref"
      assert_empty provider.pushes
    end
  end

  def test_squash_integration_cleanup_refusals_and_interrupted_resume
    fixture do |manager, provider, data, run, paths, snapshot|
      delivered = manager.deliver("TASK", run_dir: run)
      store = AgentCodingTool::StateStore.new(File.join(data, "state"))
      state = store.load("TASK")
      state["result"]["outcome"] = "complete"
      store.write("TASK", state)
      paths.each do |name, workspace|
        ordinary = snapshot.fetch(name).fetch("path")
        File.write(File.join(ordinary, "file.txt"), File.binread(File.join(workspace, "file.txt")))
        git(ordinary, "add", "file.txt")
        git(ordinary, "commit", "-qm", "squash integration")
        pr = delivered.fetch("prs").fetch(name)
        provider.integrations[pr.fetch("url")] = { "merged" => true, "head" => pr.fetch("head"),
          "base" => "main", "merge_commit_sha" => git(ordinary, "rev-parse", "HEAD") }
      end
      handler = AgentCodingTool::CleanupManager.new(data_root: data, provider: provider, liveness: ClearLiveness.new)
      before = File.binread(File.join(run, "worktrees.json"))
      parent = snapshot.fetch("alpha").fetch("path")
      ordinary_before = [git(parent, "rev-parse", "HEAD"), git(parent, "status", "--porcelain"),
                         git(parent, "worktree", "list", "--porcelain"),
                         File.stat(File.join(parent, ".git", "index")).mtime]
      assert_equal false, handler.preflight("TASK").fetch("blocked")
      assert_equal before, File.binread(File.join(run, "worktrees.json"))
      assert_equal ordinary_before.last, File.stat(File.join(parent, ".git", "index")).mtime
      assert_equal ordinary_before.first(3),
                   [git(parent, "rev-parse", "HEAD"), git(parent, "status", "--porcelain"),
                    git(parent, "worktree", "list", "--porcelain")]
      File.write(File.join(paths.fetch("beta"), "keep"), "operator")
      assert_includes handler.preflight("TASK").fetch("attempts").find { |row|
        row["repository"] == "beta" }.fetch("blockers"), "worktree contains changes"
      assert_raises(AgentCodingTool::InvalidState) { handler.remove("TASK") }
      File.unlink(File.join(paths.fetch("beta"), "keep"))
      first = true
      interrupted = AgentCodingTool::CleanupManager.new(data_root: data, provider: provider,
        liveness: ClearLiveness.new, after_removal: ->(_entry) {
          if first
            first = false
            raise "simulated interruption"
          end
        })
      assert_raises(RuntimeError) { interrupted.remove("TASK") }
      assert_equal false, File.exist?(paths.fetch("alpha"))
      assert File.directory?(paths.fetch("beta"))
      assert_equal false, handler.preflight("TASK").fetch("blocked")
      assert_equal false, handler.remove("TASK").fetch("blocked")
      assert_equal false, File.exist?(paths.fetch("beta"))
      assert File.file?(File.join(run, "repositories", "alpha", "delivery.json"))
      assert File.file?(File.join(run, "handoff.json"))
    end
  end

  def test_cleanup_refuses_unmerged_unsynchronized_unknown_and_foreign
    fixture do |manager, provider, data, run, paths, snapshot|
      delivered = manager.deliver("TASK", run_dir: run)
      store = AgentCodingTool::StateStore.new(File.join(data, "state"))
      state = store.load("TASK")
      state["result"]["outcome"] = "complete"
      store.write("TASK", state)
      handler = AgentCodingTool::CleanupManager.new(data_root: data, provider: provider, liveness: ClearLiveness.new)
      assert_includes handler.preflight("TASK").fetch("attempts").first.fetch("blockers"),
                      "PR not verifiably merged into authorized target"
      paths.each do |name, workspace|
        pr = delivered.fetch("prs").fetch(name)
        provider.integrations[pr.fetch("url")] = { "merged" => true, "head" => pr.fetch("head"),
          "base" => "main", "merge_commit_sha" => git(workspace, "rev-parse", "HEAD") }
      end
      assert_includes handler.preflight("TASK").fetch("attempts").first.fetch("blockers"),
                      "ordinary checkout has not integrated PR result"
      paths.each do |name, workspace|
        ordinary = snapshot.fetch(name).fetch("path")
        File.write(File.join(ordinary, "file.txt"), File.binread(File.join(workspace, "file.txt")))
        git(ordinary, "add", "file.txt")
        git(ordinary, "commit", "-qm", "squash")
        provider.integrations[delivered.fetch("prs").fetch(name).fetch("url")]["merge_commit_sha"] =
          git(ordinary, "rev-parse", "HEAD")
      end
      unknown = AgentCodingTool::CleanupManager.new(data_root: data, provider: provider,
        liveness: UnknownLiveness.new)
      assert_includes unknown.preflight("TASK").fetch("attempts").first.fetch("blockers"), "worker liveness unknown"
      foreign = File.join(File.dirname(paths.fetch("alpha")), "unexpected")
      File.write(foreign, "operator")
      assert handler.preflight("TASK").fetch("blocked")
      assert_includes handler.preflight("TASK").fetch("attempts").last.fetch("blockers").first,
                      "foreign task path entries"
      assert_raises(AgentCodingTool::InvalidState) { handler.remove("TASK") }
      assert File.file?(foreign)
    end
  end
end
