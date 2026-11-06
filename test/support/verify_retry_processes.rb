# frozen_string_literal: true

require_relative 'no_git_execution'
require_relative '../test_helper'
require_relative 'retry_processes'
require_relative 'validation_processes'
require_relative 'native_pilot_processes'
require 'minitest/mock'
require 'timeout'

# Standalone process-cost contract; loading the cold retry adapter is confined
# to this interpreter. Its additive inventory does not replace family acceptance.
class RetryProcessCostVerifier < Minitest::Test
  include ValidationProcesses

  # Yields one independent fixture root/environment and restores all settings.
  # Filesystem and assertion failures propagate after owned fixture cleanup.
  def fixture
    previous = ENV['ACT_RETRY_ROOT']
    Dir.mktmpdir('retry-cost-') do |root|
      ENV['ACT_RETRY_ROOT'] = root
      environment = %w[HOME PATH TMPDIR CODEX_HOME LANG LC_ALL].to_h { |key| [key, ENV[key]] }.compact
      yield root, environment
    end
  ensure
    ENV['ACT_RETRY_ROOT'] = previous
  end

  # Empty byte streams and genuine exit semantics need no status-only child.
  # Comparing the whole audit catches a returned status factory even if cached.
  def test_lsof_bytes_exit_and_zero_launches
    fixture do |root, _environment|
      before = NoGitExecution.audit
      output, error, status = Open3.capture3('lsof', '-n', '-P', '+D', root)
      assert_equal ''.b, output
      assert_equal ''.b, error
      assert_equal Encoding::BINARY, output.encoding
      assert_equal Encoding::BINARY, error.encoding
      assert_instance_of AgentCodingTool::CommandResult, status
      assert_equal 1, status.exitstatus
      assert status.exited?
      refute status.success?
      refute status.signaled?
      assert_nil status.termsig
      assert_equal before, NoGitExecution.audit
    end
  end

  # Changed lsof flags, argument counts, environment or execution options cannot
  # borrow the declared observation, and the normal guard blocks native fallback.
  def test_lsof_changed_envelopes_refuse
    fixture do |root, _environment|
      requests = [
        [['lsof', '-n', '+D', root], {}],
        [['lsof', '-n', '-P', '+D', root, 'extra'], {}],
        [[{}, 'lsof', '-n', '-P', '+D', root], {}],
        [['lsof', '-n', '-P', '+D', root], { chdir: root }]
      ]
      before = NoGitExecution.audit.count { |row| row['decision'] == 'ALLOW' }
      requests.each do |arguments, options|
        assert_raises(NoGitExecution::ProhibitedExecution) { Open3.capture3(*arguments, **options) }
      end
      assert_equal before, NoGitExecution.audit.count { |row| row['decision'] == 'ALLOW' }
    end
  end

  # Independent literal bytes qualify all five modeled responses. Mutation of
  # one returned stream must not poison another call or launch a hidden child.
  def test_preflight_raw_observations_and_fresh_streams
    fixture do |_root, environment|
      before = NoGitExecution.audit
      worker = File.join(ChildProcesses::FIXTURES, 'retry_worker.rb')
      expected = [
        [%w[--version], "codex-cli 0.162.1\n"],
        [%w[exec --help], "--sandbox workspace-write --config --json --output-last-message --ignore-user-config --ignore-rules --model\n"],
        [%w[login --help], "status\n"],
        [%w[login status], "Logged in using ChatGPT\n"],
        [%w[sandbox --help], "Usage: codex sandbox [OPTIONS] [COMMAND]...\n"]
      ]
      expected.each do |arguments, bytes|
        output, error, status = Open3.capture3(environment, worker, *arguments, unsetenv_others: true)
        assert_equal bytes.b, output
        assert_equal ''.b, error
        assert_equal [0, nil, true, false, true],
          [status.exitstatus, status.termsig, status.exited?, status.signaled?, status.success?]
        output.replace('corrupt')
        assert_equal bytes.b, Open3.capture3(environment, worker, *arguments, unsetenv_others: true).first
      end
      assert_equal before, NoGitExecution.audit
    end
  end

  # Capability replies require the same sanitized environment/options and pinned
  # executable bytes as real preflight. Drift cannot silently become success.
  def test_preflight_changed_envelope_and_source_refuse
    fixture do |_root, environment|
      worker = File.join(ChildProcesses::FIXTURES, 'retry_worker.rb')
      [environment.merge('UNDECLARED' => '1'), environment.merge('PATH' => '/foreign')].each do |changed|
        assert_raises(NoGitExecution::ProhibitedExecution) do
          Open3.capture3(changed, worker, '--version', unsetenv_others: true)
        end
      end
      [{}, { unsetenv_others: false }, { unsetenv_others: true, stdin_data: 'extra' }].each do |options|
        assert_raises(NoGitExecution::ProhibitedExecution) { Open3.capture3(environment, worker, '--version', **options) }
      end
      Digest::SHA256.stub(:file, Struct.new(:hexdigest).new('0' * 64)) do
        assert_raises(NoGitExecution::ProhibitedExecution) do
          Open3.capture3(environment, worker, '--version', unsetenv_others: true)
        end
      end
      root = ENV.delete('ACT_RETRY_ROOT')
      begin
        assert_raises(KeyError) { Open3.capture3(environment, worker, '--version', unsetenv_others: true) }
      ensure
        ENV['ACT_RETRY_ROOT'] = root
      end
    end
  end

  # One actual bounded process per static capability proves the finite fake's
  # bytes/status agree under the same cleared environment. Production transport
  # still drains pipes, translates native status and kills/reaps on its deadline.
  def test_real_preflight_process_parity
    fixture do |root, environment|
      worker = File.join(ChildProcesses::FIXTURES, 'retry_worker.rb')
      [%w[--version], %w[exec --help], %w[login --help], %w[login status], %w[sandbox --help]].each do |arguments|
        output, error, status = Open3.capture3(environment, worker, *arguments, unsetenv_others: true)
        forwarded = environment.merge('ACT_RETRY_ROOT' => root).merge(AgentCodingTool::Bootstrap::CHILD_ENVIRONMENT)
        forwarded['ACT_COVERAGE_CONTEXT'] = ENV['ACT_COVERAGE_CONTEXT'] if ENV['ACT_COVERAGE_CONTEXT']
        approval = ChildProcesses.permit('retry_worker', arguments: arguments, environment: forwarded,
          options: { unsetenv_others: true, pgroup: true })
        before = NoGitExecution.audit.count { |row| row['decision'] == 'ALLOW' }
        real = NoGitExecution.with_permit(approval) do
          AgentCodingTool::NativeCommandTransport.new.call(approval.argv, env: approval.environment,
            timeout: 2, unsetenv_others: true)
        end
        assert_equal [output, error, status.exitstatus, status.termsig],
          [real.stdout, real.stderr, real.exitstatus, real.termsig]
        assert_equal before + 1, NoGitExecution.audit.count { |row| row['decision'] == 'ALLOW' }
      end
    end
  end

  # Exercises a cleared, reviewed same-source child after ambient resolver drift.
  # The endpoint is never contacted: these fixed commands need no Git operation.
  # Captures the actual permit, preserving its hashes, coverage and single use.
  # Assertions and native process errors propagate; all environment edits restore.
  def cold_bootstrap_handoff(name)
    previous = ENV.to_h
    fixture do |root, environment|
      root = File.realpath(root)
      ENV['ACT_RETRY_ROOT'] = root
      ENV['ACT_TEST_MEMORY_ENDPOINT'] = '{}'
      %w[ACT_IMPLEMENTATION ACT_RESOLVED_COMPOSITION ACT_COMPONENT_ROOT ACT_SPLIT_DEVELOPMENT_ROOT].each do |key|
        ENV[key] = 'changed-after-bootstrap'
      end
      ENV['UNRELATED_SECRET'] = 'never-forward'
      original = ChildProcesses.method(:permit)
      approvals = []
      observe = lambda do |child, **fields|
        assert_equal name, child
        original.call(child, **fields).tap { |approval| approvals << approval }
      end
      unchanged = environment.dup
      ChildProcesses.stub(:permit, observe) { yield root, environment }
      assert_equal unchanged, environment
      assert_equal 1, approvals.length
      approval = approvals.fetch(0)
      bootstrap = AgentCodingTool::Bootstrap::CHILD_ENVIRONMENT
      assert_equal bootstrap, approval.environment.slice(*bootstrap.keys)
      assert_equal '{}', approval.environment.fetch('ACT_TEST_MEMORY_ENDPOINT')
      assert_equal true, approval.options.fetch(:unsetenv_others)
      assert approval.used?, 'worker must cross the real guarded process boundary'
      expected = environment.merge(bootstrap).merge('ACT_TEST_MEMORY_ENDPOINT' => '{}')
      expected['ACT_RETRY_ROOT'] = root if name == 'retry_worker'
      expected['ACT_COVERAGE_CONTEXT'] = ENV['ACT_COVERAGE_CONTEXT'] if ENV['ACT_COVERAGE_CONTEXT']
      assert_equal expected, approval.environment.reject { |key, _value| key == 'RUBYOPT' }
    end
  ensure
    ENV.replace(previous)
  end

  # Reaps a real spawned fixture within five seconds, returning raw files/status.
  # Timeout/failure kills and reaps only this owned process group; errors propagate.
  def capture_spawn(root)
    File.open(File.join(root, 'stdout'), 'w+b') do |output|
      File.open(File.join(root, 'stderr'), 'w+b') do |error|
        pid = nil
        begin
          pid = yield output, error
          _child, status = Timeout.timeout(5) { Process.wait2(pid) }
          pid = nil
          output.rewind
          error.rewind
          [output.read, error.read, status]
        ensure
          if pid
            Process.kill('KILL', -pid) rescue Errno::ESRCH
            Process.waitpid(pid) rescue Errno::ECHILD
          end
        end
      end
    end
  end

  # The launcher's real worker executes with frozen bootstrap and real final IO.
  def test_spawn_worker_preserves_cold_bootstrap
    cold_bootstrap_handoff('retry_worker') do |root, environment|
      final = File.join(root, 'final')
      output, error, status = capture_spawn(root) do |stdout, stderr|
        File.open(File::NULL, 'r') do |input|
          RetryProcesses.spawn_worker(environment, File.join(ChildProcesses::FIXTURES, 'retry_worker.rb'),
            'exec', '--output-last-message', final, chdir: root, unsetenv_others: true,
            pgroup: true, in: input, out: stdout, err: stderr)
        end
      end
      assert status.success?, error
      assert_equal 'thread.started', JSON.parse(output).fetch('type')
      assert_equal "No candidate. Human judgment required.\n", File.binread(final)
    end
  end

  # The transport adapter retains bounded real drains and nonzero worker status.
  def test_transport_preserves_cold_bootstrap
    cold_bootstrap_handoff('retry_worker') do |root, environment|
      File.write(File.join(root, 'mode'), 'nonzero')
      result = AgentCodingTool::NativeCommandTransport.new.call(
        [File.join(ChildProcesses::FIXTURES, 'retry_worker.rb'), 'exec', '--output-last-message', File.join(root, 'final')],
        cwd: root, env: environment, input: "prompt\x00\xff".b, timeout: 2, unsetenv_others: true, pgroup: true)
      assert_equal 7, result.exitstatus, result.stderr
      assert_equal 'thread.started', JSON.parse(result.stdout).fetch('type')
    end
  end

  # The direct sandbox probe still performs real allowed/denied fixture writes.
  def test_capture_preserves_cold_bootstrap
    cold_bootstrap_handoff('retry_worker') do |root, environment|
      allowed = File.join(root, 'allowed')
      denied = File.join(root, 'denied')
      Dir.mkdir(allowed)
      output, error, status = Open3.capture3(environment, File.join(ChildProcesses::FIXTURES, 'retry_worker.rb'),
        'sandbox', 'sandbox_workspace_write.writable_roots=[]', 'act-probe',
        File.join(allowed, 'probe'), denied, chdir: allowed, unsetenv_others: true)
      assert status.success?, error
      assert_equal "1\n0\n", output
      assert_equal 'breach', File.binread(File.join(allowed, 'probe'))
      refute File.exist?(denied)
    end
  end

  # Shared-world delivery validators preload this same ACT before emitting bytes.
  def test_validation_preserves_cold_bootstrap
    cold_bootstrap_handoff('validation_worker') do |root, environment|
      File.binwrite(File.join(root, 'fixture-validation.rb'), File.binread(File.join(ChildProcesses::FIXTURES, 'validation_worker.rb')))
      with_validation_processes do
        Open3.popen3(environment, *validation_command('2 tests, 3 assertions', 7),
          chdir: root, unsetenv_others: true, pgroup: true) do |input, output, error, waiter|
          input.close
          assert_equal "2 tests, 3 assertions\n", output.read
          diagnostic = error.read
          assert_equal 7, waiter.value.exitstatus, diagnostic
        end
      end
    end
  end

  # A pilot's reviewed shared-world substitute retains real binary IO/status.
  def test_native_pilot_preserves_cold_bootstrap
    cold_bootstrap_handoff('native_pilot_process') do |root, environment|
      profile = File.join(root, 'modeled.sb')
      File.write(profile, 'deterministic fixture boundary; never sent to sandbox-exec')
      output, error, status = capture_spawn(root) do |stdout, stderr|
        NativePilotProcesses.with_boundary do
          Process.spawn(environment, '/usr/bin/sandbox-exec', '-f', profile, RbConfig.ruby, 'binary',
            chdir: root, unsetenv_others: true, pgroup: true, out: stdout, err: stderr)
        end
      end
      assert_equal 7, status.exitstatus, error
      assert_equal "checked\x00\xff".b, output
      assert_equal "diagnostic\x00\xfe".b, error
    end
  end
end
