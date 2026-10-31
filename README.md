# agent-coding-tool

A deliberately small, local-first coordinator for a human directing multiple
coding agents.

The source repository is designed to remain safe to publish as open source.
Operational task definitions, project details, generated prompts, and runtime
state live in a separate data directory and are never required to be committed
here.

The opt-in `launch TASK --codex` command runs one local foreground worker per
task. An explicit collision flag can run a second task against the same Git
authority only when ACT verifies the first task's separate worktree and worker.
The tool does not plan architecture, interpret worker prose, or merge code.
With an operator-installed private validation contract, a successful launch
continues through trusted host validation to one task branch and draft PR.
Human review and integration remain required. The explicit `publish`
command commits and pushes selected changes in the configured private data
checkout only.

## V1 contract

- Pushed `main` is authoritative.
- Local HEAD and dirtiness are observations only.
- Tasks may reference arbitrary Git repositories under the configured repo
  root.
- Each repository is explicitly `write` or `read_only` for each task.
- Task dependencies must be explicitly complete before a dependent task can be
  prepared.
- Preparing a task snapshots exact pushed heads and emits a worker prompt.
- Generated worker prompts direct GitHub repository reads through the connected
  integration and prohibit unnecessary cloud-browser or website-permission
  fallback.
- Preparing remains allowed when another prepared, in-flight, or candidate task
  has the same writable authority, but prints a collision warning.
- Writable pushed-head movement after preparation makes the task stale;
  read-only movement requires refresh/reconciliation.
- Starting a prepared task explicitly marks it in flight and warns on fresh
  write/write overlap with in-flight or candidate work; manual isolation and
  agent liveness remain unverified.
- Worker outcomes are recorded explicitly; no prose interpretation is
  attempted.
- `needs_judgment` and `blocked` are normal outcomes, not failures to be
  auto-retried.
- Lifecycle commands never commit or push. `publish` is a separate operator
  action limited to the verified data checkout; it never opens PRs.

## Source/data separation

The public source checkout contains implementation, tests, documentation, and
examples only. Runtime data belongs in an external data directory.

By default, a checkout named `agent-coding-tool` uses a sibling directory named
`agent-coding-tool-data`. For example:

- `/path/to/code/agent-coding-tool` — public source checkout
- `/path/to/code/agent-coding-tool-data` — private/local task and state data
- `/path/to/code/other-repository` — a repository referenced by tasks

The default data directory can be overridden with
`AGENT_CODING_TOOL_DATA_DIR=/path/to/data`.

The data directory may itself be a private Git repository. Its expected
contents are:

- `config.yml` — optional overrides for repository root and default
  remote/branch and optional `publish_repository` identity.
- `tasks/*.yml` — durable human-authored task definitions.
- `state/*.yml` — explicit runtime/result state.
- `state/prompts/*.txt` — generated worker prompts.

When `config.yml` is absent, `repo_root` defaults to the parent of the data
directory, `default_remote` to `origin`, and `default_branch` to `main`.
Relative `repo_root` values are resolved from the data directory. See
`examples/config.yml`.
Publication expects `dtnorris/agent-coding-tool-data` by default. The
`publish_repository` setting can explicitly name another `owner/repository`
or an absolute local bare-repository path for offline fixtures. GitHub SSH
and HTTPS remote forms are normalized for identity verification.

The public repository also ignores legacy/local `config.yml`, `tasks/`,
`state/`, and `data/` paths as a fail-safe against accidentally committing
operational data.

## Incidental Finder metadata

ACT discovery ignores exactly the case-sensitive basename `.DS_Store` when
`lstat` establishes a readable regular file without following symlinks. This
applies at every managed evidence/task/attempt/worktree depth and on every
platform, independently of Git's ignore configuration. Other names and file
types retain their ordinary validation; unknown, inaccessible or racing evidence
never becomes a clear result. Metadata-only directories supply no run or proof.

Untracked or ignored regular metadata does not enter generated candidate patches,
change inventories, attempt counts, reservations, new closeout hashes or dirty
state. Git inventories use NUL-safe paths and check both index and HEAD before
excluding it. A separate filesystem check catches untracked nonregular Finder
entries that Git can omit (including FIFOs). Tracked/staged paths, explicit patch
destinations and explicitly referenced artifacts retain their ordinary collision,
byte-integrity and preservation rules. A `.DS_Store` name grants no authority.

Discovery and checkpoint operations leave metadata bytes intact; its later
creation, removal or content changes do not stale substantive candidates or new
closeouts. Historical closeouts that recorded a metadata hash still require that
original hash to verify; ACT never rewrites historical evidence or treats altered
old proof as valid. Old checkpoint patches likewise retain their recorded hashes
and complete reconstruction requirements, including metadata already explicitly
inventoried in the recorded patch. Altering that recorded content remains stale;
new checkpoint records exclude incidental metadata without converting old proof.

Only separately authorized disposal of an entire owned worktree may remove its
metadata. Cleanup checks ignored as well as untracked content, retains ownership,
liveness and integration gates, and uses a temporary command-local Finder exclude
for native Git removal after rechecking cleanliness. It uses no force removal,
individual metadata deletion, persistent ignore change or system setting.

## Apply a worker handoff

A worker supplies a handoff with two download links, for example:

```markdown
[Download patch](PATCH_DOWNLOAD_URL)
[Download companion JSON](JSON_DOWNLOAD_URL)
```

Save both in the same directory, then run from any working directory:

```sh
act apply ~/Downloads/new-task.json
```

ACT resolves repositories under `repo_root` from its existing data configuration,
checks the proposal without changing the repository, and displays the target,
actual HEAD and file summary. Manifest baseline drift and initial unrelated
staged, unstaged and untracked changes produce **WARN** diagnostics before consent,
identifying repository, classification and paths, including in sibling validation
repositories. A partially staged file appears in both tracked classifications.
Warnings require no extra dirty-state approval and grant no consent.
**Apply patch?**, **Run validation?**, and **Stage these
files and commit?** each independently default to no and require terminal input.
A manifest supplies no authority. EOF, blank input and redirected stdin decline;
there is no automatic yes option. The optional commit always belongs to the
patch target, even when checks run in a sibling repository. Normal local Git
commit hooks still run. Nothing pushes, opens a PR, launches a worker or updates
ACT lifecycle state.

Declining application leaves the reviewed state intact. Declining validation
leaves an applied, unvalidated proposal; declining commit leaves the validated
proposal unstaged. Pre-existing index entries remain intact in each case.
Failed checks stop the sequence, retain raw
stdout/stderr and the child exit status (signals use 128 plus signal), and report
unrun checks. An executable that cannot start returns 127. Refusals return 2;
interrupt returns 130. A declined workflow returns zero, so inspect its printed
phase outcome rather than treating zero as validation/commit evidence. Errors
and interrupts preserve applied changes and any staged files for inspection;
there is no rollback, cleanup, automatic retry or resume engine. Reinvocation
against an already applied patch still refuses ordinary applicability checks.

### Companion JSON v1 contract

`agent-coding-tool-apply/v1` is the only supported schema. Every field below is
required, and unknown fields/actions are rejected. V1 has one patch target and
explicitly declared validation/data repositories. It supports ordinary file
additions, modifications and deletions, including Git binary patches and
executable file modes; symlinks, submodules and rename-form patches are outside
the contract (producers should use `--no-renames`).

| Field | Contract |
| --- | --- |
| `schema` | Exact version string above. |
| `target` | Key in `repositories` for the only patch target. |
| `repositories` | Nonempty object keyed by portable repository names. Every entry has `path` relative to configured `repo_root`, `remote_url` identity, and a 40-character lowercase `baseline` SHA recording producer provenance. A different actual HEAD warns with expected/actual SHA; equality, ancestry and local availability of the declared object are not required. ACT checks the configured default remote using its existing identity normalization; it does no remote freshness/network check. Roots must exist, be distinct and not overlap. |
| `patch` | Object with companion `file` basename and exact lowercase 64-character `sha256`. Resolved relative to the JSON directory, never caller cwd. Embedded patches/download URLs are unsupported. |
| `paths` | Nonempty unique array of exact root-relative changed paths, checked against native patch inspection and resulting changes. |
| `validation` | Nonempty array of ordered required actions, described below. All must pass before commit can be offered. |
| `commit_message` | Nonempty single-line suggested local commit message, always passed as one argv element. |

Manifest-supplied relative paths use ASCII letters, digits, spaces, underscores, hyphens, dots and
slashes. Empty components, `.`/`..`, `.git` in any case, shell/pathspec syntax,
absolute paths and symlink components are refused. Validation `cwd` alone may
be `.` for the repository root. The patch must be a regular nonsymlink file.
Unrelated existing filenames discovered by Git may contain punctuation or
Unicode; ACT still snapshots their bytes and modes and refuses traversal,
Git administration and symlink components. This does not expand v1 patch-target
or manifest-path syntax.
Initial dirty work may coexist with the proposal when its paths are disjoint.
ACT preserves unrelated file bytes/modes, deletions, untracked contents and each
index path/stage/blob/mode entry, including distinct staged and worktree versions
of a partially staged file. Pre-existing staged or unstaged changes to a proposal
path refuse, even if native Git could apply different hunks in that same file.
An occupied addition, file/directory prefix collision, unresolved merge/index entry,
ignored patch destination, changed artifact, wrong identity or failing
`git apply --check` refuses before mutation. Confirmed application rechecks the
reviewed repository snapshots/artifact and uses ordinary atomic `git apply`.
Hidden index flags (`assume-unchanged`/`skip-worktree`) are unsupported and refused.
There is no fetch, rebase, force, partial apply, stash or index repair.

Every validation action has `action`, `repository` (a declared key), `cwd`
(existing directory relative to that repository), and `env` (an object):

| Action | Additional required field | Exact argv |
| --- | --- | --- |
| `bundle_rake` | `tasks`: nonempty array of task names using letters/digits/underscore/colon, starting with a letter/digit/underscore | `bundle exec rake <tasks...>` |
| `ruby_test` | `files`: array containing one root-of-cwd relative `.rb` test path | Current Ruby, `-Ilib:test -- <file>` |
| `git_diff_check` | None | `git diff --check` |

`env` permits only `AGENT_CODING_TOOL_DATA_DIR`, whose value names a declared
repository and resolves to its verified absolute root; `{}` changes nothing.
No executable override, shell string, Ruby flags/code, arbitrary environment or
hook is accepted from JSON. Existing process environment is otherwise inherited;
ambient `GIT_*` overrides other than pager/terminal-prompt settings are refused.
The displayed argv/cwd/environment scope requires separate operator consent.
**These actions execute repository code with operator privileges and are not a
sandbox.** Review the patch and referenced repository code before approving.

ACT inventories the actual initial HEAD/tree and compares file bytes/modes,
HEAD, branch, remote identity and index across
every declared repository before/after each step and before staging. Unexpected
edits refuse commit. Only untracked, Git-ignored output under `coverage/`, `tmp/`,
`test/tmp/` and `test/version_tmp/` is excluded from source comparisons; tracked
files there remain protected, as do other ignored files. A tool that rewrites
`Gemfile.lock` or ACTD state fails this check even if it exits zero. New files
are included in staging; ACT stages only declared paths. The optional path-scoped
commit parents the actual reviewed target HEAD and contains exactly the validated
proposal, excluding pre-existing staged changes. ACT verifies committed paths and
content and preserves unrelated index entries and worktree state; the resulting
repository may remain dirty. Ordinary Git hooks still run; a hook failure or an
unexpected hook edit leaves inspectable state and never reports verified success.
Later HEAD/index movement, artifact changes, edits/additions/deletions,
including changes to initially dirty files or sibling repositories, refuse
progression rather than producing another advisory warning. Rechecks detect observed changes;
they cannot lock out arbitrary external writers or contain trusted tests/hooks.

### Temporary direct-Git workaround

Older ACT versions can refuse initial unrelated tracked edits with
`tracked index/worktree is not clean`, or refuse a valid handoff with `unsafe relative
path` because they apply the manifest's portable allowlist to unrelated existing
filenames, including apostrophes, parentheses, ampersands and Unicode. Preserve
the rejection and downloaded artifacts for review. There is no automatic fallback.

For an independently reviewed patch, the operator may apply it directly only
after inspecting the exact repository root, HEAD, configured remote identity,
index and worktree (including untracked and ignored files), and checking the
downloaded patch's SHA-256 against the handoff. Resolve baseline or identity
uncertainty first. Review exact patch paths and modes; refuse any pre-existing
edit on those paths, occupied addition, prefix collision or ambiguous index.
Record the initial unrelated file bytes/modes and index entries for comparison;
unrelated dirty work must be preserved, never discarded to satisfy an older guard.
From that verified root, run `git apply --check /absolute/path/proposal.patch`,
then `git apply /absolute/path/proposal.patch` on the same hash-verified bytes
with no intervening repository changes. Validate separately using the reviewed
handoff actions, cwd and environment; direct Git does not supply ACT's snapshot
rechecks or independent consent prompts. Inspect the resulting diff, index and
unrelated files afterward. Stop on any mismatch or failure; do not stash, reset,
rename files, implicitly commit or publish. Keep an optional commit separate:
ordinary `git commit` would absorb unrelated staged changes. Use only explicitly
authorized proposal paths with `git commit --only -- <reviewed paths>` and verify
its parent, exact committed paths/content and remaining index/worktree state.
Companion JSON cannot bypass an installed version's unrepaired guard.
Applying or validating the workaround
does not establish acceptance of the ACT repair.

### Producing a handoff

