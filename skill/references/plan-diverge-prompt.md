# PLAN-mode diverge prompt template (canonical)

Every P1 diverge seat gets this same charter, verbatim, with `{FEATURE}` /
`{PACK_PATHS}` filled. Free-form markdown output (harness law). The template exists
because models omit functionality when allowed to summarize; forced enumeration and
the walkthrough discipline below are the fix. Do not soften or trim the mandatory
sections when dispatching.

---

You are one of six independent planners for: {FEATURE}

Frozen evidence pack (cite these paths; do not re-derive): {PACK_PATHS}

Your plan will be blind-merged against five other models' plans. Every item you
include that survives to the final plan is credited to you; every item another model
catches that you missed is scored against you. Completeness wins. Do not summarize
where you can enumerate.

MANDATORY METHOD — do these in order, show the work in the output:

1. USER WALKTHROUGH FIRST. Before any architecture, walk every user journey
   click-by-click as prose: first-time user, returning user, and admin/owner (plus
   any persona the charter implies). At each step name the exact screen, every
   control visible on it, and what each control does. If you cannot name the button,
   the plan is missing it.
2. ENUMERATE, don't gesture. "Settings page" is not an item. "Settings page:
   notification toggles (email/push/SMS), timezone select, delete-account flow with
   confirm modal, export-data button" is four items. Every list in your plan follows
   this rule.
3. STATE SWEEP. For every screen: empty state, loading state, error state, offline,
   unauthorized, and the state after the user's FIRST action. What does a brand-new
   account with zero data see?
4. HOSTILE-USER PASS. Walk each journey again as a careless or malicious user:
   double-submits, back-button mid-flow, expired session mid-form, pasted garbage,
   concurrent edits, permission escalation attempts.
5. INDUSTRY BASELINE. Name the 2-3 best products in this category (from research.md)
   and list, feature by feature, what they ship that this plan currently lacks.
   Adopt or explicitly reject each with one line of reasoning.
6. SELF-AUDIT LAST. Re-read your own plan as the end user. List AT LEAST five
   concrete things you nearly left out, and add them. "Nothing missing" is a
   failing answer — the other five planners will find your gaps if you don't.

REQUIRED OUTPUT SECTIONS (all of them, in order): feature inventory (per-screen,
per-control), state coverage, data model + lifecycle, API surface, security/auth
touchpoints, a11y, industry-standard comparison, edge cases, migration/rollout,
telemetry, risks, build sequencing, self-audit findings.

State the model identity you are actually running as at the top of the output.

---

Per-seat addendum (appended after the template):

- Grok: "Your known failure mode is shipping the skeleton and omitting the
  functionality and UX affordances a real user expects — undo, confirmations, bulk
  actions, keyboard access, sensible defaults, helpful empty states. Spend your
  extra effort on sections 1-3 and 6. An architecture-complete but
  experience-incomplete plan scores poorly here."
- Sol: emphasis on security/auth touchpoints, API surface, architecture seams.
- Kimi: cite-verify rules (every external claim cites a fetched URL from
  research.md or your own fetches; no unverified citations).
- Gemini: ground the industry-baseline section with search; quote resolutions, not
  headlines.
- GLM / Fable: no addendum; full template as-is.
