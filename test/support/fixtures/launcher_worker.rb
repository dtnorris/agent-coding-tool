#!/usr/bin/env ruby
require_relative '../no_git_execution'
require 'json'
require 'tmpdir'
require 'stringio'
require 'shellwords'
if ARGV == ['--version']
  puts 'codex-cli 0.162.1'
  exit
end
if ARGV.include?('sandbox')
  prefix = ARGV.take(ARGV.index('sandbox'))
  abort 'unsupported top-level sandbox flag' unless prefix.length.even? &&
    prefix.each_slice(2).all? { |flag, value| flag == '-c' && value && !value.empty? }
  if ARGV.include?('--help')
    puts 'Usage: codex sandbox [OPTIONS] [COMMAND]...'
    exit
  end
  home = ENV['CODEX_HOME']
  abort 'sandbox inherited user configuration' unless home && File.directory?(home) &&
    (File.stat(home).mode & 0o077).zero? && Dir.children(home).empty? &&
    home != File.join(ENV.fetch('HOME', ''), '.codex')
  abort 'legacy sandbox invocation' unless ARGV.include?('sandbox_mode="workspace-write"') &&
    ARGV[ARGV.index('sandbox') + 1] == '--' && !ARGV.include?('--full-auto')
  targets = ARGV.drop(ARGV.index('act-probe') + 1)
  settings_root = Dir.pwd
  settings_root = File.dirname(settings_root) until File.file?(File.join(settings_root, 'fake-settings.json')) || settings_root == File.dirname(settings_root)
  settings = JSON.parse(File.read(File.join(settings_root, 'fake-settings.json')))
  extra_roots = JSON.parse(ARGV.find { |arg| arg.start_with?('sandbox_workspace_write.writable_roots=') }.split('=', 2).last)
  targets.each do |target|
    if settings.fetch('mode') == 'leaky' || ([Dir.pwd] + extra_roots).any? { |root| target.start_with?(root + '/') && !target.include?('/.git/') }
      File.write(target, 'breach')
      puts '1'
    else
      puts '0'
    end
  end
  exit
end
if ARGV == ['exec', '--help']
  puts '--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model'
  exit
end
if ARGV == ['login', '--help']
  puts 'status Show login status'
  exit
end
if ARGV == ['login', 'status']
  warn 'Logged in using ChatGPT'
  exit
end
abort 'unexpected invocation' unless ARGV.first == 'exec'
path = ARGV[ARGV.index('--output-last-message') + 1]
root = File.expand_path('../../../..', path)
mode = JSON.parse(File.read(File.join(root, 'fake-settings.json'))).fetch('mode')
trap('INT') { File.write(File.join(root, 'interrupted'), 'INT'); exit 130 }
# Keep independent child observations when concurrent workers finish out of order.
observed_process = JSON.generate(pid: Process.pid, parent: Process.ppid, group: Process.getpgrp, cwd: Dir.pwd)
File.write(File.join(root, "worker-process-#{Process.pid}"), observed_process)
File.write(File.join(root, 'worker-process'), observed_process)
File.write(File.join(root, 'worker-pid'), Process.pid.to_s)
input = STDIN.read
File.binwrite(File.join(root, 'stdin'), input)
File.write(File.join(root, 'argv'), JSON.generate(ARGV))
File.write(File.join(root, 'envkeys'), JSON.generate(ENV.keys))
Dir.mktmpdir('worker-fixture-') do |directory|
  temporary = File.join(directory, 'file')
  File.write(temporary, 'created')
  abort 'fixture read failed' unless File.read(temporary) == 'created'
  File.write(temporary, 'updated')
  abort 'fixture write failed' unless File.read(temporary) == 'updated'
  File.unlink(temporary)
  File.write(File.join(root, 'worker-temp'), JSON.generate('TMPDIR' => ENV.fetch('TMPDIR'), 'directory' => directory))
end
File.write(File.join(ENV.fetch('TMPDIR'), 'retained.txt'), 'fixture content')
File.write('worker-change.txt', 'worker')
puts JSON.generate(type: 'thread.started', thread_id: 'fixture-session')
STDOUT.flush
if mode.start_with?('journey-drift-')
  # Keep ACT-31's real ready/release barrier and post-drift binary candidate.
  File.write(File.join(root, 'worker-ready'), Dir.pwd)
  require 'timeout'
  Timeout.timeout(10) { sleep 0.01 until File.file?(File.join(root, 'worker-continue')) }
  File.binwrite('worker-change.txt', "after drift\n\x00\xff".b)
  abort 'post-drift focused check failed' unless File.binread('worker-change.txt') == "after drift\n\x00\xff".b
end
if mode.start_with?('journey-')
  abort 'missing worker world handoff' unless defined?(MemoryGit::Session) && MemoryGit::Session.transport
  # Finite external worker boundary: consume the real envelope command,
  # check the fake implementation and export through the public CLI.
  abort 'focused check failed' unless mode.start_with?('journey-drift-') || File.binread('worker-change.txt') == 'worker'
  command = input.lines.find { |line| line.start_with?('After focused checks, export using') }
  abort 'missing candidate handoff' unless command
  words = Shellwords.split(command.split(': ', 2).last)
  data = words.find { |word| word.start_with?('AGENT_CODING_TOOL_DATA_DIR=') }.split('=', 2).last
  out, err = StringIO.new, StringIO.new
  code = AgentCodingTool::CLI.run(words.drop(words.index('checkpoint')), data_root: data, out: out, err: err)
  abort err.string unless code.zero?
  result = JSON.parse(out.string)
  result['focused_checks'] = [{ 'command' => 'finite fake worker content check', 'result' => 'PASS' }]
  result['startup_tools'] = mode.delete_prefix('journey-')
  File.write(path, JSON.generate(result))
  exit(mode == 'journey-drift-remote' ? 7 : 0)
end
puts JSON.generate(type: 'item.completed', text: 'progress')
STDOUT.flush
warn 'stderr progress'
sleep 30 if mode == 'sleep'
File.binwrite(path, mode == 'invalid' ? "\xff" : 'Final worker response') unless mode == 'missing'
exit(mode == 'failure' ? 7 : 0)