Generate a complete root-relative patch against the intended baseline, including
new files, using the existing [checkpoint export workflow](#implementation-checkpoints)
where applicable. Otherwise inspect `git diff --binary --full-index --no-renames`
and include each new file's root-relative diff explicitly. Check application and
reconstruction in a disposable repository at that baseline. Compute SHA-256 over
the final downloaded patch bytes, list exact changed paths, and bind each sibling
repository's current identity and HEAD as provenance. Warning-only preflight
does not establish semantic compatibility with a different actual HEAD or grant
automatic acceptance; review the current source and validation scope.
Supply only the required checks in order,
with explicit ACTD selection for sibling ACT checks. Link both artifacts; worker
test claims and a manifest do not establish operator acceptance or publication.

For example, the following complete JSON describes a task-registration proposal
for sibling directories `agent-coding-tool-data` and `agent-coding-tool`. Replace
both example baselines/identities/paths with the intended local repositories and
regenerate the hash if the patch changes. The hash shown matches exactly this
UTF-8 patch, with LF line endings and a final newline:

```diff
diff --git a/tasks/NEW.yml b/tasks/NEW.yml
new file mode 100644
--- /dev/null
+++ b/tasks/NEW.yml
@@ -0,0 +1,9 @@
+---
+id: NEW
+title: Example inspection
+repositories:
+  agent-coding-tool:
+    access: read_only
+goal: Inspect the example.
+acceptance:
+  - Report findings.
```

This new file includes the [required task fields](#task-shape). The native public CLI test
exercises this same patch/hash with disposable local remotes, real terminal
confirmations and sibling checks.

```json
{
  "schema": "agent-coding-tool-apply/v1",
  "target": "data",
  "repositories": {
    "data": {
      "path": "agent-coding-tool-data",
      "remote_url": "git@github.com:dtnorris/agent-coding-tool-data.git",
      "baseline": "322d7f43b0963bc94723555744ef00f3caea077c"
    },
    "tool": {
      "path": "agent-coding-tool",
      "remote_url": "git@github.com:dtnorris/agent-coding-tool.git",
      "baseline": "f099845176db0b6cc0bffe370d7547203ad24d09"
    }
  },
  "patch": {
    "file": "new-task.patch",
    "sha256": "4775f89ea64cbab54b94987dd3add1ef60097c017ec76bdac8265a435143ae7c"
  },
  "paths": ["tasks/NEW.yml"],
  "validation": [
    {
      "action": "bundle_rake",
      "repository": "tool",
      "cwd": ".",
      "env": {"AGENT_CODING_TOOL_DATA_DIR": "data"},
      "tasks": ["actd:validate_yaml", "test:all"]
    },
    {"action": "git_diff_check", "repository": "data", "cwd": ".", "env": {}}
  ],
  "commit_message": "Register NEW task"
}
```

## Task shape

Copy `examples/tasks/EXAMPLE.yml` into the external data directory's `tasks/`
directory and replace its contents. Repository keys default to directory names
under `repo_root`; an individual repository may additionally set `path`,
`remote`, or `branch` when it differs from the defaults.

Required task fields are `id`, `title`, and a non-empty `repositories` mapping.
`depends_on`, `constraints`, and `acceptance` are arrays. `goal` is free text.
An optional `worker_recommendation` mapping supplies non-empty `model` and
`thinking` strings as human-authored launch guidance.
An omitted `checkpoint` field requires a verified implementation checkpoint
for substantive coding work, including edit scripts. An explicit exception is
`checkpoint: {mode: exempt, category: planning, reason: "No executable change."}`;
`inspection` and `no_code` are also supported categories. The parser rejects
missing or empty reasons and unknown modes. Existing task files parse unchanged;
previously prepared prompt files remain snapshots and do not gain these instructions.

## Outcome-first task registration

ACT coordinates engineering tasks, but completing tasks is not the objective. The objective is delivering integrated, verified, operator-useful outcomes.

Before registering or splitting substantial work:

1. **Original outcome:** Identify the operator-visible result and existing acceptance requirements.
2. **Established evidence:** Determine what already works and what remains unproved.
3. **Next gate:** Identify the smallest falsifiable step toward completion, including pass/fail and stop conditions.
4. **Necessary work:** Register only changes genuinely required for safe execution, trustworthy verification, or original acceptance.

Add `depends_on` edges only for demonstrated prerequisites. Do not make incidental cleanup, tooling improvements, speculative hardening, or unrelated defects mandatory dependencies.

When work encounters a blocker, distinguish product defects from fixture, environment, instrumentation, integration, and task-management problems. Prefer bounded repairs and existing recovery mechanisms. Preserve original acceptance requirements and report out-of-scope work separately.

Use `planning_guidance: required` for ACT-generated substantial planning and registration assignments so they receive the complete canonical planning skill. Ordinary implementation tasks retain the standard coding guidance.

ACT's `next` and status rankings describe technical readiness and dependency consequences. They are advisory, not a measure of which outcome matters most. The operator determines outcome priority.

Preserve all safety, Git authority, provenance, testing, recovery, and cost controls. Never weaken verification or silently expand task authority to accelerate completion. Stop expanding work once the original outcome is verified.

## Typical workflow

1. Create a task YAML file in the external data directory.
2. Run `bin/agent-coding-tool status` to see active work, blockers, and recent
   progress.
3. Run `bin/agent-coding-tool prepare TASK` immediately before the work.
4. Run `bin/agent-coding-tool start TASK` to reserve the writable lane. Only
   after start succeeds, hand the generated prompt to the worker. Start is a
   human assertion; it does not launch a worker process.
5. Run `bin/agent-coding-tool received TASK` when the worker result is ready
   for review/application.
6. Apply/review the worker artifact yourself. Once the task has actually landed
   on authoritative pushed state, run `bin/agent-coding-tool finish TASK`.
7. Dependent tasks become ready only after that explicit completion.
8. Run `bin/agent-coding-tool publish` when ready to commit and push pending
   lifecycle state. Publication is never implicit in steps 3–6.

A worker that discovers a bad task breakout should be recorded as `blocked` or
`needs_judgment`, not encouraged to broaden scope.

## Commands

`bin/agent-coding-tool next`

Read-only advisory for work that can be started now. It uses the same effective
status/freshness snapshot, READY priority ranking, dependency-unlock metrics,
and remote URL plus branch writable authorities as `status` and `start`.
Fresh IN_FLIGHT and CANDIDATE writers occupy lanes; PREPARED work is available
but does not reserve one. The compatible start set is selected in priority
order, not rearranged to maximize the number of workers. READY rows show
`act prepare TASK` followed by `act start TASK`; fresh PREPARED rows show only
`act start TASK`. Both lifecycle commands recheck their own gates before a
prompt can be handed to a worker. The output also separates additional manual parallel work,
running lanes, candidates awaiting human review/application, dependency waits,
and recorded interventions. Expected unlock counts are conditional consequences
of verified completion, not claims that downstream work is already eligible.
No state, prompt, Git ref, or agent is changed by `next`.

`bin/agent-coding-tool next --json` exports that same plan as one JSON
document on stdout. Its binding `agent-coding-tool-next/v0.1` contract has
`schema_version`, `advisory: true`, `snapshot`, `facts`, and
`recommendations`. `facts.tasks` records effective statuses, reasons,
dependencies, one-based priority ranks, and prepared pushed-head bindings
with an explicit checked/not-checked freshness state; `facts.reservations` records
current IN_FLIGHT/CANDIDATE writable remote URL and branch pairs.
`recommendations` contains ordered `starts`, `waiting_capacity`,
`candidate_review`, `interventions`, and `waiting_dependencies` arrays.
Start rows include the same grounded lifecycle commands as the text view,
optional configured model/thinking advice, and conditional downstream counts.
The compatibility `waiting_capacity` rows identify selected or occupied
conflicting authorities as `manual_parallel` possibilities, with an explicit
isolation action and unknown liveness. Empty
sections remain empty arrays. Array ordering follows the existing ranked
planner, including ACT-first READY priority and natural task-ID ties; no
clock-generated plan ID is introduced.
The snapshot states which freshness was observed and that prepare/start must
revalidate. It does not grant authority, launch a worker, or resolve a stale
candidate or human judgment. Malformed or unavailable pushed-head evidence
produces no partial JSON, an error on stderr, and a nonzero exit.

### Reporting external agent activity

Use these commands to report work already occurring outside ACT. Reporting is
visibility only: ACT has neither verified nor authorized that execution.

```sh
bin/agent-coding-tool external report TASK --reporter 'operator' --kind 'codex' \
  --identifier 'reported-session-id'
bin/agent-coding-tool external show TASK
bin/agent-coding-tool status TASK
bin/agent-coding-tool status
bin/agent-coding-tool next --json
bin/agent-coding-tool external end TASK OBSERVATION_ID --disposition ended
```

Report works for a registered non-complete task without preparation, a generated
prompt, managed invocation, resolved historical attempts or legacy host evidence.
It never prepares or starts the task. Task detail and the normal dashboard show
`EXTERNAL WORK REPORTED` alongside the original lifecycle and blocker, including
STALE. Open observations survive READY compression, blocked limits and completed
task filters. A separately recorded COMPLETE remains authoritative but displays
an inconsistency until the observation is explicitly ended. Fresh declarations
on COMPLETE refuse.

The reporter, kind and optional identifier are supplied facts. The observation
UUID identifies ACT's record, not an invocation, process or session. ACT records
local observation time and the observed local UID separately. Isolation and
containment remain unverified; liveness is always unknown. The last-reported
timestamp is not a heartbeat. Observations never expire: process exit, source
movement, old timestamps, reset, result recording and assumed success cannot
close them or release their conflicts. Declaration may report an overlap with
an already managed worker, including the same task; both identities remain and
the dashboard reports the conflict.

Writable scope defaults to **unknown**, blocking potential new writers across
repositories while unrelated read-only tasks remain usable. If the operator
explicitly reports a complete bounded writable repository set, use:

```sh
bin/agent-coding-tool external report TASK --reporter 'operator' --kind 'codex' \
  --scope-complete --write-repository 'git@github.com:example/additional.git,main'
```

`--write-repository REMOTE,BRANCH` is repeatable and adds supplied authorities.
The floor includes registered writers and retained preparation writers; supplied
scope cannot remove them. Supported Git remote spellings use ACT's publication
identity resolution, so aliases and different branches reserve the entire same
repository. This completeness is an operator report, never host attestation or
permission to write. Bounded reports permit provably disjoint configured writers;
preparations without retained access labels conservatively reserve every prepared
repository, including references, because current labels cannot prove old scope.
unresolved identities or changed declarations/authority make scope unknown while
retaining the original envelope. Missing preparation alone is valid. Reconcile by
explicitly ending the old observation and making a new report; status reads do
not rewrite it. A read-only label or supplied directory does not prove containment.

Manual `start`, managed launch and delivery share this external conflict check.
`--allow-write-collision` and ACT-owned parallel isolation exceptions cannot
override it. Ordinary ACT-15 manual collision warnings remain advisory when no
external observation conflicts. Preparation can still take a snapshot, with a
conflict warning; it grants no execution eligibility. `next` excludes externally
blocked starts and offers no `manual_parallel` escape for them. JSON retains
`agent-coding-tool-next/v0.1`, original status/reason/freshness meanings and the
existing no-observation field order. With observations it adds task
`external_activity`/`external_conflicts`, `facts.external_reservations` and
`recommendations.external_waits`; unknown scope is explicit. These fields are
separate from managed `execution_evidence`. Conditional parallel unlock width
also respects the external envelopes.

Only one observation can be active per task. An exact repeat with the same
supplied identifier and payload returns the retained observation without changing
timestamps/history. Changed payloads, competing identifiers, a repeated report
without an identifier, and reuse across tasks refuse while retained. End requires
the observation UUID and `--disposition ended`, `failed` or `lost-contact`.
Repeating the same retained end is a no-op and cannot end a newer observation.
Unknown/evicted IDs and changed dispositions refuse. Retention is bounded to one
active observation and the last eight closed observations per task, plus an
omitted-older count; identity deduplication ends when a record is evicted. This
is not indefinite audit storage.

Optional `--note TEXT` and `--reference TEXT` are concise private inert text.
References are never opened or imported. UTF-8 byte limits are: reporter 128,
kind 64, identifier 256, note 512, reference 512. Empty/invalid text, control
characters and excess bytes refuse without echoing the payload. Additional
authority reports are limited to 128 remote/branch pairs (1024 bytes per value).
Do not supply prompts, logs, credentials or environment dumps.

Records live only in the private operator-owned
`<canonical-data-directory>-runs/.external-activity/TASK.yml` namespace, outside
ACTD. `show` exposes bounded private history; broad JSON omits supplied identifiers,
notes and references. No observation fields or pointers enter lifecycle YAML,
generated prompts or automatic delivery material, so default, task and `--all`
publication selections cannot sweep these records. Unsafe owners, symlinks,
foreign entries, damaged YAML and incompatible schemas refuse rather than become
inactivity. Inspection is lock-free and read-only. Report/end and execution
eligibility checks use the existing launch/delivery/recovery reservation lock,
including tasks without managed run directories; busy locks require retry.
Atomic replacement exposes complete old/new documents. A directory-sync error
after rename reports that replacement occurred; inspect/repeat the command
instead of assuming rollback.

Ending is an operator-reported disposition, not proof of termination or candidate
quality. It calls no managed lifecycle, retry, checkpoint, delivery, integration
or publication operation. Preserve and separately review any external result.
Use existing explicitly authorized `received`/`finish` or other result handoff
only in an eligible context; ending cannot resolve STALE preparation, legacy
liveness uncertainty or historical closeout blockers. David retains integration
and final acceptance authority.

Icebox tasks remain in `facts.tasks` with effective `status: "ICEBOX"` and
the additive `icebox` mapping and `lifecycle_status` string (`READY` or
`BLOCKED`). These fields preserve the designation and underlying eligibility
without changing existing v0.1 field types or meanings. No start or manual
parallel recommendation includes them. Deferral is not completion and grants
no dependency unlock credit; an iceboxed prerequisite remains named in its
dependent's blocker diagnosis.

`bin/agent-coding-tool icebox TASK [--reason TEXT]`

Intentionally defers worthwhile but deprioritized, unstarted READY work.
Icebox is an operator scheduling designation, separate from execution
lifecycle and recorded outcomes. A reason is optional. PREPARED, IN_FLIGHT,
CANDIDATE/STALE_CANDIDATE, STALE, terminal and dependency-BLOCKED work cannot
initially enter. Partial preparation, retained prompt, checkpoint, result or
private attempt evidence also refuses entry even when a snapshot is missing.
Task definitions, dependencies and history are never rewritten to make work
eligible. Unknown IDs and malformed/conflicting state fail with diagnostics.

The optional `icebox` mapping lives in the existing `state/TASK.yml`:

```yaml
icebox:
  at: '2026-10-18T12:00:00Z'
  reason: Revisit after profiling
```

`at` must be an ISO 8601 timestamp string including time and timezone; `reason`,
when present, must be a string. Null, scalar/list mappings, unknown keys and
invalid timestamps/types are rejected. Legacy files without `icebox` keep
ordinary behavior; unrelated compatible metadata is retained. Identical
repetitions do not write state or change the original timestamp. A different
reason requires explicit `unicebox`, followed by a new deferral.

`bin/agent-coding-tool unicebox TASK`

Removes only `icebox`; repeated restoration is a no-op. Eligibility is computed
again from actual lifecycle, dependencies and freshness. Dependency changes
while deferred remain visible as underlying blockers and may prevent READY
after restoration. Explicit `prepare`, automatic `launch`, manual `start`,
`record`, `received` and `finish` refuse designated work. `prepare --retry`
cannot restore it. `reset` is a no-op for a deferred task, retaining all state;
only explicit restoration permits lifecycle entry.

Scheduling mutations, preparation, starts and outcomes serialize on the same
private `launch.lock`, including first preparation and direct Coordinator API
calls. They reread state under the lock; competing operations refuse before
mutation/handoff and may be retried after inspection. Launch passes its held
lock through preparation/start, avoiding recursive locking. Unsafe/foreign or
symlinked reservation paths refuse. This preserves existing execution,
checkpoint, collision, recovery and human-review gates.

StateStore uses its existing same-directory atomic replacement. Failures before
rename leave the old state intact; a directory-sync failure after rename reports
that state **was replaced** with crash durability unconfirmed. Inspect state
before retrying an uncertain operation. No new lifecycle outcome is stored and
no publication occurs implicitly; normal explicit ACTD publication selects the
existing state file.

`bin/agent-coding-tool status [TASK | --fam FAMILY] [--all | --active] [--icebox]`

Shows effective task state. The default dashboard includes active work with
READY compression as described below, the three easiest blocked tasks, and the five most recently
completed tasks ranked by their recorded completion timestamps. Retained
timestamped completions display oldest-to-newest, with the newest at the
bottom. Completed tasks without a usable recorded timestamp remain visible
before the chronological rows in stable task-store order. `--all` shows every
task with the same COMPLETE ordering, and `--active` excludes every completed
task while retaining the three-blocker dashboard limit. The two options are
mutually exclusive. Explicit `status TASK` lookup always shows the named task
without compression or a NEXT marker.

Default and `--active` dashboards hide individual Icebox rows and exclude them
from READY/active recommendation counts. An open external observation keeps its
Icebox row visible, including its unverified execution and unknown liveness
qualifiers. Reporting or ending external work never removes the Icebox
designation; `unicebox` remains explicit. Both facts appear together in `next`
and its JSON inventory, without recommending the deferred task. Exactly one final line counts the
full Icebox inventory before READY compression: `0 Icebox tasks`,
`1 Icebox task from families (TST)`, or
`8 Icebox tasks from families (ACT, CL, FO, TST)`. Family names use the same
first-hyphen-prefix rule below, in deterministic lexical order. The count stays
on one readable line in non-TTY/narrow output (it may exceed a very narrow
terminal, like an intact drill-down command).

`status TASK` shows the designation timestamp, optional reason, underlying
lifecycle/blocker and `act unicebox TASK`. `status --icebox` lists only deferred
tasks; it may combine with `--fam`, `--all` or `--active`, but not TASK.
`--all` and explicit family views include full Icebox rows as the very last
status group, after BLOCKED, rather than substituting the compact footer.
Icebox rows use natural task-ID ties and receive no NEXT marker or READY
priority promotion. All other filtering/compression rules remain as below.

`act stat --fam CL` (`bin/agent-coding-tool status --fam CL`) shows all READY
work in the exact `CL` family without compression, plus that family's ordinary
status/diagnostics. Families are mechanical presentation groups: the first
hyphen-delimited task-ID prefix (`CL-AFDP-01A` and `CL-AFW-07A` are `CL`;
`ACT-STATE-01` is `ACT`). IDs without a hyphen use their whole ID; an empty
prefix also falls back to the whole ID. Matching is case-sensitive and exact
(`CL` does not match `CLX`). These groups imply no dependency, ownership or
execution compatibility. There is no family registry or task schema change.
Families are known from the full task registry, including families with only
completed or blocked work. A selector beginning with a hyphen can be passed as
`--fam=-legacy`. Unknown/missing families, repeated selectors, TASK with
`--fam`, unsupported options (including `--family`), and `--all --active` fail
with a nonzero error. `--fam CL --all` includes every CL completion;
`--fam CL --active` excludes all completions. The default five-recent-COMPLETE
window is applied globally **before** the family filter, so a completed-only
family can have an empty default view. The three-BLOCKED limit is applied
**after** the family filter; `--all` removes that limit.

Broad default and `--active` views show every READY task up to six. At seven
or more READY tasks, every READY family receives its highest-ranked member
first. With four or more families, exactly one representative is shown per
family, even if that is fewer or more than six rows. With one to three
families, remaining positions are filled from global READY rank up to six
rows total, never exceeding three per family. Capacity stays unused if these
caps prevent filling it. Selected rows retain global rank order. `--all`,
`--fam` and explicit task lookup remain uncompressed.

The one global NEXT is chosen from the complete ranked plan **before** display
filtering, with existing actionable/candidate/capacity/intervention fallbacks
and cross-family reservations intact. Operator-approved exception to
highest-ranked family representation: if compression would hide the globally
recommended READY task, it replaces the lowest-ranked displayed task in its
own family. Family coverage, allocation caps and global ranking are preserved;
reservation checks are never bypassed. Family drill-down marks NEXT only when
that same global task is present, never a family-local substitute. Each family
in a compressed view has one subordinate summary such as
`CL: 8 READY, 7 hidden — act stat --fam CL`; zero-hidden counts are shown too.
Counts include only the full READY set, before compression. Narrow output
wraps summaries while keeping each drill-down command intact; a command wider
than the terminal can overflow just like other unbreakable detail tokens.

Broad dashboards are ordered for scanability: `COMPLETE`, `CANDIDATE`,
`NEEDS_JUDGMENT`, clean `IN_FLIGHT`, a separate `IN_FLIGHT (STALE)` subgroup,
`READY`, then other active or exceptional
states, then `BLOCKED`, with `ICEBOX` last when explicitly included. Within READY only, ACT-family work ranks ahead
of all other families. Each tier retains descending immediate collision-aware
parallel unlock width, immediate unlock count, longest downstream dependency
path, then distinct downstream task count. Genuine ties use natural task-ID
ordering (numeric runs compare numerically: ACT-02 before ACT-10,
CL-AFDP-01A before CL-AFDP-02), then the full ID for equivalent natural keys
(such as leading zeros). Other lifecycle ordering is unchanged. Priority does
not promote blocked/stale/failed work to READY, grant execution authority or
bypass freshness, dependencies or write reservations. A READY task waiting for
capacity stays READY. READY and fresh CANDIDATE rows show downstream
depth/count and `unlocks: N tasks / M parallel`: `N` is the number of
dependency-blocked tasks that would become READY if the row's task completed,
while `M` is the exact maximum subset that could start together without
conflicting with each other or other fresh IN_FLIGHT/CANDIDATE writers under
normal repository-authority rules. For a CANDIDATE, this models the state after
the candidate is finished, so its own current write reservation is excluded.

One operator-approved exception promotes exactly `CL-WLO-01`, while READY,
to the first existing READY CL position across `status`, `stat --fam CL`,
`next` and `next --json`. Other families keep their positions; other CL tasks
keep their relative order and all downstream metrics remain factual. Missing
or non-READY `CL-WLO-01` has no effect. ACT-family priority and normal selection,
freshness and reservation constraints still apply. This is advisory ordering,
not a global NEXT guarantee or permission to execute cleanup: ACT does not
machine-verify Batch 39 completion or operator acceptance. The task's mandatory
operational gate must be satisfied before any WLO edits.
This is deterministic advisory prioritization only; it does not launch work or
reserve repositories. Default and `--active` dashboards show only the three
easiest dependency blockers, ranked by fewest incomplete dependencies; explicit
`blocked` outcomes without measurable dependency counts rank after
dependency-derived blockers. `--all` remains exhaustive. Major groups are
separated by a blank line. Every broad-dashboard task headline remains on one
line; embedded title whitespace is normalized, and long headlines truncate to
the terminal width with ASCII `...`. Subordinate details retain their own
wrapping or truncation behavior. Explicit `status TASK` lookup shows the full
original title and details. Dependency blockers use the compact `waiting on:`
label. When output is a TTY, status labels are colored; set `NO_COLOR` to
disable ANSI color.

Use `act stat --min` (`bin/agent-coding-tool status --min`) to scan exactly one
width-bounded row per displayed task, without blank separators, detail lines,
family/hidden-count summaries or an Icebox footer. `act stat --min --all` shows
the existing full inventory. `--min` also combines with TASK, `--active`,
`--fam FAMILY` and `--icebox` wherever those selectors are already valid. Task
selection, ordering, effective status, global NEXT, READY compression and
completed/Icebox visibility stay the same; an empty selection prints nothing.

Rows retain ID, human status (including `IN_FLIGHT (STALE)`), NEXT when present,
and title as space permits. Inline `[external reported]`, `[external conflict]`,
`[write collision]`, `[recorded overlap]` and `[read-only refresh]` indicators
refer to existing evidence, granting no execution authority or assurance of
fresh source, verified isolation or observed liveness. Omit `--min`, optionally
with TASK, to recover full warnings, reasons, next steps, checkpoint/downstream
details and restoration commands. Minimal output normalizes embedded whitespace
and neutralizes input controls/terminal escapes. It uses the existing terminal
width, ANSI-aware truncation and redirected-output fallback (`COLUMNS`, otherwise
100 columns). Status/NEXT and indicators precede the title; long IDs shrink to
retain them when possible. At extremely narrow widths, even identity, status
and warning indicators inevitably truncate with the existing ASCII `...`
convention (one or two dots below three columns).

Recorded `NEEDS_JUDGMENT` rows provide a compact operator handoff: a `reason:`,
an optional explicitly recorded `next:`, and the mechanical `resume: act
prepare TASK --retry` command. Each handoff field is normalized to one line and
dynamically truncated to the terminal width with ASCII `...`; the stored values
are unchanged. Use explicit `status TASK` to see the complete, untruncated
summary and next action.

Prepared, in-flight, and candidate tasks are compared against current pushed
heads; writable head movement produces `STALE` or `STALE_CANDIDATE`. Read-only
movement preserves the state with a refresh/reconciliation warning.
With a recorded start and no result, human status and next interventions show
`IN_FLIGHT (STALE)`: source movement does not establish that execution ended.
Broad stale in-flight rows, including `--all` and `--fam` views, have at most two
width-bounded detail lines: changed writable sources with eight-character
prepared/current commit identities and branch, then reconciliation before
delivery, unknown liveness and qualified isolation evidence. Multiple-source
summaries give the total and direct operators to `act stat TASK`. Long values
use the existing ASCII `...` truncation; narrow headlines prioritize `STALE`.
Independent external-activity warnings retain their full safety contract.
Explicit `act stat TASK` retains full source identities, remote URLs, branches,
SHAs and historical execution/overlap evidence, including renewed validation
before delivery and separate integration/completion authority. Isolation evidence
is historical; liveness stays unknown. Inspection never probes workers or changes
stored state. Effective `status` remains `STALE`; only dashboard presentation
order changes, preserving scheduling order, collision policy and action
eligibility. `next --json` keeps its schema version and adds optional
`lifecycle_status` and `writable_source_changes` facts; consumers must continue
using effective `status` and freshness for eligibility. Existing states need no
migration. Candidates and explicit outcomes retain their existing labels.
Presentation filtering does not alter task state or dependency resolution.
Fresh `PREPARED` rows also show observed overlaps with a fresh
`IN_FLIGHT` or `CANDIDATE` writer with the same authoritative
repository and branch. These terminal-width-aware diagnostics are recalculated
on every status query and disappear with the collision; they do not change the
task's `PREPARED` state. `PREPARED`/`PREPARED` overlap remains advisory, and
explicit `status TASK` shows every overlap without dashboard truncation.

Normal lifecycle: `READY` → `prepare` → `PREPARED` → `start` → `IN_FLIGHT` →
`received` → `CANDIDATE` → `finish` → `COMPLETE`. `received` is shorthand for
the `candidate_complete` outcome, and `finish` is shorthand for the `complete`
outcome. Recorded outcomes, incomplete dependencies, and hard staleness take
precedence over effective `IN_FLIGHT`; the stale human label retains the start
as historical evidence without granting permission to act on stale work.

`bin/agent-coding-tool prepare TASK`

Checks dependencies, resolves exact pushed heads with `git ls-remote`, records
local HEAD/dirtiness separately, and writes/prints a worker prompt into the
external data directory. Preparation warns about writable-authority overlap
with fresh `PREPARED`, `IN_FLIGHT`, or `CANDIDATE` tasks, but remains legal so
the operator can stage later work and choose which prepared task starts first.
When task metadata includes `worker_recommendation`, the terminal output prints
the advisory model and thinking level after the complete generated prompt. The
recommendation is not copied into the prompt file, runtime state, or snapshots,
and manual preparation does not configure a worker. A fresh preparation clears
any in-flight marker and prior collision override record, including when
re-preparing a task without a recorded outcome.

`bin/agent-coding-tool prepare TASK --retry`

Explicitly clears a recorded non-complete outcome and any in-flight marker,
then prepares another attempt in `PREPARED` state. Completed tasks cannot be
retried without resetting their state.

`bin/agent-coding-tool start TASK [--allow-write-collision]`

Human assertion that a prepared prompt has been handed to a worker. Records a
UTC `started_at` without changing the snapshot or prompt. Requires an existing
task and preparation with no recorded outcome; a second start fails with
`already in flight`.

Ordinary manual starts warn and proceed when another fresh `IN_FLIGHT` or
`CANDIDATE` task writes the same prepared `[remote_url, branch]` authority.
Warnings identify the tasks, states and effective authorities, including aliases.
The task-local `write_overlap` observation records `manual_unverified`: it proves
neither isolation nor worker liveness. Use separately isolated development and
preserve one candidate per task. Read/write and read/read overlap remain legal.

`--allow-write-collision` remains accepted as a legacy manual assertion; it
adds no verified isolation. Existing historical override records and prompts
retain their original meaning. Preparation, dependency, lifecycle and freshness
checks still refuse invalid starts before state changes. CLI `start` shares the
launch/delivery reservation lock; a busy lock gives a retryable error.

Collision checks are advisory scheduling safety for a human-operated workflow,
not a process lock or autonomous scheduler. Manual lifecycle commands do not
launch, inspect, or control agents or check liveness. The opt-in launch command
below manages only its own child process. Existing pushed-head freshness
semantics remain authoritative.

`bin/agent-coding-tool launch TASK --codex [--allow-write-collision] [--model MODEL] [--reasoning LEVEL]`

Preparation is a pushed-head/prompt snapshot, not proof that every prepared
commit object exists locally. Its output declares the implementation worker's
milestone and first transfer: focused checks and a canonical-format-checked
candidate, then operator checkpoint registration and host gates. Before native
worktree creation, launch reuses WorktreeManager's parent identity/object check
for every repository it will consume. A missing object reports repository,
exact SHA, local source path and blocked action without fetching or repairing
the source, reserving a worker or creating a partial attempt. Creation rechecks
identity at its mutation boundary. Manual preparation/start do not consume
these objects and retain their existing contracts. Inputs required only for
later validation/publication do not become universal launch prerequisites.

If launch reports a missing local commit, ACT cannot create the worker workspace
from the existing local Git storage. The commit may simply not have been fetched;
this does not establish that the local branch is behind or the repository is
corrupt. Fetch the full required SHA from the configured remote shown in the
error into the exact local repository shown, then retry launch. Pulling,
resetting or switching the ordinary checkout is unnecessary for this barrier;
its HEAD and files need not match the prepared branch. ACT performs no fetch or
repair.

The launch envelope reports actual host checks (roots, prepared sources,
worktree identity, prompt, CLI/authentication and sandbox boundary). Worker-only
tools, including connected GitHub integration, remain **unverified** until
startup: the worker inspects its actual tools and reports absent,
observed-present or unverified with its observation. Host Git freshness and
worker tool observations have separate provenance. Tool availability grants
no permission and never enables shell network, escalation or publication.
Before launching a review-only task, the operator must check that no automatic
delivery contract is configured for it; readiness does not override the
existing separately authorized delivery behavior.

Opt-in local execution for the existing `act` wrapper. Launch prepares READY
work or consumes an existing fresh PREPARED prompt, rechecks dependencies,
remote freshness and collisions, then calls the existing `start` reservation
before delivering stdin to exactly one foreground `codex exec` process.
Launch uses a collision override only for this invocation when
`--allow-write-collision` is present. Managed siblings still require verified
ACT-owned task/attempt evidence, distinct worktrees at the same prepared
writable baseline, and known process state. A manual `IN_FLIGHT` reservation
without managed run evidence may overlap even when its activity is unknown or
active, or its historical preparation differs. The new task must be fresh and
pass every normal native worktree, Git identity, prompt and sandbox check.
The second worker's sandbox probe also denies writes to verified managed
sibling worktrees. Ordinary launch still
rejects a write/write collision; read-only overlap does not require the flag.
The override records task, attempt, invocation, conflicts, authorities and
verified sibling ownership separately from unverified manual reservations in
private handoff evidence and lifecycle state. Manual-overlap diagnostics say
`operator_authorized_manual_overlap`; they never certify the external worker.
It expires with that attempt. Manual `start --allow-write-collision` retains
its human assertion contract and cannot be used to bypass launch checks.
Launch never uses `prepare --retry`. Without an installed
validation contract it retains the NC-02A handoff behavior. **Every attempt
admitted alongside an unverified manual reservation disables managed delivery,
including explicit `act deliver`, even after that reservation ends.** Preserve
the candidate with the existing checkpoint/patch workflow for separate operator
review and integration. No integration, commit, push, PR, task completion,
production or paid-resource authority follows from the flag. Other launches
retain their existing delivery behavior. With a contract,
successful worker exit continues to host validation and draft delivery. The
delivery path can record CANDIDATE only after independently verified publication;
it never records COMPLETE. Existing manual lifecycle commands retain their
contracts; `publish` remains ACTD-only.
Do not use manual prepare/reset/start to change a reservation while its worker
may still be running.

Launch requires at least one writable repository on authoritative `main`. SSH/HTTPS
GitHub remotes and absolute local remotes (for offline fixtures) are supported;
other remote/provider/branch forms fail closed. The ordinary checkout supplies
repository identity according to `repo_root`; its local HEAD and dirtiness
remain observations. Launch creates native Git worktrees under
`/Users/davidnorris/code/ACT-Worktrees/TASK/attempt-N/repository/` by default. Private
ACTD `config.yml` can set a dedicated `worktree_root`. Each writer gets its own
branch `act/TASK/attempt-N` in its separate repository at the prepared pushed SHA; readers are pinned
detached at their prepared SHAs. Missing local commit objects fail closed.
The ordinary checkout is never reset, switched, stashed or cleaned. Occupied
paths and conflicting branches require operator inspection. Project or ancestor
`.codex` project configuration (excluding the normal home authentication store)
and submodules require operator judgment and are not
supported in V1. Read-only snapshots may move and are disclosed in launch/exit
provenance for reconciliation; writable movement before spawn blocks launch.
Required external freshness failures block prompt handoff.
For example, `act launch FO-25 --codex --allow-write-collision --reasoning high`
can develop independently alongside a manually started `IG-19E-F2`. The older
task's lifecycle, prompt, unfinished files, branch and evidence are untouched.
ACT verifies only its new managed worker's boundary. An external process may
have broader filesystem access; ACT cannot retroactively sandbox it, establish
its liveness, or prevent it independently accessing the new workspace. No
quiescence approval or lifecycle update is required. Partial, damaged, ambiguous
or unresolved managed evidence still refuses; it is never imported as manual
work. Manual candidate reservations do not gain this exception. New worktrees
nested inside any existing Git checkout refuse. This does not change the
manual `start` collision contract or authorize automatic integration/publication.

Install Codex and authenticate locally with `codex login` using a ChatGPT
account. Launch accepts the verified Codex CLI 0.162.1 sandbox interface, checks
installed `exec`/`login` help and requires the recognized
ChatGPT login status. It strips API-key and other unneeded environment variables,
ignores user configuration and execpolicy rules, fixes provider/login to
OpenAI/ChatGPT, uses `--sandbox workspace-write -c approval_policy=never`,
disables shell network and broad temporary writable roots, and disables multiple
agents. It grants additional writable roots only for the task's other authorized
writer worktrees and one dedicated per-attempt fixture directory. The launcher
creates `<ACTD>-fixtures/<invocation-id>` outside public source, with private
operator-owned directories, and sets the worker's `TMPDIR` to that exact child.
Only the child is authorized; its container, sibling attempts, host temporary
directories and private ACT evidence remain outside the writable roots. Both
temporary-root exclusion flags remain enabled. Symlinks, occupied invocation
paths, unsafe ownership/permissions, identity changes and overlap with protected
paths (including ACTD, evidence/checkpoints, validation contracts, authentication,
original repositories and shared Git administration) block handoff without repair.
The private handoff records the fixture path and directory identities. Fixture
contents survive success, failure, interruption and retry for operator review;
each invocation creates a fresh root, and existing worktree cleanup does not
delete fixtures. Do not place private evidence in the writable fixture directory.
Before reserving ACT state, a no-inference Codex sandbox
probe uses flat `codex sandbox -- COMMAND` with an explicit
`sandbox_mode="workspace-write"` override. It checks writable access in every writer
and the fixture child, and denied writes to the fixture container, ACTD, ordinary
checkouts, private evidence, each reader and shared Git administration.
Other CLI versions, an unsupported probe or a failed boundary check
blocks worker handoff. The operator's installed Mac CLI must pass this probe.
No API-key billing, cloud provisioning,
profile, arbitrary provider, sandbox escalation or approval override is offered.
The CLI's built-in default model is used unless `--model` supplies an explicit
Codex model ID. `worker_recommendation` remains advisory and is retained in the
handoff; UI model names are never guessed into CLI IDs. `--reasoning` maps
`minimal`, `low`, `medium`, `high`, or `xhigh` directly to
`model_reasoning_effort`. Model/account availability is enforced by Codex;
there is no automatic fallback or retry.

The exact generated prompt bytes go to stdin, followed by a clearly separated
execution envelope binding each writable repository to its isolated checkout.
The envelope identifies host `git ls-remote` checks, discloses the absent
ChatGPT GitHub connector and disabled sandbox network, and requires a limitation
report when required reads, prerequisites or final freshness cannot be proved.
Host checks are never represented as CLI checks. Tasks that require that
connector cannot complete those requirements in this worker. The host checks
refs again at exit, recording movement or an unavailable check; this neither
proves worker reconciliation nor grants publication authority.

Evidence lives in a private sibling `<canonical-data-directory>-runs/TASK/`
directory, outside ACTD and public source, so even `publish --all` does not
select it. Every started attempt has a timestamped directory containing its
`worktrees.json` ownership record, exact prompt and stdin, streamed `stdout.jsonl` and `stderr.txt`, final
response when supplied, and atomic `handoff.json`. Progress streams to the
terminal; the final response is also printed. No credential/environment dumps
are collected. Keep this directory private; it contains task contents and
worker transcripts. Source worktrees live in the separate visible parent.
The record binds task/attempt, real parent repository, remote, branch or
detached status, base SHA, path and access. Fresh-process inspection verifies
Git's registry and these identities. Symlinked, foreign or partial artifacts fail closed and
are preserved. A nonblocking local lock serializes launch reservations.
The lock is released while each worker runs. A running ACT host updates a
private heartbeat every second; a second launch checks its recent heartbeat,
live process group (and parent on macOS), or terminal liveness and Git ownership before
its own reservation. Status labels remain per task; an in-flight or candidate
task with an override also shows its parallel authority. Cancellation and
cleanup target only that task's process group and owned worktrees. A terminal
worker awaiting review may coexist with a second worker while its verified
worktree remains pinned. A candidate whose Git HEAD advanced beyond its
prepared base needs separate review before another parallel launch.
On macOS, the root-owned `/var` and `/tmp` aliases are canonicalized to their
`/private` targets before checking the remaining path components. Arbitrary
symlinks within those paths remain forbidden.

`act worktrees TASK` verifies ownership and shows the worktree inventory.
Each attempt is checked against its original preparation, independently of the
current lifecycle pointers and repository/access declarations. Historical names,
bases and access must agree with the original checksum-bound prompt and native
ownership inventory; an inventory access claim alone is insufficient. Fresh
preparation and launch still use the current task authority. Output includes
execution status, original bases,
resource classification, artifacts, closeout/checkpoint references and blockers.
Verified failures before creation have no invented inventory. A damaged attempt
is reported alongside valid history and makes inspection exit nonzero.
`act cleanup TASK --dry-run` inventories every target and blocker without
changing files, Git state, locks or remote refs. `act cleanup TASK` first checks
the same complete inventory. It requires a completed ACT outcome, terminal
worker evidence with no active or unknown worktree use, clean task worktrees,
verified PR integration into the authorized target (including squash merges),
and an ordinary checkout whose HEAD contains the integration commit. It never
resets or cleans ordinary checkouts. Foreign paths and uncertain evidence block
the entire operation. Native non-forced `git worktree remove` then removes only
the recorded task worktrees, one at a time; an interrupted removal has a durable
marker and is checked again on resume. Feature branches and private handoffs,
logs, validation and PR records remain.

An unsuccessful managed attempt can instead be preserved **in place** for an
explicit retry. For a worker that produced no candidate, the operator sequence is:

```sh
act launch TASK --codex --reasoning high
act worktrees TASK
act record TASK blocked --summary "No candidate; original resources retained." --next "Inspect and explicitly close out before retry."
act close-attempt TASK --dry-run
act close-attempt TASK
act prepare TASK --retry
act launch TASK --codex --reasoning high
```

`failed` and `needs_judgment` are also supported non-complete outcomes. Worker
exit zero, a valid final response and a checkpoint are execution/preservation
evidence; none accepts code, creates a candidate or completes the task. Closeout
never launches a worker, prepares a task, changes lifecycle state, removes a
worktree or deletes a branch. It writes a separate immutable `closeout.json`
binding original run bytes, invocation, preparation, outcome and checkpoint
context. Reports, logs, prompts, partial creation markers and old worktrees stay
intact. Repeating closeout rechecks its evidence; a crash after publication can
be retried without rewriting the record. Interrupted evidence publication before
rename remains a blocker for judgment, with the temporary bytes preserved.

Fresh preparation requires verified closeout of all prior managed attempts (or
verified legacy pre-worker abandonment). It clears current pointers while their
original context remains in private attempt evidence. Preparation, recording,
closeout and managed launch share the reservation lock. Launch independently
rechecks dependencies, skill pins, prompt bytes, source freshness, repository
authority, reservations, Git ownership and sandbox boundaries; it denies the
new worker access to earlier attempts as well as protected shared Git metadata.
Each retry uses new paths and `act/TASK/attempt-N` branches. It cannot reuse an
already attempted preparation. This preserves ACT-15's independently verified
parallel launch and delivery requirements; manual overlap grants no managed
worker privileges.

Closeout refuses tracked, staged, untracked or ignored changes, changed native
HEAD/branch/registry/authority, foreign paths, missing or tampered evidence,
candidate/complete outcomes and existing delivery/validation records. A patch
does not grant permission to discard workspace changes. Verified partial
creation may be preserved for retry, including a native addition whose last
durable marker is `creating`; missing ownership after native mutation refuses.
No unsuccessful-attempt destructive cleanup is added. Normal cleanup and
`abandon-preflight` retain their existing eligibility and liveness gates.

Retry liveness is deliberately bounded: it requires matching host/boot identity,
absence of the recorded host PID, worker PID and worker group, consistent terminal
heartbeat evidence, and available `lsof` observations reporting no worktree use.
Live/reused PIDs, active groups, contradictory records, missing tools or permission
errors block. These observations do **not** prove escaped or reparented descendants
terminated. Non-destructive retry also depends on host sandbox enforcement that
confines surviving processes to their original workspace and protects future
attempts, ordinary checkouts, private evidence and shared Git administration.
Fixture tests simulate that external boundary; actual macOS sandbox and liveness
acceptance belongs to the operator. Closeout grants no destructive authority.

Legacy v1 fixed paths remain authoritative and inspectable. Mixed history with
an intact earlier inventory and a later missing inventory is classified as a
pre-creation failure only after independent path, branch and native registry
checks establish that no later resources were created. Older executed reports
without verifiable host/boot identity remain ineligible for automatic closeout;
inspection explains the blocker. A current state snapshot or human assertion
cannot supply missing original checkpoint or process identity.

For a closed attempt with a valid single-repository checkpoint, select its
original preparation explicitly after a retry clears the current pointer:

```sh
act checkpoint verify TASK --attempt 1
act checkpoint recover TASK --attempt 1 --destination /new/disposable/reconstruction --confirm-disconnected
```

Historical verification is read-only and accepts no workspace. Reconstruction
uses the existing independent clone/patch contract; multi-repository checkpoint
recovery is still unsupported. Publication, candidate acceptance, integration
and `finish` require their existing separate authority.
Interrupted creation preserves its operation marker and any created paths
and branches for manual recovery.

The small `agent-coding-tool-run/v1` handoff is execution evidence, never task
or lifecycle authority. It records task/attempt/invocation identity, timestamps,
host/child PIDs, exact preparation/launch/exit remote+branch+SHA provenance,
argv/model/reasoning, executable/help hashes, process exit code and signal,
final-output validity,
artifact paths, byte counts and SHA-256 identities. `session_id` comes from a
Codex `thread.started` event when present. `jsonl_path` is ACT's captured event
transcript; `session_transcript_path` is null because V1 does not discover
Codex's private rollout path. Missing session metadata is reported as null.
The optional delivery gate independently verifies freshness, artifact integrity
and the human-authored validation contract before publication.
Automatic delivery, explicit `act deliver TASK`, and recovery use the same
fail-closed overlap check under the shared reservation lock. Compatible pinned
ACT-managed workers can retain independent candidates while siblings run or
await integration. Private task/attempt/invocation, distinct worktrees and
task-owned branches, sandbox/process evidence and exact trusted validation
remain required. Unknown manual/browser workers or unresolved execution block
delivery. An advanced sibling HEAD is accepted only when its exact recorded
candidate commit, changed-file manifest, scope, contract and logs still verify;
a distinct branch or disjoint filenames alone do not establish compatibility.
Each mutation boundary rechecks reservations and source freshness. Existing
publication guards still apply independently.
Collision permission does not authorize integration, publication or completion.
If one integration advances pushed main, the other's preparation becomes
stale. Its patch/checkpoint remains recovery evidence and requires explicit
reconciliation and fresh validation against the new head. Deliberately defer
merging each draft until review against current main; a feature push or draft
PR is not merge approval. Do not combine unrelated tasks into one PR. A
multi-repository task keeps one branch/PR per modified repository under its
existing grouped validation contract. Checkpoint recording still supports one
writer and does not replace multi-repository delivery validation.

`status TASK` and `next --json` retain the original prepared SHA, observed main
SHA, artifact, recorded tests and overlaps where available. Missing attempt,
changed-path, isolation or live-process evidence is unknown, never inferred.
Candidate inspection is read-only and does not manufacture integration approval.
`next` prefers uncontended tasks using the existing ranking; additional manual
parallel work is advisory and requires separately isolated development. The
JSON `waiting_capacity` key is retained for compatibility with category
`manual_parallel`. Launch still requires its explicit overlap opt-in and host
verification. Starts, checkpoints and feature delivery never complete a task;
publication, merge and finish each require their own operator authority.

Worker exit retains ACT's IN_FLIGHT reservation. `exited` describes process
termination, including nonzero codes, and never means task completion.
`invalid_final` means the final output is missing, empty or invalid UTF-8.
The command returns the actual worker exit status even in that case (including
zero), prints an explicit error and sets `final_valid: false`; exit zero alone
is not a valid handoff. Child-spawn failure returns 127 with `child_start_failed`
and retains the reservation. Ctrl-C/TERM/HUP forward to the worker process
group, with bounded termination and descendant cleanup; signal exits use
128 plus the signal number. Failed and interrupted evidence is retained.

For a terminal `preflight_failed` attempt, `act abandon-preflight TASK --dry-run`
verifies the original preparation, ownership record, exact Git identities and
clean worktrees, absence of worker spawn/reservation evidence, and process
liveness. `act abandon-preflight TASK` holds the launch lock and uses native
non-forced Git worktree removals, retaining the run directory and feature
branches. Interrupted removal can be repeated; the attempt is marked
`preflight_abandoned` and the task receives a failed outcome. Then
`act prepare TASK --retry` creates a fresh preparation. Active, uncertain,
changed, dirty, foreign and worker-started attempts cannot use this path.
Partial worktree creation remains for operator judgment.

Mac-local acceptance is separate from the offline fake CLI tests. Verify
`codex --version` reports 0.162.1 and `codex sandbox --help` displays the flat
`[COMMAND]...` form. The following no-inference probe uses disposable paths.
It gives the sandbox command a fresh private `CODEX_HOME`, so operator
configuration cannot supply permissions or override the explicit sandbox
settings. The real launch performs the same isolation with a temporary home.
It must print `1` followed by four `0` lines; only `writer/marker` may change
from `seed` to `breach`. Stop before worker launch if the result differs.

```bash
mkdir -p "$HOME/ACT-Worktrees"
nc02d_probe=$(mktemp -d "$HOME/ACT-Worktrees/nc02d-probe.XXXXXX")
mkdir "$nc02d_probe"/{writer,reader,ordinary,evidence,admin}
mkdir -m 700 "$nc02d_probe/codex-home"
for nc02d_name in writer reader ordinary evidence admin; do printf seed > "$nc02d_probe/$nc02d_name/marker"; done
cd "$nc02d_probe/writer"
CODEX_HOME="$nc02d_probe/codex-home" codex -c 'sandbox_mode="workspace-write"' \
  -c 'sandbox_workspace_write.network_access=false' \
  -c 'sandbox_workspace_write.writable_roots=[]' \
  -c 'sandbox_workspace_write.exclude_tmpdir_env_var=true' \
  -c 'sandbox_workspace_write.exclude_slash_tmp=true' \
  sandbox -- /bin/sh -c 'for path; do if printf breach > "$path" 2>/dev/null; then printf "1\n"; else printf "0\n"; fi; done' \
  act-probe "$nc02d_probe"/{writer,reader,ordinary,evidence,admin}/marker
for nc02d_name in writer reader ordinary evidence admin; do printf '%s: ' "$nc02d_name"; cat "$nc02d_probe/$nc02d_name/marker"; done
cd "$HOME"
rm "$nc02d_probe"/{writer,reader,ordinary,evidence,admin}/marker
rm -R "$nc02d_probe/codex-home"
rmdir "$nc02d_probe"/{writer,reader,ordinary,evidence,admin} "$nc02d_probe"
```

Other recovery remains manual. `preflight`, `reserving`, `reserved`, `running`
or `judgment_required` left in a handoff after host failure means liveness is
unknown, even if a recorded PID is absent (PIDs can be reused). Partial artifacts
also require judgment. A host crash or SIGKILL cannot guarantee child cleanup.
Launch will not infer that the worker stopped, erase its reservation, reprepare
or relaunch it, and unresolved evidence blocks the same writable authority even
if manual lifecycle state was reset. Inspect artifacts and independently confirm
that the host, worker and descendants have stopped before resolving anything.
Then record the appropriate ACT outcome explicitly; only a human-reviewed result
should use `received`. For another attempt, use explicit `prepare --retry` after
a non-complete outcome. Preserve and move unresolved/partial run directories to
an operator-managed archive outside the runs root only after that liveness
judgment; launch does not provide an automatic recovery switch. An already
attempted preparation cannot be silently reused. Manual lifecycle commands
remain human assertions, not process locks.

## Canonical worker coding guidelines

Every generated worker prompt includes the complete, unchanged canonical
`skills/karpathy-manning-dtnorris-guidelines/SKILL.md` from
`dtnorris/agent-skills`, including metadata. Inclusion is universal: checkpoint
exemptions and read-only work do not introduce a separate task classification.
Task-specific requirements, safety constraints, Git restrictions and acceptance
criteria take precedence. Existing task YAML needs no changes.

ACT reads the Git blob at commit `e4e92e678b567ceaabe9c9d9c94215f6729099ba`
from the `agent-skills` checkout beside the ACT source checkout. Its SHA-256 is
`5337876cc23dfc7961d21fba3ed01dab50adef98991e02e244b3512f19198982`.
The prompt records both values. The checkout must contain that commit and blob;
its current branch and working-file contents do not affect rendering. ACT
does not fetch, use replacement objects, or fall back to a moving branch.
Missing source, invalid metadata or integrity failures block preparation before
prompt/state writes and block launch before worker reservation or handoff.
Read-only commands that do not render prompts need no skill checkout.

Preparation records the coding-skill pin in private state. Re-preparation and
launch reject a changed pin, and launch retains the existing regenerated versus
saved prompt equality check. Updating ACT's pin requires deliberate review of
the canonical revision and fingerprint; preserve prior prompt/checkpoint/run
evidence before explicitly resetting and preparing affected tasks. Pre-upgrade
preparations must be explicitly prepared again before local Codex launch. No
prepared prompt is silently rewritten by launch. Older prompts remain evidence
of the instructions originally supplied; ACT does not rewrite their history.

## Explicit canonical planning guidance

Authors designate substantial engineering planning, ACTD registration, or
explicit substantial replanning within an implementation assignment with the
optional top-level task field `planning_guidance: required`. This is the only
accepted present value: null, booleans, blank/unknown strings, arrays and mappings
are invalid. Absence preserves existing behavior and complete implementation
prompt bytes. IDs, titles, incidental prose, repository access, checkpoint
exemptions/categories and worker models never activate it. Unrelated valid
metadata remains compatible. Ordinary tasks do not retrieve planning guidance
or depend on its source being available.

Designate assignments requiring architectural decomposition, parallel ownership,
integration dependency resolution or substantial plan revisions deliberately.
For example, a registered registration assignment may propose writable YAML
artifacts for operator review without applying them to real ACTD:

```yaml
id: REGISTER-EXAMPLE
title: Plan and propose ACTD task definitions
planning_guidance: required
depends_on: []
repositories:
  registration-artifacts:
    access: write
  agent-coding-tool-data:
    access: read_only
goal: Propose reviewable YAML task definitions and an integration dependency plan.
constraints:
  - Save proposed YAML only in registration-artifacts; do not register tasks automatically.
acceptance:
  - Include whole-journey acceptance, ownership, dependencies and recovery evidence.
```

This example uses the default required implementation checkpoint. Read-only
planning and explicit checkpoint exemptions can also opt in; preservation policy
and planning guidance are independent. The ordinary implementation control is
[`examples/tasks/EXAMPLE.yml`](examples/tasks/EXAMPLE.yml), which omits the field.

Opted-in prompts retain complete universal coding guidance exactly once and add
the complete unchanged `skills/agentic-task-planning/SKILL.md`, including metadata,
exactly once before the assignment's goal, constraints and acceptance. ACT pins
planning commit `358f7f28ac6f9205227c0378cbf6bb99ad63a179`, SHA-256
`8a726b39a53bb43deebfc3ae81bd70cb657bada4ad69ac83afe35d88539fc009`, in
`dtnorris/agent-skills`. The same offline Git-object verification used for coding
guidance checks the full bytes, UTF-8 and required metadata. Neither pin follows
the source branch or working tree, uses replacement objects/lazy fetch, or falls
back to cached, summarized or substitute guidance. The coding pin remains unchanged.

The prompt requires substantive application before producing plans, task
definitions, dependency graphs, acceptance requirements, ownership/integration
plans or substantial revisions, and requires a concise planning handoff. A link
or nominal citation is insufficient. Task-specific authority, safety, Git and
acceptance constraints retain precedence. A worker discovering new substantial
replanning preserves its diagnosis and evidence and returns to the operator;
discovery grants no authority to edit task YAML, preparation or scope.

`prepare` records `planning_guidance: required` and the verified `planning_skill`
revision/SHA-256 in existing private preparation state. Initial prepare and retry
validate all required material before writing a prompt or state. Re-preparation,
manual `start` and local prompt regeneration reject added/removed designation or
missing/changed required identities. Legacy unopted preparations remain compatible;
absence cannot silently adopt planning. Opted-in manual start additionally verifies
both sources and the whole saved prompt before reservation. Local launch retains
its whole saved-versus-regenerated byte comparison before worker handoff and adds
only the documented execution envelope. These checks do not create a prompt/state
transaction; StateStore still atomically replaces individual state files only.

Pin changes require deliberate source review and operator adoption. Preserve old
prompt, state, checkpoint and run evidence externally before explicit `reset` and
fresh `prepare` when changing designation or pins. `prepare --retry` is required
after a recorded non-complete outcome with unchanged designation/pins; retry alone
does not authorize pin migration. Resolve any active/uncertain worker and follow
the existing recovery safeguards before reset/re-preparation. Historical evidence
is never automatically migrated or rewritten by these checks.

ACT verifies explicit designation, source integrity, prompt inclusion and supported
handoff bytes. The receiving agent remains responsible for applying the guidance;
ACT cannot prove obedience or plan quality. Independently authored interactive
ChatGPT Work prompts are outside ACT enforcement: Project Settings/direct
instructions own their planning guidance. No task creation or new planner is added.

## Worker test performance

Fresh prompts include one shared test-performance section when the task has a
writable repository and requires a checkpoint (including omitted checkpoint
metadata). All-read-only legacy planning/inspection tasks and explicit
`planning`, `inspection` or `no_code` checkpoint exemptions omit it. Writable
tasks without an exemption may authorize executable work; the section applies
only to code or test changes, not planning-only or inspection-only work. ACT
does not infer task types from titles or free-text goals. Existing YAML and
prepared prompt snapshots remain unchanged; normal preparation and local
Codex launch use the same generated prompt.

Workers identify commands, absolute runtime gates and available baselines
before adding or materially changing tests, then report comparable incremental
cost when practical. Passing an absolute gate does not establish acceptable
incremental cost, and a failing baseline does not establish causation or permit
unlimited growth. Match suite/command, source baseline, environment,
dependencies, worker count, modes and contention; prefer repeated timings and
medians when noise or acceptance warrants them, without requiring expensive
reruns of trustworthy evidence. Full-suite growth of both 1 second and 10%,
or 3 seconds regardless of percentage, is an advisory review trigger only.
Task-specific contracts remain authoritative. Preserve meaningful coverage,
failure behavior, essential process integration and all existing gates while
removing demonstrably redundant setup or validation.

A worker must not relax, remove or bypass committed test-runtime ceilings
solely to pass validation. Before implementing an exception, explicit human
authorization must review the old limit and observed baseline, proposed limit
and measured resulting runtime, necessity, cheaper alternatives, and preserved
test/safety guarantees. Task scope alone does not authorize an exception.
This policy adds prompt discipline and evidence-based human review, not a
performance enforcement engine. Report pre-existing failures, new cost,
contention/noise, necessary coverage and missing comparisons separately.
Unexecuted validation is never a pass; missing runtimes need not stop an
implementation, but require truthful outcomes and reproducible operator-side
validation/timing instructions. Existing checkpoint and operator gates still
apply.

## On-demand run evidence

`act evidence` is a read-only stdio MCP adapter over ACT's existing private
run and checkpoint records. It has no launch, validation, mutation, event or
follow-up tools. A worker's recommendation is evidence, not execution authority.
The human asks the browser manager to review each completed task/run.

Before connecting real data, David must approve the concrete connection endpoint,
account, effective **whole personal Work workspace** audience, designated manager,
task set, artifact types, finite limits and teardown. MCP subject/session/context
fields do not authenticate a conversation. This adapter relies on the approved
external ingress to enforce that workspace boundary. WAC-03A qualified that
boundary, not independent per-conversation authentication. Previous trial grants
cannot be reused. Owner approval and native/hosted qualification remain necessary;
offline tests do not establish live compatibility or account isolation.

Create a private operator grant outside repositories/ACTD. This example proposes
30 minutes, 4096 incoming frame attempts, 64 MiB combined incoming/outgoing wire
bytes and 32 MiB decoded evidence for two runs. These are finite upper bounds,
not measured resource requirements. Replace the identity/endpoint placeholders
with owner-approved facts before approval; do not put credentials in the file.

```json
{
  "schema": "agent-coding-tool-evidence-grant/v1",
  "approved": true,
  "session_path": "/private/read-session",
  "data_root": "/Users/davidnorris/code/agent-coding-tool-data",
  "tasks": ["FIRST-APPROVED-TASK", "SECOND-APPROVED-TASK"],
  "artifacts": ["final", "transcript", "stderr", "checkpoint", "candidate", "validation", "validation_output"],
  "transport": {
    "account": "OWNER-APPROVED-ACCOUNT",
    "workspace": "OWNER-APPROVED-WORKSPACE",
    "endpoint": "OWNER-APPROVED-CONNECTION-ENDPOINT",
    "manager": "OWNER-DESIGNATED-MANAGER",
    "audience": "whole-workspace"
  },
  "limits": {"seconds": 1800, "requests": 4096, "wire_bytes": 67108864, "decoded_bytes": 33554432}
}
```

The grant binds one exact `session_path`; copying it to another admission path
cannot reset its budgets. The grant and admission directory must be operator-owned/private (0600 file,
0700 directory). Use canonical paths: on macOS resolve `/var` to `/private/var`
with `File.realpath`, rather than comparing aliases. The parent must already
exist. `start` exclusively creates a new admission; it never overwrites one.
No ACT lifecycle or checkpoint state changes.

The reusable foreground start/status/stop route is `open`. It uses the installed
client's `sample_mcp_stdio_local` contract (`mcp.commands`, `channel: main`),
without historical Downloads files, generated task-specific source, saved-profile
changes or a new hosted tunnel. Grants and exact run selections are data.
Before each session David separately approves the grant's endpoint/account,
whole personal Work workspace audience, manager, tasks, artifacts, finite limits
and teardown. `approved: true` records that decision; key availability is not
consent. Confirm local **and hosted** endpoint idleness, serialize other managers'
connection use and record prior saved settings for owner comparison.

Create one canonical operator-owned 0700 runtime directory outside repositories,
ACTD and run evidence; use this same shared directory for every session.
`open` takes a kernel endpoint lock there and conservatively refuses any other
native `tunnel-client` process. Missing inventory means unknown ownership and
refuses. External clients do not share the lock, so owner-confirmed exclusivity
is still required. Never bypass refusals or signal historical PIDs.

Before live approval, qualify the installed client's `run --help`,
`help quickstart`, Ruby/Bundler, native `ps`, process groups, loopback sockets and
canonical executable paths offline. The client must support
`CONTROL_PLANE_API_KEY`, `health.url_file` and `/readyz`. An upgrade needs fresh
qualification. This example uses the canonical installed binary behind the
Homebrew symlink. After candidate review, qualification and concrete approval:

```sh
act evidence open --grant /private/approved-grant.json --session /private/read-session \
  --env-file /Users/davidnorris/code/agent-coding-tool/.env \
  --client /opt/homebrew/Cellar/tunnel-client/0.0.18/libexec/tunnel-client \
  --runtime-dir /private/shared-evidence-runtime
# In another terminal:
act evidence status --session /private/read-session
act evidence stop --session /private/read-session
```

Stop waits at most one second for ledger lock contention, then commits admission
revocation once and reports that committed snapshot. Sustained contention refuses
with `session.busy`; it never renews a grant or signals a historical process.

`--env-file` is explicit and canonical, even from another cwd/worktree; do not
copy the ordinary ACT `.env`. A **nonblank process `OPENAI_TUNNEL_KEY` takes
precedence**; otherwise the Ruby dotenv gem parses only the requested key.
Command/variable substitution is disabled. No unrelated entries enter global
`ENV`; other ACT commands never load dotenv. Missing, blank, duplicate, malformed,
unreadable or noncanonical file/value refuses before client startup, with no
interactive secret fallback. Nonblank process values must also satisfy the
bounded printable-ASCII credential contract. The file's bytes, permissions and
Git state are unchanged. Host metadata checks must confirm
`git -C /Users/davidnorris/code/agent-coding-tool check-ignore -- .env` names
`.env`, and `git -C /Users/davidnorris/code/agent-coding-tool ls-files -- .env`
prints nothing. Real file presence/permissions and preservation are host-only
checks; implementation tests use synthetic files.

The credential goes only in the client child's `CONTROL_PLANE_API_KEY`. Its
value never enters argv, grants, generated configuration, diagnostics, hashes or
receipts. The configured adapter starts through `env -i` before Ruby starts,
receiving neither credential nor unrelated dotenv values. Client output/logs are
discarded and tracing is disabled. The installed client requires a positive UI
log-buffer capacity; ACT limits it to one in-memory event, rather than disabling
the buffer. Never paste/upload/request the real key or file, and exclude both
from generic file/environment capture.

Keep `open` in the foreground. An independent owner polls durable stop/expiry and
controller pipe loss, and signals only its retained, unreaped direct child's
verified group before reaping it. A failed ownership/group observation remains
blocked. Client `/readyz` HTTP 200 is distinct from successful Work retrieval and
qualified account/audience isolation; admission `active` alone is not readiness.
`tunnel-result.json` in the private admission, also returned by `status`/`stop`, records fixed stage/reason,
admission stop, owned-group signal/reap outcome, retrieval `not_attested`, hosted
shutdown `not_observed` and no saved-settings write. Startup/cleanup failure exits
nonzero; cleanup cannot erase startup failure. The owner independently observes
native owned-process absence, hosted shutdown and preserved saved settings.

`credential.*` errors require checking the explicit host file or process setting;
`tunnel.ownership_unknown` requires native process permissions; `tunnel.occupied`
requires resolving exclusive use; `admission.refused` requires checking the
private grant/paths/scope. The session's bounded `adapter-diagnostics.jsonl`
retains only the adapter's fixed stage enums, across reconnects, without client
output or metadata values. Client delivery (`delivery.failed`), readiness
(`readiness.*`), adapter `metadata.*`/`reader.refused` and cleanup diagnostics
remain separate fixed codes, without raw exceptions or client responses. No
refusal asks for a key in chat or a secret prompt.

Preserve failed admissions; never blindly reopen a consumed grant. A later
session requires a new separately approved grant with a new `session_path` and
the same unchanged `open` command, shared runtime directory and canonical `.env`.
Ordinary approved selections need no repeated consent, source edits, rebuilt
packages or catalog replacement. At most one connection refresh at setup is
needed. Retain ledgers: reconnects/restarts do not replenish budgets.
`status` and `stop` use the durable session path through the supported installed
ACT command, without candidate HEAD/hash checks or historical package identity.
Keep the implementation available during a session for adapter restarts.

The lower-level `evidence start --grant ... --session ...` admission and
`evidence serve --session ...` stdio commands remain for an independently owned
external transport. They do not own a tunnel. `open` owns only its foreground
client/group; preserve all shared infrastructure and saved connection settings.

Select from authoritative `handoff.json` records using **all four** identities;
the CLI and `read_run_evidence` tool use the same resolver:

```sh
act evidence select --session /private/read-session --task FIRST-APPROVED-TASK \
  --attempt 1 --invocation EXACT-INVOCATION --codex-session EXACT-CODEX-SESSION
```

The response displays the resolved binding, immutable `handle`/`revision`, source
hashes and artifact statuses. It refuses absent/ambiguous identities; there is
no global-latest selector or model-supplied source path. For tool calls use
`operation: select` with `task_id`, numeric `attempt`, `invocation_id`, `session_id`.
For `operation: read` also supply that handle/revision, `artifact`, integer
`offset` and `length` (1..16384). `operation: manifest` requires the same binding,
handle and revision. Business fields are closed. A CLI read uses corresponding
`--handle`, `--revision`, `--artifact`, `--offset` and `--length` flags plus the
selection flags above. Explicitly select the second run using the same session;
an existing first-run handle never rolls forward. At most 16 selections are kept.

Bytes are base64, with whole-source and chunk SHA-256, total size, next offset
and complete/truncated/pending/missing status. Empty files are complete bytes.
Files over 4 MiB refuse; task/attempt/session/provenance drift, changed sources,
symlinks, traversal and nonregular files refuse before release. Transcript means
the approved ACT `stdout.jsonl`, never unmanaged Codex rollout discovery.
Checkpoint/candidate evidence comes from an existing launch-bound checkpoint;
each matching finished gate is exposed as `validation:gate-UUID.finished.json`.
Gate receipts report recorded command/candidate outcomes, not independent
revalidation. ACT gate v1 does not capture raw output: `validation_output` stays
missing. Reading runs no validation and cannot manufacture missing checkpoint
evidence from worker claims or arbitrary worker paths.

The permanent private admission ledger stores bounded identities, paths and
hashes, never transcript bodies. It durably reserves requests and byte totals
before release; reconnecting/restarting cannot reset them. Both absolute wall
and monotonic deadlines apply; stop remains a tombstone. One foreground server
holds a kernel owner lock. Stdio EOF/broken output, stop and expiry close it;
the stdio adapter itself has no children to signal. `open` has a separate client
owner as described above. Idle I/O polls stop/expiry at 250 ms. The adapter waits
at most one second for each ledger lock, then checks the original lifecycle and
budgets under that lock. Persistent contention still closes the stream. Waiting
never renews admission or replays a selection, read, reservation or byte charge;
the tunnel owner's independent expiry checks retain their nonblocking reads.
Retain the admission directory through owner closeout; deleting/recreating it is
not a restart or renewal. Changed scope or an extended lease needs new approval.
Fixed bounded stderr stages contain no metadata values, artifact bodies or
private names/types capture. Unknown metadata refuses; documented hints and
A's observed call context are type-checked, capped at 4096 bytes and discarded
before business dispatch. MCP versions 2026-07-28 discovery and the three
qualified legacy initialize versions are supported.

Focused synthetic qualification: `bundle exec ruby -Ilib:test test/run_evidence_test.rb`.
Credential qualification: `bundle exec ruby -Ilib:test test/tunnel_credential_test.rb`.
The native tunnel case exercises public dotenv/client delivery/adapter reading,
two selections and a later grant; only the external client/service and
worker/checkpoint producer are fake. Removing delivery or run binding must fail
that same case. Sandbox-denied native ownership observation is an environment
blocker, not a composed-journey PASS. Real acceptance still needs two separately
approved Mac-to-Work sessions using useful completed runs, host-oracle source
and chunk digests, final/transcript/available checkpoint/validation reads,
explicit missing evidence and a supported next action. Record commands, elapsed
time and operator interventions separately for setup, within-session selection
and later startup. No result upload, body paste or push establishes retrieval.
The native public-entry case fakes only worker/checkpoint production, exercises
real stdio/CLI handoffs and compares returned bytes to independent file oracles.
Actual-host two-run retrieval, account boundary and hosted teardown remain
separate owner acceptance gates, with original run history retained in place.

## Implementation checkpoints

Confined implementation workers stop at a complete candidate when protected
host checkpoint registration is pending. The local launch envelope supplies
exact task, workspace, prepared SHA, remote and artifact paths for:

```sh
act checkpoint export TASK --workspace PATH --base SHA --artifact OUTSIDE_WORKSPACE.patch
```

Use `--remote NAME` when the prepared remote is not `origin`. Export uses the
same canonical patch generator and reconstruction check as checkpoint record,
including new files, full object IDs, binary bytes and no rename detection.
Its temporary index **and objects** live in disposable temporary storage;
shared source Git administration is not written. The output artifact must be
absent, outside the implementation workspace, with an existing real parent.
Failed export retains any bytes already written for inspection; choose a fresh
path on retry. An applicable review diff can have different bytes and cannot
stand in for this canonical artifact.

Export reads no host task/run state and writes no checkpoint/lifecycle record.
It checks the declared local base, content, inventory and reconstruction;
`canonical_format_checked` does not verify prepared authority, pushed freshness
or test success. Set `AGENT_CODING_TOOL_DATA_DIR` to the actual host data root
from the envelope when exporting, so returned commands address that host.
The JSON binds task/workspace/artifact, base SHA, byte count, SHA-256 and changed
files, and returns shell-escaped `host_commands.record`, `verify` and
`gate_prefix`. These are macOS shell-compatible commands; the operator runs
record then verify and appends each required validation argv to gate_prefix.
No test command is guessed. Workers report actual focused checks/results
separately; host checkpoint status remains pending until independently recorded.
Host gated tests, renewed freshness, integration, acceptance and publication
are distinct owner actions. Export never grants protected ACTD writes or
initiates delivery. Exactly one writer is supported by host checkpoint record;
multi-writer candidates retain the existing separate review boundary.

After focused validation of a coherent implementation, the operator can run
`act checkpoint record TASK --workspace PATH` on a local Git checkout whose
HEAD and configured remote match the prepared writable baseline. The optional
`--artifact PATH` must contain exactly the complete generated binary patch.
The command stages the complete worktree into a temporary Git index, including
untracked files, then stores the patch and its baseline, attempt, changed-file
inventory, byte count and hashes in private `<data-directory>-runs/checkpoints/`
evidence. It verifies clean applicability and exact reconstructed content
before atomically pointing to the new immutable record. Refreshing after edits
retains the previous artifact and record. Exactly one writable repository is
supported; other cases fail closed pending a fuller launch contract. When a
matching local launch record exists, recording also verifies that the workspace
is the task-owned writable worktree in Git's registry.

Run `act checkpoint gate TASK --workspace PATH -- COMMAND [ARGS...]` before
each expensive validation command. It verifies the preserved artifact and the
current implementation before and after the command; a missing, changed,
corrupted or non-applicable checkpoint refuses execution. Run `act checkpoint
verify TASK --workspace PATH` again before the final handoff. A failed check
records `stale`; ordinary status displays the last explicit check without
rehashing the worktree. The operator or worker must use the gate: ACT cannot
intercept commands run directly in a shell or validate a browser workspace
that has not been brought to a local checkout. Focused-test success remains a
separate worker report, never inferred from a valid checkpoint.

Each gate invocation retains immutable `gate-UUID.started.json` and
`gate-UUID.finished.json` receipts beside its checkpoint record. Paths are
printed on stderr; the CLI still prints the command's exit code on success.
Read these private JSON files directly, including from a fresh process:

```sh
ruby -rjson -e 'puts JSON.pretty_generate(JSON.parse(File.binread(ARGV.fetch(0))))' /absolute/private/path/gate-UUID.finished.json
```

Receipts bind task, attempt, repository, prepared authority, checkpoint record
and patch hash to an individual invocation. They retain exact top-level argv,
workspace argument, actual cwd when execution is reached, timestamps, and only
the gate process's `TMPDIR`, `TMP`, `TEMP`, `SEED` and `TESTOPTS` settings
(null means unset). Environment inheritance and command execution are unchanged:
ACT still calls `system(*command, chdir: workspace)`, without interception,
redirection, shell instrumentation or additional environment overrides.
Stdout/stderr remain visible and complete output is explicitly **not captured**.
Descendant commands, shell assignments and framework-effective settings are
not inferred from argv or the gate's environment.

`command_outcome` distinguishes not run, failed to start, exited (with actual
exit code), signal (with signal number), and incomplete/unknown. Candidate
pre/post checks are independent: `candidate_validation: passed` requires both
checks against the same checkpoint record and a successful command. A command
pass followed by a candidate change is a validation failure. Exempt tasks have
no candidate and report `not_applicable` on command success. An unfinished
started receipt establishes an invocation attempt, not command completion or
success. Later invocations never overwrite or inherit earlier results. Unsafe
task/evidence context can refuse before any receipt is possible. Receipt setup
and write errors warn that crash durability is unconfirmed, including after a
partial write; they do not mask command/candidate exceptions or change command
returns. Exempt commands can run without receipts when storage is unavailable
or has symlinked ancestry (including macOS `/var`); evidence symlinks remain
rejected, and required checkpoint verification still blocks unsafe evidence.
Inspect retained files before retrying; no persistence redesign or guarantee
against host/disk loss is implied.

Optional gate flags before `--` record operator declarations without changing
execution: `--requested-seed NUMBER` and `--requested-selection TEXT`. These
values do not establish that a test runner used them. For supported observation,
`--observations /absolute/private/attempt/NAME.observation.json` names a fresh,
absent direct child of this checkpoint's private attempt directory (the directory
of the patch returned by `checkpoint record`). Arrange for the command or its
framework reporter to write this file with mode 0600. ACT does not inject its
path into the environment or modify the command. The sole supported format is
a JSON object of at most 8192 bytes:

```json
{"schema_version":"agent-coding-tool-gate-observation/v1","seed":31046,"selection":"subset","summary":{"tests":2,"assertions":3,"failures":0,"errors":0,"skips":0}}
```

Seed, selection and summary are optional or null. Seed is an integer; selection
is a string of at most 1024 bytes. Summary accepts only the shown count keys,
each a nonnegative integer; omitted counts stay unknown. Unknown keys or invalid,
missing, nonprivate, foreign-owned or symlinked reports yield explicit unavailable
observations, without failing a passing command. Reused or foreign report paths
refuse execution. Accepted observations retain their source path and content
hash, labeled **command-reported**, not independently verified framework facts.
The sidecar remains private; its unchecked contents are never copied into a
receipt. Without it seed, selection and counts stay explicitly unobserved. A
request for seed 51565 with reported seed 31046 remains a mismatch; a pass with
different temporary-directory or selection conditions is never called
reproduction. ACT makes no reproduction or root-cause judgment.

Invocation metadata is exact, private operator evidence, not a public report.
Do not put credentials or sensitive values in command argv, the retained setting
names, requested declarations or observation fields. Pass secrets through other
inherited environment variables, which ACT does not snapshot. Omit sensitive
observation fields rather than supplying redacted text as an exact observation.
Review and redact a separate copy before sharing; never publish private receipts
automatically. Checkpoint preservation, command success and human acceptance
remain separate facts; delivery and lifecycle authority are unchanged.

After independently confirming a disconnected worker has stopped, run
`act checkpoint recover TASK --destination PATH --confirm-disconnected`.
Recovery verifies the immutable record and checksum, reconstructs the exact
prepared baseline from the ordinary local repository in an unoccupied
destination, reapplies the patch and compares the complete content and
inventory. It does not change the ACT outcome or resolve uncertain liveness.
The private run root survives deletion of the disposable agent worktree and
ordinary process interruption; it is local to the same host and disk. It
offers no guarantee against host or disk loss, inaccessible browser files or
unverified external retention. Manual `received`, `finish` and `record` remain
human assertions; checkpoint validity grants none of those outcomes.

`bin/agent-coding-tool received TASK --summary "..." --artifact "..." --test
"rake=pass"`

Records that the worker result is ready for human review/application. This is
the preferred human-facing shorthand for `record TASK candidate_complete`; the
stored outcome remains `candidate_complete` and the effective status remains
`CANDIDATE` (or `STALE_CANDIDATE` when freshness requires it).

`bin/agent-coding-tool finish TASK --summary "..." --artifact "..." --test
"rake=pass"`

Records that the landed task is complete on authoritative pushed state. This is
the preferred human-facing shorthand for `record TASK complete`; the stored
outcome remains `complete`, the fresh completion snapshot is captured, and the
effective status remains `COMPLETE`.

`bin/agent-coding-tool record TASK OUTCOME --summary "..." --next "..."
--artifact "..." --test "rake=pass"`

Generic/manual outcome primitive. Valid outcomes: `candidate_complete`,
`complete`, `blocked`, `needs_judgment`, `failed`. The existing `record TASK
candidate_complete` and `record TASK complete` forms remain supported alongside
the preferred shorthands. `--next` stores an optional explicit operator action
for `blocked`, `needs_judgment`, or `failed`; it is rejected for successful
outcomes and is never inferred from the summary.

Every recorded result clears the in-flight marker. `IN_FLIGHT` is not an
outcome, and recording results without first calling `start` remains supported.

`complete` means the human is asserting that the task is complete on
authoritative pushed state; the tool captures a fresh completion snapshot at
that moment.

`bin/agent-coding-tool reset TASK`

Clears runtime state for a task, including the in-flight marker. The task
definition is untouched. A deferred task retains its entire state until explicit
`unicebox`; reset never silently removes scheduling intent.

`bin/agent-coding-tool publish [TASK | --all] [--dry-run]`

Publication is an explicit operator action against the configured data
checkout. Without arguments it commits pending `state/*.yml` and
`state/prompts/*.txt` changes across tasks. With a task ID it selects only
that task's state and timestamped generated prompts. `--all` commits all
ordinary tracked and nonignored untracked ACTD changes, including task
definitions and documentation. Each mode accepts `--dry-run`, which previews
the selected files, existing staged paths, commit/push need, and blockers
without staging or updating refs.

The command verifies the checkout root, expected remote identity, configured
branch, and exact remote head. Narrow modes use a path-specific commit, so
unrelated staged work is preserved; a selected file with conflicting staged
and working versions blocks publication. A previously unpublished local
commit blocks new publication unless it is exactly one commit created by the
same `publish` mode over the unchanged remote base. In that case the command
retries the normal push. No force push, merge, reset, or rebase occurs. A
failed push retains the local commit and reports its SHA; retry the same
`publish` invocation after resolving the blocker. The command reports
`PUBLISHED` only after reading back the remote ref.

## Trusted draft delivery (NC-02B)

An operator can opt a task into automatic delivery by installing a private
`<canonical-data-directory>-validation/TASK.yml` before launch. The sibling
directory must be operator-owned with mode 0700; the file must be operator-owned
and not group/world writable. It stays outside ACTD publication and the
worker's writable sandbox. No ACTD task schema fields are added. The contract
must list authorized source paths, the exact host commands for final acceptance,
minimum test/assertion counts, a runtime ceiling, an optional coverage floor,
and the publication guard. Each listed command must emit a Minitest-style
summary with zero failures, errors and skips; use a suite command, not a
worker-supplied result or a standalone command without counts. The host also
runs `git diff --check`. Example shape (replace all values with the actual
repository acceptance contract):

```yaml
allowed_paths:
  - lib/example.rb
  - test/example_test.rb
base_branch: main
commands:
  - [ruby, -Ilib:test, test/example_test.rb]
  - [rake, test]
min_tests: 1
min_assertions: 1
max_seconds: 120
coverage_min_percent: 90
publication_guard:
  trigger_assessment: "Reviewed workflow and external CI triggers; bounded lease XYZ"
  lease_check: [/absolute/path/to/independent-lease-checker]
```

The example is a format illustration, not a safe default. The host checks
contract identity before and after validation, the prepared pushed SHA, task
authority, native worktree registry, changed paths and file modes. It captures
full stdout/stderr with hashes and timestamps in the private run directory.
Missing, skipped, failed, low-coverage or altered evidence blocks publication.
After validation it rechecks every implementation byte, stages only the
authorized paths and verifies the committed bytes and single parent. Draft PR
content includes the actual accepted command output, exits and log hashes.
Content containing credential patterns or private paths blocks publication
before push; oversized output also blocks instead of silently truncating it.
The local logs retain full output and are never copied to the public PR.

Automatic live push requires an external, operator-controlled checker that
classifies feature-push and draft-PR triggers, including Actions and other
metered services, and verifies a finite cumulative budget and runtime lease
enforced independently of ACT. It receives the remote, mutation kind
(`push` or `pr`) and exact commit SHA. It must classify the exact proposed
commit (including workflow changes) and return JSON with `independently_enforced: true`,
`triggers_classified: true`, `crash_surviving: true`, the contract's exact
`assessment`, the exact `commit_sha`, finite nonnegative `remaining_usd` and
`maximum_additional_loss_usd`, `expected_cost_usd` and
`maximum_hourly_rate_usd`, positive finite `maximum_runtime_seconds`,
and future ISO 8601 `expires_at`. The checker must enforce the stated bounds
outside ACT even if ACT crashes just after publication. A rate cap, a prose
claim, or a checker inside the worker worktree does not supply this guarantee.
No checker is bundled or assumed; absent independent enforcement, the
validated local candidate remains unpublished with evidence retained.

Delivery stages are recorded in private `delivery.json`. If interrupted,
`bin/agent-coding-tool deliver TASK` rechecks the existing worktree, tested
bytes, logs, pushed ref and PR identity without rerunning the coding worker.
It refuses ambiguous runs, competing refs or a changed authoritative main.
Local commit, feature push and PR lookup are verified on recovery. No force
push, automatic rebase, merge or direct main push is performed. A verified
draft PR records CANDIDATE; `finish` remains a human-reviewed assertion of
integration. `act publish` continues to address ACTD alone.

For several writable repositories, the trusted private contract names each
repository's NC-02B validation policy and lists required cross-repository
checks. Each check runs in the named writer worktree; an argv argument can
refer to an exact coordinated path with `{worktree:repository-name}`, including
a pinned read-only dependency. For example, the contract shape is:

```yaml
repositories:
  alpha:
    allowed_paths: [lib/example.rb]
    base_branch: main
    commands: [[ruby, -Ilib:test, test/example_test.rb]]
    min_tests: 1
    min_assertions: 1
    max_seconds: 120
    publication_guard:
      trigger_assessment: "Operator-reviewed independent bounded lease"
      lease_check: [/absolute/path/to/independent-lease-checker]
  beta:
    allowed_paths: [lib/example.rb]
    base_branch: main
    commands: [[ruby, -Ilib:test, test/example_test.rb]]
    min_tests: 1
    min_assertions: 1
    max_seconds: 120
    publication_guard:
      trigger_assessment: "Operator-reviewed independent bounded lease"
      lease_check: [/absolute/path/to/independent-lease-checker]
cross_repository_checks:
  - cwd: alpha
    argv: [ruby, -Ilib:test, test/composition_test.rb, "{worktree:beta}"]
```

The names must exactly match the task's writable mappings. The host validates
every changed writer and every required cross check before the first
publication. One modified writer yields one guarded feature branch and draft
PR; peer PRs link under the same ACT task identity. Partial publication stays
visible in per-repository records and never marks the task complete. The
single-writer contract above remains supported. This example illustrates
shape only: commands, test minima, coverage and lease policy must be set for
the actual task.

**Mac-local pilot, requiring separate authorization:** Install a task-specific
private contract after reviewing the repository's test and coverage rules.
Inspect workflows, webhooks and external CI, then provision and independently
test the bounded lease checker. In a disposable task-owned worktree, confirm
`act worktrees TASK` ownership before running one `act launch TASK --codex`.
Review its private `handoff.json` and `delivery.json`, full validation logs,
feature commit/tree, remote task branch, and draft PR. Exercise `act deliver
TASK` once to check idempotence. Do not use this browser implementation run as
evidence that any Mac pilot or real publication occurred.

## Development

For a bounded Mac-local parallel pilot, run
`ruby -Ilib:test test/parallel_launch_test.rb` in the ACT checkout. It creates
two disposable task definitions, a local bare remote and separate task-owned
worktrees at one pinned commit. A fake Codex worker stays active while the
second launches with the explicit flag. The test checks the collision record,
distinct branches/results, denied sibling and ordinary-checkout writes,
independent process-group cancellation, checkpoint identity and stale status
after a local main push. It also checks that a manual IG-18C reservation remains
unverified during an explicitly authorized AFTEST-01 launch. The worker has a 30-second sleep ceiling, the
second launch is limited to 20 seconds, and no LLM inference, network, GitHub
mutation or paid resource is involved. This pilot does not validate a real Mac
Codex sandbox; that separate host check remains required before operational use.

`ruby -Ilib:test test/integration/manual_parallel_launch_git_integration.rb` exercises cold public CLI
prepare/start/launch/checkpoint/delivery, active external work, different historical
pins, byte preservation, negative controls and preflight races using finite fake
Codex processes and native temporary Git. Sandbox results are simulated there.
For non-inference native macOS acceptance, use the installed Codex 0.162.1:

```sh
ACT_NATIVE_CODEX="$(command -v codex)" ruby -Ilib:test test/integration/manual_parallel_native_sandbox.rb
```

This runs the production sandbox write/deny probe against disposable writer,
reader, ordinary checkout, private evidence, shared Git administration and a
known active external workspace. It launches no model or implementation worker
and contacts no inference service. Unsupported hosts fail rather than skip.
It also requires native fixture create/read/write/delete through the production
`TMPDIR`, and denies directory creation in the fixture container, private data,
evidence, original checkout, reader, shared Git administration, external workspace
and broad temporary roots. Run this command on the Mac host outside Codex;
ordinary tests and sandbox simulations do not establish native acceptance.

ACT-24's separate host recipe is
`test/integration/act24_continuity.rb`. It proposes an offline dirty-candidate
correction experiment; it does not add an ACT continuation command or change
Launcher, delivery, lifecycle or acceptance policy. Review and separately
authorize host execution after preserving the complete implementation with
the checkpoint commands above. Authoring/launch authorization alone does not
authorize this experiment. Run the focused, non-dispatch authoring checks with
`ruby test/act24_recipe_checks.rb`; these do not qualify native confinement.

The public `pin` command prints the digest of production and recipe source.
The public `run` command requires that reviewed digest, the exact installed
Codex executable/hash, and an **absent** `ACT-24-host-*` directory directly
inside the existing `agent-coding-tool-data-fixtures` container:

```sh
ruby test/integration/act24_continuity.rb pin
# Only after separate host authorization, substitute the reviewed literal pins:
ruby test/integration/act24_continuity.rb run \
  --root /absolute/agent-coding-tool-data-fixtures/ACT-24-host-unique \
  --source-sha256 REVIEWED_SOURCE_SHA256 \
  --codex /absolute/path/to/installed/codex \
  --codex-sha256 REVIEWED_EXECUTABLE_SHA256
```

The independently running supervisor creates a 120-second cumulative lease
(plus at most two seconds to confirm cleanup), then qualifies the controller,
worker and test policies before dispatch. These are sibling deny-default macOS
Seatbelt processes, avoiding nested sandbox creation. Unsupported syntax,
filesystem/process/network/secret isolation or process-birth inspection refuses
execution. A live listener and unrelated sentinel qualify denials and owned-only
deadline/cancellation cleanup. Worker/test code cannot write controller jobs,
budgets, ACT evidence, verifier source or Git administration. The controller's
job channel accepts fixed confined fixture operations, never arbitrary host
shell commands; neither external worker nor candidate test can access it.
For this bounded ACT-24 experiment, David approved basic BSD process metadata
visibility. Denial of `proc_pidinfo(..., PROC_PIDTBSDINFO, ...)` is not an
acceptance requirement; `qualification.json` records that limit. This changes
no Seatbelt permissions and makes no claim that other process information is
inaccessible. Foreign signalling, fork, network and protected-file denials remain
required. Supervised controller and job spawns are tracked as direct children
before identity inspection or setup.
Cleanup polls without blocking under one monotonic deadline. Unknown birth or
liveness remains in supervision evidence and blocks further checks, restoration
and redispatch; an unqualified birth permits only wait-owned direct-PID cleanup.

The installed Codex 0.162.1 is invoked for version/help only. The only fake is
the external `exec --json -` / `exec resume --json SESSION_ID -` worker process;
ACT prepare/start/checkpoint record/verify/gate and Git remain real and local.
Explicit-session CLI continuation avoids App Server/Goal state; the recipe
does not qualify native resume, native Goal accounting or real-model judgment.
It spends zero on inference and never installs dependencies, changes private
validation/delivery contracts or accesses the operator's ACTD for execution.

The positive journey uses two turns and one correction, retaining the actual
failed command/output and both replayable candidates, including new files.
One final no-progress fault uses the third turn/second correction and persists
a stop. That correction also interrupts its controller after dispatch, retaining
the pending reservation and proving fresh-process refusal before adopting only
the supervisor-reaped result. Restart/identity/evidence/test-tampering controls cannot manufacture a
PASS. A controller restart after preservation re-verifies the existing record;
unknown dispatch/liveness and human holds refuse redispatch. Public `run`
never adopts an occupied root or resets counters. Internal modes are test glue,
not supported operator recovery commands.

All partial bytes remain under the declared root. `journey.json`, `controls.json`,
`qualification.json`, supervision records, raw captures and immutable ACT
checkpoint artifacts distinguish experimental proof from operator acceptance;
`blocked.json` means the journey was not accepted. A successful recipe still
requires the ordinary implementation's host checkpoint record/verify, required
gated complete/YAML checks, freshness, review and David's acceptance. It grants
no real lifecycle transition, integration or publication authority.

The test commands have distinct contracts:

| Command | Required behavior |
| --- | --- |
| `bundle exec rake` | Validate configured ACTD YAML, then run the same covered ordinary feedback as `test`. |
| `bundle exec rake test` | Fixed ordinary identities with line/branch coverage, runtime reporting, accepted budget and a separate hard hang deadline. |
| `bundle exec rake test:ordinary` | Alias for `test`; the same finite observations and startup execution prohibition apply. |
| `bundle exec rake test:git_contract` | Bounded genuine Git/adapter contracts and direct feedback-verifier controls, with native coverage contribution. |
| `bundle exec rake test:native_integration` | Required native-only offline Git suites, in separate Ruby processes. |
| `bundle exec rake test:all` | Mandatory complete offline acceptance: ordinary, Git contracts, native default complement, then native integrations; each layer once. |
| `bundle exec rake test:integration` | Alias for exactly the same complete gate as `test:all`. |

**Ordinary/default success is insufficient for final integration or delivery
acceptance. Run `test:all` (or its `test:integration` alias) before integration.**
This intentionally replaces the former bare-Rake full aggregate; ACTD YAML
validation remains part of the default. `test:verified_default` retains the
complete default population (ordinary plus native complement). The internal
`test:native_default` task is that complement alone, not an acceptance gate.
The aggregate uses real Rake prerequisites: a failed prerequisite stops the task,
and each prerequisite runs once per invocation. Tests use explicit temporary
data directories and do not depend on personal task data. The publisher tests
in the default suite use a deterministic Git runner fake. Run the offline native
gate when changing Git staging, delivery, checkpoint or retry behavior:

```sh
bundle exec rake test:integration
```

On macOS, shared native test support resolves `/usr/bin/git` through
`xcrun --find git` once and prepends the selected tool directory to fixture
`PATH`, including cold CLI children. This avoids repeating Apple's developer-tool
dispatch while retaining genuine Git processes and checks. A custom Git already
selected by `PATH` keeps precedence. Ordinary feedback performs no resolution.

Use `test:native_integration` for native-only diagnosis. The required
suites can also be run individually for diagnosis:

```sh
ruby -Ilib:test test/integration/publisher_git_integration.rb
ruby -Ilib:test test/integration/delivery_manager_git_integration.rb
ruby -Ilib:test test/integration/multi_delivery_git_integration.rb
ruby -Ilib:test test/integration/checkpoint_git_integration.rb
ruby -Ilib:test test/integration/attempt_retry_git_integration.rb
ruby -Ilib:test test/integration/manual_parallel_launch_git_integration.rb
ruby -Ilib:test test/integration/parallel_delivery_git_integration.rb
ruby -Ilib:test test/integration/icebox_git_integration.rb
ruby -Ilib:test test/integration/apply_handoff_git_integration.rb
```

The retry integration exercises cold public CLI handoffs, native Git ownership,
preservation, negative recovery and historical fixed-path classification. Its
fake worker/sandbox/host-tool boundaries do not establish macOS host acceptance.
The deterministic retry-liveness matrix runs in the normal suite.

`test/required_cases.json` freezes the default and native file/case obligations
retained after the ACTFAST migrations and removal of `RakefileTest`
self-tests. It is an acceptance inventory, not generated discovery output.
The verified tasks reject a missing or unexpected suite file,
an empty inventory, omitted or unregistered case, duplicate execution, failed process,
missing/malformed summary or case evidence, inconsistent counts, zero assertions,
and any skip. Each child uses the current Ruby, `-Ilib:test`, repository cwd and
the passive `test/suite_reporter.rb` Minitest reporter. Raw stdout/stderr are
replayed unchanged; a child's nonzero exit status is preserved (signals map to
128 plus signal number). Evidence binds the fresh invocation and exact selection
to completed `Class#test_method` identities, observed Minitest seed and assertion
counts, independently of the human-readable summary. The complete default
population is partitioned into two interpreters: the ordinary cases listed in
`test/ordinary_cases.json` and the explicit `native_default` inventory in
`test/required_cases.json`. Their disjoint union must equal the complete default
inventory; an omission cannot silently escape into native execution. Native
integrations and Git-contract files run separately to avoid Minitest class
collisions. Existing fixture deadlines remain authoritative. The reviewed
feedback policy supplies a separate, generous hard hang deadline; this is not
the completed ordinary-run budget or an advisory growth threshold.

