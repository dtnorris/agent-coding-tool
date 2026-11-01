# frozen_string_literal: true

require_relative '../../../lib/agent_coding_tool'
class AgentCodingTool::RetryLiveness
  def self.host_identity = { "fixture_boot" => "deterministic external identity" }
end
# Historical fixture producer only: restore the inspected v1 layout,
# missing host identity and old unguarded retry preparation contract.
if ENV["ACT16_LEGACY"]
  class AgentCodingTool::WorktreeManager
    alias_method :fixture_initialize, :initialize
    def initialize(**options)
      fixture_initialize(**options.merge(attempt_paths: false, invocation_id: nil))
    end
  end
  class AgentCodingTool::AttemptRecovery
    def retry_ready!(*) = nil
  end
  class AgentCodingTool::Launcher
    alias_method :fixture_save_report, :save_report
    def save_report
      %w[worktree_layout worktree_creation prompt_sha256 prompt_bytes host_identity preparation_state execution_state].each { |key| @report.delete(key) }
      fixture_save_report
    end
  end
end
if ENV["ACT16_CREATION_FAULT"]
  class AgentCodingTool::WorktreeManager
    alias_method :fixture_git!, :git!
    def git!(path, *args)
      raise "injected before native add" if args[0, 2] == ["worktree", "add"] && ENV["ACT16_CREATION_FAULT"] == "before"
      output = fixture_git!(path, *args)
      raise "injected after native add" if args[0, 2] == ["worktree", "add"] && ENV["ACT16_CREATION_FAULT"] == "after"
      output
    end
  end
end
if ENV["ACT16_CHILD_START_FAULT"]
  # Installs the fault ahead of the existing worker adapter without aliasing
  # a prepended method back into the class (which would recurse).
  module RetryChildStartFault
    # Supplies the launcher's explicit spawn boundary; no child is created.
    # ENOENT propagates to the production reservation/recovery handler.
    def initialize(**options)
      super(**options.merge(spawner: ->(*) { raise Errno::ENOENT, "fixture spawn failure" }))
    end
  end
  AgentCodingTool::Launcher.prepend(RetryChildStartFault)
end
if ENV["ACT18_BREAK_PROJECTION"]
  module BrokenExternalProjection
    # Negative control removes the required public activity handoff only.
    def statuses(*arguments, **options, &block)
      super.map { |row| row.reject { |key, _value| key == "external_activity" } }
    end
  end
  AgentCodingTool::Coordinator.prepend(BrokenExternalProjection)
end
