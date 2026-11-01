# frozen_string_literal: true

ORIGINAL_TUNNEL_SPAWN = Process.method(:spawn)
require_relative '../../lib/agent_coding_tool'
require_relative 'tunnel_processes'
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
TunnelProcesses.install

# Alters only the request arriving at the real guard, after production emitted
# its reviewed call. Every negative must refuse before any native ALLOW entry.
module TunnelRequestMutation
  # Sends a changed request or cached native entry; the guard remains intact.
  def spawn(*command, **options)
    mode = Thread.current[:tunnel_mutation]
    return super unless mode
    environment, *argv = command
    case mode
    when :executable then argv[0] = '/usr/bin/true'
    when :arguments then argv << '--changed'
    when :environment then environment = environment.merge('OTHER_SECRET' => 'forbidden')
    when :options then options[:pgroup] = true
    when :context then ENV['ACT_COVERAGE_CONTEXT'] = 'changed-context'
    when :cached then return ORIGINAL_TUNNEL_SPAWN.call(environment, *argv, **options)
    when :reuse
      pid = super(environment, *argv, **options)
      begin
        return super(environment, *argv, **options)
      ensure
        Process.kill('KILL', pid) rescue Errno::ESRCH
        Process.waitpid(pid)
      end
    end
    super(environment, *argv, **options)
  end
end
Process.singleton_class.prepend(TunnelRequestMutation)
Kernel.prepend(TunnelRequestMutation)
Kernel.singleton_class.prepend(TunnelRequestMutation)

# Focused native envelope controls. Existing fork verifier independently owns
# parent-hit exclusion, unauthorized descendants and missing-child completion.
class TunnelProcessVerifier < Minitest::Test
  # Runs the unchanged production inventory under the same scoped composition.
  # Returns native production result, never a synthetic inventory or status.
  def inventory(mode = nil)
    tunnel = AgentCodingTool::EvidenceTunnel.allocate
    Thread.current[:act_tunnel] = tunnel
    Thread.current[:tunnel_mutation] = mode
    tunnel.send(:inventory!)
  ensure
    Thread.current[:act_tunnel] = nil
    Thread.current[:tunnel_mutation] = nil
  end

  # Produces one exact reviewed inventory permission for rejection controls.
  def permission(**changes)
    source = TunnelProcesses::SOURCE
    line = TunnelProcesses.site(source, TunnelProcesses::SOURCE_HASH, '"/bin/ps", "-axo", "comm="')
    options = { argv: ['/bin/ps', '-axo', 'comm='],
      environment: %w[PATH HOME TMPDIR LANG].to_h { |key| [key, ENV[key]] }.compact,
      options: { unsetenv_others: true }, source: source, line: line,
      files: { source => TunnelProcesses::SOURCE_HASH } }
    TunnelProcesses::NativePermit.new(**options.merge(changes))
  end

  # Genuine inventory must execute and preserve production parsing, errors and IO.
  def test_real_inventory
    before = NoGitExecution.audit.count { |row| row['decision'] == 'ALLOW' }
    assert_nil inventory
    assert_equal before + 1, NoGitExecution.audit.count { |row| row['decision'] == 'ALLOW' }
  end

  # Changed executable/argv/env/options/context and cached bypass all fail before
  # native entry. Context is restored after each independently observed refusal.
  def test_envelope_and_cached_refusals
    %i[executable arguments environment options context cached].each do |mode|
      original = ENV['ACT_COVERAGE_CONTEXT']
      before = NoGitExecution.audit.count { |row| row['decision'] == 'ALLOW' }
      assert_raises(NoGitExecution::ProhibitedExecution, mode.to_s) { inventory(mode) }
      assert_equal before, NoGitExecution.audit.count { |row| row['decision'] == 'ALLOW' }
    ensure
      original ? ENV['ACT_COVERAGE_CONTEXT'] = original : ENV.delete('ACT_COVERAGE_CONTEXT')
    end
  end

  # A consumed native permit refuses a second entry at the very same bound
  # production call chain. The first real child is explicitly reaped.
  def test_single_use_native_permission
    before = NoGitExecution.audit.count { |row| row['decision'] == 'ALLOW' }
    assert_raises(NoGitExecution::ProhibitedExecution) { inventory(:reuse) }
    assert_equal before + 1, NoGitExecution.audit.count { |row| row['decision'] == 'ALLOW' }
  end

  # A permission cannot be moved to another source/site, thread or cwd. Source
  # drift controls compare reviewed bytes without rewriting production fixtures.
  def test_source_and_context_binding
    assert_raises(NoGitExecution::ProhibitedExecution) { permission(files: { TunnelProcesses::SOURCE => '0' * 64 }) }
    assert_raises(NoGitExecution::ProhibitedExecution) { permission(line: 1) }
    permit = permission
    assert_raises(NoGitExecution::ProhibitedExecution) do
      NoGitExecution.with_permit(permit) { Process.spawn(permit.environment, *permit.argv, **permit.options) }
    end
    Thread.new do
      assert_raises(NoGitExecution::ProhibitedExecution) { NoGitExecution.with_permit(permit) { Process.spawn(permit.environment, *permit.argv, **permit.options) } }
    end.value
    Dir.mktmpdir do |root|
      Dir.chdir(root) do
        assert_raises(NoGitExecution::ProhibitedExecution) { NoGitExecution.with_permit(permit) { Process.spawn(permit.environment, *permit.argv, **permit.options) } }
      end
    end
    refute permit.used?
  end
end
