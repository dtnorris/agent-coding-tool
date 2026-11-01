# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "digest"
require_relative "../lib/agent_coding_tool/manager_reminder"

# Exercises the public CLI with real task files and a fake clipboard boundary.
# The ordinary guard prohibits Git, shell, network helpers and child processes.
class ManageTest < Minitest::Test
  include TestHelpers

  # Records one exact clipboard envelope, returning supplied termination facts
  # or raising a supplied spawn/IO error. No subprocess or clipboard is touched.
  class Clipboard
    attr_reader :calls

    # Accepts a CommandResult or exception; construction has no side effects.
    def initialize(result = AgentCodingTool::CommandResult.new(stdout: "", stderr: "", exitstatus: 0))
      @result = result
      @calls = []
    end

    # Captures argv/keyword arguments. Returns result or propagates the fixture
    # exception; any non-pbcopy operation fails before an external effect.
    def call(argv, **options)
      raise "unexpected external call" unless argv == ["pbcopy"]
      @calls << [argv, options]
      raise @result if @result.is_a?(Exception)
      @result
    end
  end

  # Runs the public dispatcher against one disposable data root and returns
  # [exit, stdout, stderr, clipboard]; product errors are handled by the CLI.
  def manage(dir, *arguments, clipboard: Clipboard.new)
    out, err = StringIO.new, StringIO.new
    code = AgentCodingTool::CLI.run(["manage", *arguments], root: dir, data_root: dir,
      out: out, err: err, transport: clipboard)
    [code, out.string, err.string, clipboard]
  end

  # Updates only the fixture task mapping; malformed replacements are explicit.
  def change_task(dir)
    path = File.join(dir, "tasks", "T1.yml")
    task = YAML.safe_load_file(path)
    yield task
    File.write(path, YAML.dump(task))
  end

  # Captures all generated regular-file bytes to prove the command writes none.
  def files(dir)
    Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
      .to_h { |path| [path, File.binread(path)] }
  end

  # Proves exact selected-source binding and no lifecycle/configuration reads.
  def test_stdout_is_deterministic_source_bound_and_read_only
    with_workspace do |dir|
      write_task(dir, id: "T1")
      File.write(File.join(dir, "config.yml"), "malformed: [")
      File.write(File.join(dir, "state", "T1.yml"), "secret progress must not be read")
      File.write(File.join(dir, "tasks", "UNRELATED.yml"), "malformed: [")
      before = files(dir)
      code, text, error, clipboard = manage(dir, "T1", "--stdout")
      assert_equal 0, code
      assert_empty error
      assert_empty clipboard.calls
      assert_includes text, 'For T1, keep this registered goal in view: "Do the bounded thing."'
      assert_includes text, "tasks/T1.yml (SHA-256 #{Digest::SHA256.hexdigest(before.fetch(File.join(dir, 'tasks', 'T1.yml')))})"
      assert_includes text, "not a prepared snapshot or verified progress report"
      assert_includes text, "complete acceptance criteria and constraints"
      refute_includes text, "secret progress"
      assert_equal text, manage(dir, "--stdout", "T1")[1]
      assert_equal before, files(dir)
    end
  end

  # The clipboard receives exactly stdout's bytes once; input is never shell code.
  def test_default_copies_exact_unicode_text_and_confirms_only_after_success
    with_workspace do |dir|
      write_task(dir, id: "T1")
      change_task(dir) { |task| task["goal"] = "Discover 雪 and café.\nPreserve $(touch nope) and `literal`." }
      before = files(dir)
      expected = manage(dir, "T1", "--stdout")[1]
      code, text, error, clipboard = manage(dir, "T1")
      assert_equal 0, code
      assert_empty error
      assert_equal [[["pbcopy"], { input: expected, timeout: 5 }]], clipboard.calls
      assert_equal "Copied manager reminder for T1; paste it above your update.\n", text
      assert_includes expected, 'Discover 雪 and café. Preserve $(touch nope) and `literal`.'
      assert_equal before, files(dir)
    end
  end

  # Nonzero exits/signals preserve failure and never print copy success or stderr secrets.
  def test_clipboard_failure_preserves_exit_or_signal_and_offers_stdout
    with_workspace do |dir|
      write_task(dir, id: "T1")
      [{ exitstatus: 7 }, { termsig: 15 }].each do |termination|
        result = AgentCodingTool::CommandResult.new(stdout: "private", stderr: "secret", **termination)
        code, text, error, clipboard = manage(dir, "T1", clipboard: Clipboard.new(result))
        assert_equal result.shell_status, code
        assert_empty text
        assert_equal 1, clipboard.calls.length
        assert_includes error, "act manage T1 --stdout"
        refute_includes error, "secret"
      end
    end
  end

  # Missing executable, IO refusal and timeout remain recoverable command failures.
  def test_clipboard_unavailable_returns_failure_without_success
    with_workspace do |dir|
      write_task(dir, id: "T1")
      [Errno::ENOENT.new, Errno::EACCES.new, IOError.new, Timeout::Error.new].each do |failure|
        code, text, error, = manage(dir, "T1", clipboard: Clipboard.new(failure))
        assert_equal 2, code
        assert_empty text
        assert_includes error, "act manage T1 --stdout"
      end
    end
  end

  # Syntax/traversal/unknown sources refuse before clipboard invocation.
  def test_invalid_arguments_and_unknown_ids_refuse_before_copy
    with_workspace do |dir|
      write_task(dir, id: "T1")
      [[], ["T1", "extra"], ["T1", "--std"], ["T1", "--unknown"],
       ["../T1"], ["/T1"], ["T1;echo"], ["MISSING"]].each do |arguments|
        code, text, error, clipboard = manage(dir, *arguments)
        assert_equal 2, code, arguments.inspect
        assert_empty text
        refute_empty error
        assert_empty clipboard.calls
      end
    end
  end

  # Missing/invalid semantics cannot produce an invented goal or acceptance.
  def test_malformed_or_incomplete_sources_refuse_before_copy
    with_workspace do |dir|
      invalid = [nil, [], { "id" => "OTHER" }, { "goal" => " " }, { "goal" => 1 },
        { "acceptance" => [] }, { "acceptance" => [nil] }, { "constraints" => "none" },
        { "constraints" => [1] }, { "goal" => "bad\e[31m" }]
      invalid.each do |replacement|
        write_task(dir, id: "T1")
        if replacement.is_a?(Hash)
          change_task(dir) { |task| task.merge!(replacement) }
        else
          File.write(File.join(dir, "tasks", "T1.yml"), YAML.dump(replacement))
        end
        code, text, error, clipboard = manage(dir, "T1")
        assert_equal 2, code, replacement.inspect
        assert_empty text
        refute_empty error
        assert_empty clipboard.calls
      end
      ["bad: [", "---\na: &a 1\nb: *a\n", "\xff".b].each do |bytes|
        File.binwrite(File.join(dir, "tasks", "T1.yml"), bytes)
        assert_equal 2, manage(dir, "T1")[0]
      end
    end
  end

  # Regular-file and containment checks reject leaf and ancestor symlinks/FIFOs.
  def test_unsafe_source_types_refuse_without_copy
    with_workspace do |dir|
      write_task(dir, id: "T1")
      path = File.join(dir, "tasks", "T1.yml")
      saved = File.join(dir, "saved.yml")
      File.rename(path, saved)
      File.symlink(saved, path)
      assert_equal 2, manage(dir, "T1")[0]
      File.unlink(path)
      Dir.mkdir(path)
      assert_equal 2, manage(dir, "T1")[0]
      Dir.rmdir(path)
      File.mkfifo(path)
      assert_equal 2, manage(dir, "T1")[0]
      File.unlink(path)
      File.rename(saved, path)
      File.rename(File.join(dir, "tasks"), File.join(dir, "moved"))
      File.symlink(File.join(dir, "moved"), File.join(dir, "tasks"))
      assert_equal 2, manage(dir, "T1")[0]
    end
  end

  # Oversize input/output is refused, never silently abbreviated onto clipboard.
  def test_size_limits_refuse_before_copy_without_truncation
    with_workspace do |dir|
      write_task(dir, id: "T1")
      path = File.join(dir, "tasks", "T1.yml")
      File.write(path, "x" * (AgentCodingTool::ManagerReminder::MAX_SOURCE_BYTES + 1))
      code, text, error, clipboard = manage(dir, "T1")
      assert_equal 2, code
      assert_empty text
      assert_empty clipboard.calls
      assert_includes error, "regular file"
      write_task(dir, id: "T1")
      change_task(dir) { |task| task["goal"] = "x" * AgentCodingTool::ManagerReminder::MAX_REMINDER_BYTES }
      code, text, error, clipboard = manage(dir, "T1")
      assert_equal 2, code
      assert_empty text
      assert_empty clipboard.calls
      assert_includes error, "not truncated"
    end
  end

  # Current local edits change both goal and source identity without stale-state claims.
  def test_local_goal_edits_change_the_next_reminder
    with_workspace do |dir|
      write_task(dir, id: "T1")
      first = manage(dir, "T1", "--stdout")[1]
      change_task(dir) { |task| task["goal"] = "Deliver the revised outcome." }
      second = manage(dir, "T1", "--stdout")[1]
      refute_equal first, second
      refute_includes second, "Do the bounded thing"
      assert_includes second, "Deliver the revised outcome."
      assert_includes second, Digest::SHA256.file(File.join(dir, "tasks", "T1.yml")).hexdigest
    end
  end
end
