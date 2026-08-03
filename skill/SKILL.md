---
name: fleet
description: An opinionated way to build and research with your whole model fleet as one team — planner, implementer, supervisor, and a blind cross-family review panel, so no model grades its own work. Codex-native: Sol plans and owns the final verdict, Terra supervises, Grok implements, Spark/Kimi/Gemini gather evidence, and every change runs risk-scaled adversarial review that can't be skipped.
---

# Fleet Orchestration for Codex

Source lineage: adapted from `$env:USERPROFILE/.claude/skills/fleet/SKILL.md`.
Design doc: `$env:USERPROFILE/Documents/docs/superpowers/specs/2026-07-03-fleet-orchestration-design.md`.

## Purpose

Fleet is an opinionated way to build and research with a whole team of models instead
of one. It started as a way to actually use every model seat we pay for; it is now a
methodology: split planning, implementation, supervision, and review across different
model families so no model grades its own work, run the independent parts in parallel,
and call nothing done until the evidence says so. What follows is that methodology on
the Codex surface.

Run the fleet from Codex without requiring Claude Code, Opus, or Fable for execution.
GPT-5.6 Sol plans and returns for final verification. GPT-5.6 Terra supervises
execution. Claude Opus 5 is the Opus final-review voice (Opus 4.8 = fallback).

Use Grok 4.5 as the default implementer for non-design work. Give it one cohesive
charter; split only independent boundaries or measured context/tool bottlenecks
instead of routing routine implementation to Terra or Luna.
Never assign Grok design judgment.

Kimi K3 is a measured design/plan candidate, not an automatic replacement for
Sol. Read references/kimi-k3.md before selecting it.

Ponytail rule: avoid extra lanes that do not pay for themselves. Trivial
deterministic lookups stay in local tools; do not spend a model call.

Harness law (twice-proven 2026-07-18): the harness moves a model's score more than the
model does. Grok scored 75.5 (last) as a reviewer forced through the implementation
worker-JSON envelope and 94 (co-first) run free-form on the same task; Gemini's
fabrication went 4/4 to 0/4 from one cite-verify rule. THEREFORE: review, analysis,
research, and plan-critique lanes ALWAYS produce free-form markdown; the worker-JSON
envelope and "Return only the JSON object" are for IMPLEMENTATION lanes only. Any
machine-readable review metadata is parsed wrapper-side or requested as a small trailer
block after the markdown, never as the primary output contract. Before scoring or
routing any model, verify the harness fits the task type: a low score in a mismatched
harness is a HARNESS finding, not a model finding.

## Non-Negotiable Contract (read first, enforce last)

This block is the short list the orchestrator MUST satisfy on EVERY run, no matter what
the deep sections below say or how long the run got. The detail lives downstream; the
mandates live here so a long run cannot drift past them. Before you say "done", "ready
to merge", or "ready to push", every line here is already true — or you are not done.

### Definition of Done — no completion claim without these quoted lines

A run is NOT complete, mergeable, or pushable until each gate below has RUN against the
shipped diff and its summary line is quoted verbatim in the Final Report. A missing line
means the gate did not run: that is a blocker, not a pass. Never substitute your own
reproductions, tests, or "I verified it myself" for the review gate — self-review is not
an independent voice; it is the exact claim the review exists to check.

- `fallow audit` (JS/TS changed code, from the package root) → quote `fallow: N new
  findings`; non-JS/TS quote `static-gates: N/5 measured` per gate-adapters.md.
- `Assert-FleetFileSize.ps1 -BaseRef <base>` → quote the `filesize:` line.
- `Assert-FleetLaneSpans.ps1 -RunId <id> -LedgerPath <l> -ExpectedLaneManifest <m>` →
  quote its summary line (proves every expected lane actually ran, not just the cheap ones).
- `Assert-FleetAdversarialReview.ps1 -Repo <repo> -BaseRef <base>` → quote its summary
  line. This proves review receipts EXIST and COVER the current diff (older-diff receipts
  do not count). MICRO is the ONLY exemption and must say so: "MICRO: deterministic gates
  only". Everything above MICRO needs real voices — see the Lane Utilization Contract.
- Tests / build the repo defines → quote the count WITH a denominator (`tests: 274/274`);
  a zero or missing denominator did not run.
- Append at least one LESSONS.md line whenever the run had any retry, timeout, or
  substituted voice — a run with retries and no LESSONS entry is an unfinished report.

The adversarial review is a STANDING step after every coding/fix/config wave — not
something the user has to ask for, and not optional because tests are green. Runs that
shipped with zero review receipts are the exact failure this gate exists to stop (see
"Adversarial Review Is Not Optional").

### Lane Utilization Contract — the tier names the voices, and you WILL dispatch them

Running one model when the tier calls for five is a defect, not a shortcut. Per tier,
these lanes MUST be exercised through the canonical wrappers — never raw CLIs, never a
single-model collapse:

| Tier | Voices that MUST run |
| --- | --- |
| MICRO | deterministic gates only — state it explicitly, zero model voices |
| LIGHT | Sol + fresh Terra; +1 cross-family (GLM via `Invoke-PiGlm.ps1`) when behavior is touched |
| STANDARD | Sol + Terra + one specialist third voice by change type |
| FULL | all five blind voices in ONE concurrent wave — `Invoke-Sol.ps1`, Terra (`codex exec`), `Invoke-Opus48.ps1 -Model claude-opus-5`, `Invoke-PiGlm.ps1`, `Invoke-Grok45.ps1` — plus the `Invoke-KimiK3Proxy.ps1` non-gating data seat. Security triggers add `[GLM 5.2 · SECURITY]` + `[KIMI K3 · SECURITY]` by default. |

Implementation default for non-design work is Grok 4.5 via `Invoke-Grok45.ps1` (one
cohesive charter + one structured self-review) — NOT Terra implementing inline. Design,
API, and architecture judgment route to Sol and never to Grok. A down voice is
substituted (GLM cross-family) and recorded `voice_substituted`, never silently dropped.
Every dispatched lane is a visible model-first labeled task. See Routing for the full table.

### Plans are maximally parallel by default

Every wave plan MINIMIZES the critical path: maximize the tasks that can run
concurrently, minimize dependency edges, and split disjoint file scopes into separate
same-wave lanes. A dependency edge is a cost that must be justified — task B depends on
task A ONLY when B genuinely consumes A's output or writes the same files. "Feels safer
to serialize" is not a dependency. See Phase 2 for the wave-graph fields and the
anti-serialization validation gate.

### Review rounds are bounded and reviews review a frozen diff

- Max 3 re-review rounds per run. Round 4 does not exist: stop, report unresolved
  blockers to the user, escalate. A new run (new run-id, new plan) is the only way
  to continue.
- The diff is FROZEN during review. Repairs are limited to verified findings — no
  new features or refactors mid-review. Shipped-diff growth >10% (bytes) since the
  frozen packet means the review target no longer exists: abort the rounds, start
  a new run.
- A review round only COUNTS if every expected lane produced a non-empty verdict
  or is explicitly recorded `voice_substituted`. Run
  `scripts/Assert-FleetLaneCompletion.ps1 -LaneDir <round dir>` before consuming a
  round; a 0-byte or missing lane output is a dead lane — substitute immediately
  with a labeled voice (record `voice_substituted`), never a silent ad-hoc file.
- Sol is plan + final verdict by default. If Sol (or any voice) times out as a
  review voice, substitute instantly (Terra or GLM, labeled `voice_substituted`)
  and let the round complete — never hold a round waiting on a dead voice.

## Modes / Tiers

`auto` default: Sol selects the tier from the evidence brief in the same planning
call (MICRO bypasses Sol via a mechanical pre-check). Read
[references/mode-selection.md](references/mode-selection.md) before dispatch;
uncertainty selects the higher tier. Four tiers replace the old binary light/full,
and `review_risk` sizes the voice count within a tier, not just timeouts:

SCOPE, before tier: every tier below is DIFF-scoped ("is this change clean?"). Work whose
input is a codebase rather than a diff — dedupe sweeps, dead-code removal, splitting a
subsystem — runs [references/refactor-mode.md](references/refactor-mode.md) instead:
census, a behavior lock scaled by `review_risk`, then waves. Its Spec axis is "behavior
preserved", not "feature delivered".

STATIC GATES, before quoting one: Fallow only understands JS/TS. On Rust, Python, or
PowerShell the gate contract is the five dimensions in
[references/gate-adapters.md](references/gate-adapters.md), and an unmeasured dimension
is a WATCH, never a pass. Quote `static-gates: N/5 measured`, never a bare zero.

- `MICRO`: <=2 files / <=15 lines / STRICT no-behavior class (comment, whitespace,
  rename, type-only, docs) / no risk path / no new dep / Fallow-clean. A constant/config
  edit or dependency bump is NOT MICRO (may move a prod knob) unless provably inert ->
  LIGHT. Direct edit, no Sol plan, zero model voices (deterministic gates only; one fast
  blind pass if user-facing). Any doubt escalates to LIGHT.
- `LIGHT`: mechanical, reversible, one bounded wave, decisions locked. Compact Sol
  plan -> Grok + self-review -> Terra gates -> 2 voices (Sol+Terra), or 3 with one
  cross-family voice when behavior is touched.
- `STANDARD`: behavior-changing/multi-file/uncertain-but-reversible. Light flow plus
  one specialist third voice by change type.
- `FULL`: any security/auth/secret/privacy/payment/migration/infra/cross-repo/public-
  API/unresolved-design/unknown-blast-radius trigger, explicit user request, or
  `review_risk=hard`. Sol wave graph -> waves -> gates -> all five blind voices in ONE
  concurrent wave -> Sol arbitration.
- `review`: no build. Snapshot the diff/PR, freeze the packet, run the tier's blind
  voices in one concurrent wave, consolidate fixes.
- `plan`: no build. Completeness-first planning for BIG projects only (explicit
  `fleet plan` or Sol judges big/ambiguous/long-horizon). Shared cheap evidence pack
  -> six-seat blind diverge (Fable, Sol, Grok, GLM, Kimi proxy, Gemini 3.1 Pro High)
  -> Fable union-biased merge with provenance + gap-hunt -> FULL blind attack against
  the coverage matrix -> Sol xhigh ratify with design-brief (Kimi) and wave-plan
  (Grok) handoffs. Read [references/plan-protocol.md](references/plan-protocol.md)
  before dispatch; never claim full-panel coverage with a missing seat.

