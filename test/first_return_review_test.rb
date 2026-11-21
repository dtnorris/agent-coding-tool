# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require_relative "../lib/agent_coding_tool/codex_manager_adapter"

# Exercises manage through the public dispatcher and real evidence/JSONL readers.
# The executor below substitutes only the inference process boundary.
class FirstReturnReviewTest < Minitest::Test
  include TestHelpers

  # Builds a Launcher-shaped immutable return, plus optional retained claims
  # and chronologically distinct host records. No current task file is needed.
  def retained_run(data, exempt: false, checkpoint_at: nil, gate_at: "2026-11-18T10:19:01Z", exit_status: 0)
    run = File.join("#{data}-runs", "T", "run-1")
    FileUtils.mkdir_p(run, mode: 0o700)
    workspace = File.realpath(data)
    authority = { "pushed_sha" => "a" * 40, "remote_url" => "git@github.com:example/source.git", "branch" => "main" }
    identity = { "task_id" => "T", "attempt" => 1, "invocation_id" => "original-invocation", "session_id" => "original-worker" }
    report = identity.merge("schema_version" => "agent-coding-tool-run/v1", "status" => "exited", "exit_status" => exit_status,
      "final_valid" => true, "ended_at" => "2026-11-18T10:18:03Z", "checkpoint_required" => !exempt,
      "workspace" => workspace, "preparation" => { "source" => authority })
    if exempt
      report.merge!("scratch_path" => workspace, "writable_repositories" => [],
        "workspaces" => {}, "writable_authorities" => {}, "fixture" => { "path" => workspace })
    else
      report.merge!("writable_repositories" => ["source"], "writable_repository" => "source", "writable_authority" => authority)
    end
    prompt = exempt ? "Inspect the pinned inputs and report the 3 workbook role bindings." : "Preserve the candidate and finish with the required composed host gate."
    final = exempt ? "Read-only inspection found the 3 named workbook role bindings." : "Worker claims focused checks passed. Host validation remains pending."
    content = { "prompt" => prompt, "stdin" => prompt + "\nExact launch envelope.", "final" => final,
      "jsonl" => JSON.generate("type" => "thread.started", "thread_id" => identity.fetch("session_id")) + "\n", "stderr" => "" }
    report["artifacts"] = content.map do |name, bytes|
      report["#{name}_path"] = File.join(run, "#{name}.txt")
      spec(report.fetch("#{name}_path"), bytes)
    end
    report["prompt_sha256"] = report.fetch("artifacts").first.fetch("sha256")
    patch = "diff --git a/catalog.rb b/catalog.rb\n"
    unless exempt
      token = "a" * 32
      package = "b" * 64
      files = { "candidate" => patch, "apply" => "{}", "focused" => "worker-only composed checks passed" }.to_h do |kind, bytes|
        filename = "worker-#{token}-#{kind}"
        [kind, spec(File.join(run, filename), bytes).merge("file" => filename)]
      end
      File.write(File.join(run, "registration-#{token}.json"), JSON.generate("binding" => identity, "workspace" => workspace,
        "base_sha" => authority.fetch("pushed_sha"), "package_sha256" => package, "files" => files))
      report["worker_evidence"] = { "status" => "registered_worker_claims", "package_sha256" => package }
    end
    if checkpoint_at
      directory = File.join("#{data}-runs", "checkpoints", "T", "recorded-attempt")
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.write(File.join(directory, "0001.patch"), patch)
      record = { "schema_version" => "agent-coding-tool-checkpoint/v1", "task_id" => "T", "attempt" => "recorded-attempt",
        "launch_invocation" => identity.fetch("invocation_id"), "authority" => authority, "repository" => "source",
        "verified_at" => checkpoint_at, "artifact" => "0001.patch", "sha256" => Digest::SHA256.hexdigest(patch) }
      checkpoint = spec(File.join(directory, "0001.json"), JSON.generate(record))
      File.write(File.join(directory, "current.json"), JSON.generate("record_file" => "0001.json", "sha256" => checkpoint.fetch("sha256")))
      gate_output = spec(File.join(directory, "gate-0002.stdout"), "independent composition passed")
      gate = record.merge("schema_version" => "agent-coding-tool-checkpoint-gate/v1", "invocation_id" => "0002",
        "finished_at" => gate_at, "receipt_phase" => "finished", "candidate_validation" => "passed",
        "output" => { "streams" => { "stdout" => gate_output.merge("file" => "gate-0002.stdout", "status" => "complete") } },
        "command_outcome" => { "status" => "exited", "exit_code" => 0 },
        "candidate" => record.slice("artifact", "launch_invocation", "sha256").merge("record_file" => "0001.json"))
      File.write(File.join(directory, "gate-0002.finished.json"), JSON.generate(gate))
    end
    File.write(File.join(run, "handoff.json"), JSON.generate(report))
    run
  end

  # Writes retained bytes and returns a Launcher artifact digest and length.
  def spec(path, bytes)
    File.binwrite(path, bytes)
    { "path" => path, "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes) }
  end

  # Runs the public command and returns its status and terminal streams. The
  # supplied block is called only by the real adapter's inference executor.
  def review(data, *args, &inference)
    out, err = StringIO.new, StringIO.new
    runtime = AgentCodingTool::CodexManagerAdapter.new(executable: RbConfig.ruby, identity: {}, executor: inference) if inference
    status = AgentCodingTool::CLI.run(["manage", "T", "--first-return", *args], root: data, data_root: data,
      out: out, err: err, first_return_runtime: runtime)
    [status, out.string, err.string]
  end

  # Supplies one fresh Codex JSONL return with a revision-bound recommendation.
  def answer(argv, input, action:, proved:, remaining:, instruction: nil)
    assert_equal ["exec", "--ignore-user-config"], argv[1, 2]
    assert_equal "-", argv.last
    assert_includes argv, "features.shell_tool=false"
    decision = { "revision" => input.fetch("revision"), "proved" => proved, "remaining" => remaining,
      "evidence" => %w[launch_input final], "action" => action, "instruction" => instruction }
    events = [{ "type" => "thread.started", "thread_id" => "fresh-reviewer" }, { "type" => "turn.started" },
      { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => JSON.generate(decision) } },
      { "type" => "turn.completed" }]
    AgentCodingTool::CommandResult.new(stdout: events.map { |event| JSON.generate(event) }.join("\n"), stderr: "", exitstatus: 0)
  end

  # Historical replay uses the original prompt and retained worker package. A
  # later checkpoint, successful gate and edited/closed task stay out of it.
  def test_pre_checkpoint_historical_review
    with_workspace do |data|
      retained_run(data, checkpoint_at: "2026-11-18T10:19:00Z")
      File.write(File.join(data, "tasks", "T.yml"), "new task goal; never read")
      File.write(File.join(data, "state", "T.yml"), "later closeout; never read")
      calls = 0
      status, out, err = review(data) do |argv, bytes|
        calls += 1
        input = JSON.parse(bytes)
        assert_equal %w[T 1 original-invocation original-worker], input.fetch("binding").values.map(&:to_s)
        assert_includes input.dig("artifacts", "launch_input", "text"), "Exact launch envelope"
        assert_includes bytes, "worker-only composed checks passed"
        refute_includes bytes, "new task goal"
        refute_includes bytes, "later closeout"
        refute input.fetch("artifacts").keys.any? { |key| key.start_with?("validation:") }
        answer(argv, input, action: "host_checkpoint", proved: "Worker claims focused checks passed.", remaining: "Host checkpoint and gate are missing.")
      end
      assert_equal 0, status, err
      assert_equal 1, calls
      assert_equal 1, out.scan("First-return recommendation").length
      assert_includes out, "Worker exit 0 (exited)."
      assert_includes out, "finished host gate evidence missing"
      assert_includes out, "act checkpoint record T --workspace"
    end
  end

  # A pre-return checkpoint is evidence, but the later finished gate does not
  # establish validation of that historical candidate.
  def test_pre_return_checkpoint_keeps_later_gate_out
    with_workspace do |data|
      retained_run(data, checkpoint_at: "2026-11-18T10:17:00Z")
      status, out, err = review(data) do |argv, bytes|
        input = JSON.parse(bytes)
        assert_includes input.fetch("host_evidence"), "verified checkpoint record retained"
        assert_includes input.fetch("host_evidence"), "finished host gate evidence missing"
        refute_includes bytes, "independent composition passed"
        refute_includes input.fetch("allowed_actions"), "operator_closeout"
        answer(argv, input, action: "host_gate", proved: "Host checkpoint was verified.", remaining: "Required host gate evidence is missing.")
      end
      assert_equal 0, status, err
      assert_includes out, "act checkpoint gate"
    end
  end

  # A genuinely finished first-return gate and its pinned output are visible.
  def test_pre_return_gate_and_output_are_eligible_evidence
    with_workspace do |data|
      retained_run(data, checkpoint_at: "2026-11-18T10:17:00Z", gate_at: "2026-11-18T10:17:30Z")
      status, out, err = review(data) do |argv, bytes|
        input = JSON.parse(bytes)
        assert_equal "independent composition passed", input.dig("artifacts", "validation_output:gate-0002.stdout", "text")
        answer(argv, input, action: "operator_closeout", proved: "A finished host gate passed on the bound candidate.", remaining: "David owns final acceptance.")
      end
      assert_equal 0, status, err
      assert_includes out, "passing host gate receipt retained for the historical candidate"
    end
  end

  # Exempt inspections can surface one David-owned closeout decision.
  def test_exempt_inspection
    with_workspace do |data|
      retained_run(data, exempt: true)
      status, out, err = review(data) do |argv, bytes|
        answer(argv, JSON.parse(bytes), action: "operator_closeout",
          proved: "Worker reported the three requested bindings in the final return.", remaining: "David must judge whether the findings satisfy the assignment.")
      end
      assert_equal 0, status, err
      assert_includes out, "launch declared the task checkpoint-exempt"
      assert_includes out, "authorize closeout if it does"
    end
  end

  # Workers and reviewers have distinct outcomes. Evidence must remain stable
  # through inference, and loss of a retained file refuses before inference.
  def test_broken_link_changed_evidence_and_reviewer_failure
    with_workspace do |data|
      run = retained_run(data, exit_status: 7)
      failed = AgentCodingTool::CommandResult.new(stdout: "", stderr: "private diagnostic", exitstatus: 9)
      status, out, err = review(data) { failed }
      assert_equal 2, status
      assert_includes out, "Worker exit 7 (exited)."
      assert_includes err, "reviewer failed (exit 9"
      refute_includes err, "private diagnostic"
      refute_includes out, "recommendation"
      path = File.join(run, "final.txt")
      status, out, err = review(data) do |argv, bytes|
        File.write(path, "changed during review")
        answer(argv, JSON.parse(bytes), action: "worker_followup", proved: "Worker process exited 7.",
          remaining: "The focused result is unverified.", instruction: "Return the focused harness failure and its exact command.")
      end
      assert_equal 2, status
      refute_includes out, "recommendation"
      assert_includes err, "artifact differs from launch record"
      File.unlink(path)
      status, out, err = review(data) { flunk "broken link must refuse before inference" }
      assert_equal 2, status
      refute_includes out, "recommendation"
      assert_includes err, "retained final evidence is missing"
    end
  end

  # The normal binary path requires a host-qualified lease and rejects multiple
  # task runs before calling inference. An explicit exact invocation can select it.
  def test_unapproved_and_ambiguous_selection
    with_workspace do |data|
      run = retained_run(data, exempt: true)
      status, out, err = review(data)
      assert_equal 2, status
      assert_includes err, "no approved confined reviewer lease"
      refute_includes out, "recommendation"
      second = File.join(File.dirname(run), "run-2")
      Dir.mkdir(second)
      report = JSON.parse(File.read(File.join(run, "handoff.json")))
      File.write(File.join(second, "handoff.json"), JSON.generate(report.merge("attempt" => 2, "invocation_id" => "other-invocation")))
      status, out, err = review(data) { flunk "ambiguous task must refuse before inference" }
      assert_equal 2, status
      assert_empty out
      assert_includes err, "multiple matching managed runs"
      assert_equal 0, review(data, "--invocation", "original-invocation") { |argv, bytes|
        answer(argv, JSON.parse(bytes), action: "operator_closeout", proved: "The inspection returned three bindings.", remaining: "David owns acceptance.")
      }.first
    end
  end
end
