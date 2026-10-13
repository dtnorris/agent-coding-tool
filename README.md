# agent-coding-tool

A deliberately small, local-first coordinator for a human directing multiple
coding agents.

The source repository is designed to remain safe to publish as open source.
Operational task definitions, project details, generated prompts, and runtime
state live in a separate data directory and are never required to be committed
here.

The opt-in `launch TASK --codex` command runs one local foreground worker.
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
- Starting a prepared task explicitly marks it in flight and rejects fresh
  write/write collisions with in-flight or candidate work unless the operator
  explicitly overrides; no agent liveness is detected.
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
prompt can be handed to a worker. The output also separates capacity waits,
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
Capacity rows identify selected or occupied conflicting authorities. Empty
sections remain empty arrays. Array ordering follows the existing ranked
planner and stable task-store order; no clock-generated plan ID is introduced.
The snapshot states which freshness was observed and that prepare/start must
revalidate. It does not grant authority, launch a worker, or resolve a stale
candidate or human judgment. Malformed or unavailable pushed-head evidence
produces no partial JSON, an error on stderr, and a nonzero exit.

`bin/agent-coding-tool status [TASK] [--all | --active]`

Shows effective task state. The default dashboard includes every non-blocked
active task, the three easiest blocked tasks, and the five most recently
completed tasks ranked by their recorded completion timestamps. Retained
timestamped completions display oldest-to-newest, with the newest at the
bottom. Completed tasks without a usable recorded timestamp remain visible
before the chronological rows in stable task-store order. `--all` shows every
task with the same COMPLETE ordering, and `--active` excludes every completed
task while retaining the three-blocker dashboard limit. The two options are
mutually exclusive. Explicit `status TASK` lookup always shows the named task.

Broad dashboards are ordered for scanability: `COMPLETE`, `CANDIDATE`,
`NEEDS_JUDGMENT`, `IN_FLIGHT`, `READY`, then other active or exceptional
states, with `BLOCKED` last. READY tasks are ranked by immediate
collision-aware parallel unlock width, immediate unlock count, longest
downstream dependency path, then
distinct downstream task count. READY and fresh CANDIDATE rows show downstream
depth/count and `unlocks: N tasks / M parallel`: `N` is the number of
dependency-blocked tasks that would become READY if the row's task completed,
while `M` is the exact maximum subset that could start together without
conflicting with each other or other fresh IN_FLIGHT/CANDIDATE writers under
normal repository-authority rules. For a CANDIDATE, this models the state after
the candidate is finished, so its own current write reservation is excluded.
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

Recorded `NEEDS_JUDGMENT` rows provide a compact operator handoff: a `reason:`,
an optional explicitly recorded `next:`, and the mechanical `resume: act
prepare TASK --retry` command. Each handoff field is normalized to one line and
dynamically truncated to the terminal width with ASCII `...`; the stored values
are unchanged. Use explicit `status TASK` to see the complete, untruncated
summary and next action.

Prepared, in-flight, and candidate tasks are compared against current pushed
heads; writable head movement produces `STALE` or `STALE_CANDIDATE`. Read-only
movement preserves the state with a refresh/reconciliation warning.
Presentation filtering does not alter task state or dependency resolution.
Fresh `PREPARED` rows also show live reasons when normal `start` is currently
blocked by a fresh `IN_FLIGHT` or `CANDIDATE` writer with the same authoritative
repository and branch. These terminal-width-aware diagnostics are recalculated
on every status query and disappear with the collision; they do not change the
task's `PREPARED` state. `PREPARED`/`PREPARED` overlap remains advisory, and
explicit `status TASK` shows every blocker without dashboard truncation.

Normal lifecycle: `READY` → `prepare` → `PREPARED` → `start` → `IN_FLIGHT` →
`received` → `CANDIDATE` → `finish` → `COMPLETE`. `received` is shorthand for
the `candidate_complete` outcome, and `finish` is shorthand for the `complete`
outcome. Recorded outcomes, incomplete dependencies, and hard staleness take
precedence over `IN_FLIGHT`.

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

By default, start fails closed when another fresh `IN_FLIGHT` or `CANDIDATE`
task writes the same authoritative repository and branch. `PREPARED` work does
not block: the first explicitly started task wins. `COMPLETE`, `FAILED`,
`BLOCKED`, `NEEDS_JUDGMENT`, `STALE`, and `STALE_CANDIDATE` do not block.
Read/write and read/read overlap remain legal. Repository identity is the
prepared snapshot's existing `[remote_url, branch]` authority, so different
logical task repository keys that resolve to the same remote and branch still
collide.

Use `--allow-write-collision` only to intentionally run conflicting write work.
When it bypasses an actual collision, the runtime state records the override
time and conflicting tasks/repositories. The flag is per start invocation;
there is no global disable switch.

Collision checks are advisory scheduling safety for a human-operated workflow,
not a process lock or autonomous scheduler. Manual lifecycle commands do not
launch, inspect, or control agents or check liveness. The opt-in launch command
below manages only its own child process. Existing pushed-head freshness
semantics remain authoritative.

`bin/agent-coding-tool launch TASK --codex [--model MODEL] [--reasoning LEVEL]`

Opt-in local execution for the existing `act` wrapper. Launch prepares READY
work or consumes an existing fresh PREPARED prompt, rechecks dependencies,
remote freshness and collisions, then calls the existing `start` reservation
before delivering stdin to exactly one foreground `codex exec` process.
Launch never uses collision overrides or `prepare --retry`. Without an installed
validation contract it retains the NC-02A handoff behavior. With a contract,
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
`/Users/davidnorris/code/ACT-Worktrees/TASK/repository/` by default. Private
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
Launch also rejects overlapping manual IN_FLIGHT reservations when they are
stale: pushed movement cannot prove worker termination. This additional guard
does not change the manual `start` collision contract.

Install Codex and authenticate locally with `codex login` using a ChatGPT
account. Launch accepts the verified Codex CLI 0.162.1 sandbox interface, checks
installed `exec`/`login` help and requires the recognized
ChatGPT login status. It strips API-key and other unneeded environment variables,
ignores user configuration and execpolicy rules, fixes provider/login to
OpenAI/ChatGPT, uses `--sandbox workspace-write -c approval_policy=never`,
disables shell network and temporary writable roots, and disables multiple
agents. It grants additional writable roots only for the task's other authorized
writer worktrees. Before reserving ACT state, a no-inference Codex sandbox
probe uses flat `codex sandbox -- COMMAND` with an explicit
`sandbox_mode="workspace-write"` override. It checks writable access in every writer and denied writes to ordinary
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
On macOS, the root-owned `/var` and `/tmp` aliases are canonicalized to their
`/private` targets before checking the remaining path components. Arbitrary
symlinks within those paths remain forbidden.

`act worktrees TASK` verifies ownership and shows the worktree inventory.
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

## Implementation checkpoints

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
definition is untouched.

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

Run `rake` for the full test suite. Tests use explicit temporary data
directories and do not depend on personal task data. The publisher tests in
the normal suite use a deterministic Git runner fake, so they do not launch
Git subprocesses. Run the slower disposable-repository smoke tests explicitly
when changing Git staging or push behavior:

```sh
ruby -Ilib:test test/integration/publisher_git_integration.rb
ruby -Ilib:test test/integration/delivery_manager_git_integration.rb
ruby -Ilib:test test/integration/multi_delivery_git_integration.rb
ruby -Ilib:test test/integration/checkpoint_git_integration.rb
```

V1 intentionally has no database, daemon, web UI, agent API, autonomous
planner, or agent-to-agent messaging. Add those only when
repeated real workflow friction demonstrates a need.
