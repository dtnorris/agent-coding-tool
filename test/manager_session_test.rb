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
      command = gate_mode == "emit" ? gate_command("emit") : gate_command("exit", "7")
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
    config = { "executable" => File.realpath(@fake), "pins" => { profile => Digest::SHA256.file(profile).hexdigest },
      "profiles" => %w[manager worker gate].to_h { |role| [role, profile] },
      "environments" => %w[manager worker gate].to_h { |role| [role, { "PATH" => "/usr/bin:/bin" }] },
      "manager_cwd" => @root, "worktree_root" => File.join(@root, "worktrees"), "run_root" => "#{@data}-runs",
      "worker_home" => File.join(@root, "worker-home"), "gate_argv" => gate_command("emit"),
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
    events = [{ "type" => "thread.started", "thread_id" => "wrong-session" },
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
          stream = [{ "type" => "thread.started", "thread_id" => "saved-session" },
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
      fresh = File.join(parent, "WAC-04-host-test")
      error = assert_raises(RuntimeError) { Wac04Qualification.qualify("root" => fresh, "source-sha256" => "0" * 64) }
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
