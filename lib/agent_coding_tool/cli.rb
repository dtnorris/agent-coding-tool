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

    def self.run(argv, root: Dir.pwd, out: $stdout, err: $stderr, data_root: nil)
      new(root: root, out: out, err: err, data_root: data_root).run(argv)
    end

    def self.default_data_root(root, env: ENV)
      override = env["AGENT_CODING_TOOL_DATA_DIR"]
      return File.expand_path(override) if override && !override.empty?

      File.expand_path("../#{File.basename(root)}-data", root)
    end

    def initialize(root:, out:, err:, data_root: nil, terminal_width: nil)
      @root = root
      @out = out
      @err = err
      @data_root = data_root || self.class.default_data_root(root)
      @terminal_width = terminal_width
    end

    def run(argv)
      command = argv.shift
      case command
      when "apply" then return apply_command(argv)
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

    # Opens finite operator-granted read sessions; select/read use the same closed
    # reader as MCP. Returns zero or a fixed refusal, never executes evidence.
    def evidence_command(argv)
      action = argv.shift
      options = {}
      parser = OptionParser.new do |opts|
        %w[session grant task invocation codex-session handle revision artifact].each do |name|
          opts.on("--#{name} VALUE") { |value| options[name] = value }
        end
        %w[attempt offset length].each do |name|
          opts.on("--#{name} NUMBER", Integer) { |value| options[name] = value }
        end
      end
      parser.require_exact = true
      parser.parse!(argv)
      allowed = case action
                when "start" then %w[session grant]
                when "serve", "status", "stop" then %w[session]
                when "select" then %w[session task attempt invocation codex-session]
                when "read" then %w[session task attempt invocation codex-session handle revision artifact offset length]
                else []
                end
      raise RunEvidenceReader::Refused, "cli.fields" unless argv.empty? && !allowed.empty? && options.keys.sort == allowed.sort
      if action == "start"
        result = EvidenceSession.start(options.fetch("session"), options.fetch("grant"))
      else
        session = EvidenceSession.new(options.fetch("session"))
        case action
        when "serve" then return EvidenceAdapter.new(session, err: @err).serve($stdin, @out) || 0
        when "status" then result = session.status
        when "stop" then result = session.stop
        else
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
    rescue RunEvidenceReader::Refused, SystemCallError, JSON::ParserError, ArgumentError, OptionParser::ParseError
      @err.puts "ERROR: evidence session refused; check private grant, exact run identity and session status"
      2
    end

    # Applies one downloaded JSON proposal with independent terminal confirmations;
    # returns the handler status. Invalid CLI arguments raise without mutation.
    def apply_command(argv)
      raise Error, "usage: agent-coding-tool apply FILE.json" unless argv.length == 1 && !argv.first.start_with?("-")
      ApplyHandoff.new(config: Config.load(File.join(@data_root, "config.yml")), out: @out, err: @err).run(argv.first)
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
        opts.on("--reason TEXT", "optional reason for intentional deferral") { |value| options[:reason] = value } unless restore
      end
      parser.require_exact = true
      parser.parse!(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool #{restore ? 'unicebox TASK' : 'icebox TASK [--reason TEXT]'}" unless id && argv.empty?

      if restore
        coordinator.unicebox(id)
        @out.puts "Restored #{id}; eligibility will be recomputed from lifecycle and dependencies"
      else
        coordinator.icebox(id, **options)
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
      result = DeliveryManager.new(data_root: @data_root, coordinator: coordinator).deliver(id, run_dir: dirs.first)
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
        opts.on("--destination PATH") { |value| options[:destination] = value }
        opts.on("--confirm-disconnected") { options[:confirm_disconnected] = true }
        opts.on("--attempt NUMBER", Integer) { |value| options[:attempt] = value }
        opts.on("--requested-seed NUMBER", Integer) { |value| options[:seed] = value }
        opts.on("--requested-selection TEXT") { |value| options[:selection] = value }
        opts.on("--observations PATH") { |value| options[:observations] = value }
      end
      parser.order!(argv)
      if action != "export" && options.keys.any? { |key| %i[base remote].include?(key) }
        raise Error, "checkpoint: base and remote are export-only options"
      end
      if action != "gate" && options.keys.any? { |key| %i[seed selection observations].include?(key) }
        raise Error, "checkpoint: requested settings and observations are gate-only options"
      end
      checkpoint = Checkpoint.new(data_root: @data_root, err: @err)
      result = case action
               when "export"
                 unless argv.empty? && options[:workspace] && options[:artifact] && options[:base] &&
                        (options.keys - %i[workspace artifact base remote]).empty?
                   raise Error, "checkpoint export requires --workspace PATH --base SHA --artifact PATH [--remote NAME]"
                 end
                 checkpoint.export(id, workspace: options.fetch(:workspace), base_sha: options.fetch(:base),
                                   artifact: options.fetch(:artifact), remote: options.fetch(:remote, "origin"))
               when "record"
                 raise Error, "checkpoint record requires --workspace" unless options[:workspace] && argv.empty? && !options[:destination] && !options[:attempt]
                 checkpoint.record(id, workspace: options.fetch(:workspace), artifact: options[:artifact])
               when "verify"
                 raise Error, "checkpoint verify accepts only --workspace" unless argv.empty? && !options[:artifact] && !options[:destination]
                 checkpoint.verify(id, workspace: options[:workspace], attempt: options[:attempt])
               when "gate"
                 raise Error, "checkpoint gate requires --workspace PATH -- COMMAND" unless options[:workspace] && argv.any? && !options[:artifact] && !options[:destination] && !options[:attempt]
                 checkpoint.gate(id, workspace: options.fetch(:workspace), command: argv,
                                 requested: options.slice(:seed, :selection), observations: options[:observations])
               when "recover"
                 raise Error, "checkpoint recover requires --destination and --confirm-disconnected" unless
                   options[:destination] && options[:confirm_disconnected] && argv.empty? && !options[:workspace] && !options[:artifact]
                 checkpoint.recover(id, destination: options.fetch(:destination), confirm_disconnected: true, attempt: options[:attempt])
               end
      @out.puts JSON.pretty_generate(result)
      0
    end

    # Prints independent historical inventories or delegates existing cleanup.
    # Inspection writes nothing and returns nonzero for damaged records while
    # retaining valid rows; unsafe arguments/cleanup preconditions raise Error.
    def worktree_command(argv, cleanup:)
      id = argv.shift
      if !id&.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) ||
         (cleanup ? ![[], ["--dry-run"]].include?(argv) : !argv.empty?)
        raise Error, "usage: agent-coding-tool #{cleanup ? 'cleanup TASK [--dry-run]' : 'worktrees TASK'}"
      end
      if cleanup
        dry_run = argv == ["--dry-run"]
        handler = CleanupManager.new(data_root: @data_root)
        result = dry_run ? handler.preflight(id) : handler.remove(id)
        @out.puts JSON.pretty_generate(result.merge("dry_run" => dry_run,
                                                     "attempts" => [result.fetch("attempts")]))
        return 0
      end
      root = File.join("#{@data_root}-runs", id)
      raise InvalidState, "#{id}: no run evidence" unless File.directory?(root) && !File.symlink?(root)
      history = AttemptRecovery.new(data_root: @data_root).inspect(id)
      records = IncidentalMetadata.children(root).sort.map do |attempt|
        directory = File.join(root, attempt)
        historical = history.find { |row| row["run_dir"] == directory }
        raise InvalidState, "#{id}: partial/foreign run evidence" if File.symlink?(directory) || !File.directory?(directory)
        path = File.join(directory, "worktrees.json")
        next historical unless File.file?(path) && !File.symlink?(path)
        manager = WorktreeManager.new(root: Config.load(File.join(@data_root, "config.yml")).worktree_root, record_path: path)
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
      @out.puts JSON.pretty_generate("task_id" => id, "attempts" => records)
      records.any? { |row| row.nil? || !row.fetch("blockers", []).empty? } ? 2 : 0
    rescue JSON::ParserError, KeyError, TypeError
      raise InvalidState, "#{id}: malformed worktree/delivery evidence"
    end

    def abandon_preflight_command(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool abandon-preflight TASK [--dry-run]" unless
        id&.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/) && [[], ["--dry-run"]].include?(argv)
      recovery = PreflightRecovery.new(data_root: @data_root)
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
      recovery = AttemptRecovery.new(data_root: @data_root)
      @out.puts JSON.pretty_generate(argv == ["--dry-run"] ? recovery.preflight(id) : recovery.close(id))
      0
    end

    def launch_command(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.on("--codex", "launch one local ChatGPT Codex worker") { options[:codex] = true }
        opts.on("--allow-write-collision", "authorize isolated development, including unverified manual reservations") { options[:allow_write_collision] = true }
        opts.on("--model MODEL", "explicit Codex model override; recommendation is advisory") { |value| options[:model] = value }
        opts.on("--reasoning LEVEL", "explicit minimal/low/medium/high/xhigh reasoning") { |value| options[:reasoning] = value }
      end
      parser.parse!(argv)
      unless options.delete(:codex) && argv.length == 1
        raise Error, "usage: agent-coding-tool launch TASK --codex [--allow-write-collision] [--model MODEL] [--reasoning LEVEL]"
      end
      Launcher.new(coordinator: coordinator, data_root: @data_root, source_root: @root, out: @out, err: @err)
              .launch(argv.first, **options)
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
                                task_store: TaskStore.new(File.join(@data_root, "tasks")))
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
          repo_inspector: RepoInspector.new(config),
          prompt_renderer: PromptRenderer.new,
          prompt_root: File.join(@data_root, "state", "prompts")
        )
      end
    end

    # Renders explicit details or a broad dashboard from one effective snapshot.
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
      end
      parser.require_exact = true
      parser.parse!(argv)
      if options[:all] && options[:active]
        raise Error, "status --all and --active are mutually exclusive"
      end
      options[:completion_filter] = :all if options[:all]
      options[:completion_filter] = :active if options[:active]

      id = argv.shift
      unless argv.empty? && !(id && (options.key?(:family) || options[:icebox]))
        raise Error, "usage: agent-coding-tool status [TASK | --fam FAMILY] [--all | --active] [--icebox]"
      end
      if options.key?(:family) && !coordinator.tasks.any? { |task| task_family(task.fetch("id")) == options[:family] }
        raise Error, "unknown task family: #{options[:family]}"
      end

      statuses = if id
                   coordinator.statuses([id])
                 else
                   coordinator.statuses(completion_filter: options.fetch(:completion_filter))
                 end
      broad_dashboard = id.nil?
      deferred = statuses.select { |item| item.fetch("status") == "ICEBOX" }
      compact_icebox = broad_dashboard && !options[:all] && !options.key?(:family) && !options[:icebox]
      completion_metrics = {}
      next_id = nil
      family_summaries = {}
      if broad_dashboard
        completion_metrics = completion_dashboard_metrics(statuses)
        statuses = sort_statuses(statuses, completion_metrics)
        if coordinator.respond_to?(:next_start_set)
          selection = coordinator.next_start_set(statuses, statuses)
          next_id = next_status_id(selection, statuses)
        end
        # Presentation subgroups must not change scheduling or global NEXT.
        statuses = sort_statuses(statuses, completion_metrics, dashboard: true)
        if options.key?(:family)
          statuses = statuses.select { |item| task_family(item.fetch("id")) == options[:family] }
        elsif !options[:all]
          statuses, family_summaries = compress_ready_statuses(statuses, next_id:)
        end
        statuses = statuses.select { |item| item.fetch("status") == "ICEBOX" } if options[:icebox]
        statuses = statuses.reject { |item| item.fetch("status") == "ICEBOX" && !item["external_activity"] } if compact_icebox
        statuses = limit_blocked_statuses(statuses) unless options[:all]
      end
      previous_bucket = nil

      statuses.each do |item|
        if options[:minimal]
          display_minimal_item(item, next_id:)
          next
        end

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

      plan = next_plan
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
                   "inspect act stat #{item.fetch('id')}"
                 end
      movement = "#{sources.length} changed; act stat #{item.fetch('id')}; #{movement}" if sources.length > 1
      @out.puts compact_detail_line("source", movement)
      isolation = if item.dig("execution_evidence", "isolation") == "last_verified_at_launch" &&
                     !item.dig("state", "write_collision_override", "launch", "unverified_manual_conflicts")
                    "isolation last verified at launch"
                  else
                    "isolation unverified"
                  end
      @out.puts compact_detail_line("next", "reconcile before delivery; liveness unknown; #{isolation}")
    end

    # Prints one bounded row from existing projection evidence, without details,
    # probes or writes. Status/NEXT and warning indicators precede the title;
    # long IDs shrink first when the remaining prefix fits. At extreme widths
    # even identity/status/warnings must truncate. Missing fields/output errors
    # propagate; indicators grant no freshness, isolation, liveness or authority.
    def display_minimal_item(item, next_id:)
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
      display_id = normalize_minimal_text(item.fetch("id"))
      identity_width = dashboard_width - display_width(": #{status}")
      display_id = truncate_display_line(display_id, identity_width) if identity_width.positive?
      title = normalize_minimal_text(item.fetch("title"))
      row = "#{display_id}: #{status}"
      title_width = dashboard_width - display_width(row) - display_width(" — ")
      row += " — #{truncate_display_line(title, title_width)}" if title_width.positive?
      @out.puts truncate_display_line(row, dashboard_width)
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

      if %w[READY CANDIDATE].include?(status)
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
        detail.call("integration", compact ? "not approved; inspect act status #{item.fetch('id')}" : handoff.fetch("next_action"))
      end
      if (overlap = item.dig("state", "write_overlap"))
        others = overlap.fetch("conflicts").map { |row| "#{row.fetch('task_id')} (#{row.fetch('status')})" }.join(", ")
        detail.call("overlap", "#{overlap.fetch('basis')} with #{others}; observed #{overlap.fetch('observed_at')}; not a live isolation check")
      end
      return unless override.is_a?(Hash) && override["conflicts"].is_a?(Array) && !override["conflicts"].empty?

      kind = if override.dig("launch", "unverified_manual_conflicts")
               "operator-authorized development; new worker checked at launch; external isolation/liveness unverified; managed delivery disabled"
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

    def truncate_display_line(text, width)
      return text if display_width(text) <= width
      return "." * width if width < 3

      available = width - 3
      prefix = +""
      used = 0
      text.scan(DISPLAY_TOKEN).each do |token|
        token_width = display_width(token)
        break if used + token_width > available

        prefix << token
        used += token_width
      end
      prefix << ANSI_RESET if prefix.match?(ANSI_SEQUENCE)
      "#{prefix}..."
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
      parser = OptionParser.new do |opts|
        opts.on("--retry", "discard the recorded non-complete outcome and prepare a new attempt") { retry_result = true }
      end
      parser.parse!(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool prepare TASK [--retry]" unless id && argv.empty?

      prepared = coordinator.prepare(id, retry_result: retry_result)
      state = prepared.fetch("state")
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
      parser = OptionParser.new do |opts|
        opts.on("--allow-write-collision", "legacy manual assertion (isolation remains unverified)") do
          allow_write_collision = true
        end
      end
      parser.parse!(argv)
      id = argv.shift
      unless id && argv.empty?
        raise Error, "usage: agent-coding-tool start TASK [--allow-write-collision]"
      end

      state = coordinator.start(id, allow_write_collision: allow_write_collision)
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

      coordinator.record(id, outcome: outcome, **options)
      @out.puts(success ? success.call(id, outcome) : "Recorded #{id}: #{outcome}")
    end

    # Resets ordinary runtime state or explains the deferred no-op. Invalid
    # arguments/state/locks raise Error; output identifies retained scheduling.
    def reset_command(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool reset TASK" unless id && argv.empty?

      state = coordinator.reset(id)
      if state.is_a?(Hash) && state.key?("icebox")
        @out.puts "#{id}: ICEBOX and runtime state retained; use act unicebox #{id} before resetting"
      else
        @out.puts "Reset #{id} runtime state"
      end
    end

    # Prints command usage and explicit planning designation to the output stream;
    # returns puts' result. Output I/O errors propagate to the caller.
    def help
      @out.puts <<~HELP
        agent-coding-tool — small local coordinator for human-directed coding agents

        Data:
          Defaults to a sibling <tool-directory>-data directory.
          Override with AGENT_CODING_TOOL_DATA_DIR=/path/to/data.

        Commands:
          evidence start --grant PRIVATE.json --session NEW_PRIVATE_DIRECTORY
          evidence {serve|status|stop} --session PRIVATE_DIRECTORY
          evidence select --session DIR --task TASK --attempt N --invocation ID --codex-session ID
          evidence read --session DIR --task TASK --attempt N --invocation ID --codex-session ID
                              --handle SHA --revision SHA --artifact NAME --offset N --length N
                              finite on-demand read only; external ingress requires owner approval
          apply FILE.json     review a patch; separately confirm apply, validation and local commit
                              terminal consent required; each defaults to no; no publication
                              baseline drift/unrelated untracked files warn; later changes refuse
          status [TASK] [--all | --active] [--min]
          status --fam FAMILY [--all | --active] [--min]
                              show the complete READY family; global NEXT only
          status --icebox [--fam FAMILY] [--all | --active] [--min]
                              show only deferred work; --all/--fam include Icebox last
          --min               one bounded row per displayed task; no details or summaries
                              omit --min for full warnings; selection and global NEXT unchanged
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
          checkpoint export TASK --workspace PATH --base SHA --artifact PATH [--remote NAME]
                              canonical-format-check candidate; no host state writes or test attestation
          checkpoint record TASK --workspace PATH [--artifact PATH]
          checkpoint verify TASK [--workspace PATH | --attempt NUMBER]
          checkpoint gate TASK --workspace PATH -- COMMAND [ARGS...]
                              records private invocation receipts; optional gate flags:
                              --requested-seed NUMBER --requested-selection TEXT
                              --observations PATH (fresh private command-report JSON)
          checkpoint recover TASK --destination PATH --confirm-disconnected [--attempt NUMBER]
          worktrees TASK      verify and show task-owned worktree ownership
          cleanup TASK [--dry-run]
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
          reset TASK
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
