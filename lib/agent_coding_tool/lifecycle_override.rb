# frozen_string_literal: true

require "digest"
require "securerandom"
require "time"

module AgentCodingTool
  # Preserves one administrative declaration outside replaceable lifecycle state.
  # Callers hold ReservationLock; this records neither validation nor retirement.
  class LifecycleOverride
    NAMESPACE = ".lifecycle-overrides"
    # Qualifies a direct state target and creates durable recovery/intent evidence.
    # Inputs are the target store/id, original mapping (nil for damaged reset),
    # transition, optional reason and observed rules. Unsafe paths/I/O raise.
    def initialize(store:, id:, state:, command:, reason:, observations:)
      @store, @id = store, id
      # Normalize only verified system aliases; arbitrary links still fail below.
      @path = WorktreeManager.canonical_system_path(store.state_path(id))
      unless File.realdirpath(@path) == @path && !File.symlink?(@path) &&
             (!File.exist?(@path) || (File.file?(@path) && File.stat(@path).nlink == 1))
        raise InvalidState, "#{id}: unsafe override state target"
      end
      @original = File.binread(@path) if File.exist?(@path)
      root = "#{File.dirname(File.dirname(@path))}-runs"
      directory = File.join(root, NAMESPACE, id, SecureRandom.uuid)
      cursor = directory
      loop do
        raise InvalidState, "#{id}: symlinked override evidence" if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)
        cursor = File.dirname(cursor)
      end
      FileUtils.mkdir_p(directory, mode: 0o700)
      [root, File.join(root, NAMESPACE), File.join(root, NAMESPACE, id), directory].each do |entry|
        unless File.stat(entry).uid == Process.uid && (File.stat(entry).mode & 0o077).zero?
          raise InvalidState, "#{id}: override evidence must be private and owned"
        end
      end
      @audit = StateStore.new(directory)
      @audit.publish_bytes("original", @original) if @original
      @record = {
        "schema" => "agent-coding-tool-lifecycle-override/v1", "task_id" => id,
        "attempt" => state && (state["started_at"] ?
          Digest::SHA256.hexdigest(JSON.generate(state.values_at("prepared_at", "started_at", "snapshot")))[0, 32] :
          state.dig("checkpoint", "attempt")),
        "command" => command, "requested_transition" => command,
        "at" => Time.now.utc.iso8601(6), "reason" => reason,
        "original_sha256" => @original && Digest::SHA256.hexdigest(@original),
        "original_absent" => @original.nil?,
        "recovery" => @original && @audit.state_path("original"),
        "observations" => observations, "write_status" => "not_attempted"
      }
      @audit.write("intent", @record)
    end

    # Publishes the requested mapping after its intent/recovery copy is durable.
    # Returns audit summary. Any publication or final audit error remains nonzero;
    # intent plus original/target hashes permits cold inspection after interruption.
    def publish(state)
      expected = YAML.dump(state)
      @record["requested_sha256"] = Digest::SHA256.hexdigest(expected)
      @audit.write("intent", @record)
      begin
        actual = File.binread(@path) if File.file?(@path) && !File.symlink?(@path)
        raise InvalidState, "#{@id}: state changed after override preservation; inspect intent" unless actual == @original
        @record["write_status"] = "uncertain"
        @store.write(@id, state)
        @record["write_status"] = "published"
      rescue StandardError => error
        actual = File.binread(@path) if File.file?(@path) && !File.symlink?(@path)
        @record["write_status"] = actual == @original ? "unchanged" : actual == expected ? "published_durability_uncertain" : "uncertain"
        @record["error_class"] = error.class.name
        raise
      ensure
        begin
          @audit.write("result", @record)
        rescue StandardError => error
          raise InvalidState, "#{@id}: override state #{@record.fetch('write_status')}; result audit failed (#{error.class}); inspect #{@audit.state_path('intent')} and target hashes"
        end
      end
      summary
    end

    # Returns compact evidence location and observations; no inspection or writes.
    def summary
      @record.merge("audit_path" => @audit.state_path("intent"))
    end
  end
end
