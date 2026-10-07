# frozen_string_literal: true

require "optparse"
require "io/console"

module AgentCodingTool
  class CLI
    STATUS_ORDER = {
      "COMPLETE" => 0,
      "CANDIDATE" => 10,
      "IN_FLIGHT" => 20,
      "READY" => 30,
      "PREPARED" => 40,
      "NEEDS_JUDGMENT" => 50,
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
      when "prepare" then prepare_command(argv)
      when "start" then start_command(argv)
      when "received" then received_command(argv)
      when "finish" then finish_command(argv)
      when "record" then record_command(argv)
      when "reset" then reset_command(argv)
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
      downstream_metrics = {}
      if broad_dashboard
        downstream_metrics = ready_downstream_metrics(statuses)
        statuses = sort_statuses(statuses, downstream_metrics)
        statuses = limit_blocked_statuses(statuses) unless options[:all]
      end
      previous_bucket = nil

      statuses.each do |item|
        bucket = status_bucket(item.fetch("status"))
        @out.puts if broad_dashboard && previous_bucket && bucket != previous_bucket

        if broad_dashboard
          display_dashboard_item(item, downstream_metrics)
        else
          status = item.fetch("status")
          @out.puts "#{item.fetch('id')}: #{colorize_status(status)} — #{item.fetch('title')}"
          @out.puts "    #{display_reason(item)}" if item["reason"]
        end
        previous_bucket = bucket
      end
    end

    def sort_statuses(statuses, downstream_metrics)
      statuses.each_with_index
              .sort_by do |item, index|
                status = item.fetch("status")
                depth, count = downstream_metrics.fetch(item.fetch("id"), [0, 0])
                ready_rank = status == "READY" ? [-depth, -count] : [0, 0]
                blocked_rank = status == "BLOCKED" ? blocked_dependency_count(item) : 0
                [STATUS_ORDER.fetch(status, 90), *ready_rank, blocked_rank, index]
              end
              .map(&:first)
    end

    def ready_downstream_metrics(statuses)
      tasks = coordinator.respond_to?(:tasks) ? coordinator.tasks : []
      downstream = Hash.new { |hash, id| hash[id] = [] }
      tasks.each do |task|
        task.fetch("depends_on", []).each { |dependency| downstream[dependency] << task.fetch("id") }
      end

      statuses.filter_map do |item|
        next unless item.fetch("status") == "READY"

        id = item.fetch("id")
        [id, [downstream_depth(id, downstream, { id => true }), downstream_count(id, downstream)]]
      end.to_h
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
      when "IN_FLIGHT" then 2
      when "READY" then 3
      when "BLOCKED" then 5
      else 4
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

    def display_dashboard_item(item, downstream_metrics)
      id = item.fetch("id")
      status = item.fetch("status")
      if status == "IN_FLIGHT"
        @out.puts "#{id}: #{colorize_status(status)}"
        puts_wrapped(item.fetch("title"), first_prefix: "    ", continuation_prefix: "    ")
        if item["reason"]
          puts_wrapped(display_in_flight_reason(item.fetch("reason")),
                       first_prefix: "    ", continuation_prefix: "    ")
        end
        return
      end

      plain_prefix = "#{id}: #{status} — "
      colored_prefix = "#{id}: #{colorize_status(status)} — "
      puts_wrapped(item.fetch("title"), first_prefix: colored_prefix,
                                        first_prefix_width: plain_prefix.length,
                                        continuation_prefix: " " * plain_prefix.length)
      if status == "READY"
        depth, count = downstream_metrics.fetch(id, [0, 0])
        puts_wrapped("downstream: #{depth} #{pluralize(depth, 'level')} / #{count} #{pluralize(count, 'task')}",
                     first_prefix: "    ", continuation_prefix: "    ")
      end
      puts_wrapped(display_reason(item), first_prefix: "    ", continuation_prefix: "    ") if item["reason"]
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
      id = argv.shift
      raise Error, "usage: agent-coding-tool start TASK" unless id && argv.empty?

      coordinator.start(id)
      @out.puts "Started #{id}: IN_FLIGHT"
    end

    def record_command(argv)
      record_result(
        argv,
        usage: "agent-coding-tool record TASK OUTCOME [--summary TEXT] [--artifact PATH] [--test RESULT]"
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
          prepare TASK [--retry]
          start TASK          mark a prepared task in flight (human assertion)
          received TASK [--summary TEXT] [--artifact PATH] [--test RESULT]
                              worker result is ready for human review/application
          finish TASK [--summary TEXT] [--artifact PATH] [--test RESULT]
                              landed task is complete on authoritative pushed state
          record TASK OUTCOME [--summary TEXT] [--artifact PATH] [--test RESULT]
                              generic/manual outcome primitive
          reset TASK

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
