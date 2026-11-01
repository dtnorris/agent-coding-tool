# frozen_string_literal: true

require "net/http"
require "open3"
require "rbconfig"
require "shellwords"
require "timeout"
require_relative "evidence_session"
require_relative "tunnel_credential"

module AgentCodingTool
  # Foreground finite tunnel controller. An independent owner retains unreaped
  # direct children, watches controller EOF and polls the durable ACT admission.
  # Does not modify profiles, hosted settings, ACT lifecycle or checkpoint data.
  class EvidenceTunnel
    Refused = RunEvidenceReader::Refused
    ENVIRONMENT = %w[PATH HOME TMPDIR LANG].freeze
    STARTUP_SECONDS = 30

    # Uses explicit operator paths and existing grant facts. No path is discovered
    # from cwd, a task-specific package, source HEAD or historical process IDs.
    def initialize(session:, grant:, env_file:, client:, runtime_dir:, out:, err:)
      @path, @grant, @env_file, @client, @runtime_dir = session, grant, env_file, client, runtime_dir
      @out, @err = out, err
    end

    # Starts one approved nonrenewable admission and waits in the foreground.
    # Returns the owner's nonzero startup/cleanup outcome; fixed refusals raise.
    # An absent process inventory refuses before the client can start.
    def run
      key = TunnelCredential.resolve(@env_file)
      check_paths
      raise Refused, "tunnel.session_reused" if File.exist?(@path) || File.symlink?(@path)
      grant = RunEvidenceStore.parse(RunEvidenceStore.bytes(@grant, root: File.dirname(@grant), private: true))
      endpoint = grant.dig("transport", "endpoint")
      raise Refused, "tunnel.endpoint" unless endpoint.is_a?(String) && endpoint.match?(/\Atunnel_[a-zA-Z0-9]+\/main\z/)
      lock_path = File.join(@runtime_dir, "#{Digest::SHA256.hexdigest(endpoint)}.lock")
      @endpoint_lock = File.open(lock_path, File::RDWR | File::CREAT | File::NOFOLLOW | File::NONBLOCK, 0o600)
      raise Refused, "tunnel.occupied" unless @endpoint_lock.stat.file? && @endpoint_lock.stat.uid == Process.uid &&
        (@endpoint_lock.stat.mode & 0o077).zero? && @endpoint_lock.flock(File::LOCK_EX | File::LOCK_NB)
      inventory!
      EvidenceSession.start(@path, @grant)
      @session = EvidenceSession.new(@path)
      write_config(endpoint.split("/").first)
      watch, keepalive = IO.pipe
      owner = fork do
        keepalive.close
        begin
          exit! own(watch, key)
        rescue StandardError
          observe("cleanup", "receipt_or_owner_failure")
          exit! 2
        end
      end
      owner_started = true
      key = nil
      watch.close
      @endpoint_lock.close
      interrupted = nil
      previous = %w[INT TERM].to_h do |name|
        [name, Signal.trap(name) { interrupted = name; keepalive.close unless keepalive.closed? }]
      end
      _pid, status = Process.wait2(owner)
      interrupted ? (interrupted == "INT" ? 130 : 143) : status.exitstatus || 2
    ensure
      previous&.each { |name, handler| Signal.trap(name, handler) }
      keepalive&.close unless keepalive&.closed?
      watch&.close unless watch&.closed?
      @endpoint_lock&.close unless @endpoint_lock&.closed?
      @session&.stop unless owner_started
    end

    private

    # Requires canonical explicit paths and a private shared endpoint-lock root.
    # Invalid paths/permissions raise fixed refusal without creating directories.
    def check_paths
      [@path, @grant, @client, @runtime_dir].each do |path|
        raise Refused, "tunnel.path" unless path.is_a?(String) && path.start_with?("/") && File.expand_path(path) == path
      end
      raise Refused, "tunnel.path" unless File.realpath(@grant) == @grant && File.realpath(@client) == @client &&
        File.file?(@client) && File.executable?(@client) && File.realpath(@runtime_dir) == @runtime_dir &&
        File.directory?(@runtime_dir) && File.stat(@runtime_dir).uid == Process.uid &&
        (File.stat(@runtime_dir).mode & 0o077).zero?
    end

    # Refuses legacy/shared clients, including ones outside ACT's kernel lock.
    # Only executable names are inspected, never argv/environments or raw logs.
    # Unavailable inventory is unknown ownership, not permission to start.
    def inventory!
      output, error, status = Open3.capture3(clean_environment, "/bin/ps", "-axo", "comm=", unsetenv_others: true)
      raise Refused, "tunnel.ownership_unknown" unless status.success? && error.empty? && output.bytesize <= 1_048_576
      raise Refused, "tunnel.occupied" if output.lines.any? { |line| File.basename(line.strip) == "tunnel-client" }
      nil
    rescue SystemCallError
      raise Refused, "tunnel.ownership_unknown", cause: nil
    end

    # Returns only required local runtime settings; no credential, dotenv value,
    # worker policy or validator environment is inherited by default.
    def clean_environment
      ENVIRONMENT.to_h { |name| [name, ENV[name]] }.compact
    end

    # Writes session-specific data only, using the installed sample's supported
    # config contract. The fixed env trampoline removes client credentials before
    # Ruby/ACT starts the adapter. No saved connection/profile is changed.
    def write_config(tunnel_id)
      File.open(File.join(@path, "adapter-diagnostics.jsonl"), File::WRONLY | File::CREAT | File::EXCL, 0o600, &:fsync)
      environment = clean_environment
      command = ["/usr/bin/env", "-i", *environment.map { |name, value| "#{name}=#{value}" },
        RbConfig.ruby, File.expand_path("../../bin/agent-coding-tool", __dir__), "evidence", "serve", "--session", @path]
      configuration = { "config_version" => 1,
        "control_plane" => { "tunnel_id" => tunnel_id, "api_key" => "env:CONTROL_PLANE_API_KEY" },
        "mcp" => { "commands" => [{ "channel" => "main", "command" => Shellwords.join(command) }] },
        "health" => { "listen_addr" => "127.0.0.1:0", "url_file" => File.join(@path, "health-url") },
        "admin_ui" => { "open_browser" => false, "log_buffer_events" => 1 },
        "log" => { "level" => "warn", "format" => "struct-text", "file" => File::NULL },
        "tracing" => { "enabled" => false } }
      File.open(File.join(@path, "tunnel.json"), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(configuration))
        file.flush
        file.fsync
      end
    end

    # Writes a fixed bounded operator event, never raw client output or errors.
    # Returns nil; broken diagnostics cannot suppress independent cleanup.
    def observe(stage, reason)
      @err.puts "ACT_EVIDENCE_TUNNEL #{JSON.generate('stage' => stage, 'reason' => reason)}"
      @err.flush
      nil
    rescue IOError, SystemCallError
      nil
    end

    # Polls only the owned client's bounded loopback readiness surface. Responses
    # and exceptions are discarded; no proxy, redirects, secret or body logging.
    # The entire HTTP exchange has a 150ms bound, including trickled headers/body.
    # Returns true only for HTTP 200, false for unavailable/malformed readiness.
    def ready?
      path = File.join(@path, "health-url")
      return false unless File.exist?(path)
      raw = RunEvidenceStore.bytes(path, root: @path, private: true)
      return false unless raw.bytesize <= 128 && raw.strip.match?(/\Ahttp:\/\/127\.0\.0\.1:[1-9][0-9]{0,4}\/?\z/)
      uri = URI.parse(raw.strip)
      return false unless uri.port.between?(1, 65_535)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.open_timeout = http.read_timeout = http.write_timeout = 0.15
      http.max_retries = 0
      count = 0
      accepted = false
      Timeout.timeout(0.15) do
        http.request(Net::HTTP::Get.new("/readyz")) do |response|
          accepted = response.code == "200"
          response.read_body do |chunk|
            count += chunk.bytesize
            raise IOError if count > 4096
          end
        end
      end
      accepted
    rescue StandardError
      false
    end

    # Returns admission/controller/deadline state, retrying only session.busy for
    # at most one second. Other ledger failures raise and fail closed. The earliest
    # observed lease deadline is retained independently of subsequent lock access;
    # retries cannot renew it or hide expiry, interruption or controller EOF.
    def owner_status(watch, startup_deadline = nil)
      retry_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      loop do
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return "interrupted" if @interrupted
        return "controller_lost" if IO.select([watch], nil, nil, 0)
        return "expired" if @admission_deadline && (now >= @admission_deadline || Time.now.to_f >= @expires_at)
        return "deadline" if startup_deadline && now >= startup_deadline
        begin
          status = @session.status
          if status.fetch("status") == "active"
            @expires_at = [@expires_at || Float::INFINITY, status.fetch("expires_at")].min
            remaining = [@expires_at - Time.now.to_f, status.fetch("limits").fetch("seconds")].min
            @admission_deadline = [@admission_deadline || Float::INFINITY, now + remaining].min
            return "expired" if remaining <= 0
          end
          return status.fetch("status")
        rescue Refused => error
          raise unless error.message == "session.busy"
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise if now >= retry_deadline
          wait = [0.05, retry_deadline - now]
          wait << [@admission_deadline - now, 0].max if @admission_deadline
          wait << [startup_deadline - now, 0].max if startup_deadline
          IO.select([watch], nil, nil, wait.min)
        end
      end
    end

    # Independent owner watches controller EOF, durable stop/expiry and readiness.
    # Keeps its direct group leader unreaped until group cleanup to prevent PID
    # reuse. Client output is never persisted/captured; only fixed receipts remain.
    # Returns 0 for normal finite closure, 2 for startup/failure/unknown cleanup.
    def own(watch, key)
      stage, reason, cleanup, pid = "delivery", "client_start_failed", "not_started", nil
      @interrupted = false
      %w[INT TERM].each { |name| Signal.trap(name) { @interrupted = true } }
      begin
        current = owner_status(watch)
        if current != "active"
          stage, reason = "readiness", current
          return 2
        end
        environment = clean_environment.merge("CONTROL_PLANE_API_KEY" => key)
        pid = Process.spawn(environment, @client, "run", "--config", File.join(@path, "tunnel.json"),
          unsetenv_others: true, pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL, chdir: @path)
        environment.clear
        key = nil
        stage, reason = "readiness", "deadline"
        startup_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STARTUP_SECONDS
        was_ready = false
        loop do
          IO.select([watch], nil, nil, 0.1)
          status = owner_status(watch, was_ready ? nil : startup_deadline)
          if status != "active"
            stage = was_ready ? "lifecycle" : "readiness"
            reason = status
            break
          end
          available = ready?
          status = owner_status(watch, was_ready ? nil : startup_deadline)
          if status != "active"
            stage, reason = was_ready ? "lifecycle" : "readiness", status
            break
          end
          if available && !was_ready
            was_ready = true
            @out.puts JSON.generate("status" => "ready", "meaning" => "client readyz; retrieval and hosted acceptance remain separate")
            @out.flush
            observe("readiness", "ready")
          elsif was_ready && !available
            stage, reason = "readiness", "lost"
            break
          elsif !was_ready && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= startup_deadline
            break
          end
        end
      rescue StandardError
        # Never serialize exceptions: child spawn/HTTP/platform errors can carry
        # argv, environment values or client responses. Preserve the fixed stage.
        reason = "failed"
      ensure
        observe(stage, reason)
        admission_stop = stop_admission
        cleanup = cleanup_group(pid) if pid
        receipt = { "stage" => stage, "reason" => reason, "local_cleanup" => cleanup,
          "admission_stop" => admission_stop, "retrieval" => "not_attested",
          "hosted_shutdown" => "not_observed", "saved_settings" => "not_modified" }
        temporary = File.join(@path, "tunnel-result.tmp")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.generate(receipt))
          file.flush
          file.fsync
        end
        File.rename(temporary, File.join(@path, "tunnel-result.json"))
        File.open(@path, File::RDONLY, &:fsync)
        observe("cleanup", cleanup)
        @endpoint_lock.close
        watch.close
      end
      was_ready && stage == "lifecycle" && admission_stop == "stopped" &&
        %w[owned_groups_signaled_and_reaped owned_groups_terminal_and_reaped].include?(cleanup) ? 0 : 2
    end

    # Stop itself bounds ledger lock contention to the existing one second.
    # Returns a fixed result; stop failure cannot suppress process cleanup.
    def stop_admission
      @session.stop
      "stopped"
    rescue StandardError
      "blocked"
    end

    # Signals only the retained unreaped direct group leader created above.
    # Unknown ownership/permission failures never authorize other process signals.
    # Returns a fixed result; native descendant absence still needs host evidence.
    def cleanup_group(pid)
      result = "unknown"
      group = begin
        Process.getpgid(pid)
      rescue Errno::ESRCH
        # Darwin can hide an unreaped zombie from getpgid. Qualify only the
        # retained leader's currently observed zombie-only group; no new signals.
        return terminal_group?(pid) ? "owned_groups_terminal_and_reaped" : "blocked"
      end
      if group == pid
        Process.kill("TERM", -pid)
        IO.select(nil, nil, nil, 0.05)
        Process.kill("KILL", -pid)
        result = "owned_groups_signaled_and_reaped"
      end
      result
    rescue Errno::ESRCH
      "owned_groups_signaled_and_reaped"
    rescue Errno::EPERM
      terminal_group?(pid) ? "owned_groups_terminal_and_reaped" : "blocked"
    rescue SystemCallError
      "blocked"
    ensure
      # Direct child ownership is retained even if group signaling is denied.
      # Damage containment does not turn a blocked group result into PASS.
      begin
        Process.kill("KILL", pid)
      rescue SystemCallError
        nil
      end
      Process.waitpid(pid)
    end

    # Qualifies only Darwin ESRCH/EPERM cases with a zombie-only owned group. Numeric
    # native inventory must include the retained group leader and no live members.
    # Failed/ambiguous observations return false and authorize no new signals.
    def terminal_group?(pid)
      output, error, status = Open3.capture3(clean_environment, "/bin/ps", "-axo", "pid=,pgid=,stat=", unsetenv_others: true)
      return false unless status.success? && error.empty? && output.bytesize <= 1_048_576
      members = []
      output.lines.each do |line|
        fields = line.split
        return false unless fields.length == 3 && fields.take(2).all? { |field| field.match?(/\A[0-9]+\z/) }
        members << fields if fields[1].to_i == pid
      end
      members.any? { |fields| fields[0].to_i == pid } && members.all? { |fields| fields[2].start_with?("Z") }
    rescue StandardError
      false
    end
  end
end
