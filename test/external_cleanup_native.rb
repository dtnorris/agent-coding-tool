# frozen_string_literal: true

# Explicit focused acceptance, outside the mandatory suite's zero-Git discovery.
# Run: bundle exec ruby -Ilib test/external_cleanup_native.rb
# All Git mutations are confined to freshly generated disposable fixtures.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "agent_coding_tool"
require_relative "support/external_cleanup_cases"

# Exercises native ownership and non-forced removal using the same CLI cases as
# modeled suite coverage, without changing the suite's execution/discovery policy.
class ExternalCleanupNative < Minitest::Test
  include ExternalCleanupCases

  # A fresh process resumes both a published receipt and an absent worktree left
  # with a removing marker. No parent in-memory state is available to the child.
  def test_native_cold_receipt_and_interrupted_removal_retry
    fixture do
      item = manager.preflight("TASK", pr: "ACT-38").fetch("external_deliveries").first
      manager.send(:publish_receipt!, item.fetch("path"), item.fetch("receipt"))
      receipt = File.binread(item.fetch("path"))
      original_rename = File.method(:rename)
      failing_rename = proc do |source, destination|
        if destination == File.join(@run, "worktrees.json") && JSON.parse(File.read(source)).fetch("entries").first["state"] == "removed"
          raise AgentCodingTool::InvalidState, "fixture post-removal interruption"
        end
        original_rename.call(source, destination)
      end
      File.stub(:rename, failing_rename) { assert_equal 2, cli.first }
      refute File.exist?(@workspace)
      assert_equal "removing", JSON.parse(File.read(File.join(@run, "worktrees.json"))).fetch("entries").first.fetch("state")
      script = File.expand_path("support/fixtures/external_cleanup_retry.rb", __dir__)
      output, errors, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), script,
        @data, @head, @provider.result.fetch("merge_commit_sha"))
      assert status.success?, errors + output
      assert_equal "removed", JSON.parse(File.read(File.join(@run, "worktrees.json"))).fetch("entries").first.fetch("state")
      assert_equal receipt, File.binread(item.fetch("path"))
      assert_equal @head, git(@parent, "rev-parse", "refs/heads/act/TASK/attempt-1")
    end
  end

  # Supplies the actual production process transport; no Git observation is faked.
  def with_git_world(_root)
    @transport = AgentCodingTool::NativeCommandTransport.new
    yield
  end

  # Initializes a disposable ordinary Git checkout with a name-only GitHub remote.
  # Returns checkout/base; no remote query, push, fetch or publication occurs.
  def build_repository(root)
    parent = File.join(root, "ordinary")
    FileUtils.mkdir_p(parent)
    git(parent, "init", "--initial-branch=main")
    git(parent, "config", "user.name", "Fixture")
    git(parent, "config", "user.email", "fixture@example.invalid")
    git(parent, "config", "commit.gpgsign", "false")
    git(parent, "remote", "add", "origin", REMOTE)
    File.write(File.join(parent, "file.txt"), "base\n")
    File.write(File.join(parent, ".gitignore"), "ignored\n")
    git(parent, "add", "--", "file.txt", ".gitignore")
    git(parent, "commit", "-m", "base")
    [parent, git(parent, "rev-parse", "HEAD")]
  end
end
