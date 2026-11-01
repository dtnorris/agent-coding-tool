# frozen_string_literal: true

require "minitest/autorun"

# Finite, deliberately failing/slow cases selected only by progress contracts.
# This filename is outside normal *_test.rb and *_contract.rb discovery.
class ProgressFixture < Minitest::Test
  # Cannot finish successfully until the parent has displayed its active name.
  # The finite deadline makes a disconnected progress handoff fail, not hang.
  def test_live
    release = ENV.fetch("ACT_PROGRESS_FIXTURE_RELEASE")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 4
    until File.file?(release) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.01
    end
    assert File.file?(release), "parent did not display progress before child completion"
  end

  # Keeps raw binary diagnostics available while returning a genuine failure.
  def test_failure
    STDOUT.binmode
    STDOUT.write("raw-output\x00\xff".b)
    STDERR.binmode
    STDERR.write("raw-error\x00\xfe".b)
    flunk "deliberate progress failure"
  end

  # A skipped case must remain unacceptable to the independent suite verifier.
  def test_skip
    skip "deliberate progress skip"
  end

  # Abnormal exit leaves no final result envelope, preserving exact status.
  def test_exit
    exit! 7
  end

  # Signals must retain the runner's conventional 128+signal exit status.
  def test_signal
    Process.kill("KILL", Process.pid)
  end

  # A valid case followed by a forged envelope must never become accepted.
  def test_corrupt
    assert true
    Minitest.after_run { File.write(ENV.fetch("ACT_SUITE_EVIDENCE"), "{}") }
  end
end
