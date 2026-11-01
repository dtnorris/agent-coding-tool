# frozen_string_literal: true

# Fixed native transport byte/status/timeout controls; no product or descendants.
case ARGV.fetch(0)
when 'bytes'
  STDOUT.binmode.write("\0\xff".b)
  STDERR.binmode.write("\xfe".b)
  exit 7
when 'signal' then Process.kill('TERM', Process.pid)
when 'sleep' then sleep 10
else abort 'unknown native observer mode'
end
