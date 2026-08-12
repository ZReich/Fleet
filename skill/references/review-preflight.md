# Selected-voice review preflight

Kill auth / argument failures before token-heavy panel work. Packet freeze requires a READY preflight for the **selected** voices only.

## Manifest schema (`selected-voices.json`)

```json
{
  "schema_version": "1",
  "run_id": "fleet-fix-trustchain-20260810",
  "selected": [
    { "lane_id": "v-sol", "voice": "sol", "probe_profile": "plan" }
  ]
}
```

| Field | Rules |
| --- | --- |
| `schema_version` | Must be `"1"`. |
| `run_id` | Nonempty; must match `review-preflight.json.run_id`. |
| `selected[]` | Ordered. Each row carries **only** `lane_id`, canonical `voice`, `probe_profile`. |
| Caller-supplied commands | **Forbidden.** Script derives wrapper + args from `voice` + `probe_profile` (trust boundary). |

Canonical voices: `sol`, `terra`, `opus`, `glm`, `glm-security`, `grok`, `kimi-security`, `kimi-proxy`.

## Probe table

| Voice | Probe (script-derived) | Pass rule |
| --- | --- | --- |
| `sol` | `Invoke-Sol.ps1 -Probe` | Nonempty non-error output; `SOL_OK` / `probe_ok` when JSON. |
| `terra` | Approved pinned `codex` + isolated `CODEX_HOME` (`New-CodexLaneHome`) + `-c model=gpt-5.6-terra` tiny exec | Nonempty non-error stdout. |
| `opus` | `Invoke-Opus48.ps1 -Model claude-opus-5 -PromptFile <tiny>` | Nonempty non-error; no OAuth-empty / 401 marker. |
| `glm`, `glm-security` | `Invoke-PiGlm.ps1` tiny prompt (`-NoTools -Thinking off`) | Nonempty non-error. |
| `grok` | `Invoke-Grok45.ps1 -Review -Effort low` tiny prompt | Nonempty non-error. |
| `kimi-security` | Auth file + wrapper param validation only (no full lane). Rejects unsupported `-Repo`. | Credential present; param surface valid. |
| `kimi-proxy` | `Invoke-KimiK3Proxy.ps1` tiny prompt | Nonempty non-error. |

A probe **PASS** requires demonstrated nonempty, non-error output. Empty response, exit ≠ 0, or auth markers (`401`, `oauth expired`, `login_required`, `credentials expired`, `not authenticated`) → **FAIL**. Failures that surface missing `-PromptFile` or unsupported `-Repo` also FAIL.

## CLI

```text
powershell -NoProfile -File scripts/Test-FleetExternalLanes.ps1 `
  -SelectedVoiceManifest <path> -RunId <id> -OutputPath <path> `
  [-Mode text|json] [-ForceProbe]
```

Legacy flags (`-RequireOpus`, `-RequireGlm`, …) remain back-compatible when `-SelectedVoiceManifest` is omitted.

## Status lines (stdout last line exactly)

```text
review-preflight: READY | selected: N | passed: N | cached: C | failed: 0
review-preflight: BLOCKED | selected: N | passed: P | failed: F | substitution: REQUIRED
```

BLOCKED exits nonzero. Orchestrator (not this script) selects fallbacks, rewrites the selection, and reruns preflight. This script never reroutes voices internally.

## Evidence JSON (`-OutputPath` → typically `review-preflight.json`)

```json
{
  "schema_version": "1",
  "run_id": "...",
  "status": "READY",
  "status_line": "review-preflight: READY | selected: 1 | passed: 1 | cached: 0 | failed: 0",
  "selected": 1,
  "passed": 1,
  "cached": 0,
  "failed": 0,
  "voices": [
    {
      "lane_id": "v-sol",
      "voice": "sol",
      "probe_profile": "plan",
      "result": "pass",
      "cache_hit": false,
      "cli": "codex",
      "version": "...",
      "wrapper_sha256": "...",
      "detail": ""
    }
  ]
}
```

`status` is `READY` or `BLOCKED`. Packet freeze requires `status=READY` and matching `run_id`.

## Cache

| Item | Value |
| --- | --- |
| File | `%USERPROFILE%\.codex\fleet\review-preflight-cache.json` |
| Key | SHA-256 of `cli\|version\|probe_profile\|wrapper_sha256` |
| Writes | **Successful probes only.** Failures are never cached. |
| TTL | 24h default; **1h** while any live run lease exists under `%USERPROFILE%\.codex\fleet\run-leases\*.json` |
| Bypass | `-ForceProbe` ignores cache |

## Packet freeze binding

`Get-FleetReviewPacket.ps1` requires both artifacts in the packet dir, hashes them into the manifest, and fail-closes when:

- either file missing / empty
- `selected-voices.json` schema invalid
- `review-preflight.json` status is not READY (or status_line does not start with `review-preflight: READY`)
- `run_id` mismatch between the two files
- preflight reports `failed > 0` while claiming READY

Absent / mismatched / BLOCKED → dispatch blocked (same fail-closed style as empty core artifacts).
