# frozen_string_literal: true

require_relative 'no_git_execution'

# Fixture-only feedback controls must not load ACT merely to spawn a sleeper:
# killed non-ACT children cannot borrow or lose production coverage evidence.
module FeedbackProcesses
  WORKER = File.realpath(File.join(__dir__, 'fixtures/feedback_worker.rb')).freeze
  HASH = '819bd831ee7663efa4cdad8ff8b731d5a49bb3f81b916827506d1ef97c93a9f1'

  # Binds one fixed mode invocation, retaining real coverage and reviewed bootstraps.
  def self.permit(arguments, options = {})
    preloads = {}
    bundler = $LOADED_FEATURES.find { |path| path.end_with?('/bundler/setup.rb') }
    preloads[bundler] = Digest::SHA256.file(bundler).hexdigest if bundler
    preloads[NoGitExecution::COVERAGE] = Digest::SHA256.file(NoGitExecution::COVERAGE).hexdigest if ENV['ACT_COVERAGE_CONTEXT']
    NoGitExecution::Permit.new(script: WORKER, sha256: HASH, arguments: arguments, preloads: preloads, options: options)
  end
end
