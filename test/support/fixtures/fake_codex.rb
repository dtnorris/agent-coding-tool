#!/usr/bin/env ruby
# frozen_string_literal: true

# A bounded Codex CLI stand-in used only by the guarded native evidence tests.
arguments = ARGV
final_index = arguments.index("--output-last-message")
abort "missing final path" unless final_index && arguments[final_index + 1]
final_path = arguments[final_index + 1]
$stdout.binmode
$stderr.binmode
$stdout.write("fake codex stdout\x80".b)
$stderr.write("fake codex stderr\x00".b)
$stdout.flush
$stderr.flush

pidfile = arguments.find { |argument| argument.start_with?("--fixture-pidfile=") }
if pidfile
  File.write(pidfile.delete_prefix("--fixture-pidfile="), Process.pid.to_s)
  loop { sleep 0.1 }
end

if arguments.include?("--fixture-oversize")
  File.open(final_path, "wb") { |file| file.write("f".b * (4 * 1024 * 1024 + 1)) }
else
  File.binwrite(final_path, "fake final\x00\xff".b)
end

exit_argument = arguments.find { |argument| argument.start_with?("--fixture-exit=") }
exit(exit_argument ? Integer(exit_argument.delete_prefix("--fixture-exit=")) : 0)
