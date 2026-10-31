# frozen_string_literal: true

require_relative "test_helper"

# Shared disposable apply-family worlds; native Git creates the oracle history.
# No source decisions are replaced and all mutations stay under TMPDIR.
module ApplyHandoffFixtures
  include TestHelpers
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
      File.write(File.join(@a, "state", "ACT-UX-02.yml"), "result: retained\n")
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

  # Executes local fixture Git with optional stdin; returns stdout, raising on
  # unexpected failure. Mutations are confined to the disposable fixture.
  def git(path, *args, input: "")
    stdout, stderr, status = Open3.capture3("git", *args, chdir: path, stdin_data: input)
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

  # Creates unrelated staged, unstaged, partially staged, deleted and untracked
  # files in both disposable repos. Returns nil; native setup failures raise.
  def dirty_repositories
    [@a, @b].each do |repo|
      File.write(File.join(repo, "file.txt"), "staged version\n")
      File.write(File.join(repo, NONPORTABLE_PATHS[2]), "staged only\n")
      git(repo, "add", "--", "file.txt", NONPORTABLE_PATHS[2])
      File.write(File.join(repo, "file.txt"), "different worktree version\n")
      File.chmod(0o755, File.join(repo, "file.txt"))
      File.unlink(File.join(repo, NONPORTABLE_PATHS[0]))
      git(repo, "rm", "--", NONPORTABLE_PATHS[1])
      File.binwrite(File.join(repo, NONPORTABLE_PATHS[3]), "unstaged\x00\xff".b)
      File.chmod(0o644, File.join(repo, NONPORTABLE_PATHS[3]))
      File.binwrite(File.join(repo, "untracked (keep & dûm's).bin"), "keep\x00\xfe".b)
    end
    File.write(File.join(@a, "state", "ACT-UX-02.yml"), "result: operator edit\n")
    File.chmod(0o755, File.join(@a, "state", "ACT-UX-02.yml"))
    nil
  end

  # Adds a tracked-file edit to the reviewed patch, then restores fixture bytes.
  # Returns the saved manifest; filesystem/native setup errors propagate.
  def overlapping_proposal
    File.write(File.join(@a, "file.txt"), "proposal version\n")
    @patch += git(@a, "diff", "--binary", "--no-renames")
    File.write(File.join(@a, "file.txt"), "base\n")
    File.binwrite(@patch_path, @patch)
    @manifest["paths"] << "file.txt"
    @manifest["patch"]["sha256"] = Digest::SHA256.hexdigest(@patch)
    save_manifest
  end

end
