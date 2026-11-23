# frozen_string_literal: true

require "json"

# A harmless child replacing sandbox-exec only at the native process boundary.
if ARGV.first == "substitute"
  ARGV.shift
  mode, action, path = ARGV
  case mode
  when "boundary"
    File.write(path, "changed before inference") if action == "change-before"
    puts(action == "unsafe" ? "boundary failed" : "manager boundary passed")
  when "version"
    puts "codex-cli 0.166.0"
  when "help"
    puts "--json --config --ignore-user-config --ignore-rules --skip-git-repo-check"
  when "features"
    puts "supported feature listing"
  when "login"
    puts "Logged in using ChatGPT"
  when "review"
    File.open("#{path}.calls", "a") { |file| file.puts "review" }
    input = JSON.parse(STDIN.read)
    abort unless input.dig("binding", "task_id") == "OS-AF-03"
    File.write(path, "changed during inference") if action == "change-during"
    decision = { "revision" => input.fetch("revision"), "proved" => "Worker returned a final.",
      "remaining" => "David owns acceptance.", "action" => "operator_closeout",
      "instruction" => nil, "evidence" => ["final"] }
    puts JSON.generate("type" => "thread.started", "thread_id" => "fixture-reviewer")
    puts JSON.generate("type" => "turn.started")
    puts JSON.generate("type" => "item.completed", "item" => { "type" => "agent_message", "text" => JSON.generate(decision) })
    puts JSON.generate("type" => "turn.completed")
  else
    abort "unexpected substitute mode"
  end
  exit
end

require_relative "../child_processes"
require_relative "../../../lib/agent_coding_tool"
require_relative "../../../lib/agent_coding_tool/native_pilot_executor"

# Models boot observation in test environments that restrict the Darwin sysctl.
def (AgentCodingTool::NativePilotExecutor).boot
  "first-return-cli-test-boot"
end

# Accepts only the exact pilot spawn shape and always executes a harmless child.
module FirstReturnProcessBoundary
  # Permits only the production supervisor's block-form fork.
  def fork(*arguments, &block)
    source = File.expand_path("../../../lib/agent_coding_tool/native_pilot_executor.rb", __dir__)
    abort "unexpected fork" unless caller_locations(1, 1).first.absolute_path == source && arguments.empty? && block
    permit = NoGitExecution::ForkPermit.new(source: __FILE__, sha256: Digest::SHA256.file(__FILE__).hexdigest, line: __LINE__ + 2)
    NoGitExecution.with_fork_permit(permit) do
      super(*arguments, &block)
    end
  end

  # Checks confinement arguments and forwards the genuine IO and process options.
  def spawn(environment, *argv, **options)
    sandbox, flag, profile, binary, *args = argv
    ruby = File.realpath(RbConfig.ruby)
    abort "unexpected process" unless [sandbox, flag, binary] == ["/usr/bin/sandbox-exec", "-f", ruby] &&
      options.values_at(:pgroup, :unsetenv_others, :close_others) == [true, true, true] &&
      options.fetch(:chdir).start_with?(environment.fetch("CODEX_HOME") + "/")
    policy = File.read(profile)
    abort "unexpected confinement profile" unless policy.include?("(deny default)") &&
      !policy.include?("(allow process-fork)") && !policy.include?(ENV.fetch("AGENT_CODING_TOOL_DATA_DIR").dump)
    mode = case args
           when ["--version"] then "version"
           when ["exec", "--help"] then "help"
           when ["features", "list"] then "features"
           when ["login", "status"] then "login"
           else
             if args.first == "--disable=gems"
               "boundary"
             elsif argv.drop(3) == AgentCodingTool::CodexManagerAdapter.new(executable: ruby, identity: {}).argv(nil)
               "review"
             else
               abort "unexpected reviewer argv"
             end
           end
    pipes = options.select { |key, _| %i[in out err].include?(key) }
    settings = options.reject { |key, _| pipes.key?(key) }
    arguments = ["substitute", mode, ENV.fetch("FIRST_RETURN_TEST_ACTION"), ENV.fetch("FIRST_RETURN_TEST_FINAL")]
    environment = environment.merge("ACT_COVERAGE_CONTEXT" => ENV.fetch("ACT_COVERAGE_CONTEXT")) if ENV["ACT_COVERAGE_CONTEXT"]
    permit = ChildProcesses.permit("first_return_cli", arguments: arguments, environment: environment, options: settings)
    NoGitExecution.with_permit(permit) { super(permit.environment, *permit.argv, **permit.options, **pipes) }
  end
end

require_relative "../../../lib/agent_coding_tool/codex_manager_adapter"
Process.singleton_class.prepend(FirstReturnProcessBoundary)
load File.expand_path("../../../bin/agent-coding-tool", __dir__)
