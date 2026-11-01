# frozen_string_literal: true

module MemoryGit
  # Scratch contexts retain the ordinary checkout identity/HEAD but own their
  # index and object writes. Ref/config authority remains shared and read-only.
  module ScratchContexts
    private

    # Accepts only the complete Checkpoint scratch envelope plus base settings.
    # Paths are validated against the actual checkout before a context is used.
    def supported_environment?(environment)
      return super unless environment.is_a?(Hash) && environment.key?("GIT_INDEX_FILE")
      scratch = %w[GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES]
      scratch.all? { |key| environment[key].is_a?(String) && !environment[key].include?("\0") } &&
        super(environment.reject { |key, _value| scratch.include?(key) })
    end

    # Returns a persistent scratch index/object view for one exact owned envelope.
    # No files are written by context selection. Unsafe/foreign paths raise Mismatch.
    def checkout_for_command(checkout, environment)
      return super unless environment.key?("GIT_INDEX_FILE")
      index, objects, alternate = environment.values_at("GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES")
      [index, objects].each do |path|
        raise Mismatch, "noncanonical scratch path" unless File.expand_path(path) == path
        owned_path!(path)
      end
      raise Mismatch, "unsafe scratch index/objects" unless File.directory?(objects) && !File.symlink?(objects) &&
        File.realpath(objects) == objects && File.directory?(File.dirname(index)) && File.realpath(File.dirname(index)) == File.dirname(index) &&
        !File.exist?(index) && !File.symlink?(index) && alternate == File.join(checkout.repository.common, "objects")
      @scratch_contexts ||= {}
      key = [checkout.admin, index, objects]
      context = @scratch_contexts[key] ||= begin
        authority = Repository.new(common: checkout.repository.common, template: Template.new(commits: []))
        authority.objects.merge!(checkout.repository.objects)
        authority.refs.merge!(checkout.repository.refs)
        authority.config.merge!(checkout.repository.config)
        authority.remotes.merge!(checkout.repository.remotes)
        view = Checkout.new(path: checkout.path, repository: authority, admin: checkout.admin,
          head_ref: checkout.head_ref, detached: checkout.detached)
        view.index.clear
        view.ignored.replace(checkout.ignored)
        view
      end
      context.repository.objects.merge!(checkout.repository.objects)
      context
    end

    # Supports Checkpoint's all-path/forced add forms while retaining core staging
    # for ordinary requests. Intent-to-add is a bounded Publisher capability.
    def command_add(checkout, arguments, input, settings)
      return super(checkout, ["-A", "--", "."], input, settings) if arguments == ["-A"]
      return super unless %w[-f -N].include?(arguments.first)
      no_input!(input)
      flags, paths = split_paths(arguments)
      exact!(flags, ["-f"], ["-N"])
      raise Mismatch, "explicit add paths required" if paths.empty?
      physical = scan(checkout)
      paths.each do |path|
        Tree.path!(path)
        raise Refusal, "path missing" unless physical.key?(path)
        raise Refusal, "ignored path" if flags == ["-N"] && ignored?(checkout, path, settings)
      end
      effect!(:stage) do
        paths.each do |path|
          next if flags == ["-N"] && checkout.index.key?(path)
          entry = flags == ["-N"] ? Entry.new("", mode: physical.fetch(path).mode) : physical.fetch(path)
          checkout.index[path] = entry
          checkout.repository.store(entry.blob)
          @intent_entries ||= {}.compare_by_identity
          (@intent_entries[checkout.index] ||= {})[path] = entry if flags == ["-N"]
        end
      end
      result
    end
  end

  PatchWorld.prepend(ScratchContexts)

  class PatchWorld
    private

    # Loads one immutable commit/tree into the selected index without changing
    # working files or HEAD. Unknown forms raise Mismatch, missing objects refuse.
    def command_read_tree(checkout, arguments, input, _settings)
      no_input!(input)
      raise Mismatch, "read-tree requires one tree" unless arguments.length == 1 && !arguments.first.start_with?("-")
      tree = revision_tree(checkout, arguments.first)
      effect!(:read_tree) { checkout.index.replace(tree.entries) }
      result
    end

    # Removes explicit index entries; no physical content or HEAD changes.
    def command_update_index(checkout, arguments, input, _settings)
      no_input!(input)
      raise Mismatch, "unsupported update-index" unless arguments.first(2) == ["--force-remove", "--"] && arguments.length > 2
      paths = arguments.drop(2).map { |path| Tree.path!(path) }
      effect!(:update_index) { paths.each { |path| checkout.index.delete(path) } }
      result
    end

    # Hashes exact stdin bytes with optional local object storage; never imports
    # remote existence or advances refs. Unsupported input modes raise Mismatch.
    def command_hash_object(checkout, arguments, input, _settings)
      exact!(arguments, ["--stdin"], ["-w", "--stdin"])
      blob = Blob.new(input)
      effect!(:hash_object) { checkout.repository.store(blob) } if arguments.include?("-w")
      result(blob.oid + "\n")
    end

    # Restores explicitly selected HEAD index entries for Publisher intent cleanup;
    # does not remove or alter any physical files or move HEAD.
    def command_reset(checkout, arguments, input, _settings)
      no_input!(input)
      flags, paths = split_paths(arguments)
      exact!(flags, ["-q"])
      raise Mismatch, "reset requires explicit paths" if paths.empty?
      paths.each { |path| Tree.path!(path) }
      effect!(:reset_index) do
        paths.each do |path|
          entry = checkout.tree.entries[path]
          entry ? checkout.index[path] = entry : checkout.index.delete(path)
        end
      end
      result
    end

    # Resolves a tree/commit without changing local object storage; missing object
    # or a blob revision refuses, malformed syntax raises Mismatch.
    def revision_tree(checkout, revision)
      object = resolve(checkout, revision)
      tree = object.is_a?(Commit) ? object.tree : object
      raise Refusal, "not a tree" unless tree.is_a?(Tree)
      tree
    end

    # Compares HEAD/index/worktree or explicit immutable trees. NUL inventory,
    # quiet status, whitespace check and patch modes preserve distinct semantics.
    def command_diff(checkout, arguments, input, _settings)
      no_input!(input)
      prefix, paths = split_paths(arguments)
      flags, revisions = prefix.partition { |argument| argument.start_with?("-") }
      allowed = %w[--cached --quiet --name-only --name-status -z --no-renames --binary --full-index --no-ext-diff --no-textconv --check]
      raise Mismatch, "unsupported diff" unless (flags - allowed).empty? && flags.uniq == flags && revisions.length <= 2 &&
        (flags & %w[--quiet --name-only --name-status --check]).length <= 1 &&
        (!flags.include?("-z") || (flags & %w[--name-only --name-status]).any?) && !(flags.include?("--cached") && revisions.length > 1)
      before = revisions.empty? ? (flags.include?("--cached") ? checkout.tree.entries : checkout.index) : revision_tree(checkout, revisions.first).entries
      after = revisions.length == 2 ? revision_tree(checkout, revisions.last).entries : flags.include?("--cached") ? checkout.index : scan(checkout)
      # Worktree diff omits genuinely untracked files; explicit tree comparisons
      # also require intent-to-add before an untracked file can contribute.
      after = after.slice(*(before.keys | checkout.index.keys)) unless flags.include?("--cached") || revisions.length == 2
      # Intent belongs to the exact placeholder entry, not its path or empty
      # bytes. Replacing/removing that entry ends intent; a skipped effect keeps
      # it. Identity-keyed indexes also keep ordinary/scratch state independent.
      intentions = (@intent_entries || {}).fetch(checkout.index, {}).filter_map do |path, entry|
        path if checkout.index[path].equal?(entry)
      end
      if revisions.length < 2
        flags.include?("--cached") ? after = after.reject { |path, _entry| intentions.include?(path) } :
          before = before.reject { |path, _entry| intentions.include?(path) }
      end
      selected = select_paths(before.keys | after.keys, paths)
      before, after = before.slice(*selected), after.slice(*selected)
      changed = selected.select { |path| before[path] != after[path] }
      return result("", "", changed.empty? ? 0 : 1) if flags.include?("--quiet")
      if flags.include?("--check")
        bad = changed.select do |path|
          after[path] && before[path]&.blob&.bytes != after[path].blob.bytes &&
            after[path].blob.bytes.lines.any? { |line| line.match?(/[ \t]+\n\z/n) }
        end
        return result(bad.map { |path| "#{quote_path(path)}: trailing whitespace\n" }.join, "", bad.empty? ? 0 : 2)
      end
      if (flags & %w[--name-only --name-status]).any?
        separator = flags.include?("-z") ? "\0" : "\n"
        return result(changed.map do |path|
          name = flags.include?("-z") ? path : quote_path(path)
          code = change(before[path], after[path])
          flags.include?("--name-status") ? code + (flags.include?("-z") ? "\0" : "\t") + name + separator : name + separator
        end.join)
      end
      result(patch_bytes(before, after, full: flags.include?("--full-index")))
    end

    # Reads one commit's parent/tree name inventory. Empty-root commits compare
    # with an empty tree; unknown formatting options fail closed.
    def command_diff_tree(checkout, arguments, input, _settings)
      no_input!(input)
      raise Mismatch, "unsupported diff-tree" unless arguments.first(4) == %w[--no-commit-id --name-only -r -z] && arguments.length == 5
      commit = resolve(checkout, arguments.last)
      raise Refusal, "not a commit" unless commit.is_a?(Commit)
      parent = commit.parents.empty? ? {} : revision_tree(checkout, commit.parents.first).entries
      paths = (parent.keys | commit.tree.entries.keys).select { |path| parent[path] != commit.tree.entries[path] }.sort
      result(paths.empty? ? "" : paths.join("\0") + "\0")
    end
  end
end