`light`/`full` remain accepted aliases for LIGHT/FULL. An explicit user tier overrides
auto. Any higher-tier trigger discovered mid-run escalates immediately; never downgrade
a running higher tier.

Do not spawn an Opus/Fable/Claude supervisor. Opus is review-only. Pi is the only
GLM transport in this Codex workflow.

## Phase 0 - Preflight

1. Read `$env:USERPROFILE/.codex/skills/fleet/LESSONS.md`.
2. Check dirty state. Proceed on clear, reversible work; avoid mixing unrelated changes.
   Before any lane dispatch, create one run lease with
   `scripts/Enter-FleetRunLease.ps1 -RunId <run_id>` and retain that run ID through
   final verification. Renew with `scripts/Renew-FleetRunLease.ps1 -RunId <run_id>`
   at every phase transition and at least hourly during long phases. Release it with
   `scripts/Exit-FleetRunLease.ps1 -RunId <run_id>`, including failed runs.
3. Read `$env:USERPROFILE/.codex/fleet/cli-update-status.json`. The daily
   automation refreshes it for Codex (runs Sol/Terra/Luna), Grok, Claude, Pi, Antigravity, and Kimi Code.
   Codex was previously unaudited even though it runs every Sol/Terra lane; track it now. The
   codex row must also assert the model-catalog schema: if `codex exec` logs
   `failed to renew cache TTL: missing field 'supports_reasoning_summaries'`, the installed
   codex-cli lags the server catalog schema and every Sol/Terra run falls back to embedded
   defaults + re-fetches (looks like a slow/degraded Sol). Remediate via the leased CLI-update
   flow, not an in-place npm update. If missing, invalid,
   schema-incompatible, timestamped in the future, or older than 24 hours, run the
   same read-only checks before dispatch. Never replace an executable in place or
   enable background binary updates. When an update target is reported, validate a
   side-by-side candidate and require that lane's
   offline wrapper suite plus one minimal live transport probe before use. Then probe
   required primary lanes plus Grok 4.5. Defer Opus, GLM, Gemini, and Kimi probes
   until Sol selects full/review or visual evidence requires Gemini. Light run reports
   label those lanes `not_selected_by_mode`; benchmark rows use status `excluded` with
   exclusion reason `not_selected_by_mode`. Provider outage after verified launch
   never reroutes; local wrapper/PATH/config failures must be repaired before full review.
   Pi print mode proves provider/model configuration but does not expose response-model
   metadata. Mark GLM model-performance attribution `no_contest`/unverified even when
   the functional lane passes; do not chart it as observed GLM 5.2 identity. Grok's
   `[cli] auto_update = false` is intentional: `grok update --check --json` remains
   the authoritative non-mutating check, while version promotion stays atomic and
   test-gated. Claude discovery scans every valid installed CLI across PATH, NVM,
   and native caches, but execution is fail-closed to the exact path, version, and
   SHA in `$env:USERPROFILE/.codex/fleet/approved-clis.json`. Claude child
   processes set `DISABLE_UPDATES=1`. Promote a side-by-side Claude candidate with
   `scripts/Approve-ClaudeCli.ps1`; it shares a mutex with Fleet run-lease creation,
   refuses live run leases, serializes promotions, rejects changed bytes at
   the approved path, runs offline and live proof against an explicit probe manifest,
   then atomically moves the approval pointer between Fleet runs. Audit npm dist-tags
   separately. Default target is newest non-prerelease `latest` after proof; `stable`
   is the lower-risk comparison and `next`/prereleases are never auto-recommended.
   Pin the approved Claude at a DEDICATED dir (e.g. `.codex/fleet/clis/claude-<ver>`
   installed with `npm install -g --prefix`), never the auto-updating nvm path — an
   in-place npm update mutates the approved bytes and fail-closes the whole Opus voice
   (H5, hit live 2026-07-18). The daily audit compares installed-vs-approved pin and,
   on drift, auto-queues a side-by-side re-approval task instead of waiting for a human
   to notice a dead voice. If a whole review voice is down at preflight, surface it
   loudly and apply the documented degraded mode: substitute one cross-family voice
   (GLM `-Thinking high`) and record `voice_substituted` — never silently run a smaller
   panel while claiming full coverage.
   Cache each lane's live-probe result keyed on (cli, version) from
   `cli-update-status.json`: skip re-probing within 24h (1h while a run lease is held);
   a `-ForceProbe` flag always re-probes. Unchanged versions do not pay a fresh probe.
4. Note stale worker processes (`codex`, `pi`, `claude`, `opencode`, `grok`, `agy`) before dispatch.
5. Run `grok inspect --json`, save it under `.fleet/`, and hash it into each Grok
   row. Same-charter comparisons are invalid when Grok's discovered rules/plugins/
   hooks/MCP surface differs silently.

Windows PowerShell probes:

```powershell
cmd /c "codex exec -s read-only CODEX_OK < NUL"
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-Grok45.ps1" -Prompt "Return a short free-form Markdown review of this transport probe." -Effort low -Review -TimeoutSeconds 90 -Mode json
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Test-FleetExternalLanes.ps1" -RequireOpus -RequireGlm
```

Bash/Git-Bash probes:

```bash
codex exec -s read-only "Reply exactly CODEX_OK" < /dev/null
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE/.codex/skills/fleet/scripts/Invoke-Grok45.ps1" -Prompt "Return a short free-form Markdown review of this transport probe." -Effort low -Review -TimeoutSeconds 90 -Mode json
```

`Invoke-PiGlm.ps1` resolves Pi from PATH, then the newest installed
`$env:NVM_HOME\v*\pi.cmd`, so Harken can remain on Node 20 while Pi uses Node 22.
Install Pi under a compatible NVM Node version with:

```powershell
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

If Pi's provider is unavailable after a verified launch, continue as `no_contest`.
Do not materialize Z.ai
credentials in shell variables or add a Claude transport to the Codex workflow.

## Phase 1 - Research Brief

## Spark utilization contract (2026-07-23 — owner caught Spark rotting unused)

Spark is effectively free and fast; it decayed because every Spark rule was a "may"
and one scope blowout (2,981-hit enumeration -> EOF) scared supervisors off. Optional
lanes decay — these are now MUSTS:

1. **Bulk reading is Spark's job, not a frontier model's.** Any gate log, test output,
   diff, or transcript over ~200 lines gets a `[SPARK · SYNTH]` summarization lane
   BEFORE Sol/Terra/Fable/Opus reads it. A frontier model reading raw bulk is the
   same contract smell as a missing Fallow quote line.
2. **Context packs and delta briefings are ALWAYS Spark-built** (manager spot-checks
   load-bearing claims, as ever).
3. **Plan validation gate is mandatory, not skippable:** every wave plan gets the
   Spark cross-check (paths exist, same-wave scopes disjoint) before Wave 1.
4. **Scope discipline so it never blows up again:** every Spark brief states "sample
   and characterize, do NOT enumerate"; pre-filter with `rg` so Spark receives a
   bounded file list, never an open-ended repo sweep. **Spark size ceiling (measured
   2026-07-23): ~150KB / ~40k tokens of artifact — Spark PASSED 165KB(45k tok) but
   BROKE with context-exhaustion at 295KB(80k tok). Artifacts over the ceiling skip
   Spark entirely and go straight to LUNA@high** (validated both tests: 8/8 then 11/11
   incl. deep-tail recall at 295KB, faster than Terra at size, ceiling proven >=130k tokens / ~500KB —
   3x test 13/13 @39s; beyond ~500KB or when line-number citations wanted, use
   Gemini Flash: 13/13 with line cites at 491KB but ~8x slower, batched/async only). One retry-narrower on Spark truncation, then Luna. grok-4.5 only
   when the read needs live tools or X-search; giant reads beyond Luna's proven range
   go to Gemini (1M window). Record every fallback.
5. **Accountability:** the final report's utilization table always carries a Spark
   row (lanes run, bytes summarized). A run whose supervisor read >200-line artifacts
   raw must say why in the report.

Use `rg`/JCodeMunch first for exact file, symbol, and reference lookup. Use Spark
(`gpt-5.3-codex-spark`, low) for multi-file exploration, context-pack synthesis,
long diff/log/test summarization, and plan-scope validation. The manager spot-checks
load-bearing file/line claims before dispatch; Spark does not make design,
architecture, API-shape, implementation, or final-gate decisions.

Create or refresh `.fleet/context.md` in the repo with:

- git sha and dirty-state note
- relevant files and line refs
- existing helpers/patterns to reuse
- test/build/lint/Fallow commands
- constraints, open questions, and per-worker shared context

If `.fleet/context.md` already exists, make a delta brief from its stamped sha.
Add `.fleet/` to `.gitignore` when absent.

## Phase 2 - Wave Graph

Dispatch one GPT-5.6 Sol planning session at high effort after the evidence brief,
through the canonical `scripts/Invoke-Sol.ps1` wrapper (never raw `codex exec` for the Sol
lane). The wrapper forces `-c model_reasoning_effort="high"` so Sol never inherits the
config default (`xhigh`, which reads as a hang), resolves the codex launcher deterministically
(codex lives in the nvm node dir, not on PATH), kills a 0-turn hang the way `Invoke-Grok45`
does, and surfaces the model-cache schema skew instead of letting it pass silently. Use
`-Effort xhigh` only for ambiguous/high-impact design, architecture, API, or security work.
In the same call, require `selected_mode`, matched triggers, rationale, and automatic
escalation conditions using [references/mode-selection.md](references/mode-selection.md).
Do not spend a separate call on classification. Record its session ID and write its locked plan to
`docs/superpowers/plans/YYYY-MM-DD-<topic>-fleet.md`.

Instruct Sol to emit a MAXIMALLY PARALLEL wave graph — this is a stated planning
objective, not a nicety. Sol structures the work so the most tasks possible run
concurrently in the fewest waves: partition the change into disjoint-file-scope tasks
that can proceed independently, and add a dependency edge ONLY where task B genuinely
consumes task A's output or writes the same files. The plan carries a one-line
`parallel width: <max concurrent tasks> across <N> waves; critical path <M> tasks` and,
for every dependency edge, a half-line reason. An unexplained edge, or a serial chain of
same-scope-independent tasks, is a planning defect to send back — not something to build.

Every charter also carries a 3-5 line INTENT BLOCK (Fable directive 2026-07-23):
what the user is actually after, why this task exists, and what failure looks like
for the user. Workers exercise judgment at spec edges from intent, not guesswork —
the D2 sample-data and refresh-token catches both came from intent-level reading.
Intent gives context, not authority: design/scope rules unchanged.

Each task needs:

- id
- dependencies
- disjoint file scope
- worker lane
- complexity: `mechanical`, `standard`, `hard`, or `review`
- self-contained spec and acceptance criteria
- required checks
- flags: `react`, `ui`, `browser`, `cross-repo`
- `design`: whether the task requires visual, interaction, product, API, or
  architecture judgment; design tasks route to GPT-5.6 and never to Grok
- decision ledger: every locked design/API/architecture choice plus rationale
- acceptance/evidence matrix: each promised behavior and the proof required

Validation gate before dispatch:

- `selected_tier` is exactly one of `MICRO`, `LIGHT`, `STANDARD`, `FULL` (legacy
  `light`/`full` and `selected_mode` are normalized to `LIGHT`/`FULL` first); only after
  alias normalization does a missing, invalid, or contradictory value become `FULL`
  without another Sol call
- every existing path resolves
- new paths are marked new
- same-wave file scopes are disjoint
- merge-order dependencies are not mistaken for build-order dependencies
- anti-serialization: every dependency edge carries a reason, and no two tasks with
  disjoint file scope and no real data dependency sit in different waves. A needless
  serial chain fails validation and returns to Sol — the default target is minimum
  critical path, and the plan states its `parallel width` / `critical path` line

After validation, run canonical live transport probes for Opus, GLM, and Grok before
full/review dispatch. A wrapper/config/PATH failure is a Fleet defect to repair before
spending review tokens; only a provider outage after a verified launch is `no_contest`.
Probe Gemini only when selected for visual evidence. Probe Kimi only when Sol selected
a K3 candidate lane; use `Test-FleetExternalLanes.ps1 -RequireKimi -KimiOnly` so
a K3 check does not spend time on unrelated external lanes.

Sol does not supervise, crawl the repo, or read long gate logs. Terra high owns
dispatch, liveness, worktree/scope enforcement, barriers, evidence compression,
repair routing, and mechanical review dedupe. Terra xhigh is exceptional for
ambiguous integration/gate diagnosis. If execution reveals a new semantic fact that
invalidates the plan, pause affected work and send one batched re-plan brief to Sol;
Terra must not improvise product, API, architecture, security, or design semantics.

## Visible Lane Identity - Mandatory

Make every lane identifiable before reading its details. Put model first because
the Codex sidebar truncates long task names.

- Name each Codex native subagent `<model>_<role>_<task-id>_<short-action>` using
  lowercase snake case required by `spawn_agent`, for example:
  `grok45_implementer_t4_ingest_integration`,
  `gpt56terra_fallback_t4_ingest_integration`, and
  `glm52_review_t4_edge_contracts`.
- Display every task, update, heartbeat, log heading, and final-report row as
  `[MODEL · ROLE] T# — action`, for example
  `[GROK 4.5 · IMPLEMENTER] T4 — Ingest integration`.
