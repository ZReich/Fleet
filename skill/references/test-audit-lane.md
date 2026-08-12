# TEST-AUDIT lane

A review lane that judges TEST quality, not code quality. It exists because AI models write
many tests that pass whether or not the code is correct (assertion-free, mock-the-subject,
tautological, duplicate) — bloating CI and giving false confidence. Research synthesis and
the number behind this: `~/Documents/docs/fleet/test-quality-research.md` (in one study
>99% of AI tests that should fail on mutated code passed on the original; ~78% coverage vs
~31% mutation score).

## The rule that makes it safe: LLM nominates, deterministic disposes

- The LLM lane is **ADVISORY. It never gates a build or a merge.** It comments; ESLint and
  Stryker decide. `Read-FleetTestAuditVerdict.ps1` exits 0 regardless of verdicts.
- Structural facts (no `expect`, conditional expect, `__mocks__` import) belong to ESLint
  (`@vitest/eslint-plugin`), which is free and has zero false-negatives. Do NOT ask the LLM
  to check those — reserve its context for the semantic calls a linter cannot phrase:
  tautology, mock-of-subject, over-mocking, duplicate-noise, boundary blindness.
- Where a Stryker mutation report is available, the lane's verdict is tagged
  `stryker: killed|survived`; otherwise `LLM-inferred` (`stryker: n/a`). A mutation survivor
  is ground truth; an LLM "would-fail-if-mutated" is a cheap prior, not proof.

## The locked 6-check rubric (per new/changed test / `it` / table-row)

1. would-fail-if-mutated · 2. independent-oracle · 3. tests-subject-not-mock ·
4. real-assertion · 5. deletes-duplicate · 6. boundary. Full wording lives in the prompt
`New-FleetTestAuditCharter.ps1` composes — it and `Read-FleetTestAuditVerdict.ps1` are the
single source of the rubric and the output contract; do not restate the wording elsewhere.

## Two run modes (same two scripts)

### A. Panel lane (per PR) — advisory sixth voice
On a STANDARD/FULL review, when the diff touches `*.test.*` / `*.spec.*` files, dispatch a
`[GROK · TEST-AUDIT]` lane CONCURRENTLY with the existing panel (so it adds ~0 wall-clock).
For each changed test file:
```powershell
$charter = & scripts/New-FleetTestAuditCharter.ps1 -TestFile <t> -ImplFile <impl> `
             [-StrykerReport <stryker.json>] -OutputPath .fleet/ta-<t>.txt -Mode json
powershell -File scripts/Invoke-Grok45.ps1 -PromptFile .fleet/ta-<t>.txt `
   -WorkingDirectory <repo> -Effort high -Review -Mode text > .fleet/ta-<t>-out.md
& scripts/Read-FleetTestAuditVerdict.ps1 -LaneOutputPath .fleet/ta-<t>-out.md -Mode json
```
Quote the `test-audit: N audited, K reject, W warn, P pass, I invalid` line in the run
report beside the panel verdict. REJECT/WARN are surfaced as review comments; they never
flip a GO to NO-GO on their own (a human or a Stryker survivor does that).

### B. Corpus sweep — the "clean out the trash" run
Point it at an entire test tree (e.g. all of Harken). Enumerate every `*.test.*`/`*.spec.*`,
pair each with its implementation, run the lane per file (fan out, disjoint), collect rows
via the parser, and rank: `action=delete`/`merge` first, then `strengthen`, then `keep`.
Output a single ranked worklist a repair session executes. This is a research/analysis run
(free-form markdown per harness law); it produces a plan, it does not delete tests itself.
Every proposed delete must carry the one-line bug the test fails to catch — a delete with no
reason is an INVALID verdict and is dropped by the parser, not actioned.

## Cost discipline (owner constraint: do not add much time)

- Panel lane: single model, changed test files only, concurrent → ~0 added wall-clock.
- Sweep: fan out across files; it is a deliberate, occasional run, not a per-PR gate.
- The lane's precision as a judge-of-tests is UNMEASURED in the literature. Treat its
  verdicts as advisory until calibrated against Stryker survivors on real PRs; prefer a
  cheap deterministic check whenever one exists.
