# frozen_string_literal: true

require_relative "act24_continuity"
require_relative "../../lib/agent_coding_tool"
require_relative "../../lib/agent_coding_tool/native_pilot_executor"
require_relative "../../lib/agent_coding_tool/codex_manager_adapter"
require "stringio"

# Host-only qualification and bounded native WAC-04 journey. All synthetic Git
# creation and live inference require the operator's separate authorization.
# No command here changes an ordinary repository or ACTD lifecycle/checkpoint.
module Wac04Qualification
  # Original prepared input provenance; implementation admission uses an explicit HEAD.
  PREPARATION_SOURCE_HEAD = "5d9af78cd7925238358089d53b03d8e419d7951b"
  SOURCE = File.realpath(File.join(__dir__, "../.."))
  EXECUTOR = AgentCodingTool::NativePilotExecutor
  PROBE = File.join(SOURCE, "test/integration/wac04_executor_probe.rb")
  DRIVER = File.join(SOURCE, "test/integration/wac04_executor_driver.rb")
  WORKER = File.join(SOURCE, "test/integration/wac04_worker.rb")
  SKILLS = File.expand_path("../agent-skills", SOURCE)
  MANAGER_SKILL = File.join(SKILLS, "skills/agent-manager/SKILL.md")
  # Complete guidance from bound agent-skills revision 5162361187be082ba897d79571345a65caad33bd.
  MANAGER_SKILL_SHA256 = "7921fec8415631767f4c7935ca6f2761e8f66c5e993d1e6ae3fe53fd7a25b7d6"

  # Pins every implementation/recipe byte, composition and complete bound manager
  # guidance identity. Declaring its required digest needs no operator checkout;
  # qualification validates the actual guidance before writes or subprocesses.
  def self.pin
    paths = (Dir.glob("{lib,test}/**/*.{rb,json}", base: SOURCE) +
      %w[bin/agent-coding-tool Gemfile Gemfile.lock Rakefile README.md AGENTS.md split-composition.json]).sort
    files = paths.to_h { |path| [path, Digest::SHA256.file(File.join(SOURCE, path)).hexdigest] }
    files[MANAGER_SKILL] = MANAGER_SKILL_SHA256
    { "files" => files, "sha256" => Digest::SHA256.hexdigest(JSON.generate(files)) }
  end

  # Builds an immutable native pilot configuration. Each role has its own Codex
  # history/home and no inherited API keys, Ruby preloads, user plugins or shells.
  # Authentication is a fixture-local symlink to the existing file, never copied
  # or writable by inference. Missing file-based ChatGPT auth blocks live mode.
  def self.configuration(root, codex, source, mode)
    ruby = File.realpath(RbConfig.ruby)
    prefix = File.realpath(RbConfig::CONFIG.fetch("prefix"))
    # Homebrew's default gem search escapes prefix before the probe can start.
    # Use only bundled gems already covered by the existing read-only grant.
    gems = File.join(prefix, "lib/ruby/gems", RbConfig::CONFIG.fetch("ruby_version"))
    homes = %w[manager worker gate].to_h { |role| [role, File.join(root, "#{role}-home")] }
    homes.each_value { |home| Dir.mkdir(home, 0o700) unless File.exist?(home) }
    homes.each_value { |home| EXECUTOR.private_directory!(home) }
    # Installed Codex refuses helper aliases when CODEX_HOME is inside TMPDIR.
    # Keep temporary files below the existing role grant, separate from its home.
    homes.each_value { |home| Dir.mkdir(File.join(home, "tmp"), 0o700) }
    manager_cwd = File.join(homes.fetch("manager"), "work")
    Dir.mkdir(manager_cwd, 0o700)
    EXECUTOR.private_directory!(manager_cwd)
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
      [role, { "PATH" => "/usr/bin:/bin", "HOME" => home, "CODEX_HOME" => home, "TMPDIR" => File.join(home, "tmp"),
        "GEM_HOME" => gems, "GEM_PATH" => gems,
        "LANG" => "C", "LC_ALL" => "C", "TZ" => "UTC" }]
    end
    pins = source.fetch("files").to_h { |path, sha| [File.expand_path(path, SOURCE), sha] }
    [codex, ruby, *profiles.values].each { |path| pins[path] = Digest::SHA256.file(path).hexdigest }
    config = { "executable" => codex, "pins" => pins, "profiles" => profiles, "environments" => environments,
      "manager_cwd" => manager_cwd, "worker_home" => homes.fetch("worker"), "worker_final_artifact" => "worker-change.txt",
      "worktree_root" => worktree_root, "run_root" => File.join(root, "case", "data-runs"),
      "gate_argv" => [ruby, WORKER, "validate", root], "manager_skill" => MANAGER_SKILL }
    if mode == "offline"
      config["inference_prefixes"] = {
        "manager" => [ruby, File.join(SOURCE, "test/support/fixtures/manager_inference.rb"), homes.fetch("manager"), "success"],
        "worker" => [ruby, WORKER, "worker", root] }
    end
    config
  end

  # Describes a captured probe without decoding arbitrary bytes. Returns bounded
  # prefixes and complete hashes/status; raw streams remain in native receipts.
  def self.probe_facts(result, stage)
    { "stage" => stage, "exit" => result.exitstatus, "signal" => result.termsig }.merge(
      %w[stdout stderr].to_h do |name|
        bytes = result.public_send(name)
        [name, { "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes),
          "prefix_base64" => [bytes.byteslice(0, 2048)].pack("m0"), "prefix_only" => bytes.bytesize > 2048 }]
      end)
  end

  # Interprets captured cwd operations, including exceptions encoded by a probe
  # that exits zero. Returns semantic success plus bounded raw diagnostics;
  # malformed JSON is failure data, never a successful process qualification.
  def self.manager_cwd_facts(result, expected)
    facts = probe_facts(result, "manager-cwd").merge("expected" => expected, "qualified" => false)
    begin
      operations = JSON.parse(result.stdout)
      facts["operations"] = operations
      facts["qualified"] = result.success? && operations == {
        "getcwd" => { "value" => expected }, "realpath" => { "value" => expected }, "stat" => { "value" => true } }
    rescue JSON::ParserError => error
      facts["parse_error"] = error.message
    end
    facts
  end

  # Runs only the fixed Ruby cwd probe through the existing inference-substitute
  # seam in a separate harmless ledger. Uses the actual manager cwd/profile/env;
  # never invokes Codex or consumes a live turn. Exact streams/status are kept by
  # the native supervisor, and the semantic receipt is saved before refusal.
  def self.qualify_manager_cwd(root, config)
    probe = config.merge("inference_prefixes" => { "manager" => [File.realpath(RbConfig.ruby), PROBE, "cwd"] })
    executor = pilot(root, "qualify-manager-cwd", probe, seconds: 10)
    argv = AgentCodingTool::CodexManagerAdapter.new(executable: config.fetch("executable"), identity: {}).argv(nil)
    result = executor.capture("manager", argv, input: "", cwd: config.fetch("manager_cwd"))
    facts = manager_cwd_facts(result, config.fetch("manager_cwd")).merge(
      "profile_sha256" => Digest::SHA256.file(config.fetch("profiles").fetch("manager")).hexdigest,
      "environment" => config.fetch("environments").fetch("manager"), "inference_invocations" => 0)
    Act24Continuity.save(File.join(root, "manager-cwd.json"), facts, exclusive: true)
    raise "manager cwd unqualified; inspect manager-cwd.json and qualify-manager-cwd raw receipts: #{JSON.generate(facts)}" unless facts.fetch("qualified")
    facts
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
    stage = "manager-cwd"
    receipts["manager_cwd"] = qualify_manager_cwd(root, config)
    %w[manager worker gate].each do |role|
      stage = "boundary-#{role}"
      probe = config.merge("profiles" => config.fetch("profiles").merge("gate" => config.fetch("profiles").fetch(role)),
        "environments" => config.fetch("environments").merge("gate" => config.fetch("environments").fetch(role)),
        "gate_argv" => [File.realpath(RbConfig.ruby), PROBE, "boundary", root, role, workspace])
      executor = pilot(root, "qualify-#{role}", probe, seconds: 20)
      result = executor.capture("gate", probe.fetch("gate_argv"), input: "", cwd: workspace)
      receipts[role] = probe_facts(result, stage)
      raise "#{role} confinement unqualified: #{JSON.generate(receipts[role])}" unless result.success? && result.stdout.include?("BOUNDARY PASS #{role}") && result.stdout.include?("EXEC DENIED")
    end
    stage = "binary-status"
    binary = config.merge("gate_argv" => [File.realpath(RbConfig.ruby), PROBE, "binary", root])
    result = pilot(root, "qualify-binary", binary, seconds: 10).capture("gate", binary.fetch("gate_argv"), input: "", cwd: workspace)
    raise "byte/status preservation failed: #{JSON.generate(probe_facts(result, stage))}" unless result.stdout == "checked\x00\xff".b && result.stderr == "diagnostic\x00\xfe".b && result.exitstatus == 7
    receipts["binary"] = { "stdout_base64" => [result.stdout].pack("m0"), "stderr_base64" => [result.stderr].pack("m0"), "exit" => 7 }
    sleeper = config.merge("gate_argv" => [File.realpath(RbConfig.ruby), PROBE, "sleep", root], "probe_cwd" => workspace)
    stage = "enclosing-expiry"
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
    stage = "turn-expiry"
    expired = pilot(root, "qualify-expiry", sleeper.merge("gate_seconds" => 0.2), seconds: 5)
    begin
      expired.capture("gate", sleeper.fetch("gate_argv"), input: "", cwd: workspace)
      raise "expiry unexpectedly succeeded"
    rescue AgentCodingTool::InvalidState => error
      raise unless error.message.include?("expired")
      receipts["expiry"] = error.message
    end
    stage = "controller-death"
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
    # Retain the harmless worker's bytes outside the future task worktrees;
    # the actual role policy was tested, but probe paths are not ACT candidates.
    File.rename(workspace, File.join(root, "qualification-candidate"))
    Dir.rmdir(File.dirname(workspace))
    receipts
  rescue StandardError => error
    Act24Continuity.save(File.join(root, "rehearsal-blocked.json"),
      { "stage" => stage, "reason" => "#{error.class}: #{error.message}", "completed" => receipts }, exclusive: true)
    raise
  ensure
    if controller
      Process.kill("KILL", controller) rescue Errno::ESRCH
      Process.waitpid(controller) rescue Errno::ECHILD
    end
  end

  # Qualifies only a fresh declared host fixture and literal reviewed pins. All
  # installed CLI observations are read-only, time bounded and retained. No live
  # calls, synthetic Git mutations or credential copies occur in this phase.
  # Requires a literal full source-head plus the independent byte digest; missing,
  # malformed or mismatched HEAD/index refuses before fixture/runtime effects.
  # Returns the qualification receipt; failed checks raise and never repair inputs.
  def self.qualify(options, mode = "live")
    root = File.expand_path(options.fetch("root"))
    parent = File.dirname(root)
    raise "fresh WAC-04 host fixture required" unless File.realpath(parent) == parent &&
      File.basename(parent) == "agent-coding-tool-data-fixtures" && File.basename(root).match?(/\AWAC-04-host-[A-Za-z0-9-]+\z/) &&
      !File.exist?(root) && !File.symlink?(root)
    expected_head = options["source-head"]
    raise "explicit source HEAD required (40 lowercase hex characters)" unless expected_head.is_a?(String) && expected_head.match?(/\A[0-9a-f]{40}\z/)
    source = pin
    raise "source pin changed" unless source.fetch("sha256") == options.fetch("source-sha256")
    raise "manager guidance path changed" unless File.realpath(SKILLS) == SKILLS && File.realpath(MANAGER_SKILL) == MANAGER_SKILL
    raise "manager guidance pin changed" unless Digest::SHA256.file(MANAGER_SKILL).hexdigest == MANAGER_SKILL_SHA256
    raise "this candidate requires the inspected legacy ACT composition" unless AgentCodingTool::Bootstrap::COMPOSITION.fetch("mode") == "legacy"
    transport = AgentCodingTool::NativeCommandTransport.new
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
    source_state["actual_head"] = source_state.fetch("head").fetch("base64").unpack1("m0").strip
    source_state["expected_head"] = expected_head
    source_state["preparation_head"] = PREPARATION_SOURCE_HEAD
    raise "source HEAD mismatch" unless source_state.fetch("actual_head") == expected_head
    raise "unexpected source index" unless source_state.fetch("index").fetch("base64").unpack1("m0").empty?
    source_state["realpath"] = SOURCE
    source_state["composition"] = AgentCodingTool::Bootstrap::COMPOSITION
    codex = File.realpath(options.fetch("codex"))
    raise "executable pin changed" unless Digest::SHA256.file(codex).hexdigest == options.fetch("codex-sha256")
    raise "Darwin host required" unless RUBY_PLATFORM.include?("darwin")
    Dir.mkdir(root, 0o700)
    created = true
    %w[scratch case].each { |name| Dir.mkdir(File.join(root, name), 0o700) }
    observations = {}
    runtime_status = {}
    { "version" => ["--version"], "exec" => ["exec", "--help"], "resume" => ["exec", "resume", "--help"],
      "auth" => ["login", "status"], "features" => ["features", "list"] }.each do |name, arguments|
      stage = "runtime-#{name}"
      result = transport.call([codex, *arguments], timeout: 5,
        env: ENV.to_h.slice("HOME", "CODEX_HOME", "PATH", "LANG", "LC_ALL"), unsetenv_others: true)
      File.binwrite(File.join(root, "#{name}.stdout"), result.stdout)
      File.binwrite(File.join(root, "#{name}.stderr"), result.stderr)
      runtime_status[name] = probe_facts(result, stage)
      Act24Continuity.save(File.join(root, "runtime-status.json"), runtime_status)
      raise "runtime observation failed: #{JSON.generate(runtime_status[name])}" unless result.success?
      observations[name] = result.stdout + result.stderr
    end
    stage = "installed-version"
    raise "unsupported installed version" unless observations.fetch("version").strip.match?(/\Acodex-cli 0\.(162\.1|166\.0)\z/)
    %w[exec resume].each do |name|
      stage = "installed-#{name}-flags"
      raise "missing installed flags: #{name}" unless %w[--json --config --ignore-user-config --ignore-rules --skip-git-repo-check].all? { |flag| observations.fetch(name).include?(flag) }
    end
    stage = "installed-authentication"
    raise "ChatGPT authentication required" unless observations.fetch("auth").lines.any? { |line| line.strip == "Logged in using ChatGPT" }
    stage = "installed-explicit-resume"
    raise "explicit resume unavailable" unless observations.fetch("resume").include?("[SESSION_ID] [PROMPT]")
    isolated_config = File.join(root, "sandbox-config")
    stage = "installed-read-only-sandbox"
    Dir.mkdir(isolated_config, 0o700)
    target = File.join(isolated_config, "read-only-deny")
    tool_probe = transport.call([codex, "-c", 'sandbox_mode="read-only"', "-c", 'approval_policy="never"',
      "sandbox", "--", File.realpath(RbConfig.ruby), PROBE, "read-only", target], cwd: root,
      env: { "HOME" => File.join(root, "scratch"), "CODEX_HOME" => isolated_config, "PATH" => "/usr/bin:/bin" },
      unsetenv_others: true, timeout: 10)
    File.binwrite(File.join(root, "read-only.stdout"), tool_probe.stdout)
    File.binwrite(File.join(root, "read-only.stderr"), tool_probe.stderr)
    runtime_status["read-only"] = probe_facts(tool_probe, stage)
    Act24Continuity.save(File.join(root, "runtime-status.json"), runtime_status)
    raise "installed read-only tool sandbox unqualified: #{JSON.generate(runtime_status['read-only'])}" unless tool_probe.success? && tool_probe.stdout.include?("READ-ONLY DENIED") && !File.exist?(target)
    stage = "role-rehearsals"
    config = configuration(root, codex, source, mode)
    rehearsals = rehearse(root, config)
    raise "source changed during qualification" unless pin == source
    receipt = { "source" => source, "source_observations" => source_state, "runtime" => observations, "rehearsals" => rehearsals, "config" => config, "mode" => mode,
      "status" => "PASS harmless host qualification only", "live_continuity" => "NOT RUN" }
    Act24Continuity.save(File.join(root, "qualification.json"), receipt, exclusive: true)
    receipt
  rescue StandardError => error
    if created
      Act24Continuity.save(File.join(root, "blocked.json"), { "status" => "BLOCKED", "stage" => stage || "source-admission",
        "failure_class" => error.class.name, "reason" => error.message }, exclusive: true)
      Act24Continuity.save(File.join(root, "RESULT.json"), failure_report(root, exit_status: nil, signal: nil, failure: nil), exclusive: true)
    end
    raise
  end

  # Runs one continuous production public-entry journey with real admission,
  # native supervision, worktrees, checkpoints and exact-session review. Offline
  # mode substitutes only inference; live mode requires explicit host consent.
  # All candidate execution is the fixed read-only byte validator, never eval.
  def self.journey(options, live: false, qualification: nil, lease: nil)
    raise "separate bounded host live authorization required" if live && !options["authorize-live"]
    stage = "qualification"
    qualification ||= qualify(options, live ? "live" : "offline")
    root = File.expand_path(options.fetch("root"))
    raise "qualification mode mismatch" unless qualification.fetch("mode") == (live ? "live" : "offline")
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
    task["constraints"] = ["Do not invoke any tools or edit files. The CLI will write your final response unchanged as worker-change.txt. " \
      "Your entire final response must be exactly the word worker followed by one newline (seven UTF-8 bytes); no Markdown, explanation or other text. " \
      "Do not omit the newline. Do not run validation; the independent host owns it. " \
      "Repository inspection/export and summary instructions are superseded only for this tiny host-seeded fixture; provenance is host-bound."]
    File.write(task_path, YAML.dump(task))
    config = qualification.fetch("config").dup
    config["enclosing_lease"] = lease if lease
    pilot(root, "native-WAC-04", config)
    calls = []
    entry = lambda do |*argv, expected: 0|
      stage = "public-entry:#{argv.take(2).join('/')}"
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
    raise "worker candidate/final evidence mismatch" unless File.binread(File.join(workspace, "worker-change.txt")) == File.binread(handoff.fetch("final_path"))
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
        models = File.foreach(matches.first, encoding: "UTF-8").filter_map do |line|
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
    Act24Continuity.save(File.join(root, "journey-blocked.json"), { "status" => "BLOCKED", "stage" => stage, "failure_class" => error.class.name, "reason" => error.message }, exclusive: true) if qualification
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
    qualification = qualify(options, live ? "live" : "offline")
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
    unless reason.nil? && status.success?
      report = failure_report(root, exit_status: status.exitstatus, signal: status.termsig, failure: reason)
      Act24Continuity.save(File.join(root, "RESULT.json"), report, exclusive: true)
      raise "bounded journey failed at #{report['stage']}: #{report['failure_class']}: #{report['reason']} " \
        "(exit=#{status.exitstatus.inspect}, signal=#{status.termsig.inspect}); inspect #{root}/RESULT.json"
    end
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

  # Consolidates the failed stage, exception, public command and raw receipt
  # references without interpreting candidate content. Returns bounded failure
  # metadata; missing receipts stay explicit. Malformed receipts raise normally.
  def self.failure_report(root, exit_status:, signal:, failure:)
    blocked_path = File.join(root, "journey-blocked.json")
    blocked_path = File.join(root, "blocked.json") unless File.file?(blocked_path)
    blocked = File.file?(blocked_path) ? Act24Continuity.read(blocked_path) : {}
    calls_path = File.join(root, "public-calls.json")
    calls = File.file?(calls_path) ? Act24Continuity.read(calls_path) : []
    command = calls.last
    manager_failures = Dir.glob(File.join(root, "case/data-runs/.manager-sessions/*/failure-*.json"))
    native_receipts = Dir.glob(File.join(root, "case/data-runs/checkpoints/native-WAC-04/*.json")).reject do |path|
      %w[ledger.json config.json].include?(File.basename(path)) || path.end_with?(".started.json")
    end
    paths = Dir.glob(File.join(root, "case/data-runs/checkpoints/*/*.{json,stdout,stderr}")) +
      %w[controller.stdout controller.stderr controller-supervision.json journey-blocked.json public-calls.json blocked.json runtime-status.json manager-cwd.json startup.json].map { |name| File.join(root, name) }
    paths += Dir.glob(File.join(root, "case/data-runs/.manager-sessions/*/{failure,result}-*.json"))
    { "status" => "BLOCKED", "stage" => blocked["stage"] || "controller-supervision",
      "failure_class" => blocked["failure_class"] || "RuntimeError",
      "reason" => blocked["reason"] || failure || "controller exited without a complete journey receipt",
      "controller_exit" => exit_status, "controller_signal" => signal,
      "controller_failure" => failure, "public_command" => command,
      "underlying_failures" => manager_failures.sort.to_h { |path| [path.delete_prefix(root + "/"), Act24Continuity.read(path)] },
      "native_command_status" => native_receipts.sort.to_h { |path| [path.delete_prefix(root + "/"), Act24Continuity.read(path)] },
      "raw_evidence" => paths.select { |path| File.file?(path) }.sort.to_h do |path|
        [path.delete_prefix(root + "/"), { "bytes" => File.size(path), "sha256" => Digest::SHA256.file(path).hexdigest }]
      end, "live_retry_authorized" => false, "live_continuity" => "UNPROVEN" }
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
      %w[root source-head source-sha256 codex codex-sha256].each { |name| opts.on("--#{name} VALUE") { |value| options[name] = value } }
      opts.on("--authorize-live") { options["authorize-live"] = true }
    end
    parser.require_exact = true
    parser.parse!(arguments)
    required = %w[codex codex-sha256 root source-head source-sha256] + (action == "run" ? ["authorize-live"] : [])
    raise "usage: pin | {qualify|offline|run} --root FRESH_PATH --source-head FULL_COMMIT_SHA --source-sha256 HASH --codex PATH --codex-sha256 HASH [--authorize-live for run]" unless
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
