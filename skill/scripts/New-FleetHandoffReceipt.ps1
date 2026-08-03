# Fleet handoff receipt: compact schema_version=1 UTF-8 JSON for resume/handoff.
# Creates or validates; rejects missing fields, non-absolute artifacts, empty/oversize
# context, missing files, hash mismatch, and status/lifecycle contradictions.
# PowerShell 5.1 safe; ASCII only; no dependencies.
[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
  [string]$RunId,
  [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
  [string]$LaneId,
  [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
  [string]$Phase,
  [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
  [ValidateSet('ready', 'blocked', 'complete')]
  [string]$Status,
  [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
  [string]$NextAction,
  [Parameter(ParameterSetName = 'Create')]
  [string[]]$ArtifactPath = @(),
  [Parameter(ParameterSetName = 'Create')]
  [double]$FirstResultSeconds = 0,
  [Parameter(ParameterSetName = 'Create')]
  [long]$TimeoutSignals = 0,
  # String true/false: [bool] via powershell -File treats non-empty "false" as $true.
  [Parameter(ParameterSetName = 'Create')]
  [ValidateSet('true', 'false')]
  [string]$LifecycleComplete = 'false',
  [Parameter(ParameterSetName = 'Create')]
  [ValidateRange(1, 104857600)]
  [int]$MaxContextBytes = 153600,
  [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
  [string]$OutputPath,
  [Parameter(Mandatory = $true, ParameterSetName = 'Validate')]
  [string]$ReceiptPath,
  [Parameter(ParameterSetName = 'Validate')]
  [ValidateRange(1, 104857600)]
  [int]$MaxContextBytesValidate = 153600
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding $false

function Get-FileSha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-IsAbsolutePath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  return [IO.Path]::IsPathRooted($Path)
}

function Test-StrictJsonInteger {
  # Reject bool/string/float; only whole integer CLR types from JSON.
  param($Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [bool]) { return $false }
  if ($Value -is [string]) { return $false }
  if ($Value -is [double] -or $Value -is [float] -or $Value -is [single] -or $Value -is [decimal]) { return $false }
  return (
    $Value -is [byte] -or $Value -is [sbyte] -or
    $Value -is [int16] -or $Value -is [uint16] -or
    $Value -is [int32] -or $Value -is [uint32] -or
    $Value -is [int64] -or $Value -is [uint64] -or
    $Value -is [int] -or $Value -is [long]
  )
}

function Test-FiniteNonNegativeNumber {
  param($Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [bool] -or $Value -is [string]) { return $false }
  if (-not (
      $Value -is [byte] -or $Value -is [sbyte] -or
      $Value -is [int16] -or $Value -is [uint16] -or
      $Value -is [int32] -or $Value -is [uint32] -or
      $Value -is [int64] -or $Value -is [uint64] -or
      $Value -is [int] -or $Value -is [long] -or
      $Value -is [double] -or $Value -is [float] -or $Value -is [single] -or $Value -is [decimal]
    )) { return $false }
  $d = [double]$Value
  if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $false }
  return ($d -ge 0.0)
}

function Assert-ReceiptObject {
  param($Obj, [long]$MaxBytes)
  if ($null -eq $Obj) { throw 'receipt is null' }
  $names = @($Obj.PSObject.Properties.Name)
  foreach ($req in @('schema_version', 'run_id', 'lane_id', 'phase', 'status', 'next_action', 'artifacts', 'telemetry')) {
    if ($req -notin $names) { throw "missing required field: $req" }
  }
  if ([string]$Obj.schema_version -ne '1') { throw 'schema_version must be 1' }
  foreach ($s in @('run_id', 'lane_id', 'phase', 'next_action')) {
    if ([string]::IsNullOrWhiteSpace([string]$Obj.$s)) { throw "$s must be non-empty" }
  }
  $st = [string]$Obj.status
  if ($st -notin @('ready', 'blocked', 'complete')) { throw "status must be ready|blocked|complete (got $st)" }

  $tel = $Obj.telemetry
  if ($null -eq $tel) { throw 'telemetry missing' }
  $tNames = @($tel.PSObject.Properties.Name)
  foreach ($req in @('context_bytes', 'first_result_seconds', 'timeout_signals', 'lifecycle_complete')) {
    if ($req -notin $tNames) { throw "telemetry missing field: $req" }
  }
  # Strict JSON types before any coercion or contradiction checks.
  if (-not ($tel.lifecycle_complete -is [bool])) {
    throw 'telemetry.lifecycle_complete must be JSON boolean (reject string/number coercion)'
  }
  if (-not (Test-StrictJsonInteger $tel.context_bytes)) {
    throw 'telemetry.context_bytes must be integer JSON type (reject bool/string/float)'
  }
  if (-not (Test-FiniteNonNegativeNumber $tel.first_result_seconds)) {
    throw 'telemetry.first_result_seconds must be finite numeric >= 0'
  }
  if (-not (Test-StrictJsonInteger $tel.timeout_signals)) {
    throw 'telemetry.timeout_signals must be integer JSON type >= 0 domain'
  }
  $ctx = [int64]$tel.context_bytes
  if ($ctx -le 0) { throw 'context_bytes must be > 0 (empty context rejected)' }
  if ($ctx -gt $MaxBytes) { throw "context_bytes $ctx exceeds max $MaxBytes" }
  $frs = [double]$tel.first_result_seconds
  if ($frs -lt 0) { throw 'telemetry.first_result_seconds must be >= 0' }
  $tSignals = [int64]$tel.timeout_signals
  if ($tSignals -lt 0) { throw 'telemetry.timeout_signals must be >= 0' }
  $life = [bool]$tel.lifecycle_complete
  if ($st -eq 'complete' -and -not $life) {
    throw 'status=complete requires telemetry.lifecycle_complete=true'
  }
  if ($life -and $st -ne 'complete') {
    throw "lifecycle_complete=true requires status=complete (got $st)"
  }

  $arts = @($Obj.artifacts)
  if ($null -eq $Obj.artifacts) { throw 'artifacts missing' }
  $artBytesSum = [int64]0
  foreach ($a in $arts) {
    if ($null -eq $a) { throw 'artifact entry null' }
    $aNames = @($a.PSObject.Properties.Name)
    foreach ($req in @('path', 'bytes', 'sha256')) {
      if ($req -notin $aNames) { throw "artifact missing field: $req" }
    }
    $p = [string]$a.path
    if (-not (Test-IsAbsolutePath $p)) { throw "artifact path must be absolute: $p" }
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "artifact missing on disk: $p" }
    $fi = Get-Item -LiteralPath $p
    $wantBytes = 0
    try { $wantBytes = [int64]$a.bytes } catch { throw 'artifact.bytes must be int' }
    if ([int64]$fi.Length -ne $wantBytes) { throw "artifact bytes mismatch for $p (disk=$($fi.Length) receipt=$wantBytes)" }
    $artBytesSum += $wantBytes
    $wantHash = ([string]$a.sha256).ToLowerInvariant()
    if ($wantHash -notmatch '^[0-9a-f]{64}$') { throw "artifact sha256 invalid for $p" }
    $gotHash = Get-FileSha256 $p
    if ($gotHash -ne $wantHash) { throw "artifact hash mismatch for $p" }
  }
  # Authority: context_bytes must equal named-delta artifact byte sum (reject under/over claims).
  if ($artBytesSum -ne $ctx) {
    throw "context_bytes mismatch: claimed $ctx != sum(artifact.bytes)=$artBytesSum"
  }
}

function Write-AtomicJson([string]$Path, [string]$Json) {
  $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $dir = Split-Path -Parent $resolved
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $temporary = "$resolved.$PID.tmp"
  try {
    [IO.File]::WriteAllText($temporary, $Json + [Environment]::NewLine, $utf8)
    Move-Item -LiteralPath $temporary -Destination $resolved -Force
  }
  finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
  }
  return $resolved
}

if ($PSCmdlet.ParameterSetName -eq 'Validate') {
  if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
    throw "ReceiptPath not found: $ReceiptPath"
  }
  $raw = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ReceiptPath).Path, $utf8)
  $obj = $raw | ConvertFrom-Json
  Assert-ReceiptObject -Obj $obj -MaxBytes $MaxContextBytesValidate
  $out = [ordered]@{
    schema_version = '1'
    valid          = $true
    path           = (Resolve-Path -LiteralPath $ReceiptPath).Path
    status         = [string]$obj.status
    lifecycle_complete = [bool]$obj.telemetry.lifecycle_complete
  }
  Write-Output ($out | ConvertTo-Json -Compress -Depth 5)
  exit 0
}

