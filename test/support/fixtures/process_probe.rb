# frozen_string_literal: true

# Fixed probes for byte/status/signal/guard propagation at a real process seam.
case ARGV.fetch(0)
when "icebox_bytes"
  STDOUT.binmode.write("text\n".b + [0, 255].pack("C*"))
  STDERR.binmode.write([254, 0].pack("C*"))
  exit 7
when "binary"
  STDOUT.binmode.write(STDIN.binmode.read.reverse)
  STDERR.binmode.write("\x00\xfe".b)
  exit 7
when "signal" then Process.kill("TERM", Process.pid)
when "strip"
  ENV.delete("RUBYOPT")
  ENV["PATH"] = "/untrusted"
  Process.spawn("/usr/bin/git", "--version")
when "wrapper" then system("/bin/sh", "-c", "git --version")
else raise "unknown fixed probe"
end