The ordinary runner puts `test/ordinary_execution.rb` first among command-line
preloads, followed by coverage, before helpers and setup. It also prepends the
guard to inherited `RUBYOPT` for cold children. Ruby 4 executes command-line
`-r` before `RUBYOPT`; relying on the environment alone is insufficient.
The guard refuses native Ruby process
entries, including Git, workers/providers, host tools, forks, Ruby children and
implicit subprocess pipes. The outer Ruby test runner is permitted; an ordinary
test cannot create descendants. Contract/integration and mixed/native selections
retain their real effects in separate interpreters. This is a test dependency
boundary for the repository's Ruby paths, not an OS sandbox against arbitrary
native extensions or FFI.

Ordinary skill setup writes only disposable files. Each case declares its finite
coding/planning read sequence in `test/ordinary_cases.json`; exact argv (including
the offline Git environment), cwd, bytes, outcome and ordering are checked by
the shared observations, with consumption verified after teardown. Tests that
vary source bytes/pins supply their own finite transcripts. The production
`PromptRenderer` defaults to the native `CommandRunner`; it still validates every
pin, hash, UTF-8 document, YAML field and prompt handoff on every render. There
is no production skill cache or native fallback in ordinary tests. Preserve the
bounded immutable-object contract, public cold prompt/consumed-worker journey
and continuous checkpoint/retry/recovery integration when changing this seam.
Use Minitest's standard `SEED=2300` environment setting for comparable runs;
the report records the independently observed seed as well as the request.

