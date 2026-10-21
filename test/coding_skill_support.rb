# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../lib/agent_coding_tool"

# Hermetic source defaults for existing in-process and child CLI tests. The
# canonical text is not copied here: tests create their own valid skill and pin.
# Production rendering, object reads, integrity and lifecycle checks still run.
module CodingSkillSupport
  TEXT = "---\nname: karpathy-manning-dtnorris-guidelines\ndescription: Fixture coding instructions.\nlicense: MIT\n---\n\nFixture instructions: inspect, change, verify.\n"
  PLANNING_TEXT = "---\nname: agentic-task-planning\ndescription: Fixture planning instructions.\nlicense: MIT\n---\n\nFixture planning: outcomes, ownership, integration, recovery, acceptance.\n"

  # Installs fixture constructor defaults once per process. Child Ruby commands
  # reuse the parent's source/pin through test-only ENV and RUBYOPT. Ordinary
  # setup creates files only; native selections create genuine Git objects.
  # Git errors raise; no operator checkout/network is used. Returns fixture root.
  def self.install
    unless ENV["ACT_TEST_CODING_SKILL"]
      root = Dir.mktmpdir("act-coding-skill-")
      path = File.join(root, AgentCodingTool::PromptRenderer::SKILL_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, TEXT)
      planning_path = File.join(root, AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH)
      FileUtils.mkdir_p(File.dirname(planning_path))
      File.write(planning_path, PLANNING_TEXT)
      if ENV["ACT_ORDINARY_SUITE"] == "1"
        # Only the external checkout-presence observation is represented here.
        # This directory is never used as a native Git repository or oracle.
        FileUtils.mkdir_p(File.join(root, ".git"))
        revision = "1" * 40
      else
        [%w[init --initial-branch=main], %w[add .],
         ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "skill fixture"]].each do |args|
          _out, error, status = Open3.capture3("git", "-C", root, *args)
          raise error unless status.success?
        end
        revision, error, status = Open3.capture3("git", "-C", root, "rev-parse", "HEAD")
        raise error unless status.success?
      end

      ENV["ACT_TEST_CODING_SKILL"] = JSON.generate(
        "root" => root, "identity" => { "revision" => revision.strip, "sha256" => Digest::SHA256.hexdigest(TEXT) },
        "planning_identity" => { "revision" => revision.strip, "sha256" => Digest::SHA256.hexdigest(PLANNING_TEXT) }
      )
      Minitest.after_run { FileUtils.remove_entry(root) if File.directory?(root) }
    end
    fixture = JSON.parse(ENV.fetch("ACT_TEST_CODING_SKILL"))
    renderer = AgentCodingTool::PromptRenderer
    renderer.send(:remove_const, :SKILL_ROOT)
    renderer.const_set(:SKILL_ROOT, fixture.fetch("root"))
    renderer.send(:remove_const, :SKILL_IDENTITY)
    renderer.const_set(:SKILL_IDENTITY, fixture.fetch("identity").freeze)
    renderer.send(:remove_const, :PLANNING_SKILL_IDENTITY)
    renderer.const_set(:PLANNING_SKILL_IDENTITY, fixture.fetch("planning_identity").freeze)
    fixture.fetch("root")
  end
end

CodingSkillSupport.install
preload = "-r#{__FILE__}"
ENV["RUBYOPT"] = [ENV["RUBYOPT"], preload].compact.join(" ") unless ENV.fetch("RUBYOPT", "").include?(preload)
