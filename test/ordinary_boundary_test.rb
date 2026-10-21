# frozen_string_literal: true

require_relative "test_helper"
require_relative "skill_observations"
require "rbconfig"
require "shellwords"

# Qualifies exact source inputs and the ordinary execution boundary. Bare rake
# test retains its native selection and runs the boundary proof in one child.
class OrdinaryBoundaryTest < Minitest::Test
  # Proves native process entries fail before any marker/child effect. Native
  # selections invoke this same proof in an isolated, bounded guarded Ruby.
  def test_dependency_entries_refuse_before_effect
    unless defined?(OrdinaryExecution)
      environment = { "RUBYOPT" => Shellwords.join(["-r#{File.join(__dir__, 'ordinary_execution.rb')}",
        *Shellwords.split(ENV.fetch("RUBYOPT", ""))]) }
      stdout, stderr, status = GitContract::Native.new.capture3(environment, RbConfig.ruby,
        "-Ilib:test", __FILE__, "--name", name, "--seed", "2300")
      assert status.success?, "#{stdout}\n#{stderr}"
      return
    end
    Dir.mktmpdir("act-boundary-") do |root|
      marker = File.join(root, "executed")
      command = [RbConfig.ruby, "-e", "File.write(ARGV.fetch(0), 'executed')", marker]
      operations = [
        -> { Process.spawn(*command) }, -> { spawn(*command) },
        -> { system(*command) }, -> { exec(*command) },
        -> { Open3.capture3(*command) }, -> { IO.popen(command) },
        -> { IO.read("|#{Shellwords.join(command)}") },
        -> { Kernel.open("|#{Shellwords.join(command)}") },
        -> { `#{Shellwords.join(command)}` },
        -> { fork { File.write(marker, "forked") } }
      ]
      operations.each do |operation|
        assert_raises(OrdinaryExecution::ProhibitedExecution, &operation)
        refute File.exist?(marker)
      end
      File.binwrite(marker, "\x00\xff".b)
      assert_equal "\x00\xff".b, IO.binread(marker)
    end
  end

  # Material environment, cwd, order, duplication and omissions fail before a
  # response is consumed; stdout/stderr bytes and exceptions remain unchanged.
  def test_strict_source_observations_and_environment
    environment = { "GIT_NO_LAZY_FETCH" => +"1", "GIT_TERMINAL_PROMPT" => "0" }
    argv = [environment, "git", "cat-file", "blob", "fixture:path"]
    first = GitContract::Observation.new(argv: argv, cwd: "/fixture", result: ["\x00\xff".b, "\xfe".b, false])
    environment["GIT_NO_LAZY_FETCH"].replace("0")
    assert_equal "1", first.argv.first.fetch("GIT_NO_LAZY_FETCH")
    exception = Errno::ENOENT.new("fixture executable")
    second = GitContract::Observation.new(argv: ["absent"], cwd: "/fixture", exception: exception)
    runner = GitContract::Replay.new([first, second])
    assert_raises(GitContract::UnexpectedObservation) { runner.capture(*argv, chdir: "/fixture") }
    assert_raises(GitContract::UnexpectedObservation) { runner.capture(*first.argv, chdir: "/wrong") }
    assert_raises(GitContract::UnexpectedObservation) { runner.capture(*second.argv, chdir: second.cwd) }
    assert_raises(GitContract::UnexpectedObservation) { runner.verify! }
    assert_equal ["\x00\xff".b, "\xfe".b, false], runner.capture(*first.argv, chdir: first.cwd)
    assert_same exception, assert_raises(Errno::ENOENT) { runner.capture(*second.argv, chdir: second.cwd) }
    assert runner.verify!
    assert_raises(GitContract::UnexpectedObservation) { runner.capture(*first.argv, chdir: first.cwd) }
  end
end
