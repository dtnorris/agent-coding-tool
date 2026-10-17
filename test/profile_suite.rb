# frozen_string_literal: true

require "json"
require "open3"
require "fileutils"

# Optional passive observer, intentionally excluded from the default test glob.
# No child output, argv, environment, paths or exception messages enter labels.
# Run from the repository root: bundle exec ruby -Ilib:test test/profile_suite.rb
# --output /absolute/evidence.json -- --seed 808 --verbose
module SuiteProfile
  GIT_COMMANDS = %w[init config add commit clone remote rev-parse status ls-remote
                    cat-file worktree symbolic-ref branch switch show diff apply
                    read-tree write-tree ls-files update-index check-ignore push
                    fetch merge-base log rev-list reset checkout clean].freeze
  PHASES = %i[before_setup setup after_setup before_teardown teardown after_teardown].freeze
  PROCESSES = %i[spawn wait wait2 waitpid waitpid2 waitall].freeze
  FILE_OPERATIONS = %i[cp cp_r remove_entry remove_entry_secure rm_rf].freeze

  # Returns monotonic seconds without consulting child output or wall-clock time.
  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Classifies whitelisted executable/subcommand tokens; arbitrary arguments,
  # shell strings and paths never enter the returned fixed label.
  def self.command_label(command)
    arguments = command.drop(command.first.is_a?(Hash) ? 1 : 0)
    executable = arguments.first
    return "other" unless executable.is_a?(String)

    name = File.basename(executable)
    if name == "git"
      subcommand = arguments.drop(1).find { |argument| GIT_COMMANDS.include?(argument) }
      if subcommand == "cat-file" && arguments.include?("blob")
        return "git.cat-file.coding_blob" if arguments.last.is_a?(String) && arguments.last.end_with?(":skills/karpathy-manning-dtnorris-guidelines/SKILL.md")
        return "git.cat-file.planning_blob" if arguments.last.is_a?(String) && arguments.last.end_with?(":skills/agentic-task-planning/SKILL.md")
      end
      return "git.#{subcommand || 'other'}"
    end
    return "ruby" if name.match?(/\Aruby(?:[0-9.]*)\z/)
    return name if %w[codex sysctl ps lsof].include?(name)

    "other"
  end

  # Returns a fixed operation label for a selected trace event, or nil. Only
  # capture3's local argv is inspected, never copied to the resulting evidence.
  def self.label(event)
    receiver, name = event.self, event.method_id
    if receiver.equal?(Open3) && name == :capture3
      boundary = event.path.end_with?("/open3.rb") ? "open3" : "stub"
      variables = event.binding
      arguments = if variables.local_variable_defined?(:cmd)
        variables.local_variable_get(:cmd)
      elsif variables.local_variable_defined?(:args)
        variables.local_variable_get(:args)
      else
        []
      end
      return "capture.#{boundary}.#{command_label(arguments)}"
    end
    return "process.#{name}" if receiver.equal?(Process) && PROCESSES.include?(name)
    return "process.spawn" if name == :spawn && event.defined_class == Kernel
    return "thread.join" if name == :join && receiver.is_a?(Thread)
    return "files.#{name}" if receiver.equal?(FileUtils) && FILE_OPERATIONS.include?(name)
    return "file.rename" if receiver.equal?(File) && name == :rename
    return "io.fsync.#{event.event == :c_call ? 'native' : 'ruby'}" if name == :fsync && receiver.is_a?(IO)
    return "kernel.sleep" if name == :sleep && event.defined_class == Kernel
    return "phase.#{name}" if @test_instance.equal?(receiver) && PHASES.include?(name)

    nil
  end

  # Installs one passive trace in this process only. Methods, stubs, child argv,
  # RUBYOPT, return bytes/status and exception propagation remain untouched.
  # Same-thread self time subtracts observed nested calls; thread totals overlap.
  def self.install!
    raise "profile already installed" if @trace

    @operations, @tests = {}, []
    @started, @cpu = clock, Process.times
    @trace = TracePoint.new(:call, :return, :c_call, :c_return, :raise) do |event|
      stack = Thread.current[:suite_profile_stack] ||= []
      if event.event == :raise
        stack.last[:raises_within] += 1 unless stack.empty?
      elsif event.event == :call || event.event == :c_call
        if event.method_id == :run && event.path.end_with?("/minitest/test.rb")
          @test_instance = event.self
          @current_test = "#{@test_instance.class.name}##{@test_instance.name}"
          @test_started = clock
        end
        operation = label(event)
        if operation
          stack << { receiver: event.self, method: event.method_id, operation: operation,
                     test: @current_test, start: clock, nested: 0.0, raises_within: 0 }
        end
      else
        if stack.last && stack.last[:receiver].equal?(event.self) && stack.last[:method] == event.method_id
          frame = stack.pop
          elapsed = clock - frame.fetch(:start)
          stack.last[:nested] += elapsed unless stack.empty?
          key = [frame.fetch(:test), frame.fetch(:operation)]
          row = @operations[key] ||= { calls: 0, inclusive_seconds: 0.0, same_thread_self_seconds: 0.0, raises_within: 0 }
          row[:calls] += 1
          row[:inclusive_seconds] += elapsed
          row[:same_thread_self_seconds] += elapsed - frame.fetch(:nested)
          row[:raises_within] += frame.fetch(:raises_within)
        end
        if event.method_id == :run && event.path.end_with?("/minitest/test.rb") && @test_instance.equal?(event.self)
          @tests << { test: @current_test,
                      file: File.basename(@test_instance.method(@test_instance.name).source_location.first),
                      seconds: clock - @test_started, assertions: @test_instance.assertions,
                      failures: @test_instance.failures.length, skipped: @test_instance.skipped? }
          @current_test = @test_instance = nil
        end
      end
    end
    @trace.enable
  end

  # Returns JSON-safe inclusive measurements and process/child CPU separately.
  # Raised-event counts include internally rescued exceptions, not just failures.
  # Child internal operations/startup and injected runner calls are unobserved.
  def self.snapshot
    cpu = Process.times
    { schema: "act-suite-profile/v1", wall_seconds: clock - @started,
      cpu_seconds: { user: cpu.utime - @cpu.utime, system: cpu.stime - @cpu.stime,
                     reaped_child_user: cpu.cutime - @cpu.cutime, reaped_child_system: cpu.cstime - @cpu.cstime },
      tests: @tests, operations: @operations.map { |(test, operation), row| row.merge(test: test, operation: operation) } }
  end
end

if $PROGRAM_NAME == __FILE__
  require "optparse"
  require "minitest/autorun"
  output = nil
  OptionParser.new do |parser|
    parser.on("--output PATH", "Write main-process measurements (required)") { |path| output = path }
  end.order!
  abort "--output PATH is required" unless output
  # Exclusive creation fails before tests rather than overwriting old evidence.
  evidence = File.open(output, File::WRONLY | File::CREAT | File::EXCL, 0o600)
  SuiteProfile.install!
  Minitest.after_run { evidence.write(JSON.pretty_generate(SuiteProfile.snapshot) + "\n"); evidence.close }
  Dir.glob(File.join(__dir__, "**/*_test.rb")).sort.each { |path| require path }
end
