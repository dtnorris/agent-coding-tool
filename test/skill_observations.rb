# frozen_string_literal: true

require_relative "git_contract/observations"

# Fixed immutable-source responses at the existing CommandRunner protocol.
# ACT still validates pins, bytes, encoding, YAML and prompt/state handoffs.
module SkillObservations
  ENVIRONMENT = { "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0" }.freeze

  # Returns one exact source observation, including the material Git environment.
  # Boolean success is CommandRunner's protocol, never a fabricated native status.
  def self.read(root:, path:, identity:, text:, success: true, stderr: "")
    GitContract::Observation.new(argv: [ENVIRONMENT, "git", "--no-replace-objects", "-C", root,
      "cat-file", "blob", "#{identity.fetch('revision')}^{commit}:#{path}"], cwd: nil,
      result: [text.b, stderr.b, success])
  end

  # Returns a finite replay of explicitly named default coding/planning reads.
  # Unknown names raise KeyError. Callers must verify consumption, even on refusal.
  def self.defaults(names, root: AgentCodingTool::PromptRenderer::SKILL_ROOT)
    renderer = AgentCodingTool::PromptRenderer
    sources = {
      "coding" => [renderer::SKILL_PATH, renderer::SKILL_IDENTITY, CodingSkillSupport::TEXT],
      "planning" => [renderer::PLANNING_SKILL_PATH, renderer::PLANNING_SKILL_IDENTITY, CodingSkillSupport::PLANNING_TEXT]
    }
    GitContract::Replay.new(names.map do |name|
      path, identity, text = sources.fetch(name)
      read(root: root, path: path, identity: identity, text: text)
    end)
  end
end