### Covered and bounded feedback

`test/feedback_coverage.rb` uses Ruby line and branch coverage. The production
denominator is **every `lib/**/*.rb` file and `bin/agent-coding-tool`** (22 files
at the TST-24 successor baseline). Ruby compiles the complete denominator
without evaluating it; unloaded files retain executable zero-hit nodes. The
outer runner independently compiles the layout and rejects reduced/changed
child layouts. Dependencies, harness code and fixture implementations are
excluded. Case inventories remain separate behavior obligations.

The preload runs before helpers in each suite interpreter and is inherited by
cold Ruby/CLI processes. The icebox CLI fixture preserves it when adding its
own preloads. The checkpoint cold recovery script requires production in its
body, after inherited hooks. A late hook refuses already-loaded production.
Copied production files contribute only after exact byte matching.
Per-interpreter startup/result and first-production-line markers make a killed
ACT-executing interpreter incomplete evidence. Killed fixture-only interpreters
contribute no coverage; their incomplete outcome remains visible. External
non-Ruby programs and fake worker implementations are outside this denominator.

Each invocation retains fresh evidence under the configured temporary directory;
the console prints its location. `report.json` records HEAD/source hashes,
invocation, child argv/cwd/selection, requested relevant environment, observed
seed/status/signal/exception, phase times, sampled owned processes and
instrumented Ruby process counts.
Raw suite stdout/stderr are retained. Native Git internals and arbitrary
descendant command counts are not observed. Ordinary, native contribution and
fresh combined coverage are distinct unions: a source node counts once.
Uncovered coordinates and zero-hit files remain visible. Aggregate test totals
and standard `Line Coverage` output appear only for accepted complete evidence.

