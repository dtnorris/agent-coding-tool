# frozen_string_literal: true

require "fileutils"
require "date"
require "tempfile"
require "time"
require "yaml"

module AgentCodingTool
  # Reads legacy state mappings and replaces whole files without serializing writers.
  class StateStore
    # Uses root as the state directory; no filesystem access occurs until load/write.
    def initialize(root)
      @root = root
    end

    # Returns a mapping (or {} for an absent file); damaged YAML raises InvalidState.
    # Diagnostics omit document contents. Other filesystem errors still propagate.
    def load(id)
      path = state_path(id)
      begin
        state = YAML.safe_load_file(path, aliases: false)
      rescue Errno::ENOENT
        return {} unless File.symlink?(path)

        raise InvalidState, "#{id}: task state is a dangling symlink"
      rescue Psych::Exception
        raise InvalidState, "#{id}: task state contains invalid YAML", cause: nil
      end
      raise InvalidState, "#{id}: task state must contain a YAML mapping" unless state.is_a?(Hash)

      validate_icebox!(id, state)
      state
    end

    # Serializes state, syncs a same-directory temporary, then atomically replaces id.
    # Pre-rename errors leave the old file intact; post-rename directory sync errors
    # raise InvalidState with the published outcome. Unsupported sync is not success.
    # Returns bytes written; serialization and pre-rename filesystem errors propagate.
    # This is not a transaction lock or proof of physical power-loss durability.
    def write(id, state)
      validate_icebox!(id, state)
      bytes = YAML.dump(state)
      FileUtils.mkdir_p(@root)
      # Follow existing links as File.write did; rename the target, not the link.
      path = File.realdirpath(state_path(id))
      previous = begin
        # Check existing write access without truncation, even if rename is allowed.
        File.open(path, File::WRONLY, &:stat)
      rescue Errno::ENOENT
        nil
      end
      directory = File.dirname(path)
      Tempfile.create([".#{File.basename(path)}-", ".tmp"], directory) do |temporary|
        temporary.binmode
        raise IOError, "#{id}: incomplete temporary state write" unless temporary.write(bytes) == bytes.bytesize

        if previous && [temporary.stat.uid, temporary.stat.gid] != [previous.uid, previous.gid]
          temporary.chown(previous.uid, previous.gid)
        end
        temporary.chmod(previous ? previous.mode & 0o7777 : 0o666 & ~File.umask)
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, path)
        begin
          File.open(directory) { |parent| parent.fsync }
        rescue Errno::EINVAL, Errno::ENOTSUP, NotImplementedError
          raise InvalidState, "#{id}: state replaced; directory synchronization unsupported; crash durability unconfirmed"
        rescue SystemCallError, IOError
          raise InvalidState, "#{id}: state replaced; directory synchronization failed; crash durability unconfirmed"
        end
      end
      bytes.bytesize
    end

    # Returns the existing task-id-based path without accessing the filesystem.
    def state_path(id)
      File.join(@root, "#{id}.yml")
    end

    private

    # Validates only the optional scheduling mapping, preserving legacy and
    # unrelated state. Returns nil; malformed shape/types/time raise InvalidState.
    def validate_icebox!(id, state)
      return unless state.key?("icebox")

      designation = state["icebox"]
      unless designation.is_a?(Hash) && (designation.keys - %w[at reason]).empty? &&
             designation["at"].is_a?(String) &&
             (!designation.key?("reason") || designation["reason"].is_a?(String))
        raise InvalidState, "#{id}: icebox must be a mapping with ISO 8601 string at and optional string reason"
      end
      begin
        raise ArgumentError unless designation.fetch("at").match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)

        DateTime.iso8601(designation.fetch("at"))
        Time.iso8601(designation.fetch("at"))
      rescue ArgumentError
        raise InvalidState, "#{id}: icebox.at must be a valid ISO 8601 timestamp"
      end
      nil
    end
  end
end
