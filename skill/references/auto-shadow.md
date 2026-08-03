# Fleet Auto-Shadow (post-hoc, async, non-blocking)

The owner's standing ask: on every run, automatically and randomly shadow one model
against another and grade in the background WITHOUT slowing the primary run. This is
**non-blocking by construction** — an in-band shadow would steal a scarce child slot
and slow the ship, so nothing here may gate, delay, or touch a primary. `Enqueue`
runs at task completion (packet already frozen) and only appends a queue entry;
`Start-FleetAutoShadow` runs later, off the critical path, in its own worktree and
run-lease. `critical_path_delay_seconds` MUST be 0 on every auto row — enforced.

## Sampling

At plan time Sol emits `shadow_eligible_tasks[]`, each with a `task_stratum`
(`mechanical|standard|hard|review`). Sampling is stratified with per-stratum weekly
targets (uniform random over-samples common mechanical work and starves rare hard
tasks): draw randomly WITHIN stratum under a recorded `sample_seed`; overall
`p_shadow` defaults to 0.15 with a floor of one shadow/day when eligible work exists.
The challenger is drawn from a rotating table (Grok<->Terra, Grok<->Luna,
Sol-plan<->K3-plan, future entrants). Every non-draw is recorded
(`shadow_skipped_reason`), wins and losses alike — on-request-only comparison invited
selective disclosure and is retired.

