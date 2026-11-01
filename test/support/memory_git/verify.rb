# frozen_string_literal: true

# Standalone focused verifier. Guard loads before bundler, Minitest or production;
# the unmigrated test_helper/Rake harness is deliberately never loaded.
require_relative "../no_git_execution"
require_relative "../../ordinary_execution"
require "bundler/setup"
require "minitest/autorun"
Minitest::Assertions.diff = nil
require "json"
require "securerandom"
require "stringio"
require "tmpdir"
require_relative "../../../lib/agent_coding_tool"
require_relative "../memory_git"

# Independent behavioral proof for the finite model; not live Git conformance.
class MemoryGitVerifier < Minitest::Test
  SEED = MemoryGit::Template.files({ "file.txt" => "base\n", "nested/keep" => "keep\n" })
  STATUS = %w[status --porcelain=v1 -z --untracked-files=all].freeze
  CODING = "---\nname: karpathy-manning-dtnorris-guidelines\ndescription: Model fixture.\nlicense: MIT\n---\n\nInspect and verify.\n"
  PLANNING = "---\nname: agentic-task-planning\ndescription: Model fixture.\nlicense: MIT\n---\n\nOwn integration and acceptance.\n"

  # Gives each case fresh stores, files and fault schedule; no native seed setup.
  def setup
    @directory = Dir.mktmpdir("memory-git-")
    @root = File.realpath(@directory)
    @previous_tmpdir = ENV["TMPDIR"]
    ENV["TMPDIR"] = @root
    @world = MemoryGit::World.new(root: @root)
    @repo = @world.repository(path: "ordinary", template: SEED)
    @remote = @world.remote(url: "git@github.com:example/repo.git", from: @repo)
    @world.connect(@repo, @remote)
  end

  # Required fault consumption is checked even after assertion failures. Physical
  # cleanup remains real and guard-protected; never shares a following case's state.
  def teardown
    @world.verify!
  ensure
    ENV["TMPDIR"] = @previous_tmpdir
    FileUtils.remove_entry(@directory)
  end

  # Calls the public transport with explicit cwd; returns raw CommandResult.
  def git(*arguments, checkout: @repo, **fields)
    @world.call(["git", *arguments], cwd: checkout&.path, **fields)
  end

  # Requires command success and returns binary output. Assertions remain separate
  # from model state access so a missing command mutation cannot manufacture a pass.
  def output(*arguments, **fields)
    response = git(*arguments, **fields)
    assert response.success?, response.stderr
    response.stdout
  end

  # Writes an actual working file without changing the modeled index/HEAD.
  def write(path, bytes, checkout: @repo)
    absolute = File.join(checkout.path, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, bytes)
  end

  # Independent filesystem snapshot of ordinary fixture files, modes and links.
  # Avoids the materializer and model scan/getters as an assertion oracle.
  def physical(checkout)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: checkout.path).reject { |path| path == "." || path.start_with?(".git/", ".git") }
      .sort.filter_map do |path|
        absolute = File.join(checkout.path, path)
        stat = File.lstat(absolute)
        next if stat.directory?
        [path.b, stat.symlink? ? File.readlink(absolute).b : File.binread(absolute), stat.symlink? ? nil : stat.mode & 0o777, stat.symlink?]
      end
  end

  # Materialization binds immutable byte/mode/link content; IDs are deterministic
  # across independent construction, and callers cannot mutate stored objects.
  def test_immutable_objects_and_real_materialization
    files = { "binary" => "\x00\xff".b, "run" => MemoryGit::Entry.new("run\n", mode: "100755"),
      "link" => MemoryGit::Entry.new("binary", mode: "120000") }
    template = MemoryGit::Template.files(files)
    assert_equal template.head, MemoryGit::Template.files(files).head
    checkout = @world.repository(path: "modes", template: template)
    assert_equal [["binary".b, "\x00\xff".b, 0o644, false], ["link".b, "binary".b, nil, true], ["run".b, "run\n".b, 0o755, false]], physical(checkout)
    blob = template.commits.first.tree.entries.fetch("binary").blob
    assert_raises(FrozenError) { blob.bytes << "changed" }
    assert_raises(FrozenError) { template.commits.first.tree.entries["foreign"] = blob }
    assert_raises(FrozenError) { template.commits << nil }
    refute File.exist?(File.join(checkout.admin, "objects"))
    refute File.exist?(File.join(checkout.admin, "HEAD"))
  end

  # New worlds rebuild refs/index/remotes/faults from immutable seed, not cached
  # mutable repositories or result objects from previous cases.
  def test_fresh_world_and_copy_isolation
    copied = @world.copy(@repo, path: "copied")
    write("file.txt", "copy\n", checkout: copied)
    output("add", "--", "file.txt", checkout: copied)
    output("commit", "-m", "copy", checkout: copied)
    refute_equal output("rev-parse", "HEAD", checkout: copied), output("rev-parse", "HEAD")
    assert_equal "base\n", File.binread(File.join(@repo.path, "file.txt"))
    assert_empty output(*STATUS)
    @world.configure(copied, "remote.origin.url", "git@github.com:other/repo.git")
    assert_equal @remote.url + "\n", output("remote", "get-url", "origin")
    other = MemoryGit::World.new(root: @root)
    fresh = other.repository(path: "fresh", template: SEED)
    remote = other.remote(url: @remote.url, from: fresh)
    remote.refs.clear
    refute_empty @remote.refs
    fresh.index.clear
    refute_empty @repo.index
    assert other.verify!
  end

  # Unborn, detached and missing refs remain distinct; branch creation does not
  # fabricate a commit and deleting an active branch must fail.
  def test_unborn_detached_and_missing_refs
    unborn = @world.repository(path: "unborn")
    refute git("rev-parse", "HEAD", checkout: unborn).success?
    assert_equal "refs/heads/main\n", output("symbolic-ref", "-q", "HEAD", checkout: unborn)
    assert_equal 1, git("show-ref", "--verify", "--quiet", "refs/heads/main", checkout: unborn).exitstatus
    write("new", "first", checkout: unborn)
    output("add", "--", "new", checkout: unborn)
    output("commit", "-m", "first", checkout: unborn)
    assert_equal "first", output("show", "HEAD:new", checkout: unborn)
    output("worktree", "add", "--detach", "--", File.join(@root, "detached"), @repo.head)
    detached = @repo.repository.worktrees.fetch(File.join(@root, "detached"))
    assert_equal 1, git("symbolic-ref", "-q", "HEAD", checkout: detached).exitstatus
    assert_equal "HEAD\n", output("rev-parse", "--symbolic-full-name", "HEAD", checkout: detached)
    assert_equal 1, git("branch", "-D", "main").exitstatus
    refute git("cat-file", "-e", "#{'f' * 40}^{commit}").success?
  end

  # Parent traversal and ancestry include all parents, not only linear equality.
  def test_parent_graph_and_tree_reads
    base = @repo.head
    left = @world.build_commit(@repo, files: { "left" => "left" })
    right = @world.build_commit(@repo, files: { "right" => "right" })
    merge = @world.build_commit(@repo, files: { "merged" => "yes" }, parents: [left.oid, right.oid], advance: true)
    assert_equal right.oid + "\n", output("rev-parse", "HEAD^2")
    assert_equal base + "\n", output("rev-parse", "HEAD~2")
    assert git("merge-base", "--is-ancestor", right.oid, merge.oid).success?
    refute git("merge-base", "--is-ancestor", merge.oid, right.oid).success?
    assert_equal "yes", output("cat-file", "blob", "HEAD:merged")
    assert_equal "change\n\n", output("show", "-s", "--format=%B", "HEAD")
    assert_equal merge.tree.oid + "\n", output("rev-parse", "HEAD^{tree}")
    assert_equal "100644 blob #{merge.tree.entries.fetch('merged').blob.oid}\tmerged\n", output("ls-tree", "HEAD", "--", "merged")
    assert_equal "merged\0", output("ls-tree", "-r", "--name-only", "-z", "HEAD")
    refute git("rev-parse", "HEAD^3").success?
  end

  # A command sequence distinguishes HEAD/index/physical state and subsequent
  # reads independently prove stage/commit effects, including retained index work.
  def test_stage_commit_sequence_and_only_preserves_unrelated_index
    write("file.txt", "staged\n")
    write("nested/keep", "unrelated staged\n")
    output("add", "--", "file.txt", "nested/keep")
    write("file.txt", "later\n")
    assert_equal "MM file.txt\0M  nested/keep\0", output(*STATUS)
    assert_equal "staged\n", output("show", ":file.txt")
    assert_equal "base\n", output("show", "HEAD:file.txt")
    before = @repo.head
    output("commit", "--only", "-m", "scoped", "--", "file.txt")
    assert_equal before + "\n", output("rev-parse", "HEAD^")
    assert_equal "later\n", output("show", "HEAD:file.txt")
    assert_equal "keep\n", output("show", "HEAD:nested/keep")
    assert_equal "unrelated staged\n", output("show", ":nested/keep")
    assert_equal "M  nested/keep\0", output(*STATUS)
    tree = output("write-tree").strip
    output("commit", "-m", "remaining")
    assert_equal tree + "\n", output("rev-parse", "HEAD^{tree}")
    assert_empty output(*STATUS)
  end

  # Deletions, executable changes, symlinks, ignored/untracked and invalid UTF-8
  # paths survive real files and porcelain NUL bytes without text coercion.
  def test_status_modes_deletion_ignored_and_odd_paths
    File.unlink(File.join(@repo.path, "nested/keep"))
    File.chmod(0o755, File.join(@repo.path, "file.txt"))
    odd = "odd\n\té".b
    write(odd, "bytes\0\xff".b)
    write("ignored/file", "ignored")
    @repo.ignored << "ignored/"
    File.symlink("file.txt", File.join(@repo.path, "link"))
    assert_equal " M file.txt\0?? link\0 D nested/keep\0?? #{odd}\0".b, output(*STATUS)
    assert_includes output(*STATUS, "--ignored"), "!! ignored/file\0"
    assert_equal "ignored/file\0", output("ls-files", "-z", "--others", "--ignored", "--exclude-standard")
    assert git("check-ignore", "--quiet", "--", "ignored/file").success?
    output("add", "-A", "--", ".")
    output("commit", "-m", "modes and paths")
    assert_equal "bytes\0\xff".b, output("show", "HEAD:#{odd}".b)
    assert_equal "100755", output("ls-files", "--stage", "--", "file.txt").split.first
    assert_equal "120000", output("ls-files", "--stage", "--", "link").split.first
    refute git("cat-file", "-e", "HEAD:nested/keep").success?
    assert_empty output(*STATUS)
    invalid = "invalid\xff".b
    imported = @world.build_commit(@repo, files: { invalid => "binary path" })
    assert_equal invalid + "\0", output("ls-tree", "-r", "--name-only", "-z", imported.oid)
    assert_equal "binary path", output("show", "#{imported.oid}:#{invalid}".b)
  end

  # Deleting in the index and recreating physically must expose both the staged
  # deletion and untracked replacement; an ignored replacement stays separate.
  def test_staged_deletion_and_recreated_untracked_file
    File.unlink(File.join(@repo.path, "file.txt"))
    output("add", "--", "file.txt")
    write("file.txt", "replacement")
    assert_equal "D  file.txt\0?? file.txt\0", output(*STATUS)
    assert_equal "file.txt\0", output("ls-files", "--others", "--exclude-standard", "-z")
    @repo.ignored << "file.txt"
    assert_equal "D  file.txt\0", output(*STATUS)
    assert_equal "D  file.txt\0!! file.txt\0", output(*STATUS, "--ignored")
  end

  # Copying staged state must also copy its immutable blob storage. Direct config
  # adapters mutate authority; unrelated raw config file bytes do not impersonate it.
  def test_copy_retains_staged_blobs_and_explicit_config_authority
    write("file.txt", "staged copy")
    output("add", "--", "file.txt")
    copied = @world.copy(@repo, path: "staged-copy")
    assert_equal "staged copy", output("show", ":file.txt", checkout: copied)
    assert_equal "M  file.txt\0", output(*STATUS, checkout: copied)
    File.binwrite(File.join(copied.admin, "config"), "[remote \"origin\"]\nurl = foreign\n")
    assert_equal @remote.url + "\n", output("remote", "get-url", "origin", checkout: copied)
    @world.configure(copied, "remote.origin.url", "explicit")
    assert_equal "explicit\n", output("config", "--get", "remote.origin.url", checkout: copied)
    assert_equal @remote.url + "\n", output("remote", "get-url", "origin")
  end

  # The materialization seam supports tracked directory/file and symlink changes
  # without writing through a malicious directory symlink to another location.
  def test_materializer_transitions_and_symlink_ancestor_refusal
    @world.build_commit(@repo, files: { "nested" => "now a file", "link" => MemoryGit::Entry.new("nested", mode: "120000") }, advance: true)
    assert_equal "now a file", File.binread(File.join(@repo.path, "nested"))
    @world.build_commit(@repo, files: { "link" => "regular", "nested/new" => "child" }, advance: true)
    refute File.symlink?(File.join(@repo.path, "link"))
    assert_equal "regular", File.binread(File.join(@repo.path, "link"))
    outside = File.join(@root, "outside")
    Dir.mkdir(outside)
    File.symlink(outside, File.join(@repo.path, "redirect"))
    assert_raises(MemoryGit::Mismatch) do
      @world.materialize!(@repo, {}, { "redirect/foreign" => MemoryGit::Entry.new("wrong") })
    end
    refute File.exist?(File.join(outside, "foreign"))
  end

  # Physical nonregular Finder metadata still reaches the real production lstat
  # refusal. The model must neither block reading a FIFO nor erase that resource.
  def test_real_nonregular_metadata_and_replaced_administration_refuse
    path = File.join(@repo.path, ".DS_Store")
    File.mkfifo(path)
    assert File.lstat(path).pipe?
    assert_raises(AgentCodingTool::InvalidState) do
      AgentCodingTool::IncidentalMetadata.git_status(@repo.path) { |*arguments| output(*arguments) }
    end
    assert File.lstat(path).pipe?
    File.unlink(path)
    original = @repo.admin + "-original"
    File.rename(@repo.admin, original)
    FileUtils.mkdir_p(@repo.admin)
    refute git("rev-parse", "HEAD").success?
    assert File.directory?(original)
  end

  # Remote ref visibility must not depend on objects already present locally.
  # Fetch fills storage explicitly; a missing branch still exits 2.
  def test_remote_visibility_fetch_and_missing_refs
    upstream = @world.repository(path: "upstream", template: SEED)
    advanced = @world.build_commit(upstream, files: { "new" => "upstream" }, advance: true)
    @remote.objects.merge!(upstream.repository.objects)
    @remote.refs["refs/heads/main"] = advanced.oid
    assert_equal "#{advanced.oid}\trefs/heads/main\n", output("ls-remote", "--exit-code", "origin", "refs/heads/main")
    refute git("cat-file", "-e", "#{advanced.oid}^{commit}").success?
    output("fetch", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
    assert_equal "upstream", output("show", "origin/main:new")
    assert_equal SEED.head + "\n", output("rev-parse", "HEAD")
    assert_equal 2, git("ls-remote", "--exit-code", "origin", "refs/heads/missing").exitstatus
    assert_equal "#{advanced.oid}\trefs/heads/main\n", @world.call(["git", "ls-remote", "--exit-code", @remote.url, "refs/heads/main"]).stdout
  end

  # An exact transient fetch failure leaves no ref/object mutation; retry recovers
  # in the same world. Scheduled faults cannot leak into a different envelope.
  def test_fetch_failure_then_recovery
    argv = ["git", "fetch", "origin", "main"]
    @world.fault(argv: argv, cwd: @repo.path) { raise MemoryGit::Refusal, "scheduled offline" }
    response = @world.call(argv, cwd: @repo.path)
    refute response.success?
    assert_includes response.stderr, "scheduled offline"
    refute @repo.repository.refs.key?("FETCH_HEAD")
    assert @world.call(argv, cwd: @repo.path).success?
    assert_equal SEED.head + "\n", output("rev-parse", "FETCH_HEAD")
    assert @world.verify!
  end

  # Lease failures leave both remote objects and refs unchanged. Successful push
  # becomes visible through a later read, not merely the mutation's return status.
  def test_push_absent_existing_moved_leases_and_fast_forward
    write("file.txt", "topic\n")
    output("add", "--", "file.txt")
    output("commit", "-m", "topic")
    head = output("rev-parse", "HEAD").strip
    target = "refs/heads/topic"
    push = ["push", "--force-with-lease=#{target}:", "origin", "#{head}:#{target}"]
    output(*push)
    assert_equal "#{head}\t#{target}\n", output("ls-remote", "--exit-code", "origin", target)
    before = [@remote.refs.dup, @remote.objects.dup]
    assert_equal 1, git(*push).exitstatus
    assert_equal before, [@remote.refs, @remote.objects]
    output("push", "origin", "HEAD:refs/heads/main")
    assert_equal head, @remote.refs.fetch("refs/heads/main")
    @remote.refs[target] = SEED.head
    assert_equal 1, git("push", "--force-with-lease=#{target}:#{head}", "origin", "HEAD:#{target}").exitstatus
    @remote.refs["refs/heads/main"] = "f" * 40
    assert_equal 1, git("push", "origin", "HEAD:refs/heads/main").exitstatus
  end

  # A declared upstream race is an in-memory effect, never a shell hook; the
  # ordinary lease check observes it and preserves the competing ref.
  def test_remote_race_and_after_commit_hook_effect
    target = "refs/heads/topic"
    argv = ["git", "push", "--force-with-lease=#{target}:", "origin", "HEAD:#{target}"]
    @world.fault(argv: argv, cwd: @repo.path) { @remote.refs[target] = SEED.head }
    assert_equal 1, @world.call(argv, cwd: @repo.path).exitstatus
    assert_equal SEED.head, @remote.refs[target]
    target = "refs/heads/effect-race"
    argv = ["git", "push", "--force-with-lease=#{target}:", "origin", "HEAD:#{target}"]
    @world.fault(argv: argv, cwd: @repo.path, phase: :before_effect, effect: :push) { @remote.refs[target] = SEED.head }
    assert_equal 1, @world.call(argv, cwd: @repo.path).exitstatus
    assert_equal SEED.head, @remote.refs[target]
    write("file.txt", "committed")
    output("add", "--", "file.txt")
    @world.fault(argv: %w[git commit -m hooks], cwd: @repo.path, phase: :after_effect, effect: :commit) { write("file.txt", "hook changed") }
    output("commit", "-m", "hooks")
    assert_equal "committed", output("show", "HEAD:file.txt")
    assert_equal " M file.txt\0", output(*STATUS)
  end

  # Exact command/effect omission controls independently fail later observations.
  # Passing mutation status by itself is intentionally insufficient evidence.
  def test_deliberately_omitted_stage_commit_fetch_and_push_are_detectable
    write("file.txt", "changed")
    @world.fault(argv: %w[git add -- file.txt], cwd: @repo.path, phase: :before_effect, effect: :stage, skip: true)
    output("add", "--", "file.txt")
    assert_equal "base\n", output("show", ":file.txt")
    refute_equal "M  file.txt\0", output(*STATUS)
    output("add", "--", "file.txt")
    original = @repo.head
    @world.fault(argv: %w[git commit -m omitted], cwd: @repo.path, phase: :before_effect, effect: :commit, skip: true)
    output("commit", "-m", "omitted")
    assert_equal original + "\n", output("rev-parse", "HEAD")
    refute_empty output(*STATUS)
    @world.fault(argv: %w[git fetch origin main], cwd: @repo.path, phase: :before_effect, effect: :fetch, skip: true)
    output("fetch", "origin", "main")
    refute git("rev-parse", "FETCH_HEAD").success?
    argv = ["git", "push", "origin", "HEAD:refs/heads/omitted"]
    @world.fault(argv: argv, cwd: @repo.path, phase: :before_effect, effect: :push, skip: true)
    assert @world.call(argv, cwd: @repo.path).success?
    assert_equal 2, git("ls-remote", "--exit-code", "origin", "refs/heads/omitted").exitstatus
  end

  # Unsupported commands/options/cwd/env/input fail outside StandardError; no
  # catch-all success, native fallback, status fabrication or swallowed mismatch.
  def test_unknown_envelopes_fail_closed
    calls = [
      [["git", "dance"], { cwd: @repo.path }], [["git", "status", "--unknown"], { cwd: @repo.path }],
      [["/usr/bin/git", "status"], { cwd: @repo.path }], [["git", "rev-parse", "HEAD"], { cwd: "/" }],
      [["git", "status"], { cwd: @repo.path, env: { "GIT_DIR" => "/tmp" } }],
      [["git", "rev-parse", "HEAD"], { cwd: @repo.path, env: { "GIT_INDEX_FILE" => File.join(@root, "undeclared-index") } }],
      [["git", "rev-parse", "HEAD"], { cwd: @repo.path, input: "unexpected" }],
      [["git", "rev-parse", "HEAD"], { cwd: @repo.path, close_others: true }],
      [["git", "rev-parse", "--unknown"], { cwd: @repo.path }],
      [["git", "diff", "--binary"], { cwd: @repo.path }],
      [["git", "-c", "core.hooksPath=/untrusted", "status"], { cwd: @repo.path }]
    ]
    calls.each do |argv, fields|
      assert_raises(MemoryGit::Mismatch) do
        begin
          @world.call(argv, **fields)
        rescue StandardError
          flunk "test mismatch was swallowed"
        end
      end
    end
    assert_empty output(*STATUS)
  end

  # An accidental native fallback is refused by the execution boundary before a
  # process exists, even if production catches StandardError around the transport.
  def test_full_process_prohibition_catches_native_transport_fallback
    assert_raises(NoGitExecution::ProhibitedExecution) do
      begin
        AgentCodingTool::NativeCommandTransport.new.call(%w[git status], cwd: @repo.path)
      rescue StandardError
        flunk "execution refusal was swallowed"
      end
    end
    assert_equal "DENY", NoGitExecution.audit.last.fetch("decision")
    refute NoGitExecution.audit.any? { |row| row.fetch("decision") == "ALLOW" }
  end

  # Fault matching binds all request fields and omission/consumption, without
  # overconstraining order-independent discovery reads elsewhere in a journey.
  def test_fault_exact_envelope_and_required_consumption
    argv = %w[git rev-parse HEAD]
    response = @world.result("fault\x00\xff".b, "err\x00\xfe".b, 23)
    @world.fault(argv: argv, cwd: @repo.path, phase: :after, env: { "GIT_PAGER" => "cat" }, result: response)
    assert_equal SEED.head + "\n", output("rev-parse", "HEAD")
    assert_raises(MemoryGit::Mismatch) { @world.verify! }
    assert_same response, @world.call(argv, cwd: @repo.path, env: { "GIT_PAGER" => "cat" })
    assert @world.verify!
    assert_equal SEED.head + "\n", output("rev-parse", "HEAD")
    records = @world.requests
    records.clear
    refute_empty @world.requests
    ["first", "second"].each do |bytes|
      @world.fault(argv: argv, cwd: @repo.path, phase: :after, result: @world.result(bytes))
    end
    assert_equal "first", @world.call(argv, cwd: @repo.path).stdout
    assert_raises(MemoryGit::Mismatch) { @world.verify! }
    assert_equal "second", @world.call(argv, cwd: @repo.path).stdout
    assert @world.verify!
  end

  # Uses actual production RepoInspector to parse remote/status/discovery output;
  # dirtiness and missing remote keep their ordinary refusal behavior.
  def test_production_inspector_dirty_and_missing_remote
    config = AgentCodingTool::Config.new({ "repo_root" => @root, "default_remote" => "origin", "default_branch" => "main" }, base_dir: @root)
    inspector = AgentCodingTool::RepoInspector.new(config, transport: @world)
    spec = { "path" => @repo.path }
    assert_equal false, inspector.snapshot("repo", spec).fetch("local_dirty")
    write("untracked", "actual")
    assert_equal true, inspector.snapshot("repo", spec).fetch("local_dirty")
    @remote.available = false
    error = assert_raises(AgentCodingTool::RepositoryError) { inspector.snapshot("repo", spec) }
    assert_includes error.message, "cannot resolve pushed"
  end

  # Creates an actual private inventory and runs unchanged production worktree
  # verification. Writer and reader share objects but have separate HEAD/index.
  def ownership_fixture
    visible, record = File.join(@root, "workers"), File.join(@root, "ownership.json")
    reader = @world.copy(@repo, path: "reader")
    snapshot = [@repo, reader].zip(%w[repo dep]).to_h do |checkout, name|
      [name, { "path" => checkout.path, "remote" => "origin", "remote_url" => @remote.url, "branch" => "main", "pushed_sha" => SEED.head }]
    end
    task = { "repositories" => { "repo" => { "access" => "write" }, "dep" => { "access" => "read_only" } } }
    manager = AgentCodingTool::WorktreeManager.new(root: visible, record_path: record, attempt_paths: true, transport: @world)
    [manager, task, snapshot, visible, record]
  end

  # Exact prepared objects create visible writer/detached reader; ordinary dirty
  # work is retained and cleanup inspects real ignored/untracked files.
  def test_production_worktree_create_inspect_dirty_and_remove
    manager, task, snapshot, _visible, record = ownership_fixture
    write("file.txt", "ordinary work")
    before = physical(@repo)
    inventory = manager.create(task_id: "T", attempt: 1, task: task, snapshot: snapshot)
    assert_equal inventory, manager.inspect!
    assert_equal 0o600, File.stat(record).mode & 0o777
    assert_equal before, physical(@repo)
    writer = inventory.fetch("entries").find { |entry| entry["access"] == "write" }
    reader = inventory.fetch("entries").find { |entry| entry["access"] == "read_only" }
    assert_equal "base\n", File.binread(File.join(writer.fetch("path"), "file.txt"))
    assert_equal "act/T/attempt-1", writer.fetch("branch")
    assert_nil reader.fetch("branch")
    linked = @repo.repository.worktrees.fetch(writer.fetch("path"))
    assert_equal File.join(@repo.admin, "objects") + "\n", output("rev-parse", "--path-format=absolute", "--git-path", "objects", checkout: linked)
    assert_equal File.join(linked.admin, "index") + "\n", output("rev-parse", "--git-path", "index", checkout: linked)
    File.binwrite(File.join(reader.fetch("path"), "foreign"), "keep")
    assert_equal ["worktree contains changes"], manager.cleanup_preflight.find { |row| row["access"] == "read_only" }.fetch("blockers")
    assert_raises(AgentCodingTool::InvalidState) { manager.remove_entry!("dep") }
    File.unlink(File.join(reader.fetch("path"), "foreign"))
    manager.remove_entry!("dep")
    refute File.exist?(reader.fetch("path"))
    assert_equal "removed", manager.inspect!.fetch("entries").find { |entry| entry["name"] == "dep" }.fetch("state")
  end

  # Actual admin backpointer tampering survives rejection, including the unchanged
  # host inventory. Removing the required materialization breaks this journey.
  def test_real_admin_pointer_tampering_and_omitted_worktree_effect
    manager, task, snapshot, _visible, record = ownership_fixture
    entry = manager.create(task_id: "T", attempt: 1, task: task, snapshot: snapshot).fetch("entries").first
    checkout = @repo.repository.worktrees.fetch(entry.fetch("path"))
    pointer = File.join(checkout.admin, "gitdir")
    before = File.binread(record)
    File.binwrite(pointer, "/foreign/.git\n")
    error = assert_raises(AgentCodingTool::InvalidState) { manager.inspect! }
    assert_includes error.message, "backpointer changed"
    assert_equal before, File.binread(record)
    assert_equal "/foreign/.git\n", File.binread(pointer)
    target = File.join(@root, "omitted-worktree")
    argv = ["git", "worktree", "add", "--detach", "--", target, SEED.head]
    @world.fault(argv: argv, cwd: @repo.path, phase: :before_effect, effect: :worktree_add, skip: true)
    assert @world.call(argv, cwd: @repo.path).success?
    refute File.exist?(File.join(target, ".git"))
    refute_includes output("worktree", "list", "--porcelain", "-z"), "worktree #{target}\0"
  end

  # Copied .git pointers, occupied/symlinked targets and branch collisions cannot
  # create ownership; actual filesystem bytes remain present after refusals.
  def test_worktree_collision_copy_and_symlink_traps
    manager, task, snapshot, visible, record = ownership_fixture
    target = File.join(visible, "T", "attempt-1", "repo")
    FileUtils.mkdir_p(target)
    File.binwrite(File.join(target, "keep"), "operator")
    assert_raises(AgentCodingTool::InvalidState) { manager.create(task_id: "T", attempt: 1, task: task, snapshot: snapshot) }
    assert_equal "operator", File.binread(File.join(target, "keep"))
    refute File.exist?(record)
    File.symlink(@repo.path, File.join(@root, "alias"))
    unsafe = AgentCodingTool::WorktreeManager.new(root: File.join(@root, "alias", "workers"), record_path: record, transport: @world)
    assert_raises(AgentCodingTool::InvalidState) { unsafe.create(task_id: "S", attempt: 1, task: task, snapshot: snapshot) }
    output("branch", "act/B/attempt-1")
    error = assert_raises(AgentCodingTool::InvalidState) { manager.create(task_id: "B", attempt: 1, task: task, snapshot: snapshot) }
    assert_includes error.message, "conflicting branch"
    FileUtils.cp_r(@repo.path, File.join(@root, "raw-copy"))
    response = @world.call(%w[git rev-parse --git-dir], cwd: File.join(@root, "raw-copy"))
    refute response.success?
    assert File.directory?(File.join(@root, "raw-copy", ".git"))
  end

  # Local missing storage is distinct from advertised remote authority. Production
  # readiness refuses with fetch instructions, then succeeds after explicit fetch.
  def test_worktree_missing_local_commit_fetch_recovery
    manager, task, snapshot, _visible, _record = ownership_fixture
    source = @world.repository(path: "new-source", template: SEED)
    commit = @world.build_commit(source, files: { "upstream" => "new" }, advance: true)
    @remote.objects.merge!(source.repository.objects)
    @remote.refs["refs/heads/main"] = commit.oid
    snapshot.fetch("repo")["pushed_sha"] = commit.oid
    error = assert_raises(AgentCodingTool::InvalidState) { manager.creation_readiness!(task: task, snapshot: snapshot) }
    assert_includes error.message, "missing required commit"
    output("fetch", "origin", "main")
    assert_equal 2, manager.creation_readiness!(task: task, snapshot: snapshot).length
    @world.configure(@repo, "remote.origin.url", "git@github.com:foreign/repo.git")
    error = assert_raises(AgentCodingTool::InvalidState) { manager.creation_readiness!(task: task, snapshot: snapshot) }
    assert_includes error.message, "remote identity changed"
  end

  # Replaces only external skill source/pin defaults for this standalone verifier.
  # Production renderer, hash/metadata parser and lifecycle checks remain intact.
  def cli_fixture
    skills = @world.repository(path: "skills")
    commit = @world.build_commit(skills, files: { AgentCodingTool::PromptRenderer::SKILL_PATH => CODING,
      AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH => PLANNING }, advance: true)
    renderer = AgentCodingTool::PromptRenderer
    replacements = { SKILL_ROOT: skills.path, SKILL_IDENTITY: { "revision" => commit.oid, "sha256" => Digest::SHA256.hexdigest(CODING) }.freeze,
      PLANNING_SKILL_IDENTITY: { "revision" => commit.oid, "sha256" => Digest::SHA256.hexdigest(PLANNING) }.freeze }
    originals = replacements.to_h { |key, _value| [key, renderer.const_get(key)] }
    replacements.each { |key, value| renderer.send(:remove_const, key); renderer.const_set(key, value) }
    data = File.join(@root, "data")
    FileUtils.mkdir_p(File.join(data, "tasks"))
    File.write(File.join(data, "config.yml"), YAML.dump("repo_root" => @root, "worktree_root" => File.join(@root, "workers")))
    task = { "id" => "T", "title" => "Memory journey", "planning_guidance" => "required", "repositories" => { "repo" => { "path" => @repo.path, "access" => "write" } } }
    File.write(File.join(data, "tasks/T.yml"), YAML.dump(task))
    yield data, skills, commit
  ensure
    originals&.each { |key, value| renderer.send(:remove_const, key); renderer.const_set(key, value) }
  end

  # Invokes the actual public CLI with fresh streams and the one injected boundary.
  def cli(data, *arguments)
    out, err = StringIO.new, StringIO.new
    code = AgentCodingTool::CLI.run(arguments, root: @root, data_root: data, out: out, err: err, transport: @world)
    [code, out.string, err.string]
  end

  # Continuous real CLI journey: prepare/status -> moved remote -> stale refusal ->
  # reprepare/start. Filesystem state independently proves durable refusal/success.
  def test_public_cli_prepare_stale_refusal_reprepare_start
    cli_fixture do |data, _skills, _commit|
      audit_before = NoGitExecution.audit
      assert_equal 0, cli(data, "prepare", "T").first
      state_path = File.join(data, "state/T.yml")
      prepared = File.binread(state_path)
      state = YAML.safe_load(prepared)
      assert_equal SEED.head, state.fetch("snapshot").fetch("repo").fetch("pushed_sha")
      assert_includes File.binread(state.fetch("prompt_path")), CODING
      assert_includes cli(data, "status", "T")[1], "PREPARED"
      upstream = @world.build_commit(@repo, files: { "file.txt" => "upstream" })
      @remote.objects.merge!(@repo.repository.objects)
      @remote.refs["refs/heads/main"] = upstream.oid
      assert_includes cli(data, "status", "T")[1], "STALE"
      assert_equal 2, cli(data, "start", "T").first
      assert_equal prepared, File.binread(state_path)
      assert_equal 0, cli(data, "prepare", "T").first
      assert_equal upstream.oid, YAML.safe_load_file(state_path).fetch("snapshot").fetch("repo").fetch("pushed_sha")
      assert_equal 0, cli(data, "start", "T").first
      refute_nil YAML.safe_load_file(state_path)["started_at"]
      assert_includes cli(data, "status", "T")[1], "IN_FLIGHT"
      assert_equal audit_before, NoGitExecution.audit
    end
  end

  # Exact source bytes are checked offline; working-file copies cannot recover a
  # missing object or mask a corrupt blob. No partial preparation writes survive.
  def test_public_cli_corrupt_missing_pinned_sources_and_missing_remote
    cli_fixture do |data, skills, commit|
      blob = commit.tree.entries.fetch(AgentCodingTool::PromptRenderer::SKILL_PATH).blob
      skills.repository.objects.delete(commit.oid)
      code, _out, error = cli(data, "prepare", "T")
      assert_equal 2, code
      assert_includes error, "pinned source unavailable"
      refute File.exist?(File.join(data, "state/T.yml"))
      skills.repository.store(commit)
      skills.repository.objects.delete(blob.oid)
      code, _out, error = cli(data, "prepare", "T")
      assert_equal 2, code
      assert_includes error, "pinned source unavailable"
      skills.repository.store(blob)
      corrupt = MemoryGit::Commit.new(tree: MemoryGit::Tree.new(AgentCodingTool::PromptRenderer::SKILL_PATH => CODING + "changed",
        AgentCodingTool::PromptRenderer::PLANNING_SKILL_PATH => PLANNING), oid: commit.oid)
      skills.repository.objects.delete(commit.oid)
      skills.repository.store(corrupt)
      code, _out, error = cli(data, "prepare", "T")
      assert_equal 2, code
      assert_includes error, "integrity mismatch"
      assert_equal CODING.b, blob.bytes
      skills.repository.objects.delete(commit.oid)
      skills.repository.store(commit)
      @remote.available = false
      code, _out, error = cli(data, "prepare", "T")
      assert_equal 2, code
      assert_includes error, "cannot resolve pushed"
      refute File.exist?(File.join(data, "state/T.yml"))
    end
  end

  # Planning-required start reads pins again. Missing remote or pinned storage
  # cannot leave a started_at write even after successful preparation.
  def test_public_cli_start_rechecks_pins_and_remote
    cli_fixture do |data, skills, commit|
      assert_equal 0, cli(data, "prepare", "T").first
      path = File.join(data, "state/T.yml")
      before = File.binread(path)
      skills.repository.objects.delete(commit.oid)
      assert_equal 2, cli(data, "start", "T").first
      assert_equal before, File.binread(path)
      skills.repository.store(commit)
      @remote.refs.delete("refs/heads/main")
      assert_equal 2, cli(data, "start", "T").first
      assert_equal before, File.binread(path)
    end
  end
end

required = JSON.parse(File.binread(File.join(__dir__, "required_cases.json")))
actual = MemoryGitVerifier.public_instance_methods.grep(/^test_/).map { |name| "MemoryGitVerifier##{name}" }.sort
raise "memory Git verifier inventory differs" unless actual == required.sort
mapping = JSON.parse(File.binread(File.join(__dir__, "case_map.json"))).fetch("cases")
raise "memory Git case map differs" unless mapping.flat_map { |row| row.fetch("new_cases") }.sort == required.sort
legacy = JSON.parse(File.binread(File.join(__dir__, "../../required_cases.json"))).values.flat_map { |files| files.values.flatten }.uniq
raise "unknown legacy case mapping" unless (mapping.flat_map { |row| row.fetch("prior_cases") } - legacy).empty?
raise "focused verifier refuses test filtering" if ARGV.any? { |argument| argument.match?(/\A(?:-n|-e|--name|--exclude)/) }
ENV["ACT_SUITE_INVOCATION"] = SecureRandom.uuid
ENV["ACT_SUITE_SELECTION"] = required.sort.join("\n")
ENV["ACT_SUITE_EVIDENCE"] = ENV["MEMORY_GIT_EVIDENCE"] || File.join(Dir.mktmpdir("memory-git-results-"), "results.json")
raise "memory Git evidence already exists" if File.exist?(ENV.fetch("ACT_SUITE_EVIDENCE"))
require_relative "../../suite_reporter"

Minitest.after_run do
  audit = ENV["MEMORY_GIT_AUDIT"]
  File.write(audit, JSON.pretty_generate("records" => NoGitExecution.audit, "independent_os_audit" => NoGitExecution.independent_audit) + "\n", mode: "wx") if audit
  evidence = JSON.parse(File.binread(ENV.fetch("ACT_SUITE_EVIDENCE")))
  results = evidence.fetch("results")
  raise "missing/failed/duplicate memory Git case evidence" unless
    results.map { |row| row.fetch("case") }.sort == required.sort && results.all? { |row| row.fetch("status") == "pass" }
end