- Use exact model names, not generic `Codex`, `Grok`, `GLM`, or `Gemini` labels.
  Resolve the model before dispatch. Roles include `MANAGER`, `PRIMARY`, `SHADOW`,
  `DESIGN`, `REVIEW`, `BROWSER`, and `VISUAL EVIDENCE`.
- In Codex desktop, dispatch each external CLI lane through one model-named native
  subagent wrapper so Grok, Pi/GLM, Gemini/agy, and Codex CLI work appears in the
  Subagents sidebar. The wrapper only launches the named CLI, relays liveness, and
  returns its structured result; it must not redo the work or launch another shadow.
  Begin the wrapper prompt itself with the same `SHADOW_COVERED:<run>/<task>` marker.
- When explicit benchmark mode creates a pair, show separate primary and Grok
  comparison entries. Never hide both under one title. Retain model prefixes.
- If native wrappers are unavailable, announce the same model-first label before
  launch and repeat it in every status update. Never rely on icon color for identity.

Canonical labels:

| Worker | Sidebar/task prefix |
| --- | --- |
| GPT-5.6 Sol | `[GPT-5.6 SOL · <ROLE>]` |
| GPT-5.6 Terra | `[GPT-5.6 TERRA · <ROLE>]` |
| GPT-5.6 Luna | `[GPT-5.6 LUNA · <ROLE>]` |
| Grok 4.5 | `[GROK 4.5 · <ROLE>]` |
| GLM 5.2 | `[GLM 5.2 · <ROLE>]` |
| Gemini 3.6 Flash | `[GEMINI 3.6 FLASH · VISUAL EVIDENCE]` |
| Kimi K3 | `[KIMI K3 · <ROLE>]` |
| Claude Opus 5 | `[CLAUDE OPUS 5 · REVIEW]` |
| Claude Opus 4.8 (fallback/benchmark only) | `[CLAUDE OPUS 4.8 · REVIEW]` |

## Routing

| Work | Lane |
| --- | --- |
| Locked wave plan, design/API/architecture decisions | GPT-5.6 Sol high; xhigh only when ambiguous/high-impact |
| Supervision, integration, gates, mechanical dedupe | GPT-5.6 Terra high; xhigh only for exceptional ambiguity |
| Final plan-coverage verification and verdict | Resume planner Sol session |
| Routine arbitration (mechanical disputes, dedupe, gate disagreements) | GPT-5.6 Terra high (research3); Sol arbitration reserved for design/security/hard judgment and FULL cross-family review scoring |
| Exact file/symbol/reference lookup | Local `rg` or JCodeMunch; no model call |
| Repo exploration, context packs, long log/diff/test synthesis | Spark (`gpt-5.3-codex-spark`, low) |
| Hard backend/debugging/state | Grok 4.5 high first; keep cohesive invariants together and use the explicit hard time budget; Codex `gpt-5.6-sol` after failed repair or when judgment is required |
| Non-design implementation, test-code changes, fixes, refactors, migrations | Grok 4.5 high primary; one structured self-review; Grok runs focused checks and Terra/Codex rerun gates; split only independent boundaries or measured bottlenecks |
| Failed Grok implementation after self-review and final-audit repair | Terra fallback; Sol for hard/security/architecture judgment |
| Browser verification | Terra real-Chrome lane (effort high pinned, xhigh escalation-only) with deterministic PASS/FAIL/BLOCKED assertions; see Browser verification lane section |
| Mechanical coding/refactors/migrations | Grok 4.5 high primary; Luna fallback only |
| Design, UX, visual hierarchy, interactions, product copy, public/cross-service API + architecture decisions | Codex `gpt-5.6-sol`, high minimum; xhigh when ambiguous or high-impact; Grok prohibited (Grok may choose private/internal signatures within the locked contract) |
| Visual QA and design review | Codex `gpt-5.6-sol`; Gemini Low runs one batched parallel evidence pass on visually important UI, never final judgment |
| Visually-important UI/design (`ui` flag) | `[KIMI K3 · DESIGN PROPOSAL]` dispatches BY DEFAULT in parallel with Sol's design pass (frozen brief + copied screenshots -> full proposal/HTML/CSS as text); Sol still locks. Every pair scored into the design-off ledger (feeds the kimi-k3.md 30-pair promotion experiment). K3 is exceptional at visual/3D per owner + vendor data — measure it here |
| Runnable visual/3D prototype iteration | `[KIMI K3 · DESIGN WORKSPACE]` (`Invoke-KimiK3.ps1 -DesignWorkspace`): Write/Edit/Read scoped to an ephemeral sandbox ONLY (no repo/shell/web/subagents; escape fails closed). Returns the prototype files as frozen artifacts |
| Whole-repo review / giant multi-file diff / multi-day plan challenge (all-in packet > 250 KiB, cross-cutting) | `[KIMI K3 · LONG-HORIZON]` artifact lane with the full corpus embedded (1M context); selected mechanically by packet size, not memory |
| Long-context plan challenge, independent design red team | Kimi K3 frozen-artifact candidate lane; Sol locks decisions and gives final verdict |
| Measuring Grok's design taste (not shipping it) | Optional `[GROK · DESIGN PROPOSAL]` frozen-artifact, no-write candidate lane in explicit benchmark mode only, mirroring Kimi; proposals never ship. Quarterly blind design-off, cross-family graded, predeclared non-inferiority bar; passing promotes only to "Grok may propose, Sol locks." This is also the counterweight that samples the stratum the shadow `coverage_scope` filter excludes |
| Broad web research / red-team sweep needing agent fan-out | Kimi K3 `[KIMI K3 · RESEARCH]` swarm lane (`-ResearchSwarm`; network + AgentSwarm on, no repo/write) when Sol judges breadth needs it; single lookups stay on `rg`/Spark/Grok X. Live transport + model-refusal proven 2026-07-18 |
| Security scanning / vuln audit of our own code (defensive) | TWO open-weights voices dispatch BY DEFAULT alongside the panel whenever a security trigger selects FULL (owner directive 2026-07-22). Both are open-weights (K3 Moonshot, GLM 5.2 Zhipu) and pursue exploit-path analysis — injection chains, deserialization, authz-bypass construction — more bluntly where hosted models (Sol especially, Fable→Opus) soften, generalize, or refuse offensive detail even in a defensive audit. **They get DIFFERENT repo visibility by design:** `[GLM 5.2 · SECURITY]` runs LIVE read-only against the real checkout (`Invoke-PiGlm.ps1 -ReadOnly -Thinking high`, tools `read,grep,find,ls`; edit/bash/approve denied) so it crawls the whole tree and follows cross-file taint→sink flow on demand. `[KIMI K3 · SECURITY]` stays boxed (ephemeral home + copied creds + auto-approve = no live FS) and instead receives the FULL security-relevant corpus embedded as a frozen artifact — the `[KIMI K3 · LONG-HORIZON]` full-repo pattern (1M context), assembled by the manager with `rg`, NOT a diff-only packet. Repo bigger than ~1M tokens: scope the embed to the security surface (auth, input handling, routes, query/DB construction, deserialization, file I/O, crypto, secrets) or chunk; GLM's live lane has no embed limit. They run concurrently with each other and the panel, so two open-weights security voices cost no extra wall-clock. Findings are ADDITIVE — any voice's security finding counts once verified against source; Sol keeps the final security verdict, and neither K3 nor GLM grades other models. Defensive audit of OUR OWN code only — never third-party targets |
| Giant-context reads, Google-grounded research | Antigravity/Gemini |
| Real-world/X research | Grok 4.5 |
| Mechanical lanes: receipt validation, lane-fit aggregation, exploration/parse-only | Fast tier: Gemini flash or forced-low effort; metric = `duration_s` on mechanical lanes |

