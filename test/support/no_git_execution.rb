# frozen_string_literal: true

require "digest"
require "rbconfig"
require "shellwords"
require "json"

# Selective test preload. Denies all process creation except one reviewed Ruby
# script invocation per permit. TracePoint also denies cached native methods.
# This Ruby boundary is not an OS sandbox against native extensions or deliberate
# in-process removal of the guard. OrdinaryExecution remains strictly stronger.
module NoGitExecution
  class ProhibitedExecution < Exception; end
  GUARD = File.realpath(__FILE__).freeze
  COVERAGE = File.realpath(File.join(__dir__, "../feedback_coverage.rb")).freeze
  PROCESS_ENTRIES = %i[spawn system exec fork _fork daemon ` popen].freeze
  FILE_ENTRIES = %i[read binread readlines foreach write binwrite].freeze
  WATCHED_ENTRIES = (PROCESS_ENTRIES + FILE_ENTRIES + [:open]).to_h { |entry| [entry, true] }.freeze
  @audit = []

  # Returns detached audit records; mechanism names distinguish Ruby wrappers,
  # native C-entry observations and unavailable independent process tracing.
  def self.audit
    @audit.map(&:dup)
  end

  # Reports scope truth. No independent OS process-creation tracer is installed.
  def self.independent_audit
    { "status" => "UNAVAILABLE", "reason" => "no qualified independent OS execution tracer installed" }
  end

  # Records a bounded diagnostic without child argv/environment secrets. Returns
  # nil; the internal audit is not independent proof of OS process creation.
  def self.record(operation, decision, mechanism)
    row = { "pid" => Process.pid, "operation" => operation.to_s,
      "decision" => decision, "mechanism" => mechanism }
    @audit << row
    if ENV['ACT_EXECUTION_AUDIT']
      File.open(File.join(ENV.fetch('ACT_EXECUTION_AUDIT'), "#{Process.pid}.jsonl"), 'a') do |file|
        file.puts(JSON.generate(row))
      end
    end
    nil
  end

  # Raises outside StandardError so product refusal handlers cannot swallow an
  # undeclared execution as a plausible Git failure. Always runs before native entry.
  def self.refuse!(operation, mechanism = "ruby-wrapper")
    record(operation, "DENY", mechanism)
    raise ProhibitedExecution, "zero-Git boundary prohibits undeclared execution: #{operation}"
  end

  # Immutable reviewed launch identity. No bare Ruby executable or arbitrary -e
  # program is authorized. Hashes must come from the caller's reviewed manifest.
  class Permit
    attr_reader :argv, :environment, :options, :operation

    # Builds one exact script/argv/preload/environment/options identity. Hash or
    # bootstrap mismatches or lost/replaced inherited coverage context raise
    # ProhibitedExecution; filesystem errors propagate.
    def initialize(script:, sha256:, arguments: [], preloads: {}, environment: {}, options: {}, operation: :spawn)
      NoGitExecution.refuse!("permit operation") unless %i[spawn system].include?(operation)
      @operation = operation
      @files = { File.realpath(RbConfig.ruby) => Digest::SHA256.file(RbConfig.ruby).hexdigest,
                 GUARD => Digest::SHA256.file(GUARD).hexdigest }
      script = File.realpath(script)
      NoGitExecution.refuse!("script hash") unless Digest::SHA256.file(script).hexdigest == sha256
      @files[script] = sha256
      paths = preloads.map do |path, digest|
        absolute = File.realpath(path)
        NoGitExecution.refuse!("preload hash") unless Digest::SHA256.file(absolute).hexdigest == digest
        @files[absolute] = digest
        absolute
      end
      inherited = Shellwords.split(ENV.fetch("RUBYOPT", ""))
      reviewed = [GUARD, *paths].flat_map { |path| ["-r#{path}", "-r#{path.delete_suffix('.rb')}"] }
      NoGitExecution.refuse!("unreviewed inherited RUBYOPT") unless (inherited - reviewed).empty?
      NoGitExecution.refuse!("invalid argv") unless arguments.all? { |argument| argument.is_a?(String) }
      NoGitExecution.refuse!("process options") unless (options.keys - %i[chdir pgroup unsetenv_others close_others]).empty?
      NoGitExecution.refuse!("environment types") unless environment.all? { |key, value|
        key.is_a?(String) && (value.nil? || value.is_a?(String)) }
      NoGitExecution.refuse!("bootstrap override") if environment.key?("RUBYOPT")
      @argv = [File.realpath(RbConfig.ruby), "-r", GUARD, *paths.flat_map { |path| ["-r", path] }, "--", script, *arguments]
      @environment = environment.merge("RUBYOPT" => Shellwords.join(["-r#{GUARD}", *paths.map { |path| "-r#{path}" }]))
      @effective_environment = (options[:unsetenv_others] ? {} : ENV.to_h).merge(@environment).compact
      context = ENV["ACT_COVERAGE_CONTEXT"]
      if context && @effective_environment["ACT_COVERAGE_CONTEXT"] != context
        NoGitExecution.refuse!("coverage context override/removal")
      end
      if @effective_environment["ACT_COVERAGE_CONTEXT"] && !paths.include?(COVERAGE)
        NoGitExecution.refuse!("missing coverage bootstrap")
      end
      @options = options.dup
      @cwd = Dir.pwd
      @owner_thread = Thread.current
      [@argv, @environment, @options, @effective_environment, @files].each do |value|
        value.each { |*items| items.each { |item| item.freeze if item.is_a?(String) } }
        value.freeze
      end
      @used = false
    end

    # Consumes the permit only for the exact Process.spawn envelope. Open3 may
    # add live IO pipes for streams; no extra process option or environment change
    # is allowed. Changed files, cwd or ambient environment fail before spawn.
    def consume!(command, options)
      environment = command.first.is_a?(Hash) ? command.first : {}
      arguments = command.drop(command.first.is_a?(Hash) ? 1 : 0)
      extra = options.reject { |key, _value| @options.key?(key) }
      valid_pipes = extra.all? { |key, value| %i[in out err].include?(key) && value.is_a?(IO) && !value.closed? }
      effective = (@options[:unsetenv_others] ? {} : ENV.to_h).merge(environment).compact
      NoGitExecution.refuse!("permit mismatch/reuse") unless Thread.current.equal?(@owner_thread) && !@used && arguments == @argv &&
        environment == @environment && options.select { |key, _value| @options.key?(key) } == @options &&
        valid_pipes && effective == @effective_environment && Dir.pwd == @cwd &&
        @files.all? { |path, digest| File.realpath(path) == path && Digest::SHA256.file(path).hexdigest == digest }
      @used = true
      true
    end

    # Returns whether the one allowed native spawn was consumed.
    def used?
      @used
    end
  end

  # One native ENOENT probe, never a command allowlist. Only a fixed absent leaf
  # in a canonical private directory is eligible; the existing Permit still binds
  # argv, environment, cwd, options, thread, source identities and single use.
  class MissingExecutablePermit < Permit
    # Takes a private directory, reviewed preloads and optional pgroup: true. Refuses
    # existing leaves (including dangling symlinks), directory drift or other
    # options. Native spawn errors remain native; no executable fallback exists.
    def initialize(directory:, preloads: {}, options: {}, operation: :spawn)
      NoGitExecution.refuse!("missing executable options") unless options.empty? || options == { pgroup: true } ||
        (operation == :spawn && options.keys.sort == %i[chdir pgroup] && options[:pgroup] == true && File.realpath(options[:chdir]) == options[:chdir]) ||
        (operation == :system && options.keys == [:chdir] && File.realpath(options[:chdir]).start_with?(directory + "/"))
      NoGitExecution.refuse!("missing executable directory") unless directory.is_a?(String) &&
        File.realpath(directory) == directory
      @directory = directory.dup.freeze
      @directory_identity = File.stat(@directory).then { |stat| [stat.dev, stat.ino] }
      @executable = File.join(@directory, "no-git-missing-executable").freeze
      absent!
      super(script: GUARD, sha256: Digest::SHA256.file(GUARD).hexdigest, preloads: preloads, options: options, operation: operation)
      # Two argv entries force direct execution even when the path contains spaces.
      @argv = [@executable, "--missing-executable-probe".freeze].freeze
    end

    # Rechecks absence immediately before the inherited exact-envelope check.
    # Replacement files, symlinks and directory identities fail before native entry.
    def consume!(command, options)
      absent!
      super
    end

    private

    # Returns true only for an absent leaf in the original private directory.
    # Filesystem failures propagate; this Ruby check is not an OS race sandbox.
    def absent!
      stat = File.stat(@directory)
      NoGitExecution.refuse!("missing executable directory drift") unless File.realpath(@directory) == @directory &&
        stat.directory? && stat.uid == Process.uid && (stat.mode & 0o077).zero? &&
        [stat.dev, stat.ino] == @directory_identity
      NoGitExecution.refuse!("missing executable exists") if File.exist?(@executable) || File.symlink?(@executable)
      true
    end
  end

  # One block-form owner fork bound to an exact reviewed source line and bytes.
  # No executable permission is implied; all descendant spawn guards remain live.
  class ForkPermit
    # Binds callsite, issuing process/thread, cwd and effective environment.
    # Invalid source identity raises ProhibitedExecution before native entry.
    def initialize(source:, sha256:, line:)
      @source = File.realpath(source).freeze
      @digest, @line = sha256.dup.freeze, line
      NoGitExecution.refuse!("fork source") unless Digest::SHA256.file(@source).hexdigest == @digest && line.is_a?(Integer)
      @pid, @thread, @cwd = Process.pid, Thread.current, Dir.pwd.freeze
      @environment = ENV.to_h.to_h { |key, value| [key.freeze, value.freeze] }.freeze
      @used = false
    end

    # Consumes exactly once at the bound block-form callsite; drift refuses.
    def consume!(location)
      NoGitExecution.refuse!("fork permit mismatch/reuse") unless !@used && Process.pid == @pid &&
        Thread.current.equal?(@thread) && Dir.pwd == @cwd && ENV.to_h == @environment &&
        location.absolute_path == @source && location.lineno == @line &&
        File.realpath(@source) == @source && Digest::SHA256.file(@source).hexdigest == @digest
      @used = true
    end

    # Reports actual consumption, never assumed OS success.
    def used?
      @used
    end
  end

  # Scopes one exact owner fork; nested, invalid and unused capabilities refuse.
  def self.with_fork_permit(permit)
    refuse!("nested/invalid fork permit") unless permit.is_a?(ForkPermit) && !Thread.current[:no_git_fork]
    Thread.current[:no_git_fork] = permit
    result = yield
    refuse!("unconsumed fork permit") unless permit.used?
    result
  ensure
    Thread.current[:no_git_fork] = nil
  end

  # Preserves native fork identity/status and performs child-only instrumentation
  # before user code. Non-block and cached native calls remain prohibited.
  module OwnerFork
    # Runs a permitted block in a real child; returns native child PID to parent.
    def fork(*arguments, &block)
      permit = Thread.current[:no_git_fork]
      NoGitExecution.refuse!("fork without block permit") unless permit && block && arguments.empty?
      permit.consume!(caller_locations(1, 1).first)
      Thread.current[:no_git_native] = [self, :fork]
      super do
        Thread.current[:no_git_native] = nil
        Thread.current[:no_git_fork] = nil
        Thread.current[:no_git_permit] = nil
        Thread.current[:no_git_owner_pid] = Process.pid
        FeedbackCoverage.after_fork if ENV["ACT_COVERAGE_CONTEXT"]
        block.call
      end
    ensure
      Thread.current[:no_git_native] = nil
    end

    # Completes fresh owner evidence before native exit!, retaining its status.
    # Other interpreters retain the ordinary exit! semantics and missing-evidence
    # detection; this is not permission to omit active child results.
    def exit!(*arguments)
      if Thread.current[:no_git_owner_pid] == Process.pid && ENV["ACT_COVERAGE_CONTEXT"]
        FeedbackCoverage.finish
      end
      super
    end
  end

  # Installs a one-shot, thread-local permit around the caller's real transport.
  # Returns the transport's original result; missing consumption raises and all
  # exceptions propagate. Nested permits are forbidden.
  def self.with_permit(permit)
    refuse!("nested/invalid permit") unless permit.is_a?(Permit) && !Thread.current[:no_git_permit]
    Thread.current[:no_git_permit] = permit
    result = yield
    refuse!("unconsumed permit") unless permit.used?
    result
  ensure
    Thread.current[:no_git_permit] = nil
  end

  # Issues a native-entry slot only after checking the full launch identity.
  # Cached original methods cannot issue this slot and are refused by TRACE.
  module Spawn
    # Delegates approved Process.spawn unchanged, retaining native status/errors.
    # Missing or mismatched permits raise before any process exists.
    def spawn(*command, **options)
      options = command.pop.merge(options) if command.last.is_a?(Hash)
      permit = Thread.current[:no_git_permit]
      NoGitExecution.refuse!("spawn without permit") unless permit && permit.operation == :spawn
      permit.consume!(command, options)
      NoGitExecution.record(permit.argv.first, "BOUND", "exact-executable-envelope")
      Thread.current[:no_git_native] = [self, :spawn]
      super(*command, **options)
    ensure
      Thread.current[:no_git_native] = nil
    end
  end

  # Exact native system boundary for reviewed validators. Native boolean, $? and
  # spawn errors remain Ruby's own; no shell/interpreter-only permit is issued.
  module System
    # Consumes one system-specific full-envelope permit or refuses before entry.
    def system(*command, **options)
      permit = Thread.current[:no_git_permit]
      NoGitExecution.refuse!("system without permit") unless permit && permit.operation == :system
      permit.consume!(command, options)
      NoGitExecution.record(permit.argv.first, "BOUND", "exact-executable-envelope")
      Thread.current[:no_git_native] = [self, :system]
      super(*command, **options)
    ensure
      Thread.current[:no_git_native] = nil
    end
  end

  # Covers implicit pipe readers while retaining actual ordinary filesystem IO.
  module FileReads
    FILE_ENTRIES.each do |operation|
      define_method(operation) do |path, *arguments, **options, &block|
        NoGitExecution.refuse!("pipe #{operation}") if !path.is_a?(String) || path.start_with?("|")
        Thread.current[:no_git_file] = [self, operation]
        begin
          super(path, *arguments, **options, &block)
        ensure
          Thread.current[:no_git_file] = nil
        end
      end
    end
  end

  # Kernel.open alone interprets leading pipes; File.open is ordinary file IO.
  module FileOpen
    # Opens a checked file path; pipe and opaque coercion requests raise first.
    def open(path, *arguments, **options, &block)
      NoGitExecution.refuse!("pipe open") if !path.is_a?(String) || path.start_with?("|")
      Thread.current[:no_git_file] = [self, :open]
      super
    ensure
      Thread.current[:no_git_file] = nil
    end
  end

  # Ordinary interpreters already prohibit every native entry, including permitted
  # children. Keep that stronger boundary authoritative and allow their Ruby-only
  # observation stubs; the selective wrappers belong to native selections only.
  unless defined?(OrdinaryExecution)
    Process.singleton_class.prepend(OwnerFork)
    Kernel.prepend(OwnerFork)
    Kernel.singleton_class.prepend(OwnerFork)
    Process.singleton_class.prepend(Spawn)
    Kernel.prepend(System)
    Kernel.singleton_class.prepend(System)
    Kernel.prepend(Spawn)
    Kernel.singleton_class.prepend(Spawn)
    IO.singleton_class.prepend(FileReads)
    Kernel.prepend(FileOpen)
    Kernel.singleton_class.prepend(FileOpen)
  end

  # Native observation closes cached-original and Open3 fallback paths. Permits
  # authorize exactly one checked Process.spawn C entry, never Kernel shell forms.
  TRACE = TracePoint.new(:c_call) do |event|
    operation = event.method_id
    next unless WATCHED_ENTRIES[operation]
    receiver = event.self
    kernel = event.defined_class == Kernel || receiver.equal?(Kernel)
    process = receiver.equal?(Process) || (receiver.is_a?(Module) && receiver.name == "PTY")
    io = receiver.is_a?(Class) && receiver <= IO
    if PROCESS_ENTRIES.include?(operation) && (kernel || process || (io && operation == :popen))
      slot = Thread.current[:no_git_native]
      NoGitExecution.refuse!(operation, "ruby-c-entry") unless slot == [receiver, operation]
      Thread.current[:no_git_native] = nil
      NoGitExecution.record(operation, "ALLOW", "ruby-c-entry-exact-permit")
    elsif (io && FILE_ENTRIES.include?(operation)) || (kernel && operation == :open)
      NoGitExecution.refuse!("captured pipe-capable #{operation}", "ruby-c-entry") unless
        Thread.current[:no_git_file] == [receiver, operation]
      Thread.current[:no_git_file] = nil
    end
  end
  TRACE.enable unless defined?(OrdinaryExecution)
end
