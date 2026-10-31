# frozen_string_literal: true

module AgentCodingTool
  # Resolves only the tunnel startup credential without changing ENV or files.
  class TunnelCredential
    # Safe local refusal codes; neither file contents nor parser messages escape.
    class Refused < StandardError; end

    # Returns a bounded printable credential from process precedence or one exact
    # canonical operator .env. No discovery, interpolation, shell or prompt occurs.
    # Missing, malformed, empty, unreadable or unsafe inputs raise fixed Refused.
    def self.resolve(path, environment: ENV)
      supplied = environment["OPENAI_TUNNEL_KEY"]
      return validate(supplied) if supplied && !supplied.strip.empty?

      raise Refused, "credential.path" unless path.is_a?(String) && path.start_with?("/") &&
        File.realpath(path) == path && File.basename(path) == ".env"
      contents = File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        stat = file.stat
        raise Refused, "credential.unreadable" unless stat.file? && stat.uid == Process.uid &&
          stat.mode & 0o400 != 0 && stat.size <= 65_536
        file.read(65_537)
      end
      raise Refused, "credential.malformed" unless contents.valid_encoding? && !contents.include?("\0") && contents.bytesize <= 65_536
      require "dotenv"
      # Dotenv supports command substitution by default. Use its real parser with
      # substitutions disabled locally, including on unrelated entries. Never
      # modify Dotenv::Parser or load the file into the process environment.
      parser = Class.new(Dotenv::Parser) do
        # Returns no interpolators: .env is data, never executable startup code.
        def self.substitutions
          []
        end
      end
      selected = []
      remainder = contents.gsub(Dotenv::Parser::LINE) do
        match = Regexp.last_match
        value = match[:value].to_s.strip
        raise Refused, "credential.malformed" if ["'", '"'].include?(value[0]) &&
          !value.match?(/\A(['"])(?:\\.|(?!\1).)*\1\z/m)
        raise Refused, "credential.malformed" unless match[:value] || !match[:export]
        selected << match.to_s if match[:key] == "OPENAI_TUNNEL_KEY"
        ""
      end
      raise Refused, "credential.malformed" unless remainder.lines.all? { |line| line.strip.empty? || line.lstrip.start_with?("#") } && selected.length <= 1
      raise Refused, "credential.missing" if selected.empty?
      validate(parser.call(selected.first, overwrite: true).fetch("OPENAI_TUNNEL_KEY"))
    rescue SystemCallError, IOError
      raise Refused, "credential.unreadable", cause: nil
    rescue ArgumentError, EncodingError, KeyError, LoadError, SyntaxError
      raise Refused, "credential.malformed", cause: nil
    end

    # Returns the original value if it fits the client's pipe-era ASCII contract;
    # whitespace, control characters and oversize values raise a fixed refusal.
    def self.validate(value)
      raise Refused, "credential.invalid" unless value.is_a?(String) && value.bytesize.between?(1, 4096) &&
        value.bytes.all? { |byte| byte.between?(33, 126) }
      value
    end
  end
end
