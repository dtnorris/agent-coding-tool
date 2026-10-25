# frozen_string_literal: true

require_relative "../test_helper"
require "pty"
require "shellwords"
require "timeout"

# Public CLI integration with real local Git, terminal consent and sibling
# validation. Every mutation is confined to disposable, locally remoted repos.
class ApplyHandoffGitIntegrationTest < Minitest::Test
  include TestHelpers
  CLI = File.expand_path("../../bin/agent-coding-tool", __dir__)
  NONPORTABLE_PATHS = ["notes (from PDF).md", "Explorer's_Guide.md",
                       "title & notes.md", "Moria_Khazad-dûm.md"].freeze
  IGNORED_PATH = "ignored (notes & dûm's).bin"
  TASK = <<~YAML
    ---
    id: NEW
    title: Example inspection
    repositories:
      agent-coding-tool:
        access: read_only
    goal: Inspect the example.
    acceptance:
      - Report findings.
  YAML
  JOURNEY_SCRIPT = <<~'RUBY'
    require "yaml"
    abort "test-only ACT preload leaked into validation" if defined?(AgentCodingTool)
    data = ENV.fetch("AGENT_CODING_TOOL_DATA_DIR")
    abort "missing task handoff" unless YAML.safe_load_file(File.join(data, "tasks", "NEW.yml"))["id"] == "NEW"
    abort "wrong validation cwd" unless File.basename(Dir.pwd) == "B"
    puts "sibling validation passed"
  RUBY

  # Creates sibling repositories, tracked lifecycle bytes and a new-file patch
  # in a download directory containing spaces. Yields with instance fixture paths
  # bound; optional unrelated nonportable files exercise repository snapshots.
  # Native setup failures propagate, and all files are removed afterward.
  def fixture(script: JOURNEY_SCRIPT, nonportable: false)
    Dir.mktmpdir("act apply ") do |root|
      @root = File.realpath(root)
      @repos = File.join(@root, "repositories")
      @a, @b = %w[A B].map { |name| File.join(@repos, name) }
      FileUtils.mkdir_p(@repos)
      seed = TestHelpers.git_seed
      [@a, @b].each do |path|
        FileUtils.cp_r(File.join(seed.fetch(:root), "ordinary"), path)
        remote = "#{path}.git"
        FileUtils.cp_r(File.join(seed.fetch(:root), "remote.git"), remote)
        git(path, "remote", "set-url", "origin", remote)
      end
      FileUtils.mkdir_p([File.join(@a, "tasks"), File.join(@a, "state")])
      File.write(File.join(@a, "state", "EXISTING.yml"), "result: retained\n")
      File.write(File.join(@a, "config.yml"), YAML.dump("repo_root" => @repos))
      File.write(File.join(@b, "verify.rb"), script)
      [@a, @b].each do |path|
        if nonportable
          NONPORTABLE_PATHS.each do |relative|
            File.binwrite(File.join(path, relative), "unrelated\x00\xff".b)
            File.chmod(0o755, File.join(path, relative))
          end
          File.write(File.join(path, ".git", "info", "exclude"), "/#{IGNORED_PATH}\n")
          File.binwrite(File.join(path, IGNORED_PATH), "ignored\x00\xfe".b)
        end
        git(path, "add", ".")
        git(path, "commit", "-m", "fixture")
      end
      @bases = [@a, @b].map { |path| git(path, "rev-parse", "HEAD").strip }
      downloads = File.join(@root, "Downloaded proposals")
      FileUtils.mkdir_p(downloads)
      @json = File.join(downloads, "new task.json")
      @patch_path = File.join(downloads, "new task.patch")
      # A complete new-file task-registration handoff, generated without staging.
      @task = File.join(@a, "tasks", "NEW.yml")
      @patch = "diff --git a/tasks/NEW.yml b/tasks/NEW.yml\nnew file mode 100644\n--- /dev/null\n+++ b/tasks/NEW.yml\n@@ -0,0 +1,#{TASK.lines.length} @@\n" + TASK.lines.map { |line| "+#{line}" }.join
      File.binwrite(@patch_path, @patch)
      @manifest = {
        "schema" => AgentCodingTool::ApplyHandoff::SCHEMA, "target" => "data",
        "repositories" => { "data" => { "path" => "A", "remote_url" => "#{@a}.git", "baseline" => @bases[0] },
                            "tool" => { "path" => "B", "remote_url" => "#{@b}.git", "baseline" => @bases[1] } },
        "patch" => { "file" => "new task.patch", "sha256" => Digest::SHA256.hexdigest(@patch) },
        "paths" => ["tasks/NEW.yml"],
        "validation" => [{ "action" => "ruby_test", "repository" => "tool", "cwd" => ".", "files" => ["verify.rb"],
                           "env" => { "AGENT_CODING_TOOL_DATA_DIR" => "data" } },
                         { "action" => "git_diff_check", "repository" => "data", "cwd" => ".", "env" => {} }],
        "commit_message" => "Register NEW task"
      }
      save_manifest
      yield
    end
  end

  # Executes local fixture Git; returns stdout, raising on unexpected failure.
  def git(path, *args)
    stdout, stderr, status = Open3.capture3("git", *args, chdir: path)
    raise stderr unless status.success?
    stdout
  end

  # Writes the currently edited proposal as UTF-8 JSON; filesystem errors propagate.
  def save_manifest
    File.write(@json, JSON.pretty_generate(@manifest))
  end

  # Returns HEAD, index entries and non-Git file bytes/modes for preservation checks.
  def state(path)
    files = Dir.glob("**/*", File::FNM_DOTMATCH, base: path).reject { |entry| entry == ".git" || entry.start_with?(".git/") }
    [git(path, "rev-parse", "HEAD"), git(path, "ls-files", "--stage"), files.select { |entry| File.file?(File.join(path, entry)) }.sort.to_h { |entry| [entry, [File.stat(File.join(path, entry)).mode & 0o777, File.binread(File.join(path, entry))]] }]
  end

  # Runs the actual CLI from unrelated cwd, using a PTY for stdin only. Each
  # response/callback occurs after its displayed prompt; stdout/stderr remain raw.
  # A 20-second fixture hang ceiling kills only the owned child on driver failure.
  def cli(responses = [], terminal: true, environment: {})
    # Apply needs no prompt-renderer skill fixture. Do not load ACT into the
    # synthetic validation children that intentionally receive signals or exec.
    # Keep every other inherited option, including the real coverage preload.
    skill_preload = "-r#{File.expand_path('../coding_skill_support.rb', __dir__)}"
    rubyopt = Shellwords.join(Shellwords.split(ENV.fetch("RUBYOPT", "")).reject { |option| option == skill_preload })
    env = { "AGENT_CODING_TOOL_DATA_DIR" => @a, "RUBYOPT" => rubyopt }.merge(environment)
    return Open3.capture3(env, RbConfig.ruby, CLI, "apply", @json, chdir: @root, binmode: true, stdin_data: responses.join("\n")) unless terminal

    PTY.open do |master, slave|
      Tempfile.create("apply-stdout") do |stdout|
        Tempfile.create("apply-stderr") do |stderr|
          pid = Process.spawn(env, RbConfig.ruby, CLI, "apply", @json, chdir: @root, in: slave, out: stdout, err: stderr)
          begin
            Timeout.timeout(20) do
              prompts = ["Apply patch?", "Run validation?", "Stage these files and commit?"]
              responses.each_with_index do |response, index|
                loop do
                  break if File.binread(stdout.path).include?(prompts.fetch(index))
                  finished = Process.waitpid2(pid, Process::WNOHANG)
                  return [File.binread(stdout.path), File.binread(stderr.path), finished.last] if finished
                  sleep 0.005
                end
                value = response.respond_to?(:call) ? response.call : response
                master.write(value.nil? ? "\x04" : "#{value}\n")
              end
              _child, status = Process.waitpid2(pid)
              return [File.binread(stdout.path), File.binread(stderr.path), status]
            end
          ensure
            begin
              Process.kill("KILL", pid)
              Process.waitpid(pid)
            rescue Errno::ESRCH, Errno::ECHILD
              # The normal completed child has already been reaped.
            end
          end
        end
      end
    end
  end

  # Exercises exact baseline, drift, untracked files and both through real
  # consent/validation/commit. Initial sibling files, modes and index stay intact;
  # declared provenance may name an absent object or an older existing commit.
  def test_public_cli_new_task_sibling_validation_and_target_commit
    [[true, false], [false, false], [false, true], [true, true]].each do |drift, untracked|
      fixture(nonportable: true) do
        if drift
          [@a, @b].each do |repo|
            File.write(File.join(repo, "current-only.txt"), "actual initial tree\n")
            git(repo, "add", "current-only.txt")
            git(repo, "commit", "-m", "advance actual HEAD")
          end
          unless untracked
            @manifest.fetch("repositories").each_value { |spec| spec["baseline"] = "a" * 40 }
            [@a, @b].each do |repo|
              _out, _err, status = Open3.capture3("git", "cat-file", "-e", "#{'a' * 40}^{commit}", chdir: repo)
              refute status.success?, "declared baseline must be absent"
            end
          end
        end
        if untracked
          [@a, @b].each do |repo|
            FileUtils.mkdir_p(File.join(repo, "local notes", ".nested"))
            File.binwrite(File.join(repo, "local notes", ".nested", "-keep.bin"), "unrelated\x00\xff".b)
            File.chmod(0o755, File.join(repo, "local notes", ".nested", "-keep.bin"))
          end
        end
        initial = state(@a)
        sibling = state(@b)
        lifecycle = File.binread(File.join(@a, "state", "EXISTING.yml"))
        @manifest["commit_message"] = "Register NEW $(touch injected)"
        save_manifest
        stdout, stderr, status = cli(["y", -> { assert_equal initial[1], state(@a)[1]; "y" }, "y"])
        assert_equal 0, status.exitstatus, stderr + stdout
        warnings, preview = stdout.split("Apply patch?", 2)
        refute_nil preview
        assert_equal 3, stdout.scan("[y/N]").length
        @manifest.fetch("repositories").each do |name, spec|
          actual_head = name == "data" ? initial[0].strip : sibling[0].strip
          if drift
            assert_includes warnings, "WARN: #{name}: baseline differs; expected #{spec.fetch('baseline')}; actual #{actual_head}"
          end
          assert_includes warnings, "WARN: #{name}: preserving initial untracked files:" if untracked
        end
        refute_includes stdout, "WARN:" unless drift || untracked
        assert_includes stdout, "sibling validation passed"
        assert_includes stdout, "committed locally"
        assert_equal TASK, git(@a, "show", "HEAD:tasks/NEW.yml")
        assert_equal "NEW", AgentCodingTool::TaskStore.new(File.join(@a, "tasks")).load("NEW").fetch("id")
        assert_equal "tasks/NEW.yml\n", git(@a, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD")
        assert_equal initial[0].strip, git(@a, "rev-parse", "HEAD^").strip
        assert_equal initial[2], state(@a)[2].reject { |path, _value| path == "tasks/NEW.yml" }
        assert_equal sibling, state(@b)
        expected_untracked = untracked ? ["local notes/.nested/-keep.bin"] : []
        [@a, @b].each do |repo|
          assert_equal expected_untracked, git(repo, "ls-files", "--others", "--exclude-standard", "-z").split("\0")
          assert_empty git(repo, "diff", "--cached", "--name-only")
        end
        assert_equal lifecycle, File.binread(File.join(@a, "state", "EXISTING.yml"))
        assert_equal "Register NEW $(touch injected)\n", git(@a, "log", "-1", "--format=%s")
        refute File.exist?(File.join(@a, "injected"))
        # Reinvocation must neither apply twice nor make another commit.
        before = state(@a)
        _out, error, repeated = cli(%w[y y y])
        assert_equal 2, repeated.exitstatus
        assert_match(/already exists|already occupied/, error)
        assert_equal before, state(@a)
      end
    end
  end

  # Blank, EOF and pipes grant no consent at each applicable phase. Declining a
  # later phase leaves the applied file inspectable without a staged/committed file.
  def test_independent_default_no_eof_and_noninteractive_consent
    [[""], [nil], ["y", ""], ["y", nil], ["y", "y", ""], ["y", "y", nil]].each do |answers|
      fixture(nonportable: true) do
        initial, sibling = state(@a), state(@b)
        stdout, stderr, status = cli(answers)
        assert_equal 0, status.exitstatus, stderr
        assert_equal answers.length > 1, File.exist?(@task)
        assert_equal @bases[0], git(@a, "rev-parse", "HEAD").strip
        assert_empty git(@a, "diff", "--cached", "--name-only")
        refute_includes stdout, "committed locally"
        refute_includes stdout, "Run validation?" if answers.length == 1
        refute_includes stdout, "Stage these files" if answers.length == 2
        after = state(@a)
        assert_equal initial, [*after.first(2), after[2].reject { |path, _value| path == "tasks/NEW.yml" }]
        assert_equal sibling, state(@b)
        if answers.length == 3
          assert_includes stdout, "sibling validation passed"
          assert_includes stdout, "Validation 2: exit 0"
          assert_includes stdout, "Commit declined"
          assert_includes stdout, "publication not performed"
          assert_equal ["tasks/NEW.yml"], git(@a, "ls-files", "--others", "--exclude-standard", "-z").split("\0")
          assert_empty git(@a, "diff", "HEAD")
        end
      end
    end
    fixture do
      before = state(@a)
      stdout, stderr, status = cli(%w[y y y], terminal: false)
      assert_equal 0, status.exitstatus, stderr
      assert_includes stdout, "Application declined"
      assert_equal before, state(@a)
    end
  end

  # All malformed contracts refuse before target mutation, including literal
  # shell payloads in action/task/path/environment fields. No payload is evaluated.
  def test_invalid_contracts_and_injection_leave_bytes_index_and_head_unchanged
    fixture do
      original = Marshal.dump(@manifest)
      before = [state(@a), state(@b)]
      edits = [
        -> { @manifest["schema"] = "future/v2" },
        -> { @manifest.delete("target") },
        -> { @manifest["extra"] = "ignored?" },
        -> { @manifest["paths"] = ["../escape"] },
        -> { @manifest["paths"] = [".GiT/config"] },
        -> { @manifest["paths"] = ["tasks/NEW.yml", "tasks/NEW.yml"] },
        -> { @manifest["patch"]["file"] = "../new task.patch" },
        -> { @manifest["patch"]["sha256"] = "z" * 64 },
        -> { @manifest["repositories"]["data"]["baseline"] = "x" },
        -> { @manifest["repositories"]["data"]["remote_url"] = "#{@b}.git" },
        -> { @manifest["repositories"]["tool"]["remote_url"] = "#{@a}.git" },
        -> { @manifest["repositories"]["data"]["path"] = "../A" },
        -> { @manifest["validation"][0]["action"] = "sh; touch injected" },
        -> { @manifest["validation"][0]["cwd"] = "../B" },
        -> { @manifest["validation"][0]["env"]["RUBYOPT"] = "-r./injected" },
        -> { @manifest["validation"][0]["env"]["AGENT_CODING_TOOL_DATA_DIR"] = "unknown" },
        -> { @manifest["validation"][0]["executable"] = "sh" },
        -> { @manifest["validation"][0] = { "action" => "bundle_rake", "repository" => "tool", "cwd" => ".", "env" => {}, "tasks" => ["test; touch injected"] } },
        -> { @manifest["validation"] = [] },
        -> { @manifest["commit_message"] = "title\nbody" }
      ]
      edits.each do |edit|
        @manifest = Marshal.load(original)
        edit.call
        save_manifest
        _stdout, stderr, status = cli(%w[y y y], terminal: false)
        assert_equal 2, status.exitstatus, stderr
        assert_equal before, [state(@a), state(@b)]
        refute File.exist?(File.join(@root, "injected"))
      end
      File.write(@json, "{invalid")
      _stdout, _stderr, status = cli([], terminal: false)
      assert_equal 2, status.exitstatus
      assert_equal before, [state(@a), state(@b)]
    end
  end

  # Native Git rejects tracked/staged edits, occupied destinations, patch tampering,
  # applicability errors, occupied additions and unsafe symlink destinations.
  def test_preflight_artifact_git_and_symlink_refusals_are_read_only
    mutations = [
      -> { File.write(File.join(@a, "file.txt"), "dirty\n") },
      -> { File.write(File.join(@a, "file.txt"), "staged\n"); git(@a, "add", "file.txt") },
      -> { File.write(File.join(@b, "verify.rb"), "dirty\n") },
      -> { File.write(File.join(@b, "verify.rb"), "staged\n"); git(@b, "add", "verify.rb") },
      -> { git(@a, "update-index", "--assume-unchanged", "file.txt"); File.write(File.join(@a, "file.txt"), "hidden edit") },
      -> { File.write(@task, "occupied") },
      -> { FileUtils.rmdir(File.dirname(@task)); File.write(File.dirname(@task), "occupied parent") },
      -> { FileUtils.mkdir_p(@task); File.write(File.join(@task, "nested.txt"), "occupied child") },
      -> { File.write(File.join(@a, ".git", "info", "exclude"), "tasks/NEW.yml\n") },
      -> { File.binwrite(@patch_path, @patch + "tamper") },
      -> { File.unlink(@patch_path) },
      -> { File.rename(@patch_path, "#{@patch_path}.original"); File.symlink("#{@patch_path}.original", @patch_path) },
      -> { @patch = @patch.sub("@@ -0,0 +1,9 @@", "@@ -0,0 +1,99 @@"); File.binwrite(@patch_path, @patch); @manifest["patch"]["sha256"] = Digest::SHA256.hexdigest(@patch); save_manifest },
      -> { @manifest["paths"] = ["unexpected.txt"]; save_manifest },
      -> { @patch = "diff --git a/file.txt b/moved.txt\nsimilarity index 100%\nrename from file.txt\nrename to moved.txt\n"; File.binwrite(@patch_path, @patch); @manifest["paths"] = ["moved.txt"]; @manifest["patch"]["sha256"] = Digest::SHA256.hexdigest(@patch); save_manifest },
      -> { @patch = @patch.sub("100644", "120000"); File.binwrite(@patch_path, @patch); @manifest["patch"]["sha256"] = Digest::SHA256.hexdigest(@patch); save_manifest },
      -> { FileUtils.rmdir(File.dirname(@task)); File.symlink(@b, File.dirname(@task)) }
    ]
    mutations.each_with_index do |mutation, index|
      fixture do
        mutation.call
        before = [state(@a), state(@b)]
        _stdout, stderr, status = cli(%w[y y y], terminal: false)
        assert_equal 2, status.exitstatus, "preflight mutation #{index}: #{stderr}"
        assert_equal before, [state(@a), state(@b)]
      end
    end
  end

  # A failing step preserves binary stdout/stderr and its exact status, skips the
  # later check and never offers commit. The applied candidate remains unstaged.
  def test_validation_failure_preserves_binary_output_status_and_stops
    fixture(script: '$stdout.binmode.write("out\\x00\\xff".b); $stderr.binmode.write("err\\x00\\xfe".b); exit 23') do
      [@a, @b].each { |repo| File.binwrite(File.join(repo, "local.bin"), "keep\x00\xff".b) }
      @manifest.fetch("repositories").each_value { |spec| spec["baseline"] = "a" * 40 }
      save_manifest
      sibling = state(@b)
      stdout, stderr, status = cli(%w[y y y])
      assert_equal 23, status.exitstatus
      assert_includes stdout, "out\x00\xff".b
      assert_includes stderr, "err\x00\xfe".b
      assert_includes stdout, "1 remaining unrun"
      refute_includes stdout, "Validation 2: exit"
      refute_includes stdout, "Stage these files"
      assert File.exist?(@task)
      assert_empty git(@a, "diff", "--cached", "--name-only")
      assert_equal @bases[0], git(@a, "rev-parse", "HEAD").strip
      assert_equal "keep\x00\xff".b, File.binread(File.join(@a, "local.bin"))
      assert_equal sibling, state(@b)
    end
  end

  # Artifact/target/source changes at confirmation boundaries must be refused
  # without staging unrelated changes or undoing the concurrent writer's work.
  def test_confirmation_races_and_repeat_applied_target_refuse
    fixture do
      stdout, stderr, status = cli([-> { File.write(@patch_path, "tampered"); "y" }])
      assert_equal 2, status.exitstatus, stdout
      assert_includes stderr, "SHA-256"
      refute File.exist?(@task)
    end
    [1, 2, 3].each do |phase|
      fixture(nonportable: true) do
        concurrent = File.join(@a, NONPORTABLE_PATHS.fetch(phase - 1))
        answers = Array.new(phase - 1, "y") + [-> { File.write(concurrent, "concurrent"); "y" }]
        stdout, stderr, status = cli(answers)
        assert_equal 2, status.exitstatus, stdout
        assert_includes stderr, "changed"
        assert_equal "concurrent", File.read(concurrent)
        assert_empty git(@a, "diff", "--cached", "--name-only")
        assert_equal phase > 1, File.exist?(@task)
      end
    end
    # Reuse each preview-only fixture, restoring only the injected change after
    # each refusal. Every callback runs after preview, before application consent.
    fixture do
      [@a, @b].each do |repo|
        local = File.join(repo, "local notes (dûm & author's).bin")
        File.binwrite(local, "keep\x00\xff".b)
        mutations = [
          -> { File.write(local, "concurrent") },
          -> { File.chmod(0o755, local) },
          -> { File.unlink(local) },
          -> { File.write(File.join(repo, "unexpected.bin"), "concurrent") }
        ]
        mutations.each do |mutation|
          stdout, stderr, status = cli([-> { mutation.call; "y" }])
          assert_equal 2, status.exitstatus, stdout + stderr
          assert_includes stderr, "changed since review"
          refute File.exist?(@task)
          assert_empty git(@a, "diff", "--cached", "--name-only")
          assert_empty git(@b, "diff", "--cached", "--name-only")
          File.binwrite(local, "keep\x00\xff".b)
          File.chmod(0o644, local)
          unexpected = File.join(repo, "unexpected.bin")
          File.unlink(unexpected) if File.exist?(unexpected)
        end
      end
    end
    fixture do
      cli(%w[y n])
      before = state(@a)
      _stdout, stderr, status = cli(%w[y y y])
      assert_equal 2, status.exitstatus
      assert_includes stderr, "already occupied"
      assert_equal before, state(@a)
    end
    ["data", "tool"].each do |name|
      fixture do
        repo = name == "data" ? @a : @b
        _stdout, stderr, status = cli([-> { git(repo, "commit", "--allow-empty", "-m", "concurrent"); "y" }])
        assert_equal 2, status.exitstatus
        assert_includes stderr, "changed"
        refute File.exist?(@task)
      end
    end
    fixture do
      File.write(File.join(@b, ".gitignore"), "/tmp/\n")
      git(@b, "add", ".gitignore")
      git(@b, "commit", "-m", "ignore generated temporary output")
      @manifest["repositories"]["tool"]["baseline"] = git(@b, "rev-parse", "HEAD").strip
      cwd = File.join(@b, "tmp", "checks")
      FileUtils.mkdir_p(cwd)
      File.write(File.join(cwd, "verify.rb"), "puts 'must not execute'\n")
      @manifest["validation"][0]["cwd"] = "tmp/checks"
      save_manifest
      stdout, stderr, status = cli(["y", -> { FileUtils.remove_entry(cwd); File.symlink(@root, cwd); "y" }])
      assert_equal 2, status.exitstatus
      assert_includes stderr, "symlink"
      refute_includes stdout, "must not execute"
      refute_includes stdout, "Stage these files"
    end
  end

  # Even exit-zero validation cannot modify target/sibling source unnoticed.
  # Ignored generated coverage is narrowly allowed and can coexist with commit.
  def test_validation_source_changes_refuse_and_generated_output_is_bounded
    ["File.write(#{NONPORTABLE_PATHS.last.dump}, 'changed')",
     'File.write(File.join(ENV.fetch("AGENT_CODING_TOOL_DATA_DIR"), "file.txt"), "changed")',
     "File.write(#{IGNORED_PATH.dump}, 'changed')",
     'File.unlink("local.bin")',
     'File.chmod(0o755, "local.bin")',
     'File.write("unexpected.bin", "changed")',
     'File.write("verify.rb", "changed"); exit 23'].each do |script|
      fixture(script: script, nonportable: true) do
        File.binwrite(File.join(@b, "local.bin"), "keep\x00\xff".b)
        stdout, stderr, status = cli(%w[y y y])
        assert_equal script.include?("exit 23") ? 23 : 2, status.exitstatus
        assert_includes stderr, "validation changed"
        refute_includes stdout, "Stage these files"
        assert_empty git(@a, "diff", "--cached", "--name-only")
      end
    end
    fixture(script: 'Dir.mkdir("coverage"); File.write("coverage/output", "generated")') do
      File.write(File.join(@b, ".gitignore"), "/coverage/\n")
      git(@b, "add", ".gitignore")
      git(@b, "commit", "-m", "ignore generated coverage")
      @manifest["repositories"]["tool"]["baseline"] = git(@b, "rev-parse", "HEAD").strip
      save_manifest
      stdout, stderr, status = cli(%w[y y y])
      assert_equal 0, status.exitstatus, stderr + stdout
      assert_includes stdout, "committed locally"
      assert_empty git(@b, "status", "--porcelain")
    end
  end

  # A configured local commit hook failure preserves its exact status and staged
  # proposal. No reset, cleanup, retry, duplicate commit or publication occurs.
  def test_commit_failure_retains_only_proposal_in_index
    fixture do
      hook = File.join(@a, ".git", "hooks", "pre-commit")
      File.write(hook, "#!/bin/sh\necho 'fixture hook refused' >&2\nexit 1\n")
      File.chmod(0o755, hook)
      stdout, stderr, status = cli(%w[y y y])
      assert_equal 1, status.exitstatus, stdout
      assert_includes stderr, "fixture hook refused"
      assert_includes stdout, "commit failed"
      assert_equal "tasks/NEW.yml\n", git(@a, "diff", "--cached", "--name-only")
      assert_equal @bases[0], git(@a, "rev-parse", "HEAD").strip
    end
  end

  # A missing supported executable has a classified 127 outcome; a validation
  # signal has 128+signal status. Both prevent the later check and commit prompt.
  def test_validation_spawn_error_and_signal_status
    fixture do
      @manifest["validation"][0] = { "action" => "bundle_rake", "repository" => "tool", "cwd" => ".", "env" => {}, "tasks" => ["test"] }
      save_manifest
      only_git = File.join(@root, "only-git")
      FileUtils.mkdir_p(only_git)
      git_path = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |directory| File.join(directory, "git") }.find { |path| File.executable?(path) }
      File.symlink(git_path, File.join(only_git, "git"))
      stdout, stderr, status = cli(%w[y y y], environment: { "PATH" => only_git })
      assert_equal 127, status.exitstatus, stdout + stderr
      assert_includes stderr, "Errno::ENOENT"
      assert_includes stderr, "1 remaining unrun"
      refute_includes stdout, "Stage these files"
      assert_empty git(@a, "diff", "--cached", "--name-only")
    end
    fixture(script: 'Process.kill("TERM", Process.pid)') do
      stdout, _stderr, status = cli(%w[y y y])
      assert_equal 143, status.exitstatus
      assert_includes stdout, "exit 143"
      refute_includes stdout, "Stage these files"
    end
  end

  # Interrupt during a real validation child preserves its output, stops the
  # owned process group and leaves applied changes available for inspection.
  def test_interrupt_during_validation_preserves_output_and_candidate
    fixture(script: 'STDOUT.sync = true; puts "before interrupt"; Process.kill("INT", Process.ppid); sleep 2') do
      stdout, stderr, status = cli(%w[y y y])
      assert_equal 130, status.exitstatus, stdout + stderr
      assert_includes stdout, "before interrupt"
      assert_includes stderr, "Interrupted"
      refute_includes stdout, "Stage these files"
      assert File.exist?(@task)
      assert_empty git(@a, "diff", "--cached", "--name-only")
      assert_equal @bases[0], git(@a, "rev-parse", "HEAD").strip
    end
  end

  # Exercises the README contract/example hash, CLI help and supported Rake argv.
  # Mixed ordinary file changes stage together; fixture Rake tasks exercise the
  # documented names without purporting to run ACT's complete acceptance gate.
  def test_bundle_rake_and_mixed_file_patch
    fixture do
      readme = File.read(File.expand_path("../../README.md", __dir__)).split("### Producing a handoff", 2).last
      documented_patch = readme.match(/```diff\n(.*?)```/m)[1]
      example = JSON.parse(readme.match(/```json\n(.*?)```/m)[1])
      assert_equal @patch, documented_patch
      assert_equal Digest::SHA256.hexdigest(documented_patch), example.fetch("patch").fetch("sha256")
      example["repositories"] = @manifest.fetch("repositories")
      example["patch"]["file"] = File.basename(@patch_path)
      @manifest = example
      File.write(File.join(@b, "Gemfile"), File.read(File.expand_path("../../Gemfile", __dir__)))
      File.write(File.join(@b, "Gemfile.lock"), File.read(File.expand_path("../../Gemfile.lock", __dir__)))
      File.write(File.join(@b, "Rakefile"), <<~RUBY)
        require "yaml"
        namespace :actd do
          task :validate_yaml do
            Psych.parse_file(File.join(ENV.fetch("AGENT_CODING_TOOL_DATA_DIR"), "tasks/NEW.yml"))
          end
        end
        namespace :test do
          task :all do
            abort "missing patch" unless File.file?(File.join(ENV.fetch("AGENT_CODING_TOOL_DATA_DIR"), "tasks/NEW.yml"))
            puts "bounded rake passed"
          end
        end
      RUBY
      git(@b, "add", ".")
      git(@b, "commit", "-m", "rake fixture")
      @manifest["repositories"]["tool"]["baseline"] = git(@b, "rev-parse", "HEAD").strip
      # Produce a real binary/modification diff without staging; restore fixture
      # bytes immediately so the proposal begins at a clean target baseline.
      File.binwrite(File.join(@a, "file.txt"), "modified\x00\xff".b)
      File.unlink(File.join(@a, "state", "EXISTING.yml"))
      @patch += git(@a, "diff", "--binary", "--no-renames")
      File.write(File.join(@a, "file.txt"), "base\n")
      File.write(File.join(@a, "state", "EXISTING.yml"), "result: retained\n")
      File.binwrite(@patch_path, @patch)
      @manifest["patch"]["sha256"] = Digest::SHA256.hexdigest(@patch)
      @manifest["paths"] += %w[file.txt state/EXISTING.yml]
      save_manifest
      stdout, stderr, status = cli(%w[y y y])
      assert_equal 0, status.exitstatus, stdout + stderr
      assert_includes stdout, "bounded rake passed"
      assert_equal "modified\x00\xff".b, git(@a, "show", "HEAD:file.txt").b
      refute File.exist?(File.join(@a, "state", "EXISTING.yml"))
      assert_empty git(@a, "status", "--porcelain")
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, CLI, "help", chdir: @root)
      assert_equal 0, status.exitstatus, stderr
      assert_includes stdout, "apply FILE.json"
      assert_includes stdout, "each defaults to no"
      _stdout, _stderr, status = Open3.capture3(RbConfig.ruby, CLI, "apply", @json, "--yes", chdir: @root)
      assert_equal 2, status.exitstatus
    end
  end
end
