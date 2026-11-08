# frozen_string_literal: true

require_relative "test_helper"
require_relative "launcher_support"
require_relative "support/checkpoint_processes"
require_relative "support/native_pilot_processes"
require_relative "../lib/agent_coding_tool/codex_manager_adapter"

# Public ACT journey with real manager/worker processes; inference and external
# Git observations alone are deterministic fakes. No live model is invoked.
class ManagerSessionTest < Minitest::Test
  include TestHelpers
  include LauncherSupport
  include CheckpointProcesses

  # Installs only the fake inference boundary in the public CLI, returning
  # status/stdout/stderr. All parser, store, lock and evidence code is production.
  def manager_cli(*arguments, runtime: @manager_runtime)
    output, error = StringIO.new, StringIO.new
    cli = AgentCodingTool::CLI.new(root: File.expand_path("..", __dir__), data_root: @data,
      out: output, err: error, manager_runtime: runtime)
    status = cli.run(["manager", *arguments])
    (@public_calls ||= []) << { "argv" => ["manager", *arguments], "status" => status,
      "stdout_sha256" => Digest::SHA256.hexdigest(output.string), "stderr_base64" => [error.string].pack("m0") }
    [status, output.string, error.string]
  end

  # Builds an adapter that reaps a reviewed fake subprocess before returning.
  # The session history directory models only Codex's external persistence.
  def manager_runtime(history, mode = "success")
    FileUtils.mkdir_p(history)
    executable = File.join(ChildProcesses::FIXTURES, "manager_inference.rb")
    executor = lambda do |arguments, prompt|
      @resume_probe.call if arguments[2] == "resume" && @resume_probe
      stdout, stderr, status = ChildProcesses.capture("manager_inference",
        arguments: [history, mode, *arguments.drop(1)], input: prompt, seconds: 5)
      AgentCodingTool::CommandResult.new(stdout: stdout, stderr: stderr, exitstatus: status.exitstatus, termsig: status.termsig)
    end
    AgentCodingTool::CodexManagerAdapter.new(executable: executable,
      identity: { "runtime" => "offline inference fake", "source" => AgentCodingTool::Bootstrap::COMPOSITION }, executor: executor)
  end

  # Runs a production public entry with the in-process modeled Git boundary.
  # Native worker and validator processes remain real; no socket is required.
  def public_act(*arguments)
    output, error = StringIO.new, StringIO.new
    status = AgentCodingTool::CLI.new(root: File.expand_path("..", __dir__),
      data_root: @data, out: output, err: error, native_pilot: @native_pilot).run(arguments)
    [status, output.string, error.string]
  end

  # Prepares one disposable world and starts M before A. Only inference and
  # Git observations are modeled; each manager/worker process exits and is reaped.
  # Yields exact completion identity and never changes ordinary/task-data sources.
  def journey(gate_mode: "emit", native: false)
    fixture(git: true, process: true) do
      status, _output, error = public_act("prepare", "T")
      assert_equal 0, status, error
      @manager_runtime = native ? native_runtime : manager_runtime(File.join(@root, "manager-history"))
      code, output, error = manager_cli("start", "T", "--id", "M")
      assert_equal 0, code, error
      first = JSON.parse(output)
      assert_equal "waiting", first.fetch("state")
      manager_pid = JSON.parse(File.binread(File.join(@root, "manager-history", "1.json"))).fetch("pid")
      assert_raises(Errno::ESRCH) { Process.kill(0, manager_pid) }
      settings = native ? { codex: @native_pilot.executable, spawner: @native_pilot.method(:spawn) } : {}
      worker = launcher(real_sandbox_probe: true, **settings)
      AgentCodingTool::Launcher.stub(:new, worker) do
        status, output, error = public_act("launch", "T", "--codex")
        assert_equal 0, status, "#{error}\n#{output}"
      end
      handoff = JSON.parse(File.binread(Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)))
      workspace = handoff.fetch("workspace")
      %w[record verify].each do |operation|
        status, output, error = public_act("checkpoint", operation, "T", "--workspace", workspace)
        assert_equal 0, status, "#{error}\n#{output}"
      end
      command = native ? @native_gate : (gate_mode == "emit" ? gate_command("emit") : gate_command("exit", "7"))
      status, output, error = public_act("checkpoint", "gate", "T", "--workspace", workspace, "--", *command)
      assert_equal gate_mode == "emit" ? 0 : 2, status, "#{error}\n#{output}"
      identity = handoff.slice(*AgentCodingTool::RunEvidenceReader::IDENTITIES)
      yield identity, handoff, first
      preserve_receipt(handoff)
    end
  end

  # Wires the production executor into the same public journey. Only sandbox,
  # boot observations and inference are deterministic substitutes; all invocations,
  # pipes, deadlines, durable counters, worker staging and gate capture are real.
  def native_runtime
    native_root = File.join("#{@data}-runs", "checkpoints", "native-pilot")
    FileUtils.mkdir_p(native_root, mode: 0o700)
    profile = File.join(native_root, "modeled.sb")
    File.write(profile, "declared deterministic sandbox boundary")
    ruby = File.realpath(RbConfig.ruby)
    FileUtils.mkdir_p([File.join(@root, "manager-history"), File.join(@root, "worker-home")])
    @native_gate = [ruby, File.join(ChildProcesses::FIXTURES, "native_pilot_worker.rb"), "validate", @root]
    config = { "executable" => File.realpath(@fake), "pins" => { profile => Digest::SHA256.file(profile).hexdigest },
      "profiles" => %w[manager worker gate].to_h { |role| [role, profile] },
      "environments" => %w[manager worker gate].to_h { |role| [role, { "PATH" => "/usr/bin:/bin" }] },
      "manager_cwd" => @root, "worktree_root" => File.join(@root, "worktrees"), "run_root" => "#{@data}-runs",
      "worker_home" => File.join(@root, "worker-home"), "worker_final_artifact" => "worker-change.txt", "gate_argv" => @native_gate,
      "inference_prefixes" => {
        "manager" => [ruby, File.join(ChildProcesses::FIXTURES, "manager_inference.rb"), File.join(@root, "manager-history"), "success"],
        "worker" => [ruby, File.join(ChildProcesses::FIXTURES, "native_pilot_worker.rb"), "worker", @root] } }
    @native_pilot = AgentCodingTool::NativePilotExecutor.create(native_root, config, seconds: 20)
    @native_pilot.manager_adapter
  end

  # Continuous positive through production CLI/executor/Launcher/checkpoint paths;
  # removing the private completion still blocks the exact resumed session.
  def test_native_executor_continuous_public_entry_and_removed_completion
    NativePilotProcesses.with_boundary do
      journey(native: true) do |identity, _handoff, first|
        assert_equal 0, bind(identity).first
        directory = File.join("#{@data}-runs", AgentCodingTool::ManagerSession::NAMESPACE, "M")
        completion = File.join(directory, "completion.json")
        File.rename(completion, completion + ".retained")
        assert_equal 2, manager_cli("review", "M", "--session", first.fetch("session_id")).first
        File.rename(completion + ".retained", completion)
        status, output, error = manager_cli("review", "M", "--session", first.fetch("session_id"))
        assert_equal 0, status, error
        assert_equal "ACCEPT", JSON.parse(output).dig("turns", 1, "decision", "decision")
        ledger = JSON.parse(File.binread(File.join("#{@data}-runs", "checkpoints", "native-pilot", "ledger.json")))
        assert_equal({ "manager" => 2, "worker" => 1, "gate" => 1 }, ledger.fetch("counts"))
        assert_nil ledger["active"]
        assert_nil ledger["held"]
        assert_equal "base\n", File.binread(File.join(@ordinary, "file.txt"))
      end
    end
  end

  # Removing explicit resume also breaks the new final-output artifact journey;
  # no extra turn or renewed budget is granted to recover the consumed review.
  def test_artifact_journey_removed_resume_fails
    NativePilotProcesses.with_boundary do
      journey(native: true) do |identity, handoff, first|
        assert_equal "worker\n", File.binread(File.join(handoff.fetch("workspace"), "worker-change.txt"))
        assert_equal "worker\n", File.binread(handoff.fetch("final_path"))
        assert_equal 0, bind(identity).first
        @manager_runtime.define_singleton_method(:argv) { |_session| super(nil) }
        assert_equal 2, manager_cli("review", "M", "--session", first.fetch("session_id")).first
        assert_equal "held", control.fetch("state")
      end
    end
  end

  # Retains bounded offline claims only in an explicitly selected existing
  # fixture directory. Complete manager/evidence bytes survive temporary-world
  # cleanup. This is neither a host checkpoint nor live acceptance evidence.
  def preserve_receipt(handoff)
    destination = ENV["ACT_WAC04_EVIDENCE"]
    return unless destination
    assert_equal File.realpath(destination), destination
    stat = File.stat(destination)
    assert stat.directory? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
    root = File.join("#{@data}-runs", AgentCodingTool::ManagerSession::NAMESPACE)
    files = Dir.glob(File.join(root, "**", "*.json")).sort.to_h do |path|
      content = File.binread(path)
      [path.delete_prefix(root + "/"), { "sha256" => Digest::SHA256.hexdigest(content), "base64" => [content].pack("m0") }]
    end
    receipt = JSON.generate("scope" => "offline fixture claims; Git/sandbox observations and inference modeled",
      "case" => name, "runtime" => RUBY_DESCRIPTION, "public_commands" => @public_calls,
      "worker" => handoff, "manager_files" => files,
      "native_files" => @native_pilot && Dir.glob(File.join("#{@data}-runs", "checkpoints", "native-pilot", "*.json")).to_h { |path| [File.basename(path), JSON.parse(File.binread(path))] })
    assert_operator receipt.bytesize, :<=, 2 * 1024 * 1024
    File.write(File.join(destination, "#{name}.json"), receipt, mode: "wx", perm: 0o600)
  end

  # Supplies exact public completion selectors, optionally replacing one field.
  # Returns the CLI result; no newest-session or implicit attempt lookup exists.
  def bind(identity, manager: "M")
    manager_cli("bind", manager, "--task", identity.fetch("task_id"), "--attempt", identity.fetch("attempt").to_s,
      "--invocation", identity.fetch("invocation_id"), "--session", identity.fetch("session_id"))
  end

  # Reads inert private control evidence, returning parsed JSON or parse errors.
  def control(name = "record.json")
    JSON.parse(File.binread(File.join("#{@data}-runs", AgentCodingTool::ManagerSession::NAMESPACE, "M", name)))
  end

  # Proves M exits, ACT admits A and binds its real candidate/gate, then a new
  # manager process resumes M and uses prior reasoning without text replay.
  # Removing either resume or evidence handoff fails this same journey.
  def test_continuous_public_entry_and_required_handoff_controls
    journey do |identity, handoff, first|
      assert_equal 2, manager_cli("review", "M", "--session", first.fetch("session_id")).first
      assert_equal 0, bind(identity).first
      assert_equal 2, manager_cli("review", "M", "--session", "different-session").first
      assert_equal 2, manager_cli("review", "M").first
      @resume_probe = lambda do
        @resume_probe = nil
        @simultaneous_resume = manager_cli("review", "M", "--session", first.fetch("session_id"))
      end
      code, output, error = manager_cli("review", "M", "--session", first.fetch("session_id"))
      assert_equal 0, code, error
      assert_equal 2, @simultaneous_resume.first
      assert_includes @simultaneous_resume.last, "busy"
      reviewed = JSON.parse(output)
      assert_equal "ACCEPT", reviewed.fetch("turns").last.fetch("decision").fetch("decision")
      assert_equal control("completion.json").fetch("binding").fetch("session_id"), identity.fetch("session_id")
      refute_equal identity.fetch("session_id"), reviewed.fetch("session_id")
      history = [1, 2].map { |number| JSON.parse(File.binread(File.join(@root, "manager-history", "#{number}.json"))) }
      refute_equal history.first.fetch("pid"), history.last.fetch("pid")
      assert_raises(Errno::ESRCH) { Process.kill(0, history.last.fetch("pid")) }
      assert_equal ["exec", "resume"], history.last.fetch("argv").take(2)
      assert_equal first.fetch("session_id"), history.last.fetch("argv")[-2]
      instructions = history.first.fetch("prompt").fetch("instructions")
      assert_includes instructions, "observation-only"
      assert_includes instructions, "not action instructions for this process"
      AgentCodingTool::ManagerSession::DECISIONS.each { |decision| assert_includes instructions, decision }
      prior = history.first.fetch("decision").fetch("rationale")
      refute_includes JSON.generate(history.last.fetch("prompt")), prior
      assert_equal prior, reviewed.fetch("turns").last.fetch("decision").fetch("prior_reasoning")
      assert_equal "base\n", File.binread(File.join(@ordinary, "file.txt"))
      assert @store.load("T")["started_at"], "manager ACCEPT must not close task"
      assert_equal 2, manager_cli("review", "M", "--session", first.fetch("session_id")).first
      assert_equal 0, handoff.fetch("exit_status")
      # Remove only the session-resume handoff at inference; the same public
      # journey must refuse instead of accepting a fresh independent manager.
      @manager_runtime = manager_runtime(File.join(@root, "removed-resume-history"))
      assert_equal 0, manager_cli("start", "T", "--id", "NO-RESUME").first
      assert_equal 0, bind(identity, manager: "NO-RESUME").first
      @manager_runtime.define_singleton_method(:argv) { |_session| super(nil) }
      assert_equal 2, manager_cli("review", "NO-RESUME", "--session", first.fetch("session_id")).first
    end
  end

  # Wrong identities, changed acceptance/evidence and competing reservations all
  # refuse before resume. Original evidence survives each negative control.
  def test_identity_revision_digest_and_simultaneous_resume_refusals
    journey do |identity, _handoff, first|
      { "task_id" => "OTHER", "attempt" => 2, "invocation_id" => "other-invocation", "session_id" => "other-worker" }.each do |field, value|
        assert_equal 2, bind(identity.merge(field => value)).first, field
      end
      assert_equal 0, bind(identity).first
      assert_equal 2, bind(identity).first
      path = File.join(@data, "tasks", "T.yml")
      original = File.binread(path)
      definition = YAML.safe_load(original)
      definition["acceptance"] << "new revision"
      File.write(path, YAML.dump(definition))
      assert_includes manager_cli("review", "M", "--session", first.fetch("session_id")).last, "revision changed"
      File.binwrite(path, original)
      selected = control.fetch("completion").fetch("selection").fetch("approvals").fetch("candidate").fetch("path")
      candidate = File.binread(selected)
      File.binwrite(selected, candidate + "changed")
      assert_equal 2, manager_cli("review", "M", "--session", first.fetch("session_id")).first
      File.binwrite(selected, candidate)
      lock_path = "#{@data}-runs/launch.lock"
      File.open(lock_path, "r+") do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        assert_includes manager_cli("review", "M", "--session", first.fetch("session_id")).last, "busy"
      end
      assert_equal 1, control.fetch("turns").length
    end
  end

  # A worker's successful self-report cannot override the independently failed
  # host command. The same evidence journey returns BLOCKED without dispatch.
  def test_failed_gate_is_reviewed_without_overriding_host_verification
    journey(gate_mode: "failed") do |identity, _handoff, first|
      assert_equal 0, bind(identity).first
      status, output, error = manager_cli("review", "M", "--session", first.fetch("session_id"))
      assert_equal 0, status, error
      assert_equal "BLOCKED", JSON.parse(output).fetch("turns").last.fetch("decision").fetch("decision")
      assert @store.load("T")["started_at"]
    end
  end

  # Invalid/binary final output holds a consumed turn and preserves exact raw
  # bytes and real failure status; reissuing start cannot overwrite the evidence.
  def test_malformed_missing_session_and_binary_output_hold_turn
    fixture do
      %w[malformed missing-session binary acceptance-mismatch incomplete].each do |mode|
        @manager_runtime = manager_runtime(File.join(@root, mode), mode)
        code, _output, error = manager_cli("start", "T", "--id", "M-#{mode}")
        assert_equal 2, code, error
        directory = File.join("#{@data}-runs", AgentCodingTool::ManagerSession::NAMESPACE, "M-#{mode}")
        record = JSON.parse(File.binread(File.join(directory, "record.json")))
        assert_equal "held", record.fetch("state")
        assert_equal 1, record.fetch("turns").length
        receipt = JSON.parse(File.binread(File.join(directory, "result-1.json")))
        if mode == "binary"
          assert_equal "\x00\xff".b, receipt.fetch("stdout_base64").unpack1("m0")
          assert_equal "diagnostic\x00\xfe".b, receipt.fetch("stderr_base64").unpack1("m0")
          assert_equal 7, receipt.fetch("exit_status")
        end
        assert_equal 2, manager_cli("start", "T", "--id", "M-#{mode}").first
      end
    end
  end
