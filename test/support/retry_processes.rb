# frozen_string_literal: true

require_relative 'child_processes'
require_relative 'memory_git/session'
# Finite capability/lsof responses and guarded real worker process boundaries.
# Public parsing, worktree creation, lifecycle and reports stay production code.
module RetryProcesses
  # Raw observations of the reviewed retry worker's five static capabilities.
  # Worker execution and sandbox effects still cross the real process boundary.
  PREFLIGHT_OUTPUTS = {
    ['--version'] => "codex-cli 0.162.1\n",
    ['exec', '--help'] => "--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model\n",
    ['login', '--help'] => "status\n",
    ['login', 'status'] => "Logged in using ChatGPT\n",
    ['sandbox', '--help'] => "Usage: codex sandbox [OPTIONS] [COMMAND]...\n"
  }.freeze

  # Returns fresh raw streams/exit facts for one declared capability request.
  # Changed source, environment or options refuse before any child can start.
  def self.preflight(environment, arguments, options)
    ENV.fetch('ACT_RETRY_ROOT') # Preserve the real adapter's required case binding.
    expected = %w[HOME PATH TMPDIR CODEX_HOME LANG LC_ALL].to_h { |key| [key, ENV[key]] }.compact
    source = File.join(ChildProcesses::FIXTURES, 'retry_worker.rb')
    NoGitExecution.refuse!('changed retry preflight envelope') unless environment == expected &&
      options == { unsetenv_others: true } &&
      Digest::SHA256.file(source).hexdigest == ChildProcesses::HASHES.fetch('retry_worker')
    AgentCodingTool::CommandResult.new(stdout: PREFLIGHT_OUTPUTS.fetch(arguments).b,
      stderr: ''.b, exitstatus: 0).to_ary
  end

  # Adapts one exact requested worker envelope; stream handles stay real IO.
  def self.spawn_worker(environment, *argv, **options)
    root = ENV.fetch('ACT_RETRY_ROOT')
    NoGitExecution.refuse!('unknown retry worker') unless File.realpath(argv.shift) == File.join(ChildProcesses::FIXTURES, 'retry_worker.rb')
    pipes = options.select { |key, _value| %i[in out err].include?(key) }
    settings = options.reject { |key, _value| pipes.key?(key) }
    forwarded = environment.merge('ACT_RETRY_ROOT' => root)
    forwarded['ACT_COVERAGE_CONTEXT'] = ENV['ACT_COVERAGE_CONTEXT'] if ENV['ACT_COVERAGE_CONTEXT']
    approval = ChildProcesses.permit('retry_worker', arguments: argv, environment: forwarded, options: settings)
    NoGitExecution.with_permit(approval) { Process.spawn(approval.environment, *approval.argv, **approval.options, **pipes) }
  end

  # Uses real pipe drains/status for the exact fake executable's preflight calls.
  module Transport
    def call(argv, cwd: nil, env: {}, input: '', timeout: nil, **options)
      root = ENV['ACT_RETRY_ROOT']
      if ENV['ACT_RETRY_HARD_RESET'] == '1' && root && argv == ['git', 'rev-parse', '--git-dir'] &&
          cwd == File.join(root, 'missing-repository') && !File.exist?(cwd)
        File.stat(cwd) # Preserve native chdir's genuine ENOENT before RPC.
      end
      return super unless root && argv.first == File.join(ChildProcesses::FIXTURES, 'retry_worker.rb')
      forwarded = env.merge('ACT_RETRY_ROOT' => root)
      forwarded['ACT_COVERAGE_CONTEXT'] = ENV['ACT_COVERAGE_CONTEXT'] if ENV['ACT_COVERAGE_CONTEXT']
      approval = ChildProcesses.permit('retry_worker', arguments: argv.drop(1), environment: forwarded,
        options: options.reject { |key, _value| key == :binmode }.merge(cwd ? { chdir: cwd } : {}))
      NoGitExecution.with_permit(approval) { super(approval.argv, cwd: cwd, env: approval.environment, input: input, timeout: timeout, **options) }
    end
  end

  # The original finite lsof executable returned 1. Keep that declared external
  # response exact; PID/group/host checks remain native production operations.
  module Capture
    def capture3(*argv, **options)
      if argv.first.is_a?(Hash) && argv[1] == File.join(ChildProcesses::FIXTURES, 'retry_worker.rb')
        environment, _executable, *arguments = argv
        if PREFLIGHT_OUTPUTS.key?(arguments)
          return RetryProcesses.preflight(environment, arguments, options)
        end
        forwarded = environment.merge('ACT_RETRY_ROOT' => ENV.fetch('ACT_RETRY_ROOT'))
        forwarded['ACT_COVERAGE_CONTEXT'] = ENV['ACT_COVERAGE_CONTEXT'] if ENV['ACT_COVERAGE_CONTEXT']
        approval = ChildProcesses.permit('retry_worker', arguments: arguments, environment: forwarded, options: options)
        return NoGitExecution.with_permit(approval) { super(approval.environment, *approval.argv, **approval.options) }
      end
      if argv.first == 'lsof' && argv.take(4) == %w[lsof -n -P +D] && argv.length == 5 && options.empty?
        return AgentCodingTool::CommandResult.new(stdout: ''.b, stderr: ''.b, exitstatus: 1).to_ary
      end
      super
    end
  end

  # Injects only the supported production spawner boundary for the real worker.
  module Launcher
    def initialize(**options)
      super(**{ spawner: RetryProcesses.method(:spawn_worker) }.merge(options))
    end
  end
end
AgentCodingTool::Launcher.prepend(RetryProcesses::Launcher)
AgentCodingTool::NativeCommandTransport.prepend(RetryProcesses::Transport)
Open3.singleton_class.prepend(RetryProcesses::Capture)
