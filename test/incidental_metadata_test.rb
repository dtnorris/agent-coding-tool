# frozen_string_literal: true

require_relative "test_helper"

# Filesystem policy and raw Git record controls without external processes.
class IncidentalMetadataTest < Minitest::Test
  # Exact basenames, type and readable ancestry determine discovery; none of
  # these observations removes, rewrites or follows a metadata entry.
  def test_only_exact_regular_metadata_is_incidental
    Dir.mktmpdir("metadata-") do |directory|
      root = File.realpath(directory)
      path = File.join(root, ".DS_Store")
      bytes = "Finder\x00\xff".b
      File.binwrite(path, bytes)
      assert AgentCodingTool::IncidentalMetadata.file?(path)
      assert_empty AgentCodingTool::IncidentalMetadata.children(root)
      assert_equal bytes, File.binread(path)
      %w[.ds_store .DS_Store.old prefix.DS_Store .other].each do |name|
        File.write(File.join(root, name), "substantive")
        refute AgentCodingTool::IncidentalMetadata.file?(File.join(root, name))
      end
      File.unlink(path)
      Dir.mkdir(path)
      refute AgentCodingTool::IncidentalMetadata.file?(path)
      Dir.rmdir(path)
      [File.join(root, ".other"), File.join(root, "absent")].each do |target|
        File.symlink(target, path)
        refute AgentCodingTool::IncidentalMetadata.file?(path)
        assert_includes AgentCodingTool::IncidentalMetadata.children(root), ".DS_Store"
        File.unlink(path)
      end
      File.mkfifo(path)
      refute AgentCodingTool::IncidentalMetadata.file?(path)
      File.unlink(path)
      assert_raises(Errno::ENOENT) { AgentCodingTool::IncidentalMetadata.file?(path) }
      File.binwrite(path, bytes)
      alias_root = File.join(root, "alias")
      File.symlink(root, alias_root)
      assert_raises(AgentCodingTool::InvalidState) { AgentCodingTool::IncidentalMetadata.file?(File.join(alias_root, ".DS_Store")) }
    end
  end

  # NUL records preserve spaces/control bytes and rename sources. Tracked and
  # staged metadata always remain; missing Git evidence is never a clear result.
  def test_status_filters_only_proven_untracked_metadata
    Dir.mktmpdir("metadata-") do |directory|
      root = File.realpath(directory)
      relative = "nested [space]\ncontrol\t/.DS_Store"
      FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
      File.binwrite(File.join(root, relative), "metadata")
      reads = []
      git = lambda do |*args|
        reads << args
        "".b
      end
      substantive = " M changed space\nfile\0R  renamed\0original\nname\0M  .DS_Store\0".b
      status = "?? #{relative}\0!! #{relative}\0".b + substantive
      assert_equal substantive, AgentCodingTool::IncidentalMetadata.status(root, status, &git)
      assert_equal 4, reads.length
      assert_equal ["--literal-pathspecs", "ls-files", "--cached", "-z", "--", relative], reads.first
      tracked = ->(*_args) { "#{relative}\0" }
      assert_equal status, AgentCodingTool::IncidentalMetadata.status(root, status, &tracked)
      head_tracked = ->(*args) { args.include?("ls-tree") ? "#{relative}\0" : "" }
      assert_equal status, AgentCodingTool::IncidentalMetadata.status(root, status, &head_tracked)
      assert_raises(AgentCodingTool::RepositoryError) do
        AgentCodingTool::IncidentalMetadata.status(root, status) { |*_args| raise AgentCodingTool::RepositoryError, "unreadable index" }
      end
      assert_raises(AgentCodingTool::InvalidState) { AgentCodingTool::IncidentalMetadata.status(root, "?? text\n", &git) }
      assert_raises(AgentCodingTool::InvalidState) { AgentCodingTool::IncidentalMetadata.status(root, "R  destination\0", &git) }
    end
  end

  # New hashes ignore incidental churn, while old recorded metadata hashes and
  # explicitly named artifacts retain their original byte-integrity checks.
  def test_closeout_hash_compatibility_and_explicit_evidence
    Dir.mktmpdir("metadata-") do |directory|
      root = File.realpath(directory)
      File.write(File.join(root, "handoff.json"), "substantive")
      path = File.join(root, ".DS_Store")
      File.binwrite(path, "old Finder bytes")
      recovery = AgentCodingTool::AttemptRecovery.allocate
      substantive = recovery.send(:evidence_hashes, root)
      refute substantive.key?(".DS_Store")
      historical = recovery.send(:evidence_hashes, root, include_metadata: true)
      assert_equal Digest::SHA256.hexdigest("old Finder bytes"), historical.fetch(".DS_Store")
      assert_equal "old Finder bytes", recovery.send(:checked_file, path)
      File.binwrite(path, "new Finder bytes")
      assert_equal substantive, recovery.send(:evidence_hashes, root)
      refute_equal historical, recovery.send(:evidence_hashes, root, include_metadata: true)
      File.unlink(path)
      assert_equal substantive, recovery.send(:evidence_hashes, root)
      assert_raises(AgentCodingTool::InvalidState) { recovery.send(:checked_file, path) }
      File.symlink(File.join(root, "handoff.json"), path)
      assert_raises(AgentCodingTool::InvalidState) { recovery.send(:evidence_hashes, root) }
    end
  end
end
