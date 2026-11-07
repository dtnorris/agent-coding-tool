# frozen_string_literal: true

require_relative "../../lib/agent_coding_tool"

# Benchmark-only external Git boundary. All parsing, ranking and output stay real.
# Sleeps release the GVL, modeling bounded overlapping real network waits.
module StatusScaleProbe
  COUNTS = Hash.new(0)
  LOCK = Mutex.new
  @active = 0
  @peak = 0

  # Records a counted boundary without changing its return value or exceptions.
  def self.count(key)
    COUNTS[key] += 1
  end

  # Models only the exact Git reads used by status/next; unknown commands raise.
  # Returns raw CommandResult; remote failure injection remains fail closed.
  def call(argv, cwd: nil, **options)
    raise "unexpected benchmark command: #{argv.inspect}" unless argv.first == "git"
    stdout = case argv[1..]
             when ["rev-parse", "--git-dir"]
               StatusScaleProbe.count("local_probes")
               ".git\n"
             when ["remote", "get-url", "origin"]
               StatusScaleProbe.count("authority_probes")
               "https://github.com/example/#{File.basename(cwd)}.git\n"
             else
               raise "unexpected benchmark Git: #{argv.inspect}" unless argv[1..2] == ["ls-remote", "--exit-code"]
               StatusScaleProbe.remote_wait
               "#{'a' * 40}\t#{argv.last}\n"
             end
    AgentCodingTool::CommandResult.new(stdout: stdout, stderr: "", exitstatus: 0)
  end

  # Tracks actual concurrent waits and request count; finite latency is explicit.
  def self.remote_wait
    LOCK.synchronize do
      count("remote_refs")
      @active += 1
      @peak = [@peak, @active].max
    end
    sleep Float(ENV.fetch("ACT_STAT_LATENCY", "0.55"))
  ensure
    LOCK.synchronize { @active -= 1 }
  end

  # Returns bounded counts and actual peak; no task/evidence bytes are included.
  def self.report
    COUNTS.merge("peak_remote_concurrency" => @peak)
  end

  # Installs optional inclusive timers for diagnosis only, outside timing claims.
  # Results overlap; they must not be summed into an additive decomposition.
  def self.profile(type, methods)
    observer = Module.new
    methods.each do |name|
      observer.define_method(name) do |*args, **options, &block|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          super(*args, **options, &block)
        ensure
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          StatusScaleProbe::COUNTS["seconds_#{name}"] += elapsed
        end
      end
    end
    type.prepend(observer)
  end

  # Counts actual YAML files parsed, separately from repeated store API reads.
  module YamlReads
    # Preserves safe_load_file arguments/results/errors and counts by directory.
    def safe_load_file(path, **options)
      StatusScaleProbe.count("yaml_#{File.basename(File.dirname(path))}")
      super
    end
  end

  # Counts state API calls, including missing files which perform no YAML parse.
  module StateReads
    # Forwards the exact ID and preserves state validation/errors.
    def load(id)
      StatusScaleProbe.count("state_loads")
      super
    end
  end
end

AgentCodingTool::NativeCommandTransport.prepend(StatusScaleProbe)
YAML.singleton_class.prepend(StatusScaleProbe::YamlReads)
AgentCodingTool::StateStore.prepend(StatusScaleProbe::StateReads)
if ENV["ACT_STAT_PROFILE"] == "1"
  StatusScaleProbe.profile(YAML.singleton_class, [:safe_load_file])
  StatusScaleProbe.profile(AgentCodingTool::Coordinator, %i[statuses filter_completed_tasks status_context completion_unlock_metrics write_collision_overlaps next_start_set])
  StatusScaleProbe.profile(AgentCodingTool::CLI, %i[completion_dashboard_metrics sort_statuses display_dashboard_item])
end
at_exit do
  File.write(ENV.fetch("ACT_STAT_COUNTS"), JSON.generate(StatusScaleProbe.report))
end
