# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "shellwords"
require "agent_coding_tool"
require_relative "apply_handoff_fixture"

# Native apply fixtures retain actual Git indexes, history and child execution.
# Separate from test_helper's guarded memory transport and skill preload.
module NativeApplyHandoffFixtures
  include ApplyHandoffFixture

  # Builds private native repositories and yields; setup failures propagate.
  # The enclosing fixture removes all files without installing a memory session.
  def with_apply_repositories
    [@a, @b].each do |path|
      FileUtils.mkdir_p(path)
      git(path, "init", "--initial-branch=main", "--object-format=sha1")
      { "user.name" => "Apply Fixture", "user.email" => "fixture@example.test",
        "core.autocrlf" => "false", "core.hooksPath" => File.join(path, ".git", "hooks"),
        "commit.gpgsign" => "false" }.each { |key, value| git(path, "config", key, value) }
      git(path, "init", "--bare", "--object-format=sha1", "#{path}.git")
      git(path, "remote", "add", "origin", "#{path}.git")
      File.write(File.join(path, "file.txt"), "base\n")
    end
    yield
  end

  # Adds a literal ignored name to private Git metadata; I/O errors propagate.
  def ignore_apply_path(path, relative)
    File.open(File.join(path, ".git", "info", "exclude"), "a") { |file| file.puts(relative) }
  end

  # Stages and commits fixture files with genuine Git; failures raise.
  def commit_apply_fixture(path)
    git(path, "add", ".")
    git(path, "commit", "-m", "fixture")
  end

  # Removes a tracked index entry, retaining worktree bytes; failures raise.
  def remove_apply_index_path(path, relative)
    git(path, "rm", "--cached", "--", relative)
  end

  # Runs native fixture Git with binary stdin/output; nonzero status raises.
  def git(path, *args, input: "")
    stdout, stderr, status = Open3.capture3("git", *args, chdir: path, stdin_data: input, binmode: true)
    raise "fixture Git failed (#{status.exitstatus}): #{stderr}" unless status.success?
    stdout
  end
end
