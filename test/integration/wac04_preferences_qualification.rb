# frozen_string_literal: true

require "timeout"
require "fileutils"
require_relative "../../lib/agent_coding_tool/native_pilot_executor"
require_relative "../../lib/agent_coding_tool/run_evidence_store"
require_relative "wac04_preferences_probe"

# Operator-only, non-inference qualification. Uses the existing production
# supervisor; no CLI execution, authentication, preference setters or live lease.
module Wac04PreferencesQualification
  EXECUTOR = AgentCodingTool::NativePilotExecutor
  SOURCE = File.realpath(File.join(__dir__, "../.."))
  PROBE = File.join(__dir__, "wac04_preferences_probe.rb")
  ROLES = %w[manager worker gate].freeze
  DOMAINS = %w[com.openai.codex.other org.openai.codex com.apple.finder .GlobalPreferences kCFPreferencesAnyApplication /tmp/com.openai.codex].freeze

  # Builds exact permission expectations independently of preference contents.
  # Filter IDs: PATH=1, GLOBAL_NAME=2, LOCAL_NAME=3, PREFERENCE_DOMAIN=6,
  # POSIX_IPC_NAME=17. Unsupported non-exec SPI fails qualification; the exec
  # query is diagnostic only and cannot replace an actual execution attempt.
  def self.specification(role, paths)
    queries, expected = {}, {}
    domain = Wac04PreferencesProbe::DOMAIN
    %w[user-preference-read managed-preference-read user-preference-write].each do |operation|
      ([domain] + DOMAINS).each do |item|
        name = "#{operation}:#{item}"
        queries[name] = [operation, 6, item]
        expected[name] = item == domain && operation != "user-preference-write" && role != "gate" ? 0 : 1
      end
    end
    [["global-daemon", 2, "com.apple.cfprefsd.daemon"], ["global-agent", 2, "com.apple.cfprefsd.agent"],
     ["local-agent", 3, "com.apple.cfprefsd.agent"], ["foreign-dispatch", 2, "com.apple.coreservices.launchservicesd"]].each do |name, filter, service|
      queries[name] = ["mach-lookup", filter, service]
      expected[name] = name != "foreign-dispatch" && role != "gate" ? 0 : 1
    end
    queries["shared-memory"] = ["ipc-posix-shm-read-data", 17, "apple.cfprefs.#{Process.uid}"]
    queries["foreign-exec"] = ["process-exec", 1, "/usr/bin/true"]
    expected.merge!("shared-memory" => 1)
    paths.fetch("denied_reads").each do |name, path|
      queries[name] = ["file-read-data", 1, path]
      expected[name] = 1
    end
    files = { "control_read" => [paths.fetch("control"), "read"], "control_write" => [paths.fetch("control"), "write"],
      "foreign_read" => [paths.fetch("foreign"), "read"], "foreign_write" => [paths.fetch("foreign"), "write"],
      "source_write" => [PROBE, "write"], "git_read" => [paths.fetch("git"), "read"],
      "candidate_write" => [paths.fetch("candidate"), "write"], "home_write" => [paths.fetch("home"), "write"] }
    expected_files = files.transform_values { "denied" }.merge("fork" => "denied", "foreign_signal" => "denied", "home_write" => "allowed")
    expected_files["candidate_write"] = "allowed" if role == "worker"
    { "queries" => queries, "expected" => expected, "files" => files, "expected_files" => expected_files,
      "cwd" => paths.fetch("cwd") }
  end

  # Checks status AND semantics. Missing data is never proof of denial; exact
  # non-exec sandbox decisions must match before and after CF calls. Returns false for
  # malformed/binary output, API errors, zero-exit semantic failures or signals.
  def self.boundaries_qualified?(result, spec, role)
    return false unless result.success?
    facts = AgentCodingTool::RunEvidenceStore.parse(result.stdout)
    return false unless %w[checks after].all? { |phase|
      checks = facts.fetch(phase)
      [-1, 0, 1].include?(checks.fetch("foreign-exec")) &&
        checks.reject { |name, _value| name == "foreign-exec" } == spec.fetch("expected") } &&
      facts.fetch("filesystem") == spec.fetch("expected_files") &&
      facts.fetch("cwd") == { "getcwd" => spec.fetch("cwd"), "realpath" => spec.fetch("cwd"), "directory" => true } &&
      facts.fetch("unrelated").reject { |name, _value| name == ".GlobalPreferences" } ==
        Wac04PreferencesProbe::UNRELATED.reject { |name, _value| name == ".GlobalPreferences" }.transform_values { { "present" => false, "forced" => false } }
    configuration = facts.fetch("configuration")
    return false unless configuration.keys.sort == Wac04PreferencesProbe::KEYS.sort
    return false unless configuration.values.all? do |item|
      [true, false].include?(item.fetch("forced_before")) && [true, false].include?(item.fetch("copied")) &&
        [true, false].include?(item.fetch("access_copy_present")) &&
        (!item.fetch("copied") || (item["forced_before"] && item["forced_after"] == true && item["string"] == true)) &&
        (role != "gate" || (!item["forced_before"] && !item["copied"] && !item["access_copy_present"]))
    end
    role == "gate" || facts.fetch("synchronized") == true
  rescue JSON::ParserError, KeyError, TypeError, NoMethodError, ArgumentError
    false
  end

  # Requires a direct exec errno plus a successful, same-PID allowed exec. The
  # supervisor owns both processes. Missing/invalid executables, fork failures,
  # generic exit statuses, signals and loader output never establish denial.
  def self.exec_denied?(facts, control, ruby)
    attempt = facts.fetch("exec")
    allowed = AgentCodingTool::RunEvidenceStore.parse(control.stdout)
    before = AgentCodingTool::RunEvidenceStore.parse(control.stderr)
    control.success? && attempt.fetch("operation") == "exec" &&
      attempt.fetch("path") == Wac04PreferencesProbe::FOREIGN_EXECUTABLE &&
      [[Errno::EPERM::Errno, "Errno::EPERM"], [Errno::EACCES::Errno, "Errno::EACCES"]].include?([attempt["errno"], attempt["error_class"]]) &&
      attempt.fetch("pid").is_a?(Integer) && attempt.fetch("pid").positive? &&
      before == { "operation" => "exec", "path" => ruby, "pid" => allowed.fetch("pid") } &&
      allowed == { "control" => "wac04-allowed-exec/v1", "pid" => before.fetch("pid") } &&
      before.fetch("pid").is_a?(Integer) && before.fetch("pid").positive?
  rescue JSON::ParserError, KeyError, TypeError, NoMethodError, ArgumentError
    false
  end

  # A returned synthetic protected marker is FAIL even when queries deny access.
  # Missing positive context or an unattributed real AppleLocale is BLOCKED, not
  # a leak claim or a safe default. A fixture-only principal does not identify
  # the source of the original process's value. No real value is retained.
  def self.preference_verdict(facts, positive, negative)
    observed = facts.fetch("unrelated").fetch(".GlobalPreferences")
    return "FAIL" unless [true, false].include?(observed.fetch("present")) && observed.fetch("forced") == false
    return "BLOCKED" unless negative&.success?
    denied = AgentCodingTool::RunEvidenceStore.parse(negative.stdout)
    readings = %w[canary locale].flat_map { |name| denied.fetch(name).values }
    return "FAIL" if readings.any? { |row| row.fetch("matches_fixture") == true }
    return "BLOCKED" unless positive&.success?
    allowed = AgentCodingTool::RunEvidenceStore.parse(positive.stdout)
    return "BLOCKED" unless allowed.fetch("file") == "allowed" && allowed.fetch("fixed_home") == true &&
      denied.fetch("file") == "denied" && denied.fetch("fixed_home") == true
    %w[canary locale].each do |name|
      return "BLOCKED" unless allowed.fetch(name) == %w[app any-app exact].to_h { |operation| [operation, { "present" => true, "matches_fixture" => true }] } &&
        denied.fetch(name) == %w[app any-app exact].to_h { |operation| [operation, { "present" => false, "matches_fixture" => false }] }
    end
    observed.fetch("present") ? "BLOCKED" : "PASS"
  rescue JSON::ParserError, KeyError, TypeError, NoMethodError, ArgumentError
    "BLOCKED"
  end

  # Combines independent controls with every retained successful boundary check.
  # Unknown preference provenance cannot qualify a role or authorize inference.
  def self.verdict(result, spec, role, controls)
    return "FAIL" unless boundaries_qualified?(result, spec, role)
    facts = AgentCodingTool::RunEvidenceStore.parse(result.stdout)
    return "FAIL" unless exec_denied?(facts, controls.fetch("exec-control"), controls.fetch("ruby"))
    preference_verdict(facts, controls["preference-positive"], controls["preference-negative"])
  rescue KeyError, TypeError, NoMethodError, JSON::ParserError
    "FAIL"
  end

  # Boolean compatibility for callers; only a fully demonstrated PASS qualifies.
  def self.qualified?(result, spec, role, controls = {})
    verdict(result, spec, role, controls) == "PASS"
  end

  # Verifies reviewed regular-file pins without running Git or any executable.
  # Rejects symlinks, missing files and drift before probe spawn; IO errors raise.
  def self.verify_pin!(pin)
    required = [__FILE__, PROBE, File.join(SOURCE, "lib/agent_coding_tool/native_pilot_executor.rb"),
      File.join(SOURCE, "lib/agent_coding_tool/run_evidence_store.rb"), pin.fetch("ruby"), pin.fetch("codex"),
      Wac04PreferencesProbe::FOREIGN_EXECUTABLE]
    raise "incomplete qualification pin" unless pin.fetch("schema") == "wac04-preferences-qualification/v2" &&
      (required - pin.fetch("files").keys).empty?
    raise "wrong source root" unless pin.fetch("source_root") == SOURCE
    pin.fetch("files").each do |path, digest|
      raise "changed qualification input: #{path}" unless File.realpath(path) == path &&
        File.file?(path) && Digest::SHA256.file(path).hexdigest == digest
    end
    foreign = File.stat(Wac04PreferencesProbe::FOREIGN_EXECUTABLE)
    raise "invalid harmless executable" unless foreign.uid.zero? && (foreign.mode & 0o022).zero? &&
      (foreign.mode & 0o111) != 0 && %w[cafebabe cafebabf cffaedfe feedfacf].include?(
        File.binread(Wac04PreferencesProbe::FOREIGN_EXECUTABLE, 4).unpack1("H*"))
  end

  # Runs one fixed control with the existing production supervisor and caps.
  # The supplied role lease includes ALL controls and teardown, never resets.
  # Returns the actual byte/status result and records its owned raw directory.
  def self.capture_control(output, name, command, config, cwd, row, consumed)
    directory = File.join(output, name)
    row["raw_directory"] = directory
    Dir.mkdir(directory, 0o700)
    executor = EXECUTOR.create(directory, config.merge("gate_argv" => command),
      seconds: config.fetch("enclosing_lease").fetch("monotonic_deadline") - EXECUTOR.clock)
    # Carry the role's prior byte charge into this NEW, never-used gate ledger.
    # The existing independent drain then enforces the original 4 MiB across
    # all controls together. No old invocation or live ledger is ever changed.
    ledger = JSON.parse(File.binread(File.join(directory, "ledger.json")))
    raise "invalid cumulative output charge" unless consumed.is_a?(Integer) && consumed.between?(0, EXECUTOR::OUTPUT_LIMIT)
    EXECUTOR.save(directory, "ledger.json", ledger.merge("bytes" => consumed))
    row["initial_bytes_charged"] = consumed
    result = executor.capture("gate", command, input: "", cwd: cwd)
    row.merge!("exit_status" => result.exitstatus, "signal" => result.termsig)
    %w[stdout stderr].each do |stream|
      bytes = result.public_send(stream)
      row["#{stream}_sha256"] = Digest::SHA256.hexdigest(bytes)
      row["#{stream}_base64"] = [bytes].pack("m0")
    end
    row["observations"] = AgentCodingTool::RunEvidenceStore.parse(result.stdout) rescue nil
    [result, JSON.parse(File.binread(File.join(directory, "ledger.json"))).fetch("bytes")]
  end

  # Executes three fixed harmless role groups under one original <=110s lease.
  # Each role shares <=20s and 4 MiB across its base probe and three controls,
  # using fresh gate-only ledgers, never manager/worker turns. The existing
  # production supervisor independently kills its owned group on
  # wrapper death, timeout or pin drift; <=1s teardown is inside each limit.
  # All bytes/status/config/profile pins and one consolidated report are saved.
  def self.run(pin_path, output)
    started = EXECUTOR.clock
    lease = { "deadline" => Time.now.to_f + 110, "monotonic_deadline" => started + 110 }
    report = { "status" => "FAIL", "purpose" => "harmless non-inference preference compatibility only",
      "live_continuity" => "NOT RUN", "previous_manager_starts_consumed" => 2, "roles" => {},
      "limit_seconds_including_teardown" => 110, "lease" => lease }
    created = false
    begin
      Timeout.timeout(112) do
        raise "macOS host required" unless RUBY_PLATFORM.include?("darwin")
        pin_path = File.realpath(pin_path)
        pin_bytes = File.binread(pin_path)
        pin = JSON.parse(pin_bytes)
        verify_pin!(pin)
        ruby = File.realpath(RbConfig.ruby)
        raise "wrong Ruby runtime" unless pin.fetch("ruby") == ruby
        output = File.expand_path(output)
        parent = File.dirname(output)
        raise "output must be the pinned harmless fixture" unless output == pin.fetch("output_root") &&
          parent == pin.fetch("output_parent") && File.realpath(parent) == parent
        Dir.mkdir(output, 0o700) # Exclusive; never replace or renew an old run.
        created = true
        report["input"] = pin.reject { |key, _value| key == "files" }.merge("pin_sha256" => Digest::SHA256.hexdigest(pin_bytes))
        EXECUTOR.save(output, "input-pin.json", pin)
        workspace = File.join(output, "worktrees", "T", "probe")
        FileUtils.mkdir_p(File.join(workspace, ".git"), mode: 0o700)
        candidate = File.join(workspace, "candidate")
        git_control = File.join(workspace, ".git", "control")
        control, foreign = %w[control foreign].map { |name| File.join(output, name) }
        [candidate, git_control, control, foreign].each { |path| File.write(path, "fixture-canary", mode: "wx", perm: 0o600) }
        prefix = File.realpath(RbConfig::CONFIG.fetch("prefix"))
        gems = File.join(prefix, "lib/ruby/gems", RbConfig::CONFIG.fetch("ruby_version"))
        ROLES.each do |role|
          verify_pin!(pin)
          role_started = EXECUTOR.clock
          role_lease = { "deadline" => [lease.fetch("deadline"), Time.now.to_f + 20].min,
            "monotonic_deadline" => [lease.fetch("monotonic_deadline"), role_started + 20].min }
          home = File.join(output, "#{role}-home")
          Dir.mkdir(home, 0o700)
          cwd = File.join(home, "T", "work")
          FileUtils.mkdir_p(cwd, mode: 0o700)
          temporary = File.join(home, "tmp")
          Dir.mkdir(temporary, 0o700)
          marker = File.join(home, "marker")
          File.write(marker, "fixture-canary", mode: "wx", perm: 0o600)
          denied_reads = { "control-decision" => control, "ordinary-source" => foreign,
            "unrelated-system-preferences" => "/Library/Preferences/com.apple.loginwindow.plist",
            "unrelated-user-preferences" => pin.fetch("unrelated_preferences"),
            "protected-task" => pin.fetch("task"), "credentials" => pin.fetch("credential_path") }
          spec = specification(role, { "control" => control, "foreign" => foreign, "git" => git_control,
            "candidate" => candidate, "home" => marker, "denied_reads" => denied_reads, "cwd" => cwd })
          principal = File.join(output, "#{role}-preference-principal")
          preferences = File.join(principal, "Library", "Preferences")
          FileUtils.mkdir_p(preferences, mode: 0o700)
          positive_cwd = File.join(principal, "T", "work")
          FileUtils.mkdir_p(positive_cwd, mode: 0o700)
          key, value = "WAC04Protected-#{SecureRandom.uuid}", "wac04-#{SecureRandom.uuid}"
          plist = File.join(preferences, ".GlobalPreferences.plist")
          File.write(plist, "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>#{key}</key><string>#{value}</string><key>AppleLocale</key><string>#{value}</string></dict></plist>", mode: "wx", perm: 0o600)
          fixture_sha = Digest::SHA256.file(plist).hexdigest
          spec["preference_fixture"] = { "principal" => principal, "plist" => plist, "key" => key, "value" => value }
          spec_path = File.join(home, "spec.json")
          EXECUTOR.save(home, "spec.json", spec)
          profile = File.join(output, "#{role}.sb")
          File.write(profile, EXECUTOR.policy(role: role, reads: [prefix, SOURCE], home: home,
            workspace: File.dirname(workspace), executables: [pin.fetch("codex"), ruby]), mode: "wx", perm: 0o600)
          raise "generated profile drift: #{role}" unless Digest::SHA256.file(profile).hexdigest == pin.fetch("profiles").fetch(role)
          positive_profile = File.join(output, "#{role}-preference-positive.sb")
          File.write(positive_profile, EXECUTOR.policy(role: role, reads: [prefix, SOURCE], home: principal,
            workspace: File.dirname(workspace), executables: [pin.fetch("codex"), ruby]), mode: "wx", perm: 0o600)
          raise "control profile drift: #{role}" unless Digest::SHA256.file(positive_profile).hexdigest == pin.fetch("control_profiles").fetch(role)
          positive_spec = EXECUTOR.save(principal, "spec.json", spec)
          pins = pin.fetch("files").merge(pin_path => Digest::SHA256.hexdigest(pin_bytes),
            profile => Digest::SHA256.file(profile).hexdigest, spec_path => Digest::SHA256.file(spec_path).hexdigest,
            positive_profile => Digest::SHA256.file(positive_profile).hexdigest,
            positive_spec => Digest::SHA256.file(positive_spec).hexdigest, plist => fixture_sha)
          command = [ruby, PROBE, spec_path]
          environment = { "PATH" => "/usr/bin:/bin", "HOME" => home, "CODEX_HOME" => home,
            "TMPDIR" => temporary, "GEM_HOME" => gems, "GEM_PATH" => gems, "LANG" => "C", "LC_ALL" => "C" }
          # Gate admission requires a T child. Keep cwd inside the existing home
          # grant, preserving the repaired manager cwd semantics without inference.
          config = { "executable" => ruby, "pins" => pins, "gate_argv" => command,
            "profiles" => { "gate" => profile }, "environments" => { "gate" => environment },
            "worktree_root" => home, "turn_seconds" => 20, "gate_seconds" => 20,
            "enclosing_lease" => role_lease }
          directory = File.join(output, "#{role}-supervision")
          Dir.mkdir(directory, 0o700)
          report.fetch("roles")[role] = { "qualified" => false, "raw_directory" => directory,
            "profile_sha256" => pins.fetch(profile), "expected_permissions" => spec.fetch("expected"),
            "expected_filesystem" => spec.fetch("expected_files"), "expected_cwd" => cwd,
            "synchronize_required" => role != "gate" }
          executor = EXECUTOR.create(directory, config, seconds: role_lease.fetch("monotonic_deadline") - EXECUTOR.clock)
          result = executor.capture("gate", command, input: "", cwd: cwd)
          facts = report.fetch("roles").fetch(role).merge(
            "exit_status" => result.exitstatus, "signal" => result.termsig)
          report.fetch("roles")[role] = facts
          raise "#{role}: base boundary probe failed; controls not retried" unless boundaries_qualified?(result, spec, role)
          facts["controls"] = {}
          consumed = JSON.parse(File.binread(File.join(directory, "ledger.json"))).fetch("bytes")
          controls = { "ruby" => ruby }
          ["exec-control", "preference-positive", "preference-negative"].each do |name|
            row = facts.fetch("controls")[name] = {}
            positive = name == "preference-positive"
            context = name.start_with?("preference-")
            control_environment = context ? environment.merge("CFFIXED_USER_HOME" => principal) : environment
            control_config = config.merge("profiles" => { "gate" => positive ? positive_profile : profile },
              "environments" => { "gate" => control_environment }, "worktree_root" => positive ? principal : home)
            control_command = [ruby, PROBE, positive ? positive_spec : spec_path, context ? "preference-context" : name]
            controls[name], consumed = capture_control(output, "#{role}-#{name}-supervision", control_command,
              control_config, positive ? positive_cwd : cwd, row, consumed)
          end
          facts["verdict"] = verdict(result, spec, role, controls)
          facts["qualified"] = facts["verdict"] == "PASS"
          facts["elapsed_seconds"] = EXECUTOR.clock - role_started
          facts["cumulative_output_bytes"] = consumed
          facts["verdict"] = "FAIL" if facts["elapsed_seconds"] > 20
          facts["qualified"] = false if facts["elapsed_seconds"] > 20
          facts["synthetic_fixture_unchanged"] = Digest::SHA256.file(plist).hexdigest == fixture_sha
          facts["qualified"] = false unless facts["synthetic_fixture_unchanged"]
          facts["preference_limitation"] = "Unattributed AppleLocale or unproved synthetic principal is BLOCKED; no real preference values retained."
          %w[stdout stderr].each do |stream|
            bytes = result.public_send(stream)
            facts["#{stream}_sha256"] = Digest::SHA256.hexdigest(bytes)
            facts["#{stream}_base64"] = [bytes].pack("m0")
          end
          facts["observations"] = AgentCodingTool::RunEvidenceStore.parse(result.stdout) rescue nil
          report.fetch("roles")[role] = facts
        end
        verify_pin!(pin)
        canaries = [candidate, git_control, control, foreign] + ROLES.map { |role| File.join(output, "#{role}-home", "marker") }
        report["canaries_unchanged"] = canaries.all? { |path| File.binread(path) == "fixture-canary" }
        report["status"] = "PASS" if report.fetch("roles").values.all? { |row| row.fetch("qualified") } && report.fetch("canaries_unchanged")
        if report["status"] != "PASS" && report.fetch("canaries_unchanged") &&
            report.fetch("roles").values.all? { |row| %w[PASS BLOCKED].include?(row["verdict"]) && row["synthetic_fixture_unchanged"] }
          report["status"] = "BLOCKED"
        end
      end
    rescue StandardError => error
      report["failure"] = "#{error.class}: #{error.message}"
    ensure
      if report
        report.fetch("roles").values.flat_map { |role| [role, *role.fetch("controls", {}).values] }.each do |row|
          directory = row["raw_directory"]
          next unless directory
          row["supervision"] = Dir.glob(File.join(directory, "*.json")).reject { |path| File.basename(path) == "config.json" }.to_h do |path|
            [File.basename(path), JSON.parse(File.binread(path))]
          end
          row["raw_captures"] = Dir.glob(File.join(directory, "*.{stdout,stderr}")).to_h do |path|
            bytes = File.binread(path)
            [File.basename(path), { "sha256" => Digest::SHA256.hexdigest(bytes), "base64" => [bytes].pack("m0") }]
          end
        end
        report["elapsed_seconds"] = EXECUTOR.clock - started
        report["status"] = "FAIL" if report["elapsed_seconds"] > 110
        report["next_action"] = if report["status"] == "PASS"
          "Harmless access gate passed. Live continuity still NOT RUN; separately bounded authority must account for both consumed starts."
        else
          "Keep live startup blocked. Review REPORT.json: returned protected synthetic data is a boundary failure; unsupported controls or unattributed AppleLocale remain BLOCKED. David must choose an isolated preference-principal qualification with demonstrated provenance, or keep this runtime path blocked. No broader grant or inference is authorized."
        end
        EXECUTOR.save(output, "REPORT.json", report) if created
        puts JSON.pretty_generate(report.slice("status", "failure", "elapsed_seconds", "canaries_unchanged", "live_continuity", "next_action").merge(
          "raw_report" => created ? File.join(output, "REPORT.json") : nil,
          "roles" => report.fetch("roles").transform_values { |row| row.slice("verdict", "exit_status", "signal", "elapsed_seconds", "preference_limitation") }))
      end
    end
    report
  end

  # CLI accepts exactly one reviewed pin and one exclusive harmless output root.
  # Semantic failures exit nonzero even when every interpreter exits zero.
  def self.main(arguments)
    raise "usage: qualification-pin.json FRESH_FIXTURE_OUTPUT" unless arguments.length == 2
    report = run(*arguments)
    report.fetch("status") == "PASS" ? 0 : 1
  rescue StandardError => error
    warn "qualification refused: #{error.class}: #{error.message}"
    1
  end
end

exit Wac04PreferencesQualification.main(ARGV) if $PROGRAM_NAME == __FILE__
