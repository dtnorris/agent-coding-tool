# frozen_string_literal: true

require "json"

# Reviewed finite non-Git child. Every waiting mode has a five-second lease;
# unknown modes raise. The inherited guard protects any descendant execution.
STDIN.binmode
STDOUT.binmode
STDERR.binmode
case ARGV.fetch(0)
when "binary"
  STDOUT.write(STDIN.read.reverse)
  STDERR.write("\xfe\x00".b)
  exit 7
when "environment"
  puts JSON.generate("cwd" => Dir.pwd, "value" => ENV["TRANSPORT_VALUE"],
    "removed" => ENV["TRANSPORT_REMOVED"], "pid" => Process.pid,
    "group" => Process.getpgrp, "guard" => defined?(NoGitExecution) == "constant")
when "signal"
  Process.kill("TERM", Process.pid)
when "reject_input"
  STDIN.close
  STDERR.write("rejected\x00\xff".b)
  exit 3
when "lease"
  STDOUT.write("ready\x00\xff".b)
  STDERR.write("waiting\xfe".b)
  STDOUT.flush
  STDERR.flush
  # Publish readiness only after its complete PID is readable by the parent.
  File.write("#{ARGV.fetch(1)}.pending", Process.pid.to_s)
  File.rename("#{ARGV.fetch(1)}.pending", ARGV.fetch(1))
  sleep 5
  exit 99
else
  raise "unknown command transport fixture mode"
end
