# frozen_string_literal: true

require_relative "../test_helper"
require "minitest/mock"

class CheckpointTest < Minitest::Test
  include TestHelpers

  def self.seed
    return @seed if @seed

    root = Dir.mktmpdir("act-checkpoint-seed-")
    ordinary = File.join(root, "ordinary")
    remote = File.join(root, "remote.git")
    _out, err, status = Open3.capture3("git", "init", "--initial-branch=main", ordinary)
    raise err unless status.success?
    [["user.email", "fixture@example.test"], ["user.name", "Fixture"]].each do |key, value|
      _out, err, status = Open3.capture3("git", "config", key, value, chdir: ordinary)
      raise err unless status.success?
    end
    { "changed.txt" => "old\n", "removed.txt" => "remove\n", "renamed.txt" => "rename\n" }.each do |path, value|
      File.write(File.join(ordinary, path), value)
    end
    [%w[add -A], %w[commit -m baseline]].each do |args|
      _out, err, status = Open3.capture3("git", *args, chdir: ordinary)
      raise err unless status.success?
    end
    _out, err, status = Open3.capture3("git", "clone", "--bare", ordinary, remote)
    raise err unless status.success?
    Minitest.after_run { FileUtils.remove_entry(root) }
    @seed = { ordinary: ordinary, remote: remote }
  end
  def git(*args, chdir: nil)
    out, err, status = Open3.capture3("git", *args, **(chdir ? { chdir: chdir } : {}))
    assert status.success?, err
    out.strip
  end

  def fixture
    Dir.mktmpdir("act-checkpoint-test-") do |root|
      root = File.realpath(root)
      ordinary = File.join(root, "ordinary")
      remote = File.join(root, "remote.git")
      workspace = File.join(root, "workspace")
      data = File.join(root, "data")
      FileUtils.mkdir_p(File.join(data, "tasks"))
      FileUtils.cp_r(self.class.seed.fetch(:ordinary), ordinary)
      FileUtils.cp_r(self.class.seed.fetch(:remote), remote)
      base = git("rev-parse", "HEAD", chdir: ordinary)
      git("remote", "add", "origin", remote, chdir: ordinary)
      git("clone", ordinary, workspace)
      git("remote", "set-url", "origin", remote, chdir: workspace)
      git("checkout", "--detach", base, chdir: workspace)
      File.write(File.join(workspace, "changed.txt"), "updated\n")
      File.write(File.join(workspace, "new.txt"), "untracked\n")
      File.unlink(File.join(workspace, "removed.txt"))
      File.rename(File.join(workspace, "renamed.txt"), File.join(workspace, "moved.txt"))
      write_task(data, id: "T", repositories: { "repo" => { "access" => "write" } })
      snapshot = { "repo" => {
        "path" => ordinary, "remote" => "origin", "remote_url" => remote,
        "branch" => "main", "pushed_sha" => base
      } }
      state = { "id" => "T", "prepared_at" => Time.now.utc.iso8601,
                "started_at" => Time.now.utc.iso8601, "snapshot" => snapshot }
      AgentCodingTool::StateStore.new(File.join(data, "state")).write("T", state)
      yield root, data, ordinary, workspace, base
    end
  end

  def test_record_verifies_complete_changes_and_fresh_process_recovers_without_workspace
    fixture do |root, data, _ordinary, workspace, base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      evidence = checkpoint.record("T", workspace: workspace)
      assert_equal %w[A A D D M], evidence.fetch("changed_files").map { |row| row.fetch("status") }.sort
      assert_equal %w[changed.txt moved.txt new.txt removed.txt renamed.txt], evidence.fetch("changed_files").map { |row| row.fetch("path") }.sort
      assert_equal base, evidence.dig("authority", "pushed_sha")
      assert_equal File.size(evidence.fetch("path")), evidence.fetch("bytes")
      assert_equal Digest::SHA256.file(evidence.fetch("path")).hexdigest, evidence.fetch("sha256")
      coordinator = AgentCodingTool::Coordinator.new(
        task_store: AgentCodingTool::TaskStore.new(File.join(data, "tasks")),
        state_store: AgentCodingTool::StateStore.new(File.join(data, "state")),
        repo_inspector: TestHelpers::FakeInspector.new(heads: { "repo" => base }, remote_urls: { "repo" => File.join(root, "remote.git") }),
        prompt_renderer: AgentCodingTool::PromptRenderer.new, prompt_root: File.join(data, "state", "prompts")
      )
      assert_equal "IN_FLIGHT", coordinator.status("T").fetch("status")
      FileUtils.remove_entry(workspace)
      coordinator.record("T", outcome: "candidate_complete")
      assert_equal "verified", checkpoint.verify("T").fetch("status")
      destination = File.join(root, "recovered")
      fresh = AgentCodingTool::Checkpoint.new(data_root: data)
      assert_raises(AgentCodingTool::InvalidState) { fresh.recover("T", destination: destination) }
      refute File.exist?(destination)
      assert_equal "reconstructed", fresh.recover("T", destination: destination, confirm_disconnected: true).fetch("status")
      assert_equal "updated\n", File.read(File.join(destination, "changed.txt"))
      assert_equal "untracked\n", File.read(File.join(destination, "new.txt"))
      assert_equal "rename\n", File.read(File.join(destination, "moved.txt"))
      refute File.exist?(File.join(destination, "removed.txt"))
    end
  end

  def test_incomplete_and_symlinked_artifacts_cannot_replace_good_checkpoint
    fixture do |root, data, _ordinary, workspace, _base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      old = checkpoint.record("T", workspace: workspace)
      truncated = File.join(root, "truncated.patch")
      File.binwrite(truncated, File.binread(old.fetch("path"))[0, 20])
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace, artifact: truncated) }
      tracked_only = File.join(root, "tracked-only.patch")
      File.binwrite(tracked_only, Open3.capture3("git", "diff", "--binary", "HEAD", chdir: workspace).first)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace, artifact: tracked_only) }
      empty = File.join(root, "empty.patch")
      File.binwrite(empty, "")
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace, artifact: empty) }
      link = File.join(root, "link.patch")
      File.symlink(old.fetch("path"), link)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace, artifact: link) }
      state = AgentCodingTool::StateStore.new(File.join(data, "state")).load("T")
      assert_equal "verified", state.dig("checkpoint", "status")
      File.binwrite(old.fetch("path"), "corrupt")
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T") }
    end
  end

  def test_stale_checkpoint_blocks_expensive_command_then_refreshes
    fixture do |root, data, _ordinary, workspace, _base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      marker = File.join(root, "ran")
      assert_raises(AgentCodingTool::InvalidState) do
        checkpoint.gate("T", workspace: workspace, command: ["touch", marker])
      end
      refute File.exist?(marker)
      old = checkpoint.record("T", workspace: workspace)
      File.write(File.join(workspace, "new.txt"), "changed again\n")
      assert_raises(AgentCodingTool::InvalidState) do
        checkpoint.gate("T", workspace: workspace, command: ["touch", marker])
      end
      refute File.exist?(marker)
      assert_equal "stale", AgentCodingTool::StateStore.new(File.join(data, "state")).load("T").dig("checkpoint", "status")
      checkpoint.stub(:verify_patch!, ->(*) { raise AgentCodingTool::InvalidState, "injected verification interruption" }) do
        assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace) }
      end
      assert_equal old.fetch("record_file"), checkpoint.verify("T").fetch("record").fetch("record_file")
      refreshed = checkpoint.record("T", workspace: workspace)
      refute_equal old.fetch("sha256"), refreshed.fetch("sha256")
      assert_equal old.fetch("record_file"), refreshed.fetch("previous_record")
      out, err = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: root, data_root: data, out: out, err: err)
      assert_equal 0, cli.run(["checkpoint", "gate", "T", "--workspace", workspace, "--", "touch", marker]), err.string
      assert File.file?(marker)
      assert_raises(AgentCodingTool::InvalidState) do
        checkpoint.gate("T", workspace: workspace, command: ["/bin/sh", "-c", "printf changed > new.txt"])
      end
      assert_equal "stale", AgentCodingTool::StateStore.new(File.join(data, "state")).load("T").dig("checkpoint", "status")
    end
  end

  def test_wrong_baseline_and_foreign_or_symlinked_evidence_fail_closed
    fixture do |root, data, _ordinary, workspace, _base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      record = checkpoint.record("T", workspace: workspace)
      git("add", "-A", chdir: workspace)
      git("commit", "-m", "unexpected head", chdir: workspace)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace) }
      assert_equal record.fetch("sha256"), checkpoint.verify("T").fetch("record").fetch("sha256")
      original = File.binread(record.fetch("path"))
      File.unlink(record.fetch("path"))
      foreign = File.join(root, "foreign.patch")
      File.binwrite(foreign, original)
      File.symlink(foreign, record.fetch("path"))
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T") }
    end
  end

  def test_multiple_writers_fail_closed
    with_workspace do |data|
      write_task(data, id: "T", repositories: {
        "one" => { "access" => "write" }, "two" => { "access" => "write" }
      })
      snapshot = %w[one two].to_h do |name|
        [name, { "path" => data, "remote" => "origin", "remote_url" => "test",
                 "branch" => "main", "pushed_sha" => "a" * 40 }]
      end
      AgentCodingTool::StateStore.new(File.join(data, "state")).write("T", {
        "id" => "T", "prepared_at" => Time.now.utc.iso8601,
        "started_at" => Time.now.utc.iso8601, "snapshot" => snapshot
      })
      error = assert_raises(AgentCodingTool::InvalidState) do
        AgentCodingTool::Checkpoint.new(data_root: data).record("T", workspace: data)
      end
      assert_includes error.message, "exactly one writable"
    end
  end

  def test_launch_attempt_rejects_foreign_workspace_and_partial_run_evidence
    fixture do |root, data, _ordinary, workspace, _base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      run_dir = File.join("#{data}-runs", "T", "run")
      FileUtils.mkdir_p(run_dir)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace) }
      state = AgentCodingTool::StateStore.new(File.join(data, "state")).load("T")
      File.write(File.join(run_dir, "handoff.json"), JSON.generate(
        "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "T",
        "prepared_at" => state.fetch("prepared_at"), "workspace" => File.join(root, "foreign"),
        "writable_repository" => "repo", "writable_authority" => state.fetch("snapshot").fetch("repo").slice("remote_url", "branch", "pushed_sha"),
        "invocation_id" => "foreign", "worktrees_path" => File.join(run_dir, "worktrees.json")
      ))
      error = assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace) }
      assert_includes error.message, "launch ownership"
    end
  end

  def test_exemption_and_old_task_default
    with_workspace do |data|
      write_task(data, id: "T")
      store = AgentCodingTool::TaskStore.new(File.join(data, "tasks"))
      assert AgentCodingTool::CheckpointPolicy.required?(store.load("T"))
      path = File.join(data, "tasks", "T.yml")
      task = YAML.safe_load_file(path)
      task["checkpoint"] = { "mode" => "exempt", "category" => "inspection", "reason" => "Read-only audit." }
      File.write(path, YAML.dump(task))
      refute AgentCodingTool::CheckpointPolicy.required?(store.load("T"))
      state = { "id" => "T", "prepared_at" => Time.now.utc.iso8601,
                "started_at" => Time.now.utc.iso8601,
                "snapshot" => { "alpha" => { "path" => data, "remote" => "origin",
                  "remote_url" => "test", "branch" => "main", "pushed_sha" => "a" * 40 } } }
      AgentCodingTool::StateStore.new(File.join(data, "state")).write("T", state)
      assert_equal "exempt", AgentCodingTool::Checkpoint.new(data_root: data).verify("T").fetch("status")
      prompt = AgentCodingTool::PromptRenderer.new.render(task, {})
      assert_equal 1, prompt.scan(/^## Implementation checkpoint$/).length
      task["checkpoint"] = { "mode" => "exempt" }
      File.write(path, YAML.dump(task))
      assert_raises(AgentCodingTool::InvalidTask) { store.load("T") }
    end
  end
end
