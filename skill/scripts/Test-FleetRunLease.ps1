param([switch]$ReclaimStale, [ValidateRange(1, 24)][int]$StaleHeartbeatHours = 2)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')

# Preflight: reclaim abandoned leases without starting a run.
if ($ReclaimStale) {
  $root = "$env:USERPROFILE\.codex\fleet\run-leases"
  $mutex = New-Object Threading.Mutex($false, 'FleetClaudePromotion')
  $reclaimed = @()
  try {
    if (-not $mutex.WaitOne(0)) { throw 'CLI promotion is active; lease reclaim refused.' }
    $now = [datetimeoffset]::Now
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      try { $lease = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      if (Test-FleetLeaseReclaimable $lease $now $StaleHeartbeatHours) {
        Remove-Item -LiteralPath $file.FullName -Force; $reclaimed += [string]$lease.run_id
      }
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
$passed = 0; $failed = 0
$utf8 = New-Object Text.UTF8Encoding($false)

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Body, [string]$Msg) {
  $threw = $false; try { & $Body } catch { $threw = $true }; Assert-True $threw $Msg
}
function LeaseRoot { $r = Join-Path $temp '.codex\fleet\run-leases'; New-Item -ItemType Directory -Force -Path $r | Out-Null; $r }
function Write-JsonFile([string]$Path, $Obj) { [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 4), $utf8) }
function Invoke-PsCapture([string]$Script, [string]$ScriptArgs, [switch]$CaptureErr) {
  # Never name a param $Args — collides with automatic $args in PS 5.1 and
  # silently drops the bound value (Enter/Renew get zero args; LiteralPath null).
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" ' + $ScriptArgs
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $temp
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  if ($CaptureErr) { return @{ Out = $out; Err = $err; Code = $p.ExitCode } }
  return $out
}
function Run-ExpectFail([string]$Script, [string]$ScriptArgs) {
  $cap = Invoke-PsCapture $Script $ScriptArgs -CaptureErr
  return @{ Code = $cap.Code; Err = ($cap.Out + $cap.Err) }
}

try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  $env:USERPROFILE = $temp

  Case 'run lease blocks promotion and preserves manifest' {
    $manifest = Join-Path $temp '.codex\fleet\approved-clis.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest) | Out-Null
    [IO.File]::WriteAllText($manifest, '{"sentinel":"unchanged"}')
    $before = [IO.File]::ReadAllBytes($manifest)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'lease-block-test' | Out-Null
    $r = Run-ExpectFail $approve "-CandidatePath `"$candidate`" -ManifestPath `"$manifest`""
    $after = [IO.File]::ReadAllBytes($manifest)
    Assert-True ($r.Code -ne 0) 'promotion was not blocked by live run lease'
    Assert-True ([Convert]::ToBase64String($before) -eq [Convert]::ToBase64String($after)) 'blocked promotion changed manifest bytes'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'lease-block-test'
  }

  Case 'promotion mutex blocks concurrent Fleet start' {
    $mutex = New-Object Threading.Mutex($false, 'FleetClaudePromotion')
    $held = $mutex.WaitOne(0)
    try {
      Assert-True $held 'test could not acquire promotion mutex'
      $r = Run-ExpectFail $enter '-RunId mutex-test'
      Assert-True ($r.Code -ne 0) 'Fleet start was not blocked by promotion mutex'
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
  }

  Case 'expired lease is pruned before new run' {
    $lr = LeaseRoot
    Write-JsonFile (Join-Path $lr 'expired.json') @{schema_version='1';run_id='expired';started_at=[datetimeoffset]::Now.AddHours(-2).ToString('o');expires_at=[datetimeoffset]::Now.AddHours(-1).ToString('o')}
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'fresh-test'
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath (Join-Path $lr 'expired.json'))) 'expired lease was not pruned'
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
    $lr = LeaseRoot
    # 999990 is never a live Windows PID (not multiple of 4).
    Write-JsonFile (Join-Path $lr 'deadpid.json') @{schema_version='1';run_id='deadpid';owner_pid=999990;started_at=[datetimeoffset]::Now.ToString('o');heartbeat_at=[datetimeoffset]::Now.ToString('o');expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')}
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'deadpid-fresh'
    Assert-True ($LASTEXITCODE -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $lr 'deadpid.json'))) 'dead-owner-PID lease was not reclaimed'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'deadpid-fresh'
  }

  Case 'stale heartbeat lease is reclaimed but a live lease survives' {
    $lr = LeaseRoot
    Write-JsonFile (Join-Path $lr 'staleheart.json') @{schema_version='1';run_id='staleheart';started_at=[datetimeoffset]::Now.AddHours(-3).ToString('o');heartbeat_at=[datetimeoffset]::Now.AddHours(-3).ToString('o');expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')}
    $live = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'live-keep'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'second-run'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $lr 'staleheart.json'))) 'stale-heartbeat lease was not reclaimed'
    Assert-True (Test-Path -LiteralPath $live) 'live lease was wrongly reclaimed'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'live-keep'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'second-run'
  }

  Case 'abandoned lease with future expiry does not block promotion' {
    $manifest = Join-Path $temp '.codex\fleet\approve-stale.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest) | Out-Null
    [IO.File]::WriteAllText($manifest, '{"sentinel":"unchanged"}')
    $abandoned = Join-Path (LeaseRoot) 'abandoned.json'
    Write-JsonFile $abandoned @{schema_version='1';run_id='abandoned';owner_pid=$null;started_at=[datetimeoffset]::Now.AddHours(-4).ToString('o');heartbeat_at=[datetimeoffset]::Now.AddHours(-4).ToString('o');expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')}
    $r = Run-ExpectFail $approve "-CandidatePath `"$candidate`" -ManifestPath `"$manifest`""
    Assert-True (-not (Test-Path -LiteralPath $abandoned)) 'abandoned lease was not pruned by the promotion gate'
    Assert-True ($r.Err -notmatch 'is active until') 'abandoned lease still refused promotion'
  }

  Case 'live lease still blocks promotion' {
    $manifest = Join-Path $temp '.codex\fleet\approve-live.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest) | Out-Null
    [IO.File]::WriteAllText($manifest, '{"sentinel":"unchanged"}')
    $livePath = Join-Path (LeaseRoot) 'live-block.json'
    Write-JsonFile $livePath @{schema_version='1';run_id='live-block';owner_pid=$null;started_at=[datetimeoffset]::Now.ToString('o');heartbeat_at=[datetimeoffset]::Now.ToString('o');expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')}
    $r = Run-ExpectFail $approve "-CandidatePath `"$candidate`" -ManifestPath `"$manifest`""
    Assert-True (Test-Path -LiteralPath $livePath) 'live lease was pruned by the promotion gate'
    Assert-True ($r.Err -match 'is active until') 'live lease did not refuse promotion'
    Remove-Item -LiteralPath $livePath -Force
  }

  Case 'owner_pid defaults to a numeric pid, not null' {
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'owner-pid-test'
    $lease = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $ownerPidVal = 0
    Assert-True ([int]::TryParse([string]$lease.owner_pid, [ref]$ownerPidVal) -and $ownerPidVal -gt 0) ('expected numeric owner_pid, got: ' + ($lease | ConvertTo-Json -Compress))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'owner-pid-test'
  }

  Case 'a live lease with the same RunId still throws (no silent reclaim)' {
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'live-same-id'
    Assert-True (Test-Path -LiteralPath $path) 'first enter for live-same-id did not create a lease'
    $r = Run-ExpectFail $enter '-RunId live-same-id'
    Assert-True ($r.Code -ne 0 -and $r.Err -match 'already exists') ('live lease with same RunId was not refused: ' + $r.Err)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'live-same-id'
  }

  Case 'expired-lease reclaim logs on stderr only; stdout stays a clean single lease path' {
    Write-JsonFile (Join-Path (LeaseRoot) 'reclaim-log-test.json') @{schema_version='1';run_id='reclaim-log-test';started_at=[datetimeoffset]::Now.AddHours(-2).ToString('o');expires_at=[datetimeoffset]::Now.AddHours(-1).ToString('o')}
    $cap = Invoke-PsCapture $enter '-RunId reclaim-log-fresh' -CaptureErr
    $stdoutLines = @($cap.Out -split "`r?`n" | Where-Object { $_ })
    Assert-True ($stdoutLines.Count -eq 1 -and (Test-Path -LiteralPath $stdoutLines[0])) ('expected exactly one stdout line (the lease path): ' + $cap.Out)
    Assert-True ($cap.Err -match 'reclaimed expired lease reclaim-log-test') ('expected reclaim log line on stderr: ' + $cap.Err)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'reclaim-log-fresh'
  }

  Case 'Renew-FleetRunLease refuses a missing lease with a clear error' {
    $r = Run-ExpectFail $renew '-RunId renew-never-existed'
    Assert-True ($r.Code -ne 0 -and $r.Err -match 'not found') ('renew of a missing lease was not refused: ' + $r.Err)
  }

  Case '-ReclaimStale prunes a dead lease without starting a run' {
    Write-JsonFile (Join-Path (LeaseRoot) 'orphan.json') @{schema_version='1';run_id='orphan';owner_pid=999990;started_at=[datetimeoffset]::Now.ToString('o');heartbeat_at=[datetimeoffset]::Now.ToString('o');expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')}
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -ReclaimStale | ConvertFrom-Json
    Assert-True (($out.reclaimed -contains 'orphan') -and -not (Test-Path -LiteralPath (Join-Path $temp '.codex\fleet\run-leases\orphan.json'))) 'ReclaimStale did not prune the orphaned lease'
  }

  # --- lease v2 HMAC key lifecycle ---
  Case 'hmac shape + outside-repo + Get-FleetRunLeaseKey' {
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'hmac-shape'
    $lease = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True ([string]$lease.schema_version -eq '2') 'schema_version not 2'
    Assert-True ([string]$lease.receipt_hmac_key_id -match '^[0-9a-f]{32}$') ('bad key_id: ' + $lease.receipt_hmac_key_id)
    $raw = [Convert]::FromBase64String([string]$lease.receipt_hmac_key_b64)
    Assert-True ($raw.Length -eq 32) ('secret not 32 bytes: ' + $raw.Length)
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Assert-True (-not $path.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) ('lease in repo: ' + $path)
    Assert-True ($path -like '*\.codex\fleet\run-leases\*') ('not under run-leases: ' + $path)
    $loaded = Get-FleetRunLeaseKey -RunId 'hmac-shape'
    Assert-True ($loaded.KeyId -eq [string]$lease.receipt_hmac_key_id -and $loaded.KeyBytes.Length -eq 32) 'Get-FleetRunLeaseKey mismatch'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'hmac-shape'
  }

  Case 'renew preserves key; secret never on enter/renew stdout' {
    $enterOut = Invoke-PsCapture $enter '-RunId hmac-renew'
    $path = ($enterOut -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
    $before = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $secret = [string]$before.receipt_hmac_key_b64; $keyId = [string]$before.receipt_hmac_key_id
    Assert-True ($enterOut -notlike ('*' + $secret + '*')) 'secret leaked on Enter stdout'
    $renewOut = Invoke-PsCapture $renew '-RunId hmac-renew -TtlHours 2'
    $after = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-True ([string]$after.receipt_hmac_key_b64 -eq $secret -and [string]$after.receipt_hmac_key_id -eq $keyId) 'renew rotated key'
    Assert-True ($renewOut -notlike ('*' + $secret + '*')) 'secret leaked on Renew stdout'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'hmac-renew'
  }

  Case 'reclaim/new lease rotates HMAC key' {
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'hmac-rotate'
    $old = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $past = [datetimeoffset]::Now.AddHours(-2).ToString('o')
    Write-JsonFile $path ([ordered]@{
      schema_version='2'; run_id='hmac-rotate'; owner_pid=999990
      started_at=$past; heartbeat_at=$past; expires_at=$past
      receipt_hmac_key_id=[string]$old.receipt_hmac_key_id
      receipt_hmac_key_b64=[string]$old.receipt_hmac_key_b64
    })
    $path2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'hmac-rotate'
    $neu = Get-Content -LiteralPath $path2 -Raw | ConvertFrom-Json
    Assert-True ([string]$neu.receipt_hmac_key_b64 -ne [string]$old.receipt_hmac_key_b64) 'reclaim reused secret'
    Assert-True ([string]$neu.receipt_hmac_key_id -ne [string]$old.receipt_hmac_key_id) 'reclaim reused key_id'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'hmac-rotate'
  }

  Case 'Get-FleetRunLeaseKey fails closed missing/expired/wrong-run/tampered' {
    Assert-Throws { Get-FleetRunLeaseKey -RunId 'hmac-never' } 'missing lease did not throw'
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'hmac-fc'
    $live = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $past = [datetimeoffset]::Now.AddHours(-1).ToString('o')
    Write-JsonFile $path ([ordered]@{
      schema_version='2'; run_id='hmac-fc'; owner_pid=$live.owner_pid
      started_at=[string]$live.started_at; heartbeat_at=$past; expires_at=$past
      receipt_hmac_key_id=[string]$live.receipt_hmac_key_id
      receipt_hmac_key_b64=[string]$live.receipt_hmac_key_b64
    })
    Assert-Throws { Get-FleetRunLeaseKey -RunId 'hmac-fc' } 'expired lease key load did not throw'
    $wrong = Join-Path (LeaseRoot) 'hmac-wrong.json'
    $nowS = [datetimeoffset]::Now.ToString('o')
    Write-JsonFile $wrong ([ordered]@{
      schema_version='2'; run_id='other-run'; owner_pid=$PID
      started_at=$nowS; heartbeat_at=$nowS; expires_at=[datetimeoffset]::Now.AddHours(20).ToString('o')
      receipt_hmac_key_id=('a' * 32); receipt_hmac_key_b64=[Convert]::ToBase64String((New-Object byte[] 32))
    })
    Assert-Throws { Get-FleetRunLeaseKey -RunId 'hmac-wrong' } 'wrong-run lease key load did not throw'
    $path2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'hmac-tamper'
    $t = Get-Content -LiteralPath $path2 -Raw | ConvertFrom-Json
    Write-JsonFile $path2 ([ordered]@{
      schema_version='2'; run_id='hmac-tamper'; owner_pid=$t.owner_pid
      started_at=[string]$t.started_at; heartbeat_at=[string]$t.heartbeat_at; expires_at=[string]$t.expires_at
      receipt_hmac_key_id=[string]$t.receipt_hmac_key_id
      receipt_hmac_key_b64=[Convert]::ToBase64String((New-Object byte[] 16))
    })
    Assert-Throws { Get-FleetRunLeaseKey -RunId 'hmac-tamper' } 'tampered non-32-byte secret did not throw'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'hmac-fc'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'hmac-wrong'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'hmac-tamper'
  }

  Case 'exit deletes lease and key' {
    $path = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $enter -RunId 'hmac-exit'
    Assert-True (Test-Path -LiteralPath $path) 'enter did not create lease'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'hmac-exit'
    Assert-True (-not (Test-Path -LiteralPath $path)) 'exit left lease/key on disk'
  }

  # --- L3 janitor owner-liveness reads (do not alter Enter reclaim semantics) ---
  Case 'Test-FleetOwnerConclusivelyDead: fresh HB live; dead+stale dead; invalid PID unknown' {
    $now = [datetimeoffset]::Now
    $freshDead = [pscustomobject]@{ owner_pid = 999990; heartbeat_at = $now.ToString('o') }
    Assert-True (-not (Test-FleetOwnerConclusivelyDead $freshDead $now 2)) 'dead PID + fresh HB must be LIVE'
    $staleLive = [pscustomobject]@{ owner_pid = $PID; heartbeat_at = $now.AddHours(-10).ToString('o') }
    Assert-True (-not (Test-FleetOwnerConclusivelyDead $staleLive $now 2)) 'stale HB + live PID must be LIVE'
    $staleDead = [pscustomobject]@{ owner_pid = 999990; heartbeat_at = $now.AddHours(-10).ToString('o') }
    Assert-True (Test-FleetOwnerConclusivelyDead $staleDead $now 2) 'dead PID + stale HB must be conclusive dead'
    $badPid = [pscustomobject]@{ owner_pid = 'nope'; heartbeat_at = $now.AddHours(-10).ToString('o') }
    Assert-True (-not (Test-FleetOwnerConclusivelyDead $badPid $now 2)) 'invalid PID must be LIVE/unknown'
    $zeroPid = [pscustomobject]@{ owner_pid = 0; heartbeat_at = $now.AddHours(-10).ToString('o') }
    Assert-True (-not (Test-FleetOwnerConclusivelyDead $zeroPid $now 2)) 'missing PID must be LIVE/unknown'
    $missingHbDead = [pscustomobject]@{ owner_pid = 999990 }
    Assert-True (-not (Test-FleetOwnerConclusivelyDead $missingHbDead $now 2)) 'missing heartbeat + dead PID must be LIVE/unknown'
    $invalidHbDead = [pscustomobject]@{ owner_pid = 999990; heartbeat_at = 'not-a-time' }
    Assert-True (-not (Test-FleetOwnerConclusivelyDead $invalidHbDead $now 2)) 'invalid heartbeat + dead PID must be LIVE/unknown'
    # Enter reclaim semantics unchanged: dead PID still reclaimable even with fresh HB.
    Assert-True (Test-FleetLeaseReclaimable $freshDead $now 2) 'Enter reclaim must still treat dead PID as reclaimable'
  }

  # --- T4 janitor wiring (stdout contract + post-mutex + crash isolation) ---
  Case 'enter still emits one lease path after janitor wire' {
    $cap = Invoke-PsCapture $enter '-RunId janitor-wire-stdout' -CaptureErr
    $stdoutLines = @($cap.Out -split "`r?`n" | Where-Object { $_ })
    Assert-True ($cap.Code -eq 0) ('enter exit ' + $cap.Code + ' err=' + $cap.Err)
    Assert-True ($stdoutLines.Count -eq 1 -and (Test-Path -LiteralPath $stdoutLines[0])) ('stdout not single lease path: ' + $cap.Out)
    Assert-True ($cap.Err -match 'fleet-lease-order: mutex-released') ('missing mutex-released: ' + $cap.Err)
    Assert-True ($cap.Err -match 'fleet-lease-order: janitor-begin') ('missing janitor-begin: ' + $cap.Err)
    $mi = $cap.Err.IndexOf('fleet-lease-order: mutex-released')
    $ji = $cap.Err.IndexOf('fleet-lease-order: janitor-begin')
    Assert-True ($mi -ge 0 -and $ji -ge 0 -and $mi -lt $ji) 'janitor ran before mutex release'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'janitor-wire-stdout'
  }

  Case 'janitor crash does not fail lease creation' {
    $env:FLEET_JANITOR_FORCE_FAIL = '1'
    try {
      $cap = Invoke-PsCapture $enter '-RunId janitor-wire-crash' -CaptureErr
      Assert-True ($cap.Code -eq 0) ('janitor crash failed enter: ' + $cap.Err)
      $stdoutLines = @($cap.Out -split "`r?`n" | Where-Object { $_ })
      Assert-True ($stdoutLines.Count -eq 1 -and (Test-Path -LiteralPath $stdoutLines[0])) 'crash spoiled lease stdout'
      Assert-True ($cap.Err -match 'janitor skipped|forced janitor failure') ('expected crash warn: ' + $cap.Err)
    } finally { Remove-Item Env:\FLEET_JANITOR_FORCE_FAIL -ErrorAction SilentlyContinue }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exit -RunId 'janitor-wire-crash'
  }
}
finally {
  $env:USERPROFILE = $oldProfile
  Remove-Item Env:\FLEET_JANITOR_FORCE_FAIL -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

$total = $passed + $failed
if ($failed) { Write-Host "selftest: FAIL $passed/$total"; exit 1 }
Write-Host "selftest: PASS $passed/$passed"
exit 0
