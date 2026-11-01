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

## Patch/index/tree capability (TST-36)

Require `test/support/memory_git/patch_capabilities` and construct
`MemoryGit::PatchWorld` with the same `root:` contract. It subclasses `World` so
core-only consumers and their absent-capability checks remain independent, even
in one interpreter. TST-37 composes shared fixtures; TST-39/40 migrate families;
TST-45 owns complete integration and acceptance. No production API, coverage
denominator, policy floor or existing required-case inventory is changed here.

Register immutable `PatchCase` records with `world.register_patch(record)`.
`PatchCase.load` reads a JSON descriptor and sibling raw patch. Each descriptor
binds a required patch SHA-256, explicit preimage/postimage bytes and modes,
exact changed-path inventory, and reviewed NUL numstat/stat observations. Hex
fields preserve byte paths without encoding loss. Optional independently hashed
sections partition the entire raw patch and inventory, permitting scoped diff
observations without decoding binary payloads. Descriptors are trusted reviewed
specifications, not data inferred from patch output. Keep literal tree assertions
and raw fixture expectations independent of the model. `corrupt-postimage` is an
intentional wrong-effect observation for Checkpoint's negative comparison.

Known application validates exact bytes and every scoped physical/index preimage
before any effect. `--check` does no file, index, object or ref writes. Normal
application changes only working files; `--cached` changes only index/object state;
`--index` requires both preimages. Unsafe paths/ancestors, symlink output modes,
symlink destinations and special/hardlinked files refuse. Extra unrelated files
and staged entries survive. Effects are named `apply` and `patch:PATH` and use the
core's exact-envelope fault scheduling. Partial failures deliberately retain
inspectable effects rather than promising a filesystem transaction.

Diffs distinguish index/HEAD/worktree and explicit tree comparisons; untracked
files require staging or intent-to-add to enter a worktree diff. Names/statuses
support NUL framing. Binary/full-index observations emit registered canonical
patch bytes, including literal binary payloads, modes, add/delete, rename-as-
add/delete and reviewed quoted renames. The model does not implement rename
heuristics, general binary literal/delta decoding or native minimal-hunk choice.
For known records the registered canonical patch also serves a plain diff
preview; it is not a claim about Git's abbreviated or binary-summary rendering.
Unknown binary sections never map to a similar record or expected postimage.

The ordinary text codec is limited to ASCII content, portable unquoted paths,
ordinary modes and exact whole-file replacement hunks, including no final
newline, empty files, addition/deletion and mode changes. It validates counts,
headers, blob hashes and preimages by exact reconstruction; fuzzy/context hunks,
whitespace repair and richer formats fail loudly. Existing manually authored
new-file hunks may omit the index header. Dynamic apply fixtures justify this
small codec; arbitrary Git text formats remain unsupported.

