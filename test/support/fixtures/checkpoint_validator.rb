# frozen_string_literal: true

require 'json'
require 'fileutils'
# Finite checkpoint validator. Literal modes retain real bytes, writes, signals
# and exit statuses; no argument is evaluated as code or a shell command.
mode, *arguments = ARGV
case mode
when 'emit' then STDOUT.binmode.write("checked\x00\xff".b)
when 'exit' then exit Integer(arguments.fetch(0))
when 'signal' then Process.kill('TERM', Process.pid); sleep 2
when 'write' then File.binwrite(arguments.fetch(0), arguments.fetch(1))
when 'touch' then FileUtils.touch(arguments.fetch(0))
when 'binary'
  STDOUT.binmode.write("\x00\xff".b)
  STDERR.binmode.write("\xfe\x00".b)
  exit 7
when 'invalid'
  File.write(arguments.fetch(0), '{"secret":"secret-canary"}', mode: 'wx', perm: 0o600)
when 'observation'
  report = { schema_version: 'agent-coding-tool-gate-observation/v1', seed: 31046,
    selection: 'subset', summary: { tests: 2, assertions: 3, failures: 0, errors: 0, skips: 0 } }
  File.open(arguments.fetch(0), 'wx', 0o600) { |file| file.write(JSON.generate(report)) }
  STDOUT.binmode.write("seed=31046\n\x00\xff".b)
  STDERR.binmode.write("\x80error-stream\x00\n".b)
when 'receipts'
  puts JSON.generate(Dir.glob(File.join(arguments.fetch(0), 'gate-*.finished.json')).map { |path| JSON.parse(File.binread(path)) })
else abort 'unknown checkpoint validator mode'
end
