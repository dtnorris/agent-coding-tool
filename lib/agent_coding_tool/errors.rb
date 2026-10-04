# frozen_string_literal: true

module AgentCodingTool
  class Error < StandardError; end
  class InvalidTask < Error; end
  class InvalidState < Error; end
  class RepositoryError < Error; end
end
