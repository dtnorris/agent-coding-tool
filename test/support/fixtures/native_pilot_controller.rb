# frozen_string_literal: true

# Reviewed controller-death fixture. The only descendant is the fixed harmless
# inference substitute; production supervision and durable accounting are real.
require_relative "../../../lib/agent_coding_tool"
require_relative "../../../lib/agent_coding_tool/native_pilot_executor"
require_relative "../native_pilot_processes"

# Terminal fixture boundary at capture's wait, after real launch/admission/fork.
# The controller never returns to capture (including its ensure). No other Ruby
# thread can execute production after completion. STOP lets the test prove this
# state before KILL; the independent supervisor keeps running with fresh coverage.
module ControllerDeathBarrier
  # Accepts capture's supervisor PID without flags and never returns. Foreign
  # calls/threads or failed coverage publication raise before the terminal stop.
  def waitpid(pid, *arguments)
    location = caller_locations(1, 1).first
    raise "foreign controller wait" unless location.absolute_path == NativePilotProcesses::SOURCE &&
      location.base_label == "capture" && arguments.empty? && pid.positive? && Thread.list == [Thread.current]

    FeedbackCoverage.finish if ENV["ACT_COVERAGE_CONTEXT"]
    Process.kill("STOP", Process.pid)
    loop { sleep }
  end
end
Process.singleton_class.prepend(ControllerDeathBarrier)

directory = File.realpath(ARGV.fetch(0))
config = JSON.parse(File.binread(File.join(directory, "config.json")))
NativePilotProcesses.with_boundary do
  executor = AgentCodingTool::NativePilotExecutor.new(directory)
  executor.capture("gate", config.fetch("gate_argv"), cwd: config.fetch("manager_cwd"), input: "")
end