Use Codex native subagents when the active tool surface exposes them. Otherwise
use `codex exec` only for Codex worker lanes, preferably in a separate worktree
for write-heavy work.

## Claude Opus 5 as orchestrator

When Claude Opus 5 is the orchestrator (not only the review seat): use adaptive
thinking (`thinking:{type:"adaptive"}` + `output_config.effort`); legacy
`thinking.type:"enabled"` returns HTTP 400. Keep phase effort tiers constant per
session (plan-lock=xhigh, arbitration=high, dispatch/receipt/telemetry=low–medium) —
effort flips invalidate the message cache. Strip over-verify / "subagent verify"
language (Opus 5 self-verifies by default); keep review blocker-focused. Spawn only
large independent work; prefer one subagent; complexity-scaled fan-out only when
needed. Full contract: [references/opus5-orchestrator.md](references/opus5-orchestrator.md).

## Handoff Receipt and Lane Lifecycle (speed)

The receipt contract is the REQUIRED shape for handoffs once wired into orchestration
flows (`schema_version=1` from `scripts/New-FleetHandoffReceipt.ps1` plus named delta
artifacts: absolute path, bytes, SHA-256). It is staged / not enforced by a production
caller until wired. Do not re-transfer full session history. First-result deadline and
partial-result exit free the lane slot; do not hold a dead child waiting on a full
gate. Repeated timeout/lifecycle churn requires a fresh-session rollover (new receipt,
new child) — never extra full gates or history replay.
Measure local byte reduction and raw-materialization wall time only — via
`scripts/Measure-FleetHandoffPerformance.ps1`; never claim model latency.

Lane-span contract (hard gate): every lane completion MUST be recorded with
`scripts/Record-FleetLaneSpan.ps1` into repo-root `BENCH-lanes.jsonl`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Record-FleetLaneSpan.ps1 -RecordPath .fleet\T1-lane-span.json -OutputPath BENCH-lanes.jsonl
```

A run is NOT complete until `scripts/Assert-FleetLaneSpans.ps1 -RunId <id>
-LedgerPath BENCH-lanes.jsonl -ExpectedLaneManifest <path>` passes and its summary line
(`lane-spans: <run> | expected: N | valid: V | missing: M | duplicate: D |
unexpected: U | invalid: I | verdict: ok|FAILED`) is quoted in the final report,
exactly like the Fallow, filesize, lane-completion, and adversarial-review lines.
Status `error`|`timeout`|`no_contest` still requires a row (the gate proves
recording, not success). Schema: references/lane-span-schema.md.

## Lane-fit report (derived, never handwritten)

Aggregate phase/genre/shadow fitness from repo-root JSONL. Every number is DERIVED
from a ledger row — never hand-authored ranks. Groups retain `coverage_scope` +
`estimand`. Spans (`phase:*`): median + p95 `duration_s`, status mix with
`no_contest` distinct. Shadow (`shadow:*`): tie-adjusted win rate
`(wins + 0.5*ties)/(wins+losses+ties)`, Wilson 95% CI; print `?` below 30 eligible
rows. Malformed lines skipped and counted; missing/empty ledger => `no data`,
exit 0. Defaults: `BENCH-lanes.jsonl` / `BENCH-genre.jsonl` / `BENCH-shadow.jsonl`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Get-FleetLaneFit.ps1
# optional overrides: -SpansPath -GenrePath -ShadowPath -OutputPath
```

## Kimi K3 Candidate Lane

Kimi dispatch is DEFAULT for: visually-important UI design proposals; FULL first-party
security via copy-sandbox only (`-RepoSandbox`; embed fallback when no git); cross-
cutting long-horizon packets; and genuinely broad read-only research (`-ResearchSwarm`
when Sol judges fan-out is needed). Sol retains architecture, product, security, API,
and final design judgment — Kimi never owns security judgment or final authority.
Static deny, no host-repo write charter, no writes, no final authority remain mandatory.
K3 does not join normal implementation or the FULL-tier blind-voice review barrier.
Its noninteractive prompt mode auto-approves ordinary tools and cannot combine with plan
mode, so prompt text alone is not a control boundary.

All Fleet K3 calls must use Invoke-KimiK3.ps1. It gives K3 an ephemeral home and
workspace, copies credentials only for the child lifetime, embeds frozen text
artifacts, denies read/write/shell/subagent/web tools, and permits ReadMediaFile only
for copied images. It validates JSONL, uses Windows extended-path cleanup for Kimi's
persisted session trees, and fails closed on unexpected tool use or cleanup failure. Never
call raw Kimi, Kimi upgrade, Kimi server, Kimi web, ACP, auto mode, or yolo mode.
Accept a visual result only when its tool evidence proves a copied-image
ReadMediaFile call. K3 output remains a proposal: Sol owns UX, product, API,
architecture, security, and final approval.

K3 also has a separate, guarded research-swarm lane `[KIMI K3 · RESEARCH]`: it may
fan out its own sub-agents plus web search/fetch for broad read-only research, but
gets no repository, no shell, and no write charter. Invoke it with
`Invoke-KimiK3.ps1 -ResearchSwarm`; live transport and model-layer refusal are
confirmed (2026-07-18), but child-attempt config enforcement is not force-testable,
so prefer the artifact-only lane for the most sensitive work. Both lanes share the
ephemeral-home/copied-credential runtime. Read references/kimi-k3.md for the exact
allow/deny split and the live-probe caveat before selecting either lane.

Run the blind promotion experiment in references/kimi-k3.md before changing this
ownership. Keep first-pass and post-review data separate.

## Grok-First Usage-Conservation Policy and Benchmark

Grok owns routine non-design implementation regardless of raw task size. The manager
locks UX/public-API/cross-service architecture decisions first, gives Grok explicit
write scope and acceptance criteria, and splits only independent boundaries or
measured context/tool bottlenecks.
Grok may read any tracked caller, helper, test, config, or dependency needed for
correctness and choose private implementation details within the locked contract.
Each Grok wave gets one structured adversarial self-review/fix pass before the
barrier. Grok runs focused executable checks; Terra/Codex rerun gates and return
failures as bounded repair evidence. Select the patch
only when tests, build/typecheck, Fallow, scope, dependency, and file-size gates pass.

Do not impose a global file-count or diff-line ceiling on Grok. Sol sets a
task-specific scope around one cohesive invariant and records its expected size.
Split only when boundaries are genuinely independent or measured context/tool
friction makes the combined charter slower; do not split merely because a wave is
large. Grok runs the smallest focused tests that exercise its branch. Do not assign
it full suites, package builds/typechecks, lint, or Fallow; Terra/Codex owns those
once per barrier. This keeps Grok's self-review substantive without paying twice
for manager-reproducible gates or extra orchestration waves.

Terra and Luna are implementation fallback lanes, not routine implementers or paired shadows. Escalate
only after Grok fails its static self-review plus one evidence-backed gate-repair attempt,
or when Sol-owned design, architecture, security, or product judgment is required.
Immediate blockers remain do-not-touch edits, unapproved dependencies, new Fallow
findings, unresolved test failures, and unauthorized design/API/architecture choices.

Benchmark sampling is POST-HOC ASYNC and ON by default — it never gates, delays, or
touches a primary ship (an in-band shadow would steal a scarce slot and slow the run,
so it is architecturally barred from the critical path). At plan time Sol emits
`shadow_eligible_tasks[]` with a `task_stratum`; every run may randomly draw one
eligible task under a recorded seed (stratified per-stratum targets, ~`p_shadow=0.15`
overall, floor of one/day when eligible work exists), freeze its packet at completion,
enqueue it, and replay it later in a detached worktree via `Enqueue-FleetShadow.ps1` /
`Start-FleetAutoShadow.ps1` (references/auto-shadow.md). Every draw, skip, and
no_contest is logged, wins and losses alike — on-request-only comparison invited
selective disclosure and is retired. Explicit benchmark mode remains the only ADOPTION
path (`adopted_into_run=false` for auto rows). The `shadow_eligible` filter
("Grok-executable, no design decision") is recorded as `coverage_scope` on every row
and aggregate so a Grok-eligible win-rate is never read as a global verdict. Normal
Grok-primary tasks still record model, session, wall time, gate result, retries, diff
size, final-audit findings, and manager rewrite status in the Fleet run report.
Shadow sampling follows `fleet-policy.json` `auto_shadow.stratified_boost` (p=1.0 for
under-filled qualification strata until `n_target`, `daily_boost_cap`, full sampling
provenance on every row) and the canary set (`fleet-canaries.json`,
`Enqueue-FleetCanary.ps1`, `repeat_count=3`, `sampling_rate_source='forced_canary'`,
canary rows labeled and never sole ship gates).

### Live shadow replay (as-built)

