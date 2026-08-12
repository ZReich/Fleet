# Self-contained tests for Write-FleetWorktreeTelemetry.ps1.
# Temp ledger only — never the real profile path. PS 5.1.
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'Write-FleetWorktreeTelemetry.ps1'
$utf8 = New-Object System.Text.UTF8Encoding $false
$passed = 0
$failed = 0
$totalCases = 5

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Case([string]$Name, [scriptblock]$Body) {
  try {
    & $Body
    $script:passed++
    Write-Host ("PASS {0} ({1}/{2})" -f $Name, $script:passed, $script:totalCases)
  } catch {
    $script:failed++
    Write-Host ("FAIL {0} ({1}/{2}) - {3}" -f $Name, ($script:passed + $script:failed), $script:totalCases, $_.Exception.Message)
  }
}

function New-ValidFields {
  param([string]$EventName = 'acquire_complete', [string]$RunId = 'run-1')
  $h = @{
    schema_version           = '1'
    timestamp_utc            = '2026-08-08T00:00:00Z'
    event                    = $EventName
    outcome                  = 'ok'
    reason                   = ''
    repo_id                  = 'repo-1'
    repo_key                 = 'rk1'
    pool_size                = 2
    slot_id                  = 'slot-0'
    run_id                   = $RunId
    branch                   = 'main'
    base_sha                 = ('a' * 40)
    ownership                = 'fleet'
    wait_ms                  = 0
    duration_ms              = 10
    provision_ms             = $null
    install_ms               = $null
    cleanup_ms               = $null
    reuse_hit                = $true
    install_reason           = $null
    dependency_fingerprint   = 'fp1'
    lockfile_sha256          = ('b' * 64)
    manifest_sha256          = ('c' * 64)
    toolchain_sha256         = ('d' * 64)
    cache_provider           = 'none'
    deps_count               = 0
    node_modules_bytes       = 0
    store_bytes_before       = 0
    store_bytes_after        = 0
    registered_worker_count  = 1
    quarantine_reason        = $null
  }
  return $h
}

