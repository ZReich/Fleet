# Grok wrapper pool-registration integration. Kept separate to avoid growing Invoke-Grok45.ps1.
function Initialize-GrokPoolRegistration {
  param(
    [Parameter(Mandatory)][string]$WorkingDirectory,
    [Parameter(Mandatory)][string]$ScriptRoot,
    [Parameter(Mandatory)][int]$WrapperProcessId
  )
  $poolHelperPaths = @(
    (Join-Path $ScriptRoot 'FleetWorktreePool.State.Helpers.ps1'),
    (Join-Path $ScriptRoot 'FleetWorktreePool.Liveness.Helpers.ps1'),
    (Join-Path $ScriptRoot 'FleetWorktreePool.Sanitize.Helpers.ps1')
  ); $poolProcScript = Join-Path $ScriptRoot 'Set-FleetWorktreePoolProcess.ps1'
  $poolMarkerPresent = $false
  try {
    $markerAncestor = [IO.Path]::GetFullPath($WorkingDirectory).TrimEnd([char]92)
    while (-not [string]::IsNullOrWhiteSpace($markerAncestor)) {
      if (Test-Path -LiteralPath (Join-Path $markerAncestor '.fleet-pool/pool.json') -PathType Leaf) { $poolMarkerPresent = $true; break }
      $markerParent = Split-Path -Parent $markerAncestor
      if ($markerParent -eq $markerAncestor) { break }
      $markerAncestor = $markerParent
    }
  } catch { }
  if ($poolMarkerPresent -and ((@($poolHelperPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -gt 0) -or (-not (Test-Path -LiteralPath $poolProcScript -PathType Leaf)))) {
    throw "Pool slot worker registration unavailable (fail closed): $WorkingDirectory"
  }
  if ((@($poolHelperPaths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq 0) -and (Test-Path -LiteralPath $poolProcScript -PathType Leaf)) {
    # Child scope so pool helpers cannot shadow wrapper functions.
    $poolProbe = & {
      param($hp, $wd, $probePid)
      foreach ($helperPath in @($hp)) { . $helperPath }
      $c = Resolve-FleetPoolSlotContext -WorkingDirectory $wd
      $underPool = $false
      try {
        # A marker, not only the worktrees root, identifies a live pool slot.
        $anc = [IO.Path]::GetFullPath($wd).TrimEnd([char]92)
        while (-not [string]::IsNullOrWhiteSpace($anc)) {
          if (Test-Path -LiteralPath (Join-Path $anc '.fleet-pool/pool.json') -PathType Leaf) { $underPool = $true; break }
          $parent = Split-Path -Parent $anc
          if ($parent -eq $anc) { break }
          $anc = $parent
        }
      } catch { $underPool = $false }
      $st = $null
      if ($null -ne $c -and -not [string]::IsNullOrWhiteSpace([string]$c.LeaseId)) { $st = Get-FleetPoolProcessStartUtc -ProcessId $probePid }
      [pscustomobject]@{ Ctx = $c; Start = $st; UnderPool = $underPool }
    } $poolHelperPaths $WorkingDirectory $WrapperProcessId
    $poolCtx = $poolProbe.Ctx
    if ($null -ne $poolCtx -and -not [string]::IsNullOrWhiteSpace([string]$poolCtx.LeaseId)) {
      $poolStartUtc = $poolProbe.Start
      if ([string]::IsNullOrWhiteSpace($poolStartUtc)) { throw "Pool slot worker registration failed: cannot resolve start time for PID $WrapperProcessId" }
      $regOut = & $poolProcScript -Action Register -Repo ([string]$poolCtx.RepoPath) -LeaseId ([string]$poolCtx.LeaseId) -ProcessId $WrapperProcessId -ProcessStartUtc $poolStartUtc -Mode json 2>&1
      if ($LASTEXITCODE -ne 0) { throw "Pool slot worker registration failed (fail closed): $regOut" }
      $poolReg = @{ Repo = [string]$poolCtx.RepoPath; Lease = [string]$poolCtx.LeaseId; Scr = $poolProcScript; Helpers = $poolHelperPaths; Rows = New-Object System.Collections.ArrayList }
      [void]$poolReg.Rows.Add(@{ ProcId = $WrapperProcessId; Start = $poolStartUtc })
      return $poolReg
    }
    if ($poolProbe.UnderPool -or $poolMarkerPresent) { throw "Working directory is under the worktree pool root but no pool slot context resolved (fail closed): $WorkingDirectory" }
  }
  return $null
}

function Register-GrokPoolWorkerRoot {
  param([hashtable]$PoolRegistration, [Parameter(Mandatory)][int]$WorkerProcessId)
  if ($null -eq $PoolRegistration) { return }
  try {
    $childStart = & { param($hp, $cpid) foreach ($helperPath in @($hp)) { . $helperPath }; Get-FleetPoolProcessStartUtc -ProcessId $cpid } $PoolRegistration.Helpers $WorkerProcessId
    if ([string]::IsNullOrWhiteSpace($childStart)) { throw "Pool slot worker-root registration failed: cannot resolve start time for PID $WorkerProcessId" }
    $regChild = & $PoolRegistration.Scr -Action Register -Repo $PoolRegistration.Repo -LeaseId $PoolRegistration.Lease -ProcessId $WorkerProcessId -ProcessStartUtc $childStart -Mode json 2>&1
    if ($LASTEXITCODE -eq 0) { [void]$PoolRegistration.Rows.Add(@{ ProcId = $WorkerProcessId; Start = $childStart }) }
    else { throw "Pool slot worker-root registration failed (fail closed): $regChild" }
  } catch { throw "Pool slot worker-root registration failed (fail closed): $($_.Exception.Message)" }
}

function Unregister-GrokPoolRegistration {
  param([hashtable]$PoolRegistration)
  if ($null -eq $PoolRegistration) { return }
  foreach ($row in @($PoolRegistration.Rows)) {
    try { $null = & $PoolRegistration.Scr -Action Unregister -Repo $PoolRegistration.Repo -LeaseId $PoolRegistration.Lease -ProcessId ([int]$row.ProcId) -ProcessStartUtc ([string]$row.Start) -Mode json 2>&1 } catch { }
  }
}
