# frozen_string_literal: true

# Focused authoring checks only: no sandbox, worker dispatch, candidate test,
# ACT lifecycle, network or native acceptance runs in this file.
require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require_relative "integration/act24_continuity"

# Verifies the recipe's pure decisions and byte observation without qualifying
# the unexecuted host sandbox, supervisor or real Codex resume runtime.
class Act24RecipeChecks < Minitest::Test
  # Returns representative configuration; no declared executable is invoked.
  def config(root = "/synthetic")
    { "root" => root, "ruby" => "/runtime/bin/ruby", "ruby_prefix" => "/runtime", "git" => "/tools/bin/git",
      "codex" => "/tools/codex", "skills" => "/skills", "skills_admin" => "/skills/.git", "deadline" => Time.now.to_f + 30,
      "sentinel_pid" => 123, "sentinel_port" => 456, "source" => Act24Continuity.source_identity }
  end

  # Returns a fresh, unconsumed ledger for decision tests; performs no writes.
  def ledger
    { "turns" => 0, "corrections" => 0, "pending" => false, "hold" => nil, "deadline" => 100 }
  end

  # Ensures cumulative reservations cannot be reset by a pending retry or hold.
  def test_cumulative_limits_and_all_decision_holds_survive_serialization
    current = ledger
    3.times do |index|
      current = Act24Continuity.reserve(current, now: 1)
      assert_equal index + 1, current.fetch("turns")
      assert_equal index, current.fetch("corrections")
      assert_raises(RuntimeError) { Act24Continuity.reserve(JSON.parse(JSON.generate(current)), now: 1) }
      current["pending"] = false
    end
    assert_raises(RuntimeError) { Act24Continuity.reserve(current, now: 1) }
    assert_raises(RuntimeError) { Act24Continuity.reserve(ledger, now: 100) }
    assert_raises(RuntimeError) { Act24Continuity.reserve(ledger.merge("turns" => -1), now: 1) }
    assert_raises(RuntimeError) { Act24Continuity.reserve(ledger.merge("corrections" => 1), now: 1) }
    Act24Continuity::DECISIONS.each do |reason|
      held = JSON.parse(JSON.generate(ledger.merge("hold" => reason)))
      error = assert_raises(RuntimeError) { Act24Continuity.reserve(held, now: 1) }
      assert_includes error.message, reason
      assert_equal 0, held.fetch("turns")
    end
  end

  # Refuses foreign job identities, unqualified dispatch and authority changes.
  # Identity reads are stubbed; no host process or sandbox operation occurs.
  def test_dispatch_requires_live_owner_qualification_and_exact_role
    Dir.mktmpdir("act24-dispatch-") do |root|
      settings = config(root)
      owner = { "pid" => 24, "parent" => 23, "group" => 24, "birth" => [1, 2] }
      request = { "role" => "worker", "owner" => owner, "argv" => [settings.fetch("ruby"), Act24Continuity::WORKER, "exec", "--json", "-"],
        "cwd" => "#{root}/case/workspace" }
      FeedbackRuntime.stub(:identity, owner) do
        assert_raises(RuntimeError) { Act24Continuity.job!(settings, request, {}) }
        assert_raises(RuntimeError) { Act24Continuity.job!(settings, request, { 24 => owner }) }
        %w[qualification.json supervision-qualification.json].each { |name| File.write("#{root}/#{name}", "inert decision fixture") }
        assert_equal [request.fetch("argv"), request.fetch("cwd")], Act24Continuity.job!(settings, request, { 24 => owner })
        assert_raises(RuntimeError) { Act24Continuity.job!(settings, request.merge("cwd" => "/real"), { 24 => owner }) }
        assert_raises(RuntimeError) { Act24Continuity.job!(settings, request.merge("role" => "controller"), { 24 => owner }) }
        assert_raises(RuntimeError) { Act24Continuity.job!(settings, request.merge("argv" => ["/bin/sh", "-c", "true"]), { 24 => owner }) }
      end
    end
  end

  # Unknown child state blocks restoration/preservation until an independent
  # supervisor reaping receipt exists; an exit claim alone is insufficient.
  def test_quiescence_requires_supervisor_reaping_receipt
    Dir.mktmpdir("act24-quiescence-") do |root|
      Dir.mkdir("#{root}/jobs")
      path = "#{root}/jobs/worker.json"
      Act24Continuity.save(path, { "role" => "worker" })
      assert_raises(RuntimeError) { Act24Continuity.quiescent_jobs!(root) }
      Act24Continuity.save("#{path}.done", { "exit" => 0 })
      assert_raises(RuntimeError) { Act24Continuity.quiescent_jobs!(root) }
      Act24Continuity.save("#{path}.done", { "exit" => 1, "reaped_by" => 24 })
      assert_nil Act24Continuity.quiescent_jobs!(root)
    end
  end

  # Exercises supervise through controlled process/clock seams only. The fake
  # PIDs never reach the OS; all spawn, signal, wait and identity calls are stubbed.
  # Yields retained observations; setup/filesystem/assertion failures propagate.
  def supervision_failure(at:, slow_reap: false)
    Dir.mktmpdir("act24-supervision-") do |root|
      %w[jobs captures].each { |name| Dir.mkdir("#{root}/#{name}") }
      settings = config(root).merge("monotonic_deadline" => 100)
      spawned, signals, waits, reaped = [], [], [], []
      tick = 0.0
      job_path = "#{root}/jobs/#{'a' * 36}.json"
      spawn = lambda do |_environment, *_argv, **options|
        child = 4101 + spawned.length
        spawned << child
        %i[out err].each { |stream| File.binwrite(options.fetch(stream), "") if options.fetch(stream).is_a?(String) }
        if child == 4101 && at != :controller_identity
          Act24Continuity.save(job_path, { "role" => "controller", "owner" => {} })
          File.binwrite("#{root}/captures/#{'a' * 36}.stdin", "")
        end
        child
      end
      identity = lambda do |child|
        if (at == :controller_identity && child == 4101) || (at == :job_identity && child == 4102)
          raise "injected identity inspection failure"
        end
        reaped.include?(child) ? nil : { "pid" => child, "parent" => Process.pid, "group" => child, "birth" => [child, 1] }
      end
      wait = lambda do |child, flags = nil|
        waits << [child, flags]
        raise "blocking wait attempted" unless flags == Process::WNOHANG
        if signals.any? { |_signal, target| target == child || target == -child } && !slow_reap
          reaped << child
          [child, Struct.new(:exitstatus, :termsig).new(nil, 9)]
        end
      end
      save = Act24Continuity.method(:save)
      write = lambda do |path, value, **options|
        raise "injected post-spawn setup failure" if at == :job_setup && path.end_with?(".started")
        save.call(path, value, **options)
      end
      original_open = File.method(:open)
      open_file = lambda do |path, *arguments, **options, &block|
        file = original_open.call(path, *arguments, **options, &block)
        if at == :job_close && path == "#{root}/captures/#{'a' * 36}.stderr" && !block
          close = file.method(:close)
          file.define_singleton_method(:close) { close.call; raise "injected post-spawn close failure" }
        end
        file
      end
      Process.stub(:spawn, spawn) do
        Process.stub(:kill, ->(signal, target) { signals << [signal, target] }) do
          Process.stub(:waitpid2, wait) do
            Signal.stub(:trap, "DEFAULT") do
              FeedbackRuntime.stub(:identity, identity) do
                FeedbackRuntime.stub(:discover, nil) do
                  FeedbackRuntime.stub(:clock, -> { tick += 0.1 }) do
                    Act24Continuity.stub(:sleep, nil) do
                      Act24Continuity.stub(:job!, [[settings.fetch("ruby"), "inert"], root]) do
                        Act24Continuity.stub(:save, write) do
                          File.stub(:open, open_file) do
                            error = if at == :job_setup && !slow_reap
                                      result = Act24Continuity.supervise(settings, "controller")
                                      assert_equal "injected post-spawn setup failure", result.fetch("failure")
                                      nil
                                    else
                                      assert_raises(RuntimeError) { Act24Continuity.supervise(settings, "controller") }
                                    end
                            receipt_path = Dir.glob("#{root}/*.supervision.json").first
                            yield spawned, signals, waits, receipt_path && Act24Continuity.read(receipt_path), error, tick, root
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # A controller already spawned when identity inspection fails remains a
  # direct-child cleanup obligation, with no unqualified process-group signals.
  def test_controller_identity_failure_keeps_direct_child_in_cleanup
    supervision_failure(at: :controller_identity) do |spawned, signals, waits, receipt, _error, _tick, root|
      assert_equal [4101], spawned
      assert_includes signals, ["KILL", 4101]
      refute signals.any? { |_signal, target| target.negative? }
      assert waits.all? { |_child, flags| flags == Process::WNOHANG }
      refute_nil receipt
      refute receipt.fetch("quiescent")
      assert_equal "injected identity inspection failure", receipt.fetch("failure")
      assert_equal 9, receipt.fetch("direct_children").first.fetch("signal")
      assert_raises(RuntimeError) { Act24Continuity.quiescent_jobs!(root) }
    end
  end

  # A job child is tracked before either identity inspection or later setup
  # can fail; the receipt retains the primary failure and actual child outcome.
  def test_job_post_spawn_identity_and_setup_failure_keep_cleanup_ownership
    %i[job_identity job_close job_setup].each do |point|
      supervision_failure(at: point) do |spawned, signals, waits, receipt, _error, _tick, _root|
        assert_equal [4101, 4102], spawned
        assert signals.any? { |_signal, target| [4102, -4102].include?(target) }
        refute_includes signals, ["KILL", -4102] unless point == :job_setup
        assert waits.all? { |_child, flags| flags == Process::WNOHANG }
        refute_nil receipt
        assert_includes receipt.fetch("failure"), "injected"
        assert_equal [9, 9], receipt.fetch("direct_children").map { |child| child.fetch("signal") }
        assert_equal point == :job_setup, receipt.fetch("quiescent")
      end
    end
  end

  # Reaped/reused PIDs and lost direct-child ownership never authorize signals
  # to unrelated processes, even when a previously observed birth is retained.
  def test_cleanup_refuses_reused_pids_and_lost_wait_ownership
    old = { "pid" => 4201, "parent" => Process.pid, "group" => 4201, "birth" => [1, 1] }
    replacement = old.merge("birth" => [2, 2])
    signals = []
    tick = 0.0
    Process.stub(:kill, ->(signal, target) { signals << [signal, target] }) do
      Process.stub(:waitpid2, ->(_child, flags) { assert_equal Process::WNOHANG, flags; raise Errno::ECHILD }) do
        FeedbackRuntime.stub(:discover, nil) do
          FeedbackRuntime.stub(:identity, replacement) do
            FeedbackRuntime.stub(:clock, -> { tick += 0.1 }) do
              Act24Continuity.stub(:sleep, nil) do
                exited = Struct.new(:exitstatus, :termsig).new(0, nil)
                clean = Act24Continuity.cleanup_children({ 4201 => old }, { 4201 => { "status" => exited } }, {}, deadline: 2)
                assert clean.fetch("quiescent")
                blocked = Act24Continuity.cleanup_children({}, { 4201 => { "status" => nil } }, {}, deadline: 2)
                refute blocked.fetch("quiescent")
                assert_includes blocked.fetch("unreaped"), 4201
                assert blocked.fetch("errors").any? { |error| error.include?("ECHILD") }
                assert_empty signals
              end
            end
          end
        end
      end
    end
  end

  # A child that stays unreaped cannot stall cleanup or turn deadline expiry
  # into quiescence. The original failure and unresolved PID survive in evidence.
  def test_unreaped_child_expires_one_monotonic_cleanup_deadline
    %i[controller_identity job_setup].each do |point|
      supervision_failure(at: point, slow_reap: true) do |_spawned, signals, waits, receipt, _error, tick, root|
        assert_includes signals, ["KILL", 4101]
        assert waits.all? { |_child, flags| flags == Process::WNOHANG }
        assert_operator tick, :<, 4
        refute_nil receipt
        refute receipt.fetch("quiescent")
        assert receipt.fetch("cleanup").fetch("deadline_expired")
        assert_nil receipt.fetch("direct_children").first.fetch("signal")
        assert_raises(RuntimeError) { Act24Continuity.quiescent_jobs!(root) }
      end
    end
  end

  # A delayed reaping result retains its actual exit rather than inferring a
  # signal from the cleanup request, and ends before the finite cleanup deadline.
  def test_delayed_nonblocking_reap_preserves_actual_exit
    identity = { "pid" => 4301, "parent" => Process.pid, "group" => 4301, "birth" => [1, 1] }
    direct = { 4301 => { "status" => nil } }
    polls, tick = 0, 0.0
    wait = lambda do |child, flags|
      assert_equal [4301, Process::WNOHANG], [child, flags]
      polls += 1
      [child, Struct.new(:exitstatus, :termsig).new(7, nil)] if polls == 3
    end
    Process.stub(:waitpid2, wait) do
      Process.stub(:kill, nil) do
        FeedbackRuntime.stub(:discover, nil) do
          FeedbackRuntime.stub(:identity, ->(_child) { direct.fetch(4301)["status"] ? nil : identity }) do
            FeedbackRuntime.stub(:clock, -> { tick += 0.1 }) do
              Act24Continuity.stub(:sleep, nil) do
                result = Act24Continuity.cleanup_children({ 4301 => identity }, direct, {}, deadline: 2)
                assert result.fetch("quiescent")
                refute result.fetch("deadline_expired")
                assert_equal 7, direct.fetch(4301).fetch("status").exitstatus
                assert_nil direct.fetch(4301).fetch("status").termsig
                assert_equal 3, polls
              end
            end
          end
        end
      end
    end
  end

  # Rejects arbitrary host commands, real task-data selection and publication.
  # Allows only the actual generated argument forms, including bounded replays.
  def test_host_command_allowlist_has_no_arbitrary_shell_or_ruby
    settings = config
    root = settings.fetch("root")
    ruby = settings.fetch("ruby")
    script = Act24Continuity::SCRIPT
    assert Act24Continuity.trusted_command?(settings, [settings.fetch("codex"), "--version"], root)
    refute Act24Continuity.trusted_command?(settings, [settings.fetch("codex"), "exec", "-"], root)
    refute Act24Continuity.trusted_command?(settings, [ruby, "-e", "arbitrary"], root)
    refute Act24Continuity.trusted_command?(settings, ["/bin/sh", "-c", "true"], root)
    refute Act24Continuity.trusted_command?(settings, [settings.fetch("git"), "push"], root)
    refute Act24Continuity.trusted_command?(settings, [settings.fetch("git"), "-c", "alias.bad=!shell", "bad"], root)
    prefix = [ruby, "#{Act24Continuity::SOURCE}/bin/agent-coding-tool", "checkpoint", "gate", "T", "--workspace", "#{root}/case/workspace", "--"]
    assert Act24Continuity.trusted_command?(settings, [*prefix, ruby, script, "gate", "#{root}/config.json"], "#{root}/case/workspace")
    refute Act24Continuity.trusted_command?(settings, [*prefix, "/bin/sh", "-c", "true"], "#{root}/case/workspace")
    patch = "#{root}/case/data-runs/checkpoints/T/#{'a' * 32}/#{'b' * 36}.patch"
    assert Act24Continuity.trusted_command?(settings, [settings.fetch("git"), "apply", "--check", "--binary", patch], "#{root}/replay-0")
    refute Act24Continuity.trusted_command?(settings, [settings.fetch("git"), "apply", "--binary", "--directory=/real", patch], "#{root}/replay-0")
    refute Act24Continuity.trusted_command?(settings, [settings.fetch("git"), "apply", "--binary", "/real/candidate.patch"], "#{root}/replay-0")
  end

  # Checks generated scope/secret/accounting policy without invoking Seatbelt.
  # Native syntax and actual enforcement remain a separate host qualification.
  def test_role_policies_and_environment_keep_worker_scope_narrow
    settings = config
    worker = Act24Continuity.policy(settings, "worker")
    test = Act24Continuity.policy(settings, "test")
    controller = Act24Continuity.policy(settings, "controller")
    assert_includes worker, "(deny default)"
    assert_includes worker, "(deny process-fork)"
    assert_includes worker, '(allow file-write* (subpath "/synthetic/case/workspace"))'
    refute_includes test, '(allow file-write* (subpath "/synthetic/case/workspace"))'
    refute_includes worker, '(allow file-read* file-map-executable (subpath "/synthetic"))'
    refute_includes worker, "network-outbound"
    assert_includes controller, '(deny file-write* (literal "/synthetic/dispatch-budget.json"))'
    assert_includes controller, '(deny file-read* (literal "/synthetic/supervisor-secret"))'
    environment = Act24Continuity.environment(settings)
    refute environment.key?("RUBYOPT")
    refute environment.key?("OPENAI_API_KEY")
    assert_equal "/synthetic/case/data", environment.fetch("AGENT_CODING_TOOL_DATA_DIR")
    assert_equal "/dev/null", environment.fetch("GIT_CONFIG_GLOBAL")
  end

  # Validates the native CLI form and actual failure handoff in process only.
  # Writes inert fixture bytes; it never invokes the fake worker or source/test.
  def test_resume_requires_failed_result_candidate_and_exact_original_bytes
    Dir.mktmpdir("act24-decisions-") do |root|
      Dir.chdir(root) do
        prompt = { "workspace" => root, "session" => Act24Worker::SESSION, "objective" => "Return 42; preserve the test and scope" }
        initial = Act24Worker.change(["exec", "--json", "-"], prompt, root)
        assert_equal [Act24Worker::INITIAL, Act24Worker::TEST], initial
        File.binwrite("answer.rb", initial.first)
        File.binwrite("answer_test.rb", initial.last)
        resume = ["exec", "resume", "--json", Act24Worker::SESSION, "-"]
        assert_raises(KeyError) { Act24Worker.change(resume, prompt, root) }
        stdout, stderr = "\x00\xffout".b, "expected 42\x00\xfe".b
        failure = { "exit" => 1, "argv" => ["act", "checkpoint", "gate"], "stdout_hex" => stdout.unpack1("H*"), "stderr_hex" => stderr.unpack1("H*"),
          "stdout_sha256" => Digest::SHA256.hexdigest(stdout), "stderr_sha256" => Digest::SHA256.hexdigest(stderr) }
        complete = prompt.merge("failure" => failure, "candidate" => { "sha256" => "a" * 64, "attempt" => "b" * 32, "base_sha" => "c" * 40 },
          "files_sha256" => initial.map { |bytes| Digest::SHA256.hexdigest(bytes) })
        assert_equal [Act24Worker::CORRECTED, Act24Worker::TEST], Act24Worker.change(resume, complete, root)
        assert_equal initial, Act24Worker.change(resume, complete.merge("fixture_fault" => "no_progress"), root)
        assert_raises(RuntimeError) { Act24Worker.change(resume, complete.merge("failure" => failure.merge("exit" => 0)), root) }
        assert_raises(RuntimeError) { Act24Worker.change(resume, complete.merge("failure" => failure.merge("stderr_hex" => "00")), root) }
        assert_raises(RuntimeError) { Act24Worker.change(resume, complete.merge("session" => "other"), root) }
        assert_raises(RuntimeError) { Act24Worker.change(["exec", "resume", "--last", "-"], complete, root) }
        File.binwrite("answer_test.rb", "exit 0\n")
        assert_raises(RuntimeError) { Act24Worker.change(resume, complete, root) }
      end
    end
  end

  # Exercises capture's exact bytes/status and exception retention with an inert
  # completion-file stub. No process is launched; native supervision is NOT RUN.
  def test_observer_retains_binary_output_failure_and_exception
    Dir.mktmpdir("act24-observer-") do |root|
      %w[captures jobs].each { |name| Dir.mkdir("#{root}/#{name}") }
      settings = config(root)
      original_save = Act24Continuity.method(:save)
      completion = lambda do |path, value, **options|
        original_save.call(path, value, **options)
        if path.end_with?(".json") && path.include?("/jobs/")
          token = File.basename(path, ".json")
          File.binwrite("#{root}/captures/#{token}.stdout", "text\x00\xff".b)
          File.binwrite("#{root}/captures/#{token}.stderr", "failed\x00\xfe".b)
          original_save.call("#{path}.done", { "exit" => 19, "signal" => nil, "reaped_by" => 123 })
        end
      end
      result = Act24Continuity.stub(:save, completion) { Act24Continuity.capture(settings, ["inert"], cwd: root, input: "\x00\xfd".b) }
      assert_equal 19, result.fetch("exit")
      assert_equal "text\x00\xff".b, [result.fetch("stdout_hex")].pack("H*")
      assert_equal Digest::SHA256.hexdigest("failed\x00\xfe".b), result.fetch("stderr_sha256")
      assert_equal Digest::SHA256.hexdigest("\x00\xfd".b), result.fetch("stdin_sha256")
      assert result.fetch("seconds") >= 0
      rejected = lambda do |path, value, **options|
        original_save.call(path, value, **options)
        original_save.call("#{path}.done", { "error" => "injected refusal" }) if path.include?("/jobs/")
      end
      assert_raises(RuntimeError) { Act24Continuity.stub(:save, rejected) { Act24Continuity.capture(settings, ["inert"], cwd: root) } }
      records = Dir.glob("#{root}/captures/*.json").map { |path| Act24Continuity.read(path) }
      assert records.any? { |record| record.dig("exception", "message") == "confined job refused: injected refusal" }
    end
  end

  # Demonstrates a worker/test zero exit cannot override immutable expected
  # bytes. The candidate execution seam is stubbed, not actually dispatched.
  def test_independent_verifier_rejects_claims_edited_tests_and_symlinks
    Dir.mktmpdir("act24-verifier-") do |root|
      FileUtils.mkdir_p("#{root}/case/workspace")
      workspace = "#{root}/case/workspace"
      File.binwrite("#{workspace}/answer.rb", Act24Worker::INITIAL)
      File.binwrite("#{workspace}/answer_test.rb", "exit 0\n")
      claim = { "exit" => 0, "stdout_hex" => "success marker".unpack1("H*"), "stderr_hex" => "" }
      capture_io do
        Act24Continuity.stub(:capture, claim) do
          assert_equal 1, Act24Continuity.gate(config(root))
          File.binwrite("#{workspace}/answer.rb", Act24Worker::CORRECTED)
          assert_equal 1, Act24Continuity.gate(config(root))
          File.binwrite("#{workspace}/answer_test.rb", Act24Worker::TEST)
          assert_equal 0, Act24Continuity.gate(config(root))
          File.rename("#{workspace}/answer.rb", "#{workspace}/target")
          File.symlink("target", "#{workspace}/answer.rb")
          assert_equal 1, Act24Continuity.gate(config(root))
        end
      end
    end
  end
end
