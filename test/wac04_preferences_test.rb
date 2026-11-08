# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"
require_relative "integration/wac04_preferences_qualification"

# Offline regressions only: no CF calls, native policy execution or inference.
class Wac04PreferencesTest < Minitest::Test
  QUALIFICATION = Wac04PreferencesQualification
  PROBE = Wac04PreferencesProbe
  EXECUTOR = AgentCodingTool::NativePilotExecutor

  # Every previous policy line survives; exactly two domain-scoped grants are
  # added to inference roles. The independent validation role gains no authority.
  def test_policy_changes_only_domain_reads_and_named_cfprefsd_lookup
    baseline = <<~POLICY
      (version 1)
      (deny default)
      (allow file-read-metadata)
      (allow file-read-data (literal "/"))
      (allow sysctl-read)
      (allow signal (target self))
      (allow process-info* (target self))
      (allow file-read* file-write-data (literal "/dev/null"))
      (allow file-read* (literal "/dev/random") (literal "/dev/urandom"))
      (allow file-read* file-map-executable (subpath "/source"))
      (allow file-read* file-map-executable (subpath "/System/Library"))
      (allow file-read* file-map-executable (subpath "/usr/lib"))
      (allow file-read* file-map-executable (subpath "/usr/share"))
      (allow file-read* file-map-executable (subpath "/private/var/db/dyld"))
      (allow process-exec file-read* file-map-executable (literal "/runtime"))
      (allow file-read* (literal "/auth"))
      (allow file-read* file-write* (subpath "/home"))
    POLICY
    grants = <<~POLICY
      (allow user-preference-read managed-preference-read (preference-domain "com.openai.codex"))
      (allow mach-lookup (global-name "com.apple.cfprefsd.daemon") (global-name "com.apple.cfprefsd.agent") (local-name "com.apple.cfprefsd.agent"))
    POLICY
    QUALIFICATION::ROLES.each do |role|
      old = baseline.dup
      if role == "worker"
        old << "(allow file-read* file-write* (subpath \"/candidate\"))\n"
        old << "(deny file-read* file-write* (subpath \"/candidate/.git\"))\n"
      end
      old << '(deny file-read* file-write* (regex #".*/[.]git(/|$)"))' + "\n"
      expected = old + (role == "gate" ? "" : grants + "(allow network*)\n")
      actual = EXECUTOR.policy(role: role, reads: ["/source"], home: "/home", workspace: "/candidate", executables: ["/runtime"], auth: "/auth")
      assert_equal expected, actual
      refute_includes actual, "(allow ipc-posix-shm"
      refute_includes actual, "(allow user-preference-write"
      refute_includes actual, '(import "system.sb")'
    end
  end

  # The loader never trusts unforced defaults; disappearing forced state and
  # non-string forced data remain explicit failures in the access qualification.
  def test_managed_configuration_preserves_forced_copy_forced_order
    # Inject only the native exec boundary: the fixed target/argv must reach it
    # directly, without fork/spawn or candidate evaluation, and retain errno.
    [Errno::EPERM, Errno::EACCES, Errno::ENOENT, Errno::ENOEXEC].each do |error|
      execution = lambda do |*argv|
        assert_equal [[PROBE::FOREIGN_EXECUTABLE, PROBE::FOREIGN_EXECUTABLE]], argv
        raise error
      end
      _stdout, stderr = capture_subprocess_io do
        Process.stub(:exec, execution) do
          row = PROBE.exec_attempt(PROBE::FOREIGN_EXECUTABLE)
          assert_equal error::Errno, row.fetch("errno")
          assert_equal error.name, row.fetch("error_class")
        end
      end
      assert_equal({ "operation" => "exec", "path" => PROBE::FOREIGN_EXECUTABLE, "pid" => Process.pid }, JSON.parse(stderr))
    end
    [
      [[false], nil, %w[forced], { "forced_before" => false, "copied" => false }],
      [[true], nil, %w[forced copy], { "forced_before" => true, "copied" => false }],
      [[true, true], true, %w[forced copy forced], { "forced_before" => true, "copied" => true, "forced_after" => true, "string" => true }],
      [[true, false], true, %w[forced copy forced], { "forced_before" => true, "copied" => true, "forced_after" => false, "string" => true }],
      [[true, true], false, %w[forced copy forced], { "forced_before" => true, "copied" => true, "forced_after" => true, "string" => false }]
    ].each do |forced, string, expected_calls, expected|
      calls = []
      api = lambda do |operation, key|
        assert_equal "config_toml_base64", key
        calls << operation
        operation == "forced" ? forced.shift : (string.nil? ? nil : { "string" => string })
      end
      assert_equal expected, PROBE.managed_read(api, "config_toml_base64")
      assert_equal expected_calls, calls
    end
  end

  # Constructs fake observations at the explicit OS boundary, never a native
  # acceptance receipt. Domain emptiness is deliberately present in valid data.
  def observations(role)
    spec = QUALIFICATION.specification(role, { "control" => "/control", "foreign" => "/foreign", "git" => "/candidate/.git/control",
      "candidate" => "/candidate/marker", "home" => "/home/marker", "denied_reads" => { "protected" => "/protected" }, "cwd" => "/home/T/work" })
    facts = { "checks" => spec.fetch("expected").merge("foreign-exec" => -1), "after" => spec.fetch("expected").merge("foreign-exec" => -1),
      "exec" => { "operation" => "exec", "path" => PROBE::FOREIGN_EXECUTABLE, "pid" => 42, "errno" => Errno::EPERM::Errno, "error_class" => "Errno::EPERM" },
      "filesystem" => spec.fetch("expected_files").dup, "synchronized" => role != "gate",
      "configuration" => PROBE::KEYS.to_h { |key| [key, { "forced_before" => false, "copied" => false, "access_copy_present" => false }] },
      "unrelated" => PROBE::UNRELATED.transform_values { { "present" => false, "forced" => false } },
      "cwd" => { "getcwd" => "/home/T/work", "realpath" => "/home/T/work", "directory" => true } }
    [spec, facts]
  end

  # Models only the declared native boundaries. A real positive CF control must
  # observe the unique disposable data before a missing negative can qualify.
  def control_observations
    result = ->(value, stderr = "") { AgentCodingTool::CommandResult.new(stdout: JSON.generate(value), stderr: stderr, exitstatus: 0) }
    contexts = [true, false].map do |present|
      reading = %w[app any-app exact].to_h { |name| [name, { "present" => present, "matches_fixture" => present }] }
      result.call("canary" => reading, "locale" => reading, "fixed_home" => true, "file" => present ? "allowed" : "denied")
    end
    { "ruby" => "/ruby", "exec-control" => result.call({ "control" => "wac04-allowed-exec/v1", "pid" => 43 },
        JSON.generate("operation" => "exec", "path" => "/ruby", "pid" => 43)),
      "preference-positive" => contexts.first, "preference-negative" => contexts.last }
  end

  # A zero interpreter exit cannot hide denied required access, unrelated access,
  # dynamic broadening, missing fields, invalid forced data or malformed streams.
  def test_semantics_refuse_empty_domain_as_denial_and_zero_exit_failures
    QUALIFICATION::ROLES.each do |role|
      spec, facts = observations(role)
      controls = control_observations
      make_result = ->(value) { AgentCodingTool::CommandResult.new(stdout: JSON.generate(value), stderr: "", exitstatus: 0) }
      assert QUALIFICATION.qualified?(make_result.call(facts), spec, role, controls)
      spec.fetch("expected").each do |name, expected|
        ["checks", "after"].each do |phase|
          changed = Marshal.load(Marshal.dump(facts))
          changed.fetch(phase)[name] = expected.zero? ? 1 : 0
          refute QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls), "#{role}:#{phase}:#{name}"
          changed.fetch(phase)[name] = -1
          refute QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls), "API errors cannot prove denial"
        end
      end
      facts.keys.each do |key|
        changed = facts.reject { |name, _value| name == key }
        # The unchanged gate has no synchronization dependency.
        next if role == "gate" && key == "synchronized"
        refute QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls)
      end
      if role != "gate"
        changed = facts.merge("synchronized" => false)
        refute QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls)
      end
      changed = facts.merge("unrelated" => facts.fetch("unrelated").merge(".GlobalPreferences" => { "present" => true, "forced" => false }))
      refute QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls)
      [{ "forced_before" => true, "copied" => true, "forced_after" => false, "string" => true, "access_copy_present" => true },
       { "forced_before" => true, "copied" => true, "forced_after" => true, "string" => false, "access_copy_present" => true }].each do |invalid|
        changed = facts.merge("configuration" => facts.fetch("configuration").merge(PROBE::KEYS.first => invalid))
        refute QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls)
      end
      ["", "{", "\x00\xff".b, JSON.generate(facts).byteslice(0, 50)].each do |bytes|
        refute QUALIFICATION.qualified?(AgentCodingTool::CommandResult.new(stdout: bytes, stderr: "", exitstatus: 0), spec, role, controls)
      end
      ["fork", "spawn", "unknown"].each do |operation|
        changed = facts.merge("exec" => facts.fetch("exec").merge("operation" => operation))
        refute QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls)
      end
      [Errno::ENOENT, Errno::ENOEXEC, Errno::ETIMEDOUT, Errno::ENOMEM].each do |error|
        changed = facts.merge("exec" => facts.fetch("exec").merge("errno" => error::Errno, "error_class" => error.name))
        refute QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls)
      end
      [Errno::EPERM, Errno::EACCES].each do |error|
        changed = facts.merge("exec" => facts.fetch("exec").merge("errno" => error::Errno, "error_class" => error.name))
        assert QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls)
      end
      [0, 1, -1].each do |spi|
        changed = facts.merge("checks" => facts.fetch("checks").merge("foreign-exec" => spi))
        assert QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls), "SPI remains inconclusive even if it says allowed"
      end
      %w[path pid errno error_class].each do |key|
        changed = facts.merge("exec" => facts.fetch("exec").reject { |name, _value| name == key })
        refute QUALIFICATION.qualified?(make_result.call(changed), spec, role, controls)
      end
      unknown = facts.merge("unrelated" => facts.fetch("unrelated").merge(".GlobalPreferences" => { "present" => true, "forced" => false }))
      assert_equal "BLOCKED", QUALIFICATION.verdict(make_result.call(unknown), spec, role, controls)
      assert_equal "BLOCKED", QUALIFICATION.verdict(make_result.call(facts), spec, role, controls.reject { |key, _value| key == "preference-positive" })
      exposed = JSON.parse(controls.fetch("preference-negative").stdout)
      exposed["canary"]["app"] = { "present" => true, "matches_fixture" => true }
      leak = controls.merge("preference-negative" => make_result.call(exposed))
      assert_equal "FAIL", QUALIFICATION.verdict(make_result.call(facts), spec, role, leak), "denied queries cannot override demonstrated CF access"
      fallback = JSON.parse(controls.fetch("preference-negative").stdout)
      fallback["locale"]["app"] = { "present" => true, "matches_fixture" => false }
      assert_equal "BLOCKED", QUALIFICATION.verdict(make_result.call(facts), spec, role,
        controls.merge("preference-negative" => make_result.call(fallback))), "non-canary fallback/cache provenance is unknown"
      ["", "{", "\x00\xff".b, controls.fetch("exec-control").stdout.byteslice(0, 10)].each do |bytes|
        refute QUALIFICATION.qualified?(make_result.call(facts), spec, role,
          controls.merge("exec-control" => AgentCodingTool::CommandResult.new(stdout: bytes, stderr: "", exitstatus: 0)))
      end
      [ { exitstatus: 7 }, { termsig: 9 } ].each do |status|
        refute QUALIFICATION.qualified?(AgentCodingTool::CommandResult.new(stdout: JSON.generate(facts), stderr: "", **status), spec, role, controls)
        previous = controls.fetch("exec-control")
        refute QUALIFICATION.qualified?(make_result.call(facts), spec, role,
          controls.merge("exec-control" => AgentCodingTool::CommandResult.new(stdout: previous.stdout, stderr: previous.stderr, **status)))
      end
    end
  end

  # Pin verification fails before any native effect. The main entry returns the
  # current semantic status; an old successful output file cannot rescue failure.
  def test_pin_drift_and_failed_current_report_refuse
    assert_raises(RuntimeError) { QUALIFICATION.verify_pin!({ "schema" => "wrong", "ruby" => "/ruby", "codex" => "/codex", "files" => {} }) }
    paths = [QUALIFICATION::PROBE, File.join(QUALIFICATION::SOURCE, "test/integration/wac04_preferences_qualification.rb"),
      File.join(QUALIFICATION::SOURCE, "lib/agent_coding_tool/native_pilot_executor.rb"),
      File.join(QUALIFICATION::SOURCE, "lib/agent_coding_tool/run_evidence_store.rb"), PROBE::FOREIGN_EXECUTABLE]
    pin = { "schema" => "wac04-preferences-qualification/v2", "source_root" => QUALIFICATION::SOURCE,
      "ruby" => paths.first, "codex" => paths.first, "files" => paths.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] } }
    QUALIFICATION.verify_pin!(pin)
    pin.fetch("files")[paths.first] = "0" * 64
    assert_raises(RuntimeError) { QUALIFICATION.verify_pin!(pin) }
    QUALIFICATION.stub(:run, { "status" => "FAIL" }) { assert_equal 1, QUALIFICATION.main(["pin", "occupied-output"]) }
    QUALIFICATION.stub(:run, { "status" => "PASS" }) { assert_equal 0, QUALIFICATION.main(["pin", "output"]) }
    Dir.mktmpdir do |directory|
      directory = File.realpath(directory)
      occupied = File.join(directory, "occupied")
      Dir.mkdir(occupied)
      old_report = File.join(occupied, "REPORT.json")
      File.write(old_report, '{"status":"PASS"}')
      pin["files"][paths.first] = Digest::SHA256.file(paths.first).hexdigest
      pin["ruby"] = File.realpath(RbConfig.ruby)
      pin["files"][pin.fetch("ruby")] = Digest::SHA256.file(pin.fetch("ruby")).hexdigest
      pin["output_parent"] = directory
      pin["output_root"] = occupied
      pin_path = File.join(directory, "pin.json")
      File.write(pin_path, JSON.generate(pin))
      stdout, = capture_io { assert_equal 1, QUALIFICATION.main([pin_path, occupied]) }
      assert_equal "FAIL", JSON.parse(stdout).fetch("status")
      assert_equal '{"status":"PASS"}', File.binread(old_report)
    end
  end
end
