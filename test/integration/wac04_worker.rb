# frozen_string_literal: true

# Host recipe's declared inference fake and fixed independent validator. Neither
# mode evaluates candidate code; all writes are under the fresh synthetic root.
require "json"
mode, root, *arguments = ARGV
workspace = File.realpath(Dir.pwd)
abort "foreign fixture workspace" unless workspace.start_with?(File.join(root, "worktrees", "T") + "/")
case mode
when "worker"
  abort "unexpected inference entry" unless arguments.first == "exec"
  final = arguments[arguments.index("--output-last-message") + 1]
  abort "foreign final path" unless (final.start_with?(File.join(root, "case", "data-runs", "T") + "/") || final == File.join(root, "worker-home", "final.txt")) && File.basename(final) == "final.txt"
  STDIN.read
  File.binwrite("worker-change.txt", "worker\n")
  puts JSON.generate("type" => "thread.started", "thread_id" => "worker-native-fixture")
  File.write(final, "Worker self-report; inspect independent evidence.")
when "validate"
  abort "candidate differs" unless File.binread("worker-change.txt") == "worker\n"
  STDOUT.binmode.write("checked\x00\xff".b)
else abort "unknown fixture role"
end
