# frozen_string_literal: true

# Complete fixed TST-37 component gate; socket-bound cases remain mandatory.
require_relative "shared_world_cases"
require_relative "shared_verification"
SharedVerification.install([SharedWorldVerifier, SharedLauncherAdapterVerifier, SharedApplyAdapterVerifier,
  SharedRecoveryAdapterVerifier, SharedSourceAdapterVerifier], "shared_required_cases.json")
