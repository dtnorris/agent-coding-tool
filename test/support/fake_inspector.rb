# frozen_string_literal: true

# Finite repository observations shared by test cases and cold CLI fixtures.
# Loading these data helpers does not install a test runner or create resources.
module TestHelpers
  # Stores heads, dirtiness and optional remotes for deterministic repository reads.
  FakeInspector = Struct.new(:heads, :local_dirty, :remote_urls, keyword_init: true) do
    # Returns snapshot facts for a declared repository; unknown names raise KeyError.
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

    # Maps requested authorities to fixture heads; missing fields or names raise KeyError.
    def pushed_heads(references)
      references.each_with_object({}) do |reference, resolved|
        repository = reference.fetch("name").split("/", 2).last
        key = [reference.fetch("remote_url"), reference.fetch("branch")]
        resolved[key] = heads.fetch(repository)
      end
    end

    # Returns the configured remote and branch, using the existing fixture defaults.
    def repository_authority(name, spec)
      [
        remote_urls&.fetch(name, nil) || "git@github.com:example/#{name}.git",
        spec.fetch("branch", "main")
      ]
    end
  end
end
