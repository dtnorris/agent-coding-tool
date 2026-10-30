# frozen_string_literal: true

require "securerandom"
require "time"
require "digest"
require "json"

module AgentCodingTool
  # Bounded private operator observations. These confer no execution, isolation,
  # liveness, result-review, recovery or publication authority.
  class ExternalActivity
    SCHEMA = "agent-coding-tool-external-activity/v1"
    NAMESPACE = ".external-activity"
    ID = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
    UUID = /\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
    LIMITS = { "reporter" => 128, "kind" => 64, "identifier" => 256, "note" => 512, "reference" => 512 }.freeze
    DISPOSITIONS = %w[ended failed lost-contact].freeze

    # Binds existing stores/configured authority resolution; does not create paths.
    def initialize(data_root:, task_store:, state_store:, repo_inspector:)
      @data = File.realpath(data_root)
      @root = "#{@data}-runs"
      @namespace = File.join(@root, NAMESPACE)
      @tasks, @states, @inspector = task_store, state_store, repo_inspector
    end

    # Serializes short mutations/handoffs with the existing reservation lock,
    # including tasks without managed runs. Busy/foreign paths raise InvalidState.
    # Never holds the lock for an external worker's lifetime.
    def with_lock
      ReservationLock.synchronize(@data) { |lock| yield lock }
    end

    # Returns validated documents without writes or liveness probes. Damaged
    # evidence refuses instead of becoming inactivity. Cold readers use rename.
    def records
      return [] unless File.exist?(@root) || File.symlink?(@root)
      check_path!(@root, directory: true)
      return [] unless File.exist?(@namespace) || File.symlink?(@namespace)
      check_path!(@namespace, directory: true)
      documents = IncidentalMetadata.children(@namespace).sort.filter_map do |name|
        path = File.join(@namespace, name)
        # Only StateStore's private temporary is unpublished; never parse its
        # partial bytes when a reader races an atomic replacement.
        if name.match?(/\A\.[A-Za-z0-9][A-Za-z0-9_-]*\.yml-\d{8}-\d+-[a-z0-9]+\.tmp\z/)
          begin
            check_path!(path, directory: false)
          rescue Errno::ENOENT
            # Rename may already have published and removed this temporary.
          end
          next
        end
        check_path!(path, directory: false)
        id = name.delete_suffix(".yml")
        raise InvalidState, "external activity: foreign namespace entry" unless name == "#{id}.yml" && id.match?(ID)
        document = begin
          StateStore.new(@namespace).load(id)
        rescue InvalidState
          raise InvalidState, "external activity: invalid private YAML record", cause: nil
        end
        validate_document!(document, id)
      end
      observations = documents.flat_map { |document| [document["active"], *document.fetch("closed")].compact }
      ids = observations.map { |row| row.fetch("observation_id") }
      supplied = observations.filter_map { |row| row["identifier"] }
      raise InvalidState, "external activity: conflicting retained identities" unless ids.uniq == ids && supplied.uniq == supplied
      documents
    rescue SystemCallError, IOError, Psych::Exception, TypeError, ArgumentError
      raise InvalidState, "external activity: inaccessible or malformed private evidence", cause: nil
    end

    # Returns private task history or an absent view, without creating paths or
    # timestamps. Requires a safe registered filename and matching task identity.
    def show(id)
      task!(id)
      records.find { |document| document["task_id"] == id } || empty_document(id)
    end

    # Records reality even during managed execution. Exact retained identifier
    # retries are no-ops; ambiguous/reused identities and fresh COMPLETE reports
    # refuse. All supplied text remains inert, private and byte bounded.
    def report(id, reporter:, kind:, identifier: nil, note: nil, reference: nil, scope_complete: false, authorities: [])
      task!(id)
      payload = { "reporter" => reporter, "kind" => kind, "identifier" => identifier,
                  "note" => note, "reference" => reference }.reject { |_key, value| value.nil? }
      validate_payload!(payload)
      raise InvalidState, "external activity: scope completeness must be boolean" unless [true, false].include?(scope_complete)
      additions = checked_authorities(authorities)
      payload.merge!("scope_complete" => scope_complete, "reported_authorities" => additions)
      with_lock do
        task = task!(id)
        documents = records
        document = documents.find { |record| record["task_id"] == id } || empty_document(id)
        retained = documents.flat_map { |record| [record["active"], *record.fetch("closed")].compact }
        if identifier && (previous = retained.find { |row| row["identifier"] == identifier })
          next document if previous["task_id"] == id && previous.slice(*LIMITS.keys, "scope_complete", "reported_authorities") == payload
          raise InvalidState, "external activity: supplied identity retained with another task or payload"
        end
        raise InvalidState, "external activity: duplicate active observation; explicitly end its observation ID first" if document["active"]
        state = @states.load(id)
        raise InvalidState, "external activity: COMPLETE refuses a new declaration" if state.dig("result", "outcome") == "complete"
        floor = authority_floor(task, state, retained_readers: true)
        envelope = { "scope" => scope_complete && floor && additions.all? { |repo| repo["repository_id"] } ? "bounded" : "unknown",
                     "authorities" => ((floor || []) + additions).uniq }
        document["active"] = payload.merge("task_id" => id, "observation_id" => SecureRandom.uuid,
          "recorded_at" => Time.now.utc.iso8601(6), "recorded_by_uid" => Process.uid,
          "registered_repositories_sha256" => repository_fingerprint(task), "envelope" => envelope)
        persist(document)
      end
    end

    # Closes exactly one retained ID without signaling processes or calling any
    # lifecycle/recovery/result/checkpoint operation. Retained repeats are no-ops;
    # unknown/evicted IDs and changed dispositions raise InvalidState.
    def end_activity(id, observation_id, disposition:)
      task!(id)
      raise InvalidState, "external activity: invalid observation ID" unless observation_id.is_a?(String) && observation_id.match?(UUID)
      raise InvalidState, "external activity: invalid disposition" unless DISPOSITIONS.include?(disposition)
      with_lock do
        document = show(id)
        closed = document.fetch("closed").find { |row| row["observation_id"] == observation_id }
        if closed
          raise InvalidState, "external activity: retained disposition differs" unless closed["disposition"] == disposition
          next document
        end
        active = document["active"]
        unless active && active["observation_id"] == observation_id
          raise InvalidState, "external activity: unknown or evicted observation ID; active observation unchanged"
        end
        document["closed"] << active.merge("ended_at" => Time.now.utc.iso8601(6), "disposition" => disposition)
        if document.fetch("closed").length > 8
          document["closed"].shift
          document["omitted_older"] += 1
        end
        document["active"] = nil
        persist(document)
      end
    end

    # Returns public projections/effective envelopes for one cold snapshot.
    # Configuration/preparation drift makes scope unknown, retaining its floor.
    # Missing preparation alone is valid. This read never updates private records.
    def active_snapshot
      records.filter_map do |document|
        row = document["active"]
        next unless row
        envelope = row.fetch("envelope")
        begin
          task = task!(row.fetch("task_id"))
          current = authority_floor(task, @states.load(row.fetch("task_id")), retained_readers: true)
          if repository_fingerprint(task) != row.fetch("registered_repositories_sha256") || !current ||
             (current - envelope.fetch("authorities")).any?
            envelope = envelope.merge("scope" => "unknown")
          end
        rescue Error, SystemCallError
          envelope = envelope.merge("scope" => "unknown")
        end
        row.slice("task_id", "observation_id", "reporter", "kind", "recorded_at").merge(
          "provenance" => "operator-reported; ACT has neither verified nor authorized execution",
          "liveness" => "unknown", "isolation" => "unverified", "containment" => "unverified",
          "envelope" => envelope)
      end
    end

    # Shared whole-repository envelope for planner/status/start/launch/delivery.
    # Same-task activity always conflicts; unknown scope blocks other writers,
    # while genuinely read-only other tasks remain usable. No managed exception.
    def conflicts(task, state, snapshot: active_snapshot)
      return [] if snapshot.empty?
      floor = authority_floor(task, state)
      writer = task.fetch("repositories").any? { |_name, spec| spec.fetch("access") == "write" } ||
        (state["snapshot"].is_a?(Hash) && floor != [])
      snapshot.select do |activity|
        envelope = activity.fetch("envelope")
        activity.fetch("task_id") == task.fetch("id") ||
          (writer && (!floor || envelope.fetch("scope") == "unknown" ||
            (floor.map { |repo| repo.fetch("repository_id") } &
              envelope.fetch("authorities").map { |repo| repo.fetch("repository_id") }).any?))
      end.map { |activity| activity.slice("task_id", "observation_id", "envelope").merge(
        "reason" => "external activity reported; execution unauthorized, isolation unverified, liveness unknown; explicit end required") }
    end

    # Refuses execution/delivery on external conflicts, irrespective of collision
    # overrides. Original managed freshness/recovery gates remain independently due.
    def assert_clear!(id)
      task = task!(id)
      return if conflicts(task, @states.load(id)).empty?
      raise InvalidState, "#{id}: external activity conflict; explicit observation end required; original managed gates still apply"
    end

    private

    # Returns configured-plus-retained-preparation writers, or nil if unresolved.
    # Observation envelopes retain all old preparation references because access
    # labels were not saved there. Removed names remain potential writers; target
    # read-only tasks use current access labels. Missing preparation is valid.
    def authority_floor(task, state, retained_readers: false)
      repositories = task.fetch("repositories")
      values = repositories.filter_map do |name, spec|
        @inspector.repository_authority(name, spec) if spec.fetch("access") == "write"
      end
      if (snapshot = state["snapshot"])
        return nil unless snapshot.is_a?(Hash)
        snapshot.each do |name, repo|
          next if !retained_readers && repositories.dig(name, "access") == "read_only"
          return nil unless repo.is_a?(Hash)
          values << repo.values_at("remote_url", "branch")
        end
      end
      authorities = checked_authorities(values)
      authorities unless authorities.any? { |repo| !repo["repository_id"] }
    rescue Error, SystemCallError, KeyError, TypeError, NoMethodError
      nil
    end

    # Uses the existing publication Git identity contract. Preserves branch facts;
    # equality for external conflicts reserves the entire repository. Bad supplied
    # input raises without echoing private text; no reference bytes are imported.
    def checked_authorities(values)
      raise InvalidState, "external activity: invalid reported authorities" unless values.is_a?(Array) && values.length <= 128
      values.map do |pair|
        unless pair.is_a?(Array) && pair.length == 2 && pair.all? { |value| valid_text?(value, 1024) }
          raise InvalidState, "external activity: invalid reported authority"
        end
        identity = repository_identity(pair.first)
        { "repository_id" => identity, "remote_url" => pair.first, "branch" => pair.last }
      end.uniq
    end

    # Reuses publication normalization but refuses ambiguous remote syntax as
    # scope evidence (such as a nonlocal file URL host or extra GitHub path).
    # Unresolved identity returns nil, making reported scope explicitly unknown.
    def repository_identity(remote)
      identity = RepositoryIdentity.resolve(remote)
      if remote.start_with?("file://")
        return nil unless [nil, "", "localhost"].include?(URI(remote).host)
      end
      return identity if identity.start_with?("file://") ||
        identity.match?(/\A[A-Za-z0-9_-][A-Za-z0-9_.-]*\/[A-Za-z0-9_-][A-Za-z0-9_.-]*\z/)
      nil
    rescue RepositoryError, URI::InvalidURIError
      nil
    end

    # Validates required/optional inert strings under fixed UTF-8 byte limits.
    def validate_payload!(payload)
      unless %w[reporter kind].all? { |key| payload.key?(key) } &&
             payload.all? { |key, value| LIMITS.key?(key) && valid_text?(value, LIMITS.fetch(key)) }
        raise InvalidState, "external activity: invalid text type, encoding, control character or byte length"
      end
    end

    # Checks text without conversion/truncation or payload-bearing diagnostics.
    def valid_text?(value, limit)
      value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
        !value.strip.empty? && value.bytesize <= limit && !value.match?(/[[:cntrl:]\p{Cf}]/)
    end

    # Rejects malformed/partial documents and injected keys. Returns the validated
    # mapping; errors never reproduce YAML or supplied observation text.
    def validate_document!(document, id)
      valid = document.keys.sort == %w[active closed omitted_older schema task_id] &&
        document.values_at("schema", "task_id") == [SCHEMA, id] &&
        document["omitted_older"].is_a?(Integer) && document["omitted_older"] >= 0 &&
        (document["active"].nil? || document["active"].is_a?(Hash)) &&
        document["closed"].is_a?(Array) && document["closed"].length <= 8 &&
        document["closed"].all? { |row| row.is_a?(Hash) }
      raise InvalidState, "external activity: incompatible or partial record" unless valid
      [document["active"], *document.fetch("closed")].compact.each do |row|
        raise InvalidState, "external activity: malformed observation" unless row.is_a?(Hash)
        validate_payload!(row.slice(*LIMITS.keys))
        closed = document.fetch("closed").include?(row)
        required = %w[task_id observation_id recorded_at recorded_by_uid registered_repositories_sha256 envelope reporter kind scope_complete reported_authorities]
        allowed = required + LIMITS.keys + (closed ? %w[ended_at disposition] : [])
        unless (required - row.keys).empty? && (row.keys - allowed).empty? &&
               row["task_id"] == id && row["observation_id"].is_a?(String) && row["observation_id"].match?(UUID) &&
               row["recorded_by_uid"].is_a?(Integer) && row["recorded_by_uid"] >= 0 &&
               [true, false].include?(row["scope_complete"]) &&
               row["registered_repositories_sha256"].is_a?(String) && row["registered_repositories_sha256"].match?(/\A[0-9a-f]{64}\z/)
          raise InvalidState, "external activity: incompatible observation identity"
        end
        Time.iso8601(row.fetch("recorded_at"))
        if closed
          Time.iso8601(row.fetch("ended_at"))
          raise InvalidState, "external activity: invalid closure" unless DISPOSITIONS.include?(row["disposition"])
        end
        envelope = row["envelope"]
        unless envelope.is_a?(Hash) && envelope.keys.sort == %w[authorities scope] && %w[bounded unknown].include?(envelope["scope"])
          raise InvalidState, "external activity: malformed conflict envelope"
        end
        [row["reported_authorities"], envelope["authorities"]].each do |authorities|
          unless authorities.is_a?(Array) && authorities.length <= 256 && authorities.all? { |authority|
            authority.is_a?(Hash) && authority.keys.sort == %w[branch remote_url repository_id] &&
              %w[remote_url branch].all? { |key| valid_text?(authority[key], 1024) } &&
              (authority["repository_id"].nil? || valid_text?(authority["repository_id"], 2048)) }
            raise InvalidState, "external activity: malformed retained authorities"
          end
          authorities.each do |authority|
            resolved = repository_identity(authority.fetch("remote_url"))
            if resolved && resolved != authority["repository_id"]
              raise InvalidState, "external activity: incompatible retained repository identity"
            end
          end
        end
        if envelope["scope"] == "bounded" && !row["scope_complete"]
          raise InvalidState, "external activity: incompatible scope completeness"
        end
        if envelope["scope"] == "bounded" && envelope.fetch("authorities").any? { |authority| !authority["repository_id"] }
          raise InvalidState, "external activity: unresolved bounded repository identity"
        end
      end
      document
    rescue ArgumentError, TypeError, KeyError
      raise InvalidState, "external activity: malformed observation", cause: nil
    end

    # Loads safe registered task identity; a filename/path alone grants no identity.
    def task!(id)
      raise InvalidTask, "external activity: unsafe task ID" unless id.is_a?(String) && id.match?(ID) && id != NAMESPACE
      task = @tasks.load(id)
      raise InvalidTask, "external activity: task identity mismatch" unless task["id"] == id
      task
    end

    # Binds scope to configured declarations without duplicating task metadata in
    # the record; declaration changes make the effective scope unknown.
    def repository_fingerprint(task)
      Digest::SHA256.hexdigest(JSON.generate(task.fetch("repositories")))
    end

    # Returns an absent-history view without allocating an observation/attempt.
    def empty_document(id)
      { "schema" => SCHEMA, "task_id" => id, "active" => nil, "closed" => [], "omitted_older" => 0 }
    end

    # Checks ancestors/ownership/modes before StateStore can follow symlinks.
    # Only explicit mutations may create the requested private directory.
    def check_path!(path, directory:, create: false)
      cursor = path
      loop do
        raise InvalidState, "external activity: symlinked private evidence path" if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)
        cursor = File.dirname(cursor)
      end
      Dir.mkdir(path, 0o700) if create && !File.exist?(path)
      stat = File.lstat(path)
      unless (directory ? stat.directory? : stat.file?) && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        raise InvalidState, "external activity: foreign or non-private evidence path"
      end
    end

    # Atomically replaces only this private document. StateStore preserves old
    # bytes before rename and reports post-publication synchronization uncertainty.
    def persist(document)
      check_path!(@namespace, directory: true, create: true)
      id = document.fetch("task_id")
      path = File.join(@namespace, "#{id}.yml")
      check_path!(path, directory: false) if File.exist?(path) || File.symlink?(path)
      validate_document!(document, id)
      # Independent values prevent YAML anchors from shared authority objects;
      # cold StateStore readers intentionally reject YAML aliases.
      serialized_document = JSON.parse(JSON.generate(document))
      previous_umask = File.umask(0o077)
      begin
        StateStore.new(@namespace).write(id, serialized_document)
      ensure
        File.umask(previous_umask)
      end
      document
    end
  end
end
