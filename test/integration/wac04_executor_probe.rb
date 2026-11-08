# frozen_string_literal: true

# Harmless process/filesystem probes for the native pilot. Never evaluates a
# candidate, uses credentials, sends data to a service or signals another process.
require "json"
require "socket"
mode, root, role = ARGV
case mode
when "cwd"
  # Capture each operation independently: process exit zero is not cwd success.
  operations = {}
  { "getcwd" => -> { Dir.pwd }, "realpath" => -> { File.realpath(".") },
    "stat" => -> { File.stat(".").directory? } }.each do |name, operation|
    begin
      operations[name] = { "value" => operation.call }
    rescue SystemCallError => error
      operations[name] = { "class" => error.class.name, "errno" => error.errno, "message" => error.message }
    end
  end
  puts JSON.generate(operations)
when "read-only"
  begin
    File.write(root, "forbidden")
    abort "read-only tool policy allowed a write"
  rescue Errno::EPERM, Errno::EACCES, Errno::EROFS
    puts "READ-ONLY DENIED"
  end
when "sleep"
  sleep 30
when "binary"
  STDOUT.binmode.write("checked\x00\xff".b)
  STDERR.binmode.write("diagnostic\x00\xfe".b)
  exit 7
when "flood"
  STDOUT.write("z" * (4 * 1024 * 1024 + 1))
when "boundary"
  denied = []
  { "control_read" => -> { File.binread(File.join(root, "secret")) },
    "control_write" => -> { File.write(File.join(root, "secret"), "forbidden") },
    "source_write" => -> { File.open(__FILE__, "a") { |file| file.write("") } },
    "foreign_write" => -> { File.write(File.join(root, "scratch", "forbidden"), "forbidden") },
    "fork" => -> { child = Process.fork { exit! 0 }; Process.waitpid(child) },
    "foreign_signal" => -> { Process.kill(0, Process.ppid) } }.each do |name, operation|
    begin
      operation.call
    rescue Errno::EPERM, Errno::EACCES
      denied << name
    end
  end
  alias_path = File.join(ENV.fetch("HOME"), "control-alias")
  File.symlink(File.join(root, "secret"), alias_path)
  begin
    File.write(alias_path, "forbidden")
  rescue Errno::EPERM, Errno::EACCES
    denied << "alias_write"
  ensure
    File.unlink(alias_path)
  end
  File.write(File.join(ENV.fetch("HOME"), "runtime-history-probe"), "allowed")
  candidate = File.join(ARGV.fetch(3), "probe.txt")
  if role == "worker"
    File.write(candidate, "allowed")
  else
    begin
      File.write(candidate, "forbidden")
    rescue Errno::EPERM, Errno::EACCES
      denied << "candidate_write"
    end
  end
  expected = %w[control_read control_write source_write foreign_write fork foreign_signal alias_write]
  expected << "candidate_write" unless role == "worker"
  abort "boundary failure: #{denied.inspect}" unless denied.sort == expected.sort
  puts "BOUNDARY PASS #{role}"
  # An exec attempt is harmless even on a broken sandbox. Missing this trailing
  # denial marker prevents qualification if the unexpected exec succeeds.
  begin
    Process.exec("/usr/bin/true")
  rescue Errno::EPERM, Errno::EACCES
    puts "EXEC DENIED"
  end
else
  abort "unknown fixed probe"
end
