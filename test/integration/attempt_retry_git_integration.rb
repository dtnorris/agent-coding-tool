# frozen_string_literal: true

require_relative "../test_helper"
require "minitest/mock"
require "stringio"

# Public retry journeys use native fixture Git and real finite fake-worker
# processes. Sandbox, boot identity and lsof are declared external test doubles;
# these tests make no claim of host macOS isolation or descendant containment.
class AttemptRecoveryTest < Minitest::Test
  include TestHelpers

  # Builds independent local authorities, private data and external executables.
  # Every ref, process and write belongs to this disposable fixture.
  def fixture(readers: 0)
    Dir.mktmpdir("act16-retry-") do |directory|
      @fixture = File.realpath(directory)
      @data, @visible = %w[data worktrees].map { |name| File.join(@fixture, name) }
      FileUtils.mkdir_p(File.join(@data, "tasks"))
      seed = TestHelpers.git_seed
      @base = seed.fetch(:base)
      repos = (["writer"] + (1..readers).map { |number| "reader#{number}" }).to_h do |name|
        ordinary, remote = [name, "#{name}.git"].map { |part| File.join(@fixture, part) }
        FileUtils.cp_r(File.join(seed.fetch(:root), "ordinary"), ordinary)
        FileUtils.cp_r(File.join(seed.fetch(:root), "remote.git"), remote)
        git("remote", "set-url", "origin", remote, directory: ordinary)
        [name, { "path" => ordinary, "access" => name == "writer" ? "write" : "read_only" }]
      end
      write_task(@data, id: "T", repositories: repos)
      File.write(File.join(@data, "config.yml"), YAML.dump("repo_root" => @fixture, "worktree_root" => @visible))
      @states = AgentCodingTool::StateStore.new(File.join(@data, "state"))
      @preload = File.join(@fixture, "boundaries.rb")
      File.write(@preload, <<~'RUBY')
        require "agent_coding_tool"
        class AgentCodingTool::RetryLiveness
          def self.host_identity = { "fixture_boot" => "deterministic external identity" }
        end
        # Historical fixture producer only: restore the inspected v1 layout,
        # missing host identity and old unguarded retry preparation contract.
        if ENV["ACT16_LEGACY"]
          class AgentCodingTool::WorktreeManager
            alias_method :fixture_initialize, :initialize
            def initialize(**options)
              fixture_initialize(**options.merge(attempt_paths: false, invocation_id: nil))
            end
          end
          class AgentCodingTool::AttemptRecovery
            def retry_ready!(*) = nil
          end
          class AgentCodingTool::Launcher
            alias_method :fixture_save_report, :save_report
            def save_report
              %w[worktree_layout worktree_creation prompt_sha256 prompt_bytes host_identity preparation_state execution_state].each { |key| @report.delete(key) }
              fixture_save_report
            end
          end
        end
        if ENV["ACT16_CREATION_FAULT"]
          class AgentCodingTool::WorktreeManager
            alias_method :fixture_git!, :git!
            def git!(path, *args)
              raise "injected before native add" if args[0, 2] == ["worktree", "add"] && ENV["ACT16_CREATION_FAULT"] == "before"
              output = fixture_git!(path, *args)
              raise "injected after native add" if args[0, 2] == ["worktree", "add"] && ENV["ACT16_CREATION_FAULT"] == "after"
              output
            end
          end
        end
        if ENV["ACT16_CHILD_START_FAULT"]
          class AgentCodingTool::Launcher
            alias_method :fixture_launcher_initialize, :initialize
            def initialize(**options)
              fixture_launcher_initialize(**options.merge(spawner: ->(*) { raise Errno::ENOENT, "fixture spawn failure" }))
            end
          end
        end
      RUBY
      File.write(File.join(@fixture, "lsof"), "#!/bin/sh\nexit 1\n")
      File.chmod(0o755, File.join(@fixture, "lsof"))
      fake_worker
      yield
    end
  end

  # Runs Git in fixture repositories only; fixture setup failures are errors.
  def git(*args, directory:)
    output, error, status = Open3.capture3({ "PATH" => fixture_command_path }, "git", *args, chdir: directory)
    raise "fixture git failed: #{error}" unless status.success?
    output.strip
  end

  # Returns a fixture-only PATH using Apple's selected native Git directly when
  # PATH selects /usr/bin/git, avoiding its developer-tool dispatcher per call.
  # Other Git installations retain PATH precedence. Resolution failures raise;
  # no Git results or ownership checks are simulated, cached or omitted.
  def fixture_command_path
    return @fixture_command_path if @fixture_command_path

    path = ENV.fetch("PATH")
    selected = path.split(File::PATH_SEPARATOR).map { |directory| File.join(directory, "git") }
                   .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
    if RbConfig::CONFIG.fetch("host_os").match?(/darwin/) && selected && File.realpath(selected) == "/usr/bin/git"
      output, error, status = Open3.capture3("/usr/bin/xcrun", "--find", "git")
      native = output.strip
      raise "fixture Git resolution failed: #{error}" unless status.success? && native.start_with?("/") &&
        File.file?(native) && File.executable?(native) && File.realpath(native) != "/usr/bin/git"

      path = "#{File.dirname(File.realpath(native))}#{File::PATH_SEPARATOR}#{path}"
    end
    @fixture_command_path = path
  end

  # Simulates Codex's pinned public interface and exact probe byte contract.
  # Mode files permit invalid final/nonzero/sandbox-failure controls, no inference.
  def fake_worker
    path = File.join(@fixture, "codex")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      root = File.dirname(File.realpath(__FILE__))
      mode = File.file?(File.join(root, "mode")) ? File.read(File.join(root, "mode")) : "clean"
      case ARGV
      when ["--version"] then puts "codex-cli 0.162.1"
      when ["exec", "--help"] then puts "--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model"
      when ["login", "--help"] then puts "status"
      when ["login", "status"] then puts "Logged in using ChatGPT"
      when ["sandbox", "--help"] then puts "Usage: codex sandbox [OPTIONS] [COMMAND]..."
      else
        if ARGV.include?("sandbox")
          ARGV.drop(ARGV.index("act-probe") + 1).each do |target|
            allowed = mode == "leaky" || target.start_with?(Dir.pwd + "/")
            File.write(target, "breach") if allowed
            puts(allowed ? "1" : "0")
          end
        else
          abort "unexpected command" unless ARGV.first == "exec"
          consumed = STDIN.binmode.read
          capture = File.join(root, "tst20-capture-prompt")
          if File.file?(capture)
            # Only this journey opts in; corrupt the observation, never the input.
            recorded = consumed.dup
            recorded.setbyte(0, recorded.getbyte(0) ^ 1) if File.read(capture) == "corrupt"
            File.binwrite(File.join(root, "tst20-consumed-stdin"), recorded)
            File.write(File.join(root, "tst20-worker.json"), JSON.generate("pid" => Process.pid, "workspace" => Dir.pwd))
          end
          puts JSON.generate("type" => "thread.started", "thread_id" => "fixture-session")
          File.write(ARGV.fetch(ARGV.index("--output-last-message") + 1), mode == "invalid" ? "" : "No candidate. Human judgment required.\\n")
          exit(mode == "nonzero" ? 7 : 0)
        end
      end
    RUBY
    File.chmod(0o755, path)
  end

  # Uses a cold public CLI process, with only host identity/lsof/sandbox external
  # boundaries faked. The real host PID disappears before the next CLI command.
  def cli(*args, fault: nil, legacy: false, child_start_fault: false)
    environment = { "PATH" => "#{@fixture}:#{fixture_command_path}", "AGENT_CODING_TOOL_DATA_DIR" => @data,
                    "RUBYOPT" => "#{ENV['RUBYOPT']} -r#{@preload}", "ACT16_CREATION_FAULT" => fault,
                    "ACT16_LEGACY" => legacy ? "1" : nil, "ACT16_CHILD_START_FAULT" => child_start_fault ? "1" : nil }
    output, error, status = Open3.capture3(environment, RbConfig.ruby, "-I#{File.join(Dir.pwd, 'lib')}",
                                          File.join(Dir.pwd, "bin", "agent-coding-tool"), *args)
    [status.exitstatus, output, error]
  end

  # Requires a successful public command and returns output for contract checks.
  def succeeds(*args, **options)
    status, output, error = cli(*args, **options)
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

  # Proves the complete public handoff for all supported non-complete outcomes.
  # Removing closeout makes preparation fail; execution success never completes.
  def test_public_exit_zero_closeout_fresh_retry_preserves_both_attempts
    %w[blocked failed needs_judgment].each do |outcome|
      fixture(readers: outcome == "blocked" ? 7 : 0) do
        succeeds("launch", "T", "--codex", "--reasoning", "high")
        first = reports.fetch(0)
        assert_equal [1, "exited", 0, true, "fresh_at_exit"], first.values_at("attempt", "status", "exit_status", "final_valid", "writable_freshness")
        old = bytes(File.dirname(first.fetch("worktrees_path")))
        original_state = first.fetch("execution_state")
        succeeds("record", "T", outcome, "--summary", "No candidate.", "--next", "Explicit closeout and retry.")
        before = bytes
        assert_equal 2, cli("prepare", "T", "--retry").first
        assert_equal before, bytes
        succeeds("worktrees", "T")
        succeeds("close-attempt", "T", "--dry-run")
        assert_equal before, bytes
        succeeds("close-attempt", "T")
        closed = bytes
        succeeds("close-attempt", "T")
        assert_equal closed, bytes
        succeeds("prepare", "T", "--retry")
        refute_equal first.fetch("prepared_at"), @states.load("T").fetch("prepared_at")
        succeeds("launch", "T", "--codex", "--reasoning", "high")
        second = reports.fetch(1)
        assert_equal 2, second.fetch("attempt")
        refute_equal first.fetch("invocation_id"), second.fetch("invocation_id")
        assert_equal first.fetch("execution_state"), original_state
        first.fetch("worktrees").fetch("entries").zip(second.fetch("worktrees").fetch("entries")).each do |earlier, later|
          refute_equal earlier.fetch("path"), later.fetch("path")
          assert File.directory?(earlier.fetch("path"))
          assert_equal @base, git("rev-parse", "HEAD", directory: earlier.fetch("path"))
          assert_equal @base, git("rev-parse", "HEAD", directory: later.fetch("path"))
        end
        assert_operator second.fetch("sandbox_probe").fetch("protected_paths"), :>=, first.fetch("worktrees").fetch("entries").length
        assert_equal 2, JSON.parse(succeeds("worktrees", "T")).fetch("attempts").length
        assert_equal old, old.keys.to_h { |path| [path, File.binread(path)] }
        assert_nil @states.load("T")["result"]
        refute @states.load("T")["checkpoint"]
        assert_empty Dir.glob("#{@data}-runs/T/*/delivery.json")
        assert_equal 2, cli("cleanup", "T").first
        if outcome == "blocked"
          succeeds("record", "T", "failed")
          succeeds("close-attempt", "T")
          succeeds("prepare", "T", "--retry")
          succeeds("launch", "T", "--codex")
          assert_equal [1, 2, 3], reports.map { |report| report.fetch("attempt") }
          assert_equal old, old.keys.to_h { |path| [path, File.binread(path)] }
        end
      end
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

  # A terminal report with changed prompt/log/ownership/closeout evidence cannot
  # authorize retries. Inspection diagnoses damage and retains other attempts.
  def test_tampered_artifacts_and_closeout_refuse_without_mutation
    fixture do
      succeeds("launch", "T", "--codex")
      succeeds("record", "T", "failed")
      report = reports.first
      original = File.binread(report.fetch("prompt_path"))
      File.write(report.fetch("prompt_path"), "tampered")
      before = bytes
      assert_equal 2, cli("close-attempt", "T").first
      assert_equal before, bytes
      File.binwrite(report.fetch("prompt_path"), original)
      succeeds("close-attempt", "T")
      path = File.join(File.dirname(report.fetch("worktrees_path")), "closeout.json")
      original_closeout = File.binread(path)
      closeout = JSON.parse(File.binread(path))
      closeout["invocation_id"] = "foreign"
      File.write(path, JSON.generate(closeout))
      before = bytes
      assert_equal 2, cli("prepare", "T", "--retry").first
      assert_equal before, bytes
      closeout = JSON.parse(original_closeout)
      closeout.fetch("state")["started_at"] = nil
      File.write(path, JSON.generate(closeout))
      before = bytes
      assert_equal 2, cli("prepare", "T", "--retry").first
      assert_equal before, bytes
    end
  end

  # Nonzero and invalid-final reports are execution facts, separate from result.
  def test_unsuccessful_execution_statuses_can_close_and_retry
    %w[nonzero invalid].each do |mode|
      fixture do
        File.write(File.join(@fixture, "mode"), mode)
        assert_equal(mode == "nonzero" ? 7 : 0, cli("launch", "T", "--codex").first)
        first = reports.first
        assert_equal(mode == "invalid" ? "invalid_final" : "exited", first.fetch("status"))
        succeeds("record", "T", "needs_judgment")
        succeeds("close-attempt", "T")
        succeeds("prepare", "T", "--retry")
        File.write(File.join(@fixture, "mode"), "clean")
        succeeds("launch", "T", "--codex")
      end
    end
  end

  # A reserved spawn failure has no child but retains its execution/preparation
  # identity. Explicit closeout and fresh prepare are still separate handoffs.
  def test_child_start_failure_is_preserved_and_can_retry
    fixture do
      assert_equal 127, cli("launch", "T", "--codex", child_start_fault: true).first
      first = reports.first
      assert_equal "child_start_failed", first.fetch("status")
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
        succeeds("record", "T", "blocked")
        succeeds("close-attempt", "T")
        succeeds("prepare", "T", "--retry")
        succeeds("launch", "T", "--codex", "--allow-write-collision")
        assert_equal sibling, sibling.keys.to_h { |path| [path, File.binread(path)] }
        assert_equal sibling_state, @states.load("B")
        assert_equal sibling_head, git("rev-parse", "refs/heads/act/B/attempt-1", directory: File.join(@fixture, "writer"))
      end
    end
  end

  # Foreign identity, native branch, task access, delivery and reservation races
  # refuse at preflight with byte-for-byte retention of the refused state.
  def test_ownership_delivery_candidate_and_changed_state_refusals
    fixture do
      succeeds("launch", "T", "--codex")
      succeeds("record", "T", "failed")
      first = reports.first
      report_path = File.join(File.dirname(first.fetch("worktrees_path")), "handoff.json")
      report_bytes = File.binread(report_path)
      %w[task_id attempt invocation_id prepared_at preparation execution_state].each do |key|
        altered = JSON.parse(report_bytes)
        altered[key] = key == "attempt" ? 17 : "foreign"
        File.write(report_path, JSON.generate(altered))
        before = bytes
        assert_equal 2, cli("close-attempt", "T").first, key
        assert_equal before, bytes, key
        File.binwrite(report_path, report_bytes)
      end
      delivery_path = File.join(File.dirname(report_path), "delivery.json")
      File.write(delivery_path, JSON.generate("stage" => "validation_failed"))
      before = bytes
      assert_equal 2, cli("close-attempt", "T").first
      assert_equal before, bytes
      File.unlink(delivery_path)
      succeeds("record", "T", "candidate_complete")
      before = bytes
      assert_equal 2, cli("close-attempt", "T").first
      assert_equal before, bytes
      succeeds("record", "T", "failed")
      state = @states.load("T")
      changed = false
      recovery = AgentCodingTool::AttemptRecovery.new(data_root: @data, liveness: Class.new { def check(*) = :clear }.new,
        before_write: lambda { |_row|
          changed = true
          @states.write("T", state.merge("operator_note" => "changed during preflight"))
        })
      assert_raises(AgentCodingTool::InvalidState) { recovery.close("T") }
      assert changed
      refute File.exist?(File.join(File.dirname(report_path), "closeout.json"))
    end
  end
end
