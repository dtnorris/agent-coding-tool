# frozen_string_literal: true

require "open3"
require "stringio"
require_relative "../test_helper"

class PublisherTest < Minitest::Test
  def with_repo
    Dir.mktmpdir do |dir|
      bare = File.join(dir, "actd.git")
      root = File.join(dir, "actd")
      run_git(dir, "init", "--bare", "--initial-branch=main", bare)
      run_git(dir, "clone", bare, root)
      run_git(root, "config", "user.name", "ACT Test")
      run_git(root, "config", "user.email", "act@example.test")
      FileUtils.mkdir_p(File.join(root, "tasks"))
      FileUtils.mkdir_p(File.join(root, "state", "prompts"))
      File.write(File.join(root, "config.yml"), YAML.dump({
        "repo_root" => "..", "default_remote" => "origin", "default_branch" => "main",
        "publish_repository" => bare
      }))
      %w[T1 T2].each do |id|
        File.write(File.join(root, "tasks", "#{id}.yml"), YAML.dump({
          "id" => id, "title" => id, "repositories" => { "alpha" => { "access" => "write" } }
        }))
      end
      File.write(File.join(root, ".gitignore"), "ignored.txt\n")
      File.write(File.join(root, "state", "T1.yml"), "before\n")
      run_git(root, "add", "-A")
      run_git(root, "commit", "-m", "base")
      run_git(root, "push", "-u", "origin", "main")
      yield(root, bare)
    end
  end

  def publisher(root)
    AgentCodingTool::Publisher.new(
      data_root: root, config: AgentCodingTool::Config.load(File.join(root, "config.yml")),
      task_store: AgentCodingTool::TaskStore.new(File.join(root, "tasks"))
    )
  end

  def run_git(root, *args, allow_failure: false)
    out, err, status = Open3.capture3("git", *args, chdir: root)
    raise "git #{args.join(' ')}: #{err}" if !status.success? && !allow_failure

    [out, err, status]
  end

  def remote_head(root)
    run_git(root, "ls-remote", "origin", "refs/heads/main").first.split.first
  end

  def committed_paths(root)
    run_git(root, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").first.lines.map(&:strip).sort
  end

  def test_default_publishes_only_lifecycle_files_and_preserves_other_index_content
    with_repo do |root, _bare|
      File.write(File.join(root, "state", "T1.yml"), "after\n")
      File.write(File.join(root, "state", "T2.yml"), "second task\n")
      File.write(File.join(root, "state", "prompts", "T1-20261008T120000Z.txt"), "prompt\n")
      File.write(File.join(root, "tasks", "T2.yml"), "operator edit\n")
      File.write(File.join(root, "config.yml"), File.read(File.join(root, "config.yml")) + "# operator\n")
      run_git(root, "add", "tasks/T2.yml")
      before_index = run_git(root, "ls-files", "--stage", "--", "tasks/T2.yml").first

      result = publisher(root).publish(mode: :default)
      assert result.fetch(:pushed)
      assert_equal remote_head(root), result.fetch(:sha)
      assert_equal %w[state/T1.yml state/T2.yml state/prompts/T1-20261008T120000Z.txt], committed_paths(root)
      assert_equal before_index, run_git(root, "ls-files", "--stage", "--", "tasks/T2.yml").first
      assert_equal " M config.yml\nM  tasks/T2.yml\n", run_git(root, "status", "--short").first
      assert_equal false, publisher(root).publish(mode: :default).fetch(:pushed, false)
    end
  end

  def test_task_scope_and_invalid_arguments
    with_repo do |root, _bare|
      File.write(File.join(root, "state", "T1.yml"), "one\n")
      File.write(File.join(root, "state", "T2.yml"), "two\n")
      File.write(File.join(root, "state", "prompts", "T1-20261008T120000Z.txt"), "one\n")
      File.write(File.join(root, "state", "prompts", "T2-20261008T120000Z.txt"), "two\n")
      result = publisher(root).publish(mode: :task, task_id: "T1")
      assert_equal %w[state/T1.yml state/prompts/T1-20261008T120000Z.txt], result.fetch(:files)
      assert_equal result.fetch(:files), committed_paths(root)
      assert_match(/state\/T2.yml/, run_git(root, "status", "--short").first)

      assert_raises(AgentCodingTool::InvalidTask) { publisher(root).publish(mode: :task, task_id: "../T2") }
      assert_raises(AgentCodingTool::InvalidTask) { publisher(root).publish(mode: :task, task_id: "UNKNOWN") }
      out = StringIO.new
      err = StringIO.new
      cli = AgentCodingTool::CLI.new(root: root, data_root: root, out: out, err: err)
      assert_equal 2, cli.run(%w[publish --all T1])
      assert_equal 2, cli.run(%w[publish --all --all])
    end
  end

  def test_all_sweeps_tracked_untracked_staged_and_deletions_but_not_ignored
    with_repo do |root, _bare|
      File.write(File.join(root, "state", "T1.yml"), "changed\n")
      File.write(File.join(root, "tasks", "T2.yml"), "staged\n")
      run_git(root, "add", "tasks/T2.yml")
      File.delete(File.join(root, "tasks", "T1.yml"))
      File.write(File.join(root, "notes.txt"), "new\n")
      File.write(File.join(root, "ignored.txt"), "secret\n")
      result = publisher(root).publish(mode: :all)
      assert result.fetch(:pushed)
      assert_equal %w[notes.txt state/T1.yml tasks/T1.yml tasks/T2.yml], committed_paths(root)
      refute_includes run_git(root, "ls-files").first, "ignored.txt"
      assert_equal "", run_git(root, "status", "--short").first
    end
  end

  def test_all_three_dry_runs_are_read_only
    with_repo do |root, _bare|
      File.write(File.join(root, "state", "T1.yml"), "pending\n")
      File.write(File.join(root, "tasks", "T2.yml"), "staged\n")
      run_git(root, "add", "tasks/T2.yml")
      before_head = run_git(root, "rev-parse", "HEAD").first
      before_index = File.binread(File.join(root, ".git", "index"))
      before_status = run_git(root, "status", "--porcelain=v1").first
      [[:default, nil], [:task, "T1"], [:all, nil]].each do |mode, id|
        result = publisher(root).publish(mode: mode, task_id: id, dry_run: true)
        assert result.fetch(:commit_needed)
        assert_equal(mode == :all, result.fetch(:files).include?("tasks/T2.yml"))
      end
      assert_equal before_head, run_git(root, "rev-parse", "HEAD").first
      assert_equal before_head.strip, remote_head(root)
      assert_equal before_index, File.binread(File.join(root, ".git", "index"))
      assert_equal before_status, run_git(root, "status", "--porcelain=v1").first
    end
  end

  def test_partial_staging_of_selected_file_blocks_narrow_publication
    with_repo do |root, _bare|
      File.write(File.join(root, "state", "T1.yml"), "staged\n")
      run_git(root, "add", "state/T1.yml")
      File.write(File.join(root, "state", "T1.yml"), "working\n")
      before = run_git(root, "ls-files", "--stage", "--", "state/T1.yml").first
      preview = publisher(root).publish(mode: :default, dry_run: true)
      assert_match(/different staged and working-tree/, preview.fetch(:blocker))
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
      assert_equal before, run_git(root, "ls-files", "--stage", "--", "state/T1.yml").first
    end
  end

  def test_identity_branch_divergence_and_unpublished_history_fail_closed
    with_repo do |root, bare|
      File.write(File.join(root, "state", "T1.yml"), "pending\n")
      File.write(File.join(root, "config.yml"), File.read(File.join(root, "config.yml")).sub(bare, "/tmp/unexpected.git"))
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
      File.write(File.join(root, "config.yml"), File.read(File.join(root, "config.yml")).sub("/tmp/unexpected.git", bare))
      run_git(root, "checkout", "-b", "other")
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
      run_git(root, "checkout", "main")
      run_git(root, "commit", "--allow-empty", "-m", "unrelated local")
      assert_match(/existing commits require operator review/,
                   assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }.message)
      run_git(root, "reset", "--hard", "HEAD^")
      run_git(root, "commit", "--allow-empty", "-m", "remote change")
      run_git(root, "push", "origin", "main")
      run_git(root, "reset", "--hard", "HEAD^")
      File.write(File.join(root, "state", "T1.yml"), "pending again\n")
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
    end
  end

  def test_push_failure_preserves_commit_and_retry_is_idempotent
    with_repo do |root, bare|
      File.write(File.join(root, "state", "T1.yml"), "pending\n")
      hook = File.join(bare, "hooks", "pre-receive")
      File.write(hook, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, hook)
      error = assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
      local = run_git(root, "rev-parse", "HEAD").first.strip
      assert_includes error.message, local
      refute_equal local, remote_head(root)
      assert publisher(root).publish(mode: :default, dry_run: true).fetch(:push_needed)
      File.delete(hook)
      retry_result = publisher(root).publish(mode: :default)
      assert_equal local, retry_result.fetch(:sha)
      assert_equal ["state/T1.yml"], retry_result.fetch(:files)
      assert_equal local, remote_head(root)
      assert_equal false, publisher(root).publish(mode: :default).fetch(:pushed, false)
    end
  end

  def test_interruption_after_commit_can_retry_without_new_commit
    with_repo do |root, _bare|
      File.write(File.join(root, "state", "T1.yml"), "pending\n")
      instance = publisher(root)
      instance.define_singleton_method(:push_and_verify!) do |_remote, _branch, _sha|
        raise AgentCodingTool::RepositoryError, "injected interruption"
      end
      error = assert_raises(AgentCodingTool::RepositoryError) { instance.publish(mode: :default) }
      local = run_git(root, "rev-parse", "HEAD").first.strip
      assert_includes error.message, local
      refute_equal local, remote_head(root)
      assert_equal local, publisher(root).publish(mode: :default).fetch(:sha)
      assert_equal local, remote_head(root)
      assert_equal "2\n", run_git(root, "rev-list", "--count", "HEAD").first
    end
  end

  def test_default_includes_deletion_and_preserves_unrelated_staging
    with_repo do |root, _bare|
      File.write(File.join(root, "state", "prompts", "T1-20261008T120000Z.txt"), "old\n")
      run_git(root, "add", "-A")
      run_git(root, "commit", "-m", "prompt base")
      run_git(root, "push", "origin", "main")
      File.delete(File.join(root, "state", "prompts", "T1-20261008T120000Z.txt"))
      File.write(File.join(root, "tasks", "T2.yml"), "staged unrelated\n")
      run_git(root, "add", "tasks/T2.yml")
      result = publisher(root).publish(mode: :default)
      assert result.fetch(:pushed)
      assert_equal ["state/prompts/T1-20261008T120000Z.txt"], committed_paths(root)
      assert_includes run_git(root, "status", "--short").first, "M  tasks/T2.yml"
    end
  end

  def test_commit_failure_does_not_claim_publication
    with_repo do |root, _bare|
      prompt = File.join(root, "state", "prompts", "T1-20261008T120000Z.txt")
      File.write(prompt, "pending\n")
      before = run_git(root, "rev-parse", "HEAD").first.strip
      hook = File.join(root, ".git", "hooks", "pre-commit")
      File.write(hook, "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, hook)
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
      assert_equal before, run_git(root, "rev-parse", "HEAD").first.strip
      assert_equal before, remote_head(root)
      assert_includes run_git(root, "status", "--short").first, "?? state/prompts/"
    end
  end

  def test_detached_missing_remote_and_dry_run_blocker
    with_repo do |root, _bare|
      File.write(File.join(root, "state", "T1.yml"), "pending\n")
      run_git(root, "checkout", "--detach")
      assert_match(/detached HEAD/, publisher(root).publish(mode: :default, dry_run: true).fetch(:blocker))
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
      run_git(root, "checkout", "main")
      run_git(root, "remote", "remove", "origin")
      assert_match(/git remote failed/, publisher(root).publish(mode: :default, dry_run: true).fetch(:blocker))
    end
  end

  def test_all_rejects_untracked_nested_git_checkout
    with_repo do |root, _bare|
      nested = File.join(root, "nested")
      run_git(root, "init", nested)
      File.write(File.join(nested, "file"), "nested\n")
      preview = publisher(root).publish(mode: :all, dry_run: true)
      assert_match(/nested Git checkout/, preview.fetch(:blocker))
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :all) }
      assert_equal remote_head(root), run_git(root, "rev-parse", "HEAD").first.strip
    end
  end

  def test_lifecycle_command_remains_local_until_explicit_publish
    with_repo do |root, _bare|
      old_remote = remote_head(root)
      out = StringIO.new
      err = StringIO.new
      cli = AgentCodingTool::CLI.new(root: root, data_root: root, out: out, err: err)
      assert_equal 0, cli.run(%w[reset T1])
      assert_equal old_remote, remote_head(root)
      assert_equal 0, cli.run(%w[publish T1])
      assert_includes out.string, "PUBLISHED:"
      refute_equal old_remote, remote_head(root)
    end
  end

  def test_parallel_publish_calls_serialize_and_do_not_duplicate_commit
    with_repo do |root, _bare|
      File.write(File.join(root, "state", "T1.yml"), "pending\n")
      ready = Queue.new
      threads = Array.new(2) do
        Thread.new do
          ready.pop
          publisher(root).publish(mode: :default)
        end
      end
      2.times { ready << true }
      results = threads.map(&:value)
      assert_equal 1, results.count { |result| result[:pushed] }
      assert_equal remote_head(root), run_git(root, "rev-parse", "HEAD").first.strip
      assert_equal 2, run_git(root, "rev-list", "--count", "HEAD").first.to_i
    end
  end

  def test_cli_dry_run_all_reports_scope_without_publication
    with_repo do |root, _bare|
      File.write(File.join(root, "tasks", "T1.yml"), "draft\n")
      out = StringIO.new
      err = StringIO.new
      cli = AgentCodingTool::CLI.new(root: root, data_root: root, out: out, err: err)
      old = remote_head(root)
      assert_equal 0, cli.run(%w[publish --all --dry-run])
      assert_includes out.string, "DRY RUN (no changes made)"
      assert_includes out.string, "tasks/T1.yml"
      assert_includes out.string, "Commit needed: true"
      assert_includes out.string, "Remote publication was not attempted."
      assert_equal old, remote_head(root)
      assert_empty err.string
    end
  end

  def test_ssh_https_identity_normalization_and_unsupported_remote
    with_repo do |root, bare|
      instance = publisher(root)
      assert_equal "dtnorris/agent-coding-tool-data",
                   instance.send(:identity, "git@github.com:dtnorris/agent-coding-tool-data.git")
      assert_equal "dtnorris/agent-coding-tool-data",
                   instance.send(:identity, "https://github.com/dtnorris/agent-coding-tool-data.git")
      assert_equal "file://#{File.realpath(bare)}", instance.send(:identity, bare)
      assert_raises(AgentCodingTool::RepositoryError) { instance.send(:identity, "https://example.com/other") }
    end
  end

  def test_unexpected_push_destination_fails_before_git_mutation
    with_repo do |root, _bare|
      other = File.join(File.dirname(root), "other.git")
      run_git(File.dirname(root), "init", "--bare", other)
      run_git(root, "remote", "set-url", "--push", "origin", other)
      File.write(File.join(root, "state", "T1.yml"), "pending\n")
      old = run_git(root, "rev-parse", "HEAD").first.strip
      assert_match(/exactly one push destination/, publisher(root).publish(mode: :default, dry_run: true).fetch(:blocker))
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
      assert_equal old, run_git(root, "rev-parse", "HEAD").first.strip
      refute File.exist?(File.join(root, ".git", "act-publish.lock"))
    end
  end

  def test_rename_crossing_narrow_scope_blocks_but_all_accepts
    with_repo do |root, _bare|
      run_git(root, "mv", "state/T1.yml", "notes.yml")
      assert_match(/renamed selected file/, publisher(root).publish(mode: :default, dry_run: true).fetch(:blocker))
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
      result = publisher(root).publish(mode: :all)
      assert_equal %w[notes.yml state/T1.yml], result.fetch(:files)
      assert_equal result.fetch(:files), committed_paths(root)
    end
  end

  def test_status_is_read_only_and_repository_operation_blocks_publish
    with_repo do |root, _bare|
      File.write(File.join(root, "state", "T1.yml"), YAML.dump({ "id" => "T1" }))
      before = remote_head(root)
      index = File.binread(File.join(root, ".git", "index"))
      out = StringIO.new
      cli = AgentCodingTool::CLI.new(root: root, data_root: root, out: out, err: StringIO.new)
      assert_equal 0, cli.run(%w[status T1])
      assert_equal before, remote_head(root)
      assert_equal index, File.binread(File.join(root, ".git", "index"))

      File.write(File.join(root, ".git", "MERGE_HEAD"), before + "\n")
      preview = publisher(root).publish(mode: :default, dry_run: true)
      assert_match(/MERGE_HEAD/, preview.fetch(:blocker))
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
      assert_equal before, remote_head(root)
    end
  end

  def test_remote_push_race_preserves_local_commit_without_reconciliation
    with_repo do |root, bare|
      other = File.join(File.dirname(root), "other")
      run_git(File.dirname(root), "clone", bare, other)
      run_git(other, "config", "user.name", "Other")
      run_git(other, "config", "user.email", "other@example.test")
      File.write(File.join(root, "state", "T1.yml"), "local\n")
      instance = publisher(root)
      tester = self
      instance.define_singleton_method(:push_and_verify!) do |remote, branch, sha|
        File.write(File.join(other, "remote.txt"), "intervening\n")
        tester.run_git(other, "add", "remote.txt")
        tester.run_git(other, "commit", "-m", "intervening")
        tester.run_git(other, "push", "origin", "main")
        super(remote, branch, sha)
      end
      error = assert_raises(AgentCodingTool::RepositoryError) { instance.publish(mode: :default) }
      local = run_git(root, "rev-parse", "HEAD").first.strip
      assert_includes error.message, local
      refute_equal local, remote_head(root)
      assert_match(/existing commits require operator review/,
                   assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }.message)
    end
  end
end
