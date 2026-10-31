# frozen_string_literal: true

require_relative "test_helper"
require "agent_coding_tool/evidence_tunnel"
require "minitest/mock"
require "stringio"

# Exercises the real owner and ledger with deterministic process/HTTP boundaries.
# Native public CLI/client/adapter composition remains in RunEvidenceTest.
class EvidenceTunnelTest < Minitest::Test
  # Creates a real finite admission without credentials, client startup or ACT state.
  def setup
    @temporary = File.realpath(Dir.mktmpdir("act-tunnel-review-"))
    @path = File.join(@temporary, "session")
    data = File.join(@temporary, "data")
    Dir.mkdir(data, 0o700)
    grant = { "schema" => "agent-coding-tool-evidence-grant/v1", "approved" => true,
      "session_path" => @path, "data_root" => data, "tasks" => ["FIXTURE"], "artifacts" => ["final"],
      "transport" => { "account" => "fixture", "workspace" => "fixture", "endpoint" => "tunnel_fixture/main",
        "manager" => "fixture", "audience" => "whole-workspace" },
      "limits" => { "seconds" => 60, "requests" => 512, "wire_bytes" => 8192, "decoded_bytes" => 4096 } }
    grant_path = File.join(@temporary, "grant.json")
    File.write(grant_path, JSON.generate(grant), perm: 0o600)
    AgentCodingTool::EvidenceSession.start(@path, grant_path)
    @session = AgentCodingTool::EvidenceSession.new(@path)
    @out, @err = StringIO.new, StringIO.new
    @tunnel = AgentCodingTool::EvidenceTunnel.new(session: @path, grant: grant_path,
      env_file: nil, client: "/unused-client", runtime_dir: @temporary, out: @out, err: @err)
    @tunnel.instance_variable_set(:@session, @session)
    @cleaned = []
    cleaned = @cleaned
    @tunnel.define_singleton_method(:cleanup_group) do |pid|
      cleaned << pid
      "owned_groups_signaled_and_reaped"
    end
    @clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @wall = Time.now
  end

  # Removes only synthetic fixture files, even after a failing regression.
  def teardown
    @lock&.close
    FileUtils.remove_entry(@temporary)
  end

  # Runs the actual owner with fake spawn/cleanup and a deterministic wait clock.
  # A real pipe supplies controller EOF; signal handlers are captured, not installed.
  # Returns its fixed receipt. Ledger I/O and locking are never substituted.
  def owner(stop_on_ready: true, &readiness)
    watch, @keepalive = IO.pipe
    endpoint_lock = File.open(File.join(@temporary, "endpoint.lock"), "w")
    @tunnel.instance_variable_set(:@endpoint_lock, endpoint_lock)
    @tunnel.define_singleton_method(:ready?, &readiness)
    session = @session
    @out.define_singleton_method(:flush) { session.stop } if stop_on_ready
    @signals = {}
    signals = @signals
    @spawned = []
    spawn = ->(*_arguments) { @spawned << 987_654; 987_654 }
    wait = ->(_read, _write = nil, _error = nil, seconds = nil) do
      @clock += seconds || 0
      @keepalive.closed? ? [[watch], [], []] : nil
    end
    Signal.stub(:trap, ->(name, handler = nil, &block) { signals[name] = handler || block }) do
      Process.stub(:spawn, spawn) do
        Process.stub(:clock_gettime, ->(_clock) { @clock }) do
          Time.stub(:now, -> { @wall }) do
            IO.stub(:select, wait) { @exit_code = @tunnel.send(:own, watch, nil) }
          end
        end
      end
    end
    JSON.parse(File.binread(File.join(@path, "tunnel-result.json")))
  ensure
    watch&.close unless watch&.closed?
    @keepalive&.close unless @keepalive&.closed?
    endpoint_lock&.close unless endpoint_lock&.closed?
  end

  # Holds the same kernel ledger lock used by reader transactions; status must busy.
  def contend
    @lock = File.open(File.join(@path, "lock"), File::RDWR)
    assert @lock.flock(File::LOCK_EX | File::LOCK_NB)
    error = assert_raises(AgentCodingTool::EvidenceSession::Refused) { @session.status }
    assert_equal "session.busy", error.message
  end

  # Initial transient contention retries without spawning early or renewing budgets.
  def test_owner_retries_transient_ledger_contention
    @session.admit
    @session.charge(wire: 123, decoded: 45)
    original = @session.status
    contend
    status = @session.method(:status)
    attempts = 0
    lock = @lock
    @session.define_singleton_method(:status) do
      attempts += 1
      lock.flock(File::LOCK_UN) if attempts == 3
      status.call
    end
    receipt = owner { true }
    assert_includes @out.string, '"status":"ready"'
    assert_operator attempts, :>=, 3
    assert_equal "stopped", receipt["reason"]
    assert_equal 0, @exit_code
    assert_equal @spawned, @cleaned
    assert_equal original.slice("expires_at", "admitted_at", "requests", "wire_bytes", "decoded_bytes"),
      @session.status.slice("expires_at", "admitted_at", "requests", "wire_bytes", "decoded_bytes")
  end

  # Sustained contention is finite even before an expiry can be read; no client starts.
  def test_owner_bounds_sustained_initial_contention
    contend
    started = @clock
    receipt = owner { flunk "readiness while ledger unavailable" }
    assert_operator @clock - started, :>, 1.5
    assert_operator @clock - started, :<=, 2.1
    assert_empty @spawned
    assert_empty @out.string
    assert_equal "failed", receipt["reason"]
    assert_equal "blocked", receipt["admission_stop"]
    assert_equal 2, @exit_code
  end

  # Reader contention after ready must recover, rather than close a healthy tunnel.
  def test_owner_retries_contention_while_ready
    lock = @lock = File.open(File.join(@path, "lock"), File::RDWR)
    locked, attempts = false, 0
    @out.define_singleton_method(:flush) { lock.flock(File::LOCK_EX); locked = true }
    status = @session.method(:status)
    @session.define_singleton_method(:status) do
      if locked
        attempts += 1
        lock.flock(File::LOCK_UN) if attempts == 3
      end
      status.call
    end
    calls, session = 0, @session
    receipt = owner(stop_on_ready: false) do
      calls += 1
      session.stop if calls == 2
      true
    end
    assert_operator attempts, :>=, 3
    assert_equal 2, calls
    assert_equal 1, @out.string.lines.length
    assert_equal "lifecycle", receipt["stage"]
    assert_equal "stopped", receipt["reason"]
    assert_equal @spawned, @cleaned
    assert_equal 0, @exit_code
  end

  # Cached finite expiry remains binding when readiness is followed by a busy ledger.
  def test_owner_contention_cannot_defer_expiry
    test = self
    started = @clock
    receipt = owner do
      test.contend
      test.instance_variable_set(:@clock, started + 60)
      true
    end
    assert_empty @out.string
    assert_equal "expired", receipt["reason"]
    assert_equal @spawned, @cleaned
    assert_equal 2, @exit_code
  end

  # Sustained contention after client startup also has a finite retry window.
  def test_owner_bounds_sustained_contention_after_start
    test = self
    started = @clock
    receipt = owner do
      test.contend
      true
    end
    assert_empty @out.string
    assert_equal "failed", receipt["reason"]
    assert_equal @spawned, @cleaned
    assert_operator @clock - started, :>, 1.5
    assert_operator @clock - started, :<, 2.2
    assert_equal 2, @exit_code
  end

  # A previously observed expiry interrupts the busy retry window itself.
  def test_owner_stops_retrying_at_cached_expiry
    @session.transaction { |state| state["expires_at"] = @wall.to_f + 0.2 }
    test = self
    started = @clock
    receipt = owner do
      test.contend
      true
    end
    assert_empty @out.string
    assert_equal "expired", receipt["reason"]
    assert_equal @spawned, @cleaned
    # Includes the unchanged one-second best-effort stop window.
    assert_operator @clock - started, :<, 1.3
    assert_equal 2, @exit_code
  end

  # Real malformed ledger bytes still fail closed and clean up the owned child.
  def test_owner_refuses_genuine_ledger_errors
    state_path = File.join(@path, "state.json")
    receipt = owner do
      File.write(state_path, "{malformed")
      true
    end
    assert_empty @out.string
    assert_equal "failed", receipt["reason"]
    assert_equal "blocked", receipt["admission_stop"]
    assert_equal @spawned, @cleaned
    assert_equal 2, @exit_code
  end

  # Injects one lifecycle event during the HTTP boundary and checks stale-ready
  # refusal, exact reason, nonzero startup outcome and owned cleanup.
  def assert_readiness_event(event)
    test, session = self, @session
    receipt = owner do
      case event
      when "stopped" then session.stop
      when "wall_expiry" then test.instance_variable_set(:@wall, Time.now + 61)
      when "monotonic_expiry" then test.instance_variable_set(:@clock, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 61)
      when "controller_lost" then test.instance_variable_get(:@keepalive).close
      when "interrupted" then test.instance_variable_get(:@signals).fetch("TERM").call
      when "deadline" then test.instance_variable_set(:@clock, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 31)
      end
      true
    end
    assert_empty @out.string, event
    assert_equal event.end_with?("expiry") ? "expired" : event, receipt["reason"], event
    assert_equal @spawned, @cleaned, event
    assert_equal 2, @exit_code, event
  end

  # A durable stop during readiness suppresses ready.
  def test_owner_observes_stop_during_readiness
    assert_readiness_event("stopped")
  end

  # Wall expiry during readiness suppresses ready even without monotonic advance.
  def test_owner_observes_wall_expiry_during_readiness
    assert_readiness_event("wall_expiry")
  end

  # Monotonic expiry during readiness suppresses ready even without wall advance.
  def test_owner_observes_monotonic_expiry_during_readiness
    assert_readiness_event("monotonic_expiry")
  end

  # Controller EOF during readiness suppresses ready.
  def test_owner_observes_controller_loss_during_readiness
    assert_readiness_event("controller_lost")
  end

  # An owner signal during readiness suppresses ready.
  def test_owner_observes_interruption_during_readiness
    assert_readiness_event("interrupted")
  end

  # A readiness success after the total startup deadline remains a startup failure.
  def test_owner_observes_startup_deadline_during_readiness
    assert_readiness_event("deadline")
  end

  # Uses Net::HTTP's request/body boundary without a real endpoint or tunnel.
  # Each simulated I/O delay is below the operation timeout; their sum is not.
  def readiness_http(code: "200", bytes: 0, slow: nil)
    File.write(File.join(@path, "health-url"), "http://127.0.0.1:12345\n", perm: 0o600)
    response = Object.new
    response.define_singleton_method(:code) { code }
    response.define_singleton_method(:read_body) do |&block|
      if slow == :body
        10.times { sleep 0.03; block.call("x") }
      else
        block.call("x" * bytes)
      end
    end
    http = Net::HTTP.new("127.0.0.1", 12345, nil)
    http.define_singleton_method(:request) do |_request, &block|
      10.times { sleep 0.03 } if slow == :headers
      block.call(response)
    end
    Net::HTTP.stub(:new, http) { @tunnel.send(:ready?) }
  end

  # Trickle headers must hit the total exchange bound.
  def test_readiness_bounds_slow_headers
    refute readiness_http(slow: :headers)
  end

  # Trickle body chunks must hit the same total exchange bound.
  def test_readiness_bounds_slow_body
    refute readiness_http(slow: :body)
  end

  # Successful bounded HTTP 200 is accepted; non-200 and oversized bodies refuse.
  def test_readiness_retains_positive_and_negative_controls
    assert readiness_http
    refute readiness_http(code: "503")
    refute readiness_http(bytes: 4097)
    File.write(File.join(@path, "health-url"), "http://example.invalid:12345", perm: 0o600)
    refute @tunnel.send(:ready?)
  end

  # Runs real cleanup/parser logic with only native observation and signal/reap
  # boundaries substituted. No process is created or signaled by this helper.
  def cleanup_after_esrch(output, successful: true, error: "")
    pid, signals, reaped = 987_654, [], []
    status = Object.new
    status.define_singleton_method(:success?) { successful }
    cleanup = AgentCodingTool::EvidenceTunnel.instance_method(:cleanup_group).bind(@tunnel)
    result = nil
    Process.stub(:getpgid, ->(_target) { raise Errno::ESRCH }) do
      Process.stub(:kill, ->(signal, target) { signals << [signal, target]; 1 }) do
        Process.stub(:waitpid, ->(target) { reaped << target; target }) do
          Open3.stub(:capture3, [output, error, status]) { result = cleanup.call(pid) }
        end
      end
    end
    [result, signals, reaped]
  end

  # Darwin hides a retained zombie from getpgid while ps still binds its group.
  # Only a leader-present all-zombie inventory qualifies; no group is signaled.
  def test_cleanup_qualifies_unreaped_terminal_group_after_esrch
    result, signals, reaped = cleanup_after_esrch("987654 987654 Z\n987655 987654 ZN\n42 42 S\n")
    assert_equal "owned_groups_terminal_and_reaped", result
    assert_equal [["KILL", 987_654]], signals
    assert_equal [987_654], reaped
  end

  # ESRCH alone proves neither group absence nor descendant cleanup. Every live,
  # missing, malformed or unavailable membership observation must remain blocked.
  def test_cleanup_refuses_live_or_unverified_group_after_esrch
    cases = [
      ["987654 987654 S\n", true, ""],
      ["987654 987654 Z\n987655 987654 S\n", true, ""],
      ["987655 987654 Z\n", true, ""],
      ["987654 42 Z\n", true, ""],
      ["", true, ""],
      ["malformed inventory\n", true, ""],
      ["987654 987654 Z\n", false, ""],
      ["987654 987654 Z\n", true, "inventory unavailable"]
    ]
    cases.each do |output, successful, error|
      result, signals, reaped = cleanup_after_esrch(output, successful: successful, error: error)
      assert_equal "blocked", result
      assert_equal [["KILL", 987_654]], signals
      assert_equal [987_654], reaped
    end
  end
end
