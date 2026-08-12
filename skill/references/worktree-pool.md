# Fleet warm worktree pool (authoritative)

Authority for pool lifecycle, slot↔store boundary, sanitation, and run-lease
exception. Future cleanup logic MUST NOT delete pool assets or treat an
`acquired`/`preparing`/live-worker slot as complete. Implementation scripts
must conform; this doc does not implement runtime logic.

## Slot ↔ store interface

**Hybrid, locked:**

- Package manager: **npm** (preserve `package-lock.json` / npm workspace semantics).
- Shared npm content-addressable download store (`cacache` blobs).
- Optional shared immutable build-output CAS.
- **No shared mutable `node_modules`.**
- Per-slot warm, **physical** `node_modules` (directory is a real directory, never a reparse point).
- **No hardlinks/symlinks** from a slot dependency tree into another slot, main checkout, or shared cache.
- `node_modules` root is never a symlink/junction.

### Vite / Vitest constraint

Symlinked `node_modules` broke Vite/Vitest path resolution on the Harken wizard
(LESSONS 2026-07-09). Therefore:

- No pnpm default symlink layout.
- No `node_modules` directory symlink.
- No hardlinked dependency trees across slots (mutation would cross isolation).
- External packages materialize inside the slot; Vite/Vitest resolves under the fixed slot root.
- npm workspace links permitted only when the resolved target remains **inside the same slot**.
- Any workspace link resolving to main checkout, another slot, cache root, or ancestor → quarantine.

### Dependency CLI

```powershell
Ensure-FleetDependencies.ps1 `
  -Worktree <absolute-slot> `
  -StoreRoot "$env:USERPROFILE\.codex\cache\fleet\npm" `
  -PreviousFingerprint <sha256-or-empty> `
  [-InstallCommand <command>] `
  [-NoInstall] `
  [-NodeBinDir <absolute-dir>] `
  -Mode json
```

Result fields: `status=reuse-hit|installed|skipped|failed`, `layout=slot-local-physical`,
`cache_provider=npm-cacache`, `dependency_fingerprint`, `manifest_sha256`,
`toolchain_sha256`, `install_reason`, `install_ms`, `lockfile_sha256`, `deps_count`,
`node_modules_bytes`, `store_bytes_before`, `store_bytes_after`.

Pool scripts consume only this frozen CLI/result contract.

## Canonical paths

Repo key:

```text
<first-12-sanitized-repo-name>-<first-8-sha256-of-canonical-git-common-dir>
```

```text
state:  %USERPROFILE%\.codex\worktrees\<repo-key>\.fleet-pool\pool.json
slots:  %USERPROFILE%\.codex\worktrees\<repo-key>\slot-01
build:  %USERPROFILE%\.codex\cache\fleet\build\sha256
events: %USERPROFILE%\.codex\fleet\worktree-pool.jsonl
npm:    %USERPROFILE%\.codex\cache\fleet\npm
```

Default pool size `3`; valid `2..4`. Slot-root path-length budget enforced before
provisioning (Windows 260-char margin).

## CLIs

| Script | Role |
| --- | --- |
| `Initialize-FleetWorktreePool.ps1` | Provision fixed slots; install deps once; state `ready` |
| `Enter-FleetWorktreePoolSlot.ps1` | Atomic acquire: `ready` → `preparing` → `acquired` |
| `Exit-FleetWorktreePoolSlot.ps1` | Sanitize + release to `ready`, or quarantine |
| `Invoke-FleetWorktreePoolReap.ps1` | Stale-lease QUARANTINE-only; never releases to `ready`, never deletes |
| `Set-FleetWorktreePoolProcess.ps1` | Register/Unregister worker PID + start-time |
| `Ensure-FleetDependencies.ps1` | Slot-local physical deps + shared npm cache |

## State machine

```text
provisioning → ready → preparing → acquired → ready
                                         ↘ quarantined
