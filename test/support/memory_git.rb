# frozen_string_literal: true

# Test-only composition root. Production never requires this backend. TST-36
# installs patch/tree commands by reopening World in separate capability files;
# absent implementations raise Mismatch, never successful empty observations.
require_relative "memory_git/core"
require_relative "memory_git/refs"
require_relative "memory_git/status_index"
require_relative "memory_git/remotes"
require_relative "memory_git/worktrees"