**Coverage-bias control:** the `shadow_eligible` filter ("Grok-executable, no design
decision") is recorded as `coverage_scope` on every row AND every aggregate; a blended
cross-stratum rate without `coverage_scope` is invalid by rule, so a Grok-eligible
win-rate is never read as a global verdict. The quarterly design-off samples the
excluded stratum.

## Stratified qualification boost (`auto_shadow.stratified_boost`)

Uniform `p_shadow=0.15` starves sparse qualification tracks (K3 FULL rows, Opus-5
pairs). Policy may set `stratified_boost.enabled` with named strata, each pointing
at a ledger + `n_current_source` (`dispatched_full_rows` or `valid_rows`) and
`n_target`. When a stratum is under target and UTC-day boosted queue entries are
below `daily_boost_cap` (default 2), the enqueue draw uses `effective_p_shadow=1.0`
and records `boost_applied=true` / `sampling_rate_source=stratified_boost`. Once the
target is filled or the daily cap is hit, rate reverts to `base_p_shadow` (0.15).
Missing ledgers count as 0 (under target); a malformed ledger cannot boost itself
and sets nonempty `boost_suppressed_reason`. A healthy stratum may still boost;
malformed reason retained in provenance. Explicit `-PShadow` override and `-Force`
(forced canary) always win and never apply boost. Daily-cap count, boost decision,
idempotency check, and queue publish share one queue-root mutex. Every decision and
queue/ledger row carries: `qualification_stratum`, `qualification_n_current`,
`qualification_n_target`, `base_p_shadow`, `effective_p_shadow`, `boost_applied`,
`sampling_rate_source` (`base_rate|stratified_boost|forced_canary`),
`daily_boost_cap`, `daily_boost_used`, `boost_suppressed_reason`. Consumer
`Start-FleetAutoShadow.ps1` passes these fields through to every shadow row.

## Estimands — never mixed

Every row declares `estimand`: `standardized_model` (identical prompt, context, effort,
tools, retries, and review budget — the only rows that may feed rankings/routing) or
`optimized_system` (each model in its strongest native harness — useful, banned from
the leaderboard). Existing asymmetric `grok_review_only` rows are `optimized_system`.

## Queue + worktree mechanics

`Enqueue-FleetShadow.ps1` — at task completion, when the frozen packet exists (base
SHA, task prompt + hash, acceptance criteria, allowed_paths, gate commands, final
diff), evaluate the recorded seeded draw; if sampled, append a durable entry to
`.fleet/shadow-queue/<run>/<task>.json` (append-only; a surviving entry is picked up by
the next sweep). Returns the draw decision. Never blocks; never runs a model.

`Start-FleetAutoShadow.ps1` — the consumer, run off the critical path with its OWN
run-lease. Live grading is `Invoke-ShadowReplay.ps1` (detached worktrees from the
entry's frozen `base_sha`, hashed prompts, cryptographic A/B identity, sealed
`private/reveal.json`, blinded diffs, gates with closed stdin). **base_drift guard
FIRST:** missing base -> `excluded`/`base_drift`, never graded. Per-arm budget =
`ceil(1.5 * primary_wall_seconds)`. Timeout/outage -> `no_contest` (never a loss);
timeout leaves the queue entry `pending` for a later sweep. Shadows are data-only:
`adopted_into_run=false` always; `critical_path_delay_seconds=0` always.

### As-built (2026-07-29) — enqueue snapshot + deterministic_partial

- **Enqueue snapshot:** after the frozen packet is known, `Enqueue-FleetShadow.ps1`
  embeds `task_spec` `{id, prompt, allowed_paths, gate_commands, max_diff_lines}`,
  `primary_lane`, `primary_wall_seconds`, and `packet_sha256` on each queue entry.
  Params: `-TaskSpecJson`, `-PrimaryLane`, `-PrimaryWallSeconds`, `-PacketSha256`
  (empty/null = honest omit). Later packet mutation cannot affect replay.
- **Legacy / spec-less entries** are terminal `deferred_no_spec`: no model launch,
  ledger records the status, qualification ledgers stay byte-identical.
  `live_not_implemented` is retired.
- **Rubric `deterministic_partial` (max 90, NEVER rescaled):** correctness 40 = all
  gates exit 0; spec 25 = allowed_paths adherence; tests 15 = gate count>0 and no
  timeout; scope 10 = diff-lines budget; maintainability = null (deferred). Tie:
  `abs(delta) <= 5` inclusive (5.00 = tie, 5.01 = win). A hard-ineligible arm
  (`scope_violation` / `binary_change` / `diff_budget_exceeded` / `gate_failed` /
  `commit_created`) may lose but never win. Both ineligible or any timeout/outage
  => `no_contest`. LLM graders = next wave.
- **Consumer:** `row.status='graded'` only when replay `success=true`.
  `Write-QualificationTrack` only on `success=true` with real `wall_seconds`.

## Blind grading (async, off-path, deterministic-first)

~80% of the rubric (correctness 40 / spec 25 / tests 15 / maintainability 10 / scope
10) is mechanically measurable from gate output (tests, typecheck, Fallow new findings,
diff/scope/do-not-touch violations). Only maintainability and spec-nuance need LLM
judgment: two fast graders with mandatory position swap (grade A-vs-B and B-vs-A;
inconsistent preference -> `position_inconsistent_tie`); disagreement >10 points pulls
a third grader from a family in neither the pair nor the first two graders. Reveal
mapping stays sealed until scores are written. All the review-protocol.md bias controls
apply: no self/same-family grading, fabrication-flagged models excluded from grading,
anonymize + leak-strip.

## Ledger

Write post-hoc rows to `BENCH-shadow.jsonl` (beside `BENCH-grok45.jsonl`) using the v8
schema (references/benchmark-schema.md). Quarterly rollup: win-rate by model x stratum
x coverage_scope with Wilson CIs. A stratum reaches decision-grade at >=30 pairs; no
promotion/demotion until a CI excludes parity; no rubric re-tuning mid-window.

## Exploration weighting + genre coverage (2026-07-23, owner directive via Fable)

The ledger over-characterizes Grok/Terra/GLM/Opus/Sol and says almost nothing about
Luna and Gemini Flash. Fix is sampling policy, not new machinery:

- **Under-characterized entrants** (currently: gpt-5.6-luna, Gemini 3.6 Flash, Kimi K3)
  get **2x draw weight** in the challenger rotation until each accumulates >=10 graded
  rows per genre; then they revert to uniform rotation. The entrant list lives here and
  shrinks as models graduate — update it when a model crosses 10 rows/genre.
- **Genre strata extend beyond implementation:** `review`, `synthesis` (summarization/
  briefing), `extraction` (structured pull from artifacts), `research`, and
  `visual-evidence` join `mechanical|standard|hard|review` implementation strata.
  Each genre uses its harness-law transport (free-form for review/analysis genres).
  Non-implementation genres default to `estimand=optimized_system` unless the prompt/
  context/effort are standardized across both arms — only standardized rows feed
  rankings, same rule as ever.
- **Luna challenger pairings (X-research confirmed 2026-07-23, grok field report at
  ~/Documents/docs/fleet/luna-gemini36-field-report.md):**
  implementation: Grok<->Luna@xhigh AND Terra@high<->Luna@xhigh (strongest consensus
  lane — "replace Terra High" claims need our own gates); extraction: effort ladder
  Luna low/high/xhigh (schema-following is effort-sensitive); synthesis: Terra<->Luna;
  review: ASYNC SHADOW ONLY — Luna@xhigh ties Sol on bug-find quality in one bench but
  +54% wall time / p95 ~242s tails; never an interactive review gate. Design: NEGATIVE
  CONTROL arm only (multiple "don't use Luna for design" reports). Research: not a lead;
  at most a fetch/summarize subworker.
- **Gemini 3.6 Flash pairings:** 3.5-vs-3.6 on visual-evidence, MANDATORY for
  object-detection and chart-reading tasks — 3.6 REGRESSES on both (Roboflow: lazy
  boxes/malformed JSON; ParseBench: -14% charts). 3.6 default for video/general
  vision/token efficiency; 3.5 stays canonical for detection + charts until shadows
  say otherwise. Spark<->3.6-Flash on long-log synthesis.
- **Per-genre capability map is DERIVED, never hand-written:** reports aggregate ledger
  rows by (model, genre, estimand) — the fleet-breakdown doc's rankings table gets its
  `?` marks replaced by these aggregates as rows accumulate. Rows land via
  scripts/Record-GenreRow.ps1 into repo-root BENCH-genre.jsonl; any standardized
  comparison or graded genre outcome MUST be recorded there at synthesis — verdicts
  logged only in prose or project memory do not exist.
