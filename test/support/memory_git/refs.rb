# frozen_string_literal: true

module MemoryGit
  class World
    private

    # Resolves observed refs, HEAD parents and commit/tree/blob selectors. Returns
    # immutable object; absent objects raise Refusal, unknown syntax Mismatch.
    def resolve(checkout, expression)
      if expression.start_with?(":")
        entry = checkout.index[Tree.path!(expression.delete_prefix(":"))]
        raise Refusal, "path missing from index" unless entry
        blob = checkout.repository.objects[entry.blob.oid]
        raise Refusal, "index blob unavailable" unless blob.is_a?(Blob)
        return blob
      end
      revision, path = expression.split(":", 2)
      match = revision.match(/\A([^\^~{}]+)((?:\^\d*|~\d+)*)(\^\{(?:commit|tree)\})?\z/)
      raise Mismatch, "unsupported revision #{expression.inspect}" unless match
      name, ancestry, peel = match.captures
      oid = name == "HEAD" ? checkout.head : checkout.repository.refs[name] || checkout.repository.refs["refs/heads/#{name}"] ||
        checkout.repository.refs["refs/remotes/#{name}"] || (name if name.match?(/\A[0-9a-f]{40}\z/))
      object = checkout.repository.objects[oid]
      raise Refusal, "unknown revision #{name}" unless object
      ancestry.scan(/\^\d*|~\d+/).each do |step|
        raise Refusal, "not a commit" unless object.is_a?(Commit)
        if step.start_with?("~")
          step.delete_prefix("~").to_i.times do
            object = checkout.repository.objects[object.parents.first] if object.is_a?(Commit)
            raise Refusal, "missing ancestor" unless object.is_a?(Commit)
          end
        else
          parent = step.delete_prefix("^")
          position = parent.empty? ? 1 : parent.to_i
          object = checkout.repository.objects[object.parents[position - 1]] unless position.zero?
          raise Refusal, "missing parent" unless object.is_a?(Commit)
        end
      end
      raise Refusal, "not a commit" if peel == "^{commit}" && !object.is_a?(Commit)
      if (path || peel == "^{tree}") && object.is_a?(Commit)
        object = checkout.repository.objects[object.tree.oid]
        raise Refusal, "tree unavailable" unless object.is_a?(Tree)
      end
      if path
        raise Refusal, "not a tree" unless object.is_a?(Tree)
        entry = object.entries[Tree.path!(path)]
        raise Refusal, "path missing from tree" unless entry
        object = checkout.repository.objects[entry.blob.oid]
        raise Refusal, "blob unavailable" unless object.is_a?(Blob)
      end
      object
    end

    # Produces observed discovery/revision fields, retaining unborn/missing failures.
    def command_rev_parse(checkout, arguments, input, _settings)
      no_input!(input)
      absolute = arguments.first == "--path-format=absolute"
      arguments.shift if absolute
      if arguments.first == "--git-path"
        exact!(arguments, ["--git-path", "index"], ["--git-path", "objects"], ["--git-path", "MERGE_HEAD"], ["--git-path", "CHERRY_PICK_HEAD"],
          ["--git-path", "REVERT_HEAD"], ["--git-path", "rebase-merge"], ["--git-path", "rebase-apply"], ["--git-path", "sequencer"])
        raise Refusal, "not a git repository" unless checkout
        directory = arguments.last == "objects" ? checkout.repository.common : checkout.admin
        return result(File.join(directory, arguments.last) + "\n")
      end
      if arguments.first == "--symbolic-full-name"
        exact!(arguments, ["--symbolic-full-name", "HEAD"])
        raise Refusal, "not a git repository" unless checkout
        return result((checkout.head_ref || "HEAD") + "\n")
      end
      verify = arguments.first == "--verify"
      arguments.shift if verify
      raise Mismatch, "rev-parse needs fields" if arguments.empty?
      fields = arguments.map do |field|
        if field.start_with?("-") && !%w[--show-toplevel --git-common-dir --absolute-git-dir --git-dir --is-inside-work-tree].include?(field)
          raise Mismatch, "unsupported rev-parse flag #{field}"
        end
        raise Refusal, "not a git repository" unless checkout
        case field
        when "--show-toplevel" then checkout.path
        when "--git-common-dir" then absolute || checkout.admin != checkout.repository.common ? checkout.repository.common : ".git"
        when "--git-dir" then absolute || checkout.admin != checkout.repository.common ? checkout.admin : ".git"
        when "--absolute-git-dir" then checkout.admin
        when "--is-inside-work-tree" then "true"
        else resolve(checkout, field).oid
        end
      end
      result(fields.join("\n") + "\n")
    end

    # Reads exact blob bytes or a commit message; unknown display formats refuse.
    def command_show(checkout, arguments, input, _settings)
      no_input!(input)
      if arguments[0, 2] == ["-s", "--format=%B"]
        raise Mismatch, "show message requires revision" unless arguments.length == 3
        object = resolve(checkout, arguments.last)
        raise Refusal, "not a commit" unless object.is_a?(Commit)
        return result(object.message + "\n")
      end
      raise Mismatch, "show requires blob selector" unless arguments.length == 1 && arguments.first.include?(":")
      object = resolve(checkout, arguments.first)
      raise Refusal, "not a blob" unless object.is_a?(Blob)
      result(object.bytes.dup)
    end

    # Reads/probes immutable objects, preserving missing-object failure and bytes.
    def command_cat_file(checkout, arguments, input, _settings)
      no_input!(input)
      raise Mismatch, "unsupported cat-file" unless arguments.length == 2 && %w[-e -t blob].include?(arguments.first)
      object = resolve(checkout, arguments.last)
      case arguments.first
      when "-e" then result
      when "-t" then result({ Blob => "blob", Tree => "tree", Commit => "commit" }.fetch(object.class) + "\n")
      when "blob"
        raise Refusal, "not a blob" unless object.is_a?(Blob)
        result(object.bytes.dup)
      end
    end

    # Reports symbolic HEAD or detached failure, never converting detached to main.
    def command_symbolic_ref(checkout, arguments, input, _settings)
      no_input!(input)
      exact!(arguments, ["-q", "HEAD"], ["--quiet", "--short", "HEAD"], ["--short", "HEAD"])
      return result("", "", 1) unless checkout.head_ref
      name = arguments.include?("--short") ? checkout.head_ref.delete_prefix("refs/heads/") : checkout.head_ref
      result(name + "\n")
    end

    # Probes an exact full ref; returns exit 1 for absent refs.
    def command_show_ref(checkout, arguments, input, _settings)
      no_input!(input)
      raise Mismatch, "unsupported show-ref" unless arguments[0, 2] == ["--verify", "--quiet"] && arguments.length == 3
      ref!(arguments.last)
      result("", "", checkout.repository.refs.key?(arguments.last) ? 0 : 1)
    end

    # Implements only ancestry queries with a real parent graph (including merges).
    def command_merge_base(checkout, arguments, input, _settings)
      no_input!(input)
      raise Mismatch, "unsupported merge-base" unless arguments.length == 3 && arguments.first == "--is-ancestor"
      older, newer = arguments.drop(1).map { |revision| resolve(checkout, revision) }
      raise Refusal, "not a commit" unless [older, newer].all? { |object| object.is_a?(Commit) }
      result("", "", ancestor?(checkout.repository.objects, older.oid, newer.oid) ? 0 : 1)
    end

    # Walks parent IDs; returns true only for reachable equality/ancestry.
    def ancestor?(objects, older, newer)
      pending, seen = [newer], {}
      until pending.empty?
        oid = pending.pop
        return true if oid == older
        next if seen[oid]
        seen[oid] = true
        object = objects[oid]
        pending.concat(object.parents) if object.is_a?(Commit)
      end
      false
    end

    # Reads/mutates observed config keys through the explicit in-memory adapter.
    def command_config(checkout, arguments, input, _settings)
      no_input!(input)
      arguments.shift if arguments.first == "--local"
      get = %w[--get --get-all].include?(arguments.first)
      arguments.shift if get
      key = arguments.first
      raise Mismatch, "unsupported config request" unless key && key.match?(/\A(?:remote\.[^.]+\.(?:url|pushurl)|branch\.[^.]+\.(?:remote|merge)|user\.(?:name|email)|core\.(?:excludesFile|hooksPath)|commit\.gpgsign)\z/)
      if arguments.length == 1
        value = checkout.repository.config[key]
        return value ? result(value + "\n") : result("", "", 1)
      end
      raise Mismatch, "unsupported config options" unless arguments.length == 2 && !get
      effect!(:config) { configure(checkout, key, arguments.last) }
      result
    end

    # Reads exact fetch/push URLs or sets one observed remote URL.
    def command_remote(checkout, arguments, input, _settings)
      no_input!(input)
      if arguments.first == "get-url"
        flags, names = arguments.drop(1).partition { |argument| argument.start_with?("-") }
        raise Mismatch, "unsupported remote get-url" unless names.length == 1 && [[], ["--push", "--all"]].include?(flags)
        name = names.first
        url = flags.empty? ? checkout.repository.remotes[name] : checkout.repository.config["remote.#{name}.pushurl"] || checkout.repository.remotes[name]
        raise Refusal, "No such remote #{name}" unless url
        return result(url + "\n")
      end
      raise Mismatch, "unsupported remote mutation" unless %w[add set-url].include?(arguments.first) && arguments.length == 3
      operation, name, url = arguments
      exists = checkout.repository.remotes.key?(name)
      raise Refusal, "remote already exists" if operation == "add" && exists
      raise Refusal, "No such remote" if operation == "set-url" && !exists
      effect!(:config) { configure(checkout, "remote.#{name}.url", url) }
      result
    end
  end
end
