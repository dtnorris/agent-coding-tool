# frozen_string_literal: true

# Capture originals before preload to test bypass attempts. No process is
# invoked during bootstrap; the boundary precedes Minitest and product loading.
ORIGINAL_ZERO_GIT_SPAWN = Process.method(:spawn)
ORIGINAL_ZERO_GIT_READ = IO.method(:read)
ORIGINAL_ZERO_GIT_POPEN = IO.method(:popen)
ORIGINAL_ZERO_GIT_FOREACH = IO.method(:foreach)
ORIGINAL_ZERO_GIT_OPEN = Kernel.instance_method(:open)
require_relative "no_git_execution"
require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "open3"
require "securerandom"
require_relative "source_identity"
require_relative "../../lib/agent_coding_tool"

# Focused boundary verifier; never loads the legacy Git-bearing test_helper.
class NoGitExecutionVerifier < Minitest::Test
  CHILD = File.join(__dir__, "fixtures/guard_child.rb")
  CHILD_SHA = Digest::SHA256.file(CHILD).hexdigest

  # Builds one finite fixture permit with exact arguments; errors propagate.
  def permit(mode, preloads: {}, **options)
    bundler = File.realpath($LOADED_FEATURES.find { |path| path.end_with?("/bundler/setup.rb") })
    NoGitExecution::Permit.new(script: CHILD, sha256: CHILD_SHA, arguments: [mode],
      preloads: { bundler => Digest::SHA256.file(bundler).hexdigest }.merge(preloads), **options)
  end

  # Runs the real Open3 transport under one permit and returns original values.
  def capture(approval, **options)
    NoGitExecution.with_permit(approval) do
      Open3.capture3(approval.environment, *approval.argv, **approval.options, **options)
    end
  end

  # Yields a fresh synthetic production coverage context and reviewed preload.
  # Restores ambient context and optionally retains raw fixture/child evidence;
  # filesystem and coverage errors propagate without starting a parent observer.
  def coverage_context
    original = ENV["ACT_COVERAGE_CONTEXT"]
    require_relative "../feedback_coverage"
    Dir.mktmpdir("zero-git-coverage-") do |root|
      FileUtils.mkdir_p([File.join(root, "lib"), File.join(root, "bin"), File.join(root, "evidence")])
      File.write(File.join(root, "lib/coverage_probe.rb"), "if ENV['ACT_COVERAGE_CONTEXT']\n  :covered\nelse\n  raise 'missing coverage context'\nend\n")
      File.write(File.join(root, "bin/agent-coding-tool"), "raise 'compile only'\n")
      context = { "root" => root, "directory" => File.join(root, "evidence"),
        "invocation" => SecureRandom.uuid, "selection" => name, "stage" => "guard-child",
        "sources" => FeedbackCoverage.sources(root), "layout" => FeedbackCoverage.layout(root) }
      path = File.join(root, "context.json")
      File.write(path, JSON.generate(context))
      ENV["ACT_COVERAGE_CONTEXT"] = path
      begin
        yield path, context, { NoGitExecution::COVERAGE => Digest::SHA256.file(NoGitExecution::COVERAGE).hexdigest }
      ensure
        destination = ENV["ZERO_GIT_COVERAGE_EVIDENCE"]
        if destination
          FileUtils.mkdir_p(destination)
          FileUtils.cp_r(root, destination)
        end
      end
    end
  ensure
    ENV["ACT_COVERAGE_CONTEXT"] = original
  end

  # Explicit deletion cannot hide the inherited coverage obligation, even when
  # the preload is supplied. Refusal must precede every native spawn entry.
  def test_coverage_context_cannot_be_deleted_or_replaced
    coverage_context do |path, _context, preloads|
      before = NoGitExecution.audit.count { |row| row["decision"] == "ALLOW" }
      [{}, preloads].each do |reviewed|
        [nil, "#{path}.replacement"].each do |replacement|
          assert_raises(NoGitExecution::ProhibitedExecution) do
            permit("coverage", preloads: reviewed, environment: { "ACT_COVERAGE_CONTEXT" => replacement })
          end
        end
      end
      assert_equal before, NoGitExecution.audit.count { |row| row["decision"] == "ALLOW" }
    end
  end

  # A cleared child environment needs explicit context forwarding as well as
  # the preload; checking the inherited parent environment alone is insufficient.
  def test_unsetenv_others_cannot_omit_coverage_context
    coverage_context do |_path, _context, preloads|
      before = NoGitExecution.audit.count { |row| row["decision"] == "ALLOW" }
      assert_raises(NoGitExecution::ProhibitedExecution) do
        permit("coverage", preloads: preloads, options: { unsetenv_others: true })
      end
      assert_equal before, NoGitExecution.audit.count { |row| row["decision"] == "ALLOW" }
    end
  end

  # Both inherited and explicitly forwarded contexts start real child coverage.
  # Reaped status, child PID, fresh start/active/result files and executed line
  # and branch nodes prove instrumentation, including the unloaded denominator.
  def test_approved_child_starts_coverage_and_writes_evidence
    [false, true].each do |cleared|
      coverage_context do |path, context, preloads|
        environment = cleared ? { "ACT_COVERAGE_CONTEXT" => path } : {}
        assert_raises(NoGitExecution::ProhibitedExecution) do
          permit("coverage", environment: environment, options: { unsetenv_others: cleared })
        end
        approval = permit("coverage", preloads: preloads, environment: environment,
          options: { unsetenv_others: cleared })
        output, error, status = capture(approval)
        File.write(File.join(context.fetch("root"), "transport.json"), JSON.generate(
          "stdout" => output, "stderr" => error, "pid" => status.pid, "exitstatus" => status.exitstatus))
        assert_instance_of Process::Status, status
        assert status.success?, error
        assert_empty error
        child = JSON.parse(output)
        assert_equal path, child.fetch("context")
        assert_equal true, child.fetch("running")
        assert_equal status.pid, child.fetch("pid")
        assert_equal true, child.fetch("guard_loaded")
        assert_equal true, child.fetch("coverage_loaded")
        %w[started active json].each do |extension|
          assert_equal 1, Dir.glob(File.join(context.fetch("directory"), "*.#{extension}")).length
        end
        record = JSON.parse(File.binread(Dir.glob(File.join(context.fetch("directory"), "*.json")).fetch(0)))
        assert_equal status.pid, record.fetch("pid")
        files = FeedbackCoverage.collect(context)
        assert files.fetch("lib/coverage_probe.rb").any? { |node, hits| node.start_with?("line:") && hits.positive? }
        assert files.fetch("lib/coverage_probe.rb").any? { |node, hits| node.start_with?("branch:") && hits.positive? }
        assert files.fetch("bin/agent-coding-tool").values.all?(&:zero?)
      end
    end
  end

  # Every native route, including wrappers/absolute paths/cached originals, must
  # refuse before executing even a harmless marker command or installed Git.
  def test_malicious_process_and_pipe_routes
    Dir.mktmpdir("zero-git-") do |root|
      marker = File.join(root, "executed")
      ruby = [RbConfig.ruby, "-e", "File.write(ARGV.fetch(0), 'escaped')", marker]
      shell = Shellwords.join(ruby)
      attacks = [
        -> { Process.spawn("git", "--version") }, -> { Process.spawn("/usr/bin/git", "--version") },
        -> { Open3.capture3("git", "--version") }, -> { spawn(*ruby) },
        -> { system(*ruby) }, -> { Kernel.system(*ruby) }, -> { Process.exec(*ruby) },
        -> { exec(*ruby) }, -> { `#{shell}` }, -> { IO.popen(ruby) },
        -> { Kernel.open("|#{shell}") }, -> { open("|#{shell}") },
        -> { IO.read("|#{shell}") }, -> { IO.binread("|#{shell}") },
        -> { IO.readlines("|#{shell}") }, -> { IO.foreach("|#{shell}").to_a },
        -> { IO.write("|#{shell}", "bytes") }, -> { IO.binwrite("|#{shell}", "bytes") },
        -> { Process.spawn("/bin/sh", "-c", "git --version") },
        -> { Process.spawn("/usr/bin/env", "git", "--version") },
        -> { Process.spawn({ "PATH" => root }, "git", "--version") },
        -> { ORIGINAL_ZERO_GIT_SPAWN.call(*ruby) },
        -> { ORIGINAL_ZERO_GIT_READ.call("|#{shell}") },
        -> { ORIGINAL_ZERO_GIT_POPEN.call(ruby) }, -> { fork { File.write(marker, "escaped") } }
      ]
      attacks.each do |attack|
        assert_raises(NoGitExecution::ProhibitedExecution, &attack)
        refute File.exist?(marker)
      end
      File.binwrite(marker, "\x00\xff".b)
      assert_equal "\x00\xff".b, IO.binread(marker)
      assert_equal "\x00\xff".b, File.binread(marker)
      IO.foreach(marker) do
        assert_raises(NoGitExecution::ProhibitedExecution) { ORIGINAL_ZERO_GIT_FOREACH.call("|#{shell}").to_a }
      end
      open(marker) do
        assert_raises(NoGitExecution::ProhibitedExecution) { ORIGINAL_ZERO_GIT_OPEN.bind(self).call("|#{shell}") }
      end
      assert_equal "\x00\xff".b, File.binread(marker)
    end
  end

  # A real production StandardError refusal handler cannot convert the guard
  # failure to a product-level failure result; the test boundary escapes intact.
  def test_product_refusal_cannot_swallow_boundary
    Dir.mktmpdir("zero-git-refusal-") do |root|
      manager = AgentCodingTool::WorktreeManager.new(root: root,
        record_path: File.join(root, "unused.json"))
      manager.stub(:parent_identity!, ->(*) { Open3.capture3("git", "--version") }) do
        assert_raises(NoGitExecution::ProhibitedExecution) do
          manager.create(task_id: "T", attempt: 1,
            task: { "repositories" => { "repo" => { "access" => "write" } } }, snapshot: { "repo" => {} })
        end
      end
    end
  end

  # Native transport retains binary stdin/stdout/stderr, a genuine reaped status
  # and a nonzero exit. No fabricated status or dummy status factory is used.
  def test_approved_binary_transport_and_single_use
    approval = permit("binary")
    output, error, status = capture(approval, stdin_data: "\x00\xff\x80\n".b, binmode: true)
    assert_equal "\n\x80\xff\x00".b, output
    assert_equal "\xfe\x00".b, error
    assert_instance_of Process::Status, status
    assert status.exited?
    refute status.success?
    assert_equal 7, status.exitstatus
    assert_nil status.termsig
    assert_raises(NoGitExecution::ProhibitedExecution) { capture(approval) }
  end

  # Text output and actual signal termination remain separate native outcomes.
  def test_text_and_signal_status
    output, error, status = capture(permit("text"))
    assert_equal "transport text\n", output
    assert_equal "transport error\n", error
    assert status.success?
    _output, _error, status = capture(permit("signal"))
    assert status.signaled?
    assert_equal Signal.list.fetch("TERM"), status.termsig
    assert_nil status.exitstatus
  end

  # Missing/changed guard, script argv, environment and options cannot borrow a
  # permit. Captured native methods cannot consume one, even with identical argv.
  def test_permit_binds_bootstrap_argv_environment_and_native_entry
    approval = permit("text")
    [approval.argv.reject { |argument| argument == NoGitExecution::GUARD },
     [RbConfig.ruby, "-e", "exit 0"], approval.argv + ["extra"]].each do |argv|
      assert_raises(NoGitExecution::ProhibitedExecution) do
        NoGitExecution.with_permit(approval) { Process.spawn(approval.environment, *argv) }
      end
    end
    assert_raises(NoGitExecution::ProhibitedExecution) do
      NoGitExecution.with_permit(approval) { Process.spawn(approval.environment.merge("RUBYOPT" => nil), *approval.argv) }
    end
    assert_raises(NoGitExecution::ProhibitedExecution) do
      NoGitExecution.with_permit(approval) { Process.spawn(approval.environment, *approval.argv, unsetenv_others: true) }
    end
    assert_raises(NoGitExecution::ProhibitedExecution) do
      NoGitExecution.with_permit(approval) { ORIGINAL_ZERO_GIT_SPAWN.call(approval.environment, *approval.argv) }
    end
    assert_raises(NoGitExecution::ProhibitedExecution) { NoGitExecution.with_permit(approval) { nil } }
  end

  # A reviewed child cannot drop protection by clearing RUBYOPT before another
  # spawn; ordinary's all-process guard rejects even a valid non-Git permit.
  def test_descendants_and_ordinary_prohibition
    output, _error, status = capture(permit("attack"))
    assert_equal "child protected\n", output
    assert_equal 9, status.exitstatus
    output, error, status = capture(permit("ordinary"))
    assert status.success?, error
    assert_equal "ordinary stronger\n", output
  end

  # Hash drift, missing coverage bootstrap and ambient changes refuse rather
  # than weakening exact approval. A genuine spawn error retains its exception.
  def test_changed_identities_and_spawn_error
    assert_raises(NoGitExecution::ProhibitedExecution) do
      NoGitExecution::Permit.new(script: CHILD, sha256: "0" * 64)
    end
    approval = permit("text")
    ENV["ZERO_GIT_UNDECLARED"] = "changed"
    assert_raises(NoGitExecution::ProhibitedExecution) { capture(approval) }
    ENV.delete("ZERO_GIT_UNDECLARED")
    assert_raises(NoGitExecution::ProhibitedExecution) do
      permit("text", environment: { "ACT_COVERAGE_CONTEXT" => "undeclared" })
    end
    Dir.mktmpdir("zero-git-drift-") do |root|
      script = File.join(root, "reviewed.rb")
      File.write(script, "exit 0\n")
      bundler = File.realpath($LOADED_FEATURES.find { |path| path.end_with?("/bundler/setup.rb") })
      approval = NoGitExecution::Permit.new(script: script, sha256: Digest::SHA256.file(script).hexdigest,
        preloads: { bundler => Digest::SHA256.file(bundler).hexdigest })
      File.write(script, "exit 99\n")
      assert_raises(NoGitExecution::ProhibitedExecution) { capture(approval) }
    end
    assert_raises(Errno::ENOENT) { capture(permit("text", options: { chdir: File.join(__dir__, "absent") })) }
  ensure
    ENV.delete("ZERO_GIT_UNDECLARED")
  end

  # Audit records distinguish internal refusals/permits from independent OS
  # tracing, whose absence cannot be represented as observed zero OS executions.
  def test_audit_scope
    assert_raises(NoGitExecution::ProhibitedExecution) { system("git --version") }
    assert NoGitExecution.audit.any? { |row| row["mechanism"] == "ruby-c-entry" && row["decision"] == "DENY" }
    assert_equal "UNAVAILABLE", NoGitExecution.independent_audit.fetch("status")
  end
