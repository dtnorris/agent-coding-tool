# frozen_string_literal: true

require "digest"
require "json"
require "thread"
require "time"

module AgentCodingTool
  # Reads one operator-selected Launcher run, never discovers paths from requests.
  # This is a transport-independent boundary, not authentication or a server.
  # A trusted adapter must authenticate the caller and supply its identity itself.
  class RunEvidenceReader
    # A refusal returns no artifact bytes; callers may report the reason verbatim.
    class Refused < StandardError; end

    ARTIFACTS = %w[final transcript stderr checkpoint candidate validation validation_output].freeze
    CONTEXT_ARTIFACTS = %w[prompt launch_input].freeze
    IDENTITIES = %w[task_id attempt invocation_id session_id].freeze
    MAX_FILE = 4 * 1024 * 1024
    MAX_CHUNK = 16 * 1024
    MAX_TRANSCRIPT = 64 * 1024 * 1024

    # Streams one managed transcript through a finite scan, retaining only a
    # requested chunk and at most one bounded JSON record during initial approval.
    # Returns full-source digest/size plus chunk bytes; unsafe, changed or foreign
    # sources raise Refused. Oversize sources/records return explicit unavailability.
    def self.transcript(path, root, session_id: nil, digest: nil, offset: 0, length: 0)
      raise Refused, "transcript.path" unless path.is_a?(String) && path.start_with?("#{root}/") &&
        File.expand_path(path) == path && File.realpath(root) == root
      cursor = path
      loop do
        raise Refused, "transcript.symlink" if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)
        cursor = File.dirname(cursor)
      end
      raise Refused, "transcript.escape" unless File.realpath(path) == path
      File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        stat = file.stat
        raise Refused, "transcript.source" unless stat.file? && stat.uid == Process.uid
        return { "status" => "missing", "reason" => "transcript.scan_limit", "bytes" => stat.size } if stat.size > MAX_TRANSCRIPT
        hash, total, chunk, pending, seen = Digest::SHA256.new, 0, "".b, "".b, false
        file.binmode
        while (part = file.read(MAX_CHUNK))
          raise Refused, "transcript.changed" if total + part.bytesize > MAX_TRANSCRIPT
          hash.update(part)
          first = [offset - total, 0].max
          last = [offset + length - total, part.bytesize].min
          chunk << part.byteslice(first, last - first) if last > first
          total += part.bytesize
          next unless session_id
          pending << part
          while (newline = pending.index("\n"))
            line = pending.slice!(0, newline + 1)
            return { "status" => "missing", "reason" => "transcript.record_limit", "bytes" => stat.size } if line.bytesize > MAX_FILE
            event = JSON.parse(line)
            next unless event.is_a?(Hash) && event["type"] == "thread.started"
            raise Refused, "transcript.session" unless event["thread_id"] == session_id
            seen = true
          end
          return { "status" => "missing", "reason" => "transcript.record_limit", "bytes" => stat.size } if pending.bytesize > MAX_FILE
        end
        if session_id && !pending.empty?
          event = JSON.parse(pending)
          if event.is_a?(Hash) && event["type"] == "thread.started"
            raise Refused, "transcript.session" unless event["thread_id"] == session_id
            seen = true
          end
        end
        raise Refused, "transcript.session" if session_id && !seen
        fields = %i[dev ino uid size mtime ctime]
        raise Refused, "transcript.changed" unless fields.all? { |field| file.stat.public_send(field) == stat.public_send(field) &&
          File.stat(path).public_send(field) == stat.public_send(field) } && total == stat.size && File.realpath(path) == path
        raise Refused, "stale source" if digest && hash.hexdigest != digest
        { "sha256" => hash.hexdigest, "bytes" => total, "data" => chunk }
      end
    rescue SystemCallError, IOError, ArgumentError, JSON::ParserError
      raise Refused, "transcript.unavailable", cause: nil
    end

    # Inputs are private operator configuration, never model/tool arguments.
    # binding pins Launcher identities plus workspace, repository, base_sha,
    # remote_url and branch. checkpoint_attempt is the separate ACT state-derived
    # checkpoint key (not Launcher's numeric attempt), when checkpoints exist.
    # approvals maps named artifacts to exact path, sha256 and complete/pending
    # status, or to {"status"=>"missing"}. Transcript means approved stdout.jsonl,
    # not the broader Codex session. Checkpoint/candidate/validation use existing
    # ACT checkpoint records. No validation command is executed or inferred.
    # Returns a leased reader; malformed configuration/files raise Refused.
    def initialize(run_dir:, checkpoint_dir:, handoff_sha256:, binding:, approvals:,
                   manager:, requests: 64, output_bytes: 1024 * 1024, seconds: 300, paged: false)
      @lock = Mutex.new
      @paged = paged
      @run_dir, @checkpoint_dir = run_dir.dup.freeze, checkpoint_dir.dup.freeze
      @binding, @approvals = JSON.parse(JSON.generate([binding, approvals]))
      @manager, @handoff_sha256 = manager.dup.freeze, handoff_sha256.dup.freeze
      refuse!("invalid lease") unless requests.is_a?(Integer) && (1..128).cover?(requests) &&
        output_bytes.is_a?(Integer) && (1..MAX_FILE).cover?(output_bytes) &&
        seconds.is_a?(Integer) && (1..300).cover?(seconds) && manager.is_a?(String) && !manager.empty?
      @requests, @output_bytes = requests, output_bytes
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      @revision = Digest::SHA256.hexdigest(JSON.generate([@binding, @approvals, handoff_sha256]))
      refuse!("invalid binding") unless @binding.is_a?(Hash)
      refuse!("invalid artifact selection") unless @approvals.is_a?(Hash) &&
        @approvals.keys.all? { |name| ARTIFACTS.include?(name) || CONTEXT_ARTIFACTS.include?(name) || name.match?(/\Avalidation:gate-[0-9a-f-]+\.(started|finished)\.json\z/) ||
          @paged && name.match?(/\Avalidation:gate-[0-9a-f-]+\.command\.json\z/) ||
          name.match?(/\Avalidation_output:gate-[0-9a-f-]+\.(stdout|stderr)\z/) ||
          name.match?(/\Avalidation_result:gate-[0-9a-f-]+\.observation\.json\z/) ||
          @paged && name.match?(/\A(checkpoint:[0-9a-f-]+\.json|candidate:[0-9a-f-]+\.patch)\z/) ||
          name.match?(/\Aworker:[0-9a-f]{32}:(candidate|apply|focused)\z/) } && !@approvals.empty?
      @approvals.each_value do |spec|
        refuse!("invalid artifact status") unless spec.is_a?(Hash) &&
          %w[complete pending missing truncated].include?(spec["status"])
      end
      report!
    rescue KeyError, TypeError, JSON::ParserError => error
      raise Refused, "malformed approval: #{error.class}"
    end

    # Accepts only manifest/read plus exact identities and revision; reads also
    # require an approved artifact, byte offset and length. caller comes from the
    # authenticated adapter, never the request. Returns metadata or lossless base64
    # with full/chunk hashes and complete/truncated/pending/missing status.
    # Every attempt consumes the finite lease, including refusals. Raises Refused
    # on identity, path, revision, mutation, budget or source changes.
    def call(request, caller:)
      @lock.synchronize do
        refuse!("lease exhausted") if @requests <= 0 || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline
        @requests -= 1
        refuse!("caller mismatch") unless caller == @manager
        refuse!("invalid request") unless request.is_a?(Hash)
        operation = request["operation"]
        allowed = IDENTITIES + %w[operation revision]
        allowed += %w[artifact offset length] if operation == "read"
        allowed += ["offset"] if @paged && operation == "manifest" && request.key?("offset")
        refuse!("unsupported operation or fields") unless %w[manifest read].include?(operation) &&
          (request.keys - allowed).empty? && (allowed - request.keys).empty?
        refuse!("run identity mismatch") unless IDENTITIES.all? { |key| request[key] == @binding.fetch(key) }
        # Initial manifest obtains the revision; all reads must present it.
        refuse!("stale revision") unless request["revision"] == @revision ||
          (operation == "manifest" && request["revision"].nil?)
        report = report!
        metadata = { "binding" => JSON.parse(JSON.generate(@binding)), "revision" => @revision.dup,
          "observed_at" => Time.now.utc.iso8601(6), "handoff_sha256" => @handoff_sha256,
          "launch_status" => report["status"], "worker_exit_status" => report["exit_status"],
          "validation_assurance" => "recorded evidence only; not independently validated" }
        if operation == "manifest"
          offset = request.fetch("offset", 0)
          refuse!("invalid manifest offset") unless offset.is_a?(Integer) && offset.between?(0, @approvals.length)
          entries = @paged ? @approvals.to_a.slice(offset, 16) : @approvals.to_a
          return metadata.merge("artifacts" => JSON.parse(JSON.generate(entries.to_h)),
            "artifact_total" => @approvals.length, "next_offset" => @paged && offset + entries.length < @approvals.length ? offset + entries.length : nil)
        end
        spec = @approvals[request["artifact"]]
        refuse!("artifact not approved") unless spec
        offset, length = request.values_at("offset", "length")
        refuse!("invalid chunk") unless offset.is_a?(Integer) && offset >= 0 &&
          length.is_a?(Integer) && (1..MAX_CHUNK).cover?(length)
        return metadata.merge("artifact" => request["artifact"], "status" => "missing") if spec["status"] == "missing"

        if request["artifact"] == "transcript" && spec["streamed"]
          refuse!("offset past end") if offset > spec.fetch("bytes")
          chunk = transcript!(report, offset: offset, length: length)
          total = spec.fetch("bytes")
        else
          bytes = artifact!(request.fetch("artifact"), report)
          refuse!("offset past end") if offset > bytes.bytesize
          chunk, total = bytes.byteslice(offset, length), bytes.bytesize
        end
        refuse!("output budget exhausted") if chunk.bytesize > @output_bytes
        @output_bytes -= chunk.bytesize
        following = offset + chunk.bytesize
        status = %w[pending truncated].include?(spec["status"]) ? spec["status"] : following < total ? "truncated" : "complete"
        metadata.merge("artifact" => request["artifact"], "source" => spec.fetch("path").dup,
          "sha256" => spec.fetch("sha256").dup, "bytes" => total,
          "offset" => offset, "next_offset" => following < total ? following : nil,
          "status" => status, "capture_status" => spec["capture_status"], "encoding" => "base64", "data" => [chunk].pack("m0"),
          "chunk_sha256" => Digest::SHA256.hexdigest(chunk))
      end
    rescue KeyError, TypeError, JSON::ParserError => error
      raise Refused, "malformed evidence/request: #{error.class}"
    end

    private

    # Raises the public refusal type without attaching private source contents.
    def refuse!(reason)
      raise Refused, reason
    end

    # Reads only bounded regular nonsymlink files beneath an exact approved root.
    # Checks all ancestors and hashes before releasing any bytes; filesystem or
    # concurrent replacement failures raise Refused. Digests pin content even if
    # a trusted host replaces an ancestor between filesystem checks.
    def bytes!(path, root, digest)
      refuse!("invalid source") unless path.is_a?(String) && root.is_a?(String) &&
        path.start_with?("#{root}/") && File.expand_path(path) == path &&
        File.expand_path(root) == root && digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
      cursor = path
      loop do
        refuse!("symlink source") if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)
        cursor = File.dirname(cursor)
      end
      refuse!("root escape") unless File.realpath(path) == path && File.realpath(root) == root
      bytes = File.open(path, File::RDONLY | File::NONBLOCK | File::NOFOLLOW) do |file|
        refuse!("nonregular or oversized source") unless file.stat.file? && file.stat.uid == Process.uid && file.stat.size <= MAX_FILE
        file.binmode.read(MAX_FILE + 1) || "".b
      end
      refuse!("stale source") unless bytes.bytesize <= MAX_FILE && Digest::SHA256.hexdigest(bytes) == digest &&
        File.realpath(path) == path
      bytes
    rescue SystemCallError, IOError, ArgumentError
      raise Refused, "source unavailable"
    end

    # Rechecks the immutable approved handoff and its launch provenance. Missing
    # session binding refuses; current workspace state is not inferred from it.
    def report!
      report = JSON.parse(bytes!(File.join(@run_dir, "handoff.json"), @run_dir, @handoff_sha256))
      authority = { "pushed_sha" => @binding.fetch("base_sha"),
        "remote_url" => @binding.fetch("remote_url"), "branch" => @binding.fetch("branch") }
      refuse!("run binding mismatch") unless report.is_a?(Hash) && report["schema_version"] == "agent-coding-tool-run/v1" &&
        IDENTITIES.all? { |key| report[key] == @binding.fetch(key) } &&
        IDENTITIES.all? { |key| !@binding.fetch(key).to_s.empty? } &&
        report["workspace"] == @binding.fetch("workspace") &&
        report["writable_repository"] == @binding.fetch("repository") &&
        File.expand_path(@binding.fetch("workspace")) == @binding.fetch("workspace") &&
        authority.all? { |key, value| report.dig("writable_authority", key) == value &&
          report.dig("preparation", @binding.fetch("repository"), key) == value }
      report
    end

    # Checks the launch's exact transcript path/digest before returning a bounded
    # chunk. Full streaming revalidation prevents changed bytes outside that chunk
    # from passing an old selection; v1 never enables this separate read contract.
    def transcript!(report, offset: 0, length: 0)
      spec = @approvals.fetch("transcript")
      refuse!("transcript authority") unless @paged && report["jsonl_path"] == spec["path"]
      recorded = report.fetch("artifacts", []).find { |entry| entry["path"] == spec["path"] }
      refuse!("artifact differs from launch record") unless spec["status"] == "pending" || recorded &&
        recorded.values_at("sha256", "bytes") == spec.values_at("sha256", "bytes")
      result = self.class.transcript(spec.fetch("path"), @run_dir, digest: spec.fetch("sha256"), offset: offset, length: length)
      refuse!("stale source") unless result["bytes"] == spec["bytes"] && result["sha256"] == spec["sha256"]
      result.fetch("data")
    end

    # Reads an approved artifact and checks its existing Launcher/checkpoint link.
    # Gate receipts retain their own invocation ID; candidate.launch_invocation
    # supplies the worker binding. Raw receipt output/status is never rewritten.
    def artifact!(name, report)
      spec = @approvals.fetch(name)
      return transcript!(report) if name == "transcript" && spec["streamed"]
      if name.start_with?("validation_result:")
        receipt = JSON.parse(artifact!(spec.fetch("receipt"), report))
        source = receipt.fetch("observed").fetch("source")
        refuse!("result binding mismatch") unless receipt.dig("observed", "status") == "reported" &&
          source.values_at("path", "sha256") == spec.values_at("path", "sha256")
        return bytes!(spec.fetch("path"), @checkpoint_dir, spec.fetch("sha256"))
      end
      if name.start_with?("worker:")
        token, kind = name.split(":").drop(1)
        refuse!("registration path") unless spec["registration"] == "registration-#{token}.json" &&
          spec["path"] == File.join(@run_dir, "worker-#{token}-#{kind}")
        registration = JSON.parse(bytes!(File.join(@run_dir, spec.fetch("registration")), @run_dir, spec.fetch("registration_sha256")))
        refuse!("registration binding") unless registration["binding"] == @binding.slice(*IDENTITIES) &&
          registration.values_at("workspace", "base_sha") == @binding.values_at("workspace", "base_sha") &&
          registration.fetch("files").fetch(kind).values_at("sha256", "bytes") == spec.values_at("sha256", "bytes")
        return bytes!(spec.fetch("path"), @run_dir, spec.fetch("sha256"))
      end
      if name.start_with?("validation_output:")
        filename = name.delete_prefix("validation_output:")
        receipt_name = spec.fetch("receipt")
        refuse!("output receipt mismatch") unless receipt_name.match?(/\Avalidation:gate-[0-9a-f-]+\.(started|command|finished)\.json\z/) &&
          receipt_name.delete_prefix("validation:").sub(/\.(started|command|finished)\.json\z/, ".#{filename.split('.').last}") == filename
        receipt = JSON.parse(artifact!(receipt_name, report))
        stream = filename.split(".").last
        captured = receipt.fetch("output").fetch("streams").fetch(stream)
        refuse!("output binding mismatch") unless captured["file"] == filename &&
          ((receipt["receipt_phase"] == "started" && spec["status"] == "pending") || captured.values_at("sha256", "bytes") == spec.values_at("sha256", "bytes")) &&
          File.join(@checkpoint_dir, filename) == spec["path"]
        return bytes!(spec.fetch("path"), @checkpoint_dir, spec.fetch("sha256"))
      end
      name = "validation" if name.start_with?("validation:")
      name = "checkpoint" if name.start_with?("checkpoint:")
      name = "candidate" if name.start_with?("candidate:")
      root = %w[checkpoint candidate validation].include?(name) ? @checkpoint_dir : @run_dir
      field = { "final" => "final_path", "transcript" => "jsonl_path", "stderr" => "stderr_path",
        "prompt" => "prompt_path", "launch_input" => "stdin_path" }[name]
      refuse!("artifact path mismatch") if field && report[field] != spec["path"]
      bytes = bytes!(spec.fetch("path"), root, spec.fetch("sha256"))
      refuse!("prompt binding mismatch") if name == "prompt" && report["prompt_sha256"] != spec["sha256"]
      if field && report["artifacts"]
        recorded = report.fetch("artifacts").find { |artifact| artifact["path"] == spec["path"] }
        refuse!("artifact differs from launch record") unless spec["status"] == "pending" || recorded &&
          recorded["sha256"] == spec["sha256"] && recorded["bytes"] == bytes.bytesize
      end
      if name == "transcript"
        sessions = bytes.lines.filter_map do |line|
          event = JSON.parse(line)
          event["thread_id"] if event.is_a?(Hash) && event["type"] == "thread.started"
        end
        refuse!("transcript session mismatch") unless sessions.uniq == [@binding.fetch("session_id")]
      elsif %w[checkpoint candidate validation].include?(name)
        checkpoint_name = spec.fetch("checkpoint", "checkpoint")
        checkpoint = JSON.parse(artifact!(checkpoint_name, report)) unless name == "checkpoint"
        record = name == "candidate" ? checkpoint : JSON.parse(bytes)
        refuse!("invalid checkpoint record") unless record.is_a?(Hash)
        invocation = name == "validation" ? record.dig("candidate", "launch_invocation") : record["launch_invocation"]
        refuse!("checkpoint binding mismatch") unless record["task_id"] == @binding["task_id"] &&
          record["attempt"] == @binding.fetch("checkpoint_attempt") && invocation == @binding["invocation_id"] &&
          record["repository"] == @binding["repository"] &&
          %w[remote_url branch].all? { |key| record.dig("authority", key) == @binding[key] } &&
          record.dig("authority", "pushed_sha") == @binding["base_sha"] &&
          record["schema_version"] == (name == "validation" ? "agent-coding-tool-checkpoint-gate/v1" : "agent-coding-tool-checkpoint/v1")
        refuse!("candidate identity mismatch") if name == "candidate" &&
          (File.join(File.dirname(@approvals.fetch(checkpoint_name).fetch("path")), record.fetch("artifact")) != spec["path"] || record["sha256"] != spec["sha256"])
        refuse!("validation candidate mismatch") if name == "validation" &&
          record.dig("candidate", "sha256") != checkpoint["sha256"]
        refuse!("validation record mismatch") if name == "validation" && @paged &&
          (record.dig("candidate", "record_file") != File.basename(@approvals.fetch(checkpoint_name).fetch("path")) ||
            %w[artifact launch_invocation].any? { |key| record.dig("candidate", key) != checkpoint[key] })
        if name == "validation"
          phase = record["receipt_phase"] == "started" ? "started" : @paged && record["receipt_phase"] == "command_finished" ? "command" : "finished"
          refuse!("validation invocation mismatch") unless File.basename(spec.fetch("path")) == "gate-#{record.fetch('invocation_id')}.#{phase}.json"
        end
      end
      bytes
    end
  end
end
