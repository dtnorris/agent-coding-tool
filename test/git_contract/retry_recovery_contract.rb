# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../retry_decision_support"
require "minitest/mock"
require "stringio"

# Recovery policy runs against real ownership/state/evidence. Only declared
# external read results are replayed; no ACT validator or durable write is faked.
class RetryRecoveryContract < Minitest::Test
  include TestHelpers
  include RetryDecisionSupport

  # Every non-complete outcome permits the same explicit closeout/readiness
  # handoff. Native preflight supplies the exact ordered transcript; replay keeps
  # validators, backpointer reads, hashes, locks and durable writes real. The
  # public retry journey owns actual fresh launches and protection of old paths.
  def test_terminal_outcome_decisions_use_native_ownership_observations
    with_retry_decision(liveness_checks: 14) do |recovery, report|
      original_state = File.binread(File.join(@decision_data, "state", "T.yml"))
      native = GitContract::Native.new
      @decision_coordinator.record("T", outcome: "blocked", summary: "No candidate.", next_action: "Explicit closeout and retry.")
      plan = Open3.stub(:capture3, native.method(:capture3)) { recovery.preflight("T") }
      assert_empty plan.fetch("attempts").first.fetch("blockers")
      transcript = native.observations
      %w[blocked failed needs_judgment].each do |outcome|
        @decision_coordinator.record("T", outcome: outcome, summary: "No candidate.", next_action: "Explicit closeout and retry.")
        before = retry_decision_bytes
        with_recovery_observations(transcript * 4) do
          assert_equal false, recovery.close("T").fetch("dry_run")
          assert_nil recovery.retry_ready!("T")
        end
        closeout_path = File.join(@decision_directory, "closeout.json")
        closeout = JSON.parse(File.binread(closeout_path))
        assert_equal ["T", 1, "retry-decision"], closeout.values_at("task_id", "attempt", "invocation_id")
        assert_equal outcome, closeout.fetch("state").fetch("result").fetch("outcome")
        assert_equal "Explicit closeout and retry.", closeout.fetch("state").fetch("result").fetch("next_action")
        assert_equal report.fetch("execution_state").reject { |key, _| key == "result" },
                     closeout.fetch("state").reject { |key, _| key == "result" }
        assert_equal 0o600, File.stat(closeout_path).mode & 0o777
        assert_equal before, retry_decision_bytes.reject { |path, _| path == closeout_path }
        closeout.fetch("evidence").each do |name, hash|
          assert_equal hash, Digest::SHA256.file(File.join(@decision_directory, name)).hexdigest
        end
        File.unlink(closeout_path)
        File.binwrite(File.join(@decision_data, "state", "T.yml"), original_state)
      end
      # A genuine on-disk backpointer fault must fail even with faithful Git
      # responses. A second native positive proves exact restoration afterward.
      entry = report.fetch("worktrees").fetch("entries").first
      admin = File.binread(File.join(entry.fetch("path"), ".git")).delete_prefix("gitdir: ").strip
      pointer = File.join(admin, "gitdir")
      original_pointer = File.binread(pointer)
      begin
        File.binwrite(pointer, "foreign\n")
        with_recovery_observations(transcript.take(4)) do
          assert_includes recovery.inspect("T").first.fetch("blockers").join, "native Git backpointer changed"
        end
      ensure
        File.binwrite(pointer, original_pointer)
      end
      @decision_coordinator.record("T", outcome: "failed")
      assert recovery.preflight("T").fetch("dry_run")
    end
  end

  # Changed prompt and closeout identities refuse without changing bytes/modes.
  # Native public checkpoint recovery independently owns original-attempt proof.
  def test_tampered_artifacts_and_closeout_refuse_without_mutation
    with_retry_decision(liveness_checks: 4) do |recovery, report|
      @decision_coordinator.record("T", outcome: "failed")
      prompt_path = File.join(@decision_directory, "prompt.txt")
      original = File.binread(prompt_path)
      File.binwrite(prompt_path, "tampered")
      before = retry_decision_bytes
      error = assert_raises(AgentCodingTool::InvalidState) { recovery.close("T") }
      assert_includes error.message, "original prompt checksum/length mismatch"
      assert_equal before, retry_decision_bytes
      File.binwrite(prompt_path, original)
      recovery.close("T")
      path = File.join(@decision_directory, "closeout.json")
      original_closeout = File.binread(path)
      ["invocation_id", "started_at"].each do |field|
        value = JSON.parse(original_closeout)
        field == "invocation_id" ? value[field] = "foreign" : value.fetch("state")[field] = nil
        File.write(path, JSON.generate(value))
        before = retry_decision_bytes
        error = assert_raises(AgentCodingTool::InvalidState) { @decision_coordinator.prepare("T", retry_result: true) }
        assert_includes error.message, "closeout evidence changed or has foreign identity"
        assert_equal before, retry_decision_bytes
      end
      File.binwrite(path, original_closeout)
      assert_nil recovery.retry_ready!("T")
      assert_equal report.fetch("preparation"), recovery.closed_state("T", 1).fetch("snapshot")
    end
  end

  # Native inventory identity, publication evidence, candidate result and a
  # racing lifecycle writer each retain their distinct production refusal.
  def test_ownership_delivery_candidate_and_changed_state_refusals
    with_retry_decision(liveness_checks: 2) do |recovery, report|
      @decision_coordinator.record("T", outcome: "failed")
      report_path = File.join(@decision_directory, "handoff.json")
      original = File.binread(report_path)
      %w[attempt invocation_id].each do |key|
        value = JSON.parse(original)
        value[key] = key == "attempt" ? 17 : "foreign"
        File.write(report_path, JSON.generate(value))
        before = retry_decision_bytes
        error = assert_raises(AgentCodingTool::InvalidState) { recovery.close("T") }
        assert_includes error.message, "inventory identity mismatch"
        assert_equal before, retry_decision_bytes
        File.binwrite(report_path, original)
      end
      delivery = File.join(@decision_directory, "delivery.json")
      File.write(delivery, JSON.generate("stage" => "validation_failed"))
      before = retry_decision_bytes
      error = assert_raises(AgentCodingTool::InvalidState) { recovery.close("T") }
      assert_includes error.message, "delivery/publication requires its existing recovery path"
      assert_equal before, retry_decision_bytes
      File.unlink(delivery)
      @decision_coordinator.record("T", outcome: "candidate_complete")
      before = retry_decision_bytes
      assert_raises(AgentCodingTool::InvalidState) { recovery.close("T") }
      assert_equal before, retry_decision_bytes
      @decision_coordinator.record("T", outcome: "failed")
      state = @decision_states.load("T")
      changed = false
      racing = AgentCodingTool::AttemptRecovery.new(data_root: @decision_data, liveness: @decision_liveness, before_write: lambda { |_row|
        changed = true
        @decision_states.write("T", state.merge("operator_note" => "changed during preflight"))
      })
      error = assert_raises(AgentCodingTool::InvalidState) { racing.close("T") }
      assert_includes error.message, "evidence or state changed during closeout"
      assert changed
      refute File.exist?(File.join(@decision_directory, "closeout.json"))
      assert_equal report.fetch("preparation"), @decision_states.load("T").fetch("snapshot")
    end
  end
end
