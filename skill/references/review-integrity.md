# Review integrity, refusal failover, security identity

Canonical policy for hosted-model refusal, open-weights failover, the review-
integrity gate, and security-voice identity. Orchestrators MUST satisfy this on
every review run; SKILL.md only links here — do not restate the algorithms.

Related: [mode-selection.md](mode-selection.md) (`review_profile`),
[merge-readiness.md](merge-readiness.md) (stage fallbacks),
[review-protocol.md](review-protocol.md) (panel freeze),
[lane-span-schema.md](lane-span-schema.md) (span fields).

## Refusal (hosted model declines a task)

A hosted model (Sol / Terra / Luna / Fable / Opus) that declines a task via
content-filter, policy, or capability is **`refused`**.

Deterministic signals live in `scripts/FleetLaneRefusal.Helpers.ps1`. Reason enum:

| Reason | Meaning |
| --- | --- |
| `content_filter:codex_cyber_flag` | Codex cyber content-filter flag |
| `content_filter:trusted_access` | Trusted-access content filter |
| `policy_decline` | Explicit policy refusal |
| `capability_decline` | Model declines for capability |
| `security_empty_verdict` | Security lane returned empty verdict after filter |

**Not a refusal:**

- Completed `BLOCK` / `NEEDS-FIX` / real findings (negative verdict ≠ refusal)
- Nonzero exit **without** a refusal signal = **transport failure**, not refusal

Transport failures follow the existing `no_contest` / repair path. Refusal is a
settled **semantic** outcome.

## Failover (hosted refusal → open-weights)

On a hosted refusal the orchestrator:

1. Records `outcome=refused` on the refused lane span:
   - span `status=error`
   - `error.type=model_refusal`
   - **NEVER** `no_contest` for a refusal
2. Re-dispatches the **BYTE-IDENTICAL** frozen charter to Kimi + GLM.

### Owner threshold

- Attempt both open-weights failover targets.
- Run **PASSES** on **>=1 real (non-refused) completion** from
  `{ Kimi, GLM, Grok }` for that task.
- A single down/unavailable open-weights model must **not** block the run.
- If both Kimi and GLM fail, **Grok is an eligible failover voice**.
- Fail closed **only** when **ZERO** eligible failover voices produced a real
  review.

### Failover lane identity

Each failover is a **NEW labeled lane** (not a wrapper reroute) with:

- its own receipt + lane-span
- `fallback_of` = the refused hosted `lane_id`
- matching `task_id` / `charter_sha256` / `input_packet_sha256` / `locked_plan_sha256`
- `started_at` >= refused lane's `completed_at`

A negative verdict / `BLOCK` never triggers failover — only a refusal does.
Distinct from the transport `no_contest` rule (Preflight / Liveness).

## Gate (`Assert-FleetReviewIntegrity.ps1`)

`scripts/Assert-FleetReviewIntegrity.ps1` is **VERIFY-SIGNATURE-FIRST**: nothing in
a receipt is trusted until its HMAC-SHA256 verifies against the **run lease key**.

### Signature authority (v2)

- Receipt `schema_version` exact `"2"`; `receipt_type` exact `review_lane`.
- Algorithm: HMAC-SHA256 over fixed-schema TLV (see design lock).
- Key: active run lease (`Get-FleetRunLeaseKey -RunId`); key lives only under
  `%USERPROFILE%\.codex\fleet\run-leases\<run_id>.json`.
- `key_id` is diagnostic only; **never** key-lookup authority. External
  **`-RunId`** selects the lease; never unsigned receipt `run_id`.
- One bad / unsigned / wrong-key / wrong-run receipt **INVALIDATES THE WHOLE SET**
  (fail closed, exit 1). Never skip it or rescue with a valid sibling.

### Universal verify order (per receipt)

1. Require external `-RunId` (Mandatory). Load active lease key
   (`Get-FleetRunLeaseKey`); fail closed if lease missing/expired/keyless.
