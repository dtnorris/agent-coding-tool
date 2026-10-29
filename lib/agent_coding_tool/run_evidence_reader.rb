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
    IDENTITIES = %w[task_id attempt invocation_id session_id].freeze
    MAX_FILE = 4 * 1024 * 1024
    MAX_CHUNK = 16 * 1024

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
                   manager:, requests: 64, output_bytes: 1024 * 1024, seconds: 300)
      @lock = Mutex.new
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
        @approvals.keys.all? { |name| ARTIFACTS.include?(name) || name.match?(/\Avalidation:gate-[0-9a-f-]+\.finished\.json\z/) } && !@approvals.empty?
      @approvals.each_value do |spec|
        refuse!("invalid artifact status") unless spec.is_a?(Hash) &&
          %w[complete pending missing].include?(spec["status"])
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
          return metadata.merge("artifacts" => JSON.parse(JSON.generate(@approvals)))
        end
        spec = @approvals[request["artifact"]]
        refuse!("artifact not approved") unless spec
        offset, length = request.values_at("offset", "length")
        refuse!("invalid chunk") unless offset.is_a?(Integer) && offset >= 0 &&
          length.is_a?(Integer) && (1..MAX_CHUNK).cover?(length)
        return metadata.merge("artifact" => request["artifact"], "status" => "missing") if spec["status"] == "missing"

        bytes = artifact!(request.fetch("artifact"), report)
        refuse!("offset past end") if offset > bytes.bytesize
        chunk = bytes.byteslice(offset, length)
        refuse!("output budget exhausted") if chunk.bytesize > @output_bytes
        @output_bytes -= chunk.bytesize
        following = offset + chunk.bytesize
        status = spec["status"] == "pending" ? "pending" : following < bytes.bytesize ? "truncated" : "complete"
        metadata.merge("artifact" => request["artifact"], "source" => spec.fetch("path").dup,
          "sha256" => spec.fetch("sha256").dup, "bytes" => bytes.bytesize,
          "offset" => offset, "next_offset" => following < bytes.bytesize ? following : nil,
          "status" => status, "encoding" => "base64", "data" => [chunk].pack("m0"),
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
        refuse!("nonregular or oversized source") unless file.stat.file? && file.stat.size <= MAX_FILE
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

    # Reads an approved artifact and checks its existing Launcher/checkpoint link.
    # Gate receipts retain their own invocation ID; candidate.launch_invocation
    # supplies the worker binding. Raw receipt output/status is never rewritten.
    def artifact!(name, report)
      spec = @approvals.fetch(name)
      name = "validation" if name.start_with?("validation:")
      root = %w[checkpoint candidate validation].include?(name) ? @checkpoint_dir : @run_dir
      field = { "final" => "final_path", "transcript" => "jsonl_path", "stderr" => "stderr_path" }[name]
      refuse!("artifact path mismatch") if field && report[field] != spec["path"]
      bytes = bytes!(spec.fetch("path"), root, spec.fetch("sha256"))
      if field && report["artifacts"]
        recorded = report.fetch("artifacts").find { |artifact| artifact["path"] == spec["path"] }
        refuse!("artifact differs from launch record") unless recorded &&
          recorded["sha256"] == spec["sha256"] && recorded["bytes"] == bytes.bytesize
      end
      if name == "transcript"
        sessions = bytes.lines.filter_map do |line|
          event = JSON.parse(line)
          event["thread_id"] if event.is_a?(Hash) && event["type"] == "thread.started"
        end
        refuse!("transcript session mismatch") unless sessions.uniq == [@binding.fetch("session_id")]
      elsif %w[checkpoint candidate validation].include?(name)
        checkpoint = JSON.parse(artifact!("checkpoint", report)) unless name == "checkpoint"
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
          (File.join(File.dirname(@approvals.fetch("checkpoint").fetch("path")), record.fetch("artifact")) != spec["path"] || record["sha256"] != spec["sha256"])
        refuse!("validation candidate mismatch") if name == "validation" &&
          record.dig("candidate", "sha256") != checkpoint["sha256"]
      end
      bytes
    end
  end
end
