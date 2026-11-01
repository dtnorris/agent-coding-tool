# frozen_string_literal: true

# Guard the entire focused invocation, including dependencies and fixture setup.
require_relative "../no_git_execution"
require_relative "../../ordinary_execution"
require "bundler/setup"
require "minitest/autorun"
Minitest::Assertions.diff = nil
require "tmpdir"
require "securerandom"
require "stringio"
require_relative "../../../lib/agent_coding_tool"
require_relative "patch_capabilities"
require_relative "../source_identity"

# Independent golden/tree assertions through real ACT consumers. These additive
# component cases do not migrate or replace the TST-39/40 family inventories.
class MemoryPatchVerifier < Minitest::Test
  BEFORE = { "binary.bin" => "\0old\xff\n".b, "deleted.txt" => "remove\n", "old.txt" => "rename\n", "run" => "echo fixture\n" }.freeze
  AFTER = [["added.txt", "no final newline", 0o644], ["binary.bin", "\0new\xfe\n".b, 0o644],
    ["new.txt", "rename\n", 0o644], ["run", "echo fixture\n", 0o755]].freeze
  PATHS = %w[added.txt binary.bin deleted.txt new.txt old.txt run].freeze
  APPLY_ENV = { "GIT_TERMINAL_PROMPT" => "0", "GIT_PAGER" => "cat" }.freeze

  # Builds fresh mutable stores from independently written constants and registers
  # reviewed patch records. All real files remain inside the owned TMPDIR.
  def setup
    @directory = Dir.mktmpdir("memory-patch-")
    @root = File.realpath(@directory)
    @previous_tmpdir = ENV["TMPDIR"]
    ENV["TMPDIR"] = @root
    @audit_before = NoGitExecution.audit
    @world = MemoryGit::PatchWorld.new(root: @root)
    @patch = @world.register_patch(MemoryGit::PatchCase.load(File.join(__dir__, "fixtures/candidate.json")))
    @repo = @world.repository(path: "repo", template: MemoryGit::Template.files(BEFORE.merge("keep" => "base\n")))
    @remote = @world.remote(url: "git@github.com:example/repo.git", from: @repo)
    @world.connect(@repo, @remote)
    @data = File.join(@root, "data")
    FileUtils.mkdir_p(File.join(@data, "tasks"))
    File.write(File.join(@data, "config.yml"), YAML.dump("repo_root" => @root, "default_remote" => "origin", "default_branch" => "main"))
    File.write(File.join(@data, "tasks/T.yml"), YAML.dump("id" => "T", "title" => "Patch fixture", "repositories" => { "repo" => { "access" => "write" } }))
    @base = { "path" => @repo.path, "remote" => "origin", "remote_url" => @remote.url, "branch" => "main", "pushed_sha" => @repo.head }
    AgentCodingTool::StateStore.new(File.join(@data, "state")).write("T", {
      "id" => "T", "prepared_at" => "2026-10-31T00:00:00Z", "started_at" => "2026-10-31T00:01:00Z", "snapshot" => { "repo" => @base } })
  end

  # Checks required faults and zero process decisions even on failures; real
  # cleanup remains guarded, never shared with the next case.
  def teardown
    @world.verify!
    assert_equal @audit_before, NoGitExecution.audit
  ensure
    ENV["TMPDIR"] = @previous_tmpdir
    FileUtils.remove_entry(@directory)
  end

  # Executes the injected command boundary; raw CommandResult retains byte/status
  # distinctions. Unknown operations raise Mismatch instead of native fallback.
  def git(*arguments, checkout: @repo, **fields)
    @world.call(["git", *arguments], cwd: checkout&.path, **fields)
  end

  # Requires command success and returns its raw output for independent assertions.
  def output(*arguments, **fields)
    response = git(*arguments, **fields)
    assert response.success?, response.stderr
    response.stdout
  end

  # Writes physical bytes only; staging/objects/HEAD remain separate.
  def write(path, bytes, checkout: @repo)
    absolute = File.join(checkout.path, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, bytes)
  end

  # Inventories physical files/modes independently of model scan/materialization.
  # Includes links as links and every untracked/ignored/incidental ordinary file.
  def physical(checkout = @repo)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: checkout.path).sort.filter_map do |path|
      next if path == "." || path == ".git" || path.start_with?(".git/")
      absolute = File.join(checkout.path, path)
      next if File.directory?(absolute) && !File.symlink?(absolute)
      [path.b, File.symlink?(absolute) ? File.readlink(absolute).b : File.binread(absolute), File.lstat(absolute).mode & 0o777]
    end
  end

  # Captures file/directory identity, permissions, mtime and contents including
  # administration. Access time is omitted because reads may update it on disk.
  def filesystem_state
    ([""] + Dir.glob("**/*", File::FNM_DOTMATCH, base: @repo.path)).uniq.sort.map do |path|
      absolute = File.join(@repo.path, path)
      stat = File.lstat(absolute)
      bytes = stat.symlink? ? File.readlink(absolute).b : stat.file? ? File.binread(absolute) : nil
      [path, stat.ftype, stat.dev, stat.ino, stat.mode, stat.mtime.to_r, bytes]
    end
  end

  # Asserts literal postimage bytes/modes independently of the PatchCase trees.
  def assert_postimage(checkout = @repo, extra: [["keep", "base\n", 0o644]])
    assert_equal (AFTER + extra).sort, physical(checkout)
  end

  # Changes files directly from literal constants rather than applying model output.
  def candidate(checkout = @repo)
    File.unlink(File.join(checkout.path, "deleted.txt"))
    File.rename(File.join(checkout.path, "old.txt"), File.join(checkout.path, "new.txt"))
    write("added.txt", "no final newline", checkout: checkout)
    write("binary.bin", "\0new\xfe\n".b, checkout: checkout)
    File.chmod(0o755, File.join(checkout.path, "run"))
  end

  # Calls real public CLI parsing with isolated streams and the sole Git seam.
  def cli(*arguments)
    out, err = StringIO.new, StringIO.new
    code = AgentCodingTool::CLI.run(arguments, root: @root, data_root: @data, out: out, err: err, transport: @world)
    [code, out.string, err.string]
  end

  # Creates an actual strict apply manifest. The terminal grants only explicit
  # answers below; the manifest itself cannot authorize a phase.
  def manifest
    @artifact = File.join(@root, "proposal.patch")
    File.binwrite(@artifact, File.binread(File.join(__dir__, "fixtures/candidate.patch")))
    @manifest = { "schema" => AgentCodingTool::ApplyHandoff::SCHEMA, "target" => "repo",
      "repositories" => { "repo" => { "path" => "repo", "remote_url" => @remote.url, "baseline" => @base.fetch("pushed_sha") } },
      "patch" => { "file" => "proposal.patch", "sha256" => "66e23a33385c596e74a44bfccae44fb917491d3acebab451fba508c9e876c732" },
      "paths" => PATHS, "validation" => [{ "action" => "git_diff_check", "repository" => "repo", "cwd" => ".", "env" => {} }],
      "commit_message" => "Apply reviewed bytes" }
    @manifest_path = File.join(@root, "proposal.json")
    save_manifest
  end

  # Persists exact test-owned proposal edits; real product parsing remains active.
  def save_manifest
    File.write(@manifest_path, JSON.pretty_generate(@manifest))
  end

  # Runs public apply with a deterministic test terminal; no confirmation method
  # or product decision is replaced. Restores global input even on exceptions.
  def apply(answers = "yes\nyes\nyes\n")
    previous = $stdin
    terminal = StringIO.new(answers)
    terminal.define_singleton_method(:tty?) { true }
    $stdin = terminal
    cli("apply", @manifest_path)
  ensure
    $stdin = previous
  end

  # Check/stat/numstat must leave filesystem, index, objects, refs and HEAD exactly
  # unchanged; fixture trees are checked against independent constants first.
  def test_golden_identity_and_check_are_read_only
    assert_equal "66e23a33385c596e74a44bfccae44fb917491d3acebab451fba508c9e876c732", Digest::SHA256.hexdigest(@patch.bytes)
    assert_equal BEFORE, @patch.before.entries.transform_values { |entry| entry.blob.bytes }
    assert_equal AFTER, @patch.after.entries.map { |path, entry| [path, entry.blob.bytes, entry.mode == "100755" ? 0o755 : 0o644] }
    before = [filesystem_state, @repo.index.dup, @repo.repository.objects.dup, @repo.repository.refs.dup]
    assert_equal "1\t0\tadded.txt\0-\t-\tbinary.bin\0".b + "0\t1\tdeleted.txt\0" + "1\t0\tnew.txt\0" + "0\t1\told.txt\0" + "0\t0\trun\0", output("apply", "--numstat", "-z", input: @patch.bytes)
    assert_includes output("apply", "--stat", input: @patch.bytes), "Bin 6 -> 6 bytes"
    2.times { assert_empty output("apply", "--check", "--binary", input: @patch.bytes) }
    assert_equal before, [filesystem_state, @repo.index.dup, @repo.repository.objects.dup, @repo.repository.refs.dup]
  end

  # Application changes physical scope only; subsequent staging/tree/commit reads
  # prove independent bytes, mode, deletion, rename-as-add/delete and no newline.
  def test_apply_stage_tree_commit_and_remote_separation
    original, advertised = @repo.head, @remote.refs.dup
    index = @repo.index.dup
    output("apply", input: @patch.bytes)
    assert_postimage
    assert_equal index, @repo.index
    assert_equal original, @repo.head
    assert_equal "binary.bin\0deleted.txt\0old.txt\0run\0", output("diff", "--name-only", "-z", "HEAD")
    output("add", "-A")
    assert_equal File.binread(File.join(__dir__, "fixtures/candidate.patch")), output("diff", "--cached", "--binary", "--full-index")
    tree = output("write-tree").strip
    assert_equal tree, output("write-tree").strip
    output("commit", "-m", "candidate")
    assert_equal original + "\n", output("rev-parse", "HEAD^")
    assert_equal "\0new\xfe\n".b, output("show", "HEAD:binary.bin")
    assert_equal "100755", output("ls-tree", "HEAD", "--", "run").split.first
    refute git("cat-file", "-e", "HEAD:deleted.txt").success?
    assert_equal advertised, @remote.refs
    refute @remote.objects.key?(@repo.head)
  end

  # Cached and index application require distinct preimages and preserve physical
  # files/unrelated staged work; a worktree conflict cannot silently bless --index.
  def test_cached_and_worktree_preimages_and_unrelated_index
    write("keep", "staged\n")
    output("add", "--", "keep")
    write("binary.bin", "conflict\0".b)
    before = physical
    refute git("apply", "--check", "--index", input: @patch.bytes).success?
    assert_equal before, physical
    output("apply", "--cached", input: @patch.bytes)
    assert_equal before, physical
    assert_equal "\0new\xfe\n".b, output("show", ":binary.bin")
    assert_equal "staged\n", output("show", ":keep")
    assert_equal @base.fetch("pushed_sha"), @repo.head
    refute git("apply", "--cached", "--check", input: @patch.bytes).success?
  end

  # Full scratch index/object state is independent; complete Checkpoint producer
  # forms include incidental removal and forced historical metadata preservation.
  def test_scratch_index_objects_and_inventory
    candidate
    write("ignored", "ignore\0")
    @repo.ignored << "ignored"
    write(".DS_Store", "metadata")
    index, objects = @repo.index.dup, @repo.repository.objects.keys.sort
    scratch = File.join(@root, "objects")
    Dir.mkdir(scratch)
    env = { "GIT_INDEX_FILE" => File.join(@root, "scratch-index"), "GIT_OBJECT_DIRECTORY" => scratch,
      "GIT_ALTERNATE_OBJECT_DIRECTORIES" => File.join(@repo.admin, "objects") }
    output("read-tree", @repo.head, env: env)
    output("add", "-A", env: env)
    inventory = output("diff", "--cached", "--name-status", "-z", "--no-renames", @repo.head, env: env)
    assert_includes inventory, "A\0.DS_Store\0"
    refute_includes inventory, "ignored"
    output("update-index", "--force-remove", "--", ".DS_Store", env: env)
    assert_equal @patch.bytes, output("diff", "--cached", "--binary", "--full-index", @repo.head, env: env)
    tree = output("write-tree", env: env).strip
    refute git("cat-file", "-e", tree).success?
    assert_equal "tree\n", output("cat-file", "-t", tree, env: env)
    assert_equal index, @repo.index
    assert_equal objects, @repo.repository.objects.keys.sort
    assert_empty output("diff", "--cached", "--name-only")
    output("read-tree", @repo.head, env: env)
    assert_empty output("diff", "--cached", "--name-only", env: env)
    output("add", "-f", "--", ".DS_Store", env: env)
    assert_equal "metadata", output("show", ":.DS_Store", env: env)
  end

  # Unknown/partial/foreign scratch envelopes and unregistered binary bytes escape
  # StandardError handlers. No request can silently fall back to host Git.
  def test_unknown_envelopes_and_binary_inputs_fail_loudly
    ["GIT binary patch\nliteral 1\nA???\n", @patch.bytes.sub("literal 6", "literal 7"), @patch.bytes + "changed"].each do |bytes|
      assert_raises(MemoryGit::Mismatch) { git("apply", "--check", input: bytes) }
    end
    [{ "GIT_INDEX_FILE" => File.join(@root, "index") }, { "GIT_OBJECT_DIRECTORY" => @root }, { "GIT_DIR" => @repo.admin }].each do |env|
      assert_raises(MemoryGit::Mismatch) { git("read-tree", "HEAD", env: env) }
    end
    assert_raises(MemoryGit::Mismatch) { git("apply", "--3way", input: @patch.bytes) }
    assert_raises(MemoryGit::Mismatch) { git("diff", "--unknown") }
    assert_raises(MemoryGit::Mismatch) { git("clone", "--mirror", checkout: nil) }
  end

  # Every reviewed descriptor is hash/scope bound. Corrupt hash/path/mode and
  # wrong physical base fail before mutation and restored positives still check.
  def test_corrupt_hash_scope_mode_and_base_refuse
    fields = { bytes: @patch.bytes, sha256: @patch.sha256, before: @patch.before.entries, after: @patch.after.entries,
      paths: @patch.paths, numstat: @patch.numstat, stat: @patch.stat }
    [{ sha256: "0" * 64 }, { paths: ["binary.bin"] }, { paths: ["../escape"] }, { paths: [".GIT/config"] }].each do |change|
      assert_raises(MemoryGit::Mismatch) { MemoryGit::PatchCase.new(**fields.merge(change)) }
    end
    assert_raises(MemoryGit::Mismatch) { MemoryGit::Entry.new("bad", mode: "160000") }
    File.chmod(0o755, File.join(@repo.path, "binary.bin"))
    before = physical
    refute git("apply", "--check", input: @patch.bytes).success?
    assert_equal before, physical
    File.chmod(0o644, File.join(@repo.path, "binary.bin"))
    write("binary.bin", "wrong\0")
    refute git("apply", "--check", input: @patch.bytes).success?
    write("binary.bin", "\0old\xff\n".b)
    output("apply", "--check", input: @patch.bytes)
  end

  # Reviewed quoted rename inventory uses true NUL delimiters and tab-containing
  # paths; raw patches and expected filesystem bytes remain independent fixtures.
  def test_quoted_rename_and_nul_inventory
    record = @world.register_patch(MemoryGit::PatchCase.load(File.join(__dir__, "fixtures/quoted-rename.json")))
    checkout = @world.repository(path: "quoted", template: MemoryGit::Template.files({ "old\tname" => "exact\0\xff".b }))
    assert_equal "0\t0\t\0old\tname\0new\tname\0", output("apply", "--numstat", "-z", checkout: checkout, input: record.bytes)
    output("apply", "--check", checkout: checkout, input: record.bytes)
    output("apply", checkout: checkout, input: record.bytes)
    assert_equal [["new\tname", "exact\0\xff".b, 0o644]], physical(checkout)
    output("add", "-A", checkout: checkout)
    assert_equal "A\0new\tname\0D\0old\tname\0", output("diff", "--cached", "--name-status", "-z", checkout: checkout)
    assert_equal record.bytes, output("diff", "--cached", "--binary", checkout: checkout)
  end

  # Actual symlinks and occupied parents are validated before any earlier patch
  # path is changed. Traversal cannot be registered as a model tree at all.
  def test_symlink_and_traversal_rejection_is_read_only
    external = File.join(@root, "outside")
    File.binwrite(external, "outside\0")
    File.unlink(File.join(@repo.path, "binary.bin"))
    File.symlink(external, File.join(@repo.path, "binary.bin"))
    before = physical
    refute git("apply", "--check", input: @patch.bytes).success?
    assert_equal before, physical
    assert_equal "outside\0", File.binread(external)
    assert_raises(MemoryGit::Mismatch) { MemoryGit::Tree.new("../escape" => "bad") }
    assert_raises(MemoryGit::Mismatch) { MemoryGit::Tree.new("bad\0path" => "bad") }
  end

  # The ordinary codec is proved against separately authored raw bytes, then a
  # dynamic no-final-newline/add/delete/mode round trip uses literal assertions.
  def test_limited_text_codec_and_corruption
    checkout = @world.repository(path: "text", template: MemoryGit::Template.files({ "file.txt" => "base\n" }))
    golden = File.binread(File.join(__dir__, "fixtures/text.patch"))
    assert_equal MemoryGit::PatchCase.load(File.join(__dir__, "fixtures/text.json")).after.entries.fetch("file.txt").blob.bytes, "new\n"
    write("file.txt", "new\n", checkout: checkout)
    assert_equal golden, output("diff", checkout: checkout)
    write("file.txt", "base\n", checkout: checkout)
    output("apply", "--check", checkout: checkout, input: golden)
    assert_equal "1\t1\tfile.txt\0", output("apply", "--numstat", "-z", checkout: checkout, input: golden)
    assert_equal " file.txt | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\n", output("apply", "--stat", checkout: checkout, input: golden)
    assert_raises(MemoryGit::Mismatch) { git("apply", "--check", checkout: checkout, input: golden.sub("df967b9", "0000000")) }
    output("apply", checkout: checkout, input: golden)
    assert_equal [["file.txt", "new\n", 0o644]], physical(checkout)
    write("file.txt", "no newline", checkout: checkout)
    File.chmod(0o755, File.join(checkout.path, "file.txt"))
    patch = output("diff", "--full-index", checkout: checkout)
    write("file.txt", "base\n", checkout: checkout)
    File.chmod(0o644, File.join(checkout.path, "file.txt"))
    output("apply", checkout: checkout, input: patch)
    assert_equal [["file.txt", "no newline", 0o755]], physical(checkout)
    write("new", "dynamic", checkout: checkout)
    output("add", "-N", "--", "new", checkout: checkout)
    assert_equal "A\0new\0M\0file.txt\0".split("\0").sort, output("diff", "--name-status", "-z", checkout: checkout).split("\0").sort
    output("reset", "-q", "--", "new", checkout: checkout)
    assert_equal "dynamic", File.binread(File.join(checkout.path, "new"))
    assert_empty output("ls-files", "--", "new", checkout: checkout)
    dynamic = "diff --git a/task.yml b/task.yml\nnew file mode 100644\n--- /dev/null\n+++ b/task.yml\n@@ -0,0 +1 @@\n+id: NEW\n"
    output("apply", "--check", checkout: checkout, input: dynamic)
    output("apply", checkout: checkout, input: dynamic)
    assert_equal "id: NEW\n", File.binread(File.join(checkout.path, "task.yml"))
  end

  # Full staging replaces intent even for empty files. Every supported add form
  # must agree with independent staged/worktree inventories and leave other
  # placeholders pending; no fixture output supplies the expected observations.
  def test_full_staging_replaces_empty_intent_entries
    [["--", "empty"], ["-f", "--", "empty"], ["-A"], ["-A", "--", "."]].each_with_index do |arguments, number|
      checkout = @world.repository(path: "intent-add-#{number}", template: MemoryGit::Template.files({ "keep" => "base\n" }))
      write("empty", "", checkout: checkout)
      output("add", "-N", "--", "empty", checkout: checkout)
      assert_empty output("diff", "--cached", "--name-only", "-z", checkout: checkout)
      assert_equal "A\0empty\0", output("diff", "--name-status", "-z", checkout: checkout)
      output("add", *arguments, checkout: checkout)
      assert_equal "A\0empty\0", output("diff", "--cached", "--name-status", "-z", checkout: checkout)
      assert_empty output("diff", "--name-only", "-z", checkout: checkout)
      assert_equal "", output("show", ":empty", checkout: checkout)
      assert_equal [["empty", "", 0o644], ["keep", "base\n", 0o644]], physical(checkout)
    end
    write("selected", "")
    write("pending", "")
    output("add", "-N", "--", "selected", "pending")
    output("add", "--", "selected")
    assert_equal "A\0selected\0", output("diff", "--cached", "--name-status", "-z")
    assert_equal "A\0pending\0", output("diff", "--name-status", "-z")
  end

  # Index removal/replacement cannot revive a previous intent marker when the
  # path is staged again. Read-tree also replaces intent with an empty blob of
  # equal value, which must remain a real staged addition.
  def test_index_replacement_does_not_revive_intent
    [["reset", "-q", "--", "empty"], ["update-index", "--force-remove", "--", "empty"], ["read-tree", "HEAD"]].each_with_index do |arguments, number|
      checkout = @world.repository(path: "intent-reset-#{number}", template: MemoryGit::Template.files({ "keep" => "base\n" }))
      write("empty", "", checkout: checkout)
      output("add", "-N", "--", "empty", checkout: checkout)
      output(*arguments, checkout: checkout)
      assert_empty output("ls-files", "--", "empty", checkout: checkout)
      output("add", "--", "empty", checkout: checkout)
      assert_equal "A\0empty\0", output("diff", "--cached", "--name-status", "-z", checkout: checkout)
    end
    write("empty", "")
    output("add", "-N", "--", "empty")
    replacement = @world.build_commit(@repo, files: BEFORE.merge("keep" => "base\n", "empty" => ""))
    output("read-tree", replacement.oid)
    assert_equal "A\0empty\0", output("diff", "--cached", "--name-status", "-z")
    assert_empty output("diff", "--name-only", "-z")
  end

  # Required omitted-effect controls retain intent until an actual mutation
  # occurs. Clearing markers merely because a command was requested would make
  # these staged/worktree assertions fail, including an omitted reset/read-tree.
  def test_omitted_index_effects_preserve_intent
    [[%w[add -- empty], :stage], [%w[reset -q -- empty], :reset_index],
      [%w[update-index --force-remove -- empty], :update_index], [%w[read-tree HEAD], :read_tree]].each_with_index do |(arguments, effect), number|
      checkout = @world.repository(path: "intent-fault-#{number}", template: MemoryGit::Template.files({ "keep" => "base\n" }))
      write("empty", "", checkout: checkout)
      output("add", "-N", "--", "empty", checkout: checkout)
      @world.fault(argv: ["git", *arguments], cwd: checkout.path, phase: :before_effect, effect: effect, skip: true)
      output(*arguments, checkout: checkout)
      assert_empty output("diff", "--cached", "--name-only", "-z", checkout: checkout)
      assert_equal "A\0empty\0", output("diff", "--name-status", "-z", checkout: checkout)
      output("add", "--", "empty", checkout: checkout)
      assert_equal "A\0empty\0", output("diff", "--cached", "--name-status", "-z", checkout: checkout)
      assert_empty output("diff", "--name-only", "-z", checkout: checkout)
    end
  end

  # Equal-valued ordinary and scratch indexes keep independent intent metadata.
  # Staging in one context cannot change staged/worktree observations in another.
  def test_scratch_index_intent_is_independent
    write("empty", "")
    output("add", "-N", "--", "empty")
    objects = File.join(@root, "intent-objects")
    Dir.mkdir(objects)
    env = { "GIT_INDEX_FILE" => File.join(@root, "intent-index"), "GIT_OBJECT_DIRECTORY" => objects,
      "GIT_ALTERNATE_OBJECT_DIRECTORIES" => File.join(@repo.admin, "objects") }
    output("read-tree", "HEAD", env: env)
    output("add", "-N", "--", "empty", env: env)
    output("add", "--", "empty", env: env)
    assert_equal "A\0empty\0", output("diff", "--cached", "--name-status", "-z", env: env)
    assert_empty output("diff", "--cached", "--name-only", "-z")
    assert_equal "A\0empty\0", output("diff", "--name-status", "-z")
    output("add", "--", "empty")
    assert_equal "A\0empty\0", output("diff", "--cached", "--name-status", "-z")
    assert_empty output("diff", "--name-only", "-z", env: env)
  end

  # Whole public journey preserves actual durable evidence, binary bytes/modes,
  # ignored/untracked distinctions and independently reconstructed postimages.
  def test_public_checkpoint_export_record_verify_recover
    candidate
    write("ignored", "retained")
    write(".DS_Store", "metadata")
    @repo.ignored << "ignored"
    artifact = File.join(@root, "export.patch")
    code, out, err = cli("checkpoint", "export", "T", "--workspace", @repo.path, "--base", @repo.head, "--artifact", artifact)
    assert_equal 0, code, err
    assert_equal "canonical_format_checked", JSON.parse(out).fetch("status")
    assert_equal File.binread(File.join(__dir__, "fixtures/candidate.patch")), File.binread(artifact)
    code, out, err = cli("checkpoint", "record", "T", "--workspace", @repo.path, "--artifact", artifact)
    assert_equal 0, code, err
    record = JSON.parse(out)
    assert_equal PATHS, record.fetch("changed_files").map { |row| row.fetch("path") }
    assert_equal 0o600, File.stat(record.fetch("path")).mode & 0o777
    assert_equal 0, cli("checkpoint", "verify", "T", "--workspace", @repo.path).first
    destination = File.join(@root, "recovered")
    code, out, err = cli("checkpoint", "recover", "T", "--destination", destination, "--confirm-disconnected")
    assert_equal 0, code, err
    assert_equal "reconstructed", JSON.parse(out).fetch("status")
    recovered = @world.instance_variable_get(:@checkouts).fetch(destination)
    assert_postimage(recovered)
    assert_equal "retained", File.binread(File.join(@repo.path, "ignored"))
    assert_equal "metadata", File.binread(File.join(@repo.path, ".DS_Store"))
    assert_empty output("diff", "--cached", "--name-only")
  end

  # Real Checkpoint rejects changed artifact/hash/source identity and stale source,
  # retains prior evidence, and succeeds again after restoring exact original bytes.
  def test_checkpoint_corruption_and_remote_change_are_rejected
    candidate
    checkpoint = AgentCodingTool::Checkpoint.new(data_root: @data, transport: @world)
    record = checkpoint.record("T", workspace: @repo.path)
    path, bytes = record.fetch("path"), File.binread(record.fetch("path"))
    File.binwrite(path, bytes + "corrupt")
    error = assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T") }
    assert_includes error.message, "checksum/length mismatch"
    File.binwrite(path, bytes)
    @world.configure(@repo, "remote.origin.url", "git@github.com:other/repo.git")
    error = assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T", workspace: @repo.path) }
    assert_includes error.message, "remote differs"
    @world.configure(@repo, "remote.origin.url", @remote.url)
    assert_equal "verified", checkpoint.verify("T", workspace: @repo.path).fetch("status")
    write("extra", "untracked")
    error = assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T", workspace: @repo.path) }
    assert_includes error.message, "stale implementation"
    File.unlink(File.join(@repo.path, "extra"))
    assert_equal "verified", checkpoint.verify("T", workspace: @repo.path).fetch("status")
  end

  # Omitting reconstruction application breaks the real export comparison. The
  # artifact survives diagnosis; restoring the effect yields the identical golden.
  def test_omitted_reconstruction_handoff_fails_product_verification
    candidate
    checkpoint = AgentCodingTool::Checkpoint.new(data_root: @data, transport: @world)
    # The exact clean path is chosen by production, so schedule at the clone
    # handoff after observing that exact source/destination command envelope.
    transport = @world
    omitted = false
    adapter = Object.new
    adapter.define_singleton_method(:call) do |argv, **fields|
      if argv.first(3) == %w[git apply --binary] && !omitted
        transport.fault(argv: argv, **fields, phase: :before_effect, effect: :apply, skip: true)
        omitted = true
      end
      transport.call(argv, **fields)
    end
    broken = AgentCodingTool::Checkpoint.new(data_root: @data, transport: adapter)
    artifact = File.join(@root, "broken.patch")
    error = assert_raises(AgentCodingTool::InvalidState) { broken.export("T", workspace: @repo.path, base_sha: @repo.head, artifact: artifact) }
    assert_includes error.message, "incomplete or inapplicable"
    assert omitted
    assert_equal @patch.bytes, File.binread(artifact)
    assert_equal "canonical_format_checked", checkpoint.export("T", workspace: @repo.path, base_sha: @repo.head, artifact: File.join(@root, "restored.patch")).fetch("status")
  end

  # Wrong binary effects have their own independent reviewed observation, letting
  # real Checkpoint compare unequal bytes rather than treating model refusal as
  # product verification. Restoring the transport effect passes the same journey.
  def test_corrupt_reconstruction_bytes_fail_product_comparison
    wrong = @world.register_patch(MemoryGit::PatchCase.load(File.join(__dir__, "fixtures/corrupt-postimage.json")))
    assert_equal "\0BAD\xfe\n".b, wrong.after.entries.fetch("binary.bin").blob.bytes
    refute_equal @patch.bytes, wrong.bytes
    candidate
    transport = @world
    corrupted = false
    adapter = Object.new
    adapter.define_singleton_method(:call) do |argv, **fields|
      if argv.first(3) == %w[git apply --binary] && !corrupted
        transport.fault(argv: argv, **fields, phase: :after_effect, effect: :apply) do
          File.binwrite(File.join(fields.fetch(:cwd), "binary.bin"), "\0BAD\xfe\n".b)
        end
        corrupted = true
      end
      transport.call(argv, **fields)
    end
    broken = AgentCodingTool::Checkpoint.new(data_root: @data, transport: adapter)
    error = assert_raises(AgentCodingTool::InvalidState) do
      broken.export("T", workspace: @repo.path, base_sha: @repo.head, artifact: File.join(@root, "wrong.patch"))
    end
    assert_includes error.message, "incomplete or inapplicable"
    assert corrupted
    assert_equal @patch.bytes, File.binread(File.join(@root, "wrong.patch"))
    checkpoint = AgentCodingTool::Checkpoint.new(data_root: @data, transport: @world)
    assert_equal "canonical_format_checked", checkpoint.export("T", workspace: @repo.path, base_sha: @repo.head, artifact: File.join(@root, "right.patch")).fetch("status")
  end

  # CLI apply honors independent phase consent and retains unrelated partially
  # staged bytes/index, ignored/untracked files and incidental metadata.
  def test_public_binary_apply_preserves_unrelated_index_and_files
    write("keep", "staged\n")
    output("add", "--", "keep")
    write("keep", "worktree\n")
    write("untracked", "keep\0")
    write("ignored", "ignored\0")
    write(".DS_Store", "finder")
    @repo.ignored << "ignored"
    index = output("ls-files", "--stage", "--", "keep")
    manifest
    code, out, err = apply
    assert_equal 0, code, err
    assert_includes out, "committed locally"
    assert_equal index, output("ls-files", "--stage", "--", "keep")
    assert_equal "staged\n", output("show", ":keep")
    assert_equal @base.fetch("pushed_sha") + "\n", output("rev-parse", "HEAD^")
    assert_postimage(extra: [["keep", "worktree\n", 0o644], ["ignored", "ignored\0", 0o644], ["untracked", "keep\0", 0o644], [".DS_Store", "finder", 0o644]])
    assert_equal @base.fetch("pushed_sha"), @remote.refs.fetch("refs/heads/main")
  end

  # Product refusal catches changed hash/path/mode plus pre-existing staged and
  # unstaged conflicts without changing files. Declined consent is also read-only.
  def test_public_apply_corruption_conflicts_and_consent
    manifest
    before = physical
    assert_equal 0, apply("no\n").first
    assert_equal before, physical
    File.binwrite(@artifact, @patch.bytes + "changed")
    code, _out, err = apply
    assert_equal 2, code
    assert_includes err, "SHA-256 mismatch"
    File.binwrite(@artifact, @patch.bytes)
    invalid_mode = @patch.bytes.sub("new mode 100755", "new mode 120000")
    File.binwrite(@artifact, invalid_mode)
    @manifest["patch"]["sha256"] = Digest::SHA256.hexdigest(invalid_mode)
    save_manifest
    assert_includes apply[2], "only ordinary file patches"
    File.binwrite(@artifact, @patch.bytes)
    @manifest["patch"]["sha256"] = @patch.sha256
    @manifest["paths"] = ["binary.bin"]
    save_manifest
    assert_includes apply[2], "paths differ"
    @manifest["paths"] = PATHS
    save_manifest
    write("run", "changed\n")
    assert_includes apply[2], "pre-existing unstaged"
    output("add", "--", "run")
    assert_includes apply[2], "pre-existing staged"
    write("run", "echo fixture\n")
    output("add", "--", "run")
    assert_equal 0, apply("yes\nno\n").first
    assert_postimage
    assert_equal @base.fetch("pushed_sha"), @repo.head
  end

  # Missing/partial effects and extra mutations cannot pass product application
  # verification. Failures retain actual partial files and never commit/publish.
  def test_partial_and_unrelated_effects_are_rejected_by_apply
    manifest
    @world.fault(argv: %w[git apply], cwd: @repo.path, env: APPLY_ENV, input: @patch.bytes, options: { pgroup: true },
      phase: :before_effect, effect: "patch:run", skip: true)
    code, _out, err = apply
    assert_equal 2, code
    assert_includes err, "changed paths differ"
    assert_equal "\0new\xfe\n".b, File.binread(File.join(@repo.path, "binary.bin"))
    assert_equal 0o644, File.stat(File.join(@repo.path, "run")).mode & 0o777
    assert_equal @base.fetch("pushed_sha"), @repo.head
    # A second independent checkout restores the positive preimage.
    @repo = @world.repository(path: "restored", template: MemoryGit::Template.files(BEFORE.merge("keep" => "base\n")))
    @world.connect(@repo, @remote)
    @manifest["repositories"]["repo"]["path"] = "restored"
    save_manifest
    @world.fault(argv: %w[git apply], cwd: @repo.path, env: APPLY_ENV, input: @patch.bytes, options: { pgroup: true }, phase: :after) { write("keep", "extra mutation") }
    code, _out, err = apply
    assert_equal 2, code
    assert_includes err, "outside proposal"
    assert_equal "extra mutation", File.binread(File.join(@repo.path, "keep"))
    assert_equal @base.fetch("pushed_sha"), @repo.head
  end

  # Deliberate check-time writes prove the production snapshot/consent handoff
  # rejects a mutating --check before application or staging can begin.
  def test_mutating_check_is_rejected_before_application
    manifest
    @world.fault(argv: %w[git apply --check], cwd: @repo.path, env: APPLY_ENV, input: @patch.bytes,
      options: { pgroup: true }, phase: :after) { write("keep", "check mutation") }
    code, _out, err = apply
    assert_equal 2, code
    assert_includes err, "repository changed since review"
    assert_equal BEFORE.fetch("binary.bin"), File.binread(File.join(@repo.path, "binary.bin"))
    assert_equal @base.fetch("pushed_sha"), @repo.head
    assert_empty output("diff", "--cached", "--name-only")
    write("keep", "base\n")
    assert_equal 0, apply.first
    assert_postimage
  end

  # Explicit partial command failure preserves effects already made and returns
  # genuine modeled failure to product code; no later path is silently applied.
  def test_partial_failure_preserves_diagnosable_effects
    manifest
    @world.fault(argv: %w[git apply], cwd: @repo.path, env: APPLY_ENV, input: @patch.bytes, options: { pgroup: true },
      phase: :after_effect, effect: "patch:binary.bin") { raise MemoryGit::Refusal.new("partial application failure", 1) }
    code, _out, err = apply
    assert_equal 2, code
    assert_includes err, "partial application failure"
    assert_equal "no final newline", File.binread(File.join(@repo.path, "added.txt"))
    assert_equal "\0new\xfe\n".b, File.binread(File.join(@repo.path, "binary.bin"))
    assert_equal "remove\n", File.binread(File.join(@repo.path, "deleted.txt"))
    assert_equal 0o644, File.stat(File.join(@repo.path, "run")).mode & 0o777
    assert_equal @base.fetch("pushed_sha"), @repo.head
    assert_equal BEFORE.fetch("binary.bin"), output("show", ":binary.bin")
  end

  # A known commit hook effect changes real file bytes. Apply's post-commit checks
  # reject it; a clean fresh checkout proves that restoring the effect succeeds.
  def test_commit_hook_mutation_and_omitted_stage_are_rejected
    manifest
    argv = ["git", "commit", "--only", "-m", "Apply reviewed bytes", "--", *PATHS]
    @world.fault(argv: argv, cwd: @repo.path, env: APPLY_ENV, options: { pgroup: true }, phase: :after_effect, effect: :commit) { write("keep", "hook mutation") }
    code, _out, err = apply
    assert_equal 2, code
    assert_includes err, "source changed during commit"
    assert_equal "hook mutation", File.binread(File.join(@repo.path, "keep"))
    @repo = @world.repository(path: "clean", template: MemoryGit::Template.files(BEFORE.merge("keep" => "base\n")))
    @world.connect(@repo, @remote)
    @manifest["repositories"]["repo"]["path"] = "clean"
    save_manifest
    @world.fault(argv: ["git", "add", "--", *PATHS], cwd: @repo.path, env: APPLY_ENV, options: { pgroup: true }, phase: :before_effect, effect: :stage, skip: true)
    assert_includes apply[2], "staged paths differ"
    @repo = @world.repository(path: "positive", template: MemoryGit::Template.files(BEFORE.merge("keep" => "base\n")))
    @world.connect(@repo, @remote)
    @manifest["repositories"]["repo"]["path"] = "positive"
    save_manifest
    assert_equal 0, apply.first
    assert_postimage
  end

  # Real delivery verification inspects independently specified bytes/modes/paths,
  # parent and clean state. Candidate objects do not advertise or push themselves.
  def test_delivery_candidate_hash_mode_scope_and_ancestry_checks
    candidate
    manager = AgentCodingTool::DeliveryManager.new(data_root: @data, coordinator: nil, transport: @world)
    paths, inventory = manager.send(:snapshot!, @repo.path, @repo.head, { "allowed_paths" => ["*"] })
    details = { "task_id" => "T", "paths" => paths, "manifest" => inventory, "base_sha" => @repo.head }
    commit = manager.send(:commit_validated!, @repo.path, details)
    assert manager.send(:verify_commit!, @repo.path, commit, details)
    assert_equal @base.fetch("pushed_sha"), @remote.refs.fetch("refs/heads/main")
    refute @remote.objects.key?(commit)
    original = inventory.fetch("binary.bin").dup
    inventory["binary.bin"]["sha256"] = "0" * 64
    assert_includes assert_raises(AgentCodingTool::InvalidState) { manager.send(:verify_commit!, @repo.path, commit, details) }.message, "bytes differ"
    inventory["binary.bin"] = original
    inventory["run"]["mode"] = 0
    assert_includes assert_raises(AgentCodingTool::InvalidState) { manager.send(:verify_commit!, @repo.path, commit, details) }.message, "mode differs"
    inventory["run"]["mode"] = 0o111
    details["paths"] = ["binary.bin"]
    assert_includes assert_raises(AgentCodingTool::InvalidState) { manager.send(:verify_commit!, @repo.path, commit, details) }.message, "paths differ"
    details["paths"] = paths
    details["base_sha"] = "f" * 40
    assert_includes assert_raises(AgentCodingTool::InvalidState) { manager.send(:verify_commit!, @repo.path, commit, details) }.message, "commit changed"
    details["base_sha"] = @base.fetch("pushed_sha")
    assert manager.send(:verify_commit!, @repo.path, commit, details)
    assert_postimage
  end
