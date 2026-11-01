# frozen_string_literal: true

require "json"
require "set"

# Advisory, line-oriented progress for terminals, pipes and Buildkite. Raw logs
# and the independent suite evidence remain the only acceptance inputs.
class SuiteProgress
  # Takes the runner's validated execution groups and an output stream. Does
  # not spawn processes; output errors propagate before execution begins.
  def initialize(groups, out: $stderr)
    @groups, @out = groups, out
    @total = groups.sum { |group| group.fetch(:cases).length }
    @layers = groups.map { |group| group.fetch(:layer) }.uniq
    @verified = @index = 0
    @begun = clock
    emit("Plan: #{@layers.length} phases, #{groups.length} suites, #{@total} tests; progress is advisory")
    emit("Phases: " + @layers.map { |layer| "#{label(layer)}=#{groups.select { |group| group.fetch(:layer) == layer }.sum { |group| group.fetch(:cases).length }}" }.join("; "))
  end

  # Maps fixed runner phase names to operator-facing labels; direct selections
  # retain their caller-supplied label (sanitized by emit).
  def label(layer)
    { "ordinary" => "Ordinary", "git_contract" => "Git contracts",
      "native_default" => "Native default", "native_integration" => "Native integration" }.fetch(layer, layer)
  end

  # Monotonic elapsed time for display only; never supplies a timeout/budget.
  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Writes and flushes one safe log line. No terminal escapes or Buildkite
  # control sequences are accepted from case names or failure messages.
  def emit(message)
    @out.puts("ACT progress: #{message.to_s.gsub(/[[:cntrl:]]/, ' ')}")
    @out.flush
  end

  # Starts a file-only observer for one child. The selection must match the
  # planned group. Returns nil; malformed plans/files raise before spawn.
  def start(path, cases, invocation:)
    group = @groups.fetch(@index)
    raise ArgumentError, "progress selection differs from plan" unless group.fetch(:cases).sort == cases.sort

    @index += 1
    @cases, @done = cases.to_set, Set.new
    @invocation, @active = invocation, nil
    @current_started = @last_display = clock
    @reader = File.open(path, File::RDWR | File::CREAT | File::EXCL, 0o600)
    @buffer = +""
    @finished = false
    @mutex, @wake = Mutex.new, ConditionVariable.new
    layer = group.fetch(:layer)
    paths = group.fetch(:paths)
    source = paths.length == 1 ? paths.first : "#{paths.length} test files"
    emit("Phase #{@layers.index(layer) + 1}/#{@layers.length} #{label(layer)}; suite #{@index}/#{@groups.length}; #{cases.length} tests; #{source}")
    display
    @observer = Thread.new do
      loop do
        drain
        @mutex.synchronize { @wake.wait(@mutex, 0.1) unless @finished }
        break if @finished
      end
      drain
    rescue StandardError => error
      emit("observer unavailable: #{error.class}; raw logs and final verification still apply")
    end
    @observer.report_on_exception = false
    nil
  end

  # Reads bounded chunks without pipes. Partial lines wait for the next poll;
  # malformed, stale, duplicate or foreign events never inflate progress.
  # Read/JSON errors disable only the observer, not acceptance validation.
  def drain
    chunk = @reader.read(65_536)
    @buffer << chunk if chunk
    while (newline = @buffer.index("\n"))
      event = JSON.parse(@buffer.slice!(0, newline + 1))
      next unless event["invocation"] == @invocation && @cases.include?(event["case"])

      case event["event"]
      when "start"
        @active = event["case"]
        @active_started = clock
      when "result"
        next if @done.include?(event["case"])
        @done << event["case"]
        @active = nil if @active == event["case"]
        emit("#{event['status'].to_s.upcase} #{event['case']}: #{event['detail']}") unless event["status"] == "pass"
      end
    end
    raise IOError, "oversized progress event" if @buffer.bytesize > 65_536
    display if clock - @last_display >= 1
  end

  # Emits counts and current activity at most once per periodic tick. Counts
  # represent cases, never a percentage/estimate of remaining execution time.
  def display
    now = clock
    active = @active ? "running #{@active} (#{format('%.1f', now - @active_started)}s)" : "loading / between tests / finalizing evidence"
    completed = @verified + @done.length
    emit("#{completed}/#{@total} tests completed; #{@total - completed} remaining; suite #{@done.length}/#{@cases.length}; elapsed #{format('%.1f', now - @begun)}s; #{active}")
    @last_display = now
  end

  # Stops and drains the observer before logs/evidence are inspected. Safe after
  # partial startup; the thread cannot outlive a failed or interrupted child.
  def stop
    if @observer
      @mutex.synchronize { @finished = true; @wake.broadcast }
      @observer.join(1)
      @observer.kill.join if @observer.alive?
      @observer = nil
    end
    @reader&.close unless @reader&.closed?
  end

  # Reports a suite only after the original case/coverage validation passed.
  # Takes the independently checked evidence envelope; returns nil.
  def verified(evidence)
    @verified += evidence.fetch("results").length
    emit("Suite #{@index}/#{@groups.length} VERIFIED; #{@verified}/#{@total} tests; seed #{evidence.fetch('seed')}; #{format('%.2f', clock - @current_started)}s; final acceptance pending")
    nil
  end

  # Reports incomplete execution without manufacturing an acceptance result.
  # Called for nonzero status, timeout, interrupt or malformed final evidence.
  def incomplete
    emit("Suite #{@index}/#{@groups.length} INCOMPLETE; #{@verified}/#{@total} tests verified; #{@groups.length - @index} suites not started; inspect raw output")
  end
end
