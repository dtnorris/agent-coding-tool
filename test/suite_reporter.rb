# frozen_string_literal: true

require "json"
require "minitest"

# Records actual Minitest results separately from human-readable process output.
class SuiteEvidenceReporter < Minitest::AbstractReporter
  # Accepts an evidence path and observed Minitest seed; returns a reporter with
  # no results. Raises no errors during initialization.
  def initialize(path, seed:)
    @path = path
    @seed = seed
    @results = []
  end

  # Accepts a completed Minitest result; appends its identity/counts. Returns array.
  def record(result)
    @results << {
      "case" => "#{result.class_name}##{result.name}",
      "assertions" => result.assertions,
      "status" => result.skipped? ? "skip" : result.error? ? "error" : result.passed? ? "pass" : "failure"
    }
  end

  # Writes completed results as JSON; returns bytes written. May raise IO errors.
  def report
    File.binwrite(@path, JSON.generate("invocation" => ENV.fetch("ACT_SUITE_INVOCATION"),
      "selection" => ENV.fetch("ACT_SUITE_SELECTION"), "seed" => @seed, "results" => @results))
  end
end

module Minitest
  # Installs evidence reporting for this child process; returns reporter collection.
  # Missing evidence-path configuration raises KeyError before tests can succeed.
  def self.plugin_act_suite_init(options)
    reporter << SuiteEvidenceReporter.new(ENV.fetch("ACT_SUITE_EVIDENCE"), seed: options.fetch(:seed))
  end

  extensions << "act_suite"
end
