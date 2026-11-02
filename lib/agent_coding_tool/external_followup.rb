# frozen_string_literal: true

require "fileutils"
require "securerandom"
require_relative "gate_capture"
require_relative "run_evidence_reader"

module AgentCodingTool
  # Captures one explicitly requested codex exec and publishes host-copied bytes
  # as immutable, task-scoped evidence. This never creates ACT launch records.
  class ExternalFollowup
    Refused = RunEvidenceReader::Refused
    STREAMS = { "stdout" => "transcript", "stderr" => "stderr", "final" => "final" }.freeze
    MAX_REGISTRATIONS = 64
    EXTERNAL_BINDING = %w[task_id source invocation_id].freeze

    # Resolves the existing private data root without creating evidence.
    def initialize(data_root)
      @data = File.realpath(data_root)
      @root = "#{@data}-followups"
      @writer_pid = nil
      @needs_recovery = false
      raise Refused, "followup.root" if File.exist?(@root) && File.realpath(@root) != @root
    rescue SystemCallError
      raise Refused, "followup.root", cause: nil
    end

    # Runs one codex exec under a local host-owned lock and preserves its output,
    # final message and actual exit/signal when available. Returns child status.
    def capture(task, command, out:, err:)
      validate_task(task)
      raise Refused, "followup.command" unless command.is_a?(Array) && command.length >= 2 &&
        command.first == "codex" && command[1] == "exec" &&
        command.none? { |argument| argument == "--output-last-message" || argument.start_with?("--output-last-message=", "-o") }
      codex, executable = resolve_codex
      task_root = create_private(File.join(@root, "captures", task))
      raise Refused, "followup.limit" if children(task_root).length >= MAX_REGISTRATIONS
      id = SecureRandom.hex(16)
      directory = create_private(File.join(task_root, id))
      lock_path = File.join(directory, "capture.lock")
      result = File.open(lock_path, File::RDWR | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |lock|
        raise Refused, "followup.lock" unless lock.stat.file? && lock.stat.uid == Process.uid && lock.flock(File::LOCK_EX | File::LOCK_NB)
        started = { "schema" => "agent-coding-tool-external-codex-capture/v1", "task_id" => task,
          "invocation_id" => "external-#{id}", "status" => "pending", "outcome" => "unknown",
          "exit_status" => nil, "signal" => nil, "executable" => executable, "started_at" => Time.now.utc.iso8601(6) }
        durable_json(File.join(directory, "capture.json"), started, exclusive: true)
        receipt_sha = Digest::SHA256.hexdigest(JSON.generate(started))
        File.binwrite(File.join(directory, "capture.sha256"), receipt_sha, mode: "wx", perm: 0o600)
        out.puts JSON.generate("task_id" => task, "source" => "external_codex_cli", "invocation_id" => "external-#{id}",
          "capture_status" => "pending", "outcome" => "unknown", "receipt_sha256" => receipt_sha)
        out.flush
        final_path = File.join(directory, "final")
        argv = [codex, "exec", "--json", "--output-last-message", final_path, *command.drop(2)]
        capture = GateCapture.new(directory, "external", out: err, err: err)
        begin
          child_status = capture.run { |pipes| run_process(argv, pipes) }
          status = child_status
          outcome = status&.signaled? ? "signaled" : status ? "exited" : "start_failed"
          exit_status, signal = status&.exitstatus, status&.termsig
        rescue Interrupt
          outcome, exit_status, signal = "unknown", nil, nil
        rescue SystemCallError => error
          outcome, exit_status, signal = "start_failed", nil, nil
          @start_error = error.class.name
        end
        if outcome == "unknown" && @writer_pid
          record = started.merge("status" => "pending", "outcome" => "unknown", "exit_status" => nil,
            "signal" => nil, "writer_pid" => @writer_pid)
          durable_replace(File.join(directory, "capture.json"), record)
          receipt_sha = Digest::SHA256.hexdigest(JSON.generate(record))
          @receipt_sha = receipt_sha
          @needs_recovery = true
          out.puts JSON.generate("task_id" => task, "source" => "external_codex_cli", "invocation_id" => "external-#{id}",
            "capture_status" => "pending", "outcome" => "unknown", "receipt_sha256" => receipt_sha)
          next nil
        end
        pin_output(final_path) if File.exist?(final_path) || File.symlink?(final_path)
        files = capture_files(directory, final_path, capture.result, outcome)
        raise Refused, "followup.executable_changed" unless executable == executable_facts(codex)
        record = started.merge("status" => files.values.all? { |entry| entry["status"] == "complete" } ? "complete" : "incomplete",
          "outcome" => outcome, "exit_status" => exit_status, "signal" => signal,
          "start_error" => @start_error, "finished_at" => Time.now.utc.iso8601(6), "files" => files)
        durable_replace(File.join(directory, "capture.json"), record)
        receipt_sha = Digest::SHA256.hexdigest(JSON.generate(record))
        @receipt_sha = receipt_sha
        out.puts JSON.generate("task_id" => task, "source" => "external_codex_cli", "invocation_id" => "external-#{id}",
          "capture_status" => record["status"], "outcome" => outcome, "exit_status" => exit_status, "signal" => signal,
          "receipt_sha256" => receipt_sha)
        child_status
      ensure
        lock.flock(File::LOCK_UN) if lock
      end
      register(task, "external-#{id}", @receipt_sha) unless @needs_recovery
      result
    rescue Refused
      raise
    rescue SystemCallError, IOError
      raise Refused, "followup.capture", cause: nil
    ensure
      @start_error = nil
      @writer_pid = nil
      @needs_recovery = false
    end

    # Recovers and publishes one explicit capture. A supplied digest pins the
    # finished receipt; a matching started receipt permits pending-byte recovery.
    def register(task, invocation, expected_sha)
      validate_task(task)
      raise Refused, "followup.identity" unless invocation.is_a?(String) && invocation.match?(/\Aexternal-[0-9a-f]{32}\z/) &&
        expected_sha.is_a?(String) && expected_sha.match?(/\A[0-9a-f]{64}\z/)
      source = File.join(@root, "captures", task, invocation.delete_prefix("external-"))
      record = nil
      secure_directory(source)
      File.open(File.join(source, "capture.lock"), File::RDONLY | File::NOFOLLOW) do |capture_lock|
        raise Refused, "followup.active" unless capture_lock.stat.file? && capture_lock.stat.uid == Process.uid &&
          capture_lock.flock(File::LOCK_EX | File::LOCK_NB)
        record_path = File.join(source, "capture.json")
        raw = RunEvidenceStore.bytes(record_path, root: source, private: true)
        record = RunEvidenceStore.parse(raw)
        unless Digest::SHA256.hexdigest(raw) == expected_sha
          started_digest = RunEvidenceStore.bytes(File.join(source, "capture.sha256"), root: source, private: true)
          raise Refused, "followup.digest" unless record["status"] == "pending" && started_digest == expected_sha
        end
      raise Refused, "followup.binding" unless record["schema"] == "agent-coding-tool-external-codex-capture/v1" &&
          record["task_id"] == task && record["invocation_id"] == invocation
        verify_writer_stopped!(record["writer_pid"]) if record["writer_pid"]
        record = recover_pending(source, record) if record["status"] == "pending"
      end
      lock(File.join(@root, "registration.lock")) do
        task_root = create_private(File.join(@root, "registrations", task))
        entries = children(task_root)
        raise Refused, "followup.limit" if entries.length >= MAX_REGISTRATIONS
        raise Refused, "followup.duplicate" if entries.include?(invocation)
        registration = publish(task_root, source, record, invocation, expected_sha)
        registration
      end
    rescue KeyError, TypeError, JSON::ParserError, SystemCallError, IOError
      raise Refused, "followup.registration", cause: nil
    end

    # Discovers only published immutable registrations for one registered task.
    def discover(task)
      validate_task(task)
      task_root = File.join(@root, "registrations", task)
      return [] unless File.exist?(task_root) || File.symlink?(task_root)
      children(task_root).map do |invocation|
        raise Refused, "followup.identity" unless invocation.match?(/\Aexternal-[0-9a-f]{32}\z/)
        record_path = File.join(task_root, invocation, "registration.json")
        record = RunEvidenceStore.parse(RunEvidenceStore.bytes(record_path, root: task_root))
        identity = { "task_id" => task, "source" => "external_codex_cli", "invocation_id" => invocation }
        self.class.validate_record(record, identity)
        identity.merge("evidence_source" => "external_codex_cli", "status" => record.fetch("status"),
          "outcome" => record.fetch("outcome"), "exit_status" => record["exit_status"], "signal" => record["signal"])
      end
    end

    # Selects one exact published registration and approves its copied bytes.
    def select(identity, artifacts:, manager:)
      task, invocation = identity.values_at("task_id", "invocation_id")
      raise Refused, "followup.identity" unless identity.keys.sort == EXTERNAL_BINDING.sort &&
        task.is_a?(String) && task.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) &&
        identity["source"] == "external_codex_cli" && invocation.is_a?(String) && invocation.match?(/\Aexternal-[0-9a-f]{32}\z/)
      directory = File.join(@root, "registrations", task, invocation)
      secure_directory(directory)
      path = File.join(directory, "registration.json")
      raw = RunEvidenceStore.bytes(path, root: directory, private: true)
      record = RunEvidenceStore.parse(raw)
      self.class.validate_record(record, identity)
      approvals = artifacts.to_h do |name|
        spec = record.fetch("files")[name]
        [name, spec ? spec.merge("path" => File.join(directory, name)) : { "status" => "missing" }]
      end
      config = { "run_dir" => directory, "checkpoint_dir" => directory,
        "handoff_sha256" => Digest::SHA256.hexdigest(raw), "binding" => identity,
        "approvals" => approvals, "manager" => manager, "paged" => true }
      reader = RunEvidenceReader.new(**config.transform_keys(&:to_sym))
      approvals.each { |name, spec| reader.send(:artifact!, name, record) unless spec["status"] == "missing" }
      config
    end

    # Validates a closed published record before discovery or every read.
    def self.validate_record(record, identity)
      raise Refused, "followup.record" unless record.is_a?(Hash) &&
        record.keys.sort == %w[schema task_id source invocation_id status outcome exit_status signal executable files assurance].sort &&
        record.values_at("schema", "task_id", "source", "invocation_id") ==
          ["agent-coding-tool-external-followup/v1", identity["task_id"], "external_codex_cli", identity["invocation_id"]] &&
        record["invocation_id"].is_a?(String) && record["invocation_id"].match?(/\Aexternal-[0-9a-f]{32}\z/) &&
        %w[complete incomplete].include?(record["status"]) && %w[exited signaled start_failed unknown].include?(record["outcome"]) &&
        (record["exit_status"].nil? || record["exit_status"].is_a?(Integer) && record["exit_status"].between?(0, 255)) &&
        (record["signal"].nil? || record["signal"].is_a?(Integer) && record["signal"].between?(1, 127)) &&
        record["assurance"] == "external Codex CLI capture; evidence only, not ACT launch or validation" &&
        record["executable"].is_a?(Hash) && record["executable"].keys.sort == %w[device inode modified_ns size uid].sort &&
        record["executable"].values.all? { |value| value.is_a?(Integer) && value >= 0 } &&
        record["files"].is_a?(Hash) && (record["files"].keys - %w[final transcript stderr]).empty? &&
        record["files"].all? { |name, spec| %w[final transcript stderr].include?(name) && spec.is_a?(Hash) &&
          spec.keys.sort == %w[bytes sha256 status].sort && %w[complete pending truncated missing].include?(spec["status"]) &&
          spec["bytes"].is_a?(Integer) && spec["bytes"].between?(0, RunEvidenceReader::MAX_FILE) &&
          spec["sha256"].is_a?(String) && spec["sha256"].match?(/\A[0-9a-f]{64}\z/) }
      true
    end

    private

    # Invokes only the explicit argv vector; no shell parses command text.
    def run_process(argv, pipes)
      @writer_pid = Process.spawn(*argv, **pipes, pgroup: true)
      _, status = Process.wait2(@writer_pid)
      @writer_pid = nil
      status
    end

    # Refuses recovery until a recorded child process group is positively absent.
    # A live, reused or unobservable group stays blocked rather than risking a writer race.
    def verify_writer_stopped!(pid)
      raise Refused, "followup.writer_unknown" unless pid.is_a?(Integer) && pid.positive?
      Process.kill(0, -pid)
      raise Refused, "followup.writer_active"
    rescue Errno::ESRCH
      true
    rescue Errno::EPERM, SystemCallError
      raise Refused, "followup.writer_unknown", cause: nil
    end

    # Checks the exact registered task definition before capture or registration.
    def validate_task(task)
      RunEvidenceStore.task_context(@data, task)
    end

    # Resolves the actual codex executable through the host PATH and pins stable
    # filesystem identity facts without trusting an argv-supplied filename.
    def resolve_codex
      path = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
        candidate = File.join(directory, "codex")
        candidate if File.file?(candidate) && File.executable?(candidate)
      end.first
      raise Refused, "followup.codex_missing" unless path
      canonical = File.realpath(path)
      [canonical, executable_facts(canonical)]
    rescue SystemCallError
      raise Refused, "followup.codex_unavailable", cause: nil
    end

    # Returns finite executable identity fields; callers never supply these.
    def executable_facts(path)
      stat = File.stat(path)
      raise Refused, "followup.codex_type" unless stat.file? && stat.executable? && stat.uid == Process.uid
      { "device" => stat.dev, "inode" => stat.ino, "size" => stat.size,
        "modified_ns" => (stat.mtime.to_r * 1_000_000_000).to_i, "uid" => stat.uid }
    end

    # Creates one owned private directory and rechecks its canonical identity.
    def create_private(path)
      raise Refused, "followup.path" unless path == @root || path.start_with?("#{@root}/")
      Dir.mkdir(@root, 0o700) unless File.exist?(@root)
      secure_directory(@root)
      current = @root
      components = path == @root ? [] : path.delete_prefix("#{@root}/").split("/")
      components.each do |component|
        raise Refused, "followup.path" unless component.match?(/\A[A-Za-z0-9_-]+\z/)
        current = File.join(current, component)
        Dir.mkdir(current, 0o700) unless File.exist?(current)
        secure_directory(current)
      end
      secure_directory(path)
      path
    end

    # Rejects symlinked, foreign or broadly accessible path components.
    def secure_directory(path)
      raise Refused, "followup.path" unless (path == @root || path.start_with?("#{@root}/")) &&
        File.directory?(path) && File.realpath(path) == path
      cursor = path
      while cursor.start_with?(@root)
        stat = File.lstat(cursor)
        raise Refused, "followup.ownership" unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        cursor = File.dirname(cursor)
      end
      true
    end

    # Returns validated immediate child directory names, refusing foreign entries.
    def children(path)
      secure_directory(path)
      entries = Dir.children(path).sort
      raise Refused, "followup.inventory" if entries.length > MAX_REGISTRATIONS || entries.any? do |entry|
        child = File.join(path, entry)
        !entry.match?(/\A[A-Za-z0-9_-]+\z/) || !File.directory?(child) || File.symlink?(child) || !secure_directory(child)
      end
      entries
    end

    # Serializes registrations with a private owner lock.
    def lock(path)
      create_private(@root)
      File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |file|
        raise Refused, "followup.lock" unless file.stat.file? && file.stat.uid == Process.uid && (file.stat.mode & 0o077).zero? &&
          file.flock(File::LOCK_EX | File::LOCK_NB)
        yield
      end
    end

    # Captures bounded binary streams and stable final output with hashes.
    def capture_files(directory, final_path, capture, outcome)
      files = {}
      STREAMS.each do |stream, name|
        if stream == "final"
          files[name] = file_spec(final_path, outcome == "exited" ? "complete" : "pending")
        else
          spec = capture.fetch("streams").fetch(stream)
          status = { "complete" => "complete", "truncated" => "truncated", "incomplete" => "pending" }.fetch(spec["status"], "missing")
          files[name] = { "status" => status, "bytes" => status == "missing" ? 0 : spec["bytes"],
            "sha256" => status == "missing" ? Digest::SHA256.hexdigest("".b) : spec.fetch("sha256") }
        end
      end
      files
    end

    # Snapshots only the three fixed output paths after an interrupted capture.
    # Every recovered byte remains pending and the child outcome remains unknown.
    def recover_pending(source, record)
      names = { "final" => "final", "transcript" => "gate-external.stdout", "stderr" => "gate-external.stderr" }
      files = names.to_h do |kind, filename|
        path = File.join(source, filename)
        if kind == "final" && (File.exist?(path) || File.symlink?(path))
          [kind, file_spec(path, "pending")]
        elsif File.exist?(path) || File.symlink?(path)
          bytes = RunEvidenceStore.bytes(path, root: source, private: true)
          [kind, { "status" => "pending", "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes) }]
        else
          [kind, { "status" => "missing", "bytes" => 0, "sha256" => Digest::SHA256.hexdigest("".b) }]
        end
      end
      record.merge("status" => "incomplete", "outcome" => "unknown", "exit_status" => nil, "signal" => nil, "files" => files)
    end

    # Hashes a bounded output file and retains its prefix when it exceeds the reader limit.
    def file_spec(path, status)
      raise Refused, "followup.output_symlink" if File.symlink?(path)
      stat = File.lstat(path)
      raise Refused, "followup.output_type" unless stat.file? && stat.uid == Process.uid
      if stat.size > RunEvidenceReader::MAX_FILE
        File.open(path, File::WRONLY | File::NOFOLLOW) do |file|
          raise Refused, "followup.output_changed" unless file.stat.dev == stat.dev && file.stat.ino == stat.ino
          file.truncate(RunEvidenceReader::MAX_FILE)
          file.flush
          file.fsync
        end
        status = "truncated"
      end
      bytes = RunEvidenceStore.bytes(path, root: File.dirname(path), private: true)
      { "status" => status, "bytes" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes) }
    rescue Errno::ENOENT
      { "status" => "missing", "bytes" => 0, "sha256" => Digest::SHA256.hexdigest("".b) }
    end

    # Tightens the Codex-created last-message file inside its already private
    # capture directory and verifies the pathname still names the opened inode.
    def pin_output(path)
      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        stat = file.stat
        raise Refused, "followup.output_type" unless stat.file? && stat.uid == Process.uid
        file.chmod(0o600)
        current = File.lstat(path)
        raise Refused, "followup.output_changed" unless current.file? && current.uid == stat.uid &&
          current.dev == stat.dev && current.ino == stat.ino && (current.mode & 0o077).zero?
      end
    rescue SystemCallError
      raise Refused, "followup.output_unavailable", cause: nil
    end

    # Copies exactly three named captures into a hidden staging directory, then
    # atomically publishes the complete immutable registration.
    def publish(task_root, source, capture, invocation, expected_sha)
      stage = File.join(task_root, ".#{invocation}.#{SecureRandom.hex(8)}.tmp")
      Dir.mkdir(stage, 0o700)
      files = capture.fetch("files", {}).slice("final", "transcript", "stderr").to_h do |name, spec|
        source_name = { "final" => "final", "transcript" => "gate-external.stdout", "stderr" => "gate-external.stderr" }.fetch(name)
        next [name, spec] if spec["status"] == "missing"
        bytes = RunEvidenceStore.bytes(File.join(source, source_name), root: source, private: true)
        raise Refused, "followup.stale" unless Digest::SHA256.hexdigest(bytes) == spec["sha256"] && bytes.bytesize == spec["bytes"]
        File.open(File.join(stage, name), File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
          file.binmode.write(bytes); file.flush; file.fsync
        end
        [name, spec]
      end
      status = capture["status"] == "pending" ? "incomplete" : capture.fetch("status")
      registration = { "schema" => "agent-coding-tool-external-followup/v1", "task_id" => capture.fetch("task_id"),
        "source" => "external_codex_cli", "invocation_id" => invocation, "status" => status,
        "outcome" => capture.fetch("outcome"), "exit_status" => capture["exit_status"], "signal" => capture["signal"],
        "executable" => capture.fetch("executable"), "files" => files,
        "assurance" => "external Codex CLI capture; evidence only, not ACT launch or validation" }
      self.class.validate_record(registration, registration.slice(*EXTERNAL_BINDING))
      durable_json(File.join(stage, "registration.json"), registration, exclusive: true)
      raise Refused, "followup.digest" unless Digest::SHA256.hexdigest(RunEvidenceStore.bytes(File.join(source, "capture.json"), root: source, private: true)) == expected_sha ||
        File.binread(File.join(source, "capture.sha256")) == expected_sha
      secure_directory(stage)
      File.rename(stage, File.join(task_root, invocation))
      File.open(task_root, File::RDONLY, &:fsync)
      registration
    ensure
      FileUtils.remove_entry(stage) if stage && File.exist?(stage)
    end

    # Atomically writes a private JSON record and syncs its containing directory.
    def durable_json(path, value, exclusive: false)
      flags = File::WRONLY | File::CREAT | File::NOFOLLOW | (exclusive ? File::EXCL : 0)
      File.open(path, flags, 0o600) { |file| file.write(JSON.generate(value)); file.flush; file.fsync }
      File.open(File.dirname(path), File::RDONLY, &:fsync)
    end

    # Replaces the started capture receipt only after the child has been reaped.
    def durable_replace(path, value)
      temporary = "#{path}.tmp"
      durable_json(temporary, value, exclusive: true)
      File.rename(temporary, path)
      File.open(File.dirname(path), File::RDONLY, &:fsync)
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary)
    end
  end
end
