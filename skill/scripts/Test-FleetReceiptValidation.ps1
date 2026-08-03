# Offline tests: New-FleetHandoffReceipt create/validate (no live model).
$ErrorActionPreference = 'Stop'
$createScript = Join-Path $PSScriptRoot 'New-FleetHandoffReceipt.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('fleet-receipt-validation-' + [guid]::NewGuid().ToString('N'))
$passed = 0; $failed = 0
$utf8 = New-Object Text.UTF8Encoding $false
function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Invoke-Create {
  param(
    [string]$RunId = 'run-1', [string]$LaneId = 'T1', [string]$Phase = 'impl',
    [string]$Status = 'ready', [string]$NextAction = 'resume lane',
    [string[]]$ArtifactPath = @(), [double]$FirstResultSeconds = 1.5,
    [int]$TimeoutSignals = 0, [string]$LifecycleComplete = 'false',
    [int]$MaxContextBytes = 153600, [string]$OutputPath
  )
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $createScript,
    '-RunId', $RunId, '-LaneId', $LaneId, '-Phase', $Phase, '-Status', $Status,
    '-NextAction', $NextAction,
    '-FirstResultSeconds', "$FirstResultSeconds", '-TimeoutSignals', "$TimeoutSignals",
    '-LifecycleComplete', $(if ($LifecycleComplete -eq 'true' -or $LifecycleComplete -eq $true) { 'true' } else { 'false' }),
    '-MaxContextBytes', "$MaxContextBytes", '-OutputPath', $OutputPath
  )
  if ($ArtifactPath.Count -gt 0) { $args += '-ArtifactPath'; $args += $ArtifactPath }
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @args 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old }
  return [pscustomobject]@{ ExitCode = $code; Raw = (($raw | ForEach-Object { "$_" }) -join "`n") }
}
function Invoke-Validate([string]$Path, [int]$MaxBytes = 153600) {
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $createScript, '-ReceiptPath', $Path, '-MaxContextBytesValidate', $MaxBytes)
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @args 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old }
  return [pscustomobject]@{ ExitCode = $code; Raw = (($raw | ForEach-Object { "$_" }) -join "`n") }
}
function Write-Utf8([string]$Path, [string]$Content) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, $Content, $utf8)
}
try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $artPath = Join-Path $root 'delta.txt'
  Write-Utf8 $artPath 'named delta artifact body'
  $artHash = (Get-FileHash -LiteralPath $artPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $artBytes = [int64](Get-Item -LiteralPath $artPath).Length
  Case 'create valid ready receipt + validate' {
    $out = Join-Path $root 'ready.json'
    $run = Invoke-Create -Status ready -LifecycleComplete false -ArtifactPath @($artPath) -OutputPath $out
    Assert-True ($run.ExitCode -eq 0) "create exit: $($run.Raw)"
    Assert-True (Test-Path -LiteralPath $out) 'output missing'
    $obj = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
    Assert-True ([string]$obj.schema_version -eq '1') 'schema'
    Assert-True ([string]$obj.status -eq 'ready') 'status'
    Assert-True ($obj.artifacts.Count -eq 1) 'artifact count'
    Assert-True ([string]$obj.artifacts[0].sha256 -eq $artHash) 'sha'
    Assert-True ([int64]$obj.artifacts[0].bytes -eq $artBytes) 'bytes'
    Assert-True ([int64]$obj.telemetry.context_bytes -eq $artBytes) 'context_bytes=art sum'
    Assert-True ([IO.Path]::IsPathRooted([string]$obj.artifacts[0].path)) 'absolute'
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -eq 0) "validate: $($v.Raw)"
    Assert-True ($v.Raw -match '"valid"\s*:\s*true') 'valid true'
  }
  Case 'create complete requires lifecycle_complete' {
    $out = Join-Path $root 'complete-bad.json'
    $run = Invoke-Create -Status complete -LifecycleComplete false -ArtifactPath @($artPath) -OutputPath $out
    Assert-True ($run.ExitCode -ne 0) "should reject complete without lifecycle: $($run.Raw)"
  }
  Case 'create complete with lifecycle ok' {
    $out = Join-Path $root 'complete-ok.json'
    $run = Invoke-Create -Status complete -LifecycleComplete true -NextAction 'done' -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "complete create: $($run.Raw)"
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -eq 0) "complete validate: $($v.Raw)"
  }
  Case 'reject empty context' {
    $out = Join-Path $root 'empty-ctx.json'
    # No artifacts => computed context_bytes 0 => rejected.
    $run = Invoke-Create -OutputPath $out
    Assert-True ($run.ExitCode -ne 0) "empty context should fail: $($run.Raw)"
  }
  Case 'reject oversize context' {
    $out = Join-Path $root 'oversize.json'
    $big = Join-Path $root 'big-delta.bin'
    # 200 bytes artifact with MaxContextBytes=50 must fail (computed context oversize).
    Write-Utf8 $big ('x' * 200)
    $run = Invoke-Create -ArtifactPath @($big) -MaxContextBytes 50 -OutputPath $out
    Assert-True ($run.ExitCode -ne 0) "oversize should fail: $($run.Raw)"
  }
  Case 'reject non-absolute artifact path' {
    $out = Join-Path $root 'rel-art.json'
    $run = Invoke-Create -ArtifactPath @('relative\delta.txt') -OutputPath $out
    Assert-True ($run.ExitCode -ne 0) "relative artifact should fail: $($run.Raw)"
  }
  Case 'reject missing artifact file' {
    $out = Join-Path $root 'missing-art.json'
    $missing = Join-Path $root 'no-such-file.bin'
    $run = Invoke-Create -ArtifactPath @($missing) -OutputPath $out
    Assert-True ($run.ExitCode -ne 0) "missing artifact should fail: $($run.Raw)"
  }
  Case 'reject hash mismatch mutation' {
    $out = Join-Path $root 'hash-bad.json'
    $run = Invoke-Create -ArtifactPath @($artPath) -OutputPath $out -Status ready
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    $mut = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
    $mut.artifacts[0].sha256 = ('0' * 64)
    Write-Utf8 $out (($mut | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0) "hash mismatch must fail: $($v.Raw)"
  }
  Case 'reject lifecycle contradiction mutation' {
    $out = Join-Path $root 'life-bad.json'
    $run = Invoke-Create -Status ready -LifecycleComplete false -ArtifactPath @($artPath) -OutputPath $out
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    $mut = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
    $mut.telemetry.lifecycle_complete = $true
    Write-Utf8 $out (($mut | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0) "lifecycle contradiction must fail: $($v.Raw)"
  }
  Case 'reject string false lifecycle mutation' {
    $out = Join-Path $root 'life-string-false.json'
    $run = Invoke-Create -Status complete -LifecycleComplete true -NextAction 'done' -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    # Crafted: status complete + lifecycle_complete string "false" must fail (not coerce).
    $raw = Get-Content -Raw -LiteralPath $out
    $crafted = $raw -replace '"lifecycle_complete"\s*:\s*true', '"lifecycle_complete":"false"'
    Assert-True ($crafted -match '"lifecycle_complete"\s*:\s*"false"') 'mutation applied'
    Write-Utf8 $out $crafted
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0) "string false lifecycle must fail: $($v.Raw)"
  }
  Case 'reject negative first_result_seconds' {
    $out = Join-Path $root 'neg-frs.json'
    $run = Invoke-Create -Status ready -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    $raw = Get-Content -Raw -LiteralPath $out
    $crafted = $raw -replace '"first_result_seconds"\s*:\s*[0-9.eE+-]+', '"first_result_seconds":-1'
    Write-Utf8 $out $crafted
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0) "negative first_result_seconds must fail: $($v.Raw)"
  }
  Case 'reject nonnumeric first_result_seconds' {
    $out = Join-Path $root 'nonnum-frs.json'
    $run = Invoke-Create -Status ready -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    $raw = Get-Content -Raw -LiteralPath $out
    $crafted = $raw -replace '"first_result_seconds"\s*:\s*[0-9.eE+-]+', '"first_result_seconds":"1.5"'
    Write-Utf8 $out $crafted
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0) "nonnumeric first_result_seconds must fail: $($v.Raw)"
  }
  Case 'reject negative timeout_signals' {
    $out = Join-Path $root 'neg-ts.json'
    $run = Invoke-Create -Status ready -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    $raw = Get-Content -Raw -LiteralPath $out
    $crafted = $raw -replace '"timeout_signals"\s*:\s*-?\d+', '"timeout_signals":-3'
    Write-Utf8 $out $crafted
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0) "negative timeout_signals must fail: $($v.Raw)"
  }
  Case 'reject noninteger timeout_signals' {
    $out = Join-Path $root 'nonint-ts.json'
    $run = Invoke-Create -Status ready -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    $raw = Get-Content -Raw -LiteralPath $out
    $crafted = $raw -replace '"timeout_signals"\s*:\s*-?\d+', '"timeout_signals":1.5'
    Write-Utf8 $out $crafted
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0) "noninteger timeout_signals must fail: $($v.Raw)"
  }
  Case 'reject context_bytes type coercion' {
    $out = Join-Path $root 'ctx-coerce.json'
    $run = Invoke-Create -Status ready -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    $raw = Get-Content -Raw -LiteralPath $out
    # String "100" must not pass via [int]"100" coercion.
    $crafted = $raw -replace '"context_bytes"\s*:\s*\d+', '"context_bytes":"100"'
    Write-Utf8 $out $crafted
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0) "string context_bytes must fail: $($v.Raw)"
    # Bool true must not pass via [int]$true.
    $crafted2 = $raw -replace '"context_bytes"\s*:\s*\d+', '"context_bytes":true'
    Write-Utf8 $out $crafted2
    $v2 = Invoke-Validate $out
    Assert-True ($v2.ExitCode -ne 0) "bool context_bytes must fail: $($v2.Raw)"
    # Float must not pass.
    $crafted3 = $raw -replace '"context_bytes"\s*:\s*\d+', '"context_bytes":100.5'
    Write-Utf8 $out $crafted3
    $v3 = Invoke-Validate $out
    Assert-True ($v3.ExitCode -ne 0) "float context_bytes must fail: $($v3.Raw)"
  }
  Case 'reject context_bytes mismatch' {
    $out = Join-Path $root 'ctx-mismatch.json'
    $run = Invoke-Create -Status ready -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    # Understated claim: context_bytes smaller than sum(artifact.bytes).
    $raw = Get-Content -Raw -LiteralPath $out
    $crafted = $raw -replace '"context_bytes"\s*:\s*\d+', '"context_bytes":1'
    Write-Utf8 $out $crafted
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0 -and $v.Raw -match 'context_bytes mismatch|mismatch') "ctx mismatch must fail: $($v.Raw)"
  }
  Case 'reject inflated context_bytes mismatch' {
    $out = Join-Path $root 'ctx-inflated.json'
    $run = Invoke-Create -Status ready -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    # Inflated claim under MaxBytes but > sum(artifact.bytes) must FAIL equality.
    $raw = Get-Content -Raw -LiteralPath $out
    $inflated = [int64]$artBytes + 1000
    $crafted = $raw -replace '"context_bytes"\s*:\s*\d+', ('"context_bytes":' + $inflated)
    Write-Utf8 $out $crafted
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0 -and $v.Raw -match 'context_bytes mismatch|mismatch') "inflated ctx must fail: $($v.Raw)"
  }
  Case 'reject missing required field mutation' {
    $out = Join-Path $root 'missing-field.json'
    $run = Invoke-Create -Status ready -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "setup: $($run.Raw)"
    $mut = Get-Content -Raw -LiteralPath $out | ConvertFrom-Json
    $mut.PSObject.Properties.Remove('next_action')
    Write-Utf8 $out (($mut | ConvertTo-Json -Depth 6 -Compress) + "`n")
    $v = Invoke-Validate $out
    Assert-True ($v.ExitCode -ne 0) "missing field must fail: $($v.Raw)"
  }
  Case 'atomic result shape on create' {
    $out = Join-Path $root 'atomic.json'
    $run = Invoke-Create -Status ready -OutputPath $out -ArtifactPath @($artPath)
    Assert-True ($run.ExitCode -eq 0) "create: $($run.Raw)"
    $shape = $run.Raw | ConvertFrom-Json
    Assert-True ([string]$shape.schema_version -eq '1' -and [bool]$shape.written -eq $true) 'shape'
    Assert-True ([int]$shape.bytes -gt 0 -and (Test-Path -LiteralPath $shape.path)) 'path/bytes'
    $tmps = @(Get-ChildItem -LiteralPath $root -Filter 'atomic.json*.tmp' -ErrorAction SilentlyContinue)
    Assert-True ($tmps.Count -eq 0 -and -not (Test-Path -LiteralPath ($out + ".$PID.tmp"))) 'no tmp leftovers'
  }
}
finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($failed -eq 0) { Write-Host "Test-FleetReceiptValidation: $passed passed"; exit 0 }
Write-Host "Test-FleetReceiptValidation: $failed failed, $passed passed"
exit 1
