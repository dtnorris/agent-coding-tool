# Finite Git world contract

This test-only capability is the TST-35 core for the
[zero-Git migration](../../coverage/zero-git-migration.md). The program contract in
ACTD `plans/TST-33-45-fast-suite.txt` controls acceptance. Production continues to
use [NativeCommandTransport](../../../lib/agent_coding_tool/command_transport.rb).
Passing this component verifier establishes neither native Git conformance nor
whole-suite coverage/runtime acceptance; TST-45 owns that integration.

## Composition and authority

Require `test/support/memory_git`, then construct one `MemoryGit::World` per case
with an existing canonical private filesystem root. Pass the world as `transport:`
to the production CLI/service. Use the case root as `TMPDIR` as well, so production
temporary excludes files remain within the declared filesystem boundary.

```ruby
template = MemoryGit::Template.files({ "file.txt" => "base\n" })
world = MemoryGit::World.new(root: private_root)
checkout = world.repository(path: "ordinary", template: template)
remote = world.remote(url: "git@github.com:example/repo.git", from: checkout)
world.connect(checkout, remote)
```

`Template`, blobs, entries, trees and commits are immutable. Blob IDs use Git's
blob hash; flat tree and commit IDs are deterministic model identities with
equality and parent-graph semantics, not native serialization compatibility.
`build_commit` constructs objects directly; `advance: true` also moves HEAD,
replaces that checkout's index and materializes its tree. An explicit `oid:` is an
imported fixture pin, never evidence about the actual source checkout.

Every checkout has an independent index and symbolic/detached HEAD. Linked
worktrees share repository objects, refs, config and remote bindings. Remote
objects/refs are separate from local storage: advertising a ref never makes its
objects locally available. A fresh world copies mutable stores from immutable
templates; neither remotes nor required fault schedules survive into another case.

`world.copy(checkout, path:)` replaces fixture `cp_r` setup: it creates independent
ordinary administration, copies local objects/refs/config/index/ignores and
projects current working bytes/modes/links. Within one world the copied checkout
still addresses the same remote store. Construct a fresh world's remote when a
case needs independent upstream authority. Raw copied `.git` content cannot
register a repository or worktree.

Use `world.configure(checkout, key, value)` for setup previously expressed as
`.git/config` edits. Physical config text is not an authoritative parser input.
Actual filesystem attacks still write actual files: the model checks root `.git`
type, ordinary administration identity and linked gitdir pointer; production
continues to inspect backpointers, ownership records, modes, symlinks and durable
evidence. Reads never repair tampered files. Ordinary `.git` stubs deliberately
lack native HEAD/object storage and are not usable native repositories.

## Finite command boundary

`World#call` implements the production command/result protocol, including binary
streams and real exit-versus-exception distinctions. It never fabricates a
`Process::Status`/PID or starts a process. `Mismatch < Exception` escapes product
`StandardError` refusals. Missing refs/objects/remotes and rejected leases are
modeled nonzero Git results, distinct from unsupported requests.

Supported commands are the audited discovery/revision/object reads, symbolic/ref
and ancestry probes, config and remote URL access, exact-branch advertisement and
fetch, scoped push/leases, status and path inventories, staging/write-tree/commit,
branch creation/deletion and worktree list/add/remove. Unknown options, global
config, input, cwd, execution options and environment combinations fail closed.
Only literal path selections, ordinary glob/directory ignore rules and complete
`--untracked-files=all` status are implemented. NUL paths retain raw bytes;
unsupported text quoting, rename heuristics, rich ignore patterns and nonrecursive
directory-tree serialization raise mismatch rather than inventing observations.

The base environment accepts only `GIT_NO_LAZY_FETCH=1`,
`GIT_TERMINAL_PROMPT=0` and `GIT_PAGER=cat`, including subsets. The only process
options are `binmode: true`, `pgroup: true` and a positive finite timeout.
Command-local config accepts disabled hooks/signing and a real, case-owned excludes
file. Shell-style fixture seeding, hooks and implicit native fallback are absent.

TST-36 owns patch/diff/tree-transition command methods in separate capability
files. The command dispatcher reserves `diff`, `diff-tree`, `apply`, `read-tree`,
`update-index`, `hash-object` and `reset`; absent methods raise mismatch. It calls
`command_NAME(checkout, arguments, input, settings)` with hyphens replaced by
underscores. TST-36 can prepend `supported_environment?` for an explicitly checked
scratch-index/object-directory envelope, delegating remaining keys to `super`,
and `checkout_for_command` for an independent index context. These hooks do not
disable the other request checks. Scratch environments remain unsupported until
that capability is installed and verified. Core staging supports explicit paths
and `add -A -- .`; additional observed staging forms need owner coordination.

`materialize!(checkout, before_entries, after_entries)` projects declared trees
onto real files/modes/symlinks without a patch parser. It refuses symlink ancestors,
special/hardlinked output files and collisions. TST-36 must validate transition
preconditions before using it; it is not an atomic transaction or a policy gate.

## Faults and evidence

`world.fault` binds exact argv, cwd, environment, stdin, timeout and execution
options. Phases are `before`, `after`, `before_effect` and `after_effect`.
Effect names include `stage`, `write_tree`, `commit`, `fetch`, `push`, `config`,
`branch_create`, `branch_delete`, `worktree_add` and `worktree_remove`.
Actions mutate declared state or raise an explicit exception without shell hooks.
`after` can replace the raw result; `before_effect` with `skip: true` deliberately
omits a mutation for independent negative controls. Repeated matching schedules
consume one per boundary. Unrelated query order is unrestricted.

Call `world.verify!` in every case teardown: an unconsumed required fault is a test
mismatch. `requests` returns detached observations, not mutable result caches.
Consumers must independently inspect later command reads and physical bytes/modes.

Run `ruby test/support/memory_git/verify.rb --seed 3501` with an owned `TMPDIR`.
It installs zero-Git and all-process guards before dependencies or product loading,
rejects filtering and reconciles its fixed `required_cases.json` with actual
Minitest result evidence. Set fresh `MEMORY_GIT_EVIDENCE` and `MEMORY_GIT_AUDIT`
paths to retain JSON. Independent OS process auditing is explicitly unavailable.
The native-fallback negative control intentionally records a denied attempt;
passing journeys introduce no allowed process creation.

`case_map.json` relates these additive component checks to retained legacy
assertion purposes and deliberate omissions. Existing family inventories are
unchanged; their owners still migrate and verify the complete scenarios. On
filesystems refusing invalid UTF-8 filenames, the verifier uses actual valid
control-byte paths and immutable tree reads for invalid UTF-8/NUL framing.
