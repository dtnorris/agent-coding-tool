# frozen_string_literal: true

# Runs one competing report/start against the parent's durable fixture stores.
# Each invocation has fresh Ruby state and the same finite repository authorities.
# InvalidState is the genuine losing outcome; other failures remain nonzero.
require_relative '../../../lib/agent_coding_tool'
require_relative '../../coding_skill_support'

# Finite, read-only authority answers for the two registered race tasks. No
# repositories or Git commands are involved in either competing interpreter.
class RaceInspector
  # Returns the fixture's configured public authority and branch for a task repo.
  def repository_authority(name, _spec)
    ["git@github.com:example/#{name}.git", 'main']
  end

  # Resolves only the two prepared heads; unexpected authority names raise.
  def pushed_heads(references)
    heads = { 'alpha' => 'a' * 40, 'beta' => 'b' * 40 }
    references.to_h do |reference|
      [[reference.fetch('remote_url'), reference.fetch('branch')], heads.fetch(reference.fetch('name').split('/').last)]
    end
  end
end
data, operation, id, identifier = ARGV
coordinator = AgentCodingTool::Coordinator.new(
  task_store: AgentCodingTool::TaskStore.new(File.join(data, 'tasks')),
  state_store: AgentCodingTool::StateStore.new(File.join(data, 'state')),
  repo_inspector: RaceInspector.new,
  prompt_renderer: AgentCodingTool::PromptRenderer.new,
  prompt_root: File.join(data, 'state', 'prompts'))
begin
  activity = coordinator.external_activity
  if operation == 'report'
    options = identifier.empty? ? {} : { identifier: identifier }
    activity.report(id, reporter: 'operator', kind: 'fake-codex', **options)
  elsif operation == 'start'
    activity.with_lock { |lock| coordinator.start(id, reservation_lock: lock) }
  else
    abort 'unknown race operation'
  end
rescue AgentCodingTool::InvalidState
  exit 2
end
