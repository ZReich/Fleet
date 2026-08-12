# Deterministic CLI pin-drift gate for Fleet runs.
# Reads approved-clis.json, runs each pinned CLI --version, compares to the pin.
# Manager quotes the summary line:
#   clipins: N drifted, M unpinned (pins <stamp>)
# Exit 1 when N > 0 (unless -ReportOnly). Unpinned targets never fail the gate.
# IO fail-open: missing/unreadable/unparseable approved-clis -> treat all as unpinned, exit 0.
param(
  [string]$ApprovedClis = "$env:USERPROFILE\.codex\fleet\approved-clis.json",
  [switch]$ReportOnly,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

# First complete SemVer in text: optional leading v; keep prerelease/build suffixes.
function Get-FirstSemVer([string]$Text) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $m = [regex]::Match($Text, 'v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)')
  if (-not $m.Success) { return $null }
  return $m.Groups[1].Value
}

# Run path --version; STDOUT only. Returns @{ Ok; ExitCode; StdOut; Installed }.
function Get-CliVersion([string]$ExePath) {
  $result = @{ Ok = $false; ExitCode = -1; StdOut = ''; Installed = $null }
  if ([string]::IsNullOrWhiteSpace($ExePath)) { return $result }
  if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { return $result }
  $oldEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    # Bind call output first so $LASTEXITCODE is native-command exit (ps51 footgun).
    $lines = @(& $ExePath '--version' 2>$null)
    $code = 0
    if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
    $stdout = ($lines | Out-String).Trim()
    $result.ExitCode = $code
    $result.StdOut = $stdout
    if ($code -ne 0) { return $result }
    $ver = Get-FirstSemVer $stdout
    if ($null -eq $ver) { return $result }
    $result.Installed = $ver
    $result.Ok = $true
    return $result
  }
  catch {
    return $result
  }
  finally { $ErrorActionPreference = $oldEap }
}

# BOM-tolerant text read (UTF-8 with/without BOM).
function Read-TextBomTolerant([string]$Path) {
  $sr = New-Object IO.StreamReader($Path, $true)
  try { return $sr.ReadToEnd() }
  finally { $sr.Dispose() }
}

# Writes report lines to pipeline; sets $script:gateExit (do NOT assign this function's
# output -- assignment would swallow Write-Output lines).
function Invoke-CliPinsCheck {
  param(
    [string]$ManifestPath,
    [switch]$ReportOnlySwitch
  )
  $script:gateExit = 0
  $driftCount = 0
  $unpinnedCount = 0
  $stamp = 'unknown'
  $clisObj = $null

  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    Write-Output ("WARNING approved-clis missing: {0}" -f $ManifestPath)
  }
  else {
    # File exists: default stamp to mtime; override with checked_at when parse succeeds.
    $stamp = (Get-Item -LiteralPath $ManifestPath).LastWriteTimeUtc.ToString('o')
    try {
      $raw = Read-TextBomTolerant $ManifestPath
      $doc = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($null -eq $doc -or $null -eq $doc.clis) {
        Write-Output ("WARNING approved-clis unparseable (no .clis): {0}" -f $ManifestPath)
      }
      else {
        $clisObj = $doc.clis
        $checkedAt = $null
        if ($doc.PSObject.Properties['checked_at']) { $checkedAt = [string]$doc.checked_at }
        if (-not [string]::IsNullOrWhiteSpace($checkedAt)) {
          $stamp = $checkedAt.Trim()
        }
      }
    }
    catch {
      Write-Output ("WARNING approved-clis unreadable/unparseable: {0}" -f $ManifestPath)
    }
  }

  # Sorted union of .clis keys + always-known targets.
  $nameSet = New-Object System.Collections.Generic.HashSet[string]
  foreach ($kn in @('claude', 'codex', 'grok')) { [void]$nameSet.Add($kn) }
  if ($null -ne $clisObj) {
    foreach ($prop in $clisObj.PSObject.Properties) {
      if (-not [string]::IsNullOrWhiteSpace($prop.Name)) { [void]$nameSet.Add([string]$prop.Name) }
    }
  }
  $targets = @($nameSet | Sort-Object)

  foreach ($cliName in $targets) {
    $entry = $null
    if ($null -ne $clisObj -and $clisObj.PSObject.Properties[$cliName]) {
      $entry = $clisObj.PSObject.Properties[$cliName].Value
    }
    if ($null -eq $entry) {
      Write-Output ("SKIP {0}: unpinned" -f $cliName)
      $unpinnedCount++
      continue
    }
    $pinVer = $null
    $pinPath = $null
    if ($entry.PSObject.Properties['version']) { $pinVer = [string]$entry.version }
    if ($entry.PSObject.Properties['path']) { $pinPath = [string]$entry.path }
    if ([string]::IsNullOrWhiteSpace($pinPath)) {
      Write-Output ("DRIFT {0}: pinned={1} installed=missing-path" -f $cliName, $pinVer)
      $driftCount++
      continue
    }
    $probe = Get-CliVersion $pinPath
    if (-not $probe.Ok) {
      $shown = 'error'
      if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) { $shown = 'missing-path' }
      elseif ($probe.ExitCode -ne 0) { $shown = ("exit-{0}" -f $probe.ExitCode) }
      elseif ([string]::IsNullOrWhiteSpace($probe.StdOut)) { $shown = 'no-stdout' }
      else { $shown = 'no-semver' }
      Write-Output ("DRIFT {0}: pinned={1} installed={2}" -f $cliName, $pinVer, $shown)
      $driftCount++
      continue
    }
    if ($probe.Installed -ne $pinVer) {
      Write-Output ("DRIFT {0}: pinned={1} installed={2}" -f $cliName, $pinVer, $probe.Installed)
      $driftCount++
      continue
    }
    Write-Output ("OK {0}: {1}" -f $cliName, $probe.Installed)
  }

  Write-Output ("clipins: {0} drifted, {1} unpinned (pins {2})" -f $driftCount, $unpinnedCount, $stamp)
  if ($driftCount -gt 0 -and -not $ReportOnlySwitch) { $script:gateExit = 1 }
}

