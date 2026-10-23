# frozen_string_literal: true

require "stringio"
require_relative "test_helper"

# Exercises contract and consent decisions with real fixture files and no Git,
# subprocess or terminal effects. The composed public journey stays native.
class ApplyHandoffTest < Minitest::Test
  # Supplies only the terminal capability and input bytes used by confirm?.
  class ConsentInput < StringIO
    # Returns the explicitly supplied terminal capability; no terminal is opened.
    def tty? = true
  end

  # Builds a downloaded proposal and sibling directories under TMPDIR. Yields
  # without loading/stubbing production decisions; fixture errors propagate.
  def with_proposal
    Dir.mktmpdir("act ordinary apply ") do |directory|
      @root = File.realpath(directory)
      FileUtils.mkdir_p([File.join(@root, "A"), File.join(@root, "B", "test"), File.join(@root, "downloads")])
      @json = File.join(@root, "downloads", "proposal.json")
      @patch_path = File.join(@root, "downloads", "proposal.patch")
      @patch = "downloaded patch bytes\n".b
      File.binwrite(@patch_path, @patch)
      @manifest = {
        "schema" => AgentCodingTool::ApplyHandoff::SCHEMA, "target" => "data",
        "repositories" => {
          "data" => { "path" => "A", "remote_url" => "git@github.com:example/data.git", "baseline" => "a" * 40 },
          "tool" => { "path" => "B", "remote_url" => "https://github.com/example/tool.git", "baseline" => "b" * 40 }
        },
        "patch" => { "file" => "proposal.patch", "sha256" => Digest::SHA256.hexdigest(@patch) },
        "paths" => ["tasks/NEW.yml"],
        "validation" => [{ "action" => "git_diff_check", "repository" => "data", "cwd" => ".", "env" => {} }],
        "commit_message" => "Register NEW task"
      }
      @out, @err = StringIO.new, StringIO.new
      @handoff = AgentCodingTool::ApplyHandoff.new(
        config: AgentCodingTool::Config.new({ "repo_root" => @root }, base_dir: @root), out: @out, err: @err
      )
      yield
    end
  end

  # Writes the proposal and invokes only parsing/resolution, returning its result.
  # Production Error/filesystem/JSON exceptions propagate to the test assertion.
  def load_proposal
    File.write(@json, JSON.generate(@manifest))
    @handoff.send(:load_manifest!, @json)
  end

  # Verifies configured sibling binding, identity normalization and artifact
  # resolution beside JSON without depending on the invocation's working dir.
  def test_contract_binds_repositories_and_downloaded_bytes
    with_proposal do
      load_proposal
      repositories = @handoff.instance_variable_get(:@repositories)
      assert_equal({ path: File.join(@root, "A"), baseline: "a" * 40, identity: "example/data" }, repositories.fetch("data"))
      assert_equal "example/tool", repositories.fetch("tool").fetch(:identity)
      assert_same repositories.fetch("data"), @handoff.instance_variable_get(:@target)
      assert_equal ["tasks/NEW.yml"], @handoff.instance_variable_get(:@paths)
      assert_equal @patch, @handoff.send(:artifact!)
      assert_empty @out.string
      assert_empty @err.string
    end
  end

  # Requires strict fields/types throughout the manifest, rather than accepting
  # worker-supplied extensions or malformed authority declarations.
  def test_invalid_contracts_are_refused_before_native_inspection
    with_proposal do
      valid = Marshal.dump(@manifest)
      mutations = [
        ->(manifest) { manifest["schema"] = "agent-coding-tool-apply/v2" },
        ->(manifest) { manifest.delete("target") },
        ->(manifest) { manifest["yes"] = true },
        ->(manifest) { manifest["target"] = "undeclared" },
        ->(manifest) { manifest["repositories"] = [] },
        ->(manifest) { manifest["repositories"] = {} },
        ->(manifest) { manifest["repositories"]["bad/name"] = manifest["repositories"].delete("tool") },
        ->(manifest) { manifest["repositories"]["data"]["baseline"] = "A" * 40 },
        ->(manifest) { manifest["repositories"]["data"]["remote_url"] = "" },
        ->(manifest) { manifest["repositories"]["data"]["remote_url"] = 7 },
        ->(manifest) { manifest["repositories"]["data"]["path"] = "../outside" },
        ->(manifest) { manifest["repositories"]["tool"]["path"] = "A" },
        ->(manifest) { manifest["repositories"]["tool"]["path"] = "A/nested" },
        ->(manifest) { manifest["patch"]["file"] = "nested/proposal.patch" },
        ->(manifest) { manifest["patch"]["sha256"] = "bad" },
        ->(manifest) { manifest["paths"] = [] },
        ->(manifest) { manifest["paths"] = "tasks/NEW.yml" },
        ->(manifest) { manifest["paths"] *= 2 },
        ->(manifest) { manifest["paths"] = [".GIT/config"] },
        ->(manifest) { manifest["commit_message"] = "two\nlines" },
        ->(manifest) { manifest["commit_message"] = "  " },
        ->(manifest) { manifest["commit_message"] = nil },
        ->(manifest) { manifest["validation"] = [] },
        ->(manifest) { manifest["validation"] = {} }
      ]
      mutations.each_with_index do |mutation, index|
        @manifest = Marshal.load(valid)
        mutation.call(@manifest)
        assert_raises(AgentCodingTool::Error, "invalid contract #{index}") { load_proposal }
      end
    end
  end

  # Checks fixed argv and explicit sibling ACTD selection, including a spaced
  # Ruby test path. No action is executed, and no executable override is inferred.
  def test_validation_actions_translate_to_exact_argv_cwd_and_environment
    with_proposal do
      @manifest["validation"] = [
        { "action" => "bundle_rake", "repository" => "tool", "cwd" => ".", "env" => { "AGENT_CODING_TOOL_DATA_DIR" => "data" }, "tasks" => ["test:all", "actd:validate_yaml"] },
        { "action" => "ruby_test", "repository" => "tool", "cwd" => "test", "env" => {}, "files" => ["a test.rb"] },
        @manifest["validation"].first
      ]
      load_proposal
      assert_equal [
        { argv: %w[bundle exec rake test:all actd:validate_yaml], cwd: File.join(@root, "B"), env: { "AGENT_CODING_TOOL_DATA_DIR" => File.join(@root, "A") } },
        { argv: [RbConfig.ruby, "-Ilib:test", "--", "a test.rb"], cwd: File.join(@root, "B", "test"), env: {} },
        { argv: %w[git diff --check], cwd: File.join(@root, "A"), env: {} }
      ], @handoff.instance_variable_get(:@steps)
    end
  end

  # Rejects shell strings, extra scope overrides and unsafe action arguments at
  # the real translator; these inputs must never reach a process boundary.
  def test_validation_scope_and_injection_attempts_are_refused
    with_proposal do
      load_proposal
      valid = @manifest.fetch("validation").first
      invalid = [nil, "git diff --check", valid.merge("action" => "shell"),
                 valid.merge("argv" => ["sh"]), valid.merge("repository" => "other"),
                 valid.merge("cwd" => "../B"), valid.merge("cwd" => "missing"),
                 valid.merge("env" => []), valid.merge("env" => { "PATH" => "/tmp" }),
                 valid.merge("env" => { "AGENT_CODING_TOOL_DATA_DIR" => "/tmp" })]
      [[], "test", [nil], ["--rakefile"], ["test;touch marker"], ["test[$(touch marker)]"]].each do |tasks|
        invalid << valid.merge("action" => "bundle_rake", "tasks" => tasks)
      end
      [[], ["one.rb", "two.rb"], ["../escape.rb"], ["test.txt"], ["$(touch marker).rb"]].each do |files|
        invalid << valid.merge("action" => "ruby_test", "files" => files)
      end
      # A leading dash remains a literal path after Ruby's --, never an option.
      invalid.each_with_index do |step, index|
        assert_raises(AgentCodingTool::Error, "invalid action #{index}") { @handoff.send(:validation_step!, step) }
      end
      assert_equal [RbConfig.ruby, "-Ilib:test", "--", "--help.rb"],
                   @handoff.send(:validation_step!, valid.merge("action" => "ruby_test", "files" => ["--help.rb"])).fetch(:argv)
      refute File.exist?(File.join(@root, "marker"))
    end
  end

  # Exercises containment with actual symlinks and portable path syntax. Both
  # inside-root links and escapes are refused; future regular paths are allowed.
  def test_paths_refuse_traversal_control_bytes_and_symlink_components
    with_proposal do
      ["", "/absolute", "a//b", "a/", "../escape", "a/./b", ".git/config", "a/.GiT/config", "x\nfile", "x\0file", ":(glob)*", "$(id)"].each do |path|
        assert_raises(AgentCodingTool::Error, path.inspect) { @handoff.send(:relative!, path) }
      end
      assert_equal File.join(@root, "A", ".hidden", "a file.rb"), @handoff.send(:contained!, @root, "A/.hidden/a file.rb")
      File.symlink(File.join(@root, "B"), File.join(@root, "A", "linked"))
      assert_raises(AgentCodingTool::Error) { @handoff.send(:contained!, @root, "A/linked/future.rb") }
      @manifest["repositories"]["data"]["path"] = "A/linked"
      assert_raises(AgentCodingTool::Error) { load_proposal }
    end
  end

  # Artifact integrity is evaluated with real bytes, missing files and symlinks;
  # cached preview data cannot authorize changed JSON or a replacement patch.
  def test_artifact_rechecks_manifest_patch_hash_and_regular_file
    with_proposal do
      load_proposal
      File.binwrite(@patch_path, "tampered")
      assert_match(/SHA-256 mismatch/, assert_raises(AgentCodingTool::Error) { @handoff.send(:artifact!) }.message)
      File.unlink(@patch_path)
      assert_match(/regular, nonsymlink/, assert_raises(AgentCodingTool::Error) { @handoff.send(:artifact!) }.message)
      File.symlink(@json, @patch_path)
      assert_match(/regular, nonsymlink/, assert_raises(AgentCodingTool::Error) { @handoff.send(:artifact!) }.message)
      File.unlink(@patch_path)
      File.binwrite(@patch_path, @patch)
      File.write(@json, File.read(@json) + "\n")
      assert_match(/manifest changed/, assert_raises(AgentCodingTool::Error) { @handoff.send(:artifact!) }.message)
    end
  end

  # Verifies the consent predicate for every independently displayed question.
  # This is no terminal simulation of the journey: real PTY effects stay native.
  def test_each_confirmation_defaults_to_no_and_requires_terminal_yes
    ["Apply patch?", "Run validation?", "Stage these files and commit?"].each do |question|
      [nil, "", "\n", "n\n", "true\n", "yes please\n", "y\n", " YES \n"].each do |answer|
        [ConsentInput.new(answer.to_s), StringIO.new(answer.to_s), Object.new].each do |input|
          out = StringIO.new
          handoff = AgentCodingTool::ApplyHandoff.new(config: nil, input: input, out: out, err: StringIO.new)
          expected = input.is_a?(ConsentInput) && ["y\n", " YES \n"].include?(answer)
          assert_equal expected, handoff.send(:confirm?, question)
          assert_equal "#{question} [y/N] ", out.string
        end
      end
    end
  end

  # Covers public argument refusal and malformed JSON without substituting any
  # apply pipeline. Native repository discovery must not run on these inputs.
  def test_public_cli_refuses_invalid_arguments_and_malformed_json
    with_proposal do
      [[], ["--yes"], ["one.json", "two.json"]].each do |arguments|
        cli = AgentCodingTool::CLI.new(root: @root, data_root: @root, out: @out, err: @err)
        assert_equal 2, cli.run(["apply", *arguments])
        assert_includes @err.string, "usage: agent-coding-tool apply FILE.json"
      end
      File.write(@json, "{bad json")
      cli = AgentCodingTool::CLI.new(root: @root, data_root: @root, out: @out, err: @err)
      assert_equal 2, cli.run(["apply", @json])
      assert_includes @err.string, "ERROR: apply:"
      assert_includes @out.string, "Apply outcome: not applied; publication not performed."
      assert_equal @patch, File.binread(@patch_path)
    end
  end
end
