# frozen_string_literal: true

module AgentCodingTool
  class PromptRenderer
    def render(task, snapshot, dependencies: [])
      writable = task.fetch("repositories").select { |_name, spec| spec.fetch("access") == "write" }
      read_only = task.fetch("repositories").select { |_name, spec| spec.fetch("access") == "read_only" }

      lines = []
      lines << "# #{task.fetch('id')}: #{task.fetch('title')}"
      lines << ""
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
