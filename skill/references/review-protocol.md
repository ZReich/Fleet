# Fleet Review Protocol (STANDARD + FULL)

Panel size is set by the tier and `review_risk` (see
[mode-selection.md](mode-selection.md)). This file governs how the selected voices
are frozen, dispatched, judged, and arbitrated.

HARNESS LAW (mandatory): every review/critique lane produces FREE-FORM MARKDOWN. Never
force a reviewer through the implementation worker-JSON envelope or "return only JSON" —
that harness buried a 94-grade Grok reviewer at 75.5 (2026-07-18). Extract any
machine-readable severity/metadata wrapper-side, or request a small trailer block AFTER
the markdown. A low score in a mismatched harness is a harness finding, not a model
finding. MICRO/LIGHT staffing lives in
mode-selection.md; this protocol's freeze, bias controls, and arbitration apply to
every scored review that uses more than the manager's own read.

## Freeze the packet

Freeze the canonical packet before dispatch:
`base.sha`, `final.diff`, `touched-files.txt`, `locked-plan.md`,
`acceptance-evidence.md`, `gate-evidence.md` (the required six), plus an OPTIONAL
`caller-context.md` (callers/importers per touched export via rg/JCodeMunch, so no-tool
reviewers verify cross-file impact without tools), and machine gate artifacts
`test-results.json` / `fallow-results.json`. Generate `caller-context.md` for any
behavior-changing review; the builder hashes it into the manifest when present and it
flows to every reviewer through `artifact_paths`. Pass
`Get-FleetReviewPacket.ps1 -ReviewRisk mechanical|behavior|hard` (default `mechanical`).
For `behavior` or `hard`, both `test-results.json` and `fallow-results.json` are
required, nonempty, valid JSON, and hashed; for `mechanical` they remain optional but
are hashed when present. Stable artifact order is the six required artifacts,
`caller-context.md`, `test-results.json`, then `fallow-results.json`. Manifest
`schema_version` stays `"1"` and includes `review_risk`, which participates in
`packet_sha256`. Behavior/hard packets cannot substitute prose in `gate-evidence.md`
for these artifacts. Run
`scripts/Get-FleetReviewPacket.ps1` before any
reviewer or budget selector; it fails closed on missing/empty artifacts, invalid
JSON, missing risk-required artifacts, or invalid
base SHA, writes `packet-manifest.json`, and its `artifact_paths` are the only list
passed to reviewers. Budget selection and the no-tool wrappers re-attest the ordered
list and canonical UTF-8 bytes against that manifest before launch
(`Assert-FleetReviewPacketManifest.ps1` rebuilds using manifest `review_risk`; omitted
risk in an older manifest means `mechanical`). A commit range
alone is not a review packet. Large diffs may be chunked, but every lane receives the
same immutable bytes.

Cross the `powershell -File` boundary with the wrapper's comma-joined `-ArtifactFile`
contract (`($reviewArtifacts -join ',')`); a raw PS array splats positionally and
corrupts later params.

Before dispatch, live-probe the selected external voices through their canonical
wrappers. A local compatibility/PATH/wrapper failure blocks review start and must be
repaired; a provider outage after a verified model launch is `no_contest`. If a whole
voice is down (e.g. Claude pin-drift), preflight surfaces it loudly and applies the
documented degraded mode: substitute one cross-family voice (GLM `-Thinking high`) and
record `voice_substituted` — never silently run a smaller panel while claiming full.

## One concurrent wave (no two-batch barrier)

Opus, GLM, and the three Grok lanes (5a/5b/5c) are PowerShell wrappers, not Codex
subagents, so they do not consume Codex child slots: launch them as detached background
jobs (`Start-Process` + JSON output file + the existing liveness poller) against the
frozen packet. Review latency is then the single slowest voice, not
`max(BatchA)+max(BatchB)`. Blindness is unaffected — isolation is about not seeing peer
output, not about timing.

