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
    @progress_path = ENV["ACT_SUITE_PROGRESS"]
    @owner = Process.pid
  end

  # Announces the active test before setup/run/teardown. Forked descendants
  # cannot impersonate the suite owner; progress never supplies case evidence.
  def prerecord(klass, name)
    progress("start", "case" => "#{klass.name}##{name}")
  end

  # Accepts a completed Minitest result; appends its identity/counts. Returns array.
  def record(result)
    @results << {
      "case" => "#{result.class_name}##{result.name}",
      "assertions" => result.assertions,
      "status" => result.skipped? ? "skip" : result.error? ? "error" : result.passed? ? "pass" : "failure"
    }
    progress("result", @results.last.merge("detail" => result.failures.map(&:message).join("; ").byteslice(0, 2048).to_s.scrub))
  end

  # Appends one flushed advisory event to the parent's private regular file.
  # Reporting failures cannot replace the independent final result envelope.
  def progress(event, fields)
    return unless @progress_path && Process.pid == @owner

    File.open(@progress_path, "ab") do |file|
      file.puts(JSON.generate(fields.merge("event" => event, "invocation" => ENV.fetch("ACT_SUITE_INVOCATION"))))
      file.flush
    end
  rescue SystemCallError, IOError
    @progress_path = nil
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
