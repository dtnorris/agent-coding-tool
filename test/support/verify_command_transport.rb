# frozen_string_literal: true

# This entrypoint deliberately avoids the unmigrated test_helper and Rake startup.
require_relative "no_git_execution"
require "bundler/setup"
require "minitest/autorun"
require "minitest/mock"
Minitest::Assertions.diff = nil
require "fileutils"
require "json"
require "securerandom"
require "stringio"
require "tmpdir"
require_relative "command_boundary_audit"
require_relative "../../lib/agent_coding_tool"
require_relative "../apply_handoff_observations"

# A finite raw transport double; mismatches escape product StandardError handlers.
class ExpectedCommandTransport
  class UnknownRequest < Exception; end

  # Takes ordered [argv, keyword-fields, result-or-exception] records. No fallback
  # or native execution exists. Calls/verification consume only declared requests.
  def initialize(records)
    @records = records.dup
  end

  # Matches every field, including omitted/default options; returns CommandResult
  # or raises the exact declared exception. Unknown requests raise UnknownRequest.
  def call(argv, cwd: nil, env: {}, input: "", timeout: nil, **options)
    expected = @records.shift
    request = [argv, { cwd: cwd, env: env, input: input, timeout: timeout }.merge(options)]
    raise UnknownRequest, "undeclared command envelope: #{request.inspect}" unless expected && request == expected[0, 2]
    response = expected[2]
    raise response if response.is_a?(Exception)
    raise UnknownRequest, "response is not CommandResult" unless response.is_a?(AgentCodingTool::CommandResult)
    response
  end

  # Refuses omitted commands after a journey; returns true for exact consumption.
  def verify!
    raise UnknownRequest, "required commands unconsumed: #{@records.length}" unless @records.empty?
    true
  end
end

