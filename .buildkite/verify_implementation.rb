# frozen_string_literal: true

require_relative "../test/support/no_git_execution"
require "tmpdir"
require "stringio"
require "timeout"

# Guarded smoke proof through the actual adapters and verified package sources.
# Uses disposable YAML and real binary pipes, without any child execution.
# Bounds startup and both real adapter handoffs; timeout fails the job.
Timeout.timeout(30) do
  selection = ARGV.fetch(0)
  raise "invalid probe selection" unless %w[default legacy split].include?(selection)
  if selection == "default"
    raise "default probe inherited selection" if ENV.key?("ACT_IMPLEMENTATION") || ENV.key?("ACT_RESOLVED_COMPOSITION")
  end
  mode = selection == "default" ? "split" : selection
  require_relative "../lib/agent_coding_tool"
  if selection == "default" && AgentCodingTool::Bootstrap.file_mode(AgentCodingTool::Bootstrap::ROOT)
    raise "default probe found .env selection"
  end
  composition = AgentCodingTool::Bootstrap::COMPOSITION
  raise "wrong implementation" unless composition.fetch("mode") == mode
  raise "development composition" if mode == "split" && composition["qualification"] != "published"
  calls = []
  observer = TracePoint.new(:call) do |event|
    if (event.defined_class.name == "ActTasks::TaskStore" && event.method_id == :load) ||
        (event.defined_class.name == "ActObservability::GateCapture" && event.method_id == :run)
      calls << File.realpath(event.path)
    end
  end
  observer.enable do
    Dir.mktmpdir("act-ci-probe-") do |directory|
      task = { "id" => "CI", "title" => "CI probe", "repositories" => { "fixture" => { "access" => "read_only" } } }
      File.write(File.join(directory, "CI.yml"), YAML.dump(task))
      raise "task handoff failed" unless AgentCodingTool::TaskStore.new(directory).load("CI") == task
      output, error = StringIO.new("".b), StringIO.new("".b)
      capture = AgentCodingTool::GateCapture.new(directory, "ci", out: output, err: error)
      value = capture.run { |pipes| pipes[:out].write("out\x00\xff".b); pipes[:err].write("err\x80".b); :complete }
      raise "capture handoff failed" unless value == :complete && output.string == "out\x00\xff".b &&
        error.string == "err\x80".b && capture.result.fetch("status") == "complete"
    end
  end
  expected = if mode == "split"
               { "act-tasks" => "lib/act_tasks/task_store.rb", "act-observability" => "lib/act_observability/gate_capture.rb" }.map do |name, source|
                 File.join(composition.fetch("packages").fetch(name).fetch("root"), source)
               end
             else
               []
             end
  raise "package implementation was bypassed" unless calls.sort == expected.sort
  puts JSON.pretty_generate("selection" => selection, "composition" => composition, "executed_package_sources" => calls)
end
