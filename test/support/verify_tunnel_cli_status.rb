# frozen_string_literal: true

require_relative "../suite_runner"

# Runs the public tunnel success and startup-failure regressions through the
# guarded suite loader. Returns verified evidence; child failures retain status.
root = File.realpath(File.join(__dir__, "../.."))
Dir.chdir(root) do
  ENV["SEED"] ||= "2300"
  TestSuiteRunner.run_process(
    ["test/run_evidence_test.rb"],
    ["RunEvidenceTest#test_native_tunnel_cli_dotenv_two_sessions_and_negative_controls",
     "RunEvidenceTest#test_native_tunnel_startup_failures_are_safe_and_nonzero"],
    root: root, selected: true
  )
end
