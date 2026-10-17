# frozen_string_literal: true

require "json"
require "minitest"

# Records actual Minitest results separately from human-readable process output.
class SuiteEvidenceReporter < Minitest::AbstractReporter
  # Accepts an evidence path; returns a reporter with no results. Raises no errors.
  def initialize(path)
    @path = path
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
    File.binwrite(@path, JSON.generate(@results))
  end
end

module Minitest
  # Installs evidence reporting for this child process; returns reporter collection.
  # Missing evidence-path configuration raises KeyError before tests can succeed.
  def self.plugin_act_suite_init(_options)
    reporter << SuiteEvidenceReporter.new(ENV.fetch("ACT_SUITE_EVIDENCE"))
  end

  extensions << "act_suite"
end
