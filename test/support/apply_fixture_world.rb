# frozen_string_literal: true

require_relative 'memory_git/patch_capabilities'
# Narrow apply fixture observations, not a native hook or index-flags emulator.
# Mutable files/index/objects remain the existing world; only declared porcelain
# presentation and refusal inputs absent from that world are supplied here.
class ApplyFixtureWorld < MemoryGit::PatchWorld
  attr_accessor :index_refusal

  private

  # Formats actual model status rows using the existing byte-preserving quote
  # formatter. NUL output remains untouched; no rows or changed paths are omitted.
  def command_status(checkout, arguments, input, settings)
    arguments = [*arguments, '--untracked-files=all'] unless arguments.include?('--untracked-files=all')
    return super if arguments.include?('-z')
    response = super(checkout, [*arguments, '-z'], input, settings)
    rows = response.stdout.split("\0").map { |row| row.byteslice(0, 3) + quote_path(row.byteslice(3..)) }
    result(rows.empty? ? '' : rows.join("\n") + "\n")
  end

  # The one deliberately malformed hunk is a native-style refusal input, not
  # an unsupported test protocol. All other patch/model mismatches still escape.
  def command_apply(checkout, arguments, input, settings)
    if input.include?("@@ -0,0 +1,99 @@")
      return result('', "error: corrupt patch\n", 128)
    end
    return super if input.empty?
    unless arguments.include?('--numstat') || arguments.include?('--stat')
      record = patch_record(input, scan(checkout))
      occupied = record.paths.find { |path| !record.before.entries.key?(path) && File.exist?(File.join(checkout.path, path)) }
      return result('', "error: #{occupied}: already exists in working directory\n", 1) if occupied
    end
    super
  end

  # Supplies one explicit malformed/hidden combined index observation. Normal
  # stage reads still reflect the authoritative model index for preservation.
  def command_ls_files(checkout, arguments, input, settings)
    response = super
    expected = %w[--stage -v -z --cached --others --exclude-standard]
    return response unless index_refusal && arguments == expected
    rows = response.stdout.split("\0")
    rows.map! do |row|
      next row unless row.end_with?("\tfile.txt")
      case index_refusal
      when :unmerged then row.sub(" 0\t", " 1\t")
      when :assume then row.sub(/^H /, 'h ')
      when :skip then row.sub(/^H /, 'S ')
      else raise MemoryGit::Mismatch, 'unknown index refusal observation'
      end
    end
    result(rows.join("\0") + "\0")
  end
end
