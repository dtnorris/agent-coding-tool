# frozen_string_literal: true

require "digest"

# Finite test Git capabilities. None of these objects execute a process.
module MemoryGit
  # Test/protocol mismatches must escape production StandardError refusals.
  class Mismatch < Exception; end

  # A modeled, ordinary Git refusal; translated to CommandResult at the boundary.
  class Refusal < StandardError
    attr_reader :code

    # Takes a diagnostic and native-style exit code; returns an exception.
    def initialize(message, code = 128)
      super(message)
      @code = code
    end
  end

  # Immutable bytes with a deterministic Git blob ID, including binary content.
  class Blob
    attr_reader :bytes, :oid

    # Copies String bytes; returns a frozen blob. Invalid inputs raise Mismatch.
    def initialize(bytes)
      raise Mismatch, "blob requires String bytes" unless bytes.is_a?(String)
      @bytes = bytes.b.freeze
      @oid = Digest::SHA1.hexdigest("blob #{@bytes.bytesize}\0".b + @bytes).freeze
      freeze
    end
  end

  # Immutable path content and one supported Git file mode.
  class Entry
    attr_reader :blob, :mode

    # Accepts bytes and 100644/100755/120000; invalid modes raise Mismatch.
    def initialize(bytes, mode: "100644")
      raise Mismatch, "unsupported file mode #{mode}" unless %w[100644 100755 120000].include?(mode)
      @blob, @mode = Blob.new(bytes), mode.dup.freeze
      freeze
    end

    # Compares independent entries by bytes and mode; returns boolean.
    def ==(other) = other.is_a?(Entry) && mode == other.mode && blob.oid == other.blob.oid
  end

  # Immutable flat path map; its ID binds every path, mode and blob ID.
  # IDs preserve equality, not native recursive tree serialization compatibility.
  class Tree
    attr_reader :entries, :oid

    # Takes relative paths => String/Entry. Unsafe paths/collisions raise Mismatch.
    def initialize(files)
      @entries = files.to_h do |path, content|
        path = self.class.path!(path).freeze
        [path, content.is_a?(Entry) ? content : Entry.new(content)]
      end.sort.to_h.freeze
      @entries.each_key do |path|
        parts = path.split("/")
        raise Mismatch, "tree has file/directory collision" if
          (1...parts.length).any? { |length| @entries.key?(parts.first(length).join("/")) }
      end
      bytes = @entries.map { |path, entry| "#{entry.mode} #{path.bytesize}:#{path}\0#{entry.blob.oid}\0".b }.join
      @oid = Digest::SHA1.hexdigest("memory-tree\0".b + bytes).freeze
      freeze
    end

    # Returns a binary relative path; traversal/admin/NUL paths raise Mismatch.
    def self.path!(path)
      unless path.is_a?(String) && !path.empty? && !path.start_with?("/") && !path.include?("\0") &&
             path.b.split("/", -1).none? { |part| ["", ".", "..", ".git"].include?(part) }
        raise Mismatch, "unsafe modeled path #{path.inspect}"
      end
      path.b.dup
    end
  end

  # Immutable commit tree/parents/message with deterministic ancestry identity.
  class Commit
    attr_reader :tree, :parents, :message, :oid

    # Takes Tree, parent IDs and message; imported pin IDs are explicit fixture
    # identities, never actual source provenance. Malformed IDs raise Mismatch.
    def initialize(tree:, parents: [], message: "seed", oid: nil)
      @tree = tree
      @parents = parents.map { |parent| parent.dup.freeze }.freeze
      @message = (message.end_with?("\n") ? message.b : message.b + "\n").freeze
      bytes = [tree.oid, *@parents, @message].join("\0")
      @oid = (oid || Digest::SHA1.hexdigest("memory-commit\0".b + bytes)).dup.freeze
      raise Mismatch, "invalid commit identity" unless ([@oid] + @parents).all? { |id| id.match?(/\A[0-9a-f]{40}\z/) }
      freeze
    end
  end

  # Reusable immutable seed. Worlds copy mutable stores, never share them.
  class Template
    attr_reader :commits, :head

    # Takes immutable commits and an optional head ID. Missing heads raise Mismatch.
    def initialize(commits:, head: commits.last&.oid)
      @commits = commits.dup.freeze
      @head = head&.dup&.freeze
      raise Mismatch, "template head missing" if head && !commits.any? { |commit| commit.oid == head }
      freeze
    end

    # Builds a one-commit template directly from files; returns Template.
    def self.files(files, message: "seed")
      new(commits: [Commit.new(tree: Tree.new(files), message: message)])
    end
  end
end
