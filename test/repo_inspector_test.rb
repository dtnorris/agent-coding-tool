# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class RepoInspectorTest < Minitest::Test
  Runner = Struct.new(:responses) do
    def capture(*command, chdir: nil)
      key = [chdir, command]
      responses.fetch(key) { ["", "unexpected command: #{command.inspect}", false] }
    end
  end

  RecordingRunner = Struct.new(:responses, :commands) do
    def capture(*command, chdir: nil)
      commands << [chdir, command]
      responses.fetch([chdir, command]) { ["", "unexpected command: #{command.inspect}", false] }
    end
  end

  class BlockingRunner
    attr_reader :max_active

    def initialize
      @commands = []
      @active = 0
      @max_active = 0
      @blocked = true
      @mutex = Mutex.new
      @condition = ConditionVariable.new
    end

    def capture(*command, chdir: nil)
      entered = false
      @mutex.synchronize do
        @commands << [chdir, command]
        @active += 1
        entered = true
        @max_active = [@max_active, @active].max
        @condition.broadcast
        @condition.wait(@mutex) while @blocked
      end
      ref = command.last
      ["#{'1' * 40}\t#{ref}\n", "", true]
    ensure
      @mutex.synchronize { @active -= 1 } if entered
    end

    def wait_until_active(count)
      Timeout.timeout(2) do
        @mutex.synchronize do
          @condition.wait(@mutex) while @active < count
        end
      end
    end

    def release
      @mutex.synchronize do
        @blocked = false
        @condition.broadcast
      end
    end

    def command_count
      @mutex.synchronize { @commands.length }
    end
  end

  Config = Struct.new(:repo_root, :default_remote, :default_branch)

  def test_pushed_main_is_authoritative_and_local_state_is_only_observed
    config = Config.new("/code", "origin", "main")
    path = "/code/repo"
    sha = "1" * 40
    local = "2" * 40
    responses = {
      [path, ["git", "rev-parse", "--git-dir"]] => [".git\n", "", true],
      [path, ["git", "ls-remote", "--exit-code", "origin", "refs/heads/main"]] => ["#{sha}\trefs/heads/main\n", "", true],
      [path, ["git", "rev-parse", "HEAD"]] => ["#{local}\n", "", true],
      [path, ["git", "status", "--porcelain"]] => [" M lib/x.rb\n", "", true],
      [path, ["git", "remote", "get-url", "origin"]] => ["git@github.com:example/repo.git\n", "", true]
    }

    runner = RecordingRunner.new(responses, [])
    snapshot = AgentCodingTool::RepoInspector.new(config, runner:).snapshot("repo", "access" => "write")

    assert_equal sha, snapshot.fetch("pushed_sha")
    assert_equal local, snapshot.fetch("local_head")
    assert snapshot.fetch("local_dirty")
    assert_equal "git@github.com:example/repo.git", snapshot.fetch("remote_url")
    assert_equal 5, runner.commands.length
  end

  def test_missing_pushed_main_fails_closed
    config = Config.new("/code", "origin", "main")
    path = "/code/repo"
    responses = {
      [path, ["git", "rev-parse", "--git-dir"]] => [".git\n", "", true],
      [path, ["git", "ls-remote", "--exit-code", "origin", "refs/heads/main"]] => ["", "not found", false]
    }

    error = assert_raises(AgentCodingTool::RepositoryError) do
      AgentCodingTool::RepoInspector.new(config, runner: Runner.new(responses)).snapshot("repo", "access" => "write")
    end
    assert_match(/cannot resolve pushed origin\/main/, error.message)
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
    runner = RecordingRunner.new(responses, [])
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
    runner = BlockingRunner.new
    inspector = AgentCodingTool::RepoInspector.new(config, runner:, remote_concurrency: 2)
    references = (1..5).map do |index|
      {
        "name" => "T1/repo#{index}",
        "remote_url" => "git@github.com:example/repo#{index}.git",
        "branch" => "main"
      }
    end

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
    runner = RecordingRunner.new({ [nil, command] => ["", "network unavailable", false] }, [])
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