end

# Source layouts are hand-authored filesystem fixtures; Git never initializes them.
class SourceIdentityVerifier < Minitest::Test
  HEAD = "a" * 40
  OTHER = "b" * 40

  # Creates metadata parents and writes exact bytes; filesystem errors propagate.
  def write(root, path, bytes)
    absolute = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, bytes)
  end

  # Captures only this fixture's explicit source file, avoiding fixture .git data
  # as product source. Returns the read-only reader's truthful identity envelope.
  def identity(root)
    SourceIdentity.capture(root: root, paths: ["source.rb"])
  end

  # Supplies disposable source and SHA-1 format metadata. No process is started.
  def fixture
    Dir.mktmpdir("source-identity-") do |root|
      write(root, "source.rb", "source bytes\n")
      write(root, ".git/config", "[core]\nrepositoryformatversion = 0\n")
      yield root
    end
  end

  # Ordinary loose symbolic refs resolve while source modifications alter hashes.
  def test_normal_loose_ref_and_source_hash
    fixture do |root|
      write(root, ".git/HEAD", "ref: refs/heads/main\n")
      write(root, ".git/refs/heads/main", HEAD + "\n")
      before = identity(root)
      assert_equal HEAD, before.fetch("head")
      assert_equal "AVAILABLE", before.fetch("availability")
      assert before.fetch("git_version").start_with?("UNAVAILABLE")
      write(root, "source.rb", "different bytes\n")
      refute_equal before.fetch("source_sha256"), identity(root).fetch("source_sha256")
    end
  end

  # Detached HEAD and packed refs resolve; loose refs take precedence over packed.
  def test_detached_packed_and_loose_precedence
    fixture do |root|
      write(root, ".git/HEAD", HEAD + "\n")
      assert_equal HEAD, identity(root).fetch("head")
      write(root, ".git/HEAD", "ref: refs/heads/main\n")
      write(root, ".git/packed-refs", "# pack-refs with: peeled\n#{HEAD} refs/heads/main\n^#{OTHER}\n")
      assert_equal HEAD, identity(root).fetch("head")
      write(root, ".git/refs/heads/main", OTHER + "\n")
      assert_equal OTHER, identity(root).fetch("head")
      write(root, ".git/refs/heads/main", "ref: refs/heads/alias\n")
      write(root, ".git/refs/heads/alias", HEAD)
      assert_equal HEAD, identity(root).fetch("head")
    end
  end

  # Linked worktrees read their private HEAD/index and common loose/packed refs.
  def test_worktree_pointer_and_commondir
    fixture do |root|
      FileUtils.mv(File.join(root, ".git"), File.join(root, "common"))
      write(root, ".git", "gitdir: common/worktrees/one\n")
      write(root, "common/worktrees/one/commondir", "../..\n")
      write(root, "common/worktrees/one/HEAD", "ref: refs/heads/main\n")
      write(root, "common/packed-refs", "#{HEAD} refs/heads/main\n")
      write(root, "common/worktrees/one/index", "index bytes\x00")
      assert_equal HEAD, identity(root).fetch("head")
      assert_equal File.join(root, "common"), identity(root).fetch("common_dir")
      write(root, ".git", "gitdir: #{root}/common/worktrees/one\n")
      assert_equal HEAD, identity(root).fetch("head")
      write(root, "common/worktrees/one/HEAD", OTHER)
      assert_equal OTHER, identity(root).fetch("head")
    end
  end

  # Unsupported, absent, unborn, cyclic and malformed formats are explicit, with
  # source hashes still available. None can fabricate a plausible HEAD/version.
  def test_absent_and_unsupported_layouts
    fixture do |root|
      ["ref: refs/heads/missing\n", "ref: ../../outside\n", "z" * 40].each do |head|
        write(root, ".git/HEAD", head)
        assert_equal "UNAVAILABLE", identity(root).fetch("availability")
        assert_nil identity(root).fetch("head")
      end
      write(root, ".git/HEAD", "ref: refs/heads/main\n")
      write(root, ".git/refs/heads/main", "ref: refs/heads/main\n")
      assert_match(/cyclic/, identity(root).fetch("reason"))
      FileUtils.rm(File.join(root, ".git/refs/heads/main"))
      write(root, ".git/packed-refs", "malformed ref bytes\n")
      assert_match(/malformed/, identity(root).fetch("reason"))
      write(root, ".git/HEAD", HEAD)
      write(root, ".git/config", "[core]\nrepositoryformatversion = 1\n[extensions]\nrefStorage = reftable\n")
      assert_equal "UNAVAILABLE", identity(root).fetch("availability")
      write(root, ".git/config", "[core]\nrepositoryformatversion = 0\n[extensions]\nobjectformat = sha256\n")
      assert_equal "UNAVAILABLE", identity(root).fetch("availability")
      FileUtils.remove_entry(File.join(root, ".git"))
      assert_equal "UNAVAILABLE", identity(root).fetch("availability")
      refute_empty identity(root).fetch("source_files")
      write(root, ".git", "not a gitdir pointer\n")
      assert_match(/malformed/, identity(root).fetch("reason"))
    end
  end

  # Fake world identities, environment redirection and fake cwd do not affect an
  # explicitly bound source root; source and metadata hashes remain unchanged.
  def test_fake_state_cannot_redirect_source_provenance
    fixture do |source|
      write(source, ".git/HEAD", HEAD)
      before = identity(source)
      fixture do |fake|
        write(fake, ".git/HEAD", OTHER)
        ENV["GIT_DIR"] = File.join(fake, ".git")
        ENV["GIT_WORK_TREE"] = fake
        Dir.chdir(fake) { assert_equal before, identity(source) }
      end
    end
  ensure
    ENV.delete("GIT_DIR")
    ENV.delete("GIT_WORK_TREE")
  end
