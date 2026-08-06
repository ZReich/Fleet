# Fleet Mode & Review-Tier Selection

Sol chooses the tier once, inside the planning call, after reading the evidence
brief. Return `selected_tier`, matched triggers, one-sentence rationale, and
escalation conditions. The user may override. Uncertainty selects the higher tier.

Four tiers replace the old binary light/full. The tier sets BOTH the build path and
the review panel size. `review_risk` (`mechanical|behavior|hard`, from Sol's locked
plan) further sizes the voice count within a tier — it no longer selects only
timeouts.

## Decision rule (first match wins)

1. **MICRO** — ALL of: `git diff --numstat` shows <=2 touched files AND <=15 changed
   lines; change is a strict no-behavior class (comment, whitespace, pure rename,
   type-only annotation, docs only); no path under auth/authz/payment/secret/privacy/
   regulated/migration/infra; no new dependency; Fallow returns 0 new findings. A
   mechanical pre-check evaluates this and BYPASSES the Sol planning call entirely; any
   doubt escalates to LIGHT. A constant/config-value edit or a dependency-version bump
   is NOT MICRO by default (it can move a production knob — retry, timeout, rate-limit,
   feature flag, connection pool): route it to LIGHT, which has a real user-path proof,
   unless it is provably inert (e.g. a doc example or a test-only fixture value).
2. **LIGHT** — mechanical, reversible, one bounded wave; product/UX/API/architecture/
   security decisions already locked; known blast radius following an existing helper;
   no auth/secret/privacy/payment/financial/regulated path; no migration, destructive
   op, infra/deploy change, or cross-repo contract; no new dependency; focused checks
   known (user-facing work also has a real user-path proof). Above MICRO thresholds.
3. **STANDARD** — behavior-changing, multi-file, or uncertain-but-reversible blast
   radius that is NOT security/migration/cross-repo/destructive/unresolved-design.
4. **FULL** — any of: auth, authz, secrets, privacy, payments, financial calculation,
   regulated data, destructive/irreversible ops, schema migration/backfill, deploy/
   infra, cross-repo or public API contract, unresolved design judgment, unknown blast
   radius, explicit user request, or any unresolved HIGH/BLOCK escalated from a lower
   tier. `review_risk=hard` forces FULL.
**sensitive-review trigger** (orthogonal to the ladder; applies when matched, even if
FULL already won via security-surface): user labels the work security-sensitive /
vuln-audit / exploit-path review, Sol judges open-weights security voices are
required, **or** the selected FULL path is a security surface
(auth/authz/secret/privacy/payment/crypto). Forces `selected_tier=FULL` and writes
`review_profile: security-sensitive` as a single machine-readable line in the frozen
`locked-plan.md`. Otherwise `review_profile: general`. Security identity + hosted-
refusal failover: [review-integrity.md](review-integrity.md).
Tier-selection output must include a one-line `k3_considered: yes|no — <why>` record
(design-proposal, DesignWorkspace, research-swarm, long-horizon, PLAN diverge, or
FULL data seat). Skipping Kimi is fine; skipping it silently is not.
Locked plan always carries exactly one of:
`review_profile: general` | `review_profile: security-sensitive`.

0. **PLAN** (pre-build, orthogonal to the build tiers) — explicit `fleet plan`, or Sol
   judges the project big/ambiguous/long-horizon enough that a missed screen, control,
   state, or requirement would be expensive mid-build. Runs plan-protocol.md (shared
   evidence pack, six-seat blind diverge incl. Fable + Gemini 3.1 Pro High, Fable
   merge, FULL blind attack vs. coverage matrix, Sol xhigh ratify). Output PLAN-FINAL
   becomes the locked input to the build run, which then tiers normally.

## Staffing (fastest models on the small tiers; `review_risk` scales the panel)

| Tier | Build path | Review panel | Target review wall |
| --- | --- | --- | --- |
| MICRO | Direct edit (root or Spark low); no Sol plan | Zero model voices by default: deterministic gates only (typecheck + focused test + Fallow + manager read). If user-facing, exactly ONE fast blind pass: Gemini 3.5 Flash Low (visual) or Spark low (text). No Grok self-review, no panel | <60s |
| LIGHT | Compact Sol plan -> Grok + self-review -> Terra gates | `review_risk` mechanical -> 2 voices (Sol + fresh Terra). `behavior` -> 3 voices: Sol + Terra + one cross-family voice (GLM frozen-packet `-NoTools -Thinking low`, ~17s proven) to break same-family blind spots | <5 min |
| STANDARD | Full light flow | Sol + fresh Terra + one specialist third voice chosen by change type: GLM (edge/error contracts), Grok review (literal scope/acceptance), Gemini Flash (visual evidence), or Opus (coupling/architecture) -- one, not all | <10 min |
| FULL | Sol wave graph -> waves -> gates | Five blind voices, with Grok FANNED to 3 diverse-lens lanes (Spec/Correctness/Regression) that dedupe to ONE counted Grok voice — coverage x3, arbitration weight x1 (review-protocol.md charter 5). Seven wrapper lanes total (Opus, GLM, Grok×3 + Sol/Terra on Codex), rolling dispatch, then Sol arbitration under the cross-family scoring rule. `review_risk=hard` raises GLM to `-Thinking high` under the existing 900s budget. No fan-out when Grok is the implementer | max(single slowest voice) |

## Escalation

Risk promotes; size never demotes risk. Any verified finding at a lower tier
re-freezes artifacts and promotes one tier. MICRO->LIGHT on any doubt is mandatory
and cheap. Recompute the tier once at review dispatch (log it); never downgrade a
running higher tier. Every run logs the chosen tier, matched triggers, false-
escalation and missed-risk counters, so a bug shipped at MICRO/LIGHT tightens the
thresholds. Any full-mode trigger discovered mid-run escalates immediately.

Legacy note: `light` == LIGHT and `full` == FULL for back-compat; new work uses the
four-tier names. `selected_mode` remains accepted as an alias for `selected_tier`
where older callers emit it.
