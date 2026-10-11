# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class WorktreeManagerTest < Minitest::Test
  def git(*args, chdir: nil)
    stdout, stderr, status = Open3.capture3("git", *args, **(chdir ? { chdir: chdir } : {}))
    raise "fixture git failed: #{stderr}" unless status.success?
    stdout.strip
  end

  def git_seed
    return @@git_seed if defined?(@@git_seed)

    @@git_seed = Dir.mktmpdir("act-worktree-seed-")
    Minitest.after_run { FileUtils.remove_entry(@@git_seed) }
    ordinary = File.join(@@git_seed, "ordinary")
    git("init", "--initial-branch=main", ordinary)
    git("config", "user.email", "fixture@example.test", chdir: ordinary)
    git("config", "user.name", "Fixture", chdir: ordinary)
    File.write(File.join(ordinary, "file.txt"), "base\n")
    git("add", "file.txt", chdir: ordinary)
    git("commit", "-m", "base", chdir: ordinary)
    git("clone", "--bare", ordinary, File.join(@@git_seed, "remote.git"))
    @@git_seed
  end

  def fixture
    Dir.mktmpdir("act-worktrees-") do |root|
      @root = File.realpath(root)
      @ordinary = File.join(@root, "ordinary")
      @remote = File.join(@root, "remote.git")
      @record = File.join(@root, "private", "worktrees.json")
      @visible = File.join(@root, "ACT-Worktrees")
      FileUtils.mkdir_p(File.dirname(@record))
      FileUtils.cp_r(File.join(git_seed, "ordinary"), @ordinary)
      FileUtils.cp_r(File.join(git_seed, "remote.git"), @remote)
      git("remote", "add", "origin", @remote, chdir: @ordinary)
      @base = git("rev-parse", "HEAD", chdir: @ordinary)
      @snapshot = { "repo" => { "path" => @ordinary, "remote" => "origin", "remote_url" => @remote,
                                  "branch" => "main", "pushed_sha" => @base } }
      @task = { "repositories" => { "repo" => { "access" => "write" } } }
      yield
    end
  end

  def manager = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: @record)

  def system_alias(path)
    { "/private/var/" => "/var/", "/private/tmp/" => "/tmp/" }.each do |canonical, alias_prefix|
      return path.sub(canonical, alias_prefix) if path.start_with?(canonical) &&
                                                  File.symlink?(alias_prefix.chomp("/")) &&
                                                  File.realpath(alias_prefix.chomp("/")) == canonical.chomp("/")
    end
    path
  end

  def test_visible_branch_exact_base_and_dirty_divergent_ordinary_checkout
    fixture do
      File.write(File.join(@ordinary, "file.txt"), "local\n")
      git("commit", "-am", "local", chdir: @ordinary)
      File.write(File.join(@ordinary, "untracked"), "untouched")
      before = [git("rev-parse", "HEAD", chdir: @ordinary), git("status", "--porcelain", chdir: @ordinary),
                File.binread(File.join(@ordinary, "untracked"))]
      aliased_snapshot = Marshal.load(Marshal.dump(@snapshot))
      aliased_snapshot.fetch("repo")["path"] = system_alias(@ordinary)
      aliased_manager = AgentCodingTool::WorktreeManager.new(root: system_alias(@visible), record_path: system_alias(@record))
      entry = aliased_manager.create(task_id: "NC-02A", attempt: 1, task: @task, snapshot: aliased_snapshot).fetch("entries").first
      assert_equal File.join(@visible, "NC-02A", "repo"), entry.fetch("path")
      assert_equal @ordinary, entry.fetch("parent")
      assert_equal @visible, JSON.parse(File.read(@record)).fetch("root")
      assert_equal "act/NC-02A/attempt-1", git("branch", "--show-current", chdir: entry.fetch("path"))
      assert_equal @base, git("rev-parse", "HEAD", chdir: entry.fetch("path"))
      assert_equal before, [git("rev-parse", "HEAD", chdir: @ordinary), git("status", "--porcelain", chdir: @ordinary),
                            File.binread(File.join(@ordinary, "untracked"))]
      preflight = manager.cleanup_preflight.first
      assert_equal entry.fetch("path"), preflight.fetch("path")
      assert_equal [], preflight.fetch("blockers")
      assert_equal entry.fetch("path"), AgentCodingTool::WorktreeManager.new(root: @visible, record_path: @record).inspect!.fetch("entries").first.fetch("path")
      second = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: File.join(@root, "private", "second.json"))
      other = second.create(task_id: "NC-02B", attempt: 1, task: @task, snapshot: @snapshot).fetch("entries").first
      assert_equal "act/NC-02B/attempt-1", git("branch", "--show-current", chdir: other.fetch("path"))
    end
  end

  def test_pinned_detached_reader_and_cleanup_blocker
    fixture do
      reader = File.join(@root, "reader")
      FileUtils.cp_r(@ordinary, reader)
      @snapshot["dep"] = { "path" => reader, "remote" => "origin", "remote_url" => @remote,
                            "branch" => "main", "pushed_sha" => @base }
      @task["repositories"]["dep"] = { "access" => "read_only" }
      inventory = manager.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot)
      dep = inventory.fetch("entries").find { |entry| entry["name"] == "dep" }
      assert_nil dep.fetch("branch")
      assert_equal @base, git("rev-parse", "HEAD", chdir: dep.fetch("path"))
      _stdout, _stderr, status = Open3.capture3("git", "symbolic-ref", "-q", "HEAD", chdir: dep.fetch("path"))
      refute status.success?
      File.write(File.join(dep.fetch("path"), "foreign"), "keep")
      assert_equal ["worktree contains changes"], manager.cleanup_preflight.find { |row| row["access"] == "read_only" }.fetch("blockers")
    end
  end

  def test_foreign_paths_partial_metadata_missing_object_and_changed_branch_fail_closed
    fixture do
      target = File.join(@visible, "T", "repo")
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "keep"), "operator")
      assert_raises(AgentCodingTool::InvalidState) { manager.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot) }
      assert_equal "operator", File.read(File.join(target, "keep"))

      missing = Marshal.load(Marshal.dump(@snapshot))
      missing["repo"]["pushed_sha"] = "f" * 40
      assert_raises(AgentCodingTool::InvalidState) { manager.create(task_id: "M", attempt: 1, task: @task, snapshot: missing) }
      refute File.exist?(@record)

      branch_manager = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: File.join(@root, "private", "branch.json"))
      entry = branch_manager.create(task_id: "B", attempt: 1, task: @task, snapshot: @snapshot).fetch("entries").first
      git("switch", "-c", "foreign", chdir: entry.fetch("path"))
      assert_raises(AgentCodingTool::InvalidState) { branch_manager.inspect! }
      assert_equal "foreign", git("branch", "--show-current", chdir: entry.fetch("path"))

      File.write(@record, '{"schema_version":')
      assert_raises(AgentCodingTool::InvalidState) { manager.inspect! }
    end
  end

  def test_symlinked_root_and_interrupted_add_preserve_evidence
    fixture do
      alias_root = File.join(@root, "foreign-alias")
      File.symlink(@ordinary, alias_root)
      foreign_manager = AgentCodingTool::WorktreeManager.new(root: alias_root, record_path: @record)
      assert_raises(AgentCodingTool::InvalidState) { foreign_manager.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot) }
      assert File.symlink?(alias_root)
      nested = File.join(@root, "nested")
      FileUtils.mkdir_p(nested)
      File.symlink(@ordinary, File.join(nested, "redirect"))
      nested_manager = AgentCodingTool::WorktreeManager.new(root: File.join(nested, "redirect", "ACT-Worktrees"), record_path: @record)
      assert_raises(AgentCodingTool::InvalidState) { nested_manager.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot) }
      refute File.exist?(File.join(@ordinary, "ACT-Worktrees"))

      reader = File.join(@root, "reader")
      FileUtils.mkdir_p(reader)
      @snapshot["dep"] = { "path" => reader, "remote" => "origin", "remote_url" => @remote,
                            "branch" => "main", "pushed_sha" => @base }
      @task["repositories"]["dep"] = { "access" => "read_only" }
      FileUtils.mkdir_p(File.join(@visible, "T"))
      File.write(File.join(@visible, "T", "dep"), "occupied between checks")
      assert_raises(AgentCodingTool::InvalidState) { manager.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot) }
      assert_equal "occupied between checks", File.read(File.join(@visible, "T", "dep"))
    end
  end

  def test_fresh_process_inspection_and_cleanup_dry_run_do_not_mutate
    fixture do
      data = File.join(@root, "data")
      FileUtils.mkdir_p(data)
      File.write(File.join(data, "config.yml"), YAML.dump("repo_root" => @root, "worktree_root" => @visible))
      run = File.join("#{data}-runs", "T", "attempt")
      FileUtils.mkdir_p(run)
      record = File.join(run, "worktrees.json")
      owned = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: record)
      entry = owned.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot).fetch("entries").first
      File.write(File.join(entry.fetch("path"), "candidate"), "keep")
      before = [File.binread(record), git("status", "--porcelain", chdir: entry.fetch("path"))]
      out, err = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: data, out: out, err: err)
      assert_equal 0, cli.run(%w[worktrees T])
      assert_equal entry.fetch("path"), JSON.parse(out.string).fetch("attempts").first.fetch("entries").first.fetch("path")
      out.truncate(0)
      out.rewind
      assert_equal 0, cli.run(%w[cleanup T --dry-run])
      assert_equal ["worktree contains changes"], JSON.parse(out.string).fetch("attempts").first.first.fetch("blockers")
      assert_equal before, [File.binread(record), git("status", "--porcelain", chdir: entry.fetch("path"))]
      assert_equal 2, cli.run(%w[cleanup T])
    end
  end
end
