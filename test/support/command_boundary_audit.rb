# frozen_string_literal: true

require "digest"

# Source-only census of native effects and Git-capable constructor handoffs.
# This supplements guarded execution; it is not independent OS instrumentation.
module CommandBoundaryAudit
  EFFECTS = %i[capture3 popen3 spawn system exec popen fork daemon `].freeze
  CONSUMERS = %i[CommandRunner RepoInspector PromptRenderer Publisher Coordinator WorktreeManager
    Launcher DeliveryManager MultiDeliveryManager GitHubDeliveryProvider CleanupManager
    PreflightRecovery AttemptRecovery Checkpoint ApplyHandoff].freeze

  # Visits Ruby AST nodes with their enclosing method name; yields without
  # executing source. Parse/IO errors propagate instead of omitting a file.
  def self.walk(node, owner = nil, &block)
    return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)
    owner = node.children[0] if node.type == :DEFN
    owner = node.children[1] if node.type == :DEFS
    yield node, owner
    node.children.each { |child| walk(child, owner, &block) }
  end

  # Extracts exact source bytes for a node, retaining multiline call boundaries.
  # Returns a String; missing coordinates raise through Array#fetch.
  def self.snippet(lines, node)
    selected = lines[(node.first_lineno - 1)..(node.last_lineno - 1)].map(&:dup)
    selected[-1] = selected.fetch(-1).byteslice(0, node.last_column)
    selected[0] = selected.fetch(0).byteslice(node.first_column..)
    selected.join
  end

  # Returns native calls, including cached spawners, and constructor requests.
  # Bound hashes allow only reviewed native non-Git effects outside the seam.
  def self.scan(root)
    native, constructors = [], []
    (Dir.glob("lib/**/*.rb", base: root).sort + ["bin/agent-coding-tool"]).each do |path|
      source = File.read(File.join(root, path), encoding: "UTF-8")
      lines = source.lines
      walk(RubyVM::AbstractSyntaxTree.parse(source)) do |node, owner|
        receiver, method = %i[CALL QCALL].include?(node.type) ? node.children[0, 2] : [nil, nil]
        method = node.children[0] if %i[FCALL VCALL].include?(node.type)
        effect = EFFECTS.include?(method) || %i[XSTR DXSTR].include?(node.type) ||
          (method == :method && snippet(lines, node).match?(/:(?:#{EFFECTS.reject { |name| name == :` }.join('|')})\b/)) ||
          (method == :call && receiver&.type == :IVAR && receiver.children[0] == :@spawner)
        if effect
          text = snippet(lines, node)
          native << { "path" => path, "method" => owner.to_s, "source" => text,
            "sha256" => Digest::SHA256.hexdigest(text) }
        end
        constant = receiver.children.last if receiver && %i[CONST COLON2 COLON3].include?(receiver.type)
        if method == :new && CONSUMERS.include?(constant)
          constructors << { "path" => path, "method" => owner.to_s, "source" => snippet(lines, node) }
        end
      end
    end
    { "native" => native, "constructors" => constructors }
  end
end
