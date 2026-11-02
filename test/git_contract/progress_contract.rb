# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "stringio"
require "tmpdir"
require "rake"
require_relative "../suite_runner"
require_relative "../feedback"
Minitest::Assertions.diff = nil

# Exercises the real guarded loader and regular-file observer. No product
# services, Git mutations, external accounts or host-specific inspection.
class ProgressContract < Minitest::Test
  ROOT = File.realpath(File.join(__dir__, "../.."))
  FIXTURE = "test/support/fixtures/progress_cases.rb"

  # A pipe-like sink releases the child only after a flushed progress line names
  # the running case. StringIO stores exact bytes for the parent's assertions.
  class LiveOutput < StringIO
    # Binds a disposable rendezvous path; creates no files until live feedback.
    def initialize(release)
      super("".b)
      @release = release
    end

    # Called by the production observer; simulates a downstream log consumer.
    def flush
      File.write(@release, "displayed") if string.include?("running ProgressFixture#test_live")
      super
    end
  end

  # Executes exactly the requested fixture cases through the normal loader.
  # Returns true or propagates the runner's actual nonzero SystemExit.
  def run_fixture(*names)
    TestSuiteRunner.run_process([FIXTURE], names.map { |name| "ProgressFixture##{name}" }, root: ROOT, selected: true)
  end

  # Proves live output while redirected: without the start event the child fails
  # its rendezvous. Compact success output hides only the internal selection regex.
  def test_live_redirected_progress_before_child_exit
    original_out, original_err = $stdout, $stderr
    old_release = ENV["ACT_PROGRESS_FIXTURE_RELEASE"]
    old_git_work_tree = ENV["GIT_WORK_TREE"]
    Dir.mktmpdir("act-progress-proof-") do |directory|
      release = File.join(directory, "release")
      ENV["ACT_PROGRESS_FIXTURE_RELEASE"] = release
      ENV["GIT_WORK_TREE"] = "/untrusted/ambient"
      output, diagnostic = StringIO.new("".b), LiveOutput.new(release)
      $stdout, $stderr = output, diagnostic
      assert run_fixture("test_live")
      assert File.file?(release)
      assert_includes diagnostic.string, "1 phases, 1 suites, 1 tests"
      assert_includes diagnostic.string, "0/1 tests completed; 1 remaining"
      assert_includes diagnostic.string, "running ProgressFixture#test_live"
      assert_includes diagnostic.string, "1/1 tests; seed"
      assert_includes output.string, "1 runs, 2 assertions, 0 failures"
      refute_includes output.string, "--name"
      refute_includes diagnostic.string, "ACT complete offline acceptance: PASS"
    end
  ensure
    $stdout, $stderr = original_out, original_err
    ENV["ACT_PROGRESS_FIXTURE_RELEASE"] = old_release
    ENV["GIT_WORK_TREE"] = old_git_work_tree
  end

  # Exact failing status and binary streams survive presentation; skips and
  # missing/corrupt evidence cannot be promoted by observed progress counts.
  def test_failures_skips_signals_and_corrupt_evidence_remain_failures
    { "test_failure" => 1, "test_skip" => 1, "test_exit" => 7,
      "test_signal" => 128 + Signal.list.fetch("KILL"), "test_corrupt" => 1 }.each do |name, expected|
      output, error = capture_io do
        failure = assert_raises(SystemExit) { run_fixture(name) }
        assert_equal expected, failure.status
      end
      assert_includes error, "INCOMPLETE"
      refute_includes error, "VERIFIED"
      if name == "test_failure"
        assert_includes output.b, "raw-output\x00\xff".b
        assert_includes error.b, "raw-error\x00\xfe".b
        assert_includes error, "FAILURE ProgressFixture#test_failure"
      end
    end
  end

  # Uses the same validated selection objects for the display and execution;
  # disjoint ordinary/native counts and single-file contract groups stay exact.
  def test_plans_follow_real_selections
    ordinary = TestSuiteRunner.execution_groups(:ordinary, root: ROOT)
    native = TestSuiteRunner.execution_groups(:native_default, root: ROOT)
    complete = TestSuiteRunner.execution_groups(:default, root: ROOT)
    assert_equal ordinary + native, complete
    assert_empty ordinary.flat_map { |group| group[:cases] } & native.flat_map { |group| group[:cases] }
    contracts = TestSuiteRunner.execution_groups(:git_contract, root: ROOT)
    assert_equal [TestSuiteRunner::CONTRACT_BATCH], contracts.select { |group| group[:paths].length > 1 }.map { |group| group[:paths] }
    assert_equal JSON.parse(File.binread(File.join(ROOT, "test/git_contract/required_cases.json"))).values.flatten.sort,
      contracts.flat_map { |group| group[:cases] }.sort
    assert_includes contracts.flat_map { |group| group[:paths] }, "test/git_contract/progress_contract.rb"
    refute_empty ordinary.first.fetch(:cases)
    # The batch observer refuses a case that leaks environment into its sibling.
    reporter = SuiteEvidenceReporter.new("unused", seed: 2300)
    before = reporter.process_state
    previous = ENV["ACT_BATCH_LEAK_CONTROL"]
    begin
      reporter.instance_variable_set(:@process_state, before)
      ENV["ACT_BATCH_LEAK_CONTROL"] = "leaked"
      result = Struct.new(:class_name, :name).new("BatchControl", "test_leak")
      error = assert_raises(RuntimeError) { reporter.record(result) }
      assert_includes error.message, "batched case changed process state"
    ensure
      ENV["ACT_BATCH_LEAK_CONTROL"] = previous
    end
    assert_equal before, reporter.process_state
  end

  # Expands aliases and combined Rake requests in actual prerequisite order,
  # avoiding a misleading full-suite total for an ordinary-only invocation.
  def test_rake_plans_aliases_and_multiple_tasks
    original = Rake.application
    Rake.application = Rake::Application.new
    load File.join(ROOT, "Rakefile")
    {
      ["test"] => %i[ordinary],
      ["default"] => %i[ordinary],
      ["test:verified_default"] => %i[ordinary native_default],
      ["test:integration", "test:all"] => %i[ordinary git_contract native_default native_integration],
      ["test:native_default", "test:ordinary"] => %i[native_default ordinary]
    }.each do |tasks, expected|
      Rake.application.instance_variable_set(:@top_level_tasks, tasks)
      assert_equal expected, TestFeedback.planned_layers
    end
  ensure
    Rake.application = original
  end

  # Partial writes, stale invocations, duplicates and foreign identities cannot
  # inflate the observer's count. Stopping drains the final partial chunk.
  def test_partial_stale_and_duplicate_events
    Dir.mktmpdir("act-progress-events-") do |directory|
      path = File.join(directory, "events")
      output = StringIO.new
      observer = SuiteProgress.new([{ layer: "fixture", paths: [FIXTURE], cases: ["Fixture#test_one"] }], out: output)
      observer.start(path, ["Fixture#test_one"], invocation: "fresh")
      event = { "invocation" => "fresh", "event" => "result", "case" => "Fixture#test_one", "status" => "pass" }
      File.open(path, "ab") do |file|
        file.puts JSON.generate(event.merge("invocation" => "stale"))
        file.puts JSON.generate(event.merge("case" => "Foreign#test_other"))
        bytes = JSON.generate(event)
        file.write(bytes[0, 10]); file.flush
        file.write(bytes[10..] + "\n"); file.puts(bytes)
      end
      observer.stop
      observer.display
      assert_includes output.string, "1/1 tests completed; 0 remaining"
      refute_includes output.string, "2/1"
      assert_equal 0, observer.instance_variable_get(:@verified)
    ensure
      observer&.stop
    end
  end

  # Injects only the host-specific supervisor outcome. A timeout or interrupt
  # must stop the real observer, preserve diagnostics and never verify a suite.
  # The existing feedback contracts separately exercise Darwin process cleanup.
  def test_timeout_and_interrupt_stop_observer
    ["timeout", "interrupt"].each do |mode|
      Dir.mktmpdir("act-progress-watchdog-") do |directory|
        record = { "coverage_context" => { "directory" => directory } }
        stage = { "layer" => "fixture" }
        before = Thread.list
        outcome = lambda do |argv, **options|
          pid = File.open(options.fetch(:stdout_path), "wb") do |output|
            File.open(options.fetch(:stderr_path), "wb") do |error|
              Process.spawn(options.fetch(:environment), *argv, chdir: options.fetch(:root), pgroup: true, out: output, err: error)
            end
          end
          _child, status = Process.wait2(pid)
          File.binwrite(options.fetch(:stdout_path), "partial-output\x00".b)
          File.binwrite(options.fetch(:stderr_path), "partial-error\xff".b)
          raise Interrupt, "fixture interruption" if mode == "interrupt"
          { status: status, timeout: true,
            seconds: 1, observed_processes: [] }
        end
        output, error = capture_io do
          TestFeedback.stub(:child, [{}, record]) do
            TestFeedback.stub(:context, { "hard_deadline_seconds" => 5 }) do
              TestFeedback.stub(:timer, [FeedbackRuntime.clock, 0]) do
                FeedbackRuntime.stub(:capture, outcome) do
                  failure = assert_raises(mode == "timeout" ? SystemExit : Interrupt) do
                    TestSuiteRunner.run_process([FIXTURE], ["ProgressFixture#test_exit"], root: ROOT, selected: true, feedback: stage)
                  end
                  assert_equal 1, failure.status if mode == "timeout"
                end
              end
            end
          end
        end
        assert_empty Thread.list - before
        assert_includes output.b, "partial-output\x00".b
        assert_includes error.b, "partial-error\xff".b
        assert_includes error, "INCOMPLETE"
        refute_includes error, "VERIFIED"
      end
    end
  end
end
