# frozen_string_literal: true

require "yaml"

module AgentCodingTool
  class Config
    DEFAULTS = {
      "repo_root" => "/Users/davidnorris/code",
      "default_remote" => "origin",
      "default_branch" => "main"
    }.freeze

    def self.load(path)
      data = File.exist?(path) ? YAML.safe_load_file(path, aliases: false) : {}
      new(DEFAULTS.merge(data || {}))
    end

    def initialize(data)
      @data = data
    end

    def repo_root = @data.fetch("repo_root")
    def default_remote = @data.fetch("default_remote")
    def default_branch = @data.fetch("default_branch")
  end
end