```

- `provisioning`: slot materializing; not claimable.
- `ready`: clean, warm, claimable.
- `preparing`: ownership assigned; branch/base/deps in progress.
- `acquired`: exclusive lane lease; live worker may be registered.
- `quarantined`: dirty or structurally suspect; ownership cleared; remains registered; **never auto-deleted**.

One slot exclusively owned by one lease. Multiple slots may hold different branches/bases concurrently.

## Sanitation / quarantine

**NO recursive delete, ever** against a pool slot. Banned: `Remove-Item -Recurse`,
`rd`, `robocopy /PURGE`, `/MIR`, generic recursive deletion, `os.walk`-style deletes.

Release (`Exit-FleetWorktreePoolSlot`):

1. Registered worker PID/start-time pairs must be dead.
2. Shared fail-closed process liveness scan: CIM failure, unreadable/null command line,
   unreadable CWD, or a command line/CWD under the slot all count as live.
3. Repo identity + worktree registration verified.
4. No-follow reparse scan; escaping/unresolvable reparse → quarantine.
5. Any staged/unstaged/nonignored untracked change → quarantine (no silent work loss).
6. Detach from lane branch only after clean proof; branch kept for merge/audit.
7. Remove ignored material **except** dependency roots from `Ensure-FleetDependencies.ps1`.
8. Preserve physical warm `node_modules`.
9. Remove copied `.env`, ignored build outputs, test artifacts, logs.
10. Clear ownership; mark `ready` (or `quarantined` with reason).

Quarantine triggers: dirty state, repo/common-dir mismatch, registration mismatch,
escaping reparse, dependency root is reparse, live/stale worker ambiguity, install
failure/hollow tree, state/lease token inconsistency, build-cache collision/corruption.

`Invoke-FleetWorktreePoolReap.ps1` is **QUARANTINE-ONLY**: a dead-run-lease `acquired`
slot → quarantine (`orphan-dead-lease`); a stuck `provisioning`/`preparing` slot with a
dead lease → quarantine (`orphan-stuck`); live run lease OR live registered worker OR
live command-line hit → untouched. **Reap NEVER sanitizes and NEVER moves a slot to
`ready`.** The ONLY path back to `ready` is `Exit-FleetWorktreePoolSlot` (lease-authenticated,
workers-dead + command-line-clean verified). A crashed/killed lane therefore leaks a
QUARANTINED slot (safe), refilled by `Initialize`. **Never deletes pool slots.**

## Known limitations (WATCH — 2026-08-08, accepted)

Clean release detaches the reusable checkout and preserves `fleet/<run-id>` for
merge/audit. Owners prune retained run branches explicitly.

The reclaim-a-live-slot CRITICAL is structurally closed (reap cannot reach `ready`). The
following release-gate hardening items are ACCEPTED residuals — they affect only the
`Exit` sanitize+release path under adversarial ORPHAN grandchildren (e.g. a wrapper
hard-killed without `/T` leaving a live `node`/`vitest` in the slot). They cannot delete
outside a slot (containment gates hold); worst case is cross-lane contamination within
slots. Close these before treating the auto-pool release gate as airtight:

- **H1** — Exit command-line liveness scan is fail-OPEN on a WMI error / unreadable
  CommandLine (treated as "clean"). Fix: `-ErrorAction Stop`, require ≥1 row, null CL → live.
- **H2** — command-line scan misses a grandchild whose slot path is only its cwd (not in
  its argv). Fix: add a cwd-based live probe.
- **H3** — `Test-FleetPoolProcessIdentityLive` treats `StartTime` Access-Denied (cross-
  integrity PID) as "dead". Fix: distinguish not-found from cannot-inspect; latter → live.
- **H4** — sanitize does not un-quote git C-quoted (non-ASCII) ignored paths; such files
  can survive release. Fix: `-c core.quotePath=false --ignored`, reject still-quoted.

Until closed, prefer explicit lifecycle (orchestrator always calls `Exit`); reap's
quarantine-only design keeps the failure mode safe (slot leak, not corruption).

## H1-H4 closure (2026-08-10)

The preceding WATCH text is historical only. `Exit` and `Reap` now share one liveness
helper whose single rule is **unknown = live**. A false positive leaks/quarantines a slot;
a false negative can release it while a process still writes it.

- **H1:** CIM/WMI enumeration uses `-ErrorAction Stop`; an error, malformed row, or
  null/unreadable `CommandLine` is live.
- **H2:** every inspected process receives a native PEB CWD probe. A CWD under the slot,
  or an inaccessible/indeterminate CWD, is live.
- **H3:** a found PID whose `StartTime` cannot be read is live. Only a missing PID is dead.
- **H4:** parsed git invocations supply `-c core.quotePath=false`; residual C-quoted paths
  are rejected before sanitation and never trim/sanitized through.

Lifecycle telemetry is mandatory: acquire/release append `acquire_complete`/
`release_complete` to `%USERPROFILE%\.codex\fleet\worktree-pool.jsonl`. A telemetry write
failure emits a warning and makes the lifecycle command return nonzero; it is never swallowed.

## Dependency fingerprint inputs

```text
SHA256(
  schema_version
  package_manager
  install_command
  sorted lockfile path + SHA256 bytes
  sorted tracked package.json path + SHA256 bytes
  node executable path + version
  npm version
  OS + architecture
)
```

Same fingerprint + nonempty physical dependency root + contained reparse graph →
`reuse-hit` (no install). Lockfile, any tracked `package.json`, or Node/npm/arch
change → refresh. Hollow/missing tree → refresh.

## Telemetry events

JSONL at `events` path (named-mutex append; UTF-8 no BOM). Events:

```text
provision_start, provision_complete, acquire_start, acquire_complete,
dependency_reuse, dependency_install, build_cache_hit, build_cache_miss,
build_cache_publish, sanitize_start, release_complete, quarantine, reap
```

Required fields include: `schema_version`, `timestamp_utc`, `event`, `outcome`,
`reason`, `repo_id`, `repo_key`, `pool_size`, `slot_id`, `run_id`, `branch`,
`base_sha`, `ownership`, timing/disk/fingerprint metrics, `registered_worker_count`,
`quarantine_reason`. No lease IDs, env contents, tokens, prompts, or command output.

## Run-lease lifecycle exception (LOCKED — verbatim)

> Run-owned worktrees must be removed at run end. Pool-owned slots must remain registered. Run completes only when every run-acquired pool slot is either sanitized and `ready`, or ownership-cleared and `quarantined`, with no live registered worker. Presence of a pool-owned slot is not incomplete; an `acquired`, `preparing`, or live-worker slot is incomplete.

Run-owned cold worktrees (legacy `New-FleetWorktree` path) still remove at run end.

## Dispatch and run ownership

`New-FleetWorktree -PoolMode Auto` (the default) uses an initialized pool before
creating a cold worktree. It cold-falls back only when every slot is busy or
quarantined, and emits `pool_fallback_reason`; malformed or identity-mismatched
pool state fails closed. Legacy state is backfilled with `repo_path` from its
`git_common_dir`. A stale `provisioning` record is re-provisioned by Initialize
to `ready`, or quarantined if that proof fails. Cold worktrees write a sibling
`<worktree>.fleet-run.json` ownership sidecar; pool slots never do.
Pool-owned slots stay registered under the path scheme above; cleanup is sanitize +
release or quarantine — never delete.
