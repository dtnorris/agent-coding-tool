# frozen_string_literal: true

require "fiddle"
require "rbconfig"

# Reads Darwin's process birth identity without launching host inspection tools.
# This is test supervision only; production launch/ownership checks stay intact.
module FeedbackRuntime
  # Returns one PID's kernel identity, or nil after exit. Unsupported platforms
  # and unavailable process inspection raise; they cannot qualify a measurement.
  def self.identity(pid)
    raise "feedback requires qualified Darwin process inspection" unless RbConfig::CONFIG.fetch("host_os").match?(/darwin/)

    @library ||= Fiddle.dlopen("/usr/lib/libproc.dylib")
    @info ||= Fiddle::Function.new(@library["proc_pidinfo"],
      [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
    buffer = Fiddle::Pointer.malloc(136, Fiddle::RUBY_FREE)
    return nil unless @info.call(pid, 3, 0, buffer, 136) == 136

    bytes = buffer.to_s(136)
    { "pid" => bytes.byteslice(12, 4).unpack1("L"),
      "parent" => bytes.byteslice(16, 4).unpack1("L"),
      "group" => bytes.byteslice(100, 4).unpack1("L"),
      "birth" => bytes.byteslice(120, 16).unpack("Q2") }
  end

  # Returns current children of an owned PID; raises on inspection failure or
  # overflow rather than silently truncating ownership. Does not enumerate host PIDs.
  def self.children(pid)
    @children ||= Fiddle::Function.new(@library["proc_listchildpids"],
      [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT)
    buffer = Fiddle::Pointer.malloc(65_536, Fiddle::RUBY_FREE)
    count = @children.call(pid, buffer, 65_536)
    raise "feedback: child ownership inspection failed or overflowed" if count.negative? || count * 4 >= 65_536

    buffer.to_s(count * 4).unpack("i*").select(&:positive?)
  end

  # Returns monotonic seconds. No wall-clock changes affect a running deadline.
  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Captures process-start elapsed time once, then advances monotonically. The
  # Darwin proc_bsdinfo ABI supplies microsecond birth time across bundle exec.
  # Raises when the current process's birth cannot be qualified.
  def self.outer_timer
    started = identity(Process.pid)&.fetch("birth")
    raise "feedback: outer process birth unavailable" unless started

    offset = Time.now.to_f - started[0] - started[1] / 1_000_000.0
    raise "feedback: invalid outer process age" unless offset.finite? && offset >= 0

    [clock, offset]
  end

  # Returns outer elapsed seconds from a previously qualified timer.
  def self.elapsed(timer)
    clock - timer.fetch(0) + timer.fetch(1)
  end

  # Supervises only one newly owned child tree and its private process group.
  # Output goes to regular files so an inherited pipe cannot trap reader cleanup.
  # Returns actual status, timeout, elapsed and cleanup facts. Spawn/interrupt
  # exceptions propagate unchanged after bounded owned-process cleanup.
  def self.capture(argv, environment:, root:, seconds:, stdout_path:, stderr_path:)
    raise ArgumentError, "positive finite hang deadline required" unless seconds.is_a?(Numeric) && seconds.finite? && seconds.positive?

    started = clock
    pid = nil
    status = nil
    expired = false
    owned = {}
    finished = false
    failure = nil
    watcher = nil
    previous_term = Signal.trap("TERM") { raise SignalException.new("TERM") } if Thread.current == Thread.main
    File.open(stdout_path, "wb") do |output|
      File.open(stderr_path, "wb") do |error|
        pid = Process.spawn(environment, *argv, chdir: root, out: output, err: error, pgroup: true)
        anchor = identity(pid)
        raise "feedback: child ownership unavailable" unless anchor && anchor.fetch("parent") == Process.pid && anchor.fetch("group") == pid

        owned[pid] = anchor
        watcher = Thread.new do
          begin
            until finished
              discover(owned)
              if clock - started >= seconds
                expired = true
                terminate(owned, pid)
                break
              end
              sleep 0.01
            end
          rescue Exception => exception
            failure = exception
            terminate(owned, pid)
          end
        end
        watcher.report_on_exception = false
        _child, status = Process.wait2(pid)
      end
    end
    raise failure if failure

    { status: status, timeout: expired, seconds: clock - started,
      observed_processes: owned.values.dup }
  ensure
    finished = true
    watcher&.join(1)
    watcher&.kill if watcher&.alive?
    begin
      if pid
        # Anchor group belongs to this invocation; never use the caller's group.
        terminate(owned, pid, anchor_reaped: !status.nil?)
        reap_until = clock + 1
        begin
          until Process.waitpid(pid, Process::WNOHANG)
            raise "feedback: owned child could not be reaped within cleanup deadline" if clock >= reap_until
            sleep 0.01
          end
        rescue Errno::ECHILD
          # The normal wait already reaped this invocation's direct child.
        end
      end
    ensure
      Signal.trap("TERM", previous_term) if previous_term
    end
  end

  # Extends an owned tree using live birth identities. Previously observed
  # descendants remain attributable after reparenting; PID reuse is refused.
  def self.discover(owned)
    pending = owned.values.dup
    until pending.empty?
      parent = pending.shift
      next unless identity(parent.fetch("pid"))&.fetch("birth") == parent.fetch("birth")

      children(parent.fetch("pid")).each do |pid|
        next if owned.key?(pid)
        child = identity(pid)
        next unless child && child.fetch("parent") == parent.fetch("pid")

        owned[pid] = child
        pending << child
      end
    end
  end

  # Terminates the invocation's group plus observed descendants in other groups.
  # Birth checks reject reused descendant PIDs. Cleanup has no pipe-reader waits;
  # waitpid for the direct child is owned by capture. ESRCH means already exited.
  def self.terminate(owned, anchor, anchor_reaped: false)
    anchored_group = !anchor_reaped || owned.values.any? { |child|
      child.fetch("group") == anchor && identity(child.fetch("pid"))&.fetch("birth") == child.fetch("birth") }
    begin
      owned.values.reverse_each do |child|
        pid = child.fetch("pid")
        next if pid == anchor
        next unless identity(pid)&.fetch("birth") == child.fetch("birth")

        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        next
      end
    ensure
      begin
        Process.kill("KILL", -anchor) if anchored_group
      rescue Errno::ESRCH
        # The owned group has already exited.
      end
    end
  end
end