The Grok fan-out puts the FULL panel at five wrapper lanes (Opus, GLM, Grok×3), above the
root-plus-three cap, so **rolling dispatch is the FULL default, not a fallback**: keep the
root-plus-three cap, and launch the next queued lane the moment any slot frees (never wait
for a whole batch). Grok is the fastest lane, so its three slots free quickly and the
extra breadth costs little wall time. Order the queue slowest-first (Opus ~2-3x, then GLM,
then the Grok lanes) so the long pole starts first. Relay each lane's `[MODEL · ROLE]`
heartbeat rows from root for sidebar identity, and verify each slot freed before the next
launch. Sol/Terra are Codex lanes and run outside this wrapper cap as before.

## Charters (assign only the voices the tier selected)

1. Resumed planner Sol: plan coverage, architecture, boundaries, decision-ledger
   compliance, and the strongest case against its plan; `CLEAR|WATCH|BLOCK`.
2. Fresh Terra (never the orchestrator session): spec, correctness, security,
   performance, maintainability.
3. Claude Opus 5 high (STANDARDS AXIS; `-Model claude-opus-5` is the wrapper default —
   4.8 only as outage fallback with `voice_substituted`, or an explicit benchmark pair):
   hidden coupling, incomplete evidence, maintainability,
   and the strongest counterargument to shipping. Its maintainability charter is
   anchored, not free-floating: paste [smell-baseline.md](smell-baseline.md) in full
   into this lane's prompt (the frozen packet does not carry it) plus the repo's own
   standards docs (`AGENTS.md` / `CODING_STANDARDS.md` / `CONTRIBUTING.md`). Repo
   standards override the baseline; baseline smells are always `judgement`, documented
   breaches may be `hard`; skip anything Fallow/eslint/tsc already gate. Findings go
   under a `## Standards` heading.
