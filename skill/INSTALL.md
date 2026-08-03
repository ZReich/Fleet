# Installing the Fleet skill

This is the runnable skill package — the contract, the protocols, and the scripts that
actually do the work. For the *concepts* (what Fleet is and why), read the
[Wiki](https://github.com/ZReich/Fleet/wiki/Home). This file is just how to get it running.

> **Platform:** the scripts are **Windows PowerShell 5.1** (`.ps1`, plus one Python
> helper). The workflow is portable; these specific scripts are not. A cross-platform
> port is open for contribution.

## What's in the box

```
fleet/
├── SKILL.md              # the Codex-side contract — modes, tiers, routing, roles
├── LESSONS.md            # ships EMPTY — your running lessons log (Fleet reads/appends it)
├── INSTALL.md            # this file
├── fleet-policy.json     # machine-readable policy: tiers, voices, budgets, bias controls
├── fleet-canaries.json   # fixed set of self-test defects the scripts replay against themselves
├── references/           # the protocols (mode selection, review, plan, refactor, schemas…)
├── scripts/              # wrappers, gates, lease + worktree + benchmark tooling (+ Test-* for each)
├── adapters/claude/      # Claude Code adapter (drive Fleet from Claude instead of Codex)
└── examples/             # templates for runtime state + ledgers (see examples/README.md)
```

## Prerequisites

Fleet orchestrates model CLIs you install and log into yourself — it bundles none of them
and handles none of your keys. Install the ones for the seats you want (all optional except
your orchestrator; Fleet degrades and tells you loudly when a lane is missing):

| CLI | Seats it fills |
| --- | --- |
| Codex | Planner (Sol), Supervisor (Terra), overflow (Luna), Synthesizer (Spark) |
| Grok CLI | Implementer (Grok 4.5) |
| Pi CLI | Review voice (GLM 5.2) |
| Kimi CLI | Design / long-context candidate (Kimi K3) |
| Antigravity CLI (`agy`) | Visual evidence (Gemini Flash) |
| Claude Code | Review voice / orchestrator (Opus) |

Plus the three workspace tools Fleet leans on: **Fallow** (static-analysis gate),
**Ponytail** (over-engineering discipline), **Caveman** (terse output). See the
[Setup & Install](https://github.com/ZReich/Fleet/wiki/Setup-and-Install) wiki page for links and detail.

## Install

1. **Drop this folder** where your orchestrator CLI loads skills from — e.g.
   `$env:USERPROFILE/.codex/skills/fleet` for Codex, or the Claude Code skills dir if
   you're driving from Claude (see `adapters/claude/SKILL.md`).
2. **Log into each model CLI** once (Fleet uses the session each CLI already holds).
3. **Seed runtime state** from `examples/`: copy `approved-clis.example.json` and
   `cli-update-status.example.json` into `$env:USERPROFILE/.codex/fleet/` (drop the
   `.example`), then let `scripts/Approve-ClaudeCli.ps1` and the daily audit populate them.
   The `BENCH-*.jsonl` ledgers create themselves on first run — don't seed them.
4. **Verify the scripts** — run the offline suite:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Test-FleetAll.ps1
   ```
5. **Invoke it** by name — `fleet`, `fleet plan`, `fleet research`, `fleet design`,
   `fleet review`. See the [Modes](https://github.com/ZReich/Fleet/wiki/Modes) wiki page.

## Minimum viable setup

You don't need the whole roster to start. The smallest useful Fleet:

- One orchestrator (Claude Code or Codex)
- One planner + one implementer + **one review voice from a different family than the implementer**
- Fallow (or your language's static-analysis equivalent)

That gets you the core value: something plans, something else builds, and a *different
family* reviews it blind. Add voices and modes from there.
