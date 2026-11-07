# frozen_string_literal: true

require "json"
require_relative "../checkpoint_processes"

# Observes the real package loader/capture through the actual bin entrypoint.
# Only the declared non-Git checkpoint validator may execute; the inherited
# guard rejects other processes. Product policy, pipes and files remain real.
root = ARGV.shift
calls = []
captures = []
reservations = []
observer = TracePoint.new(:call) do |event|
  if event.defined_class.name == "ActTasks::TaskStore" && %i[load all].include?(event.method_id)
    calls << { "method" => event.method_id, "path" => event.path }
    raise ActTasks::InvalidTask, "broken task handoff" if ENV["ACT_TEST_BROKEN_HANDOFF"] == "tasks"
  end
  if event.defined_class.name == "ActObservability::GateCapture" && event.method_id == :run
    captures << event.path
    raise IOError, "broken capture handoff" if ENV["ACT_TEST_BROKEN_HANDOFF"] == "observability"
  end
  if event.method_id == :synchronize && defined?(ActLifecycle::ReservationLock) && event.self.equal?(ActLifecycle::ReservationLock)
    reservations << event.path
    raise ActLifecycle::InvalidState, "broken lifecycle handoff" if ENV["ACT_TEST_BROKEN_HANDOFF"] == "lifecycle"
  end
end
observer.enable
at_exit do
  observer.disable
  warn "TASK_SOURCE=#{JSON.generate(calls)}"
  warn "\nCAPTURE_SOURCE=#{JSON.generate(captures)}"
  warn "RESERVATION_SOURCE=#{JSON.generate(reservations)}"
end
if ARGV.first == "reservation"
  ARGV.shift
  require File.join(root, "lib/agent_coding_tool")
  data, action, effect = ARGV
  begin
    held = case action
           when "malformed" then Object.new
           when "closed" then File.open(effect, File::RDWR).tap(&:close)
           when "foreign" then File.open(effect, File::RDWR)
           end
    value = AgentCodingTool::ReservationLock.synchronize(data, held: held) do |lock|
      if action == "hold"
        borrowed = AgentCodingTool::ReservationLock.synchronize(data, held: lock) { false }
        failures = [RuntimeError, AgentCodingTool::InvalidState]
        failures << ActLifecycle::InvalidState if defined?(ActLifecycle::InvalidState)
        failures.each do |type|
          failure = type.new("caller failure")
          begin
            AgentCodingTool::ReservationLock.synchronize(data, held: lock) { raise failure }
          rescue StandardError => error
            raise unless error.equal?(failure)
          end
        end
        puts JSON.generate("identity" => [lock.stat.dev, lock.stat.ino], "borrowed" => borrowed, "closed" => lock.closed?)
        STDOUT.flush
        loop do
          raise "holder release deadline" unless IO.select([STDIN], nil, nil, 5)
          instruction = STDIN.gets&.strip
          break if instruction == "release"
          raise "unknown holder instruction" unless instruction == "borrow"
          begin
            result = AgentCodingTool::ReservationLock.synchronize(data, held: lock) { :borrowed }
            puts JSON.generate("result" => result, "closed" => lock.closed?)
          rescue AgentCodingTool::InvalidState => error
            puts JSON.generate("error" => error.message, "class" => error.class.name,
              "cause" => error.cause&.class&.name, "closed" => lock.closed?)
          end
          STDOUT.flush
        end
      end
      File.binwrite(effect, "mutated") if action == "acquire"
      { "identity" => [lock.stat.dev, lock.stat.ino], "result" => "acquired" }
    end
    puts JSON.generate(value)
    exit 0
  rescue AgentCodingTool::InvalidState, IOError, NoMethodError, Errno::ENOENT => error
    puts JSON.generate("error" => error.message, "class" => error.class.name, "cause" => error.cause&.class&.name)
    exit 75
  ensure
    held.close if held.is_a?(IO) && !held.closed?
  end
end
if ARGV.first == "store"
  ARGV.shift
  require File.join(root, "lib/agent_coding_tool")
  store = AgentCodingTool::TaskStore.new(ARGV.shift)
  begin
    puts JSON.generate("path" => store.task_path("T1"), "tasks" => store.all, "task" => store.load("T1"))
    exit 0
  rescue AgentCodingTool::InvalidTask => error
    warn "ERROR: #{error.message}; cause=#{error.cause.class}"
    exit 2
  end
end
load File.join(root, "bin/agent-coding-tool")
