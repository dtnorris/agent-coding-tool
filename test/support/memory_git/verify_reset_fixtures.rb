# frozen_string_literal: true

require_relative '../no_git_execution'
require_relative 'reset_fixtures'
require 'minitest/autorun'
require 'tmpdir'
Minitest::Assertions.diff = nil

# Independent physical corruption controls for every finite native store. These
# checks execute no Git; native preparation and reconstruction run outside tests.
class ResetFixtureVerifier < Minitest::Test
  # Materializes exact native files in a fresh private root and yields its path.
  def with_store(row)
    Dir.mktmpdir('reset-store-') do |directory|
      row.fetch('store').each do |path, encoded|
        target = File.join(directory, path)
        FileUtils.mkdir_p(File.dirname(target))
        File.binwrite(target, encoded.unpack1('m0'))
      end
      yield directory
    end
  end

  # Every native store must validate. Index, pack, idx, HEAD, configuration and
  # extra/missing/symlinked files independently invalidate the physical store.
  def test_native_stores_and_corruptions
    MemoryGit::ResetFixtures.data.fetch('states').each_value do |row|
      with_store(row) do |directory|
        assert_equal row, MemoryGit::ResetFixtures.verify_store(directory)
        row.fetch('store').each do |path, encoded|
          target = File.join(directory, path)
          File.binwrite(target, 'corrupt')
          assert_raises(MemoryGit::Mismatch) { MemoryGit::ResetFixtures.verify_store(directory) }
          File.binwrite(target, encoded.unpack1('m0'))
        end
        extra = File.join(directory, 'extra')
        File.write(extra, 'unexpected')
        assert_raises(MemoryGit::Mismatch) { MemoryGit::ResetFixtures.verify_store(directory) }
        File.unlink(extra)
        target = File.join(directory, 'index')
        File.rename(target, target + '.saved')
        File.symlink(target + '.saved', target)
        assert_raises(MemoryGit::Mismatch) { MemoryGit::ResetFixtures.verify_store(directory) }
      end
    end
  end

  # Pack verification is independent of the golden hash: native trailers,
  # compression, object framing, complete consumption and graph closure matter.
  def test_native_pack_parser_controls
    MemoryGit::ResetFixtures.data.fetch('states').each_value do |row|
      pack = [row.fetch('pack_hex')].pack('H*')
      objects = MemoryGit::ResetFixtures.pack_objects(pack)
      assert_equal 'commit', objects.fetch(row.fetch('head')).first
      assert_raises(MemoryGit::Mismatch) { MemoryGit::ResetFixtures.pack_objects(pack[0...-1]) }
      corrupt = pack.dup
      corrupt.setbyte(12, 0x70) # unsupported delta object, with valid pack checksum
      corrupt[-20, 20] = Digest::SHA1.digest(corrupt[0...-20])
      assert_raises(MemoryGit::Mismatch) { MemoryGit::ResetFixtures.pack_objects(corrupt) }
    end
  end
end
