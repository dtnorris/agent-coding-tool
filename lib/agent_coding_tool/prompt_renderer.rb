# frozen_string_literal: true

require "digest"
require "open3"
require "yaml"

module AgentCodingTool
  # Builds worker prompts with verified canonical guidance and existing task rules.
  class PromptRenderer
    SKILL_PATH = "skills/karpathy-manning-dtnorris-guidelines/SKILL.md"
    SKILL_IDENTITY = {
      "revision" => "e4e92e678b567ceaabe9c9d9c94215f6729099ba",
      "sha256" => "5337876cc23dfc7961d21fba3ed01dab50adef98991e02e244b3512f19198982"
    }.freeze
    PLANNING_SKILL_PATH = "skills/agentic-task-planning/SKILL.md"
    PLANNING_SKILL_IDENTITY = {
      "revision" => "358f7f28ac6f9205227c0378cbf6bb99ad63a179",
      "sha256" => "8a726b39a53bb43deebfc3ae81bd70cb657bada4ad69ac83afe35d88539fc009"
    }.freeze
    SKILL_ROOT = File.expand_path("../../../agent-skills", __dir__)

    # Uses a sibling Git checkout and immutable pin; optional inputs isolate tests.
    # Returns a renderer; source errors are deferred until render, not status reads.
    def initialize(skill_root: SKILL_ROOT, skill_identity: SKILL_IDENTITY,
                   planning_skill_identity: PLANNING_SKILL_IDENTITY)
      @skill_root = skill_root
      @skill_identity = skill_identity.dup.freeze
      @planning_skill_identity = planning_skill_identity.dup.freeze
    end

    # Returns the revision/fingerprint recorded in preparation state; no I/O.
    def skill_identity = @skill_identity

    # Returns the planning revision/fingerprint for opted-in preparation; no I/O.
    def planning_skill_identity = @planning_skill_identity

    # Returns the complete prompt for task/snapshot/dependencies, or raises
    # InvalidState before returning any prompt if pinned guidance cannot load.
    def render(task, snapshot, dependencies: [])
      skill = coding_skill
      writable = task.fetch("repositories").select { |_name, spec| spec.fetch("access") == "write" }
      read_only = task.fetch("repositories").select { |_name, spec| spec.fetch("access") == "read_only" }

      lines = []
      lines << "# #{task.fetch('id')}: #{task.fetch('title')}"
      lines << ""
      lines << "## Canonical coding guidelines"
      lines << ""
      lines << "Source: dtnorris/agent-skills / #{SKILL_PATH}"
      lines << "Revision: #{skill_identity.fetch('revision')}"
      lines << "SHA-256: #{skill_identity.fetch('sha256')}"
      lines << "Apply the complete canonical skill below. Task-specific requirements, safety constraints, Git restrictions and acceptance criteria take precedence."
      lines << "<!-- Begin canonical SKILL.md -->"
      lines << skill
      lines << "<!-- End canonical SKILL.md -->"
      lines << ""
      append_planning_guidance(lines) if task["planning_guidance"] == "required"
      lines << "Use the connected GitHub integration for repository access."
      lines << "For GitHub reads, prefer the connected GitHub tools/API. Do not open github.com in the cloud browser when the connected integration can perform the required repository read."
      lines << "Do not request GitHub website-access permission merely to inspect repositories, branches, commits, files, or pushed heads."
      lines << "If a required GitHub operation is unavailable through the connected tooling, report that limitation rather than silently switching to the browser."
      lines << "Unless a task-specific constraint explicitly restricts reads, you may inspect other connected GitHub repositories for prerequisites and context. The repository lists below are not an exhaustive read allowlist."
      lines << ""
      lines << "The pushed branch heads recorded below are the preparation snapshot. Refresh these pushed heads before doing any work and again before finalizing."
      lines << "Writable repositories: if any pushed head differs from the preparation snapshot, stop and report STALE INPUT rather than silently continuing. A new preparation (with explicit retry if an outcome was recorded) is required."
      lines << "Read-only repositories: if a pushed head differs, refresh that repository to the new pushed head and re-inspect and reconcile any materially affected findings before finalizing. Unrelated read-only head movement alone does not require an abort. Preserve the preparation snapshot as provenance and report the refreshed heads and any effect on your conclusions in the handoff."
      lines << "Repository names below are logical task keys / local checkout identities, not necessarily GitHub repository names. Verify each pushed head using its recorded remote_url and branch; do not infer the remote repository from the logical key or local path."
      lines << ""
      snapshot.each do |name, repo|
        lines << "- #{name}"
        lines << "  - path: #{repo.fetch('path')}"
        lines << "  - remote_url: #{repo.fetch('remote_url')}"
        lines << "  - branch: #{repo.fetch('branch')}"
        lines << "  - pushed_sha: #{repo.fetch('pushed_sha')}"
      end
      lines << ""
      append_repo_section(lines, "Writable repositories", writable)
      append_repo_section(lines, "Read-only repositories", read_only)
      lines << "Only the repositories designated writable above may be modified for this task. Other connected repositories, including the task-data repository, may be read when needed; reading one does not grant write authority."
      lines << "Do not commit, push, create a PR, or otherwise mutate GitHub."
      lines << "Do not broaden write scope or override explicit task-specific read restrictions. If the task cannot be completed correctly within the stated boundary, report the dependency or compatibility defect instead."
      lines << ""
      lines << "## Implementation checkpoint"
      lines << ""
      if CheckpointPolicy.required?(task)
        lines << "After a coherent code change or executable edit script passes focused validation, preserve it before full-suite, coverage, lint, dependency, benchmark or runtime gates. Ask the operator to run `act checkpoint record TASK --workspace PATH` from the host on the complete local implementation (or supply `--artifact PATH` for an exact patch). ACT verifies content, changed files and applicability to the prepared writable baseline in private run evidence. Run `act checkpoint gate TASK --workspace PATH -- COMMAND` for each expensive gate; refresh after edits and verify before final handoff. Focused-test success remains your report, separate from ACT's verified preservation. A checkpoint is recovery evidence, not CANDIDATE, COMPLETE or permission to publish. Browser-only work cannot be host-verified until its complete implementation is available locally; report that limit instead of claiming a checkpoint."
      else
        policy = task.fetch("checkpoint")
        lines << "Checkpoint exempt (#{policy.fetch('category')}): #{policy.fetch('reason')}"
      end
      lines << ""
      append_test_performance(lines) if !writable.empty? && CheckpointPolicy.required?(task)
      append_dependencies(lines, dependencies)
      lines << "## Goal"
      lines << ""
      lines << task.fetch("goal", task.fetch("title")).to_s.strip
      lines << ""
      append_list(lines, "Constraints", task.fetch("constraints", []))
      append_list(lines, "Acceptance", task.fetch("acceptance", []))
      lines << "## Documentation discipline"
      lines << ""
      lines << "- Before adding Markdown, inspect relevant existing docs and canonical code contracts. Update an authoritative document when it can capture the change."
      lines << "- Add a new document when existing docs cannot serve a distinct public or cross-repository contract, architectural decision, safety invariant, operator procedure, required specification, or audience. State its relationship to existing authority; link to normative rules instead of copying them, and distinguish binding contracts from examples."
      lines << "- Preserve lasting rationale, responsibility boundaries, guarantees, compatibility, and operational consequences in proportion to the change. Code and tests alone may suffice. Avoid Markdown that retells control flow or tests, and keep patch notes, test summaries, temporary analysis, and progress in the handoff or existing outcome records."
      lines << "- Explicit task documentation and safety requirements take precedence. In the final handoff, briefly explain the enduring purpose of each new Markdown file or summarize relevant updates to existing docs."
      lines << ""
      lines.join("\n").rstrip + "\n"
    end

    private

    # Reads only the pinned commit's blob, never the working file or moving HEAD.
    # Returns unchanged UTF-8 text; missing objects, bad metadata or digest raise
    # InvalidState. Lazy fetching and replacement objects are disabled for offline
    # integrity checks, including in partial clones.
    def coding_skill
      canonical_skill(SKILL_PATH, skill_identity, "karpathy-manning-dtnorris-guidelines", "coding skill")
    end

    # Returns unchanged text for one fixed canonical source/pin, or InvalidState
    # for unavailable objects, invalid UTF-8/metadata or altered bytes. No cache,
    # working-tree fallback, replacement objects or network retrieval is allowed.
    def canonical_skill(path, identity, name, label)
      unless identity.is_a?(Hash) && identity.length == 2 && (identity.keys - %w[revision sha256]).empty?
        raise InvalidState, "#{label}: malformed pinned identity"
      end
      revision, fingerprint = identity.values_at("revision", "sha256")
      unless revision.is_a?(String) && revision.match?(/\A[0-9a-f]{40}\z/) &&
             fingerprint.is_a?(String) && fingerprint.match?(/\A[0-9a-f]{64}\z/)
        raise InvalidState, "#{label}: malformed pinned identity"
      end
      unless File.directory?(@skill_root) && File.exist?(File.join(@skill_root, ".git"))
        raise InvalidState, "#{label}: missing Git checkout: #{@skill_root}"
      end
      content, error, status = Open3.capture3(
        { "GIT_NO_LAZY_FETCH" => "1", "GIT_TERMINAL_PROMPT" => "0" },
        "git", "--no-replace-objects", "-C", @skill_root,
        "cat-file", "blob", "#{revision}^{commit}:#{path}"
      )
      raise InvalidState, "#{label}: pinned source unavailable (#{revision}): #{error.strip}" unless status.success?
      unless Digest::SHA256.hexdigest(content) == fingerprint
        raise InvalidState, "#{label}: SHA-256 integrity mismatch (#{revision})"
      end
      content.force_encoding(Encoding::UTF_8)
      raise InvalidState, "#{label}: invalid UTF-8" unless content.valid_encoding?

      frontmatter = content.match(/\A---\n(.*?)^---\n/m)
      metadata = YAML.safe_load(frontmatter[1], aliases: false) if frontmatter
      unless metadata.is_a?(Hash) && metadata["name"] == name &&
             metadata["description"].is_a?(String) && !metadata["description"].strip.empty? &&
             metadata["license"] == "MIT" && !content[frontmatter.end(0)..].strip.empty?
        raise InvalidState, "#{label}: malformed SKILL.md metadata or empty body"
      end
      content
    rescue Psych::Exception, SystemCallError => error
      raise InvalidState, "#{label}: #{error.class}: #{error.message}"
    end

    # Appends verified full planning guidance before assignment outputs. Mutates
    # lines, returning it; InvalidState refuses rendering if the source is invalid.
    def append_planning_guidance(lines)
      skill = canonical_skill(PLANNING_SKILL_PATH, planning_skill_identity, "agentic-task-planning", "planning skill")
      lines << "## Canonical planning guidance (required)"
      lines << ""
      lines << "Source: dtnorris/agent-skills / #{PLANNING_SKILL_PATH}"
      lines << "Revision: #{planning_skill_identity.fetch('revision')}"
      lines << "SHA-256: #{planning_skill_identity.fetch('sha256')}"
      lines << "Read and substantively apply the complete unchanged skill below before producing plans, implementation task definitions, dependency graphs, acceptance requirements, ownership/integration plans or substantial plan revisions for this assignment, including ACTD registration. A link or nominal citation is insufficient. Task-specific requirements, safety constraints, Git restrictions and acceptance criteria take precedence."
      lines << "<!-- Begin canonical planning SKILL.md -->"
      lines << skill
      lines << "<!-- End canonical planning SKILL.md -->"
      lines << "Planning handoff: state the whole-journey outcome, acceptance owner and negative control; the next falsifiable gate and stop decision; bounded work, dependencies, ownership and integration order; and baseline/recovery evidence, unknowns, remaining gates, cost/safety and publication authority. Scale detail to the assignment."
      lines << "Newly discovered substantial replanning does not authorize changing task YAML, preparation or scope. Preserve the diagnosis and prior evidence and hand off to the operator for explicit task revision and safe re-preparation (with --retry for a recorded non-complete outcome); follow applicable worker-recovery safeguards first. Registration may propose reviewable YAML artifacts only within the task's write authority, never automatically register tasks."
      lines << ""
    end

    def append_test_performance(lines)
      lines << "## Test performance"
      lines << ""
      lines << "For code or test changes, identify relevant test commands, established runtime limits and available baseline evidence before adding or materially changing tests. Planning-only and inspection-only work has no added test obligation. Task-specific test-command contracts, performance, coverage, runtime, benchmark and safety rules remain authoritative; preserve implementation checkpoints and operator gates."
      lines << "Respect absolute runtime ceilings and benchmark gates separately from reviewing incremental test cost: passing either does not establish the other. When practical, measure comparable before/after suite timings and report the incremental impact. Match command and selected suite, source baselines, environment/dependencies, worker count, coverage/runtime modes and contention conditions; use trustworthy comparable evidence rather than compulsory expensive reruns. Prefer repeated timings and medians when noisy, near a gate or material to acceptance. Full-suite growth of both at least 1 second and 10%, or at least 3 seconds regardless of percentage, is a provisional advisory review trigger, not a universal limit or automatic acceptance below it. Treat material growth as a reviewable cost; distinguish pre-existing debt or failing baseline, new cost, noise/contention, necessary added coverage and unavailable comparison. A failing baseline neither proves this change caused it nor permits unlimited added cost."
      lines << "Do not increase, remove, bypass or relax a committed test-runtime ceiling solely to pass validation. Any proposed exception requires explicit human authorization before implementation: supply the old limit and observed baseline, proposed limit and measured resulting runtime, why the cost is necessary, cheaper alternatives, and preserved test and safety guarantees. Existing task scope alone is not authorization. This is worker-prompt discipline and evidence-based human review, not independent machine enforcement."
      lines << "Prefer efficient fixtures and targeted validation while preserving meaningful regression tests, failure assertions/error classification, essential real-process integration coverage and all coverage/lint/dependency/benchmark/safety gates. Remove redundant fixture assertions, process startup, initialization, setup or validation only with equivalent behavioral guarantees. Raw run/assertion counts are not coverage. Do not hide contention, skip tests, report reduced counts from incomplete execution, alter timing boundaries or raise timeouts/thresholds to conceal failures."
      lines << "Report executed/passing, executed/failing, pre-existing failing baseline, not executed (missing runtime/dependencies/permissions), and executed without comparable timing evidence distinctly. Disclose missing or noncomparable measurements and provide reproducible operator-side validation/timing commands when needed. Never claim unexecuted suites passed; unavailable Ruby or another runtime alone need not block implementation."
      lines << ""
    end

    def append_dependencies(lines, dependencies)
      return if dependencies.empty?

      lines << "## Prerequisites (required COMPLETE)"
      lines << ""
      lines << "These are ACT preparation-time observations from local task state, not independent proof of pushed completion. Before work, read the corresponding task/state in the connected task-data repository and verify any substantive pushed evidence required by the task. Resolve the state path's checkout remote; later pushed heads may differ from the recorded completion snapshot. If pushed completion or required evidence is absent, stop with the precise prerequisite failure. Reading task data is permitted, but writing it is not authorized by this prompt."
      dependencies.each do |dependency|
        lines << "- #{dependency.fetch('id')}: ACT outcome #{dependency.fetch('outcome') || 'missing'}"
        lines << "  - local state: #{dependency.fetch('state_path')}"
        completion = dependency["completion_snapshot"]
        if completion.is_a?(Hash) && !completion.empty?
          lines << "  - ACT recorded completion pushed heads (provenance, verify independently):"
          completion.each do |name, repo|
            unless repo.is_a?(Hash) && %w[remote_url branch pushed_sha].all? { |field| repo[field].is_a?(String) && !repo[field].empty? }
              lines << "    - #{name}: incomplete completion provenance; verify pushed evidence independently"
              next
            end

            lines << "    - #{name}: #{repo.fetch('remote_url')} #{repo.fetch('branch')} #{repo.fetch('pushed_sha')}"
          end
        else
          lines << "  - completion snapshot: unavailable; pushed completion evidence is unverified"
        end
      end
      lines << ""
    end

    def append_repo_section(lines, title, repos)
      return if repos.empty?

      lines << "## #{title}"
      lines << ""
      repos.each_key { |name| lines << "- #{name}" }
      lines << ""
    end

    def append_list(lines, title, items)
      return if items.empty?

      lines << "## #{title}"
      lines << ""
      items.each { |item| lines << "- #{item}" }
      lines << ""
    end
  end
end
