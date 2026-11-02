# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "rake"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../feedback"
require_relative "../suite_runner"
require "agent_coding_tool"
require_relative "../support/child_processes"
require_relative "../support/validation_processes"
Minitest::Assertions.diff = nil

# Small native controls for the verifier, without running the product suite.
# Children and sentinels are finite, fixture-owned Ruby processes only.
class FeedbackContract < Minitest::Test
  include ValidationProcesses
  # Captures a finite Ruby script using the actual watchdog and output paths.
  # Returns outcome and byte streams; spawn/readiness failures propagate.
  # Optional readiness uses a separate finite startup budget.
  def capture(script, seconds: 2, arguments: [], ready_path: nil, startup_seconds: nil)
    Dir.mktmpdir("act-feedback-control-") do |root|
      output, error = %w[out err].map { |name| File.join(root, name) }
      permit = ChildProcesses.permit('feedback_worker', arguments: [script, *arguments], options: { chdir: root, pgroup: true })
      result = NoGitExecution.with_permit(permit) do
        FeedbackRuntime.capture(permit.argv, environment: permit.environment, root: root,
          seconds: seconds, stdout_path: output, stderr_path: error,
          ready_path: ready_path, startup_seconds: startup_seconds)
      end
      [result, File.binread(output), File.binread(error)]
    end
  end

  # Text/binary output, nonzero status, and signal facts must remain exact.
  def test_bytes_exit_and_signal
    outcome, output, error = capture('bytes')
    assert_equal "text\n\x00\xff\x80".b, output
    assert_equal "\xfe\x00".b, error
    assert_equal 7, outcome.fetch(:status).exitstatus
    assert_nil outcome.fetch(:status).termsig
    refute outcome.fetch(:timeout)
    outcome, = capture('signal')
    assert_equal Signal.list.fetch("TERM"), outcome.fetch(:status).termsig
    refute outcome.fetch(:timeout)
  end

  # An actual failed spawn raises ENOENT and never becomes an exit/status pass.
  def test_spawn_exception_and_invalid_deadline
    Dir.mktmpdir("act-feedback-spawn-") do |root|
      # Match the canonical directory required by the missing-executable permit.
      root = File.realpath(root)
      options = { environment: {}, root: root, seconds: 1,
                  stdout_path: File.join(root, "out"), stderr_path: File.join(root, "err") }
      # Plain rake has no Bundler preload; bundle exec retains its exact binding.
      preloads = { NoGitExecution::COVERAGE => Digest::SHA256.file(NoGitExecution::COVERAGE).hexdigest }
      bundler = $LOADED_FEATURES.find { |path| path.end_with?('/bundler/setup.rb') }
      preloads[File.realpath(bundler)] = Digest::SHA256.file(bundler).hexdigest if bundler
      permit = NoGitExecution::MissingExecutablePermit.new(directory: File.realpath(root),
        preloads: preloads, options: { chdir: root, pgroup: true })
      assert_raises(Errno::ENOENT) do
        NoGitExecution.with_permit(permit) { FeedbackRuntime.capture(permit.argv, **options.merge(environment: permit.environment)) }
      end
      assert_raises(ArgumentError) { FeedbackRuntime.capture([RbConfig.ruby], **options.merge(seconds: Float::INFINITY)) }
      ready_path = File.join(root, "never-ready")
      assert_raises(ArgumentError) do
        FeedbackRuntime.capture([RbConfig.ruby], **options, ready_path: ready_path, startup_seconds: Float::INFINITY)
      end
      File.write(ready_path, "stale")
      assert_raises(ArgumentError) do
        FeedbackRuntime.capture([RbConfig.ruby], **options, ready_path: ready_path, startup_seconds: 0.2)
      end
      File.unlink(ready_path)
      started = FeedbackRuntime.clock
      error = assert_raises(RuntimeError) do
        capture("sleep", seconds: 0.2, ready_path: ready_path, startup_seconds: 0.2)
      end
      assert_equal "feedback: child readiness deadline exceeded", error.message
      assert_operator FeedbackRuntime.clock - started, :<, 2
    end
    outcome, output, = capture('interrupt')
    assert_equal "true\n", output
    assert_equal 130, outcome.fetch(:status).exitstatus
  end

  # A hung descendant in a distinct owned group cannot keep the verifier alive;
  # an unrelated sibling sentinel remains alive and is separately reaped here.
  def test_hung_owned_descendant_and_unrelated_sentinel
    permit = ChildProcesses.permit('feedback_worker', arguments: ['sleep'], options: { pgroup: true })
    sentinel = File.open(File::NULL, 'w') do |null|
      NoGitExecution.with_permit(permit) { Process.spawn(permit.environment, *permit.argv, **permit.options, out: null, err: null) }
    end
    Dir.mktmpdir("act-feedback-hang-") do |root|
      marker = File.join(root, "descendant")
      started = FeedbackRuntime.clock
      # The fixture deliberately starts more slowly than the hang deadline.
      outcome, output, = capture('hang', seconds: 0.2, arguments: [marker],
        ready_path: marker, startup_seconds: 2)
      assert outcome.fetch(:timeout)
      assert_equal Signal.list.fetch("KILL"), outcome.fetch(:status).termsig
      assert_operator FeedbackRuntime.clock - started, :<, 4
      assert_equal "\x00\xff".b, output
      assert_equal 1, Process.kill(0, sentinel)
      descendant = Integer(File.read(marker))
      observed = outcome.fetch(:observed_processes).map { |row| row.fetch("pid") }
      assert_includes observed, descendant
      refute_includes observed, sentinel
      deadline = FeedbackRuntime.clock + 1
      sleep 0.01 while FeedbackRuntime.identity(descendant) && FeedbackRuntime.clock < deadline
      assert_nil FeedbackRuntime.identity(descendant), "owned descendant was not reaped"
    end
  ensure
    Process.kill("KILL", sentinel) rescue Errno::ESRCH if sentinel
    Process.waitpid(sentinel) rescue Errno::ECHILD if sentinel
  end

  # Kernel birth time must include pre-observer startup and agree with an
  # independent monotonic interval for this finite command.
  def test_outer_timer_includes_startup
    started = FeedbackRuntime.clock
    library = File.expand_path("../feedback_runtime.rb", __dir__)
    outcome, output, = capture('timer')
    assert outcome.fetch(:status).success?
    observed = Float(output)
    assert_operator observed, :>=, 0.03
    assert_in_delta FeedbackRuntime.clock - started, observed, 0.1
  end

  # Produces real fresh coverage for one branch and an unloaded source file.
  # Yields the context and map; fixture/hook failures are assertion failures.
  def with_coverage(cold: nil)
    Dir.mktmpdir("act-feedback-coverage-") do |root|
      # Keep probe roots consistent with real paths emitted by Ruby coverage.
      root = File.realpath(root)
      FileUtils.mkdir_p([File.join(root, "lib"), File.join(root, "bin"), File.join(root, "results")])
      File.write(File.join(root, "lib/loaded.rb"), "module CoveredExample\n def self.choose(value)\n if value\n 1\n else\n 2\n end\n end\nend\n")
      File.write(File.join(root, "lib/unloaded.rb"), "module UnloadedExample\n def self.value\n 3\n end\nend\n")
      File.write(File.join(root, "bin/agent-coding-tool"), "puts :unused\n")
      context = { "root" => root, "sources" => FeedbackCoverage.sources(root), "layout" => FeedbackCoverage.layout(root), "invocation" => "fresh-control",
                  "selection" => "one-branch", "stage" => "control", "directory" => File.join(root, "results") }
      context_path = File.join(root, "context.json")
      File.write(context_path, JSON.generate(context))
      output, error = %w[out err].map { |name| File.join(root, name) }
      variant = cold == :instrumented ? 'cold' : cold == :missing ? 'missing' : 'plain'
      permit = ChildProcesses.permit('feedback_worker', arguments: ['probe', context_path, variant], options: { chdir: root, pgroup: true })
      outcome = NoGitExecution.with_permit(permit) do
        FeedbackRuntime.capture(permit.argv, environment: permit.environment, root: root,
          seconds: 2, stdout_path: output, stderr_path: error)
      end
      assert outcome.fetch(:status).success?, File.binread(error)
      yield context, FeedbackCoverage.collect(context)
    end
  end

  # Compiled-but-unloaded production nodes stay in the denominator; the false
  # branch remains uncovered and an explicitly higher accepted floor fails.
  def test_unloaded_denominator_branch_and_coverage_violation
    with_coverage do |_context, map|
      summary = FeedbackCoverage.summary(map)
      assert_equal 3, summary.fetch("files")
      assert_includes summary.fetch("zero_hit_files"), "lib/unloaded.rb"
      assert_equal 2, summary.fetch("branch").fetch("total")
      assert_equal 1, summary.fetch("branch").fetch("covered")
      assert_raises(RuntimeError) { TestFeedback.coverage_gate(summary, { "line" => 0, "branch" => 100 }) }
      assert TestFeedback.coverage_gate(summary, { "line" => 0, "branch" => 50 })
    end
  end

  # Runs a finite script with a fresh coverage result directory for an existing
  # fixture source context. Returns outcome, stderr and context; spawn errors
  # propagate, while nonzero child exits remain available for negative controls.
  def coverage_probe(context, script)
    directory = Dir.mktmpdir("probe-", context.fetch("root"))
    child = context.merge("directory" => File.join(directory, "results"))
    Dir.mkdir(child.fetch("directory"))
    context_path = File.join(directory, "context.json")
    File.write(context_path, JSON.generate(child))
    permit = ChildProcesses.permit('feedback_worker', arguments: ['probe', context_path, script],
      options: { chdir: context.fetch("root"), pgroup: true })
    outcome = NoGitExecution.with_permit(permit) do
      FeedbackRuntime.capture(permit.argv, environment: permit.environment,
        root: context.fetch("root"), seconds: 2,
        stdout_path: File.join(directory, "out"), stderr_path: File.join(directory, "err"))
    end
    [outcome, File.binread(File.join(directory, "err")), child]
  end

  # Nested denominator compilation must not contaminate production evidence,
  # even after fixture deletion. Executed fixtures and changed production/copies
  # must still fail, including mutations after the first production line.
  def test_nested_layout_isolation_and_changed_source_refusal
    with_coverage do |context, expected|
      outcome, error, child = coverage_probe(context, 'nested')
      assert outcome.fetch(:status).success?, error
      assert_equal expected, FeedbackCoverage.collect(child)

      outcome, error, child = coverage_probe(context, 'nested_execute')
      refute outcome.fetch(:status).success?
      assert_includes error, "coverage: changed source"
      assert_raises(RuntimeError) { FeedbackCoverage.collect(child) }

      # The copied CLI has identical bytes and identity until deliberately
      # changed. It is not registered as an independently compiled fixture.
      outcome, error, child = coverage_probe(context, 'copy')
      assert outcome.fetch(:status).success?, error
      assert_operator FeedbackCoverage.collect(child).fetch("bin/agent-coding-tool").fetch("line:1"), :>, 0
      %w[copy_change copy_delete].each do |mutation|
        outcome, error, child = coverage_probe(context, mutation)
        refute outcome.fetch(:status).success?
        assert_includes error, "coverage: changed source"
        assert_raises(RuntimeError) { FeedbackCoverage.collect(child) }
      end

      # A changed copy compiled outside layout remains subject to byte checks,
      # even if every node has zero hits.
      outcome, error, child = coverage_probe(context, 'compile_change')
      refute outcome.fetch(:status).success?
      assert_includes error, "coverage: changed source"
      assert_raises(RuntimeError) { FeedbackCoverage.collect(child) }

      path = File.join(context.fetch("root"), "lib/loaded.rb")
      bytes = File.binread(path)
      begin
        outcome, error, child = coverage_probe(context, 'source_change')
        refute outcome.fetch(:status).success?
        assert_includes error, "coverage: source changed during execution"
        assert_raises(RuntimeError) { FeedbackCoverage.collect(child) }
      ensure
        File.binwrite(path, bytes)
      end
    end
  end

  # Missing, stale, contradictory and altered-source evidence must fail. Restore
  # exact result bytes after every mutation and re-collect the positive result.
  def test_missing_stale_and_contradictory_coverage
    with_coverage do |context, original|
      path = Dir.glob(File.join(context.fetch("directory"), "*.json")).fetch(0)
      bytes = File.binread(path)
      result = JSON.parse(bytes)
      %w[invocation selection sources].each do |key|
        File.write(path, JSON.generate(result.merge(key => "stale")))
        assert_raises(RuntimeError) { FeedbackCoverage.collect(context) }
        File.binwrite(path, bytes)
      end
      File.unlink(path)
      assert_raises(RuntimeError) { FeedbackCoverage.collect(context) }
      File.binwrite(path, bytes)
      reduced = JSON.parse(bytes)
      reduced.fetch("files").fetch("lib/loaded.rb").delete_if { |node, _hits| node.start_with?("branch:") }
      File.write(path, JSON.generate(reduced))
      assert_raises(RuntimeError) { FeedbackCoverage.collect(context) }
      File.binwrite(path, bytes)
      File.write(File.join(context.fetch("directory"), "extra.json"), bytes)
      assert_raises(RuntimeError) { FeedbackCoverage.collect(context) }
      File.unlink(File.join(context.fetch("directory"), "extra.json"))
      assert_equal original, FeedbackCoverage.collect(context)
      assert_equal original, FeedbackCoverage.merge([original, original])
      assert_raises(RuntimeError) { FeedbackCoverage.merge([original, original.reject { |key, _value| key == "lib/unloaded.rb" }]) }
    end
  end

  # Interrupting publication must not expose partial final JSON or overwrite a
  # prior result. Abandoned fixture-only writes are harmless; active children
  # still require complete evidence and malformed published JSON still refuses.
  def test_coverage_publication_is_atomic_and_exclusive
    with_coverage do |context, original|
      path = Dir.glob(File.join(context.fetch("directory"), "*.json")).fetch(0)
      bytes = File.binread(path)
      result = JSON.parse(bytes)
      File.unlink(path)
      interrupted = lambda do |pending, destination|
        assert_equal path, destination
        assert_equal result, JSON.parse(File.binread(pending))
        assert_equal 0o600, File.stat(pending).mode & 0o777
        refute File.exist?(destination)
        assert_raises(RuntimeError) { FeedbackCoverage.collect(context) }
        raise IOError, "interrupted coverage publication"
      end
      File.stub(:link, interrupted) do
        assert_raises(IOError) { FeedbackCoverage.publish_result(path, result) }
      end
      refute File.exist?(path)
      refute File.exist?("#{path}.pending")
      FeedbackCoverage.publish_result(path, result)
      assert_equal original, FeedbackCoverage.collect(context)
      assert_equal bytes, File.binread(path)
      assert_raises(Errno::EEXIST) { FeedbackCoverage.publish_result(path, result.merge("invocation" => "changed")) }
      assert_equal bytes, File.binread(path)
      File.binwrite("#{path}.pending", "unowned")
      assert_raises(Errno::EEXIST) { FeedbackCoverage.publish_result(path, result) }
      assert_equal "unowned", File.binread("#{path}.pending")
      File.unlink("#{path}.pending")

      prefix = File.join(context.fetch("directory"), "interrupted-fixture")
      File.write("#{prefix}.started", JSON.generate("pid" => Process.pid))
      File.write("#{prefix}.json.pending", "{\"partial\":")
      assert_equal original, FeedbackCoverage.collect(context)
      File.write("#{prefix}.active", "ACT source executed\n")
      error = assert_raises(RuntimeError) { FeedbackCoverage.collect(context) }
      assert_includes error.message, "incomplete ACT-executing child evidence"
      File.unlink("#{prefix}.active")
      File.write("#{prefix}.json", "")
      assert_raises(JSON::ParserError) { FeedbackCoverage.collect(context) }
    end
  end

  # The opposite branch executes only in a genuinely cold Ruby child. Losing
  # its preload leaves that branch uncovered and fails the same direct floor.
  def test_cold_child_visibility_and_missing_instrumentation
    with_coverage(cold: :instrumented) do |context, map|
      assert_equal 2, Dir.glob(File.join(context.fetch("directory"), "*.started")).length
      assert_equal 2, FeedbackCoverage.summary(map).fetch("branch").fetch("covered")
      assert TestFeedback.coverage_gate(FeedbackCoverage.summary(map), { "line" => 0, "branch" => 100 })
    end
    with_coverage(cold: :missing) do |_context, map|
      assert_raises(RuntimeError) { TestFeedback.coverage_gate(FeedbackCoverage.summary(map), { "line" => 0, "branch" => 100 }) }
    end
    with_coverage do |context, _map|
      outcome, error, = coverage_probe(context, 'late')
      refute outcome.fetch(:status).success?
      assert_includes error, "instrumentation started after production load"
    end
  end

  # Runtime comparability, advisory growth and budget failure are independent.
  # These synthetic acceptance values apply only to this direct policy control.
  def test_fixed_reference_noncomparable_advisory_and_budget
    conditions = { "seed" => 2300, "coverage_mode" => "line-and-branch" }
    reference = { "qualified" => true, "conditions" => conditions, "source_sha256" => "f" * 64, "outer_seconds" => 10.0 }
    comparison = TestFeedback.runtime_report(11.1, conditions, reference)
    assert comparison.fetch("advisory_growth")
    assert TestFeedback.budget_gate(11.1, 12, comparison)
    assert_raises(RuntimeError) { TestFeedback.budget_gate(12.1, 12, comparison) }
    changed = TestFeedback.runtime_report(10, conditions.merge("seed" => 1), reference)
    refute changed.fetch("comparable")
    assert_equal ["seed"], changed.fetch("changed_conditions")
    assert_raises(RuntimeError) { TestFeedback.budget_gate(10, 12, changed) }
    refute TestFeedback.runtime_report(10, conditions, nil).fetch("comparable")
    refute TestFeedback.runtime_report(10, conditions, reference.merge("source_sha256" => "missing")).fetch("comparable")
    assert_in_delta 10, reference.fetch("outer_seconds")
    outcome, = capture('short_sleep')
    assert outcome.fetch(:status).success?
    refute outcome.fetch(:timeout)
    assert_raises(RuntimeError) { TestFeedback.budget_gate(outcome.fetch(:seconds), 0.001, comparison) }
  end

  # Case inventory failures cannot be masked by a success status or total count.
  # Summary, independent case evidence and fresh invocation must agree exactly.
  def test_required_case_summary_and_freshness_refusals
    Dir.mktmpdir("act-feedback-results-") do |root|
      path = File.join(root, "results.json")
      result = { "invocation" => "fresh", "selection" => "one", "seed" => 2300,
        "results" => [{ "case" => "Example#test_one", "assertions" => 1, "status" => "pass" }] }
      File.write(path, JSON.generate(result))
      summary = "1 runs, 1 assertions, 0 failures, 0 errors, 0 skips\n"
      options = { label: "control", invocation: "fresh", selection: "one" }
      assert_equal result, TestSuiteRunner.validate(summary, path, ["Example#test_one"], **options)
      _output, diagnostics = capture_io do
        ["", "malformed\n", "0 runs, 0 assertions, 0 failures, 0 errors, 0 skips\n"].each do |output|
          assert_raises(SystemExit) { TestSuiteRunner.validate(output, path, ["Example#test_one"], **options) }
        end
        assert_raises(SystemExit) { TestSuiteRunner.validate(summary, path, ["Example#test_missing"], **options) }
        assert_raises(SystemExit) { TestSuiteRunner.validate(summary, path, ["Example#test_one"], **options.merge(invocation: "stale")) }
        %w[skip failure error].each do |status|
          result.fetch("results").first["status"] = status
          File.write(path, JSON.generate(result))
          assert_raises(SystemExit) { TestSuiteRunner.validate(summary, path, ["Example#test_one"], **options) }
        end
      end
      assert_includes diagnostics, "control: missing or malformed test summary"
      assert_includes diagnostics, "control: empty, failed, skipped or malformed case evidence"
    end
  end

  # Exercises real Rake prerequisites with a finite layer recorder, never nested
  # product suites. Restores the invoking Rake application and feedback context.
  # Yields the actual tasks; exceptions propagate after restoration.
  def with_tasks
    application = Rake.application
    context = TestFeedback.instance_variable_get(:@context)
    Rake.application = Rake::Application.new
    recorded = { "stages" => [] }
    TestFeedback.instance_variable_set(:@context, recorded)
    load File.expand_path("../../Rakefile", __dir__)
    runner = lambda do |layer, root:|
      assert_equal File.expand_path("../..", __dir__), root
      recorded.fetch("stages") << { "layer" => layer.to_s, "complete" => true }
    end
    TestFeedback.stub(:run, runner) { yield recorded }
  ensure
    TestFeedback.instance_variable_set(:@context, context)
    Rake.application = application
  end

  # Both public complete names share one ordered gate, without recursion or
  # duplicate layers. A removed aggregate handoff makes that same gate fail.
  def test_complete_alias_once_and_broken_layer
    with_tasks do |recorded|
      Rake::Task["test:integration"].invoke
      Rake::Task["test:all"].invoke
      assert_equal TestFeedback::REQUIRED_LAYERS, recorded.fetch("stages").map { |stage| stage.fetch("layer") }
      assert recorded.fetch("complete_offline_gate")
    end
    with_tasks do |_recorded|
      Rake::Task["test:native_default"].clear
      assert_raises(RuntimeError) { Rake::Task["test:all"].invoke }
    end
    with_tasks do |recorded|
      Rake::Task["test:native_integration"].invoke
      assert_equal ["native_integration"], recorded.fetch("stages").map { |stage| stage.fetch("layer") }
      refute recorded["complete_offline_gate"]
    end
  end

  # The default validates configured YAML before exactly the ordinary layer.
  # Bad YAML fails before feedback and no ordinary-only result marks full proof.
  def test_default_yaml_then_ordinary_and_bad_yaml_refusal
    previous = ENV["AGENT_CODING_TOOL_DATA_DIR"]
    Dir.mktmpdir("act-feedback-yaml-") do |root|
      ENV["AGENT_CODING_TOOL_DATA_DIR"] = root
      File.write(File.join(root, "config.yml"), "---\nrepo_root: ..\n")
      with_tasks do |recorded|
        Rake::Task["default"].invoke
        Rake::Task["test:ordinary"].invoke
        assert_equal ["ordinary"], recorded.fetch("stages").map { |stage| stage.fetch("layer") }
        refute recorded["complete_offline_gate"]
      end
      File.write(File.join(root, "config.yml"), "invalid: [\n")
      with_tasks do |recorded|
        assert_raises(Psych::SyntaxError) { Rake::Task["default"].invoke }
        assert_empty recorded.fetch("stages")
      end
    end
  ensure
    ENV["AGENT_CODING_TOOL_DATA_DIR"] = previous
  end

  # The actual delivery consumer refuses a passing ordinary ACT summary. A
  # complete accepted marker and aggregate counts remain usable by its existing
  # trusted validation contract. No provider, Git or publication path is invoked.
  def test_delivery_requires_complete_act_feedback
    Dir.mktmpdir("act-feedback-consumer-") do |root|
      manager = AgentCodingTool::DeliveryManager.allocate
      policy = { "max_seconds" => 2, "min_tests" => 1, "min_assertions" => 1 }
      ordinary = "ACT feedback evidence: fixture\n1 tests, 1 assertions, 0 failures, 0 errors, 0 skips\n"
      File.write(File.join(root, 'fixture-validation.rb'), File.binread(File.join(ChildProcesses::FIXTURES, 'validation_worker.rb')))
      command = validation_command(ordinary)
      error = assert_raises(AgentCodingTool::InvalidState) { with_validation_processes { manager.send(:run_command!, root, root, command, 0, policy) } }
      assert_match(/partial ACT feedback/, error.message)
      full = ordinary + "ACT complete offline acceptance: PASS\n"
      result = with_validation_processes { manager.send(:run_command!, root, root, validation_command(full), 1, policy) }
      assert_equal 0, result.fetch("exit_status")
      assert_equal [1, 1, 0, 0, 0], result.fetch("counts")
    end
  end
end