`Enqueue-FleetShadow.ps1` optional snapshot params: `-TaskSpecJson` (JSON string with
`id`/`prompt`/`allowed_paths`/`gate_commands`/`max_diff_lines`), `-PrimaryLane`,
`-PrimaryWallSeconds` (optional `-PacketSha256`). Queue entries embed `task_spec` +
`primary_lane` + `primary_wall_seconds` + `packet_sha256` so later packet mutation
cannot affect replay. Spec-less/legacy entries are terminal `deferred_no_spec` (never
graded; qualification ledgers stay byte-identical). `live_not_implemented` is retired.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Invoke-ShadowReplay.ps1 -EntryPath <queue-entry.json> -RepoRoot <repo> [-OutputDirectory <dir>] [-LaneSpecPath <lane-spec.json>] [-GateTimeoutSeconds 900] [-KeepWorktrees]
```

`Start-FleetAutoShadow.ps1` optional `-LaneSpecPath`; live path calls
`Invoke-ShadowReplay.ps1`. Rubric `deterministic_partial` max 90 (never rescaled):
correctness 40 (gates), spec 25 (scope), tests 15 (gate sanity), scope 10 (diff
budget); maintainability deferred/null. Tie `abs(delta)<=5`. Hard-ineligible arm may
lose never win; both-ineligible or timeout/outage => `no_contest` (never a loss). Arm
budget `ceil(1.5*primary_wall_seconds)`. `status='graded'` only on real completed
grading (`success=true`); `Write-QualificationTrack` only on `success=true` with real
`wall_seconds`. Details: [references/auto-shadow.md](references/auto-shadow.md).

For explicit sampled comparisons, shadow a primary task that Grok can execute without making design decisions:
implementation, fixes, refactors, migrations, tests, debugging, analysis, research,
and code/spec review. Use the same task prompt, acceptance criteria, base SHA, and
relevant context. Alternate execution order across pairs to reduce warm-up bias.

Rules:

- Only the root manager dispatches the shadow. Prefix every primary and shadow
  prompt with `SHADOW_COVERED:<run_id>/<task_id>`. The marker bans only NESTED shadow
  COMPARISONS (no worker/reviewer/shadow launches another benchmark shadow). It does
  NOT ban a worker's own bounded internal fan-out: depth-1 subagent parallelism is
  permitted with child count/budget recorded. Its only concrete named risk is recursive
  shadow-benchmark explosion, not capability.
- Use an isolated worktree for a writing shadow. Use the same frozen diff/artifacts
  for read-only shadows. Never let primary and shadow edit the same checkout.
- Keep Grok blind to the primary output. Grade both outputs blind before revealing
  model identity.
- Default trial mode is `grok_review_only`: primary models stop after normal targeted
  checks, while Grok runs one structured self-review/fix pass before returning its
  candidate. Terra/Codex then rerun identical executable gates before blind scoring.
  Choose between the primary first pass and Grok's reviewed final output.
- Use `both_review` only on selected benchmark runs. Give both models the same
  review/fix budget and label those rows separately; never make slow-model review
  the normal wave barrier.
- Use Grok effort `high`; current CLI `0.2.99` exposes only low/medium/high, so
  requested `xhigh` and `max` are aliases of effective `high`. Do not label, score,
  or chart high-vs-xhigh experiments until version-keyed live proof shows distinct
  effective effort. Record the effective value as `high`; exclude unsupported
  variants rather than creating fake comparison rows.
- Never send Grok a design task. Design includes visual direction, layout choice,
  hierarchy, motion, interaction behavior, product copy, PUBLIC or CROSS-SERVICE API
  shape, and architecture. GPT-5.6 Sol owns those decisions at high minimum or xhigh
  for ambiguity/high impact. A private/internal helper signature within the locked
  external contract is Grok's to choose; it escalates only when a public or
  cross-service interface would change.
- Grok may implement a design only after GPT-5.6 has locked exact behavior and visual
  constraints. If a design choice remains, Grok must stop and return `blocked`.
- In explicit benchmark mode only, Grok may compare analysis of captured functional
  browser evidence. It never judges design quality or drives the user's browser.
- Benchmark shadows ride to the wave barrier under the same task budget. Timeout or
  outage never blocks implementation; record `no_contest` or `excluded_capability`.
- Codex desktop permits root plus three child lanes. Explicit benchmark mode schedules
  only one primary/shadow pair at a time; never launch two pairs beside root.
- In benchmark mode, select the highest-scoring gate-passing candidate and record
  selection/adoption explicitly. Normal Grok-first runs have no candidate contest.
- Record paired benchmark tasks and exclusions only when a comparison actually runs;
  normal Grok-first work records operational metrics in the Fleet report.
- Score the frozen first pass for learning, but reject selection/adoption of any
  candidate that touches a do-not-touch path, adds
  an unapproved dependency, creates a new Fallow finding, or exceeds the charter's
  file/line budget. Record these counts instead of hiding them inside notes.
- After risk-scaled final review fixes the selected candidate, score it again and
  record pre/post-review scores plus catches by selected voices. In benchmark rows,
  mark omitted voices `excluded` with reason `not_selected_by_mode`; worker-final
  scores are not post-integration quality.

Blind score each first pass and each reviewed final output from 0-100: correctness
40, spec compliance 25, tests/evidence 15, maintainability 10, scope discipline 10.
Record review duration/catches separately so charts distinguish raw model quality
from Grok's self-correction value.

Read [references/benchmark-schema.md](references/benchmark-schema.md) before
writing a benchmark record. It defines v7 fields for final-review deltas, scope,
churn, tokens, latency, cost provenance, and energy/carbon availability.

For an explicit Terra Medium versus Grok 4.5 High comparison, create a JSON task
file with at least two entries under `tasks`. Each entry needs `id`, `prompt`,
`allowed_paths`, optional `max_diff_lines`, and trusted `gate_commands`. Task-file
v2 may add optional `lane_a` / `lane_b` objects `{name, wrapper, model, effort}`;
both required together. Wrappers are allowlisted basenames under `scripts/` only
(`Invoke-*.ps1`; unknown, absolute, or path-like names rejected). Patch-transport
caps (e.g. Kimi/GLM) run read-only; the runner validates and applies the returned
patch via `git apply`. `excluded_capability` is never scored as a loss. Omit both
lanes => v1 terra/grok behavior unchanged; with both, `comparison_mode=wrapper_pair`.
The runner uses detached sibling worktrees, hashes the shared task prompt, alternates
lane order, cryptographically randomizes A/B identity, reruns gates with closed stdin
and bounded timeouts, rejects scope/diff/binary violations, and emits blinded A/B
diffs. Invalid or unavailable `grok inspect --json` fingerprints fail the comparison
before model work. Copy
[references/terra-grok-tasks.example.json](references/terra-grok-tasks.example.json)
and replace its three bounded task/path/command placeholders with real repo work.
This is intentionally `grok_review_only`: Terra Medium returns its normal candidate;
Grok High includes Fleet's one structured self-review. Give graders only the emitted
`blind` folder. Keep `private/reveal.json`, lane logs, runtime fingerprints, and model
mapping sealed until scoring finishes. Grok transport failure blocks adoption but does
not hide an otherwise scoreable diff, so charts keep code quality and transport quality separate.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Run-TerraGrokComparison.ps1" -Repo C:\path\to\repo -TaskFile C:\path\to\tasks.json
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Test-TerraGrokComparison.ps1"
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Record-GrokBenchmark.ps1" -RecordPath .fleet\grok-benchmark-T1.json
```

The script calculates scores, rejects inconsistent or duplicate rows, enriches
Grok telemetry from `~/.grok/logs/unified.jsonl`, serializes concurrent appends,
and writes UTF-8 without BOM to
`$env:USERPROFILE/.codex/skills/fleet/BENCH-grok45.jsonl`. The earlier Claude
ledger remains historical source material at
`$env:USERPROFILE/.claude/skills/fleet/BENCH-grok45.md`.

Grok Build OAuth does not expose actual billed cost. Record separate primary,
Grok, and risk-scaled final-review phase telemetry; leave actual cost null and label the calculated
`api_equivalent_cost_usd_upper_bound` as an API list-price upper bound. Never call
it subscription cost. Leave energy/carbon null unless provider or measured
infrastructure supplies energy, region, PUE, and grid-intensity provenance; tokens
alone are not an energy measurement.

## Worker Commands
Always redirect stdin from null. Prefer prompt files over quoted prompt arguments.

The Sol lane (plan / design / architecture / security) goes through its wrapper, not raw
`codex exec` — the wrapper forces effort, resolves the launcher, guards the 0-turn hang, and
reports the model-cache skew:

```powershell
# canonical Sol dispatch (reads the brief from a prompt file; Mode json for structured capture)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-Sol.ps1" -Prompt (Get-Content -Raw .fleet/plan-brief.txt) -Effort high -Sandbox read-only -Mode json -TimeoutSeconds 1200
# preflight liveness + model-resolution probe (proves gpt-5.6-sol still resolves):
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-Sol.ps1" -Probe -Mode json
```

Raw `codex exec` remains only for the Terra fallback, `codex exec review`, and Spark reads:

```bash
codex exec -o .fleet/task-id.json -c model="gpt-5.6-terra" "<fallback-only prompt>" < /dev/null
codex exec review --uncommitted < /dev/null
codex exec -c model="gpt-5.3-codex-spark" -c model_reasoning_effort="low" -c mcp_servers.supabase-full-kit.enabled=false -s read-only "<repo-map or synthesis prompt>" < /dev/null
```

### Browser verification lane (Terra drives the real Chrome)

Live browser walkthroughs/verification are a Terra lane, not Sol and not Fable. Terra drives
the user's real signed-in Chrome via the plugin's `browser-client.mjs` + control-chrome SKILL
(NOT Playwright), dispatched automatically at PINNED effort high (research3: OSWorld 2.0
ablation — max/xhigh buys partial progress, not completion, at +55% cost; bounded execution
peaks at medium–high). xhigh is ESCALATION-ONLY, triggered by a distress signal (stuck loop,
repeated FAIL on the same item, ambiguous page state):

```bash
codex exec -s danger-full-access -c model="gpt-5.6-terra" -c model_reasoning_effort="high" --skip-git-repo-check "<short positional>" < .fleet/<charter>.txt
```

Charter goes over stdin (argv has a ~70KB limit). It must: point at `browser-client.mjs` +
control-chrome (never Playwright); give each check item a DETERMINISTIC assertion (DOM-state,
URL, or network condition) that emits PASS/FAIL/BLOCKED mechanically — the model consumes
assertion results, it does not judge raw pages (research3: LLM-only judges of web trajectories
run <=70% precision, ~30% false-success — AgentRewardBench); name a screenshot dir + a
`REPORT.md`; and instruct STOP + report `BLOCKED` if it lands on
`/login` (login is the only human step — Chrome inherits the signed-in profile). Visual QA
*judgment* still routes to Sol per the routing table; Gemini Low is one batched evidence pass,
never final judgment. Every browser lane completion records a `phase:"browser"` span via
`Record-FleetLaneSpan.ps1` — zero browser spans existed before research3, so no browser
before/after measurement is possible until they do.
Luna (`gpt-5.6-luna`) is a CANDIDATE cheaper driver for bounded walkthroughs behind
deterministic assertions only (research3: ALE near-parity at ~1/3 cost) — A/B experiment
against Terra with spans on both arms, escalate to Terra/Sol on distress; never LLM-judge-only,
never default. n<30 eligible rows => directional only.

