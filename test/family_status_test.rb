# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

# Exercises family presentation with the real coordinator/planner and in-memory
# task/state stores. No lifecycle calls, repository processes or network are used.
class FamilyStatusTest < Minitest::Test
  # Provides immutable task registry reads; unknown IDs raise the ordinary error.
  TaskRegistry = Struct.new(:all) do
    # Returns a task by exact ID or raises InvalidTask; never changes the registry.
    def load(id)
      all.find { |task| task.fetch("id") == id } || raise(AgentCodingTool::InvalidTask, "task not found: #{id}")
    end
  end

  # Provides legacy empty states without a write API, catching accidental writes.
  States = Struct.new(:rows) do
    # Returns an existing mapping or an empty state for an unprepared task.
    def load(id) = rows.fetch(id, {})
  end

  # Declares an empty external-evidence boundary for this in-memory display
  # fixture. Real persistence/projection is covered by external activity journeys.
  class NoExternalActivity
    # Returns no external reservations without filesystem or process access.
    def active_snapshot = []
    # Returns no conflicts for any task in this no-observation fixture.
    def conflicts(*, **) = []
  end

  # Counts resolution/probe calls; pushed freshness is deterministic and offline.
  class Inspector
    attr_reader :batches, :authority_calls
    attr_accessor :heads

    # Starts with no probes and a default valid head for every fake authority.
    def initialize
      @batches = 0
      @authority_calls = 0
      @heads = {}
    end

    # Returns the fake remote/branch pair and counts local authority resolution.
    def repository_authority(name, spec)
      @authority_calls += 1
      ["git@github.com:fixture/#{name}.git", spec.fetch("branch", "main")]
    end

    # Resolves a whole batch, allowing explicit stale/malformed head injections.
    def pushed_heads(references)
      @batches += 1
      references.to_h do |reference|
        key = reference.values_at("remote_url", "branch")
        [key, heads.fetch(key, "a" * 40)]
      end
    end

    # Raises on unexpected new snapshots during read-only inspection.
    def snapshot(*) = raise("status must not take new snapshots")
  end

  # Simulates colored terminal output at a fixed width without real terminals.
  class Terminal < StringIO
    # Captures output for a terminal with a fixed number of display columns.
    def initialize(width)
      super()
      @width = width
    end

    # Enables the production TTY color path.
    def tty? = true
    # Returns a normal terminal-height/width pair without touching a real TTY.
    def winsize = [24, @width]
  end

  # Covers the exact compression threshold and unchanged-input determinism.
  def test_zero_one_six_and_seven_ready
    [0, 1, 6, 7].each do |count|
      tasks = family_tasks("CL" => count)
      coordinator, inspector = build(tasks)
      first = output(coordinator, %w[status])
      assert_equal tasks.first(count > 6 ? 3 : count).map { |task| task.fetch("id") }, ready_ids(first)
      assert_equal first, output(coordinator, %w[status])
      if count > 6
        assert_includes first, "CL: 7 READY, 4 hidden — act stat --fam CL"
      else
        refute_includes first, "hidden"
      end
      assert_equal 0, inspector.batches
    end
  end

  # Four-plus families receive exactly one each, even above a six-row budget.
  def test_four_families_and_act_preference_have_exact_summaries
    tasks = family_tasks("CL" => 8, "ECT" => 2, "TST" => 3, "BUG" => 1)
    coordinator, = build(tasks)
    plain = output(coordinator, %w[status])
    assert_equal %w[BUG-01 CL-01 ECT-01 TST-01], ready_ids(plain)
    { "CL" => [8, 7], "ECT" => [2, 1], "TST" => [3, 2], "BUG" => [1, 0] }.each do |family, (total, hidden)|
      assert_includes plain, "#{family}: #{total} READY, #{hidden} hidden"
      assert_includes plain, "act stat --fam #{family}" if hidden.positive?
    end
    tasks.concat(family_tasks("ACT" => 1))
    with_act = output(coordinator, %w[status])
    assert_equal %w[ACT-01 BUG-01 CL-01 ECT-01 TST-01], ready_ids(with_act)
    assert_match(/^ACT-01: READY \(NEXT\)/, with_act)
    assert_includes with_act, "ACT: 1 READY, 0 hidden"
    assert_equal 1, with_act.scan("(NEXT)").length
    tasks.concat(family_tasks("FS" => 1, "IG" => 1))
    assert_equal 7, ready_ids(output(coordinator, %w[status])).length
  end

  # Breadth first selection fills by global rank without relaxing either cap.
  def test_one_two_and_three_family_allocations
    [
      [{ "CL" => 7 }, %w[CL-01 CL-02 CL-03]],
      [{ "CL" => 7, "ECT" => 7 }, %w[CL-01 CL-02 CL-03 ECT-01 ECT-02 ECT-03]],
      [{ "CL" => 7, "ECT" => 1 }, %w[CL-01 CL-02 CL-03 ECT-01]],
      [{ "CL" => 7, "ECT" => 1, "TST" => 1 }, %w[CL-01 CL-02 CL-03 ECT-01 TST-01]],
      [{ "CL" => 7, "ECT" => 7, "TST" => 7 }, %w[CL-01 CL-02 CL-03 ECT-01 ECT-02 TST-01]]
    ].each do |distribution, expected|
      coordinator, = build(family_tasks(distribution))
      assert_equal expected, ready_ids(output(coordinator, %w[status --active]))
    end
  end

  # The approved exception replaces within the same family and preserves ranking.
  def test_reserved_leaders_cannot_hide_global_next_for_four_or_fewer_families
    [{ "CL" => 4, "ECT" => 1, "TST" => 1, "BUG" => 1 }, { "CL" => 7 }].each do |distribution|
      tasks = family_tasks(distribution)
      blocked_ids = distribution.length == 4 ? %w[CL-01] : %w[CL-01 CL-02 CL-03]
      blocked_ids.each { |id| tasks.find { |task| task["id"] == id }["repositories"] = repos("busy") }
      tasks << task("RUN-01", repository: "busy")
      # Give CL's leader impact above other families using a real dependency.
      tasks << task("DEP-01", dependencies: ["CL-01"])
      tasks << task("DEP-02", dependencies: ["CL-02"])
      states = { "RUN-01" => prepared_state("busy").merge("started_at" => "now") }
      coordinator, inspector = build(tasks, states:)
      before = Marshal.dump([tasks, states])
      document = JSON.parse(output(coordinator, %w[next --json]))
      next_id = document.dig("recommendations", "starts", 0, "id")
      assert_equal distribution.length == 4 ? "CL-02" : "CL-04", next_id
      dashboard = output(coordinator, %w[status])
      assert_equal distribution.length, dashboard.scan(/READY, \d+ hidden/).length
      assert_includes ready_ids(dashboard), next_id
      assert_match(/^#{next_id}: READY \(NEXT\)/, dashboard)
      assert_equal distribution.length == 4 ? 4 : 3, ready_ids(dashboard).length
      refute_includes ready_ids(dashboard), blocked_ids.last
      assert_equal before, Marshal.dump([tasks, states])
      assert_equal 2, inspector.batches
    end
  end

  # All public recommendation surfaces share the full ranking, including ACT
  # preference, capacity waits, natural ties and one filtered global NEXT.
  def test_status_next_and_json_share_priority_and_cross_family_reservations
    tasks = family_tasks("ACT" => 2, "CL" => 7)
    tasks.find { |row| row["id"] == "ACT-01" }["repositories"] = repos("busy")
    tasks << task("RUN-01", repository: "busy")
    tasks << task("DEP-01", dependencies: ["CL-01"])
    coordinator, inspector = build(tasks, states: { "RUN-01" => prepared_state("busy").merge("started_at" => "now") })
    document = JSON.parse(output(coordinator, %w[next --json]))
    facts = document.dig("facts", "tasks")
    ready = facts.select { |row| row["status"] == "READY" }
    assert_equal %w[ACT-01 ACT-02 CL-01 CL-02 CL-03 CL-04 CL-05 CL-06 CL-07], ready.map { |row| row["id"] }
    assert_equal ready.map { |row| row["priority_rank"] }.sort, ready.map { |row| row["priority_rank"] }
    assert_equal "ACT-02", document.dig("recommendations", "starts", 0, "id")
    assert_equal "ACT-01", document.dig("recommendations", "waiting_capacity", 0, "id")
    assert_includes output(coordinator, %w[next]), "  ACT-02 (READY) — Title ACT-02"
    assert_match(/^ACT-02: READY \(NEXT\)/, output(coordinator, %w[status]))
    filtered = output(coordinator, %w[status --fam CL])
    assert_equal (1..7).map { |number| "CL-%02d" % number }, ready_ids(filtered)
    refute_includes filtered, "(NEXT)"
    assert_match(/^ACT-02: READY \(NEXT\)/, output(coordinator, %w[status --fam ACT]))
    assert_equal 5, inspector.batches
  end

  # Impact dimensions retain their order in both priority tiers; only true ties
  # reach the natural numeric comparator and full-ID fallback (including zeros).
  def test_all_four_metrics_natural_ties_and_non_ready_order
    cli = AgentCodingTool::CLI.allocate
    %w[ACT CL].each do |family|
      ids = %w[WIDTH COUNT DEPTH TOTAL ZERO].map { |suffix| "#{family}-#{suffix}" }
      metrics = { ids[0] => [0, 0, 0, 2], ids[1] => [0, 0, 2, 1], ids[2] => [2, 0, 1, 1], ids[3] => [1, 2, 1, 1] }
      rows = ids.reverse.map { |id| status_row(id) }
      assert_equal ids, cli.send(:sort_statuses, rows, metrics).map { |row| row["id"] }
    end
    ids = %w[ACT-10 ACT-02 ACT-2 ACT-STATE-10 ACT-STATE-2 CL-AFDP-02 CL-AFDP-01A T10 T2 -odd]
    expected = %w[ACT-02 ACT-2 ACT-10 ACT-STATE-2 ACT-STATE-10 -odd CL-AFDP-01A CL-AFDP-02 T2 T10]
    3.times do |seed|
      assert_equal expected, cli.send(:sort_statuses, ids.shuffle(random: Random.new(seed)).map { |id| status_row(id) }, {}).map { |row| row["id"] }
    end
    assert_equal "CL", cli.send(:task_family, "CL-AFW-07A")
    assert_equal "ACT", cli.send(:task_family, "ACT-STATE-01")
    %w[T1 legacy -odd].each { |id| assert_equal id, cli.send(:task_family, id) }
    rows = [status_row("Z", "CANDIDATE"), status_row("ACT-14", "CANDIDATE"), status_row("ACT-15", "BLOCKED"), status_row("B", "BLOCKED")]
    assert_equal %w[Z ACT-14 ACT-15 B], cli.send(:sort_statuses, rows, {}).map { |row| row["id"] }
  end

  # The full registry defines known families, and the global five-completion
  # window is applied before the family filter, retaining exhaustive opt-ins.
  def test_family_filter_completion_window_and_blocked_limit
    tasks = family_tasks("CL" => 7, "CLX" => 1, "DONE" => 1, "OLD" => 1, "NEW" => 5, "WAIT" => 5)
    states = {}
    %w[OLD-01 DONE-01 NEW-01 NEW-02 NEW-03 NEW-04 NEW-05].each_with_index do |id, index|
      states[id] = { "result" => { "outcome" => "complete", "recorded_at" => "2026-10-15T00:00:%02dZ" % index } }
    end
    (1..5).each { |number| states["WAIT-%02d" % number] = { "result" => { "outcome" => "blocked", "summary" => "decision" } } }
    coordinator, = build(tasks, states:)
    assert_equal (1..7).map { |number| "CL-%02d" % number }, ready_ids(output(coordinator, %w[status --fam CL]))
    assert_equal 8, ready_ids(output(coordinator, %w[status --all])).length
    assert_equal "", output(coordinator, %w[status --fam DONE])
    assert_includes output(coordinator, %w[status --fam DONE --all]), "DONE-01: COMPLETE"
    assert_equal "", output(coordinator, %w[status --fam DONE --active])
    assert_equal "", output(coordinator, %w[status --fam OLD])
    assert_equal 3, output(coordinator, %w[status --fam WAIT]).scan(/: BLOCKED/).length
    assert_equal 5, output(coordinator, %w[status --fam WAIT --all]).scan(/: BLOCKED/).length
    explicit = output(coordinator, %w[status CL-07])
    assert_includes explicit, "CL-07: READY — Title CL-07"
    refute_includes explicit, "(NEXT)"
  end

  # Invalid filters fail clearly before any freshness lookup; no selector can
  # accidentally broaden scope or create a family-local recommendation.
  def test_invalid_selectors_and_unsupported_options
    coordinator, inspector = build(family_tasks("CL" => 1))
    [%w[--fam], %w[--fam UNKNOWN], %w[--fam CL --fam CLX], %w[--fam CL --fam CL],
     %w[CL-01 --fam CL], %w[--all --active], %w[--family CL], %w[--fa CL], %w[--bogus]].each do |args|
      out, err = StringIO.new, StringIO.new
      cli = client(coordinator, out:, err:)
      assert_equal 2, cli.run(["status", *args]), args.inspect
      assert_empty out.string
      assert_match(/ERROR: .+/, err.string)
    end
    assert_equal 0, inspector.batches
  end

  # Width-aware summaries retain a usable command; ANSI/color and NO_COLOR
  # retain the existing headline contract. Long commands remain intact.
  def test_narrow_width_color_no_color_and_shell_escaped_fallback
    coordinator, = build(family_tasks("CL" => 7))
    old = ENV.delete("NO_COLOR")
    begin
      [38, 60, 100].each do |width|
        dashboard = output(coordinator, %w[status], out: Terminal.new(width))
        assert_equal 1, dashboard.scan("(NEXT)").length
        assert_includes dashboard, "act stat --fam CL"
        assert_match(/\e\[\d+mREADY\e\[0m/, dashboard)
        dashboard.lines.each do |line|
          assert_operator AgentCodingTool::CLI.allocate.send(:display_width, line.chomp), :<=, width
        end
      end
      ENV["NO_COLOR"] = "1"
      plain = output(coordinator, %w[status], out: Terminal.new(38))
      refute_match(/\e\[/, plain)
      assert_match(/^CL-01: READY \(NEXT\)/, plain)
    ensure
      old ? ENV["NO_COLOR"] = old : ENV.delete("NO_COLOR")
    end
    tasks = (1..7).map { |number| task("-odd-#{number}") }
    coordinator, = build(tasks)
    assert_equal 7, ready_ids(output(coordinator, %w[status])).length
    assert_equal ["-odd-1"], ready_ids(output(coordinator, ["status", "--fam=-odd-1"]))
    assert_equal ["-odd-1"], ready_ids(output(coordinator, ["status", "--", "-odd-1"]))
  end

  # ACT-14's ID grants no readiness: terminal and stale states retain their
  # real fallback behavior; a different eligible ACT task may outrank it.
  def test_act14_is_not_hardcoded_and_stale_inspection_fails_closed
    tasks = [task("ACT-14"), task("ACT-02"), task("CL-01")]
    ["complete", "blocked", "failed", "needs_judgment"].each do |outcome|
      coordinator, = build(tasks, states: { "ACT-14" => { "result" => { "outcome" => outcome } } })
      assert_match(/^ACT-02: READY \(NEXT\)/, output(coordinator, %w[status]))
    end
    coordinator, inspector = build(tasks, states: { "ACT-14" => prepared_state("ACT-14") })
    inspector.heads[["git@github.com:fixture/ACT-14.git", "main"]] = "b" * 40
    dashboard = output(coordinator, %w[status])
    assert_match(/^ACT-14: STALE/, dashboard)
    assert_match(/^ACT-02: READY \(NEXT\)/, dashboard)
    document = JSON.parse(output(coordinator, %w[next --json]))
    assert_equal "STALE", document.dig("facts", "tasks").find { |row| row["id"] == "ACT-14" }.fetch("status")
    inspector.heads[["git@github.com:fixture/ACT-14.git", "main"]] = "invalid"
    out, err = StringIO.new, StringIO.new
    assert_equal 2, client(coordinator, out:, err:).run(%w[next --json])
    assert_empty out.string
    assert_match(/missing or malformed/, err.string)
  end

  # The cleanup leads CL despite genuine downstream benefits elsewhere in CL.
  # Public views share that ranking, preserve ACT's global NEXT and do no writes.
  def test_batch39_cleanup_priority_across_public_views
    tasks = family_tasks("ACT" => 1, "CL" => 7, "BUG" => 1, "ECT" => 1)
    tasks << task("CL-WLO-01")
    tasks << task("DEP-01", dependencies: ["CL-01"])
    tasks << task("DEP-02", dependencies: ["CL-01"])
    tasks << task("DEP-03", dependencies: ["CL-02"])
    states = {}
    before = Marshal.dump([tasks, states])
    coordinator, inspector = build(tasks, states:)
    document = JSON.parse(output(coordinator, %w[next --json]))
    ready = document.dig("facts", "tasks").select { |row| row["status"] == "READY" }
    cl_ids = ["CL-WLO-01", *(1..7).map { |number| "CL-%02d" % number }]
    assert_equal cl_ids, ready.select { |row| row["id"].start_with?("CL-") }.map { |row| row["id"] }
    assert_equal "ACT-01", ready.first.fetch("id")
    assert_equal "ACT-01", document.dig("recommendations", "starts", 0, "id")
    assert_equal 0, document.dig("recommendations", "starts").find { |row| row["id"] == "CL-WLO-01" }.dig("downstream", "immediate_unlock_count")
    assert_equal 2, document.dig("recommendations", "starts").find { |row| row["id"] == "CL-01" }.dig("downstream", "immediate_unlock_count")
    assert_equal cl_ids, ready_ids(output(coordinator, %w[status --fam CL]))
    assert_equal ready.map { |row| row["id"] }, ready_ids(output(coordinator, %w[status --all]))
    dashboard = output(coordinator, %w[status])
    assert_includes ready_ids(dashboard), "CL-WLO-01"
    assert_match(/^ACT-01: READY \(NEXT\)/, dashboard)
    refute_includes output(coordinator, %w[status --fam CL]), "(NEXT)"
    starts = document.dig("recommendations", "starts").map { |row| row["id"] }
    plain = output(coordinator, %w[next])
    positions = starts.map { |id| plain.index("  #{id} (READY)") }
    assert positions.all?, plain
    assert_equal positions.sort, positions
    assert_equal before, Marshal.dump([tasks, states])
    assert_equal 0, inspector.batches
  end

  # Only existing CL slots move: unrelated families retain even their absolute
  # positions, other CL order stays stable, metrics and input rows are unchanged.
  def test_batch39_exception_preserves_unrelated_positions_and_metrics
    cli = AgentCodingTool::CLI.allocate
    rows = %w[CL-WLO-01 CL-A CL-B CL-C BUG-01 ECT-01 ACT-01].map { |id| status_row(id) }
    metrics = { "CL-A" => [0, 0, 0, 4], "BUG-01" => [0, 0, 0, 3],
                "CL-B" => [0, 0, 0, 2], "ECT-01" => [0, 0, 0, 1] }
    before = Marshal.dump([rows, metrics])
    result = cli.send(:sort_statuses, rows, metrics).map { |row| row["id"] }
    assert_equal %w[ACT-01 CL-WLO-01 BUG-01 CL-A ECT-01 CL-B CL-C], result
    assert_equal before, Marshal.dump([rows, metrics])
    assert_equal result, cli.send(:sort_statuses, rows.reverse, metrics).map { |row| row["id"] }
  end

  # No target or any non-READY lifecycle (including fresh PREPARED) is inert;
  # similar identifiers and other CL tasks retain the ordinary comparator.
  def test_batch39_missing_non_ready_and_similar_ids_receive_no_exception
    cli = AgentCodingTool::CLI.allocate
    ids = %w[CL-WLO-01-X CL-WLO-010 CL-02 CL-01 BUG-01 ACT-01]
    rows = ids.map { |id| status_row(id) }
    expected = %w[ACT-01 BUG-01 CL-01 CL-02 CL-WLO-01-X CL-WLO-010]
    assert_equal expected, cli.send(:sort_statuses, rows, {}).map { |row| row["id"] }
    (AgentCodingTool::CLI::STATUS_ORDER.keys - ["READY"]).each do |label|
      target = status_row("CL-WLO-01", label)
      baseline = cli.send(:sort_statuses, [*rows, status_row("CL-ZZZ", label)], {})
                    .map { |row| row["id"] == "CL-ZZZ" ? "CL-WLO-01" : row["id"] }
      assert_equal baseline, cli.send(:sort_statuses, [*rows, target], {}).map { |row| row["id"] }, label
    end
  end

  # The exact preferred ID cannot bypass a live reservation, malformed/stale
  # provenance or a dependency. Capacity waits remain factual READY rows.
  def test_batch39_priority_does_not_bypass_reservations_staleness_or_dependencies
    tasks = [task("ACT-01"), task("CL-01"), task("CL-WLO-01", repository: "busy"), task("RUN-01", repository: "busy")]
    states = { "RUN-01" => prepared_state("busy").merge("started_at" => "now") }
    coordinator, inspector = build(tasks, states:)
    before = Marshal.dump([tasks, states])
    document = JSON.parse(output(coordinator, %w[next --json]))
    assert_equal %w[ACT-01 CL-01], document.dig("recommendations", "starts").map { |row| row["id"] }
    assert_equal "CL-WLO-01", document.dig("recommendations", "waiting_capacity", 0, "id")
    assert_equal "RUN-01", document.dig("recommendations", "waiting_capacity", 0, "conflicts", 0, "id")
    assert_equal %w[CL-WLO-01 CL-01], ready_ids(output(coordinator, %w[status --fam CL]))
    assert_match(/^ACT-01: READY \(NEXT\)/, output(coordinator, %w[status]))
    assert_equal before, Marshal.dump([tasks, states])
    assert_equal 3, inspector.batches

    coordinator, inspector = build(tasks.first(3), states: { "CL-WLO-01" => prepared_state("busy") })
    inspector.heads[["git@github.com:fixture/busy.git", "main"]] = "b" * 40
    document = JSON.parse(output(coordinator, %w[next --json]))
    target = document.dig("facts", "tasks").find { |row| row["id"] == "CL-WLO-01" }
    assert_equal "STALE", target.fetch("status")
    refute_includes document.dig("recommendations", "starts").map { |row| row["id"] }, "CL-WLO-01"
    inspector.heads[["git@github.com:fixture/busy.git", "main"]] = "invalid"
    out, err = StringIO.new, StringIO.new
    assert_equal 2, client(coordinator, out:, err:).run(%w[next --json])
    assert_empty out.string
    assert_match(/missing or malformed/, err.string)

    tasks.last["depends_on"] = ["CL-01"]
    tasks[2]["depends_on"] = ["CL-01"]
    coordinator, = build(tasks)
    assert_equal ["CL-01"], ready_ids(output(coordinator, %w[status --fam CL]))
    assert_includes output(coordinator, %w[status --fam CL]), "CL-WLO-01: BLOCKED"
  end

  # Reordering an identical READY registry adds neither freshness batches nor
  # authority lookups; state stores expose no write API on either path.
  def test_batch39_exception_adds_no_status_probes
    tasks = [task("CL-WLO-01"), task("CL-01"), task("BUG-01")]
    tasks << task("DEP-01", dependencies: ["CL-01"])
    preferred, preferred_inspector = build(tasks)
    ordinary_tasks = Marshal.load(Marshal.dump(tasks))
    ordinary_tasks.first["id"] = "CL-ZZZ-01"
    ordinary, ordinary_inspector = build(ordinary_tasks)
    [%w[status], %w[status --fam CL], %w[next], %w[next --json]].each do |command|
      output(preferred, command)
      output(ordinary, command)
      assert_equal ordinary_inspector.batches, preferred_inspector.batches
      assert_equal ordinary_inspector.authority_calls, preferred_inspector.authority_calls
    end
  end

  private

  # Returns synthetic validated-shape task records with recognizable titles.
  def family_tasks(distribution)
    distribution.flat_map { |family, count| (1..count).map { |number| task("#{family}-%02d" % number) } }
  end

  # Returns one task record; repository identity is independent of its family.
  def task(id, repository: id, dependencies: [])
    { "id" => id, "title" => "Title #{id}", "depends_on" => dependencies, "repositories" => repos(repository) }
  end

  # Returns one writable authority specification for the fake inspector.
  def repos(name) = { name => { "access" => "write" } }

  # Returns a complete prepared binding; callers optionally mark it in flight.
  def prepared_state(name)
    { "snapshot" => { name => { "remote_url" => "git@github.com:fixture/#{name}.git", "branch" => "main", "pushed_sha" => "a" * 40 } } }
  end

  # Returns a planner plus inspector with no write interfaces or real data paths.
  def build(tasks, states: {})
    inspector = Inspector.new
    coordinator = AgentCodingTool::Coordinator.new(task_store: TaskRegistry.new(tasks), state_store: States.new(states),
      repo_inspector: inspector, prompt_renderer: nil, prompt_root: nil, external_activity: NoExternalActivity.new)
    [coordinator, inspector]
  end

  # Returns a CLI wired only to the synthetic coordinator and captured streams.
  def client(coordinator, out: StringIO.new, err: StringIO.new)
    cli = AgentCodingTool::CLI.new(root: "/unused", data_root: "/unused", out:, err:)
    cli.instance_variable_set(:@coordinator, coordinator)
    cli
  end

  # Runs one inspection command and returns stdout, asserting success/no stderr.
  def output(coordinator, args, out: StringIO.new)
    err = StringIO.new
    assert_equal 0, client(coordinator, out:, err:).run(args.dup), err.string
    assert_empty err.string
    out.string
  end

  # Extracts READY headlines only, ignoring summaries and lifecycle diagnostics.
  def ready_ids(output)
    output.lines.filter_map { |line| line.gsub(AgentCodingTool::CLI::ANSI_SEQUENCE, "")[/\A([^:]+): READY/, 1] }
  end

  # Returns the effective status shape for direct comparator unit tests.
  def status_row(id, status = "READY")
    { "id" => id, "title" => "Title #{id}", "status" => status, "state" => {} }
  end
end