# Component proof for TST-34, not whole-suite or native-Git conformance evidence.
class CommandTransportVerifier < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CHILD = File.join(__dir__, "fixtures/command_transport_child.rb")
  CHILD_SHA = "f8d95e566e709bc1157c1b94fb624d76e61c935803394f8c9cd28a366d0c7b98"
  SHA = "a" * 40
  REMOTE = "git@github.com:example/repo.git"

  # Creates one raw result; no dummy process/status or product method is faked.
  def result(stdout = "", stderr = "", code = 0, signal: nil)
    AgentCodingTool::CommandResult.new(stdout: stdout, stderr: stderr,
      exitstatus: signal ? nil : code, termsig: signal)
  end

  # Records the full defaulted request envelope, making options strict.
  def request(argv, response = result, cwd: nil, env: {}, input: "", timeout: nil, **options)
    [argv, { cwd: cwd, env: env, input: input, timeout: timeout }.merge(options), response]
  end

  # Authorizes a single reviewed Ruby fixture; every descendant inherits the guard.
  # Exact argv/env/options and current script/preload bytes are checked at spawn.
  def permit(mode, arguments: [], environment: {}, options: {})
    bundler = File.realpath($LOADED_FEATURES.find { |path| path.end_with?("/bundler/setup.rb") })
    NoGitExecution::Permit.new(script: CHILD, sha256: CHILD_SHA, arguments: [mode, *arguments],
      environment: environment, options: options,
      preloads: { bundler => Digest::SHA256.file(bundler).hexdigest })
  end

  # Runs the production native transport under a one-use permit; exceptions and
  # CommandResult are returned unchanged. IO options are separate from spawn options.
  def capture(approval, transport: AgentCodingTool::NativeCommandTransport.new, **fields)
    options = approval.options.dup
    cwd = options.delete(:chdir)
    NoGitExecution.with_permit(approval) do
      transport.call(approval.argv, cwd: cwd, env: approval.environment, **options, **fields)
    end
  end

  # Provides a real filesystem root/config with no native Git repository.
  def fixture
    Dir.mktmpdir("command-transport-") do |directory|
      root = File.realpath(directory)
      File.write(File.join(root, "config.yml"), YAML.dump("repo_root" => root, "worktree_root" => File.join(root, "workers")))
      yield root, AgentCodingTool::Config.load(File.join(root, "config.yml"))
    end
  end

  # Exit 0, nonzero and signal are independent facts, with native nil-success for
  # signals. Ambiguous/invalid results cannot masquerade as successful exits.
  def test_result_exit_signal_and_invalid_facts
    success = result("\x00\xff".b, "\xfe".b)
    stdout, stderr, status = success
    assert_same success, status
    assert_equal "\x00\xff".b, stdout
    assert_equal "\xfe".b, stderr
    assert success.exited?
    refute success.signaled?
    assert_equal true, success.success?
    assert_equal 0, success.exitstatus
    assert_nil success.termsig
    assert_equal 0, success.shell_status
    failure = result("", "", 7)
    assert failure.exited?
    assert_equal false, failure.success?
    assert_equal 7, failure.shell_status
    signal = result(signal: 15)
    assert signal.signaled?
    refute signal.exited?
    assert_nil signal.exitstatus
    assert_nil signal.success?
    assert_equal 15, signal.termsig
    assert_equal 143, signal.shell_status
    [{}, { exitstatus: 0, termsig: 15 }, { exitstatus: -1 }, { termsig: 0 },
     { exitstatus: false }, { exitstatus: 0, stdout: nil }].each do |facts|
      assert_raises(ArgumentError) do
        AgentCodingTool::CommandResult.new(**{ stdout: "", stderr: "" }.merge(facts))
      end
    end
  end

  # Both native paths preserve NUL/invalid UTF-8 and large stdin while draining
  # stdout/stderr; the real nonzero child is the evidence, not a status factory.
  def test_native_binary_capture_and_grouped_capture
    input = "\x00\xff\x80\n".b * 32_768
    [{}, { pgroup: true }].each do |options|
      response = capture(permit("binary", options: options), input: input, binmode: true)
      assert_instance_of AgentCodingTool::CommandResult, response
      assert_equal input.reverse, response.stdout.b
      assert_equal "\xfe\x00".b, response.stderr.b
      assert response.exited?
      assert_equal 7, response.exitstatus
      assert_equal false, response.success?
      assert_nil response.termsig
    end
  end

  # Environment additions/removal, cwd and native spawn options reach the actual
  # child. Group identity and bootstrap are observed by that child independently.
  def test_native_environment_cwd_and_options
    fixture do |root, _config|
      original = ENV["TRANSPORT_REMOVED"]
      ENV["TRANSPORT_REMOVED"] = "parent"
      approval = permit("environment", environment: { "TRANSPORT_VALUE" => "raw value", "TRANSPORT_REMOVED" => nil },
        options: { chdir: root, pgroup: true, unsetenv_others: true, close_others: true })
      response = capture(approval)
      facts = JSON.parse(response.stdout)
      assert_equal root, facts.fetch("cwd")
      assert_equal "raw value", facts.fetch("value")
      assert_nil facts.fetch("removed")
      assert_equal facts.fetch("pid"), facts.fetch("group")
      assert_equal true, facts.fetch("guard")
      assert response.success?
    ensure
      ENV["TRANSPORT_REMOVED"] = original
    end
  end

  # Genuine TERM termination is not a normal failed exit on either native path.
  def test_native_signal_retains_nil_success
    [{}, { pgroup: true }].each do |options|
      response = capture(permit("signal", options: options))
      assert response.signaled?
      refute response.exited?
      assert_equal Signal.list.fetch("TERM"), response.termsig
      assert_nil response.exitstatus
      assert_nil response.success?
    end
  end

  # A rejecting child closes stdin; EPIPE cannot hide diagnostics or exit status.
  def test_grouped_rejected_stdin_keeps_diagnostic
    response = capture(permit("reject_input", options: { pgroup: true }), input: "input" * 262_144)
    assert_equal 3, response.exitstatus
    assert_equal "rejected\x00\xff".b, response.stderr
    assert_empty response.stdout
  end

  # A finite timeout kills/reaps the actual owned child, including when blocked
  # writing stdin. The pid file proves execution reached the reviewed script.
  def test_native_timeout_cleans_up_child_and_blocked_input
    [false, 0, -1, Float::INFINITY, Float::NAN, Complex(1, 1), "1"].each do |timeout|
      assert_raises(ArgumentError) { AgentCodingTool::NativeCommandTransport.new.call(["unreachable"], timeout: timeout) }
    end
    fixture do |root, _config|
      ["", "blocked input" * 262_144].each_with_index do |input, index|
        pidfile = File.join(root, "child-#{index}.pid")
        approval = permit("lease", arguments: [pidfile], options: { pgroup: index.positive? })
        assert_raises(Timeout::Error) { capture(approval, input: input, timeout: 0.5) }
        pid = Integer(File.read(pidfile))
        assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
        assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      end
    end
  end

  # Interrupt occurs only after the child readiness record. Partial raw output is
  # replayed and the owned group is gone; no native-status impersonation occurs.
  def test_native_interrupt_replays_output_and_reaps
    [true, false].each do |replay|
      fixture do |root, _config|
        pidfile = File.join(root, "interrupted.pid")
        out, err = StringIO.new, StringIO.new
        transport = replay ? AgentCodingTool::NativeCommandTransport.new(interrupt_out: out, interrupt_err: err) :
          AgentCodingTool::NativeCommandTransport.new
        owner = Thread.current
        interrupter = Thread.new do
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
          until File.file?(pidfile)
            raise "child readiness timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            sleep 0.001
          end
          owner.raise Interrupt
        end
        approval = permit("lease", arguments: [pidfile], options: { pgroup: true })
        assert_raises(Interrupt) { capture(approval, transport: transport) }
        interrupter.value
        assert_equal(replay ? "ready\x00\xff".b : "".b, out.string.b)
        assert_equal(replay ? "waiting\xfe".b : "".b, err.string.b)
        assert_raises(Errno::ESRCH) { Process.kill(0, Integer(File.read(pidfile))) }
      ensure
        interrupter&.join
      end
    end
  end

  # Missing cwd and injected exact exception identity remain separate checks from
  # the genuine missing-executable probe below.
  def test_spawn_errors_propagate_unchanged
    fixture do |root, _config|
      [{}, { pgroup: true }].each do |options|
        approval = permit("environment", options: options.merge(chdir: File.join(root, "missing")))
        assert_raises(Errno::ENOENT) { capture(approval) }
      end
    end
    missing = Errno::ENOENT.new("missing executable")
    Open3.stub(:capture3, ->(*) { raise missing }) do
      error = assert_raises(Errno::ENOENT) { AgentCodingTool::NativeCommandTransport.new.call(["missing-executable"]) }
      assert_same missing, error
    end
  end

  # Real absent executable with a valid cwd reaches native spawn on capture3,
  # explicit grouped and timed paths. The raise observer proves that the exact
  # native exception, including errno/message/backtrace, escapes the transport.
  def test_native_missing_executable_propagates_on_all_paths
    fixture do |root, _config|
      [{}, { pgroup: true }, { timeout: 1 }].each do |fields|
        options = fields.empty? ? {} : { pgroup: true }
        bundler = File.realpath($LOADED_FEATURES.find { |path| path.end_with?("/bundler/setup.rb") })
        approval = NoGitExecution::MissingExecutablePermit.new(directory: root, options: options,
          preloads: { bundler => Digest::SHA256.file(bundler).hexdigest })
        native = []
        observer = TracePoint.new(:raise) do |event|
          if event.method_id == :spawn && event.raised_exception.is_a?(Errno::ENOENT)
            error = event.raised_exception
            native << [error, error.message.dup, error.backtrace.dup]
          end
        end
        before = NoGitExecution.audit.length
        error = observer.enable do
          assert_raises(Errno::ENOENT) { capture(approval, **fields) }
        end
        assert_equal 1, native.length
        assert_same native[0][0], error
        assert_equal native[0][1], error.message
        assert_equal native[0][2], error.backtrace
        assert_equal Errno::ENOENT::Errno, error.errno
        assert_includes error.message, approval.argv.first
        assert approval.used?
        assert File.directory?(Dir.pwd)
        refute File.exist?(approval.argv.first)
        assert_equal ["ruby-c-entry-exact-permit"], NoGitExecution.audit.drop(before).map { |row| row.fetch("mechanism") }
      ensure
        observer&.disable
      end
    end
  end

  # The legacy runner preserves leading env, cwd, input, timeout and options while
  # converting only success. Raw faults and nil signal success survive translation.
  def test_runner_normalizes_every_request_field_and_signal
    environment = { "GIT_NO_LAZY_FETCH" => "1" }
    response = result("\x00\xff".b, "\xfe".b, signal: 15)
    error = Errno::ENOENT.new("runner spawn")
    transport = ExpectedCommandTransport.new([
      request(["git", "cat-file", "blob", SHA], response, cwd: "/repo", env: environment,
        input: "\xff\x00".b, timeout: 1, unsetenv_others: true, close_others: false),
      request(["missing"], error)
    ])
    runner = AgentCodingTool::CommandRunner.new(transport: transport)
    assert_equal ["\x00\xff".b, "\xfe".b, nil], runner.capture(environment, "git", "cat-file", "blob", SHA,
      chdir: "/repo", stdin_data: "\xff\x00".b, timeout: 1, unsetenv_others: true, close_others: false)
    assert_same error, assert_raises(Errno::ENOENT) { runner.capture("missing") }
    assert transport.verify!
  end

  # All defaults remain native. Injection changes execution only, and an unknown
  # request escapes a production refusal handler without any native fallback.
  def test_native_defaults_and_unknown_requests
    assert_instance_of AgentCodingTool::NativeCommandTransport,
      AgentCodingTool::CommandRunner.new.instance_variable_get(:@transport)
    fixture do |root, config|
      stores = { task_store: AgentCodingTool::TaskStore.new(File.join(root, "tasks")),
        state_store: AgentCodingTool::StateStore.new(File.join(root, "state")) }
      inspector = AgentCodingTool::RepoInspector.new(config)
      renderer = AgentCodingTool::PromptRenderer.new
      publisher = AgentCodingTool::Publisher.new(data_root: root, config: config, task_store: stores.fetch(:task_store))
      [inspector, renderer, publisher].each do |service|
        assert_instance_of AgentCodingTool::NativeCommandTransport,
          service.instance_variable_get(:@runner).instance_variable_get(:@transport)
      end
      services = [AgentCodingTool::CLI.new(root: ROOT, data_root: root, out: StringIO.new, err: StringIO.new),
        AgentCodingTool::Checkpoint.new(data_root: root),
        AgentCodingTool::DeliveryManager.new(data_root: root, coordinator: nil),
        AgentCodingTool::MultiDeliveryManager.new(data_root: root, coordinator: nil),
        AgentCodingTool::CleanupManager.new(data_root: root),
        AgentCodingTool::PreflightRecovery.new(data_root: root),
        AgentCodingTool::AttemptRecovery.new(data_root: root),
        AgentCodingTool::GitHubDeliveryProvider.new,
        AgentCodingTool::ApplyHandoff.new(config: config),
        AgentCodingTool::WorktreeManager.new(root: root, record_path: File.join(root, "record.json")),
        AgentCodingTool::Launcher.new(data_root: root, source_root: ROOT, coordinator: nil),
        AgentCodingTool::Coordinator.new(**stores, repo_inspector: inspector, prompt_renderer: renderer,
          prompt_root: File.join(root, "prompts"))]
      services.each do |service|
        assert_instance_of AgentCodingTool::NativeCommandTransport, service.instance_variable_get(:@transport)
      end
      manager = AgentCodingTool::WorktreeManager.new(root: root, record_path: File.join(root, "record.json"),
        transport: ExpectedCommandTransport.new([]))
      assert_raises(ExpectedCommandTransport::UnknownRequest) do
        manager.create(task_id: "T", attempt: 1,
          task: { "repositories" => { "repo" => { "access" => "write" } } },
          snapshot: { "repo" => { "path" => root } })
      end
    end
  end

  # Public CLI -> Coordinator -> RepoInspector -> runner -> raw transport preserves
  # real ref parsing and freshness decisions. A wrong ref must fail this journey.
  def test_cli_status_continuous_journey_and_malformed_ref
    fixture do |root, _config|
      FileUtils.mkdir_p([File.join(root, "tasks"), File.join(root, "state")])
      File.write(File.join(root, "tasks/T.yml"), YAML.dump("id" => "T", "title" => "Transport journey",
        "repositories" => { "repo" => { "access" => "write" } }))
      File.write(File.join(root, "state/T.yml"), YAML.dump("id" => "T", "prepared_at" => "2026-10-31T00:00:00Z",
        "snapshot" => { "repo" => { "path" => root, "remote" => "origin", "branch" => "main",
          "remote_url" => REMOTE, "pushed_sha" => SHA, "local_head" => SHA, "local_dirty" => false } }))
      before = Dir.glob(File.join(root, "**/*")).select { |path| File.file?(path) }.to_h { |path| [path, File.binread(path)] }
      ["main", "wrong"].each do |branch|
        transport = ExpectedCommandTransport.new([
          request(["git", "ls-remote", "--exit-code", REMOTE, "refs/heads/main"], result("#{SHA}\trefs/heads/#{branch}\n"))
        ])
        out, err = StringIO.new, StringIO.new
        code = AgentCodingTool::CLI.run(%w[status T], root: ROOT, data_root: root, out: out, err: err, transport: transport)
        assert_equal(branch == "main" ? 0 : 2, code)
        if branch == "main"
          assert_includes out.string, "PREPARED"
          assert_empty err.string
        else
          assert_includes err.string, "malformed pushed ref"
        end
        assert transport.verify!
      end
      before.each { |path, bytes| assert_equal bytes, File.binread(path) }
    end
  end

  # Former checkpoint direct staged-diff and raw binary capture both use the seam.
  # A staged difference is still refused before disposable index mutation.
  def test_checkpoint_staged_refusal_and_raw_bytes
    fixture do |root, _config|
      transport = ExpectedCommandTransport.new([
        request(["git", "diff", "--cached", "--quiet", SHA], result("", "", 1), cwd: root),
        request(["git", "diff", "--binary"], result("\x00\xff\n".b), cwd: root, env: { "GIT_INDEX_FILE" => "/declared/index" })
      ])
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: root, transport: transport)
      error = assert_raises(AgentCodingTool::InvalidState) { checkpoint.send(:implementation, root, SHA) }
      assert_includes error.message, "staged-only"
      assert_equal "\x00\xff\n".b, checkpoint.send(:git!, root, "diff", "--binary", strip: false, env: { "GIT_INDEX_FILE" => "/declared/index" })
      assert transport.verify!
    end
  end

  # Delivery's deletion check and the provider's absent-ref lease use the same raw
  # seam. Missing deletion and rejected push still fail in real product logic.
  def test_delivery_deleted_blob_and_push_lease
    fixture do |root, _config|
      [1, 0].each do |blob_code|
        transport = ExpectedCommandTransport.new([
          request(["git", "rev-parse", "HEAD"], result("#{SHA}\n"), cwd: root),
          request(["git", "rev-parse", "HEAD^"], result("#{'b' * 40}\n"), cwd: root),
          request(["git", "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"], result, cwd: root),
          request(["git", "diff", "--name-only", "-z", "HEAD^", "HEAD"], result("gone\0"), cwd: root),
          request(["git", "cat-file", "-e", "HEAD:gone"], result("", "", blob_code), cwd: root)
        ])
        manager = AgentCodingTool::DeliveryManager.new(data_root: root, coordinator: nil, transport: transport)
        details = { "base_sha" => "b" * 40, "paths" => ["gone"], "manifest" => { "gone" => { "deleted" => true } } }
        if blob_code == 1
          assert manager.send(:verify_commit!, root, SHA, details)
        else
          assert_raises(AgentCodingTool::InvalidState) { manager.send(:verify_commit!, root, SHA, details) }
        end
        assert transport.verify!
      end
      [0, 1].each do |code|
        transport = ExpectedCommandTransport.new([request(["git", "-c", "core.hooksPath=/dev/null", "push",
          "--force-with-lease=refs/heads/topic:", "origin", "#{SHA}:refs/heads/topic"], result("", "lease rejected", code), cwd: root)])
        provider = AgentCodingTool::GitHubDeliveryProvider.new(transport: transport)
        if code.zero?
          provider.push(root, "origin", "topic", SHA)
        else
          assert_raises(AgentCodingTool::RepositoryError) { provider.push(root, "origin", "topic", SHA) }
        end
        assert transport.verify!
      end
    end
  end

  # ApplyHandoff retains ambient-Git refusal, stdin, environment and owned group;
  # only its workflow boundary converts a signal result into a shell exit code.
  def test_apply_request_and_signal_translation
    environment = { "GIT_TERMINAL_PROMPT" => "0", "GIT_PAGER" => "cat" }
    transport = ExpectedCommandTransport.new([
      request(["git", "apply"], result("\xff".b), cwd: "/repo", env: environment, input: "\x00\xfe".b, pgroup: true),
      request(["validator", "arg"], result("out", "err", signal: 15), cwd: "/repo", env: { "CUSTOM" => "1" }, pgroup: true)
    ])
    handoff = AgentCodingTool::ApplyHandoff.new(config: nil, transport: transport)
    assert_equal "\xff".b, handoff.send(:git!, { path: "/repo" }, "apply", input: "\x00\xfe".b)
    assert_equal ["out", "err", 143], handoff.send(:execute, ["validator", "arg"], cwd: "/repo", env: { "CUSTOM" => "1" })
    assert transport.verify!
    ENV["GIT_DIR"] = "/untrusted"
    assert_raises(AgentCodingTool::Error) { handoff.send(:execute, %w[git status], cwd: "/repo") }
  ensure
    ENV.delete("GIT_DIR")
  end

  # The apply replay binds every declared request field, including process group.
  # Mismatches, unknown options, ordering, omissions and reuse cannot cause effects.
  def test_apply_observation_exact_request_and_consumption
    record = { argv: %w[git apply], cwd: "/fixture",
      env: { "GIT_TERMINAL_PROMPT" => "0", "GIT_PAGER" => "cat" },
      input: "patch\x00\xff".b, pgroup: true, result: result("out\x00\xff".b, "err\x00\xfe".b, 23) }
    arguments = record.slice(:cwd, :env, :input, :pgroup)
    effects = []
    replay = ApplyHandoffObservations::Transport.new([record]) { |item| effects << item }
    [arguments.merge(cwd: "/wrong"), arguments.merge(env: {}),
     arguments.merge(input: "wrong"), arguments.merge(pgroup: false),
     arguments.merge(pgroup: nil)].each do |fields|
      assert_raises(GitContract::UnexpectedObservation) { replay.call(record.fetch(:argv), **fields) }
    end
    assert_raises(GitContract::UnexpectedObservation) { replay.call(%w[git diff], **arguments) }
    assert_raises(ArgumentError) { replay.call(record.fetch(:argv), **arguments.except(:pgroup)) }
    assert_raises(ArgumentError) { replay.call(record.fetch(:argv), **arguments, close_others: false) }
    assert_raises(GitContract::UnexpectedObservation) { replay.verify! }
    assert_empty effects
    assert_same record.fetch(:result), replay.call(record.fetch(:argv), **arguments)
    assert_equal [record], effects
    assert replay.verify!
    assert_raises(GitContract::UnexpectedObservation) { replay.call(record.fetch(:argv), **arguments) }
    assert_equal [record], effects

    other = record.merge(argv: %w[git status])
    ordered = ApplyHandoffObservations::Transport.new([record, other])
    assert_raises(GitContract::UnexpectedObservation) { ordered.call(other.fetch(:argv), **arguments) }
    assert_same record.fetch(:result), ordered.call(record.fetch(:argv), **arguments)
    assert_raises(GitContract::UnexpectedObservation) { ordered.verify! }
    assert_same other.fetch(:result), ordered.call(other.fetch(:argv), **arguments)
    assert ordered.verify!
    assert_raises(ArgumentError) do
      ApplyHandoffObservations::Transport.new([record.merge(result: ["", "", 0])])
    end
  end

  # The real apply workflow converts exit/signal facts only at its shell boundary.
  # Replay retains the original binary streams, CommandResult and nil signal success.
  def test_apply_observation_exit_and_signal_translation
    [result("out\x00\xff".b, "err\x00\xfe".b), result("out", "err", 23),
     result("out\x00\xff".b, "err\x00\xfe".b, signal: 15)].each do |response|
      record = { argv: %w[git apply], cwd: "/fixture",
        env: { "GIT_TERMINAL_PROMPT" => "0", "GIT_PAGER" => "cat" },
        input: "patch\x00\xff".b, pgroup: true, result: response }
      replay = ApplyHandoffObservations::Transport.new([record])
      raw = replay.call(record.fetch(:argv), **record.slice(:cwd, :env, :input, :pgroup))
      assert_same response, raw
      assert_nil raw.success? if response.signaled?
      assert replay.verify!
      workflow = ApplyHandoffObservations::Transport.new([record])
      handoff = AgentCodingTool::ApplyHandoff.new(config: nil, transport: workflow)
      assert_equal [response.stdout, response.stderr, response.shell_status],
        handoff.send(:execute, record.fetch(:argv), cwd: record.fetch(:cwd), input: record.fetch(:input))
      assert workflow.verify!
    end
  end

  # Launcher constructs its nested RepoInspector with the same transport. Raw
  # authority substitution fails; no policy/discovery method is replaced.
  def test_launcher_nested_authority_and_cleanup_status
    fixture do |root, _config|
      [REMOTE, "git@github.com:other/repo.git"].each do |remote|
        transport = ExpectedCommandTransport.new([
          request(["git", "rev-parse", "--git-dir"], result(".git\n"), cwd: root),
          request(["git", "remote", "get-url", "origin"], result("#{remote}\n"), cwd: root)
        ])
        launcher = AgentCodingTool::Launcher.new(data_root: root, source_root: ROOT, coordinator: nil, transport: transport)
        task = { "repositories" => { "repo" => { "access" => "write", "path" => root } } }
        state = { "snapshot" => { "repo" => { "remote_url" => REMOTE, "branch" => "main" } } }
        if remote == REMOTE
          launcher.send(:validate_authorities!, task, state)
        else
          assert_raises(AgentCodingTool::InvalidState) { launcher.send(:validate_authorities!, task, state) }
        end
        assert transport.verify!
      end
      transport = ExpectedCommandTransport.new([
        request(["git", "merge-base", "--is-ancestor", SHA, "HEAD"], result(signal: 15), cwd: root),
        request(["git", "status", "-z"], result("\xff\0".b), cwd: root)
      ])
      cleanup = AgentCodingTool::CleanupManager.new(data_root: root, transport: transport)
      assert_nil cleanup.send(:system_git, root, "merge-base", "--is-ancestor", SHA, "HEAD")
      assert_equal "\xff\0".b, cleanup.send(:git, root, "status", "-z")
      assert transport.verify!
    end
  end

  # Launcher's former direct symbolic-ref call still refuses detached workspaces,
  # after native-style identity/status parsing through the injected boundary.
  def test_launcher_symbolic_ref_refusal
    fixture do |root, _config|
      [0, 1].each do |code|
        transport = ExpectedCommandTransport.new([
          request(["git", "remote", "get-url", "origin"], result("#{REMOTE}\n"), cwd: root),
          request(["git", "rev-parse", "HEAD"], result("#{SHA}\n"), cwd: root),
          request(["git", "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"], result, cwd: root),
          request(["git", "symbolic-ref", "-q", "HEAD"], result("", "", code), cwd: root)
        ])
        launcher = AgentCodingTool::Launcher.new(data_root: root, source_root: ROOT, coordinator: nil, transport: transport)
        base = { "remote" => "origin", "remote_url" => REMOTE, "pushed_sha" => SHA }
        if code.zero?
          launcher.send(:verify_checkout!, root, base)
        else
          error = assert_raises(AgentCodingTool::InvalidState) { launcher.send(:verify_checkout!, root, base) }
          assert_includes error.message, "dedicated feature branch"
        end
        assert transport.verify!
      end
    end
  end

  # Closeout's formerly direct Git read preserves real porcelain parsing and dirty
  # refusal. The same raw failure must remain unreadable rather than clean.
  def test_recovery_raw_status_and_refusal
    fixture do |root, _config|
      [[result, nil], [result("?? extra\0"), "dirty worktree"], [result("", "unreadable", 1), "unreadable worktree"]].each do |response, message|
        transport = ExpectedCommandTransport.new([request(["git", "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored"], response, cwd: root)])
        recovery = AgentCodingTool::AttemptRecovery.new(data_root: root, transport: transport)
        inventory = { "entries" => [{ "path" => root }] }
        if message
          error = assert_raises(AgentCodingTool::InvalidState) { recovery.send(:verify_clean!, inventory) }
          assert_includes error.message, message
        else
          recovery.send(:verify_clean!, inventory)
        end
        assert transport.verify!
      end
    end
  end

  # Any new native effect needs an explicit audit; Git-capable nested constructors
  # must forward injection. A synthetic bypass and missing handoff trip the checks.
  def test_static_boundary_and_constructor_audit
    audit = CommandBoundaryAudit.scan(ROOT)
    allowlist = JSON.parse(File.binread(File.join(__dir__, "command_transport_native_calls.json")))
    assert_equal allowlist, audit.fetch("native")
    assert audit.fetch("constructors").length > 40
    audit.fetch("constructors").each do |row|
      assert_match(/transport:\s*(?:@transport|transport)\b/, row.fetch("source"), row.inspect)
    end
    fixture do |root, _config|
      FileUtils.mkdir_p([File.join(root, "lib"), File.join(root, "bin")])
      File.write(File.join(root, "bin/agent-coding-tool"), "# no effects\n")
      File.write(File.join(root, "lib/bypass.rb"), <<~RUBY)
        Open3.capture3("git", "status")
        Open3&.capture3("git", "status")
        fork
        Process.method(:spawn)
        WorktreeManager.new(root: root)
        AgentCodingTool::WorktreeManager.new(root: root)
      RUBY
      changed = CommandBoundaryAudit.scan(root)
      assert_equal 4, changed.fetch("native").length
      assert_equal 2, changed.fetch("constructors").length
      changed.fetch("constructors").each { |row| refute_match(/transport:/, row.fetch("source")) }
    end
  end
