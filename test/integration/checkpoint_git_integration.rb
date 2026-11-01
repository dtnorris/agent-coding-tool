# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../recovery_observations"
require_relative "../support/memory_git/broker"
require "minitest/mock"
require_relative "../support/checkpoint_processes"

# Modeled history, physical preservation and strict launch-binding refusals.
# All repositories, evidence, processes and candidate files are fixture-owned.
class CheckpointTest < Minitest::Test
  include TestHelpers
  include RecoveryObservations
  include CheckpointProcesses

  # Uses the real public CLI and local bare remote for the preserved-attempt
  # journey; cold verification proves no process-local lifecycle workaround.
  def test_forced_gate_public_journey_preserves_attempt_and_lifecycle_bytes
    fixture do |root, data, ordinary, workspace, _base|
      task_path = File.join(data, "tasks", "T.yml")
      task = YAML.safe_load_file(task_path)
      task.fetch("repositories").fetch("repo")["path"] = ordinary
      File.write(task_path, YAML.dump(task))
      File.write(File.join(data, "config.yml"), YAML.dump("repo_root" => root))
      state_path = File.join(data, "state", "T.yml")
      File.unlink(state_path)
      out, err = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: root, data_root: data, out: out, err: err)
      assert_equal 0, cli.run(%w[prepare T]), err.string
      assert_equal 0, cli.run(%w[start T]), err.string
      assert_equal 0, cli.run(["checkpoint", "record", "T", "--workspace", workspace]), err.string
      assert_equal 0, cli.run(["checkpoint", "verify", "T", "--workspace", workspace]), err.string
      original = YAML.safe_load_file(state_path)
      attempt = original.dig("checkpoint", "attempt")
      checkpoint_dir = File.dirname(original.dig("checkpoint", "record_path"))
      original_evidence = Dir.glob(File.join(checkpoint_dir, "*")).to_h { |path| [path, File.binread(path)] }
      assert_equal 0, cli.run(%w[record T needs_judgment --summary review]), err.string
      lifecycle = File.binread(state_path)
      marker = File.join(root, "validated")
      arguments = ["checkpoint", "gate", "T", "--workspace", workspace, "--", *gate_command("write", marker, "checked")]
      assert_equal 2, cli.run(arguments.dup), err.string
      refute File.exist?(marker)
      arguments.insert(3, "--force")
      assert_equal 0, cli.run(arguments.dup), err.string
      assert_equal "checked", File.read(marker)
      assert_equal lifecycle, File.binread(state_path)
      receipt = JSON.parse(File.binread(Dir.glob(File.join(checkpoint_dir, "gate-*.finished.json")).fetch(0)))
      assert_equal attempt, receipt.fetch("attempt")
      assert_equal "invocation_local_force", receipt.dig("lifecycle_exception", "consent")
      assert_equal "passed", receipt.fetch("candidate_validation")
      original_evidence.each { |path, bytes| assert_equal bytes, File.binread(path) }
      cold_out, cold_err, cold_status = checkpoint_cli(root, { "AGENT_CODING_TOOL_DATA_DIR" => data },
        "checkpoint", "verify", "T", "--workspace", workspace)
      assert cold_status.success?, cold_err
      assert_equal "verified", JSON.parse(cold_out).fetch("status")
      %w[failed blocked candidate_complete complete].each do |outcome|
        assert_equal 0, cli.run(["record", "T", outcome]), err.string
        bytes = File.binread(state_path)
        assert_equal 0, cli.run(arguments.dup), err.string
        assert_equal bytes, File.binread(state_path)
        assert_equal attempt, YAML.safe_load_file(state_path).dig("checkpoint", "attempt")
      end
      assert_equal 0, cli.run(%w[start T --force]), err.string
      new_state = YAML.safe_load_file(state_path)
      refute new_state.key?("checkpoint")
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data, err: err)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T", workspace: workspace) }
      original_evidence.each { |path, bytes| assert_equal bytes, File.binread(path) }
    end
  end

  # Negative gate controls retain lifecycle bytes and exact process outcomes.
  # Receipt failures are mandatory failures even after successful child execution.
  def test_forced_gate_failures_preserve_bytes_results_and_required_audit
    fixture do |root, data, _ordinary, workspace, _base|
      diagnostics = StringIO.new
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data, err: diagnostics)
      evidence = checkpoint.record("T", workspace: workspace)
      state_path = File.join(data, "state", "T.yml")
      state = YAML.safe_load_file(state_path)
      state.delete("started_at")
      state["result"] = { "outcome" => "needs_judgment" }
      AgentCodingTool::StateStore.new(File.dirname(state_path)).write("T", state)
      lifecycle = File.binread(state_path)
      directory = File.dirname(evidence.fetch("path"))
      AgentCodingTool::ReservationLock.synchronize(data) do
        assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"), force: true)
        end
        assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T", workspace: workspace) }
      end
      pointer = File.join(directory, "current.json")
      File.rename(pointer, "#{pointer}.saved")
      begin
        assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"), force: true)
        end
      ensure
        File.rename("#{pointer}.saved", pointer)
      end
      assert_equal lifecycle, File.binread(state_path)
      [[9, gate_command("exit", "9")],
       [128 + Signal.list.fetch("TERM"), gate_command("signal")],
       [127, [File.join(root, "no-git-missing-executable"), "--missing-executable-probe"]]].each do |expected, command|
        assert_equal expected, checkpoint.gate("T", workspace: workspace, command: command, force: true)
        assert_equal lifecycle, File.binread(state_path)
      end
      results = Dir.glob(File.join(directory, "gate-*.finished.json")).map { |path| JSON.parse(File.binread(path)) }
      assert_equal %w[exited failed_to_start signal], results.map { |receipt| receipt.dig("command_outcome", "status") }.sort
      assert results.all? { |receipt| receipt.fetch("candidate_validation") == "failed" }
      writer = checkpoint.method(:write_once!)
      marker = File.join(root, "child-ran")
      failure = lambda do |path, bytes|
        raise IOError, "injected receipt failure" if path.end_with?(".started.json")
        writer.call(path, bytes)
      end
      checkpoint.stub(:write_once!, failure) do
        assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("write", marker, "ran"), force: true)
        end
      end
      refute File.exist?(marker)
      failure = lambda do |path, bytes|
        raise IOError, "injected final receipt failure" if path.end_with?(".finished.json")
        writer.call(path, bytes)
      end
      checkpoint.stub(:write_once!, failure) do
        error = assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "7"), force: true)
        end
        assert_match(/"exit_code"\s*=>\s*7/, error.message)
      end
      commands = Dir.glob(File.join(directory, "gate-*.command.json")).map { |path| JSON.parse(File.binread(path)) }
      assert commands.any? { |receipt| receipt.dig("command_outcome", "exit_code") == 7 }
      File.write(File.join(workspace, "changed.txt"), "tampered\n")
      assert_raises(AgentCodingTool::InvalidState) do
        checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"), force: true)
      end
      assert_equal lifecycle, File.binread(state_path)
      assert_equal "verified", YAML.safe_load_file(state_path).dig("checkpoint", "status")
      # A successful child that changes candidate bytes fails the post-check;
      # the stale observation belongs to fresh receipts, not lifecycle state.
      File.write(File.join(workspace, "changed.txt"), "updated\n")
      assert_raises(AgentCodingTool::InvalidState) do
        checkpoint.gate("T", workspace: workspace,
          command: gate_command("write", "changed.txt", "changed by command"), force: true)
      end
      assert_equal lifecycle, File.binread(state_path)
      File.write(File.join(workspace, "changed.txt"), "updated\n")
      state["id"] = "foreign"
      File.write(state_path, YAML.dump(state))
      assert_raises(AgentCodingTool::InvalidState) do
        checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"), force: true)
      end
      File.binwrite(state_path, lifecycle)
      File.binwrite(evidence.fetch("path"), "tampered artifact")
      assert_raises(AgentCodingTool::InvalidState) do
        checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"), force: true)
      end
      assert_equal lifecycle, File.binread(state_path)
    end
  end

  # A real owned fixture process and sibling state survive metadata declarations.
  # External activity continues to block validation/execution after forced COMPLETE.
  def test_force_metadata_does_not_retire_live_fixture_or_sibling
    fixture do |root, data, _ordinary, workspace, _base|
      write_task(data, id: "S")
      states = AgentCodingTool::StateStore.new(File.join(data, "state"))
      states.write("S", { "id" => "S", "custom" => "sibling" })
      sibling = File.binread(states.state_path("S"))
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data, err: StringIO.new)
      checkpoint.record("T", workspace: workspace)
      coordinator = AgentCodingTool::CLI.new(root: Dir.pwd, data_root: data,
        out: StringIO.new, err: StringIO.new).send(:coordinator)
      reader, writer = IO.pipe
      release_reader, release_writer = IO.pipe
      approval = ChildProcesses.permit("manual_worker", arguments: [File.join(root, "live-sentinel"), "20"])
      pid = File.open(File::NULL, "w") do |null|
        NoGitExecution.with_permit(approval) do
          Process.spawn(approval.environment, *approval.argv, in: release_reader, out: writer, err: null)
        end
      end
      release_reader.close
      writer.close
      begin
        assert IO.select([reader], nil, nil, 5), "fixture worker did not start"
        assert_equal "ready\n", reader.gets
        activity = coordinator.external_activity.report("T", reporter: "fixture", kind: "worker", identifier: "fixture-#{pid}")
        original_activity = coordinator.external_activity.show("T")
        coordinator.record("T", outcome: "complete", force: true)
        assert_equal "COMPLETE", coordinator.status("T").fetch("status")
        assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"), force: true)
        end
        assert_equal 1, Process.kill(0, pid)
        assert_equal original_activity, coordinator.external_activity.show("T")
        coordinator.reset("T", force: true)
        assert_equal original_activity, coordinator.external_activity.show("T")
        assert_equal sibling, File.binread(states.state_path("S"))
        assert_equal 1, Process.kill(0, pid)
        assert activity.fetch("active")
      ensure
        reader.close
        release_writer.write("R")
        release_writer.close
        assert_equal 0, Timeout.timeout(2) { Process.wait2(pid).last.exitstatus }
      end
    end
  end

  # Executes a cold public checkpoint against the same leased mutable world.
  # Broker lifetime is bounded to the command and closed even on failure.
  def checkpoint_cli(root, environment, *arguments)
    broker = MemoryGit::Broker.new(world: @checkpoint_world, directory: root, case_id: 'checkpoint-public')
    ChildProcesses.capture('checkpoint_cli', arguments: arguments, environment: environment, endpoint: broker.endpoint, seconds: 10)
  ensure
    broker&.close
  end

  # Returns immutable baseline files; every case creates fresh mutable authority.
  # No native Git storage, repository identity or persistent seed directory exists.
  def self.seed
    MemoryGit::Template.files({ "changed.txt" => "old\n", "removed.txt" => "remove\n", "renamed.txt" => "rename\n" })
  end
  # Executes only this fixture's modeled setup authority; returns stripped output.
  # Unknown roots/forms and missing authority fail without a native fallback.
  def git(*args, chdir: nil)
    raise MemoryGit::Mismatch, "no checkpoint setup authority" unless @checkpoint_world
    out, err, status = @checkpoint_world.call(["git", *args], cwd: chdir)
    assert status.success?, err
    out.strip
  end

  # Yields disposable task/state, candidate files and modeled baseline identity.
  # Native-family cases use fresh modeled repository authority; refusal-only
  # cases declare exact reads at the call site. Setup/model errors
  # propagate and all fixture files are removed afterward.
  def fixture(native: true)
    Dir.mktmpdir("act-checkpoint-test-") do |root|
      root = File.realpath(root)
      ordinary = File.join(root, "ordinary")
      remote = File.join(root, "remote.git")
      workspace = File.join(root, "workspace")
      data = File.join(root, "data")
      FileUtils.mkdir_p(File.join(data, "tasks"))
      world = native ? MemoryGit::PatchWorld.new(root: root) : nil
      @checkpoint_world = world
      if world
        # Exact native-generated binary bytes and independent before/after trees
        # are stored as data; tests never invoke a binary codec or native Git.
        %w[checkpoint-tracked-metadata checkpoint-legacy-metadata].each do |name|
          descriptor = JSON.parse(File.binread(File.expand_path("../support/memory_git/fixtures/#{name}.json", __dir__)))
          trees = %w[before after].to_h do |side|
            [side.to_sym, descriptor.fetch(side).to_h { |entry|
              [MemoryGit::PatchCase.hex_bytes(entry.fetch('path_hex')),
               MemoryGit::Entry.new(MemoryGit::PatchCase.hex_bytes(entry.fetch('bytes_hex')), mode: entry.fetch('mode'))] }]
          end
          world.register_patch(MemoryGit::PatchCase.new(**trees,
            bytes: descriptor.fetch('patch_base64').unpack1('m0'), sha256: descriptor.fetch('sha256'),
            paths: descriptor.fetch('paths_hex').map { |hex| MemoryGit::PatchCase.hex_bytes(hex) },
            numstat: MemoryGit::PatchCase.hex_bytes(descriptor.fetch('numstat_hex')), stat: descriptor.fetch('stat')))
        end
      end
      previous_tmpdir = ENV['TMPDIR']
      ENV['TMPDIR'] = root
      MemoryGit::Session.with(world) do
        if native
          checkout, = memory_repository(world, path: ordinary, remote: remote, template: self.class.seed)
          @checkpoint_checkout = checkout
          base = checkout.head
          world.copy(checkout, path: workspace)
          git("checkout", "--detach", base, chdir: workspace)
        else
          base = "a" * 40
          FileUtils.mkdir_p([ordinary, workspace])
          File.write(File.join(workspace, "removed.txt"), "remove\n")
          File.write(File.join(workspace, "renamed.txt"), "rename\n")
        end
        File.write(File.join(workspace, "changed.txt"), "updated\n")
        File.write(File.join(workspace, "new.txt"), "untracked\n")
        File.unlink(File.join(workspace, "removed.txt"))
        File.rename(File.join(workspace, "renamed.txt"), File.join(workspace, "moved.txt"))
        write_task(data, id: "T", repositories: { "repo" => { "access" => "write", "path" => ordinary } })
        snapshot = { "repo" => {
          "path" => ordinary, "remote" => "origin", "remote_url" => remote,
          "branch" => "main", "pushed_sha" => base
        } }
        state = { "id" => "T", "prepared_at" => Time.now.utc.iso8601,
                  "started_at" => Time.now.utc.iso8601, "snapshot" => snapshot }
        AgentCodingTool::StateStore.new(File.join(data, "state")).write("T", state)
        yield root, data, ordinary, workspace, base
      end
    ensure
      ENV['TMPDIR'] = previous_tmpdir
      world&.verify!
    end
  end

  # Supplies only the two exact workspace identity reads before launch binding.
  # Returns the block's result, verifies empty production environment overrides,
  # and fails on any extra/missing command. Files and production checks stay real.
  def with_workspace_identity(workspace, base, remote)
    replay = GitContract::Replay.new([
      recovery_observation(workspace, "git", "rev-parse", "HEAD", stdout: "#{base}\n".b),
      recovery_observation(workspace, "git", "remote", "get-url", "origin", stdout: "#{remote}\n".b)
    ])
    capture = lambda do |environment, *argv, **options|
      assert_equal({}, environment)
      replay.capture3(*argv, **options)
    end
    result = Open3.stub(:capture3, capture) { yield }
    assert replay.verify!
    result
  end

  # Preserves all candidate change kinds, deletes the workspace and reconstructs
  # its exact files in a bounded fresh Ruby process using production recovery.
  def test_record_verifies_complete_changes_and_fresh_process_recovers_without_workspace
    fixture do |root, data, _ordinary, workspace, base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      evidence = checkpoint.record("T", workspace: workspace)
      assert_equal %w[A A D D M], evidence.fetch("changed_files").map { |row| row.fetch("status") }.sort
      assert_equal %w[changed.txt moved.txt new.txt removed.txt renamed.txt], evidence.fetch("changed_files").map { |row| row.fetch("path") }.sort
      assert_equal base, evidence.dig("authority", "pushed_sha")
      assert_equal File.size(evidence.fetch("path")), evidence.fetch("bytes")
      assert_equal Digest::SHA256.file(evidence.fetch("path")).hexdigest, evidence.fetch("sha256")
      coordinator = AgentCodingTool::Coordinator.new(
        task_store: AgentCodingTool::TaskStore.new(File.join(data, "tasks")),
        state_store: AgentCodingTool::StateStore.new(File.join(data, "state")),
        repo_inspector: TestHelpers::FakeInspector.new(heads: { "repo" => base }, remote_urls: { "repo" => File.join(root, "remote.git") }),
        prompt_renderer: AgentCodingTool::PromptRenderer.new, prompt_root: File.join(data, "state", "prompts")
      )
      assert_equal "IN_FLIGHT", coordinator.status("T").fetch("status")
      FileUtils.remove_entry(workspace)
      coordinator.record("T", outcome: "candidate_complete")
      assert_equal "verified", checkpoint.verify("T").fetch("status")
      destination = File.join(root, "recovered")
      fresh = AgentCodingTool::Checkpoint.new(data_root: data)
      assert_raises(AgentCodingTool::InvalidState) { fresh.recover("T", destination: destination) }
      refute File.exist?(destination)
      broker = MemoryGit::Broker.new(world: @checkpoint_world, directory: root, case_id: 'checkpoint-recovery')
      begin
        stdout, stderr, status = ChildProcesses.capture('cold_cli',
          arguments: ['checkpoint', 'recover', 'T', '--destination', destination, '--confirm-disconnected'],
          environment: { 'AGENT_CODING_TOOL_DATA_DIR' => data }, endpoint: broker.endpoint, seconds: 5)
      ensure
        broker.close
      end
      assert status.success?, stderr
      assert_equal "reconstructed", JSON.parse(stdout).fetch("status")
      assert_equal "updated\n", File.read(File.join(destination, "changed.txt"))
      assert_equal "untracked\n", File.read(File.join(destination, "new.txt"))
      assert_equal "rename\n", File.read(File.join(destination, "moved.txt"))
      refute File.exist?(File.join(destination, "removed.txt"))
    end
  end

  # Refuses incomplete/foreign artifacts without changing good evidence; restores
  # the corrupted patch and reruns the native completeness verification.
  def test_incomplete_and_symlinked_artifacts_cannot_replace_good_checkpoint
    fixture do |root, data, _ordinary, workspace, _base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      old = checkpoint.record("T", workspace: workspace)
      original_patch = File.binread(old.fetch("path"))
      directory = File.dirname(old.fetch("path"))
      original_evidence = Dir.children(directory).to_h { |name| [name, File.binread(File.join(directory, name))] }
      truncated = File.join(root, "truncated.patch")
      File.binwrite(truncated, File.binread(old.fetch("path"))[0, 20])
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace, artifact: truncated) }
      tracked_only = File.join(root, "tracked-only.patch")
      File.binwrite(tracked_only, @checkpoint_world.call(%w[git diff --binary HEAD], cwd: workspace).stdout)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace, artifact: tracked_only) }
      empty = File.join(root, "empty.patch")
      File.binwrite(empty, "")
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace, artifact: empty) }
      link = File.join(root, "link.patch")
      File.symlink(old.fetch("path"), link)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace, artifact: link) }
      assert_equal original_evidence, Dir.children(directory).to_h { |name| [name, File.binread(File.join(directory, name))] }
      state = AgentCodingTool::StateStore.new(File.join(data, "state")).load("T")
      assert_equal "verified", state.dig("checkpoint", "status")
      begin
        File.binwrite(old.fetch("path"), "corrupt")
        error = assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T") }
        assert_includes error.message, "checksum/length mismatch"
        assert_equal "corrupt", File.binread(old.fetch("path"))
      ensure
        File.binwrite(old.fetch("path"), original_patch)
      end
      assert_equal old.fetch("sha256"), checkpoint.verify("T", workspace: workspace).fetch("record").fetch("sha256")
      assert_equal original_evidence, Dir.children(directory).to_h { |name| [name, File.binread(File.join(directory, name))] }
    end
  end

  def test_stale_checkpoint_blocks_expensive_command_then_refreshes
    fixture do |root, data, _ordinary, workspace, _base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      marker = File.join(root, "ran")
      assert_raises(AgentCodingTool::InvalidState) do
        checkpoint.gate("T", workspace: workspace, command: gate_command("touch", marker))
      end
      refute File.exist?(marker)
      old = checkpoint.record("T", workspace: workspace)
      File.write(File.join(workspace, "new.txt"), "changed again\n")
      assert_raises(AgentCodingTool::InvalidState) do
        checkpoint.gate("T", workspace: workspace, command: gate_command("touch", marker))
      end
      refute File.exist?(marker)
      assert_equal "stale", AgentCodingTool::StateStore.new(File.join(data, "state")).load("T").dig("checkpoint", "status")
      checkpoint.stub(:verify_patch!, ->(*) { raise AgentCodingTool::InvalidState, "injected verification interruption" }) do
        assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace) }
      end
      assert_equal old.fetch("record_file"), checkpoint.verify("T").fetch("record").fetch("record_file")
      refreshed = checkpoint.record("T", workspace: workspace)
      refute_equal old.fetch("sha256"), refreshed.fetch("sha256")
      assert_equal old.fetch("record_file"), refreshed.fetch("previous_record")
      out, err = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: root, data_root: data, out: out, err: err)
      assert_equal 0, cli.run(["checkpoint", "gate", "T", "--workspace", workspace, "--", *gate_command("touch", marker)]), err.string
      assert File.file?(marker)
      assert_raises(AgentCodingTool::InvalidState) do
        checkpoint.gate("T", workspace: workspace, command: gate_command("write", "new.txt", "changed"))
      end
      assert_equal "stale", AgentCodingTool::StateStore.new(File.join(data, "state")).load("T").dig("checkpoint", "status")
    end
  end

  # Exercises public record/gate in cold CLI processes, then reads retained JSON
  # in another interpreter. Checks binary console bytes, declared versus reported
  # facts and changed conditions without treating a pass as reproduction.
  def test_public_gate_receipts_bind_candidate_and_distinguish_conditions
    fixture do |root, data, _ordinary, workspace, base|
      cli = File.expand_path("../../bin/agent-coding-tool", __dir__)
      environment = { "AGENT_CODING_TOOL_DATA_DIR" => data, "SEED" => "51565",
                      "TESTOPTS" => "--name subset", "ACT_RECEIPT_SECRET" => "secret-canary" }
      stdout, stderr, status = checkpoint_cli(root, environment,
        "checkpoint", "record", "T", "--workspace", workspace)
      assert status.success?, stderr
      record = JSON.parse(stdout)
      directory = File.dirname(record.fetch("path"))
      report_path = File.join(directory, "first.observation.json")
      command = gate_command("observation", report_path)
      stdout, stderr, status = checkpoint_cli(root, environment,
        "checkpoint", "gate", "T", "--workspace", workspace,
        "--requested-seed", "51565", "--requested-selection", "subset", "--observations", report_path, "--", *command)
      assert status.success?, stderr
      assert_equal "seed=31046\n\x00\xff0\n".b, stdout.b
      assert_equal "\x80error-stream\x00\n".b, stderr.b.gsub(/^Checkpoint gate receipt: .*\n/n, "")
      reader = 'puts JSON.generate(Dir.glob(File.join(ARGV.fetch(0), "gate-*.finished.json")).map { |path| JSON.parse(File.binread(path)) })'
      stdout, stderr, status = ChildProcesses.capture("checkpoint_validator", arguments: ["receipts", directory])
      assert status.success?, stderr
      receipt = JSON.parse(stdout).fetch(0)
      assert_equal AgentCodingTool::Checkpoint::GATE_SCHEMA, receipt.fetch("schema_version")
      assert_equal record.values_at("task_id", "attempt", "repository", "authority"), receipt.values_at("task_id", "attempt", "repository", "authority")
      assert_equal base, receipt.dig("authority", "pushed_sha")
      assert_equal record.fetch("record_file"), receipt.dig("candidate", "record_file")
      assert_equal record.fetch("sha256"), receipt.dig("candidate", "sha256")
      assert_equal command, receipt.fetch("argv")
      assert_equal workspace, receipt.fetch("cwd")
      assert_equal 51565, receipt.dig("requested", "seed")
      assert_equal 31046, receipt.dig("observed", "seed")
      assert_equal "command_report", receipt.dig("observed", "source", "kind")
      assert_equal Digest::SHA256.file(report_path).hexdigest, receipt.dig("observed", "source", "sha256")
      assert_equal 3, receipt.dig("observed", "summary", "assertions")
      assert_equal "passed", receipt.fetch("candidate_validation")
      assert_equal "verified", receipt.fetch("post_check")
      assert_equal({ "status" => "not_captured" }, receipt.fetch("output"))
      before = Dir.glob(File.join(directory, "gate-*.json")).to_h { |path| [path, File.binread(path)] }
      temporary = File.join(root, "alternate-tmp")
      Dir.mkdir(temporary)
      changed = environment.merge("TMPDIR" => temporary, "TESTOPTS" => "--name other")
      stdout, stderr, status = checkpoint_cli(root, changed,
        "checkpoint", "gate", "T", "--workspace", workspace, "--requested-selection", "other", "--", *gate_command("exit", "0"))
      assert status.success?, stderr
      receipts = Dir.glob(File.join(directory, "gate-*.finished.json")).map { |path| JSON.parse(File.binread(path)) }
      assert_equal 2, receipts.length
      other = receipts.find { |row| row.fetch("invocation_id") != receipt.fetch("invocation_id") }
      assert_equal receipt.fetch("candidate"), other.fetch("candidate")
      refute_equal receipt.dig("settings", "TMPDIR"), other.dig("settings", "TMPDIR")
      refute_equal receipt.dig("settings", "TESTOPTS"), other.dig("settings", "TESTOPTS")
      assert_equal "other", other.dig("requested", "selection")
      assert_equal({ "status" => "not_observed", "seed" => nil, "selection" => nil, "summary" => nil }, other.fetch("observed"))
      before.each { |path, bytes| assert_equal bytes, File.binread(path) }
      Dir.glob(File.join(directory, "gate-*.json")).each do |path|
        refute_includes File.binread(path), "secret-canary"
        assert_equal 0, File.stat(path).mode & 0o077
      end
    end
  end

  # Compares native system outcomes and binary bytes with the original gate's
  # failure rule, then proves post-check failures cannot turn a command pass into
  # candidate validation. All signals target only the finite fixture child.
  def test_gate_receipts_preserve_process_failures_and_candidate_checks
    fixture do |root, data, _ordinary, workspace, _base|
      diagnostics = StringIO.new
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data, err: diagnostics)
      record = checkpoint.record("T", workspace: workspace)
      directory = File.dirname(record.fetch("path"))
      commands = [
        gate_command("binary"),
        gate_command("signal"),
        [File.join(root, "no-git-missing-executable"), "--missing-executable-probe"]
      ]
      commands.each_with_index do |command, index|
        # Original command failure rule; candidate verification is exercised by
        # the real gate, including Git calls that overwrite Ruby's $? afterward.
        original = lambda do
          success = system(*command, chdir: workspace)
          exit_code = $?.exitstatus if $?
          raise AgentCodingTool::InvalidState, "checkpoint: validation command failed (#{exit_code || 'unavailable'})" unless success
        end
        expected_error = nil
        expected_stdout, expected_stderr = capture_subprocess_io { expected_error = assert_raises(AgentCodingTool::InvalidState, &original) }
        actual_error = nil
        actual_stdout, actual_stderr = capture_subprocess_io do
          actual_error = assert_raises(AgentCodingTool::InvalidState) { checkpoint.gate("T", workspace: workspace, command: command) }
        end
        assert_equal expected_error.message, actual_error.message
        assert_equal expected_stdout.b, actual_stdout.b
        assert_equal expected_stderr.b, actual_stderr.b
        receipt = Dir.glob(File.join(directory, "gate-*.finished.json")).map { |path| JSON.parse(File.binread(path)) }.find { |row| row.fetch("argv") == command }
        assert_equal %w[exited signal failed_to_start].fetch(index), receipt.dig("command_outcome", "status")
        assert_equal 7, receipt.dig("command_outcome", "exit_code") if index.zero?
        assert_equal Signal.list.fetch("TERM"), receipt.dig("command_outcome", "signal") if index == 1
        assert_equal "verified", receipt.fetch("post_check")
        assert_equal "failed", receipt.fetch("candidate_validation")
      end
      # An identical patch in a replacement checkpoint is still another record.
      replacement = lambda do |*argv, **options|
        checkpoint.record("T", workspace: workspace)
        Kernel.system(*argv, **options)
      end
      checkpoint.stub(:system, replacement) do
        error = assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"))
        end
        assert_includes error.message, "candidate changed during validation"
      end
      command = gate_command("write", "new.txt", "mutated")
      error = assert_raises(AgentCodingTool::InvalidState) { checkpoint.gate("T", workspace: workspace, command: command) }
      assert_includes error.message, "stale implementation"
      receipt = Dir.glob(File.join(directory, "gate-*.finished.json")).map { |path| JSON.parse(File.binread(path)) }.find { |row| row.fetch("argv") == command }
      assert_equal true, receipt.dig("command_outcome", "success")
      assert_equal "failed", receipt.fetch("post_check")
      assert_equal "failed", receipt.fetch("candidate_validation")
      marker = File.join(root, "must-not-run")
      refused = gate_command("touch", marker)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.gate("T", workspace: workspace, command: refused) }
      refute File.exist?(marker)
      receipt = Dir.glob(File.join(directory, "gate-*.finished.json")).map { |path| JSON.parse(File.binread(path)) }.find { |row| row.fetch("argv") == refused }
      assert_equal "not_run", receipt.dig("command_outcome", "status")
      assert_equal "failed", receipt.fetch("pre_check")
      assert_equal "not_checked", receipt.fetch("post_check")
    end
  end

  # Injects receipt sync/write errors and command exceptions at explicit seams;
  # original errors and return values survive, and interrupted facts stay unknown.
  def test_gate_receipt_write_failure_cannot_mask_primary_failure_or_claim_durability
    fixture do |_root, data, _ordinary, workspace, _base|
      diagnostics = StringIO.new
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data, err: diagnostics)
      record = checkpoint.record("T", workspace: workspace)
      directory = File.dirname(record.fetch("path"))
      write_once = checkpoint.method(:write_once!)
      failing_receipt = lambda do |path, bytes|
        raise IOError, "injected" if File.basename(path).start_with?("gate-")
        write_once.call(path, bytes)
      end
      checkpoint.stub(:write_once!, failing_receipt) do
        assert_equal 0, checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"))
        error = assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "8"))
        end
        assert_equal "checkpoint: validation command failed (8)", error.message
        File.write(File.join(workspace, "new.txt"), "changed")
        error = assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"))
        end
        assert_includes error.message, "stale implementation"
      end
      assert_empty Dir.glob(File.join(directory, "gate-*.json"))
      assert_includes diagnostics.string, "crash durability unconfirmed"
      refute_includes diagnostics.string, "Checkpoint gate receipt:"
      File.write(File.join(workspace, "new.txt"), "untracked\n")
      [Interrupt.new("injected"), Errno::ENOENT.new("injected")].each do |failure|
        checkpoint.stub(:system, ->(*) { raise failure }) do
          actual = assert_raises(failure.class) { checkpoint.gate("T", workspace: workspace, command: ["unused"]) }
          assert_same failure, actual
        end
      end
      receipts = Dir.glob(File.join(directory, "gate-*.finished.json")).map { |path| JSON.parse(File.binread(path)) }
      assert_equal %w[failed_to_start incomplete_or_unknown], receipts.map { |row| row.dig("command_outcome", "status") }.sort
      assert receipts.all? { |row| row.fetch("post_check") == "not_checked" }
      starts = Dir.glob(File.join(directory, "gate-*.started.json")).map { |path| JSON.parse(File.binread(path)) }
      assert starts.all? { |row| row.dig("command_outcome", "status") == "incomplete_or_unknown" && row.fetch("finished_at").nil? }
      # A directory sync failure can leave bytes behind without durable success.
      sync_failure = lambda do |path, bytes|
        write_once.call(path, bytes)
        raise NotImplementedError if File.basename(path).start_with?("gate-")
      end
      diagnostics.truncate(0)
      diagnostics.rewind
      checkpoint.stub(:write_once!, sync_failure) do
        assert_equal 0, checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"))
      end
      assert_includes diagnostics.string, "crash durability unconfirmed"
      refute_includes diagnostics.string, "Checkpoint gate receipt:"
    end
  end

  # Refuses stale/foreign observation inputs before execution and treats missing,
  # unsafe or unsupported command reports as unknown, never retaining their text.
  def test_gate_observation_inputs_are_fresh_private_and_narrow
    fixture do |root, data, _ordinary, workspace, _base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data, err: StringIO.new)
      record = checkpoint.record("T", workspace: workspace)
      directory = File.dirname(record.fetch("path"))
      reused = File.join(directory, "reused.observation.json")
      File.write(reused, "secret-canary", mode: "wx", perm: 0o600)
      link = File.join(directory, "link.observation.json")
      File.symlink(reused, link)
      marker = File.join(root, "must-not-run")
      [reused, link, File.join(root, "foreign.observation.json")].each do |path|
        assert_raises(AgentCodingTool::InvalidState) { checkpoint.gate("T", workspace: workspace, command: gate_command("touch", marker), observations: path) }
      end
      refute File.exist?(marker)
      absent = File.join(directory, "absent.observation.json")
      assert_equal 0, checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"), observations: absent)
      invalid = File.join(directory, "invalid.observation.json")
      assert_equal 0, checkpoint.gate("T", workspace: workspace, observations: invalid,
        command: gate_command("invalid", invalid))
      receipts = Dir.glob(File.join(directory, "gate-*.finished.json")).map { |path| JSON.parse(File.binread(path)) }
      assert_equal 3, receipts.count { |row| row.dig("command_outcome", "status") == "not_run" }
      assert_equal 2, receipts.count { |row| row.dig("observed", "status") == "unavailable_or_invalid" }
      receipts.each { |row| assert_nil row.dig("observed", "seed") }
      # The invocation argv is exact; only the sidecar's unchecked content is excluded.
      refute receipts.any? { |row| row.fetch("observed").to_json.include?("secret-canary") }
      state = AgentCodingTool::StateStore.new(File.join(data, "state")).load("T")
      fifo = File.join(directory, "fifo.observation.json")
      File.mkfifo(fifo, 0o600)
      File.chmod(0o644, reused)
      oversized = File.join(directory, "oversized.observation.json")
      File.write(oversized, " " * 8193, mode: "wx", perm: 0o600)
      [fifo, link, reused, oversized].each do |path|
        assert_equal "unavailable_or_invalid", checkpoint.send(:gate_observations, path, "T", state).fetch("status")
      end
      File.chmod(0o755, directory)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.gate("T", workspace: workspace, command: gate_command("touch", marker)) }
      refute File.exist?(marker)
    end
  end

  # Keeps the missing prepared-object native destination alongside checkpoint
  # baseline/evidence refusal. Every failed operation preserves fixture resources.
  def test_wrong_baseline_and_foreign_or_symlinked_evidence_fail_closed
    fixture do |root, data, ordinary, workspace, _base|
      ownership = File.join(root, "missing-object.json")
      visible = File.join(root, "worktrees")
      error = assert_raises(AgentCodingTool::InvalidState) do
        AgentCodingTool::WorktreeManager.new(root: visible, record_path: ownership).create(
          task_id: "M", attempt: 1, task: { "repositories" => { "repo" => { "access" => "write" } } },
          snapshot: { "repo" => { "path" => ordinary, "remote" => "origin",
            "remote_url" => File.join(root, "remote.git"), "branch" => "main", "pushed_sha" => "f" * 40 } }
        )
      end
      assert_includes error.message, "Local repo repo is missing required commit #{'f' * 40}"
      refute File.exist?(ownership)
      refute File.exist?(File.join(visible, "M", "repo"))
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      record = checkpoint.record("T", workspace: workspace)
      git("add", "-A", chdir: workspace)
      git("commit", "-m", "unexpected head", chdir: workspace)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace) }
      assert_equal record.fetch("sha256"), checkpoint.verify("T").fetch("record").fetch("sha256")
      original = File.binread(record.fetch("path"))
      File.unlink(record.fetch("path"))
      foreign = File.join(root, "foreign.patch")
      File.binwrite(foreign, original)
      File.symlink(foreign, record.fetch("path"))
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T") }
      marker = File.join(root, "must-not-run")
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.gate("T", workspace: workspace, command: gate_command("touch", marker)) }
      refute File.exist?(marker)
    end
  end

  def test_multiple_writers_fail_closed
    with_workspace do |data|
      write_task(data, id: "T", repositories: {
        "one" => { "access" => "write" }, "two" => { "access" => "write" }
      })
      snapshot = %w[one two].to_h do |name|
        [name, { "path" => data, "remote" => "origin", "remote_url" => "test",
                 "branch" => "main", "pushed_sha" => "a" * 40 }]
      end
      AgentCodingTool::StateStore.new(File.join(data, "state")).write("T", {
        "id" => "T", "prepared_at" => Time.now.utc.iso8601,
        "started_at" => Time.now.utc.iso8601, "snapshot" => snapshot
      })
      error = assert_raises(AgentCodingTool::InvalidState) do
        AgentCodingTool::Checkpoint.new(data_root: data).record("T", workspace: data)
      end
      assert_includes error.message, "exactly one writable"
    end
  end

  # Reproduces DPS-09 through public CLI actions with native launch ownership.
  # Metadata churn cannot alter canonical bytes; substantive edits still refuse.
  def test_nested_metadata_public_checkpoint_round_trip
    fixture do |root, data, _ordinary, _unused, base|
      store = AgentCodingTool::StateStore.new(File.join(data, "state"))
      state = store.load("T")
      visible = File.join(root, "worktrees")
      File.write(File.join(data, "config.yml"), YAML.dump("worktree_root" => visible))
      run_dir = File.join("#{data}-runs", "T", "run")
      FileUtils.mkdir_p(run_dir, mode: 0o700)
      record_path = File.join(run_dir, "worktrees.json")
      inventory = AgentCodingTool::WorktreeManager.new(root: visible, record_path: record_path, attempt_paths: true).create(
        task_id: "T", attempt: 1, task: { "repositories" => { "repo" => { "access" => "write" } } }, snapshot: state.fetch("snapshot"))
      workspace = inventory.fetch("entries").first.fetch("path")
      git("config", "core.excludesFile", File::NULL, chdir: workspace)
      File.write(File.join(workspace, "changed.txt"), "candidate\n")
      File.write(File.join(run_dir, "handoff.json"), JSON.generate(
        "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "T",
        "prepared_at" => state.fetch("prepared_at"), "workspace" => workspace,
        "writable_repository" => "repo", "writable_authority" => state.fetch("snapshot").fetch("repo").slice("remote_url", "branch", "pushed_sha"),
        "invocation_id" => "metadata-fixture", "worktrees_path" => record_path))
      metadata = ["#{data}-runs", File.dirname(run_dir), run_dir, visible,
                  File.dirname(File.dirname(workspace)), File.dirname(workspace), workspace,
                  File.join(workspace, "nested space\nname")].map do |directory|
        FileUtils.mkdir_p(directory, mode: 0o700)
        path = File.join(directory, ".DS_Store")
        File.binwrite(path, "Finder\x00\xff".b)
        path
      end
      out, err = StringIO.new, StringIO.new
      cli = AgentCodingTool::CLI.new(root: root, data_root: data, out: out, err: err)
      assert_equal 0, cli.run(["checkpoint", "record", "T", "--workspace", workspace]), err.string
      record = JSON.parse(out.string)
      assert_equal "metadata-fixture", record.fetch("launch_invocation")
      assert_equal [{ "status" => "M", "path" => "changed.txt" }], record.fetch("changed_files")
      assert_equal Digest::SHA256.file(record.fetch("path")).hexdigest, record.fetch("sha256")
      metadata.each { |path| assert_equal "Finder\x00\xff".b, File.binread(path) }
      excludes = File.join(root, "finder-excludes")
      File.write(excludes, ".DS_Store\n")
      git("config", "core.excludesFile", excludes, chdir: workspace)
      metadata.each { |path| File.binwrite(path, "changed Finder bytes") }
      File.unlink(metadata.last)
      assert_equal 0, cli.run(["checkpoint", "verify", "T", "--workspace", workspace]), err.string
      gate = gate_command("write", ".DS_Store", "gate metadata")
      assert_equal 0, cli.run(["checkpoint", "gate", "T", "--workspace", workspace, "--", *gate]), err.string
      assert_equal "gate metadata", File.binread(File.join(workspace, ".DS_Store"))
      artifact = File.join(root, "candidate.patch")
      result = AgentCodingTool::Checkpoint.new(data_root: data).export("T", workspace: workspace, base_sha: base, artifact: artifact)
      assert_equal record.fetch("sha256"), result.fetch("sha256")
      assert_equal File.binread(record.fetch("path")), File.binread(artifact)
      explicit_artifact = File.join(root, ".DS_Store")
      File.binwrite(explicit_artifact, "explicit artifact must be verified")
      assert_raises(AgentCodingTool::InvalidState) do
        AgentCodingTool::Checkpoint.new(data_root: data).record("T", workspace: workspace, artifact: explicit_artifact)
      end
      assert_equal "explicit artifact must be verified", File.binread(explicit_artifact)
      git("add", "-f", "--", ".DS_Store", chdir: workspace)
      assert_equal 2, cli.run(["checkpoint", "verify", "T", "--workspace", workspace])
      git("reset", "-q", "--", ".DS_Store", chdir: workspace)
      metadata_only_run = File.join(File.dirname(run_dir), "metadata-only-run")
      Dir.mkdir(metadata_only_run)
      File.write(File.join(metadata_only_run, ".DS_Store"), "no handoff")
      assert_equal 2, cli.run(["checkpoint", "verify", "T", "--workspace", workspace])
      assert_equal "no handoff", File.read(File.join(metadata_only_run, ".DS_Store"))
      FileUtils.remove_entry(metadata_only_run)
      File.write(File.join(workspace, "changed.txt"), "concurrent substantive edit\n")
      assert_equal 2, cli.run(["checkpoint", "verify", "T", "--workspace", workspace])
      assert_equal "gate metadata", File.binread(File.join(workspace, ".DS_Store"))
    end
  end

  # Tracked metadata edits remain exact candidate content; staged metadata still
  # refuses. Unsupported file types never acquire the discovery exemption.
  def test_checkpoint_preserves_tracked_metadata_and_rejects_unsafe_types
    fixture do |root, data, ordinary, workspace, _base|
      File.write(File.join(ordinary, ".DS_Store"), "deliberately tracked\n")
      git("add", "-f", "--", ".DS_Store", chdir: ordinary)
      git("commit", "-m", "tracked fixture metadata", chdir: ordinary)
      base = git("rev-parse", "HEAD", chdir: ordinary)
      tracked_workspace = File.join(root, "tracked-workspace")
      @checkpoint_world.copy(@checkpoint_checkout, path: tracked_workspace)
      git("remote", "set-url", "origin", File.join(root, "remote.git"), chdir: tracked_workspace)
      store = AgentCodingTool::StateStore.new(File.join(data, "state"))
      state = store.load("T")
      state["snapshot"]["repo"]["pushed_sha"] = base
      store.write("T", state)
      File.binwrite(File.join(tracked_workspace, ".DS_Store"), "tracked edit\x00\xff".b)
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      record = checkpoint.record("T", workspace: tracked_workspace)
      assert_equal [{ "status" => "M", "path" => ".DS_Store" }], record.fetch("changed_files")
      assert_equal "verified", checkpoint.verify("T", workspace: tracked_workspace).fetch("status")
      git("add", "--", ".DS_Store", chdir: tracked_workspace)
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: tracked_workspace) }
      # Return to the fixture's original baseline for independent unsafe entries.
      state["snapshot"]["repo"]["pushed_sha"] = git("rev-parse", "HEAD", chdir: workspace)
      store.write("T", state)
      path = File.join(workspace, ".DS_Store")
      [File.join(workspace, "changed.txt"), File.join(workspace, "absent")].each do |target|
        File.symlink(target, path)
        assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace) }
        assert File.symlink?(path)
        File.unlink(path)
      end
      Dir.mkdir(path)
      File.write(File.join(path, "substantive"), "preserve directory contents")
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace) }
      assert_equal "preserve directory contents", File.read(File.join(path, "substantive"))
    end
  end

  # A synthetic pre-policy v1 record must verify/recover its exact recorded
  # metadata bytes. Compatibility never drops hashes or rewrites old evidence.
  def test_legacy_checkpoint_metadata_remains_bound_to_recorded_bytes
    fixture do |root, data, _ordinary, workspace, base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      path = File.join(workspace, ".DS_Store")
      File.binwrite(path, "historically recorded\x00\xff".b)
      bytes, inventory = checkpoint.send(:implementation, workspace, base, preserved_paths: [".DS_Store"])
      current = checkpoint.record("T", workspace: workspace)
      directory = File.dirname(current.fetch("path"))
      record_path = File.join(directory, current.fetch("record_file"))
      record = JSON.parse(File.binread(record_path))
      record.merge!("sha256" => Digest::SHA256.hexdigest(bytes), "implementation_sha256" => Digest::SHA256.hexdigest(bytes),
                    "bytes" => bytes.bytesize, "changed_files" => inventory)
      File.binwrite(current.fetch("path"), bytes)
      File.write(record_path, JSON.pretty_generate(record) + "\n")
      File.write(File.join(directory, "current.json"), JSON.generate("record_file" => current.fetch("record_file"),
        "sha256" => Digest::SHA256.file(record_path).hexdigest))
      preserved = [current.fetch("path"), record_path, File.join(directory, "current.json")].to_h { |entry| [entry, File.binread(entry)] }
      # Force a temporary-root alias on every platform, reproducing macOS /var.
      # Only the ACT-created verification root is canonicalized; arbitrary
      # metadata ancestry remains subject to the unchanged rejection policy.
      temporary_parent = File.join(root, "verification-temporary")
      Dir.mkdir(temporary_parent)
      temporary_alias = File.join(root, "verification-temporary-alias")
      File.symlink(temporary_parent, temporary_alias)
      create_temporary = Dir.method(:mktmpdir)
      aliased_verifications = 0
      with_alias = lambda do |prefix, *arguments, **options, &operation|
        if prefix == "act-checkpoint-verify-"
          create_temporary.call(prefix, temporary_parent, **options) do |directory|
            aliased_verifications += 1
            operation.call(File.join(temporary_alias, File.basename(directory)))
          end
        else
          create_temporary.call(prefix, *arguments, **options, &operation)
        end
      end
      Dir.stub(:mktmpdir, with_alias) do
        assert_equal "verified", checkpoint.verify("T", workspace: workspace).fetch("status")
      end
      assert_equal 1, aliased_verifications
      File.binwrite(path, "changed incidental bytes")
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T", workspace: workspace) }
      destination = File.join(root, "recovered-legacy")
      assert_equal "reconstructed", checkpoint.recover("T", destination: destination, confirm_disconnected: true).fetch("status")
      assert_equal "historically recorded\x00\xff".b, File.binread(File.join(destination, ".DS_Store"))
      assert_equal preserved, preserved.keys.to_h { |entry| [entry, File.binread(entry)] }
      File.binwrite(current.fetch("path"), bytes + "tampered")
      assert_raises(AgentCodingTool::InvalidState) { checkpoint.verify("T") }
    end
  end

  # Declares workspace Git identity while production rejects partial/foreign
  # launch evidence, preserving the candidate, task state and refused report.
  def test_launch_attempt_rejects_foreign_workspace_and_partial_run_evidence
    fixture(native: false) do |root, data, _ordinary, workspace, base|
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data)
      run_dir = File.join("#{data}-runs", "T", "run")
      FileUtils.mkdir_p(run_dir)
      candidate = Dir.children(workspace).to_h { |name| [name, File.binread(File.join(workspace, name))] }
      with_workspace_identity(workspace, base, File.join(root, "remote.git")) do
        error = assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace) }
        assert_includes error.message, "missing/symlinked evidence"
      end
      state = AgentCodingTool::StateStore.new(File.join(data, "state")).load("T")
      File.write(File.join(run_dir, "handoff.json"), JSON.generate(
        "schema_version" => AgentCodingTool::Launcher::SCHEMA, "task_id" => "T",
        "prepared_at" => state.fetch("prepared_at"), "workspace" => File.join(root, "foreign"),
        "writable_repository" => "repo", "writable_authority" => state.fetch("snapshot").fetch("repo").slice("remote_url", "branch", "pushed_sha"),
        "invocation_id" => "foreign", "worktrees_path" => File.join(run_dir, "worktrees.json")
      ))
      report_path = File.join(run_dir, "handoff.json")
      before = File.binread(report_path)
      with_workspace_identity(workspace, base, File.join(root, "remote.git")) do
        error = assert_raises(AgentCodingTool::InvalidState) { checkpoint.record("T", workspace: workspace) }
        assert_includes error.message, "launch ownership"
      end
      assert_equal before, File.binread(report_path)
      assert_equal state, AgentCodingTool::StateStore.new(File.join(data, "state")).load("T")
      assert_equal candidate, Dir.children(workspace).to_h { |name| [name, File.binread(File.join(workspace, name))] }
      refute File.exist?(File.join("#{data}-runs", "checkpoints"))
    end
  end

  # Exercises exempt commands through symlinked ancestry and unavailable storage;
  # command results survive, unsafe paths stay untouched, and safe receipts persist.
  def test_exempt_gate_receipt_setup_is_best_effort_without_following_symlinks
    fixture(native: false) do |root, data, _ordinary, workspace, _base|
      task_path = File.join(data, "tasks", "T.yml")
      task = YAML.safe_load_file(task_path)
      task["checkpoint"] = { "mode" => "exempt", "category" => "inspection", "reason" => "Read-only audit." }
      File.write(task_path, YAML.dump(task))
      alias_root = File.join(root, "alias")
      File.symlink(root, alias_root)
      storage = "#{data}-runs"
      File.write(storage, "occupied")
      [File.join(alias_root, "data"), data].each do |data_root|
        diagnostics = StringIO.new
        checkpoint = AgentCodingTool::Checkpoint.new(data_root: data_root, err: diagnostics)
        marker = File.join(root, "ran")
        assert_equal 0, checkpoint.gate("T", workspace: workspace,
          command: gate_command("write", marker, "ran"))
        assert_equal "ran", File.read(marker)
        File.unlink(marker)
        error = assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "8"))
        end
        assert_equal "checkpoint: validation command failed (8)", error.message
        assert_includes diagnostics.string, "crash durability unconfirmed"
        refute_includes diagnostics.string, "Checkpoint gate receipt:"
        assert_equal "occupied", File.read(storage)
        observations = File.join(storage, "unsafe.observation.json")
        assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("touch", marker), observations: observations)
        end
        refute File.exist?(marker)
      end
      File.unlink(storage)
      diagnostics = StringIO.new
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data, err: diagnostics)
      assert_equal 0, checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"))
      receipts = Dir.glob(File.join(storage, "checkpoints", "T", "*", "gate-*.finished.json"))
      assert_equal 1, receipts.length
      receipt = JSON.parse(File.binread(receipts.fetch(0)))
      assert_nil receipt.fetch("candidate")
      assert_equal "not_applicable", receipt.fetch("candidate_validation")
      assert_includes diagnostics.string, "Checkpoint gate receipt:"
      refute_includes diagnostics.string, "crash durability unconfirmed"
    end
  end

  # Receipt directory creation failures preserve required candidate checks and
  # command results, including refusal if an identical patch replaces the record.
  def test_gate_receipt_setup_failure_retains_required_candidate_binding
    fixture do |_root, data, _ordinary, workspace, _base|
      diagnostics = StringIO.new
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data, err: diagnostics)
      record = checkpoint.record("T", workspace: workspace)
      directory = File.dirname(record.fetch("path"))
      check_directory = checkpoint.method(:directory!)
      unavailable = lambda do |id, state, create: true|
        raise Errno::EACCES, "injected receipt setup failure" if create
        check_directory.call(id, state, create: false)
      end
      checkpoint.stub(:directory!, unavailable) do
        assert_equal 0, checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"))
        error = assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "8"))
        end
        assert_equal "checkpoint: validation command failed (8)", error.message
        replacement = lambda do |*argv, **options|
          AgentCodingTool::Checkpoint.new(data_root: data).record("T", workspace: workspace)
          Kernel.system(*argv, **options)
        end
        checkpoint.stub(:system, replacement) do
          error = assert_raises(AgentCodingTool::InvalidState) do
            checkpoint.gate("T", workspace: workspace, command: gate_command("exit", "0"))
          end
          assert_equal "checkpoint: candidate changed during validation", error.message
        end
      end
      assert_empty Dir.glob(File.join(directory, "gate-*.json"))
      assert_includes diagnostics.string, "crash durability unconfirmed"
      refute_includes diagnostics.string, "Checkpoint gate receipt:"
    end
  end

  # Required checkpoints (including stored checkpoints on exempt tasks) still
  # reject symlinked ancestry/root before commands; preserved evidence is unchanged.
  def test_gate_receipt_setup_cannot_bypass_required_symlink_verification
    fixture do |root, data, _ordinary, workspace, _base|
      diagnostics = StringIO.new
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data, err: diagnostics)
      record = checkpoint.record("T", workspace: workspace)
      directory = File.dirname(record.fetch("path"))
      preserved = Dir.children(directory).to_h { |name| [name, File.binread(File.join(directory, name))] }
      alias_root = File.join(root, "alias")
      File.symlink(root, alias_root)
      marker = File.join(root, "must-not-run")
      aliased = AgentCodingTool::Checkpoint.new(data_root: File.join(alias_root, "data"), err: diagnostics)
      error = assert_raises(AgentCodingTool::InvalidState) do
        aliased.gate("T", workspace: workspace, command: gate_command("touch", marker))
      end
      assert_equal "checkpoint: symlinked evidence path", error.message
      storage = "#{data}-runs"
      relocated = File.join(root, "relocated-evidence")
      File.rename(storage, relocated)
      File.symlink(relocated, storage)
      task_path = File.join(data, "tasks", "T.yml")
      [false, true].each do |exempt|
        if exempt
          task = YAML.safe_load_file(task_path)
          task["checkpoint"] = { "mode" => "exempt", "category" => "inspection", "reason" => "Read-only audit." }
          File.write(task_path, YAML.dump(task))
        end
        error = assert_raises(AgentCodingTool::InvalidState) do
          checkpoint.gate("T", workspace: workspace, command: gate_command("touch", marker))
        end
        assert_equal "checkpoint: symlinked evidence path", error.message
        refute File.exist?(marker)
        assert_equal preserved, Dir.children(directory).to_h { |name| [name, File.binread(File.join(directory, name))] }
      end
      refute_includes diagnostics.string, "Checkpoint gate receipt:"
    end
  end

  def test_exemption_and_old_task_default
    with_workspace do |data|
      write_task(data, id: "T")
      store = AgentCodingTool::TaskStore.new(File.join(data, "tasks"))
      assert AgentCodingTool::CheckpointPolicy.required?(store.load("T"))
      path = File.join(data, "tasks", "T.yml")
      task = YAML.safe_load_file(path)
      task["checkpoint"] = { "mode" => "exempt", "category" => "inspection", "reason" => "Read-only audit." }
      File.write(path, YAML.dump(task))
      refute AgentCodingTool::CheckpointPolicy.required?(store.load("T"))
      state = { "id" => "T", "prepared_at" => Time.now.utc.iso8601,
                "started_at" => Time.now.utc.iso8601,
                "snapshot" => { "alpha" => { "path" => data, "remote" => "origin",
                  "remote_url" => "test", "branch" => "main", "pushed_sha" => "a" * 40 } } }
      AgentCodingTool::StateStore.new(File.join(data, "state")).write("T", state)
      assert_equal "exempt", AgentCodingTool::Checkpoint.new(data_root: data).verify("T").fetch("status")
      diagnostics = StringIO.new
      checkpoint = AgentCodingTool::Checkpoint.new(data_root: data, err: diagnostics)
      assert_equal 0, checkpoint.gate("T", workspace: data, command: gate_command("exit", "0"))
      if File.realpath(data) != data
        refute File.exist?("#{data}-runs")
        assert_includes diagnostics.string, "crash durability unconfirmed"
        refute_includes diagnostics.string, "Checkpoint gate receipt:"
      else
        receipt = JSON.parse(File.binread(Dir.glob(File.join("#{data}-runs", "checkpoints", "T", "*", "gate-*.finished.json")).fetch(0)))
        assert_nil receipt.fetch("candidate")
        assert_equal "not_applicable", receipt.fetch("candidate_validation")
      end
      prompt = AgentCodingTool::PromptRenderer.new.render(task, {})
      assert_equal 1, prompt.scan(/^## Implementation checkpoint$/).length
      task["checkpoint"] = { "mode" => "exempt" }
      File.write(path, YAML.dump(task))
      assert_raises(AgentCodingTool::InvalidTask) { store.load("T") }
    end
  end
end
