# Canonical pre-dispatch expected-lane manifest producer. Sole authority for Assert-FleetLaneSpans.
# Writes {"run_id","expected_lanes"}; refuses overwrite (CreateNew).
param(
  [Parameter(Mandatory)][string]$RunId,
  [string[]]$ExpectedLaneId = @(),
  [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false
$lanes = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($entry in @($ExpectedLaneId)) {
  foreach ($part in @(([string]$entry) -split ',')) {
    $id = ([string]$part).Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    if ($seen.ContainsKey($id)) { continue }
    $seen[$id] = $true
    [void]$lanes.Add($id)
  }
}
# Manual JSON: PS5.1 ConvertTo-Json collapses single-element arrays to scalars.
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('{"run_id":')
[void]$sb.Append((ConvertTo-Json -InputObject ([string]$RunId) -Compress))
[void]$sb.Append(',"expected_lanes":[')
$first = $true
foreach ($id in @($lanes)) {
  if (-not $first) { [void]$sb.Append(',') }
  $first = $false
  [void]$sb.Append((ConvertTo-Json -InputObject ([string]$id) -Compress))
}
[void]$sb.Append(']}')
$payload = $sb.ToString()
$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) {
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
}
# Refuse overwrite: CreateNew throws if path exists.
try {
  $fs = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try {
    $bytes = $utf8.GetBytes($payload)
    $fs.Write($bytes, 0, $bytes.Length)
  } finally { $fs.Dispose() }
} catch {
  throw "ExpectedLaneManifest refuse overwrite: $OutputPath ($($_.Exception.Message))"
}
Write-Output $OutputPath
