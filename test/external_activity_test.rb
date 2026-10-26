# frozen_string_literal: true

require "stringio"
require "timeout"
require_relative "test_helper"
require "minitest/mock"

# Offline decision/persistence matrix; native/cold-process journeys live with the
# retry integration. Every record and lifecycle mutation belongs to a fixture.
class ExternalActivityTest < Minitest::Test
  include TestHelpers

  # Creates private siblings under one disposable parent and fake Git authorities.
  # Returns no shared state; fixture files are removed even after assertions fail.
  def fixture
    Dir.mktmpdir("act18-") do |directory|
      @parent = File.realpath(directory)
      @data = File.join(@parent, "data")
      FileUtils.mkdir_p(File.join(@data, "tasks"))
      write_task(@data, id: "A")
      write_task(@data, id: "B", repositories: { "beta" => { "access" => "write" } })
      @inspector = FakeInspector.new(heads: { "alpha" => "a" * 40, "beta" => "b" * 40 })
      @states = AgentCodingTool::StateStore.new(File.join(@data, "state"))
      @coordinator = AgentCodingTool::Coordinator.new(
        task_store: AgentCodingTool::TaskStore.new(File.join(@data, "tasks")), state_store: @states,
        repo_inspector: @inspector, prompt_renderer: AgentCodingTool::PromptRenderer.new,
        prompt_root: File.join(@data, "state", "prompts"))
      @activity = @coordinator.external_activity
      yield
    end
  end

  # Reports one deterministic payload; optional values exercise each decision seam.
  def report(id = "A", **options)
    @activity.report(id, reporter: "operator", kind: "fake-codex", **options)
  end

  # Runs public CLI parsing/projection with real stores and a fake Git boundary.
  # Returns stdout; assertion failure retains stderr diagnostics in the failure.
  def cli(*arguments, expected: 0)
    output, error = StringIO.new, StringIO.new
    client = AgentCodingTool::CLI.new(root: @parent, data_root: @data, out: output, err: error)
    client.instance_variable_set(:@coordinator, @coordinator)
    assert_equal expected, client.run(arguments), error.string
    expected.zero? ? output.string : error.string
  end

  # Captures bytes and metadata, including directories, without following links.
  def contents
    Dir.glob(File.join(@parent, "**", "*"), File::FNM_DOTMATCH).sort.to_h do |path|
      stat = File.lstat(path)
      [path, [stat.mode, stat.mtime, stat.file? ? File.binread(path) : nil]]
    end
  end

  # Exact retries preserve IDs/bytes/times; incomplete or changed payloads refuse.
  def test_exact_duplicate_and_retained_identity_horizon
    fixture do
      first = report(identifier: "reported-session", note: "private note")
      before = contents
      assert_equal first, report(identifier: "reported-session", note: "private note")
      assert_equal before, contents
      assert_raises(AgentCodingTool::InvalidState) { report(identifier: "reported-session") }
      assert_raises(AgentCodingTool::InvalidState) { report(identifier: "another") }
      assert_raises(AgentCodingTool::InvalidState) { report }
      assert_raises(AgentCodingTool::InvalidState) { report("B", identifier: "reported-session", note: "private note") }
      id = first.fetch("active").fetch("observation_id")
      closed = @activity.end_activity("A", id, disposition: "failed")
      before = contents
      assert_equal closed, @activity.end_activity("A", id, disposition: "failed")
      assert_equal closed, report(identifier: "reported-session", note: "private note")
      assert_equal before, contents
      newer = report(identifier: "newer").fetch("active").fetch("observation_id")
      @activity.end_activity("A", id, disposition: "failed")
      assert_equal newer, @activity.show("A").fetch("active").fetch("observation_id")
      @activity.end_activity("A", newer, disposition: "lost-contact")
      8.times do |index|
        current = report(identifier: "session-#{index}").fetch("active").fetch("observation_id")
        @activity.end_activity("A", current, disposition: "ended")
      end
      document = @activity.show("A")
      assert_equal 8, document.fetch("closed").length
      assert_equal 2, document.fetch("omitted_older")
      assert_raises(AgentCodingTool::InvalidState) { @activity.end_activity("A", id, disposition: "failed") }
    end
  end

  # All supplied fields use UTF-8 byte limits, reject controls/types and omit the
  # payload from diagnostics. Referenced files are never opened or imported.
  def test_text_bounds_inert_references_and_safe_errors
    fixture do
      AgentCodingTool::ExternalActivity::LIMITS.each do |field, limit|
        values = ["private-" + "x" * limit, "private\ntext", "private\0text", 123, "\xff".b, "\u202eprivate"]
        values.each do |value|
          error = assert_raises(AgentCodingTool::InvalidState) do
            @activity.report("A", **{ reporter: "operator", kind: "fake" }.merge(field.to_sym => value))
          end
          refute_includes error.message, "private"
        end
      end
      fields = AgentCodingTool::ExternalActivity::LIMITS.to_h { |field, limit| [field.to_sym, "é" * (limit / 2)] }
      document = @activity.report("A", **fields)
      assert_equal Process.uid, document.fetch("active").fetch("recorded_by_uid")
      fields.each { |field, value| assert_equal value, document.fetch("active").fetch(field.to_s) }
      error = cli("external", "end", "A", "bad", "--disposition", "private-payload", expected: 2)
      refute_includes error, "private-payload"
    end
  end

  # An observation never rewrites lifecycle status/reason or prep/prompt bytes.
  # A subsequent explicit completion is visible and retains its conflict effect.
  def test_lifecycle_projection_matrix_and_complete_inconsistency
    %w[READY PREPARED STALE NEEDS_JUDGMENT BLOCKED CANDIDATE STALE_CANDIDATE].each do |label|
      fixture do
        @coordinator.prepare("A") unless label == "READY"
        @coordinator.record("A", outcome: "needs_judgment", summary: "original blocker") if label == "NEEDS_JUDGMENT"
        @coordinator.record("A", outcome: "blocked", summary: "original blocker") if label == "BLOCKED"
        @coordinator.record("A", outcome: "candidate_complete") if label.include?("CANDIDATE")
        @inspector.heads["alpha"] = "c" * 40 if label.start_with?("STALE")
        original = @coordinator.status("A")
        lifecycle = contents
        report(identifier: "/reported/pid-12345", scope_complete: true)
        status = @coordinator.status("A")
        assert_equal label, status.fetch("status")
        assert_equal original.values_at("status", "reason", "state", "execution_evidence"),
                     status.values_at("status", "reason", "state", "execution_evidence")
        assert_equal "unknown", status.fetch("external_activity").fetch("liveness")
        assert_equal "unverified", status.fetch("external_activity").fetch("isolation")
        lifecycle.each { |path, value| assert_equal value, contents.fetch(path) if File.file?(path) }
        assert_includes cli("status"), "EXTERNAL WORK REPORTED"
        minimal = cli("status", "A", "--min")
        assert_equal 1, minimal.lines.length
        assert_match(/\AA: #{label} \[external reported\] \[external conflict\] — Task\n\z/, minimal)
      end
    end
    fixture do
      @coordinator.record("A", outcome: "complete")
      assert_raises(AgentCodingTool::InvalidState) { report }
      @coordinator.reset("A")
      id = report(scope_complete: true).fetch("active").fetch("observation_id")
      @coordinator.record("A", outcome: "complete")
      assert_includes cli("status", "--active"), "INCONSISTENCY: COMPLETE"
      minimal = cli("status", "--active", "--min")
      assert_equal 2, minimal.lines.length
      assert_includes minimal, "A: COMPLETE [external reported] [external conflict] — Task\n"
      assert_equal id, @coordinator.status("A").fetch("external_activity").fetch("observation_id")
      @activity.assert_clear!("B") # disjoint bounded scope remains independent
      @activity.end_activity("A", id, disposition: "ended")
      assert_equal "COMPLETE", @coordinator.status("A").fetch("status")
    end
  end

  # Readers do not allocate directories, change timestamps or probe processes.
  # Public JSON excludes supplied identifiers/notes/references and retains schema.
  def test_read_only_inspection_and_no_observation_json_compatibility
    fixture do
      before = contents
      assert_nil @activity.show("A")["active"]
      baseline = JSON.parse(cli("next", "--json"))
      assert_equal before, contents
      refute baseline.fetch("facts").key?("external_reservations")
      report(identifier: "SECRET-IDENTIFIER", note: "SECRET-NOTE", reference: "/private/SENTINEL")
      before = contents
      Open3.stub(:capture3, ->(*) { raise "inspection launched a process" }) do
        Process.stub(:kill, ->(*) { raise "inspection probed liveness" }) do
          2.times do
            cli("external", "show", "A")
            cli("status", "A")
            cli("status")
            output = cli("next", "--json")
            %w[SECRET-IDENTIFIER SECRET-NOTE /private/SENTINEL].each { |sentinel| refute_includes output, sentinel }
            document = JSON.parse(output)
            assert_equal "agent-coding-tool-next/v0.1", document.fetch("schema_version")
            assert_empty document.fetch("recommendations").fetch("starts")
            assert_empty document.fetch("recommendations").fetch("waiting_capacity")
          end
        end
      end
      assert_equal before, contents
      @coordinator.prepare("A")
      prompt = @coordinator.launch_prompt("A")
      material = JSON.generate(@states.load("A")) + prompt
      %w[SECRET-IDENTIFIER SECRET-NOTE /private/SENTINEL .external-activity].each { |sentinel| refute_includes material, sentinel }
    end
  end

  # READY/blocked/recent-completion compression cannot hide an open observation.
  def test_dashboard_filters_retain_open_observations
    fixture do
      12.times { |index| write_task(@data, id: "F-#{index}") }
      report("F-11", scope_complete: true)
      assert_includes cli("status"), "F-11: READY"
      [11, *(0...11)].each { |index| @coordinator.record("F-#{index}", outcome: "complete") }
      assert_includes cli("status"), "F-11: COMPLETE"
      @coordinator.reset("F-11")
      @coordinator.prepare("F-11")
      @coordinator.record("F-11", outcome: "blocked", summary: "original reason")
      %w[A B F-0 F-1].each do |id|
        @coordinator.reset(id)
        @coordinator.prepare(id)
        @coordinator.record(id, outcome: "blocked", summary: "other")
      end
      assert_includes cli("status"), "F-11: BLOCKED"
    end
  end

  # Whole-repository equality normalizes supported remote aliases and ignores
  # branch separation only for external scope. Known disjoint writers can start.
  def test_bounded_unknown_alias_and_read_only_scheduling
    fixture do
      write_task(@data, id: "C", repositories: { "alias" => { "access" => "write", "branch" => "feature" } })
      write_task(@data, id: "R", repositories: { "alpha" => { "access" => "read_only" } })
      @inspector.remote_urls = { "alias" => "https://github.com/EXAMPLE/alpha.git" }
      report(scope_complete: true)
      assert_raises(AgentCodingTool::InvalidState) { @activity.assert_clear!("A") }
      assert_raises(AgentCodingTool::InvalidState) { @activity.assert_clear!("C") }
      @activity.assert_clear!("B")
      @activity.assert_clear!("R")
      document = JSON.parse(cli("next", "--json"))
      assert_equal %w[B R], document.fetch("recommendations").fetch("starts").map { |row| row["id"] }.sort
      assert_equal %w[A C], document.fetch("recommendations").fetch("external_waits").map { |row| row["id"] }.sort
      @coordinator.prepare("B")
      cli("start", "B")
      id = @activity.show("A").fetch("active").fetch("observation_id")
      @activity.end_activity("A", id, disposition: "ended")
      report
      assert_raises(AgentCodingTool::InvalidState) { @activity.assert_clear!("B") }
      @activity.assert_clear!("R")
    end
  end

  # Scope additions cannot subtract registered/prepared writers. Changed authority
  # or unresolved supplied facts make the projection unknown without any writes.
  def test_scope_floor_additions_and_authority_drift
    fixture do
      @coordinator.prepare("A")
      @inspector.remote_urls = { "alpha" => "ssh://git@github.com/example/new.git" }
      report(scope_complete: true, authorities: [["git@github.com:example/extra.git", "other"]])
      authorities = @activity.active_snapshot.first.fetch("envelope").fetch("authorities")
      assert_equal %w[example/alpha example/extra example/new], authorities.map { |repo| repo.fetch("repository_id") }.sort
      @inspector.remote_urls["alpha"] = "git@github.com:example/changed.git"
      before = contents
      assert_equal "unknown", @activity.active_snapshot.first.fetch("envelope").fetch("scope")
      assert_raises(AgentCodingTool::InvalidState) { @activity.assert_clear!("B") }
      assert_equal before, contents
      id = @activity.show("A").fetch("active").fetch("observation_id")
      @activity.end_activity("A", id, disposition: "ended")
      report(scope_complete: true, authorities: [["pid-123", "reported"]])
      assert_equal "unknown", @activity.active_snapshot.first.fetch("envelope").fetch("scope")
    end
  end

  # Reporting overlapping existing work remains possible; it cannot authorize a
  # new same-task start, override external conflicts, or clear managed state.
  def test_execution_refusals_and_lifecycle_boundaries
    fixture do
      @coordinator.prepare("A")
      @coordinator.start("A")
      original = @states.load("A")
      report(scope_complete: true)
      assert_equal original, @states.load("A")
      assert_includes cli("status", "A"), "managed execution also recorded"
      assert_raises(AgentCodingTool::InvalidState) { @coordinator.start("A", allow_write_collision: true) }
      @coordinator.reset("A")
      assert @activity.show("A")["active"]
      assert_nil @states.load("A")["snapshot"]
      assert_includes cli("received", "A", expected: 2), "prepare the task"
      assert_includes cli("checkpoint", "record", "A", "--workspace", @parent, expected: 2), "in-flight"
      @coordinator.prepare("A")
      assert_includes cli("start", "A", "--allow-write-collision", expected: 2), "external activity conflict"
      @coordinator.record("A", outcome: "candidate_complete", artifact: "separately-reviewed.patch")
      assert @activity.show("A")["active"]
    end
  end

  # The external facade and lifecycle APIs share one validated reservation.
  # Borrowing does not release it; a missing or foreign descriptor cannot bypass it.
  def test_shared_reservation_borrows_lock_for_lifecycle_without_unlocking
    fixture do
      @activity.with_lock do |lock|
        Timeout.timeout(5) do
          @coordinator.prepare("A", reservation_lock: lock)
          before = @states.load("A")
          assert_raises(AgentCodingTool::InvalidState) { @coordinator.start("A") }
          File.open(File.join(@parent, "foreign.lock"), "w+") do |foreign|
            assert_raises(AgentCodingTool::InvalidState) { @coordinator.start("A", reservation_lock: foreign) }
          end
          assert_equal before, @states.load("A")
          @coordinator.start("A", reservation_lock: lock)
          @coordinator.record("A", outcome: "failed", reservation_lock: lock)
          assert_raises(AgentCodingTool::InvalidState) { report("B") }
        end
      end
      assert_equal "FAILED", @coordinator.status("A").fetch("status")
      assert report("B").fetch("active")
    end
  end

  # Busy/malformed locks refuse tasks even without managed runs. Competing
  # processes cannot create two observations or reuse one retained supplied ID.
  def test_lock_serialization_and_cross_task_identity_races
    fixture do
      @coordinator.prepare("A")
      @activity.with_lock do
        assert_includes cli("external", "report", "A", "--reporter", "op", "--kind", "fake", expected: 2), "reservation lock"
        assert_includes cli("start", "A", expected: 2), "reservation lock"
      end
      children = %w[A B].map do |id|
        fork do
          begin
            report(id, identifier: "shared")
            exit! 0
          rescue AgentCodingTool::InvalidState
            exit! 2
          end
        end
      end
      results = children.map { |child| Process.wait2(child).last.exitstatus }.sort
      assert_equal [0, 2], results
      assert_equal 1, @activity.active_snapshot.length
      path = File.join("#{@data}-runs", "launch.lock")
      File.chmod(0o644, path)
      assert_raises(AgentCodingTool::InvalidState) { report }
      File.chmod(0o600, path)
      File.unlink(path)
      File.symlink(File.join(@data, "state", "A.yml"), path)
      assert_raises(AgentCodingTool::InvalidState) { report }
    end
  end

  # Damaged schemas, names, ownership modes and symlinks never become inactivity
  # or route writes to lifecycle data. Errors omit private corrupt YAML payloads.
  def test_foreign_namespace_and_corruption_fail_closed
    fixture do
      report
      path = File.join("#{@data}-runs", AgentCodingTool::ExternalActivity::NAMESPACE, "A.yml")
      original = File.binread(path)
      partial = YAML.safe_load(original)
      partial["closed"] = [nil]
      ["SECRET: [", "---\n", YAML.dump(partial), YAML.dump({ "schema" => "other", "secret" => "SECRET" })].each do |bytes|
        File.binwrite(path, bytes)
        error = assert_raises(AgentCodingTool::InvalidState) { @activity.show("A") }
        refute_includes error.message, "SECRET"
        assert_raises(AgentCodingTool::InvalidState) { @activity.assert_clear!("B") }
      end
      File.binwrite(path, original)
      File.chmod(0o644, path)
      assert_raises(AgentCodingTool::InvalidState) { @activity.records }
      File.chmod(0o600, path)
      File.unlink(path)
      target = File.join(@data, "state", "sentinel.yml")
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, "SECRET")
      File.symlink(target, path)
      assert_raises(AgentCodingTool::InvalidState) { report }
      assert_equal "SECRET", File.binread(target)
      assert_raises(AgentCodingTool::InvalidTask) { report("../unsafe") }
    end
  end

  # Serialization/rename failures preserve the old complete record. Publication
  # followed by uncertainty is safely retryable without duplicate ID/history.
  def test_atomic_failure_before_and_after_rename
    fixture do
      initial = report(identifier: "first")
      id = initial.fetch("active").fetch("observation_id")
      before = contents
      YAML.stub(:dump, ->(*) { raise TypeError, "serialization fault" }) do
        assert_raises(TypeError) { @activity.end_activity("A", id, disposition: "ended") }
      end
      assert_equal before, contents
      File.stub(:rename, ->(*) { raise Errno::ENOSPC }) do
        assert_raises(Errno::ENOSPC) { @activity.end_activity("A", id, disposition: "ended") }
      end
      assert_equal initial, @activity.show("A")
      original_rename = File.method(:rename)
      File.stub(:rename, lambda { |source, destination|
        original_rename.call(source, destination)
        raise AgentCodingTool::InvalidState, "state replaced; directory synchronization failed"
      }) do
        error = assert_raises(AgentCodingTool::InvalidState) { @activity.end_activity("A", id, disposition: "ended") }
        assert_includes error.message, "state replaced"
      end
      closed = @activity.show("A")
      assert_nil closed["active"]
      assert_equal 1, closed.fetch("closed").length
      assert_equal closed, @activity.end_activity("A", id, disposition: "ended")
    end
  end

  # Exercises actual StateStore temporaries through the private namespace wrapper.
  # Cold reads see old bytes during partial writes; post-rename fsync uncertainty
  # leaves one committed closeout whose retry cannot add another history row.
  def test_partial_write_cold_reader_and_post_rename_sync_failure
    fixture do
      initial = report(identifier: "first")
      id = initial.fetch("active").fetch("observation_id")
      create = Tempfile.method(:create)
      Tempfile.stub(:create, lambda { |*arguments, **options, &block|
        create.call(*arguments, **options) do |temporary|
          write = temporary.method(:write)
          temporary.stub(:write, lambda { |bytes|
            written = write.call(bytes.byteslice(0, 7))
            temporary.flush
            assert_equal initial, @activity.show("A")
            written
          }) { block.call(temporary) }
        end
      }) do
        assert_raises(IOError) { @activity.end_activity("A", id, disposition: "ended") }
      end
      assert_equal initial, @activity.show("A")
      open_file = File.method(:open)
      File.stub(:open, lambda { |path, *arguments, **options, &block|
        if path == File.join("#{@data}-runs", AgentCodingTool::ExternalActivity::NAMESPACE) && arguments.empty?
          open_file.call(path, *arguments, **options) do |directory|
            directory.stub(:fsync, -> { raise Errno::EIO }) { block.call(directory) }
          end
        else
          open_file.call(path, *arguments, **options, &block)
        end
      }) do
        error = assert_raises(AgentCodingTool::InvalidState) { @activity.end_activity("A", id, disposition: "ended") }
        assert_includes error.message, "state replaced"
      end
      closed = @activity.show("A")
      assert_nil closed["active"]
      assert_equal 1, closed.fetch("closed").length
      assert_equal closed, @activity.end_activity("A", id, disposition: "ended")
    end
  end

  # A removed/relabeled prepared writer cannot be subtracted by a fresh report;
  # the historical snapshot has no access labels, so all its identities are kept.
  def test_preparation_scope_floor_survives_read_only_relabeling
    fixture do
      @coordinator.prepare("A")
      write_task(@data, id: "A", repositories: { "alpha" => { "access" => "read_only" } })
      report(scope_complete: true)
      assert_equal ["example/alpha"], @activity.active_snapshot.first.fetch("envelope").fetch("authorities").map { |row| row["repository_id"] }
    end
  end

  # Competing same-task declarations never replace reality; a declaration racing
  # a managed manual start is still recordable and preserves the start's identity.
  # Losers retry only lock contention; no lock is held for the worker lifetime.
  def test_same_task_report_and_manual_start_races
    fixture do
      @coordinator.prepare("A")
      children = 2.times.map do
        fork do
          begin
            report
            exit! 0
          rescue AgentCodingTool::InvalidState
            exit! 2
          end
        end
      end
      assert_equal [0, 2], children.map { |child| Process.wait2(child).last.exitstatus }.sort
      original = @activity.show("A").fetch("active").fetch("observation_id")
      @activity.end_activity("A", original, disposition: "ended")
      children = ["report", "start"].map do |operation|
        fork do
          begin
            if operation == "report"
              report(identifier: "racing-worker")
            else
              @activity.with_lock { |lock| @coordinator.start("A", reservation_lock: lock) }
            end
            exit! 0
          rescue AgentCodingTool::InvalidState
            exit! 2
          end
        end
      end
      results = children.map { |child| Process.wait2(child).last.exitstatus }
      assert results.all? { |status| [0, 2].include?(status) }
      report(identifier: "racing-worker") unless @activity.show("A")["active"]
      current = @activity.show("A").fetch("active").fetch("observation_id")
      @activity.end_activity("A", original, disposition: "ended")
      assert_equal current, @activity.show("A").fetch("active").fetch("observation_id")
      assert_raises(AgentCodingTool::InvalidState) { @activity.with_lock { |lock| @coordinator.start("A", allow_write_collision: true, reservation_lock: lock) } }
    end
  end
end
