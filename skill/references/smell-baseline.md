# Standards Smell Baseline (Fowler 12)

Adopted 2026-07-31 from Matt Pocock's `code-review` skill (Fowler, _Refactoring_ ch.3).
Paste this file **in full** into the Standards-axis review charter. A frozen-packet
reviewer has no other access to it.

## Why it exists

Fleet charters already say "maintainability". That word produces vague findings.
Fallow already catches three of these mechanically (Duplicated Code, dead code,
complexity hotspots). The other nine are structural/semantic — no tool in the stack
detects them, and they are the ones that rot a codebase that ships fast.

## Two binding rules

- **The repo overrides.** A documented repo standard (`AGENTS.md`, `CODING_STANDARDS.md`,
  `CONTRIBUTING.md`) always wins. Where the repo endorses something the baseline would
  flag, suppress the smell and say which rule overrode it.
- **Always a judgement call.** Each smell is a labelled heuristic ("possible Feature
  Envy"), never a hard violation. Documented-standard breaches can be hard; baseline
  smells never are.
- **Skip what tooling enforces.** Do not re-report anything Fallow, eslint, prettier, or
  `tsc` already gate — the packet's `fallow-results.json` is the record. Duplicated Code
  is reportable only for shapes Fallow's detector misses (cross-language, cross-package,
  or same-shape-different-tokens).

## The twelve

Each reads *what it is* → *how to fix*. Match against the frozen diff, not the whole repo.

- **Mysterious Name** — a function, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design is murky.
- **Duplicated Code** — the same logic shape in more than one hunk or file in the change. → extract the shared shape, call it from both.
- **Feature Envy** — a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps** — the same few fields or params keep travelling together (a type wanting to be born). → bundle them into one type, pass that.
- **Primitive Obsession** — a primitive or string standing in for a domain concept that deserves its own type. → give the concept its own small type.
- **Repeated Switches** — the same `switch`/`if`-cascade on the same type recurs across the change. → replace with polymorphism, or one map both sites share.
- **Shotgun Surgery** — one logical change forces scattered edits across many files in the diff. → gather what changes together into one module.
- **Divergent Change** — one file or module edited for several unrelated reasons. → split so each module changes for one reason.
- **Speculative Generality** — abstraction, parameters, or hooks added for needs the spec doesn't have. → delete it; inline back until a real need shows.
- **Message Chains** — long `a.b().c().d()` navigation the caller shouldn't depend on. → hide the walk behind one method on the first object.
- **Middle Man** — a class or function that mostly just delegates onward. → cut it, call the real target direct.
- **Refused Bequest** — a subclass or implementer that ignores or overrides most of what it inherits. → drop the inheritance, use composition.

## Output contract

Free-form markdown (HARNESS LAW). Per finding: smell name, `file:line`, the quoted hunk,
one-line fix, and `hard` (documented standard breached) or `judgement` (baseline smell).
Group under a `## Standards` heading so arbitration can count the axis separately.
