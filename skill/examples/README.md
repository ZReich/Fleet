# examples/

Templates for the files Fleet reads/writes at runtime but that ship **empty or as
placeholders**, because the real ones are either machine-specific state or the
maintainers' private measured data.

## State files (copy + let Fleet populate)

- **`approved-clis.example.json`** → copy to `$env:USERPROFILE/.codex/fleet/approved-clis.json`.
  Pins the exact CLI bytes Fleet may run in trusted seats. Populate it with
  `scripts/Approve-ClaudeCli.ps1` rather than by hand.
- **`cli-update-status.example.json`** → lives at
  `$env:USERPROFILE/.codex/fleet/cli-update-status.json`. A daily read-only audit writes it;
  Fleet reads it at preflight. It regenerates itself — you don't hand-edit it.

## Benchmark ledgers (created on first run)

The model-performance ledgers are **append-only files Fleet creates the first time it has a
row to write.** You don't ship or seed them — you start with none and they fill up as you
run. See the [Model Performance Tracking](https://github.com/ZReich/Fleet/wiki/Model-Performance-Tracking) wiki page
for what each one holds.

| Ledger | Holds |
| --- | --- |
| `BENCH-lanes.jsonl` | One span per lane completion (model, duration, tokens, status) |
| `BENCH-shadow.jsonl` | Shadow-run comparison results |
| `BENCH-grok45.jsonl` | Detailed implementation benchmark rows |
| `BENCH-genre.jsonl` | Per-task-type capability map (derived) |
| `BENCH-k3-qualification.jsonl` | Candidate-voice qualification rows |
| `BENCH-opus5-pairs.jsonl` | Paired review-voice comparisons |

The maintainers' own ledgers (their real measured data) are **not** included — you build
your own picture of which models are good in *your* setup, from *your* runs. That's the
whole point of the measurement (see the wiki page).

Example of a single lane-span row (the shape, not real data):

```json
{"schema_version":"1","run_id":"run-0001","lane_id":"T1","phase":"implement","gen_ai.request.model":"grok-4.5","gen_ai.response.model":null,"duration_s":214.3,"first_result_s":6.1,"status":"ok","artifacts":[]}
```
