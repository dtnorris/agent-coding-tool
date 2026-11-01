# frozen_string_literal: true

require_relative "no_git_execution"
require "json"
require_relative "../git_contract/observations"

# Reviewed non-Git Ruby process boundaries. Exact scripts/argv/preloads are
# single-use permits; this helper never permits executable-only or inline code.
module ChildProcesses
  FIXTURES = File.realpath(File.join(__dir__, "fixtures")).freeze

  HASHES = {
    "icebox_control" => "70537f2603da9cedfeaf62eacb95cb03069d8255a9e0347ada32cb70d3d80e66",
    "icebox_cli" => "d0ff8e39e28e280096079855fbb28ebb17cef8959be8b97640ea5e6e58826e54",
    "publication_lease" => "5c424dd35af21d56561b89e8b6956200708d3c781223644eeb63bbb4f35cc862",
    "validation_worker" => "ac5c8f580a7949db8a5400a065e3a39edd94422edbb9dfadd5abd5905362955e",
    "launcher_cli" => "4f0f2a31de7c889162c422e8aad8b1479050e9f7b6aa79a04730573d596d0874",
    "evidence_cli" => "4d49b4c5aa19578ecc6d256a857a798bb5804e6ab0c7502796039a847ca229a5",
    "planning_consumer" => "10952eb6feabb2aa3f106494e494f782e4049964b3ff3e13d145b66e56fdb851",
    "external_race" => "29d52f5928ee7cf892557524e177fbceb5ca2af7649642ca8d22c7ff12c78853",
    "state_reader" => "c79822d71b24b5147c081f6ac260c143e1de1d11adf55947540be7456ee31a42",
    "status" => "2b3b1ffc56c1774ddaf4c11329d6da73984e588cf95ed74049d97a13bc0beeee",
    "manual_worker" => "405dc429f07e250755eb0a4406d7e5afdf47338412ec7e3e517a467a3f89f2e7",
    "cold_cli" => "c0fcdc00673b283c718fd8c93aa3b27b92590afa76eecf26009d98af0b516a69",
    "process_probe" => "f2179d559824d6090878aaff26d045b86d176c0e9fbc6c79a2586bcfad02b8f2",
    "launcher_worker" => "06d9556d243cb35c43dab7be1b0d752c23b93f865ec34840bbeaf3f239ef864f"
  }.freeze

  # Builds a permit for a named repository-owned script and exact invocation.
  # Coverage and optional shared-world handoff load before the child's product.
  # Unknown names, changed ambient bootstrap and invalid envelopes fail closed.
  def self.permit(name, arguments: [], environment: {}, options: {}, endpoint: nil)
    raise ArgumentError, "unknown child fixture" unless HASHES.key?(name)
    script = File.join(FIXTURES, "#{name}.rb")
    preloads = {}
    if defined?(Bundler)
      bundler = File.realpath($LOADED_FEATURES.find { |path| path.end_with?("/bundler/setup.rb") })
      preloads[bundler] = Digest::SHA256.file(bundler).hexdigest
    end
    preloads[NoGitExecution::COVERAGE] = Digest::SHA256.file(NoGitExecution::COVERAGE).hexdigest if ENV["ACT_COVERAGE_CONTEXT"]
    endpoint ||= JSON.parse(ENV.fetch("ACT_TEST_MEMORY_ENDPOINT")) if ENV["ACT_TEST_MEMORY_ENDPOINT"]
    if endpoint
      bootstrap = File.join(__dir__, "memory_git/child_bootstrap.rb")
      preloads[bootstrap] = Digest::SHA256.file(bootstrap).hexdigest
      environment = environment.merge("ACT_TEST_MEMORY_ENDPOINT" => JSON.generate(endpoint))
    end
    NoGitExecution::Permit.new(script: script, sha256: HASHES.fetch(name),
      arguments: arguments, preloads: preloads, environment: environment, options: options)
  end

  # Captures bounded binary output and genuine reaped status from one approved
  # Ruby child. Deadline/spawn errors remain exceptions; no status is invented.
  def self.capture(name, arguments: [], environment: {}, endpoint: nil, seconds: 2, input: "")
    approval = permit(name, arguments: arguments, environment: environment, endpoint: endpoint, options: { pgroup: true })
    NoGitExecution.with_permit(approval) do
      GitContract::Native.new(seconds: seconds).capture3(approval.environment, *approval.argv, stdin_data: input)
    end
  end
end
