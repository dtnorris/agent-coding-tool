# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

module AgentCodingTool
  # Produces a deterministic manager reminder from one current local task file.
  # It reads no runtime state, prepared prompts, logs, configuration or network.
  module ManagerReminder
    MAX_SOURCE_BYTES = 65_536
    MAX_REMINDER_BYTES = 8_192

    # Returns UTF-8 text for a portable task ID under data_root. The goal is
    # quoted without summarization (whitespace alone is normalized); acceptance
    # and constraints remain in the identified source. Invalid/missing/unsafe
    # sources raise InvalidTask before any clipboard call or output.
    def self.render(data_root, id)
      unless id.is_a?(String) && id.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
        raise InvalidTask, "manage: invalid task ID"
      end
      root = File.realpath(data_root)
      relative = "tasks/#{id}.yml"
      path = File.join(root, relative)
      unless File.realpath(File.dirname(path)) == File.dirname(path) && !File.symlink?(path)
        raise InvalidTask, "manage: task source must not contain symlinks"
      end
      bytes = read_source(path)
      task = YAML.safe_load(bytes, aliases: false)
      unless task.is_a?(Hash) && task["id"] == id &&
             task["goal"].is_a?(String) && !task["goal"].strip.empty? &&
             task["acceptance"].is_a?(Array) && !task["acceptance"].empty? &&
             task["acceptance"].all? { |item| item.is_a?(String) && !item.strip.empty? } &&
             task.fetch("constraints", []).is_a?(Array) &&
             task.fetch("constraints", []).all? { |item| item.is_a?(String) && !item.strip.empty? }
        raise InvalidTask, "manage: source must have matching id, nonblank goal and acceptance, and valid constraints"
      end
      if task.fetch("goal").match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
        raise InvalidTask, "manage: goal must not contain control characters"
      end
      goal = task.fetch("goal").gsub(/\s+/, " ").strip
      reminder = [
        "For #{id}, keep this registered goal in view: #{JSON.generate(goal)}.",
        "Read the complete acceptance criteria and constraints in local #{relative} " \
          "(SHA-256 #{Digest::SHA256.hexdigest(bytes)}) as the scope boundary; " \
          "this is the current local definition, not a prepared snapshot or verified progress report.",
        "Reconcile my update below with established evidence, distinguish proven results from missing checks " \
          "and blockers, and choose the smallest next verifiable step, explaining why any new repair or " \
          "dependency is necessary for the original acceptance.",
        "Preserve safety and repository-authority constraints, reuse applicable validated work, and stop " \
          "when the agreed acceptance and handoff are complete, recording optional improvements separately."
      ].join(" ") + "\n"
      if reminder.bytesize > MAX_REMINDER_BYTES
        raise InvalidTask, "manage: reminder exceeds #{MAX_REMINDER_BYTES} bytes; source goal was not truncated"
      end
      reminder
    rescue Psych::Exception, SystemCallError, IOError, ArgumentError => error
      raise InvalidTask, "manage: cannot read task source (#{error.class})", cause: nil
    end

    # Reads at most 64 KiB from one regular nonsymlink UTF-8 source. Refuses
    # control bytes and observed replacement/modification instead of truncating;
    # file/encoding errors propagate to render's fixed diagnostic.
    def self.read_source(path)
      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        before = file.stat
        unless before.file? && before.size <= MAX_SOURCE_BYTES
          raise InvalidTask, "manage: task source must be a regular file of at most #{MAX_SOURCE_BYTES} bytes"
        end
        bytes = file.read(MAX_SOURCE_BYTES + 1).to_s.force_encoding(Encoding::UTF_8)
        unless bytes.bytesize <= MAX_SOURCE_BYTES && file.stat == before && File.lstat(path) == before
          raise InvalidTask, "manage: task source changed during read or exceeds size limit"
        end
        unless bytes.valid_encoding? && !bytes.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
          raise InvalidTask, "manage: task source must be UTF-8 without control characters"
        end
        bytes
      end
    end
    private_class_method :read_source
  end
end
