# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"

# Runs the task's fixed coverage contract against independent child-test evidence.
module TestSuiteRunner
  PATTERNS = {
    default: "test/**/*_test.rb",
    integration: "test/integration/*_git_integration.rb",
    git_contract: "test/git_contract/**/*_contract.rb"
  }.freeze
  SUMMARY = /\A(\d+) (?:runs|tests), (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips\r?$/n

  # Runs a named suite at root; returns true only for complete passing coverage.
  # Exits with a child's exact nonzero status (128+signal for signals), or 1 for
  # missing/invalid coverage evidence. JSON, filesystem and spawn errors propagate.
  def self.run(suite, root:)
    manifest_path = suite == :git_contract ? "test/git_contract/required_cases.json" : "test/required_cases.json"
    abort "#{suite}: missing required inventory #{manifest_path}" unless File.file?(File.join(root, manifest_path))
    inventory = JSON.parse(File.binread(File.join(root, manifest_path)))
    required = suite == :git_contract ? inventory : inventory.fetch(suite.to_s)
    abort "#{suite}: empty required coverage" unless required.is_a?(Hash) && !required.empty?
    files = Dir.glob(PATTERNS.fetch(suite), base: root).sort
    abort "#{suite}: discovered files differ from required inventory" unless files == required.keys.sort
    required.each do |path, cases|
      unless cases.is_a?(Array) && !cases.empty? && cases.all? { |name| name.is_a?(String) && name.include?("#test_") } && cases.uniq == cases
        abort "#{suite}: invalid required cases for #{path}"
      end
    end
    groups = suite == :default ? [files] : files.map { |path| [path] }
    groups.each { |paths| run_process(paths, required.values_at(*paths).flatten, root: root) }
    true
  end

  # Executes selected root-relative files in one Ruby process with raw output.
  # Returns true on matching positive results; exits on failed process/evidence.
  # Filesystem/spawn errors propagate; no total integration timeout is imposed.
  def self.run_process(paths, required_cases, root:)
    Dir.mktmpdir("act-suite-") do |directory|
      evidence_path = File.join(directory, "results.json")
      stdout_path, stderr_path = %w[stdout stderr].map { |name| File.join(directory, name) }
      argv = [RbConfig.ruby, "-Ilib:test", "-r", File.join(root, "test/suite_reporter.rb"),
              "-e", "ARGV.each { |path| require File.expand_path(path) }", *paths]
      pid = Process.spawn({ "ACT_SUITE_EVIDENCE" => evidence_path }, *argv,
                          chdir: root, out: stdout_path, err: stderr_path)
      _child, status = Process.wait2(pid)
      stdout, stderr = [stdout_path, stderr_path].map { |path| File.binread(path) }
      $stdout.write(stdout)
      $stderr.write(stderr)
      exit(status.exitstatus || 128 + status.termsig) unless status.success?
      validate(stdout, evidence_path, required_cases, label: paths.join(", "))
    end
    true
  end

  # Checks stdout summary against independently recorded identities and counts.
  # Returns true, or exits 1 for missing/malformed, empty, skipped or failed results.
  # Invalid JSON and filesystem errors propagate and fail the invoking Rake task.
  def self.validate(stdout, evidence_path, required_cases, label:)
    summaries = stdout.lines.filter_map { |line| SUMMARY.match(line.chomp)&.captures&.map(&:to_i) }
    abort "#{label}: missing or malformed test summary" unless summaries.length == 1
    results = JSON.parse(File.binread(evidence_path))
    unless results.is_a?(Array) && !results.empty? && results.all? { |row|
      row.is_a?(Hash) && row["case"].is_a?(String) && row["assertions"].is_a?(Integer) && row["assertions"] >= 0 && row["status"] == "pass"
    }
      abort "#{label}: empty, failed, skipped or malformed case evidence"
    end
    cases = results.map { |row| row.fetch("case") }
    abort "#{label}: missing required case or duplicate execution" unless (required_cases - cases).empty? && cases.uniq == cases
    expected = [results.length, results.sum { |row| row.fetch("assertions") }, 0, 0, 0]
    abort "#{label}: inconsistent or empty test summary" unless expected[1].positive? && summaries.first == expected
    true
  end
end
