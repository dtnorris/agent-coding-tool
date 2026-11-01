# frozen_string_literal: true

require_relative "patch_case"

module MemoryGit
  # Opt-in patch/index/tree world; core-only consumers retain their finite surface.
  class PatchWorld < World
    # Registers reviewed bytes/trees without changing repository state. Conflicting
    # registrations raise Mismatch; returns the immutable PatchCase.
    def register_patch(record)
      raise Mismatch, "expected PatchCase" unless record.is_a?(PatchCase)
      @patch_cases ||= []
      existing = @patch_cases.find { |item| item.bytes == record.bytes }
      raise Mismatch, "ambiguous patch record" if existing &&
        [existing.before.oid, existing.after.oid] != [record.before.oid, record.after.oid]
      unless existing
        @patch_cases << record
        record.fragments.each { |fragment| register_patch(fragment) }
      end
      record
    end

    private

    # Selects exact reviewed bytes; unknown binary inputs never acquire a tree by
    # similarity. Ordinary text uses the separately bounded whole-file codec.
    def patch_record(bytes, preimage)
      known = (@patch_cases || []).find { |item| item.bytes == bytes }
      return known if known
      sections = bytes.split(/(?=^diff --git )/n).reject(&:empty?)
      if sections.length > 1
        records = sections.map { |section| patch_record(section, preimage) }
        paths = records.flat_map(&:paths)
        raise Mismatch, "overlapping composed patch paths" unless paths.uniq == paths
        return PatchCase.new(bytes: bytes, sha256: Digest::SHA256.hexdigest(bytes),
          before: records.map { |record| record.before.entries }.reduce({}, :merge),
          after: records.map { |record| record.after.entries }.reduce({}, :merge), paths: paths,
          numstat: records.map(&:numstat).join, stat: records.map(&:stat).join)
      end
      raise Mismatch, "unknown binary patch bytes" if bytes.include?("GIT binary patch") || bytes.include?("\0")
      parse_text_patch(bytes, preimage)
    end

    # Checks/previews/applies stdin or one owned artifact. Checks validate every
    # precondition before effects and never store objects, stage or touch files.
    # Unsupported flags/bytes raise Mismatch; preimage failures return nonzero.
    def command_apply(checkout, arguments, input, _settings)
      flags = arguments.take_while { |argument| argument.start_with?("-") }
      files = arguments.drop(flags.length)
      allowed = %w[--check --binary --numstat --stat -z --cached --index]
      raise Mismatch, "unsupported apply request" unless (flags - allowed).empty? && flags.uniq == flags && files.length <= 1 &&
        (flags & %w[--check --numstat --stat]).length <= 1 && (flags & %w[--cached --index]).length <= 1 &&
        (!flags.include?("-z") || flags.include?("--numstat"))
      if files.any?
        no_input!(input)
        path = files.first
        raise Mismatch, "unsafe patch artifact" unless File.absolute_path(path) == path && path.start_with?(root + "/") &&
          File.file?(path) && !File.symlink?(path) && File.realpath(path) == path
        input = File.binread(path)
      end
      physical = scan(checkout)
      record = patch_record(input, flags.include?("--cached") ? checkout.index : physical)
      return result(flags.include?("-z") ? record.numstat : text_numstat(record)) if flags.include?("--numstat")
      return result(record.stat) if flags.include?("--stat")
      states = flags.include?("--cached") ? [checkout.index] : flags.include?("--index") ? [checkout.index, physical] : [physical]
      states.each do |entries|
        raise Refusal, "patch preimage differs" unless record.paths.all? { |path| entries[path] == record.before.entries[path] }
      end
      record.paths.each do |path|
        target = safe_file!(checkout, path)
        raise Refusal, "symlink patch path" if File.symlink?(target)
        raise Refusal, "unsafe patch entry" if File.exist?(target) && (!File.file?(target) || File.stat(target).nlink != 1)
        raise Refusal, "symlink patch mode" if record.after.entries[path]&.mode == "120000"
      end
      return result if flags.include?("--check")
      effect!(:apply) do
        record.paths.each do |path|
          effect!("patch:#{path}") do
            after = record.after.entries[path]
            materialize!(checkout, record.before.entries.slice(path), record.after.entries.slice(path)) unless flags.include?("--cached")
            if flags.include?("--cached") || flags.include?("--index")
              after ? checkout.index[path] = after : checkout.index.delete(path)
              checkout.repository.store(after.blob) if after
            end
          end
        end
      end
      result
    end

    # Formats ordinary-path rows; rename text statistics require a reviewed variant.
    def text_numstat(record)
      record.numstat.split("\0").map do |row|
        added, deleted, path = row.split("\t", 3)
        raise Mismatch, "text rename numstat unsupported" if path.nil? || path.empty?
        "#{added}\t#{deleted}\t#{quote_path(path)}\n".b
      end.join
    end

    # Quotes control/high bytes in C-style octal spelling. NUL-framed inventories
    # bypass this formatter and retain original path bytes.
    def quote_path(path)
      return path if path.match?(/\A[\x21\x23-\x5b\x5d-\x7e]+\z/n)
      '"' + path.bytes.map do |byte|
        { 9 => '\\t', 10 => '\\n', 13 => '\\r', 34 => '\\"', 92 => '\\\\' }[byte] ||
          ((32..126).cover?(byte) ? byte.chr : format('\\%03o', byte))
      end.join + '"'
    end

    # Emits a registered exact tree transition or bounded ordinary whole-file text
    # diff. Unregistered binary or quoted-path transitions raise Mismatch.
    def patch_bytes(before, after, full: false)
      paths = (before.keys | after.keys).select { |path| before[path] != after[path] }.sort
      return "".b if paths.empty?
      known = (@patch_cases || []).find do |item|
        item.paths == paths && item.before.entries == before.slice(*paths) && item.after.entries == after.slice(*paths)
      end
      return known.bytes if known
      remaining, chunks = paths.dup, []
      until remaining.empty?
        fragment = (@patch_cases || []).find do |item|
          item.paths.first == remaining.first && (item.paths - remaining).empty? &&
            item.before.entries == before.slice(*item.paths) && item.after.entries == after.slice(*item.paths)
        end
        if fragment
          chunks << fragment.bytes
          remaining -= fragment.paths
        else
          path = remaining.shift
          chunks << text_diff(path, before[path], after[path], full: full)
        end
      end
      chunks.join.b
    end

    # Produces one whole-file unified hunk; no binary codec, fuzzy application,
    # rename heuristic, whitespace repair or rich path parser exists.
    def text_diff(path, before, after, full:)
      raise Mismatch, "unregistered binary or quoted-path diff" unless path.match?(/\A[A-Za-z0-9_.\/-]+\z/n) &&
        [before, after].compact.all? { |entry| %w[100644 100755].include?(entry.mode) && !entry.blob.bytes.include?("\0") && entry.blob.bytes.ascii_only? }
      old_bytes, new_bytes = before&.blob&.bytes || "".b, after&.blob&.bytes || "".b
      header = "diff --git a/#{path} b/#{path}\n".b
      header << "new file mode #{after.mode}\n" unless before
      header << "deleted file mode #{before.mode}\n" unless after
      header << "old mode #{before.mode}\nnew mode #{after.mode}\n" if before && after && before.mode != after.mode
      return header if before && after && old_bytes == new_bytes
      width = full ? 40 : 7
      header << "index #{(before&.blob&.oid || '0' * 40)[0, width]}..#{(after&.blob&.oid || '0' * 40)[0, width]}"
      header << " #{before.mode}" if before && after && before.mode == after.mode
      header << "\n"
      old_lines, new_lines = old_bytes.lines, new_bytes.lines
      return header if old_lines.empty? && new_lines.empty?
      header << "--- #{before ? "a/#{path}" : '/dev/null'}\n+++ #{after ? "b/#{path}" : '/dev/null'}\n"
      header << "@@ -#{hunk_range(old_lines.length)} +#{hunk_range(new_lines.length)} @@\n"
      [["-", old_lines], ["+", new_lines]].each do |prefix, lines|
        lines.each do |line|
          header << prefix << line
          header << "\n\\ No newline at end of file\n" unless line.end_with?("\n")
        end
      end
      header
    end

    # Returns the coordinate of a whole-file hunk, omitting Git's count one.
    def hunk_range(count) = count.zero? ? "0,0" : count == 1 ? "1" : "1,#{count}"

    # Accepts only byte-exact ordinary codec output against physical preimages.
    # Modified hashes/counts/context refuse, without any binary fallback.
    def parse_text_patch(bytes, preimage)
      raise Mismatch, "unsupported text patch" unless bytes.start_with?("diff --git ")
      before, after, paths, stats = {}, {}, [], []
      bytes.split(/(?=^diff --git )/n).reject(&:empty?).each do |section|
        match = /\Adiff --git a\/([A-Za-z0-9_.\/-]+) b\/\1\n/n.match(section)
        raise Mismatch, "unsupported text path/rename" unless match
        path = Tree.path!(match[1])
        raise Mismatch, "duplicate text patch path" if paths.include?(path)
        paths << path
        original = preimage[path]
        before[path] = original if original
        mode = section[/^(?:new file mode|new mode) (100644|100755)$/, 1] || original&.mode || "100644"
        content = "".b
        if section.include?("\n@@ ")
          previous = nil
          section.split(/^@@ .* @@\n/n, 2).last.lines.each do |line|
            if line == "\\ No newline at end of file\n"
              content.delete_suffix!("\n") if previous == "+"
            elsif line.start_with?("+")
              content << line.byteslice(1..)
              previous = "+"
            elsif line.start_with?("-")
              previous = "-"
            else
              raise Mismatch, "only whole-file text hunks supported"
            end
          end
        else
          content = original&.blob&.bytes || "".b
        end
        after[path] = Entry.new(content, mode: mode) unless section.match?(/^deleted file mode /)
        full = section.match?(/^index [0-9a-f]{40}\.\./)
        expected = text_diff(path, original, after[path], full: full)
        # Existing apply fixtures hand-author new-file hunks without an index
        # header. Only that exact whole-file spelling is additionally accepted.
        expected = expected.sub(/^index [^\n]*\n/n, "") if !original && !section.match?(/^index /)
        raise Mismatch, "text patch bytes/hash/base mismatch" unless expected == section
        same_bytes = original && after[path] && original.blob.bytes == after[path].blob.bytes
        added = same_bytes ? 0 : after[path]&.blob&.bytes&.lines&.length || 0
        deleted = same_bytes ? 0 : original&.blob&.bytes&.lines&.length || 0
        stats << "#{added}\t#{deleted}\t#{path}\0"
      end
      rows = stats.map do |row|
        added, deleted, path = row.delete_suffix("\0").split("\t", 3)
        " #{path} | #{added.to_i + deleted.to_i} #{'+' * added.to_i}#{'-' * deleted.to_i}\n".rstrip + "\n"
      end.join
      added, deleted = stats.map { |row| row.split("\t", 3).first(2).map(&:to_i) }.transpose.map(&:sum)
      summary = " #{paths.length} #{paths.length == 1 ? 'file' : 'files'} changed"
      summary << ", #{added} #{added == 1 ? 'insertion' : 'insertions'}(+)" if added.positive?
      summary << ", #{deleted} #{deleted == 1 ? 'deletion' : 'deletions'}(-)" if deleted.positive?
      PatchCase.new(bytes: bytes, sha256: Digest::SHA256.hexdigest(bytes), before: before, after: after, paths: paths,
        numstat: stats.join, stat: rows + summary + "\n")
    end
  end
end