The supervisor reads Darwin kernel process birth/parent/group identities through
`libproc` using the locked Fiddle gem. Outer elapsed includes bundle/Rake startup
and advances monotonically after initialization through final report preparation.
Independent host command timing corroborates the remaining final output/exit
overhead. Phase durations are separate. Unsupported or denied native inspection
fails qualification; YAML validation and task listing do not require it.

Each suite starts in a new invocation-owned group. An independent watchdog
tracks observed descendants by birth identity, including other groups, and kills
only that owned group/tree on deadline or interruption. Regular output files
avoid inherited-pipe reader hangs; direct-child reaping has bounded cleanup.
Unfinished stages never establish verification. Arbitrary daemonization that
escapes before ownership observation is not qualified by these controls; host
descendant-containment acceptance remains separate. Production launcher and
ownership checks retain their existing semantics.

David owns acceptance of coverage floors, the fixed runtime reference, completed
ordinary budget and separate generous hang deadline. No production thresholds
are invented by this implementation. `ACT_TEST_POLICY` selects a reviewed JSON
policy; otherwise the runner reads `test/feedback_policy.json`. Missing policy
fails closed. This shape contains **unaccepted placeholders**, not defaults:

```json
{
  "accepted_by": null,
  "hard_deadline_seconds": null,
  "ordinary_budget_seconds": null,
  "coverage": {
    "ordinary": { "line": null, "branch": null },
    "combined": { "line": null, "branch": null }
  },
  "reference": null
}
```

