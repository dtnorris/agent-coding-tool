# frozen_string_literal: true

require "zlib"

# Small stored-member ZIP fixtures; no archiver, extraction or execution occurs.
module ZipFixture
  # Returns a classic ZIP containing the supplied name/binary-byte mapping.
  # All sizes/CRCs are real; only synthetic, bounded test members are supported.
  def self.build(members)
    body, directory = "".b, "".b
    members.each do |name, content|
      content = content.b
      checksum, size, offset = Zlib.crc32(content), content.bytesize, body.bytesize
      body << [0x04034b50, 20, 0, 0, 0, 0, checksum, size, size, name.bytesize, 0].pack("Vv5V3v2") << name.b << content
      directory << [0x02014b50, 20, 20, 0, 0, 0, 0, checksum, size, size,
        name.bytesize, 0, 0, 0, 0, 0, offset].pack("Vv6V3v5V2") << name.b
    end
    body + directory + [0x06054b50, 0, 0, members.length, members.length, directory.bytesize, body.bytesize, 0].pack("Vv4V2v")
  end

  # Inspects only bounded stored synthetic members without extracting paths.
  # Unexpected compression, size, CRC or entry paths raise before inspection.
  def self.inspect_members(bytes)
    members, offset, total = {}, 0, 0
    while bytes.byteslice(offset, 4) == "PK\x03\x04".b
      raise "fixture member limit" if members.length >= 8
      header = bytes.byteslice(offset + 4, 26).unpack("v5V3v2")
      _version, flags, method, _time, _date, crc, compressed, size, name_size, extra_size = header
      raise "fixture decompression limit" unless flags.zero? && method.zero? && compressed == size && size <= 65_536
      name = bytes.byteslice(offset + 30, name_size)
      raise "untrusted fixture entry" unless name.match?(/\A[A-Za-z0-9_.-]+\z/) && !%w[. ..].include?(name)
      content = bytes.byteslice(offset + 30 + name_size + extra_size, size)
      total += size
      raise "fixture size or CRC" unless total <= 131_072 && content.bytesize == size && Zlib.crc32(content) == crc
      members[name] = content
      offset += 30 + name_size + extra_size + size
    end
    members
  end
end
