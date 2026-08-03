# Offline tests for Record-FleetLaneSpan.ps1 (no live model).
$ErrorActionPreference = 'Stop'
$recorder = Join-Path $PSScriptRoot 'Record-FleetLaneSpan.ps1'
$utf8 = [Text.UTF8Encoding]::new($false)
$passed = 0; $failed = 0

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function New-ValidSpan {
  param(
    [string]$RunId = 'run-1',
    [string]$LaneId = 'W1/T1',
    [object]$ResponseModel = 'grok-4.5',
    [object]$InputTokens = 100,
    [object]$OutputTokens = 50,
    [object]$CacheTokens = 10
  )
  [pscustomobject][ordered]@{
    schema_version = '1'
    run_id = $RunId
    lane_id = $LaneId
    phase = 'impl'
    'gen_ai.operation.name' = 'invoke_agent'
    'gen_ai.agent.name' = 'grok-4.5'
    'gen_ai.provider.name' = 'xai'
    'gen_ai.request.model' = 'grok-4.5'
    'gen_ai.response.model' = $ResponseModel
    'gen_ai.usage.input_tokens' = $InputTokens
    'gen_ai.usage.output_tokens' = $OutputTokens
    'gen_ai.usage.cache_read.input_tokens' = $CacheTokens
    tool_calls = 2
    inference_calls = 1
    duration_s = 10.5
    first_result_s = 1.2
    status = 'ok'
    'error.type' = $null
    handoff = [pscustomobject]@{ receipt_bytes = 100; verify_ms = 12.5; artifact_sha_ok = $true }
    artifacts = @(
      [pscustomobject]@{ path = 'a.txt'; bytes = 3; sha256 = ('a' * 64) }
    )
  }
}
function Write-Record($record, [string]$path) {
  [IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Depth 10 -Compress), $utf8)
}
function Invoke-Recorder([string]$RecordPath, [string]$OutputPath) {
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $recorder,
    '-RecordPath', $RecordPath, '-OutputPath', $OutputPath
  )
  $old = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $raw = & powershell.exe @args 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $old
  }
  return [pscustomobject]@{
    ExitCode = $code
    Raw = (($raw | ForEach-Object { "$_" }) -join "`n")
  }
}
function Get-FileByteCount([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return 0 }
  return [int64](Get-Item -LiteralPath $Path).Length
}

