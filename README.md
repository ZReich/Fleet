# Fleet

**Fleet is a way to run a whole team of AI models like an actual dev team — a planner, an implementer, a supervisor, and a panel of reviewers — instead of asking one model to do everything and hoping it's right.**

Here's the problem it solves. One model planning, writing, *and* reviewing its own code is a model grading its own homework. It'll tell you it's done. It'll sound confident. And it'll ship a bug that "looked fine." Fleet splits those jobs across different models, runs the independent ones at the same time, and puts every change through a blind review it can't skip. The cheap models do the grunt reading. The best model available makes the calls. **Nothing is "done" until the evidence actually says so.**

You drive it from whatever CLI you already use — Claude Code, Codex, take your pick. **Fleet is the workflow, not the tool.**

---

## What it looks like in practice

You ask for something. Fleet:

1. **Reads the ground first** — a cheap, fast model maps the repo and writes a shared brief so nobody reinvents a helper that already exists.
2. **Plans it** — a planner model writes a locked plan: what changes, in what order, in which files, and *why*. It owns the design decisions.
3. **Builds it in parallel** — independent pieces run at the same time in isolated worktrees. The implementer writes the code, then immediately reviews and fixes its own work in a second pass before anything else sees it.
4. **Reviews it hard** — a panel of models from *different families* reviews the change blind. No model grades its own work. Real bugs get found here, not in production.
5. **Proves it** — every gate quotes what it actually ran (`tests: 274/274`, not "tests pass"). Green that can't be proven doesn't count.

**The whole thing scales to the risk.** A typo fix doesn't get a five-model panel. A payment path change does.

---

## How you ask for it

Fleet has modes. You pick one by how you invoke it:

| You want to… | Mode | What happens |
| --- | --- | --- |
| Build / fix / refactor something | `fleet` | Plan → build → review, sized to the risk. The default. |
| Plan a big feature before building | `fleet plan` | Six models each design it independently and blind, then the plans get merged, attacked, and locked. |
| Research a question | `fleet research` | Several models search in parallel, each a different way, every source verified. |
| Design a UI | `fleet design` | Design candidates propose in parallel; the design lead locks the final call. |
| Review a diff or PR | `fleet review` | The blind panel only — no building. |
| Clean up a codebase | refactor mode | Scoped to a whole codebase, not a diff. The rule: behavior can't change. |

Full detail on each is in the [Wiki](#the-wiki).

---

## What you need to run it

Fleet orchestrates models that live in **CLIs you install yourself** — it doesn't bundle them. The core setup:

- A driving CLI (Claude Code or Codex) as the orchestrator
- Access to the models you want in each seat (see [Roles & Models](https://github.com/ZReich/Fleet/wiki/Roles-and-Models))
- Three workspace tools that Fleet leans on:
  - **[Fallow](https://github.com/fallow-rs/fallow)** — static-analysis gate; counts new code smells on every change
  - **[Ponytail](https://github.com/DietrichGebert/ponytail)** — the "laziest solution that works" discipline
  - **[Caveman](https://github.com/JuliusBrussee/caveman)** — terse output mode; keeps long runs readable and cheap

Setup steps are in [Setup & Install](https://github.com/ZReich/Fleet/wiki/Setup-and-Install).

---

## The Wiki

The README is the front door. The [**Wiki**](https://github.com/ZReich/Fleet/wiki/Home) is the whole house:

- **[Overview](https://github.com/ZReich/Fleet/wiki/Home)** — the philosophy and the one rule that makes it work
- **[Roles & Models](https://github.com/ZReich/Fleet/wiki/Roles-and-Models)** — who does what, and which model fills each seat
- **[The Workflow](https://github.com/ZReich/Fleet/wiki/The-Workflow)** — the phases, start to finish
- **[Modes](https://github.com/ZReich/Fleet/wiki/Modes)** — build, plan, research, design, review, refactor
- **[Rigor Tiers](https://github.com/ZReich/Fleet/wiki/Rigor-Tiers)** — how the effort scales to the risk
- **[Adversarial Review](https://github.com/ZReich/Fleet/wiki/Adversarial-Review)** — the blind panel, and why it's the heart of the thing
- **[Model Performance Tracking](https://github.com/ZReich/Fleet/wiki/Model-Performance-Tracking)** — how we actually know which models are good
- **[Code Quality](https://github.com/ZReich/Fleet/wiki/Code-Quality)** — file sizes, code smells, and green-that-lies
- **[Ponytail & Caveman](https://github.com/ZReich/Fleet/wiki/Ponytail-and-Caveman)** — the two habits baked into every lane
- **[Setup & Install](https://github.com/ZReich/Fleet/wiki/Setup-and-Install)** — get it running

---

*Fleet is a living workflow. The phases and gates are the stable spine; the exact models and thresholds move as the tools do.*
