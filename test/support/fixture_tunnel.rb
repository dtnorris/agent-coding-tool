# frozen_string_literal: true

require_relative "../../lib/agent_coding_tool/evidence_tunnel"

# Native fake-client tests own no hosted endpoint. Only their exact synthetic
# executable and endpoint bypass host-client inventory; kernel endpoint locks,
# ledger/owner checks, readiness and owned cleanup remain production code.
# No production command loads this test bootstrap or reads its environment key.
module FixtureTunnelInventory
  # Isolates an explicitly declared fake external transport from an unrelated
  # host tunnel. Every other path/endpoint runs the original native inventory.
  def inventory!
    declared = ENV["ACT_FIXTURE_TUNNEL_CLIENT"]
    return super unless declared && @client == declared && File.realpath(declared) == declared &&
      File.basename(declared) == "fixture-client" && File.stat(declared).uid == Process.uid &&
      (File.stat(declared).mode & 0o077).zero?
    grant = AgentCodingTool::RunEvidenceStore.parse(AgentCodingTool::RunEvidenceStore.bytes(@grant, root: File.dirname(@grant), private: true))
    return super unless grant.dig("transport", "endpoint") == "tunnel_fixture/main"
    nil
  end


end

AgentCodingTool::EvidenceTunnel.prepend(FixtureTunnelInventory)
