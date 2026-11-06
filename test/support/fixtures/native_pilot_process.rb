# frozen_string_literal: true

# Fixed harmless byte/status/expiry subprocess. No filesystem, networking,
# candidate execution, live inference or descendant dispatch is supported.
case ARGV.fetch(0)
when "binary"
  STDOUT.binmode.write("checked\x00\xff".b)
  STDERR.binmode.write("diagnostic\x00\xfe".b)
  exit 7
when "sleep"
  sleep 30
when "emit"
  STDOUT.write("z" * (2 * 1024 * 1024 + 1))
when "empty"
  exit 0
else
  abort "unknown fixed harmless process"
end
