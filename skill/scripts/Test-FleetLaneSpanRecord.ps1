# Lane span row validator library + offline suite.
# Dot-source for Test-FleetLaneSpanRecord; run as -File for tests.
$ErrorActionPreference = 'Stop'

function Test-StrictNonNegativeInteger {
  param($Value)
  if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { return $false }
  if ($Value -is [double] -or $Value -is [float] -or $Value -is [single] -or $Value -is [decimal]) {
    $d = [double]$Value
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -lt 0) { return $false }
    return ($d -eq [math]::Floor($d))
  }
  if (-not ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
      $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or
      $Value -is [int] -or $Value -is [long])) { return $false }
  return ([int64]$Value -ge 0)
}

function Test-FiniteNonNegativeNumber {
  param($Value)
  if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) { return $false }
  if (-not ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
      $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or
      $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [float] -or
      $Value -is [single] -or $Value -is [decimal])) { return $false }
  $d = [double]$Value
  if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $false }
  return ($d -ge 0.0)
}

function Get-LaneSpanRequiredFields {
  return @(
    'schema_version', 'run_id', 'lane_id', 'phase',
    'gen_ai.operation.name', 'gen_ai.agent.name', 'gen_ai.provider.name',
    'gen_ai.request.model', 'gen_ai.response.model',
    'gen_ai.usage.input_tokens', 'gen_ai.usage.output_tokens',
    'gen_ai.usage.cache_read.input_tokens',
    'tool_calls', 'inference_calls', 'duration_s', 'first_result_s',
    'status', 'error.type', 'handoff', 'artifacts'
  )
}

function Get-LaneSpanProp {
  param($Record, [string]$Name)
  $p = $Record.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Test-FleetLaneSpanRecord {
  param($Record)
  if ($null -eq $Record) { throw 'lane span record is null' }
  $names = @($Record.PSObject.Properties.Name)
  $required = Get-LaneSpanRequiredFields
  foreach ($req in $required) { if ($req -notin $names) { throw "missing required field: $req" } }
  foreach ($n in $names) { if ($n -notin $required) { throw "unknown field: $n" } }
  if ([string](Get-LaneSpanProp $Record 'schema_version') -ne '1') { throw 'schema_version must be 1' }
  foreach ($s in @('run_id', 'lane_id', 'phase', 'gen_ai.agent.name', 'gen_ai.provider.name', 'gen_ai.request.model')) {
    if ([string]::IsNullOrWhiteSpace([string](Get-LaneSpanProp $Record $s))) { throw "$s must be non-empty" }
  }
  if ([string](Get-LaneSpanProp $Record 'gen_ai.operation.name') -ne 'invoke_agent') {
    throw 'gen_ai.operation.name must be invoke_agent'
  }
  $respModel = Get-LaneSpanProp $Record 'gen_ai.response.model'
  if ($null -ne $respModel -and [string]::IsNullOrWhiteSpace([string]$respModel)) {
    throw 'gen_ai.response.model must be null or non-empty string'
  }
  foreach ($tok in @('gen_ai.usage.input_tokens', 'gen_ai.usage.output_tokens', 'gen_ai.usage.cache_read.input_tokens')) {
    $v = Get-LaneSpanProp $Record $tok
    if ($null -ne $v -and -not (Test-StrictNonNegativeInteger $v)) {
      throw "$tok must be null or nonnegative integer"
    }
  }
  foreach ($c in @('tool_calls', 'inference_calls')) {
    if (-not (Test-StrictNonNegativeInteger (Get-LaneSpanProp $Record $c))) {
      throw "$c must be a nonnegative integer"
    }
  }
  $duration = Get-LaneSpanProp $Record 'duration_s'
  if (-not (Test-FiniteNonNegativeNumber $duration)) { throw 'duration_s must be a nonnegative finite number' }
  $dur = [double]$duration
  $frs = Get-LaneSpanProp $Record 'first_result_s'
  if ($null -ne $frs) {
    if (-not (Test-FiniteNonNegativeNumber $frs)) { throw 'first_result_s must be null or nonnegative finite number' }
    if ([double]$frs -gt $dur) { throw 'first_result_s must be <= duration_s' }
  }
  $st = [string](Get-LaneSpanProp $Record 'status')
  if ($st -notin @('ok', 'error', 'timeout', 'no_contest')) {
    throw "status must be ok|error|timeout|no_contest (got $st)"
  }
  $errType = Get-LaneSpanProp $Record 'error.type'
  if ($null -ne $errType -and ($errType -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$errType))) {
    throw 'error.type must be null or non-empty string'
  }
  $handoff = Get-LaneSpanProp $Record 'handoff'
  if ($null -ne $handoff) {
    $hNames = @($handoff.PSObject.Properties.Name)
    $hReq = @('receipt_bytes', 'verify_ms', 'artifact_sha_ok')
    foreach ($req in $hReq) { if ($req -notin $hNames) { throw "handoff missing field: $req" } }
    foreach ($n in $hNames) { if ($n -notin $hReq) { throw "handoff unknown field: $n" } }
    if (-not (Test-StrictNonNegativeInteger $handoff.receipt_bytes)) { throw 'handoff.receipt_bytes must be nonnegative integer' }
    if (-not (Test-FiniteNonNegativeNumber $handoff.verify_ms)) { throw 'handoff.verify_ms must be nonnegative finite number' }
    if ($handoff.artifact_sha_ok -isnot [bool]) { throw 'handoff.artifact_sha_ok must be JSON boolean' }
  }
  $artifacts = Get-LaneSpanProp $Record 'artifacts'
  if ($artifacts -is [string]) { throw 'artifacts must be an array' }
  # PS 5.1: empty JSON arrays become $null; field presence already required above.
  if ($null -eq $artifacts) { $arts = @() } else { $arts = @($artifacts) }
  foreach ($a in $arts) {
    if ($null -eq $a) { throw 'artifact entry null' }
    $aNames = @($a.PSObject.Properties.Name)
    foreach ($req in @('path', 'bytes', 'sha256')) { if ($req -notin $aNames) { throw "artifact missing field: $req" } }
    foreach ($n in $aNames) { if ($n -notin @('path', 'bytes', 'sha256')) { throw "artifact unknown field: $n" } }
    if ([string]::IsNullOrWhiteSpace([string]$a.path)) { throw 'artifact.path must be non-empty' }
    if (-not (Test-StrictNonNegativeInteger $a.bytes)) { throw 'artifact.bytes must be nonnegative integer' }
    if ([string]$a.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'artifact.sha256 must be exactly 64 lowercase hex' }
  }
  return $true
}

