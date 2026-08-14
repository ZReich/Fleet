# Fleet PLAN mode — completeness-first planning for big builds

Trigger: explicit `fleet plan`, or Sol judges the work big / ambiguous / long-horizon
enough that a missed screen, button, state, or requirement would be expensive to
discover mid-build. NOT for small features — the normal tier ladder's Sol plan covers
those. PLAN mode's goal is completeness, not economy: the plan tokens are cheap
relative to the build they de-risk, so the FULL panel always sits, Fable included.

Harness law applies everywhere here: every planning, merge, attack, and ratify lane
produces free-form markdown. No worker-JSON envelope in any PLAN-mode lane.

Run under a normal Fleet run lease. All artifacts under `.fleet/plan-vN/`.

## Phase P0 — Shared evidence pack (cheap lanes, once)

Planners must NOT each re-read the repo. Build one shared evidence pack first with
the cheap lanes, then hand the same frozen pack to every planner:

- `repo-map.md` — Spark low (or local `rg`/jcodemunch): relevant modules, existing
  components/hooks/services to reuse, boundaries, current data model.
- `research.md` — industry-standard / competitor / library research: Gemini
  (Google-grounded) + Kimi `-ResearchSwarm` with `-RequireVerifiedCitations`
  (`-CitationPolicy Flag`). Grok CLI for real-world/X chatter when relevant.
- `charter.md` — the feature ask verbatim, constraints, non-goals, target users.

Freeze the pack (hash the files). Every planner cites pack paths, not live reads.

## Phase P1 — Diverge (full panel, parallel, blind)

Six independent plans, same charter + pack, no planner sees another's draft:

| seat | transport | notes |
|---|---|---|
| Fable 5 high | Claude Agent tool `model: fable` (from Claude Code) | see Fable-seat rule below |
| Sol xhigh | `codex exec` | architecture/security emphasis |
| Grok 4.6 high | `Invoke-Grok45.ps1` read-only, subagents+web on | implementer's-eye plan: sequencing, effort, gotchas |
| GLM 5.3 Thinking high | `Invoke-PiGlm.ps1` | general + long-reasoning |
| Kimi K3 | `Invoke-KimiK3Proxy.ps1` (proxy analysis lane, bounded <15 min) | cite-verify rules in prompt |
| Gemini 3.1 Pro High | `agy --model "Gemini 3.1 Pro (High)"` (verify exact tier name at first use; fall back to highest available Pro tier) | grounded standards/UX-convention sweep |

