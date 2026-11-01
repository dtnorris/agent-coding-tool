# frozen_string_literal: true

# Optional kernel-lock observer precedes the real public CLI. It reports actual
# flock returns, never substitutes a lock or a successful command result.
if ARGV.first == '--trace-lock'
  ARGV.shift
  TracePoint.new(:c_return) do |event|
    next unless event.method_id == :flock
    STDERR.puts(event.return_value == false ? 'LOCK_CONTENDED' : 'LOCK_ACQUIRED')
    STDERR.flush
  end.enable
end
ARGV.unshift('evidence')
load File.expand_path('../../../bin/agent-coding-tool', __dir__)
