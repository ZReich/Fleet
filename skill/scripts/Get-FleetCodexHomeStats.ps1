# READ-ONLY audit of leftover isolated CODEX_HOME dirs created by New-CodexLaneHome.ps1.
# Reports subdir count, total size (bytes), and age of the oldest home dir.
# Missing root = clean zeros. Never throws. PS5.1-safe, ASCII only.
[CmdletBinding()]
param(
  [string]$Root = (Join-Path $env:TEMP 'fleet-codex-homes'),
  [ValidateSet('text', 'json')]
  [string]$Mode = 'text',
  [switch]$SelfTest
)

# Soft: never throw on IO races / missing paths.
$ErrorActionPreference = 'Continue'

function Get-CodexHomeStats([string]$rootPath) {
  $count = 0
  $bytes = [int64]0
  $oldestSeconds = $null
  try {
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
      return @{ Count = 0; Bytes = [int64]0; OldestSeconds = $null }
    }
    $dirs = @(Get-ChildItem -LiteralPath $rootPath -Directory -Force -ErrorAction SilentlyContinue)
    $count = $dirs.Count
    $oldestUtc = $null
    foreach ($dir in $dirs) {
      $files = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
      foreach ($file in $files) {
        try { $bytes += [int64]$file.Length } catch { }
      }
      try {
        $created = $dir.CreationTimeUtc
        if ($null -eq $oldestUtc -or $created -lt $oldestUtc) { $oldestUtc = $created }
      } catch { }
    }
    if ($null -ne $oldestUtc) {
      $span = [datetime]::UtcNow - $oldestUtc
      $oldestSeconds = [int][Math]::Max(0, [Math]::Floor($span.TotalSeconds))
    }
  } catch {
    $count = 0
    $bytes = [int64]0
    $oldestSeconds = $null
  }
  return @{ Count = $count; Bytes = $bytes; OldestSeconds = $oldestSeconds }
}

function Write-CodexHomeStats([hashtable]$stats, [string]$rootPath, [string]$outMode) {
  $count = [int]$stats.Count
  $bytes = [int64]$stats.Bytes
  $oldestSeconds = $stats.OldestSeconds
  if ($outMode -eq 'json') {
    $oldestOut = $null
    if ($null -ne $oldestSeconds) { $oldestOut = [int]$oldestSeconds }
    $obj = [ordered]@{
      count = $count
      bytes = $bytes
      oldest_seconds = $oldestOut
      root = $rootPath
    }
    Write-Output (($obj | ConvertTo-Json -Compress -Depth 3))
    return
  }
  $ageText = 'none'
  if ($null -ne $oldestSeconds) { $ageText = ('{0}s' -f [int]$oldestSeconds) }
  Write-Output ('codexhomes: {0} dirs, {1} bytes, oldest {2} (root {3})' -f $count, $bytes, $ageText, $rootPath)
}

if ($SelfTest) {
  $fail = 0
  function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Output ("PASS {0}" -f $name) }
    else { Write-Output ("FAIL {0}" -f $name); $script:fail++ }
  }
  $tmp = Join-Path $env:TEMP ('codexhomestats-selftest-' + [guid]::NewGuid().ToString('n'))
  $fakeRoot = Join-Path $tmp 'root'
  $missingRoot = Join-Path $tmp 'missing-no-such'
  try {
    New-Item -ItemType Directory -Force -Path $fakeRoot | Out-Null
    $d1 = Join-Path $fakeRoot 'home-a'
    $d2 = Join-Path $fakeRoot 'home-b'
    New-Item -ItemType Directory -Force -Path $d1 | Out-Null
    New-Item -ItemType Directory -Force -Path $d2 | Out-Null
    Set-Content -LiteralPath (Join-Path $d1 'marker.txt') -Value 'aaaa' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $d2 'marker.txt') -Value 'bbbbbb' -Encoding ASCII

    $withHomes = Get-CodexHomeStats $fakeRoot
    Check 'count=2 with two home dirs' ($withHomes.Count -eq 2)
    Check 'bytes>0 with files inside homes' ($withHomes.Bytes -gt 0)
    Check 'oldest_seconds is int when dirs exist' ($null -ne $withHomes.OldestSeconds)

    $gone = Get-CodexHomeStats $missingRoot
    Check 'missing root count=0' ($gone.Count -eq 0)
    Check 'missing root bytes=0' ($gone.Bytes -eq 0)
    Check 'missing root oldest none' ($null -eq $gone.OldestSeconds)

    $textOut = @(Write-CodexHomeStats $withHomes $fakeRoot 'text')
    $last = $textOut[-1]
    Check 'text last line has codexhomes prefix' ($last -like 'codexhomes: 2 dirs, *')
    $jsonOut = @(Write-CodexHomeStats $gone $missingRoot 'json')
    $parsed = $jsonOut[-1] | ConvertFrom-Json
    Check 'json missing root count=0' ([int]$parsed.count -eq 0)
    Check 'json missing root bytes=0' ([int64]$parsed.bytes -eq 0)
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($fail -eq 0) {
    Write-Output 'Test-GetFleetCodexHomeStats: passed (9 checks)'
    exit 0
  }
  Write-Output ("Test-GetFleetCodexHomeStats: FAILED ({0})" -f $fail)
  exit 1
}

$stats = Get-CodexHomeStats $Root
Write-CodexHomeStats $stats $Root $Mode
exit 0
