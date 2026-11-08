# frozen_string_literal: true

require "json"
require "fiddle"
require "rbconfig"

# Harmless CFPreferences access probe. Values never leave CoreFoundation memory;
# output contains only permission decisions, presence, type and forced flags.
module Wac04PreferencesProbe
  DOMAIN = "com.openai.codex"
  KEYS = %w[config_toml_base64 requirements_toml_base64].freeze
  UNRELATED = { ".GlobalPreferences" => "AppleLocale", "com.apple.finder" => "AppleShowAllFiles",
    "com.openai.codex.other" => "config_toml_base64" }.freeze
  FOREIGN_EXECUTABLE = "/usr/bin/true"
  EXEC_CONTROL = 'STDOUT.write(%Q({"control":"wac04-allowed-exec/v1","pid":#{Process.pid}})); exit 0'

  # Replaces this supervised process directly; no fork, shell or candidate
  # executable is involved. Only a returned exec authorization errno is denial.
  # Successful replacement cannot emit the denial receipt. Other errors remain
  # explicit inconclusive facts; status, signals and streams belong to the host.
  def self.exec_attempt(path, arguments = [])
    STDERR.puts JSON.generate("operation" => "exec", "path" => path, "pid" => Process.pid)
    STDERR.flush
    Process.exec([path, path], *arguments)
  rescue SystemCallError => error
    { "operation" => "exec", "path" => path, "pid" => Process.pid,
      "errno" => error.errno, "error_class" => error.class.name }
  end

  # Reads only a unique synthetic key and locale marker, without setters. The
  # positive process must demonstrate the lookup context; HOME alone is never
  # treated as that proof. Values are compared inside CF and never serialized.
  # Unsupported APIs, principal overrides or lookup forms fail the control.
  def self.preference_context(spec)
    pointer, integer = Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT
    core = Fiddle.dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    create = Fiddle::Function.new(core["CFStringCreateWithCString"], [pointer, pointer, integer], pointer)
    release = Fiddle::Function.new(core["CFRelease"], [pointer], Fiddle::TYPE_VOID)
    equal = Fiddle::Function.new(core["CFEqual"], [pointer, pointer], Fiddle::TYPE_CHAR)
    copy = Fiddle::Function.new(core["CFPreferencesCopyAppValue"], [pointer, pointer], pointer)
    exact = Fiddle::Function.new(core["CFPreferencesCopyValue"], [pointer] * 4, pointer)
    constant = ->(name) { Fiddle::Pointer.new(core[name]).ptr }
    application = constant.call("kCFPreferencesAnyApplication")
    user = constant.call("kCFPreferencesCurrentUser")
    host = constant.call("kCFPreferencesAnyHost")
    literal = create.call(nil, ".GlobalPreferences", 0x08000100)
    raise "CFString allocation failed" if literal.null?
    original_error = STDERR.dup
    STDERR.reopen(File::NULL, "w")
    results = [spec.fetch("key"), "AppleLocale"].to_h do |name|
      key = create.call(nil, name, 0x08000100)
      expected = create.call(nil, spec.fetch("value"), 0x08000100)
      raise "CFString allocation failed" if key.null? || expected.null?
      begin
        observations = { "app" => -> { copy.call(key, literal) }, "any-app" => -> { copy.call(key, application) },
          "exact" => -> { exact.call(key, application, user, host) } }.to_h do |operation, lookup|
          value = lookup.call
          begin
            [operation, { "present" => !value.null?, "matches_fixture" => !value.null? && equal.call(value, expected) != 0 }]
          ensure
            release.call(value) unless value.null?
          end
        end
        [name == "AppleLocale" ? "locale" : "canary", observations]
      ensure
        release.call(key)
        release.call(expected)
      end
    end
    # File denial and CF access are separate observations. Never let a denied
    # file/query override a returned synthetic protected value.
    begin
      File.open(spec.fetch("plist"), "rb") { |file| file.read(1) }
      results["file"] = "allowed"
    rescue Errno::EPERM, Errno::EACCES
      results["file"] = "denied"
    end
    results["fixed_home"] = ENV["CFFIXED_USER_HOME"] == spec.fetch("principal")
    results
  ensure
    STDERR.reopen(original_error) if original_error && !original_error.closed?
    original_error&.close
    release&.call(literal) if literal && !literal.null?
  end

  # Mirrors the installed loader's forced/copy/forced ordering. The injected
  # callable returns only booleans/type facts; absent or unforced data is never
  # promoted to managed configuration. Native errors propagate to the supervisor.
  def self.managed_read(api, key)
    before = api.call("forced", key)
    return { "forced_before" => false, "copied" => false } unless before
    value = api.call("copy", key)
    return { "forced_before" => true, "copied" => false } unless value
    { "forced_before" => true, "copied" => true,
      "forced_after" => api.call("forced", key), "string" => value.fetch("string") }
  end

  # Runs only in a host-supervised role. Uses sandbox_check with the platform's
  # preference-domain filter (6; Apple WebKit SandboxSPI.h). A denial is exactly
  # 1, never an empty preference domain or an API error. No setters are called.
  def self.run(spec)
    executable = exec_attempt(FOREIGN_EXECUTABLE)
    pointer, integer = Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT
    sandbox = Fiddle.dlopen("/usr/lib/libsandbox.dylib")
    no_report = Fiddle::Pointer.new(sandbox["SANDBOX_CHECK_NO_REPORT"])[0, 4].unpack1("i")
    check = Fiddle::Function.new(sandbox["sandbox_check"], [integer, pointer, integer, Fiddle::TYPE_VARIADIC], integer)
    checks = spec.fetch("queries").to_h do |name, query|
      operation, filter, value = query
      [name, check.call(Process.pid, operation, filter | no_report, pointer, value)]
    end
    core = Fiddle.dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    create = Fiddle::Function.new(core["CFStringCreateWithCString"], [pointer, pointer, integer], pointer)
    release = Fiddle::Function.new(core["CFRelease"], [pointer], Fiddle::TYPE_VOID)
    synchronize = Fiddle::Function.new(core["CFPreferencesAppSynchronize"], [pointer], Fiddle::TYPE_CHAR)
    forced = Fiddle::Function.new(core["CFPreferencesAppValueIsForced"], [pointer, pointer], Fiddle::TYPE_CHAR)
    copy = Fiddle::Function.new(core["CFPreferencesCopyAppValue"], [pointer, pointer], pointer)
    type = Fiddle::Function.new(core["CFGetTypeID"], [pointer], Fiddle::TYPE_SIZE_T)
    string_type = Fiddle::Function.new(core["CFStringGetTypeID"], [], Fiddle::TYPE_SIZE_T).call
    domain = create.call(nil, DOMAIN, 0x08000100)
    raise "CFString allocation failed" if domain.null?
    # Suppress framework diagnostics around preference calls so unexpected OS
    # logging cannot retain private values. Our raw structured stdout/status and
    # all supervisor diagnostics remain captured, without unified-log collection.
    original_error = STDERR.dup
    STDERR.reopen(File::NULL, "w")
    sync = synchronize.call(domain) != 0
    configuration = KEYS.to_h do |key_name|
      key = create.call(nil, key_name, 0x08000100)
      raise "CFString allocation failed" if key.null?
      begin
        api = lambda do |operation, _name|
          if operation == "forced"
            forced.call(key, domain) != 0
          else
            value = copy.call(key, domain)
            next nil if value.null?
            begin
              { "string" => type.call(value) == string_type }
            ensure
              release.call(value)
            end
          end
        end
        # Also exercise CopyAppValue on an empty/unforced domain. Its null result
        # is presence information only; sandbox_check proves access independently.
        access = api.call("copy", key_name)
        [key_name, managed_read(api, key_name).merge("access_copy_present" => !access.nil?)]
      ensure
        release.call(key)
      end
    end
    # Exercise unrelated reads too, discarding every value immediately. Null
    # alone proves nothing: the controller also requires exact kernel denials.
    unrelated = UNRELATED.to_h do |application_name, key_name|
      application = create.call(nil, application_name, 0x08000100)
      key = create.call(nil, key_name, 0x08000100)
      raise "CFString allocation failed" if application.null? || key.null?
      begin
        value = copy.call(key, application)
        present = !value.null?
        release.call(value) if present
        [application_name, { "present" => present, "forced" => forced.call(key, application) != 0 }]
      ensure
        release.call(key)
        release.call(application)
      end
    end
    STDERR.reopen(original_error)
    # Repeat all permission queries AFTER CF calls to detect unexpected dynamic
    # filesystem extensions as well as the static domain boundary.
    after = spec.fetch("queries").to_h do |name, query|
      operation, filter, value = query
      [name, check.call(Process.pid, operation, filter | no_report, pointer, value)]
    end
    filesystem = spec.fetch("files").to_h do |name, item|
      path, operation = item
      begin
        if operation == "read"
          File.open(path, "rb") { |file| file.read(1) }
        else
          File.open(path, File::WRONLY) { |file| file.write("") }
        end
        [name, "allowed"]
      rescue Errno::EPERM, Errno::EACCES
        [name, "denied"]
      end
    end
    begin
      Process.kill(0, Process.ppid) # Permission check only; sends no signal.
      filesystem["foreign_signal"] = "allowed"
    rescue Errno::EPERM, Errno::EACCES
      filesystem["foreign_signal"] = "denied"
    end
    begin
      child = Process.fork { exit! 0 }
      Process.waitpid(child)
      filesystem["fork"] = "allowed"
    rescue Errno::EPERM, Errno::EACCES
      filesystem["fork"] = "denied"
    end
    puts JSON.generate("checks" => checks, "after" => after, "exec" => executable,
      "synchronized" => sync, "configuration" => configuration, "filesystem" => filesystem,
      "unrelated" => unrelated,
      "cwd" => { "getcwd" => Dir.pwd, "realpath" => File.realpath("."), "directory" => File.stat(".").directory? })
  ensure
    STDERR.reopen(original_error) if original_error && !original_error.closed?
    original_error&.close
    release&.call(domain) if domain && !domain.null?
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    spec = JSON.parse(File.binread(ARGV.fetch(0)))
    case ARGV[1]
    when "exec-control"
      puts JSON.generate(Wac04PreferencesProbe.exec_attempt(File.realpath(RbConfig.ruby),
        ["--disable=gems", "-e", Wac04PreferencesProbe::EXEC_CONTROL]))
      exit 1
    when "preference-context"
      puts JSON.generate(Wac04PreferencesProbe.preference_context(spec.fetch("preference_fixture")))
    when nil
      Wac04PreferencesProbe.run(spec)
    else
      raise "unknown fixed probe"
    end
  rescue StandardError => error
    # Exception messages can include private data; retain the class only.
    warn JSON.generate("probe_error_class" => error.class.name)
    exit 1
  end
end