end

required = JSON.parse(File.binread(File.join(__dir__, "patch_required_cases.json")))
actual = MemoryPatchVerifier.public_instance_methods.grep(/^test_/).map { |name| "MemoryPatchVerifier##{name}" }.sort
raise "patch verifier inventory differs" unless actual == required.sort
mapping = JSON.parse(File.binread(File.join(__dir__, "patch_case_map.json"))).fetch("cases")
raise "patch case map differs" unless mapping.flat_map { |row| row.fetch("new_cases") }.sort == required.sort
legacy = JSON.parse(File.binread(File.join(__dir__, "../../required_cases.json"))).values.flat_map { |files| files.values.flatten }.uniq
raise "unknown legacy case mapping" unless (mapping.flat_map { |row| row.fetch("prior_cases") } - legacy).empty?
raise "patch verifier refuses filtering" if ARGV.any? { |argument| argument.match?(/\A(?:-n|-e|--name|--exclude)/) }
ENV["ACT_SUITE_INVOCATION"] = SecureRandom.uuid
ENV["ACT_SUITE_SELECTION"] = required.sort.join("\n")
ENV["ACT_SUITE_EVIDENCE"] = ENV["MEMORY_PATCH_EVIDENCE"] || File.join(Dir.mktmpdir("patch-results-"), "results.json")
raise "patch evidence already exists" if File.exist?(ENV.fetch("ACT_SUITE_EVIDENCE"))
source_root = File.expand_path("../../..", __dir__)
source_paths = (Dir.glob("test/support/memory_git/**/*", base: source_root) +
  Dir.glob("lib/**/*.rb", base: source_root) + %w[bin/agent-coding-tool test/support/memory_git.rb
    test/support/no_git_execution.rb test/ordinary_execution.rb test/suite_reporter.rb Gemfile.lock])
  .select { |path| File.file?(File.join(source_root, path)) }.sort
source = SourceIdentity.capture(root: source_root, paths: source_paths)
require_relative "../../suite_reporter"

Minitest.after_run do
  raise "patch source changed during focused run" unless SourceIdentity.capture(root: source_root, paths: source_paths) == source
  source_path = ENV["MEMORY_PATCH_SOURCE"]
  File.write(source_path, JSON.pretty_generate(source) + "\n", mode: "wx") if source_path
  audit = ENV["MEMORY_PATCH_AUDIT"]
  File.write(audit, JSON.pretty_generate("records" => NoGitExecution.audit, "independent_os_audit" => NoGitExecution.independent_audit) + "\n", mode: "wx") if audit
  results = JSON.parse(File.binread(ENV.fetch("ACT_SUITE_EVIDENCE")))["results"]
  raise "missing/failed/duplicate patch case evidence" unless results.map { |row| row.fetch("case") }.sort == required.sort && results.all? { |row| row.fetch("status") == "pass" }
end
