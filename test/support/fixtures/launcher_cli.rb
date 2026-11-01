# frozen_string_literal: true

# Executes the public CLI with the same finite preflight/worker seam as warm
# launcher fixtures. Mutable Git authority must arrive from the existing broker.
# CLI exit codes, durable reports and child PIDs remain production observations.
require_relative '../../launcher_support'
require_relative '../../coding_skill_support'
raise "missing shared launcher authority" unless MemoryGit::Session.transport.is_a?(MemoryGit::Client)
root, data, *arguments = ARGV
context = Object.new.extend(LauncherSupport)
# The parent passes only its registered fixture hosts. Queries independently
# recheck live kernel birth/parent/group; no report supplies observed values.
context.instance_variable_set(:@fixture_processes,
  JSON.parse(ENV.delete("ACT_TEST_LAUNCHER_PROCESSES") || "{}").transform_keys { |pid| Integer(pid, 10) })
context.instance_variable_set(:@root, root)
context.instance_variable_set(:@data, data)
context.instance_variable_set(:@ordinary, File.join(root, 'ordinary'))
context.instance_variable_set(:@fake, File.join(root, 'codex'))
context.instance_variable_set(:@store, AgentCodingTool::StateStore.new(File.join(data, 'state')))
context.instance_variable_set(:@memory_world, MemoryGit::Session.transport)
# Cold overlap checks use the real worker's recorded PID/parent/group evidence.
context.instance_variable_set(:@real_process, true)
context.instance_variable_set(:@fake_mode, JSON.parse(File.binread(File.join(root, 'fake-settings.json'))).fetch('mode'))
context.instance_variable_set(:@fake_version, 'codex-cli 0.162.1')
context.instance_variable_set(:@fake_help, '--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model')
context.instance_variable_set(:@fake_auth, 'Logged in using ChatGPT')
context.instance_variable_set(:@fake_sandbox_help, 'Usage: codex sandbox [OPTIONS] [COMMAND]...')
ENV['PATH'] = "#{root}:#{ENV.fetch('PATH')}"
ENV['AGENT_CODING_TOOL_DATA_DIR'] = data
constructor = AgentCodingTool::Launcher.method(:new)
AgentCodingTool::Launcher.stub(:new, ->(**options) { constructor.call(**options, spawner: context.method(:spawn_fake_worker)) }) do
  MemoryGit::Session.with_capture(context.method(:unit_capture)) do
    ARGV.replace(arguments)
    load File.expand_path('../../../bin/agent-coding-tool', __dir__)
  end
end
