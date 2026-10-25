# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "securerandom"
require "time"
require "yaml"
require_relative "../feedback_runtime"
require_relative "act24_worker"

# Host-only, zero-inference ACT-24 recipe. Public run pins source and creates an
# absent fixture root. Internal commands are fixed test glue, not a host shell
# API. Native confinement and supervision must qualify before worker dispatch.
module Act24Continuity
  SOURCE = File.realpath(File.join(__dir__, "../.."))
  SCRIPT = File.join(SOURCE, "test/integration/act24_continuity.rb")
  WORKER = File.join(SOURCE, "test/integration/act24_worker.rb")
  MAX_SECONDS = 120
  PREPARED_ACT = "12f74405d421abcf396a3f498259a7235b614216"
  DECISIONS = %w[scope permission acceptance tests coverage paid_resource publication paused operator_blocked].freeze

  # Returns the source inventory digest binding production and all recipe code.
  # Reads only; missing/unreadable source raises rather than shrinking inventory.
  def self.source_identity
    paths = Dir.glob("lib/**/*.rb", base: SOURCE).sort +
      %w[bin/agent-coding-tool test/feedback_runtime.rb test/integration/act24_continuity.rb test/integration/act24_worker.rb]
    files = paths.to_h { |path| [path, Digest::SHA256.file(File.join(SOURCE, path)).hexdigest] }
    { "files" => files, "sha256" => Digest::SHA256.hexdigest(JSON.generate(files)) }
  end

  # Writes new or atomically replaced trusted JSON, syncing file and directory.
  # Returns the path; occupied exclusive paths and filesystem failures propagate.
  def self.save(path, value, exclusive: false)
    bytes = JSON.pretty_generate(value) + "\n"
    temporary = exclusive ? path : "#{path}.#{SecureRandom.hex(6)}.tmp"
    File.open(temporary, "wx", 0o600) { |file| file.write(bytes); file.flush; file.fsync }
    File.rename(temporary, path) unless exclusive
    File.open(File.dirname(path), &:fsync)
    path
  end

  # Reads trusted JSON and returns its mapping; absent/tampered files raise.
  def self.read(path)
    raise "symlinked evidence" if File.symlink?(path)
    JSON.parse(File.binread(path))
  end

  # Uses a sanitized, fixture-only environment for every executable child.
  # No authentication, user config, inherited Ruby injection or Git hooks enter.
  def self.environment(config)
    root = config.fetch("root")
    { "PATH" => "#{File.dirname(config.fetch('git'))}:/usr/bin:/bin", "HOME" => "#{root}/home",
      "LANG" => "C", "LC_ALL" => "C", "TZ" => "UTC", "TMPDIR" => "#{root}/tmp",
      "TMP" => "#{root}/tmp", "TEMP" => "#{root}/tmp", "CODEX_HOME" => "#{root}/home",
      "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_TERMINAL_PROMPT" => "0",
      "GIT_CONFIG_COUNT" => "2", "GIT_CONFIG_KEY_0" => "core.hooksPath", "GIT_CONFIG_VALUE_0" => "/dev/null",
      "GIT_CONFIG_KEY_1" => "protocol.file.allow", "GIT_CONFIG_VALUE_1" => "always",
      "SENTINEL_PID" => config.fetch("sentinel_pid").to_s, "SENTINEL_PORT" => config.fetch("sentinel_port").to_s,
      "AGENT_CODING_TOOL_DATA_DIR" => "#{root}/case/data" }
  end

  # Returns a deny-default Seatbelt policy. Workers can write only candidate
  # files; tests only scratch. Neither can read host/controller/evidence/secret
  # bytes, fork, exec a replacement, signal other processes or use the network.
  # Controller has synthetic-root writes and trusted process execution only.
  # macOS private policy syntax is qualified at runtime, never assumed portable.
  def self.policy(config, role)
    root = config.fetch("root")
    runtime = config.fetch("ruby_prefix")
    system_reads = %w[/System/Library /usr/lib /usr/share]
    reads = system_reads + [runtime]
    literals = %w[/dev/null /dev/random /dev/urandom]
    if role == "controller"
      reads += [SOURCE, root, config.fetch("skills"), config.fetch("skills_admin"), File.dirname(File.dirname(config.fetch("git")))]
      literals += [config.fetch("codex"), "/bin/sh"]
      writes = [root]
    else
      reads += ["#{root}/case/workspace", "#{root}/scratch"]
      literals += [WORKER, "#{root}/probe.rb"]
      writes = role == "worker" ? ["#{root}/case/workspace", "#{root}/scratch"] : ["#{root}/scratch"]
    end
    lines = ["(version 1)", "(deny default)", "(allow file-read-metadata)",
      '(allow sysctl-read (sysctl-name "hw.ncpu" "hw.activecpu" "hw.memsize" "hw.pagesize" "hw.machine" "kern.osrelease" "kern.ostype"))',
      "(allow signal (target self))", "(allow process-info* (target self))",
      "(allow process-exec (literal #{config.fetch('ruby').dump}))"]
    reads.each { |path| lines << "(allow file-read* file-map-executable (subpath #{path.dump}))" }
    literals.each { |path| lines << "(allow file-read* file-map-executable (literal #{path.dump}))" }
    writes.each { |path| lines << "(allow file-write* (subpath #{path.dump}))" }
    lines << '(allow file-write-data (literal "/dev/null"))'
    if role == "controller"
      lines += ["(allow process-fork)", "(allow process-exec)", "(allow signal (target children))",
                "(allow process-info* (target children))"]
      %w[config.json lease.json dispatch-budget.json controller.sb worker.sb test.sb supervisor-secret].each do |name|
        lines << "(deny file-write* (literal #{"#{root}/#{name}".dump}))"
      end
      lines << "(deny file-read* (literal #{"#{root}/supervisor-secret".dump}))"
    else
      lines += ["(deny file-read* file-write* (subpath #{"#{root}/case/workspace/.git".dump}))", "(deny process-fork)"]
      # sandbox-exec must perform its initial exec. A replacement exec still
      # inherits confinement; only the pinned Ruby binary is executable.
    end
    lines.join("\n") + "\n"
  end

  # Requests a fixed operation from the independent supervisor before allowing
  # execution. Returns raw byte captures, exit/signal/timing metadata. No unknown
  # liveness is treated as quiescence; missing supervision fails closed.
  def self.capture(config, argv, cwd:, input: "", confined: nil)
    root = config.fetch("root")
    token = SecureRandom.uuid
    prefix = "#{root}/captures/#{token}"
    role = confined || "controller"
    full = ["/usr/bin/sandbox-exec", "-f", "#{root}/#{role}.sb", *argv]
    File.binwrite("#{prefix}.stdin", input)
    started = FeedbackRuntime.clock
    metadata = { "argv" => argv, "executed_argv" => full, "cwd" => cwd, "environment" => environment(config),
                 "stdin_sha256" => Digest::SHA256.hexdigest(input), "started_at" => Time.now.utc.iso8601(6) }
    begin
      # Only trusted controller code can write jobs. Every operation is fixed
      # and confined; no external worker has a host endpoint. Sibling sandbox
      # processes avoid the refused nested-sandbox design.
      save("#{root}/jobs/#{token}.json", { "role" => role, "argv" => argv, "cwd" => cwd,
        "owner" => FeedbackRuntime.identity(Process.pid) }, exclusive: true)
      until File.file?("#{root}/jobs/#{token}.json.done")
        raise "supervisor unavailable/deadline" if Time.now.to_f >= config.fetch("deadline")
        sleep 0.005
      end
      completion = read("#{root}/jobs/#{token}.json.done")
      raise "confined job refused: #{completion['error']}" if completion["error"]
      metadata.merge!(completion)
      metadata.merge!("stdout_sha256" => Digest::SHA256.file("#{prefix}.stdout").hexdigest,
        "stderr_sha256" => Digest::SHA256.file("#{prefix}.stderr").hexdigest,
        "stdout_hex" => File.binread("#{prefix}.stdout").unpack1("H*"),
        "stderr_hex" => File.binread("#{prefix}.stderr").unpack1("H*"))
      metadata
    rescue Exception => error
      metadata["exception"] = { "class" => error.class.name, "message" => error.message }
      raise
    ensure
      metadata["seconds"] = FeedbackRuntime.clock - started
      metadata["finished_at"] = Time.now.utc.iso8601(6)
      save("#{prefix}.json", metadata, exclusive: true)
    end
  end

  # Accepts only finite fixture worker/test/probe/sleeper and ACT/Git operations from a live
  # trusted controller, never arbitrary host argv. Returns validated argv/cwd;
  # foreign owners, roles, paths or command forms raise before dispatch.
  def self.job!(config, request, owned)
    root = config.fetch("root")
    owner = request.fetch("owner")
    raise "foreign job owner" unless owned[owner.fetch("pid")] == owner && FeedbackRuntime.identity(owner.fetch("pid")) == owner
    argv = request.fetch("argv")
    role = request.fetch("role")
    cwd = request.fetch("cwd")
    raise "foreign sandbox role" unless %w[controller worker test].include?(role)
    ruby = config.fetch("ruby")
    worker = role == "worker" && cwd == "#{root}/case/workspace" &&
      [[ruby, WORKER, "exec", "--json", "-"], [ruby, WORKER, "exec", "resume", "--json", Act24Worker::SESSION, "-"]].include?(argv)
    test = role == "test" && cwd == "#{root}/case/workspace" && argv == [ruby, "answer_test.rb"]
    probe = %w[worker test].include?(role) && cwd == "#{root}/scratch" && argv == [ruby, "#{root}/probe.rb", role,
      "#{root}/secret", "#{root}/config.json", "#{root}/lease.json", SCRIPT, "#{root}/case/workspace/.git/config"]
    sleeper = role == "test" && cwd == root && argv == [ruby, "-e", "sleep 120"]
    trusted = role == "controller" && trusted_command?(config, argv, cwd)
    raise "unsupported confined operation" unless worker || test || probe || sleeper || trusted
    if worker || test
      raise "dispatch before complete host qualification" unless File.file?("#{root}/qualification.json") && File.file?("#{root}/supervision-qualification.json")
    end
    [argv, cwd]
  end

  # Recognizes only the recipe's fixed host operations on declared synthetic
  # paths. Returns false for arbitrary shell/Ruby snippets, external task/data
  # roots, Git configuration or publication. No worker can write this channel.
  def self.trusted_command?(config, argv, cwd)
    root = config.fetch("root")
    ruby = config.fetch("ruby")
    workspace = "#{root}/case/workspace"
    config_path = "#{root}/config.json"
    if argv.first == config.fetch("codex")
      return cwd == root && [["--version"], %w[exec resume --help], %w[app-server --help]].include?(argv.drop(1))
    end
    if argv.take(2) == [ruby, SCRIPT]
      return cwd == root && [["controller", config_path], ["resume-check", config_path, "#{root}/restart.json"],
        ["resume-check", config_path, "#{root}/no-progress-ledger.json"], ["fault-correction", config_path]].include?(argv.drop(2))
    end
    return true if cwd == root && argv == [ruby, "#{root}/controller-probe.rb"]
    if argv.take(2) == [ruby, "#{SOURCE}/bin/agent-coding-tool"]
      return false unless cwd == workspace
      args = argv.drop(2)
      return true if [%w[prepare T], %w[start T]].include?(args)
      return true if %w[record verify].any? { |verb| args == ["checkpoint", verb, "T", "--workspace", workspace] }
      return %w[gate edit-during-gate].any? { |mode| args == ["checkpoint", "gate", "T", "--workspace", workspace, "--", ruby, SCRIPT, mode, config_path] }
    end
    return false unless argv.first == config.fetch("git")
    source = "#{root}/case/source"
    remote = "#{root}/case/remote.git"
    commands = [
      [root, ["init", "--initial-branch=main", source]], [source, ["add", "baseline.txt"]],
      [source, ["-c", "user.name=ACT fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "baseline"]],
      [root, ["clone", "--bare", source, remote]], [source, ["remote", "add", "origin", remote]],
      [root, ["clone", remote, workspace]], [workspace, ["rev-parse", "HEAD"]]
    ]
    return true if commands.include?([cwd, argv.drop(1)])
    %w[0 1].any? do |index|
      destination = "#{root}/replay-#{index}"
      args = argv.drop(1)
      clone = cwd == root && args == ["clone", "--no-local", "--no-hardlinks", "--no-checkout", remote, destination]
      checkout = cwd == destination && args.take(2) == %w[checkout --detach] && args.length == 3 && args.last.match?(/\A[0-9a-f]{40}\z/)
      apply = cwd == destination && [args[0...-1]].any? { |prefix| [%w[apply --binary], %w[apply --check --binary]].include?(prefix) } &&
        args.last.match?(/\A#{Regexp.escape(root)}\/case\/data-runs\/checkpoints\/T\/[0-9a-f]{32}\/[0-9a-f-]{36}\.patch\z/)
      clone || checkout || apply
    end
  end

  # Runs a fixed trusted command and returns its stdout bytes, refusing failures.
  # Subprocess evidence is retained by capture, including command errors.
  def self.command!(config, argv, cwd: config.fetch("root"), input: "")
    result = capture(config, argv, cwd: cwd, input: input)
    raise "command failed: #{argv.inspect} (#{result['exit']})" unless result.fetch("exit").zero?
    [result.fetch("stdout_hex")].pack("H*")
  end

  # Invokes the real public ACT entry with synthetic ACTD. Returns command
  # evidence even on rejection; only fixture prepare/start/checkpoints are used.
  def self.act(config, *argv)
    capture(config, [config.fetch("ruby"), "#{SOURCE}/bin/agent-coding-tool", *argv], cwd: "#{config.fetch('root')}/case/workspace")
  end

  # Enforces persistent cumulative limits/holds before dispatch. Returns updated
  # counters, or raises without reset for decision holds, unknown liveness,
  # expiration, repeated failure or exhausted turn/correction budget.
  def self.reserve(ledger, now: Time.now.to_f)
    turns, corrections = ledger.values_at("turns", "corrections")
    raise "malformed cumulative budget" unless turns.is_a?(Integer) && turns.between?(0, 3) &&
      corrections.is_a?(Integer) && corrections.between?(0, 2) && corrections == [turns - 1, 0].max
    raise "decision required: #{ledger['hold']}" if ledger["hold"]
    raise "unknown child liveness/dispatch" if ledger["pending"]
    raise "absolute deadline expired" unless now < ledger.fetch("deadline")
    raise "cumulative limit reached" unless ledger.fetch("turns") < 3 && ledger.fetch("corrections") < 2
    ledger.merge("turns" => ledger.fetch("turns") + 1,
      "corrections" => ledger.fetch("corrections") + (ledger.fetch("turns").positive? ? 1 : 0), "pending" => true)
  end

  # Requires supervisor reaping receipts for every previously requested worker
  # or test. Returns nil; pending/unknown liveness forbids edits, preservation,
  # host checks and redispatch. Controller-only commands are not worker writers.
  def self.quiescent_jobs!(root)
    raise "unresolved supervision ownership/liveness" if Dir.glob("#{root}/*.supervision.json").any? { |path| !read(path).fetch("quiescent") }
    Dir.glob("#{root}/jobs/*.json").each do |path|
      next unless %w[worker test].include?(read(path).fetch("role"))
      raise "unknown worker/test liveness" unless File.file?("#{path}.done") && read("#{path}.done")["reaped_by"].is_a?(Integer)
    end
    nil
  end

  # Verifies both source pins and immutable case identity before continuation.
  # Returns nil; workspace/session/base drift and artifact mutation raise.
  def self.bind!(config, ledger)
    quiescent_jobs!(config.fetch("root"))
    raise "stale source" unless source_identity == config.fetch("source")
    raise "wrong workspace/session" unless ledger.fetch("workspace") == "#{config.fetch('root')}/case/workspace" &&
      ledger.fetch("session") == Act24Worker::SESSION
    base = command!(config, [config.fetch("git"), "rev-parse", "HEAD"], cwd: ledger.fetch("workspace")).strip
    raise "stale candidate baseline" unless base == ledger.fetch("base")
    ledger.fetch("candidates").each do |candidate|
      raise "missing/tampered original" unless Digest::SHA256.file(candidate.fetch("path")).hexdigest == candidate.fetch("sha256")
    end
    nil
  end

  # Fixed independent gate: run candidate code ONLY inside the test sandbox,
  # then compare raw candidate bytes without evaluating them in this verifier.
  # A forged zero exit/test/success marker cannot change the expected bytes.
  def self.gate(config)
    workspace = "#{config.fetch('root')}/case/workspace"
    result = capture(config, [config.fetch("ruby"), "answer_test.rb"], cwd: workspace, confined: "test")
    $stdout.binmode.write([result.fetch("stdout_hex")].pack("H*"))
    $stderr.binmode.write([result.fetch("stderr_hex")].pack("H*"))
    expected = { "answer.rb" => Act24Worker::CORRECTED, "answer_test.rb" => Act24Worker::TEST }
    exact = expected.all? { |path, bytes| File.file?("#{workspace}/#{path}") && !File.symlink?("#{workspace}/#{path}") && File.binread("#{workspace}/#{path}") == bytes }
    warn "independent byte verifier: #{exact ? 'PASS' : 'FAIL; expected 42 with original test'}"
    result.fetch("exit").zero? && exact ? 0 : 1
  end

  # Creates one local-only synthetic repository, ACTD/state and disposable clone.
  # Uses real ACT prepare/start/checkpoints; no operator store is writable.
  # Returns initial persistent ledger; native Git/ACT failures propagate.
  def self.setup(config)
    root = config.fetch("root")
    git = config.fetch("git")
    ordinary = "#{root}/case/source"
    remote = "#{root}/case/remote.git"
    workspace = "#{root}/case/workspace"
    data = "#{root}/case/data"
    FileUtils.mkdir_p(["#{data}/tasks", "#{data}/state"])
    command!(config, [git, "init", "--initial-branch=main", ordinary])
    File.binwrite("#{ordinary}/baseline.txt", "synthetic ACT-24 baseline\n")
    command!(config, [git, "add", "baseline.txt"], cwd: ordinary)
    command!(config, [git, "-c", "user.name=ACT fixture", "-c", "user.email=fixture@example.test", "commit", "-m", "baseline"], cwd: ordinary)
    command!(config, [git, "clone", "--bare", ordinary, remote])
    command!(config, [git, "remote", "add", "origin", remote], cwd: ordinary)
    command!(config, [git, "clone", remote, workspace])
    File.binwrite("#{data}/config.yml", YAML.dump("repo_root" => "#{root}/case", "worktree_root" => "#{root}/case/worktrees"))
    File.binwrite("#{data}/tasks/T.yml", YAML.dump("id" => "T", "title" => "Synthetic continuity", "depends_on" => [],
      "repositories" => { "repo" => { "access" => "write", "path" => ordinary } }, "goal" => "Return 42",
      "constraints" => ["offline synthetic fixture"], "acceptance" => ["fixed independent gate"]))
    %w[prepare start].each do |verb|
      result = act(config, verb, "T")
      raise "synthetic ACT #{verb} failed: #{result}" unless result.fetch("exit").zero?
    end
    { "turns" => 0, "corrections" => 0, "deadline" => config.fetch("deadline"), "pending" => false,
      "workspace" => workspace, "session" => Act24Worker::SESSION, "hold" => nil,
      "base" => command!(config, [git, "rev-parse", "HEAD"], cwd: workspace).strip, "candidates" => [], "phase" => "initial" }
  end

  # Reserves a turn durably, dispatches the selected external CLI interface and
  # requires kernel-confirmed reaping before clearing pending. Returns evidence;
  # interrupted/unknown children retain a permanent decision-required stop.
  def self.worker(config, ledger, failure: nil, no_progress: false, interrupt_after_dispatch: false)
    bind!(config, ledger)
    reserved = reserve(ledger)
    save("#{config.fetch('root')}/ledger.json", reserved)
    prompt = { "objective" => "Return 42; preserve the test and scope", "workspace" => ledger.fetch("workspace"),
      "session" => ledger.fetch("session") }
    argv = ["exec", "--json", "-"]
    if failure
      candidate = ledger.fetch("candidates").last
      prompt.merge!("failure" => failure, "candidate" => candidate.merge("base_sha" => ledger.fetch("base")),
        "files_sha256" => %w[answer.rb answer_test.rb].map { |path| Digest::SHA256.file("#{ledger.fetch('workspace')}/#{path}").hexdigest })
      prompt["fixture_fault"] = "no_progress" if no_progress
      argv = ["exec", "resume", "--json", ledger.fetch("session"), "-"]
    end
    result = capture(config, [config.fetch("ruby"), WORKER, *argv], cwd: ledger.fetch("workspace"),
      input: JSON.generate(prompt), confined: "worker")
    raise "worker failed" unless result.fetch("exit").zero?
    event = JSON.parse([result.fetch("stdout_hex")].pack("H*").lines.first)
    raise "wrong resumed session" unless event.fetch("thread_id") == ledger.fetch("session")
    if interrupt_after_dispatch
      save("#{config.fetch('root')}/interrupted-correction.json", result, exclusive: true)
      exit! 78 # Actual process interruption before clearing the durable reservation.
    end
    ledger.replace(reserved.merge("pending" => false))
    save("#{config.fetch('root')}/ledger.json", ledger)
    result
  end

  # Preserves complete bytes with real ACT and independently verifies them.
  # Returns record identity; failures preserve original evidence without repair.
  def self.preserve(config, ledger)
    quiescent_jobs!(config.fetch("root"))
    result = act(config, "checkpoint", "record", "T", "--workspace", ledger.fetch("workspace"))
    raise "ACT preservation failed" unless result.fetch("exit").zero?
    verified = act(config, "checkpoint", "verify", "T", "--workspace", ledger.fetch("workspace"))
    raise "ACT verification failed" unless verified.fetch("exit").zero?
    # CLI JSON is authoritative; no replacement patch generator or evidence store.
    value = JSON.parse([verified.fetch("stdout_hex")].pack("H*"))
    record = value.fetch("record")
    raise "untracked file omitted" unless record.fetch("changed_files").map { |row| row.fetch("path") }.sort == %w[answer.rb answer_test.rb]
    record.merge("path" => value.fetch("path"), "base_sha" => ledger.fetch("base"),
      "session" => ledger.fetch("session"), "workspace" => ledger.fetch("workspace"))
  end

  # Invokes the same fixed real ACT gate for both candidates, returning raw
  # failure/success evidence for continuation and review.
  def self.verify_candidate(config, ledger)
    act(config, "checkpoint", "gate", "T", "--workspace", ledger.fetch("workspace"), "--",
      config.fetch("ruby"), SCRIPT, "gate", "#{config.fetch('root')}/config.json")
  end

  # Asserts a required negative control actually refuses; unexpected acceptance
  # raises and leaves the whole host journey failed. Returns the observed error.
  def self.refuses
    yield
    raise "negative control unexpectedly accepted"
  rescue RuntimeError, KeyError => error
    raise if error.message == "negative control unexpectedly accepted"
    error.message
  end

  # Replays each preserved artifact independently with native Git on its exact
  # baseline, comparing all synthetic bytes. Returns replay identities; wrong
  # hashes, applicability, missing files or changed originals raise.
  def self.replay(config, ledger)
    ledger.fetch("candidates").each_with_index.map do |candidate, index|
      destination = "#{config.fetch('root')}/replay-#{index}"
      command!(config, [config.fetch("git"), "clone", "--no-local", "--no-hardlinks", "--no-checkout",
        "#{config.fetch('root')}/case/remote.git", destination])
      command!(config, [config.fetch("git"), "checkout", "--detach", ledger.fetch("base")], cwd: destination)
      command!(config, [config.fetch("git"), "apply", "--check", "--binary", candidate.fetch("path")], cwd: destination)
      command!(config, [config.fetch("git"), "apply", "--binary", candidate.fetch("path")], cwd: destination)
      expected = index.zero? ? Act24Worker::INITIAL : Act24Worker::CORRECTED
      raise "independent replay bytes differ" unless File.binread("#{destination}/answer.rb") == expected &&
        File.binread("#{destination}/answer_test.rb") == Act24Worker::TEST &&
        Digest::SHA256.file(candidate.fetch("path")).hexdigest == candidate.fetch("sha256")
      { "workspace" => destination, "artifact_sha256" => candidate.fetch("sha256"),
        "files_sha256" => %w[answer.rb answer_test.rb].to_h { |path| [path, Digest::SHA256.file("#{destination}/#{path}").hexdigest] } }
    end
  end

  # Spends the final allowed turn on a deterministic no-progress correction,
  # using the actual original failure and real preservation. Its stop persists;
  # the already-proven successor pointer/bytes are restored for final review.
  # Original artifacts are never edited; all fault records remain inspectable.
  def self.no_progress_control(config, ledger)
    root = config.fetch("root")
    workspace = ledger.fetch("workspace")
    state_path = "#{root}/case/data/state/T.yml"
    state = File.binread(state_path)
    successor = ledger.fetch("candidates").last
    pointer_path = "#{File.dirname(successor.fetch('path'))}/current.json"
    pointer = File.binread(pointer_path)
    answer = File.binread("#{workspace}/answer.rb")
    begin
      File.binwrite("#{workspace}/answer.rb", Act24Worker::INITIAL)
      incomplete = preserve(config, ledger)
      failure = verify_candidate(config, ledger)
      raise "no-progress starting gate unexpectedly passed" if failure.fetch("exit").zero?
      fault = ledger.merge("candidates" => [*ledger.fetch("candidates"), incomplete])
      save("#{root}/fault-input.json", { "ledger" => fault, "failure" => failure }, exclusive: true)
      interrupted = capture(config, [config.fetch("ruby"), SCRIPT, "fault-correction", "#{root}/config.json"], cwd: root)
      raise "correction interruption not reached" unless interrupted.fetch("exit") == 78
      pending = read("#{root}/ledger.json")
      raise "dispatch interruption erased reservation" unless pending.fetch("pending") && pending.values_at("turns", "corrections") == [3, 2]
      save("#{root}/restart.json", pending)
      refused = capture(config, [config.fetch("ruby"), SCRIPT, "resume-check", "#{root}/config.json", "#{root}/restart.json"], cwd: root)
      raise "interrupted dispatch restarted a writer" if refused.fetch("exit").zero?
      # The real capture receipt proves the owned worker was reaped. Adopt only
      # that completed result, never dispatch another turn to resolve uncertainty.
      response = read("#{root}/interrupted-correction.json")
      raise "correction quiescence unverified" unless response.fetch("exit").zero? && response.fetch("reaped_by").is_a?(Integer) &&
        response.fetch("pid").is_a?(Integer) && response.fetch("signal").nil?
      fault = pending.merge("pending" => false)
      save("#{root}/ledger.json", fault)
      unchanged = preserve(config, fault)
      raise "no-progress control changed bytes" unless unchanged.fetch("sha256") == incomplete.fetch("sha256")
      repeated = verify_candidate(config, fault)
      raise "repeated failure unexpectedly passed" if repeated.fetch("exit").zero?
      fault.merge!("hold" => "no_progress", "phase" => "blocked")
      save("#{root}/no-progress-ledger.json", fault, exclusive: true)
      ledger.merge!("turns" => fault.fetch("turns"), "corrections" => fault.fetch("corrections"), "hold" => "no_progress")
      save("#{root}/ledger.json", ledger)
      restarted = capture(config, [config.fetch("ruby"), SCRIPT, "resume-check", "#{root}/config.json", "#{root}/no-progress-ledger.json"], cwd: root)
      raise "no-progress restart cleared hold" if restarted.fetch("exit").zero?
      { "status" => "PASS", "worker" => response, "failure" => failure, "repeated_failure" => repeated,
        "dispatch_interruption" => interrupted, "pending_restart_refusal" => refused,
        "restart" => restarted, "record" => unchanged, "turns" => fault.fetch("turns"), "corrections" => fault.fetch("corrections") }
    ensure
      quiescent_jobs!(root)
      File.binwrite("#{workspace}/answer.rb", answer)
      File.binwrite(pointer_path, pointer)
      File.binwrite(state_path, state)
    end
  end

  # Executes restart/safety controls without extra worker turns. Mutations are
  # host-owned synthetic faults, restored exactly; immutable original evidence
  # stays untouched. Full ACT negative checks use its real public entry.
  def self.controls(config, ledger)
    root = config.fetch("root")
    workspace = ledger.fetch("workspace")
    outcomes = {}
    DECISIONS.each { |hold| outcomes[hold] = refuses { reserve(ledger.merge("hold" => hold)) } }
    outcomes["unknown_liveness"] = refuses { reserve(ledger.merge("pending" => true)) }
    outcomes["turn_limit"] = refuses { reserve(ledger.merge("turns" => 3)) }
    outcomes["correction_limit"] = refuses { reserve(ledger.merge("corrections" => 2)) }
    outcomes["deadline"] = refuses { reserve(ledger, now: ledger.fetch("deadline")) }
    outcomes["wrong_session"] = refuses { bind!(config, ledger.merge("session" => "foreign")) }
    outcomes["wrong_workspace"] = refuses { bind!(config, ledger.merge("workspace" => root)) }
    outcomes["stale_source"] = refuses { bind!(config.merge("source" => {}), ledger) }
    # Removing the actual failed-gate handoff breaks the same resume interface.
    prompt = { "workspace" => workspace, "session" => ledger.fetch("session"),
      "objective" => "Return 42; preserve the test and scope" }
    outcomes["removed_handoff"] = refuses { Act24Worker.change(["exec", "resume", "--json", ledger.fetch("session"), "-"], prompt, workspace) }
    %w[answer.rb answer_test.rb].each do |path|
      original = File.binread("#{workspace}/#{path}")
      begin
        File.binwrite("#{workspace}/#{path}", path == "answer.rb" ? Act24Worker::INITIAL : "exit 0\n")
        refused = verify_candidate(config, ledger)
        raise "stale/edited test accepted" if refused.fetch("exit").zero?
        outcomes["changed_#{path}"] = refused
        # Exercise the verifier itself even when ACT's pre-check prevents tests.
        raise "independent verifier accepted forged test" if gate(config).zero?
      ensure
        File.binwrite("#{workspace}/#{path}", original)
      end
    end
    # Fresh-process restarts must retain counters and holds and may not clear an
    # uncertain dispatch. These use the same ledger loader as controller resume.
    DECISIONS.each do |hold|
      save("#{root}/restart.json", ledger.merge("hold" => hold))
      result = capture(config, [config.fetch("ruby"), SCRIPT, "resume-check", "#{root}/config.json", "#{root}/restart.json"], cwd: root)
      raise "restart cleared hold" if result.fetch("exit").zero?
      outcomes["restart_#{hold}"] = result
    end
    save("#{root}/restart.json", ledger.merge("pending" => true))
    result = capture(config, [config.fetch("ruby"), SCRIPT, "resume-check", "#{root}/config.json", "#{root}/restart.json"], cwd: root)
    raise "restart redispatched unknown writer" if result.fetch("exit").zero?
    outcomes["restart_pending_dispatch"] = result
    duplicate = capture(config, [config.fetch("ruby"), SCRIPT, "controller", "#{root}/config.json"], cwd: root)
    raise "duplicate writer accepted" if duplicate.fetch("exit").zero?
    outcomes["duplicate_controller"] = duplicate
    # Preserve originals while testing missing/tampered evidence through a
    # temporary mutable pointer to new, deliberately invalid fixture records.
    candidate = ledger.fetch("candidates").last
    directory = File.dirname(candidate.fetch("path"))
    pointer_path = "#{directory}/current.json"
    pointer = File.binread(pointer_path)
    begin
      save(pointer_path, { "record_file" => "#{SecureRandom.uuid}.json", "sha256" => "0" * 64 })
      missing = act(config, "checkpoint", "verify", "T", "--workspace", workspace)
      raise "missing evidence accepted" if missing.fetch("exit").zero?
      outcomes["missing_evidence"] = missing
      token = SecureRandom.uuid
      File.binwrite("#{directory}/#{token}.patch", "corrupt copy; originals untouched\n")
      record = candidate.reject { |key, _value| %w[path base_sha record_file session workspace].include?(key) }.merge("artifact" => "#{token}.patch")
      save("#{directory}/#{token}.json", record, exclusive: true)
      save(pointer_path, { "record_file" => "#{token}.json", "sha256" => Digest::SHA256.file("#{directory}/#{token}.json").hexdigest })
      tampered = act(config, "checkpoint", "verify", "T", "--workspace", workspace)
      raise "tampered evidence accepted" if tampered.fetch("exit").zero?
      outcomes["tampered_evidence"] = tampered
    ensure
      File.binwrite(pointer_path, pointer)
    end
    before = File.binread("#{workspace}/answer.rb")
    begin
      edited = act(config, "checkpoint", "gate", "T", "--workspace", workspace, "--",
        config.fetch("ruby"), SCRIPT, "edit-during-gate", "#{root}/config.json")
      raise "edit during verification accepted" if edited.fetch("exit").zero?
      outcomes["edit_during_verification"] = edited
    ensure
      File.binwrite("#{workspace}/answer.rb", before)
    end
    outcomes["no_progress"] = no_progress_control(config, ledger)
    save("#{root}/controls.json", outcomes, exclusive: true)
    outcomes
  end

  # Runs one continuous public-entry journey in fresh controller processes.
  # A preservation interruption resumes from real ACT evidence, never another
  # worker. Final acceptance always repeats the original fixed gate.
  def self.controller(config)
    root = config.fetch("root")
    File.open("#{root}/controller.lock", File::RDWR | File::CREAT, 0o600) do |lock|
      raise "duplicate controller" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      ledger_path = "#{root}/ledger.json"
      ledger = File.file?(ledger_path) ? read(ledger_path) : setup(config)
      raise "decision required: #{ledger['hold']}" if ledger["hold"]
      raise "unknown child liveness/dispatch" if ledger["pending"]
      if ledger.fetch("phase") == "initial"
        save(ledger_path, ledger)
        initial_worker = worker(config, ledger)
        save("#{root}/initial-worker.json", initial_worker, exclusive: true)
        ledger["phase"] = "preserving_initial"
        save(ledger_path, ledger)
        candidate = preserve(config, ledger)
        save("#{root}/initial-preservation.json", candidate, exclusive: true)
        # Deliberate controller exit AFTER real preservation, BEFORE adoption.
        # Supervisor observes its quiescence and starts one fresh controller.
        return 75
      end
      raise "unexpected phase" unless ledger.fetch("phase") == "preserving_initial"
      bind!(config, ledger)
      verified = act(config, "checkpoint", "verify", "T", "--workspace", ledger.fetch("workspace"))
      raise "restart preservation verification failed" unless verified.fetch("exit").zero?
      original = read("#{root}/initial-preservation.json")
      raise "restart adopted different candidate" unless JSON.parse([verified.fetch("stdout_hex")].pack("H*")).fetch("record").fetch("sha256") == original.fetch("sha256")
      ledger.fetch("candidates") << original
      save(ledger_path, ledger)
      failure = verify_candidate(config, ledger)
      raise "initial incomplete candidate unexpectedly passed" if failure.fetch("exit").zero?
      save("#{root}/initial-failure.json", failure, exclusive: true)
      correction = worker(config, ledger, failure: failure)
      save("#{root}/correction.json", correction, exclusive: true)
      successor = preserve(config, ledger)
      raise "no progress/changed predecessor" unless successor.fetch("sha256") != original.fetch("sha256") &&
        successor.fetch("previous_record") == original.fetch("record_file")
      ledger.fetch("candidates") << successor
      save(ledger_path, ledger)
      passed = verify_candidate(config, ledger)
      raise "corrected gate failed" unless passed.fetch("exit").zero?
      save("#{root}/corrected-pass.json", passed, exclusive: true)
      positive_turns, positive_corrections = ledger.values_at("turns", "corrections")
      replays = replay(config, ledger)
      save("#{root}/replays.json", replays, exclusive: true)
      controls(config, ledger)
      final = verify_candidate(config, ledger)
      raise "final re-verification failed" unless final.fetch("exit").zero?
      bind!(config, ledger)
      ledger.merge!("phase" => "review", "pending" => false)
      save(ledger_path, ledger)
      save("#{root}/journey.json", { "status" => "PASS", "acceptance" => "pending David review",
        "transitions" => ["initial worker -> ACT preservation/FAIL", "actual FAIL -> explicit-session correction", "successor preservation -> host PASS"],
        "intermediate_operator_relays" => 0, "manual_correction_launches" => 0, "turns" => ledger.fetch("turns"),
        "corrections" => ledger.fetch("corrections"), "positive_turns" => positive_turns, "successful_corrections" => positive_corrections,
        "stop" => ledger.fetch("hold"), "candidates" => ledger.fetch("candidates"), "replays" => replays,
        "verification_invocations" => Dir.glob("#{root}/captures/*.json").count { |path| read(path).fetch("argv").include?("gate") },
        "transition_seconds" => [
          Time.iso8601(failure.fetch("finished_at")) - Time.iso8601(read("#{root}/initial-worker.json").fetch("finished_at")),
          Time.iso8601(correction.fetch("finished_at")) - Time.iso8601(failure.fetch("finished_at")),
          Time.iso8601(passed.fetch("finished_at")) - Time.iso8601(correction.fetch("finished_at"))],
        "native_inference" => "NOT RUN", "additional_paid_spend" => 0 }, exclusive: true)
      0
    end
  end

  # Qualifies real confinement and byte observers before fixture setup/dispatch.
  # Kernel-denied operations, not fabricated success markers, determine passage.
  # Any unsupported policy/runtime or escaped access refuses the entire run.
  def self.qualify(config)
    root = config.fetch("root")
    probe = <<~'RUBY'
      require "socket"
      require "fiddle"
      role = ARGV.shift
      denied = []
      ARGV.each do |path|
        begin; File.binread(path); abort "secret/controller readable: #{path}"; rescue Errno::EPERM, Errno::EACCES; denied << path; end
        begin; File.binwrite(path, "tampered"); abort "protected write allowed: #{path}"; rescue Errno::EPERM, Errno::EACCES; end
      end
      begin; Process.kill("CONT", Integer(ENV.fetch("SENTINEL_PID"))); abort "foreign signal allowed"; rescue Errno::EPERM; end
      library = Fiddle.dlopen("/usr/lib/libproc.dylib")
      info = Fiddle::Function.new(library["proc_pidinfo"], [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
      buffer = Fiddle::Pointer.malloc(136, Fiddle::RUBY_FREE)
      abort "foreign process information readable" unless info.call(Integer(ENV.fetch("SENTINEL_PID")), 3, 0, buffer, 136).zero?
      begin; Process.fork { exit! 0 }; abort "fork allowed"; rescue Errno::EPERM; end
      begin; TCPSocket.new("127.0.0.1", Integer(ENV.fetch("SENTINEL_PORT"))); abort "network allowed"; rescue Errno::EPERM, Errno::EACCES; end
      abort "inherited secret" if ENV.key?("ACT24_HOST_SECRET")
      File.binwrite("probe.bin", "\x00\xffallowed")
      abort "filesystem bytes changed" unless File.binread("probe.bin") == "\x00\xffallowed".b
      File.unlink("probe.bin")
      candidate = "../case/workspace/probe.bin"
      if role == "worker"
        File.binwrite(candidate, "allowed")
        File.unlink(candidate)
      else
        begin; File.binwrite(candidate, "forbidden"); abort "test wrote candidate"; rescue Errno::EPERM, Errno::EACCES; end
      end
      STDOUT.binmode.write("text\n\x00\xff".b)
      STDERR.binmode.write("failure\x00\xfe".b)
      exit 19
    RUBY
    File.binwrite("#{root}/probe.rb", probe)
    File.binwrite("#{root}/controller-probe.rb", <<~'RUBY')
      require "socket"
      begin; File.binread("supervisor-secret"); abort "controller read supervisor secret"; rescue Errno::EPERM, Errno::EACCES; end
      %w[lease.json dispatch-budget.json controller.sb worker.sb test.sb].each do |path|
        begin; File.open(path, "a") { |file| file.write("tamper") }; abort "controller changed supervisor authority"; rescue Errno::EPERM, Errno::EACCES; end
      end
      begin; Process.kill("CONT", Integer(ENV.fetch("SENTINEL_PID"))); abort "controller signaled sentinel"; rescue Errno::EPERM; end
      begin; TCPSocket.new("127.0.0.1", Integer(ENV.fetch("SENTINEL_PORT"))); abort "controller network allowed"; rescue Errno::EPERM, Errno::EACCES; end
      STDOUT.binmode.write("controller\x00\xff".b)
      exit 19
    RUBY
    controller = capture(config, [config.fetch("ruby"), "#{root}/controller-probe.rb"], cwd: root)
    raise "controller boundary unqualified" unless controller.fetch("exit") == 19 &&
      [controller.fetch("stdout_hex")].pack("H*") == "controller\x00\xff".b
    protected_paths = ["#{root}/secret", "#{root}/config.json", "#{root}/lease.json", SCRIPT,
                       "#{root}/case/workspace/.git/config"]
    FileUtils.mkdir_p("#{root}/case/workspace/.git")
    File.binwrite("#{root}/case/workspace/.git/config", "synthetic protected Git admin\n")
    # The supervisor owns the live listener/sentinel outside controller scope.
    snapshots = protected_paths.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
    %w[worker test].each do |role|
      result = capture(config, [config.fetch("ruby"), "#{root}/probe.rb", role, *protected_paths], cwd: "#{root}/scratch", confined: role)
      raise "boundary/observer qualification failed: #{role}" unless result.fetch("exit") == 19 &&
        [result.fetch("stdout_hex")].pack("H*") == "text\n\x00\xff".b &&
        [result.fetch("stderr_hex")].pack("H*") == "failure\x00\xfe".b
      raise "protected bytes changed" unless snapshots.all? { |path, hash| Digest::SHA256.file(path).hexdigest == hash }
    end
    FileUtils.remove_entry("#{root}/case/workspace")
    save("#{root}/qualification.json", { "status" => "PASS", "protected_sha256" => snapshots,
      "network" => "live loopback listener denied", "process" => "fork and foreign signal denied",
      "filesystem" => "worker/test narrow writes and secret/controller/Git-admin denials",
      "observer" => "exact text/binary stdout/stderr and exit 19", "native_codex" => "help/version only" }, exclusive: true)
    0
  end

  # Terminates only registered direct children/qualified descendants and polls
  # reaping/liveness until one monotonic deadline. Direct entries retain actual
  # Process::Status objects; unknown births never authorize group signals.
  # Returns cleanup evidence, including unresolved ownership, without replacing
  # the original supervisor failure. Inspection/signal/wait errors are retained.
  def self.cleanup_children(owned, direct, uncertain, deadline:)
    errors = []
    discovery_failed = false
    begin
      FeedbackRuntime.discover(owned)
    rescue StandardError => error
      errors << "discovery: #{error.class}: #{error.message}"
      discovery_failed = true
    end
    signaled = []
    live = {}
    loop do
      direct.each do |child, row|
        next if row["status"] || row["wait_error"]
        begin
          waited = Process.waitpid2(child, Process::WNOHANG)
          row["status"] = waited.last if waited
        rescue StandardError => error
          row["wait_error"] = "#{error.class}: #{error.message}"
          uncertain[child] ||= "direct-child wait ownership unavailable"
          errors << "wait #{child}: #{row.fetch('wait_error')}"
        end
      end
      live = {}
      owned.each do |child, identity|
        begin
          current = FeedbackRuntime.identity(child)
          live[child] = current if current && current.fetch("birth") == identity.fetch("birth")
        rescue StandardError => error
          live[child] = { "inspection_error" => "#{error.class}: #{error.message}" }
          errors << "identity #{child}: #{error.class}: #{error.message}"
        end
      end
      targets = direct.filter_map do |child, row|
        # An unreaped, still-waitable child cannot have its PID reused. This
        # alone justifies its positive PID, even when birth inspection failed.
        child unless row["status"] || row["wait_error"]
      end
      targets += live.filter_map { |child, identity| child unless identity["inspection_error"] }
      direct.each do |child, row|
        next unless owned.key?(child)
        unreaped = !row["status"] && !row["wait_error"]
        member = live.values.any? { |identity| identity["group"] == child }
        targets << -child if unreaped || member
      end
      (targets.uniq - signaled).each do |target|
        begin
          if target.positive?
            row = direct[target]
            unreaped = row && !row["status"] && !row["wait_error"]
            next unless unreaped || FeedbackRuntime.identity(target)&.fetch("birth") == owned.fetch(target).fetch("birth")
          else
            anchor = -target
            row = direct.fetch(anchor)
            unreaped = !row["status"] && !row["wait_error"]
            member = owned.any? do |child, identity|
              current = FeedbackRuntime.identity(child)
              current && current.fetch("birth") == identity.fetch("birth") && current.fetch("group") == anchor
            end
            next unless unreaped || member
          end
          Process.kill("KILL", target)
          signaled << target
        rescue Errno::ESRCH
          signaled << target
        rescue StandardError => error
          errors << "signal #{target}: #{error.class}: #{error.message}"
        end
      end
      break if direct.values.all? { |row| row["status"] } && live.empty?
      break if FeedbackRuntime.clock >= deadline
      sleep [0.005, [deadline - FeedbackRuntime.clock, 0].max].min
    end
    quiescent = direct.values.all? { |row| row["status"] } && live.empty? && uncertain.empty? && !discovery_failed
    { "quiescent" => quiescent, "deadline" => deadline, "deadline_expired" => FeedbackRuntime.clock >= deadline,
      "uncertain_identity" => uncertain, "unreaped" => direct.filter_map { |child, row| child unless row["status"] },
      "unresolved_processes" => live, "discovery_failed" => discovery_failed, "errors" => errors }
  end

  # Independently supervises one controller group and directly owned job
  # children by kernel birth identity, even after controller death/group escape.
  # Returns exit and all observed ownership. Absolute lease is never extended.
  # Unknown identity or cleanup leaves the fixture blocked, never redispatched.
  def self.supervise(config, mode, seconds: MAX_SECONDS)
    root = config.fetch("root")
    run_token = SecureRandom.uuid
    owned = {}
    direct = {}
    uncertain = {}
    jobs = {}
    argv = ["/usr/bin/sandbox-exec", "-f", "#{root}/controller.sb", config.fetch("ruby"), SCRIPT, mode, "#{root}/config.json"]
    pid = nil
    canceled = nil
    previous = {}
    status = nil
    failure = nil
    primary_error = nil
    local_deadline = [config.fetch("monotonic_deadline"), FeedbackRuntime.clock + seconds].min
    begin
      quiescent_jobs!(root)
      %w[INT TERM HUP].each { |signal| previous[signal] = Signal.trap(signal) { canceled = signal } }
      pid = Process.spawn(environment(config), *argv, pgroup: true, unsetenv_others: true,
        out: "#{root}/#{run_token}.stdout", err: "#{root}/#{run_token}.stderr")
      direct[pid] = { "status" => nil }
      uncertain[pid] = "controller birth not established"
      identity = FeedbackRuntime.identity(pid)
      raise "controller birth unknown" unless identity && identity.fetch("parent") == Process.pid && identity.fetch("group") == pid
      owned[pid] = identity
      uncertain.delete(pid)
      loop do
        FeedbackRuntime.discover(owned)
        Dir.glob("#{root}/jobs/*.json").sort.each do |path|
          next if jobs.key?(path) || File.exist?("#{path}.done")
          request = read(path)
          raise "dispatch after deadline" if Time.now.to_f >= config.fetch("deadline") || FeedbackRuntime.clock >= local_deadline
          argv, cwd = job!(config, request, owned)
          if request.fetch("role") == "worker" && argv[1] == WORKER
            budget = reserve(read("#{root}/dispatch-budget.json"))
            ledger = read("#{root}/ledger.json")
            raise "budget/turn binding mismatch" unless ledger["pending"] && ledger.values_at("turns", "corrections") == budget.values_at("turns", "corrections")
            raise "parallel fixture workers refused" if jobs.any? { |existing, _child| read(existing).fetch("role") == "worker" && !File.exist?("#{existing}.done") }
            save("#{root}/dispatch-budget.json", budget.merge("pending" => false))
          end
          token = File.basename(path, ".json")
          raise "unsafe job token" unless token.match?(/\A[0-9a-f-]{36}\z/)
          prefix = "#{root}/captures/#{token}"
          stdin = File.open("#{prefix}.stdin", File::RDONLY | File::NOFOLLOW)
          stdout = File.open("#{prefix}.stdout", "wx", 0o600)
          stderr = File.open("#{prefix}.stderr", "wx", 0o600)
          begin
            child = Process.spawn(environment(config), "/usr/bin/sandbox-exec", "-f", "#{root}/#{request.fetch('role')}.sb", *argv,
              chdir: cwd, in: stdin, out: stdout, err: stderr, pgroup: true, unsetenv_others: true)
            direct[child] = { "status" => nil }
            jobs[path] = child
            uncertain[child] = "job birth not established"
          ensure
            [stdin, stdout, stderr].each(&:close)
          end
          birth = FeedbackRuntime.identity(child)
          raise "confined child identity unavailable" unless birth && birth.fetch("parent") == Process.pid && birth.fetch("group") == child
          owned[child] = birth
          uncertain.delete(child)
          save("#{path}.started", birth, exclusive: true)
          Process.kill("TERM", Process.pid) if mode == "rehearse-cancel" && request.fetch("role") == "test"
        end
        jobs.each do |path, child|
          next if File.exist?("#{path}.done")
          exited = Process.waitpid2(child, Process::WNOHANG)
          next unless exited
          outcome = exited.last
          direct.fetch(child)["status"] = outcome
          save("#{path}.done", { "exit" => outcome.exitstatus || 128 + outcome.termsig, "signal" => outcome.termsig,
            "reaped_by" => Process.pid, "pid" => child }, exclusive: true)
        end
        waited = Process.waitpid2(pid, Process::WNOHANG)
        if waited
          status = waited.last
          direct.fetch(pid)["status"] = status
          break
        end
        raise "supervised absolute deadline" if Time.now.to_f >= config.fetch("deadline") || FeedbackRuntime.clock >= local_deadline
        raise "operator cancellation #{canceled}" if canceled
        sleep 0.005
      end
    rescue Exception => error # Preserve setup, inspection and interrupt failures through cleanup.
      failure = error.message
      primary_error = error
    ensure
      begin
        cleanup = cleanup_children(owned, direct, uncertain,
          deadline: [config.fetch("monotonic_deadline") + 2, FeedbackRuntime.clock + 2].min)
        status = direct.dig(pid, "status")
        jobs.each do |path, child|
          outcome = direct.fetch(child)["status"]
          next if !outcome || File.exist?("#{path}.done")
          save("#{path}.done", { "exit" => outcome.exitstatus || 128 + outcome.termsig, "signal" => outcome.termsig,
            "reaped_by" => Process.pid, "pid" => child, "supervisor_stop" => failure || "controller exited" }, exclusive: true)
        end
        save("#{root}/#{run_token}.supervision.json", { "mode" => mode, "argv" => argv, "cwd" => Dir.pwd,
          "environment" => environment(config), "status" => status&.exitstatus, "signal" => status&.termsig,
          "stdout" => "#{root}/#{run_token}.stdout", "stderr" => "#{root}/#{run_token}.stderr",
          "stdout_sha256" => File.file?("#{root}/#{run_token}.stdout") ? Digest::SHA256.file("#{root}/#{run_token}.stdout").hexdigest : nil,
          "stderr_sha256" => File.file?("#{root}/#{run_token}.stderr") ? Digest::SHA256.file("#{root}/#{run_token}.stderr").hexdigest : nil,
          "failure" => failure, "exception_class" => primary_error&.class&.name, "owned" => owned.values,
          "direct_children" => direct.map { |child, row| { "pid" => child, "status" => row["status"]&.exitstatus,
            "signal" => row["status"]&.termsig, "wait_error" => row["wait_error"] } },
          "cleanup" => cleanup, "quiescent" => cleanup.fetch("quiescent"), "finished_at" => Time.now.utc.iso8601(6) }, exclusive: true)
      ensure
        previous.each { |signal, handler| Signal.trap(signal, handler) }
      end
    end
    raise "unknown child ownership/liveness after cleanup", cause: primary_error unless cleanup.fetch("quiescent")
    raise primary_error if primary_error && !primary_error.is_a?(StandardError)
    { "exit" => status && (status.exitstatus || 128 + status.termsig), "signal" => status&.termsig,
      "owned" => owned.values, "failure" => failure, "quiescent" => true }
  end

  # Validates source/executable pins and an absent declared synthetic root,
  # installs a fixed absolute independent lease, and runs qualification before
  # any fixture worker/test. Keeps all partial outputs on failure; never adopts
  # an occupied root, changes host policy or invokes native Codex inference.
  def self.run(options)
    raise "macOS host required" unless RUBY_PLATFORM.include?("darwin")
    root = File.expand_path(options.fetch(:root))
    parent = File.dirname(root)
    raise "fresh declared fixture root required" unless File.realpath(parent) == parent &&
      File.basename(parent) == "agent-coding-tool-data-fixtures" && File.basename(root).match?(/\AACT-24-host-[A-Za-z0-9-]+\z/) &&
      !File.exist?(root) && !File.symlink?(root)
    source = source_identity
    raise "source bytes do not match reviewed pin" unless source.fetch("sha256") == options.fetch(:source_sha256)
    codex = File.realpath(options.fetch(:codex))
    raise "Codex executable changed" unless Digest::SHA256.file(codex).hexdigest == options.fetch(:codex_sha256)
    Dir.mkdir(root, 0o700)
    %w[home tmp scratch captures jobs case].each { |name| Dir.mkdir("#{root}/#{name}", 0o700) }
    git, error, status = Open3.capture3("/usr/bin/xcrun", "--find", "git")
    raise "native Git unavailable: #{error}" unless status.success?
    head, error, status = Open3.capture3(git.strip, "-C", SOURCE, "rev-parse", "HEAD")
    raise "STALE INPUT: ACT execution HEAD differs: #{error}" unless status.success? && head.strip == PREPARED_ACT
    now = Time.now.to_f
    config = { "root" => root, "source" => source, "codex" => codex, "git" => File.realpath(git.strip),
      "ruby" => File.realpath(RbConfig.ruby), "ruby_prefix" => File.realpath(RbConfig::CONFIG.fetch("prefix")),
      "started_at" => now, "deadline" => now + MAX_SECONDS, "monotonic_deadline" => FeedbackRuntime.clock + MAX_SECONDS,
      "runtime" => RUBY_DESCRIPTION }
    skills = File.realpath(File.join(SOURCE, "../agent-skills"))
    admin, error, status = Open3.capture3(config.fetch("git"), "-C", skills, "rev-parse", "--path-format=absolute", "--git-common-dir")
    raise "read-only canonical skill input unavailable: #{error}" unless status.success?
    config.merge!("skills" => skills, "skills_admin" => File.realpath(admin.strip))
    require "socket"
    listener = TCPServer.new("127.0.0.1", 0)
    sentinel = Process.spawn({ "PATH" => "/usr/bin:/bin" }, config.fetch("ruby"), "-e", "sleep 120", pgroup: true, unsetenv_others: true)
    sentinel_identity = FeedbackRuntime.identity(sentinel)
    raise "sentinel identity unavailable" unless sentinel_identity
    config.merge!("sentinel_pid" => sentinel, "sentinel_identity" => sentinel_identity, "sentinel_port" => listener.addr[1])
    save("#{root}/lease.json", config.slice("started_at", "deadline", "monotonic_deadline").merge("max_turns" => 3, "max_corrections" => 2), exclusive: true)
    save("#{root}/config.json", config, exclusive: true)
    save("#{root}/dispatch-budget.json", { "turns" => 0, "corrections" => 0, "pending" => false,
      "deadline" => config.fetch("deadline"), "hold" => nil }, exclusive: true)
    File.binwrite("#{root}/secret", SecureRandom.hex(32))
    File.binwrite("#{root}/supervisor-secret", SecureRandom.hex(32))
    %w[controller worker test].each { |role| File.binwrite("#{root}/#{role}.sb", policy(config, role)) }
    # Read-only help qualification is performed inside the confined controller.
    qualified = supervise(config, "qualify-host")
    raise "host boundary qualification failed; no dispatch" unless qualified.fetch("exit").zero? && !qualified.fetch("failure")
    raise "unrelated sentinel harmed" unless FeedbackRuntime.identity(sentinel)&.fetch("birth") == sentinel_identity.fetch("birth")
    death = supervise(config, "rehearse-controller-death")
    raise "controller-death cleanup unqualified" unless death.fetch("exit") == 76 && !death.fetch("failure")
    deadline = supervise(config, "rehearse-deadline", seconds: 1)
    raise "independent deadline unqualified" unless deadline.fetch("failure") == "supervised absolute deadline" && deadline.fetch("owned").length >= 2
    raise "unrelated sentinel harmed" unless FeedbackRuntime.identity(sentinel)&.fetch("birth") == sentinel_identity.fetch("birth")
    cancellation = supervise(config, "rehearse-cancel")
    raise "cancellation unqualified" unless cancellation.fetch("failure") == "operator cancellation TERM"
    raise "unrelated sentinel harmed" unless FeedbackRuntime.identity(sentinel)&.fetch("birth") == sentinel_identity.fetch("birth")
    save("#{root}/supervision-qualification.json", { "controller_death" => death, "deadline" => deadline, "cancel" => cancellation,
      "sentinel_survived" => true, "cumulative_deadline" => config.fetch("deadline") }, exclusive: true)
    first = supervise(config, "controller")
    raise "preservation restart not reached" unless first.fetch("exit") == 75 && !first.fetch("failure")
    final = supervise(config, "controller")
    raise "continuity failed" unless final.fetch("exit").zero? && !final.fetch("failure")
    raise "source changed during fixture" unless source_identity == source
    puts JSON.pretty_generate(read("#{root}/journey.json").merge("root" => root, "seconds" => Time.now.to_f - now))
    0
  rescue Exception => error
    if root && File.directory?(root) && config
      save("#{root}/blocked.json", { "status" => "BLOCKED", "error" => error.class.name, "reason" => error.message,
        "elapsed" => Time.now.to_f - config.fetch("started_at"), "journey" => "not accepted; inspect partial evidence" }, exclusive: true)
    end
    warn "BLOCKED: #{error.class}: #{error.message}"
    1
  ensure
    if sentinel && FeedbackRuntime.identity(sentinel)&.fetch("birth") == sentinel_identity&.fetch("birth")
      Process.kill("KILL", sentinel)
      Process.waitpid(sentinel)
    end
    listener&.close
  end

  # Dispatches public pin/run or fixed internal modes. Returns exit status;
  # invalid/missing arguments fail without worker dispatch or state repair.
  def self.main(argv)
    mode = argv.shift
    case mode
    when "pin"
      puts JSON.pretty_generate(source_identity)
      0
    when "run"
      options = {}
      OptionParser.new do |parser|
        %w[root source-sha256 codex codex-sha256].each { |name| parser.on("--#{name} VALUE") { |value| options[name.tr('-', '_').to_sym] = value } }
      end.parse!(argv)
      raise "unexpected arguments" unless argv.empty?
      run(options)
    else
      config = read(argv.shift)
      raise "stale source" unless source_identity == config.fetch("source")
      case mode
      when "qualify-host"
        version = command!(config, [config.fetch("codex"), "--version"]).strip
        resume_help = command!(config, [config.fetch("codex"), "exec", "resume", "--help"])
        app_help = command!(config, [config.fetch("codex"), "app-server", "--help"])
        raise "unsupported Codex contract" unless version == "codex-cli 0.162.1" &&
          resume_help.include?("[SESSION_ID] [PROMPT]") && resume_help.include?("--json") && resume_help.include?("read from stdin") &&
          app_help.include?("generate-json-schema")
        save("#{config.fetch('root')}/protocol.json", { "version" => version, "selected" => "exec resume explicit session; stdin prompt; JSONL",
          "reference" => "installed executable --help; ACT prepared Launcher thread.started parser", "native_resume" => "NOT RUN",
          "tradeoff" => "CLI avoids persistent server/Goal state and experimental schema; cumulative accounting stays outside worker" }, exclusive: true)
        qualify(config)
      when "controller" then controller(config)
      when "rehearse-controller-death", "rehearse-deadline", "rehearse-cancel"
        # This trusted rehearsal starts no worker/candidate test. Its registered
        # sleeper is a finite process-boundary probe; the supervisor kills it.
        if mode == "rehearse-controller-death"
          Thread.new do
            sleep 0.005 until Dir.glob("#{config.fetch('root')}/jobs/*.json").any? { |path|
              request = read(path)
              request.dig("owner", "pid") == Process.pid && File.file?("#{path}.started") }
            exit! 76
          end
        end
        capture(config, [config.fetch("ruby"), "-e", "sleep 120"], cwd: config.fetch("root"), confined: "test")
        raise "supervision rehearsal unexpectedly returned"
      when "gate" then gate(config)
      when "edit-during-gate"
        result = gate(config)
        raise "fault requires accepted command result" unless result.zero?
        File.binwrite("#{config.fetch('root')}/case/workspace/answer.rb", Act24Worker::INITIAL)
        0
      when "resume-check"
        ledger = read(argv.shift)
        bind!(config, ledger)
        reserve(ledger)
        0
      when "fault-correction"
        fault = read("#{config.fetch('root')}/fault-input.json")
        worker(config, fault.fetch("ledger"), failure: fault.fetch("failure"), no_progress: true, interrupt_after_dispatch: true)
        raise "correction interruption unexpectedly returned"
      else raise "unsupported mode"
      end
    end
  rescue StandardError => error
    warn "BLOCKED: #{error.class}: #{error.message}"
    1
  end
end

exit Act24Continuity.main(ARGV) if $PROGRAM_NAME == __FILE__
