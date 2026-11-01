# frozen_string_literal: true

require 'minitest/mock'
require_relative 'support/child_processes'

# Only external boundaries are replaced in decision tests. Coordinator lifecycle,
# prompt rendering, locks, trust checks and durable evidence use production code.
# `git: true` selects the memory world; `process: true` retains real process contracts.
module LauncherSupport
  class FakeWorktrees
    def initialize(root, ordinary, remote, base)
      @root, @ordinary, @remote, @base = root, ordinary, remote, base
    end

    def create(task_id:, attempt:, task:, snapshot:)
      entries = task.fetch('repositories').map do |name, spec|
        path = File.join(@root, 'worktrees', task_id, name)
        FileUtils.mkdir_p(path)
        source = snapshot.fetch(name)
        file = File.join(source.fetch('path'), 'file.txt')
        FileUtils.cp(file, path) if File.file?(file)
        { 'name' => name, 'path' => path, 'access' => spec.fetch('access'),
          'parent' => source.fetch('path'),
          'branch' => spec.fetch('access') == 'write' ? "act/#{task_id}/attempt-#{attempt}" : nil,
          'base_sha' => source.fetch('pushed_sha'), 'remote_url' => source.fetch('remote_url') }
      end
      { 'entries' => entries }
    end

    def inspect! = true

    # External source observations are synthetic in ordinary decision tests.
    # Native launch tests use the production read-only prerequisite check.
    def creation_readiness!(task:, snapshot:) = []
  end

  class Inspector < TestHelpers::FakeInspector
    def initialize(ordinary, remote, base)
      super(heads: { 'repo' => base }, remote_urls: { 'repo' => remote })
      @ordinary = ordinary
    end

    def snapshot(name, spec)
      key = heads.key?(name) ? name : 'repo'
      ensure_remote!(remote_urls.fetch(key))
      super(key, spec).merge('path' => spec.fetch('path', @ordinary))
    end

    def pushed_heads(references)
      references.each { |reference| ensure_remote!(reference.fetch('remote_url')) }
      super(references.map do |reference|
        name = reference.fetch('name').split('/', 2).last
        reference.merge('name' => heads.key?(name) ? name : 'repo')
      end)
    end

    def repository_authority(name, spec)
      super(heads.key?(name) ? name : 'repo', spec)
    end

    private

    def ensure_remote!(remote)
      raise AgentCodingTool::RepositoryError, "cannot resolve pushed #{remote}/main" unless File.directory?(remote)
    end
  end

  # Returns modeled exit facts for finite external responses; no PID or process.
  def status_result(success)
    AgentCodingTool::CommandResult.new(stdout: "", stderr: "", exitstatus: success ? 0 : 1)
  end

  # Returns one immutable reviewed fake worker script. Each invocation reads its
  # case settings through the final-output path; it never initializes Git.
  def fake_executable
    name = @native_fixture ? 'native_launcher_worker.rb' : 'launcher_worker.rb'
    File.expand_path("support/fixtures/#{name}", __dir__)
  end

  # Adapts only the declared fake worker boundary to a guarded Ruby invocation.
  # Production still creates pipes, forwards signals, reaps status and persists
  # evidence. Other executables/options fail before any process is created.
  def spawn_fake_worker(environment, *command, **options)
    raise GitContract::UnexpectedObservation, 'unknown fake worker' unless command.shift == File.realpath(@fake)
    if @native_fixture
      return Process.spawn(environment, RbConfig.ruby, fake_executable, *command, **options)
    end
    pipes = options.select { |key, _value| [:in, :out, :err].include?(key) }
    settings = options.reject { |key, _value| pipes.key?(key) }
    forwarded = environment.dup
    forwarded['ACT_COVERAGE_CONTEXT'] = ENV['ACT_COVERAGE_CONTEXT'] if ENV['ACT_COVERAGE_CONTEXT']
    forwarded['ACT_TEST_CODING_SKILL'] = ENV['ACT_TEST_CODING_SKILL'] if @memory_broker
    approval = ChildProcesses.permit('launcher_worker', arguments: command, environment: forwarded,
      options: settings, endpoint: @memory_broker&.endpoint)
    NoGitExecution.with_permit(approval) do
      Process.spawn(approval.environment, *approval.argv, **approval.options, **pipes)
    end
  end

  def write_fake(mode = 'success', auth: 'Logged in using ChatGPT', help: true,
                 version: 'codex-cli 0.162.1', sandbox_help: 'Usage: codex sandbox [OPTIONS] [COMMAND]...')
    @fake_mode = mode
    @fake_auth = auth
    @fake_help = help ? '--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model' : '--sandbox'
    @fake_version, @fake_sandbox_help = version, sandbox_help
    raise 'real preflight requires default fake help/auth' if @real_git && (!help || auth != 'Logged in using ChatGPT')
    File.symlink(fake_executable, @fake) unless File.exist?(@fake)
    File.write(File.join(@root, 'fake-settings.json'), JSON.generate('mode' => mode))
  end

  # Executes bounded fixture commands against this case's authority only.
  # Unknown setup forms fail rather than fall back to a captured native method.
  def setup_git(*args, chdir: nil)
    return TestHelpers.native_git(chdir || @root, *args).strip if @native_fixture
    raise MemoryGit::Mismatch, "missing launcher world" unless @memory_world
    result = @memory_world.call(["git", *args], cwd: chdir)
    raise "Git fixture failed: #{result.stderr}" unless result.success?
    result.stdout.strip
  end

  # Yields independent memory repositories or finite ordinary observations.
  # All remotes are private; mutable_remote remains a legacy keyword. Real worker
  # execution is explicit and guarded; setup/model/protocol failures propagate.
  def fixture(git: false, process: false, mutable_remote: false)
    Dir.mktmpdir('act-launch-') do |root|
      @root = File.realpath(root)
      @unit_workspace = nil
      @dep_ordinary = nil
      @data, @ordinary, @remote, @fake = %w[data ordinary remote.git codex].map { |name| File.join(@root, name) }
      @real_git, @real_process = git, process
      FileUtils.mkdir_p(File.join(@data, 'tasks'))
      @native_fixture = ENV['ACT_NATIVE_SUITE'] == '1' && ENV['ACT_ORDINARY_SUITE'] != '1'
      @memory_world = git && !@native_fixture ? MemoryGit::PatchWorld.new(root: @root) : nil
      if git && @native_fixture
        seed = TestHelpers.git_seed
        FileUtils.cp_r(File.join(seed.fetch(:root), 'ordinary'), @ordinary)
        FileUtils.cp_r(File.join(seed.fetch(:root), 'remote.git'), @remote)
        TestHelpers.native_git(@ordinary, 'remote', 'set-url', 'origin', @remote)
        @base = seed.fetch(:base)
      elsif git
        checkout, = memory_repository(@memory_world, path: @ordinary, remote: @remote)
        @base = checkout.head
      else
        FileUtils.mkdir_p([@ordinary, @remote])
        File.write(File.join(@ordinary, 'file.txt'), "base\n")
        @base = 'a' * 40
      end
      MemoryGit::Session.with(@memory_world) do
        File.write(File.join(@data, 'config.yml'), YAML.dump('repo_root' => @root, 'worktree_root' => File.join(@root, 'worktrees')))
        write_task(@data, id: 'T', repositories: { 'repo' => { 'access' => 'write', 'path' => @ordinary } })
        write_fake
        @config = AgentCodingTool::Config.load(File.join(@data, 'config.yml'))
        @store = AgentCodingTool::StateStore.new(File.join(@data, 'state'))
        @inspector = git ? AgentCodingTool::RepoInspector.new(@config) : Inspector.new(@ordinary, @remote, @base)
        @coordinator = AgentCodingTool::Coordinator.new(
          task_store: AgentCodingTool::TaskStore.new(File.join(@data, 'tasks')), state_store: @store,
          repo_inspector: @inspector, prompt_renderer: AgentCodingTool::PromptRenderer.new,
          prompt_root: File.join(@data, 'state', 'prompts'))
        @out, @err = StringIO.new, StringIO.new
        if git
          MemoryGit::Session.with_capture(method(:unit_capture)) { yield }
        else
          AgentCodingTool::RepoInspector.stub(:new, @inspector) do
            AgentCodingTool::WorktreeManager.stub(:new, FakeWorktrees.new(@root, @ordinary, @remote, @base)) do
              MemoryGit::Session.with_capture(method(:unit_capture)) { yield }
            end
          end
        end
      end
    ensure
      @memory_world&.verify!
    end
  end

  # Exact external preflight observations for existing ordinary decision cases.
  # Git source reads use the immutable adapter; undeclared requests raise.
  def unit_capture(*command, **options)
    if @native_fixture && (@real_git || command.first == RbConfig.ruby ||
        (command.first.is_a?(Hash) && command[1] == 'git' && (@real_git || command[2] == '--no-replace-objects')) || command.first == '/usr/sbin/sysctl')
      return NativeTestCapture.call(*command, **options)
    end
    if command == ['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid']
      return ['00000000-0000-0000-0000-000000000000', '', status_result(true)]
    end
    if command[0].is_a?(Hash) && command[1, 2] == ['git', '--no-replace-objects']
      raise GitContract::UnexpectedObservation, 'ordinary skill read escaped its finite runner' if ENV['ACT_ORDINARY_SUITE'] == '1'
      environment, *arguments = command
      fields = { env: environment, cwd: options[:chdir], input: options.fetch(:stdin_data, '') }
      raise GitContract::UnexpectedObservation, 'unknown source options' unless (options.keys - [:chdir, :stdin_data]).empty?
      return MemoryGit::Session.skill_transport.call(arguments, **fields).to_ary
    end
    # NativeCommandTransport makes the empty inherited environment and stdin
    # explicit. Normalize only those defaults; overrides, input and extra
    # options must still fail rather than be mistaken for Codex preflight.
    command.shift if command.first == {} && command[1] == 'git'
    if command.first == 'git'
      raise GitContract::UnexpectedObservation, 'unexpected Git stdin' unless options.fetch(:stdin_data, '') == ''
      options = options.reject { |key, _value| key == :stdin_data }
      raise GitContract::UnexpectedObservation, 'unexpected Git options' unless options.keys == [:chdir]
    end
    if command.first == 'git' && @memory_world
      return @memory_world.call(command, cwd: options.fetch(:chdir)).to_ary
    end
    if command.first.is_a?(Hash)
      env = command.shift
      allowed_options = [{ unsetenv_others: true },
                         { chdir: File.join(@root, 'worktrees', 'T', 'repo'), unsetenv_others: true }]
      raise GitContract::UnexpectedObservation, "unsafe preflight environment keys=#{env.keys.inspect} options=#{options.inspect}" unless (env.keys - %w[HOME PATH TMPDIR CODEX_HOME LANG LC_ALL]).empty? &&
                                                    allowed_options.include?(options)
      raise GitContract::UnexpectedObservation, "unexpected executable: #{command.inspect}" unless command.shift == File.realpath(@fake)
      case command
      when ['--version'] then [@fake_version, '', status_result(true)]
      when ['exec', '--help'] then [@fake_help, '', status_result(true)]
      when ['login', '--help'] then ['status Show login status', '', status_result(true)]
      when ['login', 'status'] then ['', @fake_auth, status_result(!@fake_auth.empty?)]
      when ['sandbox', '--help'] then [@fake_sandbox_help, '', status_result(true)]
      when ->(args) { args.include?('sandbox') && args.include?('act-probe') }
        prefix = command.take(command.index('sandbox'))
        home = env.fetch('CODEX_HOME')
        raise GitContract::UnexpectedObservation, 'unsupported top-level sandbox flag or inherited configuration' unless
          prefix.length.even? && prefix.each_slice(2).all? { |flag, value| flag == '-c' && value && !value.empty? } &&
          File.directory?(home) && (File.stat(home).mode & 0o077).zero? && Dir.children(home).empty? &&
          home != ENV['CODEX_HOME'] && !home.start_with?("#{@root}/")
        @observed_sandbox_home = home
        raise GitContract::UnexpectedObservation, 'legacy or unenforced sandbox invocation' unless
          command.include?('sandbox_mode="workspace-write"') && command[command.index('sandbox') + 1] == '--' &&
          !command.include?('--full-auto')
        paths = command.drop(command.index('act-probe') + 1)
        @observed_sandbox_roots = JSON.parse(command.find { |arg| arg.start_with?('sandbox_workspace_write.writable_roots=') }.split('=', 2).last)
        @observed_sandbox_tmpdir = env.fetch('TMPDIR')
        output = paths.map do |path|
          allowed = @fake_mode == 'leaky' ||
            ([options.fetch(:chdir)] + @observed_sandbox_roots).any? { |root| path.start_with?(root + '/') }
          allowed = false if @fake_mode == 'fixture_denied' && path.start_with?(env.fetch('TMPDIR') + '/')
          allowed = true if @fake_mode == 'fixture_parent_leaky' && File.dirname(path) == File.dirname(env.fetch('TMPDIR'))
          File.write(path, 'breach') if allowed
          allowed ? "1\n" : "0\n"
        end.join
        [output, '', status_result(true)]
      else raise GitContract::UnexpectedObservation, "unexpected preflight: #{command.inspect}"
      end
    else
      raise GitContract::UnexpectedObservation, "unexpected external command: #{command.inspect}" unless command.shift == 'git'
      if command == ['rev-parse', '--path-format=absolute', '--git-common-dir'] &&
         ([@ordinary, @dep_ordinary] + @store.load('T').fetch('snapshot', {}).values.map { |repo| repo.fetch('path') }).compact.include?(options[:chdir])
        admin = File.join(@root, options.fetch(:chdir) == @ordinary ? 'admin' : 'admin-dep')
        FileUtils.mkdir_p(admin)
        return [admin, '', status_result(true)]
      end
      @unit_workspace ||= File.join(@root, 'worktrees', 'T', 'repo')
      raise GitContract::UnexpectedObservation, 'unexpected Git working directory' unless options == { chdir: @unit_workspace }
      case command
      when ['remote', 'get-url', 'origin'] then [@remote, '', status_result(true)]
      when ['rev-parse', 'HEAD'] then [@base, '', status_result(true)]
      when ['--no-optional-locks', 'status', '--porcelain=v1', '-z', '--untracked-files=all'] then ['', '', status_result(true)]
      when ['symbolic-ref', '-q', 'HEAD'] then ['refs/heads/act/T/attempt-1', '', status_result(true)]
      else raise GitContract::UnexpectedObservation, "unexpected Git operation: #{command.inspect}"
      end
    end
  end

  def launcher(real_sandbox_probe: false, **extra)
    instance = AgentCodingTool::Launcher.new(coordinator: @coordinator, data_root: @data, source_root: Dir.pwd,
                                           out: @out, err: @err, codex: @fake,
                                           **{ spawner: method(:spawn_fake_worker) }.merge(extra))
    instance.define_singleton_method(:sandbox_probe!) { |_inventory, _workspace, _run_dir| true } unless real_sandbox_probe
    unless @real_process
      root, store = @root, @store
      instance.define_singleton_method(:execute) do |command, _lock|
        # A lifecycle/argv test needs no OS child. Assert the reservation precedes
        # handoff; genuine process tests exercise the unchanged execute method.
        raise 'prompt handed off before reservation' unless store.load('T')['started_at']
        File.write(File.join(root, 'argv'), JSON.generate(command.drop(1)))
        @report.merge!('status' => 'exited', 'exit_status' => 0)
        save_report
        0
      end
    end
    instance
  end
end
