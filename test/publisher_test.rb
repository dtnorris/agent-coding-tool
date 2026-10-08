# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

# A Git protocol fake: ordinary tests exercise publication decisions without
# creating repositories or launching subprocesses. The disposable real-Git
# smoke suite is opt-in under test/integration/.
class PublisherTest < Minitest::Test
  include TestHelpers

  class FakeGit
    attr_accessor :branch, :remote_url, :push_urls, :remote_head, :fail_commit,
                  :fail_push, :move_remote_on_push, :checkout_root
    attr_reader :head, :changes, :calls, :last_commit_paths, :commits

    def initialize(root)
      @root = root
      @checkout_root = root
      @branch = "main"
      @remote_url = "git@github.com:dtnorris/agent-coding-tool-data.git"
      @push_urls = [@remote_url]
      @head = "a" * 40
      @remote_head = @head
      @changes = []
      @calls = []
      @commits = 0
    end

    def change(path, xy: " M", original: nil)
      @changes << { path: path, xy: xy, original: original }
    end

    def capture(*command, chdir:)
      raise "wrong checkout: #{chdir}" unless chdir == @root && command.shift == "git"

      @calls << command.dup
      name, *args = command
      case name
      when "rev-parse"
        case args
        when ["--show-toplevel"] then ok("#{@checkout_root}\n")
        when ["--absolute-git-dir"] then ok("#{@root}/.git\n")
        when ["HEAD"] then ok("#{@head}\n")
        when ["HEAD^"] then @parent ? ok("#{@parent}\n") : failed("no parent")
        else
          args.first == "--git-path" ? ok("#{@root}/.git/#{args.last}\n") : raise("unexpected rev-parse #{args.inspect}")
        end
      when "remote"
        raise "unexpected remote #{args.inspect}" unless args.first == "get-url" && args.last == "origin"

        args.include?("--push") ? ok(@push_urls.map { |url| "#{url}\n" }.join) : ok("#{@remote_url}\n")
      when "symbolic-ref"
        @branch ? ok("#{@branch}\n") : failed("detached HEAD")
      when "ls-remote"
        ok("#{@remote_head}\trefs/heads/main\n")
      when "status"
        ok(@changes.map { |entry| "#{entry.fetch(:xy)} #{entry.fetch(:path)}\0" +
          (entry[:original] ? "#{entry.fetch(:original)}\0" : "") }.join)
      when "ls-files"
        ok("")
      when "add", "reset"
        ok("")
      when "commit"
        return failed("injected commit failure") if @fail_commit

        @last_commit_paths = if args.include?("--only")
                               args.drop(args.index("--") + 1).sort
                             else
                               @changes.flat_map { |entry| [entry[:path], entry[:original]].compact }.uniq.sort
                             end
        @parent = @head
        @commits += 1
        @head = format("%040x", @commits + 10)
        @message = args.each_index.filter_map { |index| args[index + 1] if args[index] == "-m" }.join("\n\n")
        @changes.reject! { |entry| @last_commit_paths.include?(entry[:path]) ||
          (entry[:original] && @last_commit_paths.include?(entry[:original])) }
        ok("[main #{@head[0, 7]}] committed\n")
      when "diff-tree"
        ok(@last_commit_paths.map { |path| "#{path}\0" }.join)
      when "show"
        ok("#{@message}\n")
      when "push"
        if @move_remote_on_push
          @remote_head = "f" * 40
          return failed("non-fast-forward")
        end
        return failed("injected push failure") if @fail_push

        @remote_head = @head
        ok("")
      else
        raise "unexpected Git operation: #{command.inspect}"
      end
    end

    private

    def ok(output) = [output, "", true]
    def failed(message) = ["", message, false]
  end

  def setup
    @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@root, ".git"))
    FileUtils.mkdir_p(File.join(@root, "tasks"))
    FileUtils.mkdir_p(File.join(@root, "state", "prompts"))
    %w[T1 T2].each { |id| write_task(@root, id: id) }
    @git = FakeGit.new(@root)
    @config = AgentCodingTool::Config.load(File.join(@root, "config.yml"))
    @publisher = publisher
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def publisher(config: @config)
    AgentCodingTool::Publisher.new(data_root: @root, config: config,
                                   task_store: AgentCodingTool::TaskStore.new(File.join(@root, "tasks")),
                                   runner: @git)
  end

  def test_default_selects_lifecycle_state_and_prompts_only
    @git.change("state/T1.yml")
    @git.change("state/T2.yml", xy: "D ")
    @git.change("state/prompts/T1-20261008T120000Z.txt", xy: "??")
    @git.change("tasks/T2.yml", xy: "M ")
    @git.change("config.yml")
    @git.change("notes.txt", xy: "??")
    result = @publisher.publish(mode: :default)
    assert result.fetch(:pushed)
    assert_equal %w[state/T1.yml state/T2.yml state/prompts/T1-20261008T120000Z.txt], @git.last_commit_paths
    assert_equal %w[config.yml notes.txt tasks/T2.yml], @git.changes.map { |entry| entry[:path] }.sort
    assert_equal @git.head, @git.remote_head
    assert_equal false, @publisher.publish(mode: :default).fetch(:pushed, false)
    assert_equal 1, @git.commits
  end

  def test_task_scope_selects_own_state_and_timestamped_prompts
    @git.change("state/T1.yml")
    @git.change("state/T2.yml")
    @git.change("state/prompts/T1-20261008T120000Z.txt", xy: "??")
    @git.change("state/prompts/T2-20261008T120000Z.txt", xy: "??")
    @git.change("state/prompts/T1-other.txt", xy: "??")
    result = @publisher.publish(mode: :task, task_id: "T1")
    assert_equal %w[state/T1.yml state/prompts/T1-20261008T120000Z.txt], result.fetch(:files)
    assert_equal result.fetch(:files), @git.last_commit_paths
    assert_equal 3, @git.changes.length
  end

  def test_task_scope_validates_task_ids_and_cli_arguments
    assert_raises(AgentCodingTool::InvalidTask) { @publisher.publish(mode: :task, task_id: "../T2") }
    assert_raises(AgentCodingTool::InvalidTask) { @publisher.publish(mode: :task, task_id: "UNKNOWN") }
    out, err = StringIO.new, StringIO.new
    cli = AgentCodingTool::CLI.new(root: @root, data_root: @root, out: out, err: err)
    assert_equal 2, cli.run(%w[publish --all T1])
    assert_equal 2, cli.run(%w[publish --all --all])
    assert_empty @git.calls
  end

  def test_all_sweeps_tracked_staged_deleted_and_untracked_paths
    @git.change("state/T1.yml")
    @git.change("tasks/T2.yml", xy: "M ")
    @git.change("tasks/T1.yml", xy: " D")
    @git.change("notes.txt", xy: "??")
    result = @publisher.publish(mode: :all)
    assert result.fetch(:pushed)
    assert_equal %w[notes.txt state/T1.yml tasks/T1.yml tasks/T2.yml], @git.last_commit_paths
    assert_empty @git.changes
    assert @git.calls.include?(["add", "-A", "--", "."])
  end

  def test_dry_run_uses_same_selection_and_does_not_mutate
    @git.change("state/T1.yml")
    @git.change("tasks/T2.yml", xy: "M ")
    [[:default, nil, ["state/T1.yml"]], [:task, "T1", ["state/T1.yml"]],
     [:all, nil, %w[state/T1.yml tasks/T2.yml]]].each do |mode, id, paths|
      result = @publisher.publish(mode: mode, task_id: id, dry_run: true)
      assert_equal paths, result.fetch(:files)
      assert result.fetch(:commit_needed)
      assert result.fetch(:push_needed)
    end
    assert_equal 0, @git.commits
    refute @git.calls.any? { |call| %w[add commit push reset].include?(call.first) }
    refute File.exist?(File.join(@root, ".git", "act-publish.lock"))
  end

  def test_selected_partially_staged_file_blocks_narrow_publication
    @git.change("state/T1.yml", xy: "MM")
    preview = @publisher.publish(mode: :default, dry_run: true)
    assert_match(/different staged and working-tree versions/, preview.fetch(:blocker))
    assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    assert_equal 0, @git.commits
  end

  def test_unexpected_identity_or_push_destination_fails_before_mutation
    @git.change("state/T1.yml")
    @git.remote_url = "git@github.com:another/repository.git"
    assert_match(/identity mismatch/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    @git.remote_url = @git.push_urls.first
    @git.push_urls = ["https://github.com/another/repository.git"]
    assert_match(/exactly one push destination/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    assert_equal 0, @git.commits
  end

  def test_detached_wrong_branch_and_wrong_checkout_fail_closed
    @git.change("state/T1.yml")
    @git.branch = nil
    assert_match(/detached HEAD/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    @git.branch = "other"
    assert_match(/expected branch main/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    @git.branch = "main"
    @git.checkout_root = File.dirname(@root)
    assert_match(/not the Git checkout root/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    assert_equal 0, @git.commits
  end

  def test_unpublished_or_diverged_history_requires_operator_review
    @git.change("state/T1.yml")
    @git.remote_head = "f" * 40
    assert_match(/existing commits require operator review/,
                 assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }.message)
    assert_equal 0, @git.commits
  end

  def test_push_failure_preserves_commit_and_retry_does_not_recommit
    @git.change("state/T1.yml")
    @git.fail_push = true
    error = assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    assert_includes error.message, @git.head
    refute_equal @git.head, @git.remote_head
    assert_equal 1, @git.commits
    assert @publisher.publish(mode: :default, dry_run: true).fetch(:push_needed)
    @git.fail_push = false
    assert_equal @git.head, @publisher.publish(mode: :default).fetch(:sha)
    assert_equal 1, @git.commits
    assert_equal @git.head, @git.remote_head
  end

  def test_intervening_remote_push_preserves_local_commit
    @git.change("state/T1.yml")
    @git.move_remote_on_push = true
    error = assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    assert_includes error.message, "remote publication not confirmed"
    assert_equal 1, @git.commits
    assert_match(/existing commits require operator review/,
                 assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }.message)
  end

  def test_commit_failure_does_not_claim_remote_publication
    @git.change("state/prompts/T1-20261008T120000Z.txt", xy: "??")
    @git.fail_commit = true
    error = assert_raises(AgentCodingTool::RepositoryError) { @publisher.publish(mode: :default) }
    assert_match(/git commit failed/, error.message)
    assert_equal 0, @git.commits
    assert_equal @git.head, @git.remote_head
    assert @git.calls.include?(["reset", "-q", "--", "state/prompts/T1-20261008T120000Z.txt"])
  end

  def test_rename_crossing_scope_blocks_narrow_mode_but_all_accepts
    @git.change("notes.yml", xy: "R ", original: "state/T1.yml")
    assert_match(/renamed selected file/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
    assert_equal %w[notes.yml state/T1.yml], @publisher.publish(mode: :all).fetch(:files)
  end

  def test_nested_checkout_and_in_progress_merge_block_publication
    FileUtils.mkdir_p(File.join(@root, "nested", ".git"))
    @git.change("nested", xy: "??")
    assert_match(/nested Git checkout/, @publisher.publish(mode: :all, dry_run: true).fetch(:blocker))
    @git.changes.clear
    File.write(File.join(@root, ".git", "MERGE_HEAD"), "f" * 40)
    assert_match(/MERGE_HEAD/, @publisher.publish(mode: :default, dry_run: true).fetch(:blocker))
  end

  def test_cli_outputs_verified_publication_and_dry_run
    @git.change("state/T1.yml")
    out, err = StringIO.new, StringIO.new
    cli = AgentCodingTool::CLI.new(root: @root, data_root: @root, out: out, err: err)
    constructor_class = AgentCodingTool::Publisher.singleton_class
    instance = @publisher
    AgentCodingTool::Publisher.define_singleton_method(:new) { |**_args| instance }
    begin
      assert_equal 0, cli.run(%w[publish T1 --dry-run])
      assert_includes out.string, "DRY RUN (no changes made)"
      assert_equal 0, @git.commits
      out.truncate(0)
      out.rewind
      assert_equal 0, cli.run(%w[publish T1])
      assert_includes out.string, "PUBLISHED: #{@git.head}"
    ensure
      constructor_class.send(:remove_method, :new)
    end
    assert_empty err.string
  end
end
