# Fleet worktree janitor (authoritative)

Automatic reclaim of **abandoned run-owned** worktrees under the canonical Codex
worktree root. Ambiguity is always **SKIP**, never deletion permission. A missed
stale directory is untidy; deleting a live lane tree or pool slot is catastrophic.

History: a recursive delete once followed a Windows junction into the main checkout
and destroyed 727 tracked files. Junction safety is non-negotiable.

## CLI

```powershell
Invoke-FleetWorktreeJanitor.ps1 -Mode Report|Apply -MinAgeHours 72 `
  [-WorktreeRoot <path>] [-ReportPath <path>]
```

| Param | Default | Notes |
| --- | --- | --- |
| `-Mode` | `Report` | Explicit CLI default is Report (no mutation). |
| `-MinAgeHours` | `72` | Age gate uses newest of dir mtime and sidecar `created_utc`. |
| `-WorktreeRoot` | `%USERPROFILE%\.codex\worktrees` | Override exists **for tests only**. |
| `-ReportPath` | temp JSON | Same schema for Report and Apply. |

`Enter-FleetRunLease.ps1` invokes `-Mode Apply` **after** lease creation **and**
mutex release. Janitor stdout is discarded/redirected to stderr + report file so
Enter stdout remains exactly one lease-path line. A janitor failure **never**
invalidates the new lease (catch, warn on stderr, continue).

## Sidecar schema (T5 writes; janitor consumes)

Sibling of the tree: `<worktree-path>.fleet-run.json`

```json
{
  "schema_version": "1",
  "run_id": "...",
  "repo_path": "...",
  "git_common_dir": "...",
  "created_utc": "...",
  "ownership": "run-owned"
}
```

Only `schema_version=1` + `ownership=run-owned` is a sidecar candidate.

## Candidate identification

1. **Sidecar present** with `ownership=run-owned` → candidate (run-owned).
2. **LEGACY (no sidecar)** → candidate **only if** under the worktree root **and**
   either:
   - git HEAD is an exact `fleet/<runid>`-style branch, or
   - directory name matches `*-20260[0-9]{4}*` **or** prefix `grok-*` / `fleet-*`.
3. Else → **AMBIGUOUS** → skip.

## Safety matrix (any match → SKIP, never delete)

| Condition | Reason code |
| --- | --- |
| Ancestor or self contains `.fleet-pool/pool.json` | `pool_marker` (rechecked immediately before each deletion) |
| Sidecar/legacy `run_id` has a **live** lease under `%USERPROFILE%\.codex\fleet\run-leases\` | `live_lease` |
| Running process CommandLine **or** CWD under candidate path | `live_process` |
| Age &lt; `-MinAgeHours` | `too_young` |
| Ownership ambiguous | `ownership_ambiguous` |
| Enumeration error | `enumeration_error:*` |
| Unresolved reparse point (cannot read target) | `unresolved_reparse` |

WMI/CIM process query failure → treat as live (skip). Individual null CommandLine
does not alone force skip; CWD probe is used. Access-denied CWD for a process is
ignored for that process (positive evidence only), but full query failure is live.

## Deletion path (per candidate, Apply only) — universal two-stage quarantine (2026-08-12)

NOTHING is hard-deleted at scan level. Every eligible tree (run-owned sidecar, fleet-branch
legacy, or registered work-guard class) is:

1. **No-follow reparse inspection** (`Get-ChildItem` / attributes; never follow). Candidate
   itself and the quarantine root must NOT be reparse points.
2. **Moved** (atomic same-volume rename) to `<WorktreeRoot>\.fleet-quarantine\<leaf>-<id>` with
   a `.quarantined.json` clock marker (Report mode never writes markers).
3. Stale registration pruned: `git -C <repo_path> worktree prune --expire now`; sibling
   sidecar file removed (leaf delete only).
4. Quarantined entries older than `-QuarantinePurgeAgeHours` (default 336h) are purged with
   `python scripts/purge_orphan_tree.py <path>` (junction-canary self-tested deleter).

Additional admission classes (2026-08-12): a REGISTERED linked worktree under the root
without a `fleet/*` branch is eligible only after `-RegisteredGuardAgeHours` (168h) AND
clean tree AND no commits unreachable from other refs (`dirty_tree`/`unmerged_commits`
skips otherwise). Bare no-git orphan dirs quarantine after `-OrphanQuarantineAgeHours`
(336h). Recovery from quarantine = move the directory back; nothing is lost for 14 days.

**Banned:** `rd`, `Remove-Item -Recurse`, `robocopy /MIR` or `/PURGE`, any generic
recursive walker that can follow junctions into another checkout.

Per-candidate failure → skip + record in report, continue with others.

## Report JSON

```json
{
  "schema_version": "1",
  "mode": "Report|Apply",
  "worktree_root": "...",
  "min_age_hours": 72,
  "generated_utc": "...",
  "candidates": [
    {
      "path": "...",
      "run_id": "...",
      "ownership": "run-owned|legacy|ambiguous",
      "age_hours": 0,
      "bytes_estimate": 0,
      "action": "would_remove|removed|skip",
      "reason": "...",
      "delete_via": "git_worktree_remove|purge_orphan_tree|",
      "command": "exact command line used or previewed"
    }
  ],
  "summary": {
    "scanned": 0,
    "removable": 0,
    "skipped": 0,
    "removed": 0,
    "errors": 0
  }
}
```

Report mode mutates **nothing** and writes the same report shape with
`action=would_remove` for reclaimable candidates.

## Ordering markers (tests / diagnostics)

- Enter stderr after mutex release: `fleet-lease-order: mutex-released`
- Janitor stderr at start: `fleet-lease-order: janitor-begin mode=...`

## Pool relationship

Pool slots are **never** deleted by this janitor. Presence of
`.fleet-pool/pool.json` on any ancestor is hard skip. Pool reclaim remains
quarantine-only via `Invoke-FleetWorktreePoolReap.ps1` (see `worktree-pool.md`).
