# frozen_string_literal: true

require_relative '../../../lib/agent_coding_tool'
require_relative '../fake_inspector'
require_relative '../../coding_skill_support'
require_relative '../../launcher_support'

# Cold public launcher with only the declared worker/capability boundaries
# adapted. The shared broker owns Git; production owns locks, signals and files.
class ColdLauncherFixture
  include LauncherSupport

  # Loads the parent's immutable invocation root and finite fake capabilities.
  # Missing settings or the shared-world preload fail before public execution.
  def initialize
    @root = File.realpath(ENV.fetch('ACT_LAUNCH_ROOT'))
    @data, @ordinary, @remote, @fake = %w[data ordinary remote.git codex].map { |name| File.join(@root, name) }
    @store = AgentCodingTool::StateStore.new(File.join(@data, 'state'))
    @memory_world = MemoryGit::Session.transport
    raise 'missing launcher world handoff' unless @memory_world.is_a?(MemoryGit::Client)
    @fake_mode = JSON.parse(File.binread(File.join(@root, 'fake-settings.json'))).fetch('mode')
    @fake_auth = 'Logged in using ChatGPT'
    @fake_help = '--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model'
    @fake_version = 'codex-cli 0.162.1'
    @fake_sandbox_help = 'Usage: codex sandbox [OPTIONS] [COMMAND]...'
  end
end

fixture = ColdLauncherFixture.new
adapter = Module.new do
  define_method(:initialize) do |**options|
    super(**{ spawner: fixture.method(:spawn_fake_worker) }.merge(options))
  end
end
AgentCodingTool::Launcher.prepend(adapter)
MemoryGit::Session.with_capture(fixture.method(:unit_capture)) do
  load File.expand_path('../../../bin/agent-coding-tool', __dir__)
end
