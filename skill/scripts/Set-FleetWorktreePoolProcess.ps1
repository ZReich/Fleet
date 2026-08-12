# Register or unregister a (PID, start-time) worker pair on a pool lease.
# Multiple rows per lease supported; Unregister removes only the matching row.
# ever_registered is sticky until Clear-FleetPoolSlotOwnership / Set-FleetPoolQuarantine.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Register', 'Unregister')][string]$Action,
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$LeaseId,
  [Parameter(Mandatory)][int]$ProcessId,
  [Parameter(Mandatory)][string]$ProcessStartUtc,
  [ValidateSet('json', 'text')][string]$Mode = 'json'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetWorktreePool.State.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Liveness.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetWorktreePool.Sanitize.Helpers.ps1')

function Write-Fail([string]$Message) { [Console]::Error.WriteLine($Message) }

try {
  if ([string]::IsNullOrWhiteSpace($LeaseId)) { throw 'LeaseId is required.' }
  if ($ProcessId -le 0) { throw 'ProcessId must be positive.' }
  if ([string]::IsNullOrWhiteSpace($ProcessStartUtc)) { throw 'ProcessStartUtc is required.' }

  $ident = Resolve-FleetPoolRepoIdentity -Repo $Repo
  $statePath = Get-FleetPoolStatePath $ident.RepoKey
  $actionName = $Action
  $leaseWant = $LeaseId
  $pidWant = $ProcessId
  $startWant = $ProcessStartUtc

  $result = Invoke-FleetPoolWithMutex -RepoKey $ident.RepoKey -Body {
    $st = Read-FleetPoolState -StatePath $statePath
    if ($null -eq $st) { throw "Pool state missing for $($ident.RepoKey)" }
    if ([string]$st.git_common_dir -ne $ident.CommonDir) {
      throw "Pool common-dir mismatch (state='$($st.git_common_dir)' repo='$($ident.CommonDir)')"
    }

    $target = $null
    foreach ($slot in @($st.slots)) {
      if ([string]$slot.lease_id -eq $leaseWant) { $target = $slot; break }
    }
    if ($null -eq $target) {
      throw "No pool slot holds lease_id (fail closed): $leaseWant"
    }

    $procs = New-Object System.Collections.ArrayList
    foreach ($row in @($target.processes)) {
      if ($null -eq $row) { continue }
      $rowPid = 0; try { $rowPid = [int]$row.pid } catch { continue }
      $rowStart = [string]$row.start_utc
      if ($actionName -eq 'Unregister' -and $rowPid -eq $pidWant -and $rowStart -eq $startWant) { continue }
      [void]$procs.Add([pscustomobject]@{ pid = $rowPid; start_utc = $rowStart })
    }
    if ($actionName -eq 'Register') {
      $already = $false
      foreach ($row in @($procs)) {
        if ([int]$row.pid -eq $pidWant -and [string]$row.start_utc -eq $startWant) { $already = $true; break }
      }
      if (-not $already) {
        [void]$procs.Add([pscustomobject]@{ pid = $pidWant; start_utc = $startWant })
      }
      # Sticky: first Register marks ever_registered (cleared only by ownership clear/quarantine).
      $target.ever_registered = $true
    }
    # Force real array even for 0/1 elements (ConvertTo-Json scalar footgun).
    $target.processes = @($procs.ToArray())
    Write-FleetPoolState -StatePath $statePath -State $st
    return [pscustomobject]@{
      ok = $true
      action = $actionName
      slot_id = [string]$target.id
      process_id = $pidWant
      process_count = $procs.Count
      ever_registered = [bool]$target.ever_registered
    }
  }

  if ($Mode -eq 'json') { Emit-FleetPoolJson $result }
  else { Emit-FleetPoolText ("process: $Action | slot: $($result.slot_id) | pid: $ProcessId | count: $($result.process_count)") }
  exit 0
} catch {
  Write-Fail $_.Exception.Message
  if ($Mode -eq 'json') {
    Emit-FleetPoolJson ([ordered]@{ ok = $false; error = $_.Exception.Message })
  }
  exit 1
}
