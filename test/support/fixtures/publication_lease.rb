# frozen_string_literal: true

# Emits a fixture-owned lease response as raw data; the production guard checks
# commit binding, expiration and finite bounds. No payload is executed as code.
STDOUT.binmode.write(File.binread(ARGV.fetch(0)))
