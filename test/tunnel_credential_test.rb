# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# Synthetic files only; the operator's .env and real credential are never inputs.
class TunnelCredentialTest < Minitest::Test
  SENTINEL = "ACT29_SYNTHETIC_CREDENTIAL_7fQ9"

  # Creates a canonical private fixture .env and saves the ambient environment.
  def setup
    @temporary = File.realpath(Dir.mktmpdir("act-credential-"))
    @path = File.join(@temporary, ".env")
    @environment = ENV.to_h
  end

  # Removes only synthetic inputs; verifies resolution did not mutate ENV.
  def teardown
    assert @environment == ENV.to_h, "credential resolution changed the process environment"
    FileUtils.remove_entry(@temporary)
  end

  # Resolves synthetic bytes and verifies original bytes and mode are preserved.
  def resolve(contents, environment: {})
    File.write(@path, contents, perm: 0o600)
    mode = File.stat(@path).mode
    result = AgentCodingTool::TunnelCredential.resolve(@path, environment: environment)
    assert_equal contents, File.binread(@path)
    assert_equal mode, File.stat(@path).mode
    result
  end

  # Exercises the real gem with quoted values and explicit process precedence;
  # blanks fall back, while invalid nonblank process values fail closed.
  def test_dotenv_quotes_precedence_and_explicit_path
    [SENTINEL, "'#{SENTINEL}'", '"' + SENTINEL + '"'].each do |entry|
      assert_equal SENTINEL, resolve("OPENAI_TUNNEL_KEY=#{entry}\nUNRELATED=value\n")
    end
    assert_equal "process-value", AgentCodingTool::TunnelCredential.resolve("/absent/.env", environment: { "OPENAI_TUNNEL_KEY" => "process-value" })
    assert_equal SENTINEL, resolve("OPENAI_TUNNEL_KEY=#{SENTINEL}\n", environment: { "OPENAI_TUNNEL_KEY" => " \t" })
    error = assert_raises(AgentCodingTool::TunnelCredential::Refused) do
      resolve("OPENAI_TUNNEL_KEY=#{SENTINEL}", environment: { "OPENAI_TUNNEL_KEY" => "bad value" })
    end
    assert_equal "credential.invalid", error.message
    assert_raises(AgentCodingTool::TunnelCredential::Refused) { AgentCodingTool::TunnelCredential.resolve(".env", environment: {}) }
    other = File.join(@temporary, "elsewhere")
    Dir.mkdir(other)
    Dir.chdir(other) { assert_equal SENTINEL, resolve("OPENAI_TUNNEL_KEY=#{SENTINEL}\n") }
  end

  # No interpolation, command execution, global dotenv loading or unrelated
  # credential propagation occurs. The ordinary execution guard also forbids exec.
  def test_dotenv_is_data_and_only_requested_key_is_returned
    contents = "# Synthetic only\nUNRELATED=$(touch #{@temporary}/forbidden)\n" +
      "OPENAI_TUNNEL_KEY='#{SENTINEL}'\nOTHER_SECRET=unrelated-sentinel\n"
    assert_equal SENTINEL, resolve(contents)
    refute File.exist?(File.join(@temporary, "forbidden"))
    assert_equal '$(false)', resolve("OPENAI_TUNNEL_KEY='$(false)'\n")
    assert_equal '$UNDEFINED', resolve('OPENAI_TUNNEL_KEY="$UNDEFINED"' + "\n")
  end

  # Missing, empty, malformed, duplicated, unreadable and symlinked credentials
  # return fixed actionable codes without their values or a prompt.
  def test_invalid_inputs_are_fixed_and_do_not_prompt
    ["UNRELATED=value\n", "OPENAI_TUNNEL_KEY=\n", "OPENAI_TUNNEL_KEY=' '\n",
      "OPENAI_TUNNEL_KEY='unterminated\n", "OPENAI_TUNNEL_KEY=bad value\n",
      "OPENAI_TUNNEL_KEY=#{SENTINEL}\nnot a dotenv entry\n",
      "OPENAI_TUNNEL_KEY=#{SENTINEL}\nOPENAI_TUNNEL_KEY=duplicate\n", "OPENAI_TUNNEL_KEY=bad\0entry"].each do |contents|
      error = assert_raises(AgentCodingTool::TunnelCredential::Refused) { resolve(contents) }
      assert_match(/\Acredential\.(missing|invalid|malformed)\z/, error.message)
      refute_includes error.message, SENTINEL
    end
    File.chmod(0o000, @path)
    assert_equal "credential.unreadable", assert_raises(AgentCodingTool::TunnelCredential::Refused) {
      AgentCodingTool::TunnelCredential.resolve(@path, environment: {})
    }.message
    File.chmod(0o600, @path)
    linked = File.join(@temporary, "linked")
    Dir.mkdir(linked)
    File.symlink(@path, File.join(linked, ".env"))
    assert_raises(AgentCodingTool::TunnelCredential::Refused) {
      AgentCodingTool::TunnelCredential.resolve(File.join(linked, ".env"), environment: {})
    }
    assert_raises(AgentCodingTool::TunnelCredential::Refused) {
      AgentCodingTool::TunnelCredential.resolve(File.join(@temporary, "missing", ".env"), environment: {})
    }
  end

  # Reproduces the preserved sanitizer's opaque-error defect without claiming its
  # actual Mac trigger. New local resolution returns a fixed space-free reason.
  def test_preserved_opaque_reason_and_safe_replacement
    original = "invalid runtime credential entry"
    sanitized = original.match?(/\A[a-z0-9._-]{1,160}\z/) ? original : "ValueError"
    assert_equal "ValueError", sanitized
    error = assert_raises(AgentCodingTool::TunnelCredential::Refused) { resolve("OPENAI_TUNNEL_KEY=' '\n") }
    assert_equal "credential.invalid", error.message
    out, err = StringIO.new, StringIO.new
    status = AgentCodingTool::CLI.run(["evidence", "open", "--grant", "/absent/grant.json", "--session", "/absent/session",
      "--env-file", @path, "--client", "/absent/client", "--runtime-dir", "/absent/runtime"], out: out, err: err)
    assert_equal 2, status
    assert_empty out.string
    assert_includes err.string, "credential.invalid"
    assert_includes err.string, "no secret prompt"
    refute_includes err.string, SENTINEL
  end
end