end

# Pure adapter safety contracts run without process creation in ordinary scope.
class ManagerAdapterTest < Minitest::Test
  include TestHelpers
  # Uses an inert repository file as executable identity; never invokes it.
  def adapter(executor = nil)
    AgentCodingTool::CodexManagerAdapter.new(executable: __FILE__, identity: { "runtime" => "inert" }, executor: executor)
  end

  # Confirms exact saved selection, read-only configuration and default refusal.
  def test_explicit_resume_and_unqualified_live_refusal
    runtime = adapter
    assert_equal ["exec", "resume"], runtime.argv("saved-session")[1, 2]
    assert_equal "saved-session", runtime.argv("saved-session")[-2]
    refute_includes runtime.argv("saved-session"), "--last"
    assert_includes runtime.argv(nil), 'sandbox_mode="read-only"'
    assert_includes runtime.argv(nil), "features.multi_agent=false"
    assert_raises(AgentCodingTool::InvalidState) { runtime.call(session: nil, prompt: "inert") }
    with_workspace do |data|
      output, error = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: Dir.pwd, out: output, err: error, data_root: data)
      assert_equal 2, cli.run(%w[manager start T --id M])
      assert_includes error.string, "no inference started"
      refute File.exist?("#{data}-runs")
    end
  end

  # Preserves bounded prefixes, source digests, nonzero status and explicit
  # truncation; malformed and incomplete streams never become a final decision.
  def test_output_limit_binary_status_and_malformed_streams
    output = "\x00\xff".b + "z" * AgentCodingTool::CodexManagerAdapter::OUTPUT_LIMIT
    raw = AgentCodingTool::CommandResult.new(stdout: output, stderr: "diagnostic", exitstatus: 19)
    receipt = adapter(->(*) { raw }).call(session: nil, prompt: "inert")
    assert receipt.fetch("truncated")
    assert_equal 19, receipt.fetch("exit_status")
    assert_equal output.byteslice(0, AgentCodingTool::CodexManagerAdapter::OUTPUT_LIMIT), receipt.fetch("stdout_base64").unpack1("m0")
    assert_equal Digest::SHA256.hexdigest(output), receipt.fetch("stdout_sha256")
    %w[{} null].each do |stream|
      invalid = AgentCodingTool::CommandResult.new(stdout: stream, stderr: "", exitstatus: 0)
      assert_nil adapter(->(*) { invalid }).call(session: "saved-session", prompt: "inert")["session_id"]
    end
    events = [{ "type" => "thread.started", "thread_id" => "wrong-session" }, { "type" => "turn.started" },
      { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => "{}" } }, { "type" => "turn.completed" }]
    wrong = AgentCodingTool::CommandResult.new(stdout: events.map { |event| JSON.generate(event) }.join("\n"), stderr: "", exitstatus: 0)
    assert_nil adapter(->(*) { wrong }).call(session: "saved-session", prompt: "inert")["session_id"]
  end

  # Even complete zero-exit JSONL must hold oversized/unknown/duplicate final
  # decisions. The exact final bytes remain in the private raw adapter receipt.
  def test_final_size_closed_fields_and_duplicate_decisions
    %w[oversized unknown duplicate].each do |mode|
      with_workspace do |data|
        write_task(data, id: "T")
        runtime = adapter(lambda do |_argv, input|
          prompt = JSON.parse(input)
          decision = { "schema" => "agent-coding-tool-manager-decision/v1", "decision" => "CONTINUE",
            "acceptance_sha256" => prompt.fetch("acceptance_sha256"), "completion_sha256" => nil,
            "rationale" => mode == "oversized" ? "z" * 65_536 : "Review a concrete criterion", "prior_reasoning" => "", "next_action" => "Review worker" }
          decision["unexpected"] = true if mode == "unknown"
          final = JSON.generate(decision)
          final = final.sub("{", '{"decision":"STOP",') if mode == "duplicate"
          stream = [{ "type" => "thread.started", "thread_id" => "saved-session" }, { "type" => "turn.started" },
            { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => final } }, { "type" => "turn.completed" }]
          AgentCodingTool::CommandResult.new(stdout: stream.map { |event| JSON.generate(event) }.join("\n") + "\n", stderr: "", exitstatus: 0)
        end)
        manager = AgentCodingTool::ManagerSession.new(data_root: data, runtime: runtime)
        assert_raises(AgentCodingTool::InvalidState) { manager.start("T", manager: "M") }
        path = File.join("#{data}-runs", AgentCodingTool::ManagerSession::NAMESPACE, "M")
        record = JSON.parse(File.binread(File.join(path, "record.json")))
        assert_equal "held", record.fetch("state")
        assert_equal 1, record.fetch("turns").length
        assert File.file?(File.join(path, "result-1.json"))
      end
    end
  end

  # Replays both retained host startup failures without invoking Codex. Failed
  # exits/signals precede parsing errors, consume one turn, and retain exact bytes.
  def test_startup_exit_and_signal_precede_missing_session_diagnostic
    retained_results = %w[manager_start_failure manager_preferences_failure].map do |name|
      JSON.parse(File.binread(File.join(__dir__, "support/fixtures/#{name}.json"))).fetch("result")
    end
    retained_results.product([[1, nil], [nil, 9]]).each do |retained, (exit_status, signal)|
      with_workspace do |data|
        write_task(data, id: "T")
        raw = AgentCodingTool::CommandResult.new(stdout: retained.fetch("stdout_base64").unpack1("m0"),
          stderr: retained.fetch("stderr_base64").unpack1("m0"), exitstatus: exit_status, termsig: signal)
        runtime = adapter(->(*) { raw })
        manager = AgentCodingTool::ManagerSession.new(data_root: data, runtime: runtime)
        error = assert_raises(AgentCodingTool::InvalidState) { manager.start("T", manager: "M") }
        assert_includes error.message, "inference process failed (exit_status=#{exit_status.inspect}, signal=#{signal.inspect})"
        refute_includes error.message, "session handoff"
        path = File.join("#{data}-runs", AgentCodingTool::ManagerSession::NAMESPACE, "M")
        receipt = JSON.parse(File.binread(File.join(path, "result-1.json")))
        assert_equal retained.merge("exit_status" => exit_status, "signal" => signal), receipt.reject { |key, _| %w[session_error response_error].include?(key) }
        record = JSON.parse(File.binread(File.join(path, "record.json")))
        assert_equal "held", record.fetch("state")
        assert_equal 1, record.fetch("turns").length
        assert_raises(AgentCodingTool::InvalidState) { manager.start("T", manager: "M") }
        refute File.exist?(File.join(path, "result-2.json"))
      end
    end
  end

  # Successful processes still require one exact session, one final and a
  # completed turn. Missing/conflicting/wrong sessions and malformed events hold.
  def test_zero_exit_strict_event_handoff_and_process_failure_with_valid_events
    valid = [{ "type" => "thread.started", "thread_id" => "saved-session" }, { "type" => "turn.started" },
      { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => "{}" } },
      { "type" => "turn.completed" }]
    streams = [valid.drop(1), [valid.first, valid.first, *valid.drop(1)],
      valid.map { |event| event["type"] == "thread.started" ? event.merge("thread_id" => "wrong-session") : event },
      valid.take(2), valid + [{ "type" => "error" }],
      valid + [{ "type" => "item.completed", "item" => { "type" => "command_execution" } }]]
    streams.map { |events| events.map { |event| JSON.generate(event) }.join("\n") }.concat(["not-json\n", "\xff\x00".b]).each do |stream|
      raw = AgentCodingTool::CommandResult.new(stdout: stream, stderr: "", exitstatus: 0)
      receipt = adapter(->(*) { raw }).call(session: "saved-session", prompt: "inert")
      assert receipt["session_error"] || receipt["response_error"]
      assert_equal "", receipt.fetch("final_base64")
      assert_equal stream.b, receipt.fetch("stdout_base64").unpack1("m0")
    end
    raw = AgentCodingTool::CommandResult.new(stdout: valid.map { |event| JSON.generate(event) }.join("\n"), stderr: "", exitstatus: 0)
    receipt = adapter(->(*) { raw }).call(session: "saved-session", prompt: "inert")
    assert_equal "saved-session", receipt.fetch("session_id")
    assert_equal "{}", receipt.fetch("final_base64").unpack1("m0")
    # Parsed events never override a real nonzero exit, even with valid JSONL.
    with_workspace do |data|
      write_task(data, id: "T")
      failed = AgentCodingTool::CommandResult.new(stdout: raw.stdout, stderr: "", exitstatus: 1)
      manager = AgentCodingTool::ManagerSession.new(data_root: data, runtime: adapter(->(*) { failed }))
      error = assert_raises(AgentCodingTool::InvalidState) { manager.start("T", manager: "M") }
      assert_includes error.message, "inference process failed"
    end
  end

  # Real captured phase-less pilot output must retain its thread identity while
  # refusing DEFER, preserving bytes/status and holding the consumed ACT turn.
  def test_captured_role_failure_through_public_session
    retained = JSON.parse(File.binread(File.join(__dir__, "support/fixtures/manager_role_failure.json")))
    with_workspace do |data|
      write_task(data, id: "T")
      raw = AgentCodingTool::CommandResult.new(stdout: retained.fetch("stdout_base64").unpack1("m0"),
        stderr: retained.fetch("stderr_base64").unpack1("m0"), exitstatus: retained.fetch("exit_status"))
      output, diagnostic = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: File.expand_path("..", __dir__), data_root: data,
        out: output, err: diagnostic, manager_runtime: adapter(->(*) { raw }))
      assert_equal 2, cli.run(%w[manager start T --id M])
      assert_includes diagnostic.string, 'unsupported decision "DEFER"'
      refute_includes diagnostic.string, "session handoff"
      directory = File.join("#{data}-runs", AgentCodingTool::ManagerSession::NAMESPACE, "M")
      record = JSON.parse(File.binread(File.join(directory, "record.json")))
      assert_equal "held", record.fetch("state")
      assert_equal "01a1b77f-9a36-72f0-bb3b-0ac690f96c34", record.fetch("session_id")
      receipt = JSON.parse(File.binread(File.join(directory, "result-1.json")))
      assert_equal raw.stdout, receipt.fetch("stdout_base64").unpack1("m0")
      assert_equal raw.stderr, receipt.fetch("stderr_base64").unpack1("m0")
      assert_equal 0, receipt.fetch("exit_status")
      assert_nil receipt["signal"]
      assert_equal 2, cli.run(%w[manager review M --session 01a1b77f-9a36-72f0-bb3b-0ac690f96c34])
    end
  end

  # Exercises response rejection through the real ACT session, not just selection:
  # every refusal retains a held reservation and lossless bounded raw capture.
  def test_progress_final_and_adversarial_response_contracts
    modes = %w[valid malformed prose defer multiple conflicting malformed-progress tool tool-error failed incomplete duplicate-turn
      duplicate-session missing-session wrong-session acceptance completion binary truncated unknown-event late-turn scalar-progress missing-start duplicate-start final-reasoning]
    modes.each do |mode|
      with_workspace do |data|
        write_task(data, id: "T")
        raw = nil
        runtime = adapter(lambda do |_argv, input|
          prompt = JSON.parse(input)
          decision = { "schema" => "agent-coding-tool-manager-decision/v1", "decision" => "CONTINUE",
            "acceptance_sha256" => prompt.fetch("acceptance_sha256"), "completion_sha256" => nil,
            "rationale" => "Review exact worker bytes and independent gate", "prior_reasoning" => "", "next_action" => "Review evidence" }
          decision["decision"] = "DEFER" if mode == "defer"
          decision["acceptance_sha256"] = "wrong" if mode == "acceptance"
          decision["completion_sha256"] = "wrong" if mode == "completion"
          thread = { "type" => "thread.started", "thread_id" => mode == "wrong-session" ? "bad/session" : "saved-session" }
          progress = { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => "Reviewing supplied evidence." } }
          final = { "type" => "item.completed", "item" => { "type" => "agent_message", "text" => JSON.generate(decision) } }
          final["item"]["text"] = "{broken" if mode == "malformed"
          final["item"]["text"] = "No decision available" if mode == "prose"
          progress["item"]["text"] = JSON.generate(decision) if mode == "multiple"
          progress["item"]["text"] = JSON.generate(decision.merge("decision" => "STOP")) if mode == "conflicting"
          progress["item"]["text"] = '{"decision":' if mode == "malformed-progress"
          progress["item"]["text"] = 'true' if mode == "scalar-progress"
          events = [thread, { "type" => "turn.started" }, progress, final, { "type" => "turn.completed" }]
          events.insert(3, { "type" => "item.completed", "item" => { "type" => "command_execution" } }) if mode == "tool"
          events.insert(3, { "type" => "error", "message" => "tool failed" }) if mode == "tool-error"
          events[-1] = { "type" => "turn.failed" } if mode == "failed"
          events.pop if mode == "incomplete"
          events.delete_at(1) if mode == "missing-start"
          events.insert(1, { "type" => "turn.started" }) if mode == "duplicate-start"
          events.insert(-2, { "type" => "item.completed", "item" => { "type" => "reasoning", "text" => "later reasoning" } }) if mode == "final-reasoning"
          events << events.last if mode == "duplicate-turn"
          events.unshift(thread) if mode == "duplicate-session"
          events.shift if mode == "missing-session"
          events.insert(3, { "type" => "unknown" }) if mode == "unknown-event"
          events.insert(-2, events.delete_at(1)) if mode == "late-turn"
          stream = events.map { |event| JSON.generate(event) }.join("\n") + "\n"
          stream = "\x00\xff".b if mode == "binary"
          stream += "z" * AgentCodingTool::CodexManagerAdapter::OUTPUT_LIMIT if mode == "truncated"
          raw = AgentCodingTool::CommandResult.new(stdout: stream, stderr: "retained diagnostic", exitstatus: 0)
        end)
        manager = AgentCodingTool::ManagerSession.new(data_root: data, runtime: runtime)
        if mode == "valid"
          assert_equal "waiting", manager.start("T", manager: "M").fetch("state")
        else
          assert_raises(AgentCodingTool::InvalidState, mode) { manager.start("T", manager: "M") }
        end
        directory = File.join("#{data}-runs", AgentCodingTool::ManagerSession::NAMESPACE, "M")
        record = JSON.parse(File.binread(File.join(directory, "record.json")))
        assert_equal mode == "valid" ? "waiting" : "held", record.fetch("state"), mode
        assert_equal 1, record.fetch("turns").length
        receipt = JSON.parse(File.binread(File.join(directory, "result-1.json")))
        assert_equal Digest::SHA256.hexdigest(raw.stdout), receipt.fetch("stdout_sha256")
        assert_equal raw.stdout.byteslice(0, AgentCodingTool::CodexManagerAdapter::OUTPUT_LIMIT), receipt.fetch("stdout_base64").unpack1("m0")
        assert_equal 0, receipt.fetch("exit_status")
        assert_nil receipt["signal"]
        assert_includes receipt.fetch("response_error"), "final JSON parse failure" if %w[malformed prose].include?(mode)
      end
    end
  end

  # Consolidated host failure reports carry the actual stage/exception, public
  # exit and raw stream identities even when the controller only returns two.
  def test_consolidated_journey_failure_report
    require_relative "integration/wac04_qualification"
    with_workspace do |root|
      failure = { "status" => "BLOCKED", "stage" => "public-entry:manager/start", "failure_class" => "AgentCodingTool::InvalidState",
        "reason" => 'manager: unsupported decision "DEFER"' }
      File.write(File.join(root, "journey-blocked.json"), JSON.generate(failure))
      File.write(File.join(root, "public-calls.json"), JSON.generate([{ "argv" => %w[manager start T], "status" => 2, "stderr_base64" => ["exact error"].pack("m0") }]))
      File.binwrite(File.join(root, "controller.stderr"), "diagnostic\x00\xff".b)
      report = Wac04Qualification.failure_report(root, exit_status: 2, signal: nil, failure: nil)
      assert_equal failure.fetch("stage"), report.fetch("stage")
      assert_equal failure.fetch("failure_class"), report.fetch("failure_class")
      assert_equal failure.fetch("reason"), report.fetch("reason")
      assert_equal 2, report.fetch("controller_exit")
      assert_equal 2, report.dig("public_command", "status")
      assert_equal Digest::SHA256.file(File.join(root, "controller.stderr")).hexdigest, report.dig("raw_evidence", "controller.stderr", "sha256")
      refute report.fetch("live_retry_authorized")
      File.delete(File.join(root, "journey-blocked.json"))
      File.write(File.join(root, "blocked.json"), JSON.generate(failure.merge("stage" => "installed-exec-flags")))
      report = Wac04Qualification.failure_report(root, exit_status: nil, signal: nil, failure: nil)
      assert_equal "installed-exec-flags", report.fetch("stage")
      assert_nil report.fetch("controller_exit")
    end
  end

  # Reserving a namespace never makes foreign storage invisible to admission.
  # Unsafe directories, symlinks and malformed records all remain hard refusals.
  def test_foreign_manager_namespace_is_not_ignored
    %w[file public symlink record].each do |kind|
      with_workspace do |data|
        AgentCodingTool::ReservationLock.synchronize(data) { nil }
        root = "#{data}-runs"
        path = File.join(root, AgentCodingTool::ManagerSession::NAMESPACE)
        case kind
        when "file" then File.write(path, "foreign")
        when "symlink" then File.symlink(data, path)
        else
          Dir.mkdir(path, 0o700)
          if kind == "public"
            File.chmod(0o755, path)
          else
            Dir.mkdir(File.join(path, "M"), 0o700)
            File.write(File.join(path, "M", "record.json"), "null", perm: 0o600)
          end
        end
        assert_raises(AgentCodingTool::InvalidState) { AgentCodingTool::ManagerSession.validate_namespace!(root) }
      end
    end
  end

  # Models read-only Git/guidance observations only. Unexpected commands fail;
  # no Git, Codex, native sandbox or inference process is launched. Yields fresh
  # qualification options, observed argv and root; fixture/IO errors propagate.
  def host_admission(head: "207f4e81781c0695145ebac49531a1a14d6570d2", index: "", guidance: Wac04Qualification::MANAGER_SKILL_SHA256)
    with_workspace do |data|
      parent = File.join(data, "agent-coding-tool-data-fixtures")
      Dir.mkdir(parent, 0o700)
      root = File.join(File.realpath(parent), "WAC-04-host-admission")
      options = { "root" => root, "source-head" => head,
        "source-sha256" => Wac04Qualification.pin.fetch("sha256"),
        "codex" => __FILE__, "codex-sha256" => "0" * 64 }
      calls = []
      git = File.realpath(RbConfig.ruby) # Inert identity, never executed.
      rows = { ["/usr/bin/xcrun", "--find", "git"] => "#{git}\n",
        [git, "rev-parse", "HEAD"] => "#{head}\n",
        [git, "rev-parse", "--abbrev-ref", "HEAD"] => "review-fixture\n",
        [git, "remote", "get-url", "origin"] => "git@github.com:dtnorris/agent-coding-tool.git\n",
        [git, "diff", "--cached", "--binary"] => index,
        [git, "status", "--porcelain=v1", "-z"] => " M README.md\0" }
      transport = Object.new
      transport.define_singleton_method(:call) do |argv, **_keywords|
        calls << argv
        AgentCodingTool::CommandResult.new(stdout: rows.fetch(argv), stderr: "", exitstatus: 0)
      end
      realpath = File.method(:realpath)
      digest = Digest::SHA256.method(:file)
      guidance_paths = [Wac04Qualification::SKILLS, Wac04Qualification::MANAGER_SKILL]
      File.stub(:realpath, ->(path) { guidance_paths.include?(path) ? path : realpath.call(path) }) do
        Digest::SHA256.stub(:file, ->(path) { path == Wac04Qualification::MANAGER_SKILL ? Struct.new(:hexdigest).new(guidance) : digest.call(path) }) do
          AgentCodingTool::NativeCommandTransport.stub(:new, -> { transport }) { yield options, calls, root }
        end
      end
    end
  end

  # Committed review/merge identities must reach the next executable-pin gate;
  # neither preparation provenance nor dirty unstaged candidate bytes are HEAD.
  def test_host_recipe_explicit_implementation_heads_reach_next_gate
    require_relative "integration/wac04_qualification"
    %w[207f4e81781c0695145ebac49531a1a14d6570d2 44125ab223d82f1b7afc74b03b7cfd7907f7d50b].each do |head|
      host_admission(head: head) do |options, calls, root|
        error = assert_raises(RuntimeError) { Wac04Qualification.qualify(options) }
        assert_equal "executable pin changed", error.message
        assert_equal 6, calls.length
        refute File.exist?(root)
      end
    end
  end

  # Missing, abbreviated, uppercase, padded, non-string and malformed identity
  # values refuse before even read-only Git discovery or fixture creation.
  def test_host_recipe_requires_literal_full_source_head_before_effects
    require_relative "integration/wac04_qualification"
    host_admission do |options, calls, root|
      [nil, "", "main", "207f4e8", "A" * 40, "g" * 40, "a" * 39, "a" * 41, "a" * 40 + "\n", " " + "a" * 40, 123].each do |head|
        error = assert_raises(RuntimeError) { Wac04Qualification.qualify(options.merge("source-head" => head)) }
        assert_includes error.message, "explicit source HEAD required"
        assert_empty calls
        refute File.exist?(root)
      end
      error = assert_raises(RuntimeError) { Wac04Qualification.qualify(options.reject { |key, _| key == "source-head" }) }
      assert_includes error.message, "explicit source HEAD required"
      assert_empty calls
      refute File.exist?(root)
    end
  end

  # A well-formed wrong HEAD and staged bytes refuse before executable/runtime
  # effects. Observations are modeled, never staged in the source checkout.
  def test_host_recipe_rejects_wrong_head_and_dirty_index_before_runtime
    require_relative "integration/wac04_qualification"
    host_admission do |options, calls, root|
      error = assert_raises(RuntimeError) { Wac04Qualification.qualify(options.merge("source-head" => "5d9af78cd7925238358089d53b03d8e419d7951b")) }
      assert_equal "source HEAD mismatch", error.message
      assert_equal 6, calls.length
      refute File.exist?(root)
    end
    host_admission(index: "staged bytes") do |options, calls, root|
      error = assert_raises(RuntimeError) { Wac04Qualification.qualify(options) }
      assert_equal "unexpected source index", error.message
      assert_equal 6, calls.length
      refute File.exist?(root)
    end
  end

  # Independent byte/guidance checks remain admission gates, even with the
  # correct full HEAD. Neither refusal launches any process or creates a root.
  def test_host_recipe_preserves_source_and_guidance_pin_refusals
    require_relative "integration/wac04_qualification"
    host_admission do |options, calls, root|
      error = assert_raises(RuntimeError) { Wac04Qualification.qualify(options.merge("source-sha256" => "0" * 64)) }
      assert_equal "source pin changed", error.message
      assert_empty calls
      refute File.exist?(root)
    end
    host_admission(guidance: "0" * 64) do |options, calls, root|
      error = assert_raises(RuntimeError) { Wac04Qualification.qualify(options) }
      assert_equal "manager guidance pin changed", error.message
      assert_empty calls
      refute File.exist?(root)
    end
  end

  # Each effectful public action requires the new identity option and passes its
  # literal value through. Parsing is tested without qualification or execution.
  def test_host_recipe_cli_requires_and_forwards_source_head
    require_relative "integration/wac04_qualification"
    host_admission do |options, calls, root|
      %w[qualify offline run].each do |action|
        flags = options.flat_map { |key, value| ["--#{key}", value] }
        flags << "--authorize-live" if action == "run"
        method = action == "qualify" ? :qualify : :bounded_journey
        received = nil
        Wac04Qualification.stub(method, ->(parsed, **_keywords) { received = parsed; {} }) do
          capture_io { assert_equal 0, Wac04Qualification.main([action, *flags]) }
          assert_equal options.fetch("source-head"), received.fetch("source-head")
          received = nil
          missing = flags.dup
          position = missing.index("--source-head")
          missing.slice!(position, 2)
          _output, diagnostic = capture_io { assert_equal 2, Wac04Qualification.main([action, *missing]) }
          assert_includes diagnostic, "--source-head FULL_COMMIT_SHA"
          assert_nil received
        end
      end
      assert_empty calls
      refute File.exist?(root)
    end
  end

  # Bundled RubyGems paths avoid Homebrew's external gem enumeration without
  # widening any role policy. Diagnostic facts retain binary bytes and signals.
  def test_host_recipe_bundled_gems_and_binary_diagnostics
    require_relative "integration/wac04_qualification"
    with_workspace do |data|
      root = File.realpath(data)
      config = Wac04Qualification.configuration(root, File.realpath(RbConfig.ruby), { "files" => {} }, "qualify")
      prefix = File.realpath(RbConfig::CONFIG.fetch("prefix"))
      gems = File.join(prefix, "lib/ruby/gems", RbConfig::CONFIG.fetch("ruby_version"))
      config.fetch("environments").each_value do |environment|
        assert_equal gems, environment.fetch("GEM_HOME")
        assert_equal gems, environment.fetch("GEM_PATH")
        refute environment.key?("RUBYOPT")
        home = environment.fetch("CODEX_HOME")
        temporary = environment.fetch("TMPDIR")
        assert_equal File.join(home, "tmp"), temporary
        assert File.directory?(temporary)
        assert_equal 0o700, File.stat(temporary).mode & 0o777
        refute home == temporary || home.start_with?(temporary + "/")
      end
      config.fetch("profiles").each do |role, path|
        policy = File.binread(path)
        assert_includes policy, "(deny default)"
        refute_includes policy, "(allow process-fork"
        assert_includes policy, "(allow signal (target self))"
        refute_includes policy, '(subpath "/opt/homebrew/lib'
        assert_equal role == "worker", policy.include?("(allow file-read* file-write* (subpath \"#{config.fetch('worktree_root')}/T\"))")
      end
      output = "checked\x00\xff".b
      diagnostic = "diagnostic\x00\xfe".b + "z" * 4096
      [AgentCodingTool::CommandResult.new(stdout: output, stderr: diagnostic, exitstatus: 7),
        AgentCodingTool::CommandResult.new(stdout: output, stderr: diagnostic, termsig: 9)].each do |result|
        facts = Wac04Qualification.probe_facts(result, "boundary-manager")
        assert_equal "boundary-manager", facts.fetch("stage")
        assert_equal [result.exitstatus, result.termsig], facts.values_at("exit", "signal")
        assert_equal output, facts.dig("stdout", "prefix_base64").unpack1("m0")
        assert_equal diagnostic.byteslice(0, 2048), facts.dig("stderr", "prefix_base64").unpack1("m0")
        assert_equal Digest::SHA256.hexdigest(diagnostic), facts.dig("stderr", "sha256")
        assert facts.dig("stderr", "prefix_only")
      end
    end
  end

  # Manager cwd is a private child of its already-granted home, with exact
  # policy bytes and separation from tmp, workers and authoritative evidence.
  def test_host_recipe_manager_cwd_containment_and_private_paths
    require_relative "integration/wac04_qualification"
    with_workspace do |data|
      root = File.realpath(data)
      ruby = File.realpath(RbConfig.ruby)
      config = Wac04Qualification.configuration(root, ruby, { "files" => {} }, "offline")
      home = config.dig("environments", "manager", "HOME")
      cwd = config.fetch("manager_cwd")
      assert_equal File.join(home, "work"), cwd
      assert_equal cwd, File.realpath(cwd)
      assert_equal 0o700, File.stat(cwd).mode & 0o777
      assert_equal Process.uid, File.stat(cwd).uid
      [config.fetch("worktree_root"), config.fetch("run_root"), config.fetch("worker_home"),
        config.dig("environments", "manager", "TMPDIR")].each do |separate|
        refute cwd == separate || cwd.start_with?(separate + "/") || separate.start_with?(cwd + "/")
      end
      expected_policy = AgentCodingTool::NativePilotExecutor.policy(role: "manager",
        reads: [File.realpath(RbConfig::CONFIG.fetch("prefix")), Wac04Qualification::SOURCE],
        home: home, workspace: File.join(config.fetch("worktree_root"), "T"), executables: [ruby, ruby])
      assert_equal expected_policy, File.binread(config.fetch("profiles").fetch("manager"))
      assert_equal Digest::SHA256.file(Wac04Qualification::PROBE).hexdigest,
        Wac04Qualification.pin.fetch("files").fetch("test/integration/wac04_executor_probe.rb")
    end
    %w[alias public occupied-work].each do |fault|
      with_workspace do |data|
        root = File.realpath(data)
        home = File.join(root, "manager-home")
        if fault == "alias"
          File.symlink(File.join(root, "state"), home)
        else
          Dir.mkdir(home, fault == "public" ? 0o755 : 0o700)
          File.symlink(File.join(root, "state"), File.join(home, "work")) if fault == "occupied-work"
        end
        assert_raises(fault == "occupied-work" ? Errno::EEXIST : AgentCodingTool::InvalidState) do
          Wac04Qualification.configuration(root, File.realpath(RbConfig.ruby), { "files" => {} }, "offline")
        end
        refute File.exist?(File.join(root, "manager-offline.sb"))
      end
    end
  end

  # Captured EPERM with exit zero must fail, as must a wrong canonical path,
  # stat failure, malformed bytes, missing operations or a failed process.
  def test_host_recipe_manager_cwd_requires_semantic_resolution
    require_relative "integration/wac04_qualification"
    expected = "/private/fixture/manager-home/work"
    operations = { "getcwd" => { "value" => expected }, "realpath" => { "value" => expected }, "stat" => { "value" => true } }
    success = AgentCodingTool::CommandResult.new(stdout: JSON.generate(operations), stderr: "", exitstatus: 0)
    assert Wac04Qualification.manager_cwd_facts(success, expected).fetch("qualified")
    denied = { "class" => "Errno::EPERM", "errno" => 1, "message" => "Operation not permitted" }
    failures = [operations.merge("getcwd" => denied, "realpath" => denied),
      operations.merge("realpath" => { "value" => "/wrong" }), operations.merge("getcwd" => { "value" => "/wrong" }),
      operations.merge("stat" => { "value" => false }), operations.reject { |key, _| key == "realpath" }, {}, []]
    results = failures.map { |value| AgentCodingTool::CommandResult.new(stdout: JSON.generate(value), stderr: "", exitstatus: 0) }
    results << AgentCodingTool::CommandResult.new(stdout: "invalid\x00\xff".b, stderr: "diagnostic\x00\xfe".b, exitstatus: 0)
    results << AgentCodingTool::CommandResult.new(stdout: JSON.generate(operations), stderr: "", exitstatus: 1)
    results << AgentCodingTool::CommandResult.new(stdout: JSON.generate(operations), stderr: "", termsig: 9)
    results.each do |result|
      facts = Wac04Qualification.manager_cwd_facts(result, expected)
      refute facts.fetch("qualified")
      assert_equal [result.exitstatus, result.termsig], facts.values_at("exit", "signal")
      %w[stdout stderr].each do |stream|
        assert_equal result.public_send(stream), facts.dig(stream, "prefix_base64").unpack1("m0")
        assert_equal Digest::SHA256.hexdigest(result.public_send(stream)), facts.dig(stream, "sha256")
      end
    end
  end

  # Qualification uses the actual manager role/cwd/env in a separate harmless
  # ledger, retains semantic failure before raising, and never admits inference.
  def test_host_recipe_manager_cwd_probe_binding_and_failure_receipt
    require_relative "integration/wac04_qualification"
    [true, false].each do |valid|
      with_workspace do |data|
        root = File.realpath(data)
        config = Wac04Qualification.configuration(root, File.realpath(RbConfig.ruby), { "files" => {} }, "offline")
        cwd = config.fetch("manager_cwd")
        operations = { "getcwd" => { "value" => cwd }, "realpath" => { "value" => valid ? cwd : "/wrong" }, "stat" => { "value" => true } }
        result = AgentCodingTool::CommandResult.new(stdout: JSON.generate(operations), stderr: "", exitstatus: 0)
        executor = Object.new
        observed = []
        executor.define_singleton_method(:capture) do |*arguments, **keywords|
          observed << [arguments, keywords]
          result
        end
        create = lambda do |actual_root, name, probe, seconds:|
          assert_equal root, actual_root
          assert_equal "qualify-manager-cwd", name
          assert_equal 10, seconds
          assert_equal config.reject { |key, _| key == "inference_prefixes" }, probe.reject { |key, _| key == "inference_prefixes" }
          assert_equal({ "manager" => [File.realpath(RbConfig.ruby), Wac04Qualification::PROBE, "cwd"] }, probe.fetch("inference_prefixes"))
          executor
        end
        Wac04Qualification.stub(:pilot, create) do
          if valid
            assert Wac04Qualification.qualify_manager_cwd(root, config).fetch("qualified")
          else
            error = assert_raises(RuntimeError) { Wac04Qualification.qualify_manager_cwd(root, config) }
            assert_includes error.message, "manager cwd unqualified"
          end
        end
        expected_argv = AgentCodingTool::CodexManagerAdapter.new(executable: config.fetch("executable"), identity: {}).argv(nil)
        assert_equal [[["manager", expected_argv], { input: "", cwd: cwd }]], observed
        receipt = JSON.parse(File.binread(File.join(root, "manager-cwd.json")))
        assert_equal valid, receipt.fetch("qualified")
        assert_equal operations, receipt.fetch("operations")
        assert_equal config.dig("environments", "manager"), receipt.fetch("environment")
        assert_equal 0, receipt.fetch("inference_invocations")
        error = assert_raises(RuntimeError) do
          Wac04Qualification.journey({ "root" => root, "authorize-live" => true }, live: true, qualification: { "mode" => "offline" })
        end
        assert_equal "qualification mode mismatch", error.message
      end
    end
  end

  # Host preparation refuses occupied/foreign roots and changed source pins
  # before subprocesses or writes. These checks do not qualify host execution.
  def test_host_recipe_refuses_unsafe_root_and_changed_pin_without_writes
    require_relative "integration/wac04_qualification"
    with_workspace do |data|
      original = Dir.children(data)
      assert_raises(RuntimeError) { Wac04Qualification.qualify("root" => data) }
      assert_equal original, Dir.children(data)
      parent = File.join(data, "agent-coding-tool-data-fixtures")
      Dir.mkdir(parent, 0o700)
      parent = File.realpath(parent)
      fresh = File.join(parent, "WAC-04-host-test")
      error = assert_raises(RuntimeError) { Wac04Qualification.qualify("root" => fresh, "source-head" => "2" * 40, "source-sha256" => "0" * 64) }
      assert_includes error.message, "source pin changed"
      refute File.exist?(fresh)
      assert Wac04Qualification.pin.fetch("files").key?("test/integration/wac04_worker.rb")
      assert_equal Wac04Qualification::MANAGER_SKILL_SHA256,
        Wac04Qualification.pin.fetch("files").fetch(Wac04Qualification::MANAGER_SKILL)
      assert_raises(RuntimeError) { Wac04Qualification.bounded_journey({ "root" => fresh }, live: true) }
      refute File.exist?(fresh), "missing live authorization must refuse before fixture creation"
      assert_equal 0o700, File.stat(parent).mode & 0o777
    end
  end
end
