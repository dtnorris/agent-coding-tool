# frozen_string_literal: true

# Exercises one exact reviewed owner fork with real pipe EOF and native status.
# Synthetic production files isolate parent-only and child-only coverage hits.
require 'json'
require_relative '../no_git_execution'
mode, root = ARGV
load File.join(root, 'lib/parent_probe.rb')
source = File.realpath(__FILE__)
line = File.readlines(source).find_index { |text| text.strip.start_with?('child = Process.fork do') } + 1
approval = NoGitExecution::ForkPermit.new(source: source,
  sha256: Digest::SHA256.file(source).hexdigest, line: mode == 'wrong_line' ? line + 1 : line)
reader, writer = IO.pipe
begin
  if mode == 'cached'
    Process.method(:fork).super_method.call { exit! 99 }
  elsif mode == 'undeclared'
    Process.fork { exit! 99 }
  else
    (mode == 'reuse' ? 2 : 1).times do
      NoGitExecution.with_fork_permit(approval) do
      child = Process.fork do
        reader.close
        load File.join(root, 'lib/child_probe.rb')
        # Spawn remains forbidden inside the real forked owner.
        begin
          Process.spawn('/usr/bin/git', '--version')
          exit! 98
        rescue NoGitExecution::ProhibitedExecution
          writer.write("guarded #{Process.pid}\n")
        end
        writer.close
        exit! 23
      end
      writer.close
      observed = reader.read
      waited, status = Process.wait2(child)
      raise 'identity/status/EOF changed' unless observed == "guarded #{child}\n" && waited == child && status.exitstatus == 23
    end
    end
  end
rescue NoGitExecution::ProhibitedExecution
  raise if mode == 'positive'
  puts 'REFUSED'
end
