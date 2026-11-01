# frozen_string_literal: true

require "digest"
require "fileutils"
require "securerandom"

module AgentCodingTool
  # Byte/mode preservation for hard reset only. Links are inventoried and copied
  # as links; devices, sockets, FIFOs and nested repositories refuse preservation.
  class ResetArchive
    # Binds the existing native command boundary; construction performs no I/O.
    def initialize(transport: NativeCommandTransport.new)
      @transport = transport
    end

    # Returns a complete relative-path inventory, including empty directories,
    # ignored files and link targets. Missing/unsafe entries and races raise.
    # Git pointers are ordinary bytes here; callers independently prove ownership.
    def inventory(path, worktree: false)
      rows = {}
      visit = lambda do |absolute, relative|
        stat = File.lstat(absolute)
        row = { "mode" => stat.mode & 0o7777 }
        if stat.symlink?
          row.merge!("type" => "link", "target" => File.readlink(absolute))
        elsif stat.file?
          row.merge!("type" => "file", "bytes" => stat.size, "sha256" => Digest::SHA256.file(absolute).hexdigest)
        elsif stat.directory?
          row["type"] = "directory"
        else
          raise InvalidState, "hard reset: nonpreservable entry #{absolute}"
        end
        rows[relative] = row
        if stat.directory?
          Dir.children(absolute).sort.each do |name|
            if worktree && name == ".git" && relative != "."
              raise InvalidState, "hard reset: nested repository #{absolute}; external data must remain in place"
            end
            visit.call(File.join(absolute, name), relative == "." ? name : File.join(relative, name))
          end
        end
        after = File.lstat(absolute)
        unless [stat.dev, stat.ino, stat.mode, stat.size, stat.mtime, stat.ctime] ==
               [after.dev, after.ino, after.mode, after.size, after.mtime, after.ctime]
          raise InvalidState, "hard reset: source changed while reading #{absolute}"
        end
      end
      visit.call(path, ".")
      rows
    end

    # Copies one inventoried source into an absent destination or verifies an
    # already complete copy during resume. No archive file is overwritten. A
    # failed copy retains its temporary bytes; the source is never modified.
    def preserve(source, destination, expected, worktree: false)
      unless inventory(source, worktree: worktree) == expected
        raise InvalidState, "hard reset: source changed before archival #{source}"
      end
      if File.exist?(destination) || File.symlink?(destination)
        raise InvalidState, "hard reset: incomplete/changed archive #{destination}" unless inventory(destination) == expected
        return
      end
      temporary = "#{destination}.#{SecureRandom.hex(8)}.partial"
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
      copy_entry(source, temporary)
      raise InvalidState, "hard reset: archive verification failed #{source}" unless
        inventory(temporary) == expected && inventory(source, worktree: worktree) == expected
      File.rename(temporary, destination)
      sync(File.dirname(destination))
    end

    # Preserves HEAD history and every index stage object in an independent bare
    # object store, plus the exact index and split-index dependency. Returns the
    # recovery manifest. No shared Git object/config/ref is written or collected.
    def preserve_git(entry, destination)
      path = entry.fetch("path")
      head = git(path, "rev-parse", "HEAD").strip
      stages = git(path, "ls-files", "--stage", "-z")
      ids = stages.split("\0").map do |row|
        match = row.match(/\A(\d{6}) ([0-9a-f]{40}) [0-3]\t/n)
        raise InvalidState, "hard reset: unsupported index entry" unless match && match[1] != "160000"
        match[2] unless match[2] == "0" * 40
      end.compact
      source_index = git(path, "rev-parse", "--path-format=absolute", "--git-path", "index").strip
      shared = git(path, "rev-parse", "--shared-index-path").strip
      shared = File.expand_path(shared, path) unless shared.empty?
      if File.exist?(destination)
        verify_git(entry, destination, head, stages)
        return inventory(destination)
      end
      temporary = "#{destination}.#{SecureRandom.hex(8)}.partial"
      FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
      git(nil, "init", "--bare", "--template=", temporary)
      pack = command(path, ["git", "--no-replace-objects", "pack-objects", "--stdout", "--revs"],
        input: ([head, entry.fetch("base_sha"), *ids].uniq.join("\n") + "\n")).stdout
      command(temporary, ["git", "index-pack", "--strict", "--stdin"], input: pack)
      File.binwrite(File.join(temporary, "HEAD"), "#{head}\n")
      preserve(source_index, File.join(temporary, "index"), inventory(source_index)) if File.file?(source_index)
      preserve(shared, File.join(temporary, File.basename(shared)), inventory(shared)) unless shared.empty?
      verify_git(entry, temporary, head, stages)
      # Sync every generated object/administration file before publishing it.
      inventory(temporary).each do |relative, row|
        absolute = relative == "." ? temporary : File.join(temporary, relative)
        File.open(absolute, row["type"] == "file" ? "rb" : "r") { |file| file.fsync } unless row["type"] == "link"
      end
      File.rename(temporary, destination)
      sync(File.dirname(destination))
      inventory(destination)
    end

    # Checks an independently stored Git identity/index/object closure against
    # original observations, without consulting shared objects or changing state.
    def verify_git(entry, directory, head, stages)
      raise InvalidState, "hard reset: recovery store borrows shared objects" if
        File.exist?(File.join(directory, "objects", "info", "alternates"))
      actual = git(nil, "--git-dir=#{directory}", "--work-tree=#{entry.fetch('path')}", "ls-files", "--stage", "-z")
      raise InvalidState, "hard reset: recovery index differs" unless actual == stages &&
        git(nil, "--git-dir=#{directory}", "rev-parse", "HEAD").strip == head
      git(nil, "--git-dir=#{directory}", "fsck", "--full", "--no-reflogs")
    end

    private

    # Copies a single lstat-qualified tree without following links, preserving
    # bytes and POSIX modes. I/O errors propagate; no recursive removal occurs.
    def copy_entry(source, destination)
      stat = File.lstat(source)
      if stat.symlink?
        File.symlink(File.readlink(source), destination)
        File.lchmod(stat.mode & 0o7777, destination) if (File.lstat(destination).mode & 0o7777) != (stat.mode & 0o7777)
      elsif stat.directory?
        Dir.mkdir(destination, 0o700)
        Dir.children(source).sort.each { |name| copy_entry(File.join(source, name), File.join(destination, name)) }
        File.chmod(stat.mode & 0o7777, destination)
        sync(destination)
      elsif stat.file?
        File.open(destination, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |output|
          File.open(source, File::RDONLY | File::NOFOLLOW) { |input| IO.copy_stream(input, output) }
          output.chmod(stat.mode & 0o7777)
          output.flush
          output.fsync
        end
      else
        raise InvalidState, "hard reset: nonpreservable entry #{source}"
      end
    end

    # Syncs a published directory; unsupported synchronization remains a failure.
    def sync(path)
      File.open(path) { |directory| directory.fsync }
    end

    # Executes byte-safe offline Git with lazy fetching/index refresh disabled.
    # Native spawn/status errors propagate as a reset refusal.
    def command(path, argv, input: "")
      result = @transport.call(argv, cwd: path, input: input, binmode: true,
        env: { "GIT_OPTIONAL_LOCKS" => "0", "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0" })
      raise InvalidState, "hard reset: #{argv[1]} failed: #{result.stderr.strip}" unless result.success?
      result
    end

    # Returns unmodified command stdout for index/object preservation.
    def git(path, *args)
      command(path, ["git", *args]).stdout
    end
  end
end