# Create path
$lifeFlag = ($LifecycleComplete -eq 'true')
if ($Status -eq 'complete' -and -not $lifeFlag) {
  throw 'status=complete requires LifecycleComplete=true'
}
if ($lifeFlag -and $Status -ne 'complete') {
  throw 'LifecycleComplete=true requires Status=complete'
}
if ([string]::IsNullOrWhiteSpace($RunId) -or [string]::IsNullOrWhiteSpace($LaneId) -or
    [string]::IsNullOrWhiteSpace($Phase) -or [string]::IsNullOrWhiteSpace($NextAction)) {
  throw 'RunId, LaneId, Phase, NextAction must be non-empty'
}

$artifacts = @()
$artBytesSum = [int64]0
foreach ($ap in @($ArtifactPath)) {
  if ([string]::IsNullOrWhiteSpace($ap)) { continue }
  if (-not (Test-IsAbsolutePath $ap)) { throw "artifact path must be absolute: $ap" }
  if (-not (Test-Path -LiteralPath $ap -PathType Leaf)) { throw "artifact missing on disk: $ap" }
  $full = (Resolve-Path -LiteralPath $ap).Path
  $fi = Get-Item -LiteralPath $full
  $bytes = [int64]$fi.Length
  $artBytesSum += $bytes
  $artifacts += [ordered]@{
    path   = $full
    bytes  = $bytes
    sha256 = Get-FileSha256 $full
  }
}
# context_bytes is computed from named-delta artifact bytes; callers have no authority.
if ($artBytesSum -le 0) { throw 'context_bytes must be > 0 (empty context rejected)' }
if ($artBytesSum -gt $MaxContextBytes) { throw "context_bytes $artBytesSum exceeds MaxContextBytes $MaxContextBytes" }

$receipt = [ordered]@{
  schema_version = '1'
  run_id         = $RunId
  lane_id        = $LaneId
  phase          = $Phase
  status         = $Status
  next_action    = $NextAction
  artifacts      = @($artifacts)
  telemetry      = [ordered]@{
    context_bytes        = [int64]$artBytesSum
    first_result_seconds = [double]$FirstResultSeconds
    timeout_signals      = [int64]$TimeoutSignals
    lifecycle_complete   = [bool]$lifeFlag
  }
}
$json = ($receipt | ConvertTo-Json -Depth 6 -Compress)
Assert-ReceiptObject -Obj ($json | ConvertFrom-Json) -MaxBytes $MaxContextBytes
$written = Write-AtomicJson -Path $OutputPath -Json $json
$result = [ordered]@{
  schema_version = '1'
  written        = $true
  path           = $written
  bytes          = $utf8.GetByteCount($json + [Environment]::NewLine)
  status         = $Status
  artifact_count = $artifacts.Count
  lifecycle_complete = [bool]$lifeFlag
}
Write-Output ($result | ConvertTo-Json -Compress -Depth 5)
exit 0