function ConvertTo-CanonicalLaneSpan {
  param($Record)
  [void](Test-FleetLaneSpanRecord $Record)
  $handoff = Get-LaneSpanProp $Record 'handoff'
  $handoffOut = $null
  if ($null -ne $handoff) {
    $handoffOut = [ordered]@{
      receipt_bytes = [int64]$handoff.receipt_bytes
      verify_ms = [double]$handoff.verify_ms
      artifact_sha_ok = [bool]$handoff.artifact_sha_ok
    }
  }
  $artsOut = @()
  foreach ($a in @(Get-LaneSpanProp $Record 'artifacts')) {
    if ($null -eq $a) { continue }
    $artsOut += [ordered]@{ path = [string]$a.path; bytes = [int64]$a.bytes; sha256 = [string]$a.sha256 }
  }
  $tokIn = Get-LaneSpanProp $Record 'gen_ai.usage.input_tokens'
  $tokOut = Get-LaneSpanProp $Record 'gen_ai.usage.output_tokens'
  $tokCache = Get-LaneSpanProp $Record 'gen_ai.usage.cache_read.input_tokens'
  $frs = Get-LaneSpanProp $Record 'first_result_s'
  $respModel = Get-LaneSpanProp $Record 'gen_ai.response.model'
  $errType = Get-LaneSpanProp $Record 'error.type'
  return [ordered]@{
    schema_version = '1'
    run_id = [string](Get-LaneSpanProp $Record 'run_id')
    lane_id = [string](Get-LaneSpanProp $Record 'lane_id')
    phase = [string](Get-LaneSpanProp $Record 'phase')
    'gen_ai.operation.name' = 'invoke_agent'
    'gen_ai.agent.name' = [string](Get-LaneSpanProp $Record 'gen_ai.agent.name')
    'gen_ai.provider.name' = [string](Get-LaneSpanProp $Record 'gen_ai.provider.name')
    'gen_ai.request.model' = [string](Get-LaneSpanProp $Record 'gen_ai.request.model')
    'gen_ai.response.model' = $(if ($null -eq $respModel) { $null } else { [string]$respModel })
    'gen_ai.usage.input_tokens' = $(if ($null -eq $tokIn) { $null } else { [int64]$tokIn })
    'gen_ai.usage.output_tokens' = $(if ($null -eq $tokOut) { $null } else { [int64]$tokOut })
    'gen_ai.usage.cache_read.input_tokens' = $(if ($null -eq $tokCache) { $null } else { [int64]$tokCache })
    tool_calls = [int64](Get-LaneSpanProp $Record 'tool_calls')
    inference_calls = [int64](Get-LaneSpanProp $Record 'inference_calls')
    duration_s = [double](Get-LaneSpanProp $Record 'duration_s')
    first_result_s = $(if ($null -eq $frs) { $null } else { [double]$frs })
    status = [string](Get-LaneSpanProp $Record 'status')
    'error.type' = $(if ($null -eq $errType) { $null } else { [string]$errType })
    handoff = $handoffOut
    artifacts = @($artsOut)
  }
}

