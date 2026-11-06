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
      return envelope if truncated
      begin
        events = output.lines.map { |line| RunEvidenceStore.parse(line) }
        sessions = events.select { |event| event["type"] == "thread.started" }.map { |event| event["thread_id"] }
        finals = events.select { |event| event["type"] == "item.completed" && event.dig("item", "type") == "agent_message" }
        completed = events.count { |event| event["type"] == "turn.completed" }
        tools = events.any? { |event| event["item"].is_a?(Hash) && !%w[agent_message reasoning].include?(event.dig("item", "type")) }
        if sessions.length == 1 && (!session || sessions.first == session) && finals.length == 1 && completed == 1 && !tools &&
            events.none? { |event| %w[error turn.failed].include?(event["type"]) }
          envelope["session_id"] = sessions.first
          envelope["final_base64"] = [finals.first.fetch("item").fetch("text")].pack("m0")
        end
      rescue JSON::ParserError, KeyError, TypeError, NoMethodError
        # Raw output and real status survive malformed/truncated/binary events.
      end
      envelope
    end
  end
end
