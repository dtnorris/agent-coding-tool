# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../launcher_support"
require "shellwords"
require "stringio"

# Public prepare/launch/export/host checkpoint journey; only Codex is a finite
# fake executable. All Git, state, host commands and evidence are disposable.
class ReadinessTest < Minitest::Test
  include TestHelpers
  include LauncherSupport

  # Installs a fixture-local act entry pointing to this exact implementation.
  # Yields with PATH restored afterward; no operator executable is changed.
  def public_entries
    entry = File.join(@root, "act")
    File.write(entry, "#!#{RbConfig.ruby}\nrequire #{File.expand_path('../../lib/agent_coding_tool', __dir__).inspect}\nexit AgentCodingTool::CLI.run(ARGV, root: #{Dir.pwd.inspect})\n")
    File.chmod(0o755, entry)
    previous = ENV.fetch("PATH")
    ENV["PATH"] = "#{@root}:#{previous}"
    yield
  ensure
    ENV["PATH"] = previous
  end

  # Calls the production CLI in process with captured diagnostics. Returns its
  # code; malformed state/errors preserve the CLI's normal nonzero contract.
  def cli(*argv)
    AgentCodingTool::CLI.run(argv, root: Dir.pwd, data_root: @data, out: @out, err: @err)
  end

  # Executes a returned shell-safe host command in a new process without
  # reconstructing task/workspace/artifact names; returns stdout on success.
  def host(command)
    output, error, status = Open3.capture3(*Shellwords.split(command))
    assert status.success?, "#{command}\n#{output}\n#{error}"
    output
  end

  # Returns relative file paths and exact bytes under a disposable root, including
  # Git storage when present. Used to detect refused-launch mutations; I/O raises.
  def file_bytes(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).select do |path|
      File.file?(File.join(root, path))
    end.to_h { |path| [path, File.binread(File.join(root, path))] }
  end

  # Keeps preparation/manual start independent of objects used only at launch;
  # launch must diagnose exact missing native input before allocating an attempt.
  # Removing the early check makes this same no-attempt assertion fail.
  def test_missing_imminent_object_blocks_launch_without_fetch_or_worker
    [false, true].each do |omit_readiness|
      fixture(git: true, process: true, mutable_remote: true) do
        public_entries do
          future = setup_git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
            "--git-dir", @remote, "commit-tree", "#{@base}^{tree}", "-p", @base, "-m", "remote only")
          setup_git("--git-dir", @remote, "update-ref", "refs/heads/main", future)
          assert_equal 0, cli("prepare", "T")
          assert_includes @out.string, "remain unverified until launch"
          before = file_bytes(@ordinary)
          probe = lambda do
            assert_equal 2, cli("launch", "T", "--codex", "--reasoning", "high")
            refute File.exist?(File.join(@root, "worker-pid"))
            assert_empty Dir.glob("#{@data}-runs/T/*/handoff.json")
            refute File.exist?(File.join(@root, "worktrees"))
            assert_includes @err.string, "Local repo repo is missing required commit #{future} (likely not fetched from remote)"
            assert_includes @err.string, "ACT creates worker worktrees from existing local Git storage"
            assert_includes @err.string, "cannot create the worker workspace from #{@ordinary}"
            assert_includes @err.string, "blocked action: worktree creation"
            assert_includes @err.string, "Fetch the required commit from the configured remote origin (#{@remote})"
            assert_includes @err.string, "then retry launch"
            assert_includes @err.string, "Pulling, resetting or switching the ordinary checkout is unnecessary"
            assert_includes @err.string, "ACT performed no fetch or repair"
            assert_equal before, file_bytes(@ordinary)
          end
          if omit_readiness
            constructor = AgentCodingTool::WorktreeManager.method(:new)
            without_check = lambda do |**options|
              instance = constructor.call(**options)
              instance.define_singleton_method(:creation_readiness!) { |**| [] }
              instance
            end
            AgentCodingTool::WorktreeManager.stub(:new, without_check) do
              assert_raises(Minitest::Assertion, &probe)
            end
          else
            probe.call
            # An independent permitted manual milestone does not need the object.
            assert_equal 0, cli("start", "T")
          end
          assert_equal before, file_bytes(@ordinary)
          _output, _error, status = Open3.capture3("git", "cat-file", "-e", future, chdir: @ordinary)
          refute status.success?
        end
      end
    end

    # Separate recovery: only an explicit test-owned operator fetch supplies the
    # object. The same prepared launch succeeds without moving ordinary HEAD/files.
    fixture(git: true, process: true, mutable_remote: true) do
      public_entries do
        future = setup_git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
          "--git-dir", @remote, "commit-tree", "#{@base}^{tree}", "-p", @base, "-m", "recovery remote only")
        setup_git("--git-dir", @remote, "update-ref", "refs/heads/main", future)
        assert_equal 0, cli("prepare", "T")
        prepared = @store.load("T")
        assert_equal 2, cli("launch", "T", "--codex", "--reasoning", "high")
        refute File.exist?(File.join(@root, "worker-pid"))
        ordinary = file_bytes(@ordinary).reject { |path, _bytes| path.start_with?(".git/") }
        head = setup_git("rev-parse", "HEAD", chdir: @ordinary)
        index = File.binread(File.join(@ordinary, ".git", "index"))
        source = prepared.fetch("snapshot").fetch("repo")
        setup_git("fetch", "--", source.fetch("remote"), source.fetch("pushed_sha"), chdir: @ordinary)
        assert_equal head, setup_git("rev-parse", "HEAD", chdir: @ordinary)
        assert_equal index, File.binread(File.join(@ordinary, ".git", "index"))
        assert_equal ordinary, file_bytes(@ordinary).reject { |path, _bytes| path.start_with?(".git/") }
        assert_equal prepared, @store.load("T")
        assert_equal 0, cli("launch", "T", "--codex", "--reasoning", "high"), @err.string
        report = JSON.parse(File.read(Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)))
        entry = report.fetch("worktrees").fetch("entries").fetch(0)
        assert_equal future, entry.fetch("base_sha")
        assert_equal future, setup_git("rev-parse", "HEAD", chdir: entry.fetch("path"))
        assert File.exist?(File.join(@root, "worker-pid"))
        assert_equal head, setup_git("rev-parse", "HEAD", chdir: @ordinary)
        assert_equal index, File.binread(File.join(@ordinary, ".git", "index"))
        assert_equal ordinary, file_bytes(@ordinary).reject { |path, _bytes| path.start_with?(".git/") }
      end
    end
  end

  # Verifies real handoff commands and authority limits through fresh host
  # processes. Tool states are simulated worker startup observations, never host
  # claims or permissions; no real inference or tool authorization occurs.
  def test_public_journey_exports_canonical_candidate_and_transfers_to_host
    %w[unverified absent observed-present].each do |observation|
      fixture(git: true, process: true) do
        public_entries do
          write_fake("journey-#{observation}")
          assert_equal 0, cli("prepare", "T")
          state = @store.load("T")
          source_objects = Dir.glob(File.join(@ordinary, ".git", "objects", "**", "*"))
          assert_equal 0, cli("launch", "T", "--codex", "--reasoning", "high"), @err.string
          report = JSON.parse(File.read(Dir.glob("#{@data}-runs/T/*/handoff.json").fetch(0)))
          candidate = JSON.parse(File.read(report.fetch("final_path")))
          assert_equal "unverified", report.dig("readiness", "worker_tools")
          assert_equal "verified", report.dig("readiness", "source_objects", 0, "status")
          assert_equal observation, candidate.fetch("startup_tools")
          assert_equal "canonical_format_checked", candidate.fetch("status")
          assert_equal "pending", candidate.fetch("host_checkpoint")
          assert_nil @store.load("T")["checkpoint"]
          assert_equal [{ "command" => "finite fake worker content check", "result" => "PASS" }], candidate.fetch("focused_checks")
          assert_equal state.fetch("prepared_at"), @store.load("T").fetch("prepared_at")
          assert_equal Digest::SHA256.file(candidate.fetch("artifact")).hexdigest, candidate.fetch("sha256")
          assert_includes candidate.fetch("changed_files"), { "status" => "A", "path" => "worker-change.txt" }
          assert_equal source_objects, Dir.glob(File.join(@ordinary, ".git", "objects", "**", "*"))
          next unless observation == "unverified"

          commands = candidate.fetch("host_commands")
          recorded = JSON.parse(host(commands.fetch("record")))
          assert_equal candidate.fetch("sha256"), recorded.fetch("sha256")
          assert_equal "verified", JSON.parse(host(commands.fetch("verify"))).fetch("status")
          assert_equal "0", host(commands.fetch("gate_prefix") + " " + Shellwords.join([RbConfig.ruby, "-e", "exit 0"])).strip
          # Review bytes can apply yet cannot register as canonical evidence.
          review = File.join(@root, "review.patch")
          bytes = File.binread(candidate.fetch("artifact"))
          File.binwrite(review, bytes.sub(/index [0-9a-f]+\.\.[0-9a-f]+\n/, ""))
          refute_equal bytes, File.binread(review)
          setup_git("apply", "--check", review, chdir: @ordinary)
          assert_equal 2, cli("checkpoint", "record", "T", "--workspace", candidate.fetch("workspace"), "--artifact", review)
          assert_includes @err.string, "artifact differs from complete implementation"
          # Missing the returned artifact must break the same host handoff.
          File.unlink(candidate.fetch("artifact"))
          assert_raises(Minitest::Assertion) { host(commands.fetch("record")) }
          File.write(File.join(candidate.fetch("workspace"), "worker-change.txt"), "changed")
          assert_equal 2, cli("checkpoint", "verify", "T", "--workspace", candidate.fetch("workspace"))
          assert_includes @err.string, "stale implementation"
          assert_nil @store.load("T")["result"]
          assert_empty Dir.glob("#{@data}-runs/T/*/delivery.json")
        end
      end
    end
  end
end