2. Parse JSON only enough for syntax + exact canonical field shape/order/types.
3. Recompute HMAC via `Test-FleetReceiptSignature` (lease key + expected
   `key_id`); constant-time compare.
4. **Only after** signature verifies, trust `run_id`, `lane_id`, identity, model,
   status, timestamps, paths, hashes, fallback, findings, profile.
5. Require signed `run_id` / `key_id` match lease; signed
   `expected_lane_manifest_sha256` equals SHA-256 of the immutable base manifest.
6. Apply semantic checks (below).

### Semantic checks (after provenance)

- Exact signed `lane_id` membership in base (no filename/prefix equivalence);
  non-failover lane not in base => FAILED.
- Exactly one signed receipt per base lane (0 or >1 => FAILED).
- Hosted completed label alone never satisfies: result body re-checked
  (`Test-FleetLaneRefusal`); completed-with-refusal content is treated refused.
- Each base lane binds to a schema-valid span with model agreement (request **and**
  non-null response model).
- A `model_refusal` span requires a matching refused receipt + proven eligible
  open-weights failover (`Test-EligibleFailover`, >=1 of `{kimi,glm,grok}`).
- Effective manifest **ADDS** only signature-verified failovers; never shrinks base.

Params (match script exactly):

| Param | Role |
| --- | --- |
| `-ReceiptDir` | directory of lane receipt JSON files (Mandatory) |
| `-RunId` | run id (Mandatory); lease-key authority |
| `-SpanLedger` | **MANDATORY**; span JSONL for failover/span binding |
| `-BaseManifest` | **MANDATORY**; immutable pre-dispatch ExpectedLaneManifest |
| `-OutputManifest` | path to write effective manifest (base + proven failovers only) |
| `-Mode` | `text` (default) or `json` |

Summary line (quote verbatim in Final Report for review runs) — **unchanged format**:

```text
review-integrity: <run> | hosted: H | refused: R | open-weight-failovers: C/R | verdict: ok|FAILED
```

`C/R` = covered failovers / refused hosted count (not `C/2R`). Missing line = gate
did not run.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Assert-FleetReviewIntegrity.ps1 `
  -ReceiptDir .fleet\review-receipts -RunId <run> `
  -SpanLedger BENCH-lanes.jsonl `
  -BaseManifest <immutable-pre-dispatch> `
  -OutputManifest <effective-manifest>
# then:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Assert-FleetLaneSpans.ps1 `
  -RunId <run> -LedgerPath BENCH-lanes.jsonl `
  -ExpectedLaneManifest <effective-manifest>
```

## Security identity (`review_profile`)

Locked plan carries exactly one machine-readable line:

```text
review_profile: general|security-sensitive
```

When `review_profile: security-sensitive`:

1. Tier **MUST** be **FULL**.
2. Panel **MUST** include **>=1 open-weights security voice IDENTITY**:
   - `v-glm-security` or `v-kimi-security` (required forms)
   - `v-grok-security` acceptable **backup** only
3. Generic `v-glm` / `v-kimi` / `v-kimi-proxy` do **not** satisfy.

Enforced by `scripts/Assert-FleetAdversarialReview.ps1`. Sensitive-review trigger
and `review_profile` selection: [mode-selection.md](mode-selection.md).

## Orchestrator checklist (do not skip)

- [ ] Run lease active before gate; receipts signed v2 under that lease key
- [ ] Hosted declines classified as `refused` vs transport vs real BLOCK
- [ ] Refusal → `error.type=model_refusal`, never `no_contest`
- [ ] Failover charters byte-identical; new lanes with `fallback_of`
- [ ] Pass threshold: >=1 real completion from {Kimi, GLM, Grok}
- [ ] `review-integrity:` line quoted; lane-spans use **effective** manifest
- [ ] Pre-dispatch manifest immutable; signed `expected_lane_manifest_sha256` binds
- [ ] `security-sensitive` → FULL + security identity (not generic seat)
