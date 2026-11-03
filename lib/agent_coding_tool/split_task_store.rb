# frozen_string_literal: true

require File.join(AgentCodingTool::Bootstrap::COMPOSITION.fetch("packages").fetch("act-tasks").fetch("root"), "lib/act_tasks")

module AgentCodingTool
  # Keeps the main TaskStore API and rescue type while delegating schema/loading
  # to the verified package. Checkpoint policy and all orchestration stay in main.
  class TaskStore
    VALID_ACCESS = ActTasks::TaskStore::VALID_ACCESS

    # Binds a YAML root; initialization performs no reads and raises no errors.
    def initialize(root)
      @store = ActTasks::TaskStore.new(root)
    end

    # Returns one validated task; translates package metadata errors while YAML
    # and filesystem exceptions retain their original classes and causes.
    def load(id)
      @store.load(id)
    rescue ActTasks::InvalidTask => error
      raise InvalidTask, error.message
    end

    # Returns the filename-sorted collection with the same error contract as load.
    def all
      @store.all
    rescue ActTasks::InvalidTask => error
      raise InvalidTask, error.message
    end

    # Returns the package's task path for an ID without reading the filesystem.
    def task_path(id)
      @store.task_path(id)
    end
  end
end
