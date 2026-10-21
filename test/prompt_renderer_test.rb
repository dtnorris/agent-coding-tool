# frozen_string_literal: true

require_relative "test_helper"

class PromptRendererTest < Minitest::Test
  include TestHelpers

  def test_performance_scope_uses_access_and_checkpoint_policy_not_titles
    # Representative metadata from ACTD main 0134f1cf7de3fe60599309f0f8daa04ad0903dc3:
    # FS-01/FS-02 omit checkpoint; IG-15C2 permits code despite its audit title.
    renderer = AgentCodingTool::PromptRenderer.new
    readonly = { "reference" => { "access" => "read_only" } }
    writable = readonly.merge("owner" => { "access" => "write" })
    cases = [
      ["FS-01", "Define AdventureFinder filesystem contract", readonly, nil, false],
      ["FS-02", "Audit AdventureFinder filesystem assumptions", readonly, nil, false],
      ["IG-15C2", "Audit WLO public seams for coordinated local execution", writable, nil, true],
      ["CODE", "Fix source", writable, { "mode" => "required" }, true],
      ["TEST", "Fix relocation-sensitive boundary tests", writable, nil, true]
    ]
    %w[planning inspection no_code].each do |category|
      cases << [category, "Non-executable work", writable,
                { "mode" => "exempt", "category" => category, "reason" => "No executable change." }, false]
    end
    cases.each do |id, title, repositories, checkpoint, expected|
      task = { "id" => id, "title" => title, "repositories" => repositories }
      task["checkpoint"] = checkpoint if checkpoint
      prompt = renderer.render(task, {})
      assert_equal expected ? 1 : 0, prompt.scan(/^## Test performance$/).length, id
      refute_includes prompt, "incremental test cost" unless expected
    end
  end

  def test_preparation_and_launch_share_performance_policy_and_preserve_task_rules
    with_workspace do |dir|
      write_task(dir, id: "T")
      path = File.join(dir, "tasks", "T.yml")
      task = YAML.safe_load_file(path)
      rules = ["Complete rake under 30 seconds with coverage >= 95%.", "Preserve real-process safety tests."]
      task["constraints"] = rules
      File.write(path, YAML.dump(task))
      coordinator = coordinator_for(dir, "alpha" => "a" * 40)
      prepared = coordinator.prepare("T")
      prompt = prepared.fetch("prompt")
      coordinator.start("T")
      assert_equal prompt, File.read(prepared.fetch("state").fetch("prompt_path"))
      assert_equal prompt, coordinator.launch_prompt("T")
      assert_equal 1, prompt.scan(/^## Test performance$/).length
      assert_operator prompt.index("## Test performance"), :>, prompt.index("## Implementation checkpoint")
      rules.each { |rule| assert_includes prompt, "- #{rule}\n" }
      ["passing either does not establish the other", "explicit human authorization before implementation",
       "Existing task scope alone is not authorization", "old limit and observed baseline",
       "proposed limit and measured resulting runtime", "cheaper alternatives",
       "not independent machine enforcement", "pre-existing debt or failing baseline",
       "noise/contention", "necessary added coverage", "unavailable comparison",
       "not executed (missing runtime/dependencies/permissions)", "executed without comparable timing evidence",
       "operator-side validation/timing commands", "not a universal limit or automatic acceptance",
       "essential real-process integration coverage", "equivalent behavioral guarantees"].each do |text|
        assert_includes prompt, text
      end
    end
  end

  def test_checkpoint_instruction_is_one_section_and_exemption_is_reviewable
    task = { "id" => "T", "title" => "Code", "repositories" => { "repo" => { "access" => "write" } } }
    snapshot = { "repo" => { "path" => "/repo", "remote_url" => "git@github.com:example/repo.git",
                              "branch" => "main", "pushed_sha" => "a" * 40 } }
    renderer = AgentCodingTool::PromptRenderer.new
    prompt = renderer.render(task, snapshot)
    assert_equal 1, prompt.scan(/^## Implementation checkpoint$/).length
    assert_includes prompt, "passes focused validation"
    assert_includes prompt, "ACT verifies content"
    assert_includes prompt, "not CANDIDATE, COMPLETE"
    assert_includes prompt, "Requested seed/selection declarations never prove effectiveness"
    assert_includes prompt, "Keep secrets out of argv"
    exempt = renderer.render(task.merge("checkpoint" => { "mode" => "exempt", "category" => "inspection",
                                                         "reason" => "No code." }), snapshot)
    assert_equal 1, exempt.scan(/^## Implementation checkpoint$/).length
    assert_includes exempt, "Checkpoint exempt (inspection): No code."
    refute_includes exempt, "checkpoint gate"
  end
  def test_logical_checkout_key_uses_recorded_remote_and_branch
    name = "runpod-ollama-fleet-production"
    task = {
      "id" => "T1",
      "title" => "Narrow change",
      "repositories" => {
        name => { "access" => "write" },
        "reference" => { "access" => "read_only" }
      },
      "goal" => "Expose checkout identity.",
      "constraints" => ["No paid capacity."],
      "acceptance" => ["Focused tests pass."]
    }
    snapshot = TestHelpers::FakeInspector.new(heads: { name => "a" * 40, "reference" => "b" * 40 })
    repos = task.fetch("repositories").to_h { |key, spec| [key, snapshot.snapshot(key, spec)] }
    repos.fetch(name).merge!(
      "path" => "/code/#{name}",
      "remote_url" => "git@github.com:example/runpod-ollama-fleet.git",
      "branch" => "release",
      "local_head" => "c" * 40,
      "local_dirty" => true
    )

    prompt = AgentCodingTool::PromptRenderer.new.render(task, repos)

    assert_includes prompt, <<~BLOCK
      - runpod-ollama-fleet-production
        - path: /code/runpod-ollama-fleet-production
        - remote_url: git@github.com:example/runpod-ollama-fleet.git
        - branch: release
        - pushed_sha: #{'a' * 40}
    BLOCK
    refute_includes prompt, "example/runpod-ollama-fleet-production.git"
    refute_includes prompt, "c" * 40
    refute_includes prompt, "local_dirty"
    assert_includes prompt, "not necessarily GitHub repository names"
    assert_includes prompt, "Verify each pushed head using its recorded remote_url and branch"
    assert_includes prompt, "do not infer the remote repository from the logical key or local path"
    assert_includes prompt, "# T1: Narrow change"
    assert_includes prompt, "Use the connected GitHub integration for repository access."
    assert_includes prompt, "For GitHub reads, prefer the connected GitHub tools/API."
    assert_includes prompt, "Do not open github.com in the cloud browser when the connected integration can perform the required repository read."
    assert_includes prompt, "Do not request GitHub website-access permission merely to inspect repositories, branches, commits, files, or pushed heads."
    assert_includes prompt, "If a required GitHub operation is unavailable through the connected tooling, report that limitation rather than silently switching to the browser."
    assert_includes prompt, "Refresh these pushed heads before doing any work and again before finalizing."
    assert_includes prompt, "Writable repositories: if any pushed head differs from the preparation snapshot, stop and report STALE INPUT"
    assert_includes prompt, "A new preparation (with explicit retry if an outcome was recorded) is required."
    assert_includes prompt, "Read-only repositories: if a pushed head differs, refresh that repository to the new pushed head and re-inspect and reconcile any materially affected findings before finalizing."
    assert_includes prompt, "Unrelated read-only head movement alone does not require an abort."
    assert_includes prompt, "Preserve the preparation snapshot as provenance and report the refreshed heads and any effect on your conclusions in the handoff."
    assert_includes prompt, "## Writable repositories\n\n- #{name}\n"
    assert_includes prompt, "## Read-only repositories\n\n- reference\n"
    assert_includes prompt, "Unless a task-specific constraint explicitly restricts reads"
    assert_includes prompt, "repository lists below are not an exhaustive read allowlist"
    assert_includes prompt, "Only the repositories designated writable above may be modified"
    assert_includes prompt, "including the task-data repository, may be read"
    assert_includes prompt, "Do not commit, push, create a PR, or otherwise mutate GitHub."
    assert_includes prompt, "Do not broaden write scope or override explicit task-specific read restrictions."
    refute_includes prompt, "## Prerequisites"
    assert_includes prompt, "## Goal\n\nExpose checkout identity.\n"
    assert_includes prompt, "## Constraints\n\n- No paid capacity.\n"
    assert_includes prompt, "## Acceptance\n\n- Focused tests pass.\n"
    assert_equal 1, prompt.scan(/^## Documentation discipline$/).length
    assert_operator prompt.index("## Documentation discipline"), :>, prompt.index("## Acceptance")
    assert_includes prompt, "Code and tests alone may suffice."
    assert_includes prompt, "Explicit task documentation and safety requirements take precedence."
  end

  def test_documentation_guidance_is_static_for_explicit_specification_and_source_only_tasks
    renderer = AgentCodingTool::PromptRenderer.new
    base = {
      "id" => "SPEC", "title" => "Define a versioned contract",
      "repositories" => { "pipeline" => { "access" => "write" } },
      "goal" => "Publish the public contract.",
      "constraints" => ["Create VERSIONED_SPEC.md as the authoritative v0.1 contract."],
      "acceptance" => ["The versioned specification is present."]
    }
    snapshot = { "pipeline" => TestHelpers::FakeInspector.new(heads: { "pipeline" => "a" * 40 })
                                                      .snapshot("pipeline", base.fetch("repositories").fetch("pipeline")) }
    explicit = renderer.render(base, snapshot)
    source_only = renderer.render(base.merge(
      "id" => "SOURCE", "title" => "Adjust source and tests", "goal" => "Fix the source path.",
      "constraints" => ["Keep the patch to source and tests."], "acceptance" => ["Tests pass."]
    ), snapshot)

    section = explicit.split("## Documentation discipline\n\n", 2).fetch(1)
    assert_equal section, source_only.split("## Documentation discipline\n\n", 2).fetch(1)
    assert_equal 1, explicit.scan(/^## Documentation discipline$/).length
    assert_equal 1, source_only.scan(/^## Documentation discipline$/).length
    assert_includes explicit, "## Constraints\n\n- Create VERSIONED_SPEC.md as the authoritative v0.1 contract.\n"
    assert_includes explicit, "## Acceptance\n\n- The versioned specification is present.\n"
    assert_includes section, "required specification"
    assert_includes section, "link to normative rules instead of copying them"
    assert_includes section, "enduring purpose of each new Markdown file"
    assert_includes source_only, "## Constraints\n\n- Keep the patch to source and tests.\n"
  end
end
