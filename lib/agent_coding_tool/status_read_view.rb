# frozen_string_literal: true

module AgentCodingTool
  # First successful reads retained for one advisory CLI invocation. These are
  # per-file observations, not an atomic registry snapshot or writer authority.
  # Atomic replacement after a read is visible to the next invocation; no view
  # survives CLI dispatch. Store validation/errors remain at the first read.
  module StatusReadView
    # Reads each registered filename through the selected legacy/split validator.
    # Does not expose writes or memoize a failed read.
    class Tasks
      # Binds the production store and an empty invocation-local task collection.
      def initialize(store)
        @store = store
        @loaded = {}
      end

      # Returns the first validated definition for id; original errors propagate.
      def load(id)
        @loaded.fetch(id) { @loaded[id] = @store.load(id) }
      end

      # Returns filename-sorted definitions. The directory and individual files
      # are observed separately; deletion before first read refuses normally.
      def all
        @all ||= Dir.glob(File.join(File.dirname(task_path("unused")), "*.yml")).sort.map do |path|
          load(File.basename(path, ".yml"))
        end
      end

      # Returns the original task path without reading or normalizing task IDs.
      def task_path(id) = @store.task_path(id)
    end

    # Retains validated state, including absent state, without a write interface.
    class States
      # Binds the production store; construction reads and creates nothing.
      def initialize(store)
        @store = store
        @loaded = {}
      end

      # Returns the first successful state observation; damaged state still raises.
      def load(id)
        @loaded.fetch(id) { @loaded[id] = @store.load(id) }
      end

      # Returns the original state path for existing provenance/path validation.
      def state_path(id) = @store.state_path(id)
    end

    # Shares validated reset receipts between lifecycle and presentation reads.
    class Resets
      # Binds a real reset inspector; no history is read until requested.
      def initialize(inspector)
        @inspector = inspector
        @history = {}
      end

      # Returns first validated receipts for id; malformed evidence still raises.
      def history(id)
        @history.fetch(id) { @history[id] = @inspector.history(id) }
      end

      # Preserves the real readiness checks and their blockers/errors.
      def readiness(id) = @inspector.readiness(id)
    end
  end
end
