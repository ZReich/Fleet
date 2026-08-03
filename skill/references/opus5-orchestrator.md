# Claude Opus 5 as orchestrator

Source: `.fleet/research2/R1-synthesis.md` (fleet-research2-20260729, Q2 ADOPT items).
Evidence URLs: only those fetched in the research2 synthesis (Anthropic docs + lane reports). Do not invent numbers.

## Evidence gap

**K3 named gap:** no independent (non-Anthropic) practitioner data on Opus-5 orchestration was fetched this run. Treat vendor-doc ADOPTs as correctness/speed guidance, not multi-source consensus on every numeric fan-out rule.

## Adaptive thinking migration (CORRECTNESS)

Opus 5 rejects legacy `thinking.type:"enabled"` with **HTTP 400**.

Use:

```json
{
  "thinking": { "type": "adaptive" },
  "output_config": { "effort": "<tier>" }
}
```

- Prefer **thinking-on at lower effort** over thinking-off.
- Interleaved thinking is **native** on adaptive models.
- Audit any Opus orchestrator path still carrying legacy `type:"enabled"` first — hard-fail or silent fallback.

## Phase effort tiers (constant within a session)

Effort changes invalidate the message cache. One session per phase; no mid-session effort flip.

| Phase | Effort |
| --- | --- |
| plan-lock | `xhigh` |
| arbitration | `high` |
| dispatch / receipt / telemetry | `low`–`medium` |

Metric: orchestrator `duration_s`, cache hit rate.

## Strip over-verify scaffolding

Opus 5 self-verifies by default. Over-verify language is pure `duration_s` tax.

- Remove "final verification step" / "subagent verify" language from orchestrator prompts.
- Keep review **blocker-focused**: required-blocker trailers already implement the vendor-recommended fix.
- Never add open-ended "find more issues" passes.

## Spawn discipline

Delegate only large independent parallelizable work. Prefer **one** subagent when possible.

Complexity-scaled fan-out (Anthropic numeric rule; ADOPT-IF in synthesis):

| Shape | Fan-out |
| --- | --- |
| simple | 1 agent |
| comparisons | 2–4 subagents |
| complex | 10+ |

Allow reduced review panels only on **planner-declared-trivial** charters, guarded by existing **p=0.15** shadow replays so blind-panel coverage does not silently erode.

Metric: wave wall time on simple runs.

## What Fleet already does right

Validated by all 3 research lanes against current Anthropic guidance — keep:

1. **Artifact-on-disk + distilled receipts** (never raw diffs into orchestrator context).
2. **Fresh session per phase**.
3. **Charter 4-part shape**: objective / format / tools / boundaries.
4. **Spawn cap max 3** (root + three child lanes).

## Measurement

BEFORE: `.fleet/research2/baseline-speed.json` (plan 595–758s; Sol arbitration max 782–826s from synthesis measurement protocol).
AFTER: comparable run; fail if orchestrator `duration_s` flat while `tool_call_count` rises (effort-tier ADOPT miss).
