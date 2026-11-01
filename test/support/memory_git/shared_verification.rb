# frozen_string_literal: true

# Invocation-local evidence only; no hit/result cache is reused across runs.
module SharedEvidence
  # Returns mutable timing records for this verifier invocation, not acceptance.
  def self.startups = (@startups ||= [])
end

# Reconciles a fixed additive component inventory and independent result evidence.
module SharedVerification
  # Installs per-invocation evidence for the exact loaded case classes. Refuses
  # filtering, duplicates, skipped/missing/failed results and source drift.
  def self.install(classes, manifest)
    required = JSON.parse(File.binread(File.join(__dir__, manifest)))
    actual = classes.flat_map { |type| type.public_instance_methods.grep(/^test_/).map { |name| "#{type.name}##{name}" } }.sort
    raise "shared verifier inventory differs" unless actual == required.sort
    mapping = JSON.parse(File.binread(File.join(__dir__, "shared_case_map.json"))).fetch("cases")
    legacy = JSON.parse(File.binread(File.join(__dir__, "../../required_cases.json"))).values.flat_map { |files| files.values.flatten }.uniq
    raise "unknown shared prior case" unless (mapping.flat_map { |row| row.fetch("prior_cases") } - legacy).empty?
    raise "shared case map differs" unless (mapping.flat_map { |row| row.fetch("new_cases") } & required).sort == required.sort
    raise "shared verifier refuses filtering" if ARGV.any? { |argument| argument.match?(/\A(?:-n|-e|--name|--exclude)/) }
    ENV["ACT_SUITE_INVOCATION"] = SecureRandom.uuid
    ENV["ACT_SUITE_SELECTION"] = required.sort.join("\n")
    ENV["ACT_SUITE_EVIDENCE"] = ENV["MEMORY_SHARED_EVIDENCE"] || File.join(Dir.mktmpdir("shared-results-"), "results.json")
    raise "shared evidence already exists" if File.exist?(ENV.fetch("ACT_SUITE_EVIDENCE"))
    source_root = File.expand_path("../../..", __dir__)
    source_paths = (Dir.glob("test/**/*.rb", base: source_root) + Dir.glob("test/support/memory_git/**/*", base: source_root) +
      Dir.glob("lib/**/*.rb", base: source_root) + %w[bin/agent-coding-tool Gemfile.lock]).select { |path| File.file?(File.join(source_root, path)) }.sort.uniq
    source = SourceIdentity.capture(root: source_root, paths: source_paths)
    require_relative "../../suite_reporter"

    Minitest.after_run do
      raise "shared source changed during focused run" unless SourceIdentity.capture(root: source_root, paths: source_paths) == source
      path = ENV["MEMORY_SHARED_SOURCE"]
      File.write(path, JSON.pretty_generate(source) + "\n", mode: "wx") if path
      path = ENV["MEMORY_SHARED_AUDIT"]
      File.write(path, JSON.pretty_generate("records" => NoGitExecution.audit, "broker_startups" => SharedEvidence.startups,
        "independent_os_audit" => NoGitExecution.independent_audit) + "\n", mode: "wx") if path
      results = JSON.parse(File.binread(ENV.fetch("ACT_SUITE_EVIDENCE"))).fetch("results")
      raise "missing/failed/duplicate shared case evidence" unless results.map { |row| row.fetch("case") }.sort == required.sort && results.all? { |row| row.fetch("status") == "pass" }
    end
  end
end
