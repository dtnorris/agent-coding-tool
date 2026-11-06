# frozen_string_literal: true

require "json"
require_relative "../checkpoint_processes"

# Observes the real package loader/capture through the actual bin entrypoint.
# Only the declared non-Git checkpoint validator may execute; the inherited
# guard rejects other processes. Product policy, pipes and files remain real.
root = ARGV.shift
calls = []
captures = []
observer = TracePoint.new(:call) do |event|
  if event.defined_class.name == "ActTasks::TaskStore" && %i[load all].include?(event.method_id)
    calls << { "method" => event.method_id, "path" => event.path }
  end
  if event.defined_class.name == "ActObservability::GateCapture" && event.method_id == :run
    captures << event.path
  end
end
observer.enable
at_exit do
  observer.disable
  warn "TASK_SOURCE=#{JSON.generate(calls)}"
  warn "\nCAPTURE_SOURCE=#{JSON.generate(captures)}"
end
if ARGV.first == "store"
  ARGV.shift
  require File.join(root, "lib/agent_coding_tool")
  store = AgentCodingTool::TaskStore.new(ARGV.shift)
  begin
    puts JSON.generate("path" => store.task_path("T1"), "tasks" => store.all, "task" => store.load("T1"))
    exit 0
  rescue AgentCodingTool::InvalidTask => error
    warn "ERROR: #{error.message}; cause=#{error.cause.class}"
    exit 2
  end
end
load File.join(root, "bin/agent-coding-tool")