```powershell
$packetDir = ".fleet/review-vN"
$reviewRisk = "behavior" # Sol's locked plan selects: mechanical | behavior | hard
$packet = & "$env:USERPROFILE\.codex\skills\fleet\scripts\Get-FleetReviewPacket.ps1" -PacketDir $packetDir -ReviewRisk $reviewRisk -OutputPath "$packetDir/packet-manifest.json" | ConvertFrom-Json
$reviewArtifacts = @($packet.artifact_paths) # pass as ($reviewArtifacts -join ',') to any `powershell -File` wrapper; a raw array splats positionally and corrupts later params
$opusBudget = & "$env:USERPROFILE\.codex\skills\fleet\scripts\Get-FleetReviewBudget.ps1" -PromptFile .fleet/T1-opus-review.txt -ArtifactFile $reviewArtifacts -PacketManifest "$packetDir/packet-manifest.json" -ReviewRisk $reviewRisk -OpusModel claude-opus-5 -OutputPath .fleet/T1-opus-review-budget.json | ConvertFrom-Json
$glmBudget = & "$env:USERPROFILE\.codex\skills\fleet\scripts\Get-FleetReviewBudget.ps1" -PromptFile .fleet/T1-glm-review.txt -ArtifactFile $reviewArtifacts -PacketManifest "$packetDir/packet-manifest.json" -ReviewRisk $reviewRisk -OutputPath .fleet/T1-glm-review-budget.json | ConvertFrom-Json
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-Opus48.ps1" -PromptFile .fleet/T1-opus-review.txt -ArtifactFile ($reviewArtifacts -join ',') -PacketManifest "$packetDir/packet-manifest.json" -Effort high -Model claude-opus-5 -TimeoutSeconds $opusBudget.opus_timeout_seconds -Mode json
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-Grok45.ps1" -PromptFile .fleet/T1-grok-prompt.txt -WorkingDirectory <isolated-worktree> -Effort high -BashCapability Auto -IsolatedWorktree -EnableSubagents -EnableWebSearch -LeanSystemPrompt -Mode json
# Grok FANS OUT to three diverse-lens review lanes at FULL (review-protocol.md charter 5).
# Coverage x3, but they DEDUPE to one counted Grok voice; the gate collapses v-grok-* by
# model key. Rolling dispatch (root-plus-three cap). NO fan-out when Grok is the run's
# implementer above - then this is a single cross-family voice instead.
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-Grok45.ps1" -PromptFile .fleet/T1-grok-spec.txt -WorkingDirectory <repo> -Effort high -Review -TimeoutSeconds 900 -Mode text > .fleet/review-vN/v-grok-spec.md
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-Grok45.ps1" -PromptFile .fleet/T1-grok-correctness.txt -WorkingDirectory <repo> -Effort high -Review -TimeoutSeconds 900 -Mode text > .fleet/review-vN/v-grok-correctness.md
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-Grok45.ps1" -PromptFile .fleet/T1-grok-regression.txt -WorkingDirectory <repo> -Effort high -Review -TimeoutSeconds 900 -Mode text > .fleet/review-vN/v-grok-regression.md
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-PiGlm.ps1" -PromptFile ".fleet\T1-glm-prompt.txt" -Thinking high
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-PiGlm.ps1" -PromptFile ".fleet\T1-glm-review.txt" -ArtifactFile ($reviewArtifacts -join ',') -PacketManifest "$packetDir/packet-manifest.json" -Thinking low -NoTools -TimeoutSeconds $glmBudget.glm_timeout_seconds -Mode json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/fleet/scripts/Invoke-Gemini35.ps1" -CaptureDir <capture-dir> -Prompt "<absolute screenshot paths + batched prompt>" -Mode json
```
Before invoking Opus or GLM for a full/review lane, run
`Get-FleetReviewPacket.ps1`, then `Get-FleetReviewBudget.ps1`; never hand-select a timeout.
The packet preflight is the dispatch gate: it requires nonempty `base.sha`, `final.diff`,
`touched-files.txt`, `locked-plan.md`, `acceptance-evidence.md`, and `gate-evidence.md`,
writes their stable SHA-256 manifest. The budget selector and no-tool Opus/GLM wrappers
re-attest those same paths and canonical UTF-8 bytes before launch; any drift or list
mismatch blocks dispatch. Sol's locked plan must
set `review_risk` to `mechanical`, `behavior`, or `hard`. The selector calculates
the exact serialized prompt/artifact transport, emits the budgets and evidence, and
writes the run-record input. `120` seconds is reachable only through the tiny
mechanical tier.
In PowerShell, use `cmd /c "... < NUL"` for bare CLIs. Always use the canonical
Pi wrapper for GLM in Codex and Claude (`Invoke-PiGlm.ps1`). It loads the Z.ai key
from existing OpenCode auth (never prints it), runs Pi print mode, sends prompts
over stdin, closes stdin immediately, and never requests cumulative
`message_update` bodies, emits compact heartbeats on stderr, CLI-pins provider/model
to `zai`/`glm-5.2`, labels model identity `cli-pinned-unobserved` because Pi print mode
does not expose response-model metadata, disables repo extensions, and hard-timeouts with process-tree kill
(default 900s), and returns only final text or one normalized `-Mode json` result.
Use `-NoTools` with frozen artifacts for final reviews, `-ReadOnly` for repo inspection,
and `-PromptFile` for large prompts. Tests: `scripts/Test-Invoke-PiGlm.ps1` (`-Live`).

Opus has no tools. Pass every frozen review input with `-ArtifactFile`; the wrapper
embeds canonical UTF-8 bytes over stdin and returns path/size/SHA-256 evidence. Path mentions or
Claude-style `@file` syntax alone do not supply an artifact in print mode.

Always use `Invoke-Grok45.ps1` for Grok. It owns auth expiry checks, model proof,
timeouts, working directory, implementation JSON self-audit (or `needs_gate_validation`
salvage), review/read-only Markdown capture, and version-keyed Bash proof.
Auto probe requires an isolated worktree and enables `run_terminal_cmd` only after
an exact live proof succeeds. Build-audit
delegates here. Run `scripts/Test-Invoke-Grok45.ps1` after transport changes; live
probe only after CLI/auth upgrades. Fleet imposes no turn cap by default; use
`-MaxTurns` only for an explicitly bounded experiment. Wall-clock timeout and
output validation remain mandatory. `-ReadOnly` is an alias of `-Review`.

Structured worker-JSON report is required from IMPLEMENTATION lanes only (not review/read-only):

```json
{"schema_version":"1","status":"done","files_changed":[],"files_reviewed":[],"acceptance_criteria":[{"criterion":"x","status":"passed","evidence":"y"}],"audit_passes":1,"findings":[],"fixes":[],"remaining_executable_checks":[],"self_check":"checks and review","notes":""}
```

Codex can enforce with `--output-schema`; strict schemas must list every property,
including `session_id`, in `required`. Other implementation lanes are gated by parsing JSON and
checking required keys. Invalid or missing implementation reports are not silent success:
`Invoke-Grok45.ps1` returns `status=needs_gate_validation` with exit 0 when transport and
payload are valid but the structured self-audit is missing/invalid. Exit zero alone never
accepts work — manager-owned diff, scope, dependency, focused-test, full-suite, and Fallow
gates remain mandatory. Hard transport/model/empty-output failures still exit 1 fail-closed.

Review/read-only Grok (`-Review` / alias `-ReadOnly`) returns free-form Markdown as the
deliverable. Capture review artifacts with `-Review -Mode text` (markdown on stdout).
`-Mode json` is allowed for automated probes because it wraps markdown in the
normalized result (`response` field); it does not request the implementation worker JSON.
A `-Review` lane that launches but emits no first turn within 180s (pre-first-turn
transport stall) self-kills as `failure_category=no_first_turn` (a no_contest, never a
retry) instead of burning the full 900s. Threshold is `-FirstTurnTimeoutSeconds`
(pid-filtered probe; default 180 on review lanes, 0/disabled on implementation lanes,
which legitimately think longer before a first turn).
Read-only Grok uses `dontAsk`, explicit read tools, and edit/Bash denies. Plan mode
is not a write barrier. Grok IMPLEMENTATION lanes in an isolated worktree get
subagents and web DEFAULT-ON (`-EnableSubagents -EnableWebSearch`) so native research
and depth-1 fan-out speed every task; memory stays opt-in. Turn them OFF only for
benchmarks (stateless, reproducible), read-only review lanes, and the K3 artifact
lane. Record every capability flag on the run/benchmark row.

Implementation worker prompts must end with: `Return only the JSON object. No markdown.`
Review/read-only prompts must request free-form Markdown and must not demand the worker-JSON envelope.

## Dispatch Rules

- Max three active child lanes while root is alive. Before the next batch, confirm
  every prior wrapper completed or was terminated and its slot was freed.
- Staggered wave dispatch for cache pre-warm: launch the slowest voice first; launch
  remaining voices after that voice's first response begins or after a ~30–60s lag
  (converts N cold cache writes into 1 write + N−1 reads). See
  [references/cache-contract.md](references/cache-contract.md).
- Charters put `run_id`, timestamps, and per-wave deltas AFTER the stable prefix
  (system + charter static body + schema); never in the system prompt or ahead of the
  cache breakpoint. See [references/cache-contract.md](references/cache-contract.md).
- Create one visible, model-first sidebar entry per active lane before launch. In
  explicit benchmark mode, primary and Grok comparison lanes are separate entries.
- Shared checkout writes require disjoint scopes. Overlap means separate worktrees.
- Run only one fleet supervisor against a working tree. Parallel fleets require
  separate worktrees or strict serialization.
- A behavior-changing task owns its focused tests. Scope charters name both owned
  files and explicit do-not-touch files shared with same-wave tasks.
- Checkpoint before each wave: `git stash create "fleet-wave-N"` and log the sha.
- Workers self-check their own slice only.
- Terra orchestrator runs wave gates once: typecheck, tests, lint/build as relevant, Fallow,
  diff review against acceptance criteria, and one real user-path probe for
  user-facing behavior. An equivalent-looking alternate path is not proof.
