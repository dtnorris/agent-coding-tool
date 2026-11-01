# frozen_string_literal: true

require_relative "../suite_runner"

# Runs the complete progress contract through the same guarded loader used by
# test:all. A standalone invocation needs no Darwin feedback policy.
root = File.realpath(File.join(__dir__, "../.."))
path = "test/git_contract/progress_contract.rb"
cases = JSON.parse(File.binread(File.join(root, "test/git_contract/required_cases.json"))).fetch(path)
Dir.chdir(root) { TestSuiteRunner.run_process([path], cases, root: root, selected: true) }
