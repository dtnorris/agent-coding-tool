# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../launcher_support'

# Explicit Mac host gate. Uses the installed authenticated Codex CLI for read-only
# capability checks and finite sandbox probes only; never invokes codex exec.
class QuiescenceNativeSandboxTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Proves the real host's local-activity and sandbox boundaries on disposable
  # native worktrees. Requires Codex 0.162.1/ChatGPT auth; unavailable guards fail.
  # This complements, rather than replaces, the fake-worker public CLI journey.
  def test_native_mac_probe_preserves_quiescent_external_workspace
    skip 'NOT RUN: explicit macOS host gate' unless RbConfig::CONFIG.fetch('host_os').match?(/darwin/)
    fixture(git: true, process: true) do
      write_task(@data, id: 'A', repositories: { 'repo' => { 'access' => 'write', 'path' => @ordinary } })
      %w[A T].each { |id| @coordinator.prepare(id) }
      @coordinator.start('A')
      external = File.join(@root, 'external')
      setup_git('worktree', 'add', '--detach', external, @base, chdir: @ordinary)
      File.binwrite(File.join(external, 'unfinished.bin'), "\x00\xffpreserve".b)
      preserved = [@store.state_path('A'), @store.load('A').fetch('prompt_path'),
                   File.join(external, 'unfinished.bin'), File.join(@ordinary, '.git/index')].to_h { |path| [path, File.binread(path)] }
      facility = AgentCodingTool::QuiescenceReview.new(data_root: @data, coordinator: @coordinator, source_root: Dir.pwd)
      review = facility.review('A', 'T', repositories: ['repo'], workspaces: [external])
      facility.approve('A', 'T', review_sha256: review.fetch('review_sha256'), activity: 'ended',
                       all_writers_accounted_for: true, reason: 'Disposable native host probe; no external worker active')
      directory = File.join(@root, 'native-probe')
      FileUtils.mkdir_p(directory, mode: 0o700)
      manager = AgentCodingTool::WorktreeManager.new(root: @config.worktree_root,
        record_path: File.join(directory, 'worktrees.json'), attempt_paths: true, invocation_id: 'native-probe')
      task = AgentCodingTool::TaskStore.new(File.join(@data, 'tasks')).load('T')
      inventory = manager.create(task_id: 'T', attempt: 1, task: task, snapshot: @store.load('T').fetch('snapshot'))
      assert facility.verify!('A', 'T', own_entries: manager.inspect!.fetch('entries'))
      instance = AgentCodingTool::Launcher.new(coordinator: @coordinator, data_root: @data, source_root: Dir.pwd,
        out: @out, err: @err, codex: ENV.fetch('ACT_NATIVE_CODEX', 'codex'))
      instance.send(:preflight_codex!, nil, nil)
      instance.instance_variable_set(:@quiescent_roots, [external, @data])
      instance.instance_variable_set(:@report_path, File.join(directory, 'probe.json'))
      instance.instance_variable_set(:@report, {})
      instance.send(:sandbox_probe!, inventory, inventory.fetch('entries').first.fetch('path'), directory)
      report = JSON.parse(File.binread(File.join(directory, 'probe.json')))
      assert_equal 'macos', report.dig('sandbox_probe', 'platform')
      assert_operator report.dig('sandbox_probe', 'protected_paths'), :>=, 5
      assert facility.verify!('A', 'T', own_entries: manager.inspect!.fetch('entries'))
      assert_equal preserved, preserved.to_h { |path, _| [path, File.binread(path)] }
      assert_equal 'IN_FLIGHT', @coordinator.status('A').fetch('status')
      refute @store.load('T')['started_at']
    end
  end
end
