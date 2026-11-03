# frozen_string_literal: true

# Cold native acceptance child: refuses any root other than its parent's freshly
# generated disposable fixture. Only external PR/liveness observations are faked.
require "minitest"
require "agent_coding_tool"
require_relative "../external_cleanup_cases"

data, head, merged = ARGV
root = File.realpath(ENV.fetch("TMPDIR"))
abort "foreign cleanup fixture" unless File.basename(root).start_with?("act-external-cleanup-") &&
  data == File.join(root, "data") && File.realpath(data) == data
handler = AgentCodingTool::CleanupManager.new(data_root: data,
  provider: ExternalCleanupCases::Provider.new(head, merged), liveness: ExternalCleanupCases::Liveness.new)
status = AgentCodingTool::CleanupManager.stub(:new, handler) do
  AgentCodingTool::CLI.run(%w[cleanup TASK], root: root, data_root: data)
end
exit status
