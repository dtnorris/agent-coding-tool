# frozen_string_literal: true

# Reviewed controller-death fixture. The only descendant is the fixed harmless
# inference substitute; production supervision and durable accounting are real.
require_relative "../../../lib/agent_coding_tool"
require_relative "../../../lib/agent_coding_tool/native_pilot_executor"
require_relative "../native_pilot_processes"
directory = File.realpath(ARGV.fetch(0))
config = JSON.parse(File.binread(File.join(directory, "config.json")))
NativePilotProcesses.with_boundary do
  executor = AgentCodingTool::NativePilotExecutor.new(directory)
  executor.capture("gate", config.fetch("gate_argv"), cwd: config.fetch("manager_cwd"), input: "")
end
