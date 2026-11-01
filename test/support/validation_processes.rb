# frozen_string_literal: true

require_relative 'child_processes'
require 'minitest/mock'

# Exact adapter for the delivery fixtures' non-Git validator. Production retains
# concurrent pipe drains, timeout, output parsing, receipts and real child status.
module ValidationProcesses
  # Returns baseline files for the fixed validator, plus caller-owned files.
  # Reads only the reviewed source; missing files raise filesystem errors.
  def validation_files(files)
    files.merge('fixture-validation.rb' => File.binread(File.join(ChildProcesses::FIXTURES, 'validation_worker.rb')))
  end

  # Returns a literal external validator command; no inline code or shell syntax.
  def validation_command(output = '2 tests, 3 assertions, 0 failures, 0 errors, 0 skips', code = 0)
    ['ruby', 'fixture-validation.rb', output, code.to_s]
  end

  # Yields with only the exact validator adapted to a hash-bound Ruby child.
  # Other invocations retain their original path and the execution guard. A
  # changed tracked validator refuses before spawn; exceptions/status propagate.
  def with_validation_processes
    original = Open3.method(:popen3)
    adapter = lambda do |*command, **options, &block|
      environment = command.first.is_a?(Hash) ? command.shift : {}
      if command.first(2) == ['ruby', 'fixture-validation.rb']
        source = File.join(options.fetch(:chdir), 'fixture-validation.rb')
        raise GitContract::UnexpectedObservation, 'changed validation fixture' unless
          [4, 5].include?(command.length) && Digest::SHA256.file(source).hexdigest == ChildProcesses::HASHES.fetch('validation_worker')
        environment = environment.merge('ACT_COVERAGE_CONTEXT' => ENV['ACT_COVERAGE_CONTEXT']) if ENV['ACT_COVERAGE_CONTEXT']
        approval = ChildProcesses.permit('validation_worker', arguments: command.drop(2), environment: environment, options: options)
        NoGitExecution.with_permit(approval) do
          original.call(approval.environment, *approval.argv, **approval.options, &block)
        end
      else
        original.call(environment, *command, **options, &block)
      end
    end
    Open3.stub(:popen3, adapter) { yield }
  end
end
