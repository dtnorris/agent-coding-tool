# frozen_string_literal: true

require_relative "test_helper"

class PromptRendererTest < Minitest::Test
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
