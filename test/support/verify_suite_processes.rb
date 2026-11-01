# frozen_string_literal: true

require_relative 'suite_processes'
require 'minitest/autorun'
require 'tmpdir'
require_relative 'tunnel_processes'
Minitest::Assertions.diff = nil

# The stronger ordinary bootstrap must retain Permit's immutable byte binding.
class SuiteProcessVerifier < Minitest::Test
  # Creates one fixed suite loader permission without executing a subprocess.
  def permit
    root = File.realpath(File.join(__dir__, '../..'))
    entry = File.join(root, 'test/support/fixtures/suite_entry.rb')
    boundary = File.join(root, 'test/ordinary_execution.rb')
    preloads = { boundary => Digest::SHA256.file(boundary).hexdigest }
    bundler = $LOADED_FEATURES.find { |path| path.end_with?('/bundler/setup.rb') }
    preloads[bundler] = Digest::SHA256.file(bundler).hexdigest if bundler
    SuiteProcesses::OrdinaryPermit.new(script: entry, sha256: Digest::SHA256.file(entry).hexdigest,
      arguments: ['1', 'test/ordinary_boundary_test.rb'], preloads: preloads,
      options: { chdir: root, pgroup: true })
  end

  # Reordering cannot expose an unfrozen preload path for in-place substitution.
  def test_reordered_argv_is_immutable
    approval = permit
    assert approval.argv.frozen?
    approval.argv.each do |argument|
      assert argument.frozen?
      assert_raises(FrozenError) { argument.replace('changed') }
    end
    refute approval.used?
  end

  # The replacement RUBYOPT and every effective environment value are immutable;
  # no alias may mutate both expected/requested bytes after review.
  def test_reordered_environment_is_immutable
    approval = permit
    assert approval.environment.frozen?
    assert approval.environment.fetch('RUBYOPT').frozen?
    assert_raises(FrozenError) { approval.environment.fetch('RUBYOPT').replace('changed') }
    assert approval.instance_variable_get(:@effective_environment).values.all?(&:frozen?)
    refute approval.used?
  end
  # A caller-owned digest cannot rewrite the fork permission's reviewed source.
  def test_fork_source_digest_is_copied
    Dir.mktmpdir('fork-digest-') do |root|
      source = File.join(root, 'owner.rb')
      File.write(source, "Process.fork { exit! 0 }\n")
      digest = Digest::SHA256.file(source).hexdigest
      original = digest.dup
      approval = NoGitExecution::ForkPermit.new(source: source, sha256: digest, line: 1)
      digest.replace('0' * 64)
      assert_equal original, approval.instance_variable_get(:@digest)
      assert approval.instance_variable_get(:@digest).frozen?
      refute approval.used?
    end
  end

  # The native capability must own every digest value, including values supplied
  # through a separate source/config map; changing caller data cannot rebind it.
  def test_native_source_digest_is_copied
    source = TunnelProcesses::SOURCE
    digest = TunnelProcesses::SOURCE_HASH.dup
    line = TunnelProcesses.site(source, digest, '"/bin/ps", "-axo", "comm="')
    approval = TunnelProcesses::NativePermit.new(argv: ['/bin/ps', '-axo', 'comm='],
      environment: %w[PATH HOME TMPDIR LANG].to_h { |key| [key, ENV[key]] }.compact,
      options: { unsetenv_others: true }, source: source, line: line, files: { source => digest })
    digest.replace('0' * 64)
    assert_equal TunnelProcesses::SOURCE_HASH, approval.instance_variable_get(:@files).fetch(source)
    assert approval.instance_variable_get(:@files).values.all?(&:frozen?)
    refute approval.used?
  end

end