$temp = Join-Path $env:TEMP ('fleet-lane-span-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
  Case 'canonical readback round-trip' {
    $input = Join-Path $temp 'valid.json'
    $output = Join-Path $temp 'ledger-rt.jsonl'
    $span = New-ValidSpan
    Write-Record $span $input
    $run = Invoke-Recorder $input $output
    Assert-True ($run.ExitCode -eq 0) "recorder exit: $($run.Raw)"
    $lines = @([IO.File]::ReadAllLines($output, $utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-True ($lines.Count -eq 1) "expected 1 line, got $($lines.Count)"
    $saved = $lines[0] | ConvertFrom-Json
    Assert-True ([string]$saved.schema_version -eq '1') 'schema_version'
    Assert-True ([string]$saved.run_id -eq 'run-1') 'run_id'
    Assert-True ([string]$saved.lane_id -eq 'W1/T1') 'lane_id'
    Assert-True ([string]$saved.'gen_ai.operation.name' -eq 'invoke_agent') 'op name'
    Assert-True ([string]$saved.status -eq 'ok') 'status'
    Assert-True ([int64]$saved.tool_calls -eq 2) 'tool_calls'
    Assert-True ([double]$saved.duration_s -eq 10.5) 'duration_s'
    Assert-True ([double]$saved.first_result_s -eq 1.2) 'first_result_s'
    Assert-True ($null -eq $saved.'error.type') 'error.type null'
    Assert-True ([int64]$saved.handoff.receipt_bytes -eq 100) 'handoff.receipt_bytes'
    Assert-True ([bool]$saved.handoff.artifact_sha_ok -eq $true) 'handoff.artifact_sha_ok'
    Assert-True (@($saved.artifacts).Count -eq 1) 'artifacts count'
    Assert-True ([string](@($saved.artifacts)[0].sha256) -eq ('a' * 64)) 'sha256'
  }

  Case 'invalid input leaves ledger byte count unchanged' {
    $input = Join-Path $temp 'invalid.json'
    $output = Join-Path $temp 'ledger-inv.jsonl'
    $good = New-ValidSpan -RunId 'seed-run' -LaneId 'seed-lane'
    Write-Record $good $input
    $seed = Invoke-Recorder $input $output
    Assert-True ($seed.ExitCode -eq 0) "seed: $($seed.Raw)"
    $before = Get-FileByteCount $output
    Assert-True ($before -gt 0) 'seed ledger empty'
    $bad = New-ValidSpan -RunId 'bad-run' -LaneId 'bad-lane'
    $bad.status = 'not-a-status'
    Write-Record $bad $input
    $run = Invoke-Recorder $input $output
    Assert-True ($run.ExitCode -ne 0) "invalid accepted: $($run.Raw)"
    $after = Get-FileByteCount $output
    Assert-True ($after -eq $before) "ledger grew: before=$before after=$after"
  }

  Case 'null-model/null-usage fixture round-trips honestly' {
    $input = Join-Path $temp 'nulls.json'
    $output = Join-Path $temp 'ledger-nulls.jsonl'
    # Raw JSON keeps null keys (ConvertTo-Json can drop them in some PS hosts).
    $nullJson = '{"schema_version":"1","run_id":"null-run","lane_id":"null-lane","phase":"impl","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"grok-4.5","gen_ai.provider.name":"xai","gen_ai.request.model":"grok-4.5","gen_ai.response.model":null,"gen_ai.usage.input_tokens":null,"gen_ai.usage.output_tokens":null,"gen_ai.usage.cache_read.input_tokens":null,"tool_calls":2,"inference_calls":1,"duration_s":10.5,"first_result_s":null,"status":"ok","error.type":null,"handoff":null,"artifacts":[]}'
    [IO.File]::WriteAllText($input, $nullJson, $utf8)
    $run = Invoke-Recorder $input $output
    Assert-True ($run.ExitCode -eq 0) "null fixture: $($run.Raw)"
    $saved = ([IO.File]::ReadAllText($output, $utf8).Trim()) | ConvertFrom-Json
    Assert-True ($null -eq $saved.'gen_ai.response.model') 'response.model null'
    Assert-True ($null -eq $saved.'gen_ai.usage.input_tokens') 'input_tokens null'
    Assert-True ($null -eq $saved.'gen_ai.usage.output_tokens') 'output_tokens null'
    Assert-True ($null -eq $saved.'gen_ai.usage.cache_read.input_tokens') 'cache null'
    Assert-True ($null -eq $saved.first_result_s) 'first_result_s null'
    Assert-True ($null -eq $saved.handoff) 'handoff null'
    Assert-True (@($saved.artifacts).Count -eq 0 -or ($null -eq $saved.artifacts)) 'artifacts empty'
  }

  Case 'eight concurrent recorders append exactly 8 parseable rows' {
    $output = Join-Path $temp 'ledger-conc.jsonl'
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
    $procs = @()
    $inputs = @()
    for ($i = 0; $i -lt 8; $i++) {
      $inp = Join-Path $temp ("conc-$i.json")
      $span = New-ValidSpan -RunId ("conc-run-$i") -LaneId ("lane-$i")
      Write-Record $span $inp
      $inputs += $inp
      # Start-Process -PassThru reports blank ExitCode on PS5 for these children;
      # drive Diagnostics.Process directly so ExitCode is trustworthy.
      $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RecordPath "{1}" -OutputPath "{2}"' -f $recorder, $inp, $output
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = 'powershell.exe'
      $psi.Arguments = $argLine
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardError = $true
      $psi.RedirectStandardOutput = $false
      $procs += [pscustomobject]@{ Proc = [Diagnostics.Process]::Start($psi); ErrFile = (Join-Path $temp "conc-$i.err") }
    }
    $deadline = (Get-Date).AddSeconds(60)
    foreach ($entry in $procs) {
      $p = $entry.Proc
      $remaining = [int][math]::Max(1000, ($deadline - (Get-Date)).TotalMilliseconds)
      if (-not $p.WaitForExit($remaining)) {
        try { $p.Kill() } catch { }
        throw "concurrent recorder timed out pid=$($p.Id)"
      }
      $errText = $p.StandardError.ReadToEnd()
      if ($errText) { [IO.File]::WriteAllText($entry.ErrFile, $errText, $utf8) }
      $errTail = ''
      if (-not [string]::IsNullOrWhiteSpace($errText)) {
        $errTail = ' | stderr: ' + ((($errText -split "`r?`n") | Select-Object -First 3) -join ' ; ')
      }
      Assert-True ($p.ExitCode -eq 0) "concurrent exit $($p.ExitCode) pid=$($p.Id)$errTail"
    }
    Assert-True (Test-Path -LiteralPath $output) 'concurrent ledger missing'
    $rows = @()
    foreach ($line in [IO.File]::ReadAllLines($output, $utf8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $rows += ($line | ConvertFrom-Json)
    }
    Assert-True ($rows.Count -eq 8) "expected 8 rows, got $($rows.Count)"
    $ids = @($rows | ForEach-Object { "$($_.run_id)|$($_.lane_id)" } | Sort-Object -Unique)
    Assert-True ($ids.Count -eq 8) "unique identities=$($ids.Count)"
  }

  Case 'duplicate run_id+lane_id append exits 1' {
    $input = Join-Path $temp 'dup.json'
    $output = Join-Path $temp 'ledger-dup.jsonl'
    $span = New-ValidSpan -RunId 'dup-run' -LaneId 'dup-lane'
    Write-Record $span $input
    $first = Invoke-Recorder $input $output
    Assert-True ($first.ExitCode -eq 0) "first append: $($first.Raw)"
    $second = Invoke-Recorder $input $output
    Assert-True ($second.ExitCode -eq 1) "dup exit want 1 got $($second.ExitCode): $($second.Raw)"
    Assert-True ($second.Raw -match 'Duplicate') "dup message: $($second.Raw)"
    $n = @(@([IO.File]::ReadAllLines($output, $utf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })).Count
    Assert-True ($n -eq 1) "dup grew ledger to $n rows"
  }

  Case 'ledger first three bytes are not EF BB BF' {
    $input = Join-Path $temp 'bom.json'
    $output = Join-Path $temp 'ledger-bom.jsonl'
    Write-Record (New-ValidSpan -RunId 'bom-run' -LaneId 'bom-lane') $input
    $run = Invoke-Recorder $input $output
    Assert-True ($run.ExitCode -eq 0) "bom recorder: $($run.Raw)"
    $bytes = [IO.File]::ReadAllBytes($output)
    Assert-True ($bytes.Length -ge 3) 'ledger too short'
    $isBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-True (-not $isBom) ("BOM present: {0:X2} {1:X2} {2:X2}" -f $bytes[0], $bytes[1], $bytes[2])
  }

  Case 'case and junction aliases share one ledger mutex' {
    $dir = Join-Path $temp 'alias-dir'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ledgerLower = Join-Path $dir 'bench-lanes.jsonl'
    $ledgerUpper = Join-Path $dir 'BENCH-LANES.JSONL' # case alias of same file
    $inA = Join-Path $temp 'alias-a.json'; $inB = Join-Path $temp 'alias-b.json'
    Write-Record (New-ValidSpan -RunId 'alias-run' -LaneId 'lane-a') $inA
    Write-Record (New-ValidSpan -RunId 'alias-run' -LaneId 'lane-b') $inB
    function Start-Rec([string]$Inp, [string]$Out) {
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = 'powershell.exe'
      $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RecordPath "{1}" -OutputPath "{2}"' -f $recorder, $Inp, $Out
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $psi.RedirectStandardError = $true; $psi.RedirectStandardOutput = $false
      return [Diagnostics.Process]::Start($psi)
    }
    $pA = Start-Rec $inA $ledgerLower; $pB = Start-Rec $inB $ledgerUpper
    $deadline = (Get-Date).AddSeconds(60)
    foreach ($p in @($pA, $pB)) {
      $rem = [int][math]::Max(1000, ($deadline - (Get-Date)).TotalMilliseconds)
      if (-not $p.WaitForExit($rem)) { try { $p.Kill() } catch { }; throw "alias concurrent timed out pid=$($p.Id)" }
    }
    Assert-True ($pA.ExitCode -eq 0) "case alias A: $($pA.StandardError.ReadToEnd())"
    Assert-True ($pB.ExitCode -eq 0) "case alias B: $($pB.StandardError.ReadToEnd())"
    $rows = @([IO.File]::ReadAllLines($ledgerLower, $utf8) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($rows.Count -eq 2) "case alias expected 2 rows, got $($rows.Count)"
    $ids = @($rows | ForEach-Object { [string]$_.lane_id } | Sort-Object)
    Assert-True (($ids -join ',') -eq 'lane-a,lane-b') "case alias lanes: $($ids -join ',')"
    $inDup = Join-Path $temp 'alias-dup.json'
    Write-Record (New-ValidSpan -RunId 'alias-run' -LaneId 'lane-a') $inDup
    $dup = Invoke-Recorder $inDup $ledgerUpper
    Assert-True ($dup.ExitCode -eq 1 -and $dup.Raw -match 'Duplicate') "dup via alias: $($dup.Raw)"
    $n = @(@([IO.File]::ReadAllLines($ledgerLower, $utf8) | Where-Object { $_ })).Count
    Assert-True ($n -eq 2) "dup via alias grew ledger to $n"
    $juncPath = Join-Path $temp 'junc-link'; $juncOk = $false
    try { New-Item -ItemType Junction -Path $juncPath -Target $dir -ErrorAction Stop | Out-Null; $juncOk = $true }
    catch { Write-Host "SKIP junction alias half (New-Item Junction failed): $($_.Exception.Message)" }
    if ($juncOk) {
      $inJ = Join-Path $temp 'alias-j.json'
      Write-Record (New-ValidSpan -RunId 'alias-run' -LaneId 'lane-j') $inJ
      $jRun = Invoke-Recorder $inJ (Join-Path $juncPath 'bench-lanes.jsonl')
      Assert-True ($jRun.ExitCode -eq 0) "junction append: $($jRun.Raw)"
      $n2 = @(@([IO.File]::ReadAllLines($ledgerLower, $utf8) | Where-Object { $_ })).Count
      Assert-True ($n2 -eq 3) "junction expected 3 rows, got $n2"
      $dupJ = Invoke-Recorder $inJ $ledgerUpper
      Assert-True ($dupJ.ExitCode -eq 1 -and $dupJ.Raw -match 'Duplicate') "dup via junction: $($dupJ.Raw)"
    }
  }

  $total = $passed + $failed
  if ($total -eq 0) { Write-Host 'FAIL: suite collected 0 cases'; exit 1 }
  Write-Host "RESULT: $passed passed, $failed failed, $total total"
  if ($failed -gt 0) { exit 1 }
  exit 0
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