Scratch contexts accept the complete Checkpoint envelope: `GIT_INDEX_FILE`,
`GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, plus base settings.
The index path must be absent with a canonical case-owned parent; the object
directory must be a real case-owned directory and the alternate must name that
checkout's common object path. Scratch indexes/object writes stay in memory,
separate from ordinary indexes/object stores. They are not native index files.
`read-tree`, `write-tree`, all-path/forced staging, explicit index removal,
stdin blob hashing and intent/reset cleanup have bounded command forms. Intent markers
bind exact placeholder entry identities within each index. Replacing or removing
that entry ends intent even when the replacement has identical empty bytes; a
deliberately omitted mutation preserves intent.

Reconstruction handles only Checkpoint's local `clone --no-checkout` variants
and detached `checkout`. It copies immutable local objects into separate mutable
authority and projects real files; no usable native Git repository is created.
Local object presence, commit ancestry and remote refs remain separate. Other
clone/checkout forms and unknown commands cannot fall back to a process.

Run `ruby test/support/memory_git/verify_patches.rb --seed 3601` with a private
`TMPDIR`. Its guards load before dependencies/product/fixtures and forbid all
processes. `patch_required_cases.json` and `patch_case_map.json` reconcile the
fixed additive case inventory with independent reporter results and prior
assertion purposes; filtering and skips fail. Set fresh `MEMORY_PATCH_EVIDENCE`,
`MEMORY_PATCH_AUDIT` and `MEMORY_PATCH_SOURCE` paths to retain results, the internal
guard audit, and actual source/fixture/index hashes checked across the invocation.
Independent OS process auditing remains unavailable. Public CLI apply and
checkpoint export/record/verify/recover use actual parsing, consent, durability,
hashes and scope checks. Delivery's candidate byte/mode/parent checks are covered
without calling providers. Generic non-Git child contracts remain owned elsewhere.

These golden contracts establish bounded ACT behavior, not a complete Git
implementation or compatibility with a live Git version. Zero-Git removes live
implementation conformance; neither component success nor unchanged production
source proves all-suite coverage/runtime acceptance. Host checkpoint registration,
gated validation and operator acceptance remain separate from worker export.

## Shared fixtures and cold interpreters (TST-37)

`test_helper` loads the zero-Git guard before fixture/product setup. It no longer
discovers Git with xcrun or builds native seed repositories. `TestHelpers.git_seed`
returns an immutable `Template`, **not** a directory/hash. Use
`with_memory_world(root) { |world| ... }` and
`memory_repository(world, path:, remote:, template:)` for fresh ordinary/remote
stores. `world.copy` and `world.configure` replace filesystem copy/config setup;
physical attack mutations still use actual files. Legacy leaf calls that fetch
seed directories, run Git directly, or expect fabricated/native modeled statuses
must migrate with TST-38–41. They have no compatibility fallback to Git.

`MemoryGit::Session::Transport.new(world)` is the explicit public-CLI composition
boundary. It routes only the two declared default immutable skill reads to their
separate read-only source; other commands reach the case world unchanged. Explicit
nondefault source fixtures belong in the mutable world. `Session.with(world)`
supplies the same default for legacy constructors inside one serial case scope.
It refuses replacing another active world and restores the prior scope on failure.
`Session.with_capture` nests declared non-Git capability observations without
capturing an original native method. It is not a parallel test context API.

Launcher, manual overlap, apply, retry and recovery helpers use these builders and
the common `CommandResult`. Launcher preflight responses stay in-process; its
worker spawner adapts the declared external executable to an exact approved Ruby
script while production retains reservation, pipes, signals, status and reports.
The `mutable_remote:` launcher keyword remains accepted; every memory fixture now
has independent upstream authority. `RecoveryObservations.status(code)` is reserved
for assertions requiring an actual reaped PID; ordinary modeled observations use
exit facts without a child. GitContract's capture3 replay accepts either genuine
native status or `CommandResult`; boolean-only records cannot supply termination
facts. `Replay#call` additionally matches environment, stdin, timeout and options
exactly and returns the shared result protocol.

Only a necessary process-contract world starts `Broker.new(world:, directory:,
case_id:, lease: 20, seconds: 2)`. The existing parent Ruby interpreter owns its
mutable state; one leased server thread serializes individual commands. There is
no fork copy, per-Git child or separate broker executable. Construct builders and
fault schedules before starting it. Once started, parent and child commands use
the broker/client; do not mutate retained model objects concurrently. Whole ACT
workflows are not locked, so ordinary filesystem locks/races remain observable.
The caller supplies an existing canonical, private, UID-owned directory whose
socket path fits the host's Unix socket limit. It must stay within the authorized
fixture boundary; there is no alternate transport or shared-directory fallback.

`broker.endpoint` carries the fresh case capability. `Client.new(endpoint)` sends
version, case, token and unique request ID with each command. Frames have a 4 MiB
limit, strict data-only JSON/base64 values and binary String encoding preservation.
Connect, frame IO and dispatch have deadlines; the owner also has a finite lease.
Duplicate IDs, stale/wrong capability, reset, unknown operations and malformed
envelopes refuse. A failed client is poisoned: mutations are never retried after
ambiguous completion. Inspect retained files, request records and broker events.
`close` stops only its own thread/socket, checks faults and leaves candidate files
intact; it will not unlink a replaced socket. New cases construct fresh worlds
and tokens instead of resetting a running authority.

