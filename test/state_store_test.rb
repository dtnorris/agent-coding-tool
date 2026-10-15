# frozen_string_literal: true

require "minitest/mock"
require "stringio"
require_relative "test_helper"

# Exercises persistence boundaries only with synthetic state in temporary roots.
class StateStoreTest < Minitest::Test
  include TestHelpers

  # Missing files remain absent; legacy empty and partial mappings remain valid.
  def test_missing_and_legacy_mappings
    with_store do |store, root|
      assert_equal({}, store.load("T1"))
      refute File.exist?(store.state_path("T1"))
      [{}, { "id" => "T1" }, { "started_at" => "old", "result" => { "outcome" => "failed" } }].each do |state|
        store.write("T1", state)
        assert_equal state, store.load("T1")
      end
      assert_equal ["T1.yml"], Dir.children(root)
    end
  end

  # Damaged YAML must identify the task without echoing document contents.
  def test_damaged_documents_are_rejected
    with_store do |store, _root|
      ["", " \n", "---\n", "null\n", "~\n", "secret: [\n", "secret\n", "false\n", "- secret\n"].each do |bytes|
        File.write(store.state_path("T1"), bytes)
        error = assert_raises(AgentCodingTool::InvalidState, bytes.inspect) { store.load("T1") }
        assert_includes error.message, "T1"
        refute_includes error.message, "secret"
        assert_equal bytes, File.binread(store.state_path("T1"))
      end
    end
  end

  # Serialization must finish before any destination or temporary file is opened.
  def test_serialization_failure_preserves_previous_bytes
    with_store do |store, root|
      store.write("T1", { "id" => "T1" })
      before = File.binread(store.state_path("T1"))
      YAML.stub(:dump, ->(_state) { raise TypeError, "synthetic serialization failure" }) do
        assert_raises(TypeError) { store.write("T1", { "id" => "new" }) }
      end
      assert_equal before, File.binread(store.state_path("T1"))
      assert_equal ["T1.yml"], Dir.children(root)
    end
  end

  # Partial writes and failures at flush, file sync and close cannot publish bytes.
  def test_temporary_file_failures_preserve_old_state_and_cleanup
    %i[write flush fsync close].each do |operation|
      with_store do |store, root|
        old_state = { "id" => "T1", "started_at" => "old" }
        store.write("T1", old_state)
        before = File.binread(store.state_path("T1"))
        fail_temporary_operation(operation) do
          assert_raises(Errno::ENOSPC, operation.to_s) { store.write("T1", { "id" => "new" }) }
        end
        assert_equal before, File.binread(store.state_path("T1")), operation.to_s
        assert_equal old_state, store.load("T1")
        assert_equal ["T1.yml"], Dir.children(root)
      end
    end
  end

  # Failed first writes must leave neither a partial destination nor a temporary.
  def test_failed_initial_creation_is_not_published
    %i[write flush fsync close].each do |operation|
      with_store do |store, root|
        fail_temporary_operation(operation) do
          assert_raises(Errno::ENOSPC) { store.write("T1", { "id" => "new" }) }
        end
        refute File.exist?(store.state_path("T1"))
        assert_empty Dir.children(root)
      end
    end
  end

  # Replacement failure occurs with complete temporary bytes and preserves the old file.
  def test_rename_failure_preserves_state_and_cleans_temporary
    [true, false].each do |existing|
      with_store do |store, root|
        store.write("T1", { "id" => "old" }) if existing
        path = store.state_path("T1")
        before = File.binread(path) if existing
        replacement = { "id" => "new", "payload" => "complete" }
        File.stub(:rename, lambda { |temporary, destination|
          assert_equal root, File.dirname(temporary)
          assert_equal path, destination
          assert_equal YAML.dump(replacement), File.binread(temporary)
          raise Errno::EACCES, "synthetic rename failure"
        }) do
          assert_raises(Errno::EACCES) { store.write("T1", replacement) }
        end
        if existing
          assert_equal before, File.binread(path)
          assert_equal ["T1.yml"], Dir.children(root)
        else
          refute File.exist?(path)
          assert_empty Dir.children(root)
        end
      end
    end
  end

  # Directory sync failure is reported after publication, including unsupported capability.
  def test_directory_sync_failure_truthfully_reports_published_state
    [Errno::EIO, Errno::EINVAL, Errno::ENOTSUP, NotImplementedError].each do |failure|
      with_store do |store, root|
        store.write("T1", { "id" => "old" })
        replacement = { "id" => "new" }
        open_file = File.method(:open)
        File.stub(:open, lambda { |path, *args, **options, &block|
          next open_file.call(path, *args, **options) unless block

          open_file.call(path, *args, **options) do |file|
            if path == root
              file.stub(:fsync, -> { raise failure, "synthetic directory sync failure" }) { block.call(file) }
            else
              block.call(file)
            end
          end
        }) do
          error = assert_raises(AgentCodingTool::InvalidState) { store.write("T1", replacement) }
          assert_includes error.message, "T1"
          assert_includes error.message, "replaced"
          assert_includes error.message, failure == Errno::EIO ? "failed" : "unsupported"
        end
        assert_equal replacement, store.load("T1")
        assert_equal ["T1.yml"], Dir.children(root)
      end
    end
  end

  # A short write return value cannot be mistaken for a complete temporary file.
  def test_short_write_is_rejected_and_cleaned_up
    with_store do |store, root|
      store.write("T1", { "id" => "old" })
      before = File.binread(store.state_path("T1"))
      create = Tempfile.method(:create)
      Tempfile.stub(:create, lambda { |*args, **options, &block|
        create.call(*args, **options) do |temporary|
          write = temporary.method(:write)
          temporary.stub(:write, ->(bytes) { write.call(bytes.byteslice(0, 5)) }) { block.call(temporary) }
        end
      }) do
        assert_raises(IOError) { store.write("T1", { "id" => "new" }) }
      end
      assert_equal before, File.binread(store.state_path("T1"))
      assert_equal ["T1.yml"], Dir.children(root)
    end
  end

  # Atomic replacement must not bypass write denial on an existing destination.
  def test_existing_write_access_is_checked_without_truncation
    with_store do |store, root|
      store.write("T1", { "id" => "old" })
      path = store.state_path("T1")
      before = File.binread(path)
      open_file = File.method(:open)
      File.stub(:open, lambda { |filename, *args, **options, &block|
        raise Errno::EACCES if filename == path && args.first == File::WRONLY

        open_file.call(filename, *args, **options, &block)
      }) { assert_raises(Errno::EACCES) { store.write("T1", { "id" => "new" }) } }
      assert_equal before, File.binread(path)
      assert_equal ["T1.yml"], Dir.children(root)
    end
  end

  # Fresh Ruby processes read old bytes during a partial temporary write and new bytes after rename.
  def test_cold_readers_at_controlled_publication_boundaries
    with_store do |store, root|
      previous = { "id" => "old", "payload" => "a" * 4096 }
      replacement = { "id" => "new", "payload" => "b" * 4096 }
      store.write("T1", previous)
      create = Tempfile.method(:create)
      Tempfile.stub(:create, lambda { |*args, **options, &block|
        create.call(*args, **options) do |temporary|
          write = temporary.method(:write)
          temporary.stub(:write, lambda { |bytes|
            midpoint = bytes.bytesize / 2
            write.call(bytes.byteslice(0, midpoint))
            temporary.flush
            assert_equal previous, cold_load(root)
            write.call(bytes.byteslice(midpoint, bytes.bytesize - midpoint))
            bytes.bytesize
          }) { block.call(temporary) }
        end
      }) do
        rename = File.method(:rename)
        File.stub(:rename, lambda { |source, destination|
          assert_equal previous, cold_load(root)
          result = rename.call(source, destination)
          assert_equal replacement, cold_load(root)
          result
        }) { store.write("T1", replacement) }
      end
      assert_equal replacement, cold_load(root)
      assert_equal ["T1.yml"], Dir.children(root)
    end
  end

  # New files follow the old umask semantics; replacements retain owner/group and Unix mode.
  def test_permissions_and_ownership
    with_store do |store, _root|
      old_umask = File.umask(0o027)
      begin
        assert_equal YAML.dump({ "id" => "old" }).bytesize, store.write("T1", { "id" => "old" })
        path = store.state_path("T1")
        assert_equal 0o640, File.stat(path).mode & 0o777
        File.chmod(0o600, path)
        before = File.stat(path)
        store.write("T1", { "id" => "new" })
        after = File.stat(path)
        assert_equal 0o600, after.mode & 0o777
        assert_equal [before.uid, before.gid], [after.uid, after.gid]
      ensure
        File.umask(old_umask)
      end
    end
  end

  # Existing symlinks, including dangling links, retain File.write's target semantics.
  def test_symlink_targets_are_replaced_without_removing_the_link
    with_store do |store, root|
      target = File.join(root, "target.yml")
      File.symlink("target.yml", store.state_path("T1"))
      2.times do |index|
        state = { "id" => "T1", "sequence" => index }
        store.write("T1", state)
        assert File.symlink?(store.state_path("T1"))
        assert_equal state, YAML.safe_load_file(target)
        assert_equal state, store.load("T1")
      end
    end
  end

  # A dangling existing state link is not a genuinely absent task state.
  def test_dangling_link_is_rejected_on_load
    with_store do |store, root|
      File.symlink("absent.yml", store.state_path("T1"))
      assert_raises(AgentCodingTool::InvalidState) { store.load("T1") }
      assert_equal ["T1.yml"], Dir.children(root)
    end
  end

  # Status and preparation fail closed on corrupt state before creating a new prompt or state.
  def test_corrupt_state_refuses_coordinator_and_cli_operations
    with_workspace do |root|
      write_task(root, id: "T1")
      coordinator = coordinator_for(root, "alpha" => "a" * 40)
      path = File.join(root, "state", "T1.yml")
      File.write(path, "")
      assert_raises(AgentCodingTool::InvalidState) { coordinator.status("T1") }
      assert_raises(AgentCodingTool::InvalidState) { coordinator.prepare("T1") }
      assert_raises(AgentCodingTool::InvalidState) { coordinator.start("T1") }
      [%w[status T1], %w[prepare T1], %w[start T1]].each do |command|
        out, err = StringIO.new, StringIO.new
        cli = AgentCodingTool::CLI.new(root: root, data_root: root, out: out, err: err)
        cli.instance_variable_set(:@coordinator, coordinator)
        assert_equal 2, cli.run(command)
        assert_includes err.string, "T1"
        refute_includes out.string, "READY"
      end
      assert_equal "", File.binread(path)
      assert_empty Dir.children(File.join(root, "state", "prompts"))
    end
  end

  private

  # Yields a store and its disposable root; removes all files even on test failure.
  def with_store
    Dir.mktmpdir("act-state-test-") { |root| yield AgentCodingTool::StateStore.new(root), root }
  end

  # Injects ENOSPC into one real temporary-file operation, with a partial write for :write.
  def fail_temporary_operation(operation)
    create = Tempfile.method(:create)
    Tempfile.stub(:create, lambda { |*args, **options, &block|
      create.call(*args, **options) do |temporary|
        original = temporary.method(operation)
        temporary.stub(operation, lambda { |*values|
          original.call(values.first.byteslice(0, 5)) if operation == :write
          raise Errno::ENOSPC, "synthetic #{operation} failure"
        }) { block.call(temporary) }
      end
    }) { yield }
  end

  # Loads state in an independent Ruby process; raises if the reader fails.
  def cold_load(root)
    script = 'require "json"; require "agent_coding_tool"; puts JSON.generate(AgentCodingTool::StateStore.new(ARGV.fetch(0)).load("T1"))'
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script, root)
    assert status.success?, error
    JSON.parse(output)
  end
end
