# frozen_string_literal: true

# Fixed suite loader replacing the former inline -e program. The parent binds
# this source, exact file/count/selection argv, preloads and coverage context.
root = File.realpath(File.join(__dir__, '../../..'))
# The suite-only reporter stays loaded here; descendants have their own permits
# and cannot inherit or overwrite this interpreter's case reporter.
reporter = File.join(root, 'test/suite_reporter.rb')
ENV['RUBYOPT'] = Shellwords.join(Shellwords.split(ENV.fetch('RUBYOPT', '')).reject { |token| token == "-r#{reporter}" })
$LOAD_PATH.unshift(File.join(root, 'lib'), File.join(root, 'test'))
paths = ARGV.shift(Integer(ARGV.shift))
paths.each { |path| require File.expand_path(path, root) }
