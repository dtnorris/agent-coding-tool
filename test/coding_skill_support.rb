# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "support/memory_git/session"
require_relative "../lib/agent_coding_tool"
require "json"

# Hermetic source defaults for existing in-process and child CLI tests. The
# canonical text is not copied here: tests create their own valid skill and pin.
# Production rendering, object reads, integrity and lifecycle checks still run.
module CodingSkillSupport
  # Preserve production adoption identities before installing hermetic sources.
  PUBLISHED_CODING = AgentCodingTool::PromptRenderer::SKILL_IDENTITY
  PUBLISHED_PLANNING = AgentCodingTool::PromptRenderer::PLANNING_SKILL_IDENTITY
  TEXT = "---\nname: karpathy-manning-dtnorris-guidelines\ndescription: Fixture coding instructions.\nlicense: MIT\n---\n\nFixture instructions: inspect, change, verify.\n"
  PLANNING_TEXT = "---\nname: agentic-task-planning\ndescription: Fixture planning instructions.\nlicense: MIT\n---\n\nFixture planning: outcomes, ownership, integration, recovery, acceptance.\n"

  # Immutable, read-only source boundary for default pins in each interpreter.
  # Exact source requests are repeatable; mutations/unknown reads fail closed.
  class Source
    # Copies reviewed source observations; no mutable Git state is shared.
    def initialize(fixture)
      @fixture = fixture
    end

    # Returns raw pinned bytes only for the two exact blob requests and envelope.
    # Production still parses metadata, verifies hashes and refuses invalid pins.
    def call(argv, cwd: nil, env: {}, input: "", timeout: nil, **options)
      source = [[AgentCodingTool::PromptRenderer::SKILL_PATH, "identity", TEXT],
                [AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH, "planning_identity", PLANNING_TEXT]].find do |path, identity, _text|
        argv == ["git", "--no-replace-objects", "-C", @fixture.fetch("root"), "cat-file", "blob",
                 "#{@fixture.fetch(identity).fetch('revision')}^{commit}:#{path}"]
      end
      raise MemoryGit::Mismatch, "unknown immutable skill request" unless source && cwd.nil? && input == "" && timeout.nil? && options.empty? &&
        env == { "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0" }
      AgentCodingTool::CommandResult.new(stdout: source.last.b, stderr: "".b, exitstatus: 0)
    end
  end

  # Installs test-only source defaults without Git or a child process. Children
  # receive an immutable pin/source snapshot through the explicitly approved preload.
  # Only the creating interpreter cleans up the physical source-presence stub.
  def self.install
    unless ENV["ACT_TEST_CODING_SKILL"]
      root = Dir.mktmpdir("act-coding-skill-")
      path = File.join(root, AgentCodingTool::PromptRenderer::SKILL_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, TEXT)
      planning_path = File.join(root, AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH)
      FileUtils.mkdir_p(File.dirname(planning_path))
      File.write(planning_path, PLANNING_TEXT)
      FileUtils.mkdir_p(File.join(root, ".git"))
      ENV["ACT_TEST_CODING_SKILL"] = JSON.generate(
        "root" => root, "identity" => { "revision" => "1" * 40, "sha256" => Digest::SHA256.hexdigest(TEXT) },
        "planning_identity" => { "revision" => "1" * 40, "sha256" => Digest::SHA256.hexdigest(PLANNING_TEXT) }
      )
      cleanup = proc { FileUtils.remove_entry(root) if File.directory?(root) }
      defined?(Minitest) ? Minitest.after_run(&cleanup) : at_exit(&cleanup)
    end
    fixture = JSON.parse(ENV.fetch("ACT_TEST_CODING_SKILL"))
    renderer = AgentCodingTool::PromptRenderer
    renderer.send(:remove_const, :SKILL_ROOT)
    renderer.const_set(:SKILL_ROOT, fixture.fetch("root"))
    renderer.send(:remove_const, :SKILL_IDENTITY)
    renderer.const_set(:SKILL_IDENTITY, fixture.fetch("identity").freeze)
    renderer.send(:remove_const, :PLANNING_SKILL_IDENTITY)
    renderer.const_set(:PLANNING_SKILL_IDENTITY, fixture.fetch("planning_identity").freeze)
    MemoryGit::Session.skill_root = fixture.fetch("root")
    MemoryGit::Session.skill_transport = Source.new(fixture)
    fixture.fetch("root")
  end
end

CodingSkillSupport.install
