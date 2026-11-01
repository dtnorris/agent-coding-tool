# frozen_string_literal: true

# Fixed Icebox stimuli at the public state-write boundary. The real reservation,
# state replacement and competing processes remain active. No fixture code path
# or program is supplied by the caller; only an owned barrier path is data.
require_relative '../child_processes'
root = ARGV.fetch(0)
if ENV['ACT19_REMOVE_PREPARE_GUARD']
  class AgentCodingTool::Coordinator
    # Negative control removes only the Icebox preparation refusal.
    def refuse_icebox!(_id, _state) = nil
  end
end
if ENV['ACT19_BARRIER']
  barrier = ENV.fetch('ACT19_BARRIER')
  raise 'foreign Icebox barrier' unless barrier == File.join(root, 'barrier')
  module IceboxWriteBarrier
    # Waits at a real state write while its caller holds the reservation; returns
    # the original write result. A lost release raises after the existing lease.
    def write(id, state)
      if id == 'TST-A'
        barrier = ENV.fetch('ACT19_BARRIER')
        File.write("#{barrier}.entered", 'entered')
        Timeout.timeout(10) { sleep 0.005 until File.file?("#{barrier}.release") }
      end
      super
    end
  end
  AgentCodingTool::StateStore.prepend(IceboxWriteBarrier)
end
entry = File.join(__dir__, 'launcher_cli.rb')
raise 'changed launcher bootstrap' unless Digest::SHA256.file(entry).hexdigest == ChildProcesses::HASHES.fetch('launcher_cli')
load entry
