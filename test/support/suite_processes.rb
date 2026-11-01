# frozen_string_literal: true

require_relative 'no_git_execution'

# The ordinary interpreter must install its stronger all-process prohibition
# before the selective guard is loaded. Only the fixed suite loader may do so.
module SuiteProcesses
  # One fixed suite launch retaining the stronger ordinary bootstrap order.
  class OrdinaryPermit < NoGitExecution::Permit
    # Binds the same full Ruby envelope, moving only the hash-reviewed stronger
    # boundary ahead of the selective guard in argv and inherited RUBYOPT.
    def initialize(**fields)
      script = File.realpath(File.join(__dir__, 'fixtures/suite_entry.rb'))
      boundary = File.realpath(File.join(__dir__, '../ordinary_execution.rb'))
      NoGitExecution.refuse!('ordinary suite loader') unless fields[:script] == script && fields.fetch(:preloads).key?(boundary)
      super
      argv = @argv.dup
      index = argv.index(boundary)
      NoGitExecution.refuse!('ordinary bootstrap') unless index && argv[index - 1] == '-r'
      argv.slice!(index - 1, 2)
      argv.insert(1, '-r', boundary)
      @argv = argv.map { |argument| argument.freeze }.freeze
      tokens = Shellwords.split(@environment.fetch('RUBYOPT'))
      tokens.delete("-r#{boundary}")
      @environment = @environment.merge('RUBYOPT' => Shellwords.join(["-r#{boundary}", *tokens])).freeze
      @effective_environment = ENV.to_h.merge(@environment).compact.freeze
      [@environment, @effective_environment].each do |values|
        values.each { |key, value| key.freeze; value.freeze if value.is_a?(String) }
      end
    end
  end
end
