# frozen_string_literal: true

module AgentCodingTool
  # Qualifies the installed fresh-review runtime inside the operator's one-use slot.
  class FirstReturnRuntime
    EXECUTOR = NativePilotExecutor
    SANDBOX = "/usr/bin/sandbox-exec"
    VERSION = /\Acodex-cli 0\.(162\.1|166\.0)\z/
    EXEC_FLAGS = %w[--json --config --ignore-user-config --ignore-rules --skip-git-repo-check].freeze
    BOUNDARY_PROBE = <<~'PROBE'.freeze
      expected, control = ARGV
      alias_path = File.join(expected, "control-alias")
      File.symlink(control, alias_path)
      abort unless Dir.pwd == expected && File.realpath(".") == expected && File.stat(".").directory?
      {
        read: -> { File.binread(control) },
        write: -> { File.write("#{control}.forbidden", "denied") },
        alias_read: -> { File.binread(alias_path) },
        fork: -> { Process.waitpid(Process.fork { exit! 0 }) },
        signal: -> { Process.kill(0, Process.ppid) },
        exec: -> { Process.exec("/usr/bin/true") }
      }.each_value do |operation|
        begin
          operation.call
          abort "sandbox allowed forbidden operation"
        rescue Errno::EPERM, Errno::EACCES
        end
      end
      File.unlink(alias_path)
      File.write("history-probe", "allowed")
      puts "manager boundary passed"
    PROBE

    # Retains the fixed per-invocation slot, without creating files or processes.
    def initialize(directory)
      @directory = directory
    end

    # Creates an exclusive private slot and qualifies the manager-only policy.
    # Any failed check leaves inference unarmed. An occupied slot is never reset.
    def authorize(data_root, binding, revision)
      raise InvalidState, "first-return: Darwin confinement required" unless RUBY_PLATFORM.include?("darwin")
      codex = codex_executable
      auth = File.realpath(File.join(ENV.fetch("CODEX_HOME") { File.join(Dir.home, ".codex") }, "auth.json"))
      stat = File.stat(auth)
      raise InvalidState, "first-return: private file-based ChatGPT auth required" unless
        stat.file? && stat.uid == Process.uid && stat.nlink == 1 && (stat.mode & 0o077).zero?

      EXECUTOR.private_directory!("#{data_root}-runs")
      [File.dirname(File.dirname(@directory)), File.dirname(@directory)].each do |path|
        begin
          Dir.mkdir(path, 0o700)
        rescue Errno::EEXIST
          # Another invocation may have created this shared parent.
        end
        EXECUTOR.private_directory!(path)
      end
      Dir.mkdir(@directory, 0o700)
      File.open(File.dirname(@directory), &:fsync)
      seconds = EXECUTOR::FIRST_RETURN_SECONDS
      lease = { "deadline" => Time.now.to_f + seconds, "monotonic_deadline" => EXECUTOR.clock + seconds }
      config = configuration(codex, auth, lease)
      qualify!(config, auth)
      approval = { "data_root" => data_root, "binding" => binding, "revision" => revision,
        "composition" => Bootstrap::COMPOSITION }
      EXECUTOR.create(@directory, config.merge("first_return" => approval, "turn_seconds" => seconds), seconds: seconds)
    rescue Errno::EEXIST
      raise InvalidState, "first-return: reviewer slot already occupied", cause: nil
    end

    private

    # Resolves the operator's installed native Codex on absolute PATH entries.
    # Refuses wrappers, nonexecutable files and runtimes writable by other users.
    def codex_executable
      candidate = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |path|
        File.join(path, "codex") if path.start_with?("/")
      end.find { |path| File.file?(path) && File.executable?(path) }
      raise InvalidState, "first-return: installed Codex unavailable" unless candidate
      path = File.realpath(candidate)
      stat = File.stat(path)
      raise InvalidState, "first-return: unsafe Codex executable" unless stat.file? &&
        [0, Process.uid].include?(stat.uid) && (stat.mode & 0o022).zero? &&
        %w[cffaedfe feedfacf cafebabe cafebabf].include?(File.binread(path, 4).unpack1("H*"))
      path
    end

    # Builds a manager-only profile and pins the production sources and runtime.
    # Codex can write only its private home and read only its selected auth file
    # and the system paths granted by the existing host policy.
    def configuration(codex, auth, lease)
      home = File.join(@directory, "home")
      cwd = File.join(home, "T", "work")
      tmp = File.join(home, "tmp")
      [home, File.dirname(cwd), cwd, tmp].each { |path| Dir.mkdir(path, 0o700) }
      File.symlink(auth, File.join(home, "auth.json"))
      profile = File.join(@directory, "manager.sb")
      File.write(profile, EXECUTOR.policy(role: "manager", reads: [], home: home, workspace: cwd,
        executables: [codex], auth: auth), mode: "wx", perm: 0o600)
      environment = { "PATH" => "/usr/bin:/bin", "HOME" => home, "CODEX_HOME" => home, "TMPDIR" => tmp,
        "LANG" => "C", "LC_ALL" => "C", "TZ" => "UTC" }
      sources = Dir.glob(File.join(__dir__, "**", "*.rb")) + [File.join(__dir__, "../agent_coding_tool.rb")]
      pins = [*sources.map { |path| File.expand_path(path) }, codex, SANDBOX, profile].to_h do |path|
        [path, Digest::SHA256.file(path).hexdigest]
      end
      { "executable" => codex, "pins" => pins, "profiles" => { "manager" => profile },
        "environments" => { "manager" => environment }, "manager_cwd" => cwd, "worktree_root" => home,
        "enclosing_lease" => lease }
    end

    # Checks the manager boundary with fixed harmless operations, then checks
    # the actual Codex under the narrower live profile without sending evidence.
    # Missing flags, unsupported version or non-ChatGPT login refuse admission.
    def qualify!(config, auth)
      ruby = File.realpath(RbConfig.ruby)
      prefix = File.realpath(RbConfig::CONFIG.fetch("prefix"))
      home = config.dig("environments", "manager", "HOME")
      probe_profile = File.join(@directory, "probe.sb")
      File.write(probe_profile, EXECUTOR.policy(role: "manager", reads: [prefix], home: home,
        workspace: config.fetch("manager_cwd"), executables: [config.fetch("executable"), ruby], auth: auth),
        mode: "wx", perm: 0o600)
      probe_pins = [probe_profile, ruby].to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }
      probe_config = config.merge("pins" => config.fetch("pins").merge(probe_pins))
      gems = File.join(prefix, "lib/ruby/gems", RbConfig::CONFIG.fetch("ruby_version"))
      probe_env = config.dig("environments", "manager").merge("GEM_HOME" => gems, "GEM_PATH" => gems)
      boundary = observe("boundary", [ruby, "--disable=gems", "-e", BOUNDARY_PROBE,
        config.fetch("manager_cwd"), probe_profile], probe_config, profile: probe_profile, environment: probe_env)
      raise InvalidState, "first-return: manager confinement unqualified" unless boundary.strip == "manager boundary passed"

      codex = config.fetch("executable")
      version = observe("version", [codex, "--version"], config)
      raise InvalidState, "first-return: unsupported installed Codex version" unless VERSION.match?(version.strip)
      help = observe("exec-help", [codex, "exec", "--help"], config)
      raise InvalidState, "first-return: installed Codex lacks safe exec flags" unless EXEC_FLAGS.all? { |flag| help.include?(flag) }
      observe("features", [codex, "features", "list"], config)
      auth_status = observe("login-status", [codex, "login", "status"], config)
      raise InvalidState, "first-return: ChatGPT login required" unless auth_status.lines.any? { |line| line.strip == "Logged in using ChatGPT" }
    end

    # Runs one fixed probe with the production supervisor's output, time and
    # teardown limits. Each probe has its own ledger within the enclosing lease.
    def observe(name, argv, config, profile: config.dig("profiles", "manager"), environment: config.dig("environments", "manager"))
      directory = File.join(@directory, name)
      Dir.mkdir(directory, 0o700)
      probe = config.merge("gate_argv" => argv, "gate_seconds" => 10,
        "profiles" => { "gate" => profile }, "environments" => { "gate" => environment })
      result = EXECUTOR.create(directory, probe, seconds: 10)
        .capture("gate", argv, input: "", cwd: config.fetch("manager_cwd"))
      raise InvalidState, "first-return: #{name} check failed" unless result.success?
      result.stdout + result.stderr
    end
  end
end
