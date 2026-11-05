# frozen_string_literal: true

require_relative "act24_continuity"
require_relative "../../lib/agent_coding_tool"
require_relative "../../lib/agent_coding_tool/native_pilot_executor"
require "stringio"

# Host-only qualification and bounded native WAC-04 journey. All synthetic Git
# creation and live inference require the operator's separate authorization.
# No command here changes an ordinary repository or ACTD lifecycle/checkpoint.
module Wac04Qualification
  SOURCE = File.realpath(File.join(__dir__, "../.."))
  EXECUTOR = AgentCodingTool::NativePilotExecutor
  PROBE = File.join(SOURCE, "test/integration/wac04_executor_probe.rb")
  DRIVER = File.join(SOURCE, "test/integration/wac04_executor_driver.rb")
  WORKER = File.join(SOURCE, "test/integration/wac04_worker.rb")
  SKILLS = File.realpath(File.join(SOURCE, "../agent-skills"))

  # Pins every implementation/recipe byte, composition and complete bound manager
  # guidance. Source changes invalidate qualification; no network lookup occurs.
  def self.pin
    paths = (Dir.glob("{lib,test}/**/*.{rb,json}", base: SOURCE) +
      %w[bin/agent-coding-tool Gemfile Gemfile.lock Rakefile README.md AGENTS.md split-composition.json]).sort
    files = paths.to_h { |path| [path, Digest::SHA256.file(File.join(SOURCE, path)).hexdigest] }
    files[File.join(SKILLS, "skills/agent-manager/SKILL.md")] = Digest::SHA256.file(File.join(SKILLS, "skills/agent-manager/SKILL.md")).hexdigest
    { "files" => files, "sha256" => Digest::SHA256.hexdigest(JSON.generate(files)) }
  end

  # Builds an immutable native pilot configuration. Each role has its own Codex
  # history/home and no inherited API keys, Ruby preloads, user plugins or shells.
  # Authentication is a fixture-local symlink to the existing file, never copied
  # or writable by inference. Missing file-based ChatGPT auth blocks live mode.
  def self.configuration(root, codex, source, mode)
    ruby = File.realpath(RbConfig.ruby)
    prefix = File.realpath(RbConfig::CONFIG.fetch("prefix"))
    homes = %w[manager worker gate].to_h { |role| [role, File.join(root, "#{role}-home")] }
    homes.each_value { |home| Dir.mkdir(home, 0o700) unless File.exist?(home) }
    auth = nil
    if mode == "live"
      auth = File.realpath(File.join(ENV.fetch("CODEX_HOME", File.join(ENV.fetch("HOME"), ".codex")), "auth.json"))
      stat = File.stat(auth)
      raise "private file-based ChatGPT auth required" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
      %w[manager worker].each { |role| File.symlink(auth, File.join(homes.fetch(role), "auth.json")) }
    end
    worktree_root = File.join(root, mode == "qualify" ? "qualification-worktrees" : "worktrees")
    profiles = homes.to_h do |role, home|
      path = File.join(root, "#{role}-#{mode}.sb")
      reads = [prefix, SOURCE]
      reads << File.join(worktree_root, "T") if role == "gate"
      content = EXECUTOR.policy(role: role, reads: reads, home: home,
        workspace: File.join(worktree_root, "T"), executables: [codex, ruby], auth: role == "gate" ? nil : auth)
      File.write(path, content, mode: "wx", perm: 0o600)
      [role, path]
    end
    environments = homes.to_h do |role, home|
      [role, { "PATH" => "/usr/bin:/bin", "HOME" => home, "CODEX_HOME" => home, "TMPDIR" => home,
        "LANG" => "C", "LC_ALL" => "C", "TZ" => "UTC" }]
    end
    pins = source.fetch("files").to_h { |path, sha| [File.expand_path(path, SOURCE), sha] }
    [codex, ruby, *profiles.values].each { |path| pins[path] = Digest::SHA256.file(path).hexdigest }
    config = { "executable" => codex, "pins" => pins, "profiles" => profiles, "environments" => environments,
      "manager_cwd" => File.join(root, "scratch"), "worker_home" => homes.fetch("worker"),
      "worktree_root" => worktree_root, "run_root" => File.join(root, "case", "data-runs"),
      "gate_argv" => [ruby, WORKER, "validate", root], "manager_skill" => File.join(SKILLS, "skills/agent-manager/SKILL.md") }
    if mode == "offline"
      config["inference_prefixes"] = {
        "manager" => [ruby, File.join(SOURCE, "test/support/fixtures/manager_inference.rb"), homes.fetch("manager"), "success"],
        "worker" => [ruby, WORKER, "worker", root] }
    end
    config
  end

  # Creates one exclusive private ledger in existing ACT checkpoint storage.
  # A distinct qualification pilot cannot be adopted as a fresh live budget.
  def self.pilot(root, name, config, seconds: 900)
    directory = File.join(root, "case", "data-runs", "checkpoints", name)
    FileUtils.mkdir_p(File.dirname(directory), mode: 0o700)
    Dir.mkdir(directory, 0o700)
    if config["enclosing_lease"]
      lease = config.fetch("enclosing_lease")
      seconds = [seconds, lease.fetch("deadline") - Time.now.to_f, lease.fetch("monotonic_deadline") - EXECUTOR.clock].min
    end
    EXECUTOR.create(directory, config, seconds: seconds)
  end

  # Rehearses the actual production supervisor with fixed harmless subprocesses:
  # all role boundaries, binary/nonzero status, independent expiry and controller
  # death. Any failure stops before inference and retains the consumed ledger.
  def self.rehearse(root, config)
    workspace = File.join(config.fetch("worktree_root"), "T", "probe")
    FileUtils.mkdir_p(workspace, mode: 0o700)
    File.write(File.join(root, "secret"), "host-only", mode: "wx", perm: 0o600)
    receipts = {}
    %w[manager worker gate].each do |role|
      probe = config.merge("profiles" => config.fetch("profiles").merge("gate" => config.fetch("profiles").fetch(role)),
        "environments" => config.fetch("environments").merge("gate" => config.fetch("environments").fetch(role)),
        "gate_argv" => [File.realpath(RbConfig.ruby), PROBE, "boundary", root, role, workspace])
      executor = pilot(root, "qualify-#{role}", probe, seconds: 20)
      result = executor.capture("gate", probe.fetch("gate_argv"), input: "", cwd: workspace)
      raise "#{role} confinement unqualified" unless result.success? && result.stdout.include?("BOUNDARY PASS #{role}") && result.stdout.include?("EXEC DENIED")
      receipts[role] = { "stdout_base64" => [result.stdout].pack("m0"), "stderr_base64" => [result.stderr].pack("m0"), "exit" => result.exitstatus }
    end
    binary = config.merge("gate_argv" => [File.realpath(RbConfig.ruby), PROBE, "binary", root])
    result = pilot(root, "qualify-binary", binary, seconds: 10).capture("gate", binary.fetch("gate_argv"), input: "", cwd: workspace)
    raise "byte/status preservation failed" unless result.stdout == "checked\x00\xff".b && result.stderr == "diagnostic\x00\xfe".b && result.exitstatus == 7
    receipts["binary"] = { "stdout_base64" => [result.stdout].pack("m0"), "stderr_base64" => [result.stderr].pack("m0"), "exit" => 7 }
    sleeper = config.merge("gate_argv" => [File.realpath(RbConfig.ruby), PROBE, "sleep", root], "probe_cwd" => workspace)
    enclosing = pilot(root, "qualify-enclosing", sleeper, seconds: 2)
    begin
      enclosing.capture("gate", sleeper.fetch("gate_argv"), input: "", cwd: workspace)
      raise "enclosing expiry unexpectedly succeeded"
    rescue AgentCodingTool::InvalidState => error
      raise unless error.message.include?("expired")
      directory = File.join(root, "case", "data-runs", "checkpoints", "qualify-enclosing")
      started = Dir.glob(File.join(directory, "*.started.json")).fetch(0)
      result = Act24Continuity.read(started.sub(".started.json", ".json"))
      raise "enclosing child teardown overran lease" if result.fetch("lease_overrun")
      receipts["enclosing_expiry"] = result
    end
    expired = pilot(root, "qualify-expiry", sleeper.merge("gate_seconds" => 0.2), seconds: 5)
    begin
      expired.capture("gate", sleeper.fetch("gate_argv"), input: "", cwd: workspace)
      raise "expiry unexpectedly succeeded"
    rescue AgentCodingTool::InvalidState => error
      raise unless error.message.include?("expired")
      receipts["expiry"] = error.message
    end
    pilot(root, "qualify-death", sleeper, seconds: 10)
    directory = File.join(root, "case", "data-runs", "checkpoints", "qualify-death")
    controller = Process.spawn({ "PATH" => "/usr/bin:/bin" }, File.realpath(RbConfig.ruby), DRIVER, directory,
      out: File.join(root, "death.stdout"), err: File.join(root, "death.stderr"), unsetenv_others: true)
    started = nil
    until started || EXECUTOR.clock >= (death_deadline ||= EXECUTOR.clock + 5)
      started = Dir.glob(File.join(directory, "*.started.json")).first
      sleep 0.01 unless started
    end
    raise "controller did not reach supervised spawn" unless started
    ownership = Act24Continuity.read(started)
    raise "foreign controller identity" unless ownership.fetch("controller") == controller
    Process.kill("KILL", controller)
    Process.waitpid(controller)
    controller = nil
    receipt_path = started.sub(".started.json", ".json")
    until File.exist?(receipt_path) || EXECUTOR.clock >= death_deadline
      sleep 0.01
    end
    receipt = Act24Continuity.read(receipt_path)
    raise "controller death teardown failed" unless receipt.fetch("failure").include?("controller died") && !FeedbackRuntime.identity(ownership.fetch("child"))
    receipts["controller_death"] = ownership.merge(receipt)
    raise "boundary probe changed control" unless File.binread(File.join(root, "secret")) == "host-only"
    receipts
  ensure
    if controller
      Process.kill("KILL", controller) rescue Errno::ESRCH
      Process.waitpid(controller) rescue Errno::ECHILD
    end
  end

  # Qualifies only a fresh declared host fixture and literal reviewed pins. All
  # installed CLI observations are read-only, time bounded and retained. No live
  # calls, synthetic Git mutations or credential copies occur in this phase.
  def self.qualify(options)
    root = File.expand_path(options.fetch("root"))
    parent = File.dirname(root)
    raise "fresh WAC-04 host fixture required" unless File.realpath(parent) == parent &&
      File.basename(parent) == "agent-coding-tool-data-fixtures" && File.basename(root).match?(/\AWAC-04-host-[A-Za-z0-9-]+\z/) &&
      !File.exist?(root) && !File.symlink?(root)
    source = pin
    raise "source pin changed" unless source.fetch("sha256") == options.fetch("source-sha256")
    raise "this candidate requires the inspected legacy ACT composition" unless AgentCodingTool::Bootstrap::COMPOSITION.fetch("mode") == "legacy"
    codex = File.realpath(options.fetch("codex"))
    raise "executable pin changed" unless Digest::SHA256.file(codex).hexdigest == options.fetch("codex-sha256")
    raise "Darwin host required" unless RUBY_PLATFORM.include?("darwin")
    Dir.mkdir(root, 0o700)
    created = true
    %w[scratch case].each { |name| Dir.mkdir(File.join(root, name), 0o700) }
    transport = AgentCodingTool::NativeCommandTransport.new
    observations = {}
    { "version" => ["--version"], "exec" => ["exec", "--help"], "resume" => ["exec", "resume", "--help"],
      "auth" => ["login", "status"], "features" => ["features", "list"] }.each do |name, arguments|
      result = transport.call([codex, *arguments], timeout: 5,
        env: ENV.to_h.slice("HOME", "CODEX_HOME", "PATH", "LANG", "LC_ALL"), unsetenv_others: true)
      File.binwrite(File.join(root, "#{name}.stdout"), result.stdout)
      File.binwrite(File.join(root, "#{name}.stderr"), result.stderr)
      raise "runtime observation failed: #{name}" unless result.success?
      observations[name] = result.stdout + result.stderr
    end
    raise "unsupported installed version" unless observations.fetch("version").strip.match?(/\Acodex-cli 0\.(162\.1|166\.0)\z/)
    %w[exec resume].each do |name|
      raise "missing installed flags: #{name}" unless %w[--json --config --ignore-user-config --ignore-rules --skip-git-repo-check].all? { |flag| observations.fetch(name).include?(flag) }
    end
    raise "ChatGPT authentication required" unless observations.fetch("auth").lines.any? { |line| line.strip == "Logged in using ChatGPT" }
    raise "explicit resume unavailable" unless observations.fetch("resume").include?("[SESSION_ID] [PROMPT]")
    git_observation = transport.call(["/usr/bin/xcrun", "--find", "git"], timeout: 5)
    raise "Git unavailable" unless git_observation.success?
    git = File.realpath(git_observation.stdout.strip)
    source_state = {}
    { "head" => %w[rev-parse HEAD], "branch" => %w[rev-parse --abbrev-ref HEAD], "origin" => %w[remote get-url origin],
      "index" => %w[diff --cached --binary], "worktree" => %w[status --porcelain=v1 -z] }.each do |name, arguments|
      result = transport.call([git, *arguments], cwd: SOURCE,
        env: { "PATH" => "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS" => "0", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null" },
        unsetenv_others: true, timeout: 5)
      raise "source observation failed" unless result.success?
      source_state[name] = { "base64" => [result.stdout].pack("m0"), "sha256" => Digest::SHA256.hexdigest(result.stdout) }
    end
    raise "unexpected source baseline/index" unless source_state.fetch("head").fetch("base64").unpack1("m0").strip == "5d9af78cd7925238358089d53b03d8e419d7951b" &&
      source_state.fetch("index").fetch("base64").unpack1("m0").empty?
    source_state["realpath"] = SOURCE
    source_state["composition"] = AgentCodingTool::Bootstrap::COMPOSITION
    isolated_config = File.join(root, "sandbox-config")
    Dir.mkdir(isolated_config, 0o700)
    target = File.join(isolated_config, "read-only-deny")
    tool_probe = transport.call([codex, "-c", 'sandbox_mode="read-only"', "-c", 'approval_policy="never"',
      "sandbox", "--", File.realpath(RbConfig.ruby), PROBE, "read-only", target], cwd: root,
      env: { "HOME" => File.join(root, "scratch"), "CODEX_HOME" => isolated_config, "PATH" => "/usr/bin:/bin" },
      unsetenv_others: true, timeout: 10)
    File.binwrite(File.join(root, "read-only.stdout"), tool_probe.stdout)
    File.binwrite(File.join(root, "read-only.stderr"), tool_probe.stderr)
    raise "installed read-only tool sandbox unqualified" unless tool_probe.success? && tool_probe.stdout.include?("READ-ONLY DENIED") && !File.exist?(target)
    config = configuration(root, codex, source, "qualify")
    rehearsals = rehearse(root, config)
    raise "source changed during qualification" unless pin == source
    receipt = { "source" => source, "source_observations" => source_state, "runtime" => observations, "rehearsals" => rehearsals,
      "status" => "PASS harmless host qualification only", "live_continuity" => "NOT RUN" }
    Act24Continuity.save(File.join(root, "qualification.json"), receipt, exclusive: true)
    receipt
  rescue StandardError => error
    Act24Continuity.save(File.join(root, "blocked.json"), { "status" => "BLOCKED", "reason" => error.message }, exclusive: true) if created
    raise
  end

  # Runs one continuous production public-entry journey with real admission,
  # native supervision, worktrees, checkpoints and exact-session review. Offline
  # mode substitutes only inference; live mode requires explicit host consent.
  # All candidate execution is the fixed read-only byte validator, never eval.
  def self.journey(options, live: false, qualification: nil, lease: nil)
    raise "separate bounded host live authorization required" if live && !options["authorize-live"]
    qualification ||= qualify(options)
    root = File.expand_path(options.fetch("root"))
    git, diagnostic, status = Open3.capture3("/usr/bin/xcrun", "--find", "git")
    raise "Git unavailable: #{diagnostic}" unless status.success?
    git = File.realpath(git.strip)
    environment = { "PATH" => "#{File.dirname(git)}:/usr/bin:/bin", "HOME" => File.join(root, "scratch"),
      "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_TERMINAL_PROMPT" => "0",
      "GIT_CONFIG_COUNT" => "2", "GIT_CONFIG_KEY_0" => "core.hooksPath", "GIT_CONFIG_VALUE_0" => "/dev/null",
      "GIT_CONFIG_KEY_1" => "protocol.file.allow", "GIT_CONFIG_VALUE_1" => "always" }
    environment["CODEX_HOME"] = ENV.fetch("CODEX_HOME", File.join(ENV.fetch("HOME"), ".codex"))
    transport = AgentCodingTool::NativeCommandTransport.new
    command = lambda do |argv, cwd = root|
      result = transport.call(argv, cwd: cwd, env: environment, timeout: 10, unsetenv_others: true)
      raise "fixture command failed: #{argv.first} (#{result.shell_status})" unless result.success?
      result.stdout
    end
    ordinary, remote, data = %w[ordinary remote.git case/data].map { |name| File.join(root, name) }
    command.call([git, "init", "--bare", "--initial-branch=main", remote])
    command.call([git, "clone", remote, ordinary])
    command.call([git, "config", "user.name", "ACT offline fixture"], ordinary)
    command.call([git, "config", "user.email", "fixture@example.invalid"], ordinary)
    File.write(File.join(ordinary, "file.txt"), "base\n")
    command.call([git, "add", "--", "file.txt"], ordinary)
    command.call([git, "commit", "-m", "synthetic baseline"], ordinary)
    command.call([git, "push", "origin", "HEAD:refs/heads/main"], ordinary)
    baseline = command.call([git, "rev-parse", "HEAD"], ordinary).strip
    FileUtils.mkdir_p(File.join(data, "tasks"))
    File.write(File.join(data, "config.yml"), YAML.dump("repo_root" => root, "worktree_root" => File.join(root, "worktrees")))
    File.write(File.join(data, "tasks", "T.yml"), YAML.dump("id" => "T", "title" => "Native offline manager fixture", "depends_on" => [],
      "repositories" => { "repo" => { "access" => "write", "path" => ordinary } },
      "goal" => "Add worker-change.txt containing worker, then review independent verification.",
      "constraints" => ["Fixture-only writes; no live inference or publication."],
      "acceptance" => ["Candidate adds worker-change.txt and the independent byte check passes."]))
    # The worker gets the full canonical prompt and one fixture-only native
    # patch instruction; it cannot execute shells or write authoritative records.
    task_path = File.join(data, "tasks", "T.yml")
    task = YAML.safe_load(File.binread(task_path))
    task["constraints"] = ["Use the native apply_patch tool to add worker-change.txt containing exactly worker followed by newline (seven bytes). " \
      "No shell, network tools, Git commands, other agents, installs or services. Do not run validation; the host owns it. " \
      "The original synthetic file.txt contains base followed by newline. Finish with a plain text summary. " \
      "Repository inspection and export instructions are superseded for this tiny host-seeded fixture only; all provenance is already host-bound."]
    File.write(task_path, YAML.dump(task))
    config = configuration(root, File.realpath(options.fetch("codex")), qualification.fetch("source"), live ? "live" : "offline")
    config["enclosing_lease"] = lease if lease
    pilot(root, "native-WAC-04", config)
    calls = []
    entry = lambda do |*argv, expected: 0|
      raise "bound source changed" unless pin == qualification.fetch("source")
      output, diagnostic = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: SOURCE, data_root: data, out: output, err: diagnostic,
        native_pilot: AgentCodingTool::NativePilotExecutor.new(File.join(root, "case", "data-runs", "checkpoints", "native-WAC-04")))
      code = cli.run(argv)
      calls << { "argv" => argv, "status" => code, "stdout_base64" => [output.string].pack("m0"), "stderr_base64" => [diagnostic.string].pack("m0") }
      Act24Continuity.save(File.join(root, "public-calls.json"), calls)
      raise "public entry failed: #{argv.take(2)}: #{diagnostic.string}" unless code == expected
      output.string
    end
    # CLI's existing host Git/preflight roots are synthetic; scoped environment
    # changes affect only this trusted recipe process and are restored on exit.
    original_env = ENV.to_h
    ENV.replace(environment.merge("HOME" => original_env.fetch("HOME")))
    entry.call("prepare", "T")
    first = JSON.parse(entry.call("manager", "start", "T", "--id", "M"))
    raise "missing initial reasoning" unless first.dig("turns", 0, "decision", "decision") == "CONTINUE"
    entry.call("manager", "review", "M", "--session", first.fetch("session_id"), expected: 2)
    entry.call("launch", "T", "--codex")
    handoff = Act24Continuity.read(Dir.glob("#{data}-runs/T/*/handoff.json").fetch(0))
    raise "worker session must be independent" if handoff.fetch("session_id") == first.fetch("session_id")
    workspace = handoff.fetch("workspace")
    entry.call("checkpoint", "record", "T", "--workspace", workspace)
    entry.call("checkpoint", "verify", "T", "--workspace", workspace)
    entry.call("checkpoint", "gate", "T", "--workspace", workspace, "--", *config.fetch("gate_argv"))
    selectors = ["--task", "T", "--attempt", handoff.fetch("attempt").to_s,
      "--invocation", handoff.fetch("invocation_id"), "--session", handoff.fetch("session_id")]
    wrong = selectors.dup
    wrong[wrong.index("--invocation") + 1] = "wrong-invocation"
    entry.call("manager", "bind", "M", *wrong, expected: 2)
    entry.call("manager", "bind", "M", *selectors)
    entry.call("manager", "review", "M", "--session", "wrong-session", expected: 2)
    reviewed = JSON.parse(entry.call("manager", "review", "M", "--session", first.fetch("session_id")))
    raise "candidate review failed" unless reviewed.dig("turns", 1, "decision", "decision") == "ACCEPT"
    directory = File.join(root, "case", "data-runs", "checkpoints", "native-WAC-04")
    ledger = Act24Continuity.read(File.join(directory, "ledger.json"))
    raise "pilot accounting mismatch" unless ledger.fetch("counts") == { "manager" => 2, "worker" => 1, "gate" => 1 } && !ledger["active"] && !ledger["held"]
    started = Dir.glob(File.join(directory, "*.started.json")).map { |path| Act24Continuity.read(path) }
    raise "inference did not restart/exit" unless started.map { |row| row.fetch("child") }.uniq.length == 4 &&
      started.all? { |row| !FeedbackRuntime.identity(row.fetch("child")) }
    raise "ordinary checkout changed" unless command.call([git, "rev-parse", "HEAD"], ordinary).strip == baseline &&
      command.call([git, "status", "--porcelain=v1"], ordinary).empty? && File.binread(File.join(ordinary, "file.txt")) == "base\n"
    raise "source changed during journey" unless pin == qualification.fetch("source")
    metadata = {}
    if live
      %w[manager worker].each do |role|
        session = role == "manager" ? first.fetch("session_id") : handoff.fetch("session_id")
        matches = Dir.glob(File.join(root, "#{role}-home", "sessions", "**", "*.jsonl")).select { |path| File.basename(path).include?(session) }
        raise "missing/ambiguous #{role} history" unless matches.length == 1
        models = File.foreach(matches.first).filter_map do |line|
          event = JSON.parse(line)
          event.dig("payload", "model") if event["type"] == "turn_context"
        end.uniq
        raise "effective #{role} model not observed" if models.empty?
        metadata[role] = { "session" => session, "models" => models, "history_sha256" => Digest::SHA256.file(matches.first).hexdigest }
      end
    end
    receipt = { "status" => live ? "RUN COMPLETE; David must assess semantic continuity" : "PASS offline only",
      "live_continuity" => live ? "HOST REVIEW REQUIRED" : "NOT RUN", "baseline" => baseline,
      "review" => reviewed, "worker" => handoff, "accounting" => ledger, "processes" => started, "model_observations" => metadata,
      "semantic_check" => "Assess meaningful use of turn one's criterion in turn two, correct candidate/gate interpretation, and unchanged ordinary repositories; nonce echo is insufficient." }
    Act24Continuity.save(File.join(root, live ? "live.json" : "offline.json"), receipt, exclusive: true)
    receipt
  rescue StandardError => error
    Act24Continuity.save(File.join(root, "journey-blocked.json"), { "status" => "BLOCKED", "reason" => error.message }, exclusive: true) if qualification
    raise
  ensure
    ENV.replace(original_env) if original_env
  end

  # Independently supervises the complete trusted journey, including existing
  # Launcher preflight subprocesses. The controller has its own owned group;
  # native inference supervisors deliberately use separate groups and finish
  # their own teardown when this controller dies. The original deadline also
  # bounds the durable native ledger, so reconstruction cannot renew the pilot.
  def self.bounded_journey(options, live:)
    raise "separate bounded host live authorization required" if live && !options["authorize-live"]
    qualification = qualify(options)
    root = File.expand_path(options.fetch("root"))
    lease = { "deadline" => Time.now.to_f + 900, "monotonic_deadline" => EXECUTOR.clock + 900 }
    Act24Continuity.save(File.join(root, "enclosing-lease.json"), lease, exclusive: true)
    stdout = File.open(File.join(root, "controller.stdout"), "wx", 0o600)
    stderr = File.open(File.join(root, "controller.stderr"), "wx", 0o600)
    controller = Process.fork do
      Process.setpgrp
      STDOUT.reopen(stdout)
      STDERR.reopen(stderr)
      begin
        result = journey(options, live: live, qualification: qualification, lease: lease)
        puts JSON.generate(result)
        STDOUT.flush
        STDERR.flush
        exit! 0
      rescue StandardError => error
        warn "BLOCKED: #{error.class}: #{error.message}"
        STDERR.flush
        exit! 2
      end
    end
    stopped = nil
    previous = %w[TERM INT HUP].to_h { |signal| [signal, Signal.trap(signal) { stopped = signal }] }
    reason = nil
    until EXECUTOR.exited?(controller)
      reason = "enclosing lease expired" if EXECUTOR.clock >= lease.fetch("monotonic_deadline") || Time.now.to_f >= lease.fetch("deadline")
      reason ||= "operator cancellation #{stopped}" if stopped
      reason ||= "controller output limit" if stdout.size + stderr.size > EXECUTOR::OUTPUT_LIMIT
      break if reason
      sleep 0.01
    end
    # The controller is still waitable and its owned group cannot be reused.
    Process.kill("KILL", -controller) rescue Errno::ESRCH
    _pid, status = Process.waitpid2(controller)
    controller = nil
    control = File.join(root, "case", "data-runs", "checkpoints", "native-WAC-04")
    cleanup_deadline = EXECUTOR.clock + 2
    if File.file?(File.join(control, "ledger.json"))
      while Act24Continuity.read(File.join(control, "ledger.json"))["active"] && EXECUTOR.clock < cleanup_deadline
        sleep 0.01
      end
      reason ||= "native invocation still held/unknown" if Act24Continuity.read(File.join(control, "ledger.json"))["active"]
    end
    Act24Continuity.save(File.join(root, "controller-supervision.json"), lease.merge(
      "exit" => status.exitstatus, "signal" => status.termsig, "failure" => reason,
      "stdout_sha256" => Digest::SHA256.file(stdout.path).hexdigest, "stderr_sha256" => Digest::SHA256.file(stderr.path).hexdigest), exclusive: true)
    raise "bounded journey failed: #{reason || status.exitstatus || status.termsig}; inspect #{root}" unless reason.nil? && status.success?
    Act24Continuity.read(File.join(root, live ? "live.json" : "offline.json"))
  ensure
    if controller
      Process.kill("KILL", -controller) rescue Errno::ESRCH
      Process.waitpid(controller) rescue Errno::ECHILD
    end
    previous&.each { |signal, handler| Signal.trap(signal, handler) }
    stdout&.close
    stderr&.close
  end

  # Explicit host entry: pin/qualify/offline/run. Run requires a separate consent
  # switch and a fresh root; it always requalifies, never renews an old pilot.
  def self.main(arguments)
    action = arguments.shift
    if action == "pin" && arguments.empty?
      puts JSON.pretty_generate(pin)
      return 0
    end
    options = {}
    parser = OptionParser.new do |opts|
      %w[root source-sha256 codex codex-sha256].each { |name| opts.on("--#{name} VALUE") { |value| options[name] = value } }
      opts.on("--authorize-live") { options["authorize-live"] = true }
    end
    parser.require_exact = true
    parser.parse!(arguments)
    required = %w[codex codex-sha256 root source-sha256] + (action == "run" ? ["authorize-live"] : [])
    raise "usage: pin | {qualify|offline|run} --root FRESH_PATH --source-sha256 HASH --codex PATH --codex-sha256 HASH [--authorize-live for run]" unless
      %w[qualify offline run].include?(action) && arguments.empty? && options.keys.sort == required.sort
    result = action == "qualify" ? qualify(options) : bounded_journey(options, live: action == "run")
    puts JSON.pretty_generate(result)
    0
  rescue StandardError => error
    warn "BLOCKED: #{error.class}: #{error.message}"
    2
  end
end

exit Wac04Qualification.main(ARGV) if $PROGRAM_NAME == __FILE__
