# frozen_string_literal: true

require_relative "../suite_runner"

# Runs public tunnel success, startup failure, lifecycle and lock-refusal cases
# through the guarded loader. Returns verified evidence; failures retain status.
root = File.realpath(File.join(__dir__, "../.."))
Dir.chdir(root) do
  ENV["SEED"] ||= "2300"
  TestSuiteRunner.run_process(
    ["test/run_evidence_test.rb"],
    ["RunEvidenceTest#test_native_tunnel_cli_dotenv_two_sessions_and_negative_controls",
     "RunEvidenceTest#test_native_tunnel_startup_failures_are_safe_and_nonzero",
     "RunEvidenceTest#test_native_tunnel_lifecycle_and_exclusive_ownership",
     "RunEvidenceTest#test_native_stop_serializes_once_and_refuses_persistent_contention"],
    root: root, selected: true
  )
end
