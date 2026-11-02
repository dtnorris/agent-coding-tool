# Strict Git observation contract

This is the shared observation interface for behavioral tests and suite selection.
The [zero-Git migration contract](../coverage/zero-git-migration.md) and the prepared
ACTD `plans/TST-33-45-fast-suite.txt` govern execution and acceptance. Earlier native
integration requirements are historical. Production continues to use real Git;
tests verify ACT's boundary contracts with finite authorities and independent
expected values. They do not establish conformance to an installed Git version.
This document grants no integration, publication or lifecycle authority.

## Selection and historical names

Preload the guard before test helpers or production, for example:

```sh
ruby -r./test/support/no_git_execution -rbundler/setup -Ilib:test test/git_contract/native_contract.rb
```

`native_contract.rb`, `NativeGitContract` and the `native_default` and
`native_integration` layer names are historical compatibility labels. No test,
bootstrap, setup, teardown or descendant may execute real Git. The complete
root-relative file/case inventory is [required_cases.json](required_cases.json).
The runner checks discovery and independent case evidence; a standalone focused
run is intermediate evidence, never full `test:all` acceptance. TST-45 owns that
integration, coverage and timing acceptance. Keep existing process isolation until
the runner owner verifies batching, global state and coverage together.

Fixtures build fresh memory worlds and materialize real files, modes, `.git`
pointers and backpointers. Set `TMPDIR` and optionally `ACT_GIT_CONTRACT_TMPDIR` to
an authorized writable fixture parent. Socket-dependent journeys also require a
root short enough for the platform socket limit and permission to bind sockets.
Failure of these requirements is a reported failure, never a skip or fallback.

## Stable observation interface

Require `observations.rb` directly; it loads neither Minitest nor shared fixtures.

```ruby
observation = GitContract::Observation.new(
  argv: ["git", "rev-parse", "HEAD"], cwd: "/fixture/repository",
  result: ["#{expected_sha}\n", "".b, true]
)
runner = GitContract::Replay.new([observation])
inspector = AgentCodingTool::RepoInspector.new(config, runner: runner)
# Invoke the real production operation with every required observation declared.
runner.verify!
```

`Observation` binds exact string argv, optional leading material environment,
cwd (including `nil`), binary stdin, timeout and execution options. It contains
either raw stdout/stderr plus termination facts, or an exception. `capture`
also accepts legacy boolean-success observations. `capture3` requires genuine
`Process::Status` or the declared `AgentCodingTool::CommandResult` value;
boolean-only records cannot invent exit/signal facts. No object impersonates
`Process::Status`, and modeled status creation starts no child.

Streams are copied, preserving bytes and encodings. `capture` returns boolean
success, including `nil` for a signal; `call` returns the production result value
with exact exit/signal facts. Missing executable/cwd exceptions stay exceptional.

Replay is ordered unless independent concurrent requests explicitly use
`ordered: false`. Matching/consumption is atomic and each expectation is used
once. Call `verify!` after successful operations and expected refusals. Unknown,
duplicate, wrong-order or changed-envelope requests and unused expectations raise
`UnexpectedObservation` outside `StandardError`; product refusal handlers cannot
turn a fixture mismatch into a passing negative case.

`ContractRecorder` records finite memory-world responses, with no native fallback.
Replay consistency alone is insufficient: cases assert independently chosen
semantic values, byte/mode oracles, state transitions and deliberate corruptions.
The rename-status fixture is hash-bound to a separately prepared golden NUL
transcript and admitted only for its exact independently checked index/file state.
Its historical native preparation does not execute Git during tests.

`GitContract::Native` is retained for generic **non-Git** transport controls only.
The guard admits exact hash-reviewed Ruby scripts, arguments, environment,
preloads and options through single-use permits. Binary pipes, genuine status,
spawn exceptions and a per-process-group watchdog remain real. The default
deadline is two seconds. Timeout kills/reaps the owned group and raises `IOError`
without recording a command response. This is no longer a Git transcript source.

## Independent contract matrix