- Serialize full test-suite runs. Parallel workers run only scoped checks.
- For live/provider/browser acceptance, freeze the failing matrix after two
  consecutive repair cycles or when a failure reveals a new architecture/data-contract
  decision. Return to Sol for a new bounded plan before another implementation wave.
  Do not silently turn a verification request into open-ended prompt tuning.
- Quote the Fallow result line (`fallow: N new findings`) in the heartbeat and
  final report. No quoted Fallow line means the gate did not run.
- MEASURE THE THING, NOT THE PIPE (2026-07-26, three self-inflicted misreads in one run):
  (a) `cmd | tail -N; echo $?` reports TAIL's exit code, never the command's — read exit
  codes with no pipe (or `${PIPESTATUS[0]}`); a lane that exited 1 read as 0 this way.
  (b) In PowerShell EVERY object is truthy, so `if (Test-Thing ...)` passes even when the
  returned object says `valid=$false` — assert on the FIELD (`.valid`), and when a
  validator changes from `[bool]` to an object, grep every call site. Guarded now by a
  mutation-proven case in Test-FleetContract.ps1.
  (c) Squash-merge ONE lane branch at a time and COMMIT between: a second
  `git merge --squash` against a dirty index is refused by git while a shell loop happily
  prints success, silently shipping main without that lane's work. Use
  `scripts/Merge-FleetLaneBranch.ps1` (fail-closed preconditions + staged/commit
  postconditions + `-ExpectPath`), and verify the merged tree by content, never by the
  loop's echo.
  General rule: when a check reports success, confirm the check could have failed. Every
  new gate in this repo ships a mutation proof — inject the defect, watch it go red.
- EVIDENCE INTEGRITY GATE (2026-07-26, recurring failure class): every PASSING gate
  must state WHAT IT ACTUALLY EXERCISED — its denominator — and the manager quotes it
  beside the Fallow and filesize lines (`tests: 274 collected / 274 passed`,
  `corpus: 8/8 documents`, `rows scanned: 1,412`). A pass with no denominator, or a
  zero one, is NOT a pass: it is a gate that did not run. `Get-FleetReviewPacket.ps1`
  enforces this structurally — a `passed` command entry in `test-results.json` needs a
  nonempty non-zero `sample` field or dispatch is blocked. Companion rules:
  (a) NEGATIVE CONTROL — a new test/gate/oracle is unproven until it has been seen to
  FAIL with the thing it checks broken (same standard as the deletion-tool canary);
  (b) never derive an expectation from the code under test, and never let a mock stand
  in for the semantics being verified (a store mock returning `true` hid MySQL
  changed-vs-matched rows); (c) detection without propagation is not a gate — the
  caller must act on the result; (d) a metric quoted from ONE run of a nondeterministic
  pipeline is not evidence: report mean + range over >=3 runs and compare the delta to
  the measured noise band; (e) COMPILING IS NOT RENDERING — when the artifact has
  observable output, the gate must LAUNCH it and assert that output, not just build it
  (a Tauri probe compiled exit-0 with correct window rects and 5/5 hotkeys while the
  overlay actually displayed "can't reach this page", because plain `cargo build` skips
  `frontendDist`; every marker read 0 and only a screenshot showed why); (f)
  EXISTENCE-OF-RECORD IS NOT A PASS — a scorer whose PASS branch is reachable merely
  because some record exists and is non-empty is not a gate (`UNMEAS if incomplete else
  PASS`, where "complete" meant any event carried any exe_path, would have passed a
  capability on a machine where the target app was never focused). The expectation must
  come from an independently-declared source, never from the record being scored.
  Why: green signals produced by a path that never ran the
  real thing recurred nine times in three days — a suite collecting 0 tests under a
  wrong filename suffix, CI green while the frontend suite never ran, an acceptance
  harness printing 100% coverage from 3 of 8 documents, a stale compiled backend
  "verifying" old code, and an extractor whose honest page citation carried a
  one-row-offset fabricated comparable.
- FILE-SIZE GATE: run `scripts/Assert-FleetFileSize.ps1 -BaseRef <base-sha>` with the
  other gates and quote its summary line (`filesize: N violations, M warnings`).
  Violations (new file over 300 lines, or a file pushed/grown past 300 by more than
  the 15-line grace) are BLOCKERS for new code — split before shipping; warnings
  (minimal edits to inherited over-cap files) are reported, and inherited monsters
  are refactor-wave work, not silent growth targets. Grok's lean system prompt now
  carries the same 250-soft/300-hard rule, so workers hear it and the gate proves it.
- Pipelined review: freeze wave diff to `.fleet/wave-N.diff`, then launch review
  lanes while next independent wave builds.
