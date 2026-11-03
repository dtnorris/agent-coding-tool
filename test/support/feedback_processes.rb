# frozen_string_literal: true

require_relative 'no_git_execution'

# Fixture-only feedback controls must not load ACT merely to spawn a sleeper:
# killed non-ACT children cannot borrow or lose production coverage evidence.
module FeedbackProcesses
  WORKER = File.realpath(File.join(__dir__, 'fixtures/feedback_worker.rb')).freeze
  HASH = '64b4781273cdf1bf8cb4ff539a62d23f0875f41db5acb9002603609df8d043a8'
  VALIDATOR = File.realpath(File.join(__dir__, 'fixtures/feedback_validation.rb')).freeze
  VALIDATOR_HASH = 'ef8044aa154873f8ddc7996aa25c0be3c147d850d79aa04bc8fe3ee13dcec004'

  # Binds one fixed mode invocation, retaining real coverage and reviewed bootstraps.
  def self.permit(arguments, options = {})
    preloads = {}
    bundler = $LOADED_FEATURES.find { |path| path.end_with?('/bundler/setup.rb') }
    preloads[bundler] = Digest::SHA256.file(bundler).hexdigest if bundler
    preloads[NoGitExecution::COVERAGE] = Digest::SHA256.file(NoGitExecution::COVERAGE).hexdigest if ENV['ACT_COVERAGE_CONTEXT']
    NoGitExecution::Permit.new(script: WORKER, sha256: HASH, arguments: arguments, preloads: preloads, options: options)
  end

  # Binds one literal-output validator with a fresh release-file handoff. All
  # streams/status remain native and inherited guard/coverage stay installed.
  def self.validation_permit(arguments, environment:, options:)
    preloads = {}
    bundler = $LOADED_FEATURES.find { |path| path.end_with?('/bundler/setup.rb') }
    preloads[bundler] = Digest::SHA256.file(bundler).hexdigest if bundler
    preloads[NoGitExecution::COVERAGE] = Digest::SHA256.file(NoGitExecution::COVERAGE).hexdigest if ENV['ACT_COVERAGE_CONTEXT']
    NoGitExecution::Permit.new(script: VALIDATOR, sha256: VALIDATOR_HASH, arguments: arguments,
      environment: environment, preloads: preloads, options: options)
  end
end
