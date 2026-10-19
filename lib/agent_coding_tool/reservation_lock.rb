# frozen_string_literal: true

require "fileutils"

module AgentCodingTool
  # Serializes scheduling and lifecycle writers with the existing launch lock.
  module ReservationLock
    # Yields a private, owned exclusive lock for data_root, returning the block's
    # value. A caller may pass its held IO to avoid recursive locking. Unsafe
    # paths, foreign files and competing holders raise InvalidState; IO errors
    # propagate. The borrowed lock stays open and locked for its caller.
    def self.synchronize(data_root, held: nil)
      root = "#{File.realpath(data_root)}-runs"
      cursor = root
      loop do
        raise InvalidState, "reservation: symlinked evidence path" if File.symlink?(cursor)
        break if cursor == File.dirname(cursor)

        cursor = File.dirname(cursor)
      end
      if File.exist?(root) && !File.directory?(root)
        raise InvalidState, "reservation: foreign evidence root"
      end
      FileUtils.mkdir_p(root, mode: 0o700)
      unless File.stat(root).uid == Process.uid && (File.stat(root).mode & 0o077).zero?
        raise InvalidState, "reservation: foreign evidence root"
      end
      path = File.join(root, "launch.lock")
      if File.symlink?(path) || (File.exist?(path) && !File.file?(path))
        raise InvalidState, "reservation: foreign/symlinked lock"
      end

      if held
        validate!(path, held)
        return yield held
      end

      File.open(path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        validate!(path, lock)
        yield lock
      end
    end

    # Checks path/IO identity, ownership, privacy and exclusivity before use.
    # Returns true or raises InvalidState for foreign or busy reservations.
    def self.validate!(path, lock)
      actual = File.lstat(path)
      opened = lock.stat
      unless actual.file? && opened.file? && actual.nlink == 1 &&
             [actual.dev, actual.ino] == [opened.dev, opened.ino] &&
             opened.uid == Process.uid && (opened.mode & 0o077).zero?
        raise InvalidState, "reservation: foreign/symlinked lock"
      end
      raise InvalidState, "reservation lock: launch/recovery reservation busy; retry" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

      true
    end
    private_class_method :validate!
  end
end
