# frozen_string_literal: true

# Independent fixed adapter gate. This never establishes cold-world acceptance;
# verify_shared.rb remains the mandatory complete TST-37 component gate.
require_relative "shared_adapter_cases"
require_relative "shared_verification"
SharedVerification.install([SharedLauncherAdapterVerifier, SharedApplyAdapterVerifier,
  SharedRecoveryAdapterVerifier, SharedSourceAdapterVerifier], "adapter_required_cases.json")
