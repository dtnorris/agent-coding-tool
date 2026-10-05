# frozen_string_literal: true

module AgentCodingTool
  class PromptRenderer
    def render(task, snapshot)
      writable = task.fetch("repositories").select { |_name, spec| spec.fetch("access") == "write" }
      read_only = task.fetch("repositories").select { |_name, spec| spec.fetch("access") == "read_only" }

      lines = []
      lines << "# #{task.fetch('id')}: #{task.fetch('title')}"
      lines << ""
      lines << "Use the connected GitHub account."
      lines << ""
      lines << "Work from the exact current pushed branch state recorded below. Refresh these pushed heads before doing any work. If any head differs, stop and report STALE INPUT rather than silently continuing."
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
      lines << "Do not commit, push, create a PR, or otherwise mutate GitHub."
      lines << "Do not broaden repository scope. If the task cannot be completed correctly within the stated boundary, report the dependency or compatibility defect instead."
      lines << ""
      lines << "## Goal"
      lines << ""
      lines << task.fetch("goal", task.fetch("title")).to_s.strip
      lines << ""
      append_list(lines, "Constraints", task.fetch("constraints", []))
      append_list(lines, "Acceptance", task.fetch("acceptance", []))
      lines.join("\n").rstrip + "\n"
    end

    private

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
