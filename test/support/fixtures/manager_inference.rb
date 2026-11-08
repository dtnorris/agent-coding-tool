# frozen_string_literal: true

# Deterministic inference boundary only. All admission, candidate retention,
# checkpoints, verification receipts and session control remain ACT production.
require "json"
require "digest"
history, mode, *arguments = ARGV
prompt = JSON.parse(STDIN.read)
session = "manager-fixture"
criterion = "Require an added worker-change.txt and independent checked binary output; a worker success claim alone cannot establish acceptance."
if arguments[1] == "resume"
  abort "resume session missing or wrong" unless arguments[-2] == session
  earlier = JSON.parse(File.binread(File.join(history, "1.json")))
  abort "objective changed or prior decision repeated" unless earlier.fetch("prompt").fetch("objective") == prompt.fetch("objective") &&
    !JSON.generate(prompt).include?(earlier.fetch("decision").fetch("rationale"))
  artifacts = prompt.fetch("evidence").fetch("artifacts")
  candidate = artifacts.fetch("candidate").fetch("base64").unpack1("m0")
  gate_name = artifacts.keys.find { |name| name.start_with?("validation:") }
  gate = JSON.parse(artifacts.fetch(gate_name).fetch("base64").unpack1("m0"))
  outputs = artifacts.select { |name, _| name.start_with?("validation_output:") }.values
  acceptable = candidate.include?("worker-change.txt") && gate["candidate_validation"] == "passed" &&
    gate.dig("command_outcome", "exit_code") == 0 && outputs.any? { |spec| spec.fetch("base64").unpack1("m0") == "checked\x00\xff".b }
  decision = { "schema" => "agent-coding-tool-manager-decision/v1", "decision" => acceptable ? "ACCEPT" : "BLOCKED",
    "acceptance_sha256" => prompt.fetch("acceptance_sha256"), "completion_sha256" => prompt.fetch("completion_sha256"),
    "rationale" => acceptable ? "Candidate adds worker-change.txt; independent gate passed and retained the expected binary output." : "Candidate/gate evidence fails the earlier criterion.",
    "prior_reasoning" => earlier.fetch("decision").fetch("rationale"), "next_action" => nil }
else
  abort "missing initial entry" unless arguments.first == "exec" && prompt.fetch("evidence").nil?
  decision = { "schema" => "agent-coding-tool-manager-decision/v1", "decision" => "CONTINUE",
    "acceptance_sha256" => prompt.fetch("acceptance_sha256"), "completion_sha256" => nil,
    "rationale" => criterion, "prior_reasoning" => "", "next_action" => "Review the single operator-seeded worker result." }
end
number = arguments[1] == "resume" ? 2 : 1
decision["acceptance_sha256"] = "different-revision" if mode == "acceptance-mismatch"
File.write(File.join(history, "#{number}.json"), JSON.generate("pid" => Process.pid, "parent" => Process.ppid,
  "argv" => arguments, "prompt" => prompt, "decision" => decision))
STDOUT.binmode
if mode == "binary"
  STDOUT.write("\x00\xff".b)
  STDERR.binmode.write("diagnostic\x00\xfe".b)
  exit 7
end
puts JSON.generate("type" => "thread.started", "thread_id" => mode == "wrong-session" ? "wrong-manager" : session) unless mode == "missing-session"
puts JSON.generate("type" => "turn.started")
puts JSON.generate("type" => "item.completed", "item" => { "type" => "agent_message", "text" => "Reviewing the supplied task evidence." })
puts JSON.generate("type" => "item.completed", "item" => { "type" => "agent_message", "text" => mode == "malformed" ? "{}" : JSON.generate(decision) })
puts JSON.generate("type" => "turn.completed") unless mode == "incomplete"
