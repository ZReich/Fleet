# Release a pool slot. Matching RunId+LeaseId required. Sole path to ready. Never recursive-deletes.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$RunId,
  [Parameter(Mandatory)][string]$LeaseId,
  [ValidateSet('json', 'text')][string]$Mode = 'json'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetWorktreePool.State.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Liveness.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Sanitize.Helpers.ps1')
$releaseTimer = [Diagnostics.Stopwatch]::StartNew()

function Write-Fail([string]$Message) { [Console]::Error.WriteLine($Message) }

try {
  if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'RunId is required.' }
  if ([string]::IsNullOrWhiteSpace($LeaseId)) { throw 'LeaseId is required.' }

  $ident = Resolve-FleetPoolRepoIdentity -Repo $Repo
  $statePath = Get-FleetPoolStatePath $ident.RepoKey

  $result = Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
    $st = Read-FleetPoolState -StatePath $statePath
    if ($null -eq $st) { throw "Pool state missing for $($ident.RepoKey)" }
    if ([string]$st.git_common_dir -ne $ident.CommonDir) {
      throw "Pool common-dir mismatch (state='$($st.git_common_dir)' repo='$($ident.CommonDir)')"
    }

    $target = $null
    foreach ($slot in @($st.slots)) {
      if ([string]$slot.lease_id -eq $LeaseId -and [string]$slot.run_id -eq $RunId) { $target = $slot; break }
    }
    if ($null -eq $target) {
      throw "No acquired slot matches RunId+LeaseId (wrong lease/run refused)"
    }
    # preparing is mid-Enter; concurrent Exit must never release/quarantine it.
    if ([string]$target.state -ne 'acquired') {
      throw "Slot $($target.id) not in releasable state: $($target.state)"
    }

    $spath = [string]$target.path
    $releaseBranch = [string]$target.branch
    $releaseBase = [string]$target.base_commit
    $registeredWorkers = @($target.processes).Count

    # Fail-closed gates before sanitize. Live registered worker: refuse without mutate
    # (caller can unregister/wait then Exit). Other failures quarantine (never ready).
    if (Test-FleetPoolRegisteredWorkersLive -Slot $target) {
      throw "Live registered worker blocks release of $($target.id)"
    }

    $cmdLive = $false
    try { $cmdLive = Test-FleetPoolSlotPathInLiveCommandLine -SlotPath $spath } catch { $cmdLive = $true }
    if ($cmdLive) {
      Set-FleetPoolQuarantine -Slot $target -Reason 'live_cmdline' -Evidence "command line references $spath"
      Write-FleetPoolState -StatePath $statePath -State $st
      return [ordered]@{
        ok = $false
        slot_id = [string]$target.id
        state = [string]$target.state
        path = $spath
        reason = [string]$target.quarantine_reason
        branch = $releaseBranch
        base_sha = $releaseBase
        registered_worker_count = $registeredWorkers
      }
    }

    $outcome = Invoke-FleetPoolSanitizeAndRelease -Slot $target -RepoPath $ident.RepoPath -ExpectedCommonDir $ident.CommonDir
    Write-FleetPoolState -StatePath $statePath -State $st
    return [ordered]@{
      ok = ($outcome -eq 'ready')
      slot_id = [string]$target.id
      state = [string]$target.state
      path = $spath
      reason = [string]$target.quarantine_reason
      branch = $releaseBranch
      base_sha = $releaseBase
      registered_worker_count = $registeredWorkers
    }
  }

  $releaseTimer.Stop()
  Write-FleetPoolEvent -Event @{
    event = 'pool_release'
    repo_id = $ident.RepoPath
    repo_key = $ident.RepoKey
    slot_id = [string]$result.slot_id
    run_id = $RunId
    state = [string]$result.state
    outcome = if ($result.ok) { 'ready' } else { 'quarantined' }
    reason = [string]$result.reason
    branch = [string]$result.branch
    base_sha = [string]$result.base_sha
    ownership = 'pool'
    duration_ms = [int]$releaseTimer.ElapsedMilliseconds
    registered_worker_count = [int]$result.registered_worker_count
    quarantine_reason = [string]$result.reason
  }

  if ($Mode -eq 'json') { Emit-FleetPoolJson $result }
  else { Emit-FleetPoolText ("exit: $($result.slot_id) | state: $($result.state) | path: $($result.path)") }
  if (-not $result.ok) { exit 1 }
  exit 0
} catch {
  Write-Fail $_.Exception.Message
  if ($Mode -eq 'json') { Emit-FleetPoolJson ([ordered]@{ ok = $false; error = $_.Exception.Message }) }
  exit 1
}
