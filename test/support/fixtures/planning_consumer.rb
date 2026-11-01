# frozen_string_literal: true

# Regenerates one saved prompt in a fresh interpreter with immutable default
# source authority. InvalidState exits 2; other failures retain native diagnostics.
require_relative '../../coding_skill_support'
dir, root, pin = ARGV
renderer = AgentCodingTool::PromptRenderer.new(skill_root: root, planning_skill_identity: JSON.parse(pin))
coordinator = AgentCodingTool::Coordinator.new(
  task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
  state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
  repo_inspector: nil, prompt_renderer: renderer, prompt_root: File.join(dir, "state", "prompts"))
begin
  STDOUT.binmode.write(coordinator.launch_prompt("T"))
rescue AgentCodingTool::InvalidState => error
  warn error.message
  exit 2
end
