# frozen_string_literal: true

# Reads one private store through production parsing in a fresh interpreter.
# ARGV contains its root; malformed state and filesystem failures propagate.
require_relative '../../../lib/agent_coding_tool'
puts JSON.generate(AgentCodingTool::StateStore.new(ARGV.fetch(0)).load('T1'))
