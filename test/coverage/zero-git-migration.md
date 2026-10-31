# Zero-Git migration contract

This is TST-33's shared capability, provenance and test-boundary contract for
the TST-33–45 program. The prepared ACTD `plans/TST-33-45-fast-suite.txt`
remains normative. Its October 31 zero-Git rule supersedes the older native-Git
requirements in [the historical inventory](ACTFAST-native-coverage.md),
[observation contract](../git_contract/README.md) and README development section.
Those historical records are not rewritten here. This document grants no
publication, task-data or lifecycle authority. Production continues using Git.

## Acceptance and integration ownership

The protected invocation includes wrapper provenance, Rake startup, test helpers,
fixture setup, test bodies, teardown and every descendant. No real Git executable
may run there. Preparatory source inspection and checkpoint export are outside
tests and may use Git. Focused checks are intermediate evidence. TST-45 alone
owns complete integration, whole-command behavior/coverage/zero-Git acceptance,
three profiled and three unprofiled Mac samples and runtime acceptance.

The four inventories remain `ordinary`, `git_contract`, `native_default` and
`native_integration`. Historical native names identify logical obligations;
they grant no exception to zero-Git. The exact ordinary/default complement stays
disjoint. Preserve 256 + 27 + 74 + 102 = 459 original identities, no skips,
filtering, duplicate results or removed scenarios. The 16 separately inventoried
TST-33 verifier cases are additional component checks, not substitutes for these
459 identities. TST-45 integrates their mandatory registration.

[zero_git_inventory.json](zero_git_inventory.json) records every original
layer/file/class/method, method hash/range, documented purpose, assertion sites,
scenario/fault sites, retained identity, migration owner and saved line-coverage
owner. These are source-level assertion purposes, not dynamic assertion counts.
Each row binds its original per-case line map in the hash-identified
`measurements.json`; per-case branch attribution was not collected. Family owners
must attach independently observed replacement/fault results before claiming
equivalence. A declared future negative control is not a passing mutation test.

## Command and effect matrix

The JSON's lexical census retains exact lines and preceding method declarations
for every Git, transport, cached-native, status, fixture-copy, environment and
payload reference in production and executable Ruby harness/support sources,
plus the old and migrated profiler. Comments and diagnostic strings are included
as lexical references, not counted as executed calls. The following matrix
interprets these sites. Dynamic argv are contracts at the real producer and
must be matched by the finite backend; a command absent from this matrix/census
must fail outside `StandardError`, never fall back to native execution.

