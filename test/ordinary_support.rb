# frozen_string_literal: true

require "json"
require "minitest/autorun"
require_relative "ordinary_execution"
require_relative "coding_skill_support"
require_relative "skill_observations"

# Installs finite per-case source observations only in the explicit ordinary
# interpreter. No permissive source cache, native fallback or ACT decision stub.
module OrdinarySupport
  CASES = JSON.parse(File.binread(File.join(__dir__, "ordinary_cases.json"))).values.reduce({}, :merge).freeze
  class << self
    attr_accessor :replay
  end

  # Resolves the current case's finite observations, including worker threads.
  # Missing setup or any mismatched/extra read raises, never executing Git.
  class SourceRunner
    # Implements CommandRunner.capture; returns its raw-byte/boolean tuple.
    # Raises UnexpectedObservation on an undeclared request or absent case.
    def capture(*argv, chdir: nil)
      raise GitContract::UnexpectedObservation, "skill read outside ordinary case" unless OrdinarySupport.replay
      OrdinarySupport.replay.capture(*argv, chdir: chdir)
    end
  end

  # Supplies a test-only external runner; the production default remains native.
  module RendererDefaults
    # Forwards constructor options unchanged, supplying only the source boundary.
    # Explicit test runners take precedence; production validation still runs.
    def initialize(**options)
      super(**{ runner: SourceRunner.new }.merge(options))
    end
  end

  # Starts observation accounting before test setup and verifies after teardown.
  module CaseBoundary
    # Installs the declared transcript; unknown case identities raise KeyError.
    # Fixture setup and all body/teardown reads consume the same finite replay.
    def before_setup
      OrdinarySupport.replay = SkillObservations.defaults(CASES.fetch("#{self.class.name}##{name}"))
      super
    end

    # Verifies consumption after every refusal and clears per-case observations.
    # Missing observations fail the case; teardown errors still propagate.
    def after_teardown
      super
    ensure
      begin
        OrdinarySupport.replay&.verify!
      ensure
        OrdinarySupport.replay = nil
      end
    end
  end

  AgentCodingTool::PromptRenderer.prepend(RendererDefaults)
  Minitest::Test.prepend(CaseBoundary)
end
