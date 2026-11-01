# frozen_string_literal: true

require_relative '../feedback_processes'

# Spawns only another exact mode of this same reviewed fixture. Streams/groups
# and all inherited real coverage remain guarded and native.
def child(mode, options = {})
  permit = FeedbackProcesses.permit([mode], options)
  NoGitExecution.with_permit(permit) { Process.spawn(permit.environment, *permit.argv, **permit.options) }
end

mode, *arguments = ARGV
case mode
when 'bytes'
  STDOUT.binmode; STDERR.binmode
  STDOUT.write("text\n".b + [0, 255, 128].pack('C*'))
  STDERR.write([254, 0].pack('C*'))
  exit 7
when 'signal' then Process.kill('TERM', Process.pid)
when 'sleep' then sleep 5
when 'short_sleep' then sleep 0.02
when 'timer'
  require_relative '../../feedback_runtime'
  sleep 0.03
  puts FeedbackRuntime.elapsed(FeedbackRuntime.outer_timer)
when 'hang'
  # Exercise startup slower than the hang deadline; publish readiness last.
  sleep 0.3
  pid = child('sleep', pgroup: true)
  STDOUT.binmode; STDOUT.write([0,255].pack('C*')); STDOUT.flush
  File.write(arguments.fetch(0), pid)
  sleep 5
when 'interrupt'
  require_relative '../../feedback_runtime'
  require 'tmpdir'
  exception = Interrupt.new('control')
  Thread.new { sleep 0.05; Thread.main.raise(exception) }
  Dir.mktmpdir do |root|
    permit = FeedbackProcesses.permit(['sleep'], { chdir: root, pgroup: true })
    begin
      NoGitExecution.with_permit(permit) do
        FeedbackRuntime.capture(permit.argv, environment: permit.environment, root: root, seconds: 2,
          stdout_path: File.join(root, 'out'), stderr_path: File.join(root, 'err'))
      end
    rescue Interrupt => observed
      puts observed.equal?(exception)
      exit 130
    end
  end
when 'probe'
  require_relative '../../feedback_coverage'
  require 'tmpdir'
  require 'fileutils'
  context_path, variant = arguments
  context = JSON.parse(File.binread(context_path))
  Dir.chdir(context.fetch('root'))
  require File.join(Dir.pwd, 'lib/loaded.rb') if variant == 'late'
  FeedbackCoverage.start_probe(context_path) unless variant == 'cold_missing'
  require File.join(Dir.pwd, 'lib/loaded.rb')
  CoveredExample.choose(variant == 'cold_false' || variant == 'cold_missing' ? false : true)
  case variant
  when 'cold', 'missing'
    permit = FeedbackProcesses.permit(['probe', context_path, variant == 'cold' ? 'cold_false' : 'cold_missing'])
    pid = NoGitExecution.with_permit(permit) { Process.spawn(permit.environment, *permit.argv) }
    Process.waitpid(pid)
  when 'nested', 'nested_execute'
    Dir.mktmpdir('nested-', Dir.pwd) do |root|
      FileUtils.mkdir_p([File.join(root, 'lib'), File.join(root, 'bin')])
      File.write(File.join(root, 'lib/synthetic.rb'), "puts :fixture\n")
      File.write(File.join(root, 'bin/agent-coding-tool'), "puts :unused\n")
      FeedbackCoverage.layout(root)
      load File.join(root, 'bin/agent-coding-tool') if variant == 'nested_execute'
    end
  when 'copy', 'copy_change', 'copy_delete'
    FileUtils.mkdir_p('copy/bin')
    FileUtils.cp('bin/agent-coding-tool', 'copy/bin/agent-coding-tool')
    load 'copy/bin/agent-coding-tool'
    File.write('copy/bin/agent-coding-tool', 'puts :changed') if variant == 'copy_change'
    File.unlink('copy/bin/agent-coding-tool') if variant == 'copy_delete'
  when 'compile_change'
    FileUtils.mkdir_p('copy/bin')
    File.write('copy/bin/agent-coding-tool', 'puts :changed')
    RubyVM::InstructionSequence.compile_file('copy/bin/agent-coding-tool', coverage_enabled: true)
  when 'source_change' then File.write('lib/loaded.rb', '# changed production')
  end
else
  abort 'unknown feedback fixture mode'
end
