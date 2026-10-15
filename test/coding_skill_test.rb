# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

# Exercises real local Git objects with synthetic skills, independent of the
# operator's checkout, network and canonical skill wording.
class CodingSkillTest < Minitest::Test
  include TestHelpers

  # Returns a minimal legacy-compatible task; no new task metadata is required.
  def task
    { "id" => "T", "title" => "Inspection or code", "repositories" => { "alpha" => { "access" => "write" } } }
  end

  # Verifies complete byte-preserving inclusion, pin identity and offline-only
  # object access. Local Git errors propagate rather than bypassing verification.
  def test_complete_skill_once_with_identity_and_only_offline_git_reads
    renderer = AgentCodingTool::PromptRenderer.new
    capture = Open3.method(:capture3)
    calls = []
    prompt = Open3.stub(:capture3, lambda { |*args|
      calls << args
      capture.call(*args)
    }) { renderer.render(task, {}) }
    assert_equal 1, prompt.scan(CodingSkillSupport::TEXT).length
    assert_includes prompt, "Revision: #{renderer.skill_identity.fetch('revision')}\n"
    assert_includes prompt, "SHA-256: #{Digest::SHA256.hexdigest(CodingSkillSupport::TEXT)}\n"
    assert_includes prompt, "Git restrictions and acceptance criteria take precedence."
    assert_equal [[{ "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0" },
                   "git", "--no-replace-objects", "-C", AgentCodingTool::PromptRenderer::SKILL_ROOT,
                   "cat-file", "blob", "#{renderer.skill_identity.fetch('revision')}^{commit}:#{AgentCodingTool::PromptRenderer::SKILL_PATH}"]], calls
    assert_equal prompt, renderer.render(task, {})
  end

  # Covers read-only and explicit non-coding exemptions without title heuristics.
  def test_every_worker_prompt_includes_skill_regardless_of_checkpoint_or_access
    %w[write read_only].each do |access|
      [nil, { "mode" => "exempt", "category" => "planning", "reason" => "Plan only." }].each do |policy|
        definition = task.merge("repositories" => { "alpha" => { "access" => access } })
        definition["checkpoint"] = policy if policy
        assert_equal 1, AgentCodingTool::PromptRenderer.new.render(definition, {}).scan(CodingSkillSupport::TEXT).length
      end
    end
  end

  # Missing checkouts/objects and digest drift must raise, never return a prompt.
  def test_missing_source_incorrect_revision_and_integrity_mismatch_fail_explicitly
    renderer = AgentCodingTool::PromptRenderer
    variants = [
      [{ skill_root: File.join(renderer::SKILL_ROOT, "missing") }, /missing Git checkout/],
      [{ skill_identity: renderer::SKILL_IDENTITY.merge("revision" => "0" * 40) }, /pinned source unavailable/],
      [{ skill_identity: renderer::SKILL_IDENTITY.merge("sha256" => "0" * 64) }, /integrity mismatch/],
      [{ skill_identity: { "revision" => "main", "sha256" => "0" * 64 } }, /malformed pinned identity/]
    ]
    variants.each do |options, message|
      error = assert_raises(AgentCodingTool::InvalidState) { renderer.new(**options).render(task, {}) }
      assert_match message, error.message
    end
  end

  # A matching digest does not make malformed metadata or an empty body valid.
  def test_malformed_metadata_is_rejected_even_with_matching_fingerprint
    ["not frontmatter\n", "---\nname: [broken\n---\nBody\n",
     CodingSkillSupport::TEXT.sub("license: MIT", "license: false"),
     CodingSkillSupport::TEXT.sub("Fixture coding instructions.", ""),
     CodingSkillSupport::TEXT.sub("Fixture instructions: inspect, change, verify.", "")].each do |text|
      with_skill_source(text) do |root, identity|
        error = assert_raises(AgentCodingTool::InvalidState) do
          AgentCodingTool::PromptRenderer.new(skill_root: root, skill_identity: identity).render(task, {})
        end
        assert_match(/coding skill: (malformed|Psych::)/, error.message)
      end
    end
  end

  # Failed first preparation/retry leaves prompt bytes, checkpoint and state
  # unchanged, including recorded outcomes and started markers.
  def test_source_failures_do_not_partially_prepare_or_erase_prior_evidence
    with_workspace do |dir|
      write_task(dir, id: "T")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      prepared = coordinator.prepare("T")
      store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      state = prepared.fetch("state").merge("checkpoint" => { "status" => "preserved" },
                                            "started_at" => "2026-10-14T00:00:00Z",
                                            "result" => { "outcome" => "failed" })
      store.write("T", state)
      broken = AgentCodingTool::PromptRenderer.new(skill_root: File.join(dir, "absent"))
      coordinator = coordinator_with_renderer(dir, broken)
      before = directory_bytes(dir)
      assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("T", retry_result: true) }
      assert_equal before, directory_bytes(dir)
      assert_raises(AgentCodingTool::InvalidState) { coordinator.launch_prompt("T") }
      assert_equal before, directory_bytes(dir)

      write_task(dir, id: "NEW")
      before = directory_bytes(dir)
      assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("NEW") }
      assert_equal before, directory_bytes(dir)
      refute File.exist?(store.state_path("NEW"))
    end
  end

  # Pinned object reads ignore both a newer main and uncommitted working text.
  # A fresh renderer/coordinator proves the guidance is not an in-memory cache.
  def test_branch_movement_and_dirty_source_do_not_change_prepare_or_cold_launch
    with_skill_source(CodingSkillSupport::TEXT) do |root, identity|
      with_workspace do |dir|
        write_task(dir, id: "T")
        renderer = AgentCodingTool::PromptRenderer.new(skill_root: root, skill_identity: identity)
        coordinator = coordinator_with_renderer(dir, renderer)
        prepared = coordinator.prepare("T")
        assert_equal identity, prepared.fetch("state").fetch("coding_skill")
        source = File.join(root, AgentCodingTool::PromptRenderer::SKILL_PATH)
        File.write(source, CodingSkillSupport::TEXT + "Newer branch instructions.\n")
        commit_source(root)
        File.write(source, "malformed dirty working copy")
        cold = coordinator_with_renderer(dir, AgentCodingTool::PromptRenderer.new(skill_root: root, skill_identity: identity))
        assert_equal prepared.fetch("prompt"), cold.launch_prompt("T")
        assert_equal prepared.fetch("prompt"), cold.prepare("T").fetch("prompt")
        assert_equal prepared.fetch("prompt"), File.binread(prepared.fetch("state").fetch("prompt_path"))
      end
    end
  end

  # ACT upgrades or corrupt recorded pins cannot silently migrate prior prompts.
  # Legacy state can be explicitly prepared, but cannot launch without a pin.
  def test_pin_changes_block_reprepare_and_launch_while_legacy_can_explicitly_prepare
    with_workspace do |dir|
      write_task(dir, id: "T")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      prepared = coordinator.prepare("T")
      store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      [nil, { "revision" => "b" * 40, "sha256" => "c" * 64 }].each do |pin|
        state = prepared.fetch("state").merge("coding_skill" => pin)
        store.write("T", state)
        before = directory_bytes(dir)
        assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("T") }
        assert_raises(AgentCodingTool::InvalidState) { coordinator.launch_prompt("T") }
        assert_equal before, directory_bytes(dir)
      end
      legacy = prepared.fetch("state").reject { |key, _value| key == "coding_skill" }
      store.write("T", legacy)
      assert_raises(AgentCodingTool::InvalidState) { coordinator.launch_prompt("T") }
      assert_equal prepared.fetch("prompt"), coordinator.prepare("T").fetch("prompt")
    end
  end

  private

  # Builds a production coordinator for dir with a supplied renderer; returns it.
  def coordinator_with_renderer(dir, renderer)
    AgentCodingTool::Coordinator.new(
      task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
      state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
      repo_inspector: TestHelpers::FakeInspector.new(heads: { "alpha" => "a" * 40 }),
      prompt_renderer: renderer, prompt_root: File.join(dir, "state", "prompts")
    )
  end

  # Returns all regular-file bytes under dir for no-partial-write assertions.
  def directory_bytes(dir)
    Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
       .to_h { |path| [path, File.binread(path)] }
  end

  # Yields a private Git clone and valid pin for text; removes it on exit.
  # Raises on clone/commit failures, never falling back to operator source.
  def with_skill_source(text)
    Dir.mktmpdir do |dir|
      root = File.join(dir, "source")
      _out, error, status = Open3.capture3("git", "clone", "--no-hardlinks", AgentCodingTool::PromptRenderer::SKILL_ROOT, root)
      raise error unless status.success?
      File.write(File.join(root, AgentCodingTool::PromptRenderer::SKILL_PATH), text)
      commit_source(root) unless text == CodingSkillSupport::TEXT
      revision, error, status = Open3.capture3("git", "-C", root, "rev-parse", "HEAD")
      raise error unless status.success?
      yield root, { "revision" => revision.strip, "sha256" => Digest::SHA256.hexdigest(text) }
    end
  end

  # Commits only isolated test source text; returns nil or raises on Git errors.
  def commit_source(root)
    [%w[add .], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "fixture change"]].each do |args|
      _out, error, status = Open3.capture3("git", "-C", root, *args)
      raise error unless status.success?
    end
    nil
  end
end