After qualified measurements and David's review, `accepted_by` is `David`,
floors are measured percentages, and budget/deadline are positive finite seconds.
The reference contains `qualified: true`, the accepted report's `conditions`,
`source_sha256` and `outer_seconds`; runs never update it. Runtime, platform,
lockfile, relevant environment, actual selection/seed, fixture policy, workers
and Rake arguments must match for comparable deltas. Unknown contention stays
explicitly unknown; comparison is limited to recorded conditions. Missing
qualification or changed conditions cannot pass an ordinary budget. Growth of
at least 1 second **and** 10%, or at least 3 seconds, remains an independent
advisory, distinct from budget failure and the hang deadline.

For measurement only, `ACT_TEST_QUALIFY=1` with an explicitly chosen positive
`ACT_TEST_HANG_SECONDS` collects evidence and exits nonzero as unaccepted
qualification. It cannot qualify delivery. David must accept a safe initial
hang bound before using this mode; the ten-second ordinary program goal is not
a deadline. Run the accepted ordinary budget gate and mandatory complete/YAML
gates through the checkpoint workflow after preserving the implementation.
Never raise limits or narrow the denominator simply to obtain a pass.

The operator must review private ACT validation contracts using bare `rake`,
`rake test`, `test:ordinary` or native-only commands, and require
`bundle exec rake test:all` (or `test:integration`) with an accessible accepted
policy and full aggregate minima. Delivery refuses this feedback harness's
output without its successful complete-gate marker, including otherwise passing
ordinary totals. Other repositories' validation semantics stay unchanged. The
worker does not edit private contracts; that path remains unaccepted until the
operator verifies it. Offline fixtures do not qualify installed-Codex/macOS
sandbox enforcement.

