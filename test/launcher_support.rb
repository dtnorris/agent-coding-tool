# frozen_string_literal: true

require 'minitest/mock'

# Only external boundaries are replaced in decision tests. Coordinator lifecycle,
# prompt rendering, locks, trust checks and durable evidence use production code.
# `git: true` and `process: true` select the genuine integration paths explicitly.
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

  Status = Struct.new(:success) do
    def success? = success
  end

  # Reuse the executable, not worker state. Each child resolves its own fixture
  # from the final-output argument and reads that fixture's settings. This avoids
  # both rewriting executable bytes and cold startup checks for every scenario.
  def fake_executable
    return @@fake_executable if defined?(@@fake_executable)

    directory = Dir.mktmpdir('act-fake-codex-')
    Minitest.after_run { FileUtils.remove_entry(directory) }
    @@fake_executable = File.join(directory, 'codex')
    File.write(@@fake_executable, <<~RUBY)
      #!#{RbConfig.ruby}
      require 'json'
      require 'tmpdir'
      if ARGV == ['--version']
        puts 'codex-cli 0.162.1'
        exit
      end
      if ARGV.include?('sandbox')
        prefix = ARGV.take(ARGV.index('sandbox'))
        abort 'unsupported top-level sandbox flag' unless prefix.length.even? &&
          prefix.each_slice(2).all? { |flag, value| flag == '-c' && value && !value.empty? }
        if ARGV.include?('--help')
          puts 'Usage: codex sandbox [OPTIONS] [COMMAND]...'
          exit
        end
        home = ENV['CODEX_HOME']
        abort 'sandbox inherited user configuration' unless home && File.directory?(home) &&
          (File.stat(home).mode & 0o077).zero? && Dir.children(home).empty? &&
          home != File.join(ENV.fetch('HOME', ''), '.codex')
        abort 'legacy sandbox invocation' unless ARGV.include?('sandbox_mode="workspace-write"') &&
          ARGV[ARGV.index('sandbox') + 1] == '--' && !ARGV.include?('--full-auto')
        targets = ARGV.drop(ARGV.index('act-probe') + 1)
        settings_root = Dir.pwd
        settings_root = File.dirname(settings_root) until File.file?(File.join(settings_root, 'fake-settings.json')) || settings_root == File.dirname(settings_root)
        settings = JSON.parse(File.read(File.join(settings_root, 'fake-settings.json')))
        extra_roots = JSON.parse(ARGV.find { |arg| arg.start_with?('sandbox_workspace_write.writable_roots=') }.split('=', 2).last)
        targets.each do |target|
          if settings.fetch('mode') == 'leaky' || ([Dir.pwd] + extra_roots).any? { |root| target.start_with?(root + '/') && !target.include?('/.git/') }
            File.write(target, 'breach')
            puts '1'
          else
            puts '0'
          end
        end
        exit
      end
      if ARGV == ['exec', '--help']
        puts '--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model'
        exit
      end
      if ARGV == ['login', '--help']
        puts 'status Show login status'
        exit
      end
      if ARGV == ['login', 'status']
        warn 'Logged in using ChatGPT'
        exit
      end
      abort 'unexpected invocation' unless ARGV.first == 'exec'
      path = ARGV[ARGV.index('--output-last-message') + 1]
      root = File.expand_path('../../../..', path)
      mode = JSON.parse(File.read(File.join(root, 'fake-settings.json'))).fetch('mode')
      trap('INT') { File.write(File.join(root, 'interrupted'), 'INT'); exit 130 }
      File.write(File.join(root, 'worker-pid'), Process.pid.to_s)
      File.write(File.join(root, 'worker-process'), JSON.generate(pid: Process.pid, parent: Process.ppid, group: Process.getpgrp, cwd: Dir.pwd))
      input = STDIN.read
      File.binwrite(File.join(root, 'stdin'), input)
      File.write(File.join(root, 'argv'), JSON.generate(ARGV))
      File.write(File.join(root, 'envkeys'), JSON.generate(ENV.keys))
      Dir.mktmpdir('worker-fixture-') do |directory|
        temporary = File.join(directory, 'file')
        File.write(temporary, 'created')
        abort 'fixture read failed' unless File.read(temporary) == 'created'
        File.write(temporary, 'updated')
        abort 'fixture write failed' unless File.read(temporary) == 'updated'
        File.unlink(temporary)
        File.write(File.join(root, 'worker-temp'), JSON.generate('TMPDIR' => ENV.fetch('TMPDIR'), 'directory' => directory))
      end
      File.write(File.join(ENV.fetch('TMPDIR'), 'retained.txt'), 'fixture content')
      File.write('worker-change.txt', 'worker')
      puts JSON.generate(type: 'thread.started', thread_id: 'fixture-session')
      puts 'progress'
      STDOUT.flush
      warn 'stderr progress'
      sleep 30 if mode == 'sleep'
      File.binwrite(path, mode == 'invalid' ? "\\xff" : 'Final worker response') unless mode == 'missing'
      exit(mode == 'failure' ? 7 : 0)
    RUBY
    File.chmod(0o755, @@fake_executable)
    @@fake_executable
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

  # Copy independent ordinary repositories; only read-only cases share the
  # immutable seed remote. No refs, alternates, hard links or worktrees are
  # shared with cases that mutate their remote. Fixture setup fails loudly
  # without inflating product assertion counts.
  def setup_git(*args, chdir: nil)
    stdout, stderr, status = Open3.capture3('git', *args, **(chdir ? { chdir: chdir } : {}))
    raise "Git fixture failed: #{stderr}" unless status.success?
    stdout.strip
  end

  def fixture(git: false, process: false, mutable_remote: false)
    Dir.mktmpdir('act-launch-') do |root|
      @root = File.realpath(root)
      @unit_workspace = nil
      @dep_ordinary = nil
      @data, @ordinary, @remote, @fake = %w[data ordinary remote.git codex].map { |name| File.join(@root, name) }
      @real_git, @real_process = git, process
      FileUtils.mkdir_p(File.join(@data, 'tasks'))
      if git
        seed = TestHelpers.git_seed
        FileUtils.cp_r(File.join(seed.fetch(:root), 'ordinary'), @ordinary)
        if mutable_remote
          FileUtils.cp_r(File.join(seed.fetch(:root), 'remote.git'), @remote)
          setup_git('remote', 'set-url', 'origin', @remote, chdir: @ordinary)
        else
          # Other tests read the seed remote; their Git refs and worktrees live
          # only in the independently copied ordinary checkout.
          @remote = File.join(seed.fetch(:root), 'remote.git')
        end
        @base = seed.fetch(:base)
      else
        FileUtils.mkdir_p([@ordinary, @remote])
        File.write(File.join(@ordinary, 'file.txt'), "base\n")
        @base = 'a' * 40
      end
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
        yield
      else
        @skill_capture = Open3.method(:capture3)
        AgentCodingTool::RepoInspector.stub(:new, @inspector) do
          AgentCodingTool::WorktreeManager.stub(:new, FakeWorktrees.new(@root, @ordinary, @remote, @base)) do
            Open3.stub(:capture3, method(:unit_capture)) { yield }
          end
        end
      end
    end
  end

  def unit_capture(*command, **options)
    if command == ['/usr/sbin/sysctl', '-n', 'kern.bootsessionuuid']
      return ['00000000-0000-0000-0000-000000000000', '', Status.new(true)]
    end
    if command[0].is_a?(Hash) && command[1, 2] == ['git', '--no-replace-objects']
      return @skill_capture.call(*command, **options)
    end
    if command.first.is_a?(Hash)
      env = command.shift
      allowed_options = [{ unsetenv_others: true },
                         { chdir: File.join(@root, 'worktrees', 'T', 'repo'), unsetenv_others: true }]
      raise 'unsafe preflight environment' unless (env.keys - %w[HOME PATH TMPDIR CODEX_HOME LANG LC_ALL]).empty? &&
                                                    allowed_options.include?(options)
      raise "unexpected executable: #{command.inspect}" unless command.shift == File.realpath(@fake)
      case command
      when ['--version'] then [@fake_version, '', Status.new(true)]
      when ['exec', '--help'] then [@fake_help, '', Status.new(true)]
      when ['login', '--help'] then ['status Show login status', '', Status.new(true)]
      when ['login', 'status'] then ['', @fake_auth, Status.new(!@fake_auth.empty?)]
      when ['sandbox', '--help'] then [@fake_sandbox_help, '', Status.new(true)]
      when ->(args) { args.include?('sandbox') && args.include?('act-probe') }
        prefix = command.take(command.index('sandbox'))
        home = env.fetch('CODEX_HOME')
        raise 'unsupported top-level sandbox flag or inherited configuration' unless
          prefix.length.even? && prefix.each_slice(2).all? { |flag, value| flag == '-c' && value && !value.empty? } &&
          File.directory?(home) && (File.stat(home).mode & 0o077).zero? && Dir.children(home).empty? &&
          home != ENV['CODEX_HOME'] && !home.start_with?("#{@root}/")
        @observed_sandbox_home = home
        raise 'legacy or unenforced sandbox invocation' unless
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
        [output, '', Status.new(true)]
      else raise "unexpected preflight: #{command.inspect}"
      end
    else
      raise "unexpected external command: #{command.inspect}" unless command.shift == 'git'
      if command == ['rev-parse', '--path-format=absolute', '--git-common-dir'] &&
         ([@ordinary, @dep_ordinary] + @store.load('T').fetch('snapshot', {}).values.map { |repo| repo.fetch('path') }).compact.include?(options[:chdir])
        admin = File.join(@root, options.fetch(:chdir) == @ordinary ? 'admin' : 'admin-dep')
        FileUtils.mkdir_p(admin)
        return [admin, '', Status.new(true)]
      end
      @unit_workspace ||= File.join(@root, 'worktrees', 'T', 'repo')
      raise 'unexpected Git working directory' unless options == { chdir: @unit_workspace }
      case command
      when ['remote', 'get-url', 'origin'] then [@remote, '', Status.new(true)]
      when ['rev-parse', 'HEAD'] then [@base, '', Status.new(true)]
      when ['status', '--porcelain', '--untracked-files=all'] then ['', '', Status.new(true)]
      when ['symbolic-ref', '-q', 'HEAD'] then ['refs/heads/act/T/attempt-1', '', Status.new(true)]
      else raise "unexpected Git operation: #{command.inspect}"
      end
    end
  end

  def launcher(real_sandbox_probe: false, **extra)
    instance = AgentCodingTool::Launcher.new(coordinator: @coordinator, data_root: @data, source_root: Dir.pwd,
                                           out: @out, err: @err, codex: @fake, **extra)
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
