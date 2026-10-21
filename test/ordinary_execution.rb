# frozen_string_literal: true

# Test-only dependency boundary, preloaded before inherited RUBYOPT and setup.
# All Ruby child creation is forbidden here, including Ruby workers. Native
# selections run in separate interpreters without this preload. This enforces
# the repository's Ruby execution paths, not an OS sandbox for arbitrary FFI.
module OrdinaryExecution
  # Escapes production StandardError refusal handlers so execution cannot become
  # a plausible command failure. Minitest reports it as a failing gate.
  class ProhibitedExecution < Exception; end

  # Raises before a process/pipe entry can execute; accepts a diagnostic label.
  def self.refuse!(operation)
    raise ProhibitedExecution, "ordinary suite prohibits external execution: #{operation}"
  end

  # Rejects Ruby's implicit pipe-open syntax, retaining ordinary file I/O.
  # Returns nil for file paths; raises ProhibitedExecution for pipe paths.
  def self.check_path!(path)
    refuse!("pipe open") if path.is_a?(String) && path.start_with?("|")
  end

  # Covers IO helpers whose C implementations can open a child internally,
  # without an observable Process.spawn call. File I/O still uses native Ruby.
  module PipeReads
    %i[read binread readlines foreach write binwrite].each do |operation|
      define_method(operation) do |path, *arguments, **options, &block|
        OrdinaryExecution.check_path!(path)
        super(path, *arguments, **options, &block)
      end
    end
  end

  # Kernel.open accepts implicit subprocess pipes; File.open does not.
  module PipeOpen
    # Opens a normal file using the original method, or refuses a pipe first.
    # File I/O errors propagate unchanged.
    def open(path, *arguments, **options, &block)
      OrdinaryExecution.check_path!(path)
      super
    end
  end

  IO.singleton_class.prepend(PipeReads)
  Kernel.prepend(PipeOpen)
  Kernel.singleton_class.prepend(PipeOpen)
  ENTRIES = %i[system spawn exec fork _fork daemon ` popen].freeze

  # Observes native entries rather than replacing Open3, so stubs cannot conceal
  # captured originals or lower-level fallback. Fork is refused before a child
  # exists; no applicable ordinary descendant can drop the inherited boundary.
  TRACE = TracePoint.new(:c_call) do |event|
    next unless ENTRIES.include?(event.method_id)

    kernel = event.defined_class == Kernel || event.self.equal?(Kernel)
    process = event.self.equal?(Process) || (event.self.is_a?(Module) && event.self.name == "PTY")
    io = event.self.is_a?(Class) && event.self <= IO
    if ((kernel || process) && %i[system spawn exec fork _fork daemon `].include?(event.method_id)) ||
       (io && event.method_id == :popen)
      OrdinaryExecution.refuse!(event.method_id)
    end
  end
  TRACE.enable
end
