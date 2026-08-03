param([switch]$ReclaimStale, [ValidateRange(1, 24)][int]$StaleHeartbeatHours = 2)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')

# Preflight action: reclaim abandoned leases (dead owner PID or stale heartbeat) WITHOUT
# starting a run, then return. Uses the promotion mutex so it cannot race a promotion.
if ($ReclaimStale) {
  $root = "$env:USERPROFILE\.codex\fleet\run-leases"
  $mutex = New-Object Threading.Mutex($false, 'FleetClaudePromotion')
  $reclaimed = @()
  try {
    if (-not $mutex.WaitOne(0)) { throw 'CLI promotion is active; lease reclaim refused.' }
    $now = [datetimeoffset]::Now
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      try { $lease = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      if (Test-FleetLeaseReclaimable $lease $now $StaleHeartbeatHours) { Remove-Item -LiteralPath $file.FullName -Force; $reclaimed += [string]$lease.run_id }
    }
  }
  finally { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
  Write-Output (@{ reclaimed = $reclaimed } | ConvertTo-Json -Compress)
  return
}

$enter = Join-Path $PSScriptRoot 'Enter-FleetRunLease.ps1'
$exit = Join-Path $PSScriptRoot 'Exit-FleetRunLease.ps1'
$renew = Join-Path $PSScriptRoot 'Renew-FleetRunLease.ps1'
$approve = Join-Path $PSScriptRoot 'Approve-ClaudeCli.ps1'
$candidate = '$env:USERPROFILE\AppData\Local\nvm\v22.22.2\claude.cmd'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-lease-test-' + [guid]::NewGuid().ToString('n'))
$oldProfile = $env:USERPROFILE
$passed = 0
$failed = 0

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  $env:USERPROFILE = $temp

  Case 'run lease blocks promotion and preserves manifest' {
    $manifest = Join-Path $temp '.codex\fleet\approved-clis.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest) | Out-Null
    [IO.File]::WriteAllText($manifest, '{"sentinel":"unchanged"}')
    $before = [IO.File]::ReadAllBytes($manifest)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'lease-block-test' | Out-Null
    $oldPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $approve -CandidatePath $candidate -ManifestPath $manifest 2>$null | Out-Null
      $approveExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    $after = [IO.File]::ReadAllBytes($manifest)
    Assert-True ($approveExit -ne 0) 'promotion was not blocked by live run lease'
    Assert-True ([Convert]::ToBase64String($before) -eq [Convert]::ToBase64String($after)) 'blocked promotion changed manifest bytes'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'lease-block-test'
  }

  Case 'promotion mutex blocks concurrent Fleet start' {
    $mutex = New-Object Threading.Mutex($false, 'FleetClaudePromotion')
    $held = $mutex.WaitOne(0)
    try {
      Assert-True $held 'test could not acquire promotion mutex'
      $oldPreference = $ErrorActionPreference
      try {
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'mutex-test' 2>$null | Out-Null
        $enterExit = $LASTEXITCODE
      }
      finally { $ErrorActionPreference = $oldPreference }
      Assert-True ($enterExit -ne 0) 'Fleet start was not blocked by promotion mutex'
    }
    finally {
      if ($held) { $mutex.ReleaseMutex() }
      $mutex.Dispose()
    }
  }

  Case 'expired lease is pruned before new run' {
    $leaseRoot = Join-Path $temp '.codex\fleet\run-leases'; New-Item -ItemType Directory -Force -Path $leaseRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $leaseRoot 'expired.json'), (@{schema_version='1';run_id='expired';started_at=[datetimeoffset]::Now.AddHours(-2).ToString('o');expires_at=[datetimeoffset]::Now.AddHours(-1).ToString('o')} | ConvertTo-Json))
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'fresh-test'
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath (Join-Path $leaseRoot 'expired.json'))) 'expired lease was not pruned'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'fresh-test'
  }

  Case 'active run heartbeat renews lease expiry' {
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'renew-test' -TtlHours 1
    $before = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $renew -RunId 'renew-test' -TtlHours 2
    $after = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True ([datetimeoffset]$after.heartbeat_at -ge [datetimeoffset]$before.heartbeat_at -and [datetimeoffset]$after.expires_at -gt [datetimeoffset]$before.expires_at) 'lease heartbeat did not extend expiry'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'renew-test'
  }

  Case 'dead owner PID lease is reclaimed despite fresh expiry' {
    $leaseRoot = Join-Path $temp '.codex\fleet\run-leases'; New-Item -ItemType Directory -Force -Path $leaseRoot | Out-Null
    # 999990 is not a multiple of 4, so it can never be a live Windows PID.
    [IO.File]::WriteAllText((Join-Path $leaseRoot 'deadpid.json'), (@{schema_version='1';run_id='deadpid';owner_pid=999990;started_at=[datetimeoffset]::Now.ToString('o');heartbeat_at=[datetimeoffset]::Now.ToString('o');expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')} | ConvertTo-Json))
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'deadpid-fresh'
    Assert-True ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $leaseRoot 'deadpid.json'))) 'dead-owner-PID lease was not reclaimed'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'deadpid-fresh'
  }

  Case 'stale heartbeat lease is reclaimed but a live lease survives' {
    $leaseRoot = Join-Path $temp '.codex\fleet\run-leases'; New-Item -ItemType Directory -Force -Path $leaseRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $leaseRoot 'staleheart.json'), (@{schema_version='1';run_id='staleheart';started_at=[datetimeoffset]::Now.AddHours(-3).ToString('o');heartbeat_at=[datetimeoffset]::Now.AddHours(-3).ToString('o');expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')} | ConvertTo-Json))
    $live = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'live-keep'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'second-run'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $leaseRoot 'staleheart.json'))) 'stale-heartbeat lease was not reclaimed'
    Assert-True (Test-Path -LiteralPath $live) 'live lease was wrongly reclaimed'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'live-keep'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'second-run'
  }

  Case 'abandoned lease with future expiry does not block promotion' {
    # Regression: the promotion gate tested expires_at ALONE, so a run abandoned minutes
    # in (heartbeat stale, TTL still 20h out) was reclaimable by Enter yet still refused
    # every CLI promotion until the TTL ran out. Both sides now share one predicate.
    $manifest = Join-Path $temp '.codex\fleet\approve-stale.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest) | Out-Null
    [IO.File]::WriteAllText($manifest, '{"sentinel":"unchanged"}')
    $leaseRoot = Join-Path $temp '.codex\fleet\run-leases'; New-Item -ItemType Directory -Force -Path $leaseRoot | Out-Null
    $abandoned = Join-Path $leaseRoot 'abandoned.json'
    [IO.File]::WriteAllText($abandoned, (@{schema_version='1';run_id='abandoned';owner_pid=$null;started_at=[datetimeoffset]::Now.AddHours(-4).ToString('o');heartbeat_at=[datetimeoffset]::Now.AddHours(-4).ToString('o');expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')} | ConvertTo-Json))
    $oldPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $approveErr = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $approve -CandidatePath $candidate -ManifestPath $manifest 2>&1 | Out-String)
    }
    finally { $ErrorActionPreference = $oldPreference }
    # The gate throws at the lease check BEFORE pruning, so a pruned file proves it passed.
    Assert-True (-not (Test-Path -LiteralPath $abandoned)) 'abandoned lease was not pruned by the promotion gate'
    Assert-True ($approveErr -notmatch 'is active until') 'abandoned lease still refused promotion'
  }

  Case 'live lease still blocks promotion' {
    $manifest = Join-Path $temp '.codex\fleet\approve-live.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest) | Out-Null
    [IO.File]::WriteAllText($manifest, '{"sentinel":"unchanged"}')
    $leaseRoot = Join-Path $temp '.codex\fleet\run-leases'; New-Item -ItemType Directory -Force -Path $leaseRoot | Out-Null
    $livePath = Join-Path $leaseRoot 'live-block.json'
    [IO.File]::WriteAllText($livePath, (@{schema_version='1';run_id='live-block';owner_pid=$null;started_at=[datetimeoffset]::Now.ToString('o');heartbeat_at=[datetimeoffset]::Now.ToString('o');expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')} | ConvertTo-Json))
    $oldPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $approveErr = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $approve -CandidatePath $candidate -ManifestPath $manifest 2>&1 | Out-String)
    }
    finally { $ErrorActionPreference = $oldPreference }
    Assert-True (Test-Path -LiteralPath $livePath) 'live lease was pruned by the promotion gate'
    Assert-True ($approveErr -match 'is active until') 'live lease did not refuse promotion'
    Remove-Item -LiteralPath $livePath -Force
  }

  Case 'owner_pid defaults to a numeric pid, not null' {
    # Audit fix 2026-08-03: every lease on disk had owner_pid:null because no caller
    # ever passed -OwnerPid. Enter now defaults it to the parent (caller) process.
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'owner-pid-test'
    $lease = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $ownerPidVal = 0
    Assert-True ([int]::TryParse([string]$lease.owner_pid, [ref]$ownerPidVal) -and $ownerPidVal -gt 0) ('expected numeric owner_pid, got: ' + ($lease | ConvertTo-Json -Compress))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'owner-pid-test'
  }

  Case 'a live lease with the same RunId still throws (no silent reclaim)' {
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'live-same-id'
    Assert-True (Test-Path -LiteralPath $path) 'first enter for live-same-id did not create a lease'
    $oldPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $err2 = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'live-same-id' 2>&1 | Out-String)
      $exit2 = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    Assert-True ($exit2 -ne 0 -and $err2 -match 'already exists') ('live lease with same RunId was not refused: ' + $err2)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'live-same-id'
  }

  Case 'expired-lease reclaim logs on stderr only; stdout stays a clean single lease path' {
    # Fix 2026-08-03: the reclaim log line must never land in stdout - callers capture
    # this script's stdout as the single lease-path return value.
    $leaseRoot = Join-Path $temp '.codex\fleet\run-leases'; New-Item -ItemType Directory -Force -Path $leaseRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $leaseRoot 'reclaim-log-test.json'), (@{schema_version='1';run_id='reclaim-log-test';started_at=[datetimeoffset]::Now.AddHours(-2).ToString('o');expires_at=[datetimeoffset]::Now.AddHours(-1).ToString('o')} | ConvertTo-Json))
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $enter + '" -RunId reclaim-log-fresh'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $stdoutLines = @($stdout -split "`r?`n" | Where-Object { $_ })
    Assert-True ($stdoutLines.Count -eq 1 -and (Test-Path -LiteralPath $stdoutLines[0])) ('expected exactly one stdout line (the lease path): ' + $stdout)
    Assert-True ($stderr -match 'reclaimed expired lease reclaim-log-test') ('expected reclaim log line on stderr: ' + $stderr)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'reclaim-log-fresh'
  }

  Case 'Renew-FleetRunLease refuses a missing lease with a clear error' {
    $oldPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $err3 = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $renew -RunId 'renew-never-existed' 2>&1 | Out-String)
      $exit3 = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    Assert-True ($exit3 -ne 0 -and $err3 -match 'not found') ('renew of a missing lease was not refused: ' + $err3)
  }

  Case '-ReclaimStale prunes a dead lease without starting a run' {
    $leaseRoot = Join-Path $temp '.codex\fleet\run-leases'; New-Item -ItemType Directory -Force -Path $leaseRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $leaseRoot 'orphan.json'), (@{schema_version='1';run_id='orphan';owner_pid=999990;started_at=[datetimeoffset]::Now.ToString('o');heartbeat_at=[datetimeoffset]::Now.ToString('o');expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')} | ConvertTo-Json))
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ReclaimStale | ConvertFrom-Json
    Assert-True (($out.reclaimed -contains 'orphan') -and -not (Test-Path -LiteralPath (Join-Path $leaseRoot 'orphan.json'))) 'ReclaimStale did not prune the orphaned lease'
  }
}
finally {
  $env:USERPROFILE = $oldProfile
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
