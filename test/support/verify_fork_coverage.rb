# frozen_string_literal: true

require_relative 'no_git_execution'
require_relative '../feedback_coverage'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'minitest/autorun'
Minitest::Assertions.diff = nil

# Focused instrumentation controls, separate from the public tunnel acceptance.
class ForkCoverageVerifier < Minitest::Test
  # Creates a complete independent denominator and fresh coverage context, then
  # runs an exact guarded Ruby fixture. Returns context and genuine native status.
  def with_owner(mode)
    Dir.mktmpdir('act-owner-', ENV.fetch('TMPDIR')) do |root|
      %w[lib bin evidence].each { |path| Dir.mkdir(File.join(root, path)) }
      File.write(File.join(root, 'lib/parent_probe.rb'), ":parent_only\n")
      File.write(File.join(root, 'lib/child_probe.rb'), ":child_only\n")
      File.write(File.join(root, 'bin/agent-coding-tool'), ":unloaded\n")
      context = { 'root' => root, 'directory' => File.join(root, 'evidence'),
        'invocation' => SecureRandom.uuid, 'selection' => mode, 'stage' => 'fork',
        'sources' => FeedbackCoverage.sources(root), 'layout' => FeedbackCoverage.layout(root) }
      path = File.join(root, 'context.json')
      File.write(path, JSON.generate(context))
      script = File.join(__dir__, 'fixtures/fork_owner.rb')
      preloads = { NoGitExecution::COVERAGE => Digest::SHA256.file(NoGitExecution::COVERAGE).hexdigest }
      bundler = $LOADED_FEATURES.find { |feature| feature.end_with?('/bundler/setup.rb') }
      preloads[bundler] = Digest::SHA256.file(bundler).hexdigest if bundler
      permit = NoGitExecution::Permit.new(script: script, sha256: Digest::SHA256.file(script).hexdigest,
        arguments: [mode, root], preloads: preloads, environment: { 'ACT_COVERAGE_CONTEXT' => path })
      output, error, status = NoGitExecution.with_permit(permit) { Open3.capture3(permit.environment, *permit.argv) }
      assert status.success?, error
      if ENV['FORK_COVERAGE_EVIDENCE']
        destination = File.join(ENV.fetch('FORK_COVERAGE_EVIDENCE'), "#{mode}-#{context.fetch('invocation')}")
        FileUtils.mkdir_p(destination)
        FileUtils.cp_r(root, File.join(destination, 'before-controls'))
      end
      yield context, output
      FileUtils.cp_r(root, File.join(destination, 'after-controls')) if destination
    end
  end

  # A real owner retains PID, wait status, EOF and descendant guard; its fresh
  # coverage cannot borrow parent hits, and missing completion fails collection.
  def test_fresh_owner_and_missing_completion
    with_owner('positive') do |context, _output|
      records = Dir.glob(File.join(context.fetch('directory'), '*.json')).map { |path| [path, JSON.parse(File.read(path))] }
      assert_equal 2, records.length
      child_path, child = records.find { |_path, row| row.fetch('files').fetch('lib/child_probe.rb').values.any?(&:positive?) }
      assert child
      assert child.fetch('files').fetch('lib/parent_probe.rb').values.all?(&:zero?)
      assert FeedbackCoverage.collect(context)
      File.unlink(child_path)
      assert_raises(RuntimeError) { FeedbackCoverage.collect(context) }
    end
  end

  # Cached entry, absent declaration, altered callsite and reused permits refuse.
  def test_negative_execution_controls
    %w[cached undeclared wrong_line reuse].each do |mode|
      with_owner(mode) do |context, output|
        assert_includes output, 'REFUSED'
        assert FeedbackCoverage.collect(context)
      end
    end
  end

  # Source substitution cannot issue a fork capability, even at a valid path.
  def test_wrong_source_hash
    assert_raises(NoGitExecution::ProhibitedExecution) do
      NoGitExecution::ForkPermit.new(source: __FILE__, sha256: '0' * 64, line: 1)
    end
  end

  # Changed context or source evidence is rejected by the unchanged collector.
  def test_wrong_context_and_source
    with_owner('positive') do |context, _output|
      %w[invocation sources].each do |key|
        changed = context.merge(key => 'wrong')
        assert_raises(RuntimeError) { FeedbackCoverage.collect(changed) }
      end
    end
  end
end
