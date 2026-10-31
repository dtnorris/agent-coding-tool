# frozen_string_literal: true

require "fileutils"
require "securerandom"
require_relative "run_evidence_store"

module AgentCodingTool
  # Durable, finite read admission, separate from ACT lifecycle/checkpoint state.
  # The external owner-approved ingress enforces the whole-workspace audience;
  # neither this ledger nor MCP context authenticates a conversation.
  class EvidenceSession
    Refused = RunEvidenceReader::Refused
    LIMITS = { "seconds" => 3600, "requests" => 8192,
      "wire_bytes" => 128 * 1024 * 1024, "decoded_bytes" => 64 * 1024 * 1024 }.freeze
    TUNNEL_RESULT = { "stage" => %w[delivery readiness lifecycle],
      "reason" => %w[client_start_failed deadline failed stopped expired exhausted interrupted controller_lost lost],
      "local_cleanup" => %w[not_started unknown blocked owned_groups_signaled_and_reaped owned_groups_terminal_and_reaped],
      "admission_stop" => %w[stopped blocked], "retrieval" => %w[not_attested],
      "hosted_shutdown" => %w[not_observed], "saved_settings" => %w[not_modified] }.freeze

    # Creates one exclusive permanent admission directory from private operator
    # JSON. Returns status. Refuses reused directories, unknown fields or scope;
    # failure leaves a tombstone rather than renewing a partially created grant.
    def self.start(path, grant_path)
      grant_path = File.expand_path(grant_path)
      grant = RunEvidenceStore.parse(RunEvidenceStore.bytes(grant_path, root: File.dirname(grant_path), private: true))
      raise Refused, "grant.fields" unless grant.is_a?(Hash) &&
        grant.keys.sort == %w[schema approved session_path data_root tasks artifacts transport limits].sort &&
        grant["schema"] == "agent-coding-tool-evidence-grant/v1" && grant["approved"] == true
      limits = grant["limits"]
      raise Refused, "grant.limits" unless limits.is_a?(Hash) && limits.keys.sort == LIMITS.keys.sort &&
        LIMITS.all? { |name, maximum| limits[name].is_a?(Integer) && limits[name].between?(1, maximum) }
      tasks, artifacts, boundary = grant.values_at("tasks", "artifacts", "transport")
      raise Refused, "grant.scope" unless tasks.is_a?(Array) && tasks.length.between?(1, 16) && tasks.uniq == tasks &&
        tasks.all? { |task| task.is_a?(String) && task.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) } &&
        artifacts.is_a?(Array) && !artifacts.empty? && artifacts.uniq == artifacts &&
        (artifacts - RunEvidenceReader::ARTIFACTS).empty? &&
        ((artifacts & %w[candidate validation]).empty? || artifacts.include?("checkpoint"))
      raise Refused, "grant.audience" unless boundary.is_a?(Hash) &&
        boundary.keys.sort == %w[account workspace endpoint manager audience].sort && boundary["audience"] == "whole-workspace" &&
        boundary.values.all? { |value| value.is_a?(String) && value.bytesize.between?(1, 512) }
      data_root = grant.fetch("data_root")
      raise Refused, "grant.root" unless data_root.is_a?(String) && File.realpath(data_root) == data_root
      path = File.expand_path(path)
      raise Refused, "grant.session" unless grant["session_path"] == path
      raise Refused, "grant.destination" unless File.realpath(File.dirname(path)) == File.dirname(path) &&
        [data_root, "#{data_root}-runs", File.expand_path("../..", __dir__)].none? { |root| path == root || path.start_with?("#{root}/") }
      Dir.mkdir(path, 0o700)
      %w[lock owner].each { |name| File.open(File.join(path, name), File::WRONLY | File::CREAT | File::EXCL, 0o600, &:fsync) }
      now = Time.now.to_f
      state = { "grant" => grant, "grant_sha256" => Digest::SHA256.hexdigest(JSON.generate(grant)),
        "admitted_at" => now, "expires_at" => now + limits.fetch("seconds"),
        "monotonic_start" => Process.clock_gettime(Process::CLOCK_MONOTONIC),
        "stopped" => false, "requests" => 0, "wire_bytes" => 0, "decoded_bytes" => 0, "selections" => {} }
      write(path, state)
      new(path).status
    rescue SystemCallError, JSON::ParserError, KeyError, TypeError
      raise Refused, "grant.unavailable_or_reused", cause: nil
    end

    # Atomically persists accounting before effects; fsync failures refuse rather
    # than treating unconfirmed counters as durable. Returns nil or raises.
    def self.write(path, state)
      temporary = File.join(path, "state-#{SecureRandom.hex(8)}.tmp")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(state))
        file.flush
        file.fsync
      end
      File.rename(temporary, File.join(path, "state.json"))
      File.open(path, File::RDONLY, &:fsync)
      nil
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary)
    end

    # Opens an existing canonical private admission; never creates or renews it.
    def initialize(path)
      @path = File.expand_path(path)
      raise Refused, "session.directory" unless File.realpath(@path) == @path &&
        File.stat(@path).uid == Process.uid && (File.stat(@path).mode & 0o077).zero?
      RunEvidenceStore.bytes(File.join(@path, "lock"), root: @path, private: true)
    rescue SystemCallError
      raise Refused, "session.unavailable", cause: nil
    end

    # Serializes private state changes. Callers may inspect status after expiry;
    # malformed, replaced or symlinked ledger files refuse with no evidence bytes.
    # Calls default to immediate refusal; stop and the adapter can wait within
    # one second. Only acquisition waits: no ledger work is retried or renewed.
    def transaction(wait: 0)
      RunEvidenceStore.bytes(File.join(@path, "lock"), root: @path, private: true)
      File.open(File.join(@path, "lock"), File::RDWR | File::NOFOLLOW) do |lock|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
        until lock.flock(File::LOCK_EX | File::LOCK_NB)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise Refused, "session.busy" unless remaining.positive?
          IO.select(nil, nil, nil, [0.05, remaining].min)
        end
        raw = RunEvidenceStore.bytes(File.join(@path, "state.json"), root: @path, private: true)
        state = RunEvidenceStore.parse(raw)
        raise Refused, "session.binding" unless state.dig("grant", "session_path") == @path
        raise Refused, "session.grant_changed" unless Digest::SHA256.hexdigest(JSON.generate(state.fetch("grant"))) == state.fetch("grant_sha256")
        result = yield state
        self.class.write(@path, state) unless JSON.generate(state) == raw
        result
      end
    rescue JSON::ParserError, KeyError, TypeError, SystemCallError
      raise Refused, "session.state", cause: nil
    end

    # Returns a fixed lifecycle reason. A reboot/monotonic rollback consumes the
    # grant; either wall or monotonic deadline independently expires admission.
    def reason(state)
      return "stopped" if state.fetch("stopped")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - state.fetch("monotonic_start")
      return "expired" if elapsed.negative? || elapsed >= state.dig("grant", "limits", "seconds") || Time.now.to_f >= state.fetch("expires_at")
      return "exhausted" if %w[requests wire_bytes decoded_bytes].any? { |name| state.fetch(name) >= state.dig("grant", "limits", name) }
      "active"
    end

    # Returns bounded admission/accounting metadata; never returns artifact bodies.
    # Optional wait bounds only lock acquisition, retaining nonblocking defaults.
    def status(wait: 0)
      transaction(wait: wait) { |state| status_for(state) }
    end

    # Formats one ledger snapshot using only closed tunnel receipt enums. Returns
    # bounded metadata or raises for an invalid receipt; never echoes raw values.
    def status_for(state)
      result = state.slice("grant_sha256", "admitted_at", "expires_at", "requests", "wire_bytes", "decoded_bytes").merge(
        "status" => reason(state), "limits" => state.dig("grant", "limits"),
        "selected_runs" => state.fetch("selections").values.map { |config| config.fetch("binding") })
      result["tunnel"] = tunnel_result if File.exist?(File.join(@path, "tunnel-result.json")) || File.symlink?(File.join(@path, "tunnel-result.json"))
      result
    end

    # Returns only closed, fixed tunnel result enums for supported status/stop.
    # No implementation hash or PID lookup is needed. Tampered receipts refuse
    # instead of reflecting arbitrary data, client messages or potential secrets.
    def tunnel_result
      raw = RunEvidenceStore.bytes(File.join(@path, "tunnel-result.json"), root: @path, private: true)
      result = RunEvidenceStore.parse(raw)
      raise Refused, "tunnel.receipt" unless raw.bytesize <= 4096 && result.is_a?(Hash) &&
        result.keys.sort == TUNNEL_RESULT.keys.sort && TUNNEL_RESULT.all? { |key, allowed| allowed.include?(result[key]) }
      result
    end

    # Permanently stops admission. Polling servers close themselves without
    # historical PID signaling; repeated stops do not mint a replacement grant.
    # Commit before formatting the same snapshot, without reacquiring the lock.
    # Even an invalid tunnel receipt cannot undo durable admission revocation.
    def stop
      state = transaction(wait: 1) do |current|
        current["stopped"] = true
        current
      end
      status_for(state)
    end

    # Charges one bounded incoming frame before parsing, including refusals and
    # notifications. EOF/partial input reservations are deliberately not refunded.
    # Optional wait affects acquisition only; lifecycle is checked after locking.
    def admit(wait: 0)
      transaction(wait: wait) do |state|
        raise Refused, "lifecycle.#{reason(state)}" unless reason(state) == "active"
        state["requests"] += 1
      end
    end

    # Charges exact incoming/outgoing wire and decoded bytes before release.
    # Invalid amounts or cumulative overruns raise without releasing a response.
    # Optional wait never replays charges or extends the original admission.
    def charge(wire:, decoded: 0, wait: 0)
      transaction(wait: wait) do |state|
        # The last admitted frame may finish at the request limit.
        current = reason(state)
        raise Refused, "lifecycle.#{current}" if %w[stopped expired].include?(current)
        { "wire_bytes" => wire, "decoded_bytes" => decoded }.each do |name, amount|
          raise Refused, "lifecycle.budget" unless amount.is_a?(Integer) && amount >= 0 &&
            state.fetch(name) + amount <= state.dig("grant", "limits", name)
        end
        state["wire_bytes"] += wire
        state["decoded_bytes"] += decoded
      end
    end

    # Selects an exact run or reads a pinned selection. Closed business fields
    # exclude metadata, paths and commands. Every receipt contains only bounded
    # identities, paths and digests, preserving original worker evidence in place.
    # Returns evidence metadata/bytes; optional wait is acquisition only. Invalid
    # scope, revision or identity refuses without replaying the reader operation.
    def call(request, wait: 0)
      raise Refused, "reader.fields" unless request.is_a?(Hash)
      transaction(wait: wait) do |state|
        current = reason(state)
        raise Refused, "lifecycle.#{current}" if %w[stopped expired].include?(current)
        grant = state.fetch("grant")
        identities = RunEvidenceReader::IDENTITIES
        identity = request.slice(*identities)
        raise Refused, "selection.identity" unless identity.keys.sort == identities.sort &&
          identity["attempt"].is_a?(Integer) && identity["attempt"].positive? &&
          (identities - ["attempt"]).all? { |key| identity[key].is_a?(String) && identity[key].bytesize.between?(1, 128) } &&
          grant.fetch("tasks").include?(identity["task_id"])
        if request["operation"] == "select"
          raise Refused, "reader.fields" unless request.keys.sort == (identities + ["operation"]).sort
          raise Refused, "selection.limit" if state.fetch("selections").length >= 16
          config = RunEvidenceStore.new(grant.fetch("data_root")).select(identity,
            artifacts: grant.fetch("artifacts"), manager: grant.dig("transport", "manager"))
          manifest = RunEvidenceReader.new(**config.transform_keys(&:to_sym)).call(
            identity.merge("operation" => "manifest", "revision" => nil), caller: config.fetch("manager"))
          handle = manifest.fetch("revision")
          state.fetch("selections")[handle] = config
          manifest.merge("handle" => handle)
        else
          handle = request["handle"]
          raise Refused, "selection.handle" unless handle.is_a?(String) && state.fetch("selections").key?(handle)
          config = state.fetch("selections").fetch(handle)
          RunEvidenceReader.new(**config.transform_keys(&:to_sym)).call(request.reject { |key, _value| key == "handle" },
            caller: config.fetch("manager")).merge("handle" => handle)
        end
      end
    end

    # Holds a kernel-released owner lock for one foreground server only. Crash
    # releases ownership but never resets persisted admission/accounting.
    def serve_owner
      RunEvidenceStore.bytes(File.join(@path, "owner"), root: @path, private: true)
      File.open(File.join(@path, "owner"), File::RDWR | File::NOFOLLOW) do |owner|
        raise Refused, "lifecycle.owner_busy" unless owner.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end
  end
end
