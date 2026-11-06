# frozen_string_literal: true

require "json"
require "digest"

# Verifies one invocation's existing local evidence without copying or uploading.
# A zero command status alone cannot establish acceptance or published identity.
directory, mode, status = ARGV
paths = File.binread(File.join(directory, "acceptance.log")).lines.filter_map do |line|
  line.delete_prefix("ACT feedback evidence: ").strip if line.start_with?("ACT feedback evidence: ")
end
raise "expected one independent feedback invocation" unless paths.length == 1
feedback = paths.fetch(0)
puts "ACT CI local feedback evidence: #{feedback}"
raise "acceptance command failed (#{status})" unless status == "0"
report = JSON.parse(File.binread(File.join(feedback, "report.json")))
probe = JSON.parse(File.binread(File.join(directory, "implementation.json")))
raise "incomplete acceptance" unless report["accepted"] == true && report["complete_offline_gate"] == true &&
  report["qualification"] == false && report.fetch("stages").map { |stage| stage.fetch("layer") } ==
    %w[ordinary git_contract native_default native_integration] && report.fetch("stages").all? { |stage| stage["complete"] == true }
raise "composition changed between probe and acceptance" unless report.fetch("implementation") == probe.fetch("composition") &&
  report.fetch("implementation").fetch("mode") == mode
lock_hash = Digest::SHA256.file(File.join(directory, "split-composition.json")).hexdigest
raise "published lock changed" unless report.fetch("source_files").fetch("split-composition.json") == lock_hash
puts "ACT CI #{mode} complete acceptance evidence: PASS; invocation=#{report.fetch('invocation')}; composition_sha256=#{lock_hash}"
