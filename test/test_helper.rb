# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "agent_coding_tool"
require_relative "coding_skill_support"

module TestHelpers
  def self.git_seed
    return @git_seed if @git_seed

    directory = Dir.mktmpdir("act-git-seed-")
    ordinary = File.join(directory, "ordinary")
    remote = File.join(directory, "remote.git")
    run = lambda do |*args, chdir: nil|
      _out, err, status = Open3.capture3("git", *args, **(chdir ? { chdir: chdir } : {}))
      raise "Git seed failed: #{err}" unless status.success?
    end
    run.call("init", "--initial-branch=main", ordinary)
    run.call("config", "user.email", "fixture@example.test", chdir: ordinary)
    run.call("config", "user.name", "Fixture", chdir: ordinary)
    File.write(File.join(ordinary, "file.txt"), "base\n")
    run.call("add", "file.txt", chdir: ordinary)
    run.call("commit", "-m", "base", chdir: ordinary)
    run.call("clone", "--bare", ordinary, remote)
    run.call("remote", "add", "origin", remote, chdir: ordinary)
    base, err, status = Open3.capture3("git", "rev-parse", "HEAD", chdir: ordinary)
    raise "Git seed failed: #{err}" unless status.success?
    Minitest.after_run { FileUtils.remove_entry(directory) }
    @git_seed = { root: directory, base: base.strip }.freeze
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
      yield dir
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
