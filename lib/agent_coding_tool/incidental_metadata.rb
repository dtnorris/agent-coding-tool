# frozen_string_literal: true

require "find"

module AgentCodingTool
  # Discovery-only Finder metadata policy. Explicit paths and tracked content
  # never acquire an exemption. Inspection does not modify metadata or Git state.
  module IncidentalMetadata
    # Returns true only for an exact, readable regular .DS_Store without symlink
    # ancestry. Missing/racing/unreadable entries raise; other types return false.
    def self.file?(path)
      return false unless File.basename(path) == ".DS_Store"
      stat = File.lstat(path)
      return false unless stat.file?
      raise InvalidState, "metadata: unsafe ancestor" unless File.realpath(File.dirname(path)) == File.expand_path(File.dirname(path))
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        current = file.stat
        raise InvalidState, "metadata: entry changed during inspection" unless current.file? &&
          [current.dev, current.ino] == [stat.dev, stat.ino]
      end
      true
    end

    # Returns immediate discovery names, retaining all nonmetadata entries for
    # the caller's ordinary validation. Directory/lstat/access errors propagate.
    def self.children(directory)
      Dir.children(directory).reject { |name| file?(File.join(directory, name)) }
    end

    # Git omits FIFOs/sockets even from --others. Inspect Finder names separately
    # without following links or entering root Git administration. Returns nil;
    # untracked nonregular metadata, inaccessible/racing trees and unsafe ancestry
    # raise. Tracked paths keep ordinary consumer validation, using raw Git reads
    # supplied by the block. Explicit artifact readers do not use this policy.
    def self.check_repository!(root, &git)
      Find.find(root, ignore_error: false) do |path|
        Find.prune if path == File.join(root, ".git")
        next if path == root
        next unless File.basename(path) == ".DS_Store"
        next if file?(path)
        relative = path.delete_prefix(root + "/")
        next if tracked?(relative, &git)
        raise InvalidState, "metadata: nonregular repository entry #{path}"
      end
      nil
    end

    # Checks a Git-inventoried path against both index and HEAD before excluding
    # it. The supplied block executes raw NUL-safe Git reads in this repository;
    # Git/access failures propagate. No reads occur for other basenames.
    def self.untracked?(root, path)
      return false unless File.basename(path) == ".DS_Store"
      return false if tracked?(path) { |*args| yield(*args) }
      file?(File.join(root, path))
    end

    # Returns whether index or HEAD deliberately contains this path (or a tracked
    # directory's descendants). Raw NUL Git output is never substring filtered;
    # the caller's Git executor propagates unavailable evidence as an error.
    def self.tracked?(path, &git)
      !git.call("--literal-pathspecs", "ls-files", "--cached", "-z", "--", path).empty? ||
        !git.call("--literal-pathspecs", "ls-tree", "-r", "--name-only", "-z", "HEAD", "--", path).empty?
    end

    # Filters only untracked/ignored regular metadata from raw porcelain v1 -z.
    # Rename/copy pairs retain exact bytes. Malformed records raise InvalidState;
    # tracked/staged records are never filtered. The block supplies Git reads.
    def self.status(root, bytes, &git)
      raise InvalidState, "metadata: non-NUL Git status" unless bytes.empty? || bytes.end_with?("\0")
      fields = bytes.split("\0")
      retained = []
      until fields.empty?
        field = fields.shift
        raise InvalidState, "metadata: malformed Git status" unless field.bytesize > 3 && field[2] == " "
        code, path = field[0, 2], field[3..]
        original = nil
        original = fields.shift if code.match?(/[RC]/)
        raise InvalidState, "metadata: missing rename source" if code.match?(/[RC]/) && !original
        next if %w[?? !!].include?(code) && untracked?(root, path, &git)
        retained << field
        retained << original if original
      end
      retained.empty? ? "".b : retained.join("\0") + "\0"
    end

    # Returns substantive status using complete NUL-safe paths and read-only Git
    # observations. Cleanup callers also inventory ignored content. Errors from
    # the supplied Git executor or metadata inspection propagate.
    def self.git_status(root, ignored: false, &git)
      check_repository!(root, &git)
      args = %w[--no-optional-locks status --porcelain=v1 -z --untracked-files=all]
      args << "--ignored" if ignored
      status(root, git.call(*args), &git)
    end
  end
end
