# frozen_string_literal: true

require "open3"

# Native source fixtures are actual private repositories, including cold readers.
# The memory source installer remains confined to ordinary interpreters.
module CodingSkillSupport
  # Initializes disposable immutable source history or reuses its inherited pin.
  # Git failures raise; no operator repository is mutated.
  def self.install_native
    unless ENV["ACT_TEST_CODING_SKILL"]
      root = Dir.mktmpdir("act-native-skills-")
      [ [AgentCodingTool::PromptRenderer::SKILL_PATH, TEXT],
        [AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH, PLANNING_TEXT] ].each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.binwrite(File.join(root, path), text)
      end
      [["init", "--initial-branch=main"], ["add", "."],
       ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false", "commit", "-m", "native sources"]].each do |args|
        _out, error, status = Open3.capture3("git", "-C", root, *args)
        raise error unless status.success?
      end
      revision, error, status = Open3.capture3("git", "-C", root, "rev-parse", "HEAD")
      raise error unless status.success?
      ENV["ACT_TEST_CODING_SKILL"] = JSON.generate("root" => root,
        "identity" => { "revision" => revision.strip, "sha256" => Digest::SHA256.hexdigest(TEXT) },
        "planning_identity" => { "revision" => revision.strip, "sha256" => Digest::SHA256.hexdigest(PLANNING_TEXT) })
      cleanup = proc { FileUtils.remove_entry(root) if File.directory?(root) }
      defined?(Minitest) ? Minitest.after_run(&cleanup) : at_exit(&cleanup)
    end
    fixture = JSON.parse(ENV.fetch("ACT_TEST_CODING_SKILL"))
    renderer = AgentCodingTool::PromptRenderer
    { SKILL_ROOT: fixture.fetch("root"), SKILL_IDENTITY: fixture.fetch("identity"),
      PLANNING_SKILL_IDENTITY: fixture.fetch("planning_identity") }.each do |name, value|
      renderer.send(:remove_const, name)
      renderer.const_set(name, value.freeze)
    end
  end
end

CodingSkillSupport.install_native
