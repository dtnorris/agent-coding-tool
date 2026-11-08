# frozen_string_literal: true

require_relative "manager_session"

module AgentCodingTool
  # Thin CLI inference adapter. ACT supplies the independently supervised,
  # confined executor; this adapter never treats a model/tool request or an
  # environment flag as a qualification grant. Default live execution refuses.
  class CodexManagerAdapter
    OUTPUT_LIMIT = 4 * 1024 * 1024

    # Retains executable and trusted host executor identities. executor receives
    # direct argv and prompt bytes and returns CommandResult. Construction has
    # no inference side effects. Missing executables raise SystemCallError.
    def initialize(executable:, identity:, executor: nil, guidance: nil)
      @executable = File.realpath(executable)
      @identity = identity.merge("adapter" => "codex-exec-explicit-resume/v1",
        "executable" => @executable, "executable_sha256" => Digest::SHA256.file(@executable).hexdigest)
      @executor = executor
      @guidance = guidance
      @identity["guidance_sha256"] = Digest::SHA256.hexdigest(guidance) if guidance
    end

    # Returns a detached runtime/configuration/source identity to bind in ACT's
    # private record. No current runtime compatibility or confinement is inferred.
    def identity
      JSON.parse(JSON.generate(@identity))
    end

    # Returns the bound complete manager guidance for the saved prompt. Nil is
    # permitted only for explicit deterministic inference substitutes.
    def guidance = @guidance

    # Constructs a read-only direct argv for a fresh or exact resumed session.
    # Resume lacks a sandbox switch on some installed versions, so both paths
    # explicitly set sandbox_mode in configuration. Strict host parsing is used
    # on both paths; no output-schema or output-file switch is assumed.
    def argv(session)
      raise InvalidTask, "manager: invalid session" if session && !session.match?(ManagerSession::IDENTIFIER)
      [@executable, "exec", *(session ? ["resume"] : []), "--ignore-user-config", "--ignore-rules", "--json", "--skip-git-repo-check",
        "-c", 'approval_policy="never"', "-c", 'sandbox_mode="read-only"',
        "-c", 'model_provider="openai"', "-c", 'forced_login_method="chatgpt"',
        "-c", 'model_reasoning_effort="high"',
        "-c", "features.multi_agent=false", "-c", "features.shell_tool=false",
        "-c", "features.apps=false", "-c", "features.plugins=false",
        "-c", 'web_search="disabled"', *(session ? [session] : []), "-"]
    end

    # Invokes only an explicitly installed trusted executor. Returns lossless
    # raw capture/status and a strictly identified final-message envelope. Binary,
    # truncated, conflicting or incomplete JSONL fails closed after raw retention
    # by ManagerSession. Executor exceptions propagate and hold the reserved turn.
    def call(session:, prompt:)
      raise InvalidState, "manager: live inference blocked: independently qualified confinement and lease executor required" unless @executor
      raise InvalidState, "manager: executable changed" unless Digest::SHA256.file(@executable).hexdigest == @identity.fetch("executable_sha256")
      result = @executor.call(argv(session), prompt)
      output, diagnostic = result.stdout.b, result.stderr.b
      truncated = output.bytesize + diagnostic.bytesize > OUTPUT_LIMIT
      captured_output = output.byteslice(0, OUTPUT_LIMIT)
      captured_error = diagnostic.byteslice(0, OUTPUT_LIMIT - captured_output.bytesize)
      envelope = { "stdout_base64" => [captured_output].pack("m0"), "stderr_base64" => [captured_error].pack("m0"),
        "stdout_sha256" => Digest::SHA256.hexdigest(output), "stderr_sha256" => Digest::SHA256.hexdigest(diagnostic),
        "exit_status" => result.exitstatus, "signal" => result.termsig, "truncated" => truncated,
        "session_id" => nil, "final_base64" => "" }
      if truncated
        envelope["response_error"] = "output limit exceeded"
        return envelope
      end
      events = []
      begin
        raise InvalidState, "JSONL is not UTF-8" unless output.dup.force_encoding("UTF-8").valid_encoding?
        output.lines.each do |line|
          event = RunEvidenceStore.parse(line)
          raise InvalidState, "JSONL event must be an object" unless event.is_a?(Hash)
          events << event
        end
      rescue JSON::ParserError, InvalidState => error
        envelope["response_error"] = "JSONL parse failure: #{error.message}"
      end
      sessions = events.select { |event| event["type"] == "thread.started" }.map { |event| event["thread_id"] }
      if sessions.length == 1 && sessions.first.is_a?(String) && sessions.first.match?(ManagerSession::IDENTIFIER) &&
          (!session || sessions.first == session)
        envelope["session_id"] = sessions.first
      else
        envelope["session_error"] = "session handoff missing, duplicate or wrong"
      end
      unless envelope["response_error"] || envelope["session_error"]
        begin
          envelope["final_base64"] = [final_message!(events)].pack("m0")
        rescue JSON::ParserError => error
          envelope["response_error"] = "final JSON parse failure: #{error.message}"
        rescue InvalidState => error
          envelope["response_error"] = "response contract failure: #{error.message}"
        end
      end
      envelope
    end

    private

    # Selects the terminal decision in the phase-less exec JSONL contract. Earlier
    # messages may be plain progress only, never structured/decision-bearing text.
    # Tools, errors, unknown events, conflicting messages and incomplete turns
    # raise InvalidState; malformed final JSON raises JSON::ParserError.
    def final_message!(events)
      allowed = %w[thread.started turn.started item.started item.updated item.completed turn.completed]
      raise InvalidState, "unknown, failed or error event" unless events.all? { |event| allowed.include?(event["type"]) }
      raise InvalidState, "incomplete or duplicate turn" unless events.count { |event| event["type"] == "turn.completed" } == 1 &&
        events.last["type"] == "turn.completed" && events.first["type"] == "thread.started" &&
        events.count { |event| event["type"] == "turn.started" } == 1
      started = events.index { |event| event["type"] == "turn.started" }
      raise InvalidState, "turn start out of order" if started && started != 1
      messages = []
      events.each do |event|
        next unless event["type"].start_with?("item.")
        item = event["item"]
        raise InvalidState, "tool or malformed item event" unless item.is_a?(Hash) && %w[agent_message reasoning].include?(item["type"])
        next unless item["type"] == "agent_message"
        raise InvalidState, "nonterminal agent message event" unless event["type"] == "item.completed"
        raise InvalidState, "agent message text missing" unless item["text"].is_a?(String)
        messages << item["text"]
      end
      raise InvalidState, "missing final decision" if messages.empty?
      messages[0...-1].each do |progress|
        raise InvalidState, "ambiguous or multiple decisions" if progress.match?(/[{}\[\]]|\b(?:decision|ACCEPT|CONTINUE|BLOCKED|STOP|DEFER)\b/i) ||
          progress.strip.empty?
        begin
          RunEvidenceStore.parse(progress)
        rescue JSON::ParserError
          next
        end
        raise InvalidState, "structured progress is ambiguous"
      end
      raise InvalidState, "final decision is not terminal" unless events[-2]["type"] == "item.completed" &&
        events[-2].dig("item", "type") == "agent_message"
      final = messages.last
      raise InvalidState, "final decision exceeds limit" if final.bytesize > ManagerSession::FINAL_LIMIT
      raise InvalidState, "final decision must be an object" unless RunEvidenceStore.parse(final).is_a?(Hash)
      final
    end
  end
end
