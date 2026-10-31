# frozen_string_literal: true

require "digest"
require "rbconfig"
require "shellwords"

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
    @audit << { "pid" => Process.pid, "operation" => operation.to_s,
      "decision" => decision, "mechanism" => mechanism }
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
    attr_reader :argv, :environment, :options

    # Builds one exact script/argv/preload/environment/options identity. Hash or
    # bootstrap mismatches or lost/replaced inherited coverage context raise
    # ProhibitedExecution; filesystem errors propagate.
    def initialize(script:, sha256:, arguments: [], preloads: {}, environment: {}, options: {})
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
      NoGitExecution.refuse!("spawn without permit") unless permit
      permit.consume!(command, options)
      Thread.current[:no_git_native] = [self, :spawn]
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

  Process.singleton_class.prepend(Spawn)
  Kernel.prepend(Spawn)
  Kernel.singleton_class.prepend(Spawn)
  IO.singleton_class.prepend(FileReads)
  Kernel.prepend(FileOpen)
  Kernel.singleton_class.prepend(FileOpen)

  # Native observation closes cached-original and Open3 fallback paths. Permits
  # authorize exactly one checked Process.spawn C entry, never Kernel shell forms.
  TRACE = TracePoint.new(:c_call) do |event|
    receiver, operation = event.self, event.method_id
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
  TRACE.enable
end
