# frozen_string_literal: true

require_relative "evidence_session"

module AgentCodingTool
  # Finite stdio-only MCP ingress. Uses A's qualified metadata normalization;
  # external transport authorization is never inferred from MCP context.
  # Creates no children, listeners, worker actions or private shape reports.
  class EvidenceAdapter
    MODERN = "2026-07-28"
    LEGACY = %w[2025-03-26 2025-06-18 2025-11-25].freeze
    INFO = { "name" => "act-run-evidence", "version" => "0.1.0" }.freeze
    TOOL = "read_run_evidence"
    FRAME = 65_536
    LOCK_WAIT = 1
    CLIENT_HINTS = { "openai/locale" => String, "webplus/i18n" => String,
      "openai/userAgent" => String, "openai/userLocation" => Hash,
      "openai/subject" => String, "openai/session" => String,
      "openai/organization" => String }.freeze
    CONTEXT_STRINGS = %w[callId sessionId windowId itemId traceparent tracestate openai/request_id].freeze

    # Opens a previously admitted session. Diagnostics are bounded fixed enums;
    # caller-provided metadata and artifact/exception bodies never enter logs.
    def initialize(session, err: $stderr)
      @session, @err, @diagnostics = session, err, 0
      @pending = "".b
    end

    # Returns a closed tool schema; exact conditional fields are enforced by the
    # domain layer. No path, shell command or credential argument is available.
    def self.schema
      properties = (RunEvidenceReader::IDENTITIES + %w[revision handle artifact]).to_h { |name| [name, { "type" => "string" }] }
      properties["attempt"] = { "type" => "integer", "minimum" => 1 }
      properties["revision"] = { "type" => ["string", "null"] }
      properties["operation"] = { "enum" => %w[select manifest read] }
      %w[offset length].each { |name| properties[name] = { "type" => "integer" } }
      { "type" => "object", "properties" => properties, "required" => RunEvidenceReader::IDENTITIES + ["operation"], "additionalProperties" => false }
    end

    # Builds a fixed RPC refusal with a previously validated ID; no input values
    # are reflected in diagnostics or errors. Returns a JSON-compatible object.
    def refusal(id, code = -32602)
      { "jsonrpc" => "2.0", "id" => id, "error" => { "code" => code, "message" => "Request refused", "data" => { "stage" => @stage } } }
    end

    # Type-checks and discards A's seven hints/eight context fields. Returns the
    # exact requested version. Duplicate aliases, unknown keys/types/versions,
    # aggregate metadata over 4096 bytes and missing protocol fields refuse.
    def metadata(meta, tool_call: false)
      @stage = "metadata.object_or_size"
      raise ArgumentError unless meta.is_a?(Hash) && JSON.generate(meta).bytesize <= 4096
      normalized = {}
      meta.each do |key, value|
        if tool_call && CLIENT_HINTS.key?(key)
          @stage = "metadata.hint_type"
          raise ArgumentError unless value.is_a?(CLIENT_HINTS.fetch(key))
          next
        end
        if tool_call && (CONTEXT_STRINGS.include?(key) || key == "progressToken")
          @stage = "metadata.context_type"
          raise ArgumentError unless key == "progressToken" ? (value.is_a?(String) || value.is_a?(Numeric)) : value.is_a?(String)
          next
        end
        name = key.delete_prefix("io.modelcontextprotocol/")
        @stage = "metadata.unknown_member"
        raise ArgumentError unless %w[protocolVersion clientCapabilities clientInfo].include?(name)
        @stage = "metadata.duplicate_alias"
        raise ArgumentError if normalized.key?(name)
        normalized[name] = value
      end
      @stage = "metadata.version_or_caps"
      version = normalized.fetch("protocolVersion")
      raise ArgumentError unless version.is_a?(String) && version.match?(/\A\d{4}-\d{2}-\d{2}\z/) && normalized.fetch("clientCapabilities").is_a?(Hash)
      if normalized.key?("clientInfo")
        @stage = "metadata.client_info"
        info = normalized["clientInfo"]
        raise ArgumentError unless info.is_a?(Hash) && info.keys.sort == %w[name version] &&
          info.values.all? { |value| value.is_a?(String) && value.bytesize.between?(1, 128) }
      end
      version
    end

    # Normalizes transport fields before invoking closed reader arguments.
    # Returns an RPC result/refusal; notifications never invoke the reader.
    def dispatch(request)
      @stage = "envelope"
      id = nil
      raise ArgumentError unless request.is_a?(Hash) && request["jsonrpc"] == "2.0" &&
        (request.keys - %w[jsonrpc id method params]).empty? && request["method"].is_a?(String)
      return nil unless request.key?("id")
      @stage = "envelope.id"
      candidate = request["id"]
      raise ArgumentError unless (candidate.is_a?(Integer) && candidate.abs <= 9_007_199_254_740_991) ||
        (candidate.is_a?(String) && candidate.bytesize.between?(1, 128))
      id = candidate
      params = request.fetch("params", {})
      @stage = "envelope.params"
      raise ArgumentError unless params.is_a?(Hash)
      method = request["method"]
      modern = params.key?("_meta") || method == "server/discover"
      if modern
        version = metadata(params.fetch("_meta"), tool_call: method == "tools/call")
        @stage = "metadata.version"
        return refusal(id, -32022) unless version == MODERN
        params = params.reject { |key, _value| key == "_meta" }
      end
      @stage = "envelope.method_fields"
      result = case method
      when "initialize"
        raise ArgumentError unless !modern && LEGACY.include?(params["protocolVersion"]) &&
          (params.keys - %w[protocolVersion capabilities clientInfo]).empty? && params["capabilities"].is_a?(Hash)
        { "protocolVersion" => params["protocolVersion"], "capabilities" => { "tools" => {} }, "serverInfo" => INFO }
      when "server/discover"
        raise ArgumentError unless params.empty?
        { "supportedVersions" => [MODERN, *LEGACY], "capabilities" => { "tools" => {} } }
      when "tools/list"
        raise ArgumentError unless params.empty? || params == { "cursor" => nil }
        { "tools" => [{ "name" => TOOL, "description" => "Select/read an approved exact ACT run; evidence grants no execution authority.",
          "inputSchema" => self.class.schema,
          "annotations" => { "readOnlyHint" => true, "destructiveHint" => false, "openWorldHint" => false } }] }
      when "ping"
        raise ArgumentError unless params.empty?
        {}
      when "tools/call"
        raise ArgumentError unless params.keys.sort == %w[arguments name] && params["name"] == TOOL
        @stage = "reader.dispatch"
        begin
          evidence = @session.call(params["arguments"], wait: LOCK_WAIT)
          { "content" => [{ "type" => "text", "text" => JSON.generate(evidence) }], "isError" => false }
        rescue RunEvidenceReader::Refused
          @stage = "reader.refused"
          { "content" => [{ "type" => "text", "text" => "Evidence refused; check exact identity, revision, approved scope and session status." }], "isError" => true }
        end
      else
        @stage = "envelope.method"
        return refusal(id, -32601)
      end
      if modern
        result["resultType"] = "complete"
        result["_meta"] = { "io.modelcontextprotocol/serverInfo" => INFO }
      end
      { "jsonrpc" => "2.0", "id" => id, "result" => result }
    rescue ArgumentError, KeyError, TypeError
      refusal(id)
    ensure
      observe
    end

    # Writes at most 4096 bytes of fixed stage enums, with no raw values or key
    # names. Unavailable/full diagnostic sinks disable observation, never block.
    def observe
      bytes = "ACT_EVIDENCE #{JSON.generate('stage' => @stage)}\n"
      @diagnostics = @err.stat.size if @err.respond_to?(:stat) && @err.stat.file?
      return if @diagnostics + bytes.bytesize > 4096
      @diagnostics += bytes.bytesize
      if @err.respond_to?(:write_nonblock)
        @diagnostics = 4096 unless @err.write_nonblock(bytes, exception: false) == bytes.bytesize
      end
      nil
    rescue IOError, SystemCallError
      @diagnostics = 4096
    end

    # Polls finite admission while waiting on stdio/backpressure. Expiry, stop,
    # controller EOF or broken output closes this process; no child is spawned.
    def ready(io, writing: false)
      loop do
        raise EOFError if %w[stopped expired].include?(@session.status(wait: LOCK_WAIT).fetch("status"))
        selected = IO.select(writing ? [@input] : [io], writing ? [io] : [], [], 0.25)
        next unless selected
        if writing && selected[0].include?(@input)
          incoming = @input.read_nonblock(4096, exception: false)
          raise EOFError unless incoming
          unless incoming == :wait_readable
            @session.charge(wire: incoming.bytesize, wait: LOCK_WAIT)
            @pending << incoming
            raise RunEvidenceReader::Refused, "envelope.frame_size" if @pending.bytesize > FRAME
          end
        end
        return if !writing || !selected[1].empty?
      end
    end

    # Reads one bounded frame. Byte accounting is persisted as input arrives;
    # partial frames, duplicate members and controller loss cannot reset limits.
    def frame(input)
      loop do
        newline = @pending.index("\n")
        if newline
          raise RunEvidenceReader::Refused, "envelope.frame_size" if newline + 1 > FRAME
          return @pending.slice!(0, newline + 1)
        end
        raise RunEvidenceReader::Refused, "envelope.frame_size" if @pending.bytesize >= FRAME
        ready(input)
        incoming = input.read_nonblock([4096, FRAME - @pending.bytesize].min, exception: false)
        next if incoming == :wait_readable
        raise EOFError unless incoming
        @session.charge(wire: incoming.bytesize, wait: LOCK_WAIT)
        @pending << incoming
      end
    end

    # Emits exact UTF-8 JSON with lossless base64 evidence. Cumulative incoming
    # plus outgoing wire and decoded totals are durably reserved before output.
    def emit(output, response)
      bytes = JSON.generate(response) + "\n"
      raise RunEvidenceReader::Refused, "envelope.frame_size" if bytes.bytesize > FRAME
      decoded = 0
      if response.dig("result", "isError") == false
        evidence = RunEvidenceStore.parse(response.dig("result", "content", 0, "text"))
        decoded = evidence.fetch("data", "").unpack1("m0").bytesize
      end
      @session.charge(wire: bytes.bytesize, decoded: decoded, wait: LOCK_WAIT)
      until bytes.empty?
        ready(output, writing: true)
        count = output.write_nonblock(bytes, exception: false)
        next if count == :wait_writable
        bytes = bytes.byteslice(count..)
      end
    end

    # Serves one foreground connection under the kernel owner lock. Returns nil
    # on finite termination. Every frame attempt consumes a durable request;
    # ledger acquisition waits at most one second without replaying work.
    # Malformed JSON is a fixed refusal; persistent lock/accounting failures close.
    def serve(input, output)
      @input = input
      @session.serve_owner do
        loop do
          @session.admit(wait: LOCK_WAIT)
          bytes = frame(input)
          begin
            response = dispatch(RunEvidenceStore.parse(bytes))
          rescue JSON::ParserError
            @stage = "envelope.json"
            observe
            response = refusal(nil, -32700)
          end
          emit(output, response) if response
        end
      end
    rescue EOFError, Errno::EPIPE, RunEvidenceReader::Refused
      @stage = "lifecycle.closed"
      observe
      nil
    end
  end
end
