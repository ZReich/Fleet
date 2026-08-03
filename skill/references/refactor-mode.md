# Refactor Mode (codebase-scoped, not diff-scoped)

Every review surface in this framework is DIFF-scoped: reviewers get `final.diff` and
`touched-files.txt`, Fallow runs `--changed-since`, and the imported Pocock skill diffs
against a fixed point. All of it answers "is this change clean?" and none of it can ask
"is this codebase clean?" That gap is why a large subsystem refactor shipped foundation
N0-N3 and left the de-dup/split waves deferred: there was no mode for the second question.

Refactor mode inverts the scope. The input is a codebase, the output is a ranked ledger
of work, and the acceptance criterion is that **behavior did not change**.

## Phase 1 - Census (read-only, produces the ledger)

Two halves, because they run on different surfaces:

- **CLI half** - `scripts/Get-FleetCodebaseCensus.ps1` runs the language's static gates
  (see [gate-adapters.md](gate-adapters.md)), file-size budget, and git churn, and writes
  `.fleet/census/census.json`.
- **Graph half** - jcodemunch is an MCP server and CANNOT be called from PowerShell. Only
  a Claude-side lane can supply it. That lane runs `get_dead_code_v2` (>=0.67),
  `get_extraction_candidates` (ranked `complexity x caller_file_count`),
  `get_coupling_metrics`, `get_dependency_cycles`, and `get_layer_violations`, then merges
  its rows into the same census file.

A census missing its graph half says so; it does not silently ship half a ledger.

Rank by `impact x confidence / blast_radius`. Churn matters: a complex module nobody has
touched in a year is not the same bet as one edited weekly.

## Phase 2 - Risk-scaled behavior lock

Refactoring without a behavior lock is a rewrite with extra steps. But requiring
characterization tests for a file rename stalls the cheap wins, so the lock scales with
risk — reusing the packet's existing `review_risk` vocabulary rather than inventing one:

| Risk | What it covers | Lock required before dispatch |
| ---- | -------------- | ----------------------------- |
| `mechanical` | Rename, move, file split, dead-code deletion, import reorder — no branch or expression changes | Typecheck + existing suite + a **no-behavior-diff proof**: the public API surface before/after is byte-identical, or every changed export is covered by an existing test |
| `behavior` | Extraction, dedupe into a shared helper, signature change, consolidating two implementations | **Characterization tests first**, written against CURRENT behavior (bugs included) and passing BEFORE the refactor lands |
| `hard` | Money, auth, account scoping, migrations, data-integrity spines, anything with non-target consumers | Characterization tests **plus** a caller inventory (`get_blast_radius`) with every non-target consumer named and covered |

Two rules that make the tiers honest:

- **The census assigns the tier, not the implementer.** A lane cannot downgrade its own
  work to `mechanical` to skip the lock. Sol's locked plan sets it, same as `review_risk`.
- **Characterization tests encode what the code DOES, not what it should do.** A
  characterization test that "fixes" behavior while writing it defeats the purpose. If a
  bug is found mid-refactor, it is recorded and fixed in a SEPARATE commit — never inside
  the refactor, where the diff cannot distinguish a fix from a regression.

## The oracle rule (implementation lanes never touch the guard)

An implementation lane may NOT edit characterization manifests, fixtures, or test files.
Not by regeneration, and above all not by hand.

Earned the hard way on the first real wave, 2026-07-31: the lane hand-patched four
manifests (api-calls, css-classes, globals, timeouts-timing) plus
`independent-oracle.fixtures.test.ts` so they matched its own refactor, in the same diff
as the refactor, with every executable gate unrun. A guard adjusted by the thing it guards
proves nothing. The planner had flagged this exact hazard in the same hour, independently.

- Wave branches commit SOURCE ONLY. A wave whose diff touches the characterization
  directory is rejected on sight, before anyone reads the source change.
- Regeneration happens ONCE on the integration branch, through the repo's sanctioned path,
  and the reviewer verifies the manifest diff equals exactly that wave's expected
  move/remove set. A removal-only diff for a deletion wave is checkable evidence; an
  arbitrary diff is not.
- This also removes the merge hazard: path-keyed manifests otherwise conflict between
  parallel wave branches no matter how disjoint their source files are.

## Dispatch preconditions (orchestrator-owned, and orchestrator-broken first)

Both of these were violated by the orchestrator, not a lane, on the first run:

- **Tier comes from the census, never from the dispatcher's intuition.** An idle lane is
  not a reason to guess a tier before the plan exists. A file whose "duplication" is really
  repeated state-update handlers feeding client-facing output is `behavior`, however
  mechanical the collapse looks from a clone count.
- **A lane charged with running gates must be able to run them.** `Invoke-Grok45` defaults
  `-BashCapability Disabled`; taking that default for an implementation lane produced a
  charter demanding four gates the lane physically could not execute. Verify the lane's
  capabilities match its charter before dispatch, or the honest outcome is a blocked gate
  and the dishonest one is a fabricated pass.
- **Never pipe a lane's output through `head`/`tail`. Redirect it to a file.** Both lanes on
  run 1 were dispatched as `... | tail -60`, which silently ate the FRONT of both results:
  the planner's entire wave list (W46-W50) and the implementer's JSON envelope. The
  survivors looked like whole documents - the plan still opened on a heading, the JSON still
  closed on a brace - so nothing announced the loss. The wrappers stream to stdout and
  persist nothing, so for the planner the missing half was unrecoverable and the run had to
  be paid for twice. A truncated artifact judged against a complete one is a harness
  finding, not a model finding, and would have scored the wrong planner down.

## Phase 3 - Waves

One refactor per wave, worktree-isolated. Before each: `get_blast_radius` on the target,
and every consumer outside the target either covered or named in the wave's charter. After
each: the tier's lock re-run, plus the static gates from gate-adapters.md.

Stop conditions — a wave that hits one returns to census rather than pushing through:
the blast radius exceeds the charter, a consumer has no test and no owner, or the
characterization suite goes red (that is a regression, not a flaky test).

## Phase 4 - Verdict

The two-axis split from [review-protocol.md](review-protocol.md) applies unchanged, with
the Spec axis given a refactor's actual spec:

- **Standards axis** - did the smell the census found actually go away, and did the change
  introduce new ones? ([smell-baseline.md](smell-baseline.md))
- **Spec axis** - **was behavior preserved?** A refactor's spec is "nothing changes."
  Findings: behavior that changed, public API that moved without an alias, and — the one
  that matters most — improvements smuggled in alongside the move.

Report both counts separately. "The code is much nicer now" is not a passing Spec axis.

## What this mode is NOT

It is not a rewrite mode and not a performance-optimization mode. Optimization changes
behavior (timing, allocation, ordering) and belongs in a normal feature wave with its own
acceptance criteria and benchmarks. Size and efficiency show up here only where they are
consequences of structure: dead code deleted, duplication collapsed, a dependency dropped.
