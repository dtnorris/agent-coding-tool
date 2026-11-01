# frozen_string_literal: true

require_relative "support/no_git_execution" unless ENV["ACT_NATIVE_SUITE"] == "1" && ENV["ACT_ORDINARY_SUITE"] != "1"
require_relative "support/memory_git/session"
require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "agent_coding_tool"

module TestHelpers
  # Immutable seed only. Consumers construct fresh authority with memory_repository;
  # shell-style copying of a seed directory is deliberately no longer supported.
  def self.git_seed
    @git_seed ||= MemoryGit::Template.files({ "file.txt" => "base\n" })
  end

  # Yields one fresh case world. Files and required faults are checked/cleaned by
  # the caller's fixture lifetime; no process or broker starts on this path.
  def with_memory_world(root)
    world = MemoryGit::PatchWorld.new(root: root)
    MemoryGit::Session.with(world) { yield world }
  ensure
    world&.verify!
  end

  # Builds independent ordinary/remote authority directly from an immutable seed.
  # Returns [checkout, remote]; unknown/colliding paths fail rather than copy Git.
  def memory_repository(world, path:, remote:, template: TestHelpers.git_seed)
    checkout = world.repository(path: path, template: template)
    upstream = world.remote(url: remote, from: checkout)
    FileUtils.mkdir_p(remote) if remote.start_with?(world.root + "/")
    world.connect(checkout, upstream)
    [checkout, upstream]
  end

  FakeInspector = Struct.new(:heads, :local_dirty, :remote_urls, keyword_init: true) do
    def snapshot(name, _spec)
      sha = heads.fetch(name)
      {
        "path" => "/repos/#{name}",
        "remote" => "origin",
        "remote_url" => remote_urls&.fetch(name, nil) || "git@github.com:example/#{name}.git",
        "branch" => "main",
        "pushed_sha" => sha,
        "local_head" => sha,
        "local_dirty" => !!local_dirty
      }
    end

    def pushed_heads(references)
      references.each_with_object({}) do |reference, resolved|
        repository = reference.fetch("name").split("/", 2).last
        key = [reference.fetch("remote_url"), reference.fetch("branch")]
        resolved[key] = heads.fetch(repository)
      end
    end

    def repository_authority(name, spec)
      [
        remote_urls&.fetch(name, nil) || "git@github.com:example/#{name}.git",
        spec.fetch("branch", "main")
      ]
    end
  end

  def with_workspace
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tasks"))
      FileUtils.mkdir_p(File.join(dir, "state", "prompts"))
      begin
        yield dir
      ensure
        FileUtils.remove_entry("#{dir}-runs") if File.directory?("#{dir}-runs") && !File.symlink?("#{dir}-runs")
      end
    end
  end

  def write_task(dir, id:, depends_on: [], repositories: { "alpha" => { "access" => "write" } },
                 title: "Task", worker_recommendation: nil)
    data = {
      "id" => id,
      "title" => title,
      "depends_on" => depends_on,
      "repositories" => repositories,
      "goal" => "Do the bounded thing.",
      "constraints" => ["Do not broaden scope."],
      "acceptance" => ["Focused tests pass."]
    }
    data["worker_recommendation"] = worker_recommendation if worker_recommendation
    File.write(File.join(dir, "tasks", "#{id}.yml"), YAML.dump(data))
  end

  def coordinator_for(dir, heads)
    AgentCodingTool::Coordinator.new(
      task_store: AgentCodingTool::TaskStore.new(File.join(dir, "tasks")),
      state_store: AgentCodingTool::StateStore.new(File.join(dir, "state")),
      repo_inspector: FakeInspector.new(heads: heads),
      prompt_renderer: AgentCodingTool::PromptRenderer.new,
      prompt_root: File.join(dir, "state", "prompts")
    )
  end
end

require_relative "coding_skill_support"
require_relative "native_test_support" if ENV["ACT_NATIVE_SUITE"] == "1" && ENV["ACT_ORDINARY_SUITE"] != "1"
