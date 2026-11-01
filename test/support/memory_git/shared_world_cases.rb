# frozen_string_literal: true

require_relative "shared_adapter_cases"

# Public cold entry points, wire rejection, lifetime and descendant contracts.
class SharedWorldVerifier < Minitest::Test
  include TestHelpers

  # Short exclusive private roots fit Darwin's sockaddr_un within this attempt's
  # long retained TMPDIR. Never writes a socket in a shared fallback directory.
  def setup
    32.times do
      @root = File.join(File.realpath(ENV.fetch("TMPDIR")), SecureRandom.hex(1))
      begin
        Dir.mkdir(@root, 0o700)
        break
      rescue Errno::EEXIST
        @root = nil
      end
    end
    raise "no private socket root" unless @root
    @world = MemoryGit::PatchWorld.new(root: @root)
    @repo, @remote = memory_repository(@world, path: "#{@root}/repo", remote: "#{@root}/upstream")
    @data = File.join(@root, "data")
    FileUtils.mkdir_p(File.join(@data, "tasks"))
    File.write(File.join(@data, "config.yml"), YAML.dump("repo_root" => @root, "worktree_root" => File.join(@root, "workers")))
    write_task(@data, id: "T", repositories: { "repo" => { "path" => @repo.path, "access" => "write" } })
  end

  # Closes only the owned broker, verifies faults and removes case files. Failed
  # worker-level logs/source evidence live outside this disposable case root.
  def teardown
    @broker&.close
    @world.verify!
  ensure
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # Starts one leased owner thread only when a case asserts a cold boundary.
  # Returns broker; startup time and lifetime are retained independently of calls.
  def broker(**bounds)
    @broker ||= MemoryGit::Broker.new(world: @world, directory: @root, case_id: name, **bounds).tap do |owner|
      SharedEvidence.startups << { "case" => name, "seconds" => owner.startup_seconds, "processes" => 0 }
    end
  end

  # Runs actual public parsing in-process with new streams and explicit transport.
  # Returns code/bytes; no CLI decision or filesystem method is stubbed.
  def cli(*arguments, transport: @world)
    out, err = StringIO.new, StringIO.new
    code = AgentCodingTool::CLI.run(arguments, root: @root, data_root: @data, out: out, err: err,
      transport: MemoryGit::Session::Transport.new(transport))
    [code, out.string, err.string]
  end

  # Executes bin/agent-coding-tool in a fresh interpreter after exact preloads.
  # Status remains a real reaped Process::Status with propagated binary streams.
  def cold(*arguments, endpoint: broker.endpoint)
    ChildProcesses.capture("cold_cli", arguments: arguments,
      environment: { "AGENT_CODING_TOOL_DATA_DIR" => @data, "TMPDIR" => @root }, endpoint: endpoint)
  end

  # Independent physical candidate and remote transition, through command-level
  # serialization. The parent never mutates a running broker's authority directly.
  def advance_remote(transport, checkout)
    File.binwrite(File.join(checkout.path, "file.txt"), "upstream\n")
    [["add", "--", "file.txt"], ["commit", "-m", "upstream"], ["push", "origin", "HEAD:refs/heads/main"]].each do |arguments|
      result = transport.call(["git", *arguments], cwd: checkout.path)
      assert result.success?, result.stderr
    end
    transport.call(%w[git rev-parse HEAD], cwd: checkout.path).stdout.strip
  end

  # Repeated fresh public invocations use direct calls: zero IPC or process starts.
  # Remote movement still changes real product stale/refusal decisions.
  def test_in_process_commands_have_no_broker_or_process_startup
    before = NoGitExecution.audit
    assert_equal 0, cli("prepare", "T").first
    12.times { assert_includes cli("status", "T")[1], "PREPARED" }
    assert_nil @broker
    assert_equal before, NoGitExecution.audit
    assert_empty Dir.glob(File.join(@root, "*.sock"))
    assert_equal @repo.head, YAML.safe_load_file(File.join(@data, "state/T.yml")).fetch("snapshot").fetch("repo").fetch("pushed_sha")
  end

  # Whole journey: cold public prepare -> changed remote -> cold stale refusal ->
  # reprepare/start -> cold checkpoint export of a parent-written candidate.
  # Durable files and parent reads prove both handoffs, not just child exit zero.
  def test_cold_public_cli_shares_remote_candidate_and_durable_state
    updater = @world.copy(@repo, path: "updater")
    owner = broker
    out, err, status = cold("prepare", "T")
    assert status.success?, out + err
    state_path = File.join(@data, "state/T.yml")
    prepared = File.binread(state_path)
    moved = advance_remote(owner, updater)
    refute_equal @repo.head, moved
    assert_includes cold("status", "T").first, "STALE"
    _out, err, status = cold("start", "T")
    assert_equal 2, status.exitstatus
    assert_includes err, "T: start blocked: STALE pushed branch changed: repo"
    assert_equal prepared, File.binread(state_path)
    assert cold("prepare", "T").last.success?
    assert cold("start", "T").last.success?
    assert_includes cli("status", "T", transport: owner)[1], "IN_FLIGHT"
    assert_equal moved, YAML.safe_load_file(state_path).fetch("snapshot").fetch("repo").fetch("pushed_sha")
    File.binwrite(File.join(updater.path, "file.txt"), "candidate\n")
    artifact = File.join(@root, "candidate.patch")
    output, error, status = cold("checkpoint", "export", "T", "--workspace", updater.path, "--base", moved, "--artifact", artifact)
    assert status.success?, output + error
    assert_equal "canonical_format_checked", JSON.parse(output).fetch("status")
    assert_includes File.binread(artifact), "+candidate\n"
    assert_equal "candidate\n", File.binread(File.join(updater.path, "file.txt"))
    assert_equal "upstream\n", owner.call(["git", "show", "HEAD:file.txt"], cwd: updater.path).stdout
    assert_empty owner.call(%w[git diff --cached --name-only], cwd: updater.path).stdout
    assert_equal 1, SharedEvidence.startups.count { |row| row["case"] == name }
  end

  # A missing preload and a copied mutable snapshot cannot satisfy sharing.
  # Restoring the real capability observes the later authoritative remote ref.
  def test_omitted_handoff_and_stale_snapshot_are_detected
    snapshot = @world.copy(@repo, path: "snapshot")
    copied_remote = @world.remote(url: "snapshot-only", from: snapshot)
    @world.connect(snapshot, copied_remote)
    updater = @world.copy(@repo, path: "updater")
    owner = broker
    moved = advance_remote(owner, updater)
    stale = owner.call(%w[git ls-remote --exit-code origin refs/heads/main], cwd: snapshot.path)
    refute_includes stale.stdout, moved
    assert_includes owner.call(%w[git ls-remote --exit-code origin refs/heads/main], cwd: @repo.path).stdout, moved
    _out, error, status = ChildProcesses.capture("cold_cli", arguments: %w[status T])
    refute status.success?
    assert_includes error, "missing shared-world preload"
    bad = owner.endpoint.merge("token" => "stale-token")
    _out, error, status = cold("prepare", "T", endpoint: bad)
    refute status.success?
    assert_includes error, "broker refused"
    refute File.exist?(File.join(@data, "state/T.yml"))
    assert cold("prepare", "T").last.success?
  end

  # Binary output/input and signal facts survive data-only framing. Wrong shapes,
  # unsafe types, oversized frames and malformed data cannot become commands.
  def test_binary_wire_results_and_strict_envelopes
    env = { "GIT_TERMINAL_PROMPT" => "0", "GIT_PAGER" => "cat" }
    bytes = "\0\xff\r\n".b
    assert_equal [["git", "show"], { env: env, input: bytes, pgroup: true }],
      MemoryGit::Wire.decode(MemoryGit::Wire.encode([["git", "show"], { env: env, input: bytes, pgroup: true }]))
    assert_raises(MemoryGit::Mismatch) { MemoryGit::Wire.encode(Object.new) }
    assert_raises(MemoryGit::Mismatch) { MemoryGit::Wire.decode({ "symbol" => "exec" }) }
    assert_raises(MemoryGit::Mismatch) { MemoryGit::Wire.decode({ "bytes" => "!!!", "encoding" => "ASCII-8BIT" }) }
    assert_raises(MemoryGit::Mismatch) { MemoryGit::Wire.encode([[[[[[[[[[[[[[[[[["too deep"]]]]]]]]]]]]]]]]]]) }
    binary = @world.repository(path: "binary", template: MemoryGit::Template.files({ "blob" => bytes }))
    @world.fault(argv: %w[git status --porcelain=v1 -z --untracked-files=all], cwd: @repo.path,
      phase: :after, result: AgentCodingTool::CommandResult.new(stdout: bytes, stderr: "\xfe".b, termsig: 15))
    response = broker.call(%w[git show HEAD:blob], cwd: binary.path)
    assert_equal bytes, response.stdout
    assert_equal Encoding::BINARY, response.stdout.encoding
    response = broker.call(%w[git status --porcelain=v1 -z --untracked-files=all], cwd: @repo.path)
    assert_equal [bytes, "\xfe".b, nil, 15, nil], [response.stdout, response.stderr, response.exitstatus, response.termsig, response.success?]
  end

  # Bad capabilities/IDs/operations/reset/frames refuse before effects; the owner
  # remains usable. Duplicate mutation IDs are consumed even after completion.
  def test_stale_wrong_case_duplicate_unknown_and_malformed_requests_refuse
    owner = broker
    message = { "version" => 1, "case" => name, "token" => owner.endpoint.fetch("token"),
      "id" => "#{SecureRandom.uuid}:1", "operation" => "command",
      "request" => MemoryGit::Wire.encode([%w[git rev-parse HEAD], { cwd: @repo.path }]) }
    send_request = lambda do |request|
      UNIXSocket.open(owner.endpoint.fetch("path")) do |socket|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        MemoryGit::Wire.write(socket, request, deadline)
        MemoryGit::Wire.read(socket, deadline)
      end
    end
    [{ "token" => "old" }, { "case" => "other" }, { "operation" => "reset" }, { "operation" => "exec" },
     { "request" => "not-tagged" }].each do |change|
      assert send_request.call(message.merge(change)).key?("error")
    end
    message["id"] = "#{SecureRandom.uuid}:2"
    assert send_request.call(message).key?("result")
    assert send_request.call(message).key?("error")
    assert_raises(MemoryGit::Mismatch) { owner.reset(@world) }
    UNIXSocket.open(owner.endpoint.fetch("path")) { |socket| socket.write([MemoryGit::Wire::LIMIT + 1].pack("N")) }
    assert_equal @repo.head + "\n", owner.call(%w[git rev-parse HEAD], cwd: @repo.path).stdout
    assert_raises(MemoryGit::Mismatch) { owner.call(%w[git unregistered], cwd: @repo.path) }
    assert_equal 2, @world.requests.count { |request| request.first == %w[git rev-parse HEAD] && request.last[:cwd] == @repo.path }
  end

  # A timed-out after-effect mutation is inspectable and never replayed; client
  # failure is sticky. Owner/socket death and fresh cases have distinct authority.
  def test_timeout_death_cleanup_and_case_isolation
    @world.fault(argv: %w[git add -- file.txt], cwd: @repo.path, phase: :after_effect, effect: :stage) { sleep 0.15 }
    File.binwrite(File.join(@repo.path, "file.txt"), "partial\n")
    owner = broker(seconds: 0.05)
    client = MemoryGit::Client.new(owner.endpoint)
    assert_raises(MemoryGit::Mismatch) { client.call(%w[git add -- file.txt], cwd: @repo.path) }
    assert_raises(MemoryGit::Mismatch) { client.call(%w[git add -- file.txt], cwd: @repo.path) }
    # The lease interrupts the waiting after-effect hook, leaving staged bytes.
    assert_equal "partial\n", @repo.index.fetch("file.txt").blob.bytes
    assert_equal 1, @world.requests.count { |request| request.first == %w[git add -- file.txt] }
    path = owner.endpoint.fetch("path")
    owner.close
    refute File.exist?(path)
    assert_raises(MemoryGit::Mismatch) { MemoryGit::Client.new(owner.endpoint).call(%w[git status], cwd: @repo.path) }
    assert_equal "partial\n", File.binread(File.join(@repo.path, "file.txt"))
    fresh = MemoryGit::PatchWorld.new(root: @root)
    checkout, = memory_repository(fresh, path: "#{@root}/fresh", remote: "fresh-upstream")
    assert_equal "base\n", checkout.index.fetch("file.txt").blob.bytes
    assert_empty fresh.requests
    assert fresh.verify!
  end

  # Real unrelated sentinel survives broker shutdown and timeout. Ready/release,
  # group identity and native wait status prove cleanup only owns its resources.
  def test_unrelated_sentinel_locks_and_signal_status_survive_cleanup
    release_read, release_write = IO.pipe
    ready_read, ready_write = IO.pipe
    null = File.open(File::NULL, "w")
    permit = ChildProcesses.permit("manual_worker", arguments: [File.join(@root, "sentinel"), "5"], options: { pgroup: true })
    pid = NoGitExecution.with_permit(permit) do
      Process.spawn(permit.environment, *permit.argv, **permit.options, in: release_read, out: ready_write, err: null)
    end
    release_read.close
    ready_write.close
    assert_equal "ready\n", Timeout.timeout(2) { ready_read.gets }
    File.open(File.join(@root, "lock"), "w") do |first|
      first.flock(File::LOCK_EX)
      File.open(first.path, "w") { |second| refute second.flock(File::LOCK_EX | File::LOCK_NB) }
      broker.close
      assert_nil Process.waitpid2(pid, Process::WNOHANG)
      assert_equal "external work", File.binread(File.join(@root, "sentinel"))
    end
    release_write.write("R")
    release_write.close
    _reaped, status = Timeout.timeout(2) { Process.waitpid2(pid) }
    pid = nil
    assert status.success?
    bytes = "\0\xff\r\n".b
    out, err, status = ChildProcesses.capture("process_probe", arguments: ["binary"], input: bytes)
    assert_equal [bytes.reverse, "\0\xfe".b, 7], [out, err, status.exitstatus]
    _out, _err, status = ChildProcesses.capture("process_probe", arguments: ["signal"])
    assert status.signaled?
    assert_equal Signal.list.fetch("TERM"), status.termsig
    assert_nil status.success?
  ensure
    if pid
      Process.kill("KILL", -pid) rescue Errno::ESRCH
      Process.waitpid(pid) rescue Errno::ECHILD
    end
    [release_read, release_write, ready_read, ready_write, null].compact.each { |pipe| pipe.close unless pipe.closed? }
  end

  # Guard stripping/wrappers still fail inside genuine approved Ruby descendants.
  # Dropping/replacing the exact parent permit bootstrap fails before spawn too.
  def test_descendant_guard_cannot_be_stripped_or_replaced
    %w[strip wrapper].each do |mode|
      _out, err, status = ChildProcesses.capture("process_probe", arguments: [mode])
      refute status.success?
      assert_includes err, "zero-Git boundary prohibits"
    end
    approval = ChildProcesses.permit("status", arguments: ["0"])
    assert_raises(NoGitExecution::ProhibitedExecution) do
      NoGitExecution.with_permit(approval) { Process.spawn(approval.environment.merge("RUBYOPT" => nil), *approval.argv) }
    end
    assert_raises(NoGitExecution::ProhibitedExecution) do
      NoGitExecution.with_permit(approval) { Process.spawn(approval.environment, *approval.argv.map { |part| part == NoGitExecution::GUARD ? __FILE__ : part }) }
    end
  end

  # Existing all-production coverage observes the cold public entry and retains
  # genuine PID/results; lost active evidence is a failure, never zero-filled.
  def test_coverage_preload_and_active_child_evidence_are_preserved
    previous = ENV["ACT_COVERAGE_CONTEXT"]
    source_root = File.expand_path("../../..", __dir__)
    directory = File.join(@root, "coverage")
    Dir.mkdir(directory, 0o700)
    layout = previous ? JSON.parse(File.binread(previous)).fetch("layout") : FeedbackCoverage.layout(source_root)
    context = { "root" => source_root, "directory" => directory, "invocation" => SecureRandom.uuid,
      "selection" => name, "stage" => "focused-shared", "sources" => FeedbackCoverage.sources(source_root), "layout" => layout }
    context_path = File.join(@root, "context.json")
    File.write(context_path, JSON.generate(context))
    ENV["ACT_COVERAGE_CONTEXT"] = context_path
    out, err, status = cold("prepare", "T")
    assert status.success?, out + err
    observed = FeedbackCoverage.collect(context)
    assert_equal context.fetch("sources").keys.sort, observed.keys.sort
    assert observed.fetch("bin/agent-coding-tool").values.any?(&:positive?)
    assert observed.fetch("lib/agent_coding_tool/cli.rb").values.any?(&:positive?)
    result = Dir.glob(File.join(directory, "*.json")).fetch(0)
    raw = JSON.parse(File.binread(result))
    assert_equal status.pid, raw.fetch("pid")
    raw.fetch("files").delete("lib/agent_coding_tool/cli.rb")
    File.write(result, JSON.generate(raw))
    assert_raises(RuntimeError) { FeedbackCoverage.collect(context) }
    approval = ChildProcesses.permit("status", arguments: ["0"])
    assert_raises(NoGitExecution::ProhibitedExecution) do
      NoGitExecution.with_permit(approval) do
        Process.spawn(approval.environment.merge("ACT_COVERAGE_CONTEXT" => nil), *approval.argv)
      end
    end
  ensure
    ENV["ACT_COVERAGE_CONTEXT"] = previous
  end
end
