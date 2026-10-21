# frozen_string_literal: true

require_relative "test_helper"
require_relative "launcher_support"
require "stringio"
require_relative "skill_observations"

# Covers the registered-task journey, explicit designation and immutable source
# refusals. Git history, workers and task/state writes belong only to fixtures.
class PlanningGuidanceTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Public prepare saves the exact handoff; a cold process regenerates it and a
  # real fake-worker process consumes it plus only the existing launch envelope.
  def test_public_prepare_to_cold_regeneration_and_fake_worker_handoff
    fixture(git: true, process: true) do
      designate(@data, "T")
      cli = fixture_cli
      assert_equal 0, cli.run(%w[prepare T]), @err.string
      state = @store.load("T")
      prompt = File.binread(state.fetch("prompt_path"))
      assert_includes @out.string, prompt
      assert_planning_handoff(prompt)
      assert_equal "required", state.fetch("planning_guidance")
      assert_equal AgentCodingTool::PromptRenderer::PLANNING_SKILL_IDENTITY, state.fetch("planning_skill")
      assert_equal AgentCodingTool::PromptRenderer::SKILL_IDENTITY, state.fetch("coding_skill")
      cold, error, status = cold_consume(@data)
      assert status.success?, error
      assert_equal prompt, cold

      # Verifies that the journey assertion notices a missing required handoff.
      broken = prompt.sub(CodingSkillSupport::PLANNING_TEXT, "")
      assert_raises(Minitest::Assertion) { assert_planning_handoff(broken) }
      File.binwrite(state.fetch("prompt_path"), broken)
      before = directory_bytes(@data)
      assert_raises(AgentCodingTool::InvalidState) { launcher.launch("T") }
      assert_equal before, directory_bytes(@data)
      refute File.exist?(File.join(@root, "stdin"))
      assert_empty Dir.glob("#{@data}-runs/T/*/handoff.json")
      File.binwrite(state.fetch("prompt_path"), prompt)

      assert_equal 0, launcher.launch("T")
      report = JSON.parse(File.binread(Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)))
      assert_equal prompt, File.binread(report.fetch("prompt_path"))
      consumed = File.binread(File.join(@root, "stdin"))
      assert_equal File.binread(report.fetch("stdin_path")), consumed
      assert_equal prompt, consumed.byteslice(0, prompt.bytesize)
      assert consumed.byteslice(prompt.bytesize..).start_with?("\n\n--- ACT LOCAL CLI EXECUTION ENVELOPE ---")
      assert consumed.end_with?("--- END ACT LOCAL CLI EXECUTION ENVELOPE ---\n")
      assert_planning_handoff(consumed)
      assert @store.load("T")["started_at"]
      refute @store.load("T")["result"]
    end
  end

  # Manual start verifies the saved handoff and material before reservation,
  # including read-only planning independent of a required checkpoint.
  def test_manual_consumption_and_checkpoint_access_independence
    with_workspace do |dir|
      write_task(dir, id: "T", repositories: { "alpha" => { "access" => "read_only" } })
      designate(dir, "T", "checkpoint" => { "mode" => "exempt", "category" => "planning", "reason" => "Plan only." })
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      out, err = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: dir, out: out, err: err)
      cli.instance_variable_set(:@coordinator, coordinator)
      assert_equal 0, cli.run(%w[prepare T]), err.string
      state = coordinator.status("T").fetch("state")
      prompt = File.binread(state.fetch("prompt_path"))
      assert_planning_handoff(prompt)
      File.binwrite(state.fetch("prompt_path"), prompt.sub(CodingSkillSupport::PLANNING_TEXT, ""))
      before = directory_bytes(dir)
      assert_equal 2, cli.run(%w[start T])
      assert_includes err.string, "generated prompt changed"
      assert_equal before, directory_bytes(dir)
      File.binwrite(state.fetch("prompt_path"), prompt)
      assert_equal 0, cli.run(%w[start T]), err.string
      assert_equal prompt, coordinator.launch_prompt("T")
      assert_equal prompt, File.binread(state.fetch("prompt_path"))
    end
  end

  # Every present noncanonical value fails through public preparation before
  # writes; unrelated author metadata and legacy YAML stay compatible.
  def test_strict_designation_validation_before_public_prepare_writes
    with_workspace do |dir|
      write_task(dir, id: "T")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      path = File.join(dir, "tasks", "T.yml")
      definition = YAML.safe_load_file(path)
      definition["author_metadata"] = { "custom" => [nil, false, "required"] }
      [nil, true, false, "", " ", "Required", "optional", "required ", 1, [], ["required"], { "mode" => "required" }].each do |value|
        File.write(path, YAML.dump(definition.merge("planning_guidance" => value)))
        before = directory_bytes(dir)
        error = assert_raises(AgentCodingTool::InvalidTask) { coordinator.prepare("T") }
        assert_match(/planning_guidance.*scalar string required/, error.message)
        assert_equal before, directory_bytes(dir)
      end
      File.write(path, YAML.dump(definition))
      assert_equal definition, AgentCodingTool::TaskStore.new(File.join(dir, "tasks")).load("T")
      refute coordinator.prepare("T").fetch("state").key?("planning_guidance")
    end
  end

  # Ordinary implementation prompts neither retrieve planning objects nor
  # depend on their availability; titles, prose, access and exemptions do not opt in.
  def test_ordinary_controls_ignore_missing_or_corrupt_planning_source
    with_planning_source(nil) do |root, pin|
      with_workspace do |dir|
        write_task(dir, id: "PLANNING-REGISTER", title: "Substantial ACTD planning registration")
        path = File.join(dir, "tasks", "PLANNING-REGISTER.yml")
        definition = YAML.safe_load_file(path).merge("goal" => "Define implementation task definitions and dependency graphs.")
        File.write(path, YAML.dump(definition))
        renderer = AgentCodingTool::PromptRenderer.new(skill_root: root, planning_skill_identity: pin)
        capture = Open3.method(:capture3)
        calls = []
        # Complete prompt digests at ACT 7afe873 plus ACT-21's required-checkpoint
        # milestone, export and operator-transfer guidance (exempt prompts unchanged).
        # Only coding text/revision/fingerprint use fixture-independent tokens.
        expected = {
          ["write", false] => "336a1197a584e22f31e01efc2d50311380895fdbfeeb47060c6ccd136d738717",
          ["write", true] => "2c094dbcdeb8ee5e403ca92271a1212214a4083d3b317ca069770f239debb8b4",
          ["read_only", false] => "84ced6c83728163e6f2be9527eff3dc39c18598b77848836ff52abff62f082bd",
          ["read_only", true] => "66bb12e38524532d83008a4eb361fc14e13bfec4867d923f228a6c83921ac255"
        }
        ["write", "read_only"].each do |access|
          [nil, { "mode" => "exempt", "category" => "planning", "reason" => "Only a plan." }].each do |policy|
            definition["repositories"]["alpha"]["access"] = access
            policy ? definition["checkpoint"] = policy : definition.delete("checkpoint")
            File.write(path, YAML.dump(definition))
            coordinator = coordinator_with_renderer(dir, renderer)
            prepared = Open3.stub(:capture3, lambda { |*args|
              calls << args
              capture.call(*args)
            }) { coordinator.prepare("PLANNING-REGISTER") }
            prompt = prepared.fetch("prompt")
            refute_includes prompt, "## Canonical planning guidance"
            assert_equal 1, prompt.scan(CodingSkillSupport::TEXT).length
            previous = renderer.render(definition, {}).sub(CodingSkillSupport::TEXT, "<CODING_SKILL>")
                               .gsub(renderer.skill_identity.fetch("revision"), "<REVISION>")
                               .gsub(renderer.skill_identity.fetch("sha256"), "<SHA256>")
            assert_equal expected.fetch([access, !policy.nil?]), Digest::SHA256.hexdigest(previous)
            coordinator.start("PLANNING-REGISTER")
            assert_equal prompt, coordinator.launch_prompt("PLANNING-REGISTER")
          end
        end
        assert_equal 4, calls.length
        assert calls.all? { |args| args.last.end_with?(AgentCodingTool::PromptRenderer::SKILL_PATH) }
        corrupt = "corrupt\xff".b
        File.binwrite(File.join(root, AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH), corrupt)
        commit_source(root)
        revision, error, status = Open3.capture3("git", "-C", root, "rev-parse", "HEAD")
        raise error unless status.success?

        renderer = AgentCodingTool::PromptRenderer.new(skill_root: root, planning_skill_identity: {
          "revision" => revision.strip, "sha256" => Digest::SHA256.hexdigest(corrupt)
        })
        control = coordinator_with_renderer(dir, renderer)
        prompt = control.prepare("PLANNING-REGISTER").fetch("prompt")
        control.start("PLANNING-REGISTER")
        assert_equal prompt, control.launch_prompt("PLANNING-REGISTER")
      end
    end
  end

  # Designation additions/removals, incomplete identities and changed pins may
  # never bless old preparations, even through an explicit retry.
  def test_designation_and_pin_drift_require_evidence_preserving_reset_reprepare
    with_workspace do |dir|
      write_task(dir, id: "T")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("T")
      designate(dir, "T")
      assert_consumption_refused(dir, coordinator)
      coordinator.reset("T")
      prepared = coordinator.prepare("T")
      store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
      path = File.join(dir, "tasks", "T.yml")
      definition = YAML.safe_load_file(path)
      File.write(path, YAML.dump(definition.reject { |key, _value| key == "planning_guidance" }))
      assert_consumption_refused(dir, coordinator)
      File.write(path, YAML.dump(definition))
      ["planning_guidance", "planning_skill", "coding_skill"].each do |missing|
        store.write("T", prepared.fetch("state").reject { |key, _value| key == missing })
        before = directory_bytes(dir)
        assert_raises(AgentCodingTool::InvalidState) { coordinator.start("T") }
        assert_raises(AgentCodingTool::InvalidState) { coordinator.launch_prompt("T") }
        assert_equal before, directory_bytes(dir)
      end
      store.write("T", prepared.fetch("state"))
      changed_pin = AgentCodingTool::PromptRenderer::PLANNING_SKILL_IDENTITY.merge("sha256" => "0" * 64)
      changed = coordinator_with_renderer(dir, AgentCodingTool::PromptRenderer.new(planning_skill_identity: changed_pin))
      assert_consumption_refused(dir, changed)
      coordinator.record("T", outcome: "failed", summary: "Explicit operator retry fixture")
      before = directory_bytes(dir)
      assert_raises(AgentCodingTool::InvalidState) { changed.prepare("T", retry_result: true) }
      assert_equal before, directory_bytes(dir)
      old_prompt = File.binread(prepared.fetch("state").fetch("prompt_path"))
      # Same designation/pin retries use the existing explicit contract.
      Time.stub(:now, Time.now + 2) { coordinator.prepare("T", retry_result: true) }
      assert_equal old_prompt, File.binread(prepared.fetch("state").fetch("prompt_path"))
    end
  end

  # Source failures on initial prepare, retry and consumption preserve every
  # prompt/state/checkpoint/history byte, including a fresh-process refusal.
  def test_invalid_material_preserves_initial_retry_and_consumption_evidence
    with_planning_source(CodingSkillSupport::PLANNING_TEXT) do |root, pin|
      with_workspace do |dir|
        write_task(dir, id: "T")
        designate(dir, "T")
        good = AgentCodingTool::PromptRenderer.new(skill_root: root, planning_skill_identity: pin)
        coordinator = coordinator_with_renderer(dir, good)
        prepared = coordinator.prepare("T")
        evidence = File.join("#{dir}-runs", "checkpoints", "T", "old")
        FileUtils.mkdir_p(evidence)
        File.binwrite(File.join(evidence, "current.json"), "historical checkpoint\x00".b)
        store = AgentCodingTool::StateStore.new(File.join(dir, "state"))
        store.write("T", prepared.fetch("state").merge("checkpoint" => { "status" => "verified", "record_path" => evidence }))
        blob, error, status = Open3.capture3("git", "-C", root, "rev-parse",
                                            "#{pin.fetch('revision')}:#{AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH}")
        raise error unless status.success?

        # Remove only this fixture's pinned planning blob. Coding remains valid.
        File.unlink(File.join(root, ".git", "objects", blob.strip[0, 2], blob.strip[2..]))
        before = directory_bytes(dir).merge(directory_bytes("#{dir}-runs"))
        assert_raises(AgentCodingTool::InvalidState) { coordinator.start("T") }
        _out, error, status = cold_consume(dir, root: root, pin: pin)
        refute status.success?
        assert_includes error, "planning skill: pinned source unavailable"
        assert_equal before, directory_bytes(dir).merge(directory_bytes("#{dir}-runs"))
        coordinator.record("T", outcome: "needs_judgment", summary: "Keep this result.")
        before = directory_bytes(dir).merge(directory_bytes("#{dir}-runs"))
        assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("T", retry_result: true) }
        assert_equal before, directory_bytes(dir).merge(directory_bytes("#{dir}-runs"))
        write_task(dir, id: "NEW")
        designate(dir, "NEW")
        before = directory_bytes(dir)
        assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("NEW") }
        assert_equal before, directory_bytes(dir)
        refute File.exist?(store.state_path("NEW"))
        FileUtils.remove_entry("#{dir}-runs")
      end
    end
  end

  # Matching fingerprints cannot excuse bad frontmatter, required metadata,
  # invalid encoding or empty bodies. Finite immutable-source responses leave
  # ACT's hashing, YAML and refusal decisions real; native reads remain separate.
  def test_integrity_and_metadata_refusal_matrix
    text = CodingSkillSupport::PLANNING_TEXT
    variants = [nil, "not frontmatter\n", "---\nname: [broken\n---\nBody\n",
                text.sub("agentic-task-planning", "wrong-name"),
                text.sub("Fixture planning instructions.", ""),
                text.sub("description: Fixture planning instructions.", "description: []"),
                text.sub("license: MIT", "license: false"),
                text.sub("Fixture planning: outcomes, ownership, integration, recovery, acceptance.", ""),
                text.b + "\xff".b]
    variants.each do |content|
      Dir.mktmpdir("act-planning-response-") do |root|
        FileUtils.mkdir_p(File.join(root, ".git"))
        pin = { "revision" => "2" * 40, "sha256" => Digest::SHA256.hexdigest(content || "") }
        coding = SkillObservations.read(root: root, path: AgentCodingTool::PromptRenderer::SKILL_PATH,
          identity: AgentCodingTool::PromptRenderer::SKILL_IDENTITY, text: CodingSkillSupport::TEXT)
        planning = SkillObservations.read(root: root, path: AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH,
          identity: pin, text: content || "", success: !content.nil?, stderr: content.nil? ? "missing object" : "")
        runner = GitContract::Replay.new([coding, planning])
        error = assert_raises(AgentCodingTool::InvalidState) do
          AgentCodingTool::PromptRenderer.new(skill_root: root, planning_skill_identity: pin, runner: runner).render(planning_task, {})
        end
        assert_match(/planning skill: (pinned source unavailable|malformed|Psych::|invalid UTF-8)/, error.message)
        assert runner.verify!
      end
    end
    renderer = AgentCodingTool::PromptRenderer
    [nil, [], { 1 => "invalid", "sha256" => "0" * 64 },
     { "revision" => "main", "sha256" => "0" * 64 },
     renderer::PLANNING_SKILL_IDENTITY.merge("sha256" => "bad"),
     renderer::PLANNING_SKILL_IDENTITY.merge("revision" => "0" * 40),
     renderer::PLANNING_SKILL_IDENTITY.merge("sha256" => "0" * 64)].each do |pin|
      coding = SkillObservations.read(root: renderer::SKILL_ROOT, path: renderer::SKILL_PATH,
        identity: renderer::SKILL_IDENTITY, text: CodingSkillSupport::TEXT)
      observations = [coding]
      if pin.is_a?(Hash) && [pin["revision"], pin["sha256"]].zip([40, 64]).all? { |value, length|
           value.is_a?(String) && value.match?(/\A[0-9a-f]{#{length}}\z/) }
        observations << SkillObservations.read(root: renderer::SKILL_ROOT, path: renderer::PLANNING_SKILL_PATH,
          identity: pin, text: text, success: pin["revision"] != "0" * 40,
          stderr: pin["revision"] == "0" * 40 ? "missing object" : "")
      end
      runner = GitContract::Replay.new(observations)
      error = assert_raises(AgentCodingTool::InvalidState) { renderer.new(planning_skill_identity: pin, runner: runner).render(planning_task, {}) }
      assert_match(/planning skill: (malformed pinned identity|pinned source unavailable|SHA-256 integrity mismatch)/, error.message)
      assert runner.verify!
    end
  end

  # A newer branch, dirty working file and cold regeneration all preserve the
  # original pinned handoff. Both sources use the exact offline Git read contract.
  def test_offline_object_reads_and_cold_regeneration_ignore_branch_and_worktree
    with_planning_source(CodingSkillSupport::PLANNING_TEXT) do |root, pin|
      with_workspace do |dir|
        write_task(dir, id: "T")
        designate(dir, "T")
        renderer = AgentCodingTool::PromptRenderer.new(skill_root: root, planning_skill_identity: pin)
        capture, calls = Open3.method(:capture3), []
        prepared = Open3.stub(:capture3, lambda { |*args|
          calls << args
          capture.call(*args)
        }) { coordinator_with_renderer(dir, renderer).prepare("T") }
        assert_equal 2, calls.length
        calls.each do |args|
          assert_equal({ "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0" }, args.first)
          assert_equal ["git", "--no-replace-objects", "-C", root, "cat-file", "blob"], args[1, 6]
        end
        path = File.join(root, AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH)
        File.write(path, CodingSkillSupport::PLANNING_TEXT + "New branch text\n")
        commit_source(root)
        File.write(path, "bad dirty working text")
        prompt, error, status = cold_consume(dir, root: root, pin: pin)
        assert status.success?, error
        assert_equal prepared.fetch("prompt"), prompt
      end
    end
  end

  # Inspection uses existing state presentation only, never skill retrieval.
  def test_status_does_not_retrieve_skills_or_write
    with_workspace do |dir|
      write_task(dir, id: "T")
      designate(dir, "T")
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      coordinator.prepare("T")
      renderer = AgentCodingTool::PromptRenderer.new(skill_root: File.join(dir, "missing"))
      before = directory_bytes(dir)
      Open3.stub(:capture3, ->(*) { flunk "status retrieved a skill" }) do
        assert_equal "PREPARED", coordinator_with_renderer(dir, renderer).status("T").fetch("status")
      end
      assert_equal before, directory_bytes(dir)
    end
  end

  # Launcher refuses planning pin/designation drift before new run evidence,
  # worktree creation or worker reservation; prior history remains unchanged.
  def test_launcher_refuses_planning_drift_before_handoff
    fixture do
      designate(@data, "T")
      prepared = @coordinator.prepare("T").fetch("state")
      history = File.join("#{@data}-runs", "checkpoints", "T", "old", "current.json")
      FileUtils.mkdir_p(File.dirname(history), mode: 0o700)
      File.binwrite(history, "historical checkpoint\x00".b)
      [nil, prepared.fetch("planning_skill").merge("revision" => "0" * 40)].each do |pin|
        @store.write("T", prepared.merge("planning_skill" => pin))
        before = directory_bytes(@data).merge(directory_bytes(File.dirname(history)))
        error = assert_raises(AgentCodingTool::InvalidState) { launcher.launch("T") }
        assert_includes error.message, "planning guidance"
        assert_equal before, directory_bytes(@data).merge(directory_bytes(File.dirname(history)))
        assert_empty Dir.glob("#{@data}-runs/T/*/handoff.json")
        assert_empty Dir.glob(File.join(@root, "worktrees", "*"))
        refute @store.load("T")["started_at"]
      end
    end
  end

  private

  # Updates fixture task designation/outputs; returns bytes written or raises I/O errors.
  def designate(dir, id, extra = {})
    path = File.join(dir, "tasks", "#{id}.yml")
    definition = YAML.safe_load_file(path).merge(
      "planning_guidance" => "required", "goal" => "Produce implementation task definitions and a dependency graph as reviewable ACTD YAML.",
      "acceptance" => ["State acceptance requirements, ownership/integration plans and substantial plan revisions."]
    ).merge(extra)
    File.write(path, YAML.dump(definition))
  end

  # Returns a minimal opted-in task for renderer integrity tests; no I/O.
  def planning_task
    { "id" => "T", "title" => "Registration", "planning_guidance" => "required",
      "repositories" => { "alpha" => { "access" => "write" } } }
  end

  # Checks complete handoff bytes and apply-before-output ordering; raises a
  # Minitest assertion if required source, identity or substantive instruction is lost.
  def assert_planning_handoff(prompt)
    assert_equal 1, prompt.scan(CodingSkillSupport::TEXT).length
    assert_equal 1, prompt.scan(CodingSkillSupport::PLANNING_TEXT).length
    pin = AgentCodingTool::PromptRenderer::PLANNING_SKILL_IDENTITY
    assert_includes prompt, "Revision: #{pin.fetch('revision')}\nSHA-256: #{pin.fetch('sha256')}"
    assert_includes prompt, "Read and substantively apply the complete unchanged skill below before producing plans"
    assert_includes prompt, "A link or nominal citation is insufficient."
    assert_operator prompt.index("Planning handoff:"), :<, prompt.index("## Goal")
    assert_operator prompt.index("<!-- End canonical planning SKILL.md -->"), :<, prompt.index("## Goal")
  end

  # Returns a CLI using the production fixture coordinator and captured output.
  def fixture_cli
    cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: @data, out: @out, err: @err)
    cli.instance_variable_set(:@coordinator, @coordinator)
    cli
  end

  # Returns a production coordinator with an injected immutable-source renderer.
  def coordinator_with_renderer(dir, renderer)
    AgentCodingTool::Coordinator.new(
      task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
      state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
      repo_inspector: FakeInspector.new(heads: { "alpha" => "a" * 40 }),
      prompt_renderer: renderer, prompt_root: File.join(dir, "state", "prompts")
    )
  end

  # Runs regeneration in a new interpreter; returns stdout/stderr/status with
  # failures classified as InvalidState. It uses inherited hermetic fixture pins.
  def cold_consume(dir, root: AgentCodingTool::PromptRenderer::SKILL_ROOT,
                   pin: AgentCodingTool::PromptRenderer::PLANNING_SKILL_IDENTITY)
    script = <<~'RUBY'
      require "agent_coding_tool"
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
    RUBY
    Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, dir, root, JSON.generate(pin))
  end

  # Verifies all unsupported adoption/consumption paths leave saved bytes intact.
  def assert_consumption_refused(dir, coordinator)
    before = directory_bytes(dir)
    %i[prepare start launch_prompt].each do |operation|
      error = assert_raises(AgentCodingTool::InvalidState) { coordinator.public_send(operation, "T") }
      assert_includes error.message, "planning guidance"
    end
    renderer = coordinator.instance_variable_get(:@prompt_renderer)
    _out, error, status = cold_consume(dir, pin: renderer.planning_skill_identity)
    refute status.success?
    assert_includes error, "planning guidance"
    assert_equal before, directory_bytes(dir)
  end

  # Returns regular-file bytes for evidence preservation assertions; no writes.
  def directory_bytes(dir)
    Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
       .to_h { |path| [path, File.binread(path)] }
  end

  # Yields a disposable checkout with supplied planning bytes (nil removes the
  # path) and its matching pin. Genuine Git errors raise without fallback.
  def with_planning_source(text)
    Dir.mktmpdir("act-planning-source-") do |root|
      FileUtils.cp_r(File.join(AgentCodingTool::PromptRenderer::SKILL_ROOT, "."), root)
      path = File.join(root, AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH)
      text ? File.binwrite(path, text) : File.unlink(path)
      commit_source(root) unless text == CodingSkillSupport::PLANNING_TEXT
      revision, error, status = Open3.capture3("git", "-C", root, "rev-parse", "HEAD")
      raise error unless status.success?

      yield root, { "revision" => revision.strip, "sha256" => Digest::SHA256.hexdigest(text || "") }
    end
  end

  # Commits fixture-only source changes; returns nil or raises on Git failure.
  def commit_source(root)
    [%w[add -A], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "planning fixture"]].each do |args|
      _out, error, status = Open3.capture3("git", "-C", root, *args)
      raise error unless status.success?
    end
    nil
  end
end
