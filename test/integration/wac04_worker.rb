# frozen_string_literal: true

# Host recipe's declared inference fake and fixed independent validator. Neither
# mode evaluates candidate code; all writes are under the fresh synthetic root.
require "json"
mode, root, *arguments = ARGV
workspace = File.realpath(Dir.pwd)
abort "foreign fixture workspace" unless workspace.start_with?(File.join(root, "worktrees", "T") + "/")
case mode
when /\Aworker(?:-.*)?\z/
  abort "unexpected inference entry" unless arguments.first == "exec"
  final = arguments[arguments.index("--output-last-message") + 1]
  artifact = File.join(workspace, "worker-change.txt")
  abort "foreign final path" unless final == artifact || final == File.join(root, "worker-home", "final.txt")
  STDIN.read
  # This is the declared inference/CLI-writer boundary, not a host answer.
  final_message = case mode
                  when "worker-empty" then ""
                  when "worker-no-newline" then "worker"
                  when "worker-wrong" then "other\n"
                  when "worker-oversized" then "z" * 65_537
                  else "worker\n"
                  end
  sleep 30 if mode == "worker-timeout"
  STDERR.write("ERROR codex_core::tools::router: failed to spawn code-mode host: EPERM\n") if mode == "worker-tool-error"
  STDERR.binmode.write("diagnostic\x00\xfe".b) if mode == "worker-binary-diagnostic"
  puts JSON.generate("type" => "thread.started", "thread_id" => "worker-native-fixture")
  puts JSON.generate("type" => "turn.started")
  puts JSON.generate("type" => "item.completed", "item" => { "type" => "agent_message", "text" => final_message })
  puts JSON.generate("type" => "item.completed", "item" => { "type" => "command_execution" }) if mode == "worker-tool"
  puts JSON.generate("type" => "turn.completed")
  if mode == "worker-symlink" || mode == "worker-hardlink"
    target = File.join(root, "worker-link-target")
    File.binwrite(target, final_message)
    mode == "worker-symlink" ? File.symlink(target, final) : File.link(target, final)
  elsif mode != "worker-missing"
    File.binwrite(final, mode == "worker-mismatch" ? "changed" : final_message)
  end
  exit 7 if mode == "worker-status"
when "validate"
  path = File.join(workspace, "worker-change.txt")
  File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
    stat = file.stat
    actual = File.lstat(path)
    abort "unsafe candidate" unless stat.file? && stat.nlink == 1 && stat.size == 7 &&
      [stat.dev, stat.ino] == [actual.dev, actual.ino] && File.realpath(path) == path
    abort "candidate differs" unless file.read(8) == "worker\n"
  end
  STDOUT.binmode.write("checked\x00\xff".b)
else abort "unknown fixture role"
end
