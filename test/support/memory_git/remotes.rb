# frozen_string_literal: true

module MemoryGit
  class World
    private

    # Looks up a declared remote independently of local objects; missing/offline
    # remotes are modeled failures, unknown URLs cannot trigger native fallback.
    def find_remote(checkout, name)
      url = checkout&.repository&.remotes&.fetch(name, nil) || name
      remote = @remotes[url]
      raise Refusal, "remote unavailable: #{name}" unless remote&.available
      remote
    end

    # Advertises one exact branch independently from any local object availability.
    def command_ls_remote(checkout, arguments, input, _settings)
      no_input!(input)
      raise Mismatch, "unsupported ls-remote" unless arguments.length == 3 && arguments.first == "--exit-code"
      _flag, name, ref = arguments
      ref!(ref)
      remote = find_remote(checkout, name)
      oid = remote.refs[ref]
      oid ? result("#{oid}\t#{ref}\n") : result("", "", 2)
    end

    # Copies the requested remote commit graph into local storage before updating
    # an explicit tracking ref/FETCH_HEAD. No unrelated remote refs become local.
    def command_fetch(checkout, arguments, input, _settings)
      no_input!(input)
      flags = arguments.take_while { |argument| argument.start_with?("-") }
      args = arguments.drop(flags.length)
      raise Mismatch, "unsupported fetch" unless (flags - %w[--no-tags --quiet]).empty? && flags.uniq == flags && args.length == 2
      name, spec = args
      source, destination = spec.delete_prefix("+").split(":", 2)
      source = "refs/heads/#{source}" unless source.start_with?("refs/") || source.match?(/\A[0-9a-f]{40}\z/)
      ref!(source) unless source.match?(/\A[0-9a-f]{40}\z/)
      ref!(destination) if destination
      remote = find_remote(checkout, name)
      oid = remote.refs[source] || (source if source.match?(/\A[0-9a-f]{40}\z/))
      raise Refusal, "couldn't find remote ref #{source}" unless oid && remote.objects[oid].is_a?(Commit)
      objects = reachable(remote.objects, oid)
      effect!(:fetch) do
        objects.each_value { |object| checkout.repository.store(object) }
        checkout.repository.refs[destination || "FETCH_HEAD"] = oid
      end
      result
    end

    # Walks exactly reachable commits/trees/blobs, refusing incomplete remote storage.
    # Returns a new hash of immutable objects; does not borrow the remote ref map.
    def reachable(objects, oid, found = {})
      return found if found.key?(oid)
      object = objects[oid]
      raise Refusal, "remote object missing #{oid}" unless object
      found[oid] = object
      case object
      when Commit
        reachable(objects, object.tree.oid, found)
        object.parents.each { |parent| reachable(objects, parent, found) }
      when Tree then object.entries.each_value { |entry| reachable(objects, entry.blob.oid, found) }
      end
      found
    end

    # Applies one scoped push after exact lease/fast-forward checks. Remote movement
    # faults occur before validation via :before or after copying via :after_effect.
    def command_push(checkout, arguments, input, _settings)
      no_input!(input)
      lease = arguments.first&.start_with?("--force-with-lease=") ? arguments.shift.delete_prefix("--force-with-lease=") : nil
      raise Mismatch, "unsupported push" unless arguments.length == 2 && !arguments.any? { |argument| argument.start_with?("-") }
      name, refspec = arguments
      source, target, extra = refspec.split(":", -1)
      raise Mismatch, "push requires one explicit source:target" if !target || extra || source.empty?
      ref!(target)
      raise Mismatch, "push target must be branch" unless target.start_with?("refs/heads/")
      expected = nil
      if lease
        lease_ref, expected = lease.split(":", -1)
        raise Mismatch, "push requires explicit matching lease" unless lease_ref == target && expected &&
          (expected.empty? || expected.match?(/\A[0-9a-f]{40}\z/))
      end
      object = resolve(checkout, source)
      raise Refusal, "push source not a commit" unless object.is_a?(Commit)
      remote = find_remote(checkout, name)
      current = remote.refs[target]
      if lease
        raise Refusal.new("stale info: force-with-lease rejected", 1) unless current == (expected.empty? ? nil : expected)
      elsif current && !ancestor?(checkout.repository.objects, current, object.oid)
        raise Refusal.new("non-fast-forward", 1)
      end
      objects = reachable(checkout.repository.objects, object.oid)
      effect!(:push) do
        remote = find_remote(checkout, name)
        moved = remote.refs[target]
        if lease
          raise Refusal.new("stale info: force-with-lease rejected", 1) unless moved == (expected.empty? ? nil : expected)
        elsif moved && !ancestor?(checkout.repository.objects, moved, object.oid)
          raise Refusal.new("non-fast-forward", 1)
        end
        remote.objects.merge!(objects)
        remote.refs[target] = object.oid
      end
      result
    end
  end
end