| Capability and production consumers | Command/effect contract | Required negative effect; owner |
| --- | --- | --- |
| Discovery, authority and freshness: CommandRunner/RepoInspector, WorktreeManager, Launcher, Publisher, Checkpoint, ApplyHandoff, recovery | `rev-parse` top/git/common/admin/object paths, HEAD/parent/tree/symbolic ref; `remote get-url` including push/all; `ls-remote --exit-code` exact branch; `show-ref --verify --quiet`; `symbolic-ref` quiet/detached semantics. Preserve absolute paths, multiline ordering, refs and status distinctions. | Wrong root/common/admin/backpointer, missing commit, detached/unborn HEAD, malformed/duplicate/wrong remote ref or moved authority must refuse before mutation. Boundary TST-34; modeled identity TST-35; families TST-38/39/40/41. |
| Immutable skills: PromptRenderer | Leading `GIT_NO_LAZY_FETCH=1`, `GIT_TERMINAL_PROMPT=0`; `git --no-replace-objects -C ROOT cat-file blob REV^{commit}:PATH`; no cwd override. Raw pinned bytes feed production SHA-256/UTF-8/frontmatter/name/license validation. | Missing object, substituted working-tree text, altered hash, invalid encoding or metadata must refuse. Fake skill revisions must never become harness provenance. TST-37 adapters; TST-41 cases. |
| Status and incidental metadata: IncidentalMetadata and all callers | NUL porcelain v1 including rename/copy pairs, ignored/untracked flags; literal pathspec `ls-files --cached -z` and `ls-tree -r --name-only -z HEAD`. Real traversal, lstat, regular-file and safe-ancestor checks stay in production. | Dropped rename source, non-NUL/malformed status, treating tracked/staged .DS_Store as incidental, symlink/FIFO/unreadable/racing metadata, hidden extra paths must fail. TST-35 state; family owners keep assertions. |
| Worktrees and recovery: WorktreeManager, Launcher, AttemptRecovery, PreflightRecovery, CleanupManager | `worktree add` writer branch or detached reader; `worktree list --porcelain -z`; `worktree remove` with explicit excludes configuration; branch existence; `cat-file -e` commit without replacement/lazy fetch; `merge-base --is-ancestor`. Real .git file, registry/admin/backpointer, permissions, ownership, pending/creating markers, locks, durable state and removal checks remain. | Omit registration/backpointer, wrong shared admin, dirty/ignored state, foreign resources, partial creation/removal, reused branch or changed parent must refuse and retain evidence. TST-35/37 materialization; TST-38 behavior. |
| Index, trees and patches: Checkpoint and ApplyHandoff | Checkpoint's **direct** `diff --cached --quiet BASE` bypass must migrate too. Temporary `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`; `read-tree`, `add -A`/literal forced incidental paths, `update-index --force-remove`, NUL name/status, binary/full-index/no-renames diff; clone/checkout/apply check/apply reconstruction. ApplyHandoff additionally uses raw stdin patch bytes for stat/numstat/check/apply, write-tree, staged/unstaged/untracked/ignored inventory, index binary diff and scoped commit. | Known-patch hashes must bind base/tree/path/mode/bytes. Missing/extra changes, wrong base, changed stdin, binary/mode/add/delete/rename corruption, unrelated index damage, traversal/symlink or omitted staging must fail independently. TST-36 golden transitions; TST-39 product journeys. |
| Commit and publication: DeliveryManager, MultiDeliveryManager, Publisher | Stage exact scope; inspect `show :PATH`, `show HEAD:PATH`, `ls-files --stage`, `ls-tree`, `diff-tree -z`, parent/tree/message/trailers. Preserve literal paths, no-hooks/no-signing flags, commit-only paths, intent-to-add/reset restoration. Delivery's **direct** cat-file check and GitHubDeliveryProvider's **direct** push with absent-ref force lease are separate bypasses. Remote state is shared and future reads observe mutations. | Incorrect parent/tree/blob/mode/path/trailer, omitted stage, unexpected remote ref, raced lease, publication before validation, sibling byte/mode/evidence change or idempotence failure must fail. TST-35/36 model; TST-40 behavior/provider fake. No provider call is authorized here. |
| Generic process transport: ApplyHandoff, Checkpoint validation, Launcher, retry/liveness, providers | Preserve distinct non-Git paths: ApplyHandoff `execute(argv,cwd:,env:,input:)` and native popen3; checkpoint `system` validation; delivery popen3 validation; launcher cached `Process.method(:spawn)`, version/help/login/sandbox probes; ps/sysctl/lsof, provider gh/custom commands. argv, leading env, cwd, stdin, timeout, pgroup/unsetenv_others/redirection options and exceptional spawn failures remain inputs. | Do not replace public parser, refusal/consent or persistence. Real approved Ruby processes own transport bytes, EOF/signals/status, live PID/group/locking/cold recovery assertions. Arbitrary validation payloads need exact reviewed script identities; no executable-only or arbitrary `-e` grant. TST-37 bootstrap; TST-42 process-cost owner; TST-34 result protocol. |

Native results currently differ by seam: CommandRunner returns raw streams plus
boolean/nil success; direct Open3 consumers use genuine `Process::Status`;
ApplyHandoff's explicit transport returns raw streams plus integer exit or
128+signal. TST-34 owns the common result protocol and translates genuine native
status at the boundary. No fake Process::Status, dummy child solely for a status,
truthy success substitute or default empty result is allowed. Exceptional missing
executable/cwd remains exceptional. Independent raw-byte assertions must cover
NUL and invalid UTF-8 stdout/stderr, nonzero, signaled and exceptional outcomes.

## Bootstrap, fixture and descendant inventory

These are migration requirements, **not hidden harness exemptions**:

