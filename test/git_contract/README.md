# Strict Git observation contract

This is the shared observation interface for behavioral test migrations
(TST-17/18/19) and suite selection (TST-14/20). It supplements the native
integration requirements in the repository's [development documentation](../../README.md#development).
It grants no publication or integration authority and replaces no existing case
or native integration suite. The coverage inventory owned by TST-16 remains
authoritative for migration accounting.

## Selection

Run this standalone Ruby process, including fixture setup and Ruby startup in
elapsed measurements:

```sh
bundle exec ruby -Ilib:test test/git_contract/native_contract.rb
```

The filename deliberately avoids default `*_test.rb` discovery. The complete
named case inventory in `required_cases.json` follows TST-14's runner interface:
root-relative contract filename mapped to an array of `Class#test_method` names.
The runner selects `**/*_contract.rb` and refuses absent or omitted inventory.
Standalone execution remains independent of that runner. Do not require
integration files into this process. The five documented native integration files must retain separate
Ruby invocations. This suite launches only local Git/Ruby fixture processes,
never Codex. It does not establish installed-Codex/macOS sandbox qualification.

On a sandbox with unwritable system temporary directories, create a writable
temporary parent and set both `TMPDIR` and `ACT_GIT_CONTRACT_TMPDIR` to it. The
latter chooses the fixture parent without changing production configuration.
Fixtures use isolated Git configuration, SHA-1 objects, C locale, UTC, explicit
identity/dates, disabled hooks/signing for commits, and file-only transport.
They verify the newly created local origin before use. Git must support
`worktree list --porcelain -z` and `rev-parse --path-format=absolute`.

## Stable support interface

Require `test/git_contract/observations.rb` directly; it does not load Minitest,
shared test helpers, or production classes.

```ruby
observation = GitContract::Observation.new(
  argv: ["git", "rev-parse", "HEAD"], cwd: "/fixture/repository",
  result: ["#{expected_sha}\n", "".b, true]
)
runner = GitContract::Replay.new([observation])
inspector = AgentCodingTool::RepoInspector.new(config, runner: runner)
# Invoke the real production operation using the complete expected sequence.
runner.verify!
```

`Observation` takes exact string argv, exact cwd (including `nil`), and either
`result:` or `exception:`. A result contains raw stdout/stderr and either a
boolean success or a genuine `Process::Status`. Boolean fixtures need no native
setup and are supported by `Replay#capture`, the `CommandRunner` seam.
`Replay#capture3` requires a genuine recorded status and refuses boolean-only
observations. No object pretends to implement `Process::Status`.

Both methods preserve byte strings, encoding, and exceptional execution.
Native normal exits become boolean success at `capture`; a signal retains
Ruby's `status.success? == nil` behavior. A missing executable or cwd raises
`Errno::ENOENT`; no synthetic failure tuple substitutes for that exception.

Ordered replay is the default. Use `ordered: false` only for independent
concurrent requests such as `RepoInspector#pushed_heads`. Matching and consumption
are atomic; each expectation is consumed once. Always call `verify!` after the
operation, including expected refusals, to detect omitted commands. Unexpected
argv, cwd, ordering or duplicate calls raise `UnexpectedObservation`, deliberately
outside `StandardError` so product error handling cannot turn an inaccurate
fixture into a successful refusal.

`Native#capture3` records local processes with raw binary pipes, a real status
and spawn exceptions. It uses a two-second deadline per owned process group,
with concurrent pipe draining and a watchdog that kills only that group and
joins its waiter/readers. Timeout is a fixture `IOError`, never a recorded Git
response. `environment:` isolates child configuration; `seconds:` is for narrow
observer qualification and does not alter production deadlines. Native recording
is contract support, not a command emulator or production replacement.

The contract file scopes `Open3.capture3` substitution to one operation for
production consumers without injected runners. Their parsing, filesystem
ownership checks and refusal decisions still execute. Behavioral migrations
should use existing injected runners; a new shared production seam requires
the designated owner's review. Do not shadow the global Git executable.

## Named contract matrix

Every native interpretation is repeated against recorded observations through
the same production method. Native stdout/stderr bytes and status fields are
compared exactly; expected semantic values come from the independently created
fixture history and files. Exceptional cases compare class/message. Corrupted
observations are separate negative controls, followed by restored positives.

| Test method (`test_` prefix) | Production boundary and native observations | Negative control / refusal |
| --- | --- | --- |
| `authoritative_refs_snapshot_and_dirty_state` | `RepoInspector#snapshot`: exact `ls-remote --exit-code` ref, local divergent HEAD, staged/unstaged/untracked status, remote URL | Empty, duplicate, wrong-ref and invalid-SHA rows; falsely clean bytes; false success status |
| `nul_status_parser_and_refusal` | `Publisher#status_entries` and `scope_blocker`: porcelain v1 NUL records, rename's second path, newline/non-ASCII path bytes, mixed index/worktree | Changed path bytes differ; production refuses mixed staged/working versions |
| `linked_worktree_ownership` | `WorktreeManager#verify_entry!`: absolute common/admin dirs, local HEAD, commit existence, origin, NUL registry, detached marker and real on-disk backpointer | Wrong registry path, wrong HEAD and changed backpointer are refused; backpointer bytes restored in `ensure` |
| `commit_contents_modes_and_ref_movement` | `DeliveryManager#verify_commit!`: parent/head, clean status, NUL changed paths, exact binary blob, 100644/100755 tree modes, absent deleted blob; `RepoInspector#pushed_heads` before/after local push and concurrent branch requests | Changed blob bytes/mode are refused; local remote advances while independent release ref stays fixed |
| `failures_and_exceptions` | `RepoInspector`: missing ref exits 2 with empty streams, nonrepository exits 128 with diagnostic stderr, missing cwd raises; missing executable raises | Production classifies command failures as `RepositoryError` and retains spawn exception semantics |
| `strict_replay` | Exact argv/cwd, raw bytes and false success at the declared observation boundary | Unexpected argv/cwd, missing, duplicate and wrong-order requests fail; boolean raw-status fabrication is refused |
| `concurrent_remote_requests` | Real `RepoInspector` worker scheduling, deduplication and unordered strict matching | Bounded rendezvous fails if execution becomes serial; missing/duplicate captures fail |
| `native_process_observer` | Production `CommandRunner` preserves binary stdout/stderr, exit 7 and signal termination through native and replay paths | Owned sleeping child exceeds its deadline, is killed/reaped and yields no fabricated observation |

Diagnostics, temporary paths, object IDs, registry order and Git version text
may vary by platform/version. They are obtained from the native invocation and
retained exactly within that invocation; the relevant known bytes/ref/path/mode
contracts are asserted separately. No cross-platform stderr golden is assumed.
The path fixture uses UTF-8 non-ASCII bytes and a newline, represented as binary
strings. Invalid-UTF-8 file contents and process streams are also checked;
invalid-UTF-8 filenames require separate filesystem qualification on hosts that
permit creating them. Fixture creation failures are errors, never skips.
