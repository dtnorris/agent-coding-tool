# frozen_string_literal: true

module AgentCodingTool
  # Retains only explicitly selected ZIP bytes outside source and ACTD content.
  # Imports carry no execution, session, checkpoint or acceptance provenance.
  class ImportedEvidence
    Refused = RunEvidenceReader::Refused
    SOURCE = "externally_supplied_zip"
    SCHEMA = "agent-coding-tool-imported-evidence/v1"
    MAX_FILE = RunEvidenceReader::MAX_FILE
    MAX_ARTIFACTS = 64
    MAX_STORAGE = 64 * 1024 * 1024

    # Binds one canonical data root without creating storage. Unsafe roots refuse.
    def initialize(data)
      @data = File.realpath(data)
      @root = "#{@data}-imports"
    end

    # Validates and durably copies one regular single-link ZIP, then atomically
    # publishes its task-bound identity. The caller checks live admission in the
    # prepublication block. Failed/interrupted writes never publish partial data;
    # the next locked import removes only the fixed private staging files.
    def admit(task, path)
      RunEvidenceStore.task_context(@data, task)
      filename = File.basename(path)
      raise Refused, "import.filename" unless filename.valid_encoding? && filename.bytesize.between?(5, 128) &&
        filename.match?(/\A[^\x00-\x1f\x7f\/\\]+\.zip\z/i)
      path = File.expand_path(path)
      secure_directory(@root, create: true)
      File.open(File.join(@root, "lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        raise Refused, "import.busy" unless lock.stat.file? && lock.stat.uid == Process.uid &&
          lock.stat.nlink == 1 && (lock.stat.mode & 0o077).zero? && lock.flock(File::LOCK_EX | File::LOCK_NB)
        recover
        File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |source|
          original = source.stat
          raise Refused, "import.size" if original.size > MAX_FILE
          raise Refused, "import.source" unless original.file? && original.uid == Process.uid && original.nlink == 1 &&
            original.size.between?(22, MAX_FILE) && File.realpath(path) == path && !path.start_with?("#{@root}/")
          bytes = source.binmode.read(MAX_FILE + 1)
          raise Refused, "import.zip_or_size" unless bytes.bytesize == original.size && zip?(bytes)
          digest = Digest::SHA256.hexdigest(bytes)
          id = "zip-#{Digest::SHA256.hexdigest("#{task}:#{digest}")}"
          record = { "schema" => SCHEMA, "task_id" => task, "artifact_id" => id,
            "source" => SOURCE, "filename" => filename, "bytes" => bytes.bytesize, "sha256" => digest }
          entries = records
          existing = entries.find { |entry| entry["artifact_id"] == id }
          check_source(source, original, path)
          if existing
            select({ "task_id" => task, "artifact" => id }, manager: "local-import")
            retained = RunEvidenceStore.bytes(File.join(@root, id, "bundle"), root: @root, private: true)
            raise Refused, "import.retained_changed" unless retained == bytes
            yield existing
            return existing.merge("reused" => true)
          end
          raise Refused, "import.storage_limit" if entries.length >= MAX_ARTIFACTS ||
            entries.sum { |entry| entry.fetch("bytes") } + bytes.bytesize > MAX_STORAGE
          staging = File.join(@root, ".pending")
          Dir.mkdir(staging, 0o700)
          durable_file(File.join(staging, "bundle"), bytes)
          durable_file(File.join(staging, "registration.json"), JSON.generate(record))
          File.open(staging, File::RDONLY, &:fsync)
          check_source(source, original, path)
          yield record
          File.rename(staging, File.join(@root, id))
          File.open(@root, File::RDONLY, &:fsync)
          record.merge("reused" => false)
        end
      ensure
        recover if lock && lock.flock(File::LOCK_EX | File::LOCK_NB)
      end
    rescue SystemCallError, IOError, ArgumentError, TypeError
      raise Refused, "import.unavailable", cause: nil
    end

    # Returns bounded public metadata for this registered task only. Staging is
    # invisible; no source or retained host pathname enters the remote inventory.
    def discover(task)
      return [] unless File.exist?(@root) || File.symlink?(@root)
      records.select { |record| record["task_id"] == task }.map do |record|
        record.reject { |key, _| key == "schema" }.merge("evidence_source" => SOURCE)
      end
    end

    # Pins an exact published registration and ZIP for the existing immutable
    # reader. Cross-task substitutions, changed/missing private bytes refuse.
    def select(identity, manager:)
      task, id = identity.values_at("task_id", "artifact")
      raise Refused, "import.identity" unless task.is_a?(String) && task.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) &&
        id.is_a?(String) && id.match?(/\Azip-[0-9a-f]{64}\z/)
      secure_directory(@root)
      directory = File.join(@root, id)
      secure_directory(directory)
      raw = RunEvidenceStore.bytes(File.join(directory, "registration.json"), root: @root, private: true)
      record = RunEvidenceStore.parse(raw)
      self.class.validate_record(record, identity)
      bytes = RunEvidenceStore.bytes(File.join(directory, "bundle"), root: @root, private: true)
      raise Refused, "import.retained_changed" unless bytes.bytesize == record["bytes"] && Digest::SHA256.hexdigest(bytes) == record["sha256"]
      { "run_dir" => directory, "checkpoint_dir" => directory, "handoff_sha256" => Digest::SHA256.hexdigest(raw),
        "binding" => identity.merge("source" => SOURCE), "manager" => manager, "paged" => true,
        "approvals" => { id => record.slice("filename", "bytes", "sha256").merge("status" => "complete",
          "path" => File.join(directory, "bundle")) } }
    end

    # Verifies closed metadata without inventing managed-run provenance. Returns
    # nil or raises Refused; member contents are never unpacked or executed.
    def self.validate_record(record, identity)
      raise Refused, "import.binding" unless record.is_a?(Hash) &&
        record.keys.sort == %w[schema task_id artifact_id source filename bytes sha256].sort &&
        record["schema"] == SCHEMA && record["source"] == SOURCE && record["task_id"] == identity["task_id"] &&
        record["artifact_id"] == identity["artifact"] &&
        record["task_id"].is_a?(String) && record["task_id"].match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) &&
        record["bytes"].is_a?(Integer) && record["bytes"].between?(22, MAX_FILE) &&
        record["sha256"].is_a?(String) && record["sha256"].match?(/\A[0-9a-f]{64}\z/) &&
        record["artifact_id"] == "zip-#{Digest::SHA256.hexdigest("#{record['task_id']}:#{record['sha256']}")}" &&
        record["filename"].is_a?(String) && record["filename"].bytesize.between?(5, 128) &&
        record["filename"].match?(/\A[^\x00-\x1f\x7f\/\\]+\.zip\z/i)
      nil
    end

    private

    # Checks canonical private owned directories; never repairs foreign storage.
    def secure_directory(path, create: false)
      Dir.mkdir(path, 0o700) if create && !File.exist?(path) && !File.symlink?(path)
      stat = File.lstat(path)
      raise Refused, "import.directory" unless stat.directory? && stat.uid == Process.uid &&
        (stat.mode & 0o077).zero? && File.realpath(path) == path
    end

    # Reads at most 64 published manifests. Unknown entries refuse; unfinished
    # staging reserves no visible identity and is handled only by the writer.
    def records
      secure_directory(@root)
      entries = Dir.children(@root) - %w[lock .pending]
      raise Refused, "import.inventory" unless entries.length <= MAX_ARTIFACTS && entries.all? { |name| name.match?(/\Azip-[0-9a-f]{64}\z/) }
      entries.sort.map do |name|
        directory = File.join(@root, name)
        secure_directory(directory)
        record = RunEvidenceStore.parse(RunEvidenceStore.bytes(File.join(directory, "registration.json"), root: @root, private: true))
        self.class.validate_record(record, "task_id" => record["task_id"], "artifact" => name)
        record
      end
    end

    # Removes only known, private, regular staging files under the writer lock.
    # Unexpected recovery content refuses and remains available for owner review.
    def recover
      staging = File.join(@root, ".pending")
      return unless File.exist?(staging) || File.symlink?(staging)
      secure_directory(staging)
      entries = Dir.children(staging)
      raise Refused, "import.recovery" unless (entries - %w[bundle registration.json]).empty?
      entries.each { |name| RunEvidenceStore.bytes(File.join(staging, name), root: @root, private: true) }
      entries.each { |name| File.unlink(File.join(staging, name)) }
      Dir.rmdir(staging)
    end

    # Writes bounded private bytes exclusively and syncs before publication.
    # Disk-full, interrupted or short writes fail without reporting success.
    def durable_file(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        raise Refused, "import.short_write" unless file.binmode.write(bytes) == bytes.bytesize
        file.flush
        file.fsync
      end
    end

    # Checks both the open source and its pathname after copying. Hardlinks,
    # aliases, in-place edits, replacement and deletion refuse before publication.
    def check_source(file, original, path)
      current = File.lstat(path)
      raise Refused, "import.source_changed" unless File.realpath(path) == path &&
        %i[dev ino uid nlink size mtime ctime].all? { |field| [file.stat, current].all? { |stat| stat.public_send(field) == original.public_send(field) } }
    end

    # Checks the classic single-disk ZIP envelope and central directory bounds.
    # ZIP64, split archives, prefixes and trailing bytes are unsupported. No
    # member decoding, secret detection, CRC assurance or extraction is promised.
    def zip?(bytes)
      ending = bytes.rindex("PK\x05\x06".b)
      while ending && bytes.bytesize - ending <= 65_557
        break if bytes.bytesize - ending >= 22 && ending + 22 + bytes.byteslice(ending + 20, 2).unpack1("v") == bytes.bytesize
        return false if ending.zero?
        ending = bytes.rindex("PK\x05\x06".b, ending - 1)
      end
      return false unless ending && bytes.bytesize - ending >= 22
      disk, directory_disk, disk_entries, count, size, offset, comment = bytes.byteslice(ending + 4, 18).unpack("v4V2v")
      return false unless disk.zero? && directory_disk.zero? && disk_entries == count && count < 65_535 &&
        ending + 22 + comment == bytes.bytesize && offset + size == ending
      return ending.zero? && size.zero? && offset.zero? if count.zero?
      return false unless bytes.start_with?("PK\x03\x04".b)
      cursor = offset
      count.times do
        return false unless cursor + 46 <= ending && bytes.byteslice(cursor, 4) == "PK\x01\x02".b
        name, extra, note, start_disk = bytes.byteslice(cursor + 28, 8).unpack("v4")
        local = bytes.byteslice(cursor + 42, 4).unpack1("V")
        return false unless start_disk.zero? && local + 30 <= offset && bytes.byteslice(local, 4) == "PK\x03\x04".b
        cursor += 46 + name + extra + note
      end
      cursor == ending
    end
  end
end
