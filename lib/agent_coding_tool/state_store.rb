# frozen_string_literal: true

require "fileutils"
require "yaml"

module AgentCodingTool
  class StateStore
    def initialize(root)
      @root = root
    end

    def load(id)
      path = state_path(id)
      return {} unless File.file?(path)

      YAML.safe_load_file(path, aliases: false) || {}
    end

    def write(id, state)
      FileUtils.mkdir_p(@root)
      File.write(state_path(id), YAML.dump(state))
    end

    def state_path(id)
      File.join(@root, "#{id}.yml")
    end
  end
end
