# frozen_string_literal: true

require_relative '../../../lib/agent_coding_tool'

# Cold state publication oracle: reads the real filesystem in a new interpreter.
# The parent supplies one store root; parse and filesystem failures remain fatal.
puts JSON.generate(AgentCodingTool::StateStore.new(ARGV.fetch(0)).load('T1'))
