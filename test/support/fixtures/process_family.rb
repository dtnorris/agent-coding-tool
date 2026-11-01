# frozen_string_literal: true

require_relative '../child_processes'

# Finite owned parent/child topology for the launcher's kernel observer. Both
# generations retain exact permits and preloads; no Git or fork is permitted.
ChildProcesses.popen('manual_worker', arguments: [ARGV.fetch(0), '5']) do |input, output, error, waiter|
  raise 'family child readiness timeout' unless IO.select([output], nil, nil, 2)
  raise 'family child not ready' unless output.gets == "ready\n"
  STDOUT.puts(waiter.pid)
  STDOUT.flush
  raise 'family release timeout' unless IO.select([STDIN], nil, nil, 4)
  raise 'family release missing' unless STDIN.read(1) == 'R'
  input.write('R')
  input.close
  raise "family child failed: #{error.read}" unless waiter.value.success?
end
