# frozen_string_literal: true

# Explicit opt-in composition for patch/index/tree consumers. Core-only verifiers
# retain their own absent-capability checks; production never loads these files.
require_relative "../memory_git"
require_relative "patches"
require_relative "trees"
require_relative "reconstruction"
