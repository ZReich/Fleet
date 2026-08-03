---
name: fleet
description: Claude Code adapter for the canonical Codex Fleet workflow with Sol planning/final verification, Terra supervision, Grok implementation, Spark synthesis, Gemini evidence, Kimi K3 candidate lanes, and risk-scaled review.
---

# Fleet Adapter for Claude Code

Codex Fleet is the single source of truth. At invocation, read completely:

1. `$env:USERPROFILE/.codex/skills/fleet/SKILL.md`
2. `$env:USERPROFILE/.codex/skills/fleet/LESSONS.md`

Follow the Codex contract unchanged unless this adapter explicitly maps a Claude
surface. Never copy the full contract back here; duplicate workflow text caused
Fable/Opus/four-voice drift.

## Claude Surface Mapping

- Sol writes the locked plan and returns for blind final verification/arbitration.
- Terra supervises execution, liveness, integration, gates, and repair routing.
- Claude root relays status and invokes lanes; it does not replace Sol or Terra.
- Opus is review-only through the canonical wrapper. Never make Opus supervisor.
- Grok 4.5 owns non-design implementation. Never give Grok design judgment (but a
  private/internal signature within the locked contract is Grok's to choose). Grok
  implementation lanes in an isolated worktree get subagents + web default-on.
- HARNESS LAW: review/analysis/research/critique lanes always produce free-form
  markdown; the worker-JSON envelope is implementation-only. A low score in a mismatched
  harness is a harness finding, not a model finding (Grok 75.5->94 proved it).
- Spark handles repo/context/log synthesis, not implementation or final gates.
- Handoff/resume: validated `New-FleetHandoffReceipt.ps1` + named delta artifacts only
  (no full history). First-result/partial exit frees lane; timeout churn = fresh session,
  not extra gates. Local parse metrics only — never claim model latency.
- Kimi default: visually-important UI, FULL first-party security (copy-sandbox only),
  long-horizon packets, broad read-only research. Sol keeps security/final judgment;
  static deny / no host-repo writes / no final authority.
- Security FULL: TWO open-weights voices by default — `[GLM 5.2 · SECURITY]` LIVE
  read-only (`Invoke-PiGlm.ps1 -ReadOnly -Thinking high`); `[KIMI K3 · SECURITY]`
  COPY-SANDBOX (`Invoke-KimiK3.ps1 -RepoSandbox <repo>`; embed only if no git). Concurrent;
  findings additive once verified; Sol final; first-party only. See references/kimi-k3.md.
- Every Agent-tool spawn (Opus supervisor, review voices, any Claude subagent) ends
  its prompt with the terse-output trailer: "OUTPUT STYLE (mandatory): terse — drop
  articles, filler, pleasantries, hedging; fragments OK; technical substance exact;
  code, diffs, JSON, file:line references verbatim and complete. Compress prose,
  never evidence." Subagents do not inherit the chat caveman hook — the prompt is
  the only transport.
- Use model-first task names: `[MODEL · ROLE] T# — action`. External lanes run as
  background Bash dispatches and the Bash `description` IS the only lane label the owner
  sees, so every dispatch description MUST start with the `[MODEL · ROLE]` prefix (e.g.
  `[GROK 4.5 · IMPL] T3 — build sanitizer`). Friendly prose ("Dispatch Sol plan") is a
  contract violation (caught live 07-22). Preserve the prefix through retries.
- Fleet worktrees follow the Codex contract's location rule
  (`%USERPROFILE%\.codex\worktrees\<repo-slug>\...` or session scratchpad — never
  Documents siblings) and are removed at run end.
- NO SUBSTITUTE LANES: "fleet review" means the canonical external lanes — frozen
  packet + wrapper receipts (Invoke-Grok45/Opus48/PiGlm result JSON). Claude
  subagents, Greptile, or ad-hoc review may ADD to but never replace them; claiming
  fleet review without packet + receipts is a contract violation (drift caught
  07-21). If a tier needs no canonical lane (MICRO), say so instead of substituting.
- PR-MERGE GATE (separate from fleet review): once a PR is open — TWO rounds of Codex
  review (fix + push between) FIRST, THEN Greptile to 5/5 + CI green, then merge, no
  ask. Codex is free, Greptile paid: exhaust Codex first. Fleet's packet+receipts
  review is a build-time gate and does NOT replace this merge-time loop. Full
  sequence: memory feedback_babysit_prs / automerge-greptile-5of5.
- Review scales by tier (MICRO/LIGHT/STANDARD/FULL, see references/mode-selection.md);
  FULL runs all five blind voices in ONE concurrent wave via detached wrapper jobs
  (rolling dispatch fallback), not two batches. Cross-family judging is mandatory on
  every scored comparison: no self-grade, >=1 cross-family grader, fabrication-flagged
  models (Gemini, Kimi) excluded from grading, anonymize + position-swap.
- `SHADOW_COVERED:<run>/<task>` bans only nested shadow COMPARISONS; a worker's own
  bounded depth-1 fan-out is allowed with child count/budget recorded.
- CONCURRENCY: the Codex "max three active child lanes" rule is a CODEX DESKTOP slot
  limit, NOT a Claude constraint — Claude fans out as wide as the work allows. Keep the
  non-slot rules: disjoint write scopes/worktrees, one supervisor per tree, serialized
  full suites, one benchmark pair at a time.
- MANDATORY FAN-OUT (owner 07-25, emphatic): independent lanes launch CONCURRENTLY in
  ONE message — never one-at-a-time. Serialize only when B needs A's output. Dispatch,
  THEN report. Re-check every phase — serial drift is the failure mode ("the entire
  fleet skill is to fan out agents").
- FILE DELIVERABLES USE A WORKSPACE LANE (07-26 failure): if the deliverable is FILES,
  dispatch `Invoke-Opus48.ps1 -Model claude-opus-5 -DesignOutputDir <dir>` (scoped
  Write/Read/Edit, cwd = dir, result carries `design_files[]`; zero files = error) or
  Kimi `-DesignWorkspace -DesignOutputDir`. `claude -p` returns only the FINAL message,
  so inlined 30-40KB files are silently decapitated. BANNED charter clause: "include
  complete file contents in your response". Truncation = local transport fault, re-run
  on the workspace lane — never stitch "continued from…" fragments (~40 min burned).
- EVIDENCE INTEGRITY (07-26): a passing gate states its DENOMINATOR — what it
  exercised (`tests: 274/274`, `corpus: 8/8 docs`) — quoted beside Fallow/filesize.
  Missing or zero = the gate did not run; `Get-FleetReviewPacket.ps1` blocks a
  `passed` entry lacking a nonzero `sample`. New gates need a seen-it-fail negative
  control; never derive an expectation from the code under test or let a mock stand in
  for the semantics; act on detection; one run of a nondeterministic pipeline is not a
  metric (mean+range >=3); compiling is not rendering; existence-of-record is not a pass.
- MAIN LOOP ORCHESTRATES, NEVER IMPLEMENTS fleet work (07-25: 156 inline Edit/Writes
  on bank software → mirror-image defects). Edits = .fleet charters/gate scripts only.
- OPUS 5 REPLACES 4.8 as the panel Opus seat (owner 07-26): `-Model claude-opus-5`
  (ultra trailer auto); budget ~2-3x 4.8 wall time; verify findings before charging
  repairs (pair #1: 2/5 unique FPs). 4.8 = outage fallback (`voice_substituted`) +
  explicit-benchmark partner only. Row per dispatch to `BENCH-opus5-pairs.jsonl`.
  Design: Opus 5 > Kimi per owner; Opus5-vs-K3 design-off on explicit request only,
  blind cross-family judged, Sol locks. Never main-loop implementer.
- `fleet plan` (big projects only): follow Codex Fleet's references/plan-protocol.md.
  Claude Code is the preferred orchestration surface because the Fable seat runs via
  the Agent tool (`model: fable` — diverge high, merge high). Six-seat blind diverge,
  Fable merge, FULL blind attack, Sol xhigh ratify. All PLAN lanes are free-form
  markdown (harness law).

## Canonical External Lanes

Use these shared wrappers; do not call raw Grok, Opus, or Pi commands:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/fleet/scripts/Invoke-Grok45.ps1" -PromptFile .fleet/T1-grok-prompt.txt -WorkingDirectory <isolated-worktree> -Effort high -BashCapability Auto -IsolatedWorktree -EnableSubagents -EnableWebSearch -LeanSystemPrompt -Mode json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/fleet/scripts/Invoke-Grok45.ps1" -PromptFile .fleet/T1-grok-review.txt -WorkingDirectory <repo> -Effort high -Review -TimeoutSeconds 900 -Mode text
$packetDir = ".fleet/review-vN"
$reviewRisk = "behavior" # Sol's locked plan selects: mechanical | behavior | hard
$packet = & "$HOME/.codex/skills/fleet/scripts/Get-FleetReviewPacket.ps1" -PacketDir $packetDir -ReviewRisk $reviewRisk -OutputPath "$packetDir/packet-manifest.json" | ConvertFrom-Json
$reviewArtifacts = @($packet.artifact_paths) # pass as ($reviewArtifacts -join ',') to any `powershell -File` wrapper; a raw array splats positionally and corrupts later params
$opusBudget = & "$HOME/.codex/skills/fleet/scripts/Get-FleetReviewBudget.ps1" -PromptFile .fleet/T1-opus-review.txt -ArtifactFile $reviewArtifacts -PacketManifest "$packetDir/packet-manifest.json" -ReviewRisk $reviewRisk -OpusModel claude-opus-5 -OutputPath .fleet/T1-opus-review-budget.json | ConvertFrom-Json
$glmBudget = & "$HOME/.codex/skills/fleet/scripts/Get-FleetReviewBudget.ps1" -PromptFile .fleet/T1-glm-review.txt -ArtifactFile $reviewArtifacts -PacketManifest "$packetDir/packet-manifest.json" -ReviewRisk $reviewRisk -OutputPath .fleet/T1-glm-review-budget.json | ConvertFrom-Json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/fleet/scripts/Invoke-Opus48.ps1" -PromptFile .fleet/T1-opus-review.txt -ArtifactFile ($reviewArtifacts -join ',') -PacketManifest "$packetDir/packet-manifest.json" -Effort high -Model claude-opus-5 -TimeoutSeconds $opusBudget.opus_timeout_seconds -Mode json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/fleet/scripts/Invoke-PiGlm.ps1" -PromptFile .fleet/T1-glm-prompt.txt -Thinking high
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/fleet/scripts/Invoke-PiGlm.ps1" -PromptFile .fleet/T1-glm-review.txt -ArtifactFile ($reviewArtifacts -join ',') -PacketManifest "$packetDir/packet-manifest.json" -Thinking low -NoTools -TimeoutSeconds $glmBudget.glm_timeout_seconds -Mode json
```

For each full/review Opus or GLM launch, run Codex Fleet's canonical
`scripts/Get-FleetReviewPacket.ps1`, then `scripts/Get-FleetReviewBudget.ps1`; never
hand-select a timeout. The packet preflight blocks dispatch unless nonempty `base.sha`,
`final.diff`, `touched-files.txt`, `locked-plan.md`, `acceptance-evidence.md`, and
`gate-evidence.md` are frozen and hashed. The budget selector and no-tool Opus/GLM
wrappers re-attest that manifest against their ordered artifact list and canonical
UTF-8 bytes before launch. Sol's locked plan must set `review_risk` to `mechanical`,
`behavior`, or `hard`; selector output records exact serialized transport bytes and
hash. One correctly sized provider attempt only; a timeout is `no_contest`, not a retry.

Grok wrapper uses authenticated user Grok home because disposable profiles trigger
an upstream session-registry 404. It owns auth expiry, strict structured audit,
working directory, exact model/version proof, timeout/tree cleanup, compatibility
isolation, and version-cached terminal-capability telemetry. Auto probe is
isolated-worktree only. Implementation may use `BashCapability Auto` only after an
exact, version-keyed terminal proof succeeds in an isolated worktree; otherwise the
wrapper keeps terminal execution disabled. Read-only Grok lanes deny Bash.
Its lean implementation system prompt embeds Ponytail's compact rule directly:
smallest correct change, delete/reuse before adding, use installed dependencies and
existing utilities, and do not add abstractions/files/dependencies outside locked
scope. Fleet intentionally bypasses Ponytail hooks for this path to avoid duplicate
hook/plugin context and preserve deterministic structured output.

Opus wrapper negotiates CLI-advertised isolation, stdin+EOF, no tools/persistence, hard timeout,
verifies `modelUsage` is the requested Opus (`claude-opus-5`; 4.8 only fallback). Pi wrapper uses
print-stdin + canonical GLM safeguards. Sol wrapper (`scripts/Invoke-Sol.ps1`) is canonical for the
Sol lane (never raw `codex exec`): forces `-Effort high`, resolves the off-PATH launcher, kills
0-turn hangs, reports `model_cache_skew`; codex is now a tracked CLI-audit runtime.

## Kimi K3

Use only the shared Invoke-KimiK3.ps1 wrapper and only after Sol selects a K3
candidate lane. K3 receives frozen artifacts in an ephemeral, static-deny runtime;
it has no repository write charter. The wrapper uses Windows extended-path cleanup
for Kimi session trees; cleanup failure invalidates the run. Use copied images only
for visual evidence and accept that evidence only when the wrapper proves a
copied-image ReadMediaFile call.
Never launch raw Kimi, update, server, web, ACP, auto mode, or yolo mode from this
adapter. K3 is not a standard final-review voice and never overrides Sol. Exception
(2026-07-22): FULL reviews add the K3 PROXY data seat via Invoke-KimiK3Proxy.ps1 —
sixth voice, NON-GATING, qualification evidence only, bounded under the 15-min token
TTL; outage = no_contest, never blocks the panel (review-protocol.md charter 6).
Tier selection records `k3_considered: yes|no — <why>` per mode-selection.md.

K3 has a second, guarded lane for research: `[KIMI K3 · RESEARCH]` may fan out its
own agent swarm plus web search/fetch for broad read-only research and red-team
sweeps, but still gets no repository, shell, or write charter — same ephemeral-home,
copied-credential runtime as the artifact lane. Invoke it through Codex Fleet's
`Invoke-KimiK3.ps1 -ResearchSwarm`; live transport and model-layer refusal are
confirmed (2026-07-18), but child-attempt config enforcement is not force-testable,
so prefer the artifact-only lane for the most sensitive work. Use it only when Sol
judges the breadth genuinely needs fan-out; single lookups stay on `rg`/Spark/Grok.
The exact allow/deny split and live-probe caveat live in Codex Fleet's
references/kimi-k3.md — read it, do not restate the policy here.

## Gemini / Antigravity

Gemini 3.6 Flash Low is the default (bumped from 3.5, 2026-07-23; 3.5 tiers remain fallbacks) single batched parallel evidence lane for
visually important UI work, large screenshot sets, giant-context reads, and
Google-grounded research. Sol retains every design verdict.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/fleet/scripts/Invoke-Gemini35.ps1" -CaptureDir <capture-dir> -Prompt "<absolute screenshot paths + batched prompt>" -Mode json
```

Image calls require `--add-dir` plus absolute paths. Never use bare `@filename`.
Skip Gemini for ordinary functional checks. Run Grok image comparison only for an
explicit benchmark; Gemini Low is faster on current same-image evidence.

## Preflight and Completion

Read `$env:USERPROFILE/.codex/fleet/cli-update-status.json` before dispatch.
The daily audit checks Grok, Claude, Pi, Antigravity, and Kimi Code; refresh it read-only when
missing, invalid, schema-incompatible, future-timestamped, or older than 24 hours.
Before dispatch, acquire a shared Fleet run lease with the canonical
`Enter-FleetRunLease.ps1`, renew it at every phase transition and at least hourly,
and release it in final cleanup. Never replace a CLI
executable in place or enable background updates. Validate side-by-side candidates;
promotion shares the lease mutex and can move the pin only between Fleet runs. Record Claude npm `stable`, `latest`,
and `next` separately. Default target is non-prerelease `latest` after proof; `stable`
is lower-risk comparison and `next` is never auto-recommended. Claude execution uses
only the approved path/version/SHA and sets `DISABLE_UPDATES=1`; side-by-side
promotion requires offline plus live proof before the pointer moves atomically.
Grok background auto-update remains disabled so promotion is atomic and test-gated.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$HOME/.codex/skills/fleet/scripts/Test-FleetExternalLanes.ps1" -RequireOpus -RequireGlm
```

Run Pi's test separately when GLM is enabled. Local wrapper, PATH, or compatibility
failures must be repaired before full-review dispatch; only a provider outage after a
verified launch is `no_contest`. Never claim five-voice coverage with a missing lane.
No commits or pushes unless requested. Append new active guidance to Codex Fleet's
LESSONS file. Claude's old LESSONS file was merged into it on 2026-07-31;
`adapters/claude/LESSONS.md` is now only a pointer.
