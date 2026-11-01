# frozen_string_literal: true

module MemoryGit
  # Exact reconstruction commands at the transport boundary. Kept outside the
  # TST-35 dispatcher/registry; all other requests use that unchanged dispatcher.
  module Reconstruction
    # Executes only the two unprefixed forms emitted by Checkpoint, retaining core
    # envelope, pointer, serialization, faults and result semantics. Unknown clone
    # or checkout forms raise Mismatch, ordinary Git refusals return nonzero.
    def call(argv, cwd: nil, env: {}, input: "", timeout: nil, **options)
      return super unless argv.is_a?(Array) && %w[clone checkout].include?(argv[1])
      @lock.synchronize do
        previous_request = @current_request
        validate_envelope!(argv, cwd, env, input, timeout, options)
        raise Mismatch, "scratch reconstruction unsupported" if env.key?("GIT_INDEX_FILE")
        @current_request = envelope(argv, cwd, env, input, timeout, options)
        @requests << @current_request
        no_input!(input)
        run_faults(:before)
        response = if argv[1] == "clone"
                     raise Mismatch, "clone cwd must be absent" unless cwd.nil?
                     reconstruct_clone(argv.drop(2))
                   else
                     checkout = cwd && locate(cwd)
                     raise Mismatch, "checkout requires exact registered root" unless checkout && checkout.path == cwd
                     check_pointer!(checkout)
                     reconstruct_checkout(checkout, argv.drop(2))
                   end
        override = run_faults(:after)
        override&.fetch(:result) || response
      rescue Refusal => error
        result("", "fatal: #{error.message}\n", error.code)
      ensure
        @current_request = previous_request
      end
    end

    private

    # Copies immutable local objects/refs into independent ordinary authority with
    # an empty index/worktree. No native .git objects, links or network are used.
    def reconstruct_clone(arguments)
      flags = arguments.first(arguments.index("--") || 0)
      exact!(flags, %w[--shared --no-checkout], %w[--no-local --no-hardlinks --no-checkout])
      raise Mismatch, "unsupported reconstruction clone" unless arguments.length == flags.length + 3 && arguments[flags.length] == "--"
      source, destination = arguments.last(2)
      original = @checkouts[source]
      raise Mismatch, "clone requires registered local source" unless original
      check_pointer!(original)
      destination = owned_path!(destination)
      raise Refusal, "clone destination occupied" if File.exist?(destination) || File.symlink?(destination)
      effect!(:clone) do
        clone = repository(path: destination, template: Template.new(commits: original.repository.objects.values.grep(Commit), head: original.head))
        clone.repository.objects.replace(original.repository.objects)
        clone.repository.refs.replace(original.repository.refs)
        clone.head_ref, clone.detached = original.head_ref, original.detached
        configure(clone, "remote.origin.url", source)
        materialize!(clone, clone.index, {})
        clone.index.clear
      end
      result
    end

    # Projects one locally present detached commit into the reconstruction. Files,
    # index and HEAD change together unless an explicit required-effect fault acts.
    def reconstruct_checkout(checkout, arguments)
      raise Mismatch, "only detached reconstruction checkout supported" unless arguments.length == 2 && arguments.first == "--detach"
      commit = resolve(checkout, arguments.last)
      raise Refusal, "checkout requires commit" unless commit.is_a?(Commit)
      effect!(:checkout) do
        materialize!(checkout, checkout.index, commit.tree.entries)
        checkout.index.replace(commit.tree.entries)
        checkout.head_ref, checkout.detached = nil, commit.oid
      end
      result
    end
  end

  PatchWorld.prepend(Reconstruction)
end
