# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/external_cleanup_cases"

# Runs shared cleanup journeys under the mandatory suite's zero-Git policy.
class ExternalCleanupGitIntegration < Minitest::Test
  include ExternalCleanupCases
  include TestHelpers

  # The provider must bind returned PR authority as well as the request URL.
  # Only the external API response is faked; production parsing/refusals run.
  def test_github_provider_binds_returned_pr_repository
    provider = AgentCodingTool::GitHubDeliveryProvider.new
    response = { "html_url" => URL, "merged_at" => "2026-01-01T00:00:00Z", "head" => { "sha" => "a" * 40 },
      "base" => { "ref" => "main", "repo" => { "full_name" => "dtnorris/agent-coding-tool" } }, "merge_commit_sha" => "b" * 40 }
    provider.stub(:request, response) do
      assert_equal "a" * 40, provider.integration(REMOTE, URL).fetch("head")
      response.fetch("base").fetch("repo")["full_name"] = "other/repository"
      assert_raises(AgentCodingTool::InvalidState) { provider.integration(REMOTE, URL) }
      assert_raises(AgentCodingTool::InvalidState) { provider.integration(REMOTE, "https://github.com/other/repository/pull/38") }
    end
  end

  # Yields a fresh modeled Git authority; verifies its finite command contract.
  def with_git_world(root)
    with_memory_world(root) do |world|
      @world = world
      @transport = AgentCodingTool::NativeCommandTransport.new
      yield
    end
  end

  # Creates independent repository authority with an actual ignored-file fixture.
  # Returns ordinary checkout and base SHA; unsupported model commands raise.
  def build_repository(root)
    parent = File.join(root, "ordinary")
    checkout, = memory_repository(@world, path: parent, remote: REMOTE,
      template: MemoryGit::Template.files({ "file.txt" => "base\n", ".gitignore" => "ignored\n" }))
    [parent, checkout.head]
  end
end
