# frozen_string_literal: true

require 'minitest/mock'

# Only external boundaries are replaced in decision tests. Coordinator lifecycle,
# prompt rendering, locks, trust checks and durable evidence use production code.
# `git: true` and `process: true` select the genuine integration paths explicitly.
module LauncherSupport
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

  def write_fake(mode = 'success', auth: 'Logged in using ChatGPT', help: true)
    @fake_auth = auth
    @fake_help = help ? '--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model' : '--sandbox'
    raise 'real preflight requires default fake help/auth' if @real_git && (!help || auth != 'Logged in using ChatGPT')
    File.symlink(fake_executable, @fake) unless File.exist?(@fake)
    File.write(File.join(@root, 'fake-settings.json'), JSON.generate('mode' => mode))
  end

  # Build once, then copy independent repositories (no shared mutable Git refs,
  # object alternates, hard links or worktrees). Fixture operations aren't product
  # assertions; fail loudly on a setup error without inflating assertion counts.
  def git_seed
    return @@git_seed if defined?(@@git_seed)

    @@git_seed = Dir.mktmpdir('act-launch-seed-')
    Minitest.after_run { FileUtils.remove_entry(@@git_seed) }
    checkout = File.join(@@git_seed, 'ordinary')
    remote = File.join(@@git_seed, 'remote.git')
    setup_git('init', '--initial-branch=main', checkout)
    setup_git('config', 'user.email', 'fixture@example.test', chdir: checkout)
    setup_git('config', 'user.name', 'Fixture', chdir: checkout)
    File.write(File.join(checkout, 'file.txt'), "base\n")
    setup_git('add', 'file.txt', chdir: checkout)
    setup_git('commit', '-m', 'fixture', chdir: checkout)
    setup_git('clone', '--bare', checkout, remote)
    @@git_seed
  end

  def setup_git(*args, chdir: nil)
    stdout, stderr, status = Open3.capture3('git', *args, **(chdir ? { chdir: chdir } : {}))
    raise "Git fixture failed: #{stderr}" unless status.success?
    stdout.strip
  end

  def fixture(git: false, process: false)
    Dir.mktmpdir('act-launch-') do |root|
      @root = File.realpath(root)
      @data, @ordinary, @remote, @fake = %w[data ordinary remote.git codex].map { |name| File.join(@root, name) }
      @real_git, @real_process = git, process
      FileUtils.mkdir_p(File.join(@data, 'tasks'))
      if git
        seed = git_seed
        FileUtils.cp_r(File.join(seed, 'ordinary'), @ordinary)
        FileUtils.cp_r(File.join(seed, 'remote.git'), @remote)
        setup_git('remote', 'add', 'origin', @remote, chdir: @ordinary)
        @base = setup_git('rev-parse', 'HEAD', chdir: @ordinary)
      else
        FileUtils.mkdir_p([@ordinary, @remote])
        File.write(File.join(@ordinary, 'file.txt'), "base\n")
        @base = 'a' * 40
      end
      File.write(File.join(@data, 'config.yml'), YAML.dump('repo_root' => @root))
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
        AgentCodingTool::RepoInspector.stub(:new, @inspector) do
          Open3.stub(:capture3, method(:unit_capture)) { yield }
        end
      end
    end
  end

  def unit_capture(*command, **options)
    if command.first.is_a?(Hash)
      env = command.shift
      raise 'unsafe preflight environment' unless (env.keys - %w[HOME PATH TMPDIR CODEX_HOME LANG LC_ALL]).empty? && options == { unsetenv_others: true }
      raise "unexpected executable: #{command.inspect}" unless command.shift == File.realpath(@fake)
      case command
      when ['exec', '--help'] then [@fake_help, '', Status.new(true)]
      when ['login', '--help'] then ['status Show login status', '', Status.new(true)]
      when ['login', 'status'] then ['', @fake_auth, Status.new(!@fake_auth.empty?)]
      else raise "unexpected preflight: #{command.inspect}"
      end
    else
      raise "unexpected external command: #{command.inspect}" unless command.shift == 'git'
      case command.first
      when 'clone'
        raise "unexpected clone: #{command.inspect}" unless command == ['clone', '--no-checkout', '--no-local', '--single-branch', '--branch', 'main', '--', @remote, command.last]
        raise 'unexpected clone options' unless options.empty?
        @unit_workspace = command.last
        FileUtils.mkdir_p(command.last)
        FileUtils.cp(File.join(@ordinary, 'file.txt'), command.last)
        ['', '', Status.new(true)]
      else
        raise 'unexpected Git working directory' unless options == { chdir: @unit_workspace }
        case command
        when ['checkout', '--detach', @base] then ['', '', Status.new(true)]
        when ['remote', 'get-url', 'origin'] then [@remote, '', Status.new(true)]
        when ['rev-parse', 'HEAD'] then [@base, '', Status.new(true)]
        when ['status', '--porcelain', '--untracked-files=all'] then ['', '', Status.new(true)]
        when ['symbolic-ref', '-q', 'HEAD'] then ['', '', Status.new(false)]
        else raise "unexpected Git operation: #{command.inspect}"
        end
      end
    end
  end

  def launcher(**extra)
    instance = AgentCodingTool::Launcher.new(coordinator: @coordinator, data_root: @data, source_root: Dir.pwd,
                                           out: @out, err: @err, codex: @fake, **extra)
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
