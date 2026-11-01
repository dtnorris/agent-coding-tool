# frozen_string_literal: true

# Owned non-Git writer: explicit ready/release and an independent finite lease.
path, lease = ARGV
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(lease)
File.write(path, "external work")
STDOUT.puts("ready")
STDOUT.flush
loop do
  remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
  exit 75 unless remaining.positive?
  exit(STDIN.read(1) == "R" ? 0 : 76) if IO.select([STDIN], nil, nil, [remaining, 0.025].min)
  File.write(path, "external work")
end
