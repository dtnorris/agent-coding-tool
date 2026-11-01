# frozen_string_literal: true

require_relative 'memory_git/patch_capabilities'
require_relative '../git_contract/observations'

# Records finite world responses for production/replay equivalence. It never
# falls back to native Git; genuine non-Git transport controls remain separate.
class ContractRecorder
  attr_reader :observations, :world, :checkout, :upstream

  # Owns one fresh independent modeled authority and all raw observations.
  def initialize(world, checkout, upstream)
    @world, @checkout, @upstream, @observations = world, checkout, upstream, []
  end

  # Preserves exact argv/cwd/stdin, modeled termination facts and native filesystem
  # exceptions. Unknown capabilities escape; no Process::Status is fabricated.
  def capture3(*argv, chdir: nil, stdin_data: '')
    File.stat(chdir) if chdir && !File.exist?(chdir)
    environment = argv.first.is_a?(Hash) ? argv.shift : {}
    original = environment.empty? ? argv : [environment, *argv]
    response = world.call(argv, cwd: chdir, env: environment, input: stdin_data)
    @observations << GitContract::Observation.new(argv: original, cwd: chdir, stdin_data: stdin_data, result: response.to_ary)
    response.to_ary
  rescue Errno::ENOENT => error
    @observations << GitContract::Observation.new(argv: argv, cwd: chdir, stdin_data: stdin_data, exception: error)
    raise
  end

  # Supplies the renderer/CommandRunner boolean seam from those same raw facts.
  def capture(*argv, chdir: nil)
    output, error, status = capture3(*argv, chdir: chdir)
    [output, error, status.success?]
  end
end

# The one rename-status state uses separately native-prepared raw NUL bytes.
# It is admitted only after independently comparing every physical/index entry.
module ContractRenameStatus
  PATH = File.join(__dir__, 'memory_git/fixtures/contract-status.json').freeze
  HASH = 'c4908c99d3a80f49350588f062d438cd2c20b8bf3ce9b85f844b9570e5cf6b8c'

  private

  # All other status states use the existing model; this exact state retains the
  # rename source and binary path that the production parser must preserve.
  def command_status(checkout, arguments, input, settings)
    return super unless checkout.index.key?("moved\nname")
    expected_index = { "staged" => MemoryGit::Entry.new("index\n"), "unstaged" => MemoryGit::Entry.new("base\n"), "moved\nname" => MemoryGit::Entry.new("base\n") }
    expected_files = { "staged" => MemoryGit::Entry.new("working\n"), "unstaged" => MemoryGit::Entry.new("working\n"), "moved\nname" => MemoryGit::Entry.new("base\n"), "new\né".b => MemoryGit::Entry.new("\0\xff".b) }
    raise MemoryGit::Mismatch, 'contract rename state/envelope differs' unless checkout.index == expected_index && scan(checkout) == expected_files &&
      arguments == %w[--porcelain=v1 -z --untracked-files=all --ignore-submodules=none] && input.empty? && settings.empty? && Digest::SHA256.file(PATH).hexdigest == HASH
    row = JSON.parse(File.binread(PATH))
    result([row.fetch('stdout_hex')].pack('H*'), '', row.fetch('exitstatus'))
  end
end
