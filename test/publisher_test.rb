# frozen_string_literal: true

require "stringio"
require_relative "test_helper"
require_relative "publisher_observations"

# Production decisions with strict observations; real index/commit/ref effects
# remain mandatory in the separately executed publisher_git_integration.rb.
class PublisherTest < Minitest::Test
  include TestHelpers
  include PublisherObservations

  # Creates task/filesystem inputs only; errors propagate and no processes run.
  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, ".git"))
    FileUtils.mkdir_p(File.join(@root, "tasks"))
    FileUtils.mkdir_p(File.join(@root, "state", "prompts"))
    %w[T1 T2].each { |id| write_task(@root, id: id) }
    @config = AgentCodingTool::Config.load(File.join(@root, "config.yml"))
    @replays = []
  end

  # Checks complete consumption even after refusals; always removes owned files.
  # Missing observations raise UnexpectedObservation rather than passing silently.
  def teardown
    @replays.each(&:verify!)
  ensure
    FileUtils.remove_entry(@root)
  end

  # Returns the real Publisher with fixture inputs and a required strict runner.
  def publisher(runner:)
    AgentCodingTool::Publisher.new(data_root: @root, config: @config,
      task_store: AgentCodingTool::TaskStore.new(File.join(@root, "tasks")), runner: runner)
  end

  # Default scope excludes unrelated staging and observes a no-op after success.
  def test_default_selects_lifecycle_state_and_prompts_only
    files = %w[state/T1.yml state/T2.yml state/prompts/T1-20261008T120000Z.txt]
    status = " M state/T1.yml\0D  state/T2.yml\0?? state/prompts/T1-20261008T120000Z.txt\0M  tasks/T2.yml\0 M config.yml\0?? notes.txt\0"
    expect_git([*publication_observations(status: status, scope_paths: files),
      *commit_observations(files, untracked: [files.last]), *push_observations])
    result = @publisher.publish(mode: :default)
    assert result.fetch(:pushed)
    assert_equal files, result.fetch(:files)
    assert_equal COMMIT, result.fetch(:sha)
    remaining = " M config.yml\0?? notes.txt\0M  tasks/T2.yml\0"
    expect_git(publication_observations(status: remaining, scope_paths: [], head: COMMIT, remote_head: COMMIT))
    refute @publisher.publish(mode: :default).fetch(:pushed, false)
  end

  # Task scope excludes other tasks and prompts without a timestamp.
  def test_task_scope_selects_own_state_and_timestamped_prompts
    files = %w[state/T1.yml state/prompts/T1-20261008T120000Z.txt]
    status = " M state/T1.yml\0 M state/T2.yml\0?? state/prompts/T1-20261008T120000Z.txt\0?? state/prompts/T2-20261008T120000Z.txt\0?? state/prompts/T1-other.txt\0"
    expect_git([*publication_observations(status: status, scope_paths: files),
      *commit_observations(files, task_id: "T1", untracked: [files.last]), *push_observations])
    result = @publisher.publish(mode: :task, task_id: "T1")
    assert_equal files, result.fetch(:files)
    assert_equal COMMIT, result.fetch(:sha)
  end

  # Invalid IDs/CLI arguments fail before any external observation or mutation.
  def test_task_scope_validates_task_ids_and_cli_arguments
    expect_git([])
    assert_raises(AgentCodingTool::InvalidTask) { @publisher.publish(mode: :task, task_id: "../T2") }
    assert_raises(AgentCodingTool::InvalidTask) { @publisher.publish(mode: :task, task_id: "UNKNOWN") }
    out, err = StringIO.new, StringIO.new
    cli = AgentCodingTool::CLI.new(root: @root, data_root: @root, out: out, err: err)
    assert_equal 2, cli.run(%w[publish --all T1])
    assert_equal 2, cli.run(%w[publish --all --all])
  end

  # All mode stages the complete selection, including tracked deletions.
  def test_all_sweeps_tracked_staged_deleted_and_untracked_paths
    files = %w[notes.txt state/T1.yml tasks/T1.yml tasks/T2.yml]
    status = " M state/T1.yml\0M  tasks/T2.yml\0 D tasks/T1.yml\0?? notes.txt\0"
    expect_git([*publication_observations(status: status, scope_paths: %w[state/T1.yml tasks/T2.yml tasks/T1.yml notes.txt]),
      *commit_observations(files, mode: :all), *push_observations])
    result = @publisher.publish(mode: :all)
    assert result.fetch(:pushed)
    assert_equal files, result.fetch(:files)
  end

  # All previews inspect the same status bytes and create no lock or commit.
  def test_dry_run_uses_same_selection_and_does_not_mutate
    status = " M state/T1.yml\0M  tasks/T2.yml\0"
    [[:default, nil, ["state/T1.yml"]], [:task, "T1", ["state/T1.yml"]],
     [:all, nil, %w[state/T1.yml tasks/T2.yml]]].each do |mode, id, paths|
      expect_git(inspection_observations(status: status, scope_paths: paths))
      result = @publisher.publish(mode: mode, task_id: id, dry_run: true)
      assert_equal paths, result.fetch(:files)
      assert result.fetch(:commit_needed)
      assert result.fetch(:push_needed)
    end
    refute File.exist?(File.join(@root, ".git", "act-publish.lock"))
  end

  # Mixed index/worktree versions refuse preview and actual publication.
  def test_selected_partially_staged_file_blocks_narrow_publication
    reads = inspection_observations(status: "MM state/T1.yml\0", scope_paths: ["state/T1.yml"])
    expect_git([*reads, *reads])
    assert_match(/different staged and working-tree versions/,
      @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    refute File.exist?(File.join(@root, ".git", "act-publish.lock"))
  end

  # Wrong fetch/push identities refuse before creating even the local lock.
  def test_unexpected_identity_or_push_destination_fails_before_mutation
    reads = destination_observations(remote: "git@github.com:another/repository.git")
    expect_git([*reads, *reads])
    assert_match(/identity mismatch/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    expect_git(destination_observations(push_urls: ["https://github.com/another/repository.git"]))
    assert_match(/exactly one push destination/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    refute File.exist?(File.join(@root, ".git", "act-publish.lock"))
  end

  # Branch/checkout observations cannot authorize the wrong execution root.
  def test_detached_wrong_branch_and_wrong_checkout_fail_closed
    expect_git([*destination_observations,
      git_observation(["symbolic-ref", "--quiet", "--short", "HEAD"], stderr: "detached HEAD", success: false)])
    assert_match(/detached HEAD/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    expect_git([*destination_observations,
      git_observation(["symbolic-ref", "--quiet", "--short", "HEAD"], "other\n")])
    assert_match(/expected branch main/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    expect_git([git_observation(["rev-parse", "--show-toplevel"], "#{File.dirname(@root)}\n")])
    assert_match(/not the Git checkout root/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    refute File.exist?(File.join(@root, ".git", "act-publish.lock"))
  end

  # An unrelated local parent prevents publication against a moved remote ref.
  def test_unpublished_or_diverged_history_requires_operator_review
    expect_git([*inspection_observations(status: " M state/T1.yml\0", scope_paths: ["state/T1.yml"], remote_head: "f" * 40),
      git_observation(["rev-parse", "HEAD^"], stderr: "no parent", success: false)])
    assert_match(/existing commits require operator review/,
      assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }.message)
    refute File.exist?(File.join(@root, ".git", "act-publish.lock"))
  end

  # Failed push retry verifies the original parent/trailers/paths with no commit.
  def test_push_failure_preserves_commit_and_retry_does_not_recommit
    files = ["state/T1.yml"]
    expect_git([*publication_observations(status: " M state/T1.yml\0", scope_paths: files),
      *commit_observations(files),
      git_observation(["push", "origin", "HEAD:refs/heads/main"], stderr: "injected push failure", success: false)])
    error = assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    assert_includes error.message, COMMIT
    retry_reads = [*inspection_observations(status: "", scope_paths: [], head: COMMIT),
      git_observation(["rev-parse", "HEAD^"], "#{BASE}\n"),
      git_observation(["show", "-s", "--format=%B", "HEAD"], commit_arguments(files).fetch(5) + "\n"),
      paths_observation(files), paths_observation(files)]
    expect_git(retry_reads)
    assert @publisher.publish(mode: :default, dry_run: true).fetch(:push_needed)
    expect_git([*retry_reads, *checkout_observations, *retry_reads,
      git_observation(["push", "origin", "HEAD:refs/heads/main"]), remote_observation(COMMIT), paths_observation(files)])
    assert_equal COMMIT, @publisher.publish(mode: :default).fetch(:sha)
  end

  # A push race preserves the local SHA and refuses automatic reconciliation.
  # Even a successful push response must be checked against the authoritative ref.
  def test_intervening_remote_push_preserves_local_commit
    files = ["state/T1.yml"]
    expect_git([*publication_observations(status: " M state/T1.yml\0", scope_paths: files),
      *commit_observations(files),
      git_observation(["push", "origin", "HEAD:refs/heads/main"], stderr: "non-fast-forward", success: false)])
    error = assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    assert_includes error.message, "remote publication not confirmed"
    assert_includes error.message, COMMIT
    expect_git([*inspection_observations(status: "", scope_paths: [], head: COMMIT, remote_head: "f" * 40),
      git_observation(["rev-parse", "HEAD^"], "#{BASE}\n")])
    assert_match(/existing commits require operator review/,
      assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }.message)
    expect_git([*publication_observations(status: " M state/T1.yml\0", scope_paths: files),
      *commit_observations(files),
      git_observation(["push", "origin", "HEAD:refs/heads/main"]), remote_observation("f" * 40)])
    error = assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    assert_includes error.message, "remote reports #{'f' * 40}, expected #{COMMIT}"
    assert_includes error.message, "local commit #{COMMIT} preserved"
  end

  # Commit failure resets only intent-to-add and never attempts a push.
  def test_commit_failure_does_not_claim_remote_publication
    files = ["state/prompts/T1-20261008T120000Z.txt"]
    expect_git([*publication_observations(status: "?? #{files.first}\0", scope_paths: files),
      *before_commit_observations(untracked: files),
      git_observation(commit_arguments(files), stderr: "injected commit failure", success: false),
      git_observation(["rev-parse", "HEAD"], "#{BASE}\n"), git_observation(["reset", "-q", "--", *files])])
    error = assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    assert_match(/git commit failed/, error.message)
  end

  # Cross-scope rename refuses narrow mode; all mode includes both paths.
  def test_rename_crossing_scope_blocks_narrow_mode_but_all_accepts
    status = "R  notes.yml\0state/T1.yml\0"
    expect_git(inspection_observations(status: status, scope_paths: []))
    assert_match(/renamed selected file/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    files = %w[notes.yml state/T1.yml]
    expect_git([*publication_observations(status: status, scope_paths: ["notes.yml"]),
      *commit_observations(files, mode: :all), *push_observations])
    assert_equal files, @publisher.publish(mode: :all).fetch(:files)
  end

  # Real filesystem markers block nested-checkout and unfinished-merge publication.
  def test_nested_checkout_and_in_progress_merge_block_publication
    FileUtils.mkdir_p(File.join(@root, "nested", ".git"))
    expect_git(inspection_observations(status: "?? nested\0", scope_paths: []))
    assert_match(/nested Git checkout/, @publisher.publish(mode: :all, dry_run: true).fetch(:blocker))
    File.write(File.join(@root, ".git", "MERGE_HEAD"), "f" * 40)
    expect_git(inspection_observations(status: "", scope_paths: [], operations: ["MERGE_HEAD"]))
    assert_match(/MERGE_HEAD/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
  end

  # Public CLI reports success only after exact remote-ref verification.
  def test_cli_outputs_verified_publication_and_dry_run
    files = ["state/T1.yml"]
    reads = inspection_observations(status: " M state/T1.yml\0", scope_paths: files)
    expect_git([*reads, *publication_observations(status: " M state/T1.yml\0", scope_paths: files),
      *commit_observations(files, task_id: "T1"), *push_observations])
    out, err = StringIO.new, StringIO.new
    cli = AgentCodingTool::CLI.new(root: @root, data_root: @root, out: out, err: err)
    AgentCodingTool::Publisher.stub(:new, @publisher) do
      assert_equal 0, cli.run(%w[publish T1 --dry-run])
      assert_includes out.string, "DRY RUN (no changes made)"
      out.truncate(0)
      out.rewind
      assert_equal 0, cli.run(%w[publish T1])
      assert_includes out.string, "PUBLISHED: #{COMMIT}"
    end
    assert_empty err.string
  end
end