end

required_cases = JSON.parse(File.binread(File.join(__dir__, "zero_git_required_cases.json")))
actual_cases = [NoGitExecutionVerifier, SourceIdentityVerifier].flat_map do |type|
  type.public_instance_methods.grep(/^test_/).map { |name| "#{type.name}##{name}" }
end
raise "zero-Git verifier case inventory differs" unless actual_cases.sort == required_cases.sort
ENV["ACT_SUITE_INVOCATION"] = SecureRandom.uuid
ENV["ACT_SUITE_SELECTION"] = required_cases.sort.join("\n")
ENV["ACT_SUITE_EVIDENCE"] = ENV["ZERO_GIT_EVIDENCE"] || File.join(Dir.mktmpdir("zero-git-results-"), "results.json")
raise "zero-Git evidence already exists" if File.exist?(ENV.fetch("ACT_SUITE_EVIDENCE"))
require_relative "../suite_reporter"

Minitest.after_run do
  path = ENV["ZERO_GIT_AUDIT"]
  File.write(path, JSON.pretty_generate("records" => NoGitExecution.audit,
    "independent_os_audit" => NoGitExecution.independent_audit) + "\n", mode: "wx") if path
  evidence = JSON.parse(File.binread(ENV.fetch("ACT_SUITE_EVIDENCE")))
  results = evidence.fetch("results")
  raise "zero-Git verifier missing/failed/duplicate case evidence" unless
    results.map { |row| row.fetch("case") }.sort == required_cases.sort &&
    results.all? { |row| row.fetch("status") == "pass" }
end
