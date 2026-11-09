# frozen_string_literal: true

require_relative "run_evidence_reader"
require_relative "external_followup"
require_relative "imported_evidence"

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
        raise Refused, "source.type_or_size" unless stat.file? && stat.uid == Process.uid && stat.size <= RunEvidenceReader::MAX_FILE &&
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
      @data = File.realpath(data_root)
      @root = "#{@data}-runs"
      raise Refused, "source.root" if File.exist?(@root) && File.realpath(@root) != @root
    rescue SystemCallError
      raise Refused, "source.root", cause: nil
    end

    # Resolves all four exact identities to one authoritative handoff and builds
    # immutable file approvals. Returns reader constructor arguments. Ambiguity,
    # missing provenance, unsafe paths or mismatched source bytes refuse.
    def select(identity, artifacts:, manager:, shared: false)
      if identity.key?("artifact")
        raise Refused, "selection.source" unless shared
        return ImportedEvidence.new(@data).select(identity, manager: manager)
      end
      if identity["source"] == "external_codex_cli"
        raise Refused, "selection.source" unless shared
        task_root = File.join(@root, identity.fetch("task_id"))
        managed_match = File.exist?(task_root) && children(task_root).any? do |entry|
          report = self.class.parse(self.class.bytes(File.join(task_root, entry, "handoff.json"), root: @root))
          report["task_id"] == identity["task_id"] && report["invocation_id"] == identity["invocation_id"]
        end
        raise Refused, "selection.missing_or_ambiguous" if managed_match
        return ExternalFollowup.new(@data).select(identity, artifacts: artifacts, manager: manager)
      end
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
      if report["writable_repositories"] == []
        binding = identity.merge("workspace" => report.fetch("workspace"), "repository" => nil,
          "read_only_inputs" => report.fetch("preparation"))
      else
        binding = identity.merge("workspace" => report.fetch("workspace"), "repository" => report.fetch("writable_repository"),
          "base_sha" => report.fetch("writable_authority").fetch("pushed_sha"),
          "remote_url" => report.fetch("writable_authority").fetch("remote_url"),
          "branch" => report.fetch("writable_authority").fetch("branch"))
      end
      approvals = artifacts.to_h { |name| [name, { "status" => "missing" }] }
      run_dir = File.dirname(path)
      { "final" => "final_path", "transcript" => "jsonl_path", "stderr" => "stderr_path" }.each do |name, field|
        next unless artifacts.include?(name)
        source = report.fetch(field)
        next unless File.exist?(source) || File.symlink?(source)
        status = %w[exited invalid_final interrupted child_start_failed preflight_failed preflight_abandoned].include?(report["status"]) ? "complete" : "pending"
        approvals[name] = if shared && name == "transcript"
          streamed = RunEvidenceReader.transcript(source, run_dir, session_id: binding.fetch("session_id"))
          streamed.delete("data")
          streamed["status"] == "missing" ? streamed : streamed.merge("path" => source, "status" => status, "streamed" => true)
        else
          approval(source, run_dir, status)
        end
      end
      if shared
        { "prompt" => "prompt_path", "launch_input" => "stdin_path" }.each do |name, field|
          next unless report[field]
          approvals[name] = File.exist?(report[field]) || File.symlink?(report[field]) ? approval(report[field], run_dir) : { "status" => "missing" }
        end
      end
      checkpoint_dir = checkpoint(report, binding, artifacts, approvals, shared: shared)
      registrations(run_dir, report, binding, approvals) if shared && report["writable_repositories"] != []
      config = { "run_dir" => run_dir, "checkpoint_dir" => checkpoint_dir,
        "handoff_sha256" => Digest::SHA256.hexdigest(raw), "binding" => binding,
        "approvals" => approvals, "manager" => manager }
      config["paged"] = true if shared
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

    # Reads only the registered task and its allowlisted preparation facts. No
    # environment/configuration, other task, lifecycle edit or execution occurs.
    # Returns hashed bounded context; malformed/foreign task data refuses.
    def self.task_context(data, task)
      raise Refused, "selection.task" unless task.is_a?(String) && task.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      raw = bytes(File.join(data, "tasks", "#{task}.yml"), root: data)
      definition = YAML.safe_load(raw, aliases: false)
      raise Refused, "selection.task" unless definition.is_a?(Hash) && definition["id"] == task
      definition = definition.slice("id", "title", "depends_on", "goal", "constraints", "acceptance", "repositories", "checkpoint")
      state_path = File.join(data, "state", "#{task}.yml")
      state = File.exist?(state_path) ? YAML.safe_load(bytes(state_path, root: data), aliases: false) : {}
      context = { "task" => definition, "preparation" => (state || {}).slice("prepared_at", "snapshot", "coding_skill", "planning_skill") }
      raise Refused, "selection.context_size" if JSON.generate(context).bytesize > 24_576
      context.merge("revision" => Digest::SHA256.hexdigest(JSON.generate(context)))
    rescue Psych::Exception, TypeError, NoMethodError
      raise Refused, "selection.context", cause: nil
    end

    # Discovers exact managed attempts for one approved task. New evidence is
    # visible only on an explicit discovery/refresh; no newest-run alias exists.
    # Starting before any run is valid and returns an empty run inventory.
    def discover(task, offset: 0)
      raise Refused, "selection.offset" unless offset.is_a?(Integer) && offset.between?(0, 1024)
      context = self.class.task_context(@data, task)
      task_root = File.join(@root, task)
      entries = !File.exist?(task_root) ? [] : children(task_root)
      external = ExternalFollowup.new(@data).discover(task) + ImportedEvidence.new(@data).discover(task)
      total = entries.length + external.length
      raise Refused, "selection.offset" if offset > total
      runs = entries.map do |entry|
        report = self.class.parse(self.class.bytes(File.join(task_root, entry, "handoff.json"), root: @root))
        identity = report.slice(*RunEvidenceReader::IDENTITIES)
        raise Refused, "selection.foreign" unless report["task_id"] == task && report["schema_version"] == "agent-coding-tool-run/v1" &&
          identity["attempt"].is_a?(Integer) && identity["attempt"].positive? &&
          %w[invocation_id session_id].all? { |key| report[key].nil? || report[key].is_a?(String) && report[key].match?(/\A[A-Za-z0-9_-]{1,128}\z/) }
        identity.merge("evidence_source" => "act_managed", "status" => identity["session_id"] ? "available" : "pending")
      end
      runs = (runs + external).slice(offset, 16)
      { "task_id" => task, "context" => context, "runs" => runs,
        "next_offset" => offset + runs.length < total ? offset + runs.length : nil }
    end

    # Host-owned import of one explicit worker package from the launch-recorded
    # fixture. Hashes, owner, regular files, containment and exact launch/base are
    # checked before publication; claims do not become checkpoint verification.
    # Copies only three named artifacts, never recursively scans worker storage.
    def register(identity, package_path, digest)
      config = select(identity, artifacts: %w[final], manager: "host-registration")
      run = config.fetch("run_dir")
      report = self.class.parse(self.class.bytes(File.join(run, "handoff.json"), root: run))
      fixture = report.fetch("fixture")
      root = fixture.fetch("path")
      stat = File.lstat(root)
      raise Refused, "registration.fixture" unless stat.directory? && File.realpath(root) == root && stat.uid == Process.uid &&
        (stat.mode & 0o077).zero? && stat.dev == fixture.fetch("device") && stat.ino == fixture.fetch("inode") &&
        fixture.fetch("uid") == Process.uid && File.dirname(package_path) == root
      raw = self.class.bytes(package_path, root: root)
      raise Refused, "registration.digest" unless Digest::SHA256.hexdigest(raw) == digest
      package = self.class.parse(raw)
      binding = config.fetch("binding")
      raise Refused, "registration.binding" unless package.keys.sort == %w[schema task_id workspace repository base_sha files].sort &&
        package["schema"] == "agent-coding-tool-worker-evidence/v1" &&
        %w[task_id workspace repository base_sha].all? { |key| package[key] == binding[key] }
      specs = package.fetch("files")
      raise Refused, "registration.files" unless specs.is_a?(Hash) && (specs.keys - %w[candidate apply focused]).empty? &&
        %w[candidate apply].all? { |kind| specs.key?(kind) }
      files = specs.to_h do |kind, spec|
        filename = spec.fetch("file")
        raise Refused, "registration.path" unless filename.is_a?(String) && filename.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\z/) &&
          !filename.end_with?(".env") && spec.keys.sort == %w[file sha256 bytes].sort
        bytes = self.class.bytes(File.join(root, filename), root: root)
        raise Refused, "registration.digest" unless Digest::SHA256.hexdigest(bytes) == spec["sha256"] && bytes.bytesize == spec["bytes"]
        [kind, bytes]
      end
      apply = self.class.parse(files.fetch("apply"))
      raise Refused, "registration.apply" unless apply["schema"] == ApplyHandoff::SCHEMA && apply["target"] == binding["repository"] &&
        apply.dig("patch", "sha256") == specs.dig("candidate", "sha256") &&
        apply.dig("repositories", binding["repository"], "baseline") == binding["base_sha"] &&
        apply.dig("repositories", binding["repository"], "remote_url") == binding["remote_url"]
      lock_path = File.join(run, "registration.lock")
      File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        raise Refused, "registration.busy" unless lock.stat.file? && lock.stat.uid == Process.uid && lock.flock(File::LOCK_EX | File::LOCK_NB)
        raise Refused, "registration.limit" if Dir.children(run).grep(/\Aregistration-[0-9a-f]{32}\.json\z/).length >= 16
        token = SecureRandom.hex(16)
        retained = files.to_h do |kind, bytes|
          name = "worker-#{token}-#{kind}"
          File.open(File.join(run, name), File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
            file.binmode.write(bytes)
            file.flush
            file.fsync
          end
          [kind, specs.fetch(kind).merge("file" => name)]
        end
        publication = { "binding" => identity, "workspace" => binding["workspace"], "base_sha" => binding["base_sha"],
          "package_sha256" => digest, "files" => retained, "assurance" => "host copied worker claims; not checkpoint verification or acceptance" }
        path = File.join(run, ".registration-#{token}.tmp")
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
          file.write(JSON.generate(publication)); file.flush; file.fsync
        end
        File.rename(path, File.join(run, "registration-#{token}.json"))
        File.open(run, File::RDONLY, &:fsync)
        publication
      end
    rescue KeyError, TypeError, NoMethodError, JSON::ParserError, SystemCallError
      raise Refused, "registration.invalid", cause: nil
    end

    private

    # Admits only completely published registration manifests for this exact
    # run, then pins copied worker bytes. Partial files remain undiscoverable.
    # A later registration cannot replace any prior manifest or selected bytes.
    def registrations(run, report, binding, approvals)
      entries = Dir.children(run).grep(/\Aregistration-[0-9a-f]{32}\.json\z/).sort
      raise Refused, "registration.limit" if entries.length > 16
      entries.each do |name|
        record = self.class.parse(self.class.bytes(File.join(run, name), root: run))
        raise Refused, "registration.binding" unless record["binding"] == binding.slice(*RunEvidenceReader::IDENTITIES) &&
          record["workspace"] == binding["workspace"] && record["base_sha"] == binding["base_sha"]
        record.fetch("files").each do |kind, spec|
          token = name.delete_prefix("registration-").delete_suffix(".json")
          raise Refused, "registration.path" unless %w[candidate apply focused].include?(kind) && spec["file"] == "worker-#{token}-#{kind}"
          pinned = approval(File.join(run, spec.fetch("file")), run)
          raise Refused, "registration.digest" unless pinned.values_at("sha256", "bytes") == spec.values_at("sha256", "bytes")
          approvals["worker:#{token}:#{kind}"] = pinned.merge("registration" => name,
            "registration_sha256" => Digest::SHA256.file(File.join(run, name)).hexdigest)
        end
      end
    end

    # Returns bounded run/checkpoint directories, ignoring only regular Finder
    # metadata files. Symlinks, other file types and unknown entries refuse.
    def children(path)
      raise Refused, "source.directory" unless File.directory?(path) && !File.symlink?(path) && File.realpath(path) == path
      entries = IncidentalMetadata.children(path).sort
      raise Refused, "source.inventory" unless entries.length <= 1024
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

    # Pins launch-bound checkpoint history and exact gate/candidate links. Shared
    # readers follow only published previous_record links, never filename guesses.
    # Missing history is normal; cycles, ambiguous directories or corrupt links refuse.
    def checkpoint(report, binding, artifacts, approvals, shared: false)
      return @root if report["writable_repositories"] == []
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
        history = []
        loop do
          raise Refused, "checkpoint.history" if history.length >= 64 || history.any? { |prior, _| prior["path"] == spec["path"] }
          record = self.class.parse(self.class.bytes(spec.fetch("path"), root: @root))
          history << [spec, record]
          previous = shared && record["previous_record"]
          break unless previous
          raise Refused, "checkpoint.path" unless previous.is_a?(String) && previous.match?(/\A[0-9a-f-]+\.json\z/)
          spec = approval(File.join(directory, previous), @root)
        end
        history.select! { |_, record| record["launch_invocation"] == binding["invocation_id"] }
        [directory, history] unless history.empty?
      end
      raise Refused, "checkpoint.ambiguous" if matches.length > 1
      return @root if matches.empty?
      directory, history = matches.first
      spec, record = history.first
      binding["checkpoint_attempt"] = record.fetch("attempt")
      # A's reader requires the checkpoint link internally for candidate/gates.
      approvals["checkpoint"] = spec if (artifacts & %w[checkpoint candidate validation]).any?
      if artifacts.include?("candidate")
        filename = record.fetch("artifact")
        raise Refused, "checkpoint.path" unless filename.is_a?(String) && filename.match?(/\A[0-9a-f-]+\.patch\z/)
        approvals["candidate"] = approval(File.join(directory, filename), directory)
      end
      if shared
        history.each do |checkpoint_spec, checkpoint_record|
          checkpoint_name = "checkpoint:#{File.basename(checkpoint_spec.fetch('path'))}"
          approvals[checkpoint_name] = checkpoint_spec
          next unless artifacts.include?("candidate")
          filename = checkpoint_record.fetch("artifact")
          raise Refused, "checkpoint.path" unless filename.is_a?(String) && filename.match?(/\A[0-9a-f-]+\.patch\z/)
          approvals["candidate:#{filename}"] = approval(File.join(directory, filename), directory).merge("checkpoint" => checkpoint_name)
        end
      end
      if artifacts.include?("validation")
        receipts = Dir.children(directory).grep(/\Agate-[0-9a-f-]+\.finished\.json\z/).sort
        if shared
          receipts += Dir.children(directory).grep(/\Agate-[0-9a-f-]+\.command\.json\z/).reject do |filename|
            File.exist?(File.join(directory, filename.sub(".command.", ".finished.")))
          end.sort
          receipts += Dir.children(directory).grep(/\Agate-[0-9a-f-]+\.started\.json\z/).reject do |filename|
            %w[finished command].any? { |phase| File.exist?(File.join(directory, filename.sub(".started.", ".#{phase}."))) }
          end.sort
        end
        raise Refused, "checkpoint.receipts" if receipts.length > 64
        receipts.each do |filename|
          source = File.join(directory, filename)
          receipt = self.class.parse(self.class.bytes(source, root: directory))
          next unless receipt.dig("candidate", "launch_invocation") == binding["invocation_id"]
          checkpoint_name = "checkpoint"
          if shared
            linked = history.find { |checkpoint_spec, _| File.basename(checkpoint_spec.fetch("path")) == receipt.dig("candidate", "record_file") }
            raise Refused, "checkpoint.receipt_binding" unless linked &&
              %w[sha256 artifact launch_invocation].all? { |key| receipt.dig("candidate", key) == linked.last[key] }
            checkpoint_name = "checkpoint:#{File.basename(linked.first.fetch('path'))}"
          else
            next unless receipt.dig("candidate", "sha256") == record["sha256"]
          end
          pending = receipt["receipt_phase"] == "started"
          approvals["validation:#{filename}"] = approval(source, directory, pending ? "pending" : "complete").merge("checkpoint" => checkpoint_name)
          if shared && artifacts.include?("validation_output")
            receipt.fetch("output", {}).fetch("streams", {}).each do |stream, captured|
              next unless %w[stdout stderr].include?(stream) && (pending || captured["sha256"])
              expected = filename.sub(/\.(finished|command|started)\.json\z/, ".#{stream}")
              raise Refused, "checkpoint.output_path" unless captured["file"] == expected
              next if pending && !File.exist?(File.join(directory, expected))
              spec = approval(File.join(directory, expected), directory)
              raise Refused, "checkpoint.output_digest" unless pending || spec.values_at("sha256", "bytes") == captured.values_at("sha256", "bytes")
              spec["status"] = pending ? "pending" : captured["status"] == "complete" ? "complete" : "truncated"
              spec["capture_status"] = captured["status"]
              spec["receipt"] = "validation:#{filename}"
              approvals["validation_output:#{expected}"] = spec
            end
            observed = receipt["observed"]
            if observed.is_a?(Hash) && observed["status"] == "reported"
              source = observed.fetch("source")
              spec = approval(source.fetch("path"), directory)
              raise Refused, "checkpoint.result_digest" unless spec["sha256"] == source["sha256"]
              name = filename.sub(/\.(finished|command|started)\.json\z/, ".observation.json")
              approvals["validation_result:#{name}"] = spec.merge("receipt" => "validation:#{filename}")
            end
          end
        end
        approvals.delete("validation") unless receipts.empty? || approvals.keys.none? { |name| name.start_with?("validation:") }
      end
      directory
    end
  end
end