end

required = JSON.parse(File.binread(File.join(__dir__, "command_transport_required_cases.json")))
actual = CommandTransportVerifier.public_instance_methods.grep(/^test_/).map { |name| "CommandTransportVerifier##{name}" }
raise "command transport verifier inventory differs" unless actual.sort == required.sort
ENV["ACT_SUITE_INVOCATION"] = SecureRandom.uuid
ENV["ACT_SUITE_SELECTION"] = required.sort.join("\n")
ENV["ACT_SUITE_EVIDENCE"] = ENV["COMMAND_TRANSPORT_EVIDENCE"] || File.join(Dir.mktmpdir("command-transport-results-"), "results.json")
raise "command transport evidence already exists" if File.exist?(ENV.fetch("ACT_SUITE_EVIDENCE"))
require_relative "../suite_reporter"

Minitest.after_run do
  path = ENV["COMMAND_TRANSPORT_AUDIT"]
  File.write(path, JSON.pretty_generate("records" => NoGitExecution.audit,
    "independent_os_audit" => NoGitExecution.independent_audit) + "\n", mode: "wx") if path
  evidence = JSON.parse(File.binread(ENV.fetch("ACT_SUITE_EVIDENCE")))
  results = evidence.fetch("results")
  raise "command transport missing/failed/duplicate case evidence" unless
    results.map { |row| row.fetch("case") }.sort == required.sort &&
    results.all? { |row| row.fetch("status") == "pass" }
end
