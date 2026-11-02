# frozen_string_literal: true

module AgentCodingTool
  # Version-two task leases layered on the existing finite admission ledger.
  # All scope edits, selections and wire releases use its one cross-process lock.
  module TaskSharing
    Refused = RunEvidenceReader::Refused
    # Returns whether a ledger opts into mutable task scopes; v1 is unchanged.
    def sharing?(state)
      state.dig("grant", "schema") == "agent-coding-tool-task-sharing/v2"
    end

    # Marks client readiness inside its existing owner; grants cannot race ahead
    # of transport readiness. Does not renew or reset admission.
    def sharing_ready
      transaction(wait: 1) { |state| state["ready"] = true if sharing?(state) }
    end

    # Grants or revokes one registered task. Returns requested/effective expiry
    # and scope generation. Revocation invalidates all existing task handles;
    # delivered bytes cannot be recalled. Renewal of an active scope keeps handles.
    def share_task(task, seconds:, revoke: false)
      transaction(wait: 1) do |state|
        raise Refused, "share.not_ready" unless sharing?(state) && state["ready"] && reason(state) == "active"
        raise Refused, "share.minutes" unless seconds.is_a?(Integer) && seconds.between?(60, EvidenceSession::LIMITS.fetch("seconds"))
        scopes = state.fetch("scopes")
        if revoke
          raise Refused, "share.scope" unless scopes.key?(task)
        else
          RunEvidenceStore.task_context(state.dig("grant", "data_root"), task)
        end
        raise Refused, "share.task_limit" if !scopes.key?(task) && scopes.length >= 16
        old = scopes[task]
        now = Time.now.to_f
        generation = old ? old.fetch("generation") : 0
        generation += 1 if revoke || !old || old["revoked"] || now >= old.fetch("expires_at") ||
          Process.clock_gettime(Process::CLOCK_MONOTONIC) >= old.fetch("monotonic_expires_at")
        requested = now + seconds
        scope = { "generation" => generation, "revoked" => revoke,
          "requested_expires_at" => requested, "expires_at" => [requested, state.fetch("expires_at")].min,
          "monotonic_expires_at" => Process.clock_gettime(Process::CLOCK_MONOTONIC) + [seconds, state.fetch("expires_at") - now].min }
        scopes[task] = scope
        scope.merge("task_id" => task, "status" => revoke ? "revoked" : "shared",
          "requested_expiry" => Time.at(requested).utc.iso8601,
          "effective_expiry" => Time.at(scope.fetch("expires_at")).utc.iso8601,
          "clipped" => requested > scope.fetch("expires_at"),
          "audience" => state.dig("grant", "transport"), "delivered_bytes" => "cannot be recalled")
      end
    end

    # Validates a live scope and optionally an exact selection generation.
    # Missing, expired/revoked or replaced scopes raise without artifact release.
    def task_scope!(state, task, generation = nil)
      scope = state.fetch("scopes")[task]
      raise Refused, "share.scope" unless state["ready"] && scope && !scope["revoked"] &&
        Time.now.to_f < scope.fetch("expires_at") && Process.clock_gettime(Process::CLOCK_MONOTONIC) < scope.fetch("monotonic_expires_at") &&
        (!generation || generation == scope.fetch("generation"))
      scope
    end

    # Executes scoped discovery or an immutable exact-run reader selection.
    # Discovery/refresh is explicit and never selects a global newest attempt.
    # Returns metadata/lossless chunks; unapproved fields or identities refuse.
    def shared_call(state, request)
      operation = request["operation"]
      grant = state.fetch("grant")
      if %w[discover refresh].include?(operation)
        raise Refused, "reader.fields" unless (request.keys - %w[operation task_id offset]).empty? &&
          (!request.key?("offset") || request.key?("task_id"))
        tasks = request.key?("task_id") ? [request["task_id"]] : state.fetch("scopes").keys.select do |task|
          scope = state.fetch("scopes").fetch(task)
          !scope["revoked"] && Time.now.to_f < scope.fetch("expires_at") &&
            Process.clock_gettime(Process::CLOCK_MONOTONIC) < scope.fetch("monotonic_expires_at")
        end
        tasks.each { |task| task_scope!(state, task) }
        inventory = request.key?("task_id") ? tasks.map { |task| RunEvidenceStore.new(grant.fetch("data_root")).discover(task, offset: request.fetch("offset", 0)) } :
          tasks.map { |task| { "task_id" => task, "status" => "shared" } }
        return { "tasks" => inventory,
          "_release" => { "operation" => "discover", "tasks" => tasks.to_h { |task| [task, task_scope!(state, task).fetch("generation")] } } }
      end
      identities = RunEvidenceReader.request_identity_fields(request)
      identity = request.slice(*identities)
      raise Refused, "selection.identity" unless identity.keys.sort == identities.sort &&
        identity["task_id"].is_a?(String) && identity["task_id"].match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) &&
        (identities == RunEvidenceReader::EXTERNAL_IDENTITIES ? identity["invocation_id"].is_a?(String) && identity["invocation_id"].match?(/\Aexternal-[0-9a-f]{32}\z/) :
          identity["attempt"].is_a?(Integer) && identity["attempt"].positive? &&
          %w[invocation_id session_id].all? { |key| identity[key].is_a?(String) && identity[key].match?(/\A[A-Za-z0-9_-]{1,128}\z/) })
      scope = task_scope!(state, identity.fetch("task_id"))
      if operation == "select"
        raise Refused, "reader.fields" unless request.keys.sort == (identities + ["operation"]).sort
        raise Refused, "selection.limit" if state.fetch("selections").length >= 64
        identity = identity.merge("source" => "external_codex_cli") if identities == RunEvidenceReader::EXTERNAL_IDENTITIES
        config = RunEvidenceStore.new(grant.fetch("data_root")).select(identity,
          artifacts: grant.fetch("artifacts"), manager: grant.dig("transport", "manager"), shared: true)
        manifest = RunEvidenceReader.new(**config.transform_keys(&:to_sym)).call(
          identity.slice(*RunEvidenceReader.identity_fields(config.fetch("binding"))).merge("operation" => "manifest", "revision" => nil),
          caller: config.fetch("manager"))
        handle = Digest::SHA256.hexdigest("#{state.fetch('grant_sha256')}:#{manifest.fetch('revision')}:#{scope.fetch('generation')}")
        state.fetch("selections")[handle] = { "config" => config, "generation" => scope.fetch("generation") }
        manifest.merge("handle" => handle)
      else
        selection = state.fetch("selections")[request["handle"]]
        raise Refused, "selection.handle" unless selection
        task_scope!(state, identity.fetch("task_id"), selection.fetch("generation"))
        config = selection.fetch("config")
        RunEvidenceReader.new(**config.transform_keys(&:to_sym)).call(request.reject { |key, _| key == "handle" },
          caller: config.fetch("manager")).merge("handle" => request.fetch("handle"))
      end
    end

    # Rechecks scope under the ledger lock immediately before each nonblocking
    # wire write. No waiting/output buffering occurs while holding this lock.
    # A revoked/expired existing handle cannot release the next frame fragment.
    def release(request)
      transaction(wait: 1) do |state|
        raise Refused, "lifecycle.closed" if %w[stopped expired].include?(reason(state))
        if sharing?(state) && request
          if %w[discover refresh].include?(request["operation"])
            request.fetch("tasks").each { |task, generation| task_scope!(state, task, generation) }
          else
            selection = state.fetch("selections")[request["handle"]]
            raise Refused, "selection.handle" unless selection
            task_scope!(state, request["task_id"], selection.fetch("generation"))
          end
        end
        yield
      end
    end

    # Appends one bounded safe request outcome. The existing ledger lock keeps
    # concurrent adapter lines indivisible. Storage failures durably stop sharing
    # where possible and raise a fixed visible error; no arbitrary input is logged.
    def activity(request, evidence, released:, result:, wire: 0)
      transaction(wait: 1) do |state|
        next unless sharing?(state)
        operation = request.is_a?(Hash) && %w[discover refresh select manifest read].include?(request["operation"]) ? request["operation"] : "invalid"
        event = { "at" => Time.now.utc.iso8601(6), "operation" => operation,
          "bytes" => released, "wire_bytes" => wire, "result" => result }
        if evidence.is_a?(Hash) && evidence["binding"]
          evidence["binding"].slice(*RunEvidenceReader.identity_fields(evidence["binding"])).each do |key, value|
            event[key] = value if value.is_a?(Integer) || value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]{1,128}\z/)
          end
          artifact = evidence["artifact"]
          event["artifact"] = artifact.split(":").first if artifact.is_a?(String) &&
            (RunEvidenceReader::ARTIFACTS + RunEvidenceReader::CONTEXT_ARTIFACTS).include?(artifact.split(":").first)
          event["artifact"] = "validation_result" if artifact.is_a?(String) && artifact.start_with?("validation_result:")
          event["artifact"] = artifact.split(":").last if artifact.is_a?(String) && artifact.match?(/\Aworker:[0-9a-f]{32}:(candidate|apply|focused)\z/)
        end
        bytes = "ACT_SHARE #{JSON.generate(event)}\n"
        raise Refused, "share.activity_size" if bytes.bytesize > 1024
        path = File.join(@path, "activity.jsonl")
        begin
          File.open(path, File::WRONLY | File::APPEND | File::NOFOLLOW) do |file|
            stat = file.stat
            raise IOError unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o077).zero? &&
              File.realpath(path) == path && stat.size + bytes.bytesize <= RunEvidenceReader::MAX_FILE
            raise IOError unless file.write(bytes) == bytes.bytesize
            file.flush
          end
        rescue IOError, SystemCallError, Refused
          state["stopped"] = true
          state["activity_failure"] = true
          self.class.write(@path, state)
          raise Refused, "share.activity_failed", cause: nil
        end
      end
    end
  end
end
