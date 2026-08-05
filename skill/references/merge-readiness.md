# Merge-readiness review mode

Named-stage contract + deterministic reducer for pre-merge readiness. Distinct from
ordinary `review` (plain diff panel). Tier = STANDARD or FULL by risk (see
[mode-selection.md](mode-selection.md)). Detail on freeze/panel lives in
[review-protocol.md](review-protocol.md); lane spans in
[lane-span-schema.md](lane-span-schema.md); routing provenance in
[routing-evidence.md](routing-evidence.md).

## Stage graph

```
manifest + baseline-gates
  -> change-map
    -> parallel CONDITIONAL audits:
         security-audit | migration-audit | deployment-plan |
         user-impact | key-lifecycle
      -> synthesis
        -> adversarial-challenge
          -> triage
            -> [repair-N -> verify-N] loop, cap 3
              -> deployment-runbook  (only when deploy/infra trigger matched)
                -> deterministic reducer (Assert-FleetMergeReadiness.ps1)
```

## Mandatory vs conditional

**MANDATORY floor (always, independent of `-RequiredStages`):** `change-map`,
`synthesis`, `adversarial-challenge`, `triage`. Each MUST be `status=passed`
(`not_applicable` is **not** allowed for mandatory). Plus the reducer
(`scripts/Assert-FleetMergeReadiness.ps1`).

**Fired conditionals** (`-RequiredStages`): MUST be `status=passed` (includes
`deployment-runbook` when deploy/infra fired).

**Declared-but-non-fired** (`-ConditionalStages`): may be `status=not_applicable`
only with non-empty `evidence_refs`.

| Stage | Fires when |
| --- | --- |
| `security-audit` | security / auth / secret / crypto / authz surface |
| `migration-audit` | schema or data migration |
| `deployment-plan` | deploy / infra |
| `deployment-runbook` | deploy / infra (after repair/verify, before reducer) |
| `user-impact` | user-facing or behavior change |
| `key-lifecycle` | key / token / credential rotation |

Silence never means N/A — a missing mandatory/fired receipt is `NOT_READY`.

## Receipt schema (one per named stage)

Every named stage emits **one** receipt JSON. Fields in this exact order:

`schema_version`, `run_id`, `stage`, `required`, `status`, `observed_model`,
`effort`, `input_packet_sha256`, `fallback_of`, `failure_category`, `findings`,
`evidence_refs`, `output_artifacts`, `started_at`, `completed_at`, `model`

- `schema_version`: exact string `"1"` **or** integral numeric `1` only. Reject
  boolean `$true`, floats (`1.2`, `1.49`), padded strings (`"01"`), other values.
- `run_id`, `stage`, `model`, `observed_model`: nonempty strings
- `input_packet_sha256`: nonempty 64-char hex (`^[0-9a-fA-F]{64}$`); blank/short
  rejects the receipt (treated as MISSING)
- `status`: `passed` | `not_applicable` | `blocked` | `failed` | `no_contest`
- `required`: bool — was this stage required this run
- `fallback_of`: `null`/empty for a **root** receipt, or `"stage:model"` naming the
  predecessor this receipt substitutes for (exact `stage` + `model` of that receipt)
- `findings`, `evidence_refs`, `output_artifacts`: real JSON arrays only
  (`[…]`). Scalar string, scalar object, bool, or number => invalid. (PS 5.1
  `ConvertFrom-Json` may unroll 1-el arrays; reducer restores only when the raw
  depth-1 value literally starts with `[` — never coerces a scalar JSON value.)
- `findings` elements: `{severity, id, resolved}` (`resolved` bool)
- Duplicate top-level JSON keys (depth-1 only) => receipt invalid. Nested keys
  inside `findings` objects are not counted.
- Any schema violation => receipt invalid => stage **tainted** = MISSING.
  A valid sibling receipt never rescues a tainted stage.
- Unattributable anomaly (JSON parse error, unreadable/empty `stage`, non-canonical
  `repair-*`/`verify-*` name) => whole dir fails closed (exit 2).

**HARNESS LAW:** review/analysis body stays free-form Markdown. Receipt is a
wrapper-generated sidecar (`<stage>.receipt.json`) **or** a compact fenced trailer
at EOF of the markdown (same precedent as the blocker-trailer). Receipt is never
the primary output contract of a judgment lane.

## Author-Judge Independence

Model that authored or repaired a stage **never** owns that stage's final
acceptance. `verify-N` is judged by an independent, stronger-judgment,
cross-family-where-risk-warrants voice.

## Fallback semantics

Each stage charter declares: `primary`, `fallbacks` (ordered), `fallback_on`
(`transport error` | `provider outage` | `no-equivalent-authority`),
`fail_closed_on`.

