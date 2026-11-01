# frozen_string_literal: true

# Public entry after shared-world startup, with reviewed real validator children.
require_relative '../apply_processes'
# Bundler's mandatory startup may prepend its own bin directory. Restore only
# this exact test-owned missing-executable PATH before invoking the public CLI.
if (path = ENV.delete('ACT_APPLY_TEST_PATH'))
  abort 'unsafe missing-bundle PATH' unless File.basename(path) == 'only-git' &&
    File.realpath(path) == path && File.stat(path).uid == Process.uid && (File.stat(path).mode & 0o077).zero?
  ENV['PATH'] = path
end
load File.expand_path('../../../bin/agent-coding-tool', __dir__)
