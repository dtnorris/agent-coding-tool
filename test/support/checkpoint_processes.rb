# frozen_string_literal: true

require_relative 'child_processes'
# Exact execution seam for checkpoint validators; used in warm and cold fixtures.
# Every other system request remains prohibited by the original guard.
module CheckpointProcesses
  # Returns the fixed script and literal mode arguments, never inline Ruby.
  def gate_command(*arguments)
    [RbConfig.ruby, File.join(ChildProcesses::FIXTURES, 'checkpoint_validator.rb'), *arguments]
  end

  # Intercepts only this reviewed validator, then calls native Kernel.system.
  # The real status remains in the invoking thread; exceptions are not rescued.
  module Execution
    def system(*command, **options)
      prefix = [RbConfig.ruby, File.join(ChildProcesses::FIXTURES, 'checkpoint_validator.rb')]
      if options.keys == [:chdir] && command == [File.join(File.dirname(options[:chdir]), 'no-git-missing-executable'), '--missing-executable-probe']
        preloads = {}
        if defined?(Bundler)
          bundler = File.realpath($LOADED_FEATURES.find { |path| path.end_with?('/bundler/setup.rb') })
          preloads[bundler] = Digest::SHA256.file(bundler).hexdigest
        end
        preloads[NoGitExecution::COVERAGE] = Digest::SHA256.file(NoGitExecution::COVERAGE).hexdigest if ENV['ACT_COVERAGE_CONTEXT']
        approval = NoGitExecution::MissingExecutablePermit.new(directory: File.dirname(options[:chdir]),
          options: options, preloads: preloads, operation: :system)
        return NoGitExecution.with_permit(approval) { super(approval.environment, *approval.argv, **approval.options) }
      end
      return super unless command.take(2) == prefix
      approval = ChildProcesses.permit('checkpoint_validator', arguments: command.drop(2), options: options, operation: :system)
      NoGitExecution.with_permit(approval) { super(approval.environment, *approval.argv, **approval.options) }
    end
  end
end
Kernel.prepend(CheckpointProcesses::Execution)
Kernel.singleton_class.prepend(CheckpointProcesses::Execution)
