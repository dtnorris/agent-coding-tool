# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "agent_coding_tool"
require_relative "observations"

# Native oracle and strict replay through unmodified production interpretation.
# Deliberately outside *_test.rb discovery until the coordinated runner selects it.
class NativeGitContract < Minitest::Test
  Config = Struct.new(:repo_root, :default_remote, :default_branch)

  # Builds a disposable local-only Git history under an explicit temporary
  # parent. Yields native recorder, parent checkout, bare remote and base SHA;
  # setup/process failures raise and every filesystem write is removed afterward.
  def fixture
    Dir.mktmpdir("act-contract-", ENV.fetch("ACT_GIT_CONTRACT_TMPDIR", Dir.tmpdir)) do |directory|
      root = File.realpath(directory)
      environment = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }.merge(
        "HOME" => root, "XDG_CONFIG_HOME" => root, "TMPDIR" => root,
        "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
        "GIT_CEILING_DIRECTORIES" => root,
        "GIT_TERMINAL_PROMPT" => "0", "GIT_ALLOW_PROTOCOL" => "file",
        "GIT_AUTHOR_DATE" => "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2026-01-01T00:00:00Z",
        "LC_ALL" => "C", "TZ" => "UTC"
      )
      native = GitContract::Native.new(environment: environment)
      parent = File.join(root, "ordinary")
      remote = File.join(root, "remote.git")
      git(native, nil, "init", "--initial-branch=main", "--object-format=sha1", parent)
      git(native, parent, "config", "user.name", "Contract Fixture")
      git(native, parent, "config", "user.email", "fixture@example.test")
      git(native, parent, "config", "core.autocrlf", "false")
      %w[staged unstaged renamed].each { |name| File.binwrite(File.join(parent, name), "base\n") }
      git(native, parent, "add", ".")
      git(native, parent, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "-m", "baseline")
      git(native, nil, "clone", "--bare", "--", parent, remote)
      git(native, parent, "remote", "add", "origin", remote)
      assert_equal remote, git(native, parent, "remote", "get-url", "origin").strip
      yield native, parent, remote, git(native, parent, "rev-parse", "HEAD").strip
    end
  end

  # Runs a fixture command, returning raw stdout; command failures raise with
  # actual stderr/status instead of creating a usable but invalid history.
  def git(native, cwd, *arguments)
    stdout, stderr, status = native.capture3("git", *arguments, chdir: cwd)
    raise "fixture Git failed (#{status.exitstatus}): #{stderr}" unless status.success?

    stdout
  end

  # Runs a production boundary against native observations and strict replay.
  # Returns [interpreted result, observations]; tests independently assert the
  # expected semantics. Native stdout/stderr/status/exception remain the oracle.
  def equivalent(native, ordered: true)
    start = native.observations.length
    actual = Open3.stub(:capture3, native.method(:capture3)) { yield }
    observations = native.observations.drop(start)
    replay = GitContract::Replay.new(observations, ordered: ordered)
    simulated = Open3.stub(:capture3, replay.method(:capture3)) { yield }
    assert_equal actual, simulated
    assert replay.verify!
    observations.each do |observation|
      next if observation.exception

      stdout, stderr, status = GitContract::Replay.new([observation]).capture3(*observation.argv, chdir: observation.cwd)
      assert_equal observation.stdout.bytes, stdout.bytes
      assert_equal observation.stderr.bytes, stderr.bytes
      assert_equal [observation.status.exitstatus, observation.status.termsig, observation.status.success?],
                   [status.exitstatus, status.termsig, status.success?]
    end
    [actual, observations]
  end

  # Returns a copy with one command's stdout/status corrupted, retaining all
  # other native inputs/outputs. Raises if the selected observation is absent.
  def corrupt(observations, argument, stdout: nil, status: nil)
    index = observations.index { |item| item.argv.include?(argument) }
    raise "no observation for #{argument}" unless index

    observations.each_with_index.map do |item, position|
      next item unless position == index

      GitContract::Observation.new(argv: item.argv, cwd: item.cwd,
        result: [stdout || item.stdout, item.stderr, status.nil? ? item.status : status])
    end
  end

  # Converts expected production refusals to comparable class/message values;
  # strict fixture mismatches deliberately escape this StandardError boundary.
  def refusal
    yield
    flunk "expected production refusal"
  rescue AgentCodingTool::Error => error
    [error.class, error.message]
  end

  # Exercises authoritative remote refs, divergent local HEAD, all dirty-state
  # forms and production parsing failures; returns only assertions.
  def test_authoritative_refs_snapshot_and_dirty_state
    fixture do |native, parent, remote, base|
      inspector = AgentCodingTool::RepoInspector.new(Config.new(parent, "origin", "main"))
      spec = { "path" => parent }
      clean, = equivalent(native) { inspector.snapshot("repo", spec) }
      assert_equal [base, base, false, remote], clean.values_at("pushed_sha", "local_head", "local_dirty", "remote_url")

      File.binwrite(File.join(parent, "staged"), "staged\n")
      git(native, parent, "add", "staged")
      staged, = equivalent(native) { inspector.snapshot("repo", spec) }
      assert staged.fetch("local_dirty")
      git(native, parent, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "-m", "local")
      local = git(native, parent, "rev-parse", "HEAD").strip
      refute_equal base, local
      File.binwrite(File.join(parent, "unstaged"), "unstaged\n")
      dirty, observations = equivalent(native) { inspector.snapshot("repo", spec) }
      assert_equal [base, local, true], dirty.values_at("pushed_sha", "local_head", "local_dirty")
      git(native, parent, "checkout", "--", "unstaged")
      File.binwrite(File.join(parent, "untracked\né".b), "new\n")
      untracked, = equivalent(native) { inspector.snapshot("repo", spec) }
      assert untracked.fetch("local_dirty")

      ["", "#{base}\trefs/heads/other\n", "z#{base[1..]}\trefs/heads/main\n",
       "#{base}\trefs/heads/main\n#{base}\trefs/heads/main\n"].each do |invalid|
        replay = GitContract::Replay.new(corrupt(observations.take(2), "ls-remote", stdout: invalid))
        error = refusal { AgentCodingTool::RepoInspector.new(Config.new(parent, "origin", "main"), runner: replay).snapshot("repo", spec) }
        assert_equal AgentCodingTool::RepositoryError, error.first
        assert_match(/expected exactly one|malformed pushed ref/, error.last)
        assert replay.verify!
      end
      replay = GitContract::Replay.new(corrupt(observations, "status", stdout: ""))
      inaccurate = AgentCodingTool::RepoInspector.new(Config.new(parent, "origin", "main"), runner: replay).snapshot("repo", spec)
      refute_equal dirty, inaccurate, "negative control must detect a falsely clean observation"
      assert replay.verify!
      failed_status = GitContract::Replay.new(corrupt(observations.take(1), "rev-parse", status: false))
      error = refusal { AgentCodingTool::RepoInspector.new(Config.new(parent, "origin", "main"), runner: failed_status).snapshot("repo", spec) }
      assert_match(/not a git repository/, error.last)
      assert failed_status.verify!
      equivalent(native) { inspector.snapshot("repo", spec) }
    end
  end

  # Verifies NUL-delimited staged/unstaged/untracked/rename and binary paths
  # using Publisher's actual parser and mixed-index refusal, without publishing.
  def test_nul_status_parser_and_refusal
    fixture do |native, parent, _remote, _base|
      binary_path = "new\né".b
      File.binwrite(File.join(parent, binary_path), "\x00\xFF".b)
      File.binwrite(File.join(parent, "staged"), "index\n")
      git(native, parent, "add", "staged")
      File.binwrite(File.join(parent, "staged"), "working\n")
      File.binwrite(File.join(parent, "unstaged"), "working\n")
      git(native, parent, "mv", "renamed", "moved\nname")
      publisher = AgentCodingTool::Publisher.new(data_root: parent, config: nil, task_store: nil)
      entries, observations = equivalent(native) { publisher.send(:status_entries) }
      assert_equal [
        { xy: "R ", path: "moved\nname", original: "renamed" },
        { xy: "MM", path: "staged", original: nil },
        { xy: " M", path: "unstaged", original: nil },
        { xy: "??", path: binary_path, original: nil }
      ], entries
      raw = observations.first.stdout
      assert_includes raw, "?? #{binary_path}\0".b
      assert_includes raw, "R  moved\nname\0renamed\0".b
      blocker, = equivalent(native) { publisher.send(:scope_blocker, entries, ["staged"], :default, nil) }
      assert_match(/different staged and working-tree versions/, blocker)
      altered = corrupt(observations, "status", stdout: raw.sub(binary_path, "wrong"))
      replay = GitContract::Replay.new(altered)
      changed = Open3.stub(:capture3, replay.method(:capture3)) { publisher.send(:status_entries) }
      refute_equal entries, changed, "binary-path corruption must be observable"
      assert replay.verify!
      equivalent(native) { publisher.send(:status_entries) }
    end
  end

  # Validates real linked-worktree metadata and registry through the production
  # ownership checker, including registry/HEAD/backpointer corruption refusals.
  def test_linked_worktree_ownership
    fixture do |native, parent, remote, base|
      workspace = File.join(File.dirname(parent), "linked")
      git(native, parent, "worktree", "add", "--detach", "--", workspace, base)
      entry = { "name" => "repo", "path" => workspace, "parent" => parent,
        "remote" => "origin", "remote_url" => remote, "base_sha" => base, "branch" => nil }
      manager = AgentCodingTool::WorktreeManager.new(root: File.dirname(parent), record_path: File.join(parent, "unused.json"))
      accepted, observations = equivalent(native) { manager.send(:verify_entry!, entry, expected_head: base) }
      assert_equal true, accepted
      registry = observations.find { |item| item.argv.include?("list") }
      assert_includes registry.stdout, "worktree #{workspace}\0HEAD #{base}\0detached\0\0"
      [["list", registry.stdout.sub("worktree #{workspace}", "worktree #{workspace}-foreign"), /registry mismatch/],
       ["HEAD", observations.find { |item| item.argv.include?("HEAD") }.stdout.sub(base, "0" * 40), /HEAD changed/]].each do |argument, output, message|
        replay = GitContract::Replay.new(corrupt(observations, argument, stdout: output).take(argument == "HEAD" ? 4 : observations.length))
        error = Open3.stub(:capture3, replay.method(:capture3)) { refusal { manager.send(:verify_entry!, entry, expected_head: base) } }
        assert_match message, error.last
        assert replay.verify!
      end
      admin = git(native, workspace, "rev-parse", "--absolute-git-dir").strip
      pointer = File.join(admin, "gitdir")
      original = File.binread(pointer)
      begin
        File.binwrite(pointer, "#{workspace}-foreign/.git\n")
        error, = equivalent(native) { refusal { manager.send(:verify_entry!, entry, expected_head: base) } }
        assert_match(/backpointer changed/, error.last)
      ensure
        File.binwrite(pointer, original)
      end
      equivalent(native) { manager.send(:verify_entry!, entry, expected_head: base) }
    end
  end

  # Checks exact committed binary bytes/executable modes and ref movement using
  # local remotes only; exercises DeliveryManager's real commit refusal logic.
  def test_commit_contents_modes_and_ref_movement
    fixture do |native, parent, remote, base|
      bytes = "#!/bin/sh\n\x00\xFF\r\n".b
      File.binwrite(File.join(parent, "payload"), bytes)
      File.chmod(0o755, File.join(parent, "payload"))
      File.binwrite(File.join(parent, "plain"), "plain\n")
      File.chmod(0o644, File.join(parent, "plain"))
      File.unlink(File.join(parent, "renamed"))
      git(native, parent, "add", "-A")
      git(native, parent, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "-m", "payload")
      commit = git(native, parent, "rev-parse", "HEAD").strip
      manager = AgentCodingTool::DeliveryManager.new(data_root: parent, coordinator: nil, provider: Object.new, guard: Object.new)
      details = { "base_sha" => base, "paths" => %w[payload plain renamed],
        "manifest" => {
          "payload" => { "sha256" => Digest::SHA256.hexdigest(bytes), "mode" => 0o111 },
          "plain" => { "sha256" => Digest::SHA256.hexdigest("plain\n"), "mode" => 0 },
          "renamed" => { "deleted" => true }
        } }
      accepted, observations = equivalent(native) { manager.send(:verify_commit!, parent, commit, details) }
      assert_equal true, accepted
      assert_equal bytes, observations.find { |item| item.argv.include?("show") }.stdout
      executable = observations.find { |item| item.argv.include?("ls-tree") }
      assert_match(/\A100755 blob [0-9a-f]{40}\tpayload\n\z/, executable.stdout)
      regular = observations.find { |item| item.argv.last == "plain" }
      assert_match(/\A100644 blob [0-9a-f]{40}\tplain\n\z/, regular.stdout)
      assert_equal 128, observations.last.status.exitstatus
      [["show", bytes.sub("\xFF".b, "x"), /bytes differ/],
       ["ls-tree", executable.stdout.sub("100755", "100644"), /mode differs/]].each do |argument, output, message|
        length = observations.index { |item| item.argv.include?(argument) } + 1
        replay = GitContract::Replay.new(corrupt(observations, argument, stdout: output).take(length))
        error = Open3.stub(:capture3, replay.method(:capture3)) { refusal { manager.send(:verify_commit!, parent, commit, details) } }
        assert_match message, error.last
        assert replay.verify!
      end
      equivalent(native) { manager.send(:verify_commit!, parent, commit, details) }
      references = [{ "name" => "repo", "remote_url" => remote, "branch" => "main" }]
      inspector = AgentCodingTool::RepoInspector.new(Config.new(parent, "origin", "main"))
      before, = equivalent(native) { inspector.pushed_heads(references) }
      assert_equal base, before.fetch([remote, "main"])
      # Destination is the just-created bare remote, never an operator remote.
      assert_equal File.join(File.dirname(parent), "remote.git"), remote
      git(native, parent, "-c", "core.hooksPath=/dev/null", "push", remote, "HEAD:refs/heads/main")
      after, = equivalent(native) { inspector.pushed_heads(references) }
      assert_equal commit, after.fetch([remote, "main"])
      git(native, remote, "update-ref", "refs/heads/release", base)
      references << { "name" => "release", "remote_url" => remote, "branch" => "release" }
      concurrent, = equivalent(native, ordered: false) { inspector.pushed_heads(references + references) }
      assert_equal({ [remote, "main"] => commit, [remote, "release"] => base }, concurrent)
    end
  end

  # Distinguishes exit 2 missing refs, exit 128 repository failures and ENOENT
  # spawn/cwd exceptions, preserving production error classification and bytes.
  def test_failures_and_exceptions
    fixture do |native, parent, remote, _base|
      config = Config.new(parent, "origin", "main")
      inspector = AgentCodingTool::RepoInspector.new(config)
      error, observations = equivalent(native) do
        refusal { inspector.pushed_heads([{ "name" => "repo", "remote_url" => remote, "branch" => "missing" }]) }
      end
      assert_match(/cannot resolve pushed/, error.last)
      assert_equal ["", "", 2], observations.first.then { |item| [item.stdout, item.stderr, item.status.exitstatus] }
      nonrepository = File.join(File.dirname(parent), "nonrepository")
      FileUtils.mkdir_p(nonrepository)
      error, observations = equivalent(native) { refusal { inspector.snapshot("repo", "path" => nonrepository) } }
      assert_match(/not a git repository/, error.last)
      assert_equal 128, observations.first.status.exitstatus
      assert_includes observations.first.stderr, "not a git repository"
      error, observations = equivalent(native) { refusal { inspector.snapshot("repo", "path" => File.join(parent, "absent")) } }
      assert_match(/repository path does not exist/, error.last)
      assert_instance_of Errno::ENOENT, observations.first.exception
      exception, observations = equivalent(native) do
        begin
          AgentCodingTool::CommandRunner.new.capture(File.join(parent, "missing-executable"))
          flunk "expected missing executable"
        rescue Errno::ENOENT => error
          [error.class, error.message]
        end
      end
      assert_equal Errno::ENOENT, exception.first
      assert_instance_of Errno::ENOENT, observations.first.exception
    end
  end

  # Proves strict argv/cwd/order/missing/duplicate refusal and mutable byte-copy
  # isolation without native setup. Boolean observations never fake raw status.
  def test_strict_replay
    observation = GitContract::Observation.new(argv: %w[git rev-parse HEAD], cwd: "/fixture",
      result: ["\x00\xFF\n".b, "\xFE".b, false])
    runner = GitContract::Replay.new([observation])
    assert_raises(GitContract::UnexpectedObservation) { runner.capture("git", "rev-parse", "HEAD", chdir: "/wrong") }
    assert_raises(GitContract::UnexpectedObservation) { runner.capture("git", "rev-parse", "head", chdir: "/fixture") }
    assert_raises(GitContract::UnexpectedObservation) { runner.verify! }
    output = runner.capture(*observation.argv, chdir: observation.cwd)
    assert_equal ["\x00\xFF\n".b, "\xFE".b, false], output
    output.first.clear
    assert_equal "\x00\xFF\n".b, observation.stdout
    assert runner.verify!
    assert_raises(GitContract::UnexpectedObservation) { runner.capture(*observation.argv, chdir: observation.cwd) }
    other = GitContract::Observation.new(argv: %w[git status], cwd: "/fixture", result: ["", "", true])
    ordered = GitContract::Replay.new([observation, other])
    assert_raises(GitContract::UnexpectedObservation) { ordered.capture(*other.argv, chdir: other.cwd) }
    assert_raises(ArgumentError) { observation.capture3 }
  end

  # Keeps RepoInspector's concurrent scheduling real while independently
  # matching each observation once. A bounded rendezvous detects serialization.
  def test_concurrent_remote_requests
    config = Config.new("/fixture", "origin", "main")
    references = %w[alpha beta].map { |name| { "name" => name, "remote_url" => "/fixture/#{name}.git", "branch" => "main" } }
    observations = references.map do |reference|
      GitContract::Observation.new(argv: ["git", "ls-remote", "--exit-code", reference.fetch("remote_url"), "refs/heads/main"],
        cwd: nil, result: ["#{'a' * 40}\trefs/heads/main\n", "", true])
    end
    replay = GitContract::Replay.new(observations.reverse, ordered: false)
    lock = Mutex.new
    signal = ConditionVariable.new
    active = 0
    runner = Object.new
    runner.define_singleton_method(:capture) do |*argv, chdir: nil|
      lock.synchronize do
        active += 1
        signal.broadcast
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        while active < 2
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise "concurrent observation rendezvous timed out" unless remaining.positive?

          signal.wait(lock, remaining)
        end
      end
      replay.capture(*argv, chdir: chdir)
    end
    heads = AgentCodingTool::RepoInspector.new(config, runner: runner, remote_concurrency: 2).pushed_heads(references + references)
    assert_equal 2, heads.length
    assert_equal ["a" * 40], heads.values.uniq
    assert replay.verify!
  end

  # Qualifies binary stdout/stderr, nonzero/signaled status and deadline cleanup
  # on owned fixture children; exceptions are never fabricated as exit statuses.
  def test_native_process_observer
    native = GitContract::Native.new
    output, observations = equivalent(native) do
      AgentCodingTool::CommandRunner.new.capture(RbConfig.ruby, "-e", 'STDOUT.binmode.write("\x00\xFF"); STDERR.binmode.write("\xFE"); exit 7')
    end
    assert_equal ["\x00\xFF".b, "\xFE".b, false], output
    assert_equal 7, observations.first.status.exitstatus
      signaled, observations = equivalent(native) do
        AgentCodingTool::CommandRunner.new.capture(RbConfig.ruby, "-e", 'Process.kill("TERM", Process.pid)')
      end
      assert_equal ["", "", nil], signaled
      status = observations.first.status
    assert_equal Signal.list.fetch("TERM"), status.termsig
    assert_nil status.success?
    bounded = GitContract::Native.new(seconds: 0.1)
    error = assert_raises(IOError) { bounded.capture3(RbConfig.ruby, "-e", "sleep 10") }
    assert_match(/exceeded/, error.message)
    assert_empty bounded.observations
  end

  # Proves the renderer's boolean runner seam against a bounded immutable Git
  # blob read, including material environment, dirty-source immunity, replay and
  # missing-object refusal. No test-only source defaults are installed here.
  def test_immutable_skill_object_read
    fixture do |native, parent, _remote, _base|
      text = "---\nname: karpathy-manning-dtnorris-guidelines\ndescription: Native fixture.\nlicense: MIT\n---\n\nInspect and verify.\n"
      path = AgentCodingTool::PromptRenderer::SKILL_PATH
      FileUtils.mkdir_p(File.dirname(File.join(parent, path)))
      File.binwrite(File.join(parent, path), text)
      git(native, parent, "add", path)
      git(native, parent, "-c", "core.hooksPath=/dev/null", "commit", "-m", "immutable source")
      pin = { "revision" => git(native, parent, "rev-parse", "HEAD").strip,
              "sha256" => Digest::SHA256.hexdigest(text) }
      File.binwrite(File.join(parent, path), "malformed dirty source")
      task = { "id" => "T", "title" => "Native source", "repositories" => {} }
      before = native.observations.length
      actual = AgentCodingTool::PromptRenderer.new(skill_root: parent, skill_identity: pin, runner: native).render(task, {})
      observation = native.observations.drop(before).fetch(0)
      assert_equal 1, native.observations.length - before
      assert_equal text.b, observation.stdout
      assert_equal "".b, observation.stderr
      assert_equal 0, observation.status.exitstatus
      assert_equal({ "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0" }, observation.argv.first)
      assert_equal ["git", "--no-replace-objects", "-C", parent, "cat-file", "blob",
                    "#{pin.fetch('revision')}^{commit}:#{path}"], observation.argv.drop(1)
      replay = GitContract::Replay.new([observation])
      assert_equal actual, AgentCodingTool::PromptRenderer.new(skill_root: parent, skill_identity: pin, runner: replay).render(task, {})
      assert replay.verify!
      assert_includes actual, text
      refute_includes actual, "malformed dirty source"

      missing = pin.merge("revision" => "0" * 40)
      error = assert_raises(AgentCodingTool::InvalidState) do
        AgentCodingTool::PromptRenderer.new(skill_root: parent, skill_identity: missing, runner: native).render(task, {})
      end
      assert_match(/pinned source unavailable/, error.message)
      failure = native.observations.last
      assert_equal 128, failure.status.exitstatus
      replay = GitContract::Replay.new([failure])
      replayed = assert_raises(AgentCodingTool::InvalidState) do
        AgentCodingTool::PromptRenderer.new(skill_root: parent, skill_identity: missing, runner: replay).render(task, {})
      end
      assert_equal error.message, replayed.message
      assert replay.verify!
    end
  end
end
