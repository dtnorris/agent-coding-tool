# frozen_string_literal: true

require "uri"

module AgentCodingTool
  # Supported Git spellings shared with publication; identity is not containment.
  module RepositoryIdentity
    # Returns the canonical configured remote, or raises RepositoryError without
    # echoing input. Resolves local filesystem identities without network access.
    def self.resolve(value)
      text = value.to_s
      github_path = case text
                    when /\Agit@github\.com:(.+)\z/ then Regexp.last_match(1)
                    when /\Assh:\/\/git@github\.com\/(.+)\z/ then Regexp.last_match(1)
                    when /\Ahttps:\/\/github\.com\/(.+)\z/ then Regexp.last_match(1)
                    when /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?\z/ then text
                    end
      return github_path.delete_suffix(".git").downcase if github_path
      return "file://#{File.realpath(URI::DEFAULT_PARSER.unescape(URI(text).path))}" if text.start_with?("file://")
      return "file://#{File.realpath(text)}" if text.start_with?("/")

      raise RepositoryError, "unsupported publication repository identity"
    rescue Errno::ENOENT, URI::InvalidURIError
      raise RepositoryError, "publication repository identity cannot be resolved"
    end
  end
end
