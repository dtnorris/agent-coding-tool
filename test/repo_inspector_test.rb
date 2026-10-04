# frozen_string_literal: true

require_relative "test_helper"

class RepoInspectorTest < Minitest::Test
  Runner = Struct.new(:responses) do
    def capture(*command, chdir: nil)
      key = [chdir, command]
      responses.fetch(key) { ["", "unexpected command: #{command.inspect}", false] }
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

    snapshot = AgentCodingTool::RepoInspector.new(config, runner: Runner.new(responses)).snapshot("repo", "access" => "write")

    assert_equal sha, snapshot.fetch("pushed_sha")
    assert_equal local, snapshot.fetch("local_head")
    assert snapshot.fetch("local_dirty")
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
end
