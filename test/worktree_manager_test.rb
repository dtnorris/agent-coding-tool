# frozen_string_literal: true

require_relative "test_helper"
require_relative "recovery_observations"
require "minitest/mock"
require "stringio"

# Exercises production ownership against disposable native Git, with declared
# observations only for decisions that refuse before any native mutation.
class WorktreeManagerTest < Minitest::Test
  include RecoveryObservations

  def git(*args, chdir: nil)
    stdout, stderr, status = Open3.capture3("git", *args, **(chdir ? { chdir: chdir } : {}))
    raise "fixture git failed: #{stderr}" unless status.success?
    stdout.strip
  end

  def fixture(git: true)
    Dir.mktmpdir("act-worktrees-") do |root|
      @root = File.realpath(root)
      @ordinary = File.join(@root, "ordinary")
      seed = TestHelpers.git_seed if git
      @remote = git ? File.join(seed.fetch(:root), "remote.git") : File.join(@root, "remote.git")
      @record = File.join(@root, "private", "worktrees.json")
      @visible = File.join(@root, "ACT-Worktrees")
      FileUtils.mkdir_p(File.dirname(@record))
      if git
        # The seed remote is immutable in this suite; each test owns its copied
        # ordinary checkout, refs, worktrees and ownership record.
        FileUtils.cp_r(File.join(seed.fetch(:root), "ordinary"), @ordinary)
        @base = seed.fetch(:base)
      else
        # These failures occur before Git identity is consulted.
        FileUtils.mkdir_p([@ordinary, @remote])
        @base = "a" * 40
      end
      @snapshot = { "repo" => { "path" => @ordinary, "remote" => "origin", "remote_url" => @remote,
                                  "branch" => "main", "pushed_sha" => @base } }
      @task = { "repositories" => { "repo" => { "access" => "write" } } }
      yield
    end
  end

  def manager = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: @record)

  # Both recorded layouts retain native removal gates while regular metadata
  # alone permits disposal of the entire already authorized owned worktree.
  def test_metadata_discovery_and_native_removal_in_both_layouts
    [false, true].each do |attempt_paths|
      fixture do
        handler = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: @record, attempt_paths: attempt_paths)
        inventory = handler.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot)
        workspace = inventory.fetch("entries").first.fetch("path")
        directories = [@visible, File.join(@visible, "T"), File.dirname(workspace), workspace, File.join(workspace, "space\ncontrol")].uniq
        metadata = directories.map do |directory|
          FileUtils.mkdir_p(directory)
          path = File.join(directory, ".DS_Store")
          File.binwrite(path, "Finder\x00\xff".b)
          path
        end
        assert_empty AgentCodingTool::WorktreeManager.foreign_task_paths(root: @visible, task_id: "T", paths: [workspace])
        assert_equal false, handler.cleanup_preflight.first.fetch("dirty")
        metadata.each { |path| assert_equal "Finder\x00\xff".b, File.binread(path) }
        # Each nonregular metadata entry remains a blocker for native disposal.
        nested = metadata.last
        File.unlink(nested)
        [:symlink, :dangling, :fifo, :directory].each do |kind|
          case kind
          when :symlink then File.symlink(File.join(workspace, "file.txt"), nested)
          when :dangling then File.symlink(File.join(workspace, "absent"), nested)
          when :fifo then File.mkfifo(nested)
          when :directory
            Dir.mkdir(nested)
            File.write(File.join(nested, "keep"), "substantive")
          end
          assert_raises(AgentCodingTool::InvalidState) { handler.cleanup_preflight }
          assert_raises(AgentCodingTool::InvalidState) { handler.remove_entry!("repo") }
          assert File.directory?(workspace)
          kind == :directory ? FileUtils.remove_entry(nested) : File.unlink(nested)
        end
        File.binwrite(nested, "later Finder bytes")
        git("config", "core.excludesFile", File.join(@root, "excludes"), chdir: workspace)
        File.write(File.join(@root, "excludes"), "ignored-keep\n")
        File.write(File.join(workspace, "ignored-keep"), "substantive ignored work")
        assert handler.cleanup_preflight.first.fetch("dirty")
        assert_raises(AgentCodingTool::InvalidState) { handler.remove_entry!("repo") }
        File.unlink(File.join(workspace, "ignored-keep"))
        handler.remove_entry!("repo")
        refute File.exist?(workspace)
        metadata.reject { |path| path.start_with?(workspace + "/") }.each { |path| assert_equal "Finder\x00\xff".b, File.binread(path) }
        assert_equal "removed", handler.inspect!.fetch("entries").first.fetch("state")
      end
    end
  end

  # Real filesystem socket control, separate because confined workers may deny
  # socket creation. Such denial fails this native gate; it is never skipped.
  def test_repository_metadata_socket_refuses_disposal
    fixture do
      handler = manager
      inventory = handler.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot)
      workspace = inventory.fetch("entries").first.fetch("path")
      socket = Dir.chdir(workspace) { UNIXServer.new(".DS_Store") }
      begin
        assert File.lstat(File.join(workspace, ".DS_Store")).socket?
        assert_raises(AgentCodingTool::InvalidState) { handler.cleanup_preflight }
        assert_raises(AgentCodingTool::InvalidState) { handler.remove_entry!("repo") }
        assert File.directory?(workspace)
      ensure
        socket.close
      end
    end
  end

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

  # Occupied paths, missing prepared objects and malformed records refuse without
  # writes; a genuine changed native branch remains an independent refusal case.
  def test_foreign_paths_partial_metadata_missing_object_and_changed_branch_fail_closed
    fixture(git: false) do
      target = File.join(@visible, "T", "repo")
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "keep"), "operator")
      with_recovery_observations([]) do
        error = assert_raises(AgentCodingTool::InvalidState) { manager.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot) }
        assert_includes error.message, "occupied path"
      end
      assert_equal "operator", File.read(File.join(target, "keep"))

      missing = Marshal.load(Marshal.dump(@snapshot))
      missing["repo"]["pushed_sha"] = "f" * 40
      observations = [
        recovery_observation(@ordinary, "git", "rev-parse", "--path-format=absolute",
          "--show-toplevel", "--git-common-dir", "--absolute-git-dir",
          stdout: "#{@ordinary}\n#{@ordinary}/.git\n#{@ordinary}/.git\n".b),
        recovery_observation(@ordinary, "git", "remote", "get-url", "origin", stdout: "#{@remote}\n".b),
        recovery_observation(@ordinary, { "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0" },
          "git", "--no-replace-objects", "cat-file", "-e", "#{'f' * 40}^{commit}",
          stderr: "fatal: Not a valid object name #{'f' * 40}^{commit}\n".b, exit_code: 128)
      ]
      with_recovery_observations(observations) do
        error = assert_raises(AgentCodingTool::InvalidState) { manager.create(task_id: "M", attempt: 1, task: @task, snapshot: missing) }
        assert_includes error.message, "Local repo repo is missing required commit #{'f' * 40}"
      end
      # Identity failures precede the object probe and keep their own diagnosis.
      changed_remote = observations.take(1) + [
        recovery_observation(@ordinary, "git", "remote", "get-url", "origin", stdout: "different-remote\n".b)
      ]
      with_recovery_observations(changed_remote) do
        error = assert_raises(AgentCodingTool::InvalidState) { manager.creation_readiness!(task: @task, snapshot: missing) }
        assert_equal "worktrees: remote identity changed", error.message
      end
      absent = Marshal.load(Marshal.dump(missing))
      absent["repo"]["path"] = File.join(@root, "absent")
      with_recovery_observations([]) do
        error = assert_raises(AgentCodingTool::InvalidState) { manager.creation_readiness!(task: @task, snapshot: absent) }
        assert_equal "worktrees: ordinary checkout missing #{absent['repo']['path']}", error.message
      end
      refute File.exist?(@record)
      refute File.exist?(File.join(@visible, "M", "repo"))
      assert_equal "operator", File.binread(File.join(target, "keep"))

      File.write(@record, '{"schema_version":')
      with_recovery_observations([]) do
        error = assert_raises(AgentCodingTool::InvalidState) { manager.inspect! }
        assert_includes error.message, "malformed ownership"
      end
      assert_equal '{"schema_version":', File.binread(@record)
    end
    fixture do
      branch_manager = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: File.join(@root, "private", "branch.json"))
      entry = branch_manager.create(task_id: "B", attempt: 1, task: @task, snapshot: @snapshot).fetch("entries").first
      git("switch", "-c", "foreign", chdir: entry.fetch("path"))
      assert_raises(AgentCodingTool::InvalidState) { branch_manager.inspect! }
      assert_equal "foreign", git("branch", "--show-current", chdir: entry.fetch("path"))
    end
  end

  def test_symlinked_root_and_interrupted_add_preserve_evidence
    fixture(git: false) do
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
      FileUtils.mkdir_p(run, mode: 0o700)
      record = File.join(run, "worktrees.json")
      FileUtils.mkdir_p([File.join(data, "tasks"), File.join(data, "state")])
      task = { "id" => "T", "title" => "Cleanup fixture", "repositories" => @task.fetch("repositories") }
      File.write(File.join(data, "tasks", "T.yml"), YAML.dump(task))
      AgentCodingTool::StateStore.new(File.join(data, "state")).write("T",
        { "id" => "T", "snapshot" => @snapshot })
      owned = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: record)
      inventory = owned.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot)
      entry = inventory.fetch("entries").first
      # Historical inspection requires the generated, checksum-bound authority
      # contract even when this fixture exercises only worktree discovery.
      prompt = AgentCodingTool::PromptRenderer.new.render(task, @snapshot)
      File.binwrite(File.join(run, "prompt.txt"), prompt)
      File.write(File.join(run, "handoff.json"), JSON.generate(
        "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "T",
        "attempt" => 1, "worktrees_path" => record, "worktrees" => inventory,
        "preparation" => @snapshot, "status" => "exited",
        "prompt_sha256" => Digest::SHA256.hexdigest(prompt), "prompt_bytes" => prompt.bytesize))
      File.write(File.join(entry.fetch("path"), "candidate"), "keep")
      before = [File.binread(record), git("status", "--porcelain", chdir: entry.fetch("path"))]
      out, err = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: data, out: out, err: err)
      assert_equal 0, cli.run(%w[worktrees T])
      assert_equal entry.fetch("path"), JSON.parse(out.string).fetch("attempts").first.fetch("entries").first.fetch("path")
      out.truncate(0)
      out.rewind
      assert_equal 0, cli.run(%w[cleanup T --dry-run])
      assert_includes JSON.parse(out.string).fetch("attempts").first.first.fetch("blockers"), "worktree contains changes"
      assert_equal before, [File.binread(record), git("status", "--porcelain", chdir: entry.fetch("path"))]
      assert_equal 2, cli.run(%w[cleanup T])
    end
  end

  # A legacy repository name can coincide with a new attempt container. Refuse
  # before Git/evidence writes rather than nesting retry authority inside it.
  def test_attempt_container_cannot_reuse_an_existing_resource
    fixture(git: false) do
      container = File.join(@visible, "T", "attempt-2")
      FileUtils.mkdir_p(container)
      File.write(File.join(container, "keep"), "legacy resource")
      isolated = AgentCodingTool::WorktreeManager.new(root: @visible, record_path: @record, attempt_paths: true)
      error = assert_raises(AgentCodingTool::InvalidState) do
        isolated.create(task_id: "T", attempt: 2, task: @task, snapshot: @snapshot)
      end
      assert_includes error.message, "occupied attempt container"
      assert_equal "legacy resource", File.binread(File.join(container, "keep"))
      refute File.exist?(@record)
    end
  end

  # A copied/changed Git pointer cannot borrow another native registration's
  # common administration, HEAD or detached-reader identity as ownership proof.
  def test_native_backpointer_mismatch_preserves_the_resource
    fixture do
      entry = manager.create(task_id: "T", attempt: 1, task: @task, snapshot: @snapshot).fetch("entries").first
      admin = git("rev-parse", "--absolute-git-dir", chdir: entry.fetch("path"))
      pointer = File.join(admin, "gitdir")
      original = File.binread(@record)
      original_pointer = File.binread(pointer)
      begin
        File.write(pointer, File.join(@root, "foreign", ".git") + "\n")
        error = assert_raises(AgentCodingTool::InvalidState) { manager.inspect! }
        assert_includes error.message, "native Git backpointer changed"
        assert_equal original, File.binread(@record)
        assert File.directory?(entry.fetch("path"))
        assert_equal File.join(@root, "foreign", ".git") + "\n", File.binread(pointer)
      ensure
        File.binwrite(pointer, original_pointer)
      end
      assert_equal entry, manager.inspect!.fetch("entries").first
      assert_equal [], manager.cleanup_preflight.first.fetch("blockers")
    end
  end
end
