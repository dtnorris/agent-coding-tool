# frozen_string_literal: true

require_relative "test_helper"
require_relative "recovery_observations"
require "minitest/mock"
require "stringio"

# Filesystem-only report decisions; native inventory/ownership proofs remain in
# attempt_retry_git_integration.rb. Empty transcripts prohibit dependency work.
class AttemptRecoveryDecisionTest < Minitest::Test
  include TestHelpers
  include RecoveryObservations

  # Yields real private state/report files for failures before native inspection.
  # No worktree or status is fabricated. Filesystem/setup errors propagate and
  # with_workspace removes this fixture and its private evidence after the block.
  def with_report
    with_workspace do |data|
      data = File.realpath(data)
      write_task(data, id: "T", repositories: { "writer" => { "access" => "write" } })
      preparation = { "id" => "T", "prepared_at" => "2026-01-01T00:00:00Z",
                      "snapshot" => { "writer" => { "pushed_sha" => "a" * 40 } } }
      state = preparation.merge("result" => { "outcome" => "failed" })
      AgentCodingTool::StateStore.new(File.join(data, "state")).write("T", state)
      directory = File.join("#{data}-runs", "T", "attempt")
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.write(File.join("#{data}-runs", "launch.lock"), "", perm: 0o600)
      report = { "schema_version" => AgentCodingTool::Launcher::SCHEMA,
                 "task_id" => "T", "attempt" => 1, "invocation_id" => "fixture",
                 "prepared_at" => preparation.fetch("prepared_at"), "preparation" => preparation.fetch("snapshot"),
                 "preparation_state" => preparation,
                 "execution_state" => preparation.merge("started_at" => "2026-01-01T00:00:01Z"),
                 "worktrees_path" => File.join(directory, "worktrees.json"),
                 "worktree_layout" => "attempt", "worktree_creation" => "inventory_persisted" }
      yield data, File.join(directory, "handoff.json"), report
    end
  end

  # Each migrated native permutation must retain its exact production refusal
  # before any external request, preserving all task/evidence bytes. A skipped
  # identity check cannot pass by falling through to another missing-file error.
  def test_foreign_report_identity_refuses_before_native_inspection
    with_report do |data, path, report|
      { "task_id" => "task/attempt/original preparation identity mismatch",
        "preparation" => "task/attempt/original preparation identity mismatch",
        "prepared_at" => "original preparation snapshot changed",
        "execution_state" => "original execution snapshot changed" }.each do |key, reason|
        File.write(path, JSON.generate(report.merge(key => "foreign")))
        before = Dir.glob("#{data}{,-runs}/**/*", File::FNM_DOTMATCH).select { |entry| File.file?(entry) }
                    .to_h { |entry| [entry, File.binread(entry)] }
        with_recovery_observations([]) do
          error = assert_raises(AgentCodingTool::InvalidState) do
            AgentCodingTool::AttemptRecovery.new(data_root: data).close("T")
          end
          assert_equal "close-attempt: history: #{reason}", error.message, key
        end
        after = Dir.glob("#{data}{,-runs}/**/*", File::FNM_DOTMATCH).select { |entry| File.file?(entry) }
                   .to_h { |entry| [entry, File.binread(entry)] }
        assert_equal before, after, key
      end
    end
  end
end