| Existing surface | Boundary and handoff |
| --- | --- |
| `feedback.rb` | Parent HEAD and `git --version` execute before any case. TST-43 replaces both with `SourceIdentity.capture(root: actual_source_root)`, keeps all-file line/branch denominator including unloaded `lib/**/*.rb` and `bin/agent-coding-tool`, and reports unavailable Git version/changed comparator conditions. Do not insert fake fixture HEAD/version. TST-33 deliberately does not edit the shared harness. |
| `test_helper.rb` | Darwin xcrun discovery and git_seed init/config/add/commit/clone/remote/rev-parse must disappear from test setup. TST-37 owns this helper. No native baseline rerun is permitted. |
| `coding_skill_support.rb`, live skills and source observations | Native skill init/commit/revision, per-suite fixtures and inherited RUBYOPT need TST-37 conversion. Ordinary finite observations remain strict; production pinned-source parsing remains real. TST-41 migrates skill cases. |
| `launcher_support.rb`, `manual_overlap_support.rb`, recovery/apply/publisher/retry helpers | Cached original Open3 capture, fixture commands and fallback-to-original captures can bypass high-level mocks. All are in the census. TST-37 owns shared adapters; family workers return API gaps to that owner. Unknown operations raise; no native fallback. |
| `GitContract::Native`, contract recorder and observations | No native Git recording even to make a transcript. Existing capture3 demands genuine native status, and `recovery_observations.rb` manufactures cached statuses through Ruby children. TST-34/37 replace modeled command statuses with the declared result; retain a bounded actual child when status.pid itself proves liveness. TST-41 owns remaining contract cases. |
| Direct `.git` changes and `FileUtils.cp_r` | Sources include apply_handoff_support, launcher_support, retry_decision_support, apply_handoff_contract and family attack fixtures. Copies must clone the model's mutable world as well as materialized bytes; config writes must update the declared adapter. Corruptions of actual .git pointers/ownership/permissions remain physical attacks and must not be silently repaired by a getter. TST-35/37 materializer; consuming family verifies refusal. |
| Inline children, cold CLI, worker and validation strings | These occur inside test methods/helpers as well as integration files. The census includes nested `-e`, shell/backtick, env wrappers, absolute Git and validation payload references. TST-37 converts declared scripts to guarded bootstrap; TST-42 retains necessary process properties. No script may clear guard/coverage or route unknown requests to native Git. |
| Rakefile, suite_runner, suite_reporter, feedback_coverage/runtime | TST-43 owns wrapper/child creation, coverage source identity and all-file denominator; TST-45 makes preloading mandatory at the public command after migration. Ordinary remains all-process prohibited. Preserve independent case evidence, true child status, unique invocation/selection and fresh coverage. |
| External profiler | Original wrapper hash `694962657fa08f39c190405ad991cd77f8f9a755a3ce9b197d23477c9078b17b` executes Git for root, HEAD, index and status before/after the suite. `test/profile_zero_git.py` removes those operations and preloads the guard before the unchanged observer. `--inspect-only` is safe focused provenance validation; full mode remains fail-closed on the unmigrated parent harness until TST-43/45 integrate permits. Observer string bytes remain identical; wrapper/preload/status conditions changed and need separate comparator review. |

## Guard API and scope

Preload `test/support/no_git_execution.rb` before Rake, helper and production
loading. Activation is selective in this candidate. The guard denies all external
execution by default, including shell/env wrappers and absolute paths, rather than
trying to recognize an executable called Git. `OrdinaryExecution` continues to
deny **all** processes, including approved Ruby scripts.

A trusted test composition root creates `NoGitExecution::Permit` with a reviewed
absolute script SHA-256, exact string arguments, reviewed preload path/hash map,
environment changes and process options. Use `with_permit(permit)` around the real
Open3/Process spawn with `permit.environment`, `permit.argv` and `permit.options`.
The guard validates current executable/script/preload bytes and canonical paths,
cwd, effective environment and exact arguments/options at consumption. Only live
Open3 IO pipes may be added for stdin/stdout/stderr. Extra process options refuse.
Script arguments follow `--`; `-e`, shell dispatch and executable-only permits
are not APIs. Permits consume one native spawn in the issuing thread; reuse or
failure to consume refuses. A missing cwd still raises genuine ENOENT.

Ambient RUBYOPT accepts only explicit reviewed `-rABSOLUTE_PATH` tokens naming
the guard or supplied preloads; other forms fail closed. TST-37/43 must explicitly
review/normalize bundler, skill, observer and coverage preloads at composition.
Every approved child gets the guard first in both command-line requires and
RUBYOPT. A present coverage context additionally requires the canonical source
checkout's feedback_coverage preload; a matching basename elsewhere is insufficient.
An inherited context must survive unchanged in the actual child environment.
Deletion or replacement refuses before spawn, including when `unsetenv_others`
requires the caller to forward the context explicitly. Approved coverage children
are verified through active instrumentation and fresh execution evidence.
Inherited environment changes and removal of bootstrap cannot borrow a permit.
No non-Ruby executable is currently allowlisted. Add a new executable boundary
only with explicit owner-reviewed descendant-protection requirements.

Native C-entry observation rejects cached original Process/Kernel/IO methods
that bypass Ruby wrappers; the approved wrapper authorizes only its single
checked spawn C entry. Kernel system/exec/backticks/fork/daemon, Process equivalents,
IO.popen and PTY spawn remain denied. Pipe-capable IO class methods/Kernel.open
require checked String file paths. Their cached originals are conservatively
denied even for file reads; normal wrapper-mediated file reads preserve bytes.
File.open itself does not interpret pipe syntax.

