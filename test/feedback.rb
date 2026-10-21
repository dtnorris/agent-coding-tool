# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "securerandom"
require "shellwords"
require "tmpdir"
require "open3"
require_relative "feedback_runtime"
require_relative "feedback_coverage"

# One invocation's coverage, runtime reference and independent hang deadline.
# Policy is operator-owned. Qualification collects evidence but always fails the
# acceptance gate; it cannot manufacture accepted percentages or runtime limits.
module TestFeedback
  RELEVANT_ENV = %w[SEED RUBYOPT BUNDLE_GEMFILE TMPDIR LANG LC_ALL TZ
                    AGENT_CODING_TOOL_DATA_DIR ACT_GIT_CONTRACT_TMPDIR].freeze
  REQUIRED_LAYERS = %w[ordinary git_contract native_default native_integration].freeze

  # Lazily qualifies the current command's kernel birth, so listing Rake tasks
  # and ACTD YAML validation do not require native test-process instrumentation.
  # Returns a timer or raises when the execution platform is unqualified.
  def self.timer
    @timer ||= FeedbackRuntime.outer_timer
  end

  # Returns exact bytes' hashes for production, harness, selections and locked
  # dependencies. Discovery is repeated at completion to reject added files.
  def self.source_files(root)
    paths = (Dir.glob("{lib,test}/**/*.{rb,json}", base: root) + %w[bin/agent-coding-tool Rakefile Gemfile Gemfile.lock]).sort
    paths.to_h { |path| [path, Digest::SHA256.file(File.join(root, path)).hexdigest] }
  end

  # Creates an exclusive invocation directory and reads reviewed policy at root.
  # Returns shared context; missing acceptance remains explicit in qualification.
  # Missing/invalid deadlines, source changes and malformed policy raise.
  def self.context(root)
    return @context if @context

    timer
    policy_path = ENV["ACT_TEST_POLICY"] || File.join(root, "test/feedback_policy.json")
    policy = File.file?(policy_path) ? JSON.parse(File.binread(policy_path)) : {}
    qualification = ENV["ACT_TEST_QUALIFY"] == "1"
    raise "feedback: missing operator-accepted policy #{policy_path}" unless qualification ||
      (policy["accepted_by"] == "David" && policy["reference"].is_a?(Hash))

    seconds = qualification ? Float(ENV.fetch("ACT_TEST_HANG_SECONDS")) : policy.fetch("hard_deadline_seconds")
    raise "feedback: invalid separate hang deadline" unless seconds.is_a?(Numeric) && seconds.finite? && seconds.positive?

    directory = Dir.mktmpdir("act-feedback-")
    head, error, status = Open3.capture3("git", "rev-parse", "HEAD", chdir: root)
    raise "feedback: source HEAD unavailable: #{error}" unless status.success?
    git_version, error, status = Open3.capture3("git", "--version", chdir: root)
    raise "feedback: Git version unavailable: #{error}" unless status.success?
    hashes = source_files(root)
    @context = { "schema" => "act-test-feedback/v1", "invocation" => SecureRandom.uuid,
      "root" => File.realpath(root), "directory" => directory, "head" => head.strip, "git_version" => git_version.strip,
      "source_sha256" => Digest::SHA256.hexdigest(JSON.generate(hashes)), "source_files" => hashes,
      "sources" => FeedbackCoverage.sources(root), "layout" => FeedbackCoverage.layout(root),
      "policy_path" => policy_path, "policy_sha256" => File.file?(policy_path) ? Digest::SHA256.file(policy_path).hexdigest : nil,
      "ordinary_budget_seconds" => policy["ordinary_budget_seconds"], "coverage_expectations" => policy["coverage"],
      "policy" => policy, "qualification" => qualification, "hard_deadline_seconds" => seconds,
      "rake_argv" => ARGV.dup, "cwd" => Dir.pwd, "runtime" => RUBY_DESCRIPTION,
      "platform" => RbConfig::CONFIG.values_at("host_os", "host_cpu"),
      "environment" => RELEVANT_ENV.to_h { |key| [key, ENV[key]] },
      "coverage_mode" => "ruby-lines-branches-all-production-files/v1",
      "fixture_policy" => "fresh disposable fixtures; existing per-process immutable Git seed",
      "contention" => "not observed", "workers" => 1, "stages" => [] }
    at_exit { report }
    puts "ACT feedback evidence: #{directory}"
    @context
  end

  # Runs one required layer at root, once, with fresh child evidence. Returns
  # true, or propagates runner failures/exceptions; coverage never blesses them.
  def self.run(layer, root:)
    current = context(root)
    name = layer.to_s
    raise "feedback: duplicate layer #{name}" if current.fetch("stages").any? { |stage| stage.fetch("layer") == name }

    directory = File.join(current.fetch("directory"), name)
    Dir.mkdir(directory)
    stage = { "layer" => name, "complete" => false, "processes" => [], "directory" => directory }
    current.fetch("stages") << stage
    begun = FeedbackRuntime.clock
    TestSuiteRunner.run(layer, root: root, feedback: stage)
    stage["seconds"] = FeedbackRuntime.clock - begun
    stage["complete"] = true
    if layer == :ordinary && !current.fetch("qualification")
      maps = stage.fetch("processes").map { |process| process.fetch("coverage") }
      coverage_gate(FeedbackCoverage.summary(FeedbackCoverage.merge(maps)), current.fetch("policy").fetch("coverage").fetch("ordinary"))
    end
    true
  end

  # Supplies one suite process's immutable coverage context and remaining hard
  # deadline. Called by the existing runner after validating the case inventory.
  # Returns [environment, context]; source or clock inconsistencies raise.
  def self.child(stage, paths, required_cases)
    current = @context
    index = stage.fetch("processes").length
    directory = File.join(stage.fetch("directory"), index.to_s)
    Dir.mkdir(directory)
    selection = Digest::SHA256.hexdigest(JSON.generate([paths, required_cases]))
    child = current.slice("root", "invocation", "sources", "layout").merge(
      "selection" => selection, "stage" => stage.fetch("layer"), "directory" => directory)
    context_path = File.join(stage.fetch("directory"), "#{index}.context.json")
    File.write(context_path, JSON.generate(child), mode: "wx")
    preload = File.join(current.fetch("root"), "test/feedback_coverage.rb")
    rubyopt = Shellwords.join(["-r#{preload}", *Shellwords.split(ENV.fetch("RUBYOPT", ""))])
    record = { "selection" => selection, "paths" => paths, "required_cases" => required_cases,
               "coverage_context" => child, "complete" => false }
    stage.fetch("processes") << record
    [{ "ACT_COVERAGE_CONTEXT" => context_path, "RUBYOPT" => rubyopt }, record]
  end

  # Requires every complete layer exactly once before emitting full acceptance.
  # Raises on omissions/duplicates/failure; the integration alias uses this gate.
  def self.complete!
    stages = @context.fetch("stages")
    raise "feedback: incomplete mandatory aggregate" unless stages.map { |stage| stage.fetch("layer") } == REQUIRED_LAYERS &&
      stages.all? { |stage| stage.fetch("complete") }

    @context["complete_offline_gate"] = true
  end

  # Returns comparability conditions, excluding candidate bytes so changes can
  # be compared with one fixed, separately identified accepted source reference.
  # Observed seed/selection come from completed independent suite evidence.
  def self.conditions(current)
    current.slice("runtime", "platform", "git_version", "root", "cwd", "environment", "coverage_mode", "fixture_policy", "workers", "rake_argv").merge(
      "lockfile" => current.fetch("source_files").fetch("Gemfile.lock"),
      "selections" => current.fetch("stages").map { |stage|
        [stage.fetch("layer"), stage.fetch("processes").map { |process| process.fetch("selection") }] },
      "observed_seeds" => current.fetch("stages").flat_map { |stage| stage.fetch("processes").map { |process| process["seed"] } })
  end

  # Enforces line and branch floors against a measured summary. Missing floors
  # are unqualified, not zero. Raises on deliberate or accidental violations.
  def self.coverage_gate(summary, floors)
    %w[line branch].each do |kind|
      minimum = floors.fetch(kind)
      raise "coverage: unqualified #{kind} expectation" unless minimum.is_a?(Numeric) && minimum.finite? && minimum.between?(0, 100)
      raise "coverage: #{kind} expectation violated" if summary.fetch(kind).fetch("percent") < minimum
    end
    true
  end

  # Compares only identical qualified conditions against the fixed accepted
  # reference. Returns explicit comparable/noncomparable deltas and advisory
  # growth. Completed budget and independent hard deadline remain separate.
  def self.runtime_report(elapsed, observed_conditions, reference)
    return { "comparable" => false, "reason" => "missing qualification/reference" } unless
      reference.is_a?(Hash) && reference["qualified"] == true && reference["conditions"].is_a?(Hash) &&
      reference["source_sha256"].is_a?(String) && reference["source_sha256"].match?(/\A[0-9a-f]{64}\z/) &&
      reference["outer_seconds"].is_a?(Numeric) &&
      reference["outer_seconds"].finite? && reference["outer_seconds"].positive?

    changed = (reference.fetch("conditions").keys | observed_conditions.keys).select { |key|
      reference.fetch("conditions")[key] != observed_conditions[key] }
    unless changed.empty?
      return { "comparable" => false, "reason" => "changed conditions", "changed_conditions" => changed,
               "reference_source_sha256" => reference.fetch("source_sha256") }
    end
    delta = elapsed - reference.fetch("outer_seconds")
    percent = delta * 100.0 / reference.fetch("outer_seconds")
    { "comparable" => true, "reference_source_sha256" => reference.fetch("source_sha256"),
      "reference_outer_seconds" => reference.fetch("outer_seconds"),
      "delta_seconds" => delta, "delta_percent" => percent,
      "advisory_growth" => (delta >= 1 && percent >= 10) || delta >= 3 }
  end

  # Enforces an accepted completed-run budget. Unqualified or changed conditions
  # cannot pass the budget; advisory growth alone is not a budget failure.
  def self.budget_gate(elapsed, maximum, comparison)
    raise "runtime: unqualified/noncomparable budget" unless comparison.fetch("comparable") &&
      maximum.is_a?(Numeric) && maximum.finite? && maximum.positive?
    raise "runtime: completed-run budget exceeded" if elapsed > maximum

    true
  end

  # Writes one truthful final report, even on failure. A fresh combined result
  # exists only in this invocation. Exceptions/missing policy/evidence fail the
  # command; an original nonzero exit retains priority over report failures.
  def self.report
    current = @context
    original_exception = $!
    failures = []
    begin
      raise "feedback: source changed during invocation" unless source_files(current.fetch("root")) == current.fetch("source_files") &&
        FeedbackCoverage.sources(current.fetch("root")) == current.fetch("sources")
      raise "feedback: policy changed during invocation" if current["policy_sha256"] &&
        (!File.file?(current.fetch("policy_path")) || Digest::SHA256.file(current.fetch("policy_path")).hexdigest != current.fetch("policy_sha256"))
      stages = current.fetch("stages")
      raise "feedback: unfinished stage" unless !stages.empty? && stages.all? { |stage| stage.fetch("complete") }
      ordinary = stages.select { |stage| stage.fetch("layer") == "ordinary" }.flat_map { |stage| stage.fetch("processes").map { |process| process.fetch("coverage") } }
      native = stages.reject { |stage| stage.fetch("layer") == "ordinary" }.flat_map { |stage| stage.fetch("processes").map { |process| process.fetch("coverage") } }
      current["coverage"] = {}
      { "ordinary" => ordinary, "native_contribution" => native, "combined" => ordinary + native }.each do |name, maps|
        next if maps.empty?
        current.fetch("coverage")[name] = FeedbackCoverage.summary(FeedbackCoverage.merge(maps))
      end
      unless ordinary.empty? || native.empty?
        current["native_added_nodes"] = %w[line branch].to_h { |kind|
          [kind, current.fetch("coverage").fetch("combined").fetch(kind).fetch("covered") -
                 current.fetch("coverage").fetch("ordinary").fetch(kind).fetch("covered")] }
      end
      raise "feedback: qualification only; operator acceptance missing" if current.fetch("qualification")
      floors = current.fetch("policy").fetch("coverage")
      coverage_gate(current.fetch("coverage").fetch("ordinary"), floors.fetch("ordinary")) unless ordinary.empty?
      if current["complete_offline_gate"]
        coverage_gate(current.fetch("coverage").fetch("combined"), floors.fetch("combined"))
      end
    rescue StandardError => exception
      failures << "#{exception.class}: #{exception.message}"
    end
    current["outer_seconds"] = FeedbackRuntime.elapsed(timer)
    current["measurement"] = "Darwin process birth through final report; monotonic after initialization"
    current["conditions"] = conditions(current)
    current["runtime_comparison"] = runtime_report(current.fetch("outer_seconds"), current.fetch("conditions"), current.fetch("policy")["reference"])
    current["budget_status"] = "NOT_APPLICABLE_TO_COMPLETE_OR_NATIVE_COMMAND"
    if current.fetch("stages").map { |stage| stage.fetch("layer") } == ["ordinary"]
      current["budget_status"] = "BLOCKED"
      begin
        budget_gate(current.fetch("outer_seconds"), current.fetch("policy")["ordinary_budget_seconds"], current.fetch("runtime_comparison"))
        current["budget_status"] = "PASS"
      rescue StandardError => exception
        current["budget_status"] = "FAIL" if exception.message.include?("budget exceeded")
        failures << "#{exception.class}: #{exception.message}"
      end
    end
    current["failures"] = failures
    current["accepted"] = failures.empty? && (original_exception.nil? || (original_exception.is_a?(SystemExit) && original_exception.success?))
    public_report = current.reject { |key, _value| %w[policy layout].include?(key) }.merge("stages" => current.fetch("stages").map { |stage|
      stage.merge("processes" => stage.fetch("processes").map { |process| process.reject { |key, _value| %w[coverage coverage_context].include?(key) } }) })
    File.write(File.join(current.fetch("directory"), "report.json"), JSON.pretty_generate(public_report) + "\n", mode: "wx")
    puts "ACT outer elapsed: #{format('%.6f', current.fetch('outer_seconds'))}s; comparable: #{current.fetch('runtime_comparison').fetch('comparable')}"
    current.fetch("coverage", {}).each do |name, summary|
      puts "ACT #{name} coverage: line #{format('%.4f', summary.fetch('line').fetch('percent'))}% (#{summary.fetch('line').fetch('covered')}/#{summary.fetch('line').fetch('total')}), branch #{format('%.4f', summary.fetch('branch').fetch('percent'))}% (#{summary.fetch('branch').fetch('covered')}/#{summary.fetch('branch').fetch('total')}); #{summary.fetch('files')} production files"
    end
    if current["accepted"] && current["complete_offline_gate"]
      processes = current.fetch("stages").flat_map { |stage| stage.fetch("processes") }
      puts "#{processes.sum { |process| process.fetch('tests') }} tests, #{processes.sum { |process| process.fetch('assertions') }} assertions, 0 failures, 0 errors, 0 skips"
      puts "Line Coverage: #{format('%.4f', current.fetch('coverage').fetch('combined').fetch('line').fetch('percent'))}%"
      puts "ACT complete offline acceptance: PASS"
    end
    failures.each { |failure| warn failure }
    exit 1 if !failures.empty? && (original_exception.nil? || (original_exception.is_a?(SystemExit) && original_exception.success?))
  rescue StandardError => exception
    warn "feedback report could not be preserved: #{exception.class}: #{exception.message}"
    exit 1 if original_exception.nil? || (original_exception.is_a?(SystemExit) && original_exception.success?)
  end
end
