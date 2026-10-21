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

# Small native controls for the verifier, without running the product suite.
# Children and sentinels are finite, fixture-owned Ruby processes only.
class FeedbackContract < Minitest::Test
  # Captures a finite Ruby script using the actual watchdog and output paths.
  # Returns outcome and byte streams; spawn exceptions propagate unchanged.
  def capture(script, seconds: 2, arguments: [])
    Dir.mktmpdir("act-feedback-control-") do |root|
      output, error = %w[out err].map { |name| File.join(root, name) }
      result = FeedbackRuntime.capture([RbConfig.ruby, "-e", script, *arguments],
        environment: { "ACT_COVERAGE_CONTEXT" => nil, "RUBYOPT" => nil }, root: root,
        seconds: seconds, stdout_path: output, stderr_path: error)
      [result, File.binread(output), File.binread(error)]
    end
  end

  # Text/binary output, nonzero status, and signal facts must remain exact.
  def test_bytes_exit_and_signal
    outcome, output, error = capture('STDOUT.binmode; STDERR.binmode; STDOUT.write("text\n".b + [0,255,128].pack("C*")); STDERR.write([254,0].pack("C*")); exit 7')
    assert_equal "text\n\x00\xff\x80".b, output
    assert_equal "\xfe\x00".b, error
    assert_equal 7, outcome.fetch(:status).exitstatus
    assert_nil outcome.fetch(:status).termsig
    refute outcome.fetch(:timeout)
    outcome, = capture('Process.kill("TERM", Process.pid)')
    assert_equal Signal.list.fetch("TERM"), outcome.fetch(:status).termsig
    refute outcome.fetch(:timeout)
  end

  # An actual failed spawn raises ENOENT and never becomes an exit/status pass.
  def test_spawn_exception_and_invalid_deadline
    Dir.mktmpdir("act-feedback-spawn-") do |root|
      options = { environment: {}, root: root, seconds: 1,
                  stdout_path: File.join(root, "out"), stderr_path: File.join(root, "err") }
      assert_raises(Errno::ENOENT) { FeedbackRuntime.capture([File.join(root, "missing")], **options) }
      assert_raises(ArgumentError) { FeedbackRuntime.capture([RbConfig.ruby], **options.merge(seconds: Float::INFINITY)) }
    end
    observer = File.expand_path("../feedback_runtime.rb", __dir__)
    script = "require #{observer.inspect}; require 'tmpdir'; exception = Interrupt.new('control'); Thread.new { sleep 0.05; Thread.main.raise(exception) }; Dir.mktmpdir { |root| begin; FeedbackRuntime.capture([RbConfig.ruby, '-e', 'sleep 5'], environment: {}, root: root, seconds: 2, stdout_path: File.join(root,'out'), stderr_path: File.join(root,'err')); rescue Interrupt => observed; puts observed.equal?(exception); exit 130; end }"
    outcome, output, = capture(script)
    assert_equal "true\n", output
    assert_equal 130, outcome.fetch(:status).exitstatus
  end

  # A hung descendant in a distinct owned group cannot keep the verifier alive;
  # an unrelated sibling sentinel remains alive and is separately reaped here.
  def test_hung_owned_descendant_and_unrelated_sentinel
    sentinel = Process.spawn(RbConfig.ruby, "-e", "sleep 5", pgroup: true, out: File::NULL, err: File::NULL)
    Dir.mktmpdir("act-feedback-hang-") do |root|
      marker = File.join(root, "descendant")
      script = 'require "rbconfig"; child = Process.spawn(RbConfig.ruby, "-e", "sleep 5", pgroup: true); File.write(ARGV.fetch(0), child); STDOUT.binmode; STDOUT.write([0,255].pack("C*")); STDOUT.flush; sleep 5'
      started = FeedbackRuntime.clock
      outcome, output, = capture(script, seconds: 0.2, arguments: [marker])
      assert outcome.fetch(:timeout)
      assert_equal Signal.list.fetch("KILL"), outcome.fetch(:status).termsig
      assert_operator FeedbackRuntime.clock - started, :<, 2
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
    outcome, output, = capture("sleep 0.03; require #{library.inspect}; puts FeedbackRuntime.elapsed(FeedbackRuntime.outer_timer)")
    assert outcome.fetch(:status).success?
    observed = Float(output)
    assert_operator observed, :>=, 0.03
    assert_in_delta FeedbackRuntime.clock - started, observed, 0.1
  end

  # Produces real fresh coverage for one branch and an unloaded source file.
  # Yields the context and map; fixture/hook failures are assertion failures.
  def with_coverage(cold: nil)
    Dir.mktmpdir("act-feedback-coverage-") do |root|
      FileUtils.mkdir_p([File.join(root, "lib"), File.join(root, "bin"), File.join(root, "results")])
      File.write(File.join(root, "lib/loaded.rb"), "module CoveredExample\n def self.choose(value)\n if value\n 1\n else\n 2\n end\n end\nend\n")
      File.write(File.join(root, "lib/unloaded.rb"), "module UnloadedExample\n def self.value\n 3\n end\nend\n")
      File.write(File.join(root, "bin/agent-coding-tool"), "puts :unused\n")
      context = { "root" => root, "sources" => FeedbackCoverage.sources(root), "layout" => FeedbackCoverage.layout(root), "invocation" => "fresh-control",
                  "selection" => "one-branch", "stage" => "control", "directory" => File.join(root, "results") }
      context_path = File.join(root, "context.json")
      File.write(context_path, JSON.generate(context))
      output, error = %w[out err].map { |name| File.join(root, name) }
      hook = File.expand_path("../feedback_coverage.rb", __dir__)
      script = 'require_relative "lib/loaded"; CoveredExample.choose(true)'
      if cold
        environment = cold == :missing ? { "ACT_COVERAGE_CONTEXT" => nil, "RUBYOPT" => nil } : {}
        script += "; require 'rbconfig'; child = Process.spawn(#{environment.inspect}, RbConfig.ruby, '-e', 'require_relative \"lib/loaded\"; CoveredExample.choose(false)'); Process.waitpid(child)"
      end
      outcome = FeedbackRuntime.capture([RbConfig.ruby, "-e", script],
        environment: { "ACT_COVERAGE_CONTEXT" => context_path, "RUBYOPT" => "-r#{hook}" }, root: root,
        seconds: 2, stdout_path: output, stderr_path: error)
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
    hook = File.expand_path("../feedback_coverage.rb", __dir__)
    outcome = FeedbackRuntime.capture([RbConfig.ruby, "-e", script],
      environment: { "ACT_COVERAGE_CONTEXT" => context_path, "RUBYOPT" => "-r#{hook}" },
      root: context.fetch("root"), seconds: 2,
      stdout_path: File.join(directory, "out"), stderr_path: File.join(directory, "err"))
    [outcome, File.binread(File.join(directory, "err")), child]
  end

  # Nested denominator compilation must not contaminate production evidence,
  # even after fixture deletion. Executed fixtures and changed production/copies
  # must still fail, including mutations after the first production line.
  def test_nested_layout_isolation_and_changed_source_refusal
    with_coverage do |context, expected|
      prefix = 'require_relative "lib/loaded"; CoveredExample.choose(true); '
      nested = <<~RUBY
        require 'tmpdir'; require 'fileutils'
        Dir.mktmpdir('nested-', Dir.pwd) do |root|
          FileUtils.mkdir_p([File.join(root, 'lib'), File.join(root, 'bin')])
          File.write(File.join(root, 'lib/synthetic.rb'), "puts :fixture\n")
          File.write(File.join(root, 'bin/agent-coding-tool'), "puts :unused\n")
          FeedbackCoverage.layout(root)
          %s
        end
      RUBY
      outcome, error, child = coverage_probe(context, prefix + (nested % ""))
      assert outcome.fetch(:status).success?, error
      assert_equal expected, FeedbackCoverage.collect(child)

      outcome, error, child = coverage_probe(context, prefix + (nested % "load File.join(root, 'bin/agent-coding-tool')"))
      refute outcome.fetch(:status).success?
      assert_includes error, "coverage: changed source"
      assert_raises(RuntimeError) { FeedbackCoverage.collect(child) }

      # The copied CLI has identical bytes and identity until deliberately
      # changed. It is not registered as an independently compiled fixture.
      copy = <<~RUBY
        require 'fileutils'
        FileUtils.mkdir_p('copy/bin')
        FileUtils.cp('bin/agent-coding-tool', 'copy/bin/agent-coding-tool')
        load 'copy/bin/agent-coding-tool'
        %s
      RUBY
      outcome, error, child = coverage_probe(context, prefix + (copy % ""))
      assert outcome.fetch(:status).success?, error
      assert_operator FeedbackCoverage.collect(child).fetch("bin/agent-coding-tool").fetch("line:1"), :>, 0
      ["File.write('copy/bin/agent-coding-tool', 'puts :changed')",
       "File.unlink('copy/bin/agent-coding-tool')"].each do |mutation|
        outcome, error, child = coverage_probe(context, prefix + (copy % mutation))
        refute outcome.fetch(:status).success?
        assert_includes error, "coverage: changed source"
        assert_raises(RuntimeError) { FeedbackCoverage.collect(child) }
      end

      # A changed copy compiled outside layout remains subject to byte checks,
      # even if every node has zero hits.
      outcome, error, child = coverage_probe(context, prefix + <<~RUBY)
        File.write('copy/bin/agent-coding-tool', 'puts :changed')
        RubyVM::InstructionSequence.compile_file('copy/bin/agent-coding-tool', coverage_enabled: true)
      RUBY
      refute outcome.fetch(:status).success?
      assert_includes error, "coverage: changed source"
      assert_raises(RuntimeError) { FeedbackCoverage.collect(child) }

      path = File.join(context.fetch("root"), "lib/loaded.rb")
      bytes = File.binread(path)
      begin
        outcome, error, child = coverage_probe(context, prefix + "File.write('lib/loaded.rb', '# changed production')")
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
      root = context.fetch("root")
      hook = File.expand_path("../feedback_coverage.rb", __dir__)
      outcome = FeedbackRuntime.capture([RbConfig.ruby, "-r", File.join(root, "lib/loaded.rb"), "-e", "CoveredExample.choose(true)"],
        environment: { "ACT_COVERAGE_CONTEXT" => File.join(root, "context.json"), "RUBYOPT" => "-r#{hook}" },
        root: root, seconds: 2, stdout_path: File.join(root, "late-out"), stderr_path: File.join(root, "late-err"))
      refute outcome.fetch(:status).success?
      assert_includes File.binread(File.join(root, "late-err")), "instrumentation started after production load"
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
    outcome, = capture("sleep 0.02")
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
      command = [RbConfig.ruby, "-e", "print #{ordinary.inspect}"]
      error = assert_raises(AgentCodingTool::InvalidState) { manager.send(:run_command!, root, root, command, 0, policy) }
      assert_match(/partial ACT feedback/, error.message)
      full = ordinary + "ACT complete offline acceptance: PASS\n"
      result = manager.send(:run_command!, root, root, [RbConfig.ruby, "-e", "print #{full.inspect}"], 1, policy)
      assert_equal 0, result.fetch("exit_status")
      assert_equal [1, 1, 0, 0, 0], result.fetch("counts")
    end
  end
end
