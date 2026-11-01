# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# Exercises the byte-safe capture seam without a command fake masking bytes.
class GateCaptureTest < Minitest::Test
  # Both streams preserve binary/partial writes, empty output and explicit caps.
  # Only bounded test strings are allocated; the console oracle sees all bytes.
  def test_binary_streams_empty_output_and_output_limit
    Dir.mktmpdir do |directory|
      out, err = StringIO.new("".b), StringIO.new("".b)
      capture = AgentCodingTool::GateCapture.new(directory, "fixture", out: out, err: err)
      chunk = "\x00\xff".b * 8192
      assert_equal :command_result, capture.run { |pipes| 257.times { pipes[:out].write(chunk) }; :command_result }
      result = capture.result
      assert_equal "incomplete", result["status"]
      stdout = result.fetch("streams").fetch("stdout")
      assert_equal "truncated", stdout["status"]
      assert_equal chunk.bytesize * 257, stdout["observed_bytes"]
      assert_equal AgentCodingTool::GateCapture::LIMIT, stdout["bytes"]
      assert_equal chunk * 257, out.string
      assert_equal Digest::SHA256.file(File.join(directory, stdout["file"])).hexdigest, stdout["sha256"]
      assert_equal "complete", result.dig("streams", "stderr", "status")
      assert_empty err.string
    end
  end

  # Missing storage/console failures never become command success; exceptions
  # remain the original objects and retained counts explicitly describe loss.
  def test_persistence_console_and_command_failures_are_independent
    broken = Object.new
    broken.define_singleton_method(:write) { |_| raise IOError }
    capture = AgentCodingTool::GateCapture.new(nil, "fixture", out: broken, err: StringIO.new)
    failure = Interrupt.new("fixture interruption")
    actual = assert_raises(Interrupt) { capture.run { |pipes| pipes[:out].write("\x80".b); raise failure } }
    assert_same failure, actual
    assert_equal "incomplete", capture.result["status"]
    assert_equal "persistence_error", capture.result.dig("streams", "stdout", "status")
    assert_equal "delivery_error", capture.result.dig("streams", "stdout", "console")
    assert_equal 1, capture.result.dig("streams", "stdout", "observed_bytes")
  end
end