`ChildProcesses.permit/capture` accepts only named, hash-pinned scripts. It binds
argv/env/cwd/options and propagates reviewed Bundler, zero-Git and active coverage
preloads. An explicit `endpoint:` additionally preloads the client before ACT;
`cold_cli` then loads the actual `bin/agent-coding-tool`. Supply a broker endpoint
for worker journeys that call ACT; independent non-Git children need only their
declared process bootstrap. Clearing/replacing guard or coverage settings cannot
borrow the permit. No arbitrary inline Ruby, shell launcher or Git shim is allowed.

`verify_adapters.rb --seed 3701` is an independent fixed shared-adapter component
gate. `verify_shared.rb --seed 3701` is the complete fixed TST-37 component gate,
including continuous cold public CLI/remote/candidate, omitted/stale handoffs,
protocol refusals, timeout, unrelated sentinel survival, locks, signals and active
child coverage. Neither filters/skips cases nor establishes full-suite acceptance.
Set fresh `MEMORY_SHARED_EVIDENCE`, `MEMORY_SHARED_AUDIT`, `MEMORY_SHARED_SOURCE`
paths to retain results, internal audit/startup timings and source/index hashes.
`shared_case_map.json` maps additive checks to retained prior purposes; all original
family inventories remain unchanged. Report sandbox socket failures as blocked,
not successful protocol tests. Independent OS process auditing remains unavailable.
TST-43 integrates the runner/coverage census; TST-45 owns complete integration,
coverage retention and runtime acceptance. The existing native-Git baseline is
not rerun or replaced by these component timings.

The launcher fixture keeps its temporary files inside its case world, including
command-local excludes and the private sandbox configuration home. Probe cwd and
TMPDIR come from the current durable handoff; changed environments and unowned
paths are refused. Cold launchers use the same leased broker as their parent. Registered sibling
host birth identities cross the reviewed child environment; a cold overlap query
rechecks those identities against the kernel before returning parent/group facts.
In-process launches need no broker. Cold readers that inspect repository state
receive the same leased authority as their parent.
The short `al-` case-directory prefix leaves room for `w.sock` under the
reconstructed worker's longer TMPDIR; every path remains inside the case world.

On Darwin, the launcher adapter answers only the exact production
`ps -o ppid= -o pgid= -p PID` query, without process creation, using the existing
`FeedbackRuntime.identity` libproc observer. Spawned fixture hosts/workers are
registered by kernel PID/parent/group/birth; queries require that live identity
or its direct child. Handoff reports never supply observed parent/group values.
Unknown argv/options, foreign or reused identities raise; unavailable observations
return failure. Production retains its parent/group and process/group liveness
checks. The retained fixture-permissions case checks these positive and negative
paths, including a real two-generation permitted Ruby family. This qualifies the
observer only; the full cold parallel-launch journey still requires host sockets.

`state_reader`, `planning_consumer`, `external_race`, `launcher_cli` and
`evidence_cli` are fixed, hash-pinned Ruby scripts at the existing permit seam.
They retain actual processes, locks, streams and exit statuses. The interactive
pipe helper releases its consumed permit before yielding, so another reviewed
child can run while the first is alive. Each spawn still needs its own permit.
The external-activity race uses fresh interpreters rather than inherited forks.

These child adapters do not authorize native Git. `TunnelProcesses` separately
binds the production owner fork, inventory and client launch to exact reviewed
source bytes and call sites; the sharing journey uses that same boundary.
The fixture-only inventory adapter isolates the declared synthetic endpoint from
a real host tunnel, while real ownership and occupied-endpoint refusals remain
covered separately. Socket denial blocks the broker and tunnel journeys and must
remain visible, without a transport fallback or skip. Memory-world checks do not
replace native Git or live Mac-to-Work acceptance.
