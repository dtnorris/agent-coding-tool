# frozen_string_literal: true

require "socket"
require "json"
require "pathname"
require "securerandom"
require "timeout"
require_relative "session"

module MemoryGit
  # Bounded data-only codec. No Marshal, executable objects or text conversion of
  # subprocess bytes crosses the socket. Invalid envelopes raise test mismatches.
  module Wire
    LIMIT = 4 * 1024 * 1024

    # Encodes only request/result primitives, retaining String encoding and bytes.
    # Unsupported objects or excessive nesting raise Mismatch before transmission.
    def self.encode(value, depth = 0)
      raise Mismatch, "protocol nesting limit" if depth > 16
      case value
      when String then { "bytes" => [value.b].pack("m0"), "encoding" => value.encoding.name }
      when Symbol then { "symbol" => value.to_s }
      when Array then value.map { |item| encode(item, depth + 1) }
      when Hash then { "pairs" => value.map { |key, item| [encode(key, depth + 1), encode(item, depth + 1)] } }
      when Integer, TrueClass, FalseClass, NilClass then value
      when Float
        raise Mismatch, "nonfinite protocol number" unless value.finite?
        value
      else raise Mismatch, "unsupported protocol value"
      end
    end

    # Decodes exact tagged primitives; ambiguous tags/duplicate hash keys refuse.
    # Malformed base64/encoding/shape errors become uncatchable test mismatches.
    def self.decode(value, depth = 0)
      raise Mismatch, "protocol nesting limit" if depth > 16
      case value
      when Hash
        case value.keys.sort
        when %w[bytes encoding] then value.fetch("bytes").unpack1("m0").force_encoding(value.fetch("encoding"))
        when ["symbol"]
          raise Mismatch, "invalid protocol symbol" unless %w[cwd env input timeout binmode pgroup].include?(value["symbol"])
          value.fetch("symbol").to_sym
        when ["pairs"]
          pairs = value.fetch("pairs").map do |pair|
            raise Mismatch, "invalid protocol pair" unless pair.is_a?(Array) && pair.length == 2
            pair.map { |item| decode(item, depth + 1) }
          end
          raise Mismatch, "duplicate protocol key" unless pairs.map(&:first).uniq.size == pairs.size
          pairs.to_h
        else raise Mismatch, "invalid protocol tag"
        end
      when Array then value.map { |item| decode(item, depth + 1) }
      when Integer, Float, TrueClass, FalseClass, NilClass then value
      else raise Mismatch, "untagged protocol value"
      end
    rescue ArgumentError, TypeError, NoMethodError => error
      raise Mismatch, "malformed protocol value: #{error.class}"
    end

    # Writes one bounded network-order frame by an absolute monotonic deadline.
    # Partial writes/timeouts propagate; callers must never retry mutations.
    def self.write(socket, message, deadline)
      bytes = JSON.generate(message).b
      raise Mismatch, "protocol frame limit" unless bytes.bytesize.between?(1, LIMIT)
      pending = [bytes.bytesize].pack("N") + bytes
      until pending.empty?
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout::Error, "memory broker write timeout" unless remaining.positive? && IO.select(nil, [socket], nil, remaining)
        count = socket.write_nonblock(pending, exception: false)
        pending = pending.byteslice(count..) unless count == :wait_writable
      end
    end

    # Reads an exact frame, refusing EOF/truncation/oversize/malformed JSON.
    # All reads share one deadline, including slow partial headers and bodies.
    def self.read(socket, deadline)
      length = exact(socket, 4, deadline).unpack1("N")
      raise Mismatch, "protocol frame limit" unless length.between?(1, LIMIT)
      JSON.parse(exact(socket, length, deadline), max_nesting: 48)
    rescue JSON::ParserError => error
      raise Mismatch, "malformed broker JSON: #{error.class}"
    end

    # Reads a bounded byte count; returns binary String or raises on timeout/EOF.
    def self.exact(socket, length, deadline)
      bytes = "".b
      while bytes.bytesize < length
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout::Error, "memory broker read timeout" unless remaining.positive? && IO.select([socket], nil, nil, remaining)
        part = socket.read_nonblock(length - bytes.bytesize, exception: false)
        raise EOFError, "memory broker closed mid-frame" unless part
        bytes << part unless part == :wait_readable
      end
      bytes
    end
  end

  # One Ruby owner in the parent interpreter. A leased server thread serializes
  # individual commands; no process/fork/snapshot or workflow lock is involved.
  # Builders finish before start. Once started, all mutable reads/writes use call.
  class Broker
    attr_reader :endpoint, :startup_seconds, :events

    # Returns a bounded address for the canonical socket from this interpreter's
    # cwd without changing it. Unrepresentable paths refuse; no external fallback.
    def self.socket_path(absolute_path)
      cwd = File.realpath(Dir.pwd)
      path = absolute_path.bytesize < 104 ? absolute_path :
        Pathname.new(absolute_path).relative_path_from(Pathname.new(cwd)).to_s
      raise Mismatch, "broker socket path exceeds sockaddr_un limit" unless
        path.bytesize < 104 && File.expand_path(path, cwd) == absolute_path
      path
    end

    # Binds a socket in an existing canonical private directory under the world.
    # Paths must fit sockaddr_un; no fallback to a shared or external directory.
    # Filesystem/bind failures propagate; lease/request bounds are positive finite.
    def initialize(world:, directory:, case_id:, lease: 20, seconds: 2)
      raise Mismatch, "invalid broker bounds" unless [lease, seconds].all? { |value| value.is_a?(Numeric) && value.finite? && value.positive? }
      stat = File.lstat(directory)
      raise Mismatch, "unsafe socket directory" unless File.realpath(directory) == directory && stat.directory? &&
        stat.uid == Process.uid && (stat.mode & 0o077).zero? && (directory == world.root || directory.start_with?(world.root + "/"))
      @world, @seconds = world, seconds
      @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + lease
      @events, @seen, @closed = [], {}, false
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      absolute_path = File.join(directory, "w.sock")
      @cwd = File.realpath(Dir.pwd)
      path = self.class.socket_path(absolute_path)
      @server = UNIXServer.new(path)
      File.chmod(0o600, path)
      @identity = File.lstat(path).then { |item| [item.dev, item.ino] }
      @endpoint = { "path" => path.freeze, "directory" => directory.freeze, "cwd" => @cwd.freeze,
        "case" => case_id.dup.freeze, "token" => SecureRandom.hex(32).freeze, "seconds" => seconds }.freeze
      @thread = Thread.new { serve }
      @thread.report_on_exception = false
      @startup_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    # Submits parent commands through the same authoritative serialization seam.
    # Returns CommandResult; protocol failures poison this client without retries.
    def call(argv, **fields)
      (@client ||= Client.new(endpoint)).call(argv, **fields)
    end

    # Explicitly forbids replacing live authority. Each case constructs a new
    # broker/token; stale clients never acquire a later world's mutable stores.
    def reset(*) = raise(Mismatch, "live broker reset prohibited")

    # Stops only this thread/socket, retaining files, events and candidate state.
    # Repeated close is safe; a replaced socket is never removed by cleanup.
    def close
      return if @closed
      @closed = true
      @server.close
      @connection&.close
      @thread.join(@seconds + 0.5)
      raise Mismatch, "broker did not stop" if @thread.alive?
      @world.verify!
    ensure
      path = @endpoint && File.expand_path(@endpoint.fetch("path"), @cwd)
      if path && File.socket?(path) && File.lstat(path).then { |item| [item.dev, item.ino] } == @identity
        File.unlink(path)
      end
    end

    private

    # Processes one bounded connection at a time until close/lease expiry.
    # Bad clients cannot stop the owner or consume another client's command.
    def serve
      until @closed
        remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break unless remaining.positive?
        next unless IO.select([@server], nil, nil, [remaining, 0.05].min)
        connection = @server.accept_nonblock(exception: false)
        next if connection == :wait_readable
        @connection = connection
        begin
          deadline = [@deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + @seconds].min
          message = Wire.read(connection, deadline)
          response = Timeout.timeout([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.001].max) { dispatch(message) }
          Wire.write(connection, response, deadline)
        rescue Mismatch, StandardError => error
          @events << { "status" => "refused", "error" => error.class.name }
        ensure
          connection.close unless connection.closed?
          @connection = nil
        end
      end
    rescue IOError, Errno::EBADF
      raise unless @closed
    ensure
      @server.close unless @server.closed?
    end

    # Authenticates exact version/case/token/id/operation before command decoding.
    # IDs are consumed before effects, including errors; ambiguous work never retries.
    def dispatch(message)
      unless message.is_a?(Hash) && message.keys.sort == %w[case id operation request token version] &&
             message["version"] == 1 && message["case"] == endpoint["case"] && message["token"] == endpoint["token"] &&
             message["id"].is_a?(String) && message["id"].match?(/\A[0-9a-f-]{36}:\d{1,5}\z/) &&
             !@seen[message["id"]] && @seen.size < 10_000 && message["operation"] == "command"
        raise Mismatch, "unauthorized/stale/duplicate broker request"
      end
      identifier = message.fetch("id")
      @seen[identifier] = true
      @events << { "id" => identifier, "status" => "started" }
      request = Wire.decode(message.fetch("request"))
      raise Mismatch, "malformed command envelope" unless request.is_a?(Array) && request.length == 2 && request[0].is_a?(Array) && request[1].is_a?(Hash)
      argv, fields = request
      result = @world.call(argv, **fields)
      @events << { "id" => identifier, "status" => "completed" }
      { "id" => identifier, "result" => Wire.encode([result.stdout, result.stderr, result.exitstatus, result.termsig]) }
    rescue Mismatch, StandardError => error
      @events << { "id" => identifier, "status" => "failed", "error" => error.class.name }
      { "id" => message.is_a?(Hash) ? message["id"] : nil, "error" => error.class.name, "message" => error.message.to_s.byteslice(0, 512) }
    end
  end

  # Per-interpreter client, with explicit request IDs and no reconnect/retry after
  # uncertain completion. Socket identity/permissions are checked before every call.
  class Client
    # Copies the private capability; no IO or mutable snapshot is imported.
    def initialize(endpoint)
      @endpoint = endpoint.dup.freeze
      @prefix, @sequence, @failed = SecureRandom.uuid, 0, false
      @lock = Mutex.new
    end

    # Sends one exact command; binary streams and exit/signal facts round-trip.
    # Broker refusal/death/timeout/malformed response raises Mismatch, never native Git.
    def call(argv, **fields)
      @lock.synchronize do
        raise Mismatch, "broker client unusable after failure" if @failed
        absolute_path = File.expand_path(@endpoint.fetch("path"), @endpoint.fetch("cwd"))
        directory = @endpoint.fetch("directory")
        path = Broker.socket_path(absolute_path)
        socket_stat, parent_stat = [absolute_path, directory].map { |item| File.lstat(item) }
        raise Mismatch, "unsafe broker endpoint" unless File.dirname(absolute_path) == directory &&
          File.realpath(directory) == directory && parent_stat.directory? &&
          parent_stat.uid == Process.uid && (parent_stat.mode & 0o077).zero? && socket_stat.socket? &&
          socket_stat.uid == Process.uid && (socket_stat.mode & 0o777) == 0o600
        identifier = "#{@prefix}:#{@sequence += 1}"
        request = { "version" => 1, "case" => @endpoint.fetch("case"), "token" => @endpoint.fetch("token"),
          "id" => identifier, "operation" => "command", "request" => Wire.encode([argv, fields]) }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @endpoint.fetch("seconds")
        connect(path, deadline) do |socket|
          Wire.write(socket, request, deadline)
          response = Wire.read(socket, deadline)
          raise Mismatch, "broker response identity" unless response.is_a?(Hash) && response["id"] == identifier
          raise Mismatch, "broker refused: #{response['error']}: #{response['message']}" if response["error"]
          raise Mismatch, "broker response shape" unless response.keys.sort == %w[id result]
          facts = Wire.decode(response.fetch("result"))
          raise Mismatch, "broker result shape" unless facts.is_a?(Array) && facts.length == 4
          stdout, stderr, exitstatus, termsig = facts
          AgentCodingTool::CommandResult.new(stdout: stdout, stderr: stderr, exitstatus: exitstatus, termsig: termsig)
        end
      rescue Mismatch, StandardError => error
        @failed = true
        raise Mismatch, "memory broker failure (not retried): #{error.message}"
      end
    end

    private

    # Bounds connect as well as IO; a full listener queue cannot hang a child.
    # Every error closes this socket and propagates without replaying the command.
    def connect(path, deadline)
      socket = Socket.new(Socket::AF_UNIX, Socket::SOCK_STREAM, 0)
      connected = socket.connect_nonblock(Socket.sockaddr_un(path), exception: false)
      if connected == :wait_writable
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Timeout::Error, "memory broker connect timeout" unless remaining.positive? && IO.select(nil, [socket], nil, remaining)
        error = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
        raise SystemCallError.new("memory broker connect", error) unless error.zero?
      end
      yield socket
    ensure
      socket&.close
    end
  end
end
