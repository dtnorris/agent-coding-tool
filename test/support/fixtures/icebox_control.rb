# frozen_string_literal: true

# Runs exactly the public Icebox journey with its refusal removed. The parent
# checks the genuine failing assertion and reaped status, never an invented code.
$LOAD_PATH.unshift(File.expand_path('../../../lib', __dir__))
ARGV.replace(['--seed', '2300', '--name', 'test_public_cli_journey'])
require_relative '../../integration/icebox_git_integration'
