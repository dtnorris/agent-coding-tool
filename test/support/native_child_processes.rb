# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "../git_contract/observations"

# Native suites own real children. Ordinary suites keep their exact single-use
# permits and zero-Git guard; no guard is installed or disabled on this path.
module ChildProcesses
  # Captures one fixed repository fixture with native status and bounded lifetime.
  # Unknown fixture names and process/time failures raise.
  def self.capture(name, arguments: [], environment: {}, endpoint: nil, seconds: 2, input: "")
    raise ArgumentError, "unsupported native endpoint" if endpoint
    raise ArgumentError, "unknown native fixture" unless %w[status manual_worker process_probe].include?(name)
    script = File.join(__dir__, "fixtures", "#{name}.rb")
    GitContract::Native.new(seconds: seconds).capture3(environment, RbConfig.ruby, script, *arguments, stdin_data: input)
  end
end
