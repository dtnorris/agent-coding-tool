# frozen_string_literal: true

if ENV["ACT_NATIVE_SUITE"] == "1" && ENV["ACT_ORDINARY_SUITE"] != "1"
  require_relative "native_child_processes"
else
require_relative "no_git_execution"
require "json"
require_relative "../git_contract/observations"

# Reviewed non-Git Ruby process boundaries. Exact scripts/argv/preloads are
# single-use permits; this helper never permits executable-only or inline code.
module ChildProcesses
  FIXTURES = File.realpath(File.join(__dir__, "fixtures")).freeze

  HASHES = {
    "status" => "2b3b1ffc56c1774ddaf4c11329d6da73984e588cf95ed74049d97a13bc0beeee",
    "manual_worker" => "405dc429f07e250755eb0a4406d7e5afdf47338412ec7e3e517a467a3f89f2e7",
    "cold_cli" => "c0fcdc00673b283c718fd8c93aa3b27b92590afa76eecf26009d98af0b516a69",
    "process_probe" => "82cb500628f739ca3c4cd750fd34a13ce249bdbee68f486d6bd5efee38774b74",
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

end