4. GLM: a GENERAL adversarial voice (co-champion at 94.67, 2026-07-18), not a narrow
   specialist. Its edge/error checklist (null/empty/error paths, races, timezone/
   encoding, tests, each touched export's error/routing contract vs base) is a FLOOR,
   not a ceiling — it also finds doc-drift and security inconsistencies. Default
   `-Thinking high` for STANDARD and FULL (the 900s budget absorbs it and the evidence
   says the marginal tokens buy the top score); `-Thinking low` only for LIGHT. Keep the
   `cli-pinned-unobserved` identity caveat.
5. Grok 4.6 high (`high` is the effective ceiling — the CLI dropped xhigh/max and the
   wrapper collapses both to high; benchmark rows record `high`):
   a full-strength adversarial voice (75.5->94 once freed from the
   worker-JSON harness — see the Harness Law). Grok is the fastest and cheapest lane on
   the panel, so at FULL it FANS OUT to THREE diverse-lens lanes instead of one. This
   multiplies COVERAGE, not voting weight: the three lanes each hunt a different failure
   class, and Terra dedupes their findings into a SINGLE counted Grok voice (see "Grok
   fan-out counts as one voice" below). Diverse lenses, not redundant votes — three
   identical passes would just be one voice paying triple. Each lane may read the
   referenced scripts/files READ-ONLY when the packet references executable behavior (two
   of Grok's best v3 catches — the tier-gate coercion and the auto-shadow stub — required
   reading on-disk code a frozen-packet-only voice cannot see); keep frozen-packet-only
   for pure-diff reviews. `[GROK 4.6 · SPEC]`, `[GROK 4.6 · CORRECTNESS]`,
   `[GROK 4.6 · REGRESSION]` label the three lanes. Each lane's prompt is built by copying
   its checked-in lens template — [grok-lens-spec.md](grok-lens-spec.md),
   [grok-lens-correctness.md](grok-lens-correctness.md),
   [grok-lens-regression.md](grok-lens-regression.md) — into `.fleet/T1-grok-<lens>.txt`
   and appending the frozen packet. Do not paraphrase the lens per run; the templates are
   what keep the three lenses distinct and the correctness lane's concrete-repro rule
   enforced.

   - **5a — SPEC (owns the `## Spec` axis heading).** Against `locked-plan.md` and the
     originating ticket/PRD, three questions explicitly: (a) what the spec asked for that
     is missing or partial, (b) behavior in the diff nobody asked for (scope creep),
     (c) requirements that look implemented but are implemented wrong — quoting the spec
     line for each finding. Also literal acceptance/directive compliance, drift, silent
     fallbacks, sample data. No spec resolvable (no locked plan, no ticket) = say "no spec
     available" and the axis reports zero, never silently passes.
   - **5b — CORRECTNESS (concrete reproduction, not a checklist).** Null/empty/error
     paths, races, off-by-one and boundary conditions, resource leaks, and each touched
     export's error/routing contract vs base. EVERY finding names concrete inputs/state →
     the wrong output or crash; a finding with no reproduction is downgraded to a WATCH.
     This overlaps GLM's floor on purpose — two independent error-path passes on the same
     diff catch more than one, and this lane must produce the repro GLM's checklist does
     not.
   - **5c — REGRESSION (what previously-working behavior does this diff break?).** The
     diff-scoped regression lens, not "is the new code good": trace behavior that worked
     at base and no longer does, silent fallbacks that swallow a changed contract, and
     sample/mock data or `resolve(true)` stubs masking real changed-rows semantics. This
     lens caught the no-op comp re-save CRITICAL a five-voice panel + 1,800 tests passed
     over (LESSONS 2026-07-25). Read the referenced source read-only and compare against
     base.

   Cross-check every Grok finding against source before folding it in. No Fleet turn cap;
   timeout and output validation bound each lane.

   **Grok fan-out counts as ONE voice.** Terra mechanically normalizes and dedupes the
   three lanes' findings into a single Grok contribution BEFORE arbitration. That merged
   set is one voice for arbitration, one voice toward five-voice coverage, and one row in
   any scored comparison — never three. Three same-family lanes voting three times is
   exactly the same-family dominance the bias controls forbid; the fan-out buys breadth,
   and the collapse keeps the panel honest. A lane that returns `error`/`timeout`/
   `no_contest` simply drops from the merge; one surviving Grok lane still constitutes the
   Grok voice.

   **When Grok is the run's IMPLEMENTER, there is NO fan-out.** Its FULL panel seat is
   replaced by a single cross-family voice (or recorded `same_family_audit=true`, not
   counted as an independent voice) — the implementation self-review exemption never
   covered the panel seat, and it certainly does not license three self-review lanes.

   Below FULL the fan-out does not apply: STANDARD and LIGHT use a single Grok review lane
   (the SPEC lens, 5a) when Grok is the change-type-selected voice, per mode-selection.md.

6. Kimi K3 (FULL only, DATA SEAT — never gating): dispatched via
   `Invoke-KimiK3Proxy.ps1` (the claude-code proxy harness won the review-genre A/B
   +8.25 over native, adopted 2026-07-22; never the native CLI for this seat). Free-form
   markdown, same frozen packet, general adversarial charter. HARD LIMITS: its findings
   and verdict NEVER count toward arbitration, five-voice coverage, or gating — treat as
   candidate evidence only; cross-check any adopted finding against source before
   folding it in. Keep prompts bounded under the ~15-min OAuth token TTL; a 401/timeout
   is `no_contest` and never blocks the panel. Record per run: wall time, verified
   unique catches, false positives, fabrication flags, adopted findings.
   QUALIFICATION TRACK: after 10 completed FULL reviews with the seat, Sol assesses —
   promotion to a counted voice requires ≥2 verified unique adopted catches, zero
   fabrication flags, and false-positive rate no worse than the worst counted voice
   over the window; otherwise the seat stays data-only or is dropped. K3 remains
   excluded from grading other models throughout.
   At FULL-review synthesis, the supervisor appends exactly one row via scripts/Record-K3Qualification.ps1 to repo-root
   `BENCH-k3-qualification.jsonl`, including non-dispatch and transport `no_contest`
   rows, using fields `run_id`, `date`, `review_tier`, `dispatched`, `why_not`,
   `verdict_summary`, `unique_findings_count`, `verified_unique_adopted_catches`,
   `fabrication_flags`, `false_positive_count`, `wall_seconds`,
   `transport_no_contest_reason`, and `k3_considered`. When the append creates the
   tenth dispatched FULL row, the final report adds a
   `[GPT-5.6 SOL · PROMOTION ASSESSMENT]` task against the locked qualification
   thresholds; it never auto-promotes K3.

Route a review that genuinely needs a 1M-context read to Kimi's long-context/research
lane rather than paying a 2.8T model to read a frozen diff a 20B model can review.

## Bias controls (each anchored to a proven in-house failure)

Every scored comparison (final-review arbitration and every benchmark row) applies:

- **No self / same-family grading.** No grader ever scores its own output; no scored
  comparison is decided solely by graders from a contestant's model family; where the
  roster allows, the judge panel for a pair excludes both contestants' families.
  Proven live 2026-07-18: design-owner-class models self-inflated (Opus +2, Sol +5)
  while implementer-class did not (Grok/GLM neutral-or-below). Sol keeps arbitration
  (it has plan context) but a scored ranking needs >=1 cross-family grader,
  position-swapped; weight Sol/Opus grades with extra care when they judge their own
  family.
- **Exclude fabrication-prone graders, with a REQUALIFICATION window.** Models with a
  live fabrication record are excluded from grading duty and serve as reviewers only.
  Re-eligibility: N=3 consecutive scored rounds with 0 deterministic citation violations
  (`cited_but_unfetched.Count`=0) and 0 upheld fabrication flags; one violation restarts
  the window. Gemini's window started 2026-07-18 (0/4 after cite-verify). This replaces
  the permanent ban and fixes grader starvation (Opus+GLM were the only eligible graders
  for an OpenAI-vs-xAI pair). Grader for a scored pair MUST NOT be a contestant's family
  where the roster allows; degraded substitution never records a duplicate family as
  restored coverage.
- **Anonymize + strip style leaks.** Normalize whitespace/headers; strip lane identity,
  session IDs, timestamps, and characteristic wrapper artifacts before grading; keep the
  reveal mapping sealed until scores are written.
- **Position swap.** Grade A-vs-B and B-vs-A; an inconsistent preference is a
  `position_inconsistent_tie`.

## Two axes, never collapsed into one number

Standards (charter 3) and Spec (charter 5) are reported side by side and counted
separately, all the way to the verdict. A change can pass one and fail the other:
follows every convention but builds the wrong thing (Standards pass / Spec fail);
does exactly what the ticket asked but wrecks the project's boundaries (Spec pass /
Standards fail). Separation is what stops a loud axis from masking a quiet one.

- Findings still normalize and dedupe as below — merging is for dedupe, never for
  reranking one axis against the other.
- Every review summary and final report carries `standards: N findings` and
  `spec: M findings` as distinct counts, each with its own worst finding. No single
  cross-axis "worst issue", no combined score.
- A Spec-axis `HIGH`/`CRITICAL` gates on its own; a clean Standards axis (or a clean
  Fallow line) never waives it, and the reverse holds too.
- Below FULL, or when a seat is substituted (Grok implementing, voice outage), the
  axes do not disappear — the staffed voices carry both charters and both headings.
  A missing heading is an incomplete review, same contract smell as a missing Fallow
  quote line.

## Arbitration

Terra mechanically normalizes and dedupes findings after all voices return. Resume the
same Sol session with anonymized findings for `GO|NO-GO`; if resume fails, start fresh
Sol with frozen artifacts, obtain its blind verdict, then arbitrate. Sol cannot
silently waive blockers.

Every `NO-GO` verdict that requires repair must end with exactly one EOF trailer consumed
by `scripts/Assert-FleetRepairCoverage.ps1`:

```text
<!-- FLEET_REQUIRED_BLOCKERS_V1
{"schema_version":"1","required_blockers":[{"id":"B1","summary":"Exact repair requirement","evidence":[{"path":"repo/relative/file.ts","change":"added","pattern":"required\\.NET-regex"}]}]}
FLEET_REQUIRED_BLOCKERS_V1 -->
```

Coverage pre-check wiring (D3): before spending another arbitration call, run
`Assert-FleetRepairCoverage.ps1 -VerdictPath <prior-verdict> -RepairDiffPath <cumulative-repair.diff>`
so every required blocker evidence clause is proven in the repair diff (`added` /
`removed` / `touched` semantics). Uncovered blockers return to repair without spending
an arbitration round.

### Arbitration cap (D5)

- Maximum three Sol arbitration rounds per wave.
- Initial arbitration is round 1.
- Before dispatching rounds 2 or 3, run `Assert-FleetRepairCoverage.ps1` against the immediately preceding verdict and cumulative repair diff.
- Any uncovered blocker returns directly to repair; no arbitration call is spent.
- After round-2 `NO-GO`, the round-3 repair charter contains only unresolved blocker IDs and their locked evidence clauses. No opportunistic cleanup, redesign, or unrelated WATCH work.
- Round 3 receives one final arbitration.
- Round-3 `NO-GO`, a newly discovered semantic blocker, or an invalid coverage trailer freezes the diff, packet, verdicts, and evidence. No fourth repair/arbitration round is allowed.
- Resume only through a new Sol-locked plan and new wave; the new wave resets the counter.

Gating:
- any evidence-verified `BLOCK`, `CRITICAL`, or `HIGH` -> request changes
- unresolved `WATCH` -> comment with exact follow-up
- otherwise Sol may approve after the tier's required verdict

### Re-review round cap (separate counter from arbitration)

Not the same counter as the Sol arbitration cap above (D5, three rounds WITHIN one
wave's verdict cycle). This caps whole re-review rounds across a run — dispatch a
fresh panel, gate it, repeat.

- Maximum three re-review rounds per run. A fourth does not exist: freeze the diff,
  packet, and verdicts; report unresolved blockers to the user; escalate. Continuing
  requires a new run-id and a new locked plan, not a fourth round.
- Each round reviews the packet FROZEN at round start, never a moving target.
  Repairs between rounds are limited to the verified findings from the prior round —
  no opportunistic cleanup or new behavior. If the shipped diff has grown more than
  10% in bytes since the frozen packet, the round's review target no longer exists:
  abort the round and re-freeze a new packet under a new round (still counted toward
  the cap).
- Before consuming any round's lane outputs, run
  `scripts/Assert-FleetLaneCompletion.ps1 -LaneDir <round dir>`. A 0-byte or missing
  lane output is a dead lane, not a completed round — it does not count as a voice
  and must not be silently folded into the verdict.
- A voice that times out or comes back dead is substituted instantly with a labeled
  cross-family voice (`voice_substituted`) so the round completes on schedule — never
  hold the round open waiting on a dead voice, and never let a dead lane's absence
  pass unnoticed.

## Retention (FULL panel)

`scripts/Get-FleetReviewBudget.ps1` is the executable authority for Opus/GLM budgets;
it builds the all-in frozen packet exactly as the no-tool wrappers serialize it. Sol
sets `review_risk` in the locked plan; risk can only promote a byte tier.

| Tier | All-in packet / review shape | Opus | GLM |
| --- | --- | ---: | ---: |
| tiny | <=50 KiB, mechanical, narrow export/config, no behavior/cross-file contract | 120s | 180s |
| standard | >50-250 KiB, or any normal behavior-changing/cross-file review | 300s | 600s |
| hard | >250 KiB, or migration/auth/security/concurrency/data-contract/multi-surface UI | 600s | 900s |

Never manually pass `120s` for a non-tiny lane. One attempt at the selected budget;
provider timeout is `no_contest`, never a retry/reroute. Record wall time, availability,
verified unique catches, false positives, adopted findings, and `voice_substituted`.
After each 10 completed FULL reviews, Sol assesses incremental value: recommend
demotion-to-opt-in for a voice only when it produced zero verified unique adopted
catches across that window and materially delayed review; permanent removal or
promotion requires predeclared non-inferiority stats. An optional-voice outage never
blocks remaining voices.

Record all voices in the v8 run record via `scripts/Record-GrokBenchmark.ps1`:
execution status, exclusion reason, wall time, unique/false/adopted catches, grader
provenance, and phase telemetry. Keep GLM identity `cli-pinned-unobserved` unless a
benchmark identity-capture probe verifies it. Transport-only probes are verification
evidence, not model-quality rows.

For cross-repo work, name sibling roots in every charter so reviewers do not
false-flag missing routes/files from the wrong checkout.

## Converged-finding fast path (Fable directive 2026-07-23)

When >=2 cross-family voices converge on the same finding (same file+line+claim),
the supervisor MAY dispatch its fix worker immediately — during arbitration, before
the full verdict — because convergence already meets the fix-without-debate bar.
Singleton findings still wait for arbitration. The fix lands in the normal repair
worktree and is re-reviewed with the round; this trades nothing for wall-clock on
the dominant tail (review -> fix -> re-review cycles).
