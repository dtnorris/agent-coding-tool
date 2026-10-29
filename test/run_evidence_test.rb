# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "timeout"

# Deterministic ACT records stand in only for the external worker/checkpoint
# producer. All selection, transport, accounting and byte reading are real.
class RunEvidenceTest < Minitest::Test
  # Builds canonical private fixture paths and one completed managed run.
  def setup
    @temporary = File.realpath(Dir.mktmpdir("act-evidence-"))
    @data = File.join(@temporary, "data")
    FileUtils.mkdir_p(@data, mode: 0o700)
    @session_path = File.join(@temporary, "session")
    @grant_path = File.join(@temporary, "grant.json")
    @grant = { "schema" => "agent-coding-tool-evidence-grant/v1", "approved" => true,
      "data_root" => @data, "session_path" => @session_path, "tasks" => ["FIXTURE"],
      "artifacts" => AgentCodingTool::RunEvidenceReader::ARTIFACTS,
      "transport" => { "account" => "fixture-account", "workspace" => "fixture-workspace", "endpoint" => "offline-pipes",
        "audience" => "whole-workspace", "manager" => "fixture-manager" },
      "limits" => { "seconds" => 60, "requests" => 512, "wire_bytes" => 8_388_608, "decoded_bytes" => 4_194_304 } }
    write_json(@grant_path, @grant)
    @first = write_run(1)
    AgentCodingTool::EvidenceSession.start(@session_path, @grant_path)
    @session = AgentCodingTool::EvidenceSession.new(@session_path)
    @adapter = AgentCodingTool::EvidenceAdapter.new(@session, err: StringIO.new)
  end

  # Removes only this test's disposable records, never real ACT evidence.
  def teardown
    FileUtils.remove_entry(@temporary)
  end

  # Writes private deterministic JSON; returns the path for fixture construction.
  def write_json(path, value)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, JSON.generate(value), mode: "w", perm: 0o600)
    path
  end

  # Creates one distinct managed run plus optional current checkpoint/failed gate.
  # Returns exact public identity, run path and original bytes for host oracles.
  def write_run(number, checkpoint: true, status: "exited")
    identity = { "task_id" => "FIXTURE", "attempt" => number, "invocation_id" => "invocation-#{number}", "session_id" => "codex-#{number}" }
    run = File.join("#{@data}-runs", "FIXTURE", "run-#{number}")
    FileUtils.mkdir_p(run, mode: 0o700)
    authority = { "pushed_sha" => "a" * 40, "remote_url" => "git@github.com:fixture/source.git", "branch" => "main" }
    contents = { "final" => "result #{number}\x00\xff".b + "z" * 17_000,
      "transcript" => JSON.generate("type" => "thread.started", "thread_id" => identity["session_id"]) + "\n" +
        JSON.generate("type" => "item.completed", "text" => "Worker claims checks passed; independently inspect the failed gate.") + "\n",
      "stderr" => "".b }
    report = identity.merge("schema_version" => "agent-coding-tool-run/v1", "workspace" => File.join(@temporary, "workspace-#{number}"),
      "writable_repository" => "source", "writable_authority" => authority, "preparation" => { "source" => authority },
      "status" => status, "exit_status" => 0, "artifacts" => [])
    { "final" => ["final_path", "final.txt"], "transcript" => ["jsonl_path", "stdout.jsonl"], "stderr" => ["stderr_path", "stderr.txt"] }.each do |name, fields|
      path = File.join(run, fields.last)
      File.binwrite(path, contents.fetch(name))
      report[fields.first] = path
      report["artifacts"] << { "path" => path, "bytes" => contents.fetch(name).bytesize, "sha256" => Digest::SHA256.hexdigest(contents.fetch(name)) }
    end
    write_json(File.join(run, "handoff.json"), report)
    if checkpoint
      directory = File.join("#{@data}-runs", "checkpoints", "FIXTURE", number.to_s.rjust(32, "0"))
      patch = "diff --git a/example b/example\n# synthetic candidate #{number}\n"
      record = { "schema_version" => "agent-coding-tool-checkpoint/v1", "task_id" => "FIXTURE", "attempt" => number.to_s.rjust(32, "0"),
        "repository" => "source", "authority" => authority, "launch_invocation" => identity["invocation_id"],
        "artifact" => "0001.patch", "sha256" => Digest::SHA256.hexdigest(patch) }
      record_path = write_json(File.join(directory, "0001.json"), record)
      File.binwrite(File.join(directory, "0001.patch"), patch)
      write_json(File.join(directory, "current.json"), "record_file" => "0001.json", "sha256" => Digest::SHA256.file(record_path).hexdigest)
      write_json(File.join(directory, "gate-0001.finished.json"), record.merge("schema_version" => "agent-coding-tool-checkpoint-gate/v1",
        "invocation_id" => "gate-0001", "candidate" => { "sha256" => record["sha256"], "launch_invocation" => identity["invocation_id"] },
        "command_outcome" => { "status" => "exited", "exit_code" => 1 }, "candidate_validation" => "failed", "output" => { "status" => "not_captured" }))
    end
    { identity: identity, run: run, contents: contents }
  end

  # Returns representative modern metadata with all A-qualified hints/context.
  def metadata(tool: false)
    result = { "protocolVersion" => "2026-07-28", "clientCapabilities" => {}, "clientInfo" => { "name" => "fixture", "version" => "1" } }
    if tool
      AgentCodingTool::EvidenceAdapter::CLIENT_HINTS.each { |name, type| result[name] = type == Hash ? { "city" => "synthetic" } : "untrusted-context" }
      AgentCodingTool::EvidenceAdapter::CONTEXT_STRINGS.each { |name| result[name] = "not-a-codex-session-or-credential" }
      result["progressToken"] = 12.5
    end
    result
  end

  # Builds a real RPC envelope for discovery/list/call; returns a Hash.
  def rpc(method, arguments = nil, meta: metadata(tool: method == "tools/call"))
    params = { "_meta" => meta }
    params.merge!("name" => "read_run_evidence", "arguments" => arguments) if method == "tools/call"
    { "jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params }
  end

  # Calls actual dispatch and requires a successful tool result; returns evidence.
  def tool(arguments, meta: metadata(tool: true))
    result = @adapter.dispatch(rpc("tools/call", arguments, meta: meta)).fetch("result")
    refute result.fetch("isError"), result.inspect
    JSON.parse(result.fetch("content").first.fetch("text"))
  end

  # Resolves one exact identity, returning a pinned manifest and handle.
  def select(run = @first)
    tool(run.fetch(:identity).merge("operation" => "select"))
  end

  # Builds a complete closed read request bound to one manifest.
  def read_request(manifest, artifact = "final", offset: 0, length: 16_384)
    manifest.fetch("binding").slice(*AgentCodingTool::RunEvidenceReader::IDENTITIES).merge(
      "operation" => "read", "handle" => manifest.fetch("handle"), "revision" => manifest.fetch("revision"),
      "artifact" => artifact, "offset" => offset, "length" => length)
  end

  # Proves full modern dispatch, all hints/context and exact binary/empty chunks.
  def test_modern_transport_and_lossless_artifacts
    assert_equal "complete", @adapter.dispatch(rpc("server/discover")).dig("result", "resultType")
    listed = @adapter.dispatch(rpc("tools/list"))
    assert_equal "act-run-evidence", listed.dig("result", "_meta", "io.modelcontextprotocol/serverInfo", "name")
    manifest = select
    meta = metadata(tool: true).merge("progressToken" => "opaque-string")
    first = tool(read_request(manifest), meta: meta)
    following = tool(read_request(manifest, offset: first.fetch("next_offset")))
    bytes = first.fetch("data").unpack1("m0") + following.fetch("data").unpack1("m0")
    assert_equal @first[:contents]["final"], bytes
    assert_equal Digest::SHA256.hexdigest(bytes), first["sha256"]
    assert_equal Digest::SHA256.hexdigest(first["data"].unpack1("m0")), first["chunk_sha256"]
    assert_equal "truncated", first["status"]
    assert_equal "complete", following["status"]
    empty = tool(read_request(manifest, "stderr"))
    assert_equal "", empty["data"]
    assert_equal Digest::SHA256.hexdigest(""), empty["sha256"]
    assert_equal "missing", tool(read_request(manifest, "validation_output"))["status"]
    failed = JSON.parse(tool(read_request(manifest, "validation:gate-0001.finished.json"))["data"].unpack1("m0"))
    assert_equal 1, failed.dig("command_outcome", "exit_code")
    assert_equal "not_captured", failed.dig("output", "status")
    assert_match "not independently validated", first["validation_assurance"]
  end

  # Wrong metadata/aliases/types/unknown fields fail before any business dispatch.
  def test_metadata_refusals_and_duplicate_json
    base = metadata(tool: true)
    wrong = AgentCodingTool::EvidenceAdapter::CLIENT_HINTS.keys.to_h { |name| [name, nil] }
    AgentCodingTool::EvidenceAdapter::CONTEXT_STRINGS.each { |name| wrong[name] = 7 }
    wrong["progressToken"] = true
    wrong.each do |name, value|
      assert @adapter.dispatch(rpc("tools/call", {}, meta: base.merge(name => value)))["error"], name
    end
    [base.merge("future" => "private-value"), base.merge("io.modelcontextprotocol/protocolVersion" => "2026-07-28"),
      base.merge("protocolVersion" => "2026-01-01"), base.merge("openai/userAgent" => "x" * 4096),
      base.merge("clientCapabilities" => []), base.merge("clientInfo" => { "name" => "x" })].each do |meta|
      assert @adapter.dispatch(rpc("tools/call", {}, meta: meta))["error"]
    end
    ['{"a":1,"a":2}', '{"nested":{"key":1,"key":2}}'].each do |text|
      assert_raises(JSON::ParserError) { AgentCodingTool::RunEvidenceStore.parse(text) }
    end
    assert_empty @session.status.fetch("selected_runs")
    assert_equal %w[lock owner state.json], Dir.children(@session_path).sort
  end

  # Identity, mutation, path and mixed-revision requests release no evidence.
  def test_business_refusals
    manifest = select
    valid = read_request(manifest)
    variants = { "task_id" => "OTHER", "attempt" => 2, "invocation_id" => "wrong", "session_id" => "wrong",
      "revision" => "f" * 64, "handle" => "f" * 64, "length" => 16_385, "offset" => -1,
      "artifact" => "../../outside", "operation" => "execute", "command" => "touch forbidden", "path" => "/etc/passwd" }
    variants.each do |field, value|
      response = @adapter.dispatch(rpc("tools/call", valid.merge(field => value)))
      assert response.dig("result", "isError"), field
      refute_includes JSON.generate(response), [@first[:contents]["final"]].pack("m0")
    end
    assert @adapter.dispatch(rpc("events/list"))["error"]
    assert_nil @adapter.dispatch(rpc("tools/call", valid).reject { |key, _value| key == "id" })
  end

  # Completion B cannot alter a pinned A; explicit B selection is independently
  # readable. Missing/duplicate authoritative identities fail closed.
  def test_fresh_run_rollover_and_ambiguity
    first_manifest = select
    original = Dir.glob(File.join(@first[:run], "*")).to_h { |path| [path, File.binread(path)] }
    second = write_run(2)
    second_manifest = select(second)
    assert_equal @first[:identity], tool(read_request(first_manifest))["binding"].slice(*@first[:identity].keys)
    assert_equal second[:contents]["final"].byteslice(0, 16_384), tool(read_request(second_manifest))["data"].unpack1("m0")
    refute_equal first_manifest["revision"], second_manifest["revision"]
    assert @adapter.dispatch(rpc("tools/call", read_request(first_manifest).merge("revision" => second_manifest["revision"])) ).dig("result", "isError")
    assert @adapter.dispatch(rpc("tools/call", @first[:identity].merge("operation" => "select", "session_id" => "absent"))).dig("result", "isError")
    FileUtils.cp_r(@first[:run], File.join(File.dirname(@first[:run]), "duplicate"))
    assert @adapter.dispatch(rpc("tools/call", @first[:identity].merge("operation" => "select"))).dig("result", "isError")
    original.each { |path, bytes| assert_equal bytes, File.binread(path) }
  end

  # Required handoff corruption breaks the continuous selection/read journey;
  # source tampering and symlink escapes never yield outside bytes.
  def test_run_binding_negative_control_and_path_safety
    manifest = select
    handoff = File.join(@first[:run], "handoff.json")
    original = File.binread(handoff)
    report = JSON.parse(original)
    report["preparation"]["source"]["pushed_sha"] = "b" * 40
    write_json(handoff, report)
    assert @adapter.dispatch(rpc("tools/call", @first[:identity].merge("operation" => "select"))).dig("result", "isError")
    assert @adapter.dispatch(rpc("tools/call", read_request(manifest))).dig("result", "isError")
    File.binwrite(handoff, original)
    final_path = File.join(@first[:run], "final.txt")
    File.binwrite(final_path, "changed")
    assert @adapter.dispatch(rpc("tools/call", read_request(manifest))).dig("result", "isError")
    outside = File.join(@temporary, "outside")
    File.binwrite(outside, "private outside bytes")
    File.unlink(final_path)
    File.symlink(outside, final_path)
    assert @adapter.dispatch(rpc("tools/call", @first[:identity].merge("operation" => "select"))).dig("result", "isError")
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      AgentCodingTool::RunEvidenceStore.bytes(File.join(@first[:run], "..", "outside"), root: @first[:run])
    end
    assert_equal "private outside bytes", File.binread(outside)
  end

  # Optional missing artifacts and in-progress bytes have distinct honest status.
  def test_pending_and_missing_evidence
    pending = write_run(2, checkpoint: false, status: "running")
    manifest = select(pending)
    assert_equal "pending", tool(read_request(manifest))["status"]
    %w[checkpoint candidate validation validation_output].each { |name| assert_equal "missing", manifest.dig("artifacts", name, "status") }
    File.unlink(File.join(pending[:run], "stderr.txt"))
    fresh = select(pending)
    assert_equal "missing", tool(read_request(fresh, "stderr"))["status"]
  end

  # Regular Finder metadata in either inventory leaves exact run/checkpoint
  # selection readable and unchanged; its private bytes are never artifacts.
  def test_regular_finder_metadata_coexists_with_run_and_checkpoint_selection
    roots = [File.dirname(@first[:run]), File.join("#{@data}-runs", "checkpoints", "FIXTURE")]
    metadata_bytes = "Finder metadata\x00\xff".b
    roots.each { |root| File.binwrite(File.join(root, ".DS_Store"), metadata_bytes) }
    manifest = select
    assert_equal @first[:contents]["final"].byteslice(0, 16_384), tool(read_request(manifest))["data"].unpack1("m0")
    assert_equal "complete", tool(read_request(manifest, "candidate"))["status"]
    refute_includes manifest.fetch("artifacts").keys, ".DS_Store"
    roots.each { |root| assert_equal metadata_bytes, File.binread(File.join(root, ".DS_Store")) }
  end

  # Finder's filename grants no symlink/directory exception. Unknown entries
  # and linked run/checkpoint directories refuse without releasing outside bytes.
  def test_inventory_refuses_symlinks_and_unknown_entries
    outside = File.join(@temporary, "outside-inventory")
    File.binwrite(outside, "private outside inventory bytes")
    roots = [File.dirname(@first[:run]), File.join("#{@data}-runs", "checkpoints", "FIXTURE")]
    roots.each do |root|
      [[".DS_Store", :directory], [".DS_Store", :symlink], ["linked", :symlink],
        ["unknown.txt", :file], ["unknown", :file], ["unknown.entry", :directory]].each do |name, kind|
        path = File.join(root, name)
        case kind
        when :directory then Dir.mkdir(path)
        when :symlink then File.symlink(outside, path)
        when :file then File.binwrite(path, "unknown entry")
        end
        response = @adapter.dispatch(rpc("tools/call", @first[:identity].merge("operation" => "select")))
        assert response.dig("result", "isError"), "#{name}: #{kind} must refuse"
        refute_includes JSON.generate(response), "private outside inventory bytes"
        assert_empty @session.status.fetch("selected_runs")
        FileUtils.remove_entry(path)
      end
    end
    assert_equal "private outside inventory bytes", File.binread(outside)
  end

  # Restart retains cumulative counters, manual stop and original admission;
  # expiry refuses even when a fresh adapter opens the same directory.
  def test_durable_limits_stop_and_expiry
    @session.admit
    @session.charge(wire: 123, decoded: 45)
    restarted = AgentCodingTool::EvidenceSession.new(@session_path)
    assert_equal 123, restarted.status["wire_bytes"]
    assert_equal 45, restarted.status["decoded_bytes"]
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { AgentCodingTool::EvidenceSession.start(@session_path, @grant_path) }
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { AgentCodingTool::EvidenceSession.start(File.join(@temporary, "grant-replay"), @grant_path) }
    restarted.stop
    assert_equal "stopped", @session.status["status"]
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.admit }
    expiry_path = File.join(@temporary, "expiry")
    @grant["session_path"] = expiry_path
    @grant["limits"]["seconds"] = 1
    write_json(@grant_path, @grant)
    AgentCodingTool::EvidenceSession.start(expiry_path, @grant_path)
    expired = AgentCodingTool::EvidenceSession.new(expiry_path)
    # Move only the fixture's wall deadline; monotonic enforcement is separately
    # exercised by the native process timeout case below.
    expired.transaction { |state| state["expires_at"] = Time.now.to_f - 1 }
    assert_equal "expired", expired.status["status"]
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { expired.admit }
  end

  # Exact request/byte ceilings survive reconnection and boundary admissions;
  # private grants, unknown fields and expanded artifact scope fail closed.
  def test_budget_boundaries_and_grant_closure
    bounded_path = File.join(@temporary, "bounded")
    @grant["session_path"] = bounded_path
    @grant["limits"].merge!("requests" => 1, "wire_bytes" => 4, "decoded_bytes" => 2)
    write_json(@grant_path, @grant)
    AgentCodingTool::EvidenceSession.start(bounded_path, @grant_path)
    bounded = AgentCodingTool::EvidenceSession.new(bounded_path)
    bounded.admit
    bounded.charge(wire: 4, decoded: 2)
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { bounded.admit }
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { bounded.charge(wire: 1) }
    assert_equal "exhausted", bounded.status["status"]
    @grant["extra"] = true
    write_json(@grant_path, @grant)
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { AgentCodingTool::EvidenceSession.start(File.join(@temporary, "bad"), @grant_path) }
    File.chmod(0o644, @grant_path)
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { AgentCodingTool::EvidenceSession.start(File.join(@temporary, "public"), @grant_path) }
  end

  # Invokes the public CLI with binary-preserving observers and exact exit status.
  # Only declared native cases call this helper; ordinary tests spawn nothing.
  def cli(*arguments)
    output, error, status = Open3.capture3(RbConfig.ruby, File.expand_path("../bin/agent-coding-tool", __dir__), "evidence", *arguments)
    assert status.success?, "CLI #{arguments.first} failed: #{error}"
    JSON.parse(output)
  end

  # Exercises public start/select/read/status/stop plus real stdio discovery,
  # list/call, fresh rollover and controller EOF without sockets or paid workers.
  def test_native_public_cli_two_runs_and_owned_eof
    path = File.join(@temporary, "public")
    @grant["session_path"] = path
    write_json(@grant_path, @grant)
    assert_equal "active", cli("start", "--session", path, "--grant", @grant_path)["status"]
    [File.dirname(@first[:run]), File.join("#{@data}-runs", "checkpoints", "FIXTURE")].each do |root|
      File.binwrite(File.join(root, ".DS_Store"), "synthetic Finder metadata")
    end
    flags = ["--task", "FIXTURE", "--attempt", "1", "--invocation", "invocation-1", "--codex-session", "codex-1"]
    manifest = cli("select", "--session", path, *flags)
    command = [RbConfig.ruby, File.expand_path("../bin/agent-coding-tool", __dir__), "evidence", "serve", "--session", path]
    Open3.popen3(*command) do |input, output, error, waiter|
      exchange = lambda do |request|
        input.write(JSON.generate(request) + "\n")
        input.flush
        assert IO.select([output], [], [], 5), "bounded public response missing"
        JSON.parse(output.gets)
      end
      assert exchange.call(rpc("server/discover"))["result"]
      assert exchange.call(rpc("tools/list"))["result"]
      manifest.fetch("artifacts").each do |name, spec|
        next if spec["status"] == "missing"
        bytes = "".b
        offset = 0
        loop do
          received = exchange.call(rpc("tools/call", read_request(manifest, name, offset: offset)))
          refute received.dig("result", "isError")
          evidence = JSON.parse(received.dig("result", "content", 0, "text"))
          chunk = evidence.fetch("data").unpack1("m0")
          assert_equal Digest::SHA256.hexdigest(chunk), evidence["chunk_sha256"]
          bytes << chunk
          break unless evidence["next_offset"]
          offset = evidence.fetch("next_offset")
        end
        # An independent host oracle opens original files without the reader.
        assert_equal File.binread(spec.fetch("path")), bytes
        assert_equal Digest::SHA256.file(spec.fetch("path")).hexdigest, Digest::SHA256.hexdigest(bytes)
      end
      input.write('{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}' + "\n")
      input.flush
      assert_equal(-32700, JSON.parse(output.gets).dig("error", "code"))
      assert exchange.call(rpc("tools/call", {}, meta: metadata(tool: true).merge("unknown" => "private-context")))["error"]
      handoff = File.join(@first[:run], "handoff.json")
      original_handoff = File.binread(handoff)
      damaged_handoff = JSON.parse(original_handoff).merge("session_id" => "broken-required-handoff")
      write_json(handoff, damaged_handoff)
      assert exchange.call(rpc("tools/call", read_request(manifest))).dig("result", "isError")
      File.binwrite(handoff, original_handoff)
      response = exchange.call(rpc("tools/call", read_request(manifest)))
      assert_equal @first[:contents]["final"].byteslice(0, 16_384), JSON.parse(response.dig("result", "content", 0, "text"))["data"].unpack1("m0")
      second = write_run(2)
      selected = exchange.call(rpc("tools/call", second[:identity].merge("operation" => "select")))
      second_manifest = JSON.parse(selected.dig("result", "content", 0, "text"))
      response = exchange.call(rpc("tools/call", read_request(second_manifest)))
      assert_equal "codex-2", JSON.parse(response.dig("result", "content", 0, "text")).dig("binding", "session_id")
      response = exchange.call(rpc("tools/call", read_request(manifest)))
      assert_equal "codex-1", JSON.parse(response.dig("result", "content", 0, "text")).dig("binding", "session_id")
      assert_equal 2, cli("status", "--session", path)["selected_runs"].length
      assert_equal "stopped", cli("stop", "--session", path)["status"]
      assert Timeout.timeout(5) { waiter.value }.success?
      diagnostics = error.read
      refute_includes diagnostics, "untrusted-context"
      refute_includes diagnostics, "private-context"
      assert_nil output.read(1)
    end
    read = cli("read", "--session", @session_path, *flags, "--handle", select["handle"], "--revision", select["revision"],
      "--artifact", "stderr", "--offset", "0", "--length", "16")
    assert_equal "complete", read["status"]
    # Controller EOF closes a newly owned foreground process; no signal or
    # historical PID lookup is used. Waiting independently observes direct exit.
    Open3.popen3(RbConfig.ruby, File.expand_path("../bin/agent-coding-tool", __dir__), "evidence", "serve", "--session", @session_path) do |input, output, error, waiter|
      input.close
      assert Timeout.timeout(5) { waiter.value }.success?
      assert_empty output.read
      assert_operator error.read.bytesize, :<=, 4096
    end
    assert_equal %w[lock owner state.json], Dir.children(@session_path).sort
    expiry_path = File.join(@temporary, "native-expiry")
    @grant["session_path"] = expiry_path
    @grant["limits"]["seconds"] = 1
    write_json(@grant_path, @grant)
    cli("start", "--session", expiry_path, "--grant", @grant_path)
    Open3.popen3(RbConfig.ruby, File.expand_path("../bin/agent-coding-tool", __dir__), "evidence", "serve", "--session", expiry_path) do |_input, output, error, waiter|
      assert Timeout.timeout(5) { waiter.value }.success?
      assert_empty output.read
      assert_operator error.read.bytesize, :<=, 4096
    end
    assert_equal "expired", cli("status", "--session", expiry_path)["status"]
  end
end
