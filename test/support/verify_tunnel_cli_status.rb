# frozen_string_literal: true

require_relative "../suite_runner"

# Runs only the native tunnel CLI regression through the existing guarded suite
# loader. Returns verified case evidence; child failures retain their exit status.
root = File.realpath(File.join(__dir__, "../.."))
Dir.chdir(root) do
  ENV["SEED"] ||= "2300"
  TestSuiteRunner.run_process(
    ["test/run_evidence_test.rb"],
    ["RunEvidenceTest#test_native_tunnel_cli_dotenv_two_sessions_and_negative_controls"],
    root: root, selected: true
  )
end
