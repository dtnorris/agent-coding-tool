# frozen_string_literal: true

require_relative "../no_git_execution"
require_relative "patch_capabilities"

module MemoryGit
  # Serial test composition, never a production environment-selected Git mode.
  # The scope owns mutable state; immutable skill objects have separate authority.
  module Session
    # Explicit composition for CLI.run callers: default immutable sources use
    # their read-only authority; every other request goes to the case transport.
    class Transport
      # Takes the sole mutable case authority; performs no IO or process startup.
      def initialize(world)
        @world = world
      end

      # Forwards exact command fields, preserving all result/exception semantics.
      def call(argv, **fields)
        position = argv.index("-C")
        source = argv.first == "git" && position && argv[position + 1] == Session.skill_root
        (source ? Session.skill_transport : @world).call(argv, **fields)
      end
    end

    class << self
      attr_reader :transport
      attr_reader :capture
      attr_accessor :skill_transport, :skill_root

      # Yields a case transport and restores its predecessor even on failure.
      # Concurrent replacement is refused; nested use of the same world is safe.
      def with(transport)
        previous = @transport
        raise Mismatch, "concurrent memory world replacement" if previous && !previous.equal?(transport)
        @transport = transport
        yield transport
      ensure
        @transport = previous
      end

      # Nests declared non-Git observations without capturing an original native
      # method. Restores the preceding adapter after refusal or assertion failure.
      def with_capture(capture)
        previous = @capture
        @capture = capture
        yield
      ensure
        @capture = previous
      end

      # Selects only a declared source read or the active case authority. Returns
      # nil outside composition; the process guard still refuses native execution.
      def for_command(argv)
        return unless argv.first == "git"
        source = argv.index("-C")
        return skill_transport if source && argv[source + 1] == skill_root && skill_transport
        transport
      end
    end
  end

  # Legacy constructor compatibility at the existing external command seam.
  # Explicit transport injection remains preferred. Unknown modeled operations
  # propagate Mismatch; there is no rescue or fallback from a selected world.
  module ComposedTransport
    # Forwards the entire request without interpreting product arguments/results.
    # Non-Git processes retain their real transport and require exact guard permits.
    def call(argv, **fields)
      transport = Session.for_command(argv)
      transport ? transport.call(argv, **fields) : super
    end
  end

  # Compatibility for production's direct non-Git capability probes. Only an
  # explicit fixture scope supplies observations; native execution stays guarded.
  module ComposedCapture
    # Delegates the exact argv/options to the current declared fixture adapter.
    # Unknown calls raise there; absence preserves normal Open3/guard behavior.
    def capture3(*argv, **options)
      Session.capture ? Session.capture.call(*argv, **options) : super
    end
  end
end

AgentCodingTool::NativeCommandTransport.prepend(MemoryGit::ComposedTransport)
Open3.singleton_class.prepend(MemoryGit::ComposedCapture)
