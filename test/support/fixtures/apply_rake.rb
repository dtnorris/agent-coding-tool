# frozen_string_literal: true

# Fixed Ruby entry to the real installed Rake API; the parent checks the exact
# fixture Rakefile and tasks. Bundler setup remains a mandatory reviewed preload.
require 'rake'
Rake.application.run(ARGV)
