# frozen_string_literal: true

require_relative "evidence_tunnel"

module AgentCodingTool
  # Local opt-in commands for one owner/data-root/endpoint. Settings contain
  # paths and audience facts only; credentials are resolved by EvidenceTunnel.
  class ShareController
    Refused = RunEvidenceReader::Refused
    SETTINGS = %w[env-file client runtime-dir account workspace endpoint].freeze

    # Binds the canonical data root and consoles. No I/O/mutation on construction.
    def initialize(data_root, out:, err:)
      @data, @out, @err = File.realpath(data_root), out, err
      @root = "#{@data}-sharing"
    end

    # Explicit one-time setup; accepts existing canonical local runtime/client
    # paths and whole personal Work workspace facts. Does not edit hosted or
    # saved client settings; replacement requires separate local removal/review.
    def setup(options)
      raise Refused, "share.setup_fields" unless options.keys.sort == SETTINGS.sort
      %w[env-file client runtime-dir].each do |name|
        path = options.fetch(name)
        raise Refused, "share.setup_path" unless path.start_with?("/") && File.realpath(path) == path
      end
      raise Refused, "share.setup_path" unless File.basename(options["env-file"]) == ".env" && File.file?(options["env-file"]) &&
        File.stat(options["env-file"]).uid == Process.uid && File.directory?(options["runtime-dir"]) &&
        File.stat(options["runtime-dir"]).uid == Process.uid && (File.stat(options["runtime-dir"]).mode & 0o077).zero?
      raise Refused, "share.setup_client" unless File.file?(options["client"]) && File.executable?(options["client"])
      raise Refused, "share.setup_endpoint" unless options["endpoint"].match?(/\Atunnel_[A-Za-z0-9]+\/main\z/)
      %w[account workspace].each do |field|
        raise Refused, "share.setup_audience" unless options[field].match?(/\A[A-Za-z0-9@_. -]{1,128}\z/)
      end
      create_root
      locked do
        write_once(File.join(@root, "settings.json"), options.merge("data_root" => @data, "owner" => Process.uid))
      end
      { "status" => "configured", "audience" => audience(options) }
    end

    # Starts a fresh foreground admission with zero task scopes. The root lock
    # serializes publication of its unique identity; it is released before run.
    # Existing active/starting/unknown admissions refuse rather than being reused.
    def tunnel(minutes)
      settings = settings!
      controller = controller_lock
      path = grant_path = nil
      locked do
        pointer = File.join(@root, "active.json")
        if File.exist?(pointer)
          previous_pointer = pointer!
          unless previous_pointer["status"] == "stopped_before_admission"
            previous = active
            status = previous.status(wait: 1)
            raise Refused, "share.tunnel_exists" if status["status"] == "active"
          end
        end
        token = SecureRandom.hex(16)
        path = File.join(@root, "session-#{token}")
        grant_path = File.join(@root, "grant-#{token}.json")
        grant = { "schema" => "agent-coding-tool-task-sharing/v2", "approved" => true,
          "session_path" => path, "data_root" => @data, "tasks" => [], "artifacts" => RunEvidenceReader::ARTIFACTS,
          "transport" => audience(settings), "limits" => EvidenceSession::LIMITS.merge("seconds" => minutes * 60) }
        write_once(grant_path, grant)
        # A reserved starting identity is intentionally fail-closed if startup
        # dies before admission. No second tunnel silently assumes ownership.
        EvidenceSession.write(@root, { "session" => path })
        File.rename(File.join(@root, "state.json"), pointer)
        File.open(@root, File::RDONLY, &:fsync)
      end
      @out.puts JSON.generate("audience" => audience(settings), "minutes" => minutes, "tasks" => [],
        "expiry" => "nonrenewable; task leases end no later than tunnel expiry")
      @out.flush
      EvidenceTunnel.new(session: path, grant: grant_path, env_file: settings.fetch("env-file"),
        client: settings.fetch("client"), runtime_dir: settings.fetch("runtime-dir"), out: @out, err: @err).run
    ensure
      controller&.close
    end

    # Returns status or permanently stops the current admission. No PID signaling,
    # automatic replacement, renewal, hosted change or lifecycle mutation occurs.
    def control(action)
      settings!
      begin
        session = active
      rescue Refused
        raise unless action == "stop"
        controller = controller_lock
        locked do
          pointer = pointer!
          raise Refused, "share.session" unless pointer["session"].is_a?(String) && File.dirname(pointer["session"]) == @root &&
            !File.exist?(File.join(pointer["session"], "state.json"))
          EvidenceSession.write(@root, pointer.merge("status" => "stopped_before_admission"))
          File.rename(File.join(@root, "state.json"), File.join(@root, "active.json"))
        end
        return { "status" => "stopped_before_admission", "retrieval" => "no admission" }
      ensure
        controller&.close
      end
      result = action == "stop" ? session.stop : session.status(wait: 1)
      session.transaction(wait: 1) do |state|
        result.merge("tasks" => state.fetch("scopes").transform_values { |scope| scope.slice("generation", "expires_at", "revoked") },
          "audience" => state.dig("grant", "transport"))
      end
    end

    # Grants/revokes exactly one registered task in the ready current tunnel.
    # Returns promptly; validates duration before any mutation in the caller.
    def task(id, minutes:, revoke: false)
      settings!
      active.share_task(id, seconds: minutes * 60, revoke: revoke)
    end

    private

    # Holds startup/controller identity across the foreground owner process. A
    # kernel-released lock permits explicit recovery of an unadmitted failed
    # startup, without historical PID signaling or replacing an active tunnel.
    def controller_lock
      file = File.open(File.join(@root, "controller"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
      unless file.stat.file? && file.stat.uid == Process.uid && (file.stat.mode & 0o077).zero? && file.flock(File::LOCK_EX | File::LOCK_NB)
        file.close
        raise Refused, "share.tunnel_exists"
      end
      file
    end

    # Formats explicit setup facts; manager is an adapter binding label, never
    # authenticated conversation identity. Returns the existing transport shape.
    def audience(settings)
      settings.slice("account", "workspace", "endpoint").merge("manager" => "task-sharing-v2", "audience" => "whole-workspace")
    end

    # Creates only a private canonical sibling root and lock; unsafe ancestry,
    # foreign ownership and permissions refuse. Never repairs unknown settings.
    def create_root
      Dir.mkdir(@root, 0o700) unless File.exist?(@root) || File.symlink?(@root)
      check_root
      File.open(File.join(@root, "lock"), File::WRONLY | File::CREAT | File::EXCL, 0o600, &:fsync) unless File.exist?(File.join(@root, "lock"))
    end

    # Checks setup directory identity without exposing private paths on errors.
    def check_root
      raise Refused, "share.setup_required" unless File.directory?(@root) && File.realpath(@root) == @root &&
        File.stat(@root).uid == Process.uid && (File.stat(@root).mode & 0o077).zero?
    end

    # Serializes local startup/setup; lock acquisition is bounded to one second.
    # Changes to task scopes use the separate shared admission transaction lock.
    def locked
      RunEvidenceStore.bytes(File.join(@root, "lock"), root: @root, private: true)
      File.open(File.join(@root, "lock"), File::RDWR | File::NOFOLLOW) do |lock|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        until lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise Refused, "share.busy" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          IO.select(nil, nil, nil, 0.01)
        end
        yield
      end
    end

    # Loads existing explicit setup and verifies its owner/root binding. Missing
    # facts require the supported setup command, never a historical grant guess.
    def settings!
      check_root
      result = RunEvidenceStore.parse(RunEvidenceStore.bytes(File.join(@root, "settings.json"), root: @root, private: true))
      raise Refused, "share.settings" unless result.is_a?(Hash) && result.keys.sort == (SETTINGS + %w[data_root owner]).sort &&
        result["data_root"] == @data && result["owner"] == Process.uid && SETTINGS.all? { |key| result[key].is_a?(String) }
      result
    end

    # Resolves only the published current session under this canonical root.
    # Unknown/missing/ambiguous identity refuses with no fallback or PID lookup.
    def active
      pointer = pointer!
      path = pointer.fetch("session")
      raise Refused, "share.session" unless path.is_a?(String) && File.dirname(path) == @root &&
        File.basename(path).match?(/\Asession-[0-9a-f]{32}\z/)
      session = EvidenceSession.new(path)
      session.transaction(wait: 1) do |state|
        raise Refused, "share.session" unless session.sharing?(state) && state.dig("grant", "data_root") == @data &&
          state.dig("grant", "transport") == audience(settings!)
      end
      session
    end

    # Checks the current pointer's closed identity/status shape. Unknown or
    # tampered startup ownership cannot become permission for a replacement.
    def pointer!
      pointer = RunEvidenceStore.parse(RunEvidenceStore.bytes(File.join(@root, "active.json"), root: @root, private: true))
      raise Refused, "share.session" unless pointer.is_a?(Hash) && (pointer.keys - %w[session status]).empty? &&
        (!pointer.key?("status") || pointer["status"] == "stopped_before_admission") &&
        pointer["session"].is_a?(String) && File.dirname(pointer["session"]) == @root &&
        File.basename(pointer["session"]).match?(/\Asession-[0-9a-f]{32}\z/)
      pointer
    end

    # Persists an exclusive private settings/grant file with directory sync.
    # Existing files and filesystem errors propagate without overwriting evidence.
    def write_once(path, value)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        file.write(JSON.generate(value))
        file.flush
        file.fsync
      end
      File.open(@root, File::RDONLY, &:fsync)
    end
  end
end
