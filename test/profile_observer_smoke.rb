# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "rbconfig"
require_relative "profile_suite"

# Isolated observer controls; intentionally excluded from the default test glob.
class ProfileObserverSmoke < Minitest::Test
  SuiteProfile.install!

  # Actual text/binary subprocesses retain exact streams, status and signal facts.
  def test_real_text_and_binary_status
    text, error, status = Open3.capture3(RbConfig.ruby, "-e", 'puts "text"; warn "error"')
    assert_equal "text\n", text
    assert_equal "error\n", error
    assert status.success?
    output, error, status = Open3.capture3(RbConfig.ruby, "-e",
      'STDOUT.binmode; STDERR.binmode; STDOUT.write([0,255,128,10].pack("C*")); STDERR.write([254,0].pack("C*")); exit 7')
    assert_equal [0, 255, 128, 10], output.bytes
    assert_equal [254, 0], error.bytes
    assert_equal 7, status.exitstatus
    assert_nil status.termsig
  end

  # Stubbed results retain object identity; raised errors retain the same object.
  # A nested real capture remains separately attributable to its Open3 boundary.
  def test_stub_identity_exception_and_nested_attribution
    original = Open3.method(:capture3)
    value = ["\xff".b, "\x00".b, Object.new]
    Open3.stub(:capture3, ->(*) { value }) { assert_same value, Open3.capture3("secret must not become a label") }
    exception = IOError.new("secret exception must not become a label")
    Open3.stub(:capture3, ->(*) { raise exception }) do
      assert_same exception, assert_raises(IOError) { Open3.capture3("private") }
    end
    Open3.stub(:capture3, ->(*) { original.call(RbConfig.ruby, "-e", "exit 0") }) do
      assert Open3.capture3("private").last.success?
    end
    rows = SuiteProfile.snapshot.fetch(:operations)
    assert rows.any? { |row| row[:operation] == "capture.stub.other" && row[:raises_within].positive? }
    assert rows.any? { |row| row[:operation] == "capture.open3.ruby" }
    assert rows.any? { |row| row[:operation] == "process.spawn" }
    assert rows.any? { |row| row[:operation] == "capture.stub.other" && row[:same_thread_self_seconds] < row[:inclusive_seconds] }
    assert rows.all? { |row| row[:same_thread_self_seconds] >= 0 && row[:same_thread_self_seconds] <= row[:inclusive_seconds] }
    refute_includes JSON.generate(rows), "secret"
    refute_includes JSON.generate(rows), "private"
  end

  # A real missing executable preserves ENOENT rather than inventing a status.
  def test_real_spawn_exception
    assert_raises(Errno::ENOENT) { Open3.capture3(File.join(__dir__, "absent-profile-fixture")) }
  end
end
