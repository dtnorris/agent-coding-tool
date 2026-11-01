# frozen_string_literal: true

require_relative "test_helper"
require_relative "apply_handoff_fixture"

# Ordinary apply fixtures own memory authority and never execute Git.
module ApplyHandoffFixtures
  include TestHelpers
  include ApplyHandoffFixture

  # Yields fresh memory repositories; setup and verification failures propagate.
  def with_apply_repositories
    with_memory_world(@root) do |world|
      @memory_world = world
      @apply_checkouts = [@a, @b].to_h do |path|
        [path, memory_repository(world, path: path, remote: "#{path}.git").first]
      end
      yield
    end
  end

  # Records ignored fixture names in memory authority; unknown repos raise.
  def ignore_apply_path(path, relative)
    @apply_checkouts.fetch(path).ignored << relative
  end

  # Commits current nonignored fixture files in memory; invalid state raises.
  def commit_apply_fixture(path)
    checkout = @apply_checkouts.fetch(path)
    files = @memory_world.scan(checkout).reject { |relative, _entry| checkout.ignored.include?(relative) }
    @memory_world.build_commit(checkout, files: files, message: "fixture", advance: true)
  end

  # Removes only the named memory index entry, retaining worktree bytes.
  def remove_apply_index_path(path, relative)
    @apply_checkouts.fetch(path).index.delete(relative.b)
  end

  # Executes local fixture Git with optional stdin; returns stdout, raising on
  # unexpected failure. Mutations are confined to the disposable fixture.
  def git(path, *args, input: "")
    result = @memory_world.call(["git", *args], cwd: path, input: input)
    raise result.stderr unless result.success?
    result.stdout
  end

end
