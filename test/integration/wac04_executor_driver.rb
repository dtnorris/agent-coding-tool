# frozen_string_literal: true

# Fixed controller-death rehearsal entry, not a command dispatch endpoint.
require_relative "../../lib/agent_coding_tool"
require_relative "../../lib/agent_coding_tool/native_pilot_executor"
pilot = AgentCodingTool::NativePilotExecutor.new(ARGV.fetch(0))
config = JSON.parse(File.binread(File.join(ARGV.fetch(0), "config.json")))
pilot.capture("gate", config.fetch("gate_argv"), input: "", cwd: config.fetch("probe_cwd"))
