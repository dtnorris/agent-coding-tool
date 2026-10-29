# frozen_string_literal: true

require_relative "run_evidence_reader"

module AgentCodingTool
  # Resolves exact managed run identities from existing ACT records. This class
  # neither discovers unmanaged Codex sessions nor executes evidence or commands.
  class RunEvidenceStore
    Refused = RunEvidenceReader::Refused

    # Rejects duplicate members at every nesting level before any dispatch.
    class UniqueObject < Hash
      # Inserts a JSON member, returning its value; duplicate keys raise.
      def []=(key, value)
        raise JSON::ParserError, "duplicate member" if key?(key)
        super
      end
    end

    # Parses bounded nesting with unique members; invalid JSON raises ParserError.
    def self.parse(bytes)
      checked = JSON.parse(bytes, max_nesting: 16, allow_duplicate_key: false, object_class: UniqueObject)
      # UniqueObject guards parsing, not subsequent legitimate ledger updates.
      JSON.parse(JSON.generate(checked), max_nesting: 16)
    end

    # Returns bounded regular-file bytes under a canonical root. All ancestors
    # must be nonsymlinks; private requires operator ownership and private mode.
    # Missing, escaped, changed or malformed sources raise fixed refusals.
    def self.bytes(path, root:, private: false)
      raise Refused, "source.path" unless path.is_a?(String) && path.start_with?("#{root}/") &&
        File.expand_path(path) == path && File.realpath(root) == root
      cursor = path
      loop do
        raise Refused, "source.symlink" if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)
        cursor = File.dirname(cursor)
      end
      raise Refused, "source.escape" unless File.realpath(path) == path
      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        stat = file.stat
        raise Refused, "source.type_or_size" unless stat.file? && stat.size <= RunEvidenceReader::MAX_FILE &&
          (!private || (stat.uid == Process.uid && (stat.mode & 0o077).zero?))
        bytes = file.binmode.read(RunEvidenceReader::MAX_FILE + 1) || "".b
        current = File.stat(path)
        raise Refused, "source.changed" unless bytes.bytesize <= RunEvidenceReader::MAX_FILE && file.stat == stat &&
          File.realpath(path) == path && current.dev == stat.dev && current.ino == stat.ino
        bytes
      end
    rescue SystemCallError, IOError, ArgumentError
      raise Refused, "source.unavailable", cause: nil
    end

    # Uses an operator-approved ACT data root, returning a read-only resolver.
    # Missing/noncanonical roots raise; no directory is created.
    def initialize(data_root)
      @root = "#{File.realpath(data_root)}-runs"
      raise Refused, "source.root" unless File.realpath(@root) == @root
    rescue SystemCallError
      raise Refused, "source.root", cause: nil
    end

    # Resolves all four exact identities to one authoritative handoff and builds
    # immutable file approvals. Returns reader constructor arguments. Ambiguity,
    # missing provenance, unsafe paths or mismatched source bytes refuse.
    def select(identity, artifacts:, manager:)
      task = identity.fetch("task_id")
      raise Refused, "selection.task" unless task.is_a?(String) && task.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      task_root = File.join(@root, task)
      paths = children(task_root).map { |entry| File.join(task_root, entry, "handoff.json") }
      matches = paths.filter_map do |path|
        raw = self.class.bytes(path, root: @root)
        report = self.class.parse(raw)
        raise Refused, "selection.foreign" unless report.is_a?(Hash) && report["task_id"] == task &&
          report["schema_version"] == "agent-coding-tool-run/v1"
        [path, raw, report] if RunEvidenceReader::IDENTITIES.all? { |field| report[field] == identity[field] }
      end
      raise Refused, "selection.missing_or_ambiguous" unless matches.length == 1
      path, raw, report = matches.first
      binding = identity.merge("workspace" => report.fetch("workspace"), "repository" => report.fetch("writable_repository"),
        "base_sha" => report.fetch("writable_authority").fetch("pushed_sha"),
        "remote_url" => report.fetch("writable_authority").fetch("remote_url"),
        "branch" => report.fetch("writable_authority").fetch("branch"))
      approvals = artifacts.to_h { |name| [name, { "status" => "missing" }] }
      run_dir = File.dirname(path)
      { "final" => "final_path", "transcript" => "jsonl_path", "stderr" => "stderr_path" }.each do |name, field|
        next unless artifacts.include?(name)
        source = report.fetch(field)
        next unless File.exist?(source) || File.symlink?(source)
        approvals[name] = approval(source, run_dir,
          %w[exited invalid_final interrupted child_start_failed preflight_failed preflight_abandoned].include?(report["status"]) ? "complete" : "pending")
      end
      checkpoint_dir = checkpoint(report, binding, artifacts, approvals)
      config = { "run_dir" => run_dir, "checkpoint_dir" => checkpoint_dir,
        "handoff_sha256" => Digest::SHA256.hexdigest(raw), "binding" => binding,
        "approvals" => approvals, "manager" => manager }
      # The qualified reader checks every available artifact link before selection
      # is admitted; malformed evidence cannot become an apparently valid manifest.
      reader = RunEvidenceReader.new(**config.transform_keys(&:to_sym))
      approvals.each do |name, spec|
        next if spec["status"] == "missing"
        reader.send(:artifact!, name, report)
      end
      config
    rescue KeyError, TypeError, JSON::ParserError, NoMethodError
      raise Refused, "selection.malformed", cause: nil
    end

    private

    # Returns bounded run/checkpoint directories, ignoring only regular Finder
    # metadata files. Symlinks, other file types and unknown entries refuse.
    def children(path)
      raise Refused, "source.directory" unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      entries = Dir.children(path).sort
      raise Refused, "source.inventory" unless entries.length <= 1024
      entries.reject! { |entry| entry == ".DS_Store" && File.lstat(File.join(path, entry)).file? }
      raise Refused, "source.inventory" unless entries.all? do |entry|
        entry.match?(/\A[A-Za-z0-9_-]+\z/) && File.lstat(File.join(path, entry)).directory?
      end
      entries
    end

    # Pins exact bytes in an approved directory; returns metadata, never a copy.
    def approval(path, root, status = "complete")
      bytes = self.class.bytes(path, root: root)
      { "path" => path, "sha256" => Digest::SHA256.hexdigest(bytes), "bytes" => bytes.bytesize, "status" => status }
    end

    # Finds an existing checkpoint pointer bound to this launch, then pins its
    # candidate and every matching finished gate receipt. Raw validation output
    # remains missing: ACT gate v1 does not capture it. Missing records are normal;
    # multiple matching checkpoint pointers or corrupt evidence refuse.
    def checkpoint(report, binding, artifacts, approvals)
      return @root if (artifacts & %w[checkpoint candidate validation]).empty?
      task_root = File.join(@root, "checkpoints", binding.fetch("task_id"))
      return @root unless File.exist?(task_root) || File.symlink?(task_root)
      matches = children(task_root).filter_map do |entry|
        directory = File.join(task_root, entry)
        pointer_path = File.join(directory, "current.json")
        next unless File.exist?(pointer_path) || File.symlink?(pointer_path)
        pointer = self.class.parse(self.class.bytes(pointer_path, root: @root))
        filename = pointer.fetch("record_file")
        raise Refused, "checkpoint.path" unless filename.is_a?(String) && filename.match?(/\A[0-9a-f-]+\.json\z/)
        spec = approval(File.join(directory, filename), @root)
        raise Refused, "checkpoint.digest" unless spec["sha256"] == pointer.fetch("sha256")
        record = self.class.parse(self.class.bytes(spec.fetch("path"), root: @root))
        [directory, spec, record] if record["launch_invocation"] == binding["invocation_id"]
      end
      raise Refused, "checkpoint.ambiguous" if matches.length > 1
      return @root if matches.empty?
      directory, spec, record = matches.first
      binding["checkpoint_attempt"] = record.fetch("attempt")
      # A's reader requires the checkpoint link internally for candidate/gates.
      approvals["checkpoint"] = spec if (artifacts & %w[checkpoint candidate validation]).any?
      if artifacts.include?("candidate")
        filename = record.fetch("artifact")
        raise Refused, "checkpoint.path" unless filename.is_a?(String) && filename.match?(/\A[0-9a-f-]+\.patch\z/)
        approvals["candidate"] = approval(File.join(directory, filename), directory)
      end
      if artifacts.include?("validation")
        receipts = Dir.children(directory).grep(/\Agate-[0-9a-f-]+\.finished\.json\z/).sort
        raise Refused, "checkpoint.receipts" if receipts.length > 64
        receipts.each do |filename|
          source = File.join(directory, filename)
          receipt = self.class.parse(self.class.bytes(source, root: directory))
          next unless receipt.dig("candidate", "sha256") == record["sha256"] &&
            receipt.dig("candidate", "launch_invocation") == binding["invocation_id"]
          approvals["validation:#{filename}"] = approval(source, directory)
        end
        approvals.delete("validation") unless receipts.empty? || approvals.keys.none? { |name| name.start_with?("validation:") }
      end
      directory
    end
  end
end
