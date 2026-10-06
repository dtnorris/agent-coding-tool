# frozen_string_literal: true

require "optparse"

module AgentCodingTool
  class CLI
    STATUS_ORDER = {
      "COMPLETE" => 0,
      "IN_FLIGHT" => 10,
      "READY" => 20,
      "PREPARED" => 30,
      "CANDIDATE" => 40,
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
    BLOCKED_DISPLAY_LIMIT = 5
    ANSI_RESET = "\e[0m"

    def self.run(argv, root: Dir.pwd, out: $stdout, err: $stderr, data_root: nil)
      new(root: root, out: out, err: err, data_root: data_root).run(argv)
    end

    def self.default_data_root(root, env: ENV)
      override = env["AGENT_CODING_TOOL_DATA_DIR"]
      return File.expand_path(override) if override && !override.empty?

      File.expand_path("../#{File.basename(root)}-data", root)
    end

    def initialize(root:, out:, err:, data_root: nil)
      @root = root
      @out = out
      @err = err
      @data_root = data_root || self.class.default_data_root(root)
    end

    def run(argv)
      command = argv.shift
      case command
      when "status" then status_command(argv)
      when "prepare" then prepare_command(argv)
      when "start" then start_command(argv)
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
      if broad_dashboard
        statuses = sort_statuses(statuses)
        statuses = limit_blocked_statuses(statuses) unless options[:all]
      end
      previous_bucket = nil

      statuses.each do |item|
        bucket = status_bucket(item.fetch("status"))
        @out.puts if broad_dashboard && previous_bucket && bucket != previous_bucket

        status = item.fetch("status")
        @out.puts "#{item.fetch('id')}: #{colorize_status(status)} — #{item.fetch('title')}"
        @out.puts "    #{display_reason(item)}" if item["reason"]
        previous_bucket = bucket
      end
    end

    def sort_statuses(statuses)
      statuses.each_with_index
              .sort_by do |item, index|
                [STATUS_ORDER.fetch(item.fetch("status"), 90), blocked_dependency_count(item), index]
              end
              .map(&:first)
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
      when "IN_FLIGHT" then 1
      when "READY" then 2
      when "BLOCKED" then 4
      else 3
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
      @out.write(prepared.fetch("prompt"))
    end

    def start_command(argv)
      id = argv.shift
      raise Error, "usage: agent-coding-tool start TASK" unless id && argv.empty?

      coordinator.start(id)
      @out.puts "Started #{id}: IN_FLIGHT"
    end

    def record_command(argv)
      options = { tests: [] }
      parser = OptionParser.new do |opts|
        opts.on("--summary TEXT", "short explicit result summary") { |value| options[:summary] = value }
        opts.on("--artifact PATH", "patch or other handoff artifact") { |value| options[:artifact] = value }
        opts.on("--test RESULT", "record a test result such as 'rake=pass'; repeatable") { |value| options[:tests] << value }
      end
      parser.parse!(argv)
      id = argv.shift
      outcome = argv.shift
      unless id && outcome && argv.empty?
        raise Error, "usage: agent-coding-tool record TASK OUTCOME [--summary TEXT] [--artifact PATH] [--test RESULT]"
      end

      coordinator.record(id, outcome: outcome, **options)
      @out.puts "Recorded #{id}: #{outcome}"
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
          record TASK OUTCOME [--summary TEXT] [--artifact PATH] [--test RESULT]
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
