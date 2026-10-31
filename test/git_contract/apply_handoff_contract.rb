# frozen_string_literal: true

require_relative "../apply_handoff_support"
require_relative "../apply_handoff_observations"

# Records one genuine composed run, then exercises full Ruby decision workflows
# against finite phase transcripts and real fixture bytes/modes. Native public
# CLI tests independently retain Git mutation, PTY, hook and process contracts.
class ApplyHandoffContract < Minitest::Test
  include ApplyHandoffFixtures

  # Runs real parsing, snapshots, decisions and reporting using terminal answers
  # and a declared transport. Returns code/streams; missing observations raise.
  def observed_run(records, answers, &validation_effect)
    transport = ApplyHandoffObservations::Transport.new(records) do |record|
      if record.fetch(:argv) == %w[git apply]
        File.binwrite(@task, TASK)
      elsif record.fetch(:argv).first == RbConfig.ruby
        validation_effect&.call
      end
    end
    input = ApplyHandoffObservations::Input.new(answers)
    result = run_handoff(input, transport)
    begin
      transport.verify!
    rescue GitContract::UnexpectedObservation => error
      raise GitContract::UnexpectedObservation, "#{error.message}; run result: #{result.inspect}"
    end
    input.verify!
    result
  end

  # Calls the real owned native pipe implementation, recording exact requests
  # and native results. Marks partition requests at actual confirmation reads.
  # Returns [run result, records, marks]; native failures remain test failures.
  def native_run(answers)
    # Match the public CLI driver's removal of only its synthetic skill preload;
    # retain arbitrary inherited options, especially child coverage instrumentation.
    previous_rubyopt = ENV["RUBYOPT"]
    skill_preload = "-r#{File.expand_path('../coding_skill_support.rb', __dir__)}"
    ENV["RUBYOPT"] = Shellwords.join(Shellwords.split(previous_rubyopt.to_s).reject { |option| option == skill_preload })
    records, marks = [], []
    input = ApplyHandoffObservations::Input.new(answers) { marks << records.length }
    native = nil
    transport = lambda do |argv, **options|
      result = native.send(:capture_process, argv, **options)
      records << { argv: argv, **options, result: result }
      result
    end
    out, err = StringIO.new("".b), StringIO.new("".b)
    native = AgentCodingTool::ApplyHandoff.new(config: apply_config, input: input, out: out, err: err, transport: transport)
    code = native.run(@json)
    assert_equal 0, code, out.string + err.string
    input.verify!
    [[code, out.string, err.string], records, marks]
  ensure
    ENV["RUBYOPT"] = previous_rubyopt
  end

  # Creates only the configured repository binding; configuration errors raise.
  def apply_config
    AgentCodingTool::Config.new({ "repo_root" => @repos, "default_remote" => "origin" }, base_dir: @root)
  end

  # Executes one invocation using raw binary streams; exceptions propagate.
  def run_handoff(input, transport)
    out, err = StringIO.new("".b), StringIO.new("".b)
    code = AgentCodingTool::ApplyHandoff.new(config: apply_config, input: input, out: out, err: err, transport: transport).run(@json)
    [code, out.string, err.string]
  end

  # Restores this matrix's private seed copy and original downloaded artifacts.
  # Real file I/O errors propagate; no Git command or shared checkout is touched.
  def restore_world
    FileUtils.remove_entry(@repos)
    FileUtils.cp_r(@saved_repos, @repos)
    @manifest = Marshal.load(@saved_manifest)
    File.unlink(@patch_path) if File.symlink?(@patch_path)
    File.binwrite(@patch_path, @patch)
    save_manifest
  end

  # Captures non-Git regular bytes/modes directly; used independently of replayed
  # Git output. Paths and content retain binary/nonportable bytes; I/O may raise.
  def file_state(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |path| path == ".git" || path.start_with?(".git/") }
       .select { |path| File.file?(File.join(root, path)) }.sort.to_h do |path|
      absolute = File.join(root, path)
      [path, [File.stat(absolute).mode & 0o777, File.binread(absolute)]]
    end
  end

  # Requires refusal before application/validation/staging and proves both real
  # trees and indexes retain their original bytes. Returns nil; assertions fail.
  def assert_read_only_refusal(records)
    before = [file_state(@a), file_state(@b)]
    indexes = [@a, @b].map { |repo| File.binread(File.join(repo, ".git", "index")) }
    code, stdout, stderr = observed_run(records, [])
    assert_equal 2, code, stdout + stderr
    assert_includes stderr, "ERROR: apply:"
    assert_equal before, [file_state(@a), file_state(@b)]
    assert_equal indexes, [@a, @b].map { |repo| File.binread(File.join(repo, ".git", "index")) }
    refute File.exist?(File.join(@root, "injected"))
  end

  # Returns a transcript with selected native stdout bytes changed, retaining
  # every exact request, code and stream otherwise. The selector must match.
  def changed_output(records, argv, cwd, replacement)
    found = false
    altered = records.map do |record|
      next record unless record.fetch(:argv) == argv && record.fetch(:cwd) == cwd
      found = true
      record.merge(result: [replacement, *record.fetch(:result).drop(1)])
    end
    assert found, "missing native request #{argv.inspect}"
    altered
  end

  # Records real application/sibling validation/local commit once, verifies its
  # native effects, and checks every migrated permutation through actual run.
  # Assertions and strict request consumption fail closed on lost transitions.
  def test_complete_run_decision_matrices_with_native_parity
    fixture(nonportable: true) do
      executed = Hash.new(0)
      [@a, @b].each { |repo| File.binwrite(File.join(repo, "local.bin"), "keep\x00\xff".b) }
      @saved_manifest = Marshal.dump(@manifest)
      @saved_repos = File.join(@root, "saved-repositories")
      FileUtils.cp_r(@repos, @saved_repos)
      initial_files = [file_state(@a), file_state(@b)]
      initial_indexes = [@a, @b].map { |repo| File.binread(File.join(repo, ".git", "index")) }
      [@a, @b].each do |repo|
        _stdout, _stderr, status = Open3.capture3("git", "cat-file", "-e", "#{'a' * 40}^{commit}", chdir: repo)
        refute status.success?, "declared drift baseline must be absent"
      end
      declined, declined_records, = native_run(["no"])
      assert_equal 0, declined.first, declined.inspect
      assert_equal initial_files, [file_state(@a), file_state(@b)]
      result, records, marks = native_run(%w[yes yes yes])
      assert_equal 0, result.first, result.inspect
      assert_includes result[1], "sibling validation passed"
      assert_includes result[1], "committed locally"
      assert_equal TASK, git(@a, "show", "HEAD:tasks/NEW.yml")
      assert_equal "tasks/NEW.yml\n", git(@a, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD")
      assert_equal @bases[0], git(@a, "rev-parse", "HEAD^").strip
      assert_equal initial_files[0], file_state(@a).reject { |path, _value| path == "tasks/NEW.yml" }
      assert_equal initial_files[1], file_state(@b)
      preview = records.take(marks.fetch(0))
      application = records[marks.fetch(0)...marks.fetch(1)]
      validation = records[marks.fetch(1)...marks.fetch(2)]
      initial_report = declined_records.last(2)
      applied_report = application.last(2)
      snapshot_length = preview.index { |record| record.fetch(:argv) == %w[git diff --cached --name-only --no-renames -z] }
      refute_nil snapshot_length
      snapshot = preview.take(snapshot_length)
      applied_snapshot = validation.take(snapshot_length)

      # Each refusal stops the actual composed flow at its independent consent
      # boundary. Native PTY blank/EOF/nonterminal cases prove the OS capability.
      [1, 2, 3].each do |phase|
        executed["consent"] += 1
        restore_world
        prefix = [preview, preview + application, preview + application + validation].fetch(phase - 1)
        report = phase == 1 ? initial_report : applied_report
        code, stdout, stderr = observed_run(prefix + report, Array.new(phase - 1, "yes") + ["no"])
        assert_equal 0, code, stderr
        assert_includes stdout, "#{%w[Application Validation Commit].fetch(phase - 1)} declined"
        assert_equal phase > 1, File.exist?(@task)
        refute_includes stdout, "committed locally"
        assert_equal initial_indexes, [@a, @b].map { |repo| File.binread(File.join(repo, ".git", "index")) }
      end

      # Drift and untracked permutations retain exact native output contracts;
      # the absent baseline is provenance only, never an object to execute/read.
      [false, true].product([false, true]).each do |drift, untracked|
        executed["success"] += 1
        restore_world
        @manifest.fetch("repositories").each_value { |spec| spec["baseline"] = "a" * 40 } if drift
        selected = records
        unless untracked
          [@a, @b].each { |repo| File.unlink(File.join(repo, "local.bin")) }
          selected = records.map do |record|
            output = record.fetch(:result).first
            output = output.split("\0").reject { |path| path == "local.bin" }.map { |path| "#{path}\0" }.join if record.fetch(:argv).include?("--others")
            output = output.lines.reject { |line| line == "?? local.bin\n" }.join if record.fetch(:argv)[1] == "status"
            record.merge(result: [output, *record.fetch(:result).drop(1)])
          end
        end
        @manifest["commit_message"] = "Register NEW task"
        save_manifest
        code, stdout, stderr = observed_run(selected, %w[y y y])
        assert_equal 0, code, stderr
        assert_equal 3, stdout.scan("[y/N]").length
        %w[data tool].each do |name|
          assert_equal drift, stdout.include?("WARN: #{name}: baseline differs;")
          assert_equal untracked, stdout.include?("WARN: #{name}: preserving initial untracked files:")
        end
        assert_includes stdout, "sibling validation passed"
        assert_includes stdout, "committed locally"
        assert_equal "NEW", AgentCodingTool::TaskStore.new(File.join(@a, "tasks")).load("NEW").fetch("id")
        assert_equal TASK, File.binread(@task)
        assert_equal initial_indexes, [@a, @b].map { |repo| File.binread(File.join(repo, ".git", "index")) }
      end

      # The original 20 contract mutations plus malformed JSON are full run
      # refusals. Identity errors consume exactly their native inspection prefix.
      restore_world
      mutations = [
        -> { @manifest["schema"] = "future/v2" }, -> { @manifest.delete("target") },
        -> { @manifest["extra"] = "ignored?" }, -> { @manifest["paths"] = ["../escape"] },
        -> { @manifest["paths"] = [".GiT/config"] }, -> { @manifest["paths"] *= 2 },
        -> { @manifest["patch"]["file"] = "../new task.patch" }, -> { @manifest["patch"]["sha256"] = "z" * 64 },
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
        -> { @manifest["validation"] = [] }, -> { @manifest["commit_message"] = "title\nbody" }
      ]
      mutations.each_with_index do |mutation, index|
        executed["contract"] += 1
        @manifest = Marshal.load(@saved_manifest)
        mutation.call
        save_manifest
        expected = [0, 1, 2, 8, 11].include?(index) ? [] : initial_report
        if [9, 10].include?(index)
          cwd = index == 9 ? @a : @b
          last = snapshot.index { |record| record.fetch(:cwd) == cwd && record.fetch(:argv) == %w[git remote get-url origin] }
          expected = snapshot.take(last + 1) + initial_report
        end
        assert_read_only_refusal(expected)
      end
      File.write(@json, "{invalid")
      assert_read_only_refusal([])
      executed["contract"] += 1

      # Artifact and portable-path decisions formerly required seven separate
      # worlds. Git applicability/index/occupied-file refusals remain native.
      before_patch = preview.take(preview.index { |record| record.fetch(:argv) == %w[git apply --numstat -z] })
      artifact_mutations = [
        -> { File.binwrite(@patch_path, @patch + "tamper") },
        -> { File.unlink(@patch_path) },
        -> { File.rename(@patch_path, "#{@patch_path}.original"); File.symlink("#{@patch_path}.original", @patch_path) },
        -> { @manifest["paths"] = ["unexpected.txt"] },
        -> { File.binwrite(@patch_path, "diff --git a/file.txt b/moved.txt\nsimilarity index 100%\nrename from file.txt\nrename to moved.txt\n"); @manifest["paths"] = ["moved.txt"] },
        -> { File.binwrite(@patch_path, @patch.sub("100644", "120000")) },
        -> { FileUtils.rmdir(File.dirname(@task)); File.symlink(@b, File.dirname(@task)) }
      ]
      artifact_mutations.each_with_index do |mutation, index|
        executed["preflight"] += 1
        restore_world
        mutation.call
        @manifest["patch"]["sha256"] = Digest::SHA256.file(@patch_path).hexdigest if [4, 5].include?(index)
        save_manifest
        expected = before_patch + ([3, 6].include?(index) ? [preview.fetch(before_patch.length)] : []) + initial_report
        assert_read_only_refusal(expected)
      end

      # Every phase checks both source snapshots and downloaded bytes again.
      # Head/index responses are deliberate faults in native observations; real
      # file races at all three prompts independently remain in the PTY suite.
      [1, 2, 3].each do |phase|
        prefix = [preview, preview + application, preview + application + validation].fetch(phase - 1)
        current_snapshot = phase == 1 ? snapshot : applied_snapshot
        report = phase == 1 ? initial_report : applied_report
        %i[head sibling_head index patch manifest].each do |mutation|
          executed["phase"] += 1
          restore_world
          inspection = current_snapshot
          if %i[head sibling_head].include?(mutation)
            inspection = changed_output(inspection, %w[git rev-parse HEAD], mutation == :head ? @a : @b, "#{'c' * 40}\n")
          elsif mutation == :index
            native_index = inspection.find { |record| record.fetch(:cwd) == @a && record.fetch(:argv) == %w[git ls-files --stage -z] }.fetch(:result).first
            inspection = changed_output(inspection, %w[git ls-files --stage -z], @a, native_index.sub("100644", "100755"))
          end
          answers = Array.new(phase - 1, "y") + [lambda do
            File.binwrite(@patch_path, "tampered") if mutation == :patch
            File.write(@json, File.read(@json) + "\n") if mutation == :manifest
            "y"
          end]
          code, stdout, stderr = observed_run(prefix + inspection + report, answers)
          assert_equal 2, code, stdout + stderr
          assert_match(/changed|SHA-256/, stderr)
          assert_equal phase > 1, File.exist?(@task)
          outcome = ["not applied; validation and commit not run", "applied; validation not run; commit not run",
                     "applied; validated; commit not run"].fetch(phase - 1)
          assert_includes stdout, "Apply outcome: #{outcome}"
          refute_includes stdout, "committed locally"
          assert_equal initial_indexes, [@a, @b].map { |repo| File.binread(File.join(repo, ".git", "index")) }
        end
      end

      # Real untracked byte/mode/deletion/addition effects in each sibling are
      # read by production snapshots; only the Git name inventory is observed.
      [@a, @b].each do |repo|
        %i[bytes mode deletion addition].each do |mutation|
          executed["local"] += 1
          restore_world
          inspection = snapshot
          if mutation == :addition
            inspection = changed_output(inspection, %w[git ls-files -z --others --exclude-standard], repo, "local.bin\0unexpected.bin\0")
          end
          local = File.join(repo, "local.bin")
          answer = lambda do
            case mutation
            when :bytes then File.binwrite(local, "concurrent")
            when :mode then File.chmod(0o755, local)
            when :deletion then File.unlink(local)
            when :addition then File.binwrite(File.join(repo, "unexpected.bin"), "concurrent")
            end
            "y"
          end
          code, stdout, stderr = observed_run(preview + inspection + initial_report, [answer])
          assert_equal 2, code, stdout + stderr
          assert_includes stderr, "changed since review"
          refute File.exist?(@task)
          assert_equal initial_indexes, [@a, @b].map { |root| File.binread(File.join(root, ".git", "index")) }
        end
      end

      # Validation effects retain real file reads and the failing-step status
      # even when source changed. Native output/status/signal and target-source
      # changes, plus bounded generated output and commit, stay in the CLI suite.
      first_validation = validation.index { |record| record.fetch(:argv).first == RbConfig.ruby }
      validation_prefix = validation.take(first_validation + 1)
      after_step = validation.drop(first_validation + 1).take(snapshot_length)
      %i[nonportable ignored deletion mode addition failing_source].each do |mutation|
        executed["validation"] += 1
        restore_world
        inspection = after_step
        execution = validation_prefix
        if mutation == :addition
          inspection = changed_output(inspection, %w[git ls-files -z --others --exclude-standard], @b, "local.bin\0unexpected.bin\0")
        elsif mutation == :failing_source
          execution = validation_prefix[0...-1] + [validation_prefix.last.merge(result: ["".b, "".b, 23])]
        end
        code, stdout, stderr = observed_run(preview + application + execution + inspection + applied_report, %w[y y]) do
          case mutation
          when :nonportable then File.binwrite(File.join(@b, NONPORTABLE_PATHS.last), "changed")
          when :ignored then File.binwrite(File.join(@b, IGNORED_PATH), "changed")
          when :deletion then File.unlink(File.join(@b, "local.bin"))
          when :mode then File.chmod(0o755, File.join(@b, "local.bin"))
          when :addition then File.binwrite(File.join(@b, "unexpected.bin"), "changed")
          when :failing_source then File.binwrite(File.join(@b, "verify.rb"), "changed")
          end
        end
        assert_equal mutation == :failing_source ? 23 : 2, code, stdout + stderr
        assert_includes stderr, "validation changed"
        refute_includes stdout, "Stage these files"
        assert_equal initial_indexes, [@a, @b].map { |repo| File.binread(File.join(repo, ".git", "index")) }
      end
      restore_world
      restored = observed_run(records, %w[yes yes yes])
      assert_equal result, restored
      # Independent accounting catches a missing/empty matrix even when another
      # permutation happens to cover the same production lines or branches.
      assert_equal({ "consent" => 3, "success" => 4, "contract" => 21, "preflight" => 7,
                     "phase" => 15, "local" => 8, "validation" => 6 }, executed)
    end
  end

  # Qualifies exact matching/consumption including binary stdin, environment,
  # cwd, ordering, duplicates and omitted requests. Ambient Git overrides must
  # refuse before even the injected boundary; restored positive requests pass.
  def test_strict_transport_and_ambient_git_refusal
    record = { argv: %w[git apply], cwd: "/fixture", env: { "GIT_TERMINAL_PROMPT" => "0", "GIT_PAGER" => "cat" },
               input: "patch\x00\xff".b, result: ["out\x00\xff".b, "err\x00\xfe".b, 23] }
    arguments = record.slice(:cwd, :env, :input)
    [arguments.merge(cwd: "/wrong"), arguments.merge(env: {}), arguments.merge(input: "wrong")].each do |options|
      replay = ApplyHandoffObservations::Transport.new([record])
      assert_raises(GitContract::UnexpectedObservation) { replay.call(record.fetch(:argv), **options) }
    end
    replay = ApplyHandoffObservations::Transport.new([record])
    assert_raises(GitContract::UnexpectedObservation) { replay.call(%w[git diff], **arguments) }
    assert_raises(GitContract::UnexpectedObservation) { replay.verify! }
    assert_equal record.fetch(:result), replay.call(record.fetch(:argv), **arguments)
    assert replay.verify!
    assert_raises(GitContract::UnexpectedObservation) { replay.call(record.fetch(:argv), **arguments) }
    other = record.merge(argv: %w[git status])
    ordered = ApplyHandoffObservations::Transport.new([record, other])
    assert_raises(GitContract::UnexpectedObservation) { ordered.call(other.fetch(:argv), **arguments) }
    previous = ENV["GIT_WORK_TREE"]
    begin
      ENV["GIT_WORK_TREE"] = "/untrusted"
      handoff = AgentCodingTool::ApplyHandoff.new(config: nil, transport: replay)
      error = assert_raises(AgentCodingTool::Error) { handoff.send(:execute, %w[git apply], cwd: "/fixture") }
      assert_includes error.message, "ambient GIT_*"
    ensure
      ENV["GIT_WORK_TREE"] = previous
    end
    positive = ApplyHandoffObservations::Transport.new([record])
    handoff = AgentCodingTool::ApplyHandoff.new(config: nil, transport: positive)
    assert_equal record.fetch(:result), handoff.send(:execute, record.fetch(:argv), cwd: "/fixture", input: record.fetch(:input))
    assert positive.verify!
  end
end
