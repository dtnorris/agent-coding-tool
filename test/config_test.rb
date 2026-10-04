# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
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
