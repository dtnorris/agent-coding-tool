# frozen_string_literal: true

require "json"

# Fetches every published pin into an exclusively new CI component parent.
# No branch checkout, shared worktree, development manifest or fallback is used.
module CIComponents
  # Creates parent from split-composition.json at root, invoking only exact Git
  # argv through the supplied runner. Raises on existing storage or fetch errors;
  # bootstrap subsequently verifies revision and every production source digest.
  def self.prepare(root:, parent:, run:)
    lock = JSON.parse(File.binread(File.join(root, "split-composition.json")))
    Dir.mkdir(parent)
    lock.fetch("packages").each do |name, pin|
      raise "invalid package name" unless name.match?(/\Aact-[a-z]+\z/)
      revision = pin.fetch("revision")
      raise "invalid published revision" unless revision.match?(/\A[0-9a-f]{40}\z/)
      package = File.join(parent, name)
      run.call("init", package)
      run.call("-C", package, "remote", "add", "origin", pin.fetch("remote_url"))
      run.call("-C", package, "fetch", "--depth=1", "origin", revision)
      run.call("-C", package, "checkout", "--detach", "FETCH_HEAD")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  parent = File.expand_path(ARGV.fetch(0))
  raise "component root differs" unless parent == ENV.fetch("ACT_COMPONENT_ROOT")
  CIComponents.prepare(root: File.expand_path("..", __dir__), parent: parent,
    run: lambda { |*arguments|
      system({ "GIT_TERMINAL_PROMPT" => "0" }, "git", "-c", "core.hooksPath=/dev/null", *arguments, exception: true)
    })
  require_relative "../lib/agent_coding_tool/bootstrap"
  raise "not published split" unless AgentCodingTool::Bootstrap::COMPOSITION.values_at("mode", "qualification") == ["split", "published"]
  puts JSON.generate(AgentCodingTool::Bootstrap::COMPOSITION)
end