- WORKTREE PROVISIONING (2026-07-26): create fleet worktrees with
  `scripts/New-FleetWorktree.ps1 -Repo <repo> -RunId <run> -CopyFile <.env paths>
  [-Install -NodeBinDir <node20 dir>]`. It fixes the canonical location, copies env
  files, scans for escaping junctions, and VERIFIES the dependency tree actually
  materialised. A worker charter that names executable gates REQUIRES an installed
  worktree: without it Grok reports `status=partial` ("node_modules essentially
  empty — required gates not run here") and the manager re-runs every gate by hand.
  If a lane is deliberately dependency-free, say so in the charter and assign the
  gates to the manager instead — never leave the worker unable to pass its own gate.
- WORKTREE LOCATION: every Fleet-created worktree lives under
  `%USERPROFILE%\.codex\worktrees\<repo-slug>\<run-or-branch>` (or the session
  scratchpad for throwaway probes) — NEVER as a sibling of the main checkout and
  NEVER anywhere under `Documents\`. Sibling worktrees buried the owner's Documents
  folder in 30+ `Harken-v2-*` dirs (caught 2026-07-22). Remove the worktree AND its
  directory at run end; a run is not complete while its worktree remains.
- Before removing a Windows worktree, inspect for junctions with
  `Get-ChildItem -Recurse -Attributes ReparsePoint`; remove junctions themselves
  before `git worktree remove`. Never recursively delete a worktree path. For a
  tree that is already unregistered/orphaned, the ONLY approved delete is
  `python scripts/purge_orphan_tree.py <dir>` (junction-canary self-tested; never
  robocopy /PURGE or /MIR, never os.walk-based deletion, never rd/Remove-Item -Recurse).
  `Invoke-Grok45.ps1` now enforces this structurally: it refuses fail-closed to run in
  an `-IsolatedWorktree` whose directory tree holds a reparse point escaping the
  worktree, and never recurse-deletes through one. The manual rule still applies to any
  caller that deletes a worktree without going through the wrapper.
- Any acceptance oracle that is itself a model call (e.g. LLM-judged extraction/UI
  acceptance) must pin temperature per-request and require 2-of-2 (or best-of-N
  majority) agreement before emitting GO or NO-GO. A single sampled model verdict is a
  flaky gate; run every model-based acceptance doc at least twice before scoring.
- Every wrapper invocation quotes every path argument. The user profile path
  contains a space; an unquoted `-File` argument truncates at the space and
  dispatches a nonexistent half-path, killing the lane instantly (three lanes
  died this way 2026-08-03).
- Native Codex subagent spawns MUST pin an explicit fleet model (spawn parameter),
  never inherit the app default. Default-model fan-out burned 44.6% of
  2026-08-03 tokens on gpt-5.5, a model outside this routing table. A spawn
  without an explicit model is a dispatch defect.

## Liveness

Use hard timeouts and output files for external CLIs:

| Tag | Budget |
| --- | --- |
| mechanical | 10 min; pass `-TimeoutSeconds 600` |
| standard | 20 min; wrapper default or pass `-TimeoutSeconds 1200` |
| hard | 40 min; pass `-TimeoutSeconds 2400` explicitly |
| Grok review | 15 min; pass `-TimeoutSeconds 900` |
| Opus/GLM review | selector-owned all-in frozen-packet + risk-aware; see full-review protocol |

For required implementation lanes, poll about every 5 minutes. File growth, thinking events, or CPU growth means
alive. Flat output and flat CPU across two polls means hung: kill the entire
process tree, verify it is gone, mark strike, and retry once fresh. Do not reroute
while an old child process can still edit the same scope.
If source files, thinking events, and CPU are flat across two one-minute polls, no
test/tool child is active, and only the structured report appears stuck, stop the worker tree and
freeze its diff. Run manager gates; if they pass, require one short read-only Grok
self-audit (240 seconds) against that exact diff before acceptance. Never rerun
implementation merely to recover a missing report, and never use this salvage path
while source or test output is still changing.
Opus/GLM final-review lanes consume `Get-FleetReviewBudget.ps1` output, including
the selected tier and transport hash. Provider timeout is `no_contest`, not a retry
or reroute; local transport faults are repaired before dispatch. Record scheduler
queue delay separately from wrapper wall time so a queued batch is never attributed
to model latency.
Codex `-o` writes the final answer while live events may appear on stderr. The Pi
wrapper uses print mode so cumulative event bodies never exist in its output;
never bypass it or request raw Pi JSONL.
End of run: kill only worker processes this fleet started, then verify with a
process list. Verify worktree cleanup with `git worktree list`. Run
`scripts/Assert-FleetLaneCompletion.ps1 -LaneDir .fleet [-DeliverableDir <dirs>]`
and quote its summary line (`lanes: N audited, X ok, ...`) in the final report: a
0-byte or unparseable lane result is a DEAD lane, not a finished one (two died
unnoticed on 2026-07-25), and a workspace lane's empty stdout is only excused when
its deliverable directory actually holds files. A run with an unrescued dead lane is
not complete.

Before declaring worker code missing, read how the worker wrote it and pattern
verification greps to the actual style (`stdin?.on` vs `stdin.on` matters).

## Output & Discipline

- All wrapper transports append the mandatory terse-output trailer; supervisors and the planner write caveman-terse narration; evidence is never compressed.
- Keep progress terse: action, evidence, blocker.
- Put this in every worker prompt: "Smallest diff that satisfies the spec. Reuse
  existing helpers; search before writing new ones. No new abstractions, files,
  or dependencies unless the task says so. Over-engineering is rejected."
- `Invoke-Grok45.ps1 -LeanSystemPrompt` carries this compact Ponytail rule directly
  into each Grok implementation call: delete or reuse before adding, use installed
  dependencies and existing utilities, and create no abstraction/file/dependency
  outside the locked charter. Fleet keeps Ponytail hooks disabled for these calls so
  the structured worker contract stays deterministic and does not pay a second
  hook/plugin context cost.
- Give Grok a literal write manifest: owned paths, do-not-touch paths, allowed new
  files, expected size, and required focused checks. Use a numerical hard cap only
  for an explicit benchmark or evidence-backed task risk; never as a global default. Permit broad
  tracked-repository reads so Grok can find callers and existing helpers. A missing
  write manifest makes the comparison invalid.
- On Windows, state that the terminal is PowerShell 5.1. Prohibit Bash heredocs,
  inline-shell whole-file rewrites, helper scripts, and temp source artifacts; use
  `search_replace` for source edits.
- Grok coding prompts require effective effort high, literal acceptance-criteria checking, scope/EOL
  preservation, and adversarial self-review before reporting.
  Validate `self_check`, `findings`, and `fixes`; notes are context, not a redundant
  pass/fail field.
- Make Grok self-review reconcile every edited path against the manifest, then inspect
  duplicate helpers and over-budget files. Grok runs focused commands; Terra/Codex rerun
  `git diff --name-status`, `git diff --numstat`, focused tests, and Fallow before selection.
- Require Grok to report suspected scope violations, new dependencies, largest
  changed source file, and static self-findings. Require Terra/Codex to report diff
  lines, Fallow findings, failed tests, and exact retest output.
  Score the frozen output for learning, then reject it from selection when a hard
  constraint is violated.
- Grok prompts must say: "Do not make UX, product, public-API, cross-service
  architecture, or security-policy decisions. Within locked external behavior,
  choose private implementation details and return blocked only when a locked
  decision or write-scope expansion is required."
- Gemini research/review prompts ALWAYS carry two standing rules (not benchmark-only):
  cite-verify-or-drop (cite only URLs fetched this run; drop unverifiable sources — this
  took its fabrication 4/4 to 0/4) and quote-the-resolution (before reporting a
  contradiction, quote the neighboring text and state why no resolution exists — its v3
  lone CRITICAL was a misread of a contract line resolved two lines later). Route text/
  contract review to Gemini only in benchmarks; its real lanes are visual evidence and
  giant-context reads, where it should be measured.
- The manager owns browser work through Codex browser/computer-use tools and Sol
  owns the visual verdict. Gemini/agy defaults to one batched call for UI-heavy work;
  launch it after capture in parallel with other work, and skip it for ordinary
  functional checks. Wait for it only on UI-heavy work, large image sets, or an
  explicit request for an independent visual opinion. Never call it per screenshot.

## Reviews
Panel size follows the tier (references/mode-selection.md): MICRO = deterministic
gates only (one fast blind pass if user-facing); LIGHT = Sol + fresh Terra, +1
cross-family voice when behavior is touched; STANDARD = Sol + Terra + one specialist;
FULL = all five blind voices. Grok's implementation self-review is mandatory but never
counts as an independent final-review voice. FULL also dispatches the Kimi K3 PROXY
data seat (Invoke-KimiK3Proxy.ps1): a sixth, NON-GATING voice recorded for panel-
qualification evidence only — see review-protocol.md charter 6; its outage or timeout
never blocks the panel, and it never grades other models.
At FULL-review synthesis, the supervisor appends one K3 qualification row to
`BENCH-k3-qualification.jsonl`; the tenth dispatched FULL row adds a Sol
promotion-assessment task to the final report, never automatic promotion.

OPUS 5 REVIEW VOICE (owner directives 2026-07-25/26, replacement 07-26): Claude
Opus 5 REPLACES Opus 4.8 as the Opus seat on adversarial review panels — one Opus
voice, not both. Dispatch via the canonical wrapper (`Invoke-Opus48.ps1 -Model
claude-opus-5`, label `[CLAUDE OPUS 5 · REVIEW]`; wrapper auto-appends the
caveman-ULTRA block). Budget the lane for Opus 5's measured ~2-3x wall time vs 4.8.
VERIFY-BEFORE-CHARGE is mandatory for its findings: pair #1 measured 2/5 false
positives among its unique findings, and each FP costs a manager verification pass.
Opus 4.8 remains available ONLY as (a) outage/timeout fallback for the Opus seat
(record `voice_substituted`) and (b) explicit-benchmark pair partner. Log one row
per Opus 5 review dispatch to `BENCH-opus5-pairs.jsonl` (solo rows allowed:
wall/precision/verified-FP fields; paired fields only when a 4.8 pair actually ran).
Opus 5 never implements and is never the main loop on fleet work (07-25 regressions).

OPUS 5 DESIGN (owner 2026-07-26: "better than Kimi" at design): Opus 5 joins Kimi
K3 as a design-proposal candidate — `[CLAUDE OPUS 5 · DESIGN PROPOSAL]`, Sol still
locks. EXPLICIT-REQUEST ONLY (slow): on request, run Opus 5 + K3 on the same frozen
design brief and blind-judge both with cross-family graders (no self-grade,
position-swap, fabrication-flagged models excluded), scored into the design-off
ledger. Not a default lane; the owner asks.

FILE DELIVERABLES NEVER RIDE THE CHAT TRANSPORT (2026-07-26 failure, now structural):
when a lane's deliverable is FILES (HTML prototypes, design systems, generated
source), dispatch it as a WORKSPACE lane — Opus:
`Invoke-Opus48.ps1 -Model claude-opus-5 -DesignOutputDir <dir>` (tools scoped
Write/Read/Edit, cwd = that dir, result carries `design_files[]` + `design_file_count`,
and zero files written is `status=error` no matter how cheerful the reply); Kimi:
`-DesignWorkspace -DesignOutputDir` with incremental export. NEVER ask a print-mode
lane to inline file contents in its response: `claude -p` returns only the FINAL
assistant message, so a 30-40KB file is silently decapitated. Charter language is
part of the fix — the clause "include the complete file contents in your response
because only your response text is guaranteed to survive" CAUSED the failure and is
BANNED; say "write each file with the Write tool, most important first; the response
carries only the manifest + rationale". A truncated deliverable is a LOCAL TRANSPORT
FAULT: re-dispatch on the workspace lane. Never accept, stitch, or re-prompt for
"continued from…" fragments — one live run burned ~40 min across three lanes
producing hand-stitch instructions while the Kimi workspace lane wrote four complete
files. Any lane whose result file is 0 bytes is DEAD, not done: check the deliverable
directory before reporting.

No substitute lanes: a claim of fleet review requires the frozen packet plus wrapper
receipts (result JSON from the canonical Invoke-* lanes). Orchestrator-native
subagents or third-party reviewers may supplement, never replace, the tier's
canonical voices; if a tier needs no canonical lane (MICRO), state that explicitly.

LIGHT: if the selected voices are clear and gates pass, Sol's verdict is final. Any
verified finding is repaired and returned to Sol for `GO|NO-GO`; any higher-tier
trigger escalates before approval.

STANDARD/FULL and `review` follow
[references/review-protocol.md](references/review-protocol.md): freeze the packet, run
the selected voices in ONE concurrent wave (detached wrapper jobs; rolling dispatch
fallback — no two-batch barrier), then Sol arbitration under the cross-family scoring
rule. SLOWEST VOICE LAUNCHES FIRST (2026-07-26): dispatch order inside the wave is by
measured wall time descending — Opus 5 (~2-3x Opus 4.8) goes out before the faster
voices so the panel finishes inside its window instead of after it. Order costs
nothing and is pure wall-clock. Bias controls are mandatory on every scored comparison: no grader scores its own
output, a scored ranking needs >=1 cross-family grader, fabrication-flagged models
(Gemini, Kimi) are excluded from grading duty, and artifacts are anonymized/leak-
stripped with position swap. Read the protocol before freezing or dispatching.

For cross-repo work, name sibling repo roots in every charter so reviewers do
not false-flag missing routes/files from the wrong checkout.

Gating:

- any evidence-verified `BLOCK`, `CRITICAL`, or `HIGH` -> request changes
- unresolved `WATCH` -> comment with exact follow-up
- otherwise Sol may approve after the selected mode's required final verdict

## Adversarial Review Is Not Optional (owner mark, 2026-07-26)

The Definition of Done at the top of this file is the enforced summary of this section;
if the two ever disagree, the DoD wins. This section is the rationale and the history.

The review is a STANDING step after every coding/fix/config wave, before any claim of
done - not something the owner has to ask for. On 2026-07-26 three implementation runs
(`fleet-fix-20260726b`, `fleet-measbug-20260726`, `fleet-backlog-20260726`) shipped with
ZERO review receipts; the orchestrator substituted its own reproductions, which is
self-review and never counts as an independent voice. The owner had to ask every time.

Enforcement, so this cannot depend on the orchestrator remembering:

- A run is NOT complete until `scripts/Assert-FleetAdversarialReview.ps1 -Repo <repo>
  -BaseRef <base>` passes and its summary line is quoted in the final report, exactly like
  the Fallow, filesize, and lane-completion lines.
- That gate proves receipts EXIST and COVER the shipped diff: a frozen packet whose
  manifest matches the current diff, plus wrapper result files from the tier's voices.
  Receipts for an older diff do not count.
- Tier still scales the voice count (MICRO = deterministic gates only, and say so
  explicitly); everything above MICRO needs real voices.
- Suites, self-repros, and mutation proofs are PRE-conditions for review, not substitutes
  for it. "I verified it myself" is the exact claim the review exists to check.

## Final Report

Include only:

- tasks shipped
- changed files
- gate evidence
- review verdicts
- outages/reroutes
- known risks or WATCH items
- utilization by lane
- Grok implementation count, self-review repairs, final-audit findings, escalations,
  Opus/GLM metrics (availability, time, unique/false/adopted findings, or
  `not_selected_by_mode`),
  and available time/token/cost telemetry. Include win/tie/loss and ledger metrics
  only when this run contained a genuine paired benchmark.
- Per external lane: wall time, model turns when available, tool-call count/errors,
  final prompt/context tokens when available, focused-check time, timeout/kill reason,
  and whether code was already usable before report completion. Separate model,
  tool, environment, acceptance, and orchestration failures; never attribute total
  task wall time to Grok without phase evidence.

No commits or pushes unless the user asked.

Append durable friction one-liners to
`$env:USERPROFILE/.codex/skills/fleet/LESSONS.md`.
