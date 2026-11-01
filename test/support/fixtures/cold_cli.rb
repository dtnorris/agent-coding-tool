# frozen_string_literal: true

# Executes the actual public entry point after the approved bootstrap. Genuine
# process exit, public argv parsing and all production filesystem effects remain.
raise "missing shared-world preload" unless defined?(MemoryGit::Client) && MemoryGit::Session.transport.is_a?(MemoryGit::Client)
load File.expand_path("../../../bin/agent-coding-tool", __dir__)
