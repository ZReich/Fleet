# Test-only pool-state recovery used by the integration suite.
function Restore-FleetPoolReadySlots {
  param([string]$UserProfile)
  $pj = Find-FleetPoolJsonPath -UserProfile $UserProfile
  if ([string]::IsNullOrWhiteSpace($pj)) { return }
  $st = ([IO.File]::ReadAllText($pj) | ConvertFrom-Json)
  foreach ($s in @($st.slots)) {
    $sn = [string]$s.state
    if ($sn -eq 'ready' -or $sn -eq 'preparing' -or $sn -eq 'provisioning') { continue }
    $sp = [string]$s.path
    if (-not [string]::IsNullOrWhiteSpace($sp) -and (Test-Path -LiteralPath $sp)) {
      try { $null = @(& git -C $sp reset --hard HEAD 2>&1); $null = @(& git -C $sp clean -fd 2>&1) } catch { }
    }
    $s.state = 'ready'; $s.lease_id = $null; $s.run_id = $null; $s.owner_pid = $null; $s.owner_start_utc = $null
    $s.processes = @(); $s.quarantine_reason = $null; $s.quarantine_at = $null; $s.quarantine_evidence = $null
    try { $s.ever_registered = $false } catch { }
  }
  [IO.File]::WriteAllText($pj, ($st | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
}