`ProhibitedExecution < Exception` escapes product StandardError handlers.
`audit` records internal Ruby wrapper/C-entry decisions without raw argv/env
secrets. An ALLOW means the Ruby boundary authorized an entry, not proof of OS
execution (another guard or native ENOENT may still prevent it). Independent OS
process-creation tracing is **UNAVAILABLE** here. This is no OS sandbox and cannot
protect against arbitrary native extensions, deliberate disabling/redefinition
of guard internals or external non-Ruby launchers. It protects the declared Ruby
execution mechanisms; do not label its log independent OS evidence.

## Source provenance and evidence retention

`SourceIdentity` takes an explicit actual source root and ignores cwd, GIT_DIR,
GIT_WORK_TREE and product/fake runners. It reads normal .git directories, gitdir
pointer files, relative/absolute worktree paths, commondir, detached/symbolic HEAD,
loose and packed SHA-1 refs and hashes source/index/consumed metadata bytes.
Source hashes remain available when metadata is absent/unsupported. Unborn,
cyclic, malformed, symlinked, unsupported extensions/format/reftable/SHA-256 or
unreadable metadata returns an explicit UNAVAILABLE reason with no invented HEAD.
Worktree cleanliness and installed Git version are UNAVAILABLE, not inferred.
Hashes identify current bytes; they do not attest to an unmodified commit tree.

The saved original artifacts were recovered from
`~/Downloads/ACT-test-profile-20261031T130405Z-9x33ucbs/`, alongside
`~/Downloads/act-test-profile.py`. Their hashes are in the JSON. The existing
policy at the original source checkout matches saved policy SHA-256
`5921d925ea0ba3439944cfe1ab485224c87c747dbb03b15abd495fd85b45e573`.
It records floors 52/38 ordinary, 94/78 combined, ordinary budget 8s and separate
hard deadline 500s. No candidate policy, new acceptance or replacement reference
is installed. Original profiled PASS: 459 cases / 10,819 assertions, 5364/5617
lines, 2397/3001 branches; wrapper wall 302.8404974169971s, official outer
302.82965112539574s. These clocks differ and must stay separately labeled.

[zero_git_baseline_nodes.json](zero_git_baseline_nodes.json) reconstructs exact
aggregate covered nodes from the 16 same-invocation saved layouts minus the
official combined uncovered-node lists, checking the recovered counts. All 28
production file hashes still match the saved run, including the executable.
This recovers aggregate node identities; per-case branches remain unavailable.
The saved observer supplies per-case line hits, not current replacement coverage.
TST-44 verifies retention against these maps; aggregate percentages alone cannot.

Workbook rows and the current exact partition match 459 identities / 43 files.
Saved source is ACT `7dd8a1a…`; the prepared candidate is `194debd…`.
TST-30's integration source changed, retaining its identities; the prepared
commit contains its decision-helper/cold-launch reductions. Original policy was
an ignored local file and is absent from the isolated checkout. Current TST-30
ACTD state is complete; its retained checkpoint is historical evidence, not an
unapplied patch to replay. No historical state is modified. The supplied
TST-30 11,214-assertion PASS is a different run from this profiler's 10,819.

Saved conditions include Ruby 4.0.6 arm64-darwin23, workers=1, per-process random
seeds recorded in the JSON, fresh native fixtures and unobserved contention.
The policy comparison already reports changed conditions for the saved profile;
its ordinary reference is not a new full-suite reference. TST-08's older
175 Ruby captures/47.775 inclusive seconds and 0.087407s native fsync are historical
diagnostics only. No exact host contention/cache/thermal equivalence or variance
is established. Relative candidate improvement, current coverage and complete Mac
runtime acceptance remain NOT RUN / NOT ESTABLISHED until TST-45's host gates.

Rebuild the inventory with `python3 test/support/inventory_zero_git.py`, supplying
`--artifacts`, `--profiler` and `--policy` pointing to those preserved inputs.
This reads source/JSON/XLSX only. Run `ruby test/support/verify_zero_git.rb --seed
2300` with this attempt's writable TMPDIR for focused checks; it loads no legacy
test_helper and reconciles its own fixed case manifest and independent reporter.
Set ZERO_GIT_EVIDENCE and ZERO_GIT_AUDIT to fresh external paths for raw evidence.
Neither command discharges full acceptance. Preserve the complete candidate using
ACT checkpoint export; operator record/verify and gated acceptance remain separate.
