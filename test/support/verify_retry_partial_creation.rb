# frozen_string_literal: true

require_relative "../feedback"
require_relative "../suite_runner"

# Runs the partial-creation journey with the existing execution guard, fresh
# all-production coverage and case accounting. Child or evidence failures retain
# failure status. This selected check does not claim complete-suite acceptance.
root = File.realpath(File.join(__dir__, "../.."))
Dir.chdir(root) do
  ENV["SEED"] ||= "2300"
  context = TestFeedback.context(root)
  directory = File.join(context.fetch("directory"), "native_integration")
  Dir.mkdir(directory)
  stage = { "layer" => "native_integration", "complete" => false,
    "processes" => [], "directory" => directory }
  context.fetch("stages") << stage
  started = FeedbackRuntime.clock
  TestSuiteRunner.run_process(
    ["test/integration/attempt_retry_git_integration.rb"],
    ["AttemptRecoveryTest#test_partial_creation_before_and_after_native_add_is_preserved"],
    root: root, selected: true, feedback: stage
  )
  stage["seconds"] = FeedbackRuntime.clock - started
  stage["complete"] = true
end
