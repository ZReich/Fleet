# Static-Gate Adapters (language-agnostic gate contract)

Fleet's maintainability gate was written around Fallow, which only understands JS/TS.
The moment a run targets Rust (Loupe), Python, or PowerShell, "Fallow didn't run" turns
into a green gate — the false-green class this framework exists to kill.

The contract is the FIVE DIMENSIONS below. Fallow is one adapter that happens to satisfy
four of them at once. Any tool that measures a dimension is a valid adapter.

## The five dimensions

| # | Dimension | What a finding means |
| - | --------- | -------------------- |
| D1 | Dead code | Symbol/file unreachable from any entry point |
| D2 | Duplication | Same logic shape in more than one place |
| D3 | Complexity | Function/module past the repo's cyclomatic or cognitive threshold |
| D4 | Unused dependencies | Declared and never imported |
| D5 | Size | File/module past the line budget; binary or bundle bloat |

## Adapters

| Dim | JS/TS | Rust | PowerShell | Any language (fallback) |
| --- | ----- | ---- | ---------- | ----------------------- |
| D1 | `fallow audit` | `cargo clippy` (`dead_code`), `cargo-machete` | — | jcodemunch `get_dead_code_v2` (>=0.67) |
| D2 | `fallow audit` | `jscpd` | `jscpd` | `jscpd --min-tokens 50` |
| D3 | `fallow audit` | `rust-code-analysis-cli` | — | `lizard` |
| D4 | `depcheck` | `cargo-udeps` / `cargo-machete` | — | — |
| D5 | `Assert-FleetFileSize` + bundle report | `cargo-bloat`, `cargo llvm-lines` | `Assert-FleetFileSize` | `Assert-FleetFileSize` |

`jscpd` and `lizard` are the portable pair: token-based duplication and multi-language
complexity. A language with no first-party tooling still gets D2, D3, and D5 from them,
plus D1 from jcodemunch's import/call graph. There is no such thing as an unmeasurable
repo — only an unconfigured one.

### Rust (Loupe) concrete gate

```bash
cargo clippy --all-targets --all-features -- -D warnings -W clippy::pedantic  # D1, D3
cargo machete                                                                 # D1, D4
jscpd --min-tokens 50 --reporters json --output .fleet/jscpd src/             # D2
lizard -l rust -C 15 src/                                                     # D3
cargo bloat --release --crates -n 20                                          # D5
```

## not_measured is a WATCH, never a pass

`Get-FleetReviewPacket.ps1` accepts `fallow-results.json` with `status: "not_measured"`
plus a nonempty `reason`, so a packet stays valid when a tool genuinely cannot run. That
escape hatch was built for PowerShell-only repos and it is correct — but a valid packet
is not a clean one. Rules:

1. `not_measured` names the DIMENSION and the missing ADAPTER, not the tool that happens
   to be absent. `"Fallow targets JS/TS"` is not a reason on a Rust repo — `jscpd`,
   `lizard`, and `clippy` all run there, so the dimension is unmeasured by choice.
2. Every `not_measured` dimension enters the verdict as a **WATCH** with the exact command
   that would have measured it. It never counts toward "gates green".
3. A run may not report "gates: clean" while any dimension is unmeasured. It reports
   `gates: N/5 measured` — the denominator rule, applied to coverage instead of tests.
4. Only the owner waives a dimension, per run, in the locked plan. Silence is not a waiver.

## Quoting the result

Same shape as the Fallow line, one row per dimension, so a reader can see coverage:

```text
static-gates: 5/5 measured | D1 dead: 0 | D2 dup: 0 | D3 complexity: 1 WATCH | D4 deps: 0 | D5 size: 0
```

A missing row is a gate that did not run. `0` with no denominator is not evidence.