# --- offline suite (skipped when dot-sourced) ---
if ($MyInvocation.InvocationName -ne '.') {
  $passed = 0; $failed = 0
  function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }
  function Case([string]$n, [scriptblock]$b) {
    try { & $b; $script:passed++; Write-Host "PASS $n" }
    catch { $script:failed++; Write-Host "FAIL $n - $($_.Exception.Message)" }
  }
  function New-ValidSpan {
    [pscustomobject][ordered]@{
      schema_version = '1'; run_id = 'run-1'; lane_id = 'W1/T1'; phase = 'impl'
      'gen_ai.operation.name' = 'invoke_agent'; 'gen_ai.agent.name' = 'grok-4.5'
      'gen_ai.provider.name' = 'xai'; 'gen_ai.request.model' = 'grok-4.5'
      'gen_ai.response.model' = 'grok-4.5'; 'gen_ai.usage.input_tokens' = 100
      'gen_ai.usage.output_tokens' = 50; 'gen_ai.usage.cache_read.input_tokens' = 10
      tool_calls = 2; inference_calls = 1; duration_s = 10.5; first_result_s = 1.2
      status = 'ok'; 'error.type' = $null
      handoff = [pscustomobject]@{ receipt_bytes = 100; verify_ms = 12.5; artifact_sha_ok = $true }
      artifacts = @([pscustomobject]@{ path = 'a.txt'; bytes = 3; sha256 = ('a' * 64) })
    }
  }
  function Copy-Span($r) { $r | ConvertTo-Json -Depth 8 | ConvertFrom-Json }
  function Assert-Rejects([scriptblock]$Mutate, [string]$Pattern, [string]$Name) {
    Case $Name {
      $r = Copy-Span (New-ValidSpan)
      & $Mutate $r
      $threw = $false
      try { [void](Test-FleetLaneSpanRecord $r) } catch {
        $threw = $true
        Assert-True ($_.Exception.Message -match $Pattern) "msg=$($_.Exception.Message)"
      }
      Assert-True $threw "$Name accepted"
    }
  }

  Case 'valid row passes' { Assert-True (Test-FleetLaneSpanRecord (New-ValidSpan)) 'valid should pass' }
  Assert-Rejects { param($r) $r.PSObject.Properties.Remove('phase') } 'missing required field: phase' 'missing field rejected'
  Assert-Rejects { param($r) $r | Add-Member -NotePropertyName 'extra_field' -NotePropertyValue 1 } 'unknown field: extra_field' 'unknown field rejected'
  Assert-Rejects { param($r) $r.status = 'done' } 'status must be' 'bad status rejected'
  Assert-Rejects { param($r) @($r.artifacts)[0].sha256 = ('A' * 64) } 'sha256' 'bad sha256 rejected'
  Assert-Rejects { param($r) $r.first_result_s = 99; $r.duration_s = 10 } 'first_result_s' 'first_result_s > duration_s rejected'
  Assert-Rejects { param($r) $r.tool_calls = -1 } 'tool_calls' 'negative count rejected'
  Assert-Rejects { param($r) $r.handoff = [pscustomobject]@{ receipt_bytes = 1; verify_ms = 2 } } 'handoff missing field: artifact_sha_ok' 'incomplete handoff rejected'

  $total = $passed + $failed
  if ($total -eq 0) { Write-Host 'FAIL: suite collected 0 cases'; exit 1 }
  Write-Host "RESULT: $passed passed, $failed failed, $total total"
  if ($failed -gt 0) { exit 1 }
  exit 0
}
