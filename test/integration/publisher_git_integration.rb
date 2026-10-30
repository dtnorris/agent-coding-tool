# frozen_string_literal: true

require "open3"
require "stringio"
require_relative "../test_helper"

# Physical publication oracles; policy/string permutations use strict ordinary
# observations in publisher_test.rb rather than constructing another Git world.
class PublisherTest < Minitest::Test
  def with_repo
    Dir.mktmpdir do |dir|
      # Keep native fixtures canonical when macOS spells TMPDIR through /var.
      dir = File.realpath(dir)
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

  # Dry-run selection excludes incidental metadata without publication; tracked
  # and staged metadata retain normal selection and dirty-state observations.
  def test_metadata_selection_and_repository_inspection
    with_repo do |root, _bare|
      root = File.realpath(root)
      run_git(root, "config", "core.excludesFile", File::NULL)
      nested = File.join(root, "space\ncontrol")
      FileUtils.mkdir_p(nested)
      paths = [File.join(root, ".DS_Store"), File.join(nested, ".DS_Store")]
      paths.each { |path| File.binwrite(path, "Finder\x00\xff".b) }
      config = AgentCodingTool::Config.load(File.join(root, "config.yml"))
      inspector = AgentCodingTool::RepoInspector.new(config)
      spec = { "path" => root, "access" => "write" }
      refute inspector.snapshot("data", spec).fetch("local_dirty")
      result = publisher(root).publish(mode: :all, dry_run: true)
      assert_empty result.fetch(:files)
      run_git(root, "add", "--", ".DS_Store")
      assert inspector.snapshot("data", spec).fetch("local_dirty")
      assert_equal [".DS_Store"], publisher(root).publish(mode: :all, dry_run: true).fetch(:files)
      paths.each { |path| assert_equal "Finder\x00\xff".b, File.binread(path) }
      assert_equal "A\0.DS_Store\0", run_git(root, "diff", "--cached", "--name-status", "-z").first
    end
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

  # Publishes modified, new and deleted lifecycle paths to a local fixture remote;
  # asserts exact commit scope and unrelated index bytes. Fixture failures raise.
  def test_default_publishes_only_lifecycle_files_and_preserves_other_index_content
    with_repo do |root, _bare|
      deleted = "state/prompts/T1-20261007T120000Z.txt"
      File.write(File.join(root, deleted), "old prompt\n")
      run_git(root, "add", "--", deleted)
      run_git(root, "commit", "-m", "prompt base")
      run_git(root, "push", "origin", "main")
      File.delete(File.join(root, deleted))
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
      assert_equal ["state/T1.yml", "state/T2.yml", deleted, "state/prompts/T1-20261008T120000Z.txt"], committed_paths(root)
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

  # Public publish selections never see external records in their private sibling.
  # Sentinels remain absent from selected bytes/prompts/state; dry runs preserve
  # the real disposable index, HEAD, refs, files and observation timestamps.
  def test_external_observations_are_structurally_outside_all_public_selections
    with_repo do |root, _bare|
      File.unlink(File.join(root, "state", "T1.yml"))
      config = AgentCodingTool::Config.load(File.join(root, "config.yml"))
      activity = AgentCodingTool::ExternalActivity.new(data_root: root,
        task_store: AgentCodingTool::TaskStore.new(File.join(root, "tasks")),
        state_store: AgentCodingTool::StateStore.new(File.join(root, "state")),
        repo_inspector: TestHelpers::FakeInspector.new(heads: { "alpha" => "a" * 40 }))
      document = activity.report("T1", reporter: "operator", kind: "fake",
        identifier: "SECRET-IDENTIFIER", note: "SECRET-NOTE", reference: "/private/SECRET-PATH", scope_complete: true)
      id = document.fetch("active").fetch("observation_id")
      [false, true].each do |ended|
        activity.end_activity("T1", id, disposition: "ended") if ended
        before = Dir.glob(File.join(File.dirname(root), "**", "*"), File::FNM_DOTMATCH)
                    .select { |path| File.file?(path) }.to_h { |path| [path, [Digest::SHA256.file(path).hexdigest, File.mtime(path)]] }
        [[], ["T1"], ["--all"]].each do |arguments|
          output, error = StringIO.new, StringIO.new
          assert_equal 0, AgentCodingTool::CLI.run(["publish", *arguments, "--dry-run"], root: root, data_root: root, out: output, err: error), error.string
          %w[SECRET-IDENTIFIER SECRET-NOTE /private/SECRET-PATH external-activity].each { |sentinel| refute_includes output.string, sentinel }
          selection = publisher(root).publish(mode: arguments == ["--all"] ? :all : arguments.empty? ? :default : :task,
                                              task_id: arguments == ["T1"] ? "T1" : nil, dry_run: true)
          selection.fetch(:files).each do |path|
            next unless File.file?(File.join(root, path))
            %w[SECRET-IDENTIFIER SECRET-NOTE /private/SECRET-PATH].each { |sentinel| refute_includes File.binread(File.join(root, path)), sentinel }
          end
        end
        before.each { |path, value| assert_equal value, [Digest::SHA256.file(path).hexdigest, File.mtime(path)], path }
        assert_equal document.fetch("active").fetch("observation_id"), id
      end
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

  # An actual rejecting hook leaves the committed SHA available for retry;
  # the accepted retry must publish it without a third commit. Git failures raise.
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
      assert_equal "2\n", run_git(root, "rev-list", "--count", "HEAD").first
      assert_equal false, publisher(root).publish(mode: :default).fetch(:pushed, false)
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
      # Give reset valid state with a value to clear locally.
      File.write(File.join(root, "state", "T1.yml"), YAML.dump({
        "id" => "T1", "note" => "before reset"
      }))
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

  def test_rename_crossing_narrow_scope_blocks_but_all_accepts
    with_repo do |root, _bare|
      metadata = File.join(root, ".DS_Store")
      File.binwrite(metadata, "Finder\x00\xff".b)
      run_git(root, "mv", "state/T1.yml", "notes.yml")
      assert_match(/renamed selected file/, publisher(root).publish(mode: :default, dry_run: true).fetch(:blocker))
      assert_raises(AgentCodingTool::RepositoryError) { publisher(root).publish(mode: :default) }
      result = publisher(root).publish(mode: :all)
      assert_equal %w[notes.yml state/T1.yml], result.fetch(:files)
      assert_equal result.fetch(:files), committed_paths(root)
      assert_equal "Finder\x00\xff".b, File.binread(metadata)
      assert_empty run_git(root, "ls-files", "--", ".DS_Store").first
    end
    # An already staged deletion has no remaining path for git add. Its exact
    # deletion still belongs in the commit; incidental metadata stays untouched.
    with_repo do |root, _bare|
      metadata = File.join(root, ".DS_Store")
      File.binwrite(metadata, "Finder\x00\xff".b)
      run_git(root, "rm", "state/T1.yml")
      result = publisher(root).publish(mode: :all)
      assert_equal ["state/T1.yml"], result.fetch(:files)
      assert_equal result.fetch(:files), committed_paths(root)
      assert_equal "Finder\x00\xff".b, File.binread(metadata)
      assert_empty run_git(root, "ls-files", "--", ".DS_Store").first
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
