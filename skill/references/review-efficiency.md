# Review-pipeline efficiency contract (Sol-locked 2026-08-11, run fleet-reviewburn-20260811)

Why this exists: the 2026-08-11 codex run burned ~40% of review wall-time on harness/format
churn — 4 rounds, only 1 driven by a real code finding (r2 missing RED evidence, r3->r4
preflight status-line rebuild, r4 re-ran two APPROVEs that lacked the parser marker). These
rules make every one of those round classes structurally impossible or free.

## 1. Single-source verdict grammar (D1)

`scripts/FleetReviewGrammar.Helpers.ps1` owns BOTH the human grammar block pasted into every
charter (`Get-FleetReviewGrammarBlock`) and the parser (`Parse-FleetReviewVerdict`,
`Test-FleetReviewVerdict`). `Test-FleetVoiceContent` consumes the same parser. A self-test
(`Test-FleetReviewGrammar.ps1`) asserts the block's own examples parse — grammar and parser
cannot drift silently.

Terminal block (EOF, nothing after, ASCII only):

```
VERDICT: GO
FINDINGS: none
```

or

```
VERDICT: NO-GO
FINDINGS:
- HIGH | F001 | scripts/Example.ps1:123 | Concise actionable finding
```

Rules: severities CRITICAL|HIGH|MEDIUM|LOW; finding line
`- <severity> | <id> | <path>:<line> | <summary>`; `FINDINGS: none` requires GO; NO-GO needs
>=1 finding; CRITICAL/HIGH force NO-GO; GO carries only MEDIUM/LOW; no aliases.

Charters are built ONLY by `scripts/New-FleetReviewCharter.ps1` — never hand-assembled — so
the grammar block is byte-identical to what the parser enforces.

## 2. Deterministic legacy-GO alias (D3 — replaces any model re-prompt)

A result whose LAST line is exactly `VERDICT: GO` with a body free of severity tokens,
evidence-shaped bullets, negative verdicts, refusal markers, and `FINDINGS:` headers parses as
GO/no-findings with `parse_mode = legacy-go-alias-v1`. Anything ambiguous fails closed and
requires full same-model redispatch. NEVER re-prompt a model to "clarify" a verdict — a second
model call can change semantics and cannot be proven grammar-only.

## 3. Packet lint BEFORE dispatch (D2)

`scripts/Test-FleetReviewPacketReady.ps1 -PacketDir <dir> -ReviewRisk <risk> -RunId <id>` runs
the frozen-packet gate plus: exactly one `review_profile` in locked-plan.md, EXACT canonical
preflight status line (`review-preflight: READY | selected: N | passed: P | cached: C |
failed: 0` — prefix matches are rejected), and RED evidence. Fix a BLOCKED packet with ZERO
voice tokens spent. `Get-FleetReviewPacket.ps1` enforces the same predicates at freeze
(shared helper `FleetReviewPacketReady.Helpers.ps1`); it writes diagnostic
`packet-readiness.json` (never trusted — certification re-derives from frozen bytes).

RED evidence contract: whenever `test-results.json` is present it must state its RED position
explicitly — behavior|hard require `red_denominator >= 1`, `red_observed == red_denominator`,
and `red_controls[]` entries
(`id/command/expected_failure/observed_exit_code(nonzero)/sample/evidence_path/evidence_sha256`)
whose evidence files live INSIDE the packet (reparse-free path walk) and hash-match; mechanical
may claim `0/0/[]` only when no test/gate/validator/oracle changed. RED evidence files become
hashed packet artifacts (`red:<path>`), so post-freeze mutation breaks the manifest, and
certification re-runs the same predicates from frozen bytes before receipt reduction.

## 4. Exact-hash all-or-none carry-forward (D4)

Round N+1 re-dispatches ONLY lanes that raised findings, refused, or failed. A signed
completed GO/**no-findings** receipt carries forward IFF the run_id matches and
`input_packet_sha256` is byte-identical to the current packet hash (a GO carrying MEDIUM/LOW
findings is still open review material and never carries). ANY packet change disables ALL
carry-forward. No lens-scoped partial reuse. The trust math is already enforced:
Assert-FleetReviewIntegrity binds every receipt to the current packet hash, so a stale carried
receipt fails certification regardless of bookkeeping.

Record each round with `scripts/New-FleetReviewRound.ps1` -> `review-round-<n>.json`.
It HMAC-verifies every recorded receipt (new and carried) under the run lease key,
re-hashes the result bytes against the signed `result_sha256`, validates
`carried_forward_from` linkage (`r<N>`, strictly earlier round), and never rewrites an
existing round file (byte-identical replay only). Signed receipts are never modified or copied.

## 5. Round accounting (D5)

A review round COUNTS exactly once when at least one voice produced a signed review_lane
receipt with outcome `completed` or `refused` against a packet hash. NOT rounds: packet lint
failures, packet rebuilds before dispatch, grammar parsing/legacy normalization, pure
transport failures with no completed/refused receipt, and redispatching only missing lanes
against the IDENTICAL packet hash (that completes the same logical round). A completed
response with malformed grammar consumed a voice review: it counts once, and fixing its
format does not create another round. The 3-round cap, perf-rule #3 escalation, and
frozen-diff limits are unchanged.

## 6. Span publication (A1)

Lanes write spans via `Record-FleetLaneSpan.ps1` (dedupe key run_id+lane_id). Runs that
buffered per-run span files publish them with
`scripts/Publish-FleetRunSpans.ps1 -RunId <id> -SpanDir <dir> -ExpectedLanes <ids>` BEFORE
`Assert-FleetLaneSpans.ps1`/certification — never inside lease cleanup (Exit-FleetRunLease
stays cleanup-only; publication failure blocks certification, never lease release). Identical
replay is a no-op; a conflicting duplicate fails. Emits `span-publish-manifest.json`.

## 7. Model-evidence tiers (A2)

`model_evidence` values are an allowlist; requested evidence NEVER becomes observed evidence:

| transport | observed_model | model_evidence |
|---|---|---|
| Grok unified log | exact observed | `observed-provider:grok-unified-log` |
| Claude/Opus modelUsage | exact observed | `observed-envelope:claude-modelUsage` |
| Codex Sol/Terra | `unobserved` | `requested-pinned:codex-cli-config` |
| Pi/GLM | `unobserved` | `requested-pinned:pi-provider-model` |
| Kimi CLI | `unobserved` | `requested-pinned:kimi-cli-config` |

Codex JSONL was probed live 2026-08-11 on pinned 0.146.1: no model field in `--json` events,
so codex stays requested-pinned until a captured fixture proves one. requested-pinned receipts
qualify only through the unobservable-transport carve-out and can never support observed-model
claims or model-performance attribution.

## 8. Codex Desktop label fallback (A3)

Surfaces that cannot render `[MODEL · ROLE] T# — action` (Codex Desktop `task_name`) use the
authoritative fallback grammar `<model><role>_t<n>_<slug>` — lowercase ASCII,
`^[a-z][a-z0-9_]*$`, model + role + `t<n>` mandatory, stable slug (collision gets a
deterministic short-hash suffix). Examples: `gpt56sol_architect_t5_reviewburn`,
`glm52_review_t3_packetlint`. Rich display labels remain preferred wherever supported.
