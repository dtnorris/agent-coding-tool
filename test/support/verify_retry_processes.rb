# frozen_string_literal: true

require_relative 'no_git_execution'
require_relative '../test_helper'
require_relative 'retry_processes'
require 'minitest/mock'

# Standalone process-cost contract; loading the cold retry adapter is confined
# to this interpreter. Its additive inventory does not replace family acceptance.
class RetryProcessCostVerifier < Minitest::Test
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
        forwarded = environment.merge('ACT_RETRY_ROOT' => root)
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
end
