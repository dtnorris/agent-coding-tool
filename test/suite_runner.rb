# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"
require "shellwords"
require "securerandom"

# Runs fixed behavior inventories against independent child-test evidence.
# Feedback supplies source coverage separately; case names are not that measure.
module TestSuiteRunner
  PATTERNS = {
    default: "test/**/*_test.rb",
    ordinary: "test/**/*_test.rb",
    native_default: "test/**/*_test.rb",
    integration: "test/integration/*_git_integration.rb",
    native_integration: "test/integration/*_git_integration.rb",
    git_contract: "test/git_contract/**/*_contract.rb"
  }.freeze
  SUMMARY = /\A(\d+) (?:runs|tests), (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips\r?$/n

  # Runs a named suite at root; returns true only for complete passing case evidence.
  # Exits with a child's exact nonzero status (128+signal for signals), or 1 for
  # missing/invalid coverage evidence. JSON, filesystem and spawn errors propagate.
  def self.run(suite, root:, feedback: nil)
    manifest_path = suite == :git_contract ? "test/git_contract/required_cases.json" : "test/required_cases.json"
    abort "#{suite}: missing required inventory #{manifest_path}" unless File.file?(File.join(root, manifest_path))
    inventory = JSON.parse(File.binread(File.join(root, manifest_path)))
    key = %i[ordinary native_default].include?(suite) ? "default" : suite == :native_integration ? "integration" : suite.to_s
    required = suite == :git_contract ? inventory : inventory.fetch(key)
    abort "#{suite}: empty required coverage" unless required.is_a?(Hash) && !required.empty?
    files = Dir.glob(PATTERNS.fetch(suite), base: root).sort
    abort "#{suite}: discovered files differ from required inventory" unless files == required.keys.sort
    required.each do |path, cases|
      unless cases.is_a?(Array) && !cases.empty? && cases.all? { |name| name.is_a?(String) && name.include?("#test_") } && cases.uniq == cases
        abort "#{suite}: invalid required cases for #{path}"
      end
    end
    if %i[default ordinary native_default].include?(suite)
      ordinary = JSON.parse(File.binread(File.join(root, "test/ordinary_cases.json")))
      abort "ordinary: empty required scope" if ordinary.empty?
      ordinary.each do |path, cases|
        unless cases.is_a?(Hash) && !cases.empty? && required.key?(path) &&
               (cases.keys - required.fetch(path)).empty? && cases.values.all? { |reads|
                 reads.is_a?(Array) && (reads - %w[coding planning]).empty? }
          abort "ordinary: invalid scope or source observations for #{path}"
        end
      end
      native = inventory.fetch("native_default")
      abort "default: empty required native scope" unless native.is_a?(Hash) && !native.empty?
      native.each do |path, cases|
        unless cases.is_a?(Array) && !cases.empty? && cases.uniq == cases && required.key?(path) &&
               (cases - required.fetch(path)).empty? && (cases & ordinary.fetch(path, {}).keys).empty?
          abort "default: invalid native scope for #{path}"
        end
      end
      unless (ordinary.keys | native.keys).sort == required.keys.sort && required.all? { |path, cases|
        (ordinary.fetch(path, {}).keys + native.fetch(path, [])).sort == cases.sort }
        abort "default: ordinary/native scopes must exactly partition required cases"
      end
      unless suite == :native_default
        run_process(ordinary.keys.sort, ordinary.values.flat_map(&:keys), root: root, ordinary: true, selected: true, feedback: feedback)
      end
      return true if suite == :ordinary

      run_process(native.keys.sort, native.values.flatten, root: root, selected: true, feedback: feedback) unless native.empty?
      return true
    end
    groups = files.map { |path| [path] }
    groups.each { |paths| run_process(paths, required.values_at(*paths).flatten, root: root, feedback: feedback) }
    true
  end

  # Executes selected root-relative files in one Ruby process with raw output.
  # Returns true on matching positive results; exits on failed process/evidence.
  # ordinary preloads the execution guard before setup; selected filters only
  # the declared identities. SEED retains Minitest's standard environment control.
  # Feedback supplies a separately accepted hang deadline and fresh coverage.
  # Filesystem/spawn errors propagate after raw output is replayed unchanged.
  def self.run_process(paths, required_cases, root:, ordinary: false, selected: false, feedback: nil)
    Dir.mktmpdir("act-suite-") do |directory|
      evidence_path = File.join(directory, "results.json")
      stdout_path, stderr_path = %w[stdout stderr].map { |name| File.join(directory, name) }
      argv = [RbConfig.ruby, "-Ilib:test", "-r", File.join(root, "test/suite_reporter.rb"),
              "-e", "paths = ARGV.shift(Integer(ARGV.shift)); paths.each { |path| require File.expand_path(path) }", paths.length.to_s, *paths]
      if selected
        argv += ["--name", "/\\A(?:#{required_cases.map { |name| Regexp.escape(name) }.join('|')})\\z/"]
      end
      invocation = SecureRandom.uuid
      selection = required_cases.sort.join("\n")
      environment = { "ACT_SUITE_EVIDENCE" => evidence_path, "ACT_ORDINARY_SUITE" => nil,
                      "ACT_TEST_CODING_SKILL" => nil, "ACT_SUITE_INVOCATION" => invocation,
                      "ACT_SUITE_SELECTION" => selection }
      record = nil
      if feedback
        additions, record = TestFeedback.child(feedback, paths, required_cases)
        environment.merge!(additions)
        stdout_path, stderr_path = %w[stdout stderr].map { |name| File.join(record.fetch("coverage_context").fetch("directory"), name) }
        record["argv"], record["cwd"] = argv, root
      end
      if ordinary
        # Ruby executes command-line -r before RUBYOPT -r. Explicit preloads
        # below protect helpers; inherited RUBYOPT also protects cold children.
        boundary = File.join(root, "test/ordinary_execution.rb")
        environment.merge!("ACT_ORDINARY_SUITE" => "1",
          "RUBYOPT" => Shellwords.join(["-r#{boundary}", *Shellwords.split(environment.fetch("RUBYOPT", ENV.fetch("RUBYOPT", "")))]))
        argv.insert(2, "-r", File.join(root, "test/ordinary_support.rb"))
      end
      argv.insert(2, "-r", File.join(root, "test/feedback_coverage.rb")) if feedback
      argv.insert(2, "-r", File.join(root, "test/ordinary_execution.rb")) if ordinary
      begin
        if feedback
          remaining = TestFeedback.context(root).fetch("hard_deadline_seconds") - FeedbackRuntime.elapsed(TestFeedback.timer)
          abort "feedback: hard deadline reached before next suite" unless remaining.positive?
          outcome = FeedbackRuntime.capture(argv, environment: environment, root: root, seconds: remaining,
            stdout_path: stdout_path, stderr_path: stderr_path)
          status = outcome.fetch(:status)
          record.merge!("exit_status" => status.exitstatus, "signal" => status.termsig,
                        "timeout" => outcome.fetch(:timeout), "seconds" => outcome.fetch(:seconds),
                        "observed_owned_processes" => outcome.fetch(:observed_processes),
                        "process_count_scope" => "one direct suite child plus sampled descendants; short-lived/escaped-before-observation processes unknown",
                        "stdout" => stdout_path, "stderr" => stderr_path)
          abort "feedback: hard hang deadline; verification incomplete" if outcome.fetch(:timeout)
        else
          pid = Process.spawn(environment, *argv, chdir: root, out: stdout_path, err: stderr_path)
          _child, status = Process.wait2(pid)
        end
      rescue Exception => exception
        record["exception"] = { "class" => exception.class.name, "message" => exception.message } if record
        raise
      ensure
        stdout, stderr = [stdout_path, stderr_path].map { |path| File.file?(path) ? File.binread(path) : "".b }
        $stdout.write(stdout)
        $stderr.write(stderr)
      end
      exit(status.exitstatus || 128 + status.termsig) unless status.success?
      evidence = validate(stdout, evidence_path, required_cases, label: paths.join(", "), invocation: invocation, selection: selection)
      if record
        record["seed"] = evidence.fetch("seed")
        record["tests"] = evidence.fetch("results").length
        record["assertions"] = evidence.fetch("results").sum { |result| result.fetch("assertions") }
        record["coverage"] = FeedbackCoverage.collect(record.fetch("coverage_context"))
        child_directory = record.fetch("coverage_context").fetch("directory")
        record["instrumented_interpreters"] = Dir.glob(File.join(child_directory, "*.started")).map do |path|
          prefix = path.delete_suffix(".started")
          JSON.parse(File.binread(path)).merge("complete" => File.file?("#{prefix}.json"), "executed_production" => File.file?("#{prefix}.active"))
        end
        record["complete"] = true
      end
    end
    true
  end

  # Checks stdout summary against independently recorded identities and counts.
  # Returns the verified evidence envelope, or exits 1 for missing/malformed,
  # unregistered, duplicated,
  # empty, skipped or failed results. Case identities must match exactly.
  # Invalid JSON and filesystem errors propagate and fail the invoking Rake task.
  def self.validate(stdout, evidence_path, required_cases, label:, invocation:, selection:)
    summaries = stdout.lines.filter_map { |line| SUMMARY.match(line.chomp)&.captures&.map(&:to_i) }
    abort "#{label}: missing or malformed test summary" unless summaries.length == 1
    evidence = JSON.parse(File.binread(evidence_path))
    abort "#{label}: stale, missing or contradictory invocation/selection" unless evidence.is_a?(Hash) &&
      evidence.values_at("invocation", "selection") == [invocation, selection] && evidence["seed"].is_a?(Integer)
    results = evidence.fetch("results")
    unless results.is_a?(Array) && !results.empty? && results.all? { |row|
      row.is_a?(Hash) && row["case"].is_a?(String) && row["assertions"].is_a?(Integer) && row["assertions"] >= 0 && row["status"] == "pass"
    }
      abort "#{label}: empty, failed, skipped or malformed case evidence"
    end
    cases = results.map { |row| row.fetch("case") }
    abort "#{label}: missing required case, unregistered case or duplicate execution" unless required_cases.sort == cases.sort && cases.uniq == cases
    expected = [results.length, results.sum { |row| row.fetch("assertions") }, 0, 0, 0]
    abort "#{label}: inconsistent or empty test summary" unless expected[1].positive? && summaries.first == expected
    evidence
  end
end
