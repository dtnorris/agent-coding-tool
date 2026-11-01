# frozen_string_literal: true

require_relative '../../../lib/agent_coding_tool'
require_relative '../fake_inspector'
require_relative '../../coding_skill_support'

# Competing cold writers retain real reservation locks and atomic publication.
# Only repository observations are finite fixtures; invalid state exits two.
directory, operation, id, identifier = ARGV
coordinator = AgentCodingTool::Coordinator.new(
  task_store: AgentCodingTool::TaskStore.new(File.join(directory, 'tasks')),
  state_store: AgentCodingTool::StateStore.new(File.join(directory, 'state')),
  repo_inspector: TestHelpers::FakeInspector.new(heads: { 'alpha' => 'a' * 40, 'beta' => 'b' * 40 }),
  prompt_renderer: AgentCodingTool::PromptRenderer.new, prompt_root: File.join(directory, 'state', 'prompts'))
begin
  activity = coordinator.external_activity
  case operation
  when 'report'
    activity.report(id, reporter: 'operator', kind: 'fake-codex', identifier: identifier)
  when 'start'
    activity.with_lock { |lock| coordinator.start(id, reservation_lock: lock) }
  else
    abort 'unknown external activity fixture operation'
  end
rescue AgentCodingTool::InvalidState
  exit 2
end
