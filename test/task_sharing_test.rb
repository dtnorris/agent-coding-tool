# frozen_string_literal: true

require_relative "test_helper"
require "agent_coding_tool/share_controller"
require "minitest/mock"
require "stringio"

# Deterministic lease/concurrency checks use real private ledgers and file locks.
# The composed native journey separately proves the reader and command boundary.
class TaskSharingTest < Minitest::Test
  # Builds two registered tasks and a fresh versioned, initially empty admission.
  def setup
    @temporary = File.realpath(Dir.mktmpdir("act-sharing-"))
    @data = File.join(@temporary, "data")
    FileUtils.mkdir_p(File.join(@data, "tasks"), mode: 0o700)
    %w[FIRST SECOND].each do |task|
      File.write(File.join(@data, "tasks", "#{task}.yml"), YAML.dump("id" => task, "title" => task, "goal" => "fixture"))
    end
    @path = File.join(@temporary, "session")
    grant = { "schema" => "agent-coding-tool-task-sharing/v3", "approved" => true,
      "session_path" => @path, "data_root" => @data, "tasks" => [], "artifacts" => AgentCodingTool::RunEvidenceReader::ARTIFACTS,
      "transport" => { "account" => "fixture", "workspace" => "personal", "endpoint" => "tunnel_fixture/main",
        "audience" => "whole-workspace", "manager" => "task-sharing-v2" },
      "limits" => AgentCodingTool::EvidenceSession::CURRENT_SHARING_LIMITS }
    grant_path = File.join(@temporary, "grant.json")
    File.write(grant_path, JSON.generate(grant), perm: 0o600)
    AgentCodingTool::EvidenceSession.start(@path, grant_path)
    @session = AgentCodingTool::EvidenceSession.new(@path)
  end

  # Removes fixture-owned evidence only; no real task or admission is touched.
  def teardown
    FileUtils.remove_entry(@temporary)
  end

  # Defaults/explicit limits are checked through public dispatch before mutation.
  # Only the foreground external controller is substituted, not CLI parsing.
  def test_public_defaults_and_invalid_minutes_precede_mutation
    out, err = StringIO.new, StringIO.new
    controller = Object.new
    calls = []
    controller.define_singleton_method(:task) { |task, minutes:, revoke: false| calls << [task, minutes, revoke]; {} }
    controller.define_singleton_method(:tunnel) { |minutes| calls << ["tunnel", minutes]; 0 }
    AgentCodingTool::ShareController.stub(:new, controller) do
      [["FIRST"], ["tunnel"], ["tunnel", "--min", "30"], ["FIRST", "--min", "60"]].each do |arguments|
        assert_equal 0, AgentCodingTool::CLI.run(["share", *arguments], data_root: @data, out: out, err: err)
      end
      ["0", "-1", "61", "1.5", "30x", "+1", "999999", ""].each do |minutes|
        assert_equal 2, AgentCodingTool::CLI.run(["share", "FIRST", "--min", minutes], data_root: @data, out: out, err: err)
      end
      assert_equal 2, AgentCodingTool::CLI.run(%w[share tunnel --min], data_root: @data, out: out, err: err)
    end
    assert_equal [["FIRST", 30, false], ["tunnel", 60], ["tunnel", 30], ["FIRST", 60, false]], calls
    assert_equal 0, AgentCodingTool::CLI.run(["help"], data_root: @data, out: out, err: err)
    assert_includes out.string, "evidence register --task TASK"
    assert_includes out.string, "--repository NAME [--focused PATH]"
    assert_equal 0, AgentCodingTool::CLI.run(%w[share help], data_root: @data, out: out, err: err)
    assert_includes out.string, "no cumulative byte caps"
    refute File.exist?("#{@data}-sharing")
  end

  # Two task leases coexist without renewing tunnel budgets; renewal clips to
  # the original deadline. Both clocks advance without waiting for real leases.
  def test_ready_two_tasks_renewal_clipping_and_nonrenewable_accounting
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.share_task("FIRST", seconds: 1800) }
    @session.sharing_ready
    @session.admit
    @session.charge(wire: 10, decoded: 3)
    before = @session.status
    first = @session.share_task("FIRST", seconds: 1800)
    @session.share_task("SECOND", seconds: 1800)
    discovered = @session.call({ "operation" => "discover" })
    assert_equal %w[FIRST SECOND], discovered.fetch("tasks").map { |task| task.fetch("task_id") }
    assert_empty @session.call({ "operation" => "discover", "task_id" => "FIRST" }).fetch("tasks").first.fetch("runs")
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1700
    wall = Time.now + 1700
    Process.stub(:clock_gettime, ->(*) { clock }) do
      Time.stub(:now, wall) do
        renewed = @session.share_task("FIRST", seconds: 3600)
        assert_equal first["generation"], renewed["generation"]
        assert_operator renewed["requested_expires_at"], :>, renewed["expires_at"]
        assert_equal before["expires_at"], renewed["expires_at"]
      end
    end
    assert_equal before, @session.status
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.call({ "operation" => "discover", "task_id" => "UNKNOWN" }) }
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.share_task("../../outside", seconds: 1800) }
  end

  # Every nonblocking release checks the scope generation. Revoking/regranting,
  # expiry on either clock, stop and reopening the same admission revive nothing.
  def test_existing_handles_revoke_expiry_stop_and_reopen
    @session.sharing_ready
    scope = @session.share_task("FIRST", seconds: 60)
    @session.transaction do |state|
      state["selections"]["handle"] = { "generation" => scope["generation"], "config" => { "binding" => { "task_id" => "FIRST" } } }
    end
    request = { "task_id" => "FIRST", "handle" => "handle" }
    assert_equal :released, @session.release(request) { :released }
    @session.share_task("FIRST", seconds: 60, revoke: true)
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.release(request) { flunk "revoked bytes" } }
    @session.share_task("FIRST", seconds: 60)
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.release(request) { flunk "old generation" } }
    @session.transaction { |state| state["selections"]["handle"]["generation"] = state["scopes"]["FIRST"]["generation"] }
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 61
    Process.stub(:clock_gettime, ->(*) { clock }) do
      assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { @session.release(request) { flunk "expired bytes" } }
    end
    @session.stop
    reopened = AgentCodingTool::EvidenceSession.new(@path)
    assert_equal "stopped", reopened.status["status"]
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { reopened.release(request) { flunk "stopped bytes" } }
  end

  # Concurrent grants/revokes and release serialize on the real kernel lock;
  # observations after completed revocation cannot enter the release callback.
  def test_concurrent_scope_edits_and_safe_activity_lines
    @session.sharing_ready
    @session.share_task("FIRST", seconds: 60)
    @session.share_task("SECOND", seconds: 60)
    workers = %w[FIRST SECOND].map do |task|
      Thread.new do
        session = AgentCodingTool::EvidenceSession.new(@path)
        8.times do
          session.share_task(task, seconds: 60)
          session.activity({ "operation" => "read", "task_id" => "evil\n/private/path" }, nil, released: 0, result: "refused")
          session.share_task(task, seconds: 60, revoke: true)
        end
      end
    end
    workers.each(&:value)
    lines = File.readlines(File.join(@path, "activity.jsonl"))
    assert_equal 16, lines.length
    lines.each do |line|
      assert_operator line.bytesize, :<=, 1024
      event = JSON.parse(line.delete_prefix("ACT_SHARE "))
      assert_equal 0, event["bytes"]
      assert_equal "refused", event["result"]
      refute_includes line, "evil"
      refute_includes line, @temporary
    end
    File.unlink(File.join(@path, "activity.jsonl"))
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) do
      @session.activity({ "operation" => "read" }, nil, released: 0, result: "refused")
    end
    assert_equal "stopped", @session.status["status"]
  end

  # Explicit setup binds audience/root once. A failed credential startup creates
  # no admission, and only a released controller lock permits supported stop
  # recovery. Unknown pointers or replaced settings never authorize reuse.
  def test_setup_binding_and_failed_startup_recovery
    client = File.join(@temporary, "fixture-client")
    File.write(client, "fixture never executed", perm: 0o700)
    env_file = File.join(@temporary, ".env")
    File.write(env_file, "fixture never read", perm: 0o600)
    runtime = File.join(@temporary, "runtime")
    Dir.mkdir(runtime, 0o700)
    options = { "env-file" => env_file, "client" => client, "runtime-dir" => runtime,
      "account" => "fixture", "workspace" => "personal", "endpoint" => "tunnel_fixture/main" }
    controller = AgentCodingTool::ShareController.new(@data, out: StringIO.new, err: StringIO.new)
    assert_equal "configured", controller.setup(options)["status"]
    assert_raises(Errno::EEXIST) { controller.setup(options) }
    root = "#{@data}-sharing"
    first = nil
    AgentCodingTool::TunnelCredential.stub(:resolve, ->(*) { raise AgentCodingTool::TunnelCredential::Refused, "credential.missing" }) do
      2.times do
        assert_raises(AgentCodingTool::TunnelCredential::Refused) { controller.tunnel(30) }
        pointer = JSON.parse(File.binread(File.join(root, "active.json")))
        refute File.exist?(pointer["session"])
        issued = JSON.parse(File.binread(Dir.glob(File.join(root, "grant-*.json")).max_by { |path| File.mtime(path) }))
        assert_equal "agent-coding-tool-task-sharing/v3", issued["schema"]
        assert_equal({ "seconds" => 1800, "requests" => 8192 }, issued["limits"])
        refute_equal first, pointer["session"] if first
        first = pointer["session"]
        assert_equal "stopped_before_admission", controller.control("stop")["status"]
      end
    end
    pointer_path = File.join(root, "active.json")
    File.write(pointer_path, JSON.generate("session" => "/foreign", "status" => "stopped_before_admission"))
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { controller.control("stop") }
    settings = File.join(root, "settings.json")
    File.write(settings, JSON.generate(options.merge("data_root" => "/foreign", "owner" => Process.uid)))
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { controller.task("FIRST", minutes: 30) }
  end

  # Context reads reject cross-task symlinks and foreign-owner observations
  # before parsing bytes. Only UID observation is substituted; file I/O and
  # containment are real. The fixture is restored even on assertion failure.
  def test_context_refuses_symlinks_and_foreign_file_ownership
    path = File.join(@data, "tasks", "FIRST.yml")
    original = File.binread(path)
    File.rename(path, "#{path}.saved")
    begin
      File.symlink(File.join(@data, "tasks", "SECOND.yml"), path)
      assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { AgentCodingTool::RunEvidenceStore.task_context(@data, "FIRST") }
    ensure
      File.unlink(path)
      File.rename("#{path}.saved", path)
    end
    open_file = File.method(:open)
    foreign = lambda do |source, *arguments, **options, &operation|
      open_file.call(source, *arguments, **options) do |file|
        stat = file.stat
        stat.define_singleton_method(:uid) { Process.uid + 1 }
        file.define_singleton_method(:stat) { stat }
        operation.call(file)
      end
    end
    File.stub(:open, foreign) do
      assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { AgentCodingTool::RunEvidenceStore.task_context(@data, "FIRST") }
    end
    assert_equal original, File.binread(path)
  end
  # Reconnects and task regrants retain the original counters/deadline. The last
  # admitted request may finish; another connection cannot release another frame.
  def test_v3_reconnect_regrant_and_request_exhaustion
    @session.sharing_ready
    @session.share_task("FIRST", seconds: 1800)
    @session.charge(wire: 167772161, decoded: 104857601)
    before = @session.status
    assert_equal "telemetry", before["byte_policy"]
    incoming = sender = receiver = outgoing = server = nil
    3.times do |connection|
      @session.transaction { |state| state["requests"] = 8191 } if connection == 2
      incoming, sender = IO.pipe
      receiver, outgoing = IO.pipe
      adapter = AgentCodingTool::EvidenceAdapter.new(AgentCodingTool::EvidenceSession.new(@path), err: StringIO.new)
      server = Thread.new { adapter.serve(incoming, outgoing) }
      sender.write(JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
        "params" => { "name" => "read_run_evidence", "arguments" => { "operation" => "discover", "task_id" => "FIRST" },
          "_meta" => { "protocolVersion" => "2026-07-28", "clientCapabilities" => {} } }) + "\n")
      assert IO.select([receiver], nil, nil, 2)
      refute JSON.parse(receiver.gets).fetch("result").fetch("isError")
      sender.close
      assert server.join(2)
      outgoing.close
      assert_empty receiver.read
      [incoming, receiver].each(&:close)
      current = @session.status
      assert_equal before["expires_at"], current["expires_at"]
      assert_equal before["admitted_at"], current["admitted_at"]
      if connection < 2
        assert_equal (connection + 1) * 2, current["requests"] # frame plus nonrefundable EOF attempt
        @session.share_task("FIRST", seconds: 3600)
        assert_equal current, @session.status
      end
    end
    assert_equal 8192, @session.status["requests"]
    assert_equal "exhausted", @session.status["status"]
    reopened = AgentCodingTool::EvidenceSession.new(@path)
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { reopened.admit }
    assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { reopened.share_task("FIRST", seconds: 3600) }
    clock = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3601
    Process.stub(:clock_gettime, ->(*) { clock }) do
      assert_equal "expired", reopened.status["status"]
      assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { reopened.release(nil) { flunk "expired release" } }
    end
  ensure
    sender&.close unless sender&.closed?
    server&.join(2)
    [incoming, receiver, outgoing].compact.each { |io| io.close unless io.closed? }
  end

  # Schema versions distinguish capped legacy grants from telemetry-only v3;
  # missing legacy limits and invented v3 byte quotas fail before admission.
  def test_versioned_grants_require_their_exact_limit_fields
    original = JSON.parse(File.binread(File.join(@temporary, "grant.json")))
    invalid = [
      original.merge("schema" => "agent-coding-tool-task-sharing/v2"),
      original.merge("schema" => "agent-coding-tool-evidence-grant/v1"),
      original.merge("limits" => AgentCodingTool::EvidenceSession::SHARING_LIMITS),
      original.merge("limits" => { "seconds" => 3600, "requests" => 8193 }),
      original.merge("limits" => { "seconds" => 3601, "requests" => 8192 })
    ]
    invalid.each_with_index do |grant, number|
      path = File.join(@temporary, "invalid-#{number}")
      grant = grant.merge("session_path" => path)
      input = File.join(@temporary, "invalid-#{number}.json")
      File.write(input, JSON.generate(grant), perm: 0o600)
      error = assert_raises(AgentCodingTool::RunEvidenceReader::Refused) { AgentCodingTool::EvidenceSession.start(path, input) }
      assert_equal "grant.limits", error.message
      refute File.exist?(path)
    end
  end

end
