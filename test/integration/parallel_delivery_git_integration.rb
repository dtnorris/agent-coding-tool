# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../launcher_support"
require "timeout"

# Real disposable Git/process evidence with simulated publication only; no network.
class ParallelDeliveryTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Tracks independent feature identities and can simulate a lost push response.
  class Provider
    attr_reader :refs, :prs, :pushes
    attr_accessor :fail_after_push

    # Creates empty simulated remote state; no I/O or errors.
    def initialize
      @refs, @prs, @pushes = {}, {}, []
    end

    # Returns a simulated ref or nil for the requested remote/branch.
    def branch(_remote, name) = @refs[name]

    # Records one simulated feature push; optional lost response raises RepositoryError.
    def push(_workspace, _remote, name, sha)
      @refs[name] = sha
      @pushes << name
      raise AgentCodingTool::RepositoryError, "lost push response" if fail_after_push
    end

    # Returns simulated PRs for one task branch; never contacts GitHub.
    def pull_requests(_remote, name) = @prs.fetch(name, [])

    # Records one draft for the requested branch/base; returns its identity.
    def create_draft(_remote, name, base, _title, _body)
      @prs[name] = [{ "url" => "https://example.invalid/#{name}", "state" => "open",
                     "draft" => true, "head" => @refs.fetch(name), "base" => base }]
    end
  end

  # Fake independent guard; refusal tests prove it still gates simulated pushes.
  class Guard
    attr_accessor :deny

    # Returns nil or raises InvalidState; never provisions resources.
    def verify!(*_args)
      raise AgentCodingTool::InvalidState, "publication not authorized" if deny
    end
  end

  # Models the unavailable open-file probe; real child process groups must be gone.
  # Production CleanupLiveness remains unchanged and still fails closed on unknown.
  class TerminalLiveness
    attr_accessor :unknown
    # Returns clear only for a reaped fixture child group, unknown otherwise.
    def check(report, _inventory)
      return :unknown if unknown
      Process.kill(0, -report.fetch("child_pid"))
      :unknown
    rescue Errno::ESRCH
      :clear
    end
  end

  # Runs fixture decision matrices with a controlled terminal open-file boundary.
  # Git, process execution, artifacts, worktree verification and locks remain real.
  def delivery_fixture(**options)
    fixture(git: true, process: true, **options) do
      @terminal_liveness = TerminalLiveness.new
      AgentCodingTool::CleanupLiveness.stub(:new, @terminal_liveness) { yield }
    end
  end

  # Returns one recorded host run; missing/ambiguous evidence raises IndexError.
  def run_for(id)
    path = Dir.glob("#{@data}-runs/#{id}/*/handoff.json").fetch(0)
    [JSON.parse(File.binread(path)), File.dirname(path)]
  end

  # Installs fixture-owned trusted commands/scope; never alters a real contract.
  def install_contract(id)
    root = "#{@data}-validation"
    FileUtils.mkdir_p(root, mode: 0o700)
    File.write(File.join(root, "#{id}.yml"), YAML.dump(
      "allowed_paths" => ["worker-change.txt", "file.txt"], "base_branch" => "main",
      "commands" => [["ruby", "-e", "puts '2 tests, 3 assertions, 0 failures, 0 errors, 0 skips'"]],
      "max_seconds" => 30, "min_tests" => 2, "min_assertions" => 3,
      "publication_guard" => { "trigger_assessment" => "simulated publication, zero cost" }))
  end

  # Prepares and executes two independent fake workers; returns simulated boundaries.
  # Both workers use production ownership/artifact capture and a fake sandbox probe.
  def independent_runs
    write_task(@data, id: "B", repositories: { "alias" => { "access" => "write", "path" => @ordinary } })
    %w[T B].each { |id| @coordinator.prepare(id) }
    assert_equal 0, launcher(real_sandbox_probe: true).launch("T")
    assert_equal 0, launcher(real_sandbox_probe: true).launch("B", allow_write_collision: true)
    %w[T B].each do |id|
      report, = run_for(id)
      File.write(File.join(report.fetch("workspace"), "file.txt"), "candidate #{id}\n")
      install_contract(id)
    end
    [Provider.new, Guard.new]
  end

  # Delivers both orders, including recovery beside a sibling's validated commit.
  # Exact bytes, independent branches/PRs, checkpoints and unchanged main are checked.
  def test_both_delivery_orders_preserve_independent_candidates_and_recover
    [%w[T B], %w[B T]].each do |order|
      delivery_fixture(mutable_remote: true) do
        provider, guard = independent_runs
        checkpoints = %w[T B].to_h do |id|
          report, = run_for(id)
          [id, AgentCodingTool::Checkpoint.new(data_root: @data).record(id, workspace: report.fetch("workspace"))]
        end
        manager = AgentCodingTool::DeliveryManager.new(data_root: @data, coordinator: @coordinator, provider:, guard:)
        order.each_with_index do |id, index|
          report, run_dir = run_for(id)
          sibling = order.fetch(1 - index)
          sibling_before = File.binread(@store.state_path(sibling))
          provider.fail_after_push = index == 1
          if index == 1
            assert_raises(AgentCodingTool::RepositoryError) { manager.deliver(id, run_dir:) }
            provider.fail_after_push = false
          end
          assert_equal "draft_pr", manager.deliver(id, run_dir:).fetch("stage")
          assert_equal sibling_before, File.binread(@store.state_path(sibling))
          detail = JSON.parse(File.binread(File.join(run_dir, "delivery.json")))
          assert_equal "candidate #{id}\n", setup_git("show", "#{detail.fetch('commit_sha')}:file.txt", chdir: report.fetch("workspace")) + "\n"
          assert_equal @base, setup_git("rev-parse", "refs/heads/main", chdir: @remote)
          assert_equal "CANDIDATE", @coordinator.status(id).fetch("status")
          handoff = @coordinator.status(id).fetch("candidate_handoff")
          assert_equal report.fetch("attempt"), handoff.fetch("attempt")
          assert_equal detail.fetch("paths"), handoff.fetch("changed_paths").values.first
          assert_equal detail.fetch("commit_sha"), handoff.dig("host_delivery", "repositories").values.first.fetch("commit_sha")
          checkpoint_path = checkpoints.fetch(id).fetch("path")
          assert_equal checkpoints.fetch(id).fetch("sha256"), Digest::SHA256.file(checkpoint_path).hexdigest
        end
        assert_equal %w[act/B/attempt-1 act/T/attempt-1], provider.refs.keys.sort
        assert_equal 2, provider.pushes.length
        assert_equal 2, provider.prs.length
        before = @store.load(order.first)
        File.write(File.join(@ordinary, "file.txt"), "advanced main\n")
        setup_git("commit", "-am", "advance main", chdir: @ordinary)
        setup_git("push", "origin", "main", chdir: @ordinary)
        status = @coordinator.status(order.first)
        assert_equal "STALE_CANDIDATE", status.fetch("status")
        assert_equal "not approved", status.dig("candidate_handoff", "integration")
        assert_equal before, @store.load(order.first)
        _, run_dir = run_for(order.first)
        assert_raises(AgentCodingTool::InvalidState) { manager.deliver(order.first, run_dir:) }
        assert_equal 2, provider.pushes.length
        checkpoints.each do |id, record|
          assert_equal record.fetch("sha256"), Digest::SHA256.file(record.fetch("path")).hexdigest
          assert_equal "verified", AgentCodingTool::Checkpoint.new(data_root: @data).verify(id).fetch("status")
        end
      end
    end
  end

  # Manual overlap and failed publication authority must leave remotes untouched.
  def test_unknown_manual_sibling_and_unavailable_publication_guard_fail_closed
    delivery_fixture do
      @coordinator.prepare("T")
      assert_equal 0, launcher(real_sandbox_probe: true).launch("T")
      install_contract("T")
      provider, guard = Provider.new, Guard.new
      manager = AgentCodingTool::DeliveryManager.new(data_root: @data, coordinator: @coordinator, provider:, guard:)
      _, run_dir = run_for("T")
      write_task(@data, id: "MANUAL", repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      @coordinator.prepare("MANUAL")
      @coordinator.start("MANUAL")
      sibling = File.binread(@store.state_path("MANUAL"))
      error = assert_raises(AgentCodingTool::InvalidState) { manager.deliver("T", run_dir:) }
      assert_match(/manual worker isolation and activity are unverified/, error.message)
      assert_empty provider.pushes
      assert_equal sibling, File.binread(@store.state_path("MANUAL"))
      @coordinator.record("MANUAL", outcome: "blocked")
      guard.deny = true
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("T", run_dir:) }
      assert_empty provider.pushes
      assert File.file?(File.join(run_dir, "delivery.json"))
    end
  end

  # A sibling's changed command logs cannot bless its advanced feature HEAD.
  def test_tampered_advanced_sibling_validation_blocks_delivery
    delivery_fixture do
      provider, guard = independent_runs
      manager = AgentCodingTool::DeliveryManager.new(data_root: @data, coordinator: @coordinator, provider:, guard:)
      _, first_dir = run_for("T")
      assert_equal "draft_pr", manager.deliver("T", run_dir: first_dir).fetch("stage")
      File.write(File.join(first_dir, "validation-0.stdout"), "forged")
      _, second_dir = run_for("B")
      assert_raises(AgentCodingTool::InvalidState) { manager.deliver("B", run_dir: second_dir) }
      assert_equal ["act/T/attempt-1"], provider.pushes
      assert_equal "IN_FLIGHT", @coordinator.status("B").fetch("status")
    end
  end

  # Automatic and explicit CLI delivery share the same verified overlap policy.
  def test_automatic_then_explicit_cli_delivery_keep_separate_task_candidates
    delivery_fixture do
      write_task(@data, id: "B", repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      %w[T B].each { |id| @coordinator.prepare(id) }
      assert_equal 0, launcher(real_sandbox_probe: true).launch("T")
      %w[T B].each { |id| install_contract(id) }
      provider, guard = Provider.new, Guard.new
      constructor = AgentCodingTool::DeliveryManager.method(:new)
      factory = ->(**options) { constructor.call(**options, provider:, guard:) }
      AgentCodingTool::DeliveryManager.stub(:new, factory) do
        assert_equal 0, launcher(real_sandbox_probe: true).launch("B", allow_write_collision: true), @err.string
        assert_equal "CANDIDATE", @coordinator.status("B").fetch("status")
        assert_equal "IN_FLIGHT", @coordinator.status("T").fetch("status")
        cli = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: @data, out: @out, err: @err)
        cli.instance_variable_set(:@coordinator, @coordinator)
        assert_equal 0, cli.run(%w[deliver T]), @err.string
        assert_equal "CANDIDATE", @coordinator.status("T").fetch("status")
      end
      assert_equal %w[act/B/attempt-1 act/T/attempt-1], provider.pushes.sort
      assert_equal @base, setup_git("rev-parse", "main", chdir: @ordinary)
    end
  end

  # Returns bytes at the supplied fixture state/source paths for refusal checks.
  # Missing evidence raises rather than treating a lost candidate as unchanged.
  def candidate_bytes(paths)
    paths.to_h { |path| [path, File.binread(path)] }
  end

  # Reuses one native ownership pair for reversible refusals, then a reservation
  # race during trusted validation. Each refusal must preserve both candidates.
  def test_overlap_refusal_matrix_preserves_sibling_and_unpublished_candidate
    delivery_fixture do
      provider, guard = independent_runs
      manager = AgentCodingTool::DeliveryManager.new(data_root: @data, coordinator: @coordinator, provider:, guard:)
      _, sibling_dir = run_for("T")
      path = File.join(sibling_dir, "handoff.json")
      original_handoff = File.binread(path)
      _, run_dir = run_for("B")
      candidate_paths = %w[T B].flat_map do |id|
        report, = run_for(id)
        [@store.state_path(id), *%w[file.txt worker-change.txt].map { |name| File.join(report.fetch("workspace"), name) }]
      end
      candidates = candidate_bytes(candidate_paths)
      mutations = [
        [/judgment_required execution evidence/, ->(row) { row["status"] = "judgment_required" }],
        [/sandbox verification is unavailable/, ->(row) { row.delete("sandbox_probe") }],
        [/worktree ownership differs/, ->(row) { row["attempt"] = 2 }],
        [/launch roots or pinned heads are unverified/, ->(row) { row["workspace"] = @ordinary }],
        [/launch roots or pinned heads are unverified/, ->(row) { row["launch_heads"].values.first["pushed_sha"] = "f" * 40 }],
        [/sibling invocation changed/, ->(row) { row["invocation_id"] = "forged-invocation" }]
      ]
      mutations.each do |message, mutation|
        altered = JSON.parse(original_handoff)
        mutation.call(altered)
        File.binwrite(path, JSON.generate(altered))
        error = assert_raises(AgentCodingTool::InvalidState) { manager.deliver("B", run_dir:) }
        assert_match message, error.message
        assert_empty provider.pushes
        assert_equal candidates, candidate_bytes(candidate_paths)
      ensure
        File.binwrite(path, original_handoff)
      end
      @terminal_liveness.unknown = true
      error = assert_raises(AgentCodingTool::InvalidState) { manager.deliver("B", run_dir:) }
      assert_match(/terminal worker liveness is uncertain/, error.message)
      assert_empty provider.pushes
      assert_equal candidates, candidate_bytes(candidate_paths)
      @terminal_liveness.unknown = false

      File.open(File.join("#{@data}-runs", "launch.lock"), File::RDWR) do |lock|
        assert lock.flock(File::LOCK_EX | File::LOCK_NB)
        error = assert_raises(AgentCodingTool::InvalidState) { manager.deliver("B", run_dir:) }
        assert_match(/another launch holds the reservation lock/, error.message)
      end
      assert_equal candidates, candidate_bytes(candidate_paths)
      write_task(@data, id: "EXTERNAL", repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      @coordinator.prepare("EXTERNAL")
      external_state = File.binread(@store.state_path("EXTERNAL"))
      original = manager.method(:run_command!)
      coordinator = @coordinator
      manager.define_singleton_method(:run_command!) do |*args|
        result = original.call(*args)
        coordinator.start("EXTERNAL")
        result
      end
      error = assert_raises(AgentCodingTool::InvalidState) { manager.deliver("B", run_dir:) }
      # Concurrent starts fail at the reservation; the separate manual-sibling
      # negative control still checks workers already in flight before delivery.
      assert_equal "reservation: launch/recovery reservation busy", error.message
      assert_equal external_state, File.binread(@store.state_path("EXTERNAL"))
      assert_equal "PREPARED", @coordinator.status("EXTERNAL").fetch("status")
      assert_empty provider.pushes
      assert_empty provider.refs
      assert_empty provider.prs
      assert_equal candidates, candidate_bytes(candidate_paths)
      assert_equal "IN_FLIGHT", @coordinator.status("B").fetch("status")
      assert File.file?(File.join(run_dir, "validation-0.stdout"))
    end
  end

  # A genuine foreground fixture worker remains alive while its sibling delivers.
  # Cancellation targets only that fixture child group and host subprocess.
  def test_automatic_delivery_while_verified_sibling_remains_running
    delivery_fixture do
      write_task(@data, id: "B", repositories: { "repo" => { "access" => "write", "path" => @ordinary } })
      %w[T B].each { |id| @coordinator.prepare(id) }
      write_fake("sleep")
      host = Process.spawn({ "PATH" => "#{@root}:#{ENV.fetch('PATH')}", "AGENT_CODING_TOOL_DATA_DIR" => @data },
        RbConfig.ruby, File.join(Dir.pwd, "bin", "agent-coding-tool"), "launch", "T", "--codex",
        out: File.join(@root, "host-out"), err: File.join(@root, "host-err"))
      child = nil
      begin
        running = Timeout.timeout(8) do
          loop do
            paths = Dir.glob("#{@data}-runs/T/*/handoff.json")
            report = JSON.parse(File.binread(paths.first)) unless paths.empty?
            break report if report && report["status"] == "running" && File.file?(File.join(@root, "worker-pid"))
            sleep 0.01
          end
        end
        child = running.fetch("child_pid")
        sibling_state = File.binread(@store.state_path("T"))
        install_contract("B")
        write_fake("success")
        provider, guard = Provider.new, Guard.new
        constructor = AgentCodingTool::DeliveryManager.method(:new)
        factory = ->(**options) { constructor.call(**options, provider:, guard:) }
        AgentCodingTool::DeliveryManager.stub(:new, factory) do
          assert_equal 0, Timeout.timeout(20) {
            launcher(real_sandbox_probe: true).launch("B", allow_write_collision: true)
          }, @err.string
        end
        assert_equal "CANDIDATE", @coordinator.status("B").fetch("status")
        assert_equal "running", run_for("T").first.fetch("status")
        assert_equal sibling_state, File.binread(@store.state_path("T"))
        assert_equal ["act/B/attempt-1"], provider.pushes
      ensure
        Process.kill("TERM", -child) rescue Errno::ESRCH if child
        begin
          Timeout.timeout(5) { Process.waitpid(host) }
        rescue Timeout::Error
          Process.kill("TERM", host) rescue Errno::ESRCH
          Process.waitpid(host) rescue Errno::ECHILD
        end
      end
    end
  end
end
