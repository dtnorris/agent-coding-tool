# frozen_string_literal: true

require "digest"
require "json"

# Read-only harness provenance, deliberately independent of product Git runners,
# fixture worlds, cwd and GIT_* environment. This is not a Git status parser.
module SourceIdentity
  class Unsupported < StandardError; end

  # Reads actual source bytes at an explicit root. Returns hashes even when Git
  # metadata is absent/unsupported; never invents HEAD, cleanliness or a version.
  # Invalid source paths and filesystem errors propagate to the caller.
  def self.capture(root:, paths: nil)
    root = File.realpath(root)
    paths ||= (Dir.glob("{lib,test}/**/*.{rb,json,py}", base: root) +
      %w[bin/agent-coding-tool Rakefile Gemfile Gemfile.lock]).select { |path| File.file?(File.join(root, path)) }.sort
    hashes = paths.sort.to_h do |path|
      absolute = File.realpath(File.join(root, path))
      raise ArgumentError, "source path outside root: #{path}" unless absolute.start_with?(root + File::SEPARATOR)
      [path, Digest::SHA256.file(absolute).hexdigest]
    end
    identity = Reader.new(root).read
    identity.merge("root" => root, "source_files" => hashes,
      "source_sha256" => Digest::SHA256.hexdigest(JSON.generate(hashes)),
      "status" => "UNAVAILABLE: worktree/index semantics are not inferred from source hashes",
      "git_version" => "UNAVAILABLE: no Git executable invoked")
  end

  # Resolves only file-backed SHA-1 refs. Records every metadata file read so
  # consumers can compare provenance before/after an invocation without Git.
  class Reader
    # Accepts a canonical source root; does not consult environment overrides.
    def initialize(root)
      @root, @metadata = root, {}
    end

    # Returns resolved HEAD or an explicit unavailable reason and metadata hashes.
    # Unsupported layouts never masquerade as a fixture revision or clean tree.
    def read
      pointer = File.join(@root, ".git")
      raise Unsupported, ".git is absent" unless File.exist?(pointer)
      raise Unsupported, "symlink .git is unsupported" if File.symlink?(pointer)
      @git_dir = if File.directory?(pointer)
                   File.realpath(pointer)
                 else
                   match = /\Agitdir: ([^\x00\r\n]+)\n?\z/.match(bytes(pointer))
                   raise Unsupported, "malformed .git pointer" unless match
                   File.realpath(File.expand_path(match[1], @root))
                 end
      common_path = File.join(@git_dir, "commondir")
      @common_dir = if File.exist?(common_path)
                      common = bytes(common_path).strip
                      raise Unsupported, "malformed commondir" if common.empty? || common.include?("\x00") || common.include?("\n")
                      File.realpath(File.expand_path(common, @git_dir))
                    else
                      @git_dir
                    end
      config = File.join(@common_dir, "config")
      if File.file?(config)
        text = bytes(config)
        raise Unsupported, "repository format/extensions unsupported" if
          text.scan(/^\s*repositoryformatversion\s*=\s*([^\r\n]*)/i).any? { |match| match.first.strip != "0" } ||
          text.match?(/^\s*\[extensions\]/i) || text.match?(/^\s*\[include(?:If\b[^\]]*)?\]/i)
      end
      head = resolve(bytes(File.join(@git_dir, "HEAD")).strip, [])
      index = File.join(@git_dir, "index")
      bytes(index) if File.file?(index)
      { "availability" => "AVAILABLE", "head" => head, "git_dir" => @git_dir,
        "common_dir" => @common_dir, "metadata_sha256" => @metadata }
    rescue Unsupported, SystemCallError => error
      { "availability" => "UNAVAILABLE", "head" => nil,
        "reason" => "#{error.class}: #{error.message}", "metadata_sha256" => @metadata }
    end

    private

    # Reads a regular, non-symlink metadata file and hashes its exact bytes.
    # Missing files raise; unusual filesystem layouts are explicitly unsupported.
    def bytes(path)
      raise Unsupported, "nonregular/symlink metadata: #{path}" unless File.file?(path) &&
        File.realpath(path) == File.expand_path(path)
      value = File.binread(path)
      @metadata[path] = Digest::SHA256.hexdigest(value)
      value
    end

    # Resolves symbolic chains, loose refs and packed refs, rejecting malformed,
    # cyclic, unborn or non-SHA-1 identities rather than guessing a source HEAD.
    def resolve(value, seen)
      return value if value.match?(/\A[0-9a-f]{40}\z/)
      reference = value.delete_prefix("ref: ")
      raise Unsupported, "malformed HEAD/ref" unless value.start_with?("ref: ") &&
        reference.start_with?("refs/") && reference.split("/").all? { |part|
          part.match?(/\A[A-Za-z0-9_-][A-Za-z0-9_.-]*\z/) && !part.include?("..") &&
            !part.end_with?(".", ".lock") }
      raise Unsupported, "cyclic/excessive symbolic refs" if seen.include?(reference) || seen.length >= 16
      directory = reference.match?(/\Arefs\/(?:bisect|worktree|rewritten)\//) ? @git_dir : @common_dir
      loose = File.join(directory, reference)
      return resolve(bytes(loose).strip, seen + [reference]) if File.exist?(loose) || File.symlink?(loose)
      packed = File.join(directory, "packed-refs")
      raise Unsupported, "unresolved/unborn ref: #{reference}" unless File.file?(packed)
      refs = {}
      bytes(packed).each_line do |line|
        next if line.start_with?("#")
        if line.start_with?("^")
          raise Unsupported, "malformed packed peeled ref" unless line.match?(/\A\^[0-9a-f]{40}\n?\z/) && !refs.empty?
          next
        end
        match = /\A([0-9a-f]{40}) (refs\/[^\s]+)\n?\z/.match(line)
        raise Unsupported, "malformed/duplicate packed ref" unless match && !refs.key?(match[2])
        refs[match[2]] = match[1]
      end
      refs.fetch(reference) { raise Unsupported, "unresolved/unborn ref: #{reference}" }
    end
  end
end

puts JSON.generate(SourceIdentity.capture(root: ARGV.fetch(0))) if $PROGRAM_NAME == __FILE__
