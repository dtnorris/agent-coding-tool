# frozen_string_literal: true

require_relative "no_git_execution"
require "json"
require_relative "../git_contract/observations"

# Reviewed non-Git Ruby process boundaries. Exact scripts/argv/preloads are
# single-use permits; this helper never permits executable-only or inline code.
module ChildProcesses
  FIXTURES = File.realpath(File.join(__dir__, "fixtures")).freeze

  HASHES = {
    "native_pilot_worker" => "5469047bf2959e1e14271f7429a003e3373e61c97f4fe7ed0163e9037fe4aa76",
    "native_pilot_process" => "b6b3d9149ec4177b067361441b6895f87562d107771e739aa4b7e36889e7fd38",
    "native_pilot_controller" => "21cde11081aafa9530639e4b2b24ac8ea37d97ae5686e498e37a3515f11cd1e3",
    "manager_inference" => "fd1f325601c885e930dff62ebb8883f6b778bfbabfe0087e4115a65befedc0f2",
    "bootstrap_cli" => "afa0f903558dfa53bb58706e99d676cc94d2fc76e82f99c69f0e4526fcdac697",
    "process_family" => "ac335450fd2d2acf30f9a3503a41878108c40784b362fbefc9aee5359f3aebec",
    "native_observer" => "42dc07d57751164e7180ccd17bfa7f5991f746828711d719723eba5c7c5c27a7",
    "feedback_worker" => "21dd58ac5596c110732afb351af9900f77ee02126e09da77d0d8d266d953cf89",
    "retry_probe" => "2ac042125d3e8334ec69a79fcd8be39703648edafe529b2609e6f687d6b93fa3",
    "retry_worker" => "682291fe5581214252854c591db0599f5ff6197f4c0109442f22aa247c4dff93",
    "retry_cli" => "44d599341d8f53b78c7204f18a20ed5c1f2ad7cba5418db8186d7bf8a364c709",
    "apply_cli" => "3a04cc7d56e4260165359b77ee14fb6fd7d39b17d147d378ad9a7073a1ced853",
    "readiness_cli" => "0e103eb6aeff4937a2409fd48761805e14d087f51d44a87e534bd28a4fbfcf83",
    "checkpoint_cli" => "2619e666754844fae65605c1083f9f9af946026203380ce742b5c8c562327999",
    "checkpoint_validator" => "1eb4c90c65cf160cfd0f6006319f2cbb854cafb2a517ff20bde36e5f8a4d8ac5",
    "icebox_control" => "4de00827a67fc6457c8ea8609f8cf8241e377240a88db13e45da3189477c7c9b",
    "icebox_cli" => "049ccce0d2f471256ddd9c7a41e122f77c80f3dfd0f2aa9078987b560a258310",
    "publication_lease" => "5c424dd35af21d56561b89e8b6956200708d3c781223644eeb63bbb4f35cc862",
    "validation_worker" => "ac5c8f580a7949db8a5400a065e3a39edd94422edbb9dfadd5abd5905362955e",
    "evidence_cli" => "c1c0eb6d26712c862fe2862c258837b333a6785bb3381f942cfe49f930018e9b",
    "state_reader" => "c79822d71b24b5147c081f6ac260c143e1de1d11adf55947540be7456ee31a42",
    "external_race" => "29d52f5928ee7cf892557524e177fbceb5ca2af7649642ca8d22c7ff12c78853",
    "launcher_cli" => "0652e4128bfaaafee14965bb9281042693ee73dcc943a9c305041546642a62f1",
    "planning_consumer" => "10952eb6feabb2aa3f106494e494f782e4049964b3ff3e13d145b66e56fdb851",

    "status" => "2b3b1ffc56c1774ddaf4c11329d6da73984e588cf95ed74049d97a13bc0beeee",
    "manual_worker" => "f213498808f7953184bd1e751381a96951d294bb082ea40b1986a49cbc5462b5",
    "cold_cli" => "c0fcdc00673b283c718fd8c93aa3b27b92590afa76eecf26009d98af0b516a69",
    "process_probe" => "7cb7536f1c8e40e19a7e0ba49310df26098826a47860b1bf94de7ef74109bb15",
    "launcher_worker" => "bc3ac327c1c88ffab9ea177624032441f85608beca14a940daea1507c053abd1",
    "fake_codex" => "78ee157375d8164caa43b491e57e91c344a701dcbac06cc7cef6642e86b05781"
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

  # Opens genuine Open3 pipes under a single-use permit, releasing the permit
  # before user code can launch another reviewed child. Streams and waiter are
  # closed/joined exactly as Open3's block API; native errors propagate.
  def self.popen(name, arguments: [], environment: {}, endpoint: nil)
    approval = permit(name, arguments: arguments, environment: environment, endpoint: endpoint)
    streams = NoGitExecution.with_permit(approval) { Open3.popen3(approval.environment, *approval.argv) }
    begin
      yield(*streams)
    ensure
      streams.take(3).each { |stream| stream.close unless stream.closed? }
      streams.last.join
    end
  end
end
