# frozen_string_literal: true

require "yaml"

module AgentCodingTool
  class Config
    DEFAULTS = {
      "repo_root" => "..",
      "default_remote" => "origin",
      "default_branch" => "main"
    }.freeze

    def self.load(path)
      data = File.exist?(path) ? YAML.safe_load_file(path, aliases: false) : {}
      new(DEFAULTS.merge(data || {}), base_dir: File.dirname(path))
    end

    def initialize(data, base_dir:)
      @data = data
      @base_dir = base_dir
    end

    def repo_root = File.expand_path(@data.fetch("repo_root"), @base_dir)
    def default_remote = @data.fetch("default_remote")
    def default_branch = @data.fetch("default_branch")
  end
end
