# frozen_string_literal: true

require_relative "child_processes"
require_relative "../../lib/agent_coding_tool/native_pilot_executor"

# Declared deterministic sandbox/inference boundary for supervisor tests. This
# never attempts a native sandbox and never falls back after a sandbox refusal.
# Production fork/accounting/IO/deadline paths remain unchanged and no Git runs.
module NativePilotProcesses
  SOURCE = File.expand_path("../../lib/agent_coding_tool/native_pilot_executor.rb", __dir__)

  # Scopes the harmless boundary to the invoking thread (inherited by fork).
  # Unscoped calls retain the repository's process prohibitions unchanged.
  def self.with_boundary
    previous = Thread.current[:native_pilot_boundary]
    Thread.current[:native_pilot_boundary] = true
    yield
  ensure
    Thread.current[:native_pilot_boundary] = previous
  end

  # Models only the unavailable boot observation in this disposable sandbox.
  # Real host qualification never loads this module and still requires sysctl.
  module BootObservation
    def boot
      Thread.current[:native_pilot_boundary] ? "deterministic-offline-boot" : super
    end
  end

  # Permits only the production supervisor's block-form fork from its inspected
  # source; the test wrapper itself has an exact single-use callsite permit.
  module Execution
    def fork(*arguments, &block)
      return super unless Thread.current[:native_pilot_boundary]
      location = caller_locations(1, 1).first
      raise "foreign pilot fork" unless location.absolute_path == SOURCE && arguments.empty? && block
      approval = NoGitExecution::ForkPermit.new(source: __FILE__, sha256: Digest::SHA256.file(__FILE__).hexdigest, line: __LINE__ + 2)
      NoGitExecution.with_fork_permit(approval) do
        super(*arguments, &block)
      end
    end

    # Replaces only a fixed sandbox invocation with a reviewed harmless process.
    # Exact original argv/cwd/env still pass production admission beforehand.
    def spawn(environment, *argv, **options)
      return super unless Thread.current[:native_pilot_boundary] && argv.first == "/usr/bin/sandbox-exec"
      raise "foreign sandbox request" unless argv[1] == "-f" && File.file?(argv[2]) && File.realpath(argv[3]) == File.realpath(RbConfig.ruby)
      pipes = options.select { |key, _| %i[in out err].include?(key) }
      settings = options.reject { |key, _| pipes.key?(key) }
      script = argv.fetch(4)
      named = %w[manager_inference native_pilot_worker checkpoint_validator].find { |name| script == File.join(ChildProcesses::FIXTURES, "#{name}.rb") }
      mode = named || "native_pilot_process"
      arguments = named ? argv.drop(5) : [script]
      # Only reviewed fixture descendants receive instrumentation. Keep explicit
      # deletion/replacement visible to the permit's unchanged coverage checks.
      context = ENV["ACT_COVERAGE_CONTEXT"]
      environment = { "ACT_COVERAGE_CONTEXT" => context }.merge(environment) if context
      approval = ChildProcesses.permit(mode, arguments: arguments, environment: environment, options: settings)
      NoGitExecution.with_permit(approval) { super(approval.environment, *approval.argv, **approval.options, **pipes) }
    end
  end
end
# Ordinary interpreters need no native substitutions. A prepended Ruby wrapper
# would let a captured spawn delegate through a later observation stub instead
# of reaching the prohibited C entry, invalidating the fallback negative control.
Process.singleton_class.prepend(NativePilotProcesses::Execution) unless defined?(OrdinaryExecution)

AgentCodingTool::NativePilotExecutor.singleton_class.prepend(NativePilotProcesses::BootObservation)
