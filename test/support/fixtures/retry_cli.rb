# frozen_string_literal: true

# Cold public retry/reset entry with fixed, reviewed external fault boundaries.
require_relative '../retry_processes'
require_relative 'retry_boundaries'
require_relative 'reset_boundaries' if ENV['ACT_RETRY_HARD_RESET'] == '1'
load File.expand_path('../../../bin/agent-coding-tool', __dir__)