For the TST-15 handoff, put genuine contract suites in
`test/git_contract/**/*_contract.rb` and supply
`test/git_contract/required_cases.json` as a nonempty JSON object mapping each
root-relative filename to a nonempty array of required `Class#test_method`
identities. This naming keeps contracts outside the unchanged default glob.
Every discovered contract file must be inventoried. No passing placeholder
contract establishes acceptance. TST-16 reconciles the fixed native identities
with its coverage inventory; TST-17/18/19 consume these entry points and must
preserve named coverage when moving behavior. TST-20 owns final coordinated
Rakefile and inventory reconciliation after operator-accepted integration.
An inventory change needs review against original behavior obligations; do not
regenerate it from reduced discovery to make an omission pass.

For TST-17/18/19 integration, David is the single owner of
`test/required_cases.json` updates until handing that responsibility to TST-20.
The migration workers supply their test patches and explicit original-to-destination
coverage tables; they do not independently edit the shared manifest. Use the
existing fixed inventory, with no runner registration extension:

1. Review each original identity and subcase against
   `test/coverage/ACTFAST-native-coverage.md`. Preserve default identities while
   making decision tests faster; register each new native subcase separately.
   For a whole-case move, retain the exact original `Class#test_method` at its
   mandatory destination. Renamed, split or consolidated replacements require
   independent behavioral review and an explicit original/subcase-to-file/identity
   table before any original obligation is removed.
