# frozen_string_literal: true

require "stringio"
require "minitest/mock"
require "timeout"
require_relative "test_helper"

# Scheduling/persistence/display safety with real files and synthetic tasks only.
class IceboxTest < Minitest::Test
  include TestHelpers

  # Deferral/restoration preserve compatible metadata and timestamps exactly on
  # identical repetition; a different reason requires explicit restoration.
  def test_idempotency_optional_reason_and_metadata_preservation
    with_icebox_workspace do |root, coordinator, store|
      [nil, "Revisit after profiling", ""].each do |reason|
        original = { "id" => "TST-A", "operator_note" => { "keep" => [1, "two"] } }
        store.write("TST-A", original)
        result = coordinator.icebox("TST-A", reason: reason)
        assert_equal original, result.reject { |key, _| key == "icebox" }
        reason.nil? ? assert_nil(result.fetch("icebox")["reason"]) : assert_equal(reason, result.fetch("icebox")["reason"])
        assert_equal !reason.nil?, result.fetch("icebox").key?("reason")
        Time.iso8601(result.dig("icebox", "at"))
        before = File.binread(store.state_path("TST-A"))
        modified = File.stat(store.state_path("TST-A")).mtime
        Time.stub(:now, Time.now + 60) { assert_equal result, coordinator.icebox("TST-A", reason: reason) }
        assert_equal before, File.binread(store.state_path("TST-A"))
        assert_equal modified, File.stat(store.state_path("TST-A")).mtime
        error = assert_raises(AgentCodingTool::InvalidState) { coordinator.icebox("TST-A", reason: "different") }
        assert_includes error.message, "unicebox"
        assert_equal before, File.binread(store.state_path("TST-A"))
        coordinator.unicebox("TST-A")
        assert_equal original, store.load("TST-A")
        restored = File.binread(store.state_path("TST-A"))
        coordinator.unicebox("TST-A")
        assert_equal restored, File.binread(store.state_path("TST-A"))
      end
      assert_empty Dir.children(File.join(root, "state/prompts"))
      refute File.exist?("#{root}-runs/TST-A")
    end
  end

  # Invalid mapping shapes, keys, timestamp/calendar values and reason types
  # fail on both reads and writes; legacy state and unrelated fields remain valid.
  def test_strict_mapping_validation_and_legacy_state
    with_icebox_workspace do |_root, coordinator, store|
      invalid = [nil, false, "later", [], {}, { "at" => nil }, { "at" => 1 },
                 { "at" => "tomorrow" }, { "at" => "2026-02-30T12:00:00Z" },
                 { "at" => "2026-10-18T12:00:00+99:99" },
                 { "at" => "2026-10-18" }, { "at" => "2026-10-18T12:00:00" },
                 designation.merge("reason" => nil), designation.merge("reason" => 2),
                 designation.merge("reason" => []), designation.merge("reason" => {}),
                 designation.merge("extra" => "unsupported")]
      invalid.each do |value|
        state = { "icebox" => value }
        assert_raises(AgentCodingTool::InvalidState, value.inspect) { store.write("TST-A", state) }
        File.write(store.state_path("TST-A"), YAML.dump(state))
        assert_raises(AgentCodingTool::InvalidState, value.inspect) { store.load("TST-A") }
        assert_raises(AgentCodingTool::InvalidState) { coordinator.icebox("TST-A") }
        assert_raises(AgentCodingTool::InvalidState) { coordinator.unicebox("TST-A") }
      end
      [{}, { "id" => "TST-A" }, { "legacy" => { "compatible" => true } }].each do |legacy|
        File.write(store.state_path("TST-A"), YAML.dump(legacy))
        assert_equal legacy, store.load("TST-A")
        coordinator.icebox("TST-A")
        coordinator.unicebox("TST-A")
        assert_equal legacy, store.load("TST-A")
      end
      ["missing", "../TST-A"].each do |id|
        assert_raises(AgentCodingTool::InvalidTask) { coordinator.icebox(id) }
        assert_raises(AgentCodingTool::InvalidTask) { coordinator.unicebox(id) }
      end
      assert_raises(AgentCodingTool::InvalidState) { coordinator.icebox("TST-A", reason: 2) }
    end
  end

  # Every lifecycle and partial/history evidence refuses initial designation,
  # including missing snapshots and stale candidates. Definitions stay intact.
  def test_ready_only_entry_and_conflicting_evidence
    with_icebox_workspace do |root, coordinator, store|
      definition = File.binread(File.join(root, "tasks/TST-A.yml"))
      prepared = coordinator.prepare("TST-A").fetch("state")
      FileUtils.rm_f(Dir.glob(File.join(root, "state/prompts/*")))
      states = [prepared, prepared.merge("started_at" => "now"),
                prepared.merge("result" => { "outcome" => "candidate_complete" }),
                { "started_at" => "old" }, { "prepared_at" => "old" },
                { "status" => "PREPARED" }, { "checkpoint" => { "status" => "verified" } },
                { "snapshot" => nil }, { "id" => "OTHER" }, { "result" => "bad" }]
      AgentCodingTool::Coordinator::OUTCOMES.each { |outcome| states << { "result" => { "outcome" => outcome } } }
      states.each do |state|
        store.write("TST-A", state)
        before = File.binread(store.state_path("TST-A"))
        assert_raises(AgentCodingTool::InvalidState) { coordinator.icebox("TST-A") }
        assert_equal before, File.binread(store.state_path("TST-A"))
      end
      inspector = coordinator.instance_variable_get(:@repo_inspector)
      inspector.heads["alpha"] = "b" * 40
      [prepared, prepared.merge("result" => { "outcome" => "candidate_complete" })].each do |state|
        store.write("TST-A", state)
        assert_includes %w[STALE STALE_CANDIDATE], coordinator.status("TST-A").fetch("status")
        assert_raises(AgentCodingTool::InvalidState) { coordinator.icebox("TST-A") }
      end
      store.write("TST-A", {})
      write_task(root, id: "TST-A", depends_on: ["TST-B"])
      assert_raises(AgentCodingTool::InvalidState) { coordinator.icebox("TST-A") }
      File.binwrite(File.join(root, "tasks/TST-A.yml"), definition)
      File.write(File.join(root, "state/prompts/TST-A-old.txt"), "retained prompt")
      assert_raises(AgentCodingTool::InvalidState) { coordinator.icebox("TST-A") }
      File.unlink(File.join(root, "state/prompts/TST-A-old.txt"))
      FileUtils.mkdir_p("#{root}-runs/checkpoints/TST-A")
      assert_raises(AgentCodingTool::InvalidState) { coordinator.icebox("TST-A") }
      FileUtils.mkdir_p("#{root}-runs/TST-A")
      assert_raises(AgentCodingTool::InvalidState) { coordinator.icebox("TST-A") }
      assert_equal definition, File.binread(File.join(root, "tasks/TST-A.yml"))
    end
  end

  # Direct and public lifecycle paths cannot restore implicitly. Reset is a
  # complete no-op for deferred state; explicit restoration retains every field.
  def test_lifecycle_entrypoints_refuse_and_reset_preserves_designation
    with_icebox_workspace do |root, coordinator, store|
      coordinator.icebox("TST-A", reason: "later")
      before = File.binread(store.state_path("TST-A"))
      [-> { coordinator.prepare("TST-A") }, -> { coordinator.prepare("TST-A", retry_result: true) },
       -> { coordinator.launch_prompt("TST-A") },
       -> { coordinator.start("TST-A") }, *AgentCodingTool::Coordinator::OUTCOMES.map { |outcome|
         -> { coordinator.record("TST-A", outcome: outcome) }
       }].each do |operation|
        error = assert_raises(AgentCodingTool::InvalidState, &operation)
        assert_includes error.message, "ICEBOX"
        assert_equal before, File.binread(store.state_path("TST-A"))
      end
      [%w[prepare TST-A], %w[prepare TST-A --retry], %w[start TST-A],
       %w[finish TST-A], %w[received TST-A], %w[record TST-A failed]].each do |command|
        output, error, status = cli(root, coordinator, command)
        assert_equal 2, status
        assert_includes error, "ICEBOX"
        assert_empty output
      end
      coordinator.reset("TST-A")
      output, _error, status = cli(root, coordinator, %w[reset TST-A])
      assert_equal 0, status
      assert_includes output, "ICEBOX and runtime state retained"
      assert_equal before, File.binread(store.state_path("TST-A"))
      # Conflicting state is diagnosed rather than concealed. Restoration
      # removes only the designation, retaining historical result/checkpoint data.
      conflicting = store.load("TST-A").merge("result" => { "outcome" => "failed", "tests" => ["retained"] },
                                             "checkpoint" => { "attempt" => "retained" })
      store.write("TST-A", conflicting)
      assert_raises(AgentCodingTool::InvalidState) { coordinator.status("TST-A") }
      coordinator.reset("TST-A")
      assert_equal conflicting, store.load("TST-A")
      coordinator.unicebox("TST-A")
      assert_equal conflicting.reject { |key, _| key == "icebox" }, store.load("TST-A")
      assert_equal "FAILED", coordinator.status("TST-A").fetch("status")
    end
  end

  # Dependency changes remain visible while deferred and after restoration.
  # Deferral gives neither completion credit nor an immediate unlock opportunity.
  def test_dependency_changes_and_unlock_metrics_remain_truthful
    with_icebox_workspace do |root, coordinator, store|
      coordinator.icebox("TST-A")
      write_task(root, id: "TST-A", depends_on: ["TST-B"])
      status = coordinator.status("TST-A")
      assert_equal "ICEBOX", status.fetch("status")
      assert_equal "BLOCKED", status.fetch("lifecycle_status")
      assert_includes status.fetch("reason"), "TST-B"
      write_task(root, id: "TST-C", depends_on: ["TST-A"])
      assert_includes coordinator.status("TST-C").fetch("reason"), "TST-A"
      metrics = coordinator.completion_unlock_metrics(coordinator.statuses)
      refute metrics.key?("TST-A")
      assert_equal 0, metrics.fetch("TST-B").fetch("unlock_count")
      coordinator.unicebox("TST-A")
      assert_equal "BLOCKED", coordinator.status("TST-A").fetch("status")
      assert_empty store.load("TST-A")
    end
  end

  # Scheduling mutations keep atomic-write diagnostics truthful at both sides
  # of rename; uncertain publication must be inspected before an idempotent retry.
  def test_pre_rename_and_post_rename_failures
    with_icebox_workspace do |_root, coordinator, store|
      store.write("TST-A", { "note" => "keep" })
      before = File.binread(store.state_path("TST-A"))
      File.stub(:rename, ->(*) { raise Errno::ENOSPC }) do
        assert_raises(Errno::ENOSPC) { coordinator.icebox("TST-A") }
      end
      assert_equal before, File.binread(store.state_path("TST-A"))
      open_file = File.method(:open)
      File.stub(:open, lambda { |path, *args, **options, &block|
        next open_file.call(path, *args, **options, &block) unless path == File.dirname(store.state_path("TST-A")) && block

        open_file.call(path, *args, **options) do |file|
          file.stub(:fsync, -> { raise Errno::EIO }) { block.call(file) }
        end
      }) do
        error = assert_raises(AgentCodingTool::InvalidState) { coordinator.icebox("TST-A") }
        assert_includes error.message, "state replaced; directory synchronization failed"
      end
      published = store.load("TST-A")
      assert published["icebox"]
      assert_equal "keep", published.fetch("note")
      assert_equal published, coordinator.icebox("TST-A")
      File.stub(:rename, ->(*) { raise Errno::ENOSPC }) do
        assert_raises(Errno::ENOSPC) { coordinator.unicebox("TST-A") }
      end
      assert_equal published, store.load("TST-A")
      File.stub(:open, lambda { |path, *args, **options, &block|
        next open_file.call(path, *args, **options, &block) unless path == File.dirname(store.state_path("TST-A")) && block

        open_file.call(path, *args, **options) do |file|
          file.stub(:fsync, -> { raise Errno::EIO }) { block.call(file) }
        end
      }) do
        error = assert_raises(AgentCodingTool::InvalidState) { coordinator.unicebox("TST-A") }
        assert_includes error.message, "state replaced; directory synchronization failed"
      end
      assert_equal({ "note" => "keep" }, store.load("TST-A"))
    end
  end

  # Restoration and starts use the same lock. Even a manually conflicting
  # designation cannot lose preparation bytes or permit a deferred handoff.
  def test_restoration_serializes_with_direct_start
    with_icebox_workspace do |_root, coordinator, store|
      prepared = coordinator.prepare("TST-A").fetch("state")
      store.write("TST-A", prepared.merge("icebox" => designation))
      entered, release = Queue.new, Queue.new
      write = store.method(:write)
      store.define_singleton_method(:write) do |id, state|
        entered << true
        Timeout.timeout(5) { release.pop }
        write.call(id, state)
      end
      worker = Thread.new { coordinator.unicebox("TST-A") }
      Timeout.timeout(5) { entered.pop }
      error = assert_raises(AgentCodingTool::InvalidState) { coordinator.start("TST-A") }
      assert_includes error.message, "reservation busy"
      refute store.load("TST-A")["started_at"]
      release << true
      Timeout.timeout(5) { worker.value }
      assert_equal prepared, store.load("TST-A")
      store.define_singleton_method(:write, write)
      assert coordinator.start("TST-A")["started_at"]
    ensure
      release << true if release
      worker&.join(5)
    end
  end

  # Counts use the full inventory before READY compression; intentional mixed
  # views put natural-order Icebox rows after BLOCKED and never mark them NEXT.
  def test_output_count_order_filters_and_recommendations
    with_icebox_workspace do |root, coordinator, _store|
      assert_equal "0 Icebox tasks\n", output(root, coordinator, %w[status]).lines.last
      %w[TST-10 TST-2 TST-02].each { |id| write_task(root, id: id); coordinator.icebox(id) }
      assert_equal "3 Icebox tasks from families (TST)\n", output(root, coordinator, %w[status]).lines.last
      %w[ACT-1 CL-AFDP-1 FO-1 CL-2 FO-2].each { |id| write_task(root, id: id); coordinator.icebox(id) }
      8.times { |index| write_task(root, id: "READY-#{index}") }
      write_task(root, id: "TST-C", depends_on: ["TST-2"])
      expected = "8 Icebox tasks from families (ACT, CL, FO, TST)\n"
      [%w[status], %w[status --active]].each do |command|
        dashboard = output(root, coordinator, command)
        assert_equal expected, dashboard.lines.last
        assert_equal 1, dashboard.scan(/^\d+ Icebox/).length
        refute_includes dashboard, ": ICEBOX"
        assert_includes dashboard, "READY,"
      end
      [%w[status --all], %w[status --fam TST], %w[status --fam TST --all]].each do |command|
        listing = output(root, coordinator, command)
        headlines = listing.lines.grep(/^[^ ]+:/)
        assert headlines.last.include?("ICEBOX"), listing
        assert_operator listing.index("TST-C: BLOCKED"), :<, listing.index("TST-02: ICEBOX")
        assert_equal %w[TST-02 TST-2 TST-10], headlines.filter_map { |line| line[/^(TST-[^:]+): ICEBOX/, 1] }
        refute_match(/^\d+ Icebox/, listing)
      end
      [%w[status --icebox], %w[status --icebox --all], %w[status --icebox --active]].each do |command|
        listing = output(root, coordinator, command)
        assert_equal 8, listing.scan(/: ICEBOX/).length
        refute_match(/^\S+: (READY|BLOCKED)/, listing)
      end
      assert_equal 2, output(root, coordinator, %w[status --icebox --fam CL]).scan(/: ICEBOX/).length
      document = JSON.parse(output(root, coordinator, %w[next --json]))
      deferred = document.dig("facts", "tasks").select { |row| row["status"] == "ICEBOX" }
      assert_equal 8, deferred.length
      recommendations = document.fetch("recommendations").values.flatten.map { |row| row.fetch("id") }
      assert_empty recommendations & deferred.map { |row| row.fetch("id") }
      assert_equal 0, document.dig("recommendations", "starts").first.dig("downstream", "immediate_unlock_count")
      [%w[status TST-A --icebox], %w[status --icebox --all --active], %w[icebox TST-A --reason],
       %w[unicebox TST-A --reason text], %w[icebox missing]].each do |command|
        assert_equal 2, cli(root, coordinator, command).last
      end
      [20, 38].each do |width|
        assert_equal expected, output(root, coordinator, %w[status], width: width).lines.last
      end
    end
  end

  # Direct callers share the same real lock even before a first run. Both race
  # orders refuse the loser before state writes; borrowed locks avoid deadlock.
  def test_direct_api_concurrency_and_borrowed_lock
    [:icebox, :prepare].each do |first|
      with_icebox_workspace do |root, coordinator, store|
        entered, release = Queue.new, Queue.new
        write = store.method(:write)
        store.define_singleton_method(:write) do |id, state|
          entered << true
          Timeout.timeout(5) { release.pop }
          write.call(id, state)
        end
        worker = Thread.new { coordinator.public_send(first, "TST-A") }
        Timeout.timeout(5) { entered.pop }
        loser = first == :icebox ? :prepare : :icebox
        error = assert_raises(AgentCodingTool::InvalidState) { coordinator.public_send(loser, "TST-A") }
        assert_includes error.message, "reservation busy"
        release << true
        Timeout.timeout(5) { worker.value }
        assert_equal first == :icebox ? "ICEBOX" : "PREPARED", coordinator.status("TST-A").fetch("status")
      ensure
        release << true if release
        worker&.join(5)
      end
    end
    with_icebox_workspace do |root, coordinator, _store|
      AgentCodingTool::ReservationLock.synchronize(root) do |lock|
        Timeout.timeout(5) do
          coordinator.prepare("TST-A", reservation_lock: lock)
          coordinator.start("TST-A", reservation_lock: lock)
          coordinator.record("TST-A", outcome: "failed", reservation_lock: lock)
        end
      end
      assert_equal "FAILED", coordinator.status("TST-A").fetch("status")
    end
  end

  # Symlinked, public, substituted and foreign-owned reservation files cannot be
  # accepted or repaired. All public/direct mutations retain the original state.
  def test_unsafe_reservation_locks_are_refused
    with_icebox_workspace do |root, coordinator, store|
      coordinator.icebox("TST-A")
      path = "#{File.realpath(root)}-runs/launch.lock"
      before = File.binread(store.state_path("TST-A"))
      File.chmod(0o644, path)
      assert_raises(AgentCodingTool::InvalidState) { coordinator.unicebox("TST-A") }
      File.chmod(0o600, path)
      stat = File.stat(path)
      File.open(path, File::RDWR) do |lock|
        stat.stub(:uid, Process.uid + 1) do
          lock.stub(:stat, stat) do
            error = assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("TST-A", reservation_lock: lock) }
            assert_includes error.message, "foreign/symlinked lock"
          end
        end
      end
      File.rename(path, "#{path}.saved")
      File.symlink("#{path}.saved", path)
      [-> { coordinator.unicebox("TST-A") }, -> { coordinator.prepare("TST-A") },
       -> { coordinator.start("TST-A") }].each { |operation| assert_raises(AgentCodingTool::InvalidState, &operation) }
      File.unlink(path)
      File.rename("#{path}.saved", path)
      FileUtils.mkdir_p("#{root}-runs/TST-A")
      File.rename(path, "#{path}.saved")
      error = assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("TST-A") }
      assert_includes error.message, "missing managed reservation lock"
      File.rename("#{path}.saved", path)
      FileUtils.rmdir("#{root}-runs/TST-A")
      AgentCodingTool::ReservationLock.synchronize(root) do |lock|
        File.rename(path, "#{path}.saved")
        File.write(path, "replacement")
        File.chmod(0o600, path)
        assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("TST-A", reservation_lock: lock) }
      end
      assert_equal before, File.binread(store.state_path("TST-A"))
    end
  end

  private

  # Yields a real store/coordinator with two independent synthetic READY tasks.
  # File/process setup errors propagate; every effect is disposable.
  def with_icebox_workspace
    with_workspace do |root|
      %w[TST-A TST-B].each { |id| write_task(root, id: id) }
      coordinator = coordinator_for(root, "alpha" => "a" * 40)
      yield root, coordinator, coordinator.instance_variable_get(:@state_store)
    end
  end

  # Returns a valid persisted designation for type/calendar negative cases.
  def designation = { "at" => "2026-10-18T12:00:00Z" }

  # Runs the native CLI object with captured streams and an actual coordinator;
  # returns [stdout, stderr, exit code], propagating unexpected implementation errors.
  def cli(root, coordinator, command, width: nil)
    out, err = StringIO.new, StringIO.new
    client = AgentCodingTool::CLI.new(root: root, data_root: root, out: out, err: err, terminal_width: width)
    client.instance_variable_set(:@coordinator, coordinator)
    status = client.run(command.dup)
    [out.string, err.string, status]
  end

  # Asserts success and returns stdout for a synthetic inspection command.
  def output(root, coordinator, command, width: nil)
    out, err, status = cli(root, coordinator, command, width: width)
    assert_equal 0, status, err
    out
  end
end
