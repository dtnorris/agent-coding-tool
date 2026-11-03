# frozen_string_literal: true

# Arm coverage cleanup before fixture loading: startup cleanup may signal this
# interpreter while its preload chain is still running.
Signal.trap('TERM') do
  if ENV['ACT_COVERAGE_CONTEXT']
    context = JSON.parse(File.binread(ENV.fetch('ACT_COVERAGE_CONTEXT')))
    marker = File.join(context.fetch('directory'), "#{Process.pid}.term")
    File.write(marker, "received #{Process.clock_gettime(Process::CLOCK_MONOTONIC)}\n")
    begin
      FeedbackCoverage.finish
      File.write(marker, "finished #{Process.clock_gettime(Process::CLOCK_MONOTONIC)}\n", mode: 'a')
    rescue Exception => error
      File.write(marker, "#{error.class}: #{error.message}\n", mode: 'a')
      raise
    end
  end
  raise SignalException.new('TERM')
end

require_relative "../source_fixture"