2. Add each new `test/integration/*_git_integration.rb` path and its exact case
   identities to the `integration` object. Preserve all five existing native
   file entries and their cases unless an independently verified replacement is
   accepted. Update default entries only for reviewed moves or new default cases;
   preserve every untouched family. Do not derive obligations from discovery.
3. Compose the reviewed test and manifest changes in the same disposable
   candidate before validation or integration. A manifest entry without its file
   or evidence must fail. Workers may run their own files directly for focused
   development; that is not verified aggregate acceptance. Preserve sibling
   candidates and reconcile the manifest serially after each integration.
4. Run the documented suite commands on the composed candidate. Full native
   and aggregate acceptance belongs to the operator. Refresh baseline and
   preparation when integration advances main; this procedure grants no
   publication authority.

The offline gate does not invoke `manual_parallel_native_sandbox.rb`. Its
separately authorized real-macOS/installed-Codex qualification above remains
required for host operational acceptance. Unavailable qualification means
BLOCKED host acceptance, even if offline gates pass.
`terminal_attempt_reproduction.rb` remains historical characterization, not a
required green gate. Restricted-environment failures must be reported separately
from product failures and do not establish qualified-host success.

V1 intentionally has no database, daemon, web UI, agent API, autonomous
planner, or agent-to-agent messaging. Add those only when
repeated real workflow friction demonstrates a need.