# Historical contract decisions with real prompt/report/state bytes. Native Git
# ownership and liveness are explicit unit boundaries, never acceptance evidence.
class AttemptRepositoryContractTest < Minitest::Test
  include TestHelpers
  include RecoveryObservations

  # Reads only the supplied inventory bytes; does NOT prove native ownership.
  # Production WorktreeManager remains covered by the native retry journey.
  class InventoryBoundary
    # Binds an output-fixture inventory path; no external work occurs.
    def initialize(path)
      @path = path
    end

    # Returns fixture observations for the historical decision under test.
    # JSON/file errors propagate; partial inspection must be explicitly enabled.
    def inspect!(allow_partial:)
      raise "unexpected inspection mode" unless allow_partial
      JSON.parse(File.binread(@path))
    end
  end

  # Produces an original generated prompt and terminal preparation, then yields
  # an output-only fixture. Git ownership and clear liveness are declared fakes;
  # no native Git, worker, sandbox or process containment is proved here.
  def with_contract
    with_workspace do |data|
      data = File.realpath(data)
      write_task(data, id: "T", repositories: {
        "writer" => { "access" => "write" }, "reader" => { "access" => "read_only" }
      })
      File.write(File.join(data, "config.yml"), YAML.dump("worktree_root" => File.join(data, "worktrees")))
      coordinator = coordinator_for(data, "writer" => "a" * 40, "reader" => "b" * 40, "added" => "c" * 40)
      prepared = coordinator.prepare("T")
      original = prepared.fetch("state")
      states = AgentCodingTool::StateStore.new(File.join(data, "state"))
      states.write("T", original.merge("result" => { "outcome" => "blocked" }))
      directory = File.join("#{data}-runs", "T", "attempt")
      FileUtils.mkdir_p(directory, mode: 0o700)
      prompt_path = File.join(directory, "prompt.txt")
      File.binwrite(prompt_path, prepared.fetch("prompt"))
      inventory = { "task_id" => "T", "attempt" => 1, "invocation_id" => "contract-fixture", "entries" =>
        prepared.fetch("task").fetch("repositories").map do |name, spec|
          base = original.fetch("snapshot").fetch(name)
          { "name" => name, "access" => spec.fetch("access"), "state" => "removed",
            "path" => File.join(data, "worktrees", "T", "attempt-1", name),
            "parent" => base.fetch("path"), "remote" => base.fetch("remote"),
            "remote_url" => base.fetch("remote_url"), "source_branch" => base.fetch("branch"), "base_sha" => base.fetch("pushed_sha") }
        end }
      record_path = File.join(directory, "worktrees.json")
      File.write(record_path, JSON.generate(inventory))
      report = { "schema_version" => AgentCodingTool::Launcher::SCHEMA,
        "task_id" => "T", "attempt" => 1, "invocation_id" => "contract-fixture", "status" => "preflight_failed",
        "host_identity" => { "fixture" => true }, "prepared_at" => original.fetch("prepared_at"),
        "preparation" => original.fetch("snapshot"), "preparation_state" => original,
        "worktrees_path" => record_path, "worktrees" => inventory,
        "prompt_sha256" => Digest::SHA256.file(prompt_path).hexdigest, "prompt_bytes" => File.size(prompt_path),
        "artifacts" => [{ "path" => prompt_path, "sha256" => Digest::SHA256.file(prompt_path).hexdigest, "bytes" => File.size(prompt_path) }] }
      report_path = File.join(directory, "handoff.json")
      File.write(report_path, JSON.generate(report))
      liveness = Object.new
      liveness.define_singleton_method(:check) { |_report, _inventory| :clear }
      factory = ->(**options) { InventoryBoundary.new(options.fetch(:record_path)) }
      AgentCodingTool::WorktreeManager.stub(:new, factory) do
        AgentCodingTool::RetryLiveness.stub(:new, liveness) do
          with_recovery_observations([]) { yield data, coordinator, report_path, report }
        end
      end
    end
  end

  # Changed repository membership and both access directions affect fresh
  # preparation, while closeout/retry continue to use the bound old contract.
  # Missing closeout remains a blocker; history and the old prompt stay unchanged.
  def test_changed_task_contract_preserves_history_and_prepares_current_authority
    with_contract do |data, coordinator, report_path, report|
      before = File.binread(report_path)
      write_task(data, id: "T", repositories: {
        "reader" => { "access" => "write" }, "writer" => { "access" => "read_only" },
        "added" => { "access" => "write" }
      })
      recovery = AgentCodingTool::AttemptRecovery.new(data_root: data)
      assert_empty recovery.inspect("T").first.fetch("blockers")
      error = assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("T", retry_result: true) }
      assert_includes error.message, "explicit close-attempt required"
      assert recovery.preflight("T").fetch("dry_run")
      out, err = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: data, out: out, err: err)
      cli.instance_variable_set(:@coordinator, coordinator)
      assert_equal 0, cli.run(%w[close-attempt T]), err.string
      assert_equal 0, cli.run(%w[prepare T --retry]), err.string
      current = AgentCodingTool::StateStore.new(File.join(data, "state")).load("T")
      assert_equal %w[added reader writer], current.fetch("snapshot").keys.sort
      assert_nil current["result"]
      prompt = File.binread(current.fetch("prompt_path"))
      assert_includes prompt, "## Writable repositories\n\n- reader\n- added\n\n## Read-only repositories\n\n- writer\n"
      assert_equal prompt, coordinator.launch_prompt("T").b
      assert_equal before, File.binread(report_path)
      assert_equal report.fetch("preparation"), recovery.closed_state("T", 1).fetch("snapshot")
      # Exercise the public launcher refusal before any worktree/worker creation.
      # CLI capability and remote freshness probes are additional declared fakes;
      # prompt regeneration and history validation remain production behavior.
      launcher = AgentCodingTool::Launcher.new(coordinator: coordinator, data_root: data,
        source_root: Dir.pwd, out: out, err: err,
        spawner: ->(*) { raise "unexpected worker execution" })
      write_task(data, id: "T", repositories: {
        "reader" => { "access" => "read_only" }, "writer" => { "access" => "write" },
        "added" => { "access" => "write" }
      })
      saved_state = File.binread(File.join(data, "state", "T.yml"))
      launcher.stub(:preflight_codex!, nil) do
        launcher.stub(:checked_status!, {}) do
          error = assert_raises(AgentCodingTool::InvalidState) { launcher.launch("T") }
          assert_includes error.message, "generated prompt changed"
          # Membership changes must also refuse an unreprepared launch.
          write_task(data, id: "T", repositories: { "reader" => { "access" => "write" } })
          assert_empty recovery.inspect("T").first.fetch("blockers")
          error = assert_raises(AgentCodingTool::InvalidState) { launcher.launch("T") }
          assert_includes error.message, "incompatible preparation"
        end
      end
      assert_equal saved_state, File.binread(File.join(data, "state", "T.yml"))
      assert_equal [File.dirname(report_path)], Dir.glob(File.join("#{data}-runs", "T", "*"))
    end
  end

  # Coordinated report/inventory rewrites cannot use a new current access claim
  # or matching preparation_state to replace independently bound prompt evidence.
  # Legacy artifact-bound prompts remain supported; unavailable binding refuses.
  def test_tampered_original_contract_refuses_even_when_report_and_inventory_agree
    with_contract do |data, _coordinator, report_path, report|
      mutations = {
        "access" => ->(value) { value.fetch("worktrees").fetch("entries").last["access"] = "write" },
        "base" => ->(value) {
          value.fetch("worktrees").fetch("entries").last["base_sha"] = "d" * 40
          value.fetch("preparation").fetch("reader")["pushed_sha"] = "d" * 40
          value.fetch("preparation_state")["snapshot"] = value.fetch("preparation")
        },
        "membership" => ->(value) {
          value.fetch("worktrees").fetch("entries").pop
          value.fetch("preparation").delete("reader")
          value.fetch("preparation_state")["snapshot"] = value.fetch("preparation")
        },
        "unbound" => ->(value) { value.delete("prompt_sha256"); value.delete("artifacts") }
      }
      recovery = AgentCodingTool::AttemptRecovery.new(data_root: data)
      mutations.each do |label, mutate|
        value = JSON.parse(JSON.generate(report))
        mutate.call(value)
        current = { "writer" => { "access" => "write" }, "reader" => { "access" => "read_only" } }
        current.fetch("reader")["access"] = "write" if label == "access"
        current.delete("reader") if label == "membership"
        write_task(data, id: "T", repositories: current)
        File.write(report_path, JSON.generate(value))
        File.write(report.fetch("worktrees_path"), JSON.generate(value.fetch("worktrees")))
        expected = label == "unbound" ? "not bound to prompt evidence" : "differs from bound prompt"
        assert_includes recovery.inspect("T").first.fetch("blockers").join, expected, label
        error = assert_raises(AgentCodingTool::InvalidState) { recovery.preflight("T") }
        assert_includes error.message, expected, label
        assert_raises(AgentCodingTool::InvalidState) { recovery.retry_ready!("T") }
      end
      File.write(report.fetch("worktrees_path"), JSON.generate(report.fetch("worktrees")))
      legacy = report.reject { |key, _value| %w[prompt_sha256 prompt_bytes].include?(key) }
      File.write(report_path, JSON.generate(legacy))
      assert_empty recovery.inspect("T").first.fetch("blockers")
      File.binwrite(File.join(File.dirname(report_path), "prompt.txt"), "tampered")
      assert_includes recovery.inspect("T").first.fetch("blockers").join, "artifact checksum/length mismatch"
    end
  end
end
