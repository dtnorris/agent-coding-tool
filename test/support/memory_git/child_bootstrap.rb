# frozen_string_literal: true

# Explicit approved-child preload, before the public entry point requires ACT.
# No production ENV switch exists. The guard is also a command-line preload, so
# clearing RUBYOPT inside a child cannot remove the already active boundary.
require_relative "../no_git_execution"
require_relative "broker"
raise MemoryGit::Mismatch, "missing cold-world handoff" unless ENV["ACT_TEST_MEMORY_ENDPOINT"]
endpoint = JSON.parse(ENV.fetch("ACT_TEST_MEMORY_ENDPOINT"))
MemoryGit::Session.instance_variable_set(:@transport, MemoryGit::Client.new(endpoint))
require_relative "../../coding_skill_support"
