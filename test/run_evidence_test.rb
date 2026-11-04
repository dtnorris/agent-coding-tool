# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/child_processes"
require_relative "support/memory_git/broker"
require_relative "support/source_fixture"
require "stringio"
require "timeout"
require "socket"
require "minitest/mock"

# Deterministic ACT records stand in only for the external worker/checkpoint
# producer. All selection, transport, accounting and byte reading are real.
class RunEvidenceTest < Minitest::Test
  include TestHelpers
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
    @sharing_broker&.close
    @sharing_world&.verify!
    FileUtils.remove_entry(@temporary)
  end

  # Writes private deterministic JSON; returns the path for fixture construction.
  def write_json(path, value)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, JSON.generate(value), mode: "w", perm: 0o600)
    path
  end

  # Resolves a disposable owned Codex stand-in without consulting the host PATH.
  def fake_codex_path
    path = File.join(@temporary, "fake-codex")
    FileUtils.cp(File.join(ChildProcesses::FIXTURES, "fake_codex.rb"), path)
    File.chmod(0o700, path)
    File.realpath(path)
  end

  # Runs the repository-owned Codex stand-in under the exact native test permit.
  def run_fake_codex(followup, executable, argv, pipes)
    raise "wrong fake executable" unless argv.first == executable
    approval = ChildProcesses.permit("fake_codex", arguments: argv.drop(1), options: { pgroup: true })
    pid = NoGitExecution.with_permit(approval) do
      Process.spawn(approval.environment, *approval.argv, **approval.options, out: pipes.fetch(:out), err: pipes.fetch(:err))
    end
    followup.instance_variable_set(:@writer_pid, pid)
    _, status = Process.wait2(pid)
    followup.instance_variable_set(:@writer_pid, nil)
    status
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
        "invocation_id" => "0001", "candidate" => { "record_file" => "0001.json", "artifact" => record["artifact"],
          "sha256" => record["sha256"], "launch_invocation" => identity["invocation_id"] },
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
    manifest.fetch("binding").slice(*AgentCodingTool::RunEvidenceReader.identity_fields(manifest.fetch("binding"))).merge(
      "operation" => "read", "handle" => manifest.fetch("handle"), "revision" => manifest.fetch("revision"),
      "artifact" => artifact, "offset" => offset, "length" => length)
  end

  # Shared transcript reads stream beyond the ordinary-file ceiling, bind the
  # complete managed source and refuse mutation/foreign paths without broadening v1.
  def test_shared_oversized_transcript_chunks_and_source_refusals
    path = File.join(@first[:run], "stdout.jsonl")
    line = JSON.generate("type" => "item.completed", "text" => "x" * 16_000) + "\n"
    File.open(path, "ab") { |file| 263.times { file.write(line) } }
    report_path = File.join(@first[:run], "handoff.json")
    report = JSON.parse(File.binread(report_path))
    recorded = report.fetch("artifacts").find { |entry| entry["path"] == path }
    recorded.merge!("bytes" => File.size(path), "sha256" => Digest::SHA256.file(path).hexdigest)
    write_json(report_path, report)
    store = AgentCodingTool::RunEvidenceStore.new(@data)
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      store.select(@first[:identity], artifacts: %w[final transcript], manager: "fixture-manager")
    end
    config = store.select(@first[:identity], artifacts: %w[final transcript], manager: "fixture-manager", shared: true)
    reader = AgentCodingTool::RunEvidenceReader.new(**config.transform_keys(&:to_sym))
    manifest = reader.call(@first[:identity].merge("operation" => "manifest", "revision" => nil), caller: "fixture-manager")
    manifest["handle"] = "direct-reader"
    assert_equal recorded["sha256"], manifest.dig("artifacts", "transcript", "sha256")
    assert_equal "complete", manifest.dig("artifacts", "final", "status")
    final_request = read_request(manifest).reject { |key, _| key == "handle" }
    assert_equal @first[:contents]["final"].byteslice(0, 16_384), reader.call(final_request, caller: "fixture-manager")["data"].unpack1("m0")
    digest, offset, response = Digest::SHA256.new, 0, nil
    loop do
      # The shared session reconstructs a reader for each request; cumulative
      # authorization/accounting remains owned by the admission ledger.
      request = read_request(manifest, "transcript", offset: offset).reject { |key, _| key == "handle" }
      response = AgentCodingTool::RunEvidenceReader.new(**config.transform_keys(&:to_sym)).call(request, caller: "fixture-manager")
      chunk = response.fetch("data").unpack1("m0")
      assert_operator chunk.bytesize, :<=, AgentCodingTool::RunEvidenceReader::MAX_CHUNK
      assert_equal Digest::SHA256.hexdigest(chunk), response["chunk_sha256"]
      digest.update(chunk)
      offset += chunk.bytesize
      break unless response["next_offset"]
    end
    assert_equal recorded["bytes"], offset
    assert_equal recorded["sha256"], digest.hexdigest
    assert_equal "complete", response["status"]
    File.open(path, "r+b") { |file| file.seek(-2, IO::SEEK_END); file.write("y") }
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      reader.call(read_request(manifest, "transcript").reject { |key, _| key == "handle" }, caller: "fixture-manager")
    end
    File.open(path, "r+b") { |file| file.seek(-2, IO::SEEK_END); file.write("}") }
    assert_equal recorded["sha256"], Digest::SHA256.file(path).hexdigest
    outside = File.join(@temporary, "foreign-transcript")
    File.write(outside, "private foreign source")
    File.rename(path, "#{path}.saved")
    begin
      %w[symlink fifo].each do |kind|
        kind == "symlink" ? File.symlink(outside, path) : File.mkfifo(path, 0o600)
        assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
          reader.call(read_request(manifest, "transcript").reject { |key, _| key == "handle" }, caller: "fixture-manager")
        end
        File.unlink(path)
      end
    ensure
      File.unlink(path) if File.exist?(path) || File.symlink?(path)
      File.rename("#{path}.saved", path)
    end
    report["status"] = "running"
    write_json(report_path, report)
    pending_config = store.select(@first[:identity], artifacts: %w[final transcript], manager: "fixture-manager", shared: true)
    pending_reader = AgentCodingTool::RunEvidenceReader.new(**pending_config.transform_keys(&:to_sym))
    pending_manifest = pending_reader.call(@first[:identity].merge("operation" => "manifest", "revision" => nil), caller: "fixture-manager").merge("handle" => "direct-reader")
    assert_equal "pending", pending_reader.call(read_request(pending_manifest, "transcript").reject { |key, _| key == "handle" }, caller: "fixture-manager")["status"]
    File.open(path, "ab") { |file| file.write(line) }
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      pending_reader.call(read_request(pending_manifest, "transcript").reject { |key, _| key == "handle" }, caller: "fixture-manager")
    end
    report["status"] = "exited"
    write_json(report_path, report)
    foreign = write_run(2, checkpoint: false)
    report["jsonl_path"] = File.join(foreign[:run], "stdout.jsonl")
    write_json(report_path, report)
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      store.select(@first[:identity], artifacts: %w[final transcript], manager: "fixture-manager", shared: true)
    end
    report["jsonl_path"] = path
    write_json(report_path, report)
    File.open(path, "wb") { |file| file.truncate(AgentCodingTool::RunEvidenceReader::MAX_TRANSCRIPT + 1) }
    unavailable = store.select(@first[:identity], artifacts: %w[final transcript], manager: "fixture-manager", shared: true)
    assert_equal "missing", unavailable.dig("approvals", "transcript", "status")
    assert_equal "transcript.scan_limit", unavailable.dig("approvals", "transcript", "reason")
    assert_equal "complete", unavailable.dig("approvals", "final", "status")
    File.open(path, "wb") do |file|
      file.write(@first[:contents]["transcript"])
      file.write('{' + 'x' * AgentCodingTool::RunEvidenceReader::MAX_FILE + "\n")
    end
    unavailable = store.select(@first[:identity], artifacts: %w[final transcript], manager: "fixture-manager", shared: true)
    assert_equal "transcript.record_limit", unavailable.dig("approvals", "transcript", "reason")
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

  # Fresh registration calls retain binary streams, argv and ambient settings.
  # Only the stream/exception boundary is doubled; real parsing also refuses.
  def test_registration_cli_preserves_streams_and_restores_environment
    environment = { "AGENT_CODING_TOOL_DATA_DIR" => @data, "OPENAI_TUNNEL_KEY" => nil, "TMPDIR" => @temporary }
    original_environment = ENV.to_h
    arguments = %w[evidence register --task FIXTURE]
    output, error, exit_code = registration_cli(*arguments, environment: environment)
    assert_equal 2, exit_code
    assert_empty output
    assert_equal "ERROR: evidence registration refused; check exact run, recorded fixture, package digest and bounded regular owned files.\n".b, error
    assert ENV.to_h == original_environment, "registration changed ambient environment"
    binary_call = lambda do |argv, **options|
      assert_equal arguments, argv
      assert_equal @data, options.fetch(:data_root)
      assert environment == environment.keys.to_h { |key| [key, ENV[key]] }, "registration environment overrides missing"
      options.fetch(:out).write("\x00\xff".b)
      options.fetch(:err).write("\xfe\x00".b)
      argv.clear
      7
    end
    AgentCodingTool::CLI.stub(:run, binary_call) do
      2.times do
        assert_equal ["\x00\xff".b, "\xfe\x00".b, 7], registration_cli(*arguments, environment: environment)
        assert_equal %w[evidence register --task FIXTURE], arguments
        assert ENV.to_h == original_environment, "registration changed ambient environment"
      end
    end
    exception = IOError.new("registration stream failure")
    AgentCodingTool::CLI.stub(:run, ->(*) { raise exception }) do
      assert_same exception, assert_raises(IOError) { registration_cli(*arguments, environment: environment) }
    end
    assert ENV.to_h == original_environment, "registration changed ambient environment"
    assert_raises(ArgumentError) { registration_cli("share", "tunnel", environment: environment) }
    assert ENV.to_h == original_environment, "registration changed ambient environment"
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

  # Preserves an oversized final message as a bounded, hashed prefix.
  def test_external_oversized_final_is_truncated_and_hashed
    FileUtils.mkdir_p(File.join(@data, "tasks"))
    File.write(File.join(@data, "tasks", "FIXTURE.yml"), YAML.dump("id" => "FIXTURE"))
    followup = AgentCodingTool::ExternalFollowup.new(@data)
    executable = fake_codex_path
    followup.define_singleton_method(:resolve_codex) { [executable, executable_facts(executable)] }
    status = Struct.new(:exitstatus, :termsig) { def signaled? = !termsig.nil? }.new(0, nil)
    capture_final = lambda do |final|
      followup.define_singleton_method(:run_process) do |argv, pipes|
        pipes.fetch(:out).write("stdout")
        pipes.fetch(:err).write("stderr")
        File.binwrite(argv.fetch(4), final)
        status
      end
      output = StringIO.new
      followup.capture("FIXTURE", ["codex", "exec", "fixture"], out: output, err: StringIO.new)
      JSON.parse(output.string.lines.last)
    end
    maximum = AgentCodingTool::RunEvidenceReader::MAX_FILE
    exact = "x".b * maximum
    boundary = capture_final.call(exact)
    boundary_identity = boundary.slice("task_id", "invocation_id").merge("source" => "external_codex_cli")
    boundary_config = AgentCodingTool::RunEvidenceStore.new(@data).select(boundary_identity,
      artifacts: ["final"], manager: "fixture", shared: true)
    boundary_spec = boundary_config.fetch("approvals").fetch("final")
    assert_equal "complete", boundary_spec.fetch("status")
    assert_equal maximum, boundary_spec.fetch("bytes")
    assert_equal Digest::SHA256.hexdigest(exact), boundary_spec.fetch("sha256")

    failed_status = Struct.new(:exitstatus, :termsig) { def signaled? = !termsig.nil? }.new(9, nil)
    followup.define_singleton_method(:run_process) do |_argv, pipes|
      pipes.fetch(:out).write("available stdout")
      pipes.fetch(:err).write("available stderr")
      failed_status
    end
    missing_output = StringIO.new
    followup.capture("FIXTURE", ["codex", "exec", "missing final"], out: missing_output, err: StringIO.new)
    missing_receipt = JSON.parse(missing_output.string.lines.last)
    missing_identity = missing_receipt.slice("task_id", "invocation_id").merge("source" => "external_codex_cli")
    missing_config = AgentCodingTool::RunEvidenceStore.new(@data).select(missing_identity,
      artifacts: ["final"], manager: "fixture", shared: true)
    assert_equal "missing", missing_config.dig("approvals", "final", "status")
    assert_equal "exited", missing_receipt.fetch("outcome")
    assert_equal 9, missing_receipt.fetch("exit_status")

    oversized = "x".b * (maximum + 1)
    receipt = capture_final.call(oversized)
    identity = receipt.slice("task_id", "invocation_id").merge("source" => "external_codex_cli")
    config = AgentCodingTool::RunEvidenceStore.new(@data).select(identity, artifacts: ["final"], manager: "fixture", shared: true)
    spec = config.fetch("approvals").fetch("final")
    retained = "x".b * maximum
    assert_equal "truncated", spec.fetch("status")
    assert_equal retained.bytesize, spec.fetch("bytes")
    assert_equal Digest::SHA256.hexdigest(retained), spec.fetch("sha256")
    assert_equal retained, File.binread(spec.fetch("path"))
  end

  # Exercises interrupt recovery only with a guarded live test-owned child.
  def test_native_external_followup_waits_for_interrupted_child_termination
    FileUtils.mkdir_p(File.join(@data, "tasks"))
    File.write(File.join(@data, "tasks", "FIXTURE.yml"), YAML.dump("id" => "FIXTURE"))
    share_path = File.join(@temporary, "followup-sharing")
    grant = @grant.merge("schema" => "agent-coding-tool-task-sharing/v2", "session_path" => share_path, "tasks" => [])
    AgentCodingTool::EvidenceSession.start(share_path, write_json(File.join(@temporary, "followup-grant.json"), grant))
    @session = AgentCodingTool::EvidenceSession.new(share_path)
    @session.sharing_ready
    @session.share_task("FIXTURE", seconds: 60)
    @adapter = AgentCodingTool::EvidenceAdapter.new(@session, err: StringIO.new)
    executable = fake_codex_path
    bin = File.join(@temporary, "codex-bin")
    Dir.mkdir(bin, 0o700)
    FileUtils.cp(executable, File.join(bin, "codex"))
    File.chmod(0o700, File.join(bin, "codex"))
    previous_path = ENV["PATH"]
    ENV["PATH"] = bin
    followup = AgentCodingTool::ExternalFollowup.new(@data)
    unregistered_final = File.join(@temporary, "unregistered-final")
    direct_out, direct_err, direct_status = ChildProcesses.capture("fake_codex",
      arguments: ["exec", "--json", "--output-last-message", unregistered_final], seconds: 5)
    assert direct_status.success?, direct_err.inspect
    assert_equal "fake codex stdout\x80".b, direct_out.b
    assert_equal "fake final\x00\xff".b, File.binread(unregistered_final)
    before_registration = tool({ "operation" => "discover", "task_id" => "FIXTURE" }).fetch("tasks").first.fetch("runs")
    assert_equal ["act_managed"], before_registration.map { |run| run.fetch("evidence_source") }
    assert @adapter.dispatch(rpc("tools/call", { "operation" => "select", "task_id" => "FIXTURE",
      "invocation_id" => "external-#{'f' * 32}" })).dig("result", "isError")
    pidfile = File.join(@temporary, "fake-codex.pid")
    output = StringIO.new
    spawned_pid = nil
    child_reaped = false
    runner = lambda do |argv, pipes|
      run_fake_codex(followup, File.realpath(File.join(bin, "codex")), argv, pipes)
    end
    followup.define_singleton_method(:run_process) { |argv, pipes| runner.call(argv, pipes) }
    successful_output = StringIO.new
    status = followup.capture("FIXTURE", ["codex", "exec", "--fixture-exit=9"], out: successful_output, err: StringIO.new)
    assert_equal 9, status.exitstatus
    complete_receipt = JSON.parse(successful_output.string.lines.last)
    complete_identity = complete_receipt.slice("task_id", "invocation_id").merge("source" => "external_codex_cli")
    complete_config = followup.select(complete_identity, artifacts: %w[final transcript stderr], manager: "fixture")
    complete_reader = AgentCodingTool::RunEvidenceReader.new(**complete_config.transform_keys(&:to_sym))
    complete_manifest = complete_reader.call(complete_identity.slice("task_id", "invocation_id").merge(
      "operation" => "manifest", "revision" => nil), caller: "fixture")
    { "final" => "fake final\x00\xff".b, "transcript" => "fake codex stdout\x80".b,
      "stderr" => "fake codex stderr\x00".b }.each do |artifact, source_bytes|
      response = complete_reader.call(complete_identity.slice("task_id", "invocation_id").merge(
        "operation" => "read", "revision" => complete_manifest.fetch("revision"), "artifact" => artifact,
        "offset" => 0, "length" => 1024), caller: "fixture")
      assert_equal source_bytes, response.fetch("data").unpack1("m0")
      assert_equal Digest::SHA256.hexdigest(source_bytes), response.fetch("sha256")
    end
    capture_thread = Thread.new do
      followup.capture("FIXTURE", ["codex", "exec", "--fixture-pidfile=#{pidfile}"], out: output, err: StringIO.new)
    end
    Timeout.timeout(5) { sleep 0.01 until File.file?(pidfile) }
    child_pid = Integer(File.read(pidfile))
    spawned_pid = followup.instance_variable_get(:@writer_pid)
    assert_equal child_pid, spawned_pid
    capture_thread.raise(Interrupt, "owned test interruption")
    assert_nil capture_thread.value
    receipt = JSON.parse(output.string.lines.last)
    assert_equal "pending", receipt.fetch("capture_status")
    assert_equal "unknown", receipt.fetch("outcome")
    source = File.join(@data + "-followups", "captures", "FIXTURE", receipt.fetch("invocation_id").delete_prefix("external-"))
    pending = JSON.parse(File.binread(File.join(source, "capture.json")))
    assert_equal child_pid, pending.fetch("writer_pid")
    error = assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      followup.register("FIXTURE", receipt.fetch("invocation_id"), receipt.fetch("receipt_sha256"))
    end
    assert_equal "followup.writer_active", error.message
    retained_record = File.binread(File.join(source, "capture.json"))
    uncertain = JSON.parse(retained_record).merge("writer_pid" => "uncertain")
    File.binwrite(File.join(source, "capture.json"), JSON.generate(uncertain))
    unknown_sha = Digest::SHA256.file(File.join(source, "capture.json")).hexdigest
    error = assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      followup.register("FIXTURE", receipt.fetch("invocation_id"), unknown_sha)
    end
    assert_equal "followup.writer_unknown", error.message
    File.binwrite(File.join(source, "capture.json"), retained_record)
    visible = followup.discover("FIXTURE").map { |run| run.fetch("invocation_id") }
    assert_equal [complete_receipt.fetch("invocation_id")], visible
    assert_equal 1, Process.kill("TERM", child_pid)
    assert_equal child_pid, Process.waitpid(child_pid)
    child_reaped = true
    registered = followup.register("FIXTURE", receipt.fetch("invocation_id"), receipt.fetch("receipt_sha256"))
    assert_equal "incomplete", registered.fetch("status")
    assert_equal "unknown", registered.fetch("outcome")
    discovered = followup.discover("FIXTURE").find { |run| run.fetch("invocation_id") == receipt.fetch("invocation_id") }
    refute_nil discovered
    assert_equal "external_codex_cli", discovered.fetch("evidence_source")
    assert_equal "unknown", discovered.fetch("outcome")
    assert_nil discovered.fetch("exit_status")
    config = followup.select(discovered.slice("task_id", "source", "invocation_id"),
      artifacts: %w[final transcript stderr], manager: "fixture")
    manifest = AgentCodingTool::RunEvidenceReader.new(**config.transform_keys(&:to_sym)).call(
      discovered.slice("task_id", "invocation_id").merge("operation" => "manifest", "revision" => nil), caller: "fixture")
    assert_equal "pending", manifest.dig("artifacts", "transcript", "status")
    assert_equal Digest::SHA256.hexdigest("fake codex stdout\x80".b), manifest.dig("artifacts", "transcript", "sha256")
    response = AgentCodingTool::RunEvidenceReader.new(**config.transform_keys(&:to_sym)).call(
      discovered.slice("task_id", "invocation_id").merge("operation" => "read", "revision" => manifest.fetch("revision"),
        "artifact" => "transcript", "offset" => 0, "length" => 1024), caller: "fixture")
    assert_equal "fake codex stdout\x80".b, response.fetch("data").unpack1("m0")
  ensure
    ENV["PATH"] = previous_path if defined?(previous_path)
    owned_pid = spawned_pid || followup&.instance_variable_get(:@writer_pid)
    if owned_pid && !child_reaped
      begin
        Process.kill("TERM", owned_pid)
        Process.waitpid(owned_pid)
      rescue Errno::ESRCH, Errno::ECHILD
      end
    end
    capture_thread&.join(5)
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

  # A forced gate's durable command receipt remains readable when final receipt
  # persistence fails. Real scoped dispatch keeps post-check uncertainty and old
  # selections, rejects phase tampering, and leaves legacy grants unchanged.
  def test_shared_command_receipt_survives_missing_final_without_claiming_acceptance
    FileUtils.mkdir_p(File.join(@data, "tasks"))
    File.write(File.join(@data, "tasks", "FIXTURE.yml"), YAML.dump("id" => "FIXTURE", "title" => "Fixture"))
    path = File.join(@temporary, "command-sharing")
    grant = @grant.merge("schema" => "agent-coding-tool-task-sharing/v2", "session_path" => path, "tasks" => [])
    AgentCodingTool::EvidenceSession.start(path, write_json(File.join(@temporary, "command-grant.json"), grant))
    @session = AgentCodingTool::EvidenceSession.new(path)
    @session.sharing_ready
    @session.share_task("FIXTURE", seconds: 60)
    @adapter = AgentCodingTool::EvidenceAdapter.new(@session, err: StringIO.new)
    directory = File.join("#{@data}-runs", "checkpoints", "FIXTURE", "1".rjust(32, "0"))
    final_path = File.join(directory, "gate-0001.finished.json")
    receipt = JSON.parse(File.binread(final_path))
    File.unlink(final_path)
    receipt.merge!("receipt_phase" => "command_finished", "post_check" => "not_checked", "candidate_validation" => "unknown")
    bytes = "diagnostic\x00\xff".b
    output_path = File.join(directory, "gate-0001.stdout")
    File.binwrite(output_path, bytes)
    receipt["output"] = { "status" => "complete", "streams" => { "stdout" => {
      "file" => File.basename(output_path), "status" => "complete", "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes) } } }
    write_json(File.join(directory, "gate-0001.started.json"), receipt.merge("receipt_phase" => "started"))
    command_path = write_json(File.join(directory, "gate-0001.command.json"), receipt)
    manifest = select
    command_name = "validation:gate-0001.command.json"
    assert_equal [command_name], manifest.fetch("artifacts").keys.grep(/\Avalidation:/)
    retained = JSON.parse(tool(read_request(manifest, command_name))["data"].unpack1("m0"))
    assert_equal "not_checked", retained["post_check"]
    assert_equal "unknown", retained["candidate_validation"]
    assert_equal 1, retained.dig("command_outcome", "exit_code")
    assert_equal bytes, tool(read_request(manifest, "validation_output:gate-0001.stdout"))["data"].unpack1("m0")
    legacy = AgentCodingTool::RunEvidenceStore.new(@data).select(@first[:identity], artifacts: %w[validation], manager: "fixture-manager")
    assert_empty legacy.fetch("approvals").keys.grep(/\.command\.json\z/)
    write_json(final_path, receipt.merge("receipt_phase" => "finished", "post_check" => "verified", "candidate_validation" => "failed"))
    tool({ "operation" => "refresh", "task_id" => "FIXTURE" })
    refreshed = select
    assert_equal ["validation:gate-0001.finished.json"], refreshed.fetch("artifacts").keys.grep(/\Avalidation:/)
    assert_equal "unknown", JSON.parse(tool(read_request(manifest, command_name))["data"].unpack1("m0"))["candidate_validation"]
    File.unlink(final_path)
    write_json(command_path, receipt.merge("receipt_phase" => "finished"))
    assert @adapter.dispatch(rpc("tools/call", @first[:identity].merge("operation" => "select"))).dig("result", "isError")
  end

  # Version-two selection/manifest pages remain immutable across a newer run.
  # Pending artifacts and per-invocation receipts use the real store and reader;
  # only the worker/checkpoint producer is a declared deterministic fixture.
  def test_shared_discovery_refresh_pagination_and_exact_invocation_binding
    FileUtils.mkdir_p(File.join(@data, "tasks"))
    File.write(File.join(@data, "tasks", "FIXTURE.yml"), YAML.dump("id" => "FIXTURE", "title" => "Fixture"))
    path = File.join(@temporary, "task-sharing")
    grant = @grant.merge("schema" => "agent-coding-tool-task-sharing/v2", "session_path" => path, "tasks" => [])
    AgentCodingTool::EvidenceSession.start(path, write_json(File.join(@temporary, "sharing-grant.json"), grant))
    @session = AgentCodingTool::EvidenceSession.new(path)
    @session.sharing_ready
    @session.share_task("FIXTURE", seconds: 60)
    @adapter = AgentCodingTool::EvidenceAdapter.new(@session, err: StringIO.new)
    directory = File.join("#{@data}-runs", "checkpoints", "FIXTURE", "1".rjust(32, "0"))
    original = JSON.parse(File.binread(File.join(directory, "gate-0001.finished.json")))
    18.times do |number|
      token = (number + 2).to_s(16).rjust(4, "0")
      write_json(File.join(directory, "gate-#{token}.finished.json"), original.merge("invocation_id" => token))
    end
    assert_equal ["FIXTURE"], tool({ "operation" => "discover" }).fetch("tasks").map { |task| task["task_id"] }
    discovered = tool({ "operation" => "discover", "task_id" => "FIXTURE" }).fetch("tasks").first
    assert_equal @first[:identity], discovered.fetch("runs").first.slice(*AgentCodingTool::RunEvidenceReader::IDENTITIES)
    manifest = select
    assert_equal 16, manifest.fetch("artifacts").length
    page = tool(@first[:identity].merge("operation" => "manifest", "handle" => manifest["handle"],
      "revision" => manifest["revision"], "offset" => manifest.fetch("next_offset")))
    assert_nil page["next_offset"]
    assert_equal manifest["artifact_total"], manifest["artifacts"].length + page["artifacts"].length
    second = write_run(2, status: "running")
    refreshed = tool({ "operation" => "refresh", "task_id" => "FIXTURE" }).fetch("tasks").first
    assert_equal [1, 2], refreshed.fetch("runs").map { |run| run["attempt"] }
    pending = select(second)
    assert_equal "pending", pending.dig("artifacts", "final", "status")
    assert_equal "codex-1", tool(read_request(manifest)).dig("binding", "session_id")

    # Deterministic fake Codex children exercise actual capture, durable host
    # registration, refresh, exact selection and bounded binary reader paths.
    followup = AgentCodingTool::ExternalFollowup.new(@data)
    executable = fake_codex_path
    followup.define_singleton_method(:resolve_codex) { [executable, executable_facts(executable)] }
    fake_status = Struct.new(:exitstatus, :termsig) do
      def signaled? = !termsig.nil?
    end
    sources = []
    captures = []
    [0, 9].each_with_index do |exit_code, index|
      final = ("final-#{index}\x00\xff".b + "f" * 17_000)
      stdout, stderr = "stdout-#{index}\x80".b, "stderr-#{index}\x00".b
      sources << { "final" => final, "transcript" => stdout, "stderr" => stderr }
      captured_out = StringIO.new
      followup.define_singleton_method(:run_process) do |argv, pipes|
        raise "capture identity was not emitted before launch" if captured_out.string.empty?
        pipes.fetch(:out).write(stdout)
        pipes.fetch(:err).write(stderr)
        File.binwrite(argv[4], final)
        fake_status.new(exit_code, nil)
      end
      status = followup.capture("FIXTURE", ["codex", "exec", "fixture prompt"], out: captured_out, err: StringIO.new)
      assert_equal exit_code, status.exitstatus
      capture_lines = captured_out.string.lines.map { |line| JSON.parse(line) }
      assert_equal "pending", capture_lines.first.fetch("capture_status")
      captures << capture_lines.last
      identity = captures.last.slice("task_id", "invocation_id")
      assert_equal %w[invocation_id operation task_id], identity.merge("operation" => "select").keys.sort
      refute AgentCodingTool::EvidenceAdapter.schema.fetch("properties").key?("source")
      manifest = tool(identity.merge("operation" => "select"))
      assert_equal "external_codex_cli", manifest.dig("binding", "source")
      %w[final transcript stderr].each do |artifact|
        entry = manifest.dig("artifacts", artifact)
        assert_equal Digest::SHA256.hexdigest(sources.last.fetch(artifact)), entry.fetch("sha256")
        assert_equal sources.last.fetch(artifact).bytesize, entry.fetch("bytes")
        chunk = tool(read_request(manifest, artifact))
        data = chunk.fetch("data").unpack1("m0")
        if chunk["next_offset"]
          chunk = tool(read_request(manifest, artifact, offset: chunk.fetch("next_offset")))
          data << chunk.fetch("data").unpack1("m0")
        end
        assert_equal sources.last.fetch(artifact), data
      end
      assert_equal exit_code, tool(read_request(manifest))["worker_exit_status"]
      if index.zero?
        @pinned_followup = manifest
      else
        pinned = tool(read_request(@pinned_followup))
        pinned_data = pinned.fetch("data").unpack1("m0")
        if pinned["next_offset"]
          pinned = tool(read_request(@pinned_followup, "final", offset: pinned.fetch("next_offset")))
          pinned_data << pinned.fetch("data").unpack1("m0")
        end
        assert_equal sources.first.fetch("final"), pinned_data
      end
    end
    @adapter = AgentCodingTool::EvidenceAdapter.new(@session, err: StringIO.new)
    refreshed = tool({ "operation" => "refresh", "task_id" => "FIXTURE" }).fetch("tasks").first
    assert_equal 4, refreshed.fetch("runs").length
    assert_equal %w[act_managed act_managed external_codex_cli external_codex_cli], refreshed.fetch("runs").map { |run| run.fetch("evidence_source") }
    failed = refreshed.fetch("runs").find { |run| run["invocation_id"] == captures.last.fetch("invocation_id") }
    assert_equal "exited", failed.fetch("outcome")
    assert_equal 9, failed.fetch("exit_status")
    external_request = { "operation" => "select", "task_id" => "FIXTURE", "invocation_id" => captures.first.fetch("invocation_id") }
    assert @adapter.dispatch(rpc("tools/call", external_request.merge("source" => "external_codex_cli"))).dig("result", "isError")
    handoff_path = File.join(@first.fetch(:run), "handoff.json")
    original_handoff = File.binread(handoff_path)
    handoff = JSON.parse(original_handoff)
    handoff["invocation_id"] = captures.first.fetch("invocation_id")
    write_json(handoff_path, handoff)
    assert @adapter.dispatch(rpc("tools/call", external_request)).dig("result", "isError")
    File.binwrite(handoff_path, original_handoff)
    assert @adapter.dispatch(rpc("tools/call", { "operation" => "select", "task_id" => "FIXTURE",
      "invocation_id" => "external-#{'0' * 32}" })).dig("result", "isError")
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      followup.register("FIXTURE", captures.first.fetch("invocation_id"), captures.first.fetch("receipt_sha256"))
    end
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      followup.register("OTHER", captures.first.fetch("invocation_id"), captures.first.fetch("receipt_sha256"))
    end
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      followup.register("FIXTURE", captures.first.fetch("invocation_id"), "0" * 64)
    end
    stale_output = "stale source bytes".b
    followup.define_singleton_method(:run_process) do |argv, pipes|
      pipes.fetch(:out).write("out".b)
      pipes.fetch(:err).write("err".b)
      File.binwrite(argv[4], "final".b)
      fake_status.new(0, nil)
    end
    stale_console = StringIO.new
    followup.capture("FIXTURE", ["codex", "exec", "fixture"], out: stale_console, err: StringIO.new)
    stale_identity = JSON.parse(stale_console.string.lines.last)
    stale_directory = File.join(@data + "-followups", "captures", "FIXTURE", stale_identity.fetch("invocation_id").delete_prefix("external-"))
    FileUtils.remove_entry(File.join(@data + "-followups", "registrations", "FIXTURE", stale_identity.fetch("invocation_id")))
    File.binwrite(File.join(stale_directory, "final"), stale_output)
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      followup.register("FIXTURE", stale_identity.fetch("invocation_id"), stale_identity.fetch("receipt_sha256"))
    end
    symlink_console = StringIO.new
    followup.capture("FIXTURE", ["codex", "exec", "fixture"], out: symlink_console, err: StringIO.new)
    symlink_identity = JSON.parse(symlink_console.string.lines.last)
    symlink_source = File.join(@data + "-followups", "captures", "FIXTURE", symlink_identity.fetch("invocation_id").delete_prefix("external-"))
    symlink_registration = File.join(@data + "-followups", "registrations", "FIXTURE", symlink_identity.fetch("invocation_id"))
    FileUtils.remove_entry(symlink_registration)
    outside = File.join(@temporary, "followup-outside")
    File.binwrite(outside, "foreign source", perm: 0o600)
    stream_path = File.join(symlink_source, "gate-external.stdout")
    File.rename(stream_path, "#{stream_path}.saved")
    begin
      File.symlink(outside, stream_path)
      assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
        followup.register("FIXTURE", symlink_identity.fetch("invocation_id"), symlink_identity.fetch("receipt_sha256"))
      end
    ensure
      File.unlink(stream_path)
      File.rename("#{stream_path}.saved", stream_path)
    end
    incomplete = File.join(@data + "-followups", "registrations", "FIXTURE", ".incomplete.tmp")
    Dir.mkdir(incomplete, 0o700)
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { followup.discover("FIXTURE") }
    FileUtils.remove_entry(incomplete)
    recovery_out = StringIO.new
    followup.define_singleton_method(:run_process) do |argv, pipes|
      pipes.fetch(:out).write("recovered stdout".b)
      pipes.fetch(:err).write("recovered stderr".b)
      File.binwrite(argv[4], "recovered final".b)
      fake_status.new(0, nil)
    end
    followup.capture("FIXTURE", ["codex", "exec", "fixture"], out: recovery_out, err: StringIO.new)
    pending_receipt, finished_receipt = recovery_out.string.lines.map { |line| JSON.parse(line) }
    recovery_source = File.join(@data + "-followups", "captures", "FIXTURE", pending_receipt.fetch("invocation_id").delete_prefix("external-"))
    finished_record = JSON.parse(File.binread(File.join(recovery_source, "capture.json")))
    started_record = finished_record.slice("schema", "task_id", "invocation_id", "executable", "started_at")
      .merge("status" => "pending", "outcome" => "unknown", "exit_status" => nil, "signal" => nil)
    File.binwrite(File.join(recovery_source, "capture.json"), JSON.generate(started_record))
    FileUtils.remove_entry(File.join(@data + "-followups", "registrations", "FIXTURE", pending_receipt.fetch("invocation_id")))
    recovery_cli_out, recovery_cli_err = StringIO.new, StringIO.new
    assert_equal 0, AgentCodingTool::CLI.run(["evidence", "register-followup", "--task", "FIXTURE",
      "--invocation", pending_receipt.fetch("invocation_id"), "--sha256", pending_receipt.fetch("receipt_sha256")],
      data_root: @data, out: recovery_cli_out, err: recovery_cli_err)
    recovered = JSON.parse(recovery_cli_out.string)
    assert_equal "incomplete", recovered.fetch("capture_status")
    assert_equal "unknown", recovered.fetch("outcome")
    assert_equal finished_receipt.fetch("invocation_id"), recovered.fetch("invocation_id")
    cli_status = Struct.new(:exitstatus, :termsig).new(9, nil)
    cli_capture = Object.new
    cli_capture.define_singleton_method(:capture) do |task, command, out:, err:|
      raise "wrong task" unless task == "FIXTURE"
      raise "wrong codex argv" unless command == ["codex", "exec", "--sandbox", "workspace-write", "follow-up"]
      cli_status
    end
    cli_out, cli_err = StringIO.new, StringIO.new
    cli_result = nil
    AgentCodingTool::ExternalFollowup.stub(:new, cli_capture) do
      cli_result = AgentCodingTool::CLI.run(%w[evidence capture --task FIXTURE -- codex exec --sandbox workspace-write follow-up],
        data_root: @data, out: cli_out, err: cli_err)
      assert_equal 2, AgentCodingTool::CLI.run(%w[evidence capture --task FIXTURE codex exec follow-up],
        data_root: @data, out: cli_out, err: cli_err)
    end
    assert_equal 9, cli_result
    FileUtils.remove_entry(File.join(@data + "-followups", "registrations", "FIXTURE", captures.first.fetch("invocation_id")))
    assert @adapter.dispatch(rpc("tools/call", captures.first.slice("task_id", "invocation_id").merge("operation" => "select")))
      .dig("result", "isError")
    receipt_path = File.join(directory, "gate-0001.finished.json")
    write_json(receipt_path, original.merge("invocation_id" => "foreign-invocation"))
    refused = @adapter.dispatch(rpc("tools/call", @first[:identity].merge("operation" => "select")))
    assert refused.dig("result", "isError")
  end

  # Runs only registration policy checks through a fresh production CLI with
  # independent binary output/error streams and the existing broker authority.
  # Returns [stdout, stderr, integer exit code]; exceptions propagate after ENV
  # restoration. Other commands raise ArgumentError before changing settings.
  def registration_cli(*arguments, environment:)
    raise ArgumentError, "expected evidence register" unless arguments.take(2) == %w[evidence register]
    previous = environment.keys.to_h { |key| [key, ENV[key]] }
    environment.each { |key, value| ENV[key] = value }
    output, error = StringIO.new("".b), StringIO.new("".b)
    exit_code = AgentCodingTool::CLI.run(arguments.dup, data_root: @data,
      out: output, err: error, transport: @sharing_broker)
    [output.string, error.string, exit_code]
  ensure
    previous&.each { |key, value| ENV[key] = value }
  end

  # Invokes the public CLI with binary-preserving observers and exact exit status.
  # Only declared native cases call this helper; ordinary tests spawn nothing.
  def cli(*arguments)
    output, error, status = ChildProcesses.capture("evidence_cli", arguments: ["plain", "evidence", *arguments], seconds: 8)
    assert status.success?, "CLI #{arguments.first} failed: #{error}"
    JSON.parse(output)
  end

  # Observes live public status within one deadline. Only the exact nonblocking
  # busy refusal is retried; persistent contention, other failures and bad JSON
  # still fail. Each fresh CLI keeps the genuine ledger and child-process guard.
  def cli_status_when_available(path, seconds: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    busy = "ERROR: evidence session refused (session.busy); check private grant, exact run identity and session status\n"
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      flunk "CLI status remained busy after #{seconds}s" unless remaining.positive?
      output, error, status = ChildProcesses.capture("evidence_cli",
        arguments: ["plain", "evidence", "status", "--session", path], seconds: remaining)
      unless status.exitstatus == 2 && output.empty? && error == busy
        assert status.success?, "CLI status failed: #{error}"
        return JSON.parse(output)
      end
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      IO.select(nil, nil, nil, [0.01, remaining].min) if remaining.positive?
    end
  end

  # Yields live pipes and a genuine waiter for one exact public evidence child.
  # The caller owns EOF/signals and bounded waits; the permit preserves coverage.
  def evidence_process(*arguments, mode: "plain", environment: {}, cwd: nil, &block)
    options = { pgroup: true }
    options[:chdir] = cwd if cwd
    approval = ChildProcesses.permit("evidence_cli", arguments: [mode, *arguments],
      environment: environment, options: options)
    pipes = NoGitExecution.with_permit(approval) do
      Open3.popen3(approval.environment, *approval.argv, **approval.options)
    end
    block.call(*pipes)
  ensure
    if pipes
      pipes.first(3).each { |pipe| pipe.close unless pipe.closed? }
      unless pipes.last.join(8)
        Process.kill("KILL", -pipes.last.pid) rescue Errno::ESRCH
        pipes.last.join
        raise Timeout::Error, "owned evidence child did not finish"
      end
    end
  end

  # Real kernel contention is released only after a fresh public CLI observes
  # failed flock. No sleeps, simulated ledger operations, ps or tunnel startup.
  # Persistent contention refuses, preserving accounting and the competing lock.
  def test_native_stop_serializes_once_and_refuses_persistent_contention
    @session.admit
    @session.charge(wire: 123, decoded: 45)
    before = @session.status
    command = ["evidence", "stop", "--session", @session_path]
    File.open(File.join(@session_path, "lock"), File::RDWR) do |lock|
      assert lock.flock(File::LOCK_EX | File::LOCK_NB)
      output, error, status = ChildProcesses.capture("evidence_cli", arguments: ["flock", *command], seconds: 8)
      refute status.success?
      assert_empty output
      assert_includes error, "session.busy"
      refute JSON.parse(File.binread(File.join(@session_path, "state.json")))["stopped"]
      evidence_process(*command, mode: "flock") do |input, output, error, waiter|
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
    command = ["evidence", "serve", "--session", path]
    evidence_process(*command) do |input, output, error, waiter|
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
    evidence_process("evidence", "serve", "--session", @session_path) do |input, output, error, waiter|
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
    evidence_process("evidence", "serve", "--session", expiry_path) do |_input, output, error, waiter|
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
    source = File.binread(File.join(ChildProcesses::FIXTURES, "tunnel_client.rb"))
    File.write(client, source, perm: 0o700)
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
    arguments = ["evidence", "open",
      "--session", path, "--grant", grant_path, "--env-file", @dotenv, "--client", client, "--runtime-dir", @runtime]
    environment = { "OPENAI_TUNNEL_KEY" => nil, "CONTROL_PLANE_API_KEY" => nil, "OTHER_SECRET" => nil,
      "ACT_FIXTURE_TUNNEL_CLIENT" => client }
    evidence_process(*arguments, mode: controller_loss ? "controller_loss" : "plain",
      environment: environment, cwd: @temporary) do |input, output, error, waiter|
      begin
        assert IO.select([output], [], [], 5), "public tunnel startup did not finish"
        line = output.gets
        assert line, "public tunnel startup refused before READY: #{error.read unless line}"
        assert_equal "ready", JSON.parse(line)["status"]
        wire = Dir.chdir(path) { UNIXSocket.new("wire") }
        yield wire, waiter, path
      ensure
        AgentCodingTool::EvidenceSession.new(path).stop if File.exist?(File.join(path, "state.json"))
        wire&.close unless wire&.closed?
        input.close
        status = Timeout.timeout(5) { waiter.value }
        assert status.exited? || status.signaled?
        # The client must reap its real adapter before the owner can reap it.
        # Missing evidence also detects forced cleanup that interrupts that wait.
        reaped_path = File.join(path, "fixture-adapter-reaped.json")
        assert File.file?(reaped_path), "tunnel client exited before reaping its adapter"
        reaped = JSON.parse(File.binread(reaped_path))
        assert_operator reaped.fetch("pid"), :>, 0
        assert reaped.fetch("exit_code").is_a?(Integer) || reaped.fetch("signal").is_a?(Integer)
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
    output, error, status = ChildProcesses.capture("evidence_cli", arguments: ["help_no_dotenv"],
      environment: { "OPENAI_TUNNEL_KEY" => nil }, seconds: 5)
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
      assert_equal 2, cli_status_when_available(path)["selected_runs"].length
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

  # Proves independent expiry/controller-loss cleanup, endpoint collision and
  # nonrenewable session accounting through actual public process boundaries.
  # An unrelated live child is a sentinel and must survive every owned teardown.
  def test_native_tunnel_lifecycle_and_exclusive_ownership
    client = tunnel_fixture
    release_read, release_write = IO.pipe
    ready_read, ready_write = IO.pipe
    sentinel = nil
    approval = ChildProcesses.permit("manual_worker", arguments: [File.join(@temporary, "unrelated-sentinel"), "30"])
    File.open(File::NULL, "w") do |null|
      sentinel = NoGitExecution.with_permit(approval) do
        Process.spawn(approval.environment, *approval.argv, in: release_read, out: ready_write, err: null)
      end
    end
    release_read.close
    ready_write.close
    assert_equal "ready\n", Timeout.timeout(2) { ready_read.gets }
    with_tunnel(client, "controller-loss", controller_loss: true) do |wire, waiter, path|
      wire.write(JSON.generate(rpc("ping")) + "\n")
      assert IO.select([wire], [], [], 3), "lifecycle probe response missing"
      assert JSON.parse(wire.gets)["result"]
      # The live adapter may briefly hold the ledger lock between observations.
      before = cli_status_when_available(path)
      arguments = ["evidence", "open",
        "--session", path, "--grant", File.join(@temporary, "controller-loss-grant.json"),
        "--env-file", @dotenv, "--client", client, "--runtime-dir", @runtime]
      output, error, status = ChildProcesses.capture("evidence_cli", arguments: ["plain", *arguments],
        environment: { "OPENAI_TUNNEL_KEY" => nil }, seconds: 5)
      refute status.success?
      assert_empty output
      assert_includes error, "tunnel.session_reused"
      assert_equal "active", cli_status_when_available(path)["status"]
      # A separately approved new admission still cannot take this endpoint.
      occupied = File.join(@temporary, "occupied")
      proposal = @grant.merge("session_path" => occupied)
      write_json(File.join(@temporary, "occupied-grant.json"), proposal)
      occupied_arguments = arguments.map { |value| value == path ? occupied : value == File.join(@temporary, "controller-loss-grant.json") ? File.join(@temporary, "occupied-grant.json") : value }
      _output, error, status = ChildProcesses.capture("evidence_cli", arguments: ["plain", *occupied_arguments],
        environment: { "OPENAI_TUNNEL_KEY" => nil }, seconds: 5)
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
      _output, error, status = ChildProcesses.capture("evidence_cli", arguments: ["plain", *arguments],
        environment: { "OPENAI_TUNNEL_KEY" => nil }, seconds: 5)
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
      Process.kill("TERM", sentinel) rescue Errno::ESRCH
      Process.waitpid(sentinel) rescue Errno::ECHILD
    end
    [release_read, release_write, ready_read, ready_write].compact.each { |pipe| pipe.close unless pipe.closed? }
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
      arguments = ["evidence", "open",
        "--session", path, "--grant", grant_path, "--env-file", @dotenv, "--client", client, "--runtime-dir", @runtime]
      evidence_process(*arguments, environment: { "OPENAI_TUNNEL_KEY" => nil, "ACT_FIXTURE_TUNNEL_CLIENT" => client }) do |input, output, error, waiter|
        input.close
        if name == "stopped-startup"
          Timeout.timeout(3) { IO.select(nil, nil, nil, 0.02) until File.exist?(File.join(path, "tunnel.json")) }
          cli("stop", "--session", path)
        end
        refute Timeout.timeout(4) { waiter.value }.success?
        assert_empty output.read
        diagnostics = error.read
        refute_includes diagnostics, "wrong-synthetic-delivery"
        receipt_path = File.join(path, "tunnel-result.json")
        assert File.file?(receipt_path), "tunnel receipt absent: #{diagnostics}"
        result = JSON.parse(File.binread(receipt_path))
        assert_equal "readiness", result["stage"]
        assert_includes %w[expired stopped], result["reason"]
        assert_equal "not_attested", result["retrieval"]
        assert_equal "stopped", result["admission_stop"]
        assert_equal 0, cli("status", "--session", path)["decoded_bytes"]
      end
    end
  end

  # Composes local source consent with the actual configured adapter over the
  # existing tunnel. Only hosted transport and external Git metadata are fakes;
  # the remote client uses no filesystem shortcut to source or run contents.
  def test_native_source_and_task_share_continuous_public_journey
    code = File.join(@temporary, "code")
    roots = %w[alpha beta].to_h do |name|
      root = SourceFixture.repository(File.join(code, name),
        { "main.rb" => "RelatedSymbol #{name}\n" * 2000, ".env.local" => "SOURCE_CANARY_ENV",
          "credentials.json" => "SOURCE_CANARY_TRACKED", ".config/notify.yml" => "SOURCE_CANARY_NOTIFY" })
      File.write(File.join(root, "untracked.rb"), "SOURCE_CANARY_UNTRACKED")
      [name, root]
    end
    SourceFixture.repository(File.join(code, "private-sibling"), { "main.rb" => "SOURCE_CANARY_SIBLING" })
    FileUtils.mkdir_p(File.join(code, ".config"))
    File.write(File.join(code, ".config", "notify.yml"), "SOURCE_CANARY_CODE_CONFIG")
    File.symlink(File.join(code, "private-sibling", "main.rb"), File.join(roots.fetch("alpha"), "escape.rb"))
    File.mkfifo(File.join(roots.fetch("alpha"), "special.rb"))
    index_path = File.join(roots.fetch("alpha"), ".git", "index")
    index = JSON.parse(File.read(index_path))
    %w[escape.rb special.rb].each { |name| index[name] = index.fetch("main.rb") }
    File.write(index_path, JSON.generate(index))
    FileUtils.mkdir_p(File.join(@data, "tasks"))
    File.write(File.join(@data, "tasks", "FIXTURE.yml"), YAML.dump("id" => "FIXTURE", "title" => "fixture", "goal" => "fixture"))
    client = tunnel_fixture
    environment = { "AGENT_CODING_TOOL_DATA_DIR" => @data, "OPENAI_TUNNEL_KEY" => nil }
    run_cli = lambda do |*arguments, success: true|
      output, error, status = ChildProcesses.capture("evidence_cli", arguments: ["plain", "share", *arguments],
        environment: environment, seconds: 10)
      assert_equal success, status.success?, error
      success ? JSON.parse(output) : error
    end
    run_cli.call("setup", "--env-file", @dotenv, "--client", client, "--runtime-dir", @runtime,
      "--account", "fixture-account", "--workspace", "fixture-workspace", "--endpoint", "tunnel_fixture/main")
    2.times do |iteration|
      evidence_process("share", "tunnel", "--min", "30",
        environment: environment.merge("ACT_FIXTURE_TUNNEL_CLIENT" => client)) do |input, output, error, waiter|
        begin
          assert IO.select([output], [], [], 5), "startup missing"
          assert_equal [], JSON.parse(output.gets)["tasks"]
          path = JSON.parse(File.binread("#{@data}-sharing/active.json")).fetch("session")
          assert IO.select([output], [], [], 5), "readiness missing"
          assert_equal "ready", JSON.parse(output.gets)["status"]
          path = JSON.parse(File.binread("#{@data}-sharing/active.json")).fetch("session")
          wire = Dir.chdir(path) { UNIXSocket.new("wire") }
          exchange = lambda do |arguments, source: true, success: true|
            request = rpc("tools/call", arguments)
            request.fetch("params")["name"] = "read_source" if source
            wire.write(JSON.generate(request) + "\n")
            wire.flush
            assert IO.select([wire], [], [], 5), "response missing"
            frame = wire.gets
            assert frame, "adapter closed"
            refute_includes frame, @temporary if source
            refute_includes frame, "SOURCE_CANARY"
            result = JSON.parse(frame).fetch("result")
            assert_equal !success, result.fetch("isError"), result.inspect
            success ? JSON.parse(result.dig("content", 0, "text")) : result
          end
          assert_empty exchange.call({ "operation" => "discover" }).fetch("repositories")
          assert_empty exchange.call({ "operation" => "discover" }, source: false).fetch("tasks")
          exchange.call({ "operation" => "read", "repository" => "alpha", "path" => "main.rb" }, success: false)
          if iteration.zero?
            run_cli.call("FIXTURE")
            assert_empty exchange.call({ "operation" => "discover" }).fetch("repositories")
            run_cli.call("revoke", "FIXTURE")
            roots.each do |name, root|
              grant = run_cli.call("source", "grant", name, "--code-root", code, "--root", root)
              assert_equal "granted", grant["status"]
            end
            assert_empty exchange.call({ "operation" => "discover" }, source: false).fetch("tasks")
            exchange.call(@first[:identity].merge("operation" => "select"), source: false, success: false)
            assert_equal %w[alpha beta], exchange.call({ "operation" => "discover" }).fetch("repositories").map { |entry| entry["repository"] }
            status = run_cli.call("status")
            assert_equal roots, status.fetch("sources").transform_values { |scope| scope["root"] }
            first = nil
            roots.each_key do |name|
              listed = exchange.call({ "operation" => "list", "repository" => name, "path" => "" })
              assert_equal ["main.rb"], listed.fetch("entries").map { |entry| entry["path"] }
              found = exchange.call({ "operation" => "search", "repository" => name, "query" => "RelatedSymbol" })
              assert_equal ["main.rb"], found.fetch("matches").map { |entry| entry["path"] }
              read = exchange.call({ "operation" => "read", "repository" => name, "path" => "main.rb", "length" => 64 })
              assert_equal "live_source", read["kind"]
              assert_equal Digest::SHA256.hexdigest("RelatedSymbol #{name}\n" * 2000), read["sha256"]
              assert_equal ("RelatedSymbol #{name}\n" * 2000).byteslice(0, 64), read.fetch("data").unpack1("m0")
              first = read if name == "alpha"
            end
            %w[.env .env.local credentials.json .config/notify.yml untracked.rb .git .git/index escape.rb special.rb ../private-sibling/main.rb /etc/passwd].each do |denied|
              exchange.call({ "operation" => "read", "repository" => "alpha", "path" => denied }, success: false)
            end
            exchange.call({ "operation" => "search", "repository" => "private-sibling", "query" => "SOURCE_CANARY" }, success: false)
            assert_empty exchange.call({ "operation" => "search", "repository" => "alpha", "query" => "SOURCE_CANARY" }).fetch("matches")
            run_cli.call("FIXTURE")
            manifest = exchange.call(@first[:identity].merge("operation" => "select"), source: false)
            run_read = read_request(manifest, "final").merge("length" => 32)
            evidence = exchange.call(run_read, source: false)
            assert_equal @first[:identity], evidence.fetch("binding").slice(*AgentCodingTool::RunEvidenceReader::IDENTITIES)
            assert_equal @first[:contents]["final"].byteslice(0, 32), evidence.fetch("data").unpack1("m0")
            run_cli.call("source", "revoke", "alpha")
            exchange.call({ "operation" => "read", "repository" => "alpha", "path" => "main.rb", "offset" => 64, "version" => first["version"] }, success: false)
            exchange.call(run_read, source: false)
            run_cli.call("revoke", "FIXTURE")
            exchange.call(run_read, source: false, success: false)
            exchange.call({ "operation" => "read", "repository" => "beta", "path" => "main.rb" })
          end
        ensure
          run_cli.call("stop") if path
          wire&.close
          input.close
          assert Timeout.timeout(5) { waiter.value }.success?, error.read
          activity = output.read
          refute_includes activity, "SOURCE_CANARY"
          refute_includes activity, roots.fetch("alpha")
          refute_includes error.read, "SOURCE_CANARY"
        end
      end
    end
  end

  # Retains cold export/register/gate and both real tunnel generations; repeated
  # registration refusals use fresh public CLI instances with cold byte parity.
  # Only worker records and hosted transport are fakes; Git has one shared broker.
  # Independent file hashes prove diagnostics; host acceptance uses native Git.
  def test_native_share_continuous_public_journey
    FileUtils.remove_entry(File.join("#{@data}-runs", "checkpoints", "FIXTURE"))
    source = File.join(@temporary, "source")
    remote = File.join(@temporary, "remote.git")
    @sharing_world = MemoryGit::PatchWorld.new(root: @temporary)
    checkout, = memory_repository(@sharing_world, path: source, remote: remote)
    base = checkout.head
    snapshot = { "source" => { "path" => source, "remote" => "origin", "remote_url" => remote,
      "branch" => "main", "pushed_sha" => base } }
    FileUtils.mkdir_p(File.join(@data, "tasks"), mode: 0o700)
    FileUtils.mkdir_p(File.join(@data, "state"), mode: 0o700)
    task = { "id" => "FIXTURE", "title" => "Share fixture", "repositories" => { "source" => { "access" => "write" } },
      "goal" => "Read preserved failed and passing bytes", "constraints" => ["fixture only"], "acceptance" => ["exact bytes"] }
    File.write(File.join(@data, "tasks", "FIXTURE.yml"), YAML.dump(task))
    worktrees = File.join(@temporary, "worktrees")
    File.write(File.join(@data, "config.yml"), YAML.dump("worktree_root" => worktrees, "secret_setting" => "OUTSIDE_CONFIG_SENTINEL"))
    File.write(File.join(@data, ".env"), "OUTSIDE_ENV_SENTINEL")
    report_path = File.join(@first[:run], "handoff.json")
    report = JSON.parse(File.binread(report_path))
    ownership = File.join(@first[:run], "worktrees.json")
    inventory = MemoryGit::Session.with(@sharing_world) do
      AgentCodingTool::WorktreeManager.new(root: worktrees, record_path: ownership).create(
        task_id: "FIXTURE", attempt: 1, task: task, snapshot: snapshot)
    end
    @sharing_broker = MemoryGit::Broker.new(world: @sharing_world, directory: @temporary, case_id: "share-journey")
    workspace = inventory.fetch("entries").first.fetch("path")
    prepared_at = "2026-01-01T00:00:00Z"
    AgentCodingTool::StateStore.new(File.join(@data, "state")).write("FIXTURE",
      "id" => "FIXTURE", "prepared_at" => prepared_at, "started_at" => prepared_at, "snapshot" => snapshot)
    exports = File.join(@temporary, "exports")
    Dir.mkdir(exports, 0o700)
    stat = File.stat(exports)
    report.merge!("workspace" => workspace, "prepared_at" => prepared_at, "worktrees_path" => ownership,
      "preparation" => snapshot, "writable_authority" => snapshot.fetch("source").slice("remote_url", "branch", "pushed_sha"),
      "fixture" => { "path" => exports, "device" => stat.dev, "inode" => stat.ino, "uid" => stat.uid })
    write_json(report_path, report)
    File.write(File.join(workspace, "file.txt"), "candidate\n")
    # Keep checkpoint scratch indexes and objects inside this case's memory world.
    environment = { "AGENT_CODING_TOOL_DATA_DIR" => @data, "OPENAI_TUNNEL_KEY" => nil, "TMPDIR" => @temporary }
    run_cli = lambda do |*arguments, success: true|
      output, error, status = ChildProcesses.capture("evidence_cli", arguments: ["plain", *arguments],
        environment: environment, endpoint: @sharing_broker.endpoint, seconds: 15)
      assert_equal success, status.success?, "#{arguments.take(2).inspect}: #{error}"
      [output, error]
    end
    registration_refusals = []
    refuse_registration = lambda do |*arguments|
      output, error, exit_code = registration_cli(*arguments, environment: environment)
      assert_equal 2, exit_code, error
      registration_refusals << [output, error]
    end
    artifact = File.join(exports, "FIXTURE.patch")
    focused = File.join(exports, "focused.json")
    write_json(focused, "schema" => "fixture-worker-claims/v1", "task_id" => "FIXTURE", "checks" => [{ "exit_code" => 0 }])
    export, = run_cli.call("checkpoint", "export", "FIXTURE", "--workspace", workspace, "--base", base,
      "--artifact", artifact, "--repository", "source", "--focused", focused)
    package = JSON.parse(export).fetch("package")
    register = ["evidence", "register", "--task", "FIXTURE", "--attempt", "1", "--invocation", @first[:identity]["invocation_id"],
      "--codex-session", @first[:identity]["session_id"]]
    original_package = JSON.parse(File.binread(package.fetch("path")))
    { "task_id" => "OTHER", "base_sha" => "b" * 40, "workspace" => "/foreign" }.each do |field, value|
      bad = write_json(File.join(exports, "bad.export.json"), original_package.merge(field => value))
      refuse_registration.call(*register, "--package", bad, "--sha256", Digest::SHA256.file(bad).hexdigest)
    end
    cold_refusal = run_cli.call(*register, "--package", package.fetch("path"), "--sha256", "0" * 64, success: false)
    outside = File.join(@temporary, "outside-task")
    File.write(outside, "outside-task-secret-sentinel")
    %w[symlink fifo].each do |kind|
      File.rename(artifact, "#{artifact}.saved")
      begin
        kind == "symlink" ? File.symlink(outside, artifact) : File.mkfifo(artifact, 0o600)
        refuse_registration.call(*register, "--package", package.fetch("path"), "--sha256", package.fetch("sha256"))
      ensure
        File.unlink(artifact)
        File.rename("#{artifact}.saved", artifact)
      end
    end
    assert_equal [cold_refusal] * 5, registration_refusals
    assert_empty Dir.children(@first[:run]).grep(/\Aregistration-/)
    run_cli.call(*register, "--package", package.fetch("path"), "--sha256", package.fetch("sha256"))
    record, = run_cli.call("checkpoint", "record", "FIXTURE", "--workspace", workspace, "--artifact", artifact)
    record = JSON.parse(record)
    client = tunnel_fixture
    run_cli.call("share", "setup", "--env-file", @dotenv, "--client", client, "--runtime-dir", @runtime,
      "--account", "fixture-account", "--workspace", "fixture-workspace", "--endpoint", "tunnel_fixture/main")
    # Use the same reviewed external client and real socket/adapter boundary as
    # existing tunnel tests; Git authority is shared with each fresh CLI child.
    original_hashes = nil
    2.times do |iteration|
      evidence_process("share", "tunnel", "--min", "30",
        environment: environment.merge("ACT_FIXTURE_TUNNEL_CLIENT" => client)) do |input, output, error, waiter|
        begin
          assert IO.select([output], [], [], 5), "tunnel startup missing"
          assert_equal [], JSON.parse(output.gets)["tasks"]
          assert IO.select([output], [], [], 5), "tunnel readiness missing"
          assert_equal "ready", JSON.parse(output.gets)["status"]
          path = JSON.parse(File.binread("#{@data}-sharing/active.json")).fetch("session")
          wire = Dir.chdir(path) { UNIXSocket.new("wire") }
          responses = wire
          requests_sent = 0
          exchange = lambda do |arguments, success: true|
            requests_sent += 1
            wire.write(JSON.generate(rpc("tools/call", arguments)) + "\n")
            wire.flush
            assert IO.select([responses], [], [], 5), "tool response missing"
            frame = responses.gets
            assert frame, File.binread(File.join(path, "adapter-diagnostics.jsonl"))
            response = JSON.parse(frame).fetch("result")
            assert_equal !success, response.fetch("isError"), response.inspect
            success ? JSON.parse(response.dig("content", 0, "text")) : response
          end
          assert_empty exchange.call({ "operation" => "discover" }).fetch("tasks")
          exchange.call(@first[:identity].merge("operation" => "select"), success: false)
          shared, = run_cli.call("share", "FIXTURE")
          assert_equal "shared", JSON.parse(shared)["status"]
          discovered = exchange.call({ "operation" => "discover", "task_id" => "FIXTURE" }).fetch("tasks").first
          refute_includes JSON.generate(discovered), "OUTSIDE_CONFIG_SENTINEL"
          refute_includes JSON.generate(discovered), "OUTSIDE_ENV_SENTINEL"
          assert_equal @first[:identity], discovered.fetch("runs").first.slice(*AgentCodingTool::RunEvidenceReader::IDENTITIES)
          if iteration.zero?
            failed_selection = nil
            [7, 0].each do |exit_code|
              if exit_code.zero?
                File.write(File.join(workspace, "file.txt"), "candidate B\n")
                replacement, = run_cli.call("checkpoint", "record", "FIXTURE", "--workspace", workspace)
                record = JSON.parse(replacement)
              end
              observation = File.join(File.dirname(record.fetch("path")), "passing.observation.json")
              arguments = ["checkpoint", "gate", "FIXTURE", "--workspace", workspace]
              arguments += ["--observations", observation] if exit_code.zero?
              arguments += ["--", RbConfig.ruby,
                File.join(ChildProcesses::FIXTURES, "checkpoint_validator.rb"), "share", exit_code.to_s]
              arguments << observation if exit_code.zero?
              run_cli.call(*arguments, success: exit_code.zero?)
              failed_selection = exchange.call(@first[:identity].merge("operation" => "select")) unless exit_code.zero?
            end
            # Candidate B cannot roll an already selected failed A forward.
            old_candidate = exchange.call(read_request(failed_selection, "candidate"))
            assert_equal Digest::SHA256.file(artifact).hexdigest, old_candidate["sha256"]
            old_receipt = failed_selection.fetch("artifacts").keys.find { |name| name.start_with?("validation:") }
            assert_equal 7, JSON.parse(exchange.call(read_request(failed_selection, old_receipt))["data"].unpack1("m0")).dig("command_outcome", "exit_code")
          end
          exchange.call({ "operation" => "refresh", "task_id" => "FIXTURE" })
          manifest = exchange.call(discovered.fetch("runs").first.slice(*AgentCodingTool::RunEvidenceReader::IDENTITIES).merge("operation" => "select"))
          page = manifest
          while page["next_offset"]
            page = exchange.call(read_request(manifest).reject { |key, _| %w[artifact offset length].include?(key) }.merge(
              "operation" => "manifest", "offset" => page["next_offset"]))
            manifest.fetch("artifacts").merge!(page.fetch("artifacts"))
          end
          historical_candidates = manifest.fetch("artifacts").select { |name, _| name.start_with?("candidate:") }
          assert_equal [Digest::SHA256.file(artifact).hexdigest, record.fetch("sha256")].sort,
            historical_candidates.values.map { |spec| spec.fetch("sha256") }.sort
          exchange.call(read_request(manifest).reject { |key, _| %w[artifact offset length].include?(key) }.merge("operation" => "manifest"))
          hashes = {}
          manifest.fetch("artifacts").each do |name, spec|
            next if spec["status"] == "missing"
            bytes, offset = "".b, 0
            loop do
              evidence = exchange.call(read_request(manifest, name, offset: offset))
              chunk = evidence.fetch("data").unpack1("m0")
              assert_equal Digest::SHA256.hexdigest(chunk), evidence.fetch("chunk_sha256")
              bytes << chunk
              break unless evidence["next_offset"]
              offset = evidence.fetch("next_offset")
            end
            assert_equal File.binread(spec.fetch("path")), bytes
            refute_includes bytes, "OUTSIDE_CONFIG_SENTINEL"
            refute_includes bytes, "OUTSIDE_ENV_SENTINEL"
            refute_includes bytes, "outside-task-secret-sentinel"
            hashes[name] = Digest::SHA256.hexdigest(bytes)
            assert_equal spec.fetch("sha256"), hashes[name]
          end
          assert_equal 4, hashes.keys.grep(/\Avalidation_output:/).length
          assert_equal 3, hashes.keys.grep(/\Aworker:/).length
          assert_equal 1, hashes.keys.grep(/\Avalidation_result:/).length
          assert_equal record.fetch("sha256"), hashes["candidate"]
          assert_equal original_hashes, hashes if original_hashes
          original_hashes = hashes
          receipts = manifest["artifacts"].select { |name, _| name.start_with?("validation:") }.values.map { |spec| JSON.parse(File.binread(spec["path"])) }
          assert_equal [0, 7], receipts.map { |receipt| receipt.dig("command_outcome", "exit_code") }.sort
          assert_equal 1, receipts.find { |receipt| receipt.dig("command_outcome", "exit_code") == 0 }.dig("observed", "summary", "tests")
          if iteration.zero?
            failed_name, failed_spec = manifest.fetch("artifacts").find do |name, spec|
              name.start_with?("validation:") && JSON.parse(File.binread(spec["path"])).dig("command_outcome", "exit_code") == 7
            end
            original_receipt = File.binread(failed_spec.fetch("path"))
            corrupted = JSON.parse(original_receipt)
            corrupted.fetch("candidate")["sha256"] = record.fetch("sha256")
            write_json(failed_spec.fetch("path"), corrupted)
            exchange.call(@first[:identity].merge("operation" => "select"), success: false)
            exchange.call(read_request(manifest, failed_name), success: false)
            File.binwrite(failed_spec.fetch("path"), original_receipt)
            corrupted = JSON.parse(original_receipt)
            corrupted.fetch("candidate")["record_file"] = record.fetch("record_file")
            write_json(failed_spec.fetch("path"), corrupted)
            exchange.call(@first[:identity].merge("operation" => "select"), success: false)
            File.binwrite(failed_spec.fetch("path"), original_receipt)
            prior = historical_candidates.values.find { |spec| spec["sha256"] == Digest::SHA256.file(artifact).hexdigest }
            original_patch = File.binread(prior.fetch("path"))
            File.binwrite(prior.fetch("path"), original_patch + "corrupt")
            exchange.call(@first[:identity].merge("operation" => "select"), success: false)
            File.binwrite(prior.fetch("path"), original_patch)
          end
          run_cli.call("share", "revoke", "FIXTURE")
          exchange.call(read_request(manifest), success: false)
          run_cli.call("share", "FIXTURE")
          exchange.call(read_request(manifest), success: false) # old generation never revives
          assert IO.select([output], [], [], 3), "foreground activity missing"
          line = output.gets
          assert_match(/\AACT_SHARE /, line)
          refute_includes line, @temporary
          refute_includes line, "ACT29_SYNTHETIC_CREDENTIAL_7fQ9"
        ensure
          _stop_output, stop_error, stop_status = ChildProcesses.capture("evidence_cli",
            arguments: ["plain", "share", "stop"], environment: environment, seconds: 8)
          wire&.close
          responses&.close unless responses&.closed?
          input.close
          # Drain activity concurrently: a full console pipe must not prevent cleanup.
          drain = Thread.new { output.read }
          tunnel_status = Timeout.timeout(5) { waiter.value }
          remaining_activity = drain.value
        end
        assert tunnel_status.success?, error.read
        assert stop_status.success?, stop_error
        activity = [line, *remaining_activity.lines]
        assert_equal requests_sent, activity.length
        events = activity.map do |event_line|
          assert_operator event_line.bytesize, :<=, 1024
          refute_includes event_line, @temporary
          refute_includes event_line, "ACT29_SYNTHETIC_CREDENTIAL_7fQ9"
          JSON.parse(event_line.delete_prefix("ACT_SHARE "))
        end
        assert events.any? { |event| event["operation"] == "read" && event["bytes"] > 0 && event["wire_bytes"] > event["bytes"] && event["result"] == "delivered" }
        assert events.any? { |event| event["operation"] == "read" && event["bytes"] == 0 && event["result"] == "refused" }
      end
    end
  end
end
