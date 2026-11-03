# frozen_string_literal: true

require "json"

# Observes calls to the real loader while executing the actual bin entrypoint.
# No TaskStore, CLI parser or filesystem operation is substituted. Unprepared
# status needs no remote observation; the inherited guard rejects any execution.
root = ARGV.shift
calls = []
observer = TracePoint.new(:call) do |event|
  if event.defined_class.name == "ActTasks::TaskStore" && %i[load all].include?(event.method_id)
    calls << { "method" => event.method_id, "path" => event.path }
  end
end
observer.enable
at_exit do
  observer.disable
  warn "TASK_SOURCE=#{JSON.generate(calls)}"
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
