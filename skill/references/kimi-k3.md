# Kimi K3 candidate lane

## Decision

Kimi K3 is enabled as a measured Fleet candidate for long-context planning,
design critique, visual/frontend proposals, and independent red-team analysis.
It is not yet the planner, orchestrator, architecture/API/security owner, or
final shipping authority. Sol still locks those decisions and gives the final
verdict. K3 does not join Fleet's standard five-voice review barrier by default:
it is slow enough that it must pay for its own latency.

Use one [KIMI K3 · DESIGN] or [KIMI K3 · REVIEW] lane only when Sol
identifies a material visual, long-context, or independent-view benefit. Feed it
a frozen packet, not a repository. For screenshots, give the wrapper copied image
files. Never give it an unlocked write charter.

## Evidence snapshot - 2026-07-17

Moonshot reports K3 as a 2.8T MoE model with 1M context and native vision. Its
own release post says K3 is competitive but overall trails Fable 5 and GPT-5.6
Sol. The vendor table uses mixed Kimi Code, Claude Code, and Codex harnesses, so
these are capability signals, not clean model-only head-to-heads.

| Vendor-reported benchmark | K3 | Sol | Fable 5 |
| --- | ---: | ---: | ---: |
| DeepSWE | 67.5 | 73.0 | 70.0 |
| FrontierSWE | 81.2 | 71.3 | 86.6 |
| TerminalBench 2.1 | 88.3 | 88.8 | 84.6 |
| ProgramBench | 77.8 | 77.6 | 76.8 |
| SWE Marathon | 42.0 | 39.0 | 35.0 |
| GDPval | 1668 | 1748 | 1760 |
| AA-Briefcase | 1548 | 1495 | - |
| JobBench | 52.9 | 46.5 | - |
| SpreadsheetBench | 34.8 | 32.4 | - |
| BrowseComp | 91.2 | 90.4 | 88.0 |
| CharXiv tools | 91.3 | 89.1 | - |
| Zerobench tools pass@5 | 41.0 | 35.0 | - |

Independent Artificial Analysis currently places K3 at intelligence 57, below
Sol max (59) and Fable 5 (60), while reporting strong agentic/knowledge-work
results: GDPval 1668, AA-Briefcase roughly 1547, and AutomationBench 53%.
It reports about 62 output tokens/sec, near USD 0.94/task versus Sol's USD
1.04/task, and elevated output volume. Treat those figures as directional because
provider capacity and caching affect them.

Do **not** claim K3 hallucinates less than Sol. No credible direct comparison was
found. Artificial Analysis reports K3's AA-Omniscience hallucination rate at 51%,
versus 39% for K2.6, even as K3's accuracy improved. Fleet therefore requires
frozen evidence and explicit uncertainty for all K3 research or plan claims.