Every seat is dispatched with the canonical charter in
[plan-diverge-prompt.md](plan-diverge-prompt.md) — verbatim template + per-seat
addendum. It forces enumeration over summary: user walkthrough click-by-click before
architecture, per-screen/per-control inventory, state sweep, hostile-user pass,
industry baseline from research.md, and a mandatory >=5-item self-audit. The
contribution-ledger incentive ("items others catch that you missed score against
you") is stated in the prompt itself. Do not dispatch a diverge seat with an ad-hoc
prompt.

Fable-seat rule: Fable runs via the Claude Agent tool. When PLAN mode is orchestrated
from Codex and no Claude surface is available, the Fable seat is NOT silently dropped —
either hand orchestration to a Claude Code session or record the missing seat
explicitly in PLAN-FINAL.md. Never claim full-panel coverage without it. Note: Fable
may silently serve a lower model under load; the merge prompt tells Fable to state its
own identity, and gross quality mismatch is treated as a degraded seat.

## Phase P2 — Merge (Fable high)

Fable reads all diverge plans and emits `PLAN-MERGED.md`:

- Union-biased: prefer including a candidate item over dropping it; drop only with a
  one-line reason in the conflict register.
- Stable item ID + provenance tag on every merged item, one item per line:
  `[P-001] [sol,grok] <item text>`. Seats: `sol grok glm kimi gemini fable`; merge-
  originated items tag `[fable]`. IDs never reused or renumbered after merge.
- Mandatory gap-hunt section: "items other seats caught that Fable and Sol both
  missed" — this section existing and being non-trivially populated is the point of
  the whole exercise.
- Conflict register: contradictions between plans + Fable's resolution + rationale.

## Phase P3 — Attack (blind completeness audit)

Freeze PLAN-MERGED.md into a review packet and run the FULL-tier blind panel (one
concurrent wave, cross-family rules from review-protocol.md; Fable and the merge
prompt are excluded from grading their own merge). Charter is gap-hunting, not style:

Coverage matrix the attackers check line-by-line (`coverage-matrix.md`):
screens/routes; every button/control per screen; states (empty, loading, error,
offline, unauthorized); roles/permissions; data lifecycle (create/read/update/
delete/archive/export); validation + error copy; a11y; responsive/mobile; industry
standards vs. research.md; migrations; telemetry/observability; rollback; sequencing
sanity (can Grok build it in the stated waves?).

Every finding = missing item, wrong resolution, or unbuildable sequence, with
severity. Fold CONFIRMED findings back into the plan. Attack additions get NEW IDs
tagged with the finding seat; attack cuts list the cut ID in `attack-cuts.md`
(`[P-014] cut: <reason>`). Ratify vetoes likewise in the risk register
(`[P-021] veto: <reason>`). PLAN-FINAL.md keeps the ID+tag line format.

## Phase P4 — Ratify (Sol xhigh)

Sol signs `PLAN-FINAL.md`: architecture + security sign-off, risk register, and two
handoffs —

- `design-brief.md` → Kimi native design lanes (design-proposal / DesignWorkspace)
  for visuals; Sol retains final design judgment per the standing override.
- `wave-plan.md` → normal Fleet build flow (Sol locked plan, Grok implementation
  waves, Terra gates, tiered adversarial review).

Ratify may VETO items on security/architecture grounds even if merged; vetoes go in
the risk register with rationale. After ratify, PLAN-FINAL.md is the locked input to
the build run — the build's Sol plan derives from it, not from re-planning.

Survivorship accounting rule (live-proven need, plan-v1 2026-07-20): PLAN-FINAL.md
must make every surviving item countable — either restate its `[P-###] [seats]` line,
or carry a blanket-lock line in the exact form
`items P-<a> through P-<b> remain locked` (plus explicit `[P-###] cut:` / `veto:`
lines for the exceptions). Drop lines may carry a short parenthetical qualifier
(`cut (partial):`). Anything not restated, not in a lock range, and not explicitly
dropped is counted as dropped — silent disappearance is a protocol violation.

## Artifacts

`.fleet/plan-vN/`: charter.md, repo-map.md, research.md, PLAN-<model>.md ×6,
PLAN-MERGED.md, coverage-matrix.md, attack findings, attack-cuts.md, PLAN-FINAL.md,
design-brief.md, wave-plan.md, contribution.json. Benchmark rows (v8 schema) may be
recorded for diverge plans via the normal blind-grading machinery — planning is a
judgment lane; grades use `Parse-FleetGrades.ps1`.

## Contribution ledger (deterministic, no model calls)

After ratify, run `scripts/Get-FleetPlanContribution.ps1 -PlanDir .fleet/plan-vN`
-> `contribution.json`. It parses the ID+tag lines and reports per seat:

- `merged` — items carrying the seat's tag in PLAN-MERGED.md
- `survived` — those still present in PLAN-FINAL.md
- `unique_survived` — survived items where the seat is the SOLE tag (caught by
  nobody else — the headline planning-value stat)
- `cut` / `vetoed` — the seat's items removed at attack or ratify

Counted from provenance, not judged — no self-preference bias, zero token cost.
Record per-seat rows in the v8 benchmark ledger (`genre=planning`,
`estimand=optimized_system`) so planning value accumulates across runs alongside
blind-grade data. Multi-tag survivals credit every tagged seat.