function Test-LineHasAllRequired([string]$Line, [string[]]$Required) {
  $obj = $Line | ConvertFrom-Json
  foreach ($rk in $Required) {
    $props = @($obj.PSObject.Properties.Name)
    $found = $false
    foreach ($pn in $props) {
      if ([string]::Equals($pn, $rk, [StringComparison]::OrdinalIgnoreCase)) {
        $found = $true
        break
      }
    }
    if (-not $found) { throw "missing key on line: $rk" }
  }
  return $obj
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('fleet-wtt-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  . $helper

  $required = @(
    'schema_version', 'timestamp_utc', 'event', 'outcome', 'reason',
    'repo_id', 'repo_key', 'pool_size', 'slot_id', 'run_id', 'branch', 'base_sha',
    'ownership', 'wait_ms', 'duration_ms', 'provision_ms', 'install_ms', 'cleanup_ms',
    'reuse_hit', 'install_reason', 'dependency_fingerprint', 'lockfile_sha256',
    'manifest_sha256', 'toolchain_sha256', 'cache_provider', 'deps_count',
    'node_modules_bytes', 'store_bytes_before', 'store_bytes_after',
    'registered_worker_count', 'quarantine_reason'
  )

  Case '20 writers produce one-event-per-line parseable JSON with all required keys (1/4)' {
    $ledger = Join-Path $tempRoot 'ledger-20.jsonl'
    if (Test-Path -LiteralPath $ledger) { Remove-Item -LiteralPath $ledger -Force }
    $writeCount = 20
    for ($wi = 0; $wi -lt $writeCount; $wi++) {
      $fld = New-ValidFields -EventName 'acquire_complete' -RunId ("run-$wi")
      Write-FleetWorktreeTelemetry -Event 'acquire_complete' -Fields $fld -LedgerPath $ledger -Mode json
    }
    Assert-True (Test-Path -LiteralPath $ledger) 'ledger missing after writes'
    $rawBytes = [IO.File]::ReadAllBytes($ledger)
    # UTF-8 without BOM: no EF BB BF prefix
    if ($rawBytes.Length -ge 3) {
      $hasBom = ($rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)
      Assert-True (-not $hasBom) 'ledger has UTF-8 BOM'
    }
    $allLines = [IO.File]::ReadAllLines($ledger, $utf8)
    $nonEmpty = @($allLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-True ($nonEmpty.Count -eq $writeCount) ("expected $writeCount lines, got $($nonEmpty.Count)")
    # No partial / interleaved lines: each line independently parseable JSON
    $seenRuns = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($ln in $nonEmpty) {
      Assert-True ($ln.TrimStart().StartsWith('{')) "line not JSON object start: $ln"
      Assert-True ($ln.TrimEnd().EndsWith('}')) "line not JSON object end (partial?): $ln"
      $parsed = Test-LineHasAllRequired $ln $required
      Assert-True ([string]$parsed.event -eq 'acquire_complete') 'event field'
      [void]$seenRuns.Add([string]$parsed.run_id)
    }
    Assert-True ($seenRuns.Count -eq $writeCount) "unique run_ids: $($seenRuns.Count)"
  }

  Case 'missing outcome defaults ok; timestamp auto-stamped (2/4)' {
    $ledger = Join-Path $tempRoot 'ledger-miss.jsonl'
    if (Test-Path -LiteralPath $ledger) { Remove-Item -LiteralPath $ledger -Force }
    $fld = New-ValidFields -EventName 'reap'
    $fld.Remove('outcome')
    $fld.Remove('timestamp_utc')
    Write-FleetWorktreeTelemetry -Event 'reap' -Fields $fld -LedgerPath $ledger -Mode json
    Assert-True (Test-Path -LiteralPath $ledger) 'ledger missing after write with omitted key'
    $lines = @([IO.File]::ReadAllLines($ledger, $utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-True ($lines.Count -eq 1) "expected 1 line, got $($lines.Count)"
    $parsed = Test-LineHasAllRequired $lines[0] $required
    Assert-True ([string]$parsed.event -eq 'reap') 'event field'
    $outcomeVal = [string]$parsed.outcome
    Assert-True ($outcomeVal -eq 'ok') "outcome should default to ok when omitted, got '$outcomeVal'"
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$parsed.timestamp_utc)) 'timestamp_utc must auto-stamp'
  }

  Case 'denylisted key lease_id rejected (3/4)' {
    $ledger = Join-Path $tempRoot 'ledger-deny.jsonl'
    $fld = New-ValidFields -EventName 'quarantine'
    $fld['lease_id'] = 'secret-lease-should-not-log'
    $threw = $false
    $msg = ''
    try {
      Write-FleetWorktreeTelemetry -Event 'quarantine' -Fields $fld -LedgerPath $ledger -Mode json
    } catch {
      $threw = $true
      $msg = [string]$_.Exception.Message
    }
    Assert-True $threw 'denylist should throw'
    Assert-True ($msg -match 'Denied secret field key:\s*lease_id') "msg=$msg"
    Assert-True (-not (Test-Path -LiteralPath $ledger)) 'ledger must not be created on deny'
  }

  Case 'byte walker does not follow junction into victim (4/4)' {
    $measureRoot = Join-Path $tempRoot 'measure'
    $victimRoot = Join-Path $tempRoot 'victim'
    New-Item -ItemType Directory -Force -Path $measureRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $victimRoot | Out-Null

    $localFile = Join-Path $measureRoot 'local.txt'
    $localContent = 'local-only'
    [IO.File]::WriteAllText($localFile, $localContent, $utf8)
    $localSize = [int64]([IO.File]::ReadAllBytes($localFile).Length)

    $victimFile = Join-Path $victimRoot 'huge.bin'
    $victimBytes = New-Object byte[] 200000
    for ($bi = 0; $bi -lt $victimBytes.Length; $bi++) { $victimBytes[$bi] = [byte]($bi % 251) }
    [IO.File]::WriteAllBytes($victimFile, $victimBytes)
    $victimSize = [int64]$victimBytes.Length
    Assert-True ($victimSize -gt 100000) 'victim fixture too small'

    $juncPath = Join-Path $measureRoot 'junc-to-victim'
    if (Test-Path -LiteralPath $juncPath) {
      cmd.exe /c "rmdir `"$juncPath`"" | Out-Null
    }
    $mklinkOut = & cmd.exe /c "mklink /J `"$juncPath`" `"$victimRoot`"" 2>&1
    $mklinkCode = $LASTEXITCODE
    Assert-True ($mklinkCode -eq 0) "mklink failed ($mklinkCode): $mklinkOut"
    Assert-True (Test-Path -LiteralPath $juncPath) 'junction missing'

    $measured = Get-FleetDirectoryBytes -Path $measureRoot
    Assert-True ($measured -eq $localSize) "measured=$measured local=$localSize victim=$victimSize (junction followed?)"
    Assert-True ($measured -lt $victimSize) 'measured includes victim size'
    Assert-True ($measured -ne ($localSize + $victimSize)) 'sum includes junction target'
  }

  Case 'locked telemetry ledger surfaces append failure (5/5)' {
    $ledger = Join-Path $tempRoot 'ledger-locked.jsonl'
    [IO.File]::WriteAllText($ledger, '', $utf8)
    $lock = New-Object IO.FileStream($ledger, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
      $threw = $false
      try { Write-FleetWorktreeTelemetry -Event 'release_complete' -Fields (New-ValidFields -EventName 'release_complete') -LedgerPath $ledger -Mode json } catch { $threw = $true }
      Assert-True $threw 'exclusive telemetry ledger lock must fail visibly'
    } finally { $lock.Dispose() }
  }

} finally {
  try {
    # Best-effort cleanup (junctions first).
    $juncClean = Join-Path $tempRoot 'measure\junc-to-victim'
    if (Test-Path -LiteralPath $juncClean) {
      cmd.exe /c "rmdir `"$juncClean`"" 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch { }
}

$ran = $passed + $failed
Write-Host ("tests: {0}/{1}" -f $passed, $totalCases)
if ($failed -gt 0 -or $passed -ne $totalCases -or $ran -ne $totalCases) {
  exit 1
}
exit 0
