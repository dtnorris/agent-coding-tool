# frozen_string_literal: true

# Finite repository observations shared with cold non-Git fixture processes.
module TestHelpers
  FakeInspector = Struct.new(:heads, :local_dirty, :remote_urls, keyword_init: true) do
    # Returns a finite repository snapshot; missing fixture identities raise.
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

    # Resolves declared references from fixture heads, raising on unknown names.
    def pushed_heads(references)
      references.each_with_object({}) do |reference, resolved|
        repository = reference.fetch("name").split("/", 2).last
        key = [reference.fetch("remote_url"), reference.fetch("branch")]
        resolved[key] = heads.fetch(repository)
      end
    end

    # Returns the configured URL/branch pair without filesystem or Git discovery.
    def repository_authority(name, spec)
      [
        remote_urls&.fetch(name, nil) || "git@github.com:example/#{name}.git",
        spec.fetch("branch", "main")
      ]
    end
  end
end