**Canonical scope (merge-readiness stages only):** a merge-readiness stage
fallback is a **NEW LABELED LANE**, not a wrapper reroute. The global rule
that wrappers never reroute an in-flight call and that provider outage /
timeout for that in-flight call is `no_contest` is **UNCHANGED** (see
SKILL.md Preflight / Liveness). Merge-readiness only records a separate
labeled substitute lane after the primary lane settled as a legitimate
transport / outage / no-authority failure.

- WRAPPER never reroutes internally (global rule, unchanged).
- Fallback = **new** labeled lane with its own receipt + lane-span;
  `fallback_of` set to `"stage:model"` of the predecessor (primary or prior hop).
- `fallback_of` is the receipt form of `voice_substituted`; a fallback lane
  sets **both**.
- Low-quality output or a NO-GO verdict **never** triggers a model fallback —
  only transport / outage / no-authority does.
- Fallback chain ends at a different-family voice (e.g. `claude-opus-5`) then
  fail-closed.
- Reducer fallback resolution (per stage group; INVALID => stage MISSING):
  - **Root** = `fallback_of` null/empty. Exactly **one** root per stage. Two
    roots (e.g. passed primary + blocked primary) => INVALID (never sort-pick).
  - Non-root MUST name an **existing** predecessor in the same stage group via
    `fallback_of` = `"stage:model"`. Orphan (nonexistent), cross-stage, or
    predecessor with blank/illegitimate `failure_category` (not one of
    `transport error` | `provider outage` | `no-equivalent-authority`) => INVALID.
  - Authoritative receipt = single **terminal** of one valid linear chain
    root→…→terminal. Reject fork (two receipts naming the same predecessor),
    ambiguous terminal, cycle, or disconnected receipt. An unrelated passed
    fallback must not rescue a failed primary of a different stage/model.
  - Mixed `run_id` in one dir is a usage error (exit 2).

## How to run

1. Pick tier (STANDARD or FULL by risk) via mode-selection.md.
2. Select required stages from triggers (mandatory + fired conditionals;
   non-fired conditionals still require N/A receipts when listed).
3. Emit `change-map` (Spark by default) → `.fleet/change-map.md` + receipt.
4. Fan out conditional audits concurrently.
5. Run `synthesis` → `adversarial-challenge` → `triage`.
6. Bounded `repair-N` / `verify-N` with **canonical positive indices only**
   (`repair-1`..`repair-N`, `verify-1`..`verify-N`; `repair-0`, `repair-01`,
   `repair-1a` are anomalies and fail closed). Cap 3.
7. If deploy/infra trigger: `deployment-runbook` (must `passed`).
8. Run reducer; quote its line verbatim in Final Report:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Assert-FleetMergeReadiness.ps1 `
  -ReceiptDir .fleet\merge-receipts `
  -RequiredStages change-map,synthesis,adversarial-challenge,triage `
  [-ConditionalStages security-audit,user-impact] [-RoundCap 1..3] [-OutputPath path]
```

Stdout line form (exactly one on success; written after optional `-OutputPath`):
`merge-readiness: READY|NOT_READY|BLOCKED | required: N | valid: V | missing: M | stale: S | unresolved: U`

Exit: `0` READY, `3` NOT_READY, `4` BLOCKED, `2` usage (bad args, RoundCap not in
1..3, mixed `run_id`, parse/stage anomaly, or `-OutputPath` write failure).
Missing line = did not run.
`unresolved` counts unresolved HIGH/CRITICAL findings **and** each `status=blocked`
stage (BLOCKED never prints `unresolved: 0` from a blocked stage alone).

## Fail-closed reducer posture

No receipt is ever silently dropped. Decision table:

| Anomaly | Effect |
| --- | --- |
| JSON parse error | fail-dir-closed (exit 2) |
| Empty / unreadable `stage` | fail-dir-closed (exit 2) |
| Duplicate depth-1 `stage` key | fail-dir-closed (exit 2) |
| Non-canonical `repair-*`/`verify-*` (`repair-0`, `repair-01`, …) | fail-dir-closed (exit 2) |
| Mixed `run_id` in dir | fail-dir-closed (exit 2) |
| Schema-invalid receipt (incl. bool/float/`"01"` schema_version, scalar arrays, bad sha) | taint-stage = MISSING |
| Duplicate depth-1 key other than ambiguous `stage` | taint-stage = MISSING |
| Second root / dup identity / fork / cycle / orphan fallback | stage resolve fails = MISSING |
| Valid + invalid receipts for same stage | taint-stage (valid never rescues) |
