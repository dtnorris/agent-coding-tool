# frozen_string_literal: true

require_relative "test_helper"
require "timeout"
require_relative "git_contract/observations"

class RepoInspectorTest < Minitest::Test
  # Records exact command inputs while consuming a finite external transcript.
  class RecordingRunner
    attr_reader :commands

    # Converts explicit cwd/argv/tuple inputs to observations. Only independent
    # concurrent requests may use ordered: false; malformed tuples raise.
    def initialize(responses, ordered: true)
      @commands = []
      @replay = GitContract::Replay.new(responses.map { |(cwd, argv), result|
        GitContract::Observation.new(argv: argv, cwd: cwd, result: result) }, ordered: ordered)
    end

    # Returns raw response bytes/success, or raises on any undeclared request.
    def capture(*command, chdir: nil)
      commands << [chdir, command]
      @replay.capture(*command, chdir: chdir)
    end

    # Returns true only when every observation was consumed; omissions raise.
    def verify!
      @replay.verify!
    end
  end

  # Holds genuine production threads at the external boundary, then replays
  # independently declared responses without interpreting their Git requests.
  class BlockingRunner < RecordingRunner
    attr_reader :max_active

    # Accepts explicit finite responses and creates a bounded test rendezvous.
    def initialize(responses)
      super(responses, ordered: false)
      @active = 0
      @max_active = 0
      @blocked = true
      @mutex = Mutex.new
      @condition = ConditionVariable.new
    end

    # Waits for release, then consumes one exact response; unexpected calls raise.
    def capture(*command, chdir: nil)
      entered = false
      @mutex.synchronize do
        @active += 1
        entered = true
        @max_active = [@max_active, @active].max
        @condition.broadcast
        @condition.wait(@mutex) while @blocked
      end
      super
    ensure
      @mutex.synchronize { @active -= 1 } if entered
    end

    # Waits at most two seconds for count active requests; Timeout propagates.
    def wait_until_active(count)
      Timeout.timeout(2) do
        @mutex.synchronize do
          @condition.wait(@mutex) while @active < count
        end
      end
    end

    # Releases all owned request threads; returns the condition broadcast result.
    def release
      @mutex.synchronize do
        @blocked = false
        @condition.broadcast
      end
    end

    # Returns the number of observed requests under the rendezvous mutex.
    def command_count
      @mutex.synchronize { @commands.length }
    end
  end

  Config = Struct.new(:repo_root, :default_remote, :default_branch)

  # Starts per-case transcript ownership; returns an empty collection.
  def setup
    @runners = []
  end

  # Verifies consumption after both successful and refused production calls.
  # Omissions raise UnexpectedObservation, including expected refusal paths.
  def teardown
    @runners.each(&:verify!)
  end

  # Registers a finite recording runner for teardown verification; returns it.
  def runner_for(responses, ordered: true)
    RecordingRunner.new(responses, ordered: ordered).tap { |runner| @runners << runner }
  end

  def test_pushed_main_is_authoritative_and_local_state_is_only_observed
    Dir.mktmpdir("act-inspection-") do |directory|
      config = Config.new("/code", "origin", "main")
      path = File.realpath(directory)
      sha = "1" * 40
      local = "2" * 40
      responses = {
        [path, ["git", "rev-parse", "--git-dir"]] => [".git\n", "", true],
        [path, ["git", "ls-remote", "--exit-code", "origin", "refs/heads/main"]] => ["#{sha}\trefs/heads/main\n", "", true],
        [path, ["git", "rev-parse", "HEAD"]] => ["#{local}\n", "", true],
        [path, ["git", "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"]] => [" M lib/x.rb\0", "", true],
        [path, ["git", "remote", "get-url", "origin"]] => ["git@github.com:example/repo.git\n", "", true]
      }

      runner = runner_for(responses)
      snapshot = AgentCodingTool::RepoInspector.new(config, runner:).snapshot("repo", "access" => "write", "path" => path)

      assert_equal sha, snapshot.fetch("pushed_sha")
      assert_equal local, snapshot.fetch("local_head")
      assert snapshot.fetch("local_dirty")
      assert_equal "git@github.com:example/repo.git", snapshot.fetch("remote_url")
      assert_equal 5, runner.commands.length
    end
  end

  def test_missing_pushed_main_fails_closed
    config = Config.new("/code", "origin", "main")
    path = "/code/repo"
    responses = {
      [path, ["git", "rev-parse", "--git-dir"]] => [".git\n", "", true],
      [path, ["git", "ls-remote", "--exit-code", "origin", "refs/heads/main"]] => ["", "not found", false]
    }

    error = assert_raises(AgentCodingTool::RepositoryError) do
      AgentCodingTool::RepoInspector.new(config, runner: runner_for(responses)).snapshot("repo", "access" => "write")
    end
    assert_match(/cannot resolve pushed origin\/main/, error.message)
  end

  def test_repository_authority_resolves_remote_url_and_branch_without_remote_fetch
    config = Config.new("/code", "origin", "main")
    path = "/code/repo"
    responses = {
      [path, ["git", "rev-parse", "--git-dir"]] => [".git\n", "", true],
      [path, ["git", "remote", "get-url", "upstream"]] =>
        ["git@github.com:example/shared.git\n", "", true]
    }
    runner = runner_for(responses)
    inspector = AgentCodingTool::RepoInspector.new(config, runner:)

    authority = inspector.repository_authority(
      "repo",
      "access" => "write", "remote" => "upstream", "branch" => "release"
    )

    assert_equal ["git@github.com:example/shared.git", "release"], authority
    assert_equal [
      [path, ["git", "rev-parse", "--git-dir"]],
      [path, ["git", "remote", "get-url", "upstream"]]
    ], runner.commands
  end

  def test_status_head_resolution_deduplicates_remote_and_branch_without_local_probes
    config = Config.new("/code", "origin", "main")
    alpha = "git@github.com:example/alpha.git"
    beta = "git@github.com:example/beta.git"
    responses = {
      [nil, ["git", "ls-remote", "--exit-code", alpha, "refs/heads/main"]] =>
        ["#{'a' * 40}\trefs/heads/main\n", "", true],
      [nil, ["git", "ls-remote", "--exit-code", beta, "refs/heads/release"]] =>
        ["#{'b' * 40}\trefs/heads/release\n", "", true]
    }
    runner = runner_for(responses, ordered: false)
    inspector = AgentCodingTool::RepoInspector.new(config, runner:, remote_concurrency: 2)
    references = [
      { "name" => "T1/alpha", "remote_url" => alpha, "branch" => "main" },
      { "name" => "T2/alpha", "remote_url" => alpha, "branch" => "main" },
      { "name" => "T2/beta", "remote_url" => beta, "branch" => "release" }
    ]

    heads = inspector.pushed_heads(references)

    assert_equal "a" * 40, heads.fetch([alpha, "main"])
    assert_equal "b" * 40, heads.fetch([beta, "release"])
    assert_equal 2, runner.commands.length
    assert runner.commands.all? { |chdir, command| chdir.nil? && command.take(2) == %w[git ls-remote] }
  end

  def test_status_head_resolution_respects_bounded_concurrency
    config = Config.new("/code", "origin", "main")
    references = (1..5).map do |index|
      {
        "name" => "T1/repo#{index}",
        "remote_url" => "git@github.com:example/repo#{index}.git",
        "branch" => "main"
      }
    end

    responses = references.to_h do |reference|
      [[nil, ["git", "ls-remote", "--exit-code", reference.fetch("remote_url"), "refs/heads/main"]],
       ["#{'1' * 40}\trefs/heads/main\n", "", true]]
    end
    runner = BlockingRunner.new(responses)
    @runners << runner
    inspector = AgentCodingTool::RepoInspector.new(config, runner:, remote_concurrency: 2)

    resolution = Thread.new { inspector.pushed_heads(references) }
    runner.wait_until_active(2)
    assert_equal 2, runner.max_active
    runner.release
    heads = resolution.value

    assert_equal 5, heads.length
    assert_equal 5, runner.command_count
    assert_operator runner.max_active, :<=, 2
  ensure
    runner&.release
    resolution&.join(2)
  end

  def test_status_head_resolution_failure_is_explicit_and_does_not_fall_back
    config = Config.new("/code", "origin", "main")
    remote_url = "git@github.com:example/missing.git"
    command = ["git", "ls-remote", "--exit-code", remote_url, "refs/heads/main"]
    runner = runner_for({ [nil, command] => ["", "network unavailable", false] })
    inspector = AgentCodingTool::RepoInspector.new(config, runner:)

    error = assert_raises(AgentCodingTool::RepositoryError) do
      inspector.pushed_heads([
        { "name" => "T1/missing", "remote_url" => remote_url, "branch" => "main" }
      ])
    end

    assert_includes error.message, "T1/missing"
    assert_includes error.message, "network unavailable"
    assert_equal 1, runner.commands.length
  end
end
