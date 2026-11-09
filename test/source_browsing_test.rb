# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/source_fixture"
require "agent_coding_tool/share_controller"
require "minitest/mock"
require "stringio"

# Real file descriptors, synthetic canaries and durable session/release checks.
# Only external Git metadata is modeled; denied contents are never a Git oracle.
class SourceBrowsingTest < Minitest::Test
  Refused = AgentCodingTool::RunEvidenceReader::Refused

  # Creates a fresh private source/evidence admission and explicit Git inventory.
  def setup
    @temporary = File.realpath(Dir.mktmpdir("act-source-"))
    @code = File.join(@temporary, "code")
    @root = SourceFixture.repository(File.join(@code, "alpha"),
      { "lib/main.rb" => "RelatedSymbol\n" * 2000, "ignored.rb" => "IGNORED_CANARY" }, ignored: ["ignored.rb"])
    @data = File.join(@temporary, "data")
    FileUtils.mkdir_p(File.join(@data, "tasks"))
    File.write(File.join(@data, "tasks", "TASK.yml"), YAML.dump("id" => "TASK", "title" => "fixture", "goal" => "fixture"))
    @path = File.join(@temporary, "session")
    grant = { "schema" => "agent-coding-tool-task-sharing/v2", "approved" => true,
      "data_root" => @data, "session_path" => @path, "tasks" => [], "artifacts" => ["final"],
      "transport" => { "account" => "fixture", "workspace" => "personal", "endpoint" => "tunnel_fixture/main",
        "manager" => "task-sharing-v2", "audience" => "whole-workspace" }, "limits" => AgentCodingTool::EvidenceSession::LIMITS }
    grant_path = File.join(@temporary, "grant.json")
    File.write(grant_path, JSON.generate(grant), perm: 0o600)
    AgentCodingTool::EvidenceSession.start(@path, grant_path)
    @session = AgentCodingTool::EvidenceSession.new(@path)
    @session.sharing_ready
    @err = StringIO.new
    @adapter = AgentCodingTool::EvidenceAdapter.new(@session, err: @err)
  end

  # Removes only this test's disposable owned tree after every outcome.
  def teardown
    FileUtils.remove_entry(@temporary)
  end

  # Locally admits the fixture under a finite lease; returns the local receipt.
  def approve
    @session.share_source("alpha", code_root: @code, root: @root, seconds: 60)
  end

  # Calls the real MCP dispatcher. Returns decoded source results or a fixed
  # refusal, asserting that no private root or Git URL reaches the response.
  def source(arguments, success: true)
    response = @adapter.dispatch({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
      "params" => { "name" => "read_source", "arguments" => arguments } })
    assert_equal !success, response.dig("result", "isError"), response.inspect
    refute_includes JSON.generate(response), @temporary
    success ? JSON.parse(response.dig("result", "content", 0, "text")) : response
  end

  # Builds a default bounded source request, never a direct client filesystem read.
  def request(operation = "read", **fields)
    { "operation" => operation, "repository" => "alpha", "path" => "lib/main.rb" }.merge(fields.transform_keys(&:to_s))
  end

  # Source/task grants are separate and source bytes carry live digest/revision
  # facts. Changed files/index/lease generations refuse old noninitial chunks.
  def test_separate_grants_live_provenance_and_changed_chunks
    assert_empty source({ "operation" => "discover" }).fetch("repositories")
    @session.share_task("TASK", seconds: 60)
    source(request, success: false)
    approve
    assert_equal [{ "repository" => "alpha" }], source({ "operation" => "discover" })["repositories"]
    first = source(request)
    assert_equal "live_source", first["kind"]
    assert_equal "a" * 40, first.dig("git", "revision")
    assert_equal "matches_index", first["worktree"]
    assert_equal Digest::SHA256.file(File.join(@root, "lib/main.rb")).hexdigest, first["sha256"]
    assert_equal "truncated", first["status"]
    next_request = request(offset: first["next_offset"], version: first["version"])
    assert_equal "complete", source(next_request)["status"]
    source(next_request.reject { |key, _value| key == "version" }, success: false)
    File.write(File.join(@root, "lib/main.rb"), "RelatedSymbol changed\n" * 2000)
    source(next_request, success: false)
    assert_equal "modified_from_index", source(request)["worktree"]
    @session.share_source("alpha", revoke: true)
    source(request, success: false)
    assert_equal ["TASK"], @session.call({ "operation" => "discover" }).fetch("tasks").map { |task| task["task_id"] }
    approve
    @session.share_task("TASK", seconds: 60, revoke: true)
    assert_empty @session.call({ "operation" => "discover" }).fetch("tasks")
    source(request)
  end

  # Sensitive tracked/untracked content, Git admin, paths, symlinks, hardlinks,
  # special files and binary content fail at the actual read/list/search boundary.
  def test_denied_files_never_enter_source_results_or_audit
    denied = %w[.env .env.local .env.production .env.example .npmrc id_rsa server.key credentials.json .config/notify.yml .git/config]
    files = denied.to_h { |path| [path, "CANARY_#{path}"] }.merge("safe.rb" => "RelatedSymbol safe\n", "binary.rb" => "\x00CANARY_BINARY")
    SourceFixture.repository(@root, files)
    File.write(File.join(@root, "untracked.rb"), "CANARY_UNTRACKED")
    outside = File.join(@temporary, "outside")
    File.write(outside, "CANARY_OUTSIDE")
    index_path = File.join(@root, ".git/index")
    index = JSON.parse(File.read(index_path))
    %w[link.rb pipe.rb hard.rb].each { |path| index[path] = index.fetch("safe.rb") }
    File.write(index_path, JSON.generate(index))
    File.symlink(outside, File.join(@root, "link.rb"))
    File.mkfifo(File.join(@root, "pipe.rb"))
    File.link(outside, File.join(@root, "hard.rb"))
    approve
    listed = source(request("list", path: ""))
    assert_equal %w[binary.rb safe.rb], listed.fetch("entries").map { |entry| entry["path"] }.sort
    assert_empty source(request("search", path: "", query: "CANARY"))["matches"]
    (denied + %w[untracked.rb link.rb pipe.rb hard.rb binary.rb ../outside /etc/passwd .git .git/index]).each do |path|
      source(request(path: path), success: false)
    end
    source(request(repository: "sibling"), success: false)
    source(request("search", query: ".*", root: @root), success: false)
    source(request("search", query: "CANARY", path: ".config"), success: false)
    refute_includes @err.string, "CANARY"
    @session.activity({ "operation" => "source_read", "path" => "CANARY" }, nil, released: 0, result: "refused")
    audit = File.read(File.join(@path, "activity.jsonl"))
    refute_includes audit, "CANARY"
    refute_includes audit, @temporary
    assert_raises(Refused) { @session.share_source("config", code_root: @code, root: File.join(@code, ".config")) }
    assert_raises(Refused) { @session.share_source("whole", code_root: @code, root: @code) }
  end

  # Revocation/expiry/stop and budget checks occur after dispatch, immediately
  # before nonblocking output, including already-started reads and discoveries.
  def test_release_rechecks_lease_generation_expiry_and_budgets
    approve
    first = @session.source_call(request)
    release = first.fetch("_release")
    assert_equal :ok, @session.release(release) { :ok }
    @session.share_source("alpha", revoke: true)
    assert_raises(Refused) { @session.release(release) { flunk "revoked bytes" } }
    approve
    assert_raises(Refused) { @session.release(release) { flunk "old grant bytes" } }
    source(request(offset: 10, version: first["version"]), success: false)
    release = @session.source_call(request).fetch("_release")
    future = Time.now + 61
    Time.stub(:now, future) do
      assert_raises(Refused) { @session.release(release) { flunk "expired bytes" } }
    end
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 61
    Process.stub(:clock_gettime, ->(*) { clock }) do
      assert_raises(Refused) { @session.release(release) { flunk "monotonic expired bytes" } }
    end
    @session.transaction { |state| state["decoded_bytes"] = state.dig("grant", "limits", "decoded_bytes") }
    assert_raises(Refused) { @session.charge(wire: 1, decoded: 1) }
    @session.stop
    source(request, success: false)
    assert_raises(Refused) { @session.release(release) { flunk "stopped bytes" } }
  end

  # Directory entry churn preserves descriptor identity, while ancestor swaps
  # and in-place file changes still refuse before returning source bytes.
  def test_ancestor_swap_and_in_place_change_fail_closed
    approve
    # Model changing directory nlink between adjacent fstats, independent of
    # host timing and filesystem-specific directory link-count conventions.
    identity = AgentCodingTool::SourceFiles.method(:identity)
    ancestor = File.stat(@temporary)
    observations = 0
    changing_links = lambda do |stat|
      if stat.directory? && [stat.dev, stat.ino] == [ancestor.dev, ancestor.ino]
        observations += 1
        links = stat.nlink + observations
        stat.define_singleton_method(:nlink) { links }
      end
      identity.call(stat)
    end
    AgentCodingTool::SourceFiles.stub(:identity, changing_links) do
      assert_equal "matches_index", source(request).fetch("worktree")
    end
    assert_operator observations, :>=, 2

    original = AgentCodingTool::SourceFiles.method(:openat)
    switched = false
    outside = File.join(@temporary, "outside")
    FileUtils.mkdir_p(outside)
    File.write(File.join(outside, "main.rb"), "CANARY_RACE")
    swap = lambda do |descriptor, name, flags|
      result = original.call(descriptor, name, flags)
      if name == "lib" && !switched
        switched = true
        File.rename(File.join(@root, "lib"), File.join(@root, "saved"))
        File.symlink(outside, File.join(@root, "lib"))
      end
      result
    end
    AgentCodingTool::SourceFiles.stub(:openat, swap) { source(request, success: false) }
    assert switched
    File.unlink(File.join(@root, "lib"))
    File.rename(File.join(@root, "saved"), File.join(@root, "lib"))
    before = @session.source_call(request)
    File.write(File.join(@root, "lib/main.rb"), "changed after dispatch")
    assert_raises(Refused) { @session.release(before.fetch("_release")) { flunk "changed bytes" } }
    source(request)
  end

  # Listing/search/read bounds report continuation or refusal. Ignored files are
  # absent even when tracked. Regex-looking queries are literal and never execute.
  def test_bounded_listing_search_and_large_binary_reads
    files = 300.times.to_h { |index| ["f#{index.to_s.rjust(3, '0')}.rb", "RelatedSymbol\n"] }
    files["large.rb"] = "z" * (AgentCodingTool::SourceReader::FILE_LIMIT + 1)
    files["ignored.rb"] = "IGNORED_CANARY"
    SourceFixture.repository(@root, files, ignored: ["ignored.rb"])
    approve
    page = source(request("list", path: ""))
    assert_equal 64, page["entries"].length
    assert page["truncated"]
    assert_equal 64, page["next_offset"]
    found = source(request("search", path: "", query: "RelatedSymbol"))
    assert_equal 32, found["matches"].length
    assert found["truncated"]
    assert_equal 32, found["next_offset"]
    found = source(request("search", path: "", query: "CANARY"))
    assert_empty found["matches"]
    assert found["truncated"]
    assert_operator found["scanned_files"], :<=, 256
    source(request(path: "large.rb"), success: false)
    source(request(path: "ignored.rb"), success: false)
    assert_empty source(request("search", path: "", query: ".*"))["matches"]
  end

  # Exercises production pipe draining and fixed Git argv at its process boundary.
  # Files stand in only for child streams/status; no native execution is enabled.
  def test_git_transport_bounds_bytes_deadline_and_query_authority
    root = File.join(@temporary, "not-a-source-fixture")
    Dir.mkdir(root)
    output_path, error_path = %w[stdout stderr].map { |name| File.join(@temporary, name) }
    File.write(error_path, "private diagnostic never returned")
    status = Struct.new(:success?).new(true)
    waiter = Object.new
    waiter.define_singleton_method(:join) { |*| self }
    waiter.define_singleton_method(:value) { status }
    result = nil
    popen = lambda do |environment, *argv, **options, &block|
      assert_equal "/usr/bin/git", argv.first
      assert_equal %w[rev-parse HEAD], argv.last(2)
      assert_includes argv, "core.fsmonitor=false"
      assert_equal "/dev/null", environment["GIT_CONFIG_GLOBAL"]
      assert_equal({ chdir: root, unsetenv_others: true }, options)
      File.open(output_path, "rb") do |output|
        File.open(error_path, "rb") { |error| block.call(StringIO.new, output, error, waiter) }
      end
    end
    git = AgentCodingTool::SourceGit.new
    Open3.stub(:popen3, popen) do
      File.write(output_path, "a" * 40 + "\n")
      result = git.call(root, %w[rev-parse HEAD], deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1)
      assert_equal "a" * 40 + "\n", result
      File.write(output_path, "x" * (AgentCodingTool::SourceGit::LIMIT + 1))
      assert_raises(Refused) { git.call(root, %w[rev-parse HEAD], deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1) }
      assert_raises(Refused) { git.call(root, %w[rev-parse HEAD], deadline: 0) }
      assert_raises(Refused) { git.call(root, %w[status], deadline: 0) }
    end
    refute_includes result, "private diagnostic"
  end

  # Local settings/active-session audience mismatch cannot edit either scope.
  # Remote fields likewise cannot masquerade as local grant or audience consent.
  def test_audience_binding_and_remote_grant_fields_refuse
    client = File.join(@temporary, "fixture-client")
    File.write(client, "unused fixture", perm: 0o700)
    env = File.join(@temporary, ".env")
    File.write(env, "unused", perm: 0o600)
    runtime = File.join(@temporary, "runtime")
    Dir.mkdir(runtime, 0o700)
    controller = AgentCodingTool::ShareController.new(@data, out: StringIO.new, err: StringIO.new)
    controller.setup({ "env-file" => env, "client" => client, "runtime-dir" => runtime,
      "account" => "different-audience", "workspace" => "personal", "endpoint" => "tunnel_fixture/main" })
    sharing = "#{@data}-sharing"
    session_path = File.join(sharing, "session-#{'b' * 32}")
    File.rename(@path, session_path)
    @path = session_path
    # Bind this copied fixture admission to its actual new local path, preserving
    # the original audience; the settings comparison must still reject it.
    state_path = File.join(@path, "state.json")
    state = JSON.parse(File.read(state_path))
    state["grant"]["session_path"] = @path
    state["grant_sha256"] = Digest::SHA256.hexdigest(JSON.generate(state["grant"]))
    File.write(state_path, JSON.generate(state))
    File.write(File.join(sharing, "active.json"), JSON.generate("session" => @path), perm: 0o600)
    assert_raises(Refused) { controller.source("alpha", code_root: @code, root: @root) }
    assert_raises(Refused) { controller.control("status") }
    @session = AgentCodingTool::EvidenceSession.new(@path)
    @adapter = AgentCodingTool::EvidenceAdapter.new(@session, err: @err)
    source(request(root: @root, approved: true), success: false)
    source(request(operation: "grant", audience: "personal"), success: false)
  end

  # Actual adapter framing/output accounts source bytes and rechecks revocation.
  # Real anonymous pipes retain the full stdio/session boundary without a host
  # socket permission; this complements rather than replaces the tunnel journey.
  def test_adapter_stream_accounts_source_bytes_and_denies_next_chunk
    approve
    server_input, client_input = IO.pipe
    client_output, server_output = IO.pipe
    serving = Thread.new { @adapter.serve(server_input, server_output) }
    exchange = lambda do |arguments|
      client_input.write(JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
        "params" => { "name" => "read_source", "arguments" => arguments }) + "\n")
      client_input.flush
      assert IO.select([client_output], [], [], 2), "bounded stdio response missing"
      JSON.parse(client_output.gets).fetch("result")
    end
    before = @session.status(wait: 1)
    result = exchange.call(request(length: 64))
    refute result.fetch("isError")
    first = JSON.parse(result.dig("content", 0, "text"))
    expected = 64 + JSON.generate(first.reject { |key, _value| key == "data" }).bytesize
    assert_equal expected, @session.status(wait: 1)["decoded_bytes"] - before["decoded_bytes"]
    @session.share_source("alpha", revoke: true)
    assert exchange.call(request(offset: 64, version: first["version"])).fetch("isError")
    approve
    @session.transaction { |state| state["decoded_bytes"] = state.dig("grant", "limits", "decoded_bytes") }
    client_input.write(JSON.generate("jsonrpc" => "2.0", "id" => 2, "method" => "tools/call",
      "params" => { "name" => "read_source", "arguments" => request }) + "\n")
    client_input.flush
    assert serving.join(2), "exhausted adapter did not close"
    server_output.close
    assert_empty client_output.read
  ensure
    client_input&.close unless client_input&.closed?
    serving&.join(2)
    [server_input, client_output, server_output].compact.each { |stream| stream.close unless stream.closed? }
  end

  # Public local CLI parsing accepts only finite explicit source consent. An
  # isolated controller records calls; invalid fields/durations cause no mutation.
  def test_public_source_consent_arguments_precede_mutation
    calls = []
    controller = Object.new
    controller.define_singleton_method(:source) { |repository, **options| calls << [repository, options]; {} }
    run = ->(arguments) { AgentCodingTool::CLI.run(["share", "source", *arguments], data_root: @data, out: StringIO.new, err: StringIO.new) }
    AgentCodingTool::ShareController.stub(:new, controller) do
      assert_equal 0, run.call(["grant", "alpha", "--code-root", @code, "--root", @root])
      assert_equal 0, run.call(%w[revoke alpha])
      [[], %w[grant alpha], %w[revoke alpha --min 1], ["grant", "alpha", "--code-root", @code, "--root", @root, "--min", "61"],
        ["grant", "alpha", "--code-root", @code, "--root", @root, "--approved", "true"]].each do |arguments|
        assert_equal 2, run.call(arguments)
      end
    end
    assert_equal 2, calls.length
    assert_equal ["alpha", { code_root: @code, root: @root, minutes: 30, revoke: false }], calls.first
    assert calls.last.last[:revoke]
  end
  # Ordinary v3 source output works beyond former total and non-ZIP byte caps;
  # production framing still charges exact input/output and source metadata.
  def test_v3_source_frames_beyond_legacy_byte_caps
    grant = JSON.parse(File.binread(File.join(@temporary, "grant.json")))
    @path = File.join(@temporary, "v3-session")
    grant.merge!("schema" => "agent-coding-tool-task-sharing/v3", "session_path" => @path,
      "limits" => AgentCodingTool::EvidenceSession::CURRENT_SHARING_LIMITS)
    grant_path = File.join(@temporary, "v3-grant.json")
    File.write(grant_path, JSON.generate(grant), perm: 0o600)
    AgentCodingTool::EvidenceSession.start(@path, grant_path)
    @session = AgentCodingTool::EvidenceSession.new(@path)
    @session.sharing_ready
    approve
    @session.charge(wire: 167772161, decoded: 104857601)
    before = @session.status
    incoming, sender = IO.pipe
    receiver, outgoing = IO.pipe
    server = Thread.new { AgentCodingTool::EvidenceAdapter.new(@session, err: StringIO.new).serve(incoming, outgoing) }
    frame = JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
      "params" => { "name" => "read_source", "arguments" => request(length: 64) }) + "\n"
    sender.write(frame)
    assert IO.select([receiver], nil, nil, 2)
    received = receiver.gets
    result = JSON.parse(received).fetch("result")
    refute result.fetch("isError")
    evidence = JSON.parse(result.dig("content", 0, "text"))
    assert_equal File.binread(File.join(@root, "lib/main.rb"), 64), evidence.fetch("data").unpack1("m0")
    sender.close
    assert server.join(2)
    after = @session.status
    assert_equal frame.bytesize + received.bytesize, after["wire_bytes"] - before["wire_bytes"]
    assert_equal 64 + JSON.generate(evidence.reject { |key, _| key == "data" }).bytesize,
      after["decoded_bytes"] - before["decoded_bytes"]
    assert_equal "active", after["status"]
    assert_equal "telemetry", after["byte_policy"]
  ensure
    sender&.close unless sender&.closed?
    server&.join(2)
    [incoming, receiver, outgoing].compact.each { |io| io.close unless io.closed? }
  end

end
