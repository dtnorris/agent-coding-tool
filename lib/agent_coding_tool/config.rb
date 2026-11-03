# frozen_string_literal: true

require "yaml"

module AgentCodingTool
  class Config
    DEFAULTS = {
      "repo_root" => "..",
      "default_remote" => "origin",
      "default_branch" => "main",
      "worktree_root" => "/Users/davidnorris/code/ACT-Worktrees",
      "publish_repository" => "dtnorris/agent-coding-tool-data",
      "repository_aliases" => { "ACT" => "dtnorris/agent-coding-tool", "ACTD" => "dtnorris/agent-coding-tool-data",
                                "AGS" => "dtnorris/agent-skills" }.freeze
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
    def publish_repository = @data.fetch("publish_repository")
    def worktree_root = File.expand_path(@data.fetch("worktree_root"), @base_dir)

    # Returns default and explicitly configured GitHub names keyed by uppercase
    # aliases. Invalid mappings and case-fold collisions raise InvalidState.
    def repository_aliases
      configured = @data.fetch("repository_aliases")
      unless configured.is_a?(Hash) && configured.all? { |key, value|
        key.is_a?(String) && key.match?(/\A[A-Za-z]{3,4}\z/) &&
          value.is_a?(String) && value.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/) &&
          value.split("/").none? { |part| %w[. ..].include?(part) } }
        raise InvalidState, "config: repository_aliases must map 3-4 letter aliases to owner/repository"
      end
      normalized = configured.transform_keys(&:upcase)
      raise InvalidState, "config: repository_aliases case-fold collision" unless normalized.size == configured.size
      DEFAULTS.fetch("repository_aliases").merge(normalized)
    end

    # Resolves a full GitHub PR URL or ALIAS-NUMBER to a canonical URL, without
    # granting repository authority. Invalid/unknown references raise InvalidState.
    def pull_request_url(reference)
      aliases = repository_aliases
      return reference if reference.match?(/\Ahttps:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*\z/)
      match = reference.match(/\A([A-Za-z]{3,4})-([1-9][0-9]*)\z/)
      raise InvalidState, "cleanup: use a GitHub PR URL or ALIAS-NUMBER with a positive PR number" unless match
      repository = aliases[match[1].upcase]
      raise InvalidState, "cleanup: unknown repository alias #{match[1]}" unless repository
      "https://github.com/#{repository}/pull/#{match[2]}"
    end
  end
end
