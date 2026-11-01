# frozen_string_literal: true

require_relative "no_git_execution"
require "json"
require_relative "../git_contract/observations"

# Reviewed non-Git Ruby process boundaries. Exact scripts/argv/preloads are
# single-use permits; this helper never permits executable-only or inline code.
module ChildProcesses
  FIXTURES = File.realpath(File.join(__dir__, "fixtures")).freeze

  HASHES = {
    "process_family" => "ac335450fd2d2acf30f9a3503a41878108c40784b362fbefc9aee5359f3aebec",
    "evidence_cli" => "70b60a59ecfb86888f8a4cdbe68c06ea304ea9c1ff092d7b5024346d134d42d0",
    "launcher_cli" => "a3db63829a6695c0deb038fab6c6b51d49a58c73e6693d6fb74b34e14fd41ec1",
    "external_activity" => "612f9cc2995860dde1be2a590c18c6b67b51aee96e4121c1906add87cac1c48f",
    "state_reader" => "26c64e87985ca8bc2c23110e0434893cd81b857072bc2c0fe8ba4ff2723446bb",
    "planning_consumer" => "bcd6a01ccf04860afcd409e3ac8cfc4a82ea43afda995c7763fb4dd3edf47a90",
    "status" => "2b3b1ffc56c1774ddaf4c11329d6da73984e588cf95ed74049d97a13bc0beeee",
    "manual_worker" => "405dc429f07e250755eb0a4406d7e5afdf47338412ec7e3e517a467a3f89f2e7",
    "cold_cli" => "c0fcdc00673b283c718fd8c93aa3b27b92590afa76eecf26009d98af0b516a69",
    "process_probe" => "82cb500628f739ca3c4cd750fd34a13ce249bdbee68f486d6bd5efee38774b74",
    "launcher_worker" => "cbdf71d69c007fb83bd3d103c279fead2880d2e57b51b0d959efee58eb0f9892"
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
