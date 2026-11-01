# frozen_string_literal: true

module ResetFaultBoundary
  def initialize(**options)
    super(**options.merge(fault: ->(phase, _receipt) {
      raise IOError, "injected #{phase}" if phase == ENV["ACT28_RESET_FAULT"]
    }))
  end
  def retire_evidence!(*arguments)
    return if ENV["ACT28_BREAK_RETIREMENT"] == "1"
    super
  end
end
AgentCodingTool::TaskReset.prepend(ResetFaultBoundary)
if ENV["ACT28_LEGACY_LAYOUT"] == "1"
  module ResetLegacyWorktrees
    def initialize(**options)
      super(**options.merge(attempt_paths: false, invocation_id: nil))
    end
  end
  module ResetLegacyReport
    def save_report
      @report.delete("worktree_layout")
      super
    end
  end
  AgentCodingTool::WorktreeManager.prepend(ResetLegacyWorktrees)
  AgentCodingTool::Launcher.prepend(ResetLegacyReport)
end
