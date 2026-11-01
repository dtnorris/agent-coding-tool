# frozen_string_literal: true

require_relative '../../../lib/agent_coding_tool'
require_relative '../../coding_skill_support'

# Regenerates the persisted prompt through production code in a fresh process.
# Pins and data root are explicit; invalid guidance exits with the public refusal.
directory, root, pin = ARGV
renderer = AgentCodingTool::PromptRenderer.new(skill_root: root, planning_skill_identity: JSON.parse(pin))
coordinator = AgentCodingTool::Coordinator.new(
  task_store: AgentCodingTool::TaskStore.new(File.join(directory, 'tasks')),
  state_store: AgentCodingTool::StateStore.new(File.join(directory, 'state')),
  repo_inspector: nil, prompt_renderer: renderer, prompt_root: File.join(directory, 'state', 'prompts'))
begin
  STDOUT.binmode.write(coordinator.launch_prompt('T'))
rescue AgentCodingTool::InvalidState => error
  warn error.message
  exit 2
end
