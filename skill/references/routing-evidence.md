# Routing evidence (provenance, not policy)

Dated supporting measurements for stage/genre routing. **Not policy truth** —
routing decisions live in `SKILL.md` and stage charters. This table is provenance
only: refresh before trusting economics; never invent rows.

**Authority order:** Fleet internal ledgers (`BENCH-*.jsonl`) **dominate** when
task + harness match. External DeepSWE / Pareto / Atomic numbers are
**supporting only** (UNVALIDATED external unless a Fleet ledger row exists).

| stage/genre | primary | fallback | eval source | harness | n | pass@1 or task-success | measured wall | actual cost vs list-price est | availability | observed (date) | expires | confidence | known exclusions |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| non-design implementation | grok-4.6 high | terra / luna | internal `BENCH-grok45.jsonl` | fleet worker-JSON | ledger exists (multi-run) | mixed; self-review catches common | task-local | actual cost null (Grok OAuth exposes no bill; `api_equivalent_cost_usd_upper_bound` = list-price upper bound only) | seat-available | 2026-08-05 | until ledger refresh | med | design / UX / public-API / architecture banned for Grok |
| judgment / reviewer gates | gpt-5.6-sol | other frontier → claude-opus-5 | Atomic DeepSWE snapshot (vendor/Atomic docs) | external | n unknown | Sol ~73% pass@1 | not Fleet-measured | ~$8.39/task list est (Atomic docs, UNVALIDATED) | provider-dependent | 2026-07-17 | soon | low | external harness ≠ Fleet review free-form; do not route solely on this |
| locked planning / architecture | gpt-5.6-sol | terra / luna | Fleet routing (SKILL locked-planning authority) | fleet plan lane | operational | n/a (authority, not DeepSWE) | task-local | list-price N/A for authority row | provider-dependent | 2026-08-05 | until re-measure | high | Sol owns locked planning/architecture; Terra does **not** own locked planning |
| merge-readiness synthesis stage | gpt-5.6-terra | sol / luna | external DeepSWE (Atomic / vendor table) | external | n unknown | ~70% pass@1 (Fable 5 row on same table) | not Fleet-measured | ~$4.95/task list est (Atomic docs, UNVALIDATED) | provider-dependent | 2026-07-17 | soon | low | merge-readiness `synthesis` stage only; supporting external; Fleet supervision evidence is operational, not DeepSWE |
| change-map / bulk diff read | gpt-5.3-codex-spark low (Spark) | luna@high → gemini flash | internal Spark size-ceiling lessons (LESSONS 2026-07-23) | fleet bulk-read | size tests 2x/3x | Spark pass ≤~165KB/~45k tok; break ~295KB/~80k | Spark fast under ceiling; Luna 11/11@26–39s at 295KB; Gemini cites at 491KB ~8× slower | Spark effectively free seat | high under ceiling | 2026-07-23 | until re-measure | med | artifacts over ~150KB/40k tok skip Spark → Luna; beyond Luna proven range / line cites → Gemini batched |

## How to use

- Prefer a matching `BENCH-*.jsonl` row over any external cell in this table.
- Mark low-confidence external cells as directional; never claim subscription cost
  from list-price estimates.
- When task or harness diverges (e.g. free-form review vs worker-JSON), treat the
  row as non-transferable (harness law).
- Expiry: re-probe or re-score before promoting a row into a charter default.
