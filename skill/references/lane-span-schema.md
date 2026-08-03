# Fleet lane span record schema (v1)

Normative schema for one OTel-GenAI-shaped JSONL row per lane completion.
Ledger: repo-root `BENCH-lanes.jsonl` — one compact JSON object per line, UTF-8 no BOM.

Recorder: `scripts/Record-FleetLaneSpan.ps1` (fail-closed; never appends invalid input).
Validator: `scripts/Test-FleetLaneSpanRecord.ps1` (`Test-FleetLaneSpanRecord`).

## Row shape

Exact top-level field names. Dotted GenAI keys are flat property names (not nested).

| Field | Type | Nullability |
| --- | --- | --- |
| `schema_version` | string | required; must be `"1"` |
| `run_id` | string | required non-empty |
| `lane_id` | string | required non-empty |
| `phase` | string | required non-empty |
| `gen_ai.operation.name` | string | required; must be `"invoke_agent"` |
| `gen_ai.agent.name` | string | required non-empty |
| `gen_ai.provider.name` | string | required non-empty |
| `gen_ai.request.model` | string | required non-empty |
| `gen_ai.response.model` | string \| null | null when cli-pinned-unobserved |
| `gen_ai.usage.input_tokens` | int \| null | null when unavailable |
| `gen_ai.usage.output_tokens` | int \| null | null when unavailable |
| `gen_ai.usage.cache_read.input_tokens` | int \| null | null when unavailable |
| `tool_calls` | int | required; nonnegative |
| `inference_calls` | int | required; nonnegative |
| `duration_s` | number | required; nonnegative finite |
| `first_result_s` | number \| null | null only when no result arrived; else `0 <= first_result_s <= duration_s` |
| `status` | string | required; `ok` \| `error` \| `timeout` \| `no_contest` |
| `error.type` | string \| null | null when no error classification |
| `handoff` | object \| null | null, or complete `{receipt_bytes, verify_ms, artifact_sha_ok}` |
| `artifacts` | array | always array (may be empty); each `{path, bytes, sha256}` |

### handoff object (when non-null)

| Field | Type |
| --- | --- |
| `receipt_bytes` | nonnegative integer |
| `verify_ms` | nonnegative finite number |
| `artifact_sha_ok` | boolean |

Incomplete handoff (missing any of the three fields, or unknown keys) is rejected.

### artifacts[] entry

| Field | Type |
| --- | --- |
| `path` | non-empty string |
| `bytes` | nonnegative integer |
| `sha256` | exactly 64 lowercase hex (`[0-9a-f]{64}`) |

## Validation (fail-closed)

- Unknown top-level fields rejected.
- Missing required fields rejected.
- Invalid values rejected (status enum, nonnegative counts/durations, sha256 form, handoff completeness, first_result_s range).
- Invalid input is NEVER appended to the ledger.

## Identity / concurrency

- Identity key: `(run_id, lane_id)`.
- Duplicate identity: second append exits 1 inside the global mutex.
- Mutex: `Global\CodexFleetLaneSpan-<sha256(abs_ledger_path)[0..24]>`, 30s wait.
- Append: UTF-8 no BOM, compact JSON + newline, canonical field order as listed above.

## Example

```json
{
  "schema_version": "1",
  "run_id": "fleet-build-20260729",
  "lane_id": "W1/T1",
  "phase": "impl",
  "gen_ai.operation.name": "invoke_agent",
  "gen_ai.agent.name": "grok-4.5",
  "gen_ai.provider.name": "xai",
  "gen_ai.request.model": "grok-4.5",
  "gen_ai.response.model": null,
  "gen_ai.usage.input_tokens": null,
  "gen_ai.usage.output_tokens": null,
  "gen_ai.usage.cache_read.input_tokens": null,
  "tool_calls": 12,
  "inference_calls": 3,
  "duration_s": 420.5,
  "first_result_s": 18.2,
  "status": "ok",
  "error.type": null,
  "handoff": {
    "receipt_bytes": 2048,
    "verify_ms": 45.5,
    "artifact_sha_ok": true
  },
  "artifacts": [
    {
      "path": "scripts/Record-FleetLaneSpan.ps1",
      "bytes": 4096,
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  ]
}
```

## Recorder CLI

```text
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\Record-FleetLaneSpan.ps1 -RecordPath .fleet\T1-lane-span.json -OutputPath BENCH-lanes.jsonl
```

`RecordPath` is a single span JSON file produced by the lane/manager.
