# frozen_string_literal: true

# Runs the public evidence entry point with one fixed optional flock observer.
# All lock results, stream bytes, EOF and exit status remain native.
mode = ARGV.shift
case mode
when 'plain'
when 'controller_loss'
  trap('USR1') { exit 86 }
when 'help_no_dotenv'
  require_relative '../../../lib/agent_coding_tool'
  result = AgentCodingTool::CLI.run(['help'])
  abort 'unexpected dotenv loading' if defined?(Dotenv)
  exit result
when 'flock'
  TracePoint.new(:c_return) do |event|
    next unless event.method_id == :flock
    STDERR.puts(event.return_value == false ? 'LOCK_CONTENDED' : 'LOCK_ACQUIRED')
    STDERR.flush
  end.enable
else
  abort 'unknown evidence fixture mode'
end
require_relative '../tunnel_processes'
require_relative '../checkpoint_processes'
require_relative '../fixture_tunnel'
TunnelProcesses.install
abort 'unexpected fixture command' unless %w[evidence checkpoint share].include?(ARGV.first)
load File.expand_path('../../../bin/agent-coding-tool', __dir__)
