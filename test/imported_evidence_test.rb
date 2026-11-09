# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/zip_fixture"
require "agent_coding_tool/share_controller"
require "minitest/mock"
require "stringio"

# Covers imported evidence through the public CLI and modern MCP frames.
# The repeat-download case substitutes an in-memory archive body.
class ImportedEvidenceTest < Minitest::Test
  # Creates an existing task with no managed attempt and a ready synthetic tunnel.
  def setup
    @temporary = File.realpath(Dir.mktmpdir("act-import-"))
    @data = File.join(@temporary, "data")
    FileUtils.mkdir_p(File.join(@data, "tasks"), mode: 0o700)
    %w[FIRST SECOND].each { |task| File.write(File.join(@data, "tasks", "#{task}.yml"), YAML.dump("id" => task)) }
    @controller = AgentCodingTool::ShareController.new(@data, out: StringIO.new, err: StringIO.new)
    env_file, client, runtime = %w[.env client runtime].map { |name| File.join(@temporary, name) }
    File.write(env_file, "not loaded", perm: 0o600)
    File.write(client, "not executed", perm: 0o700)
    Dir.mkdir(runtime, 0o700)
    @transport = { "account" => "fixture", "workspace" => "fixture", "endpoint" => "tunnel_fixture/main",
      "manager" => "task-sharing-v2", "audience" => "whole-workspace" }
    @controller.setup({ "env-file" => env_file, "client" => client, "runtime-dir" => runtime }.merge(@transport.slice("account", "workspace", "endpoint")))
    @path = File.join("#{@data}-sharing", "session-#{'a' * 32}")
    start_session(@path)
    File.write("#{@data}-sharing/active.json", JSON.generate("session" => @path), perm: 0o600)
  end

  # Creates a small source ZIP for the cases that exercise local import behavior.
  def prepare_zip_fixture
    @members = { "review.txt" => "completed synthetic review\n", "binary.dat" => (0..255).to_a.pack("C*") * 80, "empty" => "".b }
    @zip = ZipFixture.build(@members)
    @source = File.join(@temporary, "completed results.zip")
    File.binwrite(@source, @zip)
  end

  # Starts an admission with fresh zero scopes; no external transport is launched.
  def start_session(path, legacy: false)
    grant = { "schema" => "agent-coding-tool-task-sharing/v#{legacy ? 2 : 3}", "approved" => true,
      "session_path" => path, "data_root" => @data, "tasks" => [],
      "artifacts" => AgentCodingTool::RunEvidenceReader::ARTIFACTS, "transport" => @transport,
      "limits" => legacy ? AgentCodingTool::EvidenceSession::SHARING_LIMITS : AgentCodingTool::EvidenceSession::CURRENT_SHARING_LIMITS }
    grant_path = File.join(@temporary, "grant-#{File.basename(path)}.json")
    File.write(grant_path, JSON.generate(grant), perm: 0o600)
    AgentCodingTool::EvidenceSession.start(path, grant_path)
    @session = AgentCodingTool::EvidenceSession.new(path)
    @session.sharing_ready
  end

  # Removes only disposable synthetic inputs and retained evidence.
  def teardown
    FileUtils.remove_entry(@temporary)
  end

  # Invokes public CLI parsing with independent binary consoles, returning status
  # and decoded successful metadata. Errors must not echo selected path details.
  def share(*arguments, success: true)
    out, err = StringIO.new("".b), StringIO.new("".b)
    status = AgentCodingTool::CLI.run(["share", *arguments], data_root: @data, out: out, err: err)
    assert_equal(success ? 0 : 2, status, err.string)
    refute_includes err.string, @temporary
    success ? JSON.parse(out.string) : err.string
  end

  # Calls modern MCP dispatch against the live ledger; production serve/emit
  # framing and cumulative accounting are exercised separately in the journey.
  def tool(arguments, success: true, metadata: {})
    adapter = AgentCodingTool::EvidenceAdapter.new(@session, err: StringIO.new)
    response = adapter.dispatch(rpc(arguments, metadata: metadata))
    result = response.fetch("result")
    assert_equal !success, result.fetch("isError"), response.inspect
    success ? JSON.parse(result.dig("content", 0, "text")) : result
  end

  # Builds a production modern RPC frame; identity/path arguments remain closed.
  def rpc(arguments, metadata: {})
    { "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => {
      "name" => "read_run_evidence", "arguments" => arguments,
      "_meta" => { "protocolVersion" => "2026-07-28", "clientCapabilities" => {} }.merge(metadata) } }
  end

  # Produces a read request pinned to one import and one immutable revision.
  def read_request(manifest, offset: 0, length: 16_384)
    manifest.fetch("binding").slice("task_id", "artifact").merge("operation" => "read",
      "handle" => manifest.fetch("handle"), "revision" => manifest.fetch("revision"),
      "offset" => offset, "length" => length)
  end

  # Maps discovered immutable metadata onto the installed connector's existing
  # artifact field. No attempt/session or new tool-schema input is required.
  def identity(record)
    { "task_id" => record.fetch("task_id"), "artifact" => record.fetch("artifact_id") }
  end

  # Lowers a storage bound for one deterministic exhaustion check and restores
  # it even on failure. Production constants and test-runtime policy stay intact.
  def with_limit(name, value)
    type = AgentCodingTool::ImportedEvidence
    original = type.const_get(name)
    type.send(:remove_const, name)
    type.const_set(name, value)
    yield
  ensure
    type.send(:remove_const, name)
    type.const_set(name, original)
  end

  # Proves framed reads and repeat retrieval beyond the old cumulative caps
  # through the real adapter, reader and ledger, with opaque in-memory bytes.
  def test_framed_import_can_be_read_twice_past_old_byte_caps
    archive = AgentCodingTool::ImportedEvidence
    chunk_size = 32_768
    bytes = Random.new(43).bytes(2 * chunk_size + 2)
    digest = Digest::SHA256.hexdigest(bytes)
    artifact_id = "zip-#{Digest::SHA256.hexdigest("FIRST:#{digest}")}"
    directory = File.join("#{@data}-imports", artifact_id)
    FileUtils.mkdir_p(directory, mode: 0o700)
    record = { "schema" => archive::SCHEMA, "source" => archive::SOURCE,
      "task_id" => "FIRST", "artifact_id" => artifact_id, "filename" => "opaque.zip",
      "bytes" => bytes.bytesize, "sha256" => digest }
    File.write(File.join(directory, "registration.json"), JSON.generate(record), perm: 0o600)
    share("FIRST")
    lease = @session.transaction { |state| state.fetch("scopes").fetch("FIRST") }

    old_limits = AgentCodingTool::EvidenceSession::SHARING_LIMITS
    @session.charge(wire: old_limits.fetch("wire_bytes") - 1, decoded: old_limits.fetch("decoded_bytes") - 1)
    before = @session.status
    retained_identity = ["synthetic archive"]
    retained = lambda do |path, root:, size:, digest: nil, identity: nil, offset: 0, length: 0|
      assert_equal [File.join(directory, "bundle"), directory, bytes.bytesize], [path, root, size]
      assert_equal record.fetch("sha256"), digest if digest
      assert_equal retained_identity, identity if identity
      { "identity" => retained_identity, "data" => bytes.byteslice(offset, length) }
    end

    incoming, sender = IO.pipe
    receiver, outgoing = IO.pipe
    adapter = AgentCodingTool::EvidenceAdapter.new(@session, err: StringIO.new)
    exchange = lambda do |arguments, success: true|
      sender.write(JSON.generate(rpc(arguments)) + "\n")
      assert IO.select([receiver], nil, nil, 10), "missing framed response"
      frame = receiver.gets(AgentCodingTool::EvidenceAdapter::FRAME + 1)
      refute_nil frame
      assert_operator frame.bytesize, :<=, AgentCodingTool::EvidenceAdapter::FRAME
      assert frame.end_with?("\n"), "incomplete bounded frame"
      envelope = JSON.parse(frame).fetch("result")
      assert_equal !success, envelope.fetch("isError")
      JSON.parse(envelope.dig("content", 0, "text")) if success
    end

    archive.stub(:retained, retained) do
      server = Thread.new { adapter.serve(incoming, outgoing) }
      begin
        discovery = exchange.call({ "operation" => "discover", "task_id" => "FIRST" })
        discovered = discovery.fetch("tasks").first.fetch("runs").find { |entry| entry["artifact_id"] == artifact_id }
        refute_nil discovered
        assert_equal archive::SOURCE, discovered.fetch("evidence_source")
        manifest = exchange.call(identity(discovered).merge("operation" => "select"))
        exchange.call(read_request(manifest, length: chunk_size + 1), success: false)

        2.times do
          received = "".b
          [0, chunk_size, 2 * chunk_size].each do |offset|
            evidence = exchange.call(read_request(manifest, offset: offset, length: chunk_size))
            chunk = evidence.fetch("data").unpack1("m0")
            assert_equal offset, evidence.fetch("offset")
            assert_equal digest, evidence.fetch("sha256")
            assert_equal bytes.bytesize, evidence.fetch("bytes")
            assert_equal Digest::SHA256.hexdigest(chunk), evidence.fetch("chunk_sha256")
            assert_equal [chunk_size, bytes.bytesize - offset].min, chunk.bytesize
            received << chunk
            if received.bytesize == bytes.bytesize
              assert_nil evidence.fetch("next_offset")
            else
              assert_equal received.bytesize, evidence.fetch("next_offset")
            end
          end
          assert_equal digest, Digest::SHA256.hexdigest(received)
        end
      ensure
        sender.close
        server.join(5)
        refute server.alive?, "adapter did not terminate"
      end
    end

    after = @session.status(wait: 1)
    assert_equal "active", after.fetch("status")
    assert_operator after.fetch("wire_bytes"), :>, old_limits.fetch("wire_bytes")
    assert_equal before.fetch("decoded_bytes") + 2 * bytes.bytesize, after.fetch("decoded_bytes")
    assert_equal lease, @session.transaction(wait: 1) { |state| state.fetch("scopes").fetch("FIRST") }
  ensure
    [incoming, sender, receiver, outgoing].compact.each { |pipe| pipe.close unless pipe.closed? }
  end

  # First continuous public CLI -> import -> modern connector binary proof.
  # The client sees only protocol bytes; removing the import handoff breaks the
  # same discovery/select/read path, rather than merely checking a filename.
  def test_cli_connector_binary_journey_and_missing_handoff
    prepare_zip_fixture
    before = Dir.glob("#{@data}/**/*").to_h { |path| [path, File.file?(path) ? File.binread(path) : nil] }
    imported = Dir.chdir(@temporary) { share("FIRST", "./completed results.zip") }.fetch("import")
    refute File.exist?("#{@data}-runs")
    input_reader, input_writer = IO.pipe
    output_reader, output_writer = IO.pipe
    adapter = AgentCodingTool::EvidenceAdapter.new(@session, err: StringIO.new)
    server = Thread.new { adapter.serve(input_reader, output_writer) }
    exchange = lambda do |arguments, success: true|
      input_writer.write(JSON.generate(rpc(arguments)) + "\n")
      input_writer.flush
      assert IO.select([output_reader], nil, nil, 2), "connector response missing"
      frame = output_reader.gets
      assert_operator frame.bytesize, :<=, AgentCodingTool::EvidenceAdapter::FRAME
      result = JSON.parse(frame).fetch("result")
      assert_equal !success, result.fetch("isError")
      success ? JSON.parse(result.dig("content", 0, "text")) : result
    end
    discovery = exchange.call({ "operation" => "discover", "task_id" => "FIRST" })
    identity = identity(discovery.fetch("tasks").first.fetch("runs").first)
    assert_equal identity(imported), identity
    manifest = exchange.call(identity.merge("operation" => "select"))
    assert_equal "externally_supplied_zip", manifest["evidence_source"]
    %w[attempt session_id invocation_id launch_status worker_exit_status].each { |key| refute manifest.key?(key) || manifest["binding"].key?(key) }
    refute_includes JSON.generate(manifest), @temporary
    received, offset = "".b, 0
    loop do
      evidence = exchange.call(read_request(manifest, offset: offset))
      refute_includes JSON.generate(evidence), @temporary
      chunk = evidence.fetch("data").unpack1("m0")
      assert_equal Digest::SHA256.hexdigest(chunk), evidence["chunk_sha256"]
      received << chunk
      break unless evidence["next_offset"]
      offset = evidence["next_offset"]
    end
    assert_equal @zip, received
    assert_equal Digest::SHA256.file(@source).hexdigest, Digest::SHA256.hexdigest(received)
    assert_equal @members, ZipFixture.inspect_members(received)
    retained = File.join("#{@data}-imports", identity["artifact"], "bundle")
    File.rename(retained, "#{retained}.removed")
    exchange.call(read_request(manifest), success: false)
    File.rename("#{retained}.removed", retained)
    exchange.call(read_request(manifest), success: false)
    manifest = exchange.call(identity.merge("operation" => "select"))
    assert_equal @zip.byteslice(0, 16_384), exchange.call(read_request(manifest))["data"].unpack1("m0")
    status = @session.status(wait: 1)
    assert_operator status["wire_bytes"], :>, received.bytesize
    assert_operator status["decoded_bytes"], :>=, received.bytesize
    assert_equal before, Dir.glob("#{@data}/**/*").to_h { |path| [path, File.file?(path) ? File.binread(path) : nil] }
  ensure
    input_writer&.close
    server&.join(3)
    assert !server&.alive?, "adapter failed to terminate"
    [input_reader, output_reader, output_writer].compact.each { |stream| stream.close unless stream.closed? }
  end

  # Same bytes reuse storage and their original public filename; changed bytes
  # create another immutable selection. Source deletion cannot affect old reads.
  def test_identity_reuse_versions_and_source_independence
    prepare_zip_fixture
    first = share("FIRST", @source)["import"]
    manifest = tool(identity(first).merge("operation" => "select"))
    duplicate = share("FIRST", @source)["import"]
    assert duplicate["reused"]
    assert_equal first["artifact_id"], duplicate["artifact_id"]
    renamed = File.join(@temporary, "renamed.zip")
    File.binwrite(renamed, @zip)
    assert_equal first["filename"], share("FIRST", renamed).dig("import", "filename")
    changed = ZipFixture.build("other.txt" => "changed bytes")
    File.binwrite(@source, changed)
    second = share("FIRST", @source)["import"]
    refute_equal first["artifact_id"], second["artifact_id"]
    assert_equal first["filename"], second["filename"]
    assert_equal 2, Dir.children("#{@data}-imports").grep(/\Azip-/).length
    File.unlink(@source)
    assert_equal @zip.byteslice(0, 16_384), tool(read_request(manifest))["data"].unpack1("m0")
    later = tool(identity(second).merge("operation" => "select"))
    assert_equal changed, tool(read_request(later))["data"].unpack1("m0")
    tool(read_request(manifest).merge("artifact" => second["artifact_id"]), success: false)
    assert_equal 2, tool({ "operation" => "refresh", "task_id" => "FIRST" }).dig("tasks", 0, "runs").length
  end

  # Explicit local consent cannot be widened to special files, aliases, unknown
  # tasks or unsupported ZIP containers, and errors never disclose source paths.
  def test_invalid_inputs_and_prior_shares_survive
    prepare_zip_fixture
    first = share("FIRST", @source)["import"]
    original_scope = @session.transaction { |state| state["scopes"]["FIRST"].dup }
    share("UNKNOWN", @source, success: false)
    share("FIRST", File.join(@temporary, "missing.zip"), success: false)
    share("FIRST", @source, "extra.zip", success: false)
    invalid = File.join(@temporary, "invalid.zip")
    ["not a zip", "PK\x03\x04" + "x" * 40, @zip.byteslice(0...-1), @zip + "trailing"].each do |bytes|
      File.binwrite(invalid, bytes)
      share("FIRST", invalid, success: false)
    end
    alias_path = File.join(@temporary, "alias.zip")
    File.symlink(@source, alias_path)
    share("FIRST", alias_path, success: false)
    File.unlink(alias_path)
    File.link(@source, alias_path)
    share("FIRST", alias_path, success: false)
    share("FIRST", @source, success: false)
    File.unlink(alias_path)
    File.mkfifo(alias_path, 0o600)
    share("FIRST", alias_path, success: false)
    File.unlink(alias_path)
    directory_alias = File.join(@temporary, "alias-directory")
    File.symlink(@temporary, directory_alias)
    share("FIRST", File.join(directory_alias, File.basename(@source)), success: false)
    File.open(invalid, "wb") { |file| file.truncate(AgentCodingTool::ImportedEvidence::MAX_FILE + 1) }
    assert_includes share("FIRST", invalid, success: false), "100 MiB"
    assert_equal original_scope, @session.transaction { |state| state["scopes"]["FIRST"] }
    assert_equal [first["artifact_id"]], tool({ "operation" => "discover", "task_id" => "FIRST" }).dig("tasks", 0, "runs").map { |entry| entry["artifact_id"] }
    empty = File.join(@temporary, "empty.zip")
    File.binwrite(empty, ZipFixture.build({}))
    assert_equal 22, share("FIRST", empty).dig("import", "bytes")
  end

  # Exercises the exact size boundary with a scaled fixture and checks that
  # an opaque ZIP comment may include the end-of-central-directory signature.
  def test_exact_size_ceiling_and_zip_comments
    prepare_zip_fixture
    maximum = 65_536
    overhead = ZipFixture.build("large.bin" => "").bytesize
    bytes = ZipFixture.build("large.bin" => "\xff\x00".b * ((maximum - overhead) / 2))
    assert_equal maximum, bytes.bytesize
    with_limit(:MAX_FILE, maximum) do
      File.binwrite(@source, bytes)
      record = share("FIRST", @source).fetch("import")
      assert_equal maximum, record.fetch("bytes")
      assert_equal Digest::SHA256.hexdigest(bytes), record.fetch("sha256")
      manifest = tool(identity(record).merge("operation" => "select"))
      evidence = tool(read_request(manifest, offset: maximum - 16_384))
      assert_equal bytes.byteslice(-16_384, 16_384), evidence.fetch("data").unpack1("m0")
      assert_nil evidence.fetch("next_offset")
    end
    comment = "comment PK\x05\x06 opaque bytes".b
    with_comment = @zip.byteslice(0...-2) + [comment.bytesize].pack("v") + comment
    File.binwrite(@source, with_comment)
    assert_equal with_comment.bytesize, share("FIRST", @source).dig("import", "bytes")
  end

  # Deterministic external filesystem faults leave no publication, preserve old
  # grants, and permit bounded retry. Crash residue is cleaned only under lock.
  def test_copy_failure_races_and_retry_recovery
    prepare_zip_fixture
    first = share("FIRST", @source)["import"]
    scope = @session.transaction { |state| state["scopes"].dup }
    File.binwrite(@source, ZipFixture.build("new.txt" => "new bytes"))
    writer = AgentCodingTool::ImportedEvidence.instance_method(:durable_file)
    store = AgentCodingTool::ImportedEvidence.new(@data)
    failure = lambda do |path, bytes|
      File.binwrite(path, bytes.byteslice(0, 7), perm: 0o600)
      raise Errno::ENOSPC
    end
    store.define_singleton_method(:durable_file, &failure)
    AgentCodingTool::ImportedEvidence.stub(:new, store) { share("FIRST", @source, success: false) }
    refute File.exist?("#{@data}-imports/.pending")
    store.define_singleton_method(:durable_file) do |path, bytes|
      writer.bind_call(self, path, bytes)
      File.binwrite(@source_path, "source changed during copy") if path.end_with?("/bundle")
    end
    store.instance_variable_set(:@source_path, @source)
    AgentCodingTool::ImportedEvidence.stub(:new, store) { share("FIRST", @source, success: false) }
    assert_equal [first["artifact_id"]], AgentCodingTool::ImportedEvidence.new(@data).discover("FIRST").map { |entry| entry["artifact_id"] }
    assert_equal scope, @session.transaction { |state| state["scopes"] }
    File.binwrite(@source, ZipFixture.build("retry.txt" => "retry"))
    pending = "#{@data}-imports/.pending"
    Dir.mkdir(pending, 0o700)
    File.binwrite(File.join(pending, "bundle"), "interrupted copy", perm: 0o600)
    second = share("FIRST", @source)["import"]
    refute second["reused"]
    refute File.exist?(pending)
    assert_equal 2, AgentCodingTool::ImportedEvidence.new(@data).discover("FIRST").length
    File.binwrite(@source, ZipFixture.build("interrupt.txt" => "interrupted"))
    store.define_singleton_method(:durable_file) do |path, bytes|
      writer.bind_call(self, path, bytes)
      raise Interrupt
    end
    AgentCodingTool::ImportedEvidence.stub(:new, store) do
      assert_raises(Interrupt) { share("FIRST", @source) }
    end
    refute File.exist?(pending)
    refute share("FIRST", @source).dig("import", "reused")
    assert_equal 3, AgentCodingTool::ImportedEvidence.new(@data).discover("FIRST").length
  end

  # Substituting source identity after its open, including equal-byte replacement,
  # is detected through inode/metadata checks rather than content hash alone.
  def test_replacement_race_and_readonly_input
    prepare_zip_fixture
    original = File.method(:open)
    replacement = lambda do |path, *arguments, **options, &block|
      original.call(path, *arguments, **options) do |file|
        if path == @source
          File.rename(@source, "#{@source}.old")
          File.binwrite(@source, @zip)
        end
        block.call(file)
      end
    end
    File.stub(:open, replacement) { share("FIRST", @source, success: false) }
    assert_empty AgentCodingTool::ImportedEvidence.new(@data).discover("FIRST")
    assert_empty @session.transaction { |state| state["scopes"] }
    File.chmod(0o400, @source)
    assert_equal @zip.bytesize, share("FIRST", @source).dig("import", "bytes")
    assert_equal 0o400, File.stat(@source).mode & 0o777
  end

  # Retained storage has finite artifact/byte limits independent of tunnel
  # budgets. Regrant/retry never replenish the admission's cumulative counters.
  def test_storage_and_remaining_transport_limits
    prepare_zip_fixture
    first = share("FIRST", @source)["import"]
    File.binwrite(@source, ZipFixture.build("next.txt" => "next bytes"))
    with_limit(:MAX_STORAGE, @zip.bytesize) do
      assert_includes share("FIRST", @source, success: false), "storage exhausted"
    end
    with_limit(:MAX_ARTIFACTS, 1) do
      share("FIRST", @source, success: false)
    end
    # New tunnels account beyond both old caps, including ordinary non-ZIP bytes.
    @session.charge(wire: 167772160, decoded: 104857600)
    @session.charge(wire: 1, decoded: 1)
    assert_equal "active", @session.status["status"]
    File.binwrite(@source, @zip)
    assert_equal first["artifact_id"], share("FIRST", @source).dig("import", "artifact_id")
    File.binwrite(@source, ZipFixture.build("next.txt" => "next bytes"))
    # Explicit v2 grants retain all prior total and non-ZIP cap semantics.
    start_session(File.join("#{@data}-sharing", "session-#{'d' * 32}"), legacy: true)
    File.write("#{@data}-sharing/active.json", JSON.generate("session" => @session.instance_variable_get(:@path)))
    share("FIRST")
    original = @session.transaction { |state| state.slice("requests", "decoded_bytes", "wire_bytes") }
    { "requests" => AgentCodingTool::EvidenceSession::SHARING_LIMITS["requests"] - 2,
      "decoded_bytes" => AgentCodingTool::EvidenceSession::SHARING_LIMITS["decoded_bytes"] - 1,
      "wire_bytes" => AgentCodingTool::EvidenceSession::SHARING_LIMITS["wire_bytes"] - 1 }.each do |key, exhausted|
      @session.transaction { |state| state[key] = exhausted }
      assert_includes share("FIRST", @source, success: false), "Insufficient remaining"
      share("FIRST")
      assert_equal exhausted, @session.status[key]
      @session.transaction { |state| state[key] = original[key] }
    end
    assert_equal [first["artifact_id"]], AgentCodingTool::ImportedEvidence.new(@data).discover("FIRST").map { |entry| entry["artifact_id"] }
    # Increased total v2 allowances cannot be spent on non-ZIP data, including
    # source output. Input and non-ZIP output preserve the original cumulative
    # limits even when a sharing grant permits a larger imported ZIP response.
    %w[wire_bytes decoded_bytes].each do |key|
      @session.transaction { |state| state[key] = AgentCodingTool::EvidenceSession::LIMITS.fetch(key) }
      amounts = key == "wire_bytes" ? { wire: 1 } : { wire: 0, decoded: 1 }
      assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.charge(**amounts) }
      @session.charge(**amounts, zip: true)
      @session.transaction do |state|
        state[key] = original[key]
        state["zip_#{key}"] = 0
      end
    end
    16.times do |number|
      File.binwrite(@source, ZipFixture.build("page.txt" => "revision #{number}"))
      share("FIRST", @source)
    end
    assert_equal 5, @session.zip_control_frames(@data, "FIRST")
    @session.transaction { |state| state["requests"] = state.dig("grant", "limits", "requests") - 6 }
    File.binwrite(@source, ZipFixture.build("page.txt" => "not published"))
    assert_includes share("FIRST", @source, success: false), "requests budget"
    assert_equal 17, AgentCodingTool::ImportedEvidence.new(@data).discover("FIRST").length
  end

  # Remote requests cannot supply host paths or cross task/artifact identities.
  # Missing/corrupt retained bytes and registrations refuse on existing handles.
  def test_remote_boundaries_and_retained_mutations
    prepare_zip_fixture
    first = share("FIRST", @source)["import"]
    identity = identity(first)
    manifest = tool(identity.merge("operation" => "select"))
    config = AgentCodingTool::ImportedEvidence.new(@data).select(identity, manager: "approved-audience")
    reader = AgentCodingTool::RunEvidenceReader.new(**config.transform_keys(&:to_sym))
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      reader.call(identity.merge("operation" => "manifest", "revision" => nil), caller: "different-audience")
    end
    share("SECOND")
    tool(identity.merge("task_id" => "SECOND", "operation" => "select"), success: false)
    tool(identity.merge("operation" => "select", "path" => @source), success: false)
    tool(read_request(manifest).merge("source" => @source), success: false)
    tool(read_request(manifest).merge("artifact_id" => first["artifact_id"]), success: false)
    tool(read_request(manifest).merge("artifact" => @source), success: false)
    tool(read_request(manifest).merge("length" => 32_769), success: false)
    tool(read_request(manifest).merge("offset" => -1), success: false)
    tool(read_request(manifest).merge("revision" => "f" * 64), success: false)
    tool(read_request(manifest).merge("artifact" => "zip-#{'f' * 64}"), success: false)
    directory = File.join("#{@data}-imports", first["artifact_id"])
    # An equal-size edit outside the requested range still refuses after
    # restoring mtime. An equal-byte inode replacement also refuses. These
    # exercise the pinned ctime/inode, independently of per-chunk digests.
    bundle = File.join(directory, "bundle")
    File.chmod(0o755, "#{@data}-imports")
    tool(read_request(manifest), success: false)
    File.chmod(0o700, "#{@data}-imports")
    [["in_place", false], ["replacement", true]].each do |_label, replace|
      manifest = tool(identity.merge("operation" => "select"))
      stat = File.stat(bundle)
      if replace
        File.rename(bundle, "#{bundle}.saved")
        File.binwrite(bundle, @zip, perm: 0o600)
      else
        File.open(bundle, "r+b") { |file| file.seek(-1, IO::SEEK_END); file.write("X") }
        File.utime(stat.atime, stat.mtime, bundle)
      end
      tool(read_request(manifest, length: 1), success: false)
      assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.release(read_request(manifest)) { flunk "changed ZIP released" } }
      if replace
        File.unlink(bundle)
        File.rename("#{bundle}.saved", bundle)
      else
        File.binwrite(bundle, @zip)
      end
    end
    %w[bundle registration.json].each do |name|
      manifest = tool(identity.merge("operation" => "select"))
      path = File.join(directory, name)
      bytes = File.binread(path)
      File.binwrite(path, "changed retained bytes")
      tool(read_request(manifest), success: false)
      File.unlink(path)
      tool(read_request(manifest), success: false)
      File.binwrite(path, bytes, perm: 0o600)
      File.chmod(0o644, path)
      tool(read_request(manifest), success: false)
      File.chmod(0o600, path)
      File.rename(path, "#{path}.saved")
      File.symlink("#{path}.saved", path)
      tool(read_request(manifest), success: false)
      File.unlink(path)
      File.rename("#{path}.saved", path)
    end
    settings = "#{@data}-sharing/settings.json"
    contents = File.binread(settings)
    File.binwrite(settings, JSON.generate(JSON.parse(contents).merge("workspace" => "another-audience")))
    share("FIRST", @source, success: false)
    File.binwrite(settings, contents)
    # MCP hints cannot claim another authenticated caller. Authentication itself
    # remains the existing external tunnel boundary, unchanged by this feature.
    schema = AgentCodingTool::EvidenceAdapter.schema
    refute schema["properties"].key?("path")
    refute schema["properties"].key?("source")
    assert_equal ["task_id", "artifact"], AgentCodingTool::RunEvidenceReader.identity_fields(manifest["binding"])
  end

  # Every later chunk checks lease/generation. Revocation, expiry, stop, exhausted
  # budgets and a new zero-scope tunnel cannot revive previous selections.
  def test_revocation_expiry_stop_budget_and_tunnel_restart
    prepare_zip_fixture
    imported = share("FIRST", @source)["import"]
    identity = identity(imported)
    manifest = tool(identity.merge("operation" => "select"))
    share("revoke", "FIRST")
    tool(read_request(manifest), success: false)
    tool({ "operation" => "discover", "task_id" => "FIRST" }, success: false)
    share("FIRST")
    tool(read_request(manifest), success: false)
    manifest = tool(identity.merge("operation" => "select"))
    @session.transaction { |state| state["scopes"]["FIRST"]["expires_at"] = Time.now.to_f - 1 }
    tool(read_request(manifest), success: false)
    share("FIRST")
    manifest = tool(identity.merge("operation" => "select"))
    request = read_request(manifest)
    @session.transaction { |state| state["requests"] = state.dig("grant", "limits", "requests") }
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.admit }
    @session.stop
    tool(request, success: false)
    new_path = File.join("#{@data}-sharing", "session-#{'b' * 32}")
    start_session(new_path)
    assert_empty tool({ "operation" => "discover" })["tasks"]
    tool(identity.merge("operation" => "select"), success: false)
    File.binwrite("#{@data}-sharing/active.json", JSON.generate("session" => new_path))
    share("FIRST")
    tool(request, success: false)
    assert_equal imported["sha256"], tool(identity.merge("operation" => "select")).dig("artifacts", imported["artifact_id"], "sha256")
  end
end
