# Reap dead run-leases into quarantined only. NEVER releases to ready. Never deletes slots.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Repo,
  [ValidateSet('json', 'text')][string]$Mode = 'json'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetWorktreePool.State.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Liveness.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Sanitize.Helpers.ps1')
$reapTimer = [Diagnostics.Stopwatch]::StartNew()

function Write-Fail([string]$Message) { [Console]::Error.WriteLine($Message) }

try {
  $ident = Resolve-FleetPoolRepoIdentity -Repo $Repo
  $statePath = Get-FleetPoolStatePath $ident.RepoKey

  $summary = Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
    $st = Read-FleetPoolState -StatePath $statePath
    if ($null -eq $st) {
      return [ordered]@{ ok = $true; reaped = 0; quarantined = 0; untouched = 0; note = 'no pool state' }
    }
    if ([string]$st.git_common_dir -ne $ident.CommonDir) {
      return [ordered]@{ ok = $false; error = "common-dir mismatch"; reaped = 0; quarantined = 0; untouched = @($st.slots).Count }
    }

    $reaped = 0; $quarantined = 0; $untouched = 0
    $actions = New-Object System.Collections.ArrayList
    foreach ($slot in @($st.slots)) {
      $stName = [string]$slot.state
      $spath = [string]$slot.path

      # Live anything => leave untouched (never reclaim under live worker/cmdline).
      $liveWorker = Test-FleetPoolRegisteredWorkersLive -Slot $slot
      $liveOwner = Test-FleetPoolOwnerLive -Slot $slot
      $liveCmd = $false
      if (-not [string]::IsNullOrWhiteSpace($spath)) {
        try { $liveCmd = Test-FleetPoolSlotPathInLiveCommandLine -SlotPath $spath } catch { $liveCmd = $true }
      }

      if ($stName -eq 'acquired') {
        if ($liveWorker -or $liveOwner -or $liveCmd) {
          $untouched++
          $why = if ($liveWorker) { 'live_registered_worker' } elseif ($liveOwner) { 'live_owner' } else { 'live_cmdline' }
          [void]$actions.Add([ordered]@{ id = [string]$slot.id; action = 'untouched'; reason = $why })
          continue
        }
        # Dead run-lease: quarantine only (never sanitize, never ready).
        Set-FleetPoolQuarantine -Slot $slot -Reason 'orphan-dead-lease' -Evidence 'acquired with dead lease/owner and no live cmdline'
        $quarantined++
        [void]$actions.Add([ordered]@{ id = [string]$slot.id; action = 'quarantined'; reason = [string]$slot.quarantine_reason })
        continue
      }

      if ($stName -eq 'provisioning' -or $stName -eq 'preparing') {
        $hasLease = -not [string]::IsNullOrWhiteSpace([string]$slot.lease_id)
        $ownPid = 0; try { if ($null -ne $slot.owner_pid) { $ownPid = [int]$slot.owner_pid } } catch { }
        $hasOwn = ($ownPid -gt 0)
        if (-not $hasLease -and -not $hasOwn) {
          $untouched++
          continue
        }
        if ($liveWorker -or $liveOwner -or $liveCmd) {
          $untouched++
          [void]$actions.Add([ordered]@{ id = [string]$slot.id; action = 'untouched'; reason = 'live_while_' + $stName })
          continue
        }
        Set-FleetPoolQuarantine -Slot $slot -Reason 'orphan-stuck' -Evidence ("$stName with dead lease")
        $quarantined++
        [void]$actions.Add([ordered]@{ id = [string]$slot.id; action = 'quarantined'; reason = [string]$slot.quarantine_reason })
        continue
      }

      $untouched++
    }
    Write-FleetPoolState -StatePath $statePath -State $st
    return [ordered]@{
      ok = $true
      reaped = $reaped
      quarantined = $quarantined
      untouched = $untouched
      actions = @($actions)
      note = 'reap never releases to ready; never deletes'
    }
  }

  Write-FleetPoolEvent -Event @{
    event = 'pool_reap'
    repo_id = $ident.RepoPath
    repo_key = $ident.RepoKey
    reaped = [int]$summary.reaped
    quarantined = [int]$summary.quarantined
    outcome = 'ok'
    reason = 'reap'
    ownership = 'pool'
    duration_ms = [int]$reapTimer.ElapsedMilliseconds
  }

  if ($Mode -eq 'json') { Emit-FleetPoolJson $summary }
  else {
    Emit-FleetPoolText ("reap: reaped=$($summary.reaped) quarantined=$($summary.quarantined) untouched=$($summary.untouched)")
  }
  if ($summary.ok -eq $false) { exit 1 }
  exit 0
} catch {
  Write-Fail $_.Exception.Message
  if ($Mode -eq 'json') { Emit-FleetPoolJson ([ordered]@{ ok = $false; error = $_.Exception.Message }) }
  exit 1
}
