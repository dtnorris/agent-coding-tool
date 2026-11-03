# frozen_string_literal: true

require_relative "source_reader"

module AgentCodingTool
  # Separate, local-only source leases in the existing finite sharing session.
  # Source authorization never selects, grants or releases task/run evidence.
  module SourceSharing
    Refused = RunEvidenceReader::Refused
    # Approves one named repository or revokes its lease. Returns local grant
    # metadata, including its root for operator review. Inputs are local CLI facts;
    # no remote source operation can invoke admission. Refuses unsafe roots or IDs.
    def share_source(repository, code_root: nil, root: nil, seconds: 1800, revoke: false)
      raise Refused, "source.repository" unless repository.is_a?(String) && repository.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/)
      binding = SourceReader.admit(code_root, root) unless revoke
      transaction(wait: 1) do |state|
        raise Refused, "share.not_ready" unless sharing?(state) && state["ready"] && reason(state) == "active"
        raise Refused, "source.lease" unless seconds.is_a?(Integer) && seconds.between?(60, EvidenceSession::LIMITS.fetch("seconds"))
        sources = state["sources"] ||= {}
        previous = sources[repository]
        raise Refused, "source.repository" if revoke && !previous
        raise Refused, "source.capacity" if !previous && sources.length >= 16
        if !revoke && sources.values.any? { |scope| scope.fetch("binding").fetch("code_root") != code_root }
          raise Refused, "source.code_root"
        end
        now = Time.now.to_f
        expiry = [now + seconds, state.fetch("expires_at")].min
        scope = { "binding" => revoke ? previous.fetch("binding") : binding,
          "generation" => previous ? previous.fetch("generation") + 1 : 1, "revoked" => revoke,
          "expires_at" => expiry,
          "monotonic_expires_at" => Process.clock_gettime(Process::CLOCK_MONOTONIC) + [seconds, expiry - now].min }
        sources[repository] = scope
        { "repository" => repository, "root" => scope.dig("binding", "root"),
          "status" => revoke ? "revoked" : "granted", "expires_at" => expiry,
          "generation" => scope.fetch("generation"), "audience" => state.dig("grant", "transport") }
      end
    end

    # Requires an active source lease and optional exact generation. Both clocks,
    # readiness and finite tunnel admission apply on every call and wire fragment.
    # Returns the private scope; missing/revoked/expired grants raise Refused.
    def source_scope!(state, repository, generation = nil)
      scope = state.fetch("sources", {})[repository]
      raise Refused, "source.scope" unless sharing?(state) && state["ready"] && scope && !scope["revoked"] &&
        Time.now.to_f < scope.fetch("expires_at") && Process.clock_gettime(Process::CLOCK_MONOTONIC) < scope.fetch("monotonic_expires_at") &&
        (!generation || scope.fetch("generation") == generation)
      scope
    end

    # Executes a closed source query under the same lock/budgets as task reads.
    # Returns only approved IDs/relative paths and live-source metadata. Remote
    # callers cannot supply roots, grant fields, commands or task identities.
    def source_call(request, wait: 0)
      raise Refused, "source.fields" unless request.is_a?(Hash)
      operation = request["operation"]
      fields = { "discover" => %w[operation], "list" => %w[operation repository path offset],
        "search" => %w[operation repository path query offset], "read" => %w[operation repository path offset length version] }[operation]
      raise Refused, "source.fields" unless fields && (request.keys - fields).empty?
      %w[offset length].each do |name|
        next unless request.key?(name)
        value = request[name]
        maximum = name == "length" ? SourceReader::CHUNK : operation == "read" ? SourceReader::FILE_LIMIT : SourceReader::ENTRIES
        raise Refused, "source.range" unless value.is_a?(Integer) && value.between?(name == "length" ? 1 : 0, maximum)
      end
      raise Refused, "source.version" if request.key?("version") && (!request["version"].is_a?(String) || !request["version"].match?(/\A[0-9a-f]{64}\z/))
      transaction(wait: wait) do |state|
        raise Refused, "source.closed" unless sharing?(state) && state["ready"] && !%w[stopped expired].include?(reason(state))
        if operation == "discover"
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SourceReader::SECONDS
          roots = state.fetch("sources", {}).filter_map do |repository, scope|
            begin
              source_scope!(state, repository)
              # Discovery validates identities and excludes no-longer-safe roots.
              SourceReader.new(scope.fetch("binding"), deadline: deadline).inventory
              [repository, scope.fetch("generation")]
            rescue Refused
              raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              nil
            end
          end.to_h
          next { "kind" => "live_source", "repositories" => roots.keys.map { |repository| { "repository" => repository } },
            "_release" => { "source" => roots } }
        end
        repository = request.fetch("repository")
        scope = source_scope!(state, repository)
        binding = scope.fetch("binding").merge("lease" => [state.fetch("grant_sha256"), repository, scope.fetch("generation")])
        result = SourceReader.new(binding).call(request)
        snapshot = result.delete("_snapshot")
        result.merge("repository" => repository, "_release" => { "source" => { repository => scope.fetch("generation") },
          "repository" => repository, "snapshot" => snapshot })
      end
    rescue KeyError, TypeError, ArgumentError
      raise Refused, "source.fields", cause: nil
    end

    # Revalidates source roots and observed file versions before each wire write.
    # Called only with server-created private release facts while the ledger lock
    # is held. Refused/changed source releases no further fragment.
    def source_release!(state, request)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SourceReader::SECONDS
      request.fetch("source").each do |repository, generation|
        scope = source_scope!(state, repository, generation)
        binding = scope.fetch("binding").merge("lease" => [state.fetch("grant_sha256"), repository, scope.fetch("generation")])
        reader = SourceReader.new(binding, deadline: deadline)
        if repository == request["repository"]
          reader.verify(request.fetch("snapshot"))
        else
          reader.inventory
        end
        source_scope!(state, repository, generation)
      end
    end
  end
end