Production parsers, authorization/refusal decisions and filesystem ownership
checks run unchanged. Model/replay substitutions occur only at external command
boundaries. Every listed identity retains its existing method suffix.

| Case (`test_` prefix) | Independent oracle and state effect | Deliberate fault or refusal |
| --- | --- | --- |
| `authoritative_refs_snapshot_and_dirty_state` | Chosen baseline, independently edited staged/unstaged/untracked files, local divergence and unchanged remote | Empty, duplicate, wrong-ref, invalid-SHA rows; falsely clean bytes; false success |
| `nul_status_parser_and_refusal` | Golden NUL rename pair and explicit expected paths/index-worktree flags, including newline/non-ASCII paths | Changed path bytes; mixed staged/working versions refuse |
| `linked_worktree_ownership` | Exact base/path/registry, materialized admin and physical backpointer | Foreign registry, wrong HEAD and physical backpointer corruption; restored positive |
| `commit_contents_modes_and_ref_movement` | Independently authored binary/plain bytes, executable/regular modes and deleted path; remote main advances, release stays fixed | Changed committed blob or mode refuses |
| `failures_and_exceptions` | Missing ref has empty streams/exit 2; nonrepository exit 128; actual absent-cwd/executable exceptions | Production classification and unchanged exceptional semantics |
| `strict_replay` | Fixed binary streams and false success | Wrong argv/cwd/order, missing/duplicate requests and boolean raw-status fabrication refuse |
| `concurrent_remote_requests` | Fixed independent ref rows; real scheduling and deduplication | Bounded rendezvous detects serialization; strict single consumption |
| `native_process_observer` | Actual permitted Ruby child emits fixed invalid-UTF-8/NUL bytes, exit 7 or TERM | Watchdog kills/reaps owned sleeping child; no fabricated timeout observation |
| `immutable_skill_object_read` | Authored immutable text/hash and exact offline env/revision/path; dirty text ignored | Missing pinned object exit 128 and `InvalidState`; replay preserves classification |

Apply-handoff contracts retain independent physical bytes/modes and index
snapshots, parent/path effects, exact consent counts and corruption matrices.
`test_complete_run_decision_matrices_with_native_parity` is a retained historical
identity, not a live-native parity claim. Retry contracts exercise real durable
closeout/state/evidence and physical backpointer corruption against the shared
world; no empty Open3 recording is used as ownership proof. Feedback/progress
contracts qualify real non-Git status/streams, descendants, coverage census,
case accounting and failure presentation using bounded synthetic fixtures.

## Identity and fixture-entry accounting

The ordinary publisher class is now `PublisherDecisionTest`. For every entry
under `test/publisher_test.rb`, old `PublisherTest#test_SUFFIX` maps one-to-one to
`PublisherDecisionTest#test_SUFFIX`, preserving all 16 bodies and assertions.
The integration file retains its `PublisherTest` class and identities. This
removes their collision without changing sibling manifest entries.

The earlier parallel-launch identity
`ParallelLaunchTest#test_explicit_parallel_launch_owns_distinct_roots_and_preserves_stale_checkpoint`
maps to
`ParallelLaunchTest#test_default_parallel_launch_owns_distinct_roots_and_preserves_stale_checkpoint`.
It retains separate prepared roots, active sibling checks and preserved stale
checkpoint assertions while covering the subsequently implemented default admission.

Default discovery is `test/**/*_test.rb`; integration discovery is
`test/integration/*_git_integration.rb`; contracts use `**/*_contract.rb` in this
directory. Fixed child/verifier fixtures and manual recipes are outside those
patterns. The opt-in `manual_parallel_native_sandbox.rb`,
`terminal_attempt_reproduction.rb`, `act24_continuity.rb`, `act24_worker.rb`,
`act24_recipe_checks.rb` and old profiling helpers are historical/manual tools,
not suite entrypoints or zero-Git acceptance evidence. Their external commands
must not be admitted into test discovery. Required inventory checks reject such
additions until their explicit migration and review. Inherited guards still
refuse undeclared execution; fixture executables grant no standalone authority.
