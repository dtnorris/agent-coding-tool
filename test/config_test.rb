# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  # Resolves defaults and configured names only, rejecting malformed mappings,
  # case-fold collisions, unknown names and nonpositive or malformed PR numbers.
  def test_repository_aliases_and_pull_request_references
    config = AgentCodingTool::Config.new(AgentCodingTool::Config::DEFAULTS, base_dir: "/")
    assert_equal "https://github.com/dtnorris/agent-coding-tool/pull/38", config.pull_request_url("act-38")
    assert_equal "https://github.com/dtnorris/agent-coding-tool-data/pull/2", config.pull_request_url("ACTD-2")
    assert_equal "https://github.com/dtnorris/agent-skills/pull/1", config.pull_request_url("AGS-1")
    url = "https://github.com/owner/repository/pull/42"
    assert_equal url, config.pull_request_url(url)
    custom = AgentCodingTool::Config::DEFAULTS.merge("repository_aliases" => { "demo" => "owner/repository" })
    configured = AgentCodingTool::Config.new(custom, base_dir: "/")
    assert_equal url, configured.pull_request_url("DEMO-42")
    assert_equal config.pull_request_url("ACT-38"), configured.pull_request_url("ACT-38")
    [nil, [], { "TOOLONG" => "owner/repo" }, { "AB" => "owner/repo" }, { "ABC" => "bad" },
     { "ABC" => "../repo" }, { "ABC" => "owner/repo/pull/1" }, { "ABC" => 1 },
     { "ABC" => "owner/repo", "abc" => "other/repo" }].each do |mapping|
      invalid = AgentCodingTool::Config.new(custom.merge("repository_aliases" => mapping), base_dir: "/")
      assert_raises(AgentCodingTool::InvalidState) { invalid.pull_request_url("ACT-38") }
    end
    %w[ACT-0 ACT--1 ACT-01 ACT-1x NOPE-2 A-1 ABCDE-1 https://github.com/owner/repo/pull/0].each do |reference|
      assert_raises(AgentCodingTool::InvalidState) { config.pull_request_url(reference) }
    end
  end

  def test_missing_config_uses_data_directory_parent_as_repo_root
    Dir.mktmpdir do |dir|
      data_root = File.join(dir, "agent-coding-tool-data")
      FileUtils.mkdir_p(data_root)

      config = AgentCodingTool::Config.load(File.join(data_root, "config.yml"))

      assert_equal dir, config.repo_root
      assert_equal "origin", config.default_remote
      assert_equal "main", config.default_branch
    end
  end

  def test_relative_repo_root_is_resolved_from_data_directory
    Dir.mktmpdir do |dir|
      data_root = File.join(dir, "private-data")
      FileUtils.mkdir_p(data_root)
      File.write(File.join(data_root, "config.yml"), YAML.dump("repo_root" => "../repositories"))

      config = AgentCodingTool::Config.load(File.join(data_root, "config.yml"))

      assert_equal File.join(dir, "repositories"), config.repo_root
    end
  end
end
