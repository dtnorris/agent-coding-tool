# frozen_string_literal: true

require "optparse"
require "io/console"
require "time"
require "json"

module AgentCodingTool
  class CLI
    STATUS_ORDER = {
      "COMPLETE" => 0,
      "CANDIDATE" => 10,
      "NEEDS_JUDGMENT" => 20,
      "IN_FLIGHT" => 30,
      "READY" => 40,
      "PREPARED" => 50,
      "STALE_CANDIDATE" => 60,
      "STALE" => 70,
      "FAILED" => 80,
      "BLOCKED" => 100
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
      when "status" then status_command(argv)
      when "next" then next_command(argv)
      when "prepare" then prepare_command(argv)
      when "start" then start_command(argv)
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

    def status_command(argv)
      options = { completion_filter: :recent }
      parser = OptionParser.new do |opts|
        opts.on("--all", "show every task, including all completed tasks") { options[:all] = true }
        opts.on("--active", "show no completed tasks") { options[:active] = true }
      end
      parser.parse!(argv)
      if options[:all] && options[:active]
        raise Error, "status --all and --active are mutually exclusive"
      end
      options[:completion_filter] = :all if options[:all]
      options[:completion_filter] = :active if options[:active]

      id = argv.shift
      raise Error, "usage: agent-coding-tool status [TASK] [--all | --active]" unless argv.empty?

      statuses = if id
                   coordinator.statuses([id])
                 else
                   coordinator.statuses(completion_filter: options.fetch(:completion_filter))
                 end
      broad_dashboard = id.nil?
      completion_metrics = {}
      if broad_dashboard
        completion_metrics = completion_dashboard_metrics(statuses)
        statuses = sort_statuses(statuses, completion_metrics)
        if coordinator.respond_to?(:next_start_set)
          selection = coordinator.next_start_set(statuses, statuses)
          display_next_summary(selection, statuses)
        end
        statuses = limit_blocked_statuses(statuses) unless options[:all]
      end
      previous_bucket = nil

      statuses.each do |item|
        bucket = status_bucket(item.fetch("status"))
        @out.puts if broad_dashboard && previous_bucket && bucket != previous_bucket

        if broad_dashboard
          display_dashboard_item(item, completion_metrics)
        else
          status = item.fetch("status")
          @out.puts "#{item.fetch('id')}: #{colorize_status(status)} — #{item.fetch('title')}"
          display_explicit_details(item)
        end
        previous_bucket = bucket
      end
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

      display_next_section("Waiting for write capacity", selection.fetch("waiting_capacity")) do |row|
        conflicts = row.fetch("conflicts").map do |conflict|
          "#{conflict.fetch('task_id')} (#{conflict.fetch('status')}) on " \
            "#{format_authorities(conflict.fetch('authorities'))}"
        end
        @out.puts "  #{row.fetch('id')} (#{row.fetch('status')}): #{conflicts.join('; ')}"
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
        @out.puts "  #{status.fetch('id')} (#{status.fetch('status')}): #{status.fetch('reason')}"
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
            { "id" => id, "status" => status.fetch("status"), "reason" => status["reason"],
              "depends_on" => tasks.fetch(id).fetch("depends_on", []),
              "priority_rank" => priority.fetch(id),
              "freshness" => next_freshness(status, tasks.fetch(id)) }
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
              "category" => "wait_write_capacity",
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
      }
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

    def display_next_summary(selection, ranked_statuses)
      first = selection.fetch("starts").first
      text = if first
               id = first.fetch("id")
               label = first.fetch("status")
               action = label == "READY" ? "prepare then start" : "start"
               summary = "NEXT: #{id} (#{colorize_status(label)}) — #{action}"
               others = selection.fetch("starts").length - 1
               summary << "; +#{others} parallel" if others.positive?
               summary
             elsif (candidate = ranked_statuses.find { |item| item.fetch("status") == "CANDIDATE" })
               "NEXT: review #{candidate.fetch('id')} (#{colorize_status('CANDIDATE')})"
             elsif (waiting = selection.fetch("waiting_capacity").first)
               "NEXT: #{waiting.fetch('id')} waits for write capacity"
             elsif (intervention = ranked_statuses.find do |item|
                       %w[STALE STALE_CANDIDATE NEEDS_JUDGMENT FAILED].include?(item.fetch("status")) ||
                         (item.fetch("status") == "BLOCKED" && item.dig("state", "result", "outcome") == "blocked")
                     end)
               "NEXT: #{intervention.fetch('id')} (#{colorize_status(intervention.fetch('status'))}) needs intervention"
             elsif ranked_statuses.any? { |item| item.fetch("status") == "BLOCKED" }
               "NEXT: waiting for dependencies"
             elsif selection.fetch("occupied").any?
               "NEXT: work in flight; no safe new starts"
             else
               "NEXT: no startable work"
             end
      suffix = "; details: act next"
      width = dashboard_width
      line = "#{text}#{suffix}"
      if display_width(line) > width && width >= display_width(suffix) + 10
        line = "#{truncate_display_line(text, width - display_width(suffix))}#{suffix}"
      end
      @out.puts truncate_display_line(line, width)
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

    def sort_statuses(statuses, completion_metrics)
      statuses.each_with_index
              .sort_by do |item, index|
                status = item.fetch("status")
                depth, count, unlock_count, parallel_width =
                  completion_metrics.fetch(item.fetch("id"), [0, 0, 0, 0])
                ready_rank = status == "READY" ? [-parallel_width, -unlock_count, -depth, -count] : [0, 0, 0, 0]
                complete_rank = status == "COMPLETE" ? completion_rank(item) : [0, 0]
                blocked_rank = status == "BLOCKED" ? blocked_dependency_count(item) : 0
                [STATUS_ORDER.fetch(status, 90), *ready_rank, *complete_rank, blocked_rank, index]
              end
              .map(&:first)
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
        next true unless item.fetch("status") == "BLOCKED"

        blocked_seen += 1
        blocked_seen <= BLOCKED_DISPLAY_LIMIT
      end
    end

    def status_bucket(status)
      case status
      when "COMPLETE" then 0
      when "CANDIDATE" then 1
      when "NEEDS_JUDGMENT" then 2
      when "IN_FLIGHT" then 3
      when "READY" then 4
      when "BLOCKED" then 6
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

    def display_dashboard_item(item, completion_metrics)
      id = item.fetch("id")
      status = item.fetch("status")
      colored_prefix = "#{id}: #{colorize_status(status)} — "
      title = normalize_dashboard_text(item.fetch("title"))
      @out.puts truncate_display_line("#{colored_prefix}#{title}", dashboard_width)

      if status == "IN_FLIGHT"
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

    def display_explicit_details(item)
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

    def display_dashboard_write_collisions(item)
      collisions = write_collisions(item)
      return if collisions.empty?

      detail = collisions.map { |collision| write_collision_detail(collision, prefix: false) }.join("; ")
      count = collisions.length
      summary = count == 1 ? "cannot start; #{detail}" : "cannot start; #{count} blockers: #{detail}"
      @out.puts compact_detail_line("reason", summary)
    end

    def write_collisions(item)
      item.fetch("write_collisions", [])
    end

    def write_collision_detail(collision, prefix: true)
      repositories = collision.fetch("repositories").join(", ")
      detail = "#{collision.fetch('task_id')} (#{collision.fetch('status')}) writes #{repositories}"
      prefix ? "cannot start; #{detail}" : detail
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
      prepared.fetch("write_collisions").each do |collision|
        repositories = collision.fetch("repositories")
        noun = repositories.length == 1 ? "repository" : "repositories"
        @out.puts "WARNING: #{id} shares writable #{noun} #{repositories.join(', ')} with " \
                  "#{collision.fetch('task_id')} (#{collision.fetch('status')})."
        @out.puts "Starting both concurrently is likely to make one stale when the other lands."
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

    def start_command(argv)
      allow_write_collision = false
      parser = OptionParser.new do |opts|
        opts.on("--allow-write-collision", "explicitly allow concurrent write/write work") do
          allow_write_collision = true
        end
      end
      parser.parse!(argv)
      id = argv.shift
      unless id && argv.empty?
        raise Error, "usage: agent-coding-tool start TASK [--allow-write-collision]"
      end

      coordinator.start(id, allow_write_collision: allow_write_collision)
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

    def reset_command(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool reset TASK" unless id && argv.empty?

      coordinator.reset(id)
      @out.puts "Reset #{id} runtime state"
    end

    def help
      @out.puts <<~HELP
        agent-coding-tool — small local coordinator for human-directed coding agents

        Data:
          Defaults to a sibling <tool-directory>-data directory.
          Override with AGENT_CODING_TOOL_DATA_DIR=/path/to/data.

        Commands:
          status [TASK] [--all | --active]
          next [--json]       advise safe parallel work without changing state
          prepare TASK [--retry]
          start TASK [--allow-write-collision]
                              mark a prepared task in flight (human assertion)
          received TASK [--summary TEXT] [--artifact PATH] [--test RESULT]
                              worker result is ready for human review/application
          finish TASK [--summary TEXT] [--artifact PATH] [--test RESULT]
                              landed task is complete on authoritative pushed state
          record TASK OUTCOME [--summary TEXT] [--next TEXT] [--artifact PATH] [--test RESULT]
                              generic/manual outcome primitive
          reset TASK
          publish [TASK | --all] [--dry-run]
                              explicitly commit and push ACTD changes

        Outcomes:
          candidate_complete  worker result is ready for human application/review
          complete            task is complete on authoritative pushed state
          blocked             task cannot proceed under current dependencies/boundary
          needs_judgment      human decision is required before continuing
          failed              attempt failed without a more specific disposition
      HELP
    end
  end
end
