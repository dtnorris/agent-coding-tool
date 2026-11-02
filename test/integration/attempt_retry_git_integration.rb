# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../retry_decision_support"
require "minitest/mock"
require "stringio"
require "pty"
require "timeout"
require_relative "../support/memory_git/broker"
require_relative "../support/child_processes"
require_relative "../support/memory_git/reset_fixtures"

# Public retry journeys use modeled Git and real finite fake-worker
# processes. Sandbox, boot identity and lsof are declared external test doubles;
# these tests make no claim of host macOS isolation or descendant containment.
class AttemptRecoveryTest < Minitest::Test
  include TestHelpers
  include RetryDecisionSupport

  # Adds only the offline read envelope emitted by TaskReset. No index/object
  # override is accepted; all other fields retain the shared world's validation.
  module RetryWorldEnvironment
    # Matches NativeCommandTransport's untimed Open3 stream encoding. Bytes and
    # termination facts remain unchanged; binary/grouped/timed streams stay binary.
    def call(argv, **fields)
      response = super
      return response if fields[:binmode] || fields[:pgroup] || fields[:timeout]
      AgentCodingTool::CommandResult.new(
        stdout: response.stdout.dup.force_encoding(Encoding.default_external),
        stderr: response.stderr.dup.force_encoding(Encoding.default_external),
        exitstatus: response.exitstatus, termsig: response.termsig)
    end

    # Accepts optional-lock suppression exactly as "0"; wrong values and unknown
    # keys still raise MemoryGit::Mismatch through the base envelope validator.
    def supported_environment?(environment)
      return super unless environment.is_a?(Hash) && environment.key?("GIT_OPTIONAL_LOCKS")
      environment["GIT_OPTIONAL_LOCKS"] == "0" && super(environment.reject { |key, _value| key == "GIT_OPTIONAL_LOCKS" })
    end
  end

  # Builds independent local authorities, private data and external executables.
  # Every ref, process and write belongs to this disposable fixture.
  def fixture(readers: 0, native_reset: false)
    Dir.mktmpdir("act16-retry-") do |directory|
      @authority_root = File.realpath(directory)
      @fixture = File.join(@authority_root, "fixture")
      Dir.mkdir(@fixture, 0o700)
      @data, @visible = %w[data worktrees].map { |name| File.join(@fixture, name) }
      FileUtils.mkdir_p(File.join(@data, "tasks"))
      with_memory_world(@authority_root) do |world|
        world.extend(RetryWorldEnvironment)
        @retry_world = world
        @retry_broker = nil
        @hard_reset_fixture = false
        @retry_checkouts = {}
        world.extend(MemoryGit::ResetFixtures::World) if native_reset
        seed = native_reset ? MemoryGit::ResetFixtures.seed : TestHelpers.git_seed
        @base = seed.head
        repos = (["writer"] + (1..readers).map { |number| "reader#{number}" }).to_h do |name|
          ordinary, remote = [name, "#{name}.git"].map { |part| File.join(@fixture, part) }
          checkout, = memory_repository(world, path: ordinary, remote: remote, template: seed)
          @retry_checkouts[ordinary] = checkout
          FileUtils.mkdir_p(File.join(ordinary, '.git', 'info'))
          exclude = File.join(ordinary, '.git', 'info', 'exclude')
          File.write(exclude, '')
          world.configure(checkout, 'core.excludesFile', exclude)
          [name, { "path" => ordinary, "access" => name == "writer" ? "write" : "read_only" }]
        end
        write_task(@data, id: "T", repositories: repos)
        File.write(File.join(@data, "config.yml"), YAML.dump("repo_root" => @fixture, "worktree_root" => @visible))
        @states = AgentCodingTool::StateStore.new(File.join(@data, "state"))
        File.write(File.join(@fixture, "lsof"), "#!/bin/sh\nexit 1\n")
        File.chmod(0o755, File.join(@fixture, "lsof"))
        fake_worker
        begin
          yield
        ensure
          @retry_broker&.close
          @retry_broker = nil
        end
      end
    end
  end

  # Normalizes legacy setup forms to the existing object/staging APIs only.
  # No product request is normalized; unsupported model capabilities still fail.
  def git(*args, directory:)
    if args == ['worktree', 'list', '--porcelain']
      return git('worktree', 'list', '--porcelain', '-z', directory: directory).tr("\0", "\n")
    elsif args.length == 4 && args.first(3) == ['commit', '--allow-empty', '-m']
      checkout = @retry_checkouts.values.flat_map { |item| item.repository.worktrees.values }.find { |item| item.path == directory }
      raise MemoryGit::Mismatch, 'missing empty-commit setup authority' unless checkout
      commit = @retry_world.build_commit(checkout, files: checkout.index, message: args.last)
      checkout.move_head!(commit.oid)
      return commit.oid
    elsif args == ['push', 'origin', 'main']
      args = ['push', 'origin', 'refs/heads/main:refs/heads/main']
    elsif args == ['restore', '--staged', 'file.txt']
      args = ['reset', '-q', '--', 'file.txt']
    elsif args.first(2) == ['commit', '-am']
      git('add', '-A', '--', '.', directory: directory)
      args = ['commit', '-m', *args.drop(2)]
    elsif args.first == 'add' && args[1] != '--' && !args[1].start_with?('-')
      args = ['add', '--', *args.drop(1)]
    end
    output, error, status = (@retry_broker || @retry_world).call(["git", *args], cwd: directory)
    raise "fixture git failed: #{error}" unless status.success?
    output.strip
  end

  # Simulates Codex's pinned public interface and exact probe byte contract.
  # Mode files permit invalid final/nonzero/sandbox-failure controls, no inference.
  def fake_worker
    path = File.join(@fixture, "codex")
    File.symlink(File.join(ChildProcesses::FIXTURES, 'retry_worker.rb'), path)

  end

  # Uses a cold public CLI process, with only host identity/lsof/sandbox external
  # boundaries faked. The real host PID disappears before the next CLI command.
  def cli(*args, fault: nil, legacy: false, child_start_fault: false, break_projection: false)
    environment = retry_environment.merge("ACT16_CREATION_FAULT" => fault,
      "ACT16_LEGACY" => legacy ? "1" : nil, "ACT16_CHILD_START_FAULT" => child_start_fault ? "1" : nil,
      "ACT18_BREAK_PROJECTION" => break_projection ? "1" : nil)
    output, error, status = ChildProcesses.capture('retry_cli', arguments: args,
      environment: environment, endpoint: retry_broker.endpoint, seconds: 15)
    [status.exitstatus, output, error]
  end

  # One finite 120s authority covers multi-command retry/reset cases, including
  # CI process-startup delays that can outlast 60s. The default 20s lease, 2s
  # request deadline and child deadlines stay unchanged; no renewal or retry.
  # This fixture lease is not an accepted whole-program runtime budget.
  def retry_broker
    @retry_broker ||= MemoryGit::Broker.new(world: @retry_world, directory: @authority_root, case_id: 'retry-public', lease: 120)
  end

  # Exact test-owned boundaries; public CLI argv and lifecycle stay production.
  def retry_environment
    { 'TMPDIR' => @authority_root, 'PATH' => "#{@fixture}:#{ENV.fetch('PATH')}", 'AGENT_CODING_TOOL_DATA_DIR' => @data,
      'ACT_RETRY_ROOT' => @fixture, 'ACT_RETRY_HARD_RESET' => @hard_reset_fixture ? '1' : nil }
  end

  # Requires a successful public command and returns output for contract checks.
  def succeeds(*args, **options)
    status, output, error = cli(*args, **options)
    assert_equal 0, status, "#{args.inspect}: #{error}"
    output
  end

  # Runs real recovery/launcher decisions with exact finite lsof observations.
  # Only boot identity and lsof results are injected; native Git, PID checks,
  # locks, validation and durable writes execute normally. Returns the block's
  # result; unexpected or unconsumed requests raise even during a refusal.
  def with_decision_liveness(checks)
    observations = if checks.zero?
                     []
                   else
                     reports.flat_map { |report| report.fetch("worktrees").fetch("entries") }.map do |entry|
                       recovery_observation(nil, "lsof", "-n", "-P", "+D", entry.fetch("path"), exit_code: 1)
                     end * checks
                   end
    replay = GitContract::Replay.new(observations)
    liveness = AgentCodingTool::RetryLiveness.new(capture: replay)
    AgentCodingTool::RetryLiveness.stub(:host_identity, { "fixture_boot" => "deterministic external identity" }) do
      AgentCodingTool::RetryLiveness.stub(:new, liveness) { yield }
    end
  ensure
    assert replay.verify! if replay
  end

  # Runs repeated recovery commands through the real public parser in-process.
  # Returns the CLI's integer result and raw streams; unexpected external
  # requests raise. Full launches and cold restart journeys remain native.
  def decision_cli(*args, liveness_checks: 0)
    raise ArgumentError, "not a recovery decision command" unless %w[record worktrees close-attempt prepare].include?(args.first)

    out, err = StringIO.new, StringIO.new
    with_decision_liveness(liveness_checks) do
      result = AgentCodingTool::CLI.run(args, root: Dir.pwd, data_root: @data, out: out, err: err)
      [result, out.string, err.string]
    end
  end

  # Requires success from a real in-process decision command and returns stdout.
  # CLI refusals become assertion failures; strict observation errors propagate.
  def decision_succeeds(*args, **options)
    status, output, error = decision_cli(*args, **options)
    assert_equal 0, status, "#{args.inspect}: #{error}"
    output
  end

  # Returns reports sorted by independently recorded attempt number.
  def reports
    Dir.glob("#{@data}-runs/T/*/handoff.json").map { |path| JSON.parse(File.binread(path)) }.sort_by { |report| report.fetch("attempt") }
  end

  # Captures bytes for preservation and read-only assertions, including Git
  # administration, refs, checkpoints, private logs, prompts and lifecycle.
  def bytes(root = @fixture)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) && !File.symlink?(path) }
       .to_h { |path| [path, File.binread(path)] }
  end

  # Requires truthful external and canonical status in the same public output.
  # Used unchanged for the projection-removal negative control.
  def assert_external_stale_projection(output)
    ["T: STALE", "pushed branch changed: writer", "EXTERNAL WORK REPORTED",
     "unauthorized", "liveness unknown", "isolation unverified"].each do |text|
      assert_includes output, text
    end
  end

  # Starts a finite external fake independently of ACT. The pipe permits release
  # after inspection; the five-second select bound survives parent failure.
  def independent_worker
    reader, writer = IO.pipe
    approval = ChildProcesses.permit('retry_probe')
    process = File.open(File::NULL, 'w') do |null|
      NoGitExecution.with_permit(approval) do
        Process.spawn(approval.environment, *approval.argv, in: reader, out: null, err: null)
      end
    end
    reader.close
    [process, writer]
  end

  # Exercises reporting through cold public CLI processes against a stale task.
  # The finite worker is launched independently; its exit cannot close a report.
  # A projection-breaking preload is the negative control for this same journey.
  def test_external_activity_public_journey_preserves_stale_lifecycle
    fixture do
      succeeds("prepare", "T")
      git("commit", "--allow-empty", "-m", "advance", directory: File.join(@fixture, "writer"))
      git("push", "origin", "main", directory: File.join(@fixture, "writer"))
      before = bytes
      worker, release_worker = independent_worker
      begin
        report = JSON.parse(succeeds("external", "report", "T", "--reporter", "operator",
                                    "--kind", "fake-codex", "--identifier", "fixture-worker", "--scope-complete"))
        observation = report.fetch("active").fetch("observation_id")
        namespace_metadata = File.join("#{@data}-runs", AgentCodingTool::ExternalActivity::NAMESPACE, ".DS_Store")
        File.binwrite(namespace_metadata, "Finder\x00\xff".b)
        detail = succeeds("status", "T", "--full")
        dashboard = succeeds("status", "--full")
        [detail, dashboard].each { |output| assert_external_stale_projection(output) }
        broken = succeeds("status", "T", "--full", break_projection: true)
        assert_raises(Minitest::Assertion) { assert_external_stale_projection(broken) }
        document = JSON.parse(succeeds("next", "--json"))
        fact = document.fetch("facts").fetch("tasks").find { |row| row["id"] == "T" }
        assert_equal "STALE", fact.fetch("status")
        assert_equal observation, fact.fetch("external_activity").fetch("observation_id")
        release_worker.close
        Process.wait(worker)
        worker = nil
        assert_equal observation, JSON.parse(succeeds("external", "show", "T")).fetch("active").fetch("observation_id")
        assert_equal before, before.keys.to_h { |path| [path, File.binread(path)] }
        closed = JSON.parse(succeeds("external", "end", "T", observation, "--disposition", "ended"))
        assert_nil closed.fetch("active")
        assert_equal observation, closed.fetch("closed").last.fetch("observation_id")
        assert_equal "Finder\x00\xff".b, File.binread(namespace_metadata)
        assert_includes succeeds("status", "T"), "T: STALE"
        assert_equal before, before.keys.to_h { |path| [path, File.binread(path)] }
        # Existing result authority is exercised only on an independently
        # eligible control, never by laundering the stale incident preparation.
        write_task(@data, id: "REVIEW", repositories: { "writer" => { "access" => "write", "path" => File.join(@fixture, "writer") } })
        succeeds("prepare", "REVIEW")
        control = JSON.parse(succeeds("external", "report", "REVIEW", "--reporter", "reviewer", "--kind", "fake", "--scope-complete"))
        control_id = control.fetch("active").fetch("observation_id")
        succeeds("external", "end", "REVIEW", control_id, "--disposition", "ended")
        assert_includes succeeds("status", "REVIEW"), "REVIEW: PREPARED"
        succeeds("start", "REVIEW")
        succeeds("received", "REVIEW", "--artifact", "separately-reviewed-control.patch", "--test", "fixture-review=pass")
        assert_includes succeeds("status", "REVIEW"), "REVIEW: CANDIDATE"
        succeeds("finish", "REVIEW", "--summary", "Separately authorized fixture acceptance")
        assert_includes succeeds("status", "REVIEW"), "REVIEW: COMPLETE"
      ensure
        release_worker.close unless release_worker.closed?
        Process.wait(worker) if worker
      end
    end
  end

  # Proves the public retry handoff with one native resource per access role.
  # The outcome matrix belongs to RetryRecoveryContract; this journey retains
  # cold CLI, actual fresh worktrees, old-path protection and metadata effects.
  def test_public_exit_zero_closeout_fresh_retry_preserves_both_attempts
    fixture(readers: 1) do
      FileUtils.mkdir_p(File.join("#{@data}-runs", "T"), mode: 0o700)
      File.binwrite(File.join("#{@data}-runs", "T", ".DS_Store"), "before launch")
      succeeds("launch", "T", "--codex", "--reasoning", "high")
      first = reports.first
      assert_equal [1, "exited", 0, true, "fresh_at_exit"], first.values_at("attempt", "status", "exit_status", "final_valid", "writable_freshness")
      assert_equal %w[write read_only], first.fetch("worktrees").fetch("entries").map { |entry| entry.fetch("access") }
      first_fixture = first.fetch("fixture").fetch("path")
      run_dir = File.dirname(first.fetch("worktrees_path"))
      metadata = [run_dir, *first.fetch("worktrees").fetch("entries").flat_map { |entry| [entry.fetch("path"), File.dirname(entry.fetch("path"))] }].uniq.map do |directory|
        path = File.join(directory, ".DS_Store")
        File.binwrite(path, "Finder\x00\xff".b)
        path
      end
      File.binwrite(File.join(first_fixture, "retained.bin"), "\x00\xfffixture".b)
      old = reports.each_with_object({}) { |report, retained| retained.merge!(bytes(File.dirname(report.fetch("worktrees_path")))) }
      old.reject! { |path, _bytes| File.basename(path) == ".DS_Store" }
      original_state = first.fetch("execution_state")
      succeeds("record", "T", "blocked", "--summary", "No candidate.", "--next", "Explicit closeout and retry.")
      before = bytes
      assert_equal 2, cli("prepare", "T", "--retry").first
      assert_equal before, bytes
      succeeds("worktrees", "T")
      succeeds("close-attempt", "T", "--dry-run")
      assert_equal before, bytes
      succeeds("close-attempt", "T")
      closeout = JSON.parse(File.binread(File.join(run_dir, "closeout.json")))
      refute closeout.fetch("evidence").key?(".DS_Store")
      metadata.each { |path| assert_equal "Finder\x00\xff".b, File.binread(path) }
      metadata.each { |path| File.binwrite(path, "changed after closeout") }
      File.unlink(metadata.first)
      closed = bytes
      succeeds("close-attempt", "T")
      assert_equal closed, bytes
      succeeds("prepare", "T", "--retry")
      refute_equal first.fetch("prepared_at"), @states.load("T").fetch("prepared_at")
      succeeds("launch", "T", "--codex", "--reasoning", "high")
      second = reports.fetch(1)
      second_fixture = second.fetch("fixture").fetch("path")
      refute_equal first_fixture, second_fixture
      assert_equal "\x00\xfffixture".b, File.binread(File.join(first_fixture, "retained.bin"))
      assert_includes second.fetch("argv"), "sandbox_workspace_write.writable_roots=#{JSON.generate([second_fixture])}"
      refute_includes second.fetch("argv"), "sandbox_workspace_write.writable_roots=#{JSON.generate([first_fixture])}"
      assert_equal 2, second.fetch("attempt")
      refute_equal first.fetch("invocation_id"), second.fetch("invocation_id")
      assert_equal first.fetch("execution_state"), original_state
      first.fetch("worktrees").fetch("entries").zip(second.fetch("worktrees").fetch("entries")).each do |earlier, later|
        refute_equal earlier.fetch("path"), later.fetch("path")
        assert File.directory?(earlier.fetch("path"))
        assert_equal @base, git("rev-parse", "HEAD", directory: earlier.fetch("path"))
        assert_equal @base, git("rev-parse", "HEAD", directory: later.fetch("path"))
        expected_branch = later.fetch("access") == "write" ? "act/T/attempt-2" : ""
        assert_equal expected_branch, git("branch", "--show-current", directory: later.fetch("path"))
      end
      assert_operator second.fetch("sandbox_probe").fetch("protected_paths"), :>=, first.fetch("worktrees").fetch("entries").length
      assert_equal 2, JSON.parse(succeeds("worktrees", "T")).fetch("attempts").length
      assert_equal old, old.keys.to_h { |path| [path, File.binread(path)] }
      assert_nil @states.load("T")["result"]
      refute @states.load("T")["checkpoint"]
      assert_empty Dir.glob("#{@data}-runs/T/*/delivery.json")
      assert_equal 2, cli("cleanup", "T").first
      assert_equal [1, 2], reports.map { |report| report.fetch("attempt") }
    end
  end

  # Proves exact creating-marker/native-add boundaries remain distinguishable,
  # preserve their original markers and allow non-destructive closeout/retry.
  def test_partial_creation_before_and_after_native_add_is_preserved
    %w[before after].each do |fault|
      fixture do
        assert_equal 2, cli("launch", "T", "--codex", fault: fault).first
        first = reports.fetch(0)
        inventory_bytes = File.binread(first.fetch("worktrees_path"))
        inventory = JSON.parse(inventory_bytes)
        assert_equal "creating", inventory.fetch("entries").first.fetch("state")
        assert_equal(fault == "after", File.directory?(inventory.fetch("entries").first.fetch("path")))
        row = JSON.parse(succeeds("worktrees", "T")).fetch("attempts").first
        assert_equal "partial_creation", row.fetch("classification")
        succeeds("record", "T", "failed", "--summary", "Injected fixture creation interruption.")
        succeeds("close-attempt", "T")
        succeeds("prepare", "T", "--retry")
        succeeds("launch", "T", "--codex")
        assert_equal inventory_bytes, File.binread(first.fetch("worktrees_path"))
        assert_equal 2, reports.length
      end
    end
  end

  # Native launches change both membership and access between attempts; repeated
  # recovery decisions use the public parser in-process with exact lsof results.
  # Native Git ownership remains real; fake worker/sandbox/boot/lsof boundaries
  # are the same as this suite's other journeys. No inference or host isolation
  # acceptance is claimed. Old evidence/resources remain protected and unchanged.
  def test_retry_uses_original_contract_after_repository_and_access_changes
    fixture(readers: 2) do
      succeeds("launch", "T", "--codex")
      first = reports.first
      decision_succeeds("record", "T", "blocked")
      task = YAML.safe_load_file(File.join(@data, "tasks", "T.yml"))
      repositories = task.fetch("repositories")
      repositories.fetch("writer")["access"] = "read_only"
      repositories.fetch("reader1")["access"] = "write"
      repositories["added"] = repositories.delete("reader2").merge("access" => "write")
      File.write(File.join(@data, "tasks", "T.yml"), YAML.dump(task))
      old = bytes(File.dirname(first.fetch("worktrees_path")))
      decision_succeeds("worktrees", "T")
      status, _output, error = decision_cli("prepare", "T", "--retry")
      assert_equal 2, status
      assert_includes error, "explicit close-attempt required"
      decision_succeeds("close-attempt", "T", "--dry-run", liveness_checks: 1)
      decision_succeeds("close-attempt", "T", liveness_checks: 3)
      decision_succeeds("prepare", "T", "--retry", liveness_checks: 1)
      succeeds("launch", "T", "--codex")
      second = reports.last
      assert_equal 2, second.fetch("attempt")
      assert_equal %w[added reader1 writer], second.fetch("preparation").keys.sort
      assert_equal %w[added reader1], second.fetch("writable_repositories").sort
      entries = second.fetch("worktrees").fetch("entries")
      assert_equal "read_only", entries.find { |entry| entry["name"] == "writer" }.fetch("access")
      assert_equal %w[added reader1], entries.select { |entry| entry["access"] == "write" }.map { |entry| entry.fetch("name") }.sort
      assert_equal 2, JSON.parse(decision_succeeds("worktrees", "T")).fetch("attempts").length
      assert_operator second.fetch("sandbox_probe").fetch("protected_paths"), :>=, first.fetch("worktrees").fetch("entries").length
      assert_equal old, old.keys.to_h { |path| [path, File.binread(path)] }
      first.fetch("worktrees").fetch("entries").each do |entry|
        assert_equal @base, git("rev-parse", "HEAD", directory: entry.fetch("path"))
        assert_empty git("--no-optional-locks", "status", "--porcelain", "--untracked-files=all", "--ignored", directory: entry.fetch("path"))
      end
    end
  end

  # Deleting ownership after a native add never becomes a harmless preflight.
  def test_missing_ownership_after_native_mutation_refuses_without_changes
    fixture do
      assert_equal 2, cli("launch", "T", "--codex", fault: "after").first
      first = reports.first
      File.unlink(first.fetch("worktrees_path"))
      succeeds("record", "T", "failed")
      before = bytes
      status, output, = cli("worktrees", "T")
      assert_equal 2, status
      assert_includes output, "unaccounted"
      assert_equal 2, cli("close-attempt", "T").first
      assert_equal 2, cli("prepare", "T", "--retry").first
      assert_equal before, bytes
    end
  end

  # Retains IG-19E's exact eight-worktree ordering as historical v1 evidence.
  # Inspection separates valid old ownership from pre-creation failure, without
  # attributing the old inventory to attempt 2. Missing legacy host identity
  # remains an explicit closeout blocker, never an assertion of termination.
  def test_legacy_fixed_path_mixed_history_is_accurately_classified
    fixture(readers: 7) do
      succeeds("launch", "T", "--codex", legacy: true)
      first = reports.first
      old = bytes(File.dirname(first.fetch("worktrees_path")))
      succeeds("record", "T", "blocked", legacy: true)
      succeeds("prepare", "T", "--retry", legacy: true)
      status, _output, error = cli("launch", "T", "--codex", legacy: true)
      assert_equal 2, status
      assert_includes error, "occupied path"
      second = reports.fetch(1)
      assert_equal ["preflight_failed", nil, nil], second.values_at("status", "workspace", "child_pid")
      refute File.exist?(second.fetch("worktrees_path"))
      git("commit", "--allow-empty", "-m", "advance writer", directory: File.join(@fixture, "writer"))
      git("push", "origin", "main", directory: File.join(@fixture, "writer"))
      # Original recovery errors must remain before, during and after observing
      # an independently started worker; absent legacy boot evidence stays absent.
      before_retry = cli("prepare", "T", "--retry")
      before_launch = cli("launch", "T", "--codex")
      assert_equal 2, before_retry.first
      assert_equal 2, before_launch.first
      original = bytes
      worker, release_worker = independent_worker
      begin
        observation = JSON.parse(succeeds("external", "report", "T", "--reporter", "operator", "--kind", "fake-codex", "--scope-complete"))
        id = observation.fetch("active").fetch("observation_id")
        assert_external_stale_projection(succeeds("status", "T", "--full"))
        assert_external_stale_projection(succeeds("status", "--full"))
        fact = JSON.parse(succeeds("next", "--json")).fetch("facts").fetch("tasks").first
        assert_equal ["STALE", id], [fact.fetch("status"), fact.fetch("external_activity").fetch("observation_id")]
        assert_equal before_retry, cli("prepare", "T", "--retry")
        assert_equal before_launch, cli("launch", "T", "--codex")
        release_worker.close
        Process.wait(worker)
        worker = nil
        assert_equal id, JSON.parse(succeeds("external", "show", "T")).fetch("active").fetch("observation_id")
        succeeds("external", "end", "T", id, "--disposition", "lost-contact")
        assert_equal before_retry, cli("prepare", "T", "--retry")
        assert_equal before_launch, cli("launch", "T", "--codex")
        assert_equal original, original.keys.to_h { |path| [path, File.binread(path)] }
      ensure
        release_worker.close unless release_worker.closed?
        Process.wait(worker) if worker
      end
      before = bytes
      rows = JSON.parse(succeeds("worktrees", "T")).fetch("attempts").sort_by { |row| row.fetch("attempt") }
      assert_equal "owned", rows.fetch(0).fetch("classification")
      assert_equal 8, rows.fetch(0).fetch("entries").length
      assert_equal "verified_precreation_failure", rows.fetch(1).fetch("classification")
      refute rows.fetch(1).key?("entries")
      assert_equal before, bytes
      succeeds("record", "T", "failed")
      before = bytes
      status, _output, error = cli("close-attempt", "T")
      assert_equal 2, status
      assert_includes error, "unknown host"
      assert_equal before, bytes
      assert_equal old, old.keys.to_h { |path| [path, File.binread(path)] }

      # A single inspection may share a complete prior-inventory proof, but
      # every path still needs exactly one matching original authority. Later
      # inspections must observe newly damaged native administration afresh.
      recovery = AgentCodingTool::AttemptRecovery.new(data_root: @data)
      second_path = File.join(File.dirname(second.fetch("worktrees_path")), "handoff.json")
      second_bytes = File.binread(second_path)
      changed = JSON.parse(second_bytes)
      changed.fetch("preparation")["reader1"] = changed.fetch("preparation").fetch("writer").dup
      begin
        File.write(second_path, JSON.generate(changed))
        damaged = bytes
        row = recovery.inspect("T").find { |item| item["run_dir"] == File.dirname(second_path) }
        assert_includes row.fetch("blockers").join, "unaccounted worktree"
        assert_equal damaged, bytes
      ensure
        File.binwrite(second_path, second_bytes)
      end

      original_directory = File.dirname(first.fetch("worktrees_path"))
      duplicate_directory = File.join(File.dirname(original_directory), "duplicate-ownership")
      begin
        FileUtils.cp_r(original_directory, duplicate_directory)
        duplicate = JSON.parse(File.binread(File.join(duplicate_directory, "handoff.json")))
        %w[worktrees_path jsonl_path stderr_path final_path prompt_path stdin_path session_transcript_path].each do |key|
          next unless duplicate[key]&.start_with?(original_directory + "/")
          duplicate[key] = File.join(duplicate_directory, File.basename(duplicate.fetch(key)))
        end
        duplicate.fetch("artifacts").each do |artifact|
          artifact["path"] = File.join(duplicate_directory, File.basename(artifact.fetch("path")))
        end
        File.write(File.join(duplicate_directory, "handoff.json"), JSON.generate(duplicate))
        duplicated = bytes
        rows = recovery.inspect("T")
        assert_equal 2, rows.count { |row| row["classification"] == "owned" }
        assert_includes rows.find { |row| row["run_dir"] == File.dirname(second_path) }.fetch("blockers").join, "unaccounted worktree"
        assert_equal duplicated, bytes
      ensure
        FileUtils.remove_entry(duplicate_directory) if File.directory?(duplicate_directory)
      end

      workspace = first.fetch("worktrees").fetch("entries").first.fetch("path")
      admin = File.binread(File.join(workspace, ".git")).delete_prefix("gitdir: ").strip
      pointer = File.join(admin, "gitdir")
      original_pointer = File.binread(pointer)
      begin
        File.binwrite(pointer, "foreign\n")
        damaged = bytes
        assert_includes recovery.inspect("T").find { |row| row["run_dir"] == File.dirname(second_path) }.fetch("blockers").join,
                        "native Git backpointer changed"
        assert_equal damaged, bytes
      ensure
        File.binwrite(pointer, original_pointer)
      end
      assert_equal %w[owned verified_precreation_failure], recovery.inspect("T").map { |row| row.fetch("classification") }
      assert_equal before, bytes
    end
  end

  # Dirty tracked/staged/untracked/ignored resources never qualify, even with
  # preserved evidence. Each refusal retains code, Git state and run bytes.
  def test_dirty_resources_refuse_before_any_closeout_or_retry_mutation
    fixture do
      succeeds("launch", "T", "--codex")
      succeeds("record", "T", "blocked")
      workspace = reports.first.fetch("workspace")
      ["tracked", "staged", "untracked", "ignored"].each do |kind|
        exclude = File.join(@fixture, "writer", ".git", "info", "exclude")
        original_exclude = File.binread(exclude)
        File.write(exclude, original_exclude + "\nignored\n") if kind == "ignored"
        path = File.join(workspace, { "untracked" => "extra", "ignored" => "ignored" }.fetch(kind, "file.txt"))
        File.write(path, "operator data\n")
        git("add", "file.txt", directory: workspace) if kind == "staged"
        before = bytes
        assert_equal 2, cli("close-attempt", "T").first
        assert_equal before, bytes
        # Restore only fixture-authored bytes, never through product recovery.
        git("restore", "--staged", "file.txt", directory: workspace) if kind == "staged"
        %w[untracked ignored].include?(kind) ? File.unlink(path) : File.write(path, "base\n")
        File.binwrite(exclude, original_exclude) if kind == "ignored"
      end
      succeeds("close-attempt", "T")
      File.write(File.join(workspace, "late"), "late operator change")
      before = bytes
      assert_equal 2, cli("prepare", "T", "--retry").first
      assert_equal before, bytes
    end
  end

  # Actual nonzero and invalid-final execution facts each retain a cold native
  # launch. Their closeout/fresh-preparation decisions need no second worker:
  # create/inspect the new native inventory from the real prepared state instead.
  # The public exit-zero and historical journeys own the complete second launch,
  # sandbox protection, prompt consumption and cold reconstruction handoffs.
  def test_unsuccessful_execution_statuses_can_close_and_retry
    %w[nonzero invalid].each do |mode|
      fixture do
        File.write(File.join(@fixture, "mode"), mode)
        assert_equal(mode == "nonzero" ? 7 : 0, cli("launch", "T", "--codex").first)
        first = reports.first
        assert_equal(mode == "invalid" ? "invalid_final" : "exited", first.fetch("status"))
        assert_equal(mode == "nonzero" ? 7 : 0, first.fetch("exit_status"))
        assert_equal(mode != "invalid", first.fetch("final_valid"))
        old = bytes(File.dirname(first.fetch("worktrees_path"))).merge(bytes(first.fetch("workspace")))
                   .to_h { |path, content| [path, [content, File.stat(path).mode & 0o777]] }
        decision_succeeds("record", "T", "needs_judgment")
        before = bytes
        status, _output, error = decision_cli("prepare", "T", "--retry")
        assert_equal 2, status
        assert_includes error, "explicit close-attempt required"
        assert_equal before, bytes
        decision_succeeds("close-attempt", "T", liveness_checks: 3)
        decision_succeeds("prepare", "T", "--retry", liveness_checks: 1)
        prepared = @states.load("T")
        refute_equal first.fetch("prepared_at"), prepared.fetch("prepared_at")
        assert_equal first.fetch("preparation"), prepared.fetch("snapshot")
        assert_nil prepared["result"]
        assert_nil prepared["started_at"]
        coordinator = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: @data, out: StringIO.new, err: StringIO.new).send(:coordinator)
        assert_equal File.binread(prepared.fetch("prompt_path")), coordinator.launch_prompt("T").b
        # Exercise the launcher's real terminal-status/reused-preparation gate
        # for each produced failure, without repeating preflight and execution.
        launcher = AgentCodingTool::Launcher.new(coordinator: coordinator, data_root: @data,
          source_root: Dir.pwd, out: StringIO.new, err: StringIO.new)
        with_decision_liveness(1) do
          assert_equal [first.fetch("invocation_id")], launcher.send(:prior_runs!, "T", prepared).map { |report| report.fetch("invocation_id") }
        end
        task = AgentCodingTool::TaskStore.new(File.join(@data, "tasks")).load("T")
        manager = AgentCodingTool::WorktreeManager.new(root: @visible,
          record_path: File.join(@fixture, "retry-inventory.json"), attempt_paths: true, invocation_id: "native-retry-handoff")
        assert_equal ["verified"], manager.creation_readiness!(task: task, snapshot: prepared.fetch("snapshot")).map { |row| row.fetch("status") }
        inventory = manager.create(task_id: "T", attempt: 2, task: task, snapshot: prepared.fetch("snapshot"))
        assert_equal inventory, manager.inspect!
        entry = inventory.fetch("entries").fetch(0)
        refute_equal first.fetch("workspace"), entry.fetch("path")
        assert_equal @base, git("rev-parse", "HEAD", directory: entry.fetch("path"))
        assert_equal "act/T/attempt-2", git("branch", "--show-current", directory: entry.fetch("path"))
        assert_equal old, old.keys.to_h { |path| [path, [File.binread(path), File.stat(path).mode & 0o777]] }
      end
    end
  end

  # A reserved spawn failure has no child but retains its execution/preparation
  # identity. Explicit closeout and fresh prepare are still separate handoffs.
  def test_child_start_failure_is_preserved_and_can_retry
    fixture do
      code, output, error = cli("launch", "T", "--codex", child_start_fault: true)
      assert_equal 127, code, "#{output}\n#{error}"
      first = reports.first
      assert_equal "child_start_failed", first.fetch("status")
      assert_retry_failure_report(first)
      refute first["child_pid"]
      assert @states.load("T")["started_at"]
      old = bytes(File.dirname(first.fetch("worktrees_path")))
      succeeds("record", "T", "failed")
      succeeds("close-attempt", "T")
      succeeds("prepare", "T", "--retry")
      succeeds("launch", "T", "--codex")
      assert_equal old, old.keys.to_h { |path| [path, File.binread(path)] }
    end
  end

  # Injects stale preparation only as a negative fixture, after valid closeout.
  # Relaunch must refuse without creating a run, branch, worktree or state write.
  def test_already_attempted_preparation_cannot_be_reused
    fixture do
      succeeds("launch", "T", "--codex")
      first = reports.first
      succeeds("record", "T", "blocked")
      succeeds("close-attempt", "T")
      @states.write("T", first.fetch("preparation_state"))
      before = bytes
      status, _output, error = cli("launch", "T", "--codex")
      assert_equal 2, status
      assert_includes error, "preparation already attempted"
      assert_equal before, bytes
      assert_equal 1, reports.length
    end
  end

  # Uses deterministic seams for competing reservation and crash publication,
  # with real inventories. No resources or lifecycle state are ever removed.
  def test_closeout_lock_race_and_cold_repeat_after_publication_interruption
    fixture do
      succeeds("launch", "T", "--codex")
      succeeds("record", "T", "failed")
      recovery = AgentCodingTool::AttemptRecovery.new(data_root: @data, liveness: Class.new { def check(*) = :clear }.new)
      lock_path = "#{@data}-runs/launch.lock"
      File.open(lock_path, "r+") do |lock|
        lock.flock(File::LOCK_EX)
        before = bytes
        assert_raises(AgentCodingTool::InvalidState) { recovery.close("T") }
        assert_equal before, bytes
      end
      before = bytes
      before_write = AgentCodingTool::AttemptRecovery.new(data_root: @data, liveness: Class.new { def check(*) = :clear }.new,
        before_write: ->(*) { raise "injected before closeout publication" })
      assert_raises(RuntimeError) { before_write.close("T") }
      assert_equal before, bytes
      interrupted = AgentCodingTool::AttemptRecovery.new(data_root: @data, liveness: Class.new { def check(*) = :clear }.new,
        after_write: ->(*) { raise "injected after closeout publication" })
      assert_raises(RuntimeError) { interrupted.close("T") }
      assert File.file?(File.join(File.dirname(reports.first.fetch("worktrees_path")), "closeout.json"))
      succeeds("close-attempt", "T")
      succeeds("prepare", "T", "--retry")
      succeeds("launch", "T", "--codex")
    end
  end

  # A failed evidence rename retains temporary bytes and refuses a cold repeat
  # with an exact blocker. It never declares partial closeout successful.
  def test_interrupted_evidence_publication_remains_precisely_blocked
    fixture do
      succeeds("launch", "T", "--codex")
      succeeds("record", "T", "failed")
      recovery = AgentCodingTool::AttemptRecovery.new(data_root: @data, liveness: Class.new { def check(*) = :clear }.new)
      File.stub(:rename, ->(*) { raise IOError, "injected rename failure" }) do
        assert_raises(IOError) { recovery.close("T") }
      end
      directory = File.dirname(reports.first.fetch("worktrees_path"))
      assert File.file?(File.join(directory, "closeout.json.pending"))
      refute File.exist?(File.join(directory, "closeout.json"))
      before = bytes
      status, _output, error = cli("close-attempt", "T", "--dry-run")
      assert_equal 2, status
      assert_includes error, "interrupted evidence publication"
      assert_equal before, bytes
    end
  end

  # One cold public CLI journey binds explicit preparation, actual worker stdin,
  # checkpoint and historical reconstruction. A fixture-only corruption flag
  # falsifies the same byte assertion required by test:all. The fixture restores
  # only its own code before retry; product closeout never discards workspace data.
  def test_historical_checkpoint_uses_original_preparation_after_retry
    fixture do
      succeeds("prepare", "T")
      prepared = @states.load("T")
      prompt = File.binread(prepared.fetch("prompt_path"))
      refute_empty prompt
      File.write(File.join(@fixture, "tst20-capture-prompt"), ENV["ACT_TST20_BREAK_PROMPT"] == "1" ? "corrupt" : "faithful")
      succeeds("launch", "T", "--codex")
      first = reports.first
      assert_equal ["T", 1, "exited", 0], first.values_at("task_id", "attempt", "status", "exit_status")
      assert_equal prepared, first.fetch("preparation_state")
      assert_equal prompt, File.binread(first.fetch("prompt_path"))
      assert_equal Digest::SHA256.hexdigest(prompt), first.fetch("prompt_sha256")
      assert_equal prompt.bytesize, first.fetch("prompt_bytes")
      worker = JSON.parse(File.binread(File.join(@fixture, "tst20-worker.json")))
      assert_equal first.values_at("child_pid", "workspace"), worker.values_at("pid", "workspace")
      assert_equal @base, git("rev-parse", "HEAD", directory: worker.fetch("workspace"))
      assert_equal "act/T/attempt-1", git("branch", "--show-current", directory: worker.fetch("workspace"))
      authority = prepared.fetch("snapshot").fetch("writer").slice("remote_url", "branch", "pushed_sha")
      assert_equal authority, first.fetch("writable_authority")
      assert_equal authority.fetch("remote_url"), git("remote", "get-url", "origin", directory: worker.fetch("workspace"))
      stdin = File.binread(first.fetch("stdin_path"))
      consumed = File.binread(File.join(@fixture, "tst20-consumed-stdin"))
      exact_worker_prompt = lambda do |actual|
        message = "TST20_EXACT_WORKER_PROMPT #{self.class}##{name}"
        assert_equal prompt, actual.byteslice(0, prompt.bytesize), message
        assert_equal stdin, actual, message
      end
      exact_worker_prompt.call(consumed)
      assert_raises(Minitest::Assertion) { exact_worker_prompt.call(consumed + "\0") }
      envelope = consumed.byteslice(prompt.bytesize..)
      assert envelope.start_with?("\n\n--- ACT LOCAL CLI EXECUTION ENVELOPE ---\n")
      assert envelope.end_with?("--- END ACT LOCAL CLI EXECUTION ENVELOPE ---\n")
      assert_includes envelope, "Writable worktrees: #{JSON.generate('writer' => worker.fetch('workspace'))}."
      assert_includes envelope, "Host verified remote_url/branch using git ls-remote before launch: #{JSON.generate('writer' => authority)}."
      file = File.join(first.fetch("workspace"), "file.txt")
      File.write(file, "preserved implementation\n")
      checkpoint = JSON.parse(succeeds("checkpoint", "record", "T", "--workspace", first.fetch("workspace")))
      original_attempt = Digest::SHA256.hexdigest(JSON.generate(first.fetch("execution_state").values_at("prepared_at", "started_at", "snapshot")))[0, 32]
      assert_equal ["T", original_attempt, "writer", first.fetch("invocation_id"), authority],
                   checkpoint.values_at("task_id", "attempt", "repository", "launch_invocation", "authority")
      patch_bytes = File.binread(checkpoint.fetch("path"))
      assert_equal patch_bytes.bytesize, checkpoint.fetch("bytes")
      assert_equal Digest::SHA256.hexdigest(patch_bytes), checkpoint.fetch("sha256")
      assert_equal checkpoint.fetch("sha256"), checkpoint.fetch("implementation_sha256")
      checkpoint_bytes = bytes(File.dirname(checkpoint.fetch("path")))
      verified = JSON.parse(succeeds("checkpoint", "verify", "T", "--workspace", worker.fetch("workspace")))
      assert_equal ["verified", true], verified.values_at("status", "workspace_checked")
      assert_equal checkpoint.reject { |key, _| key == "path" }, verified.fetch("record")
      run_bytes = bytes(File.dirname(first.fetch("worktrees_path")))
      File.write(file, "base\n")
      succeeds("record", "T", "failed")
      checkpoint_state = @states.load("T")
      stale_state = Marshal.load(Marshal.dump(checkpoint_state))
      stale_state.fetch("checkpoint")["status"] = "stale"
      @states.write("T", stale_state)
      before = bytes
      assert_equal 2, cli("close-attempt", "T").first
      assert_equal before, bytes
      @states.write("T", checkpoint_state)
      succeeds("close-attempt", "T")
      closeout = JSON.parse(File.binread(File.join(File.dirname(first.fetch("worktrees_path")), "closeout.json")))
      assert_equal first.values_at("task_id", "attempt", "invocation_id"), closeout.values_at("task_id", "attempt", "invocation_id")
      assert_equal prepared.fetch("snapshot"), closeout.fetch("state").fetch("snapshot")
      assert_equal checkpoint_state.fetch("checkpoint"), closeout.fetch("state").fetch("checkpoint")
      assert_equal run_bytes.to_h { |path, content| [File.basename(path), Digest::SHA256.hexdigest(content)] }, closeout.fetch("evidence")
      succeeds("prepare", "T", "--retry")
      refute_equal prepared.fetch("prepared_at"), @states.load("T").fetch("prepared_at")
      refute @states.load("T")["checkpoint"]
      File.unlink(File.join(@fixture, "tst20-capture-prompt"))
      succeeds("launch", "T", "--codex")
      second = reports.last
      assert_equal 2, second.fetch("attempt")
      refute_equal first.fetch("invocation_id"), second.fetch("invocation_id")
      refute_equal first.fetch("workspace"), second.fetch("workspace")
      before = bytes
      result = JSON.parse(succeeds("checkpoint", "verify", "T", "--attempt", "1"))
      assert_equal "verified", result.fetch("status")
      assert_equal verified.fetch("record"), result.fetch("record")
      refute result.fetch("workspace_checked")
      assert_equal before, bytes
      destination = File.join(@fixture, "reconstructed")
      recovered = JSON.parse(succeeds("checkpoint", "recover", "T", "--attempt", "1", "--destination", destination, "--confirm-disconnected"))
      assert_equal ["T", original_attempt, "reconstructed", destination], recovered.values_at("task_id", "attempt", "status", "path")
      assert_equal authority.fetch("pushed_sha"), git("rev-parse", "HEAD", directory: destination)
      assert_equal "preserved implementation\n", File.binread(File.join(destination, "file.txt"))
      assert_equal patch_bytes, File.binread(checkpoint.fetch("path"))
      assert_equal checkpoint_bytes, checkpoint_bytes.keys.to_h { |path| [path, File.binread(path)] }
      assert_equal run_bytes, run_bytes.keys.to_h { |path| [path, File.binread(path)] }
      assert_equal prompt, File.binread(prepared.fetch("prompt_path"))
      assert_equal consumed, File.binread(File.join(@fixture, "tst20-consumed-stdin"))
      task_path = File.join(@data, "tasks", "T.yml")
      task = YAML.safe_load_file(task_path)
      task["checkpoint"] = { "mode" => "exempt", "category" => "inspection", "reason" => "Fixture policy change cannot erase evidence." }
      File.write(task_path, YAML.dump(task))
      File.write(checkpoint.fetch("path"), "tampered checkpoint")
      before = bytes
      assert_equal 2, cli("checkpoint", "verify", "T", "--attempt", "1").first
      assert_equal 2, cli("launch", "T", "--codex").first
      assert_equal before, bytes
    end
  end

  # Recovery under the shared lock leaves an independently reviewed sibling's
  # bytes/state/branch unchanged in either task order. Only terminal fake workers
  # are used, so the existing running-worker macOS ps boundary is never invoked.
  def test_sibling_terminal_review_is_independent_in_both_orders
    [%w[T B], %w[B T]].each do |order|
      fixture do
        task = YAML.safe_load_file(File.join(@data, "tasks", "T.yml"))
        write_task(@data, id: "B", repositories: task.fetch("repositories"))
        succeeds("launch", order.first, "--codex")
        succeeds("launch", order.last, "--codex", "--allow-write-collision")
        sibling_report = JSON.parse(File.binread(Dir.glob("#{@data}-runs/B/*/handoff.json").first))
        sibling = bytes(File.dirname(sibling_report.fetch("worktrees_path"))).merge(bytes(sibling_report.fetch("workspace")))
        sibling_state = @states.load("B")
        sibling_head = git("rev-parse", "refs/heads/act/B/attempt-1", directory: File.join(@fixture, "writer"))
        decision_succeeds("record", "T", "blocked")
        decision_succeeds("close-attempt", "T", liveness_checks: 3)
        decision_succeeds("prepare", "T", "--retry", liveness_checks: 1)
        succeeds("launch", "T", "--codex", "--allow-write-collision")
        assert_equal sibling, sibling.keys.to_h { |path| [path, File.binread(path)] }
        assert_equal sibling_state, @states.load("B")
        assert_equal sibling_head, git("rev-parse", "refs/heads/act/B/attempt-1", directory: File.join(@fixture, "writer"))
      end
    end
  end

  # Extends only declared external host/fault boundaries in disposable fixtures.
  # Reset ownership, archive, state and native Git remain production code.
  def hard_reset_fixture(readers: 0)
    fixture(readers: readers, native_reset: true) do
      @hard_reset_fixture = true
      yield
    end
  end

  # Invokes a cold public CLI with genuine terminal input or redirected stdin.
  # Captures binary streams/status separately; a bounded wait owns only this
  # newly spawned fixture child. No production process is signaled.
  def hard_reset_cli(*arguments, answer: "yes\n", interactive: true, fault: nil, break_retirement: false)
    environment = retry_environment.merge('ACT28_RESET_FAULT' => fault,
      'ACT28_BREAK_RETIREMENT' => break_retirement ? '1' : nil)
    approval = ChildProcesses.permit('retry_cli', arguments: arguments, environment: environment,
      endpoint: retry_broker.endpoint, options: { pgroup: true })
    unless interactive
      return NoGitExecution.with_permit(approval) do
        Open3.capture3(approval.environment, *approval.argv, stdin_data: answer == :eof ? '' : answer,
          binmode: true, **approval.options).then { |out, err, status| [status.exitstatus, out, err] }
      end
    end
    PTY.open do |master, slave|
      Tempfile.create("act28-out-") do |output|
        Tempfile.create("act28-err-") do |error|
          child = NoGitExecution.with_permit(approval) do
            Process.spawn(approval.environment, *approval.argv, in: slave, out: output, err: error, **approval.options)
          end
          master.write(answer == :eof ? "\x04" : answer)
          status = Timeout.timeout(20) { Process.wait2(child).last }
          [status.exitstatus, File.binread(output.path), File.binread(error.path)]
        ensure
          if child && !status
            Process.kill("KILL", child) rescue Errno::ESRCH
            Process.waitpid(child) rescue Errno::ECHILD
          end
        end
      end
    end
  end

  # Requires success and returns the printed reset summary for scope assertions.
  def hard_reset_succeeds(*arguments, **options)
    code, output, error = hard_reset_cli(*arguments, **options)
    assert_equal 0, code, error
    output
  end

  # Returns reset receipts from their separate private, non-discovery root.
  def reset_receipts
    Dir.glob("#{@data}-resets/T/*/operation.yml").map { |path| YAML.safe_load_file(path) }
  end

  # Uses the same explicit boot/lsof host boundaries as cold CLI fixtures for
  # deterministic confirmation-race checks. Native PID checks remain enabled.
  def with_reset_handler(**options)
    previous_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{@fixture}:#{previous_path}"
    capture = Object.new
    checkouts = @retry_checkouts
    capture.define_singleton_method(:capture3) do |*argv, **fields|
      paths = checkouts.values.flat_map { |checkout| checkout.repository.worktrees.keys }
      raise MemoryGit::Mismatch, 'undeclared warm reset lsof' unless argv.take(4) == %w[lsof -n -P +D] &&
        argv.length == 5 && paths.include?(argv.last) && fields.empty?
      ChildProcesses.capture('status', arguments: ['1'])
    end
    liveness = AgentCodingTool::RetryLiveness.new(capture: capture)
    AgentCodingTool::RetryLiveness.stub(:host_identity, { "fixture_boot" => "deterministic external identity" }) do
      yield AgentCodingTool::TaskReset.new(data_root: @data, liveness: liveness, **options)
    end
  ensure
    ENV["PATH"] = previous_path
  end

  # The same continuous public journey must fail if retirement handoff is removed.
  # It covers the OS-EV-03-shaped access/membership change and fresh preparation
  # without retry. Only fake worker and explicit host boundaries are substituted.
  def assert_hard_reset_journey(break_retirement: false)
    succeeds("launch", "T", "--codex")
    first = reports.first
    task_path = File.join(@data, "tasks", "T.yml")
    task = YAML.safe_load_file(task_path)
    task.fetch("repositories").fetch("writer")["access"] = "read_only"
    task.fetch("repositories")["af-evidence"] = task.fetch("repositories").delete("reader1").merge("access" => "write")
    File.write(task_path, YAML.dump(task))
    succeeds("reset", "T")
    code, _output, error = cli("prepare", "T", "--retry")
    assert_equal 2, code
    assert_includes error, "explicit close-attempt required"
    before = bytes
    preview = hard_reset_succeeds("reset", "--hard", "T", "--dry-run")
    assert_includes preview, first.fetch("workspace")
    assert_equal before, bytes
    output = hard_reset_succeeds("reset", "T", "--hard", break_retirement: break_retirement)
    assert_includes output, "T: READY"
    assert_includes output, "Next: act prepare T"
    receipt = reset_receipts.fetch(0)
    assert_equal "complete", receipt.fetch("phase")
    archive = receipt.fetch("archive")
    assert_equal first, JSON.parse(File.binread(Dir.glob(File.join(archive, "original", "runs", "*", "handoff.json")).fetch(0)))
    first.fetch("worktrees").fetch("entries").each do |entry|
      refute File.exist?(entry.fetch("path"))
      refute_includes git("worktree", "list", "--porcelain", directory: entry.fetch("parent")), entry.fetch("path")
    end
    assert_empty JSON.parse(succeeds("worktrees", "T")).fetch("attempts")
    next_view = JSON.parse(succeeds("next", "--json"))
    task_fact = next_view.fetch("facts").fetch("tasks").find { |row| row["id"] == "T" }
    assert_equal "READY", task_fact.fetch("status")
    assert_equal archive, task_fact.fetch("reset_history").first.fetch("archive")
    foreign = File.join("#{@data}-runs", "foreign-active-evidence")
    File.write(foreign, "unknown active namespace entry")
    before = bytes
    assert_equal 2, cli("launch", "T", "--codex").first
    assert_equal before, bytes
    File.unlink(foreign)
    succeeds("prepare", "T")
    succeeds("launch", "T", "--codex")
    second = reports.fetch(0)
    assert_equal 2, second.fetch("attempt")
    assert_equal %w[af-evidence writer], second.fetch("preparation").keys.sort
    assert_equal ["af-evidence"], second.fetch("writable_repositories")
    refute_equal first.fetch("workspace"), second.fetch("workspace")
    refute_equal first.fetch("invocation_id"), second.fetch("invocation_id")
    history = JSON.parse(succeeds("worktrees", "T"))
    assert_equal 1, history.fetch("attempts").length
    assert_equal archive, history.fetch("resets").fetch(0).fetch("archive")
    assert_includes succeeds("status", "T", "--full"), archive
    assert_equal @base, git("rev-parse", "refs/heads/act/T/attempt-1", directory: File.join(@fixture, "writer"))
  end

  # Real terminal confirmation, genuine native retirement and archive handoff
  # are part of one fresh-process journey; a removed handoff fails that journey.
  def test_hard_reset_changed_scope_public_journey_and_retirement_negative_control
    hard_reset_fixture(readers: 1) { assert_hard_reset_journey }
    hard_reset_fixture(readers: 1) do
      failure = assert_raises(Minitest::Assertion) { assert_hard_reset_journey(break_retirement: true) }
      assert_includes failure.message, "evidence retirement incomplete"
      refute_equal "complete", reset_receipts.fetch(0).fetch("phase")
      refute @states.load("T")["snapshot"]
      assert File.directory?("#{@data}-runs/T")
    end
  end

  # All read-only/declined paths preserve bytes, POSIX modes, links and native
  # registries/index/refs. Noninteractive yes cannot consent to destruction.
  def test_hard_reset_preview_decline_eof_and_unsafe_arguments_are_read_only
    hard_reset_fixture do
      succeeds("launch", "T", "--codex")
      archive = AgentCodingTool::ResetArchive.new
      before = archive.inventory(@fixture)
      [%w[reset T --hard --dry-run], %w[reset --hard T --dry-run]].each do |arguments|
        hard_reset_succeeds(*arguments)
        assert_equal before, archive.inventory(@fixture)
      end
      [{answer: "\n"}, {answer: "no\n"}, {answer: :eof}, {interactive: false}].each do |options|
        assert_includes hard_reset_succeeds("reset", "--hard", "T", **options), "Declined"
        assert_equal before, archive.inventory(@fixture)
      end
      [%w[reset T --hard --force], %w[reset T --dry-run], %w[reset T --hard --hard],
       %w[reset --hard ../T], %w[reset MISSING --hard], %w[reset T --hard --yes]].each do |arguments|
        assert_equal 2, hard_reset_cli(*arguments).first
        assert_equal before, archive.inventory(@fixture)
      end
    end
  end

  # Preserves independent HEAD/index/worktree versions, binary/unmerged stages,
  # additions/deletions, ignored/untracked content, modes and links. Reconstruction
  # uses only the archive, with ordinary/sibling/external bytes and refs unchanged.
  def test_hard_reset_dirty_binary_index_and_worktree_reconstruct_independently
    hard_reset_fixture do
      ordinary = File.join(@fixture, "writer")
      File.binwrite(File.join(ordinary, "delete.bin"), "delete\0\xff".b)
      git("add", "delete.bin", directory: ordinary)
      git("commit", "-m", "fixture binary baseline", directory: ordinary)
      git("push", "origin", "main", directory: ordinary)
      succeeds("launch", "T", "--codex")
      report = reports.first
      workspace = report.fetch("workspace")
      write_task(@data, id: "B", repositories: YAML.safe_load_file(File.join(@data, "tasks", "T.yml")).fetch("repositories"))
      succeeds("launch", "B", "--codex", "--allow-write-collision")
      sibling_path = Dir.glob("#{@data}-runs/B/*/handoff.json").fetch(0)
      sibling = JSON.parse(File.binread(sibling_path))
      sibling_files = bytes(sibling.fetch("workspace")).merge(bytes(File.dirname(sibling_path)))
        .merge(bytes(git("rev-parse", "--absolute-git-dir", directory: sibling.fetch("workspace"))))
      sibling_files[@states.state_path("B")] = File.binread(@states.state_path("B"))
      sibling_snapshot = sibling_files.to_h { |path, content| [path, [content, File.stat(path).mode]] }
      git("commit", "--allow-empty", "-m", "fixture advanced task candidate", directory: workspace)
      File.binwrite(File.join(workspace, "file.txt"), "index\0\xff".b)
      File.binwrite(File.join(workspace, "added.bin"), "added index\0\xfe".b)
      git("add", "file.txt", "added.bin", directory: workspace)
      File.binwrite(File.join(workspace, "file.txt"), "worktree\0\x80".b)
      File.unlink(File.join(workspace, "delete.bin"))
      File.binwrite(File.join(workspace, "untracked.bin"), "untracked\0\xff".b)
      File.write(File.join(workspace, ".gitignore"), "ignored.bin\n")
      File.binwrite(File.join(workspace, "ignored.bin"), "ignored\0\xff".b)
      File.chmod(0o755, File.join(workspace, "file.txt"))
      external = File.join(@fixture, "external.bin")
      File.binwrite(external, "external\0\xff".b)
      File.symlink(external, File.join(workspace, "external-link"))
      base_blob = git("rev-parse", "HEAD:file.txt", directory: workspace)
      staged_blob = git("rev-parse", ":added.bin", directory: workspace)
      _out, error, status = @retry_world.call(["git", "update-index", "--index-info"], cwd: workspace,
        input: "100644 #{base_blob} 1\tconflict.bin\n100644 #{staged_blob} 2\tconflict.bin\n100644 #{base_blob} 3\tconflict.bin\n")
      assert status.success?, error
      File.binwrite(File.join(workspace, "conflict.bin"), "unmerged working bytes\0\xff".b)
      source_head = git("rev-parse", "HEAD", directory: workspace)
      stages = git("ls-files", "--stage", directory: workspace)
      index_path = git("rev-parse", "--path-format=absolute", "--git-path", "index", directory: workspace)
      index_bytes = File.binread(index_path)
      index_mode = File.stat(index_path).mode & 0o7777
      original = AgentCodingTool::ResetArchive.new.inventory(workspace).reject { |path, _row| path == ".git" }
      refs = git("show-ref", directory: ordinary)
      ordinary_files = bytes(ordinary).reject { |path, _value| path.include?("/.git/worktrees/") }
      hard_reset_succeeds("reset", "T", "--hard")
      receipt = reset_receipts.fetch(0)
      snapshot = File.join(receipt.fetch("archive"), "candidates", "0")
      rebuilt = File.join(@fixture, "independent")
      FileUtils.cp_r(File.join(snapshot, "worktree"), rebuilt, preserve: true)
      File.unlink(File.join(rebuilt, ".git"))
      FileUtils.cp_r(File.join(snapshot, "repository.git"), File.join(rebuilt, ".git"), preserve: true)
      git("config", "core.bare", "false", directory: rebuilt)
      assert_equal source_head, git("rev-parse", "HEAD", directory: rebuilt)
      assert_equal stages, git("ls-files", "--stage", directory: rebuilt)
      assert_equal index_bytes, File.binread(File.join(rebuilt, ".git", "index"))
      assert_equal index_mode, File.stat(File.join(rebuilt, ".git", "index")).mode & 0o7777
      actual = AgentCodingTool::ResetArchive.new.inventory(rebuilt).reject { |path, _row| path == ".git" || path.start_with?(".git/") }
      assert_equal original, actual
      assert_equal refs, git("show-ref", directory: ordinary)
      assert_equal ordinary_files, bytes(ordinary).reject { |path, _value| path.include?("/.git/worktrees/") }
      assert_equal "external\0\xff".b, File.binread(external)
      assert_equal external, File.readlink(File.join(rebuilt, "external-link"))
      assert_equal sibling_snapshot, sibling_snapshot.keys.to_h { |path| [path, [File.binread(path), File.stat(path).mode]] }
    end
  end

  # Cold repeats at archive/native/evidence/lifecycle boundaries either resume
  # the exact operation or refuse new material. No old evidence is rewritten.
  def test_hard_reset_interruptions_fence_admission_and_resume_same_archive
    ["before_archive", "before_archive_verified", "after_archive", "before_remove:0", "after_remove:0",
     "after_move:original/runs", "before_state", "after_state"].each do |phase|
      hard_reset_fixture do
        succeeds("launch", "T", "--codex")
        original = bytes(File.dirname(reports.first.fetch("worktrees_path")))
        code, _output, error = hard_reset_cli("reset", "T", "--hard", fault: phase)
        assert_equal 2, code, phase
        assert_includes error, "injected #{phase}"
        receipt = reset_receipts.fetch(0)
        refute_equal "complete", receipt.fetch("phase")
        assert_equal 2, cli("prepare", "T").first
        assert_equal 2, cli("launch", "T", "--codex").first
        assert_includes succeeds("status", "T", "--full"), "unfinished hard reset"
        hard_reset_succeeds("reset", "--hard", "T")
        assert_equal [receipt.fetch("archive")], reset_receipts.map { |record| record.fetch("archive") }
        assert_equal "complete", reset_receipts.fetch(0).fetch("phase")
        original.each do |path, content|
          archived = File.join(receipt.fetch("archive"), "original", "runs", File.basename(File.dirname(path)), File.basename(path))
          assert_equal content, File.binread(archived)
        end
        before = bytes
        assert_includes hard_reset_succeeds("reset", "T", "--hard"), "already reset"
        assert_equal before, bytes
      end
    end
  end

  # Reusing a logical repository name never hides an older attempt's external
  # authority. Real observation envelopes must block in either attempt order;
  # ending each observation removes only its own blocker without rewriting inputs.
  def test_hard_reset_retains_each_historical_external_authority
    fixture(readers: 1) do
      stores = AgentCodingTool::TaskStore.new(File.join(@data, "tasks"))
      original = stores.load("T").fetch("repositories")
      old_spec = original.fetch("writer")
      new_spec = original.fetch("reader1").merge("access" => "write")
      write_task(@data, id: "T", repositories: { "writer" => new_spec })
      write_task(@data, id: "OLD", repositories: { "writer" => old_spec })
      write_task(@data, id: "NEW", repositories: { "writer" => new_spec })
      inspector = AgentCodingTool::RepoInspector.new(AgentCodingTool::Config.load(File.join(@data, "config.yml")))
      external = AgentCodingTool::ExternalActivity.new(data_root: @data, task_store: stores,
        state_store: @states, repo_inspector: inspector)
      observations = %w[OLD NEW].to_h do |id|
        document = external.report(id, reporter: "fixture", kind: "external", scope_complete: true)
        assert_equal "bounded", document.fetch("active").fetch("envelope").fetch("scope")
        [id, document.fetch("active").fetch("observation_id")]
      end
      preparations = [old_spec, new_spec].map { |spec| { "writer" => inspector.snapshot("writer", spec) } }
      attempts = preparations.each_with_index.map do |preparation, index|
        { "report" => { "attempt" => index + 1, "preparation" => preparation }, "inventory" => {}, "entries" => [] }
      end
      state = { "snapshot" => preparations.last }
      task = stores.load("T")
      original_inputs = Marshal.dump([task, state, attempts])
      liveness = AgentCodingTool::RetryLiveness.new
      liveness.stub(:check, :clear) do
        with_reset_handler(liveness: liveness) do |handler|
          [attempts, attempts.reverse].each do |ordered|
            blockers = handler.send(:liveness_blockers, task, state, ordered)
            assert_equal 2, blockers.length
            observations.each_value { |id| assert_equal 1, blockers.count { |message| message.include?(id) } }
          end
          external.end_activity("OLD", observations.fetch("OLD"), disposition: "ended")
          blockers = handler.send(:liveness_blockers, task, state, attempts)
          assert_equal 1, blockers.length
          assert_includes blockers.first, observations.fetch("NEW")
          external.end_activity("NEW", observations.fetch("NEW"), disposition: "ended")
          assert_empty handler.send(:liveness_blockers, task, state, attempts)
        end
      end
      assert_equal original_inputs, Marshal.dump([task, state, attempts])
    end
  end

  # Live/reused host identities, uncertain boot proof, foreign paths/inventories,
  # external observations and busy physical locks refuse without changing data.
  # The real live sentinel remains alive until this test releases its own pipe.
  def test_hard_reset_live_unknown_foreign_external_and_busy_refusals
    hard_reset_fixture do
      succeeds("launch", "T", "--codex")
      report = reports.first
      report_path = File.join(File.dirname(report.fetch("worktrees_path")), "handoff.json")
      original_report = File.binread(report_path)
      sentinel, release = independent_worker
      begin
        [{ "host_pid" => sentinel }, { "host_identity" => nil }].each do |changes|
          File.write(report_path, JSON.pretty_generate(report.merge(changes)))
          before = bytes
          code, _output, error = hard_reset_cli("reset", "T", "--hard")
          assert_equal 2, code
          assert_match(/use (active|unknown)/, error)
          assert_equal before, bytes
          assert Process.kill(0, sentinel)
        end
      ensure
        File.binwrite(report_path, original_report)
        release.write("x") rescue Errno::EPIPE
        release.close
        Process.waitpid(sentinel)
      end
      inventory_path = report.fetch("worktrees_path")
      original_inventory = File.binread(inventory_path)
      tampered = JSON.parse(original_inventory)
      tampered.fetch("entries").first["access"] = "read_only"
      tampered.fetch("entries").first["branch"] = nil
      File.write(inventory_path, JSON.generate(tampered))
      before = bytes
      assert_equal 2, hard_reset_cli("reset", "T", "--hard").first
      assert_equal before, bytes
      File.binwrite(inventory_path, original_inventory)
      foreign = File.join(@visible, "T", "foreign")
      File.write(foreign, "unowned bytes")
      before = bytes
      assert_equal 2, hard_reset_cli("reset", "T", "--hard").first
      assert_equal before, bytes
      File.unlink(foreign)
      activity = JSON.parse(succeeds("external", "report", "T", "--reporter", "fixture", "--kind", "external"))
      before = bytes
      code, _output, error = hard_reset_cli("reset", "T", "--hard")
      assert_equal 2, code
      assert_includes error, activity.fetch("active").fetch("observation_id")
      assert_equal before, bytes
      succeeds("external", "end", "T", activity.fetch("active").fetch("observation_id"), "--disposition", "ended")
      File.open("#{@data}-runs/launch.lock", "r+") do |lock|
        lock.flock(File::LOCK_EX)
        before = bytes
        code, _output, error = hard_reset_cli("reset", "T", "--hard")
        assert_equal 2, code
        assert_includes error, "reservation busy"
        assert_equal before, bytes
        marker = File.join(@fixture, "gate-must-not-run")
        [["prepare", "T"], ["launch", "T", "--codex"],
         ["checkpoint", "record", "T", "--workspace", report.fetch("workspace")],
         ["checkpoint", "gate", "T", "--workspace", report.fetch("workspace"), "--", RbConfig.ruby, "-e", "File.write(ARGV.fetch(0), 'ran')", marker]].each do |arguments|
          code, _output, error = cli(*arguments)
          assert_equal 2, code
          assert_includes error, "reservation busy"
          refute File.exist?(marker)
          assert_equal before, bytes
        end
      end
      assert_empty reset_receipts
    end
  end

  # Confirmation binds both raw state/task sources and index-only content.
  # An archive I/O failure retains all original candidates/evidence and records
  # an unfinished phase; none of these failures may manufacture READY.
  def test_hard_reset_confirmation_races_archive_capacity_and_new_resource_refuse
    hard_reset_fixture do
      succeeds("launch", "T", "--codex")
      report = reports.first
      with_reset_handler do |handler|
        preview = handler.preview("T")
        task_path = File.join(@data, "tasks", "T.yml")
        task_bytes = File.binread(task_path)
        File.write(task_path, task_bytes.sub("title: Task", "title: Changed"))
        before = bytes
        assert_includes assert_raises(AgentCodingTool::InvalidState) { handler.execute("T", preview: preview) }.message, "source changed after preview"
        assert_equal before, bytes
        File.binwrite(task_path, task_bytes)
        preview = handler.preview("T")
        git("add", "file.txt", directory: report.fetch("workspace"))
        # Force an index-only semantic change while preserving working bytes.
        git("update-index", "--chmod=+x", "file.txt", directory: report.fetch("workspace"))
        before = bytes
        assert_includes assert_raises(AgentCodingTool::InvalidState) { handler.execute("T", preview: preview) }.message, "source changed after preview"
        assert_equal before, bytes
      end
      archive = AgentCodingTool::ResetArchive.new
      archive.define_singleton_method(:preserve) { |*| raise Errno::ENOSPC, "fixture capacity" }
      AgentCodingTool::ResetArchive.stub(:new, archive) do
        with_reset_handler do |handler|
          preview = handler.preview("T")
          original = bytes(File.dirname(report.fetch("worktrees_path"))).merge(bytes(report.fetch("workspace")))
          assert_includes assert_raises(AgentCodingTool::InvalidState) { handler.execute("T", preview: preview) }.message, "ENOSPC"
          assert_equal original, original.keys.to_h { |path| [path, File.binread(path)] }
        end
      end
      assert_equal "preserving", reset_receipts.first.fetch("phase")
      extra = File.join(@data, "state", "prompts", "T-new.txt")
      File.write(extra, "new unowned preparation")
      before = bytes
      assert_equal 2, hard_reset_cli("reset", "T", "--hard").first
      assert_equal before, bytes
      assert File.directory?(report.fetch("workspace"))
      assert_equal 2, cli("prepare", "T").first
    end
  end

  # Pre-worker partial creation, malformed state/log progress and multiple owned
  # attempts can be independently preserved. Missing original prompt/ownership
  # cannot be substituted by current task state or a caller's reset receipt.
  def test_hard_reset_partial_creation_and_malformed_progress_preserve_original_bytes
    %w[before after].each do |fault|
      hard_reset_fixture(readers: 1) do
        assert_equal 2, cli("launch", "T", "--codex", fault: fault).first
        original_report = reports.first
        raw = "id: [unterminated\n\xff".b
        File.binwrite(@states.state_path("T"), raw)
        directory = File.dirname(original_report.fetch("worktrees_path"))
        File.binwrite(File.join(directory, "progress.tmp"), "malformed\0\xff".b)
        hard_reset_succeeds("reset", "T", "--hard")
        receipt = reset_receipts.first
        assert_equal raw, File.binread(File.join(receipt.fetch("archive"), "original", "state"))
        assert_equal "malformed\0\xff".b, File.binread(Dir.glob(File.join(receipt.fetch("archive"), "original", "runs", "*", "progress.tmp")).fetch(0))
        assert_equal({ "id" => "T" }, @states.load("T"))
        succeeds("prepare", "T")
      end
    end
    hard_reset_fixture do
      succeeds("launch", "T", "--codex")
      report = reports.first
      File.unlink(report.fetch("worktrees_path"))
      before = bytes
      assert_equal 2, hard_reset_cli("reset", "T", "--hard").first
      assert_equal before, bytes
      assert File.directory?(report.fetch("workspace"))
    end
  end

  # Hard reset clears each explicit lifecycle/deferral state, preserving prior
  # outcomes and downstream declarations. Real dependency blockers survive.
  # A second unchanged reset creates no archive; a fresh run gets a new identity.
  def test_hard_reset_lifecycle_variants_deferral_dependencies_and_repeat
    hard_reset_fixture do
      write_task(@data, id: "DEPENDENT", depends_on: ["T"])
      write_task(@data, id: "PREREQUISITE")
      succeeds("icebox", "T")
      deferred = @states.load("T")
      succeeds("reset", "T")
      assert_equal deferred, @states.load("T")
      hard_reset_succeeds("reset", "T", "--hard")
      refute @states.load("T").key?("icebox")
      %w[prepared blocked failed needs_judgment candidate_complete complete].each do |state|
        succeeds("prepare", "T")
        succeeds("launch", "T", "--codex") unless state == "prepared"
        succeeds("record", "T", state) unless state == "prepared"
        previous = File.binread(@states.state_path("T"))
        output = hard_reset_succeeds("reset", "T", "--hard")
        assert_includes output, "DEPENDENT"
        receipt = reset_receipts.max_by { |record| record.fetch("created_at") }
        assert_equal previous, File.binread(File.join(receipt.fetch("archive"), "original", "state"))
        assert_equal({ "id" => "T" }, @states.load("T"))
      end
      task_path = File.join(@data, "tasks", "T.yml")
      task = YAML.safe_load_file(task_path)
      task["depends_on"] = ["PREREQUISITE"]
      File.write(task_path, YAML.dump(task))
      @states.write("T", { "id" => "T", "icebox" => { "at" => "2026-10-31T12:00:00Z" }, "operator_note" => "retain" })
      output = hard_reset_succeeds("reset", "T", "--hard")
      assert_includes output, "T: BLOCKED; dependencies incomplete: PREREQUISITE"
      assert_equal task, YAML.safe_load_file(task_path)
      assert_empty @states.load("PREREQUISITE")
      assert_empty @states.load("DEPENDENT")
      assert_equal({ "id" => "T", "operator_note" => "retain" }, @states.load("T"))
      before = bytes
      count = reset_receipts.length
      assert_includes hard_reset_succeeds("reset", "T", "--hard"), "already reset"
      assert_equal count, reset_receipts.length
      assert_equal before, bytes
      task["depends_on"] = []
      task.fetch("repositories").fetch("writer")["path"] = File.join(@fixture, "missing-repository")
      File.write(task_path, YAML.dump(task))
      output = succeeds("status", "T", "--full")
      assert_includes output, "T: BLOCKED"
      assert_includes output, "configuration: writer: repository path does not exist"
    end
  end

  # Retires every owned generation/repository without branch reuse or adoption of
  # old checkpoint/delivery proof. An interrupted second native removal resumes
  # against the same inventory, with original outcomes/evidence kept intact.
  def test_hard_reset_multiple_attempts_native_retirement_and_fresh_binding
    hard_reset_fixture(readers: 1) do
      succeeds("launch", "T", "--codex")
      succeeds("record", "T", "failed")
      succeeds("close-attempt", "T")
      succeeds("prepare", "T", "--retry")
      succeeds("launch", "T", "--codex")
      old = reports
      code, _output, error = hard_reset_cli("reset", "T", "--hard", fault: "after_remove:1")
      assert_equal 2, code
      assert_includes error, "injected after_remove:1"
      hard_reset_succeeds("reset", "T", "--hard")
      receipt = reset_receipts.first
      assert_equal 2, receipt.fetch("last_attempt")
      assert_equal 4, receipt.fetch("retired").length
      assert receipt.fetch("retired").values.all? { |status| status == "removed" }
      succeeds("prepare", "T")
      succeeds("launch", "T", "--codex")
      current = reports.fetch(0)
      assert_equal 3, current.fetch("attempt")
      assert_equal 2, cli("checkpoint", "verify", "T", "--attempt", "1").first
      old.each do |report|
        record = Dir.glob(File.join(receipt.fetch("archive"), "original", "runs", "*", "handoff.json"))
          .find { |path| JSON.parse(File.binread(path))["invocation_id"] == report.fetch("invocation_id") }
        assert_equal report, JSON.parse(File.binread(record))
        handler = AgentCodingTool::DeliveryManager.new(data_root: @data, coordinator: Object.new)
        assert_includes assert_raises(AgentCodingTool::InvalidState) { handler.deliver("T", run_dir: File.dirname(record)) }.message, "foreign run"
        assert_equal @base, git("rev-parse", "refs/heads/act/T/attempt-#{report.fetch('attempt')}", directory: File.join(@fixture, "writer"))
      end
      succeeds("record", "T", "failed")
      succeeds("close-attempt", "T")
      succeeds("prepare", "T", "--retry")
      assert_equal [3], reports.map { |report| report.fetch("attempt") }
    end
  end

  # Old fixed-path inventories with independently verifiable boot/process proof
  # retain their original layout. A new generation uses fresh isolated paths.
  def test_hard_reset_legacy_owned_layout_without_rewriting_history
    hard_reset_fixture do
      previous = ENV["ACT28_LEGACY_LAYOUT"]
      begin
        ENV["ACT28_LEGACY_LAYOUT"] = "1"
        succeeds("launch", "T", "--codex")
      ensure
        ENV["ACT28_LEGACY_LAYOUT"] = previous
      end
      old = reports.first
      assert_equal File.join(@visible, "T", "writer"), old.fetch("workspace")
      assert_nil old.fetch("worktrees")["layout"]
      original = bytes(File.dirname(old.fetch("worktrees_path")))
      hard_reset_succeeds("reset", "T", "--hard")
      receipt = reset_receipts.first
      original.each do |path, value|
        assert_equal value, File.binread(File.join(receipt.fetch("archive"), "original", "runs", File.basename(File.dirname(path)), File.basename(path)))
      end
      succeeds("prepare", "T")
      succeeds("launch", "T", "--codex")
      assert_equal 2, reports.first.fetch("attempt")
      assert_equal File.join(@visible, "T", "attempt-2", "writer"), reports.first.fetch("workspace")
    end
  end

  # Unsafe roots/types, unfinished gates/publication and altered archives refuse
  # at their own boundary. A reoccupied retired path is never removed on resume.
  def test_hard_reset_unsafe_progress_and_archive_tampering_refuse
    hard_reset_fixture do
      succeeds("launch", "T", "--codex")
      report = reports.first
      workspace = report.fetch("workspace")
      parked = workspace + "-parked"
      File.rename(workspace, parked)
      File.symlink(parked, workspace)
      before = bytes
      code, _output, error = hard_reset_cli("reset", "T", "--hard")
      assert_equal 2, code
      assert_includes error, "symlinked"
      assert_equal before, bytes
      File.unlink(workspace)
      File.rename(parked, workspace)
      socket_path = File.join(workspace, "fifo")
      File.mkfifo(socket_path)
      before = bytes
      code, _output, error = hard_reset_cli("reset", "T", "--hard")
      assert_equal 2, code
      assert_includes error, "nonpreservable entry"
      assert_equal before, bytes
      File.unlink(socket_path)
      gates = File.join("#{@data}-runs", "checkpoints", "T", "a" * 32)
      FileUtils.mkdir_p(gates, mode: 0o700)
      started = File.join(gates, "gate-#{SecureRandom.uuid}.started.json")
      File.write(started, "{}")
      before = bytes
      code, _output, error = hard_reset_cli("reset", "T", "--hard")
      assert_equal 2, code
      assert_includes error, "unresolved active gate"
      assert_equal before, bytes
      File.unlink(started)
      delivery = File.join(File.dirname(report.fetch("worktrees_path")), "delivery.json")
      File.write(delivery, JSON.generate("schema" => AgentCodingTool::DeliveryManager::SCHEMA, "task_id" => "T", "stage" => "pushed"))
      before = bytes
      code, _output, error = hard_reset_cli("reset", "T", "--hard")
      assert_equal 2, code
      assert_includes error, "unresolved publication"
      assert_equal before, bytes
      File.unlink(delivery)
      code, _output, error = hard_reset_cli("reset", "T", "--hard", fault: "after_archive")
      assert_equal 2, code
      assert_includes error, "injected after_archive"
      receipt = reset_receipts.first
      copy = File.join(receipt.fetch("archive"), "candidates", "0", "worktree", "file.txt")
      File.binwrite(copy, "altered archive")
      before = bytes
      code, _output, error = hard_reset_cli("reset", "T", "--hard")
      assert_equal 2, code
      assert_includes error, "candidate archive changed"
      assert_equal before, bytes
      assert File.directory?(workspace)
    end
    hard_reset_fixture do
      succeeds("launch", "T", "--codex")
      workspace = reports.first.fetch("workspace")
      assert_equal 2, hard_reset_cli("reset", "T", "--hard", fault: "after_remove:0").first
      Dir.mkdir(workspace)
      File.write(File.join(workspace, "foreign"), "keep new resource")
      before = bytes
      assert_equal 2, hard_reset_cli("reset", "T", "--hard").first
      assert_equal before, bytes
      assert_equal "keep new resource", File.read(File.join(workspace, "foreign"))
    end
  end

  # Administrative outcomes/overrides cannot prove that a manual worker ended.
  # No receipt, archive or source removal may result from these declarations.
  def test_hard_reset_manual_reservations_do_not_become_inactive_by_declaration
    hard_reset_fixture do
      succeeds("prepare", "T")
      succeeds("start", "T")
      before = bytes
      code, _output, error = hard_reset_cli("reset", "T", "--hard")
      assert_equal 2, code
      assert_includes error, "manual/unknown worker"
      assert_equal before, bytes
      succeeds("record", "T", "failed")
      before = bytes
      code, _output, error = hard_reset_cli("reset", "T", "--hard")
      assert_equal 2, code
      assert_includes error, "manual/unknown outcome"
      assert_equal before, bytes
      succeeds("reset", "T", "--force")
      before = bytes
      assert_equal 2, hard_reset_cli("reset", "T", "--hard").first
      assert_equal before, bytes
      assert_empty reset_receipts
    end
  end

end
