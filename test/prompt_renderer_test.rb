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
  end
end
