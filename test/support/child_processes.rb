# frozen_string_literal: true

require_relative "no_git_execution"
require "json"
require_relative "../git_contract/observations"

# Reviewed non-Git Ruby process boundaries. Exact scripts/argv/preloads are
# single-use permits; this helper never permits executable-only or inline code.
module ChildProcesses
  FIXTURES = File.realpath(File.join(__dir__, "fixtures")).freeze

  HASHES = {
    "native_observer" => "42dc07d57751164e7180ccd17bfa7f5991f746828711d719723eba5c7c5c27a7",
    "feedback_worker" => "64b4781273cdf1bf8cb4ff539a62d23f0875f41db5acb9002603609df8d043a8",
    "retry_probe" => "2ac042125d3e8334ec69a79fcd8be39703648edafe529b2609e6f687d6b93fa3",
    "retry_worker" => "682291fe5581214252854c591db0599f5ff6197f4c0109442f22aa247c4dff93",
    "retry_cli" => "44d599341d8f53b78c7204f18a20ed5c1f2ad7cba5418db8186d7bf8a364c709",
    "apply_cli" => "3a04cc7d56e4260165359b77ee14fb6fd7d39b17d147d378ad9a7073a1ced853",
    "readiness_cli" => "0e103eb6aeff4937a2409fd48761805e14d087f51d44a87e534bd28a4fbfcf83",
    "checkpoint_cli" => "2619e666754844fae65605c1083f9f9af946026203380ce742b5c8c562327999",
    "checkpoint_validator" => "1edde26a02c4971b89ba67e015bb0416fb5c99512f8fedbdd12121f5458490e4",
    "icebox_control" => "4de00827a67fc6457c8ea8609f8cf8241e377240a88db13e45da3189477c7c9b",
    "icebox_cli" => "049ccce0d2f471256ddd9c7a41e122f77c80f3dfd0f2aa9078987b560a258310",
    "publication_lease" => "5c424dd35af21d56561b89e8b6956200708d3c781223644eeb63bbb4f35cc862",
    "validation_worker" => "ac5c8f580a7949db8a5400a065e3a39edd94422edbb9dfadd5abd5905362955e",
    "evidence_cli" => "5547775b775026b6c45271e7a95a63ee0aec50927dc36d79be13b4e79157cc2b",
    "state_reader" => "c79822d71b24b5147c081f6ac260c143e1de1d11adf55947540be7456ee31a42",
    "external_race" => "29d52f5928ee7cf892557524e177fbceb5ca2af7649642ca8d22c7ff12c78853",
    "launcher_cli" => "b1438e99ece26b9036010a0746a65ea8240860b9d6bbc0a5396e5cd5745bba0a",
    "planning_consumer" => "10952eb6feabb2aa3f106494e494f782e4049964b3ff3e13d145b66e56fdb851",

    "status" => "2b3b1ffc56c1774ddaf4c11329d6da73984e588cf95ed74049d97a13bc0beeee",
    "manual_worker" => "405dc429f07e250755eb0a4406d7e5afdf47338412ec7e3e517a467a3f89f2e7",
    "cold_cli" => "c0fcdc00673b283c718fd8c93aa3b27b92590afa76eecf26009d98af0b516a69",
    "process_probe" => "7cb7536f1c8e40e19a7e0ba49310df26098826a47860b1bf94de7ef74109bb15",
    "launcher_worker" => "431b98fe25a165b40ec972b906b950884b2291c5d2966a0407cdb797d4a18947"
  }.freeze

  # Builds a permit for a named repository-owned script and exact invocation.
  # Coverage and optional shared-world handoff load before the child's product.
  # Unknown names, changed ambient bootstrap and invalid envelopes fail closed.
  def self.permit(name, arguments: [], environment: {}, options: {}, endpoint: nil, operation: :spawn)
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
      arguments: arguments, preloads: preloads, environment: environment, options: options, operation: operation)
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
