# frozen_string_literal: true

require_relative 'no_git_execution'
require 'json'
require 'open3'
require 'shellwords'

# Candidate-only composition of the two operator-reviewed native boundaries.
# No product switch or general native executable permission is introduced.
module TunnelProcesses
  ROOT = File.realpath(File.join(__dir__, '../..')).freeze
  SOURCE = File.join(ROOT, 'lib/agent_coding_tool/evidence_tunnel.rb').freeze
  SOURCE_HASH = 'd51db1eea7ad331fcf9eb320fd3fd5570edeb8684a5b1df3adad69cbea193d9b'
  CLIENT = File.join(__dir__, 'fixtures/tunnel_client.rb').freeze
  CLIENT_HASH = 'a9c25a6b9394df6677dfb6f1fc803e07ef93f86b5ebd225afde72b81e9ef5d12'
  ENTRY = File.join(ROOT, 'bin/agent-coding-tool').freeze
  ENTRY_HASH = '35cd5470b2bddf672a1c43763ac6aece470517c5adc909b3dd9d34c2693ca309'

  # Exact-envelope native capability, with process/source/callsite and file-byte
  # bindings in addition to Permit's thread/cwd/environment/single-use checks.
  # Construction is restricted to the two finite envelopes below.
  class NativePermit < NoGitExecution::Permit
    # Accepts only fixed ps observations or a clean env launch containing a
    # separately validated guarded Ruby serve permit. Invalid envelopes refuse.
    def initialize(argv:, environment:, options:, source:, line:, files:, adapter: nil)
      ps = argv == ['/bin/ps', '-axo', 'comm='] || argv == ['/bin/ps', '-axo', 'pid=,pgid=,stat=']
      clean = adapter && argv == ['/usr/bin/env', '-i', *adapter.environment.compact.map { |key, value| "#{key}=#{value}" }, *adapter.argv]
      NoGitExecution.refuse!('native envelope') unless (ps && source == SOURCE && options == { unsetenv_others: true }) ||
        (clean && source == File.realpath($PROGRAM_NAME) && files[source] == CLIENT_HASH && environment.empty? && options.empty?)
      NoGitExecution.refuse!('native source bytes') unless files[source] == (ps ? SOURCE_HASH : CLIENT_HASH) &&
        Digest::SHA256.file(source).hexdigest == files[source]
      if ps
        NoGitExecution.refuse!('inventory environment') unless environment == %w[PATH HOME TMPDIR LANG].to_h { |key| [key, ENV[key]] }.compact
        expected_line = TunnelProcesses.site(SOURCE, SOURCE_HASH, "\"/bin/ps\", \"-axo\", \"#{argv.last}\"")
        NoGitExecution.refuse!('native site') unless line == expected_line
      else
        entry_index = adapter.argv.index('--')
        tail = adapter.argv.drop(entry_index + 1)
        NoGitExecution.refuse!('native serve child') unless tail.length == 5 &&
          tail.take(4) == [ENTRY, 'evidence', 'serve', '--session'] &&
          adapter.options == { unsetenv_others: true } &&
          (adapter.environment.keys - %w[PATH HOME TMPDIR LANG RUBYOPT ACT_COVERAGE_CONTEXT ACT_EXECUTION_AUDIT]).empty?
        NoGitExecution.refuse!('native client site') unless line == TunnelProcesses.site(CLIENT, CLIENT_HASH, 'TunnelProcesses.adapter(config_path:')
      end
      super(script: NoGitExecution::GUARD, sha256: Digest::SHA256.file(NoGitExecution::GUARD).hexdigest,
        preloads: TunnelProcesses.preloads)
      @argv = argv.map { |value| value.dup.freeze }.freeze
      @environment = environment.to_h { |key, value| [key.dup.freeze, value&.dup&.freeze] }.freeze
      @options = options.dup.freeze
      @effective_environment = (options[:unsetenv_others] ? {} : ENV.to_h).merge(environment).compact.freeze
      files = files.merge(adapter.instance_variable_get(:@files)) if clean
      @files = @files.merge(files).merge(File.realpath(argv.first) => Digest::SHA256.file(argv.first).hexdigest)
        .to_h { |path, digest| [path.dup.freeze, digest.dup.freeze] }.freeze
      @source, @line, @pid = source.dup.freeze, line, Process.pid
      @context_path = ENV['ACT_COVERAGE_CONTEXT']
      @context_bytes = File.binread(@context_path) if @context_path
    end

    # Consumes one native entry only from the bound call chain. Context-file
    # replacement, issuing-process drift and any inherited envelope drift refuse.
    def consume!(command, options)
      NoGitExecution.refuse!('native source/context') unless Process.pid == @pid &&
        caller_locations.any? { |location| location.absolute_path == @source && location.lineno == @line } &&
        ENV['ACT_COVERAGE_CONTEXT'] == @context_path && (!@context_path || File.binread(@context_path) == @context_bytes)
      super
    end
  end

  # Returns reviewed coverage and bundler bootstraps, never credentials.
  def self.preloads
    paths = [NoGitExecution::COVERAGE].select { ENV['ACT_COVERAGE_CONTEXT'] }
    bundler = $LOADED_FEATURES.find { |path| path.end_with?('/bundler/setup.rb') }
    paths << bundler if bundler
    paths.to_h { |path| [File.realpath(path), Digest::SHA256.file(path).hexdigest] }
  end

  # Validates pinned source bytes before locating a unique reviewed native site.
  # Ambiguous or changed source refuses; no line-number guessing is permitted.
  def self.site(source, digest, text)
    NoGitExecution.refuse!('tunnel source') unless File.realpath(source) == source && Digest::SHA256.file(source).hexdigest == digest
    contents = File.readlines(source)
    lines = contents.each_index.select { |index| contents[index].include?(text) }
    NoGitExecution.refuse!('ambiguous tunnel site') unless lines.length == 1
    lines.first + 1
  end

  # Installs adapters only in the reviewed public CLI fixture interpreter.
  def self.install
    require File.join(ROOT, 'lib/agent_coding_tool/evidence_tunnel')
    AgentCodingTool::EvidenceTunnel.prepend(Owner)
    Process.singleton_class.prepend(ClientSpawn)
    Open3.singleton_class.prepend(Inventory)
  end

  # Scopes production inventory/cleanup/fork/client activity without replacing
  # its results, controller, readiness, signals or lifecycle implementation.
  module Owner
    # Preserves the real owner run and grants only its pinned block-form fork.
    def run
      line = TunnelProcesses.site(SOURCE, SOURCE_HASH, 'owner = fork do')
      permit = NoGitExecution::ForkPermit.new(source: SOURCE, sha256: SOURCE_HASH, line: line)
      Thread.current[:act_tunnel] = self
      # Early public refusals legitimately happen before the fork is reached.
      Thread.current[:no_git_fork] = permit
      super
    ensure
      Thread.current[:no_git_fork] = nil
      Thread.current[:act_tunnel] = nil
    end
  end

  # Binds only actual production ps sites to single-use native permits.
  module Inventory
    # Preserves native output/error/status, including failed observations.
    def capture3(*command, **options)
      return super unless Thread.current[:act_tunnel] && command[1] == '/bin/ps'
      format = command[3]
      text = "\"/bin/ps\", \"-axo\", \"#{format}\""
      line = TunnelProcesses.site(SOURCE, SOURCE_HASH, text)
      environment = %w[PATH HOME TMPDIR LANG].to_h { |key| [key, ENV[key]] }.compact
      permit = NativePermit.new(argv: ['/bin/ps', '-axo', format], environment: environment,
        options: { unsetenv_others: true }, source: SOURCE, line: line, files: { SOURCE => SOURCE_HASH })
      NoGitExecution.with_permit(permit) { super }
    end
  end

  # Replaces only the reviewed private Ruby client's shebang bootstrap with an
  # exact guarded Ruby invocation. The product launch envelope is checked first.
  module ClientSpawn
    # Validates source/config/session binding; retains all production IO/group
    # options and genuine spawn failures. Unknown launches use the denying guard.
    def spawn(*command, **options)
      tunnel = Thread.current[:act_tunnel]
      return super unless tunnel && command[1] == tunnel.instance_variable_get(:@client)
      client, session = command[1], tunnel.instance_variable_get(:@path)
      line = TunnelProcesses.site(SOURCE, SOURCE_HASH, 'pid = @spawn.call(environment, @client')
      NoGitExecution.refuse!('client callsite') unless caller_locations.any? { |location| location.absolute_path == SOURCE && location.lineno == line }
      NoGitExecution.refuse!('client bytes') unless Digest::SHA256.file(client).hexdigest == CLIENT_HASH
      expected = { unsetenv_others: true, pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL, chdir: session }
      environment = %w[PATH HOME TMPDIR LANG].to_h { |key| [key, ENV[key]] }.compact
      environment['CONTROL_PLANE_API_KEY'] = command.first['CONTROL_PLANE_API_KEY']
      NoGitExecution.refuse!('client envelope') unless command == [environment, client, 'run', '--config', File.join(session, 'tunnel.json')] && options == expected
      context = ENV['ACT_COVERAGE_CONTEXT']
      environment['ACT_COVERAGE_CONTEXT'] = context if context
      environment['ACT_EXECUTION_AUDIT'] = ENV['ACT_EXECUTION_AUDIT'] if ENV['ACT_EXECUTION_AUDIT']
      environment['ACT_TEST_TUNNEL_SUPPORT'] = File.realpath(__FILE__)
      environment['ACT_TEST_TUNNEL_CONFIG_SHA256'] = Digest::SHA256.file(File.join(session, 'tunnel.json')).hexdigest
      # Open file streams are the only permitted additions to the Ruby envelope.
      permit = NoGitExecution::Permit.new(script: client, sha256: CLIENT_HASH,
        arguments: ['run', '--config', File.join(session, 'tunnel.json')], preloads: TunnelProcesses.preloads,
        environment: environment, options: { unsetenv_others: true, pgroup: true, chdir: session })
      File.open(File::NULL, 'r+') do |null|
        NoGitExecution.with_permit(permit) do
          super(permit.environment, *permit.argv, **permit.options, in: null, out: null, err: null)
        end
      end
    end
  end

  # Launches the exact configured ACT evidence serve child via real env -i.
  # Only reviewed instrumentation is added after proving the unmodified product
  # command. Client credential variables are absent from the effective child env.
  def self.adapter(config_path:, command:)
    session = File.dirname(config_path)
    NoGitExecution.refuse!('config/session') unless File.realpath(session) == session &&
      config_path == File.join(session, 'tunnel.json') && File.stat(config_path).uid == Process.uid &&
      (File.stat(config_path).mode & 0o077).zero?
    environment = %w[PATH HOME TMPDIR LANG].to_h { |key| [key, ENV[key]] }.compact
    expected = ['/usr/bin/env', '-i', *environment.map { |key, value| "#{key}=#{value}" }, RbConfig.ruby, ENTRY, 'evidence', 'serve', '--session', session]
    NoGitExecution.refuse!('configured command') unless command == expected &&
      Digest::SHA256.file(config_path).hexdigest == ENV.fetch('ACT_TEST_TUNNEL_CONFIG_SHA256') &&
      Shellwords.split(JSON.parse(File.binread(config_path)).fetch('mcp').fetch('commands').first.fetch('command')) == expected
    environment['ACT_COVERAGE_CONTEXT'] = ENV.fetch('ACT_COVERAGE_CONTEXT') if ENV['ACT_COVERAGE_CONTEXT']
    environment['ACT_EXECUTION_AUDIT'] = ENV['ACT_EXECUTION_AUDIT'] if ENV['ACT_EXECUTION_AUDIT']
    adapter = NoGitExecution::Permit.new(script: ENTRY, sha256: ENTRY_HASH,
      arguments: ['evidence', 'serve', '--session', session], preloads: preloads.merge(
        File.join(__dir__, 'fixtures/tunnel_adapter_bootstrap.rb') => Digest::SHA256.file(File.join(__dir__, 'fixtures/tunnel_adapter_bootstrap.rb')).hexdigest),
      environment: environment, options: { unsetenv_others: true })
    argv = ['/usr/bin/env', '-i', *adapter.environment.compact.map { |key, value| "#{key}=#{value}" }, *adapter.argv]
    line = site(CLIENT, CLIENT_HASH, 'TunnelProcesses.adapter(config_path:')
    # Bind the exact private copy as well as the canonical reviewed bytes.
    source = File.realpath($PROGRAM_NAME)
    NoGitExecution.refuse!('private client identity') unless Digest::SHA256.file(source).hexdigest == CLIENT_HASH
    permit = NativePermit.new(argv: argv, environment: {}, options: {}, source: source, line: line,
      files: { source => CLIENT_HASH, CLIENT => CLIENT_HASH, config_path => Digest::SHA256.file(config_path).hexdigest, ENTRY => ENTRY_HASH }, adapter: adapter)
    NoGitExecution.with_permit(permit) { Open3.popen2(*argv) }
  end
end
