# frozen_string_literal: true

require "open3"
require "shellwords"
require "minitest/mock"

# Genuine Git seed for native ownership tests. Consumers copy its private checkout
# and use its immutable private remote; ordinary tests retain MemoryGit::Template.
module TestHelpers
  # Returns a private native checkout, remote and committed base; Git errors raise.
  def self.git_seed
    @native_git_seed ||= begin
      root = Dir.mktmpdir("act-native-seed-")
      ordinary = File.join(root, "ordinary")
      remote = File.join(root, "remote.git")
      FileUtils.mkdir_p(ordinary)
      [["init", "--initial-branch=main"], ["config", "user.name", "Fixture"],
       ["config", "user.email", "fixture@example.test"], ["config", "commit.gpgsign", "false"]].each do |args|
        native_git(ordinary, *args)
      end
      File.write(File.join(ordinary, "file.txt"), "base\n")
      native_git(ordinary, "add", ".")
      native_git(ordinary, "commit", "-m", "fixture")
      native_git(root, "init", "--bare", "--initial-branch=main", remote)
      native_git(ordinary, "remote", "add", "origin", remote)
      native_git(ordinary, "push", "origin", "main")
      Minitest.after_run { FileUtils.remove_entry(root) if File.directory?(root) }
      { root: root, base: native_git(ordinary, "rev-parse", "HEAD").strip }
    end
  end

  # Runs Git only at the supplied disposable fixture path; errors propagate.
  def self.native_git(path, *args)
    output, error, status = Open3.capture3("git", *args, chdir: path)
    raise error unless status.success?
    output
  end
end

# Cold public CLI readers inherit the same real source history, with coverage.
preload = File.expand_path("coding_skill_support.rb", __dir__)
ENV["RUBYOPT"] = Shellwords.join([*Shellwords.split(ENV.fetch("RUBYOPT", "")), "-r#{preload}"])

# Native calls bypass the fixture adapter only; no execution guard is loaded.
NativeTestCapture = Open3.method(:capture3)
