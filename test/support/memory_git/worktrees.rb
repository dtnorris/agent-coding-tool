# frozen_string_literal: true

module MemoryGit
  class World
    private

    # Reads/creates/deletes observed branches with collision and ancestry checks.
    def command_branch(checkout, arguments, input, _settings)
      no_input!(input)
      return result(checkout.head_ref ? checkout.head_ref.delete_prefix("refs/heads/") + "\n" : "") if arguments == ["--show-current"]
      delete = arguments.first == "-d" || arguments.first == "-D"
      if delete
        raise Mismatch, "branch deletion needs one name" unless arguments.length == 2
        ref = ref!("refs/heads/#{arguments.last}")
        raise Refusal.new("branch missing", 1) unless checkout.repository.refs.key?(ref)
        raise Refusal.new("branch is checked out", 1) if checkout.repository.worktrees.values.any? { |item| item.head_ref == ref }
        if arguments.first == "-d" && !ancestor?(checkout.repository.objects, checkout.repository.refs.fetch(ref), checkout.head)
          raise Refusal.new("branch not fully merged", 1)
        end
        effect!(:branch_delete) { checkout.repository.refs.delete(ref) }
      else
        raise Mismatch, "branch creation needs name and optional start" unless (1..2).cover?(arguments.length) && !arguments.first.start_with?("-")
        ref = ref!("refs/heads/#{arguments.first}")
        raise Refusal, "branch already exists" if checkout.repository.refs.key?(ref)
        object = resolve(checkout, arguments[1] || "HEAD")
        raise Refusal, "branch requires commit" unless object.is_a?(Commit)
        effect!(:branch_create) { checkout.repository.refs[ref] = object.oid }
      end
      result
    end

    # Routes the audited worktree list/add/remove forms. No repair/prune/force
    # capability exists; unknown operations raise Mismatch without a process.
    def command_worktree(checkout, arguments, input, settings)
      no_input!(input)
      case arguments.shift
      when "list"
        exact!(arguments, ["--porcelain", "-z"])
        rows = checkout.repository.worktrees.values.map do |item|
          fields = ["worktree #{item.path}", "HEAD #{item.head || '0' * 40}",
            item.head_ref ? "branch #{item.head_ref}" : "detached", ""]
          fields.join("\0") + "\0"
        end
        result(rows.join)
      when "add" then worktree_add(checkout, arguments)
      when "remove" then worktree_remove(checkout, arguments, settings)
      else raise Mismatch, "unsupported worktree operation"
      end
    end

    # Creates independent HEAD/index plus real .git/admin backpointers, sharing
    # only repository authority/objects/config. Collisions refuse before mutation.
    def worktree_add(checkout, arguments)
      branch = nil
      if arguments.first == "-b"
        raise Mismatch, "invalid worktree branch add" unless arguments.length == 5 && arguments[2] == "--"
        branch = ref!("refs/heads/#{arguments[1]}")
        raise Refusal, "branch already exists" if checkout.repository.refs.key?(branch)
        target, revision = arguments.last(2)
      else
        raise Mismatch, "invalid detached worktree add" unless arguments.length == 4 && arguments.first(2) == ["--detach", "--"]
        target, revision = arguments.last(2)
      end
      target = owned_path!(target)
      raise Refusal, "worktree target occupied" if File.exist?(target) || File.symlink?(target) || @checkouts.key?(target)
      object = resolve(checkout, revision)
      raise Refusal, "worktree needs commit" unless object.is_a?(Commit)
      repository = checkout.repository
      stem = File.basename(target)
      suffix = 1
      suffix += 1 while repository.worktrees.values.any? { |item| File.basename(item.admin) == "#{stem}#{suffix}" }
      admin = File.join(repository.common, "worktrees", "#{stem}#{suffix}")
      raise Refusal, "worktree admin occupied" if File.exist?(admin) || File.symlink?(admin)
      effect!(:worktree_add) do
        repository.refs[branch] = object.oid if branch
        item = Checkout.new(path: target, repository: repository, admin: admin,
          head_ref: branch, detached: branch ? nil : object.oid)
        @checkouts[target] = item
        repository.worktrees[target] = item
        owned_path!(admin)
        FileUtils.mkdir_p([target, admin])
        File.binwrite(File.join(target, ".git"), "gitdir: #{admin}\n")
        File.binwrite(File.join(admin, "gitdir"), File.join(target, ".git") + "\n")
        File.binwrite(File.join(admin, "commondir"), "../..\n")
        materialize!(item, {}, item.index)
      end
      result
    end

    # Removes only a registered, physically bound, clean linked worktree. Real
    # files/pointers are checked before disposal; copied directories confer no authority.
    def worktree_remove(checkout, arguments, settings)
      raise Mismatch, "invalid worktree remove" unless arguments.length == 2 && arguments.first == "--"
      target = owned_path!(arguments.last)
      item = checkout.repository.worktrees[target]
      raise Refusal, "not a linked worktree" unless item && item.admin != item.repository.common
      pointer = File.join(target, ".git")
      backpointer = File.join(item.admin, "gitdir")
      raise Refusal, "worktree pointer changed" unless File.file?(pointer) && !File.symlink?(pointer) &&
        File.binread(pointer) == "gitdir: #{item.admin}\n" && File.file?(backpointer) && !File.symlink?(backpointer) &&
        File.binread(backpointer).strip == pointer
      physical = scan(item)
      extra = (physical.keys - item.index.keys).reject { |path| ignored?(item, path, settings) }
      raise Refusal, "worktree contains changes" unless item.tree.entries == item.index &&
        item.index.all? { |path, entry| entry == physical[path] } && extra.empty?
      effect!(:worktree_remove) do
        FileUtils.remove_entry(target)
        FileUtils.remove_entry(item.admin)
        checkout.repository.worktrees.delete(target)
        @checkouts.delete(target)
      end
      result
    end
  end
end
