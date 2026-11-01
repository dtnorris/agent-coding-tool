# frozen_string_literal: true

require "json"
root = ENV.fetch('ACT_RETRY_ROOT')
mode = File.file?(File.join(root, "mode")) ? File.read(File.join(root, "mode")) : "clean"
case ARGV
when ["--version"] then puts "codex-cli 0.162.1"
when ["exec", "--help"] then puts "--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model"
when ["login", "--help"] then puts "status"
when ["login", "status"] then puts "Logged in using ChatGPT"
when ["sandbox", "--help"] then puts "Usage: codex sandbox [OPTIONS] [COMMAND]..."
else
  if ARGV.include?("sandbox")
    roots = [Dir.pwd] + JSON.parse(ARGV.find { |arg| arg.start_with?("sandbox_workspace_write.writable_roots=") }.split("=", 2).last)
    ARGV.drop(ARGV.index("act-probe") + 1).each do |target|
      allowed = mode == "leaky" || roots.any? { |root| target.start_with?(root + "/") }
      File.write(target, "breach") if allowed
      puts(allowed ? "1" : "0")
    end
  else
    abort "unexpected command" unless ARGV.first == "exec"
    consumed = STDIN.binmode.read
    capture = File.join(root, "tst20-capture-prompt")
    if File.file?(capture)
      # Only this journey opts in; corrupt the observation, never the input.
      recorded = consumed.dup
      recorded.setbyte(0, recorded.getbyte(0) ^ 1) if File.read(capture) == "corrupt"
      File.binwrite(File.join(root, "tst20-consumed-stdin"), recorded)
      File.write(File.join(root, "tst20-worker.json"), JSON.generate("pid" => Process.pid, "workspace" => Dir.pwd))
    end
    puts JSON.generate("type" => "thread.started", "thread_id" => "fixture-session")
    File.write(ARGV.fetch(ARGV.index("--output-last-message") + 1), mode == "invalid" ? "" : "No candidate. Human judgment required.\n")
    exit(mode == "nonzero" ? 7 : 0)
  end
end