Sources: [Moonshot K3 launch and benchmarks](https://www.kimi.com/blog/kimi-k3),
[Artificial Analysis release analysis](https://artificialanalysis.ai/articles/kimi-k3-achieves-3-in-the-artificial-analysis-intelligence-index-comparable-to-opus-4-8-and-gpt-5-5/),
[Artificial Analysis model profile](https://artificialanalysis.ai/models/kimi-k3),
and [Kimi Code CLI reference](https://moonshotai.github.io/kimi-code/en/reference/kimi-command.html).

## Runtime contract

Kimi prompt mode is noninteractive auto permission mode and cannot be combined
with plan mode; plan mode is not a security boundary. The canonical
`Invoke-KimiK3.ps1` wrapper compensates by:

- creating a disposable Kimi home/workspace and treating cleanup failure as a failed run;
  on Windows it uses extended-length paths because Kimi visual sessions can exceed
  the legacy recursive-delete limit;
- copying OAuth credentials only into that disposable home, never emitting or retaining them;
- prepending static deny rules for repository reads, writes, edits, shell, subagents,
  web/fetch, cron, tool discovery, and MCP-like expansion;
- embedding frozen text artifacts directly in the prompt;
- allowing only `ReadMediaFile` for an exact whitelist of copied screenshot/image files;
- disabling telemetry, auto-update checks, and background task persistence;
- rejecting malformed JSONL, any disallowed tool call, empty replies, timeout,
  cleanup failure, or required-but-invalid JSON.

Do not invoke raw Kimi, Kimi upgrade, Kimi server, Kimi web, ACP, auto mode, or
yolo mode from Fleet. Kimi upgrade is interactive and can install an update.
The K3 wrapper starts one new session per task; never resume its session ID.

    & "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-KimiK3.ps1" -PromptFile .fleet/T1-k3-design-brief.txt -ArtifactFile .fleet/locked-plan.md,.fleet/final.diff -ImageFile C:\absolute\capture.png -TimeoutSeconds 2400 -Mode json

If `ImageFile` is used, accept the visual lane only when `tool_evidence` shows
`ReadMediaFile` with `copied_image_path=true`. If a caller asks for JSON, use
`RequireJsonResponse` and validate the resulting JSON against that task's schema;
K3 returned invalid JSON in a trivial live probe.

After an interrupted K3 run, clear only stale Fleet-owned temporary roots with:

    & "$env:USERPROFILE\.codex\skills\fleet\scripts\Clear-StaleKimiK3Runtime.ps1" -MinAgeMinutes 15

## Research swarm lane (separate, guarded)

Status: **implemented, offline-proven, live transport + model-refusal confirmed
2026-07-18.** `Invoke-KimiK3.ps1 -ResearchSwarm` passes `Test-Invoke-KimiK3.ps1`
(guarded-config allow set, denied-tool rejection under the lane, no web leak into
the default artifact lane). Live 0.27.0 probes: web research ran a real `WebSearch`
with a cited answer and `lane=research-swarm`; a direct shell+host-read request and
a delegate-to-sub-agent shell request were both refused at the orchestrator with
`tool_call_count=0` (K3: "routing a prohibited action through a sub-agent doesn't
launder it").

Known gap: the config-deny layer for a **child that actually attempts** a denied
tool is not force-testable from outside — K3 refuses to attempt the violation, so
we cannot drive a child into a blocked `Bash`/`Read` to watch the engine reject it.
Model-layer refusal is strong and the wrapper fails closed on any surfaced denied
call, but for the most sensitive work still prefer the artifact-only lane, which has
no network or swarm at all.

K3 can fan out its own sub-agent swarm for broad research and red-team synthesis;
its 1M context plus native agent-swarm is the reason to pick it over a single
Spark/Grok pass. That ability is worth a lane, but it is a **different security
profile** from the artifact-only lane and never replaces it. Keep both:

- artifact-only lane: no network, no swarm, frozen evidence, design/plan critique.
- research swarm lane: network + swarm ON for read-only research, no repo, no writes.

## Security-scan lane (`[KIMI K3 · SECURITY]`, owner directive 2026-07-22)

A charter genre of the ARTIFACT-ONLY lane, not a new runtime: frozen packet
(diff + touched sources embedded), no network, no swarm, no repo, no shell.
Rationale: K3 is open-weights and empirically pursues exploit-path construction
(injection chains, deserialization gadgets, authz bypass sequencing, secret-handling
flaws) more bluntly than hosted frontier models, which tend to soften or generalize
on offensive detail even in defensive audits. That bluntness is signal we want when
auditing OUR OWN code.

Repo visibility differs between the two voices BY DESIGN — this is the crux, because a
diff-only packet is too thin for a real vuln hunt (cross-file taint→sink flow lives
outside any one diff):

- `[GLM 5.2 · SECURITY]` runs LIVE read-only against the real checkout via
  `Invoke-PiGlm.ps1 -ReadOnly -Thinking high` (Pi grants `read,grep,find,ls`;
  edit/bash/approve denied). GLM crawls the whole tree itself, greps for sinks, and
  chases data flow across files on demand. No embed limit. This is the deep-dive lane.
- `[KIMI K3 · SECURITY]` stays BOXED (ephemeral home, copied creds, auto-approving
  prompt mode = we do NOT give it live filesystem read, which could wander outside the
  repo and pair with a network lane to exfiltrate). It goes repo-wide via the
  REPO COPY-SANDBOX (default since 2026-07-22, owner directive): `Invoke-KimiK3.ps1
  -RepoSandbox <repo> [-RepoSandboxRef <committish>]` materializes `git archive` into
  the ephemeral home — tracked files only, structurally no `.git`, no untracked
  secrets, no junctions (verified fail-closed), frozen at the recorded sha. K3 gets
  scoped Read/Grep/Glob over the copy only; shell/web/write/subagents stay denied.
  Containment does not depend on Kimi's permission engine: worst case it reads its
  own sandbox. This is the panel-sanctioned "OS-level copy-sandbox" from the
  2026-07-22 DECIDED lesson; live repo access remains banned. Fallback when no git
  repo is available (loose artifact sets): the LONG-HORIZON `rg`-assembled corpus
  EMBED (1M context) — never a diff-only packet either way.

Both dispatch concurrently with each other and the panel, so two open-weights security
voices add no wall-clock over one. GLM's lane reuses the existing `-ReadOnly` repo
transport; K3's reuses `-ArtifactFile` — no new wrapper for either. Same
additive-findings and Sol-final-verdict rules apply to both; neither grades other
models.

Rules:
- Both `[KIMI K3 · SECURITY]` and `[GLM 5.2 · SECURITY]` dispatch BY DEFAULT alongside
  the review panel whenever a security trigger selects FULL tier; optional on explicit
  request at lower tiers.
- K3's security lane MUST see the whole repo: repo copy-sandbox by default, LONG-HORIZON
  corpus embed as fallback — never a diff-only packet; a change-scoped packet cannot
  support a repo-wide vuln hunt.
- Charter must state the target is first-party code under audit (defensive), require
  concrete evidence (file:line + input construction) per finding, and CVSS-style
  severity. Speculative findings without an evidence path are labeled hypotheses.
- Findings are ADDITIVE: any verified security finding counts regardless of which
  voice found it. K3's findings are verified against source by the arbiter (Sol) or
  deterministically; K3 never grades other models and never owns the final security
  verdict.
- Never point this lane at third-party systems or targets we do not own/operate.

Runtime carries over unchanged: ephemeral home, credentials copied for the child
lifetime only, extended-path cleanup, cleanup failure = failed run, telemetry and
auto-update disabled, one fresh session per task, never resume a session ID. The
only change is the permission policy.

Research-swarm permission policy (differs from the static-deny artifact list):

- ALLOW: `AgentSwarm`, `Agent`, and the task-management tools K3 needs to drive
  its own children (`TaskList`, `TaskOutput`, `TaskStop`); `WebSearch`, `FetchURL`
  for the research itself; `ReadMediaFile` for copied images only.
- STILL DENY: `Write`, `Edit`, `Bash`/shell, host-repo `Read`/`Grep`/`Glob`,
  `Skill`, `EnterPlanMode`/`ExitPlanMode`, `CronCreate`/`CronList`/`CronDelete`,
  MCP/`mcp__*`, and tool discovery. K3 gets no repository and no write charter; it
  researches the open web and returns a proposal.

Because network is now on, the "no external facts" guarantee is replaced by a
citation requirement, not dropped silently. Artificial Analysis reports K3's
AA-Omniscience hallucination rate at 51%, so every research claim must carry a
source and explicit uncertainty, and Sol verifies load-bearing claims before any
decision rests on them. K3 remains a candidate: it never owns architecture, API,
security, product, or final judgment.

Selection and cost (Ponytail): use the swarm lane only when Sol judges the breadth
genuinely needs fan-out — a wide literature/red-team sweep across many sources. A
single lookup or one-angle question stays on `rg`/JCodeMunch, Spark, or Grok X
research; do not spin a swarm to save one search. K3's internal children live
inside its own runtime and count as one Fleet lane against the root-plus-three cap.

Label the lane `[KIMI K3 · RESEARCH]`. Invocation:

    & "$env:USERPROFILE\.codex\skills\fleet\scripts\Invoke-KimiK3.ps1" -ResearchSwarm -PromptFile .fleet/T1-k3-research-brief.txt -TimeoutSeconds 2400 -Mode json

The wrapper emits `tool_evidence` for every call, allows only the research set
(`AgentSwarm`, `Agent`, `TaskList`/`TaskOutput`/`TaskStop`, `WebSearch`,
`FetchURL`, plus copied-image `ReadMediaFile`), rejects every other tool exactly as
the artifact lane does, and fails closed on cleanup failure. Result carries
`lane = research-swarm`. The allow set lives once in
`$script:ResearchSwarmAllowTools` so the config writer and the runtime validator
cannot drift.

## Promotion experiment

Keep first pass and post-review separate. Use identical frozen briefs, artifacts,
screenshots, time budgets, and blind grading. Run at least 30 visual/frontend
pairs and 30 planning/architecture pairs against Sol before changing ownership.

Track: spec/constraint coverage, invented-repo-fact rate, critical miss rate,
accessibility and browser acceptance, repair burden, wall time, output tokens,
429/retry rate, wrapper completion rate, and cost. Promote K3 only if it is
non-inferior on critical misses and constraint coverage, has no worse accessibility
or design-acceptance rate, and its latency/cost is acceptable. A K3 result never
overrules Sol on architecture, API shape, security, product, or final judgment
during this experiment.

---

## New lanes + controls (2026-07-18 optimization round)

Driven by the benchmark cycle: K3 at 71.0 was a locked-down-lane/wrong-genre artifact,
the same signature Grok had in v2. K3's owner-observed + vendor-data strengths (visual/UI
design, 3D, long-horizon, 1M context) now get real lanes. All still route through
`Invoke-KimiK3.ps1`.

### Deterministic citation validation (all web/research lanes)
The wrapper now captures every `FetchURL`/`WebSearch` URL, extracts URLs cited in the
response (incl. bare arXiv ids, abs/pdf normalized to one canonical form), and computes
`cited_but_unfetched[]`. Params: `-RequireVerifiedCitations` (default ON for
`-ResearchSwarm` and any web lane), `-CitationPolicy Fail` (reject the run like a
disallowed tool, default for benchmark rows) or `Flag` (return `citation_verified=false`
+ the list; orchestrator strips those claims before any grader/Sol consumes them). Result
fields: `citation_verified`, `cited_url_count`, `fetched_url_count`, `cited_but_unfetched`,
`citation_policy`. Attach the verified-fetch list to graders as an appendix so a
hallucination flag is deterministic (`cited_but_unfetched>0`) + grader claim-vs-source
fidelity only. The research-swarm prompt now requires a `CITATIONS:` block and forbids
citing a sub-agent's fetch until re-fetched. Tests: 4 citation cases in
Test-Invoke-KimiK3.ps1.

### `[KIMI K3 · DESIGN PROPOSAL]` — default-on for `ui`-flagged visually-important tasks
Frozen brief + copied screenshots -> complete proposal (layout, hierarchy, tokens, full
HTML/CSS/component code AS TEXT; no tools). Dispatched in parallel with Sol's design pass;
Sol locks. Score every pair into the design-off ledger — this finally feeds the 30-pair
promotion experiment above instead of starving it.

### `[KIMI K3 · DESIGN WORKSPACE]` — `-DesignWorkspace` (guarded)
Third permission profile: Write/Edit/Read/ReadMediaFile allowed ONLY inside the
wrapper's ephemeral workspace dir (pattern-scoped in the runtime config); repo read,
shell, web, and subagents stay denied; any path outside the workspace fails closed
(validated + tested). K3 iterates a runnable HTML/React/three.js prototype; the wrapper
returns `workspace_files[]` as the deliverable and lane=`design-workspace`. This is what
visual/3D iteration needs (a file to run) without granting the repo.

### `[KIMI K3 · LONG-HORIZON]`
Whole-repo review / giant multi-file diff / multi-day plan challenge: artifact lane with
the full corpus embedded (1M context). Selected mechanically when the all-in packet
exceeds ~250 KiB and is cross-cutting (mode-selection.md), not by memory.

## Proxy / stronger-harness A/B (SPEC — build + live A/B pending a Moonshot key)
Status: DESIGN COMPLETE, not yet built. Hypothesis (the Grok lesson): K3-the-model may
outperform K3-the-native-CLI in a stronger agentic harness. A/B-FIRST — do not adopt
unseen, do not reject.
- Mechanism (Windows-viable, first-party both ends): Anthropic's claude-code CLI +
  `ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic`, `ANTHROPIC_AUTH_TOKEN=<Moonshot
  key>`, model pinned to the K3 id. NOT the whitesmith npm proxy (macOS/third-party/
  K2-via-Groq — rejected).
- New wrapper `Invoke-KimiK3Proxy.ps1`: ephemeral HOME/config, env set for child lifetime
  only + never printed, dedicated SEPARATE pinned CLI at `.codex/fleet/clis/
  claude-k3proxy-<ver>` in its own approved-clis entry (NEVER sharing the Opus pin),
  model-identity proof per run (assert response model == K3), lane-mirrored permission
  profile (never `--dangerously-skip-permissions`), telemetry off, hard timeout + tree
  kill. Every row: `transport=claude-code@<ver>->moonshot-anthropic-endpoint`,
  `harness_variant=claude_code_proxy`, `estimand=optimized_system` (banned from the model
  leaderboard).
- A/B: 3 genres (review / UI design / long-horizon) x 2 runs vs native harness, 4 hardened
  graders, citation appendix, double-pass grading. ADOPTION BAR: mean delta >= +8 across
  >=6 pairs AND no new hallucination flags AND no guardrail incident -> proxy becomes K3's
  harness for the winning genres (per-genre). Loss/tie -> keep native. One proxy
  experiment at a time; do not proxy any other model now (Grok/GLM/Gemini show no mismatch).
- BLOCKED ON: a Moonshot Anthropic-endpoint API key. The native K3 OAuth (kimi.com) is a
  different credential and cannot drive this endpoint.
