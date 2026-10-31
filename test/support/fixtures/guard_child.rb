# frozen_string_literal: true

require "open3"

# Finite transport fixture. Receives a mode and optional marker path; reports
# binary/text/status facts or attempts an undeclared child. No Git may start.
case ARGV.fetch(0)
when "binary"
  STDIN.binmode
  STDOUT.binmode
  STDERR.binmode
  STDOUT.write(STDIN.read.reverse)
  STDERR.write("\xfe\x00".b)
  exit 7
when "text"
  puts "transport text"
  warn "transport error"
when "coverage"
  require "json"
  context = ENV["ACT_COVERAGE_CONTEXT"]
  running = !!(defined?(Coverage) && Coverage.running?)
  require File.join(JSON.parse(File.binread(context)).fetch("root"), "lib/coverage_probe") if running
  puts JSON.generate("context" => context, "running" => running, "pid" => Process.pid,
    "guard_loaded" => $LOADED_FEATURES.include?(NoGitExecution::GUARD),
    "coverage_loaded" => $LOADED_FEATURES.include?(NoGitExecution::COVERAGE))
when "signal"
  Process.kill("TERM", Process.pid)
when "attack"
  ENV.delete("RUBYOPT")
  begin
    Open3.capture3("git", "--version")
  rescue NoGitExecution::ProhibitedExecution
    puts "child protected"
    exit 9
  end
  File.write(ARGV.fetch(1), "escaped")
  exit 99
when "ordinary"
  require_relative "../../ordinary_execution"
  bundler = $LOADED_FEATURES.find { |path| path.end_with?("/bundler/setup.rb") }
  permit = NoGitExecution::Permit.new(script: __FILE__, sha256: Digest::SHA256.file(__FILE__).hexdigest,
    arguments: ["text"], preloads: bundler ? { bundler => Digest::SHA256.file(bundler).hexdigest } : {})
  begin
    NoGitExecution.with_permit(permit) { Open3.capture3(permit.environment, *permit.argv) }
  rescue OrdinaryExecution::ProhibitedExecution
    puts "ordinary stronger"
    exit 0
  end
  exit 99
else
  raise "unknown guard fixture mode"
end
