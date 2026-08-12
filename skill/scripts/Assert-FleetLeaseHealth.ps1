# Gate: report stale Fleet run leases under run-leases/.
# Manager quotes the summary line:
#   leasehealth: N stale, M active (dir <LeaseDir>)
# Exit 1 when N > 0 unless -ReportOnly. Missing/empty dir = fail-open exit 0.
param(
  [string]$LeaseDir = "$env:USERPROFILE\.codex\fleet\run-leases",
  [int]$StaleHours = 3,
  [switch]$ReportOnly,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

function Get-LeaseHeartbeatUtc([object]$Lease, [IO.FileInfo]$File) {
  if ($null -ne $Lease -and $Lease.PSObject.Properties['heartbeat_at']) {
    $raw = [string]$Lease.heartbeat_at
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      try { return ([datetimeoffset]::Parse($raw.Trim(), [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
      catch { }
    }
  }
  return $File.LastWriteTimeUtc
}

function Get-LeaseRunId([object]$Lease, [IO.FileInfo]$File) {
  if ($null -ne $Lease -and $Lease.PSObject.Properties['run_id']) {
    $rid = [string]$Lease.run_id
    if (-not [string]::IsNullOrWhiteSpace($rid)) { return $rid.Trim() }
  }
  return [IO.Path]::GetFileNameWithoutExtension($File.Name)
}

# Writes report lines; sets $script:gateExit. Do not assign this function's output.
function Invoke-LeaseHealthCheck {
  param([string]$DirPath, [int]$Hours, [switch]$ReportOnlySwitch)
  $script:gateExit = 0
  $staleCount = 0
  $activeCount = 0
  $summary = { param($sn, $an, $d) Write-Output ("leasehealth: {0} stale, {1} active (dir {2})" -f $sn, $an, $d) }

  if ([string]::IsNullOrWhiteSpace($DirPath) -or -not (Test-Path -LiteralPath $DirPath -PathType Container)) {
    & $summary 0 0 $DirPath
    return
  }

  $files = @(Get-ChildItem -LiteralPath $DirPath -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($files.Count -eq 0) {
    & $summary 0 0 $DirPath
    return
  }

  $nowUtc = [datetime]::UtcNow
  $threshold = [timespan]::FromHours($Hours)
  foreach ($file in $files) {
    $lease = $null
    try {
      $raw = [IO.File]::ReadAllText($file.FullName)
      if (-not [string]::IsNullOrWhiteSpace($raw)) { $lease = $raw | ConvertFrom-Json -ErrorAction Stop }
    }
    catch { $lease = $null }

    $runId = Get-LeaseRunId $lease $file
    $hbUtc = Get-LeaseHeartbeatUtc $lease $file
    $age = $nowUtc - $hbUtc
    if ($age -lt [timespan]::Zero) { $age = [timespan]::Zero }

    if ($age -gt $threshold) {
      Write-Output ("STALE {0} {1}h" -f $runId, [math]::Round($age.TotalHours, 1))
      $staleCount++
    }
    else {
      Write-Output ("ACTIVE {0}" -f $runId)
      $activeCount++
    }
  }

  & $summary $staleCount $activeCount $DirPath
  if ($staleCount -gt 0 -and -not $ReportOnlySwitch) { $script:gateExit = 1 }
}

if ($SelfTest) {
  $fail = 0
  $dir = Join-Path $env:TEMP ("leasehealth-selftest-" + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $self = $PSCommandPath
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false

  function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Output ("PASS {0}" -f $name) }
    else { Write-Output ("FAIL {0}" -f $name); $script:fail++ }
  }
  function Write-LeaseJson([string]$Path, [string]$RunId, [datetimeoffset]$Heartbeat) {
    $doc = [ordered]@{ schema_version = '2'; run_id = $RunId; heartbeat_at = $Heartbeat.ToString('o') }
    [IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 4), $utf8NoBom)
  }
  function Invoke-Gate {
    param([string]$DirArg, [int]$HoursArg = 3, [switch]$AsReportOnly)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      if ($AsReportOnly) {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $self -LeaseDir $DirArg -StaleHours $HoursArg -ReportOnly 2>&1)
      }
      else {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $self -LeaseDir $DirArg -StaleHours $HoursArg 2>&1)
      }
      $code = 0
      if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
      return @{ ExitCode = $code; Text = (($lines | ForEach-Object { "$_" }) -join "`n") }
    }
    finally { $ErrorActionPreference = $oldEap }
  }

  try {
    $now = [datetimeoffset]::Now
    $freshPath = Join-Path $dir 'fresh-run.json'
    $stalePath = Join-Path $dir 'stale-run.json'
    Write-LeaseJson $freshPath 'fresh-run' $now
    Write-LeaseJson $stalePath 'stale-run' $now.AddHours(-12)
    (Get-Item -LiteralPath $stalePath).LastWriteTime = (Get-Date).AddHours(-12)

    $r1 = Invoke-Gate -DirArg $dir
    Check 'stale detected + exit 1' (
      ($r1.ExitCode -eq 1) -and ($r1.Text -match 'STALE stale-run') -and
      ($r1.Text -match 'ACTIVE fresh-run') -and ($r1.Text -match 'leasehealth: 1 stale, 1 active')
    )

    $r2 = Invoke-Gate -DirArg $dir -AsReportOnly
    Check 'ReportOnly exit 0 with stale present' (
      ($r2.ExitCode -eq 0) -and ($r2.Text -match 'STALE stale-run') -and
      ($r2.Text -match 'leasehealth: 1 stale, 1 active')
    )

    $freshDir = Join-Path $dir 'all-fresh'
    New-Item -ItemType Directory -Force -Path $freshDir | Out-Null
    Write-LeaseJson (Join-Path $freshDir 'a.json') 'run-a' $now
    Write-LeaseJson (Join-Path $freshDir 'b.json') 'run-b' $now
    $r3 = Invoke-Gate -DirArg $freshDir
    Check 'all-fresh 0 stale exit 0' (
      ($r3.ExitCode -eq 0) -and ($r3.Text -match 'ACTIVE run-a') -and
      ($r3.Text -match 'ACTIVE run-b') -and ($r3.Text -match 'leasehealth: 0 stale, 2 active')
    )

    $r4 = Invoke-Gate -DirArg (Join-Path $dir 'does-not-exist')
    Check 'missing dir fail-open exit 0' (
      ($r4.ExitCode -eq 0) -and ($r4.Text -match 'leasehealth: 0 stale, 0 active')
    )
  }
  finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($fail -eq 0) {
    Write-Output 'Test-AssertFleetLeaseHealth: passed (4 checks)'
    exit 0
  }
  Write-Output ("Test-AssertFleetLeaseHealth: FAILED ({0})" -f $fail)
  exit 1
}

$script:gateExit = 0
Invoke-LeaseHealthCheck -DirPath $LeaseDir -Hours $StaleHours -ReportOnlySwitch:$ReportOnly
exit $script:gateExit
