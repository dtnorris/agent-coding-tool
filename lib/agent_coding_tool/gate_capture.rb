# frozen_string_literal: true

require_relative "bootstrap"

if AgentCodingTool::Bootstrap::COMPOSITION.fetch("mode") == "split"
  require File.join(AgentCodingTool::Bootstrap::COMPOSITION.fetch("packages").fetch("act-observability").fetch("root"), "lib/act_observability")
  unless defined?(ActObservability::GateCapture)
    raise AgentCodingTool::Bootstrap::Refused, "bootstrap: pinned act-observability has no GateCapture; check the published composition"
  end
  module AgentCodingTool
    # Preserves the capture API and original package exceptions at the gate seam.
    GateCapture = ActObservability::GateCapture
  end
else
require "digest"

module AgentCodingTool
  # Bounded binary capture at the native gate boundary. Console delivery and
  # durable capture have independent outcomes; neither changes command success.
  class GateCapture
    LIMIT = 4 * 1024 * 1024

    # Binds a private gate directory and invocation token plus existing consoles.
    # Missing storage is reported as unavailable, without preventing execution.
    def initialize(directory, token, out:, err:)
      @directory, @token = directory, token
      @consoles = { "stdout" => out, "stderr" => err }
      @streams, @writers, @threads = {}, {}, []
    end

    # Yields native system redirections and returns the block result. Always
    # closes/drains owned pipes, retaining partial evidence on spawn/interrupt.
    # Original exceptions propagate; stalled inherited pipes have bounded cleanup.
    def run
      @consoles.each do |name, console|
        reader, writer = IO.pipe
        reader.binmode
        writer.binmode
        @writers[name.to_sym] = writer
        @threads << Thread.new { drain(name, reader, console) }
      end
      yield @writers.transform_keys { |key| key == :stdout ? :out : :err }
    ensure
      @writers.each_value { |writer| writer.close unless writer.closed? }
      @threads.each do |thread|
        next if thread.join(1)
        thread.kill.join
      end
    end

    # Returns explicit per-stream counts, digests and completeness. Paths are
    # basenames relative to this invocation's checkpoint directory. No output
    # bytes or environment values enter the receipt. Does not claim durability
    # for absent/partial files or failed flush/fsync operations.
    def result
      { "status" => @streams.values.all? { |spec| spec["status"] == "complete" } && @streams.length == 2 ? "complete" : "incomplete",
        "limit_per_stream" => LIMIT, "streams" => @streams }
    end

    private

    # Drains binary bytes to a capped private file and the original console.
    # Capturing/presentation failures remain separate from command status. Files
    # are never overwritten; incomplete captures survive forced thread cleanup.
    def drain(name, reader, console)
      spec = { "status" => "pending", "bytes" => 0, "observed_bytes" => 0,
        "console" => "complete", "file" => "gate-#{@token}.#{name}" }
      @streams[name] = spec
      file = nil
      begin
        raise IOError unless @directory
        file = File.open(File.join(@directory, spec["file"]), File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600)
        file.binmode
      rescue IOError, SystemCallError, NotImplementedError
        spec["status"] = "persistence_error"
      end
      loop do
        bytes = reader.readpartial(16_384)
        spec["observed_bytes"] += bytes.bytesize
        if file
          begin
            retained = bytes.byteslice(0, [LIMIT - spec["bytes"], bytes.bytesize].min)
            file.write(retained)
            spec["bytes"] += retained.bytesize
          rescue IOError, SystemCallError, NotImplementedError
            spec["status"] = "persistence_error"
            file.close rescue nil
            file = nil
          end
        end
        if spec["console"] == "complete"
          begin
            console.write(bytes)
            console.flush if console.respond_to?(:flush)
          rescue IOError, SystemCallError
            spec["console"] = "delivery_error"
          end
        end
      end
    rescue EOFError
      spec["status"] = spec["observed_bytes"] > LIMIT ? "truncated" : "complete" if spec["status"] == "pending"
    ensure
      if file
        begin
          file.flush
          file.fsync
          file.close
          spec["sha256"] = Digest::SHA256.file(File.join(@directory, spec["file"])).hexdigest
          File.open(@directory, File::RDONLY, &:fsync)
        rescue IOError, SystemCallError, NotImplementedError
          spec["status"] = "persistence_error"
        ensure
          begin
            file.close unless file.closed?
          rescue IOError, SystemCallError
            spec["status"] = "persistence_error"
          end
        end
      end
      spec["status"] = "incomplete" if spec["status"] == "pending"
      reader.close unless reader.closed?
    end
  end
end
end
