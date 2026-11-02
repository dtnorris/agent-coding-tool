# frozen_string_literal: true

# A real validator cannot finish until its real waiter has returned nil once.
# The parent releases it at that observation; a lost handoff expires finitely.
output, code, release = ARGV
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
until File.file?(release)
  abort 'validator release lease expired' if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
  sleep 0.001
end
STDOUT.puts(output)
exit Integer(code)
