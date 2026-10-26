# frozen_string_literal: true

require "json"
require "digest"

# Deterministic substitute ONLY for Codex 0.162.1's exec/exec-resume process.
# The host launches this file with Ruby, never the installed Codex for inference.
# Inputs are the inspected CLI argument forms and a JSON prompt on stdin. Invalid
# bindings raise; successful exits are worker claims, never host acceptance.
module Act24Worker
  SESSION = "40240000-0000-4000-8000-000000000024"
  TEST = "require_relative 'answer'\nabort 'expected 42' unless answer == 42\n"
  INITIAL = "# Synthetic answer used by the continuity fixture.\ndef answer\n  41\nend\n"
  CORRECTED = INITIAL.sub("41", "42")

  # Validates the exact external interface, candidate and failed invocation.
  # Returns the intended file bytes; malformed prompts/bindings raise RuntimeError.
  def self.change(argv, prompt, cwd)
    raise "wrong workspace/session" unless prompt.fetch("workspace") == cwd && prompt.fetch("session") == SESSION
    raise "wrong objective" unless prompt.fetch("objective") == "Return 42; preserve the test and scope"
    case argv
    when ["exec", "--json", "-"]
      raise "occupied initial candidate" unless !File.exist?("answer.rb") && !File.exist?("answer_test.rb")
      [INITIAL, TEST]
    when ["exec", "resume", "--json", SESSION, "-"]
      failure = prompt.fetch("failure")
      candidate = prompt.fetch("candidate")
      raise "missing actual failed gate" unless failure.fetch("exit") != 0 && failure.fetch("argv").is_a?(Array) &&
        failure.fetch("stdout_sha256").match?(/\A[0-9a-f]{64}\z/) && failure.fetch("stderr_sha256").match?(/\A[0-9a-f]{64}\z/) &&
        failure.fetch("stderr_hex").include?("expected 42".unpack1("H*"))
      %w[stdout stderr].each do |stream|
        raise "changed failed output" unless Digest::SHA256.hexdigest([failure.fetch("#{stream}_hex")].pack("H*")) == failure.fetch("#{stream}_sha256")
      end
      raise "unbound candidate" unless candidate.fetch("sha256").match?(/\A[0-9a-f]{64}\z/) &&
        candidate.fetch("attempt").match?(/\A[0-9a-f]{32}\z/) && candidate.fetch("base_sha").match?(/\A[0-9a-f]{40}\z/)
      raise "candidate bytes differ" unless File.binread("answer.rb") == INITIAL && File.binread("answer_test.rb") == TEST &&
        prompt.fetch("files_sha256") == [INITIAL, TEST].map { |bytes| Digest::SHA256.hexdigest(bytes) }
      [prompt["fixture_fault"] == "no_progress" ? INITIAL : CORRECTED, TEST]
    else
      raise "unsupported exec interface"
    end
  end

  # Writes exactly the two authorized synthetic files and emits the event ACT's
  # pinned Launcher consumes. JSON/file errors propagate; no child is launched.
  def self.run(argv)
    prompt = JSON.parse($stdin.read)
    answer, test = change(argv, prompt, Dir.pwd)
    File.binwrite("answer.rb", answer)
    File.binwrite("answer_test.rb", test)
    puts JSON.generate("type" => "thread.started", "thread_id" => SESSION)
    puts JSON.generate("type" => "turn.completed")
    warn "fixture worker claims success; host verification required"
  end
end

Act24Worker.run(ARGV) if $PROGRAM_NAME == __FILE__
