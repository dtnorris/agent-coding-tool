# frozen_string_literal: true

require "optparse"
require "io/console"
require "time"
require "json"
require "shellwords"

module AgentCodingTool
  class CLI
    STATUS_ORDER = {
      "COMPLETE" => 0,
      "CANDIDATE" => 10,
      "NEEDS_JUDGMENT" => 20,
      "IN_FLIGHT" => 30,
      "IN_FLIGHT_STALE" => 35,
      "READY" => 40,
      "PREPARED" => 50,
      "STALE_CANDIDATE" => 60,
      "STALE" => 70,
      "FAILED" => 80,
      "BLOCKED" => 100,
      "ICEBOX" => 110
    }.freeze
    STATUS_COLORS = {
      "COMPLETE" => 32,
      "IN_FLIGHT" => 36,
      "READY" => 92,
      "PREPARED" => 34,
      "CANDIDATE" => 33,
      "NEEDS_JUDGMENT" => 33,
      "STALE_CANDIDATE" => 31,
      "STALE" => 31,
      "FAILED" => 31,
      "BLOCKED" => 31
    }.freeze
    DEPENDENCY_REASON_PREFIX = "dependencies incomplete: "
    READ_ONLY_FRESHNESS_REASON_PREFIX =
      "read-only pushed branch changed; refresh and reconcile materially affected findings before finalizing: "
    READY_DISPLAY_LIMIT = 6
    READY_FAMILY_LIMIT = 3
    BLOCKED_DISPLAY_LIMIT = 3
    DEFAULT_DASHBOARD_WIDTH = 100
    ANSI_RESET = "\e[0m"
    ANSI_SEQUENCE = /\e\[[0-?]*[ -\/]*[@-~]/
    DISPLAY_TOKEN = /#{ANSI_SEQUENCE}|\X/
    NEXT_JSON_VERSION = "agent-coding-tool-next/v0.1"

    def self.run(argv, root: Dir.pwd, out: $stdout, err: $stderr, data_root: nil, transport: nil)
      new(root: root, out: out, err: err, data_root: data_root, transport: transport).run(argv)
    end

    def self.default_data_root(root, env: ENV)
      override = env["AGENT_CODING_TOOL_DATA_DIR"]
      return File.expand_path(override) if override && !override.empty?

      File.expand_path("../#{File.basename(root)}-data", root)
    end

    # A host may embed a qualified NativePilotExecutor for the bounded session
    # slice. CLI/model arguments and environment flags cannot install one.
    def initialize(root:, out:, err:, data_root: nil, terminal_width: nil, transport: nil, input: $stdin, manager_runtime: nil, native_pilot: nil)
      @root = root
      @out = out
      @err = err
      @data_root = data_root || self.class.default_data_root(root)
      @terminal_width = terminal_width
      @input = input
      @manager_runtime = manager_runtime || native_pilot&.manager_adapter
      @native_pilot = native_pilot
      @transport = transport || NativeCommandTransport.new(interrupt_out: out, interrupt_err: err)
    end

    def run(argv)
      command = argv.shift
      case command
      when "implementation" then @out.puts JSON.generate(Bootstrap::COMPOSITION)
      when "share" then return share_command(argv)
      when "apply" then return apply_command(argv)
      when "manage" then return manage_command(argv)
      when "manager" then return manager_command(argv)
      when "evidence" then return evidence_command(argv)
      when "status" then status_command(argv)
      when "next" then next_command(argv)
      when "external" then external_command(argv)
      when "icebox" then icebox_command(argv)
      when "unicebox" then icebox_command(argv, restore: true)
      when "prepare" then prepare_command(argv)
      when "start" then start_command(argv)
      when "launch" then return launch_command(argv)
      when "deliver" then return deliver_command(argv)
      when "checkpoint" then return checkpoint_command(argv)
      when "worktrees" then return worktree_command(argv, cleanup: false)
      when "cleanup" then worktree_command(argv, cleanup: true)
      when "abandon-preflight" then abandon_preflight_command(argv)
      when "close-attempt" then close_attempt_command(argv)
      when "received" then received_command(argv)
      when "finish" then finish_command(argv)
      when "record" then record_command(argv)
      when "reset" then reset_command(argv)
      when "publish" then publish_command(argv)
      when "help", nil then help
      else
        raise Error, "unknown command: #{command}"
      end
      0
    rescue AgentCodingTool::Error, OptionParser::ParseError => e
      @err.puts "ERROR: #{e.message}"
      2
    end

    private

    # Uses a separate advisory coordinator only until this dispatch returns or
    # raises. Reusing a CLI instance never carries cached inputs into a writer
    # or a later command. Test coordinators without a view retain their API.
    def with_status_read_view
      original = coordinator
      @coordinator = original.respond_to?(:read_view) ? original.read_view : original
      yield
    ensure
      @coordinator = original
    end

    # Hosts a two-turn observation-only review through an ACT-installed runtime.
    # The runtime is a trusted embedding seam, never a CLI/model-issued grant.
    # Returns JSON or raises Error on malformed identities, evidence or missing
    # qualification. Existing manage reminder and worker launch stay unchanged.
    def manager_command(argv)
      require_relative "manager_session"
      action = argv.shift
      options = {}
      parser = OptionParser.new do |opts|
        opts.on("--id ID") { |value| options[:manager] = value }
        opts.on("--task TASK") { |value| options[:task_id] = value }
        opts.on("--attempt N", Integer) { |value| options[:attempt] = value }
        opts.on("--invocation ID") { |value| options[:invocation_id] = value }
        opts.on("--session ID") { |value| options[:session_id] = value }
      end
      parser.require_exact = true
      parser.parse!(argv)
      expected = { "start" => [:manager], "bind" => %i[task_id attempt invocation_id session_id], "review" => [:session_id] }
      raise Error, "usage: act manager {start TASK --id ID|bind ID --task TASK --attempt N --invocation ID --session ID|review ID --session ID}" unless
        argv.length == 1 && expected.key?(action) && options.keys.sort == expected.fetch(action).sort
      raise InvalidState, "manager: live runtime unavailable; host must qualify and install a confined independent lease executor; no inference started" unless @manager_runtime
      manager = ManagerSession.new(data_root: @data_root, runtime: @manager_runtime)
      result = case action
               when "start" then manager.start(argv.first, **options)
               when "bind" then manager.bind(argv.first, options.transform_keys(&:to_s))
               when "review" then manager.review(argv.first, session: options.fetch(:session_id))
               end
      @out.puts JSON.generate(result)
      0
    rescue SystemCallError, RunEvidenceReader::Refused, JSON::ParserError, KeyError, TypeError => error
      raise InvalidState, "manager: unavailable or malformed input (#{error.class})", cause: nil
    end

    # Public finite sharing opt-in; strict duration parsing precedes setup,
    # grant or tunnel mutation. Returns a fixed safe actionable refusal on error.
    def share_command(argv)
      require_relative "share_controller"
      action = argv.shift
      if action.nil? || %w[help --help].include?(action)
        @out.puts "share tunnel [--min N] (default 60); share TASK [PATH_TO_ZIP] [--min N] (default 30); maximum 60 minutes"
        @out.puts 'Example: act share TASK "./completed results.zip"; ZIP maximum 4 MiB; externally supplied evidence, not verified execution.'
        @out.puts "share status; share revoke TASK; share stop. Delivered bytes cannot be recalled."
        @out.puts "share source grant ID --code-root PATH --root REPOSITORY [--min N]; share source revoke ID"
        @out.puts "share setup --env-file PATH --client PATH --runtime-dir PATH --account ACCOUNT --workspace WORKSPACE --endpoint tunnel_ID/main"
        return 0
      end
      return source_share_command(argv) if action == "source"
      options = {}
      parser = OptionParser.new do |opts|
        (ShareController::SETTINGS + ["min"]).each { |name| opts.on("--#{name} VALUE") { |value| options[name] = value } }
      end
      parser.require_exact = true
      parser.parse!(argv)
      minutes = options.fetch("min", action == "tunnel" ? "60" : "30")
      raise RunEvidenceReader::Refused, "share.minutes" unless minutes.match?(/\A[1-9][0-9]?\z/) && minutes.to_i <= 60
      if action == "setup"
        raise RunEvidenceReader::Refused, "share.fields" unless argv.empty? && options.keys.sort == ShareController::SETTINGS.sort
      else
        raise RunEvidenceReader::Refused, "share.fields" unless (options.keys - ["min"]).empty? &&
          (!%w[status stop revoke].include?(action) || options.empty?) &&
          (action == "revoke" ? argv.length == 1 : %w[status stop tunnel].include?(action) ? argv.empty? : argv.length <= 1)
      end
      controller = ShareController.new(@data_root, out: @out, err: @err)
      result = case action
               when "setup" then controller.setup(options)
               when "tunnel" then return controller.tunnel(minutes.to_i)
               when "status", "stop" then controller.control(action)
               when "revoke" then controller.task(argv.first, minutes: 30, revoke: true)
               else argv.empty? ? controller.task(action, minutes: minutes.to_i) : controller.task(action, minutes: minutes.to_i, zip: argv.first)
               end
      @out.puts JSON.generate(result)
      0
    rescue RunEvidenceReader::Refused, TunnelCredential::Refused, SystemCallError, JSON::ParserError, KeyError, ArgumentError, OptionParser::ParseError => error
      case error.message
      when "import.size" then @err.puts "ERROR: ZIP exceeds the supported 4 MiB limit; no import shared."
      when "import.storage_limit" then @err.puts "ERROR: ZIP admission storage exhausted (64 artifacts / 64 MiB); no import shared."
      when "import.admission_budget" then @err.puts "ERROR: Insufficient remaining tunnel request/wire/decoded budget for ZIP retrieval; no import shared."
      end
      @err.puts "ERROR: share refused; use act share help, act share setup for missing facts, or act share tunnel for a new ready tunnel; inspect act share status before retrying."
      2
    end

    # Parses local source consent separately from task sharing. Exact fields and
    # finite minutes are validated before admission; errors use share's fixed
    # refusal path. Returns zero after printing local grant/revocation metadata.
    def source_share_command(argv)
      action, repository = argv.shift(2)
      options = {}
      parser = OptionParser.new do |opts|
        %w[code-root root min].each { |name| opts.on("--#{name} VALUE") { |value| options[name] = value } }
      end
      parser.require_exact = true
      parser.parse!(argv)
      minutes = options.fetch("min", "30")
      raise RunEvidenceReader::Refused, "source.fields" unless argv.empty? && repository &&
        ((action == "grant" && (options.keys - %w[code-root root min]).empty? && options.key?("code-root") && options.key?("root")) ||
          (action == "revoke" && options.empty?)) && minutes.match?(/\A[1-9][0-9]?\z/) && minutes.to_i <= 60
      result = ShareController.new(@data_root, out: @out, err: @err).source(repository,
        code_root: options["code-root"], root: options["root"], minutes: minutes.to_i, revoke: action == "revoke")
      @out.puts JSON.generate(result)
      0
    end

    # Copies a source-bound reminder through macOS pbcopy, or writes only its
    # text with --stdout. No task/repository state is changed. Parsing/source
    # errors raise Error; failed/missing clipboard commands return nonzero with
    # an explicit stdout recovery command, never a false copy-success message.
    def manage_command(argv)
      stdout = false
      parser = OptionParser.new do |opts|
        opts.on("--stdout", "print the reminder without changing the clipboard") { stdout = true }
      end
      parser.require_exact = true
      parser.parse!(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool manage TASK [--stdout]" unless id && argv.empty?

      require_relative "manager_reminder"
      reminder = ManagerReminder.render(@data_root, id)
      if stdout
        @out.write(reminder)
        return 0
      end
      result = @transport.call(["pbcopy"], input: reminder, timeout: 5)
      unless result.success?
        @err.puts "ERROR: manage: pbcopy failed (status #{result.shell_status}); use act manage #{id} --stdout"
        return result.shell_status
      end
      @out.puts "Copied manager reminder for #{id}; paste it above your update."
      0
    rescue SystemCallError, IOError, Timeout::Error => error
      @err.puts "ERROR: manage: clipboard unavailable (#{error.class}); use act manage #{id} --stdout"
      2
    end

    # Opens finite operator-granted read sessions; select/read use the same closed
    # reader as MCP. Returns zero or a fixed refusal, never executes evidence.
    def evidence_command(argv)
      action = argv.shift
      return register_evidence_command(argv) if action == "register"
      return capture_followup_command(argv) if action == "capture"
      return register_followup_command(argv) if action == "register-followup"
      require_relative "evidence_tunnel" if action == "open"
      options = {}
      parser = OptionParser.new do |opts|
        %w[session grant task invocation codex-session handle revision artifact env-file client runtime-dir].each do |name|
          opts.on("--#{name} VALUE") { |value| options[name] = value }
        end
        %w[attempt offset length].each do |name|
          opts.on("--#{name} NUMBER", Integer) { |value| options[name] = value }
        end
      end
      parser.require_exact = true
      parser.parse!(argv)
      allowed = case action
                when "open" then %w[session grant env-file client runtime-dir]
                when "start" then %w[session grant]
                when "serve", "status", "stop" then %w[session]
                when "select" then %w[session task attempt invocation codex-session]
                when "read" then %w[session task attempt invocation codex-session handle revision artifact offset length]
                else []
                end
      raise RunEvidenceReader::Refused, "cli.fields" unless argv.empty? && !allowed.empty? && options.keys.sort == allowed.sort
      if action == "open"
        return EvidenceTunnel.new(session: options.fetch("session"), grant: options.fetch("grant"),
          env_file: options.fetch("env-file"), client: options.fetch("client"), runtime_dir: options.fetch("runtime-dir"),
          out: @out, err: @err).run
      end
      if action == "start"
        result = EvidenceSession.start(options.fetch("session"), options.fetch("grant"))
      else
        session = EvidenceSession.new(options.fetch("session"))
        case action
        when "serve"
          sink = @err
          diagnostic_path = File.join(File.expand_path(options.fetch("session")), "adapter-diagnostics.jsonl")
          if File.exist?(diagnostic_path) || File.symlink?(diagnostic_path)
            RunEvidenceStore.bytes(diagnostic_path, root: File.expand_path(options.fetch("session")), private: true)
            sink = File.open(diagnostic_path, File::WRONLY | File::APPEND | File::NOFOLLOW)
          end
          begin
            return EvidenceAdapter.new(session, err: sink).serve($stdin, @out) || 0
          ensure
            sink.close unless sink.equal?(@err)
          end
        when "status" then result = session.status
        when "stop" then result = session.stop
        else
          session.transaction do |state|
            raise RunEvidenceReader::Refused, "share.use_tool" if session.sharing?(state)
          end
          request = options.reject { |key, _value| key == "session" }.transform_keys do |key|
            { "task" => "task_id", "invocation" => "invocation_id", "codex-session" => "session_id" }.fetch(key, key)
          end.merge("operation" => action)
          session.admit
          session.charge(wire: JSON.generate(request).bytesize)
          result = session.call(request)
          session.charge(wire: JSON.generate(result).bytesize, decoded: result.fetch("data", "").unpack1("m0").bytesize)
        end
      end
      @out.puts JSON.generate(result)
      0
    rescue TunnelCredential::Refused => error
      @err.puts "ERROR: #{error.message}; check the explicit canonical ACT .env or nonblank OPENAI_TUNNEL_KEY; no secret prompt"
      2
    rescue RunEvidenceReader::Refused, SystemCallError, JSON::ParserError, ArgumentError, OptionParser::ParseError => error
      if action == "open"
        reason = %w[tunnel.session_reused tunnel.endpoint tunnel.occupied tunnel.path tunnel.ownership_unknown].include?(error.message) ? error.message : "admission.refused"
        @err.puts "ERROR: #{reason}; check endpoint exclusivity, private grant/paths and native process permissions; use a new approved session after admission"
        return 2
      end
      detail = error.is_a?(RunEvidenceReader::Refused) && error.message == "session.busy" ? " (session.busy)" : ""
      @err.puts "ERROR: evidence session refused#{detail}; check private grant, exact run identity and session status"
      2
    end

    # Explicitly wraps one independently launched codex exec, then registers its
    # captured bytes for the named task. The child never receives ACT authority.
    def capture_followup_command(argv)
      separator = argv.index("--")
      raise RunEvidenceReader::Refused, "followup.command" unless separator && separator.positive?
      options, command = argv.take(separator), argv.drop(separator + 1)
      parser = OptionParser.new do |opts|
        opts.on("--task TASK") { |value| @followup_task = value }
      end
      parser.require_exact = true
      parser.parse!(options)
      raise RunEvidenceReader::Refused, "followup.fields" unless options.empty? && @followup_task && command.any?
      status = ExternalFollowup.new(@data_root).capture(@followup_task, command, out: @out, err: @err)
      status&.exitstatus || (status&.termsig && 128 + status.termsig) || 2
    rescue RunEvidenceReader::Refused, SystemCallError, OptionParser::ParseError
      @err.puts "ERROR: follow-up capture refused; check task, codex exec argv, private storage and capture receipt."
      2
    ensure
      @followup_task = nil
    end

    # Publishes an interrupted capture only after its exact receipt digest and
    # private task-bound source have been verified.
    def register_followup_command(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.on("--task TASK") { |value| options["task"] = value }
        opts.on("--invocation ID") { |value| options["invocation"] = value }
        opts.on("--sha256 HASH") { |value| options["sha256"] = value }
      end
      parser.require_exact = true
      parser.parse!(argv)
      raise RunEvidenceReader::Refused, "followup.fields" unless argv.empty? && options.keys.sort == %w[invocation sha256 task]
      result = ExternalFollowup.new(@data_root).register(options.fetch("task"), options.fetch("invocation"), options.fetch("sha256"))
      @out.puts JSON.generate("task_id" => result.fetch("task_id"), "source" => result.fetch("source"),
        "invocation_id" => result.fetch("invocation_id"), "capture_status" => result.fetch("status"), "outcome" => result.fetch("outcome"))
      0
    rescue RunEvidenceReader::Refused, SystemCallError, OptionParser::ParseError
      @err.puts "ERROR: follow-up registration refused; check task, exact invocation, receipt digest and completed capture."
      2
    end

    # Host-owned bounded adoption of a worker export package. Requires all exact
    # run identities and the package digest; no global-latest or directory scan.
    def register_evidence_command(argv)
      options = {}
      parser = OptionParser.new do |opts|
        %w[task invocation codex-session package sha256].each { |name| opts.on("--#{name} VALUE") { |value| options[name] = value } }
        opts.on("--attempt NUMBER", Integer) { |value| options["attempt"] = value }
      end
      parser.require_exact = true
      parser.parse!(argv)
      raise RunEvidenceReader::Refused, "registration.fields" unless argv.empty? && options.keys.sort == %w[task invocation codex-session package sha256 attempt].sort
      identity = { "task_id" => options["task"], "attempt" => options["attempt"], "invocation_id" => options["invocation"], "session_id" => options["codex-session"] }
      @out.puts JSON.generate(RunEvidenceStore.new(@data_root).register(identity, options["package"], options["sha256"]))
      0
    rescue RunEvidenceReader::Refused, SystemCallError, JSON::ParserError, OptionParser::ParseError
      @err.puts "ERROR: evidence registration refused; check exact run, recorded fixture, package digest and bounded regular owned files."
      2
    end

    # Applies one downloaded JSON proposal with independent terminal confirmations;
    # returns the handler status. Invalid CLI arguments raise without mutation.
    def apply_command(argv)
      raise Error, "usage: agent-coding-tool apply FILE.json" unless argv.length == 1 && !argv.first.start_with?("-")
      ApplyHandoff.new(config: Config.load(File.join(@data_root, "config.yml")), out: @out, err: @err, transport: @transport).run(argv.first)
    end

    # Public explicit observation commands. Show is read-only; report/end acquire
    # the existing shared reservation lock internally and print private JSON.
    # Invalid arguments or private evidence raise Error without payload echoes.
    def external_command(argv)
      action = argv.shift
      id = argv.shift
      raise Error, "usage: external {report|show|end} TASK ..." unless %w[report show end].include?(action) && id
      options = {}
      observation_id = argv.shift if action == "end"
      parser = OptionParser.new do |opts|
        if action == "report"
          %w[reporter kind identifier note reference].each do |field|
            opts.on("--#{field} TEXT") { |value| options[field.to_sym] = value }
          end
          opts.on("--scope-complete", "operator reports a complete writable repository set") { options[:scope_complete] = true }
          opts.on("--write-repository REMOTE,BRANCH", "additional reported writable authority; repeatable") do |value|
            (options[:authorities] ||= []) << value.split(",", 2)
          end
        elsif action == "end"
          opts.on("--disposition VALUE", ExternalActivity::DISPOSITIONS) { |value| options[:disposition] = value }
        end
      end
      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError
        raise Error, "external activity: invalid options (private input omitted)", cause: nil
      end
      raise Error, "external activity: unexpected arguments" unless argv.empty?
      store = coordinator.external_activity
      result = case action
               when "show" then store.show(id)
               when "report"
                 raise Error, "external report requires --reporter and --kind" unless options[:reporter] && options[:kind]
                 store.report(id, **options)
               when "end"
                 raise Error, "external end requires observation ID and --disposition" unless observation_id && options[:disposition]
                 store.end_activity(id, observation_id, **options)
               end
      @out.puts JSON.pretty_generate(result.merge("trust" => {
        "reporter" => "operator-reported", "execution" => "unmanaged; unauthorized by ACT",
        "isolation" => "unverified", "containment" => "unverified", "liveness" => "unknown",
        "closure" => "operator report; not proof of termination or candidate quality" }))
    end

    # Parses explicit deferral/restoration, printing the resulting designation.
    # Invalid arguments, ineligible state or unsafe/busy locks raise Error.
    def icebox_command(argv, restore: false)
      options = {}
      parser = OptionParser.new do |opts|
        lifecycle_force_options(opts, options)
      end
      parser.require_exact = true
      parser.parse!(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool #{restore ? 'unicebox TASK' : 'icebox TASK [--reason TEXT]'}" unless id && argv.empty?

      if restore
        state = coordinator.unicebox(id, **options)
        display_override(state) if options[:force]
        @out.puts "Restored #{id}; eligibility will be recomputed from lifecycle and dependencies"
      else
        state = coordinator.icebox(id, **options)
        display_override(state) if options[:force]
        @out.puts "Deferred #{id}: ICEBOX; restore with act unicebox #{id}"
      end
    end

    def deliver_command(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool deliver TASK" unless id&.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) && argv.empty?
      root = File.join("#{@data_root}-runs", id)
      raise InvalidState, "#{id}: no run evidence" unless File.directory?(root) && !File.symlink?(root)
      dirs = IncidentalMetadata.children(root).map { |entry| File.join(root, entry) }.select { |path| File.directory?(path) }
      raise InvalidState, "#{id}: ambiguous run evidence" unless dirs.length == 1
      result = DeliveryManager.new(data_root: @data_root, coordinator: coordinator, transport: @transport).deliver(id, run_dir: dirs.first)
      urls = result["prs"] ? result.fetch("prs").values.map { |pr| pr.fetch("url") } :
                               [result.fetch("pr").fetch("url")]
      @out.puts "Draft PR#{result["prs"] ? "s" : ""}: #{urls.join(', ')} (CANDIDATE)"
      0
    end

    # Dispatches explicit checkpoint actions, including read-only historical
    # verification and independent reconstruction. Invalid options/evidence raise
    # Error; successful actions print JSON and return zero.
    def checkpoint_command(argv)
      action = argv.shift
      id = argv.shift
      unless %w[export record verify gate recover].include?(action) && id&.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
        raise Error, "usage: agent-coding-tool checkpoint {export|record|verify|gate|recover} TASK ..."
      end
      options = {}
      parser = OptionParser.new do |opts|
        opts.on("--workspace PATH") { |value| options[:workspace] = value }
        opts.on("--artifact PATH") { |value| options[:artifact] = value }
        opts.on("--base SHA") { |value| options[:base] = value }
        opts.on("--remote NAME") { |value| options[:remote] = value }
        opts.on("--repository NAME") { |value| options[:repository] = value }
        opts.on("--focused PATH") { |value| options[:focused] = value }
        opts.on("--destination PATH") { |value| options[:destination] = value }
        opts.on("--confirm-disconnected") { options[:confirm_disconnected] = true }
        opts.on("--attempt NUMBER", Integer) { |value| options[:attempt] = value }
        opts.on("--requested-seed NUMBER", Integer) { |value| options[:seed] = value }
        opts.on("--requested-selection TEXT") { |value| options[:selection] = value }
        opts.on("--observations PATH") { |value| options[:observations] = value }
        opts.on("--force") { options[:force] = true }
        opts.on("--reason TEXT") { |value| options[:reason] = value }
      end
      parser.order!(argv)
      if action != "export" && options.keys.any? { |key| %i[base remote repository focused].include?(key) }
        raise Error, "checkpoint: base and remote are export-only options"
      end
      if action != "gate" && options.keys.any? { |key| %i[seed selection observations force reason].include?(key) }
        raise Error, "checkpoint: requested settings and observations are gate-only options"
      end
      checkpoint = Checkpoint.new(data_root: @data_root, err: @err, transport: @transport,
        gate_executor: @native_pilot && @native_pilot.method(:gate))
      result = case action
               when "export"
                 unless argv.empty? && options[:workspace] && options[:artifact] && options[:base] &&
                        (options.keys - %i[workspace artifact base remote repository focused]).empty?
                   raise Error, "checkpoint export requires --workspace PATH --base SHA --artifact PATH [--remote NAME]"
                 end
                 checkpoint.export(id, workspace: options.fetch(:workspace), base_sha: options.fetch(:base),
                   artifact: options.fetch(:artifact), remote: options.fetch(:remote, "origin"), repository: options[:repository], focused: options[:focused])
               when "record"
                 raise Error, "checkpoint record requires --workspace" unless options[:workspace] && argv.empty? && !options[:destination] && !options[:attempt]
                 checkpoint.record(id, workspace: options.fetch(:workspace), artifact: options[:artifact])
               when "verify"
                 raise Error, "checkpoint verify accepts only --workspace" unless argv.empty? && !options[:artifact] && !options[:destination]
                 checkpoint.verify(id, workspace: options[:workspace], attempt: options[:attempt])
               when "gate"
                 raise Error, "checkpoint gate requires --workspace PATH -- COMMAND" unless options[:workspace] && argv.any? && !options[:artifact] && !options[:destination] && !options[:attempt]
                 checkpoint.gate(id, workspace: options.fetch(:workspace), command: argv,
                                 requested: options.slice(:seed, :selection), observations: options[:observations],
                                 **options.slice(:force, :reason))
               when "recover"
                 raise Error, "checkpoint recover requires --destination and --confirm-disconnected" unless
                   options[:destination] && options[:confirm_disconnected] && argv.empty? && !options[:workspace] && !options[:artifact]
                 checkpoint.recover(id, destination: options.fetch(:destination), confirm_disconnected: true, attempt: options[:attempt])
               end
      @out.puts JSON.pretty_generate(result)
      action == "gate" && result.is_a?(Integer) ? result : 0
    end

    # Prints independent historical inventories or delegates existing cleanup.
    # Inspection writes nothing and returns nonzero for damaged records while
    # retaining valid rows; unsafe arguments/cleanup preconditions raise Error.
    def worktree_command(argv, cleanup:)
      id = argv.shift
      usage = "usage: agent-coding-tool #{cleanup ? 'cleanup TASK [--dry-run] [--pr URL|ALIAS-NUMBER]' : 'worktrees TASK'}"
      raise Error, usage unless id&.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
      if cleanup
        dry_run, pr = false, nil
        until argv.empty?
          case argv.shift
          when "--dry-run"
            raise Error, usage if dry_run
            dry_run = true
          when "--pr"
            raise Error, usage if pr || argv.empty? || argv.first.start_with?("--")
            pr = argv.shift
          else
            raise Error, usage
          end
        end
        handler = CleanupManager.new(data_root: @data_root, transport: @transport)
        options = pr ? { pr: pr } : {}
        result = dry_run ? handler.preflight(id, **options) : handler.remove(id, **options)
        @out.puts JSON.pretty_generate(result.merge("dry_run" => dry_run,
                                                     "attempts" => [result.fetch("attempts")]))
        return 0
      end
      raise Error, usage unless argv.empty?
      root = File.join("#{@data_root}-runs", id)
      resets = TaskReset.new(data_root: @data_root, transport: @transport).history(id)
      unless resets.empty? || File.directory?(root)
        @out.puts JSON.pretty_generate("task_id" => id, "attempts" => [], "resets" => resets)
        return resets.all? { |receipt| receipt["phase"] == "complete" } ? 0 : 2
      end
      raise InvalidState, "#{id}: no run evidence" unless File.directory?(root) && !File.symlink?(root)
      history = AttemptRecovery.new(data_root: @data_root, transport: @transport).inspect(id)
      records = IncidentalMetadata.children(root).sort.map do |attempt|
        directory = File.join(root, attempt)
        historical = history.find { |row| row["run_dir"] == directory }
        raise InvalidState, "#{id}: partial/foreign run evidence" if File.symlink?(directory) || !File.directory?(directory)
        path = File.join(directory, "worktrees.json")
        next historical unless File.file?(path) && !File.symlink?(path)
        manager = WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root, record_path: path, transport: @transport)
        delivery_path = File.join(directory, "delivery.json")
        overrides = {}
        if File.exist?(delivery_path) || File.symlink?(delivery_path)
          raise InvalidState, "#{id}: foreign delivery evidence" if File.symlink?(delivery_path) || !File.file?(delivery_path)
          delivery = JSON.parse(File.binread(delivery_path))
          if %w[committed pushed draft_pr].include?(delivery["stage"])
            raise InvalidState, "#{id}: invalid delivered commit" unless
              delivery["schema"] == DeliveryManager::SCHEMA && delivery["task_id"] == id &&
              delivery["commit_sha"].is_a?(String) && delivery["commit_sha"].match?(/\A[0-9a-f]{40}\z/)
            name = JSON.parse(File.binread(path)).fetch("entries").find { |entry| entry["access"] == "write" }.fetch("name")
            overrides[name] = delivery.fetch("commit_sha")
          end
        end
        entries = JSON.parse(File.binread(path)).fetch("entries")
        if entries.count { |entry| entry["access"] == "write" } > 1
          entries.each do |entry|
            next unless entry["access"] == "write"
            detail_path = File.join(directory, "repositories", entry.fetch("name"), "delivery.json")
            next unless File.file?(detail_path) && !File.symlink?(detail_path)
            detail = JSON.parse(File.binread(detail_path))
            overrides[entry.fetch("name")] = detail.fetch("commit_sha") if
              detail["commit_sha"].to_s.match?(/\A[0-9a-f]{40}\z/)
          end
        end
        inventory = manager.inspect!(head_overrides: overrides, allow_partial: historical && historical["status"] == "preflight_failed")
        metadata = historical&.slice("invocation_id", "status", "prepared_at", "preparation", "classification", "closed", "checkpoint", "next_action", "artifacts", "blockers", "closeout_blockers", "liveness") || {}
        # Delivered candidates use the established verified HEAD overrides above.
        metadata.delete("blockers") unless overrides.empty?
        inventory.merge(metadata)
      rescue Error, JSON::ParserError, KeyError, TypeError => error
        { "run_dir" => directory, "classification" => "unverified", "blockers" => [error.message] }
      end
      result = { "task_id" => id, "attempts" => records }
      result["resets"] = resets unless resets.empty?
      @out.puts JSON.pretty_generate(result)
      records.any? { |row| row.nil? || !row.fetch("blockers", []).empty? } ? 2 : 0
    rescue JSON::ParserError, KeyError, TypeError
      raise InvalidState, "#{id}: malformed worktree/delivery evidence"
    end

    def abandon_preflight_command(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool abandon-preflight TASK [--dry-run]" unless
        id&.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) && [[], ["--dry-run"]].include?(argv)
      recovery = PreflightRecovery.new(data_root: @data_root, transport: @transport)
      result = argv == ["--dry-run"] ? recovery.preflight(id) : recovery.abandon(id)
      @out.puts JSON.pretty_generate(result)
      0
    end

    # Explicitly preserves unsuccessful managed attempts after a human outcome.
    # Dry run is read-only; action writes only separate private closeout records.
    def close_attempt_command(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool close-attempt TASK [--dry-run]" unless
        id&.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) && [[], ["--dry-run"]].include?(argv)
      recovery = AttemptRecovery.new(data_root: @data_root, transport: @transport)
      @out.puts JSON.pretty_generate(argv == ["--dry-run"] ? recovery.preflight(id) : recovery.close(id))
      0
    end

    # Parses supported launch options and returns worker status. Manual overlap
    # returns 2 with a shell-safe conditional retry; other errors remain distinct.
    def launch_command(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.on("--codex", "launch one local ChatGPT Codex worker") { options[:codex] = true }
        opts.on("--allow-write-collision", "permit unverified manual overlap; verified managed overlap is automatic") { options[:allow_write_collision] = true }
        opts.on("--model MODEL", "explicit Codex model override; recommendation is advisory") { |value| options[:model] = value }
        opts.on("--reasoning LEVEL", "explicit minimal/low/medium/high/xhigh reasoning") { |value| options[:reasoning] = value }
      end
      parser.parse!(argv)
      unless options.delete(:codex) && argv.length == 1
        raise Error, "usage: agent-coding-tool launch TASK --codex [--allow-write-collision] [--model MODEL] [--reasoning LEVEL]"
      end
      settings = @native_pilot ? { codex: @native_pilot.executable, spawner: @native_pilot.method(:spawn) } : {}
      Launcher.new(coordinator: coordinator, data_root: @data_root, source_root: @root, out: @out, err: @err, transport: @transport, **settings)
              .launch(argv.first, **options)
    rescue Launcher::WriteCollision => error
      retry_argv = ["act", "launch", argv.first, "--codex"]
      retry_argv.concat(["--model", options[:model]]) if options[:model]
      retry_argv.concat(["--reasoning", options[:reasoning]]) if options[:reasoning]
      retry_argv << "--allow-write-collision"
      @err.puts "ERROR: #{argv.first} was not started: another task has overlapping write scope."
      @err.puts "  • Repository/s: #{error.collisions.flat_map { |row| row.fetch('repositories') }.uniq.sort.join(', ')}"
      @err.puts "  • Other task/s: #{error.collisions.map { |row| row.fetch('task_id') }.uniq.sort.join(', ')}"
      @err.puts "Next steps:"
      @err.puts "  • If you have reviewed the overlap and explicitly authorize parallel"
      @err.puts "    development, retry with:"
      @err.puts "  • #{Shellwords.join(retry_argv)}"
      2
    rescue Psych::Exception, TypeError, ArgumentError, KeyError => e
      raise InvalidTask, "launch: malformed configuration/task data: #{e.message}"
    end

    def publish_command(argv)
      unless argv.count("--dry-run") <= 1 && argv.count("--all") <= 1 &&
             argv.all? { |arg| !arg.start_with?("-") || %w[--all --dry-run].include?(arg) }
        raise Error, "usage: agent-coding-tool publish [TASK | --all] [--dry-run]"
      end
      dry_run = argv.delete("--dry-run")
      all = argv.delete("--all")
      if argv.length > 1 || (all && !argv.empty?) || argv.any? { |arg| arg.start_with?("-") }
        raise Error, "usage: agent-coding-tool publish [TASK | --all] [--dry-run]"
      end

      task_id = argv.first
      config = Config.load(File.join(@data_root, "config.yml"))
      publisher = Publisher.new(data_root: @data_root, config: config,
                                task_store: TaskStore.new(File.join(@data_root, "tasks")), transport: @transport)
      result = publisher.publish(mode: all ? :all : task_id ? :task : :default,
                                 task_id: task_id, dry_run: !!dry_run)
      @out.puts(dry_run ? "DRY RUN (no changes made)" : "ACTD publication")
      @out.puts "Mode: #{result.fetch(:mode)}"
      @out.puts "Repository: #{result.fetch(:repository)}"
      @out.puts "Destination: #{result.fetch(:remote)}/#{result.fetch(:branch)}"
      @out.puts "Files (#{result.fetch(:files).length}):"
      result.fetch(:files).each { |path| @out.puts "  #{path}" }
      @out.puts "Existing staged changes: #{result.fetch(:staged).join(', ')}" if dry_run
      @out.puts "Commit needed: #{result.fetch(:commit_needed)}" if dry_run
      @out.puts "Push needed: #{result.fetch(:push_needed)}" if dry_run
      if result[:blocker]
        @out.puts "BLOCKED: #{result.fetch(:blocker)}"
        raise Error, "publication blocked: #{result.fetch(:blocker)}" unless dry_run
      elsif dry_run
        @out.puts "Remote publication was not attempted."
      elsif result[:pushed]
        @out.puts "PUBLISHED: #{result.fetch(:sha)} (remote ref verified)"
      else
        @out.puts "No selected local changes; already synchronized with remote."
      end
    end

    def coordinator
      @coordinator ||= begin
        unless Dir.exist?(@data_root)
          raise Error, "data directory does not exist: #{@data_root}; set AGENT_CODING_TOOL_DATA_DIR to override"
        end

        config = Config.load(File.join(@data_root, "config.yml"))
        Coordinator.new(
          task_store: TaskStore.new(File.join(@data_root, "tasks")),
          state_store: StateStore.new(File.join(@data_root, "state")),
          repo_inspector: RepoInspector.new(config, transport: @transport),
          prompt_renderer: PromptRenderer.new(transport: @transport),
          prompt_root: File.join(@data_root, "state", "prompts"), transport: @transport
        )
      end
    end

    # Renders minimal rows by default, or existing details with --full, from one snapshot.
    # argv accepts presentation/completion flags or one family selector; invalid combinations
    # raise Error/OptionParser::ParseError before status resolution. Family and
    # compression filters run after global NEXT selection and never change state.
    def status_command(argv)
      options = { completion_filter: :recent }
      parser = OptionParser.new do |opts|
        opts.on("--fam FAMILY", "show one task-ID family without READY compression") do |value|
          raise Error, "status accepts only one --fam selector" if options.key?(:family)

          options[:family] = value
        end
        opts.on("--all", "show every task, including all completed tasks") { options[:all] = true }
        opts.on("--active", "show no completed tasks") { options[:active] = true }
        opts.on("--icebox", "show only intentionally deferred tasks") { options[:icebox] = true }
        opts.on("--min", "show one width-bounded row per displayed task") { options[:minimal] = true }
        opts.on("--full", "show expanded details, warnings and summaries") { options[:full] = true }
      end
      parser.require_exact = true
      parser.parse!(argv)
      if options[:minimal] && options[:full]
        raise Error, "status --min and --full are mutually exclusive"
      end
      options[:minimal] = !options[:full]
      if options[:all] && options[:active]
        raise Error, "status --all and --active are mutually exclusive"
      end
      options[:completion_filter] = :all if options[:all]
      options[:completion_filter] = :active if options[:active]

      id = argv.shift
      unless argv.empty? && !(id && (options.key?(:family) || options[:icebox]))
        raise Error, "usage: agent-coding-tool status [TASK | --fam FAMILY] [--all | --active] [--icebox] [--min | --full]"
      end
      with_status_read_view { render_status(id, options) }
    end

    # Renders a validated selector/presentation request from one advisory view.
    # Returns output's result; missing families and invalid evidence still raise.
    def render_status(id, options)
      if options.key?(:family) && !coordinator.tasks.any? { |task| task_family(task.fetch("id")) == options[:family] }
        raise Error, "unknown task family: #{options[:family]}"
      end

      statuses = if id
                   coordinator.statuses([id], report_unavailable: true)
                 else
                   coordinator.statuses(completion_filter: options.fetch(:completion_filter), report_unavailable: true)
                 end
      broad_dashboard = id.nil?
      deferred = statuses.select { |item| item.fetch("status") == "ICEBOX" }
      compact_icebox = broad_dashboard && !options[:all] && !options.key?(:family) && !options[:icebox]
      completion_metrics = nil
      next_id = nil
      family_summaries = {}
      if broad_dashboard
        freshness_known = statuses.none? { |item| item.fetch("status") == "FRESHNESS_UNAVAILABLE" }
        completion_metrics = completion_dashboard_metrics(statuses) if freshness_known
        ranking_metrics = completion_metrics || {}
        statuses = sort_statuses(statuses, ranking_metrics)
        if freshness_known && coordinator.respond_to?(:next_start_set)
          selection = coordinator.next_start_set(statuses, statuses)
          next_id = next_status_id(selection, statuses)
        end
        # Presentation subgroups must not change scheduling or global NEXT.
        statuses = sort_statuses(statuses, ranking_metrics, dashboard: true)
        unless freshness_known
          puts_wrapped("NEXT withheld: repository freshness unavailable.", first_prefix: "", continuation_prefix: "  ")
        end
        if options.key?(:family)
          statuses = statuses.select { |item| task_family(item.fetch("id")) == options[:family] }
        elsif !options[:all]
          statuses, family_summaries = compress_ready_statuses(statuses, next_id:)
        end
        statuses = statuses.select { |item| item.fetch("status") == "ICEBOX" } if options[:icebox]
        statuses = statuses.reject { |item| item.fetch("status") == "ICEBOX" && !item["external_activity"] } if compact_icebox
        statuses = limit_blocked_statuses(statuses) unless options[:all]
      end
      if options[:minimal]
        rows = statuses.map do |item|
          [normalize_minimal_text(item.fetch("id")) + ":", minimal_status(item, next_id:),
           normalize_minimal_text(item.fetch("title"))]
        end
        id_width = rows.map { |identity, _status, _title| display_width(identity) }.max || 0
        status_width = rows.map { |_identity, status, _title| display_width(status) }.max || 0
        aligned = id_width + 1 + status_width + 2 < dashboard_width
        rows.each { |row| display_minimal_item(row, id_width:, status_width:, aligned:) }
        return
      end
      previous_bucket = nil

      statuses.each do |item|
        bucket = stale_in_flight?(item) ? :stale_in_flight : status_bucket(item.fetch("status"))
        @out.puts if broad_dashboard && previous_bucket && bucket != previous_bucket

        if broad_dashboard
          display_dashboard_item(item, completion_metrics, next_id:)
          family = task_family(item.fetch("id"))
          summary = item.fetch("status") == "READY" ? family_summaries.delete(family) : nil
          display_family_summary(family, summary) if summary
        else
          @out.puts "#{item.fetch('id')}: #{human_status(item)} — #{item.fetch('title')}"
          display_explicit_details(item)
        end
        previous_bucket = bucket
      end
      display_icebox_summary(deferred) if compact_icebox && !options[:minimal]
    end

    # Prints exactly one final, uncompressed inventory count. Families use the
    # existing first-prefix rule and lexical order; output errors propagate.
    def display_icebox_summary(deferred)
      count = deferred.length
      families = deferred.map { |item| task_family(item.fetch("id")) }.uniq.sort
      suffix = families.empty? ? "" : " from families (#{families.join(', ')})"
      @out.puts "#{count} Icebox #{pluralize(count, 'task')}#{suffix}"
    end

    def next_command(argv)
      json = argv == ["--json"]
      raise Error, "usage: agent-coding-tool next [--json]" unless argv.empty? || json

      plan = with_status_read_view { next_plan }
      if json
        @out.puts JSON.generate(next_json_document(plan))
        return
      end

      selection = plan.fetch(:selection)
      ranked = plan.fetch(:ranked)
      metrics = plan.fetch(:metrics)
      tasks_by_id = plan.fetch(:tasks_by_id)
      render_next_plan(selection, ranked, metrics, tasks_by_id)
    end

    def next_plan
      statuses = coordinator.statuses(completion_filter: :all, strict_freshness: true)
      metrics = completion_dashboard_metrics(statuses)
      ranked = sort_statuses(statuses, metrics)
      selection = coordinator.next_start_set(statuses, ranked)
      tasks_by_id = coordinator.tasks.to_h { |task| [task.fetch("id"), task] }
      { statuses:, ranked:, metrics:, selection:, tasks_by_id: }
    end

    # Prints one ranked snapshot, including optional isolated manual work. Inputs
    # are the shared planner's rows/metrics; no state changes or probes occur.
    def render_next_plan(selection, ranked, metrics, tasks_by_id)
      @out.puts "Next safe parallel starts (READY priority first; never trade a higher-ranked task for width):"
      if selection.fetch("starts").empty?
        @out.puts "  None currently available."
      else
        selection.fetch("starts").each do |row|
          id = row.fetch("id")
          @out.puts "  #{id} (#{row.fetch('status')}) — #{tasks_by_id.fetch(id).fetch('title')}"
          @out.puts "    act prepare #{id}" if row.fetch("status") == "READY"
          @out.puts "    act start #{id}"
          if (recommendation = tasks_by_id.fetch(id)["worker_recommendation"])
            @out.puts "    worker: #{recommendation.fetch('model')} / #{recommendation.fetch('thinking')}"
          end
          print_expected_unlock(id, metrics)
        end
      end
      @out.puts "  Prepare and start still recheck their safety gates before worker handoff."

      display_next_section("Additional manual parallel work", selection.fetch("waiting_capacity")) do |row|
        conflicts = row.fetch("conflicts").map do |conflict|
          "#{conflict.fetch('task_id')} (#{conflict.fetch('status')}) on " \
            "#{format_authorities(conflict.fetch('authorities'))}"
        end
        @out.puts "  #{row.fetch('id')} (#{row.fetch('status')}): #{conflicts.join('; ')}"
        @out.puts "    use separately isolated development; manual isolation/liveness unverified"
        @out.puts "    act prepare #{row.fetch('id')}" if row.fetch("status") == "READY"
        @out.puts "    act start #{row.fetch('id')} (warns and proceeds; integration remains separate)"
      end
      display_next_section("External activity blocks starts", selection.fetch("external_waits", [])) do |row|
        @out.puts "  #{row.fetch('id')} (#{row.fetch('status')}): explicit external observation end required; original managed gates still apply"
      end
      ranked.each do |status|
        next unless status["external_activity"]

        @out.puts "  #{status.fetch('id')} (#{status.fetch('status')}): external activity reported"
        display_external_activity(status)
        display_icebox_details(status) if status.fetch("status") == "ICEBOX"
      end
      display_next_section("Running lanes", selection.fetch("occupied").select { |row| row.fetch("status") == "IN_FLIGHT" }) do |row|
        @out.puts "  #{row.fetch('id')}: #{format_authorities(row.fetch('authorities'))}"
      end
      candidates = ranked.select { |status| status.fetch("status") == "CANDIDATE" }
      display_next_section("Awaiting human review/application", candidates) do |status|
        @out.puts "  #{status.fetch('id')}: review the candidate and verify landing; completion is not inferred."
        @out.puts "    artifact: #{status.dig('state', 'result', 'artifact')}" if status.dig("state", "result", "artifact")
        @out.puts "    #{status.fetch('reason')}" if status["reason"]
        print_expected_unlock(status.fetch("id"), metrics)
      end
      interventions = ranked.select do |status|
        %w[STALE STALE_CANDIDATE NEEDS_JUDGMENT FAILED].include?(status.fetch("status")) ||
          (status.fetch("status") == "BLOCKED" && status.dig("state", "result", "outcome") == "blocked")
      end
      display_next_section("Interventions", interventions) do |status|
        @out.puts "  #{status.fetch('id')} (#{human_status(status)}): #{status.fetch('reason')}"
        display_stale_source(status)
        display_parallel_authorization(status) if status["lifecycle_status"] == "IN_FLIGHT"
        @out.puts "    recorded next: #{status.fetch('next_action')}" if status.key?("next_action")
      end
      dependency_waits = ranked.select do |status|
        status.fetch("status") == "BLOCKED" && status["reason"]&.start_with?(DEPENDENCY_REASON_PREFIX)
      end
      display_next_section("Waiting for dependencies", dependency_waits) do |status|
        @out.puts "  #{status.fetch('id')}: #{display_reason(status)}"
      end
      @out.puts "Unlock counts are conditional on verified completion, not present eligibility."
    end

    # Returns the same advisory plan as machine-readable evidence/actions without
    # reprobing or asserting current isolation. Missing plan fields raise KeyError.
    def next_json_document(plan)
      selection = plan.fetch(:selection)
      ranked = plan.fetch(:ranked)
      tasks = plan.fetch(:tasks_by_id)
      metrics = plan.fetch(:metrics)
      priority = ranked.each_with_index.to_h { |status, index| [status.fetch("id"), index + 1] }
      occupied = selection.fetch("occupied")
      candidates = ranked.select { |status| status.fetch("status") == "CANDIDATE" }
      interventions = ranked.select do |status|
        %w[STALE STALE_CANDIDATE NEEDS_JUDGMENT FAILED].include?(status.fetch("status")) ||
          (status.fetch("status") == "BLOCKED" && status.dig("state", "result", "outcome") == "blocked")
      end
      dependencies = ranked.select do |status|
        status.fetch("status") == "BLOCKED" && status["reason"]&.start_with?(DEPENDENCY_REASON_PREFIX)
      end

      {
        "schema_version" => NEXT_JSON_VERSION,
        "advisory" => true,
        "snapshot" => {
          "freshness" => "strict_pushed_heads_for_prepared_work",
          "ready_authorities" => "local_repository_configuration",
          "revalidation" => "prepare and start independently recheck safety gates"
        },
        "facts" => {
          "tasks" => ranked.map do |status|
            id = status.fetch("id")
            row = { "id" => id, "status" => status.fetch("status"), "reason" => status["reason"],
              "depends_on" => tasks.fetch(id).fetch("depends_on", []),
              "priority_rank" => priority.fetch(id),
              "execution_evidence" => status["execution_evidence"],
              "candidate_handoff" => status["candidate_handoff"],
              "freshness" => next_freshness(status, tasks.fetch(id)) }.merge(
                status.fetch("status") == "ICEBOX" ? { "icebox" => status.fetch("state").fetch("icebox"),
                                                        "lifecycle_status" => status.fetch("lifecycle_status") } : {})
            row["external_activity"] = status["external_activity"] if status["external_activity"]
            row["reset_history"] = status["reset_history"] if status["reset_history"]
            row["external_conflicts"] = status["external_conflicts"] if status["external_conflicts"]
            row["lifecycle_status"] = status["lifecycle_status"] if status["lifecycle_status"]
            row["writable_source_changes"] = status["writable_source_changes"] if status["writable_source_changes"]
            row
          end,
          "reservations" => occupied.map { |row| next_authority_row(row) }
        },
        "recommendations" => {
          "starts" => selection.fetch("starts").map do |row|
            id = row.fetch("id")
            next_action_row(row, priority, metrics).merge(
              "category" => "start",
              "commands" => (row.fetch("status") == "READY" ? ["act prepare #{id}", "act start #{id}"] : ["act start #{id}"]),
              "worker_recommendation" => tasks.fetch(id)["worker_recommendation"]
            )
          end,
          "waiting_capacity" => selection.fetch("waiting_capacity").map do |row|
            next_action_row(row, priority, metrics).merge(
              "category" => "manual_parallel",
              "isolation" => "unverified", "liveness" => "unknown",
              "next_action" => "use separately isolated development, then prepare/start; integration remains separate",
              "conflicts" => row.fetch("conflicts").map { |conflict| next_authority_row(conflict) }
            )
          end,
          "candidate_review" => candidates.map do |status|
            next_status_row(status, priority, metrics).merge(
              "category" => "review_candidate",
              "artifact" => status.dig("state", "result", "artifact"),
              "next_action" => "review candidate and verify landing; completion is not inferred"
            )
          end,
          "interventions" => interventions.map do |status|
            next_status_row(status, priority, metrics).merge(
              "category" => "intervene", "next_action" => status["next_action"]
            )
          end,
          "waiting_dependencies" => dependencies.map do |status|
            next_status_row(status, priority, metrics).merge("category" => "wait_dependencies")
          end
        }
      }.tap do |document|
        if ranked.any? { |status| status["external_reservations"] }
          document.fetch("facts")["external_reservations"] = ranked.first.fetch("external_reservations", [])
          document.fetch("recommendations")["external_waits"] = selection.fetch("external_waits", [])
        end
      end
    end

    def next_authority_row(row)
      { "id" => row["id"] || row["task_id"], "status" => row.fetch("status"),
        "authorities" => row.fetch("authorities").map { |remote, branch| { "remote_url" => remote, "branch" => branch } } }
    end

    def next_freshness(status, task)
      snapshot = status.fetch("state")["snapshot"]
      label = status.fetch("status")
      checked = %w[PREPARED IN_FLIGHT CANDIDATE STALE STALE_CANDIDATE].include?(label)
      {
        "state" => if checked
                     %w[STALE STALE_CANDIDATE].include?(label) ? "changed_writable_head" : "checked"
                   elsif snapshot
                     "not_checked_effective_state"
                   else
                     "not_prepared"
                   end,
        "prepared_repositories" => task.fetch("repositories").filter_map do |name, spec|
          binding = snapshot&.[](name)
          next unless binding

          { "name" => name, "access" => spec.fetch("access"),
            "remote_url" => binding.fetch("remote_url"), "branch" => binding.fetch("branch"),
            "prepared_pushed_sha" => binding.fetch("pushed_sha") }
        end
      }
    end

    def next_action_row(row, priority, metrics)
      next_authority_row(row).merge("priority_rank" => priority.fetch(row.fetch("id")),
                                    "downstream" => next_downstream(row.fetch("id"), metrics))
    end

    def next_status_row(status, priority, metrics)
      id = status.fetch("id")
      { "id" => id, "status" => status.fetch("status"), "priority_rank" => priority.fetch(id),
        "reason" => status["reason"], "downstream" => next_downstream(id, metrics) }
    end

    def next_downstream(id, metrics)
      depth, count, unlock_count, parallel_width = metrics.fetch(id, [0, 0, 0, 0])
      { "depth" => depth, "count" => count, "immediate_unlock_count" => unlock_count,
        "conditional_parallel_width" => parallel_width }
    end

    def next_status_id(selection, ranked_statuses)
      selected = selection.fetch("starts").first ||
                 ranked_statuses.find { |item| item.fetch("status") == "CANDIDATE" } ||
                 selection.fetch("waiting_capacity").first ||
                 ranked_statuses.find do |item|
                   %w[STALE STALE_CANDIDATE NEEDS_JUDGMENT FAILED].include?(item.fetch("status")) ||
                     (item.fetch("status") == "BLOCKED" && item.dig("state", "result", "outcome") == "blocked")
                 end
      selected&.fetch("id")
    end

    def display_next_section(title, rows)
      return if rows.empty?

      @out.puts
      @out.puts "#{title}:"
      rows.each { |row| yield row }
    end

    def print_expected_unlock(id, metrics)
      depth, count, unlock_count, parallel_width = metrics.fetch(id, [0, 0, 0, 0])
      @out.puts "    downstream: #{depth} levels / #{count} tasks; " \
                "expected immediate unlocks: #{unlock_count} tasks / #{parallel_width} parallel (conditional)"
    end

    def format_authorities(authorities)
      return "no writable authority" if authorities.empty?

      authorities.map { |remote, branch| "#{remote} [#{branch}]" }.join(", ")
    end

    # Returns a new bucket-ordered array. Only READY receives ACT preference,
    # descending unlock/dependency metrics, natural numeric ID ties and finally
    # full-ID ties, then the one-time CL-WLO-01 exception within READY CL slots.
    # Icebox sorts last with natural ID ties; other lifecycle ordering and input
    # rows are preserved. dashboard places recorded stale starts after fresh
    # starts for display only; next/scheduling retain effective-status ranking.
    # Missing row/metric fields raise KeyError.
    def sort_statuses(statuses, completion_metrics, dashboard: false)
      ranked = statuses.each_with_index
              .sort_by do |item, index|
                status = item.fetch("status")
                depth, count, unlock_count, parallel_width =
                  completion_metrics.fetch(item.fetch("id"), [0, 0, 0, 0])
                id = item.fetch("id")
                ready_rank = if status == "READY"
                               [task_family(id) == "ACT" ? 0 : 1, -parallel_width, -unlock_count,
                                -depth, -count, natural_task_id(id), id]
                             else
                               [0, 0, 0, 0, 0, [], ""]
                             end
                complete_rank = status == "COMPLETE" ? completion_rank(item) : [0, 0]
                blocked_rank = status == "BLOCKED" ? blocked_dependency_count(item) : 0
                icebox_rank = status == "ICEBOX" ? [natural_task_id(id), id] : [[], ""]
                display_status = dashboard && stale_in_flight?(item) ? "IN_FLIGHT_STALE" : status
                [STATUS_ORDER.fetch(display_status, 90), *ready_rank, *complete_rank, blocked_rank, *icebox_rank, index]
              end
              .map(&:first)
      prioritize_batch39_cleanup(ranked)
    end

    # Returns a new ranking promoting only READY CL-WLO-01 within existing READY
    # CL positions. Other families keep their positions; other CL rows keep their
    # relative order. Missing/non-READY targets are inert. No I/O or state changes.
    def prioritize_batch39_cleanup(ranked)
      cleanup = ranked.find { |item| item.fetch("id") == "CL-WLO-01" && item.fetch("status") == "READY" }
      return ranked unless cleanup

      cl_ready = ranked.select { |item| item.fetch("status") == "READY" && task_family(item.fetch("id")) == "CL" }
      cl_ready.delete(cleanup)
      cl_ready.unshift(cleanup)
      ranked.map do |item|
        item.fetch("status") == "READY" && task_family(item.fetch("id")) == "CL" ? cl_ready.shift : item
      end
    end

    # Prints one subordinate READY family summary from [total, hidden] counts.
    # At narrow widths the drill-down command stays intact on its own line;
    # commands longer than the terminal may overflow, as other detail tokens do.
    def display_family_summary(family, summary)
      total, hidden = summary
      detail = "#{normalize_dashboard_text(family)}: #{total} READY, #{hidden} hidden"
      command = "act stat --fam=#{Shellwords.escape(family)}"
      command = "act stat --fam #{Shellwords.escape(family)}" unless family.start_with?("-")
      if hidden.positive? && display_width("    #{detail} — #{command}") <= dashboard_width
        @out.puts "    #{detail} — #{command}"
      else
        puts_wrapped(detail, first_prefix: "    ", continuation_prefix: "    ")
        @out.puts "    #{command}" if hidden.positive?
      end
    end

    # Returns the first hyphen-delimited ID prefix; no hyphen or an empty
    # prefix falls back to the whole accepted ID. Grouping grants no authority.
    def task_family(id)
      prefix = id.split("-", 2).first
      prefix.nil? || prefix.empty? ? id : prefix
    end

    # Returns comparable tagged text/numeric runs; leading zeros compare equally.
    # The caller uses the full ID to resolve equivalent keys deterministically.
    def natural_task_id(id)
      id.scan(/\d+|\D+/).map do |part|
        part.match?(/\A\d+\z/) ? [1, part.to_i] : [0, part]
      end
    end

    # Returns [visible statuses, family => [total READY, hidden READY]]. Input
    # must already be globally ranked. At most six READY rows are allocated for
    # up to three families (three per family); four or more get one each.
    # Operator-approved exception: a hidden READY NEXT replaces the lowest-ranked
    # displayed member of its own family. Ordering, caps and planner stay intact.
    # Six or fewer READY rows are returned unchanged, without summaries.
    def compress_ready_statuses(statuses, next_id:)
      ready = statuses.select { |item| item.fetch("status") == "READY" }
      return [statuses, {}] if ready.length <= READY_DISPLAY_LIMIT

      families = ready.group_by { |item| task_family(item.fetch("id")) }
      selected = families.transform_values { |items| [items.first.fetch("id")] }
      if families.length <= READY_FAMILY_LIMIT
        ready.each do |item|
          break if selected.values.sum(&:length) >= READY_DISPLAY_LIMIT

          members = selected.fetch(task_family(item.fetch("id")))
          id = item.fetch("id")
          members << id if members.length < READY_FAMILY_LIMIT && !members.include?(id)
        end
      end
      if ready.any? { |item| item.fetch("id") == next_id }
        members = selected.fetch(task_family(next_id))
        unless members.include?(next_id)
          members.pop
          members << next_id
        end
      end
      visible_ids = selected.values.flatten.to_h { |id| [id, true] }
      summaries = families.to_h do |family, items|
        [family, [items.length, items.length - selected.fetch(family).length]]
      end
      visible = statuses.select { |item| item.fetch("status") != "READY" || item["external_activity"] || visible_ids.key?(item.fetch("id")) }
      [visible, summaries]
    end

    def completion_dashboard_metrics(statuses)
      tasks = coordinator.respond_to?(:tasks) ? coordinator.tasks : []
      downstream = Hash.new { |hash, id| hash[id] = [] }
      tasks.each do |task|
        task.fetch("depends_on", []).each { |dependency| downstream[dependency] << task.fetch("id") }
      end
      unlock_metrics = if coordinator.respond_to?(:completion_unlock_metrics)
                         coordinator.completion_unlock_metrics(statuses)
                       else
                         {}
                       end

      statuses.filter_map do |item|
        next unless %w[READY CANDIDATE].include?(item.fetch("status"))

        id = item.fetch("id")
        unlock = unlock_metrics.fetch(id, {})
        [
          id,
          [
            downstream_depth(id, downstream, { id => true }),
            downstream_count(id, downstream),
            unlock.fetch("unlock_count", 0),
            unlock.fetch("parallel_width", 0)
          ]
        ]
      end.to_h
    end

    def completion_rank(item)
      recorded_at = item.dig("state", "result", "recorded_at")
      return [0, 0] unless recorded_at.is_a?(String) && !recorded_at.empty?

      [1, Time.iso8601(recorded_at).to_f]
    rescue ArgumentError
      [0, 0]
    end

    def downstream_depth(id, downstream, path)
      downstream.fetch(id, []).filter_map do |child|
        next if path[child]

        1 + downstream_depth(child, downstream, path.merge(child => true))
      end.max || 0
    end

    def downstream_count(id, downstream)
      seen = { id => true }
      pending = downstream.fetch(id, []).dup
      until pending.empty?
        descendant = pending.shift
        next if seen[descendant]

        seen[descendant] = true
        pending.concat(downstream.fetch(descendant, []))
      end
      seen.length - 1
    end

    def blocked_dependency_count(item)
      return 0 unless item.fetch("status") == "BLOCKED"

      reason = item["reason"]
      return Float::INFINITY unless reason&.start_with?(DEPENDENCY_REASON_PREFIX)

      reason.delete_prefix(DEPENDENCY_REASON_PREFIX)
            .split(",")
            .map(&:strip)
            .reject(&:empty?)
            .length
    end

    def limit_blocked_statuses(statuses)
      blocked_seen = 0
      statuses.select do |item|
        next true unless item.fetch("status") == "BLOCKED" && !item["external_activity"]

        blocked_seen += 1
        blocked_seen <= BLOCKED_DISPLAY_LIMIT
      end
    end

    # Returns the display separator bucket for an effective status, including
    # the final Icebox group. Unknown labels retain the exceptional-state bucket.
    def status_bucket(status)
      case status
      when "COMPLETE" then 0
      when "CANDIDATE" then 1
      when "NEEDS_JUDGMENT" then 2
      when "IN_FLIGHT" then 3
      when "READY" then 4
      when "BLOCKED" then 6
      when "ICEBOX" then 7
      else 5
      end
    end

    def display_reason(item)
      reason = item.fetch("reason")
      if item.fetch("status") == "FRESHNESS_UNAVAILABLE"
        return normalize_minimal_text(reason.b.force_encoding(Encoding::UTF_8).scrub)
      end

      if item.fetch("status") == "BLOCKED" && reason.start_with?(DEPENDENCY_REASON_PREFIX)
        "waiting on: #{reason.delete_prefix(DEPENDENCY_REASON_PREFIX)}"
      else
        reason
      end
    end

    def display_in_flight_reason(reason)
      if reason.start_with?(READ_ONLY_FRESHNESS_REASON_PREFIX)
        "read-only refresh/reconcile: #{reason.delete_prefix(READ_ONLY_FRESHNESS_REASON_PREFIX)}"
      else
        reason
      end
    end

    # Returns a human label from effective status and recorded lifecycle evidence.
    # Eligibility consumers keep using status. Missing status raises KeyError.
    def human_status(item)
      status = item.fetch("status")
      return "FRESHNESS UNAVAILABLE" if status == "FRESHNESS_UNAVAILABLE"
      return colorize_status(status) unless stale_in_flight?(item)

      label = "IN_FLIGHT (STALE)"
      color_status? ? "\e[#{STATUS_COLORS.fetch(status)}m#{label}#{ANSI_RESET}" : label
    end

    # Returns whether an effective stale row has a recorded in-flight lifecycle.
    # This is presentation evidence only; missing effective status raises KeyError.
    def stale_in_flight?(item)
      item.fetch("status") == "STALE" && item["lifecycle_status"] == "IN_FLIGHT"
    end

    # Prints verified changed writable identities and reconciliation requirements.
    # Full identities are retained even on narrow terminals; no probes or writes.
    # Missing source fields and output failures propagate to the caller.
    def display_stale_source(item)
      return unless item["writable_source_changes"]

      @out.puts "    STALE: reconcile writable source and renew validation before delivery; integration/completion require separate authority."
      item.fetch("writable_source_changes").each do |source|
        @out.puts "    source #{source.fetch('repository')}: #{source.fetch('remote_url')} [#{source.fetch('branch')}]"
        @out.puts "      prepared pushed: #{source.fetch('prepared_sha')}"
        @out.puts "      current pushed:  #{source.fetch('observed_sha')}"
      end
    end

    # Prints two bounded stale-start details from existing projection evidence:
    # short changed-source identities, then reconciliation and qualified safety.
    # No probes/writes occur; missing source fields/output failures propagate.
    def display_compact_stale_source(item)
      sources = item.fetch("writable_source_changes", [])
      source = sources.first
      movement = if source
                   "#{source.fetch('repository')}: #{source.fetch('prepared_sha')[0, 8]} -> " \
                     "#{source.fetch('observed_sha')[0, 8]} (#{source.fetch('branch')} changed)"
                 else
                   "inspect act stat #{item.fetch('id')} --full"
                 end
      movement = "#{sources.length} changed; act stat #{item.fetch('id')} --full; #{movement}" if sources.length > 1
      @out.puts compact_detail_line("source", movement)
      isolation = if item.dig("execution_evidence", "isolation") == "last_verified_at_launch" &&
                     !item.dig("state", "write_collision_override", "launch", "unverified_manual_conflicts")
                    "isolation last verified at launch"
                  else
                    "isolation unverified"
                  end
      @out.puts compact_detail_line("next", "reconcile before delivery; liveness unknown; #{isolation}")
    end

    # Returns the colored effective status, NEXT and ordered safety annotations
    # for one projected item. Missing fields raise KeyError; no probes or writes
    # occur. Compact status is capped at 24 cells with two dots; --full retains
    # complete annotations. Indicators grant no freshness or execution authority.
    def minimal_status(item, next_id:)
      indicators = []
      if item["external_activity"]
        indicators << "[external reported]"
        indicators << "[external conflict]" if item.dig("state", "started_at") || item.fetch("status") == "COMPLETE"
      end
      indicators << "[external conflict]" if item["external_conflicts"]
      indicators << "[write collision]" unless write_collisions(item).empty?
      if item.dig("state", "write_overlap") || !item.dig("state", "write_collision_override", "conflicts").to_a.empty?
        indicators << "[recorded overlap]"
      end
      indicators << "[read-only refresh]" if item["reason"]&.start_with?(READ_ONLY_FRESHNESS_REASON_PREFIX)
      status = human_status(item)
      status += " (NEXT)" if item.fetch("id") == next_id
      status += " #{indicators.uniq.join(' ')}" unless indicators.empty?
      truncate_display_line(status, 24, omission: "..")
    end

    # Prints normalized [ID-with-colon, colored status, title] cells using widths
    # measured from the final displayed rows. If no title cell fits, every row
    # uses the unpadded fallback: shrink long IDs before status/NEXT/warnings,
    # then hard-truncate at extreme widths. Output errors propagate.
    def display_minimal_item(cells, id_width:, status_width:, aligned:)
      identity, status, title = cells
      if aligned
        row = identity + " " * (id_width - display_width(identity) + 1) + status
        separator = " " * (status_width - display_width(status) + 2)
      else
        identity_width = dashboard_width - display_width(": #{status}")
        display_id = identity.delete_suffix(":")
        display_id = truncate_display_line(display_id, identity_width) if identity_width.positive?
        row = "#{display_id}: #{status}"
        separator = "  "
      end
      title_width = dashboard_width - display_width(row) - display_width(separator)
      row += separator + truncate_display_line(title, title_width) if title_width.positive? && !title.empty?
      @out.puts truncate_display_line(row, dashboard_width).rstrip
    end

    # Returns normalized single-row input text with terminal escapes and control
    # characters neutralized. Generated status color is added separately; this
    # never changes stored text and accepts any value convertible to a string.
    def normalize_minimal_text(text)
      normalize_dashboard_text(text.to_s.gsub(ANSI_SEQUENCE, "").gsub(/[[:cntrl:]]/, " "))
    end

    # Prints one width-aware dashboard row plus its relevant evidence. Accepts
    # an effective status and metrics; missing fields/output errors propagate.
    def display_dashboard_item(item, completion_metrics, next_id:)
      id = item.fetch("id")
      status = item.fetch("status")
      next_marker = id == next_id ? " (NEXT)" : ""
      display_id = normalize_dashboard_text(id)
      colored_prefix = "#{display_id}: #{human_status(item)}#{next_marker} — "
      if stale_in_flight?(item) && display_width(colored_prefix) > dashboard_width - 3
        colored_prefix = "#{colorize_status('STALE')}: #{display_id}#{next_marker} — "
      end
      title = normalize_dashboard_text(item.fetch("title"))
      @out.puts truncate_display_line("#{colored_prefix}#{title}", dashboard_width)
      if stale_in_flight?(item)
        display_compact_stale_source(item)
        display_external_activity(item)
        return
      end
      display_stale_source(item)
      display_external_activity(item)
      display_icebox_details(item) if status == "ICEBOX"

      if status == "IN_FLIGHT"
        @out.puts "    checkpoint: #{item.fetch('checkpoint')} (last explicit check)" if item["checkpoint"]
        display_parallel_authorization(item, compact: true)
        if item["reason"]
          puts_wrapped(display_in_flight_reason(item.fetch("reason")),
                       first_prefix: "    ", continuation_prefix: "    ")
        end
        return
      end

      if completion_metrics && %w[READY CANDIDATE].include?(status)
        depth, count, unlock_count, parallel_width = completion_metrics.fetch(id, [0, 0, 0, 0])
        detail = "downstream: #{depth} #{pluralize(depth, 'level')} / #{count} #{pluralize(count, 'task')}; " \
                 "unlocks: #{unlock_count} #{pluralize(unlock_count, 'task')} / #{parallel_width} parallel"
        puts_wrapped(detail,
                     first_prefix: "    ", continuation_prefix: "    ")
      end
      display_parallel_authorization(item, compact: status != "STALE") if %w[STALE CANDIDATE STALE_CANDIDATE].include?(status)
      if recorded_retryable_outcome?(item)
        display_compact_handoff(item)
      elsif item["reason"]
        puts_wrapped(display_reason(item), first_prefix: "    ", continuation_prefix: "    ")
      end
      display_dashboard_write_collisions(item)
    end

    def display_compact_handoff(item)
      @out.puts compact_detail_line("reason", item["reason"]) if item["reason"]
      @out.puts compact_detail_line("next", item["next_action"]) if item.key?("next_action")
      @out.puts compact_detail_line("resume", "act prepare #{item.fetch('id')} --retry")
    end

    # Prints full task details, including designation/restoration and lifecycle
    # evidence. Missing fields and output errors propagate; no state is changed.
    def display_explicit_details(item)
      item.fetch("reset_history", []).each do |receipt|
        puts_full_detail("hard reset history", "#{receipt.fetch('phase')}; archive: #{receipt.fetch('archive')}; retired through attempt #{receipt.fetch('last_attempt')}")
      end
      if item["administrative_override"]
        puts_full_detail("operator declaration", item.fetch("administrative_override").fetch("audit_path"))
        puts_full_detail("resource eligibility", item.fetch("resource_eligibility"))
      end
      display_stale_source(item)
      display_external_activity(item)
      display_icebox_details(item) if item.fetch("status") == "ICEBOX"
      @out.puts "    checkpoint: #{item.fetch('checkpoint')} (last explicit check)" if item["checkpoint"]
      display_parallel_authorization(item)
      if recorded_retryable_outcome?(item)
        puts_full_detail("reason", item["reason"]) if item["reason"]
        puts_full_detail("next", item["next_action"]) if item.key?("next_action")
        puts_full_detail("resume", "act prepare #{item.fetch('id')} --retry")
      else
        @out.puts "    #{display_reason(item)}" if item["reason"]
      end

      write_collisions(item).each do |collision|
        puts_full_detail("reason", write_collision_detail(collision))
      end
    end

    # Prints reported activity without truncating trust/age qualifiers. Canonical
    # lifecycle/reason remain on their original rows; no liveness probe occurs.
    def display_external_activity(item)
      if (activity = item["external_activity"])
        @out.puts "    EXTERNAL WORK REPORTED: unmanaged; unauthorized by ACT"
        @out.puts "    isolation unverified; containment unverified; liveness unknown"
        @out.puts "    last reported: #{activity.fetch('recorded_at')}; observation #{activity.fetch('observation_id')}"
        @out.puts "    scope: #{activity.fetch('envelope').fetch('scope')} (operator report); explicit end required"
        @out.puts "    INCONSISTENCY: COMPLETE with open external activity" if item["status"] == "COMPLETE"
        @out.puts "    CONFLICT: managed execution also recorded" if item.dig("state", "started_at")
      end
      if item["external_conflicts"]
        @out.puts "    External conflict: #{item.fetch('external_conflicts').map { |row| row.fetch('task_id') }.uniq.join(', ')}; new execution blocked"
      end
    end

    # Shows persisted scheduling evidence separately from underlying lifecycle.
    # Expects a validated Icebox row; output errors and missing fields propagate.
    def display_icebox_details(item)
      designation = item.fetch("state").fetch("icebox")
      puts_full_detail("icebox since", designation.fetch("at"))
      puts_full_detail("icebox reason", designation.fetch("reason")) if designation.key?("reason")
      puts_full_detail("underlying lifecycle", item.fetch("lifecycle_status"))
      puts_full_detail("restore", "act unicebox #{item.fetch('id')}")
    end

    # Renders recorded execution/candidate evidence; compact dashboards truncate
    # at their existing width. No probes, writes or live-isolation claims occur.
    def display_parallel_authorization(item, compact: false)
      override = item.dig("state", "write_collision_override")
      detail = lambda do |label, text|
        @out.puts(compact ? compact_detail_line(label, text) : "    #{label}: #{text}")
      end
      if (evidence = item["execution_evidence"])
        detail.call("execution", "isolation #{evidence.fetch('isolation')}; liveness unknown")
      end
      if (handoff = item["candidate_handoff"])
        unless compact
          detail.call("attempt", handoff["attempt"] || "unknown")
          detail.call("artifact", handoff["artifact"] || "unknown")
          detail.call("validation", handoff.fetch("validation_provenance"))
          if (delivery = handoff["host_delivery"])
            delivery.fetch("repositories").each do |name, record|
              detail.call("candidate #{name}", "#{record['branch'] || 'unknown branch'} #{record['commit_sha'] || 'unknown commit'}; paths #{record['paths']&.join(', ') || 'unknown'}")
            end
          end
          handoff.fetch("source").each do |source|
            detail.call("candidate #{source.fetch('repository')}", "base #{source.fetch('prepared_sha')}; observed #{source.fetch('observed_sha')}")
          end
        end
        detail.call("integration", compact ? "not approved; inspect act status #{item.fetch('id')} --full" : handoff.fetch("next_action"))
      end
      if (overlap = item.dig("state", "write_overlap"))
        others = overlap.fetch("conflicts").map { |row| "#{row.fetch('task_id')} (#{row.fetch('status')})" }.join(", ")
        detail.call("overlap", "#{overlap.fetch('basis')} with #{others}; observed #{overlap.fetch('observed_at')}; not a live isolation check")
      end
      return unless override.is_a?(Hash) && override["conflicts"].is_a?(Array) && !override["conflicts"].empty?

      kind = if override.dig("launch", "unverified_manual_conflicts")
               "operator-authorized development; new worker checked at launch; external isolation/liveness unverified; managed delivery disabled"
             elsif override.dig("launch", "admission_basis") == "default_verified_managed"
               "default managed admission; last verified ACT launch; current liveness unavailable"
             elsif override.dig("launch", "admission_basis") == "explicit_permission"
               "explicit permission; last verified ACT launch; current liveness unavailable"
             else
               override["launch"] ? "last verified ACT launch; current liveness unavailable" : "manual start assertion; isolation/liveness unverified"
             end
      others = override.fetch("conflicts").map { |row| row.fetch("task_id") }.join(", ")
      detail.call("parallel", "#{kind} with #{others}; integration remains separate")
    end

    # Prints width-limited manual overlap warnings from one observed status row.
    def display_dashboard_write_collisions(item)
      collisions = write_collisions(item)
      return if collisions.empty?

      detail = collisions.map { |collision| write_collision_detail(collision, prefix: false) }.join("; ")
      count = collisions.length
      summary = count == 1 ? "manual overlap warning; #{detail}" : "manual overlap warning; #{count} overlaps: #{detail}"
      @out.puts compact_detail_line("reason", summary)
    end

    def write_collisions(item)
      item.fetch("write_collisions", [])
    end

    # Returns one observed conflict's text, optionally including operator advice.
    def write_collision_detail(collision, prefix: true)
      repositories = collision.fetch("repositories").join(", ")
      detail = "#{collision.fetch('task_id')} (#{collision.fetch('status')}) writes #{repositories}"
      prefix ? "manual overlap warning; #{detail}; use separately isolated development" : detail
    end

    def recorded_retryable_outcome?(item)
      return true if %w[NEEDS_JUDGMENT FAILED].include?(item.fetch("status"))

      item.fetch("status") == "BLOCKED" && item.dig("state", "result", "outcome") == "blocked"
    end

    def puts_full_detail(label, text)
      prefix = "    #{label}: "
      lines = text.to_s.lines(chomp: true)
      lines = [""] if lines.empty?
      @out.puts "#{prefix}#{lines.shift}"
      continuation = " " * prefix.length
      lines.each { |line| @out.puts "#{continuation}#{line}" }
    end

    def compact_detail_line(label, text)
      normalized = normalize_dashboard_text(text)
      truncate_display_line("    #{label}: #{normalized}", dashboard_width)
    end

    def normalize_dashboard_text(text)
      text.to_s.gsub(/[[:space:]]+/, " ").strip
    end

    # Truncates visible cells without splitting ANSI sequences or graphemes.
    # The omission marker consumes width; short cells contain only dots.
    def truncate_display_line(text, width, omission: "...")
      return text if display_width(text) <= width
      return "." * width if width < display_width(omission)

      available = width - display_width(omission)
      prefix = +""
      used = 0
      text.scan(DISPLAY_TOKEN).each do |token|
        token_width = display_width(token)
        break if used + token_width > available

        prefix << token
        used += token_width
      end
      prefix << ANSI_RESET if prefix.match?(ANSI_SEQUENCE)
      "#{prefix}#{omission}"
    end

    def display_width(text)
      text.gsub(ANSI_SEQUENCE, "").scan(/\X/).sum { |cluster| grapheme_width(cluster) }
    end

    def grapheme_width(cluster)
      return 0 if cluster.match?(/\A\p{M}+\z/)

      codepoints = cluster.codepoints
      return 2 if codepoints.include?(0xFE0F) || codepoints.any? { |codepoint| wide_codepoint?(codepoint) }

      1
    end

    def wide_codepoint?(codepoint)
      (0x1100..0x115F).cover?(codepoint) ||
        [0x2329, 0x232A].include?(codepoint) ||
        ((0x2E80..0xA4CF).cover?(codepoint) && codepoint != 0x303F) ||
        (0xAC00..0xD7A3).cover?(codepoint) ||
        (0xF900..0xFAFF).cover?(codepoint) ||
        (0xFE10..0xFE19).cover?(codepoint) ||
        (0xFE30..0xFE6F).cover?(codepoint) ||
        (0xFF00..0xFF60).cover?(codepoint) ||
        (0xFFE0..0xFFE6).cover?(codepoint) ||
        (0x1F1E6..0x1F1FF).cover?(codepoint) ||
        (0x1F300..0x1FAFF).cover?(codepoint) ||
        (0x20000..0x3FFFD).cover?(codepoint)
    end

    def pluralize(count, noun)
      count == 1 ? noun : "#{noun}s"
    end

    def puts_wrapped(text, first_prefix:, continuation_prefix:, first_prefix_width: first_prefix.length)
      words = text.to_s.split
      if words.empty?
        @out.puts first_prefix.rstrip
        return
      end

      prefix = first_prefix
      prefix_width = first_prefix_width
      line = prefix.dup
      line_width = prefix_width
      has_word = false
      words.each do |word|
        separator = has_word ? " " : ""
        if has_word && line_width + separator.length + word.length > dashboard_width
          @out.puts line
          prefix = continuation_prefix
          prefix_width = continuation_prefix.length
          line = prefix.dup
          line_width = prefix_width
          separator = ""
          has_word = false
        end
        line << separator << word
        line_width += separator.length + word.length
        has_word = true
      end
      @out.puts line
    end

    def dashboard_width
      @dashboard_width ||= resolve_dashboard_width
    end

    def resolve_dashboard_width
      return @terminal_width if @terminal_width&.positive?

      if @out.respond_to?(:tty?) && @out.tty? && @out.respond_to?(:winsize)
        width = output_terminal_width
        return width if width&.positive?
      end

      columns = Integer(ENV.fetch("COLUMNS", ""), 10)
      return columns if columns.positive?
    rescue ArgumentError
      DEFAULT_DASHBOARD_WIDTH
    else
      DEFAULT_DASHBOARD_WIDTH
    end

    def output_terminal_width
      @out.winsize.last
    rescue SystemCallError
      nil
    end

    def colorize_status(status)
      color = STATUS_COLORS[status]
      return status unless color && color_status?

      "\e[#{color}m#{status}#{ANSI_RESET}"
    end

    def color_status?
      @out.respond_to?(:tty?) && @out.tty? && !ENV.key?("NO_COLOR")
    end

    # Explicitly prepares current task inputs under the managed reservation lock.
    # Prints the retained prompt and snapshot; unresolved history, stale inputs
    # or a busy lock raise before preparation changes.
    def prepare_command(argv)
      retry_result = false
      options = {}
      parser = OptionParser.new do |opts|
        lifecycle_force_options(opts, options)
        opts.on("--retry", "discard the recorded non-complete outcome and prepare a new attempt") { retry_result = true }
      end
      parser.parse!(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool prepare TASK [--retry]" unless id && argv.empty?

      prepared = coordinator.prepare(id, retry_result: retry_result, **options)
      state = prepared.fetch("state")
      display_override(state) if options[:force]
      @out.puts "Prepared #{id} against authoritative pushed heads:"
      state.fetch("snapshot").each do |name, repo|
        local = repo.fetch("local_head") == repo.fetch("pushed_sha") ? "local matches" : "local differs"
        local += ", dirty" if repo.fetch("local_dirty")
        @out.puts "  #{name}: #{repo.fetch('pushed_sha')} (#{local})"
      end
      @out.puts "Prompt: #{state.fetch('prompt_path')}"
      @out.puts "Preparation verifies pushed heads and pinned prompt guidance; local source objects for worktree creation remain unverified until launch."
      @out.puts "Worker-only tools remain unverified until startup. Launch rechecks local roots, source objects, CLI/authentication, configuration and sandbox before execution."
      if CheckpointPolicy.required?(prepared.fetch("task"))
        @out.puts "Worker milestone: authorized implementation, focused checks and canonical candidate; first transfer to operator for checkpoint record/verify and required host gates."
      else
        @out.puts "Worker milestone: authorized exempt task report; first transfer to operator for review and remaining host checks; no implementation checkpoint."
      end
      @out.puts "Write scope grants no publication authority; operator must review any configured automatic delivery before launch."
      @out.puts "Evidence: launch supplies an export/package path; host evidence register retains worker claims, checkpoint gate captures validation. Use act share tunnel, then act share #{id}; managers discover exact scoped runs without pasted logs."
      prepared.fetch("write_collisions").each do |collision|
        repositories = collision.fetch("repositories")
        noun = repositories.length == 1 ? "repository" : "repositories"
        @out.puts "WARNING: #{id} shares writable #{noun} #{repositories.join(', ')} with " \
                  "#{collision.fetch('task_id')} (#{collision.fetch('status')})."
        @out.puts "Starting both concurrently is likely to make one stale when the other lands."
      end
      conflicts = coordinator.external_activity.conflicts(prepared.fetch("task"), state)
      unless conflicts.empty?
        @out.puts "WARNING: external activity conflict; preparation is a snapshot only; execution remains blocked until explicit end."
      end
      @out.puts
      prompt = prepared.fetch("prompt")
      @out.write(prompt)
      if (recommendation = prepared.fetch("task")["worker_recommendation"])
        @out.puts unless prompt.end_with?("\n")
        @out.puts
        @out.puts "Recommended worker model: #{recommendation.fetch('model')}"
        @out.puts "Thinking level: #{recommendation.fetch('thinking')}"
      end
    end

    # Parses one manual start, locks reservations, then prints durable overlap
    # observations. Invalid arguments, unsafe evidence or refusal raise Error.
    def start_command(argv)
      allow_write_collision = false
      options = {}
      parser = OptionParser.new do |opts|
        lifecycle_force_options(opts, options)
        opts.on("--allow-write-collision", "legacy manual assertion (isolation remains unverified)") do
          allow_write_collision = true
        end
      end
      parser.parse!(argv)
      id = argv.shift
      unless id && argv.empty?
        raise Error, "usage: agent-coding-tool start TASK [--allow-write-collision]"
      end

      state = coordinator.start(id, allow_write_collision: allow_write_collision, **options)
      display_override(state) if options[:force]
      if (overlap = state["write_overlap"])
        overlap.fetch("conflicts").each do |row|
          @out.puts "WARNING: #{id} overlaps #{row.fetch('task_id')} (#{row.fetch('status')}) on " \
                    "#{format_authorities(row.fetch('repositories').map { |name| state.fetch('snapshot').fetch(name).values_at('remote_url', 'branch') })}."
        end
        @out.puts "Manual start: isolation and worker liveness unverified; use separately isolated development and review integration."
      end
      @out.puts "Started #{id}: IN_FLIGHT"
    end

    def record_command(argv)
      record_result(
        argv,
        usage: "agent-coding-tool record TASK OUTCOME [--summary TEXT] [--next TEXT] [--artifact PATH] [--test RESULT]"
      )
    end

    def received_command(argv)
      record_result(
        argv,
        outcome: "candidate_complete",
        usage: "agent-coding-tool received TASK [--summary TEXT] [--artifact PATH] [--test RESULT]",
        success: ->(id, _outcome) { "Received #{id}: CANDIDATE" }
      )
    end

    def finish_command(argv)
      record_result(
        argv,
        outcome: "complete",
        usage: "agent-coding-tool finish TASK [--summary TEXT] [--artifact PATH] [--test RESULT]",
        success: ->(id, _outcome) { "Finished #{id}: COMPLETE" }
      )
    end

    # Records a human outcome under the managed reservation lock and prints its
    # lifecycle label. Malformed input or a competing reservation raises Error;
    # recording does not itself close out or retry a managed attempt.
    def record_result(argv, outcome: nil, usage:, success: nil)
      options = { tests: [] }
      parser = OptionParser.new do |opts|
        lifecycle_force_options(opts, options)
        opts.on("--summary TEXT", "short explicit result summary") { |value| options[:summary] = value }
        opts.on("--next TEXT", "explicit operator next action for a retryable outcome") do |value|
          options[:next_action] = value
        end
        opts.on("--artifact PATH", "patch or other handoff artifact") { |value| options[:artifact] = value }
        opts.on("--test RESULT", "record a test result such as 'rake=pass'; repeatable") { |value| options[:tests] << value }
      end
      parser.parse!(argv)
      id = argv.shift
      outcome ||= argv.shift
      unless id && outcome && argv.empty?
        raise Error, "usage: #{usage}"
      end

      state = coordinator.record(id, outcome: outcome, **options)
      display_override(state) if options[:force]
      @out.puts(success ? success.call(id, outcome) : "Recorded #{id}: #{outcome}")
    end

    # Resets ordinary runtime state or explains the deferred no-op. Invalid
    # arguments/state/locks raise Error; output identifies retained scheduling.
    def reset_command(argv)
      options = {}
      raise Error, "reset: repeated flags" if argv.count("--hard") > 1 || argv.count("--dry-run") > 1
      parser = OptionParser.new do |opts|
        lifecycle_force_options(opts, options)
        opts.on("--hard", "archive complete candidates and retire verified task resources") { options[:hard] = true }
        opts.on("--dry-run", "preview --hard without writes") { options[:dry_run] = true }
      end
      parser.require_exact = true
      parser.parse!(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool reset TASK [--hard [--dry-run]]" unless id && argv.empty?
      if options[:hard]
        raise Error, "reset --hard accepts neither --force nor --reason" if options[:force] || options[:reason]
        return hard_reset_command(id, dry_run: options[:dry_run])
      end
      raise Error, "reset: --dry-run requires --hard" if options[:dry_run]

      state = coordinator.reset(id, **options)
      display_override(state) if options[:force]
      if state.is_a?(Hash) && state.key?("icebox")
        @out.puts "#{id}: ICEBOX and runtime state retained; use act unicebox #{id} before resetting"
      else
        @out.puts "Reset #{id} runtime state"
      end
    end

    # Displays the complete affected scope, then requires one terminal-only,
    # default-no confirmation. Preview/decline perform no writes or preparation.
    # Success reports scheduler facts; preparation retains its own current gates.
    def hard_reset_command(id, dry_run: false)
      handler = TaskReset.new(data_root: @data_root, transport: @transport)
      preview = handler.preview(id)
      summary = preview.reject { |key, _value| %w[intent receipt].include?(key) }
      summary["attempts"] = preview.fetch("intent").fetch("attempts").map { |attempt|
        attempt.fetch("report").slice("attempt", "invocation_id", "status", "prepared_at") }
      summary["evidence"] = preview.fetch("intent").fetch("sources").map { |source| source.slice("path", "archive", "retire") }
      summary["phase"] = preview.dig("receipt", "phase")
      @out.puts JSON.pretty_generate(summary)
      return if dry_run
      if preview.fetch("noop")
        @out.puts "#{id}: already reset; no new archive or changes"
        return
      end
      raise InvalidState, "hard reset: #{preview.fetch('blockers').join('; ')}" unless preview.fetch("blockers").empty?
      @out.print "Hard reset #{id}? [y/N] "
      @out.flush
      unless @input.tty? && (answer = @input.gets) && answer.strip.match?(/\A(?:y|yes)\z/i)
        @out.puts "Declined; no changes made"
        return
      end
      result = handler.execute(id, preview: preview)
      status = coordinator.status(id)
      @out.puts "Hard reset #{id} complete; archive: #{result.fetch('archive')}"
      preview.fetch("resources").each do |resource|
        @out.puts "Retired: #{resource.fetch('path')}; retained branch: #{resource['branch'] || '(detached)'}"
      end
      @out.puts "#{id}: #{status.fetch('status')}#{status['reason'] ? '; ' + status.fetch('reason') : ''}"
      @out.puts "Next: act prepare #{id} (current definition, configuration, prerequisites and source checks still apply)"
    end

    # Adds only invocation-local metadata override consent and its optional reason.
    # OptionParser rejects malformed values; these flags are never worker inputs.
    def lifecycle_force_options(parser, options)
      parser.require_exact = true
      parser.on("--force", "audit an operator lifecycle declaration") { options[:force] = true }
      parser.on("--reason TEXT", "optional override/deferral reason") { |value| options[:reason] = value }
    end

    # Prints durable override facts only after successful publication. Returns
    # nil for ordinary state; unreadable audit/output errors remain failures.
    def display_override(state)
      return unless state.is_a?(Hash) && state["administrative_override"]
      path = state.fetch("administrative_override").fetch("audit_path")
      audit = StateStore.new(File.dirname(path)).load("result")
      @out.puts "Operator declaration: #{audit.fetch('write_status')}; audit/recovery: #{path}"
      audit.fetch("observations").each do |fact|
        @out.puts "  #{fact.fetch('rule')}: #{fact.fetch('status')}#{fact['detail'] ? "; #{fact['detail']}" : ''}"
      end
      @out.puts "Verification, resource retirement, execution and publication require their own checks/authority."
    end

    # Prints command usage and explicit planning designation to the output stream;
    # returns puts' result. Output I/O errors propagate to the caller.
    def help
      @out.puts <<~HELP
        agent-coding-tool — small local coordinator for human-directed coding agents

        Data:
          Defaults to a sibling <tool-directory>-data directory.
          Override with AGENT_CODING_TOOL_DATA_DIR=/path/to/data.

        Implementation:
          Published split by default; provision the pinned packages before startup.
          ACT_IMPLEMENTATION=legacy selects rollback without split packages.
          ACT_IMPLEMENTATION=split selects split explicitly; invalid values refuse.

        Commands:
          implementation             resolved mode and verified package source identities
          share tunnel [--min MINUTES]  foreground read tunnel, default 60 (maximum 60)
          share TASK [PATH_TO_ZIP] [--min MINUTES] grant/renew task visibility; optional ZIP up to 4 MiB
          share {status|stop}; share revoke TASK; share help
          share source grant ID --code-root PATH --root REPOSITORY [--min MINUTES]
          share source revoke ID      revoke live source independently of task evidence
                              zero tasks on startup; whole configured Work workspace audience
                              setup required once; no execution/publication; delivered bytes cannot be recalled
          manage TASK [--stdout]
          manager start TASK --id ID
          manager bind ID --task TASK --attempt N --invocation ID --session ID
          manager review ID --session ID
                              copy a local task-goal reminder with pbcopy; --stdout prints only
                              source path/hash included; no progress claims or task-state writes
          evidence open --grant PRIVATE.json --session NEW_PRIVATE_DIRECTORY --env-file /CANONICAL/ACT/.env
                        --client /CANONICAL/tunnel-client --runtime-dir SHARED_PRIVATE_DIRECTORY
                              foreground finite owner-approved tunnel; explicit canonical paths
                              nonblank OPENAI_TUNNEL_KEY overrides .env; no key prompt or global dotenv load
                              later session needs a new approved grant/path; status/stop use durable ledger
          evidence start --grant PRIVATE.json --session NEW_PRIVATE_DIRECTORY
          evidence {serve|status|stop} --session PRIVATE_DIRECTORY
          evidence select --session DIR --task TASK --attempt N --invocation ID --codex-session ID
          evidence read --session DIR --task TASK --attempt N --invocation ID --codex-session ID
                              --handle SHA --revision SHA --artifact NAME --offset N --length N
                              finite on-demand read only; external ingress requires owner approval
          evidence register --task TASK --attempt N --invocation ID --codex-session ID
                              --package PATH --sha256 SHA
                              host copy from the exact recorded fixture; worker claims, not acceptance
          evidence capture --task TASK -- codex exec ...
                              bounded local follow-up capture and exact task registration
          evidence register-followup --task TASK --invocation ID --sha256 SHA
                              recover one interrupted local follow-up capture
          apply FILE.json     review a patch; separately confirm apply, validation and local commit
                              terminal consent required; each defaults to no; no publication
                              baseline drift/unrelated untracked files warn; later changes refuse
          status [TASK] [--all | --active] [--min | --full]
          status --fam FAMILY [--all | --active] [--min | --full]
                              show the complete READY family; global NEXT only
          status --icebox [--fam FAMILY] [--all | --active] [--min | --full]
                              show only deferred work; --all/--fam include Icebox last
          --min               default: one bounded row per task; no details or summaries
          --full              expanded warnings, reasons, next steps and summaries
                              status TASK --full shows complete per-task diagnostics
                              --min/--full are exclusive; selection and global NEXT unchanged
          icebox TASK [--reason TEXT]
                              defer unstarted READY work; identical reason is a no-op
          unicebox TASK       explicitly restore normal eligibility computation
          next [--json]       advise safe parallel work without changing state
          external report TASK --reporter TEXT --kind TEXT [--identifier TEXT]
                              [--scope-complete] [--write-repository REMOTE,BRANCH]
                              [--note TEXT] [--reference TEXT]
                              report unmanaged activity; grants no execution authority
          external show TASK  inspect bounded private history (read-only)
          external end TASK OBSERVATION_ID --disposition ended|failed|lost-contact
                              operator closeout; proves neither exit nor result quality
          prepare TASK [--retry]
          start TASK [--allow-write-collision]
                              mark a prepared task in flight (human assertion)
          launch TASK --codex [--allow-write-collision] [--model MODEL] [--reasoning LEVEL]
                              prepare/start and run one foreground local worker
                              verified managed overlap is automatic; manual overlap requires the flag
          checkpoint export TASK --workspace PATH --base SHA --artifact PATH [--remote NAME]
                              [--repository NAME [--focused PATH]]
                              canonical-format-check candidate; no host state writes or test attestation
          checkpoint record TASK --workspace PATH [--artifact PATH]
          checkpoint verify TASK [--workspace PATH | --attempt NUMBER]
          checkpoint gate TASK [--force] [--reason TEXT] --workspace PATH -- COMMAND [ARGS...]
                              records private invocation receipts; optional gate flags:
                              --requested-seed NUMBER --requested-selection TEXT
                              --observations PATH (fresh private command-report JSON)
          checkpoint recover TASK --destination PATH --confirm-disconnected [--attempt NUMBER]
          worktrees TASK      verify and show task-owned worktree ownership
          cleanup TASK [--dry-run] [--pr URL|ALIAS-NUMBER]
                              inspect removal targets and blockers; changes nothing
          abandon-preflight TASK [--dry-run]
                              verify and explicitly abandon one failed pre-worker launch
          close-attempt TASK [--dry-run]
                              preserve unsuccessful attempts for explicit fresh retry
          received TASK [--summary TEXT] [--artifact PATH] [--test RESULT]
                              worker result is ready for human review/application
          finish TASK [--summary TEXT] [--artifact PATH] [--test RESULT]
                              landed task is complete on authoritative pushed state
          record TASK OUTCOME [--summary TEXT] [--next TEXT] [--artifact PATH] [--test RESULT]
                              generic/manual outcome primitive
          reset TASK [--force] [--reason TEXT]
          reset TASK --hard [--dry-run]
                              same as reset --hard TASK; preview then one terminal yes/no
                              complete private archive before exact owned worktree removal
                              clears deferral; branches and historical outcomes survive
                              interrupted reset blocks admission; repeat the same command
                              ordinary prepare TASK follows; READY is conditional
          publish [TASK | --all] [--dry-run]
                              explicitly commit and push ACTD changes

        READY dashboard:
          ACT family first, then parallel unlock width, unlock count, depth/count,
          then natural task-ID ties. Advisory only; reservations still apply.
          READY CL-WLO-01 leads CL within existing CL positions; acceptance required.
          Families use the first hyphen prefix; empty/no prefix uses the whole ID.
          At 7+ READY: 4+ families get one each; 1-3 families get at most six
          rows, breadth first, at most three per family. A hidden READY NEXT
          replaces the lowest displayed member of its family; global order holds.
          Summaries count total/hidden READY. --all, --fam and TASK do not compress.
          --fam is exact and exclusive with TASK; --all and --active conflict.
          The recent COMPLETE window is global, before family filtering.
          Default/--active hide Icebox rows except open external reports, then count all.
          Administrative prepare/start/record/received/finish/reset/icebox/unicebox
          accept --force before or after TASK, with optional --reason TEXT.
          Force is an audited operator declaration, not verification, worker
          liveness, resource retirement, delivery or publication authority.
          Exact original bytes and intent/result are preserved in private
          <data-root>-runs/.lifecycle-overrides/TASK/UUID; inspect hashes after interruption.
          Force gate preserves lifecycle bytes and checkpoint attempt, requires
          verification and durable receipts, and retains child failure results.
          --hard accepts neither --force nor --reason; EOF/nonterminal input declines.

          Icebox is scheduling, not an outcome; it never receives a start recommendation.
          Only unstarted READY may enter. Prepare/start/launch/record refuse it;
          reset retains it. All writers share the private launch reservation lock.
          State YAML icebox: {at: ISO-8601 string, reason: optional string} is
          atomically replaced; unicebox removes only that mapping. Different
          repeated reasons require unicebox first; identical repeats keep time.
          --icebox may combine with --fam/--all/--active, never TASK.

        Outcomes:
          candidate_complete  worker result is ready for human application/review
          complete            task is complete on authoritative pushed state
          blocked             task cannot proceed under current dependencies/boundary
          needs_judgment      human decision is required before continuing
          failed              attempt failed without a more specific disposition

        Planning guidance:
          Task YAML planning_guidance: required opts into full pinned planning
          guidance before plan/task-definition outputs. Omit for ordinary work.
          Designation/pin changes require evidence preservation and explicit
          operator reset/re-preparation; retry alone does not migrate pins.

        External activity:
          Reporter/process facts are operator-reported. Last-reported time is
          not a heartbeat: liveness unknown, isolation/containment unverified.
          Scope defaults to unknown and blocks new writers; --scope-complete
          reserves registered/prepared writers plus reported additions, across
          branches. Disjoint bounded writers may proceed. Overrides cannot bypass
          external conflicts. Existing lifecycle/freshness/recovery gates apply.
          Exact retained identifier/payload repeats are no-ops; other duplicate
          reports refuse. Keep one active and eight closed observations per task.
          End requires its observation ID; retained repeats are idempotent.
          Notes/references are private inert text, never imported or published.
          Ending changes no lifecycle or result; separately review any candidate.
      HELP
    end
  end
end
