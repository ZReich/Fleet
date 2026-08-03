# Fleet — Lessons Log

This file is **yours to grow — and it fills itself.** Every time you run the Fleet skill,
it reads this file at preflight (Phase 0) and appends any new lessons at the end of the run.
So you start empty, and over time this becomes a record of what *your* setup learned the
hard way, without you having to maintain it by hand.

It ships **empty on purpose.** The maintainers' own lessons file is a private operational
log — full of dated, project-specific incidents — so it isn't included in the public
release. What you're holding is the mechanism; the history writes itself once you start
running Fleet.

## How to use it

- **At preflight:** read this file. Whatever's here is context for the run about to start.
- **At run end:** append a one-line, durable lesson for any real friction you hit —
  a gate that lied, a wrapper that hung, a mode that was mis-selected. Keep it terse and
  keep the evidence (the command, the `file:line`, the exact error).
- **Format:** free-form. A dated bullet list works fine. Example:

```
## 2026-08-02
- Grok review lane stalled with no first turn for 180s → self-killed as no_contest.
  Fix: pre-first-turn timeout is working as intended; don't retry, treat as no_contest.
```

Over time this becomes the most valuable file in the skill — the accumulated, hard-won
knowledge of how *your* setup actually behaves. Start writing.
