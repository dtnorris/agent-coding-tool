# frozen_string_literal: true

require_relative "test_helper"
require_relative "recovery_observations"
require "minitest/mock"

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
