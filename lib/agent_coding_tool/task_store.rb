# frozen_string_literal: true

require "yaml"

module AgentCodingTool
  class TaskStore
    VALID_ACCESS = %w[write read_only].freeze

    def initialize(root)
      @root = root
    end

    def load(id)
      path = task_path(id)
      raise InvalidTask, "task not found: #{id}" unless File.file?(path)

      task = YAML.safe_load_file(path, aliases: false) || {}
      validate!(task, path)
      task
    end

    def all
      Dir.glob(File.join(@root, "*.yml")).sort.map do |path|
        task = YAML.safe_load_file(path, aliases: false) || {}
        validate!(task, path)
        task
      end
    end

    def task_path(id)
      File.join(@root, "#{id}.yml")
    end

    private

    def validate!(task, path)
      id = task["id"]
      title = task["title"]
      repositories = task["repositories"]

      raise InvalidTask, "#{path}: id is required" unless id.is_a?(String) && !id.empty?
      raise InvalidTask, "#{path}: title is required" unless title.is_a?(String) && !title.empty?
      unless repositories.is_a?(Hash) && !repositories.empty?
        raise InvalidTask, "#{path}: repositories must be a non-empty mapping"
      end

      repositories.each do |name, spec|
        raise InvalidTask, "#{path}: repository name must be a string" unless name.is_a?(String) && !name.empty?
        unless spec.is_a?(Hash) && VALID_ACCESS.include?(spec["access"])
          raise InvalidTask, "#{path}: #{name} access must be write or read_only"
        end
      end

      depends_on = task.fetch("depends_on", [])
      raise InvalidTask, "#{path}: depends_on must be an array" unless depends_on.is_a?(Array)

      %w[constraints acceptance].each do |field|
        value = task.fetch(field, [])
        raise InvalidTask, "#{path}: #{field} must be an array" unless value.is_a?(Array)
      end
    end
  end
end
