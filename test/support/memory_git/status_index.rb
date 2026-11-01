# frozen_string_literal: true

module MemoryGit
  class World
    private

    # Returns whether an untracked path matches the finite ignore rules. Supports
    # ordinary glob/directory patterns; negated/rich Git ignore syntax refuses.
    def ignored?(checkout, path, settings = {})
      patterns = checkout.ignored.dup
      excludes = settings["core.excludesFile"] || checkout.repository.config["core.excludesFile"]
      patterns.concat(File.binread(excludes).lines.map(&:chomp)) if excludes && File.file?(excludes)
      ignore = File.join(checkout.path, ".gitignore")
      patterns.concat(File.binread(ignore).lines.map(&:chomp)) if File.file?(ignore) && !File.symlink?(ignore)
      patterns.any? do |pattern|
        next false if pattern.empty? || pattern.start_with?("#")
        raise Mismatch, "unsupported ignore pattern" if pattern.start_with?("!") || pattern.include?("\\")
        clean = pattern.delete_prefix("/").delete_suffix("/")
        candidates = pattern.include?("/") ? [path] : path.split("/")
        candidates.any? { |candidate| File.fnmatch?(clean, candidate, File::FNM_DOTMATCH) } ||
          (pattern.end_with?("/") && path.start_with?(clean + "/"))
      end
    end

    # Returns A/D/M/type-change/space by independent entry comparison.
    def change(before, after)
      return " " if before == after
      return "A" unless before
      return "D" unless after
      before.mode == "120000" || after.mode == "120000" ? (before.mode == after.mode ? "M" : "T") : "M"
    end

    # Emits porcelain v1 NUL paths verbatim. Renames are deliberately represented
    # as add/delete; no heuristic pairing or quoting contaminates raw -z framing.
    def command_status(checkout, arguments, input, settings)
      no_input!(input)
      allowed = %w[--porcelain=v1 --porcelain --short -z --untracked-files=all --ignored --ignore-submodules=none]
      raise Mismatch, "unsupported status options" unless (arguments - allowed).empty? && arguments.uniq == arguments &&
        arguments.count { |argument| %w[--porcelain=v1 --porcelain --short].include?(argument) } == 1 && arguments.include?("--untracked-files=all")
      physical, committed = scan(checkout), checkout.tree.entries
      paths = (committed.keys + checkout.index.keys + physical.keys).uniq.sort
      rows = paths.flat_map do |path|
        staged = change(committed[path], checkout.index[path])
        unstaged = change(checkout.index[path], physical[path])
        if !checkout.index.key?(path) && !committed.key?(path)
          next [] if ignored?(checkout, path, settings) && !arguments.include?("--ignored")
          code = ignored?(checkout, path, settings) ? "!!" : "??"
        else
          next [] if staged == " " && unstaged == " "
          # A deleted staged path with a new physical file is a separate untracked
          # row in Git; preserve both observations rather than call it a re-add.
          if !checkout.index.key?(path) && physical.key?(path)
            untracked = ignored?(checkout, path, settings) ? (arguments.include?("--ignored") ? "!!" : nil) : "??"
            next ["#{staged}  #{path}".b, ("#{untracked} #{path}".b if untracked)].compact
          end
          code = staged + unstaged
        end
        ["#{code} #{path}".b]
      end
      if arguments.include?("-z")
        result(rows.empty? ? "" : rows.join("\0") + "\0")
      else
        raise Mismatch, "text status cannot quote odd paths" if paths.any? { |path| path.match?(/[\x00-\x20\x7f-\xff"\\]/n) }
        result(rows.empty? ? "" : rows.join("\n") + "\n")
      end
    end

    # Selects exact paths or descendants. Literal pathspecs only; no shell globbing.
    def select_paths(paths, selections)
      return paths.sort if selections.empty?
      selections.each { |path| Tree.path!(path) }
      paths.select { |path| selections.any? { |selection| path == selection.b || path.start_with?(selection.b + "/") } }.sort
    end

    # Separates a literal -- path list; returns option/revision prefix and paths.
    def split_paths(arguments)
      position = arguments.index("--")
      position ? [arguments.first(position), arguments.drop(position + 1)] : [arguments, []]
    end

    # Inventories stage entries or untracked/ignored files with raw NUL framing.
    # Unknown flag combinations refuse rather than silently omitting entries.
    def command_ls_files(checkout, arguments, input, settings)
      no_input!(input)
      flags, selections = split_paths(arguments)
      allowed = %w[--stage -v -z --cached --others --exclude-standard --ignored]
      raise Mismatch, "unsupported ls-files options" unless (flags - allowed).empty? && flags.uniq == flags
      raise Mismatch, "ignored requires others/exclude-standard" if flags.include?("--ignored") &&
        !%w[--others --exclude-standard].all? { |flag| flags.include?(flag) }
      other = flags.include?("--others")
      stage = flags.include?("--stage")
      paths = other && !flags.include?("--cached") ? [] : checkout.index.keys
      if other
        paths += (scan(checkout).keys - checkout.index.keys).select do |path|
          ignored = ignored?(checkout, path, settings)
          flags.include?("--ignored") ? ignored : !flags.include?("--exclude-standard") || !ignored
        end
      end
      ending = flags.include?("-z") ? "\0" : "\n"
      rows = select_paths(paths.uniq, selections).map do |path|
        entry = checkout.index[path]
        prefix = stage && entry ? "#{entry.mode} #{entry.blob.oid} 0\t" : ""
        prefix = (entry ? "H " : "? ") + prefix if flags.include?("-v")
        prefix.b + path + ending
      end
      result(rows.join)
    end

    # Reads committed tree modes/blob IDs/names; supports only audited flat output.
    def command_ls_tree(checkout, arguments, input, _settings)
      no_input!(input)
      prefix, selections = split_paths(arguments)
      flags = prefix.take_while { |argument| argument.start_with?("-") }
      revisions = prefix.drop(flags.length)
      raise Mismatch, "unsupported ls-tree" unless (flags - %w[-r --name-only -z]).empty? && flags.uniq == flags && revisions.length == 1
      object = resolve(checkout, revisions.first)
      tree = object.is_a?(Commit) ? object.tree : object
      raise Refusal, "not a tree" unless tree.is_a?(Tree)
      if !flags.include?("-r") && selections.empty? && tree.entries.keys.any? { |path| path.include?("/") }
        raise Mismatch, "nonrecursive directory tree output is outside the audited capability"
      end
      ending = flags.include?("-z") ? "\0" : "\n"
      rows = select_paths(tree.entries.keys, selections).map do |path|
        entry = tree.entries.fetch(path)
        prefix = flags.include?("--name-only") ? "" : "#{entry.mode} blob #{entry.blob.oid}\t"
        prefix.b + path + ending
      end
      result(rows.join)
    end

    # Checks one literal ignored untracked path; tracked files are never ignored.
    def command_check_ignore(checkout, arguments, input, settings)
      no_input!(input)
      raise Mismatch, "unsupported check-ignore" unless arguments[0, 2] == ["--quiet", "--"] && arguments.length == 3
      path = Tree.path!(arguments.last)
      result("", "", !checkout.index.key?(path) && ignored?(checkout, path, settings) ? 0 : 1)
    end

    # Stages physical bytes/modes/deletions independently of HEAD. Only observed
    # add and add -A forms are supported; transition/intent forms belong to TST-36.
    def command_add(checkout, arguments, input, settings)
      no_input!(input)
      flags, selections = split_paths(arguments)
      exact!(flags, [], ["-A"])
      raise Mismatch, "add needs explicit paths" if selections.empty?
      physical = scan(checkout)
      paths = selections == ["."] ? (physical.keys + checkout.index.keys).uniq.sort :
        select_paths((physical.keys + checkout.index.keys).uniq, selections)
      raise Refusal, "pathspec did not match any files" if paths.empty?
      paths.each do |path|
        raise Refusal, "ignored path #{path}" if physical.key?(path) && !checkout.index.key?(path) && ignored?(checkout, path, settings) && selections != ["."]
      end
      effect!(:stage) do
        paths.each do |path|
          next if !checkout.index.key?(path) && ignored?(checkout, path, settings)
          physical.key?(path) ? checkout.index[path] = physical.fetch(path) : checkout.index.delete(path)
          checkout.repository.store(physical.fetch(path).blob) if physical.key?(path)
        end
      end
      result
    end

    # Stores the independent index tree; does not advance HEAD or alter files.
    def command_write_tree(checkout, arguments, input, _settings)
      no_input!(input)
      exact!(arguments, [])
      tree = Tree.new(checkout.index)
      effect!(:write_tree) { checkout.repository.store(tree) }
      result(tree.oid + "\n")
    end

    # Commits the index or explicit --only physical paths while retaining unrelated
    # staged entries. Hooks/races are scheduled effects, never shell execution.
    def command_commit(checkout, arguments, input, _settings)
      no_input!(input)
      prefix, paths = split_paths(arguments)
      only = prefix.first == "--only"
      prefix = prefix.drop(1) if only
      messages = []
      until prefix.empty?
        raise Mismatch, "unsupported commit options" unless prefix.shift == "-m" && !prefix.empty?
        messages << prefix.shift
      end
      raise Mismatch, "commit needs message and explicit only paths" if messages.empty? || (only && paths.empty?) || (!only && !paths.empty?)
      entries = checkout.index.dup
      if only
        entries = checkout.tree.entries.dup
        physical = scan(checkout)
        selected = select_paths((physical.keys + entries.keys + checkout.index.keys).uniq, paths)
        raise Refusal, "pathspec did not match" if selected.empty?
        selected.each { |path| physical.key?(path) ? entries[path] = physical.fetch(path) : entries.delete(path) }
      end
      tree = Tree.new(entries)
      raise Refusal.new("nothing to commit", 1) if checkout.head && tree.oid == checkout.tree.oid
      commit = Commit.new(tree: tree, parents: [checkout.head].compact, message: messages.join("\n\n") + "\n")
      effect!(:commit) do
        checkout.repository.store(commit)
        checkout.move_head!(commit.oid)
        if only
          select_paths((checkout.index.keys + entries.keys).uniq, paths).each do |path|
            entries.key?(path) ? checkout.index[path] = entries.fetch(path) : checkout.index.delete(path)
          end
        end
      end
      result("[memory #{commit.oid[0, 7]}] #{messages.first}\n")
    end
  end
end
