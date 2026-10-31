# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "timeout"
require "socket"
require "minitest/mock"

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

  # Runs the actual adapter over pipes and closes only its owned fixture thread.
  # EOF terminates the server; thread exceptions propagate after bounded cleanup.
  def adapter_pipe
    input, sender = IO.pipe
    receiver, output = IO.pipe
    worker = Thread.new do
      begin
        @adapter.serve(input, output)
      ensure
        input.close
        output.close
      end
    end
    worker.report_on_exception = false
    yield sender, receiver
  ensure
    sender&.close unless sender&.closed?
    if worker
      joined = worker.join(2)
      unless joined
        worker.kill
        worker.join
        flunk "adapter did not terminate after fixture EOF" unless $!
      end
      worker.value if joined
    end
    receiver&.close unless receiver&.closed?
  end

  # Exchanges one real frame, retaining exact wire counts and explicit EOF errors.
  # A refusal/early close is never replaced by a retry or a fabricated response.
  def adapter_exchange(sender, receiver, request)
    bytes = JSON.generate(request) + "\n"
    sender.write(bytes)
    @incoming_wire += bytes.bytesize
    assert IO.select([receiver], [], [], 3), "adapter response missing"
    line = receiver.gets
    refute_nil line, "transient contention closed adapter"
    @outgoing_wire += line.bytesize
    JSON.parse(line)
  end

  # Every real ledger acquisition first collides with another descriptor. Release
  # follows the actual failed flock, without sleeps, fake state reads or retries.
  def test_adapter_ledger_transient_contention
    before = @session.status
    lock_path = File.join(@session_path, "lock")
    competitor = File.open(lock_path, File::RDWR)
    original = @session.method(:transaction)
    operations, yielded, released = [], 0, 0
    @session.define_singleton_method(:transaction) do |wait: 0, &operation|
      raise "fixture competitor unavailable" unless competitor.flock(File::LOCK_EX | File::LOCK_NB)
      operations << caller_locations(1, 1).first.base_label
      original.call(wait: wait) do |state|
        yielded += 1
        operation.call(state)
      end
    ensure
      competitor.flock(File::LOCK_UN)
    end
    trace = TracePoint.new(:c_return) do |event|
      next unless event.method_id == :flock && event.return_value == false &&
        event.self.is_a?(File) && event.self.path == lock_path
      released += 1
      competitor.flock(File::LOCK_UN)
    end
    @incoming_wire, @outgoing_wire = 0, 0
    # Include the adapter worker; block-form tracing otherwise watches this thread.
    trace.enable(target_thread: nil) do
      adapter_pipe do |sender, receiver|
        assert adapter_exchange(sender, receiver, rpc("server/discover"))["result"]
        selected = adapter_exchange(sender, receiver,
          rpc("tools/call", @first[:identity].merge("operation" => "select")))
        refute selected.dig("result", "isError")
        manifest = JSON.parse(selected.dig("result", "content", 0, "text"))
        response = adapter_exchange(sender, receiver, rpc("tools/call", read_request(manifest)))
        refute response.dig("result", "isError")
        evidence = JSON.parse(response.dig("result", "content", 0, "text"))
        bytes = evidence.fetch("data").unpack1("m0")
        assert_equal @first[:contents]["final"].byteslice(0, 16_384), bytes
        assert_equal Digest::SHA256.hexdigest(bytes), evidence.fetch("chunk_sha256")
      end
    end
    @session.singleton_class.remove_method(:transaction)
    after = @session.status
    assert_equal before.slice("admitted_at", "expires_at", "grant_sha256", "limits"),
      after.slice("admitted_at", "expires_at", "grant_sha256", "limits")
    assert_equal 4, after["requests"] # Three frames plus the nonrefundable EOF attempt.
    assert_equal @incoming_wire + @outgoing_wire, after["wire_bytes"]
    assert_equal 16_384, after["decoded_bytes"]
    assert_equal operations.length, yielded
    assert_equal yielded, released
    %w[admit status charge call].each { |name| assert_includes operations, name }
    assert_equal after, AgentCodingTool::EvidenceSession.new(@session_path).status
  ensure
    trace&.disable
    if @session.singleton_class.instance_methods(false).include?(:transaction)
      @session.singleton_class.remove_method(:transaction)
    end
    competitor&.close
  end

  # Persistent real contention has a one-second acquisition bound. Only the
  # wait clock advances synthetically; no ledger operation or charge is replayed.
  def test_adapter_ledger_persistent_contention
    ledger_path = File.join(@session_path, "state.json")
    before = File.binread(ledger_path)
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    started = clock
    output = StringIO.new
    File.open(File.join(@session_path, "lock"), File::RDWR) do |lock|
      assert lock.flock(File::LOCK_EX | File::LOCK_NB)
      error = assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.status }
      assert_equal "session.busy", error.message # Controller/CLI defaults stay nonblocking.
      Process.stub(:clock_gettime, ->(_kind) { clock }) do
        IO.stub(:select, ->(_read, _write, _error, seconds) { clock += seconds; nil }) do
          @adapter.serve(StringIO.new, output)
        end
      end
      assert_operator clock - started, :>=, 1
      assert_operator clock - started, :<=, 1.05
      assert_equal before, File.binread(ledger_path)
      assert_empty output.string
      assert lock.flock(File::LOCK_EX | File::LOCK_NB), "competing lock was preserved"
    end
    assert_equal "active", @session.status["status"]
  end

  # A real competing writer stops/expires the fixture before releasing its lock.
  # The waiting adapter rechecks lifecycle and emits/charges no evidence bytes.
  def test_adapter_ledger_stop_and_expiry_after_contention
    %w[stopped expired].each do |reason|
      path = File.join(@temporary, "contended-#{reason}")
      grant = @grant.merge("session_path" => path)
      AgentCodingTool::EvidenceSession.start(path, write_json(File.join(@temporary, "#{reason}.json"), grant))
      session = AgentCodingTool::EvidenceSession.new(path)
      adapter = AgentCodingTool::EvidenceAdapter.new(session, err: StringIO.new)
      before = session.status
      lock_path = File.join(path, "lock")
      output, observed, refusal = StringIO.new, false, nil
      File.open(lock_path, File::RDWR) do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        trace = TracePoint.new(:c_return, :raise) do |event|
          if event.event == :raise
            error = event.raised_exception
            refusal = error.message if error.is_a?(AgentCodingTool::RunEvidenceReader::Refused)
            next
          end
          next unless !observed && event.method_id == :flock && event.return_value == false &&
            event.self.is_a?(File) && event.self.path == lock_path
          observed = true
          state = JSON.parse(File.binread(File.join(path, "state.json")))
          if reason == "stopped"
            state["stopped"] = true
          else
            state["expires_at"] = Time.now.to_f - 1
          end
          AgentCodingTool::EvidenceSession.write(path, state)
          lock.flock(File::LOCK_UN)
        end
        begin
          trace.enable { adapter.serve(StringIO.new, output) }
        ensure
          trace.disable
        end
      end
      after = session.status
      assert observed, "adapter never observed the competing writer"
      assert_equal "lifecycle.#{reason}", refusal
      assert_equal reason, after["status"]
      assert_empty output.string
      assert_equal before.slice("admitted_at", "grant_sha256", "limits", "requests", "wire_bytes", "decoded_bytes"),
        after.slice("admitted_at", "grant_sha256", "limits", "requests", "wire_bytes", "decoded_bytes")
      assert_equal before["expires_at"], after["expires_at"] if reason == "stopped"
    end
  end

  # Status/stop expose only fixed tunnel outcomes, independently of launcher
  # source identity; malformed receipts cannot become an arbitrary data echo.
  def test_tunnel_status_is_closed_and_independent_of_candidate_identity
    result = { "stage" => "readiness", "reason" => "failed", "local_cleanup" => "blocked",
      "admission_stop" => "stopped", "retrieval" => "not_attested", "hosted_shutdown" => "not_observed", "saved_settings" => "not_modified" }
    path = File.join(@session_path, "tunnel-result.json")
    write_json(path, result)
    assert_equal result, @session.status["tunnel"]
    assert_equal result, AgentCodingTool::EvidenceSession.new(@session_path).stop["tunnel"]
    write_json(path, result.merge("reason" => "private-response"))
    error = assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.status }
    assert_equal "tunnel.receipt", error.message
    refute_includes error.message, "private-response"
  end

  # Invokes the public CLI with binary-preserving observers and exact exit status.
  # Only declared native cases call this helper; ordinary tests spawn nothing.
  def cli(*arguments)
    output, error, status = Open3.capture3(RbConfig.ruby, File.expand_path("../bin/agent-coding-tool", __dir__), "evidence", *arguments)
    assert status.success?, "CLI #{arguments.first} failed: #{error}"
    JSON.parse(output)
  end

  # Real kernel contention is released only after a fresh public CLI observes
  # failed flock. No sleeps, simulated ledger operations, ps or tunnel startup.
  # Persistent contention refuses, preserving accounting and the competing lock.
  def test_native_stop_serializes_once_and_refuses_persistent_contention
    @session.admit
    @session.charge(wire: 123, decoded: 45)
    before = @session.status
    probe = <<~'RUBY'
      trace = TracePoint.new(:c_return) do |event|
        next unless event.method_id == :flock
        STDERR.puts(event.return_value == false ? "LOCK_CONTENDED" : "LOCK_ACQUIRED")
        STDERR.flush
      end
      trace.enable
      load ARGV.shift
    RUBY
    command = [RbConfig.ruby, "-e", probe, File.expand_path("../bin/agent-coding-tool", __dir__),
      "evidence", "stop", "--session", @session_path]
    File.open(File.join(@session_path, "lock"), File::RDWR) do |lock|
      assert lock.flock(File::LOCK_EX | File::LOCK_NB)
      output, error, status = Open3.capture3(*command)
      refute status.success?
      assert_empty output
      assert_includes error, "session.busy"
      refute JSON.parse(File.binread(File.join(@session_path, "state.json")))["stopped"]
      Open3.popen3(*command) do |input, output, error, waiter|
        input.close
        assert IO.select([error], [], [], 5), "stop never observed the contended lock"
        assert_equal "LOCK_CONTENDED\n", error.gets
        lock.flock(File::LOCK_UN)
        response = JSON.parse(output.read)
        status = waiter.value
        diagnostics = error.read
        assert status.success?, diagnostics
        assert_equal "stopped", response["status"]
        assert_equal before.slice("requests", "wire_bytes", "decoded_bytes", "expires_at", "grant_sha256"),
          response.slice("requests", "wire_bytes", "decoded_bytes", "expires_at", "grant_sha256")
        # A single acquisition proves stop cannot hit its former status race.
        assert_equal 1, diagnostics.scan("LOCK_ACQUIRED").length
      end
      assert lock.flock(File::LOCK_EX | File::LOCK_NB), "competing descriptor remains usable"
    end
    assert_equal "stopped", cli("stop", "--session", @session_path)["status"]
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.admit }
    # A malformed receipt still refuses its output after durable revocation.
    write_json(File.join(@session_path, "tunnel-result.json"), "reason" => "private-value")
    error = assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.stop }
    assert_equal "tunnel.receipt", error.message
    assert JSON.parse(File.binread(File.join(@session_path, "state.json")))["stopped"]
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

  # Makes only an external client/service fake. It verifies the actual credential
  # environment, launches the configured real adapter and offers an offline wire.
  # The client key appears only in this declared synthetic assertion and .env.
  def tunnel_fixture
    client = File.join(@temporary, "fixture-client")
    source = <<~'RUBY'
      require "json"
      require "socket"
      require "open3"
      require "shellwords"
      exit 41 unless ENV["CONTROL_PLANE_API_KEY"] == "ACT29_SYNTHETIC_CREDENTIAL_7fQ9"
      exit 42 if ENV.key?("OPENAI_TUNNEL_KEY") || ENV.key?("OTHER_SECRET")
      config = JSON.parse(File.binread(ARGV.fetch(2)))
      capacity = config.dig("admin_ui", "log_buffer_events")
      exit 45 unless capacity.is_a?(Integer) && capacity.positive?
      command = Shellwords.split(config.fetch("mcp").fetch("commands").first.fetch("command"))
      exit 43 unless command.take(2) == ["/usr/bin/env", "-i"]
      exit 44 if command.any? { |argument| argument.include?(ENV.fetch("CONTROL_PLANE_API_KEY")) }
      input, output, waiter = Open3.popen2(*command)
      wire = UNIXServer.new("wire")
      health = TCPServer.new("127.0.0.1", 0)
      Thread.new do
        loop do
          connection = health.accept
          connection.gets
          connection.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
          connection.close
        end
      end
      File.write(config.fetch("health").fetch("url_file"), "http://127.0.0.1:#{health.addr[1]}\n", perm: 0o600)
      connection = wire.accept
      while (frame = connection.gets)
        input.write(frame)
        input.flush
        response = output.gets
        break unless response
        connection.write(response)
      end
      input.close
      waiter.value
    RUBY
    RubyVM::InstructionSequence.compile(source)
    File.write(client, "#!#{RbConfig.ruby}\n" + source, perm: 0o700)
    @dotenv = File.join(@temporary, ".env")
    File.write(@dotenv, "OPENAI_TUNNEL_KEY='ACT29_SYNTHETIC_CREDENTIAL_7fQ9'\nOTHER_SECRET=unrelated-sentinel\n", perm: 0o600)
    @runtime = File.join(@temporary, "shared-runtime")
    Dir.mkdir(@runtime, 0o700)
    client
  end

  # Opens one fresh-process public session from an unrelated cwd, yields its wire
  # and owned controller, then requests bounded stop even if an assertion fails.
  def with_tunnel(client, name, seconds: 10, controller_loss: false)
    path = File.join(@temporary, name)
    @grant["session_path"] = path
    @grant["transport"]["endpoint"] = "tunnel_fixture/main"
    @grant["limits"]["seconds"] = seconds
    grant_path = write_json(File.join(@temporary, "#{name}-grant.json"), @grant)
    arguments = [RbConfig.ruby, File.expand_path("../bin/agent-coding-tool", __dir__), "evidence", "open",
      "--session", path, "--grant", grant_path, "--env-file", @dotenv, "--client", client, "--runtime-dir", @runtime]
    arguments = controller_loss_command + arguments.drop(2) if controller_loss
    environment = { "OPENAI_TUNNEL_KEY" => nil, "CONTROL_PLANE_API_KEY" => nil, "OTHER_SECRET" => nil }
    Open3.popen3(environment, *arguments, chdir: @temporary) do |input, output, error, waiter|
      begin
        assert IO.select([output], [], [], 5), "public tunnel startup did not finish"
        line = output.gets
        assert line, "public tunnel startup refused before READY"
        assert_equal "ready", JSON.parse(line)["status"]
        wire = Dir.chdir(path) { UNIXSocket.new("wire") }
        yield wire, waiter, path
      ensure
        AgentCodingTool::EvidenceSession.new(path).stop if File.exist?(File.join(path, "state.json"))
        wire&.close unless wire&.closed?
        input.close
        status = Timeout.timeout(5) { waiter.value }
        assert status.exited? || status.signaled?
        @tunnel_diagnostics = error.read
        refute_includes @tunnel_diagnostics, "ACT29_SYNTHETIC_CREDENTIAL_7fQ9"
        refute_includes @tunnel_diagnostics, "unrelated-sentinel"
      end
    end
  end

  # Exercises real dotenv -> client credential channel -> actual adapter -> exact
  # reader bytes through public open/status/stop, two selections and later reuse.
  # Missing delivery or a broken run binding fails this very composed journey.
  def test_native_tunnel_cli_dotenv_two_sessions_and_negative_controls
    client = tunnel_fixture
    original_dotenv = File.binread(@dotenv)
    original_mode = File.stat(@dotenv).mode
    output, error, status = Open3.capture3({ "OPENAI_TUNNEL_KEY" => nil }, RbConfig.ruby,
      "-I", File.expand_path("../lib", __dir__), "-e",
      'require "agent_coding_tool"; AgentCodingTool::CLI.run(["help"]); abort "unexpected dotenv loading" if defined?(Dotenv)', chdir: @temporary)
    assert status.success?, error
    refute_includes output, "ACT29_SYNTHETIC_CREDENTIAL_7fQ9"
    later = write_run(2)
    with_tunnel(client, "tunnel-first") do |wire, _waiter, path|
      exchange = lambda do |request|
        wire.write(JSON.generate(request) + "\n")
        assert IO.select([wire], [], [], 3), "bounded tunnel response missing"
        JSON.parse(wire.gets)
      end
      assert exchange.call(rpc("server/discover"))["result"]
      assert exchange.call(rpc("tools/list"))["result"]
      [@first, later].each do |run|
        selected = exchange.call(rpc("tools/call", run[:identity].merge("operation" => "select")))
        refute selected.dig("result", "isError")
        manifest = JSON.parse(selected.dig("result", "content", 0, "text"))
        manifest.fetch("artifacts").each do |name, spec|
          next if spec["status"] == "missing"
          bytes, offset = "".b, 0
          loop do
            response = exchange.call(rpc("tools/call", read_request(manifest, name, offset: offset)))
            refute response.dig("result", "isError")
            evidence = JSON.parse(response.dig("result", "content", 0, "text"))
            chunk = evidence.fetch("data").unpack1("m0")
            assert_equal Digest::SHA256.hexdigest(chunk), evidence["chunk_sha256"]
            assert_equal Digest::SHA256.file(spec.fetch("path")).hexdigest, evidence["sha256"]
            bytes << chunk
            break unless evidence["next_offset"]
            offset = evidence.fetch("next_offset")
          end
          assert_equal File.binread(spec.fetch("path")), bytes
        end
        handoff = File.join(run[:run], "handoff.json")
        original = File.binread(handoff)
        write_json(handoff, JSON.parse(original).merge("session_id" => "broken-required-binding"))
        assert exchange.call(rpc("tools/call", read_request(manifest))).dig("result", "isError")
        File.binwrite(handoff, original)
        assert exchange.call(rpc("tools/call", read_request(manifest).merge("task_id" => "OUTSIDE"))).dig("result", "isError")
      end
      bad = exchange.call(rpc("tools/call", {}, meta: metadata(tool: true).merge("unknown" => "private-context")))
      assert_equal "metadata.unknown_member", bad.dig("error", "data", "stage")
      assert_equal 2, cli("status", "--session", path)["selected_runs"].length
      assert_equal "stopped", cli("stop", "--session", path)["status"]
    end
    adapter_diagnostics = File.binread(File.join(@temporary, "tunnel-first", "adapter-diagnostics.jsonl"))
    assert_includes adapter_diagnostics, "reader.refused"
    refute_includes adapter_diagnostics, "private-context"
    assert_operator adapter_diagnostics.bytesize, :<=, 4096
    # The same command/client source and .env are used with a new approved grant.
    with_tunnel(client, "tunnel-later") do |wire, _waiter, path|
      wire.write(JSON.generate(rpc("tools/call", later[:identity].merge("operation" => "select"))) + "\n")
      assert IO.select([wire], [], [], 3), "later selection response missing"
      response = JSON.parse(wire.gets)
      manifest = JSON.parse(response.dig("result", "content", 0, "text"))
      wire.write(JSON.generate(rpc("tools/call", read_request(manifest))) + "\n")
      assert IO.select([wire], [], [], 3), "later read response missing"
      evidence = JSON.parse(JSON.parse(wire.gets).dig("result", "content", 0, "text"))
      assert_equal later[:contents]["final"].byteslice(0, 16_384), evidence.fetch("data").unpack1("m0")
      assert_equal "stopped", cli("stop", "--session", path)["status"]
    end
    assert_equal original_dotenv, File.binread(@dotenv)
    assert_equal original_mode, File.stat(@dotenv).mode
    %w[tunnel-first tunnel-later].each do |name|
      receipt = JSON.parse(File.binread(File.join(@temporary, name, "tunnel-result.json")))
      assert_equal "not_attested", receipt["retrieval"]
      assert_equal "not_observed", receipt["hosted_shutdown"]
      refute_equal "unknown", receipt["local_cleanup"]
      refute_equal "blocked", receipt["local_cleanup"]
      assert_equal "stopped", cli("status", "--session", File.join(@temporary, name))["status"]
    end
  end

  # Returns a test-only public CLI bootstrap. USR1 exits the controller with a
  # distinct status without the cooperative TERM wait, while Ruby at_exit can
  # finalize coverage. This stimulus does not prove SIGKILL behavior.
  def controller_loss_command
    [RbConfig.ruby, "-e", 'trap("USR1") { exit 86 }; load ARGV.shift',
      File.expand_path("../bin/agent-coding-tool", __dir__)]
  end

  # Proves independent expiry/controller-loss cleanup, endpoint collision and
  # nonrenewable session accounting through actual public process boundaries.
  # An unrelated live child is a sentinel and must survive every owned teardown.
  def test_native_tunnel_lifecycle_and_exclusive_ownership
    client = tunnel_fixture
    sentinel = Process.spawn(RbConfig.ruby, "-e", "sleep 30", out: File::NULL, err: File::NULL)
    with_tunnel(client, "controller-loss", controller_loss: true) do |wire, waiter, path|
      wire.write(JSON.generate(rpc("ping")) + "\n")
      assert IO.select([wire], [], [], 3), "lifecycle probe response missing"
      assert JSON.parse(wire.gets)["result"]
      before = cli("status", "--session", path)
      arguments = [RbConfig.ruby, File.expand_path("../bin/agent-coding-tool", __dir__), "evidence", "open",
        "--session", path, "--grant", File.join(@temporary, "controller-loss-grant.json"),
        "--env-file", @dotenv, "--client", client, "--runtime-dir", @runtime]
      output, error, status = Open3.capture3({ "OPENAI_TUNNEL_KEY" => nil }, *arguments)
      refute status.success?
      assert_empty output
      assert_includes error, "tunnel.session_reused"
      assert_equal "active", cli("status", "--session", path)["status"]
      # A separately approved new admission still cannot take this endpoint.
      occupied = File.join(@temporary, "occupied")
      proposal = @grant.merge("session_path" => occupied)
      write_json(File.join(@temporary, "occupied-grant.json"), proposal)
      occupied_arguments = arguments.map { |value| value == path ? occupied : value == File.join(@temporary, "controller-loss-grant.json") ? File.join(@temporary, "occupied-grant.json") : value }
      _output, error, status = Open3.capture3({ "OPENAI_TUNNEL_KEY" => nil }, *occupied_arguments)
      refute status.success?
      assert_includes error, "tunnel.occupied"
      refute File.exist?(occupied)
      # Observe actual controller death before any fixture stop/cleanup path.
      Process.kill("USR1", waiter.pid)
      controller_status = Timeout.timeout(5) { waiter.value }
      assert controller_status.exited?
      assert_equal 86, controller_status.exitstatus
      receipt_path = File.join(path, "tunnel-result.json")
      Timeout.timeout(5) { IO.select(nil, nil, nil, 0.05) until File.exist?(receipt_path) }
      receipt = JSON.parse(File.binread(receipt_path))
      assert_equal "controller_lost", receipt["reason"]
      assert_equal "stopped", receipt["admission_stop"]
      assert_includes %w[owned_groups_signaled_and_reaped owned_groups_terminal_and_reaped], receipt["local_cleanup"]
      after = cli("status", "--session", path)
      assert_equal "stopped", after["status"]
      health = URI.parse(File.binread(File.join(path, "health-url")).strip)
      assert_raises(Errno::ECONNREFUSED) { TCPSocket.new(health.host, health.port) }
      assert_equal before.values_at("wire_bytes", "decoded_bytes", "expires_at", "limits"),
        after.values_at("wire_bytes", "decoded_bytes", "expires_at", "limits")
      _output, error, status = Open3.capture3({ "OPENAI_TUNNEL_KEY" => nil }, *arguments)
      refute status.success?
      assert_includes error, "tunnel.session_reused"
      assert_equal after, cli("stop", "--session", path)
      assert_equal after, cli("stop", "--session", path)
      assert_equal 1, Process.kill(0, sentinel)
    end
    with_tunnel(client, "finite-expiry", seconds: 1) do |_wire, waiter, path|
      assert Timeout.timeout(4) { waiter.value }.exited?
      result = cli("status", "--session", path)
      assert_equal "expired", result.dig("tunnel", "reason")
      assert_equal "stopped", result["status"]
      assert_equal 1, Process.kill(0, sentinel)
    end
  ensure
    if sentinel
      Process.kill("TERM", sentinel)
      Process.waitpid(sentinel)
    end
  end

  # Credential rejection happens locally without a prompt. Wrong delivery to
  # the synthetic client fails startup; stopping a startup leaves its failure
  # distinct from cleanup. No consumed grant is automatically retried.
  def test_native_tunnel_startup_failures_are_safe_and_nonzero
    client = tunnel_fixture
    File.write(@dotenv, "OPENAI_TUNNEL_KEY=wrong-synthetic-delivery\n", perm: 0o600)
    %w[failed-client stopped-startup].each do |name|
      path = File.join(@temporary, name)
      proposal = @grant.merge("session_path" => path,
        "transport" => @grant.fetch("transport").merge("endpoint" => "tunnel_fixture/main"),
        "limits" => @grant.fetch("limits").merge("seconds" => 1))
      grant_path = write_json(File.join(@temporary, "#{name}-grant.json"), proposal)
      arguments = [RbConfig.ruby, File.expand_path("../bin/agent-coding-tool", __dir__), "evidence", "open",
        "--session", path, "--grant", grant_path, "--env-file", @dotenv, "--client", client, "--runtime-dir", @runtime]
      Open3.popen3({ "OPENAI_TUNNEL_KEY" => nil }, *arguments) do |input, output, error, waiter|
        input.close
        if name == "stopped-startup"
          Timeout.timeout(3) { IO.select(nil, nil, nil, 0.02) until File.exist?(File.join(path, "tunnel.json")) }
          cli("stop", "--session", path)
        end
        refute Timeout.timeout(4) { waiter.value }.success?
        assert_empty output.read
        diagnostics = error.read
        refute_includes diagnostics, "wrong-synthetic-delivery"
        result = JSON.parse(File.binread(File.join(path, "tunnel-result.json")))
        assert_equal "readiness", result["stage"]
        assert_includes %w[expired stopped], result["reason"]
        assert_equal "not_attested", result["retrieval"]
        assert_equal "stopped", result["admission_stop"]
        assert_equal 0, cli("status", "--session", path)["decoded_bytes"]
      end
    end
  end
end