if ($SelfTest) {
  $fail = 0
  $dir = Join-Path $env:TEMP ("clipins-selftest-" + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $self = $PSCommandPath
  $utf8Bom = New-Object System.Text.UTF8Encoding $true
  function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Output ("PASS {0}" -f $name) }
    else { Write-Output ("FAIL {0}" -f $name); $script:fail++ }
  }
  function Write-Manifest([string]$Path, [hashtable]$Clis, [string]$CheckedAt) {
    $clisOrdered = [ordered]@{}
    foreach ($k in @($Clis.Keys | Sort-Object)) {
      $clisOrdered[$k] = [ordered]@{ path = [string]$Clis[$k].path; version = [string]$Clis[$k].version }
    }
    $doc = [ordered]@{ schema_version = '1'; checked_at = $CheckedAt; clis = $clisOrdered }
    [IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 6), $utf8Bom)
  }
  function Invoke-Gate([string]$Manifest, [switch]$AsReportOnly) {
    # Call operator (not Start-Process ArgumentList) so paths with spaces stay intact.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      if ($AsReportOnly) {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $self -ApprovedClis $Manifest -ReportOnly 2>&1)
      }
      else {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $self -ApprovedClis $Manifest 2>&1)
      }
      $code = 0
      if ($null -ne $LASTEXITCODE) { $code = [int]$LASTEXITCODE }
      $text = ($lines | ForEach-Object { "$_" }) -join "`n"
      return @{ ExitCode = $code; Text = $text }
    }
    finally { $ErrorActionPreference = $oldEap }
  }
  try {
    $fakeCli = Join-Path $dir 'toolx.cmd'
    Set-Content -LiteralPath $fakeCli -Encoding ASCII -Value "@echo off`r`necho toolx 1.2.3`r`n"
    $stamp = '2026-01-01T00:00:00Z'

    # (1) matching version passes
    $m1 = Join-Path $dir 'match.json'
    Write-Manifest $m1 @{ toolx = @{ path = $fakeCli; version = '1.2.3' } } $stamp
    $r1 = Invoke-Gate $m1
    Check 'matching version passes (exit 0, 0 drifted)' (
      ($r1.ExitCode -eq 0) -and ($r1.Text -match 'OK toolx: 1\.2\.3') -and ($r1.Text -match 'clipins: 0 drifted,')
    )

    # (2) version mismatch -> DRIFT + exit 1; -ReportOnly exit 0
    $m2 = Join-Path $dir 'mismatch.json'
    Write-Manifest $m2 @{ toolx = @{ path = $fakeCli; version = '9.9.9' } } $stamp
    $r2 = Invoke-Gate $m2
    $r2r = Invoke-Gate $m2 -AsReportOnly
    Check 'version mismatch DRIFT + exit 1; ReportOnly exit 0' (
      ($r2.Text -match 'DRIFT toolx:') -and ($r2.ExitCode -eq 1) -and ($r2r.ExitCode -eq 0) -and ($r2r.Text -match 'DRIFT toolx:')
    )

    # (3) unpinned target -> SKIP, increments M, no failure
    $m3 = Join-Path $dir 'unpinned.json'
    Write-Manifest $m3 @{ toolx = @{ path = $fakeCli; version = '1.2.3' } } $stamp
    $r3 = Invoke-Gate $m3
    Check 'unpinned target SKIP increments M, exit 0' (
      ($r3.Text -match 'SKIP grok: unpinned') -and ($r3.Text -match 'clipins: 0 drifted, [1-9]\d* unpinned') -and ($r3.ExitCode -eq 0)
    )

    # (4) missing executable path -> DRIFT + exit 1
    $m4 = Join-Path $dir 'missing.json'
    $gone = Join-Path $dir 'does-not-exist.cmd'
    Write-Manifest $m4 @{ toolx = @{ path = $gone; version = '1.2.3' } } $stamp
    $r4 = Invoke-Gate $m4
    Check 'missing executable path DRIFT + exit 1' (
      ($r4.Text -match 'DRIFT toolx:') -and ($r4.ExitCode -eq 1)
    )
  }
  finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($fail -eq 0) {
    Write-Output 'Test-AssertFleetCliPins: passed (4 checks)'
    exit 0
  }
  Write-Output ("Test-AssertFleetCliPins: FAILED ({0})" -f $fail)
  exit 1
}

$script:gateExit = 0
Invoke-CliPinsCheck -ManifestPath $ApprovedClis -ReportOnlySwitch:$ReportOnly
exit $script:gateExit
