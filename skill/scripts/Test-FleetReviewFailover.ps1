# Self-test Invoke-FleetReviewFailover.ps1. Injectable dispatch only; no live models.
# Prints selftest: PASS k/k. PS 5.1; UTF-8 no BOM.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$script:Helper = Join-Path $PSScriptRoot 'Invoke-FleetReviewFailover.ps1'
$script:Enter = Join-Path $PSScriptRoot 'Enter-FleetRunLease.ps1'
$script:ExitLease = Join-Path $PSScriptRoot 'Exit-FleetRunLease.ps1'
$script:AssertRi = Join-Path $PSScriptRoot 'Assert-FleetReviewIntegrity.ps1'
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
$script:passed = 0; $script:failed = 0; $script:total = 0
$script:temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-fo-' + [guid]::NewGuid().ToString('n'))
$script:oldProfile = $env:USERPROFILE
$script:oldHarness = $env:FLEET_TEST_HARNESS
$script:Fields = @('schema_version','receipt_type','run_id','task_id','lane_id','voice_id','review_role','requested_model','observed_model','model_evidence','emitter_id','input_packet_sha256','expected_lane_manifest_sha256','locked_plan_sha256','review_profile','charter_path','review_tier','result_path','charter_sha256','result_sha256','exit_code','outcome','refusal_reason','fallback_of','started_at','completed_at','sig_alg','key_id','signature')
$script:OkBody = "## Findings`n- none material`nVERDICT: CLEAR"
$script:RefuseBody = 'I cannot help with that request.'
$script:BlockBody = "## Adversarial review`nFinding: authz gap at scripts/x.ps1:10.`nVERDICT: BLOCK"
$script:PktSha = ('a' * 64); $script:PlanSha = ('d' * 64)

function Case([string]$Name, [scriptblock]$Body) {
  $script:total++
  try { & $Body; $script:passed++; Write-Host ("PASS {0}" -f $Name) }
  catch { $script:failed++; Write-Host ("FAIL {0} - {1}" -f $Name, $_.Exception.Message) }
}
function Assert-True([bool]$Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }
function Write-Utf8([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Get-Sha256Text([string]$Text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return (([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($Text))) -replace '-', '').ToLowerInvariant()) }
  finally { $sha.Dispose() }
}
function Get-Sha256File([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $fs = [IO.File]::OpenRead($Path); try { return (([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant()) } finally { $fs.Dispose() } }
  finally { $sha.Dispose() }
}
function Enter-Lease([string]$RunId) {
  $prev = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Enter -RunId $RunId 2>&1
    $code = $LASTEXITCODE
  }
  finally { $ErrorActionPreference = $prev }
  Assert-True ($code -eq 0) ("enter lease failed: $RunId")
}
function Exit-Lease([string]$RunId) {
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ExitLease -RunId $RunId 2>$null
}
function New-FakeTransport {
  param(
    [string]$Dir, [string]$Name, [string]$Response, [int]$ExitCode = 0,
    [string]$Model = 'grok-4.6', [string]$Observed = 'grok-4.6', [string]$Evidence = 'unified-log'
  )
  $respLit = $Response.Replace("'", "''")
  $modLit = $Model.Replace("'", "''"); $obsLit = $Observed.Replace("'", "''"); $evLit = $Evidence.Replace("'", "''")
  $body = @"
param([string]`$Prompt='', [string]`$PromptFile='', [ValidateSet('text','json')][string]`$Mode='text')
`$r=[ordered]@{status='ok';model='$modLit';observed_model='$obsLit';model_evidence='$evLit';response='$respLit';exit_code=$ExitCode}
if(`$Mode -eq 'json'){Write-Output (`$r|ConvertTo-Json -Compress)} else {Write-Output `$r.response}
exit $ExitCode
"@
  $p = Join-Path $Dir ($Name + '.ps1'); Write-Utf8 $p $body; return $p
}
function New-FakeKimi([string]$Dir, [string]$Response, [int]$ExitCode = 0) {
  return (New-FakeTransport $Dir 'Invoke-KimiK3' $Response $ExitCode 'kimi-code/k3' 'unobserved' 'requested-cli-argument+isolated-config')
}
function New-FakeGlm([string]$Dir, [string]$Response, [int]$ExitCode = 0) {
  return (New-FakeTransport $Dir 'Invoke-PiGlm' $Response $ExitCode 'glm-5.3' 'unobserved' 'cli-pinned-unobserved')
}
function New-FakeGrok([string]$Dir, [string]$Response, [int]$ExitCode = 0) {
  return (New-FakeTransport $Dir 'Invoke-Grok45' $Response $ExitCode 'grok-4.6' 'grok-4.6' 'unified-log')
}
function New-DualKimiGlm([string]$Dir, [string]$KimiResponse, [string]$GlmResponse) {
  New-FakeKimi $Dir $KimiResponse | Out-Null
  New-FakeGlm $Dir $GlmResponse | Out-Null
  return @{
    'Invoke-KimiK3' = (Join-Path $Dir 'Invoke-KimiK3.ps1')
    'Invoke-PiGlm' = (Join-Path $Dir 'Invoke-PiGlm.ps1')
  }
}
function Write-SignedParent {
  param(
    [string]$Dir, [string]$Name, [string]$RunId, [string]$LaneId, [string]$Model,
    [string]$Outcome, [string]$Body, [string]$CharterPath, [string]$ManifestSha,
    [string]$Refusal = $null, [int]$ExitCode = 0, [byte[]]$Secret = $null, [string]$KeyId = '',
    [string]$Started = '2026-08-05T01:00:00.0000000Z', [string]$Completed = '2026-08-05T01:05:00.0000000Z'
  )
  $rp = Join-Path $Dir ($Name + '.result.md'); Write-Utf8 $rp $Body
  $rsha = Get-Sha256File $rp
  $csha = Get-Sha256File $CharterPath
  if ($null -eq $Secret) {
    $k = Get-FleetRunLeaseKey -RunId $RunId; $Secret = $k.KeyBytes; $KeyId = $k.KeyId
  }
  $obj = [pscustomobject][ordered]@{
    schema_version = '2'; receipt_type = 'review_lane'; run_id = $RunId; task_id = 'T-sec'
    lane_id = $LaneId; voice_id = $Model; review_role = 'security-review'
    requested_model = $Model; observed_model = $Model; model_evidence = 'unified-log'
    emitter_id = 'test-emitter'; input_packet_sha256 = $script:PktSha
    expected_lane_manifest_sha256 = $ManifestSha; locked_plan_sha256 = $script:PlanSha
    review_profile = 'security-sensitive'; charter_path = $CharterPath; review_tier = 'FULL'
    result_path = $rp; charter_sha256 = $csha; result_sha256 = $rsha
    exit_code = $ExitCode; outcome = $Outcome; refusal_reason = $Refusal; fallback_of = $null
    started_at = $Started; completed_at = $Completed; sig_alg = 'HMAC-SHA256'; key_id = $KeyId
  }
  $sig = New-FleetReceiptSignature -Receipt $obj -ReceiptType 'review_lane' -RunSecret $Secret -KeyId $KeyId
  $parts = New-Object System.Collections.ArrayList
  foreach ($fk in $script:Fields) {
    if ($fk -eq 'signature') { [void]$parts.Add(('"{0}":{1}' -f $fk, (ConvertTo-Json -InputObject $sig -Compress))); continue }
    $v = $obj.$fk
    if ($null -eq $v) { [void]$parts.Add(('"{0}":null' -f $fk)) }
    else { [void]$parts.Add(('"{0}":{1}' -f $fk, (ConvertTo-Json -InputObject $v -Compress))) }
  }
  Write-Utf8 (Join-Path $Dir ($Name + '.json')) ('{' + ($parts -join ',') + '}')
}
function Write-SpanLine([string]$RunId, [string]$Lane, [string]$Model, [string]$Status, $ErrType = $null) {
  $err = if ($null -eq $ErrType -or [string]::IsNullOrEmpty([string]$ErrType)) { 'null' } else { '"' + $ErrType + '"' }
  return ('{"schema_version":"1","run_id":' + (ConvertTo-Json -InputObject $RunId -Compress) +
    ',"lane_id":' + (ConvertTo-Json -InputObject $Lane -Compress) +
    ',"phase":"review","gen_ai.operation.name":"invoke_agent","gen_ai.agent.name":"fleet","gen_ai.provider.name":"x","gen_ai.request.model":' +
    (ConvertTo-Json -InputObject $Model -Compress) + ',"gen_ai.response.model":' + (ConvertTo-Json -InputObject $Model -Compress) +
    ',"gen_ai.usage.input_tokens":1,"gen_ai.usage.output_tokens":1,"gen_ai.usage.cache_read.input_tokens":0,"tool_calls":0,"inference_calls":1,"duration_s":1.0,"first_result_s":0.5,"status":' +
    (ConvertTo-Json -InputObject $Status -Compress) + ',"error.type":' + $err + ',"handoff":null,"artifacts":null}')
}
function New-CaseDir([string]$Name) {
  $d = Join-Path $script:temp $Name
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $d 'receipts') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $d 'scripts') | Out-Null
  return $d
}
function Write-Base([string]$Dir, [string]$RunId, [string[]]$Lanes) {
  $parts = @(); foreach ($x in $Lanes) { $parts += (ConvertTo-Json -InputObject $x -Compress) }
  $p = Join-Path $Dir 'base-manifest.json'
  Write-Utf8 $p ('{"run_id":' + (ConvertTo-Json -InputObject $RunId -Compress) + ',"expected_lanes":[' + ($parts -join ',') + ']}')
  return $p
}
function Write-Plan([string]$Dir, $Rows) {
  $p = Join-Path $Dir 'failover-plan.json'
  $arr = @($Rows)
  # PS 5.1: force JSON array even for single row
  $json = ConvertTo-Json -InputObject $arr -Depth 4 -Compress
  if ($arr.Count -eq 1 -and $json -notmatch '^\s*\[') { $json = '[' + $json + ']' }
  Write-Utf8 $p $json
  return $p
}
function Invoke-Helper {
  param(
    [string]$RunId, [string]$Plan, [string]$ReceiptDir, [string]$Base, [string]$Span, [string]$OutMan,
    [hashtable]$Table, [string]$ScriptsRoot
  )
  $dtPath = Join-Path $ReceiptDir '_dispatch-table.json'
  if ($null -ne $Table -and $Table.Count -gt 0) {
    $ord = [ordered]@{}; foreach ($k in @($Table.Keys)) { $ord[[string]$k] = [string]$Table[$k] }
    Write-Utf8 $dtPath (($ord | ConvertTo-Json -Compress))
  }
  $argList = New-Object System.Collections.ArrayList
  foreach ($t in @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Helper,
      '-RunId', $RunId, '-FailoverPlan', $Plan, '-ReceiptDir', $ReceiptDir,
      '-BaseManifest', $Base, '-SpanLedger', $Span, '-OutputManifest', $OutMan,
      '-ScriptsRoot', $ScriptsRoot
    )) { [void]$argList.Add($t) }
  if (Test-Path -LiteralPath $dtPath) { [void]$argList.Add('-DispatchTablePath'); [void]$argList.Add($dtPath) }
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = (($argList | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
      }) -join ' ')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $script:temp
  $psi.EnvironmentVariables['FLEET_TEST_HARNESS'] = '1'
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
  $null = $p.Handle; $p.WaitForExit()
  $raw = ($out + "`n" + $err).Trim()
  $sum = ''
  foreach ($line in ($raw -split "`r?`n")) { if ($line.Trim() -like 'review-integrity:*') { $sum = $line.Trim(); break } }
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Raw = $raw; Summary = $sum }
}

try {
  New-Item -ItemType Directory -Force -Path $script:temp | Out-Null
  $env:USERPROFILE = $script:temp
  $env:FLEET_TEST_HARNESS = '1'
  $charter = Join-Path $script:temp 'charter.md'
  Write-Utf8 $charter "# charter`nfailover selftest body"

  Case 'AC1-refusal-dual-one-ok' {
    $runId = 'fo-ref-ok'; Enter-Lease $runId
    $d = New-CaseDir 'ac1-ok'
    $scripts = Join-Path $d 'scripts'
    $table = New-DualKimiGlm $scripts $script:RefuseBody $script:OkBody
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    $manSha = Get-Sha256File $base
    Write-SignedParent $rc 'sol' $runId 'v-sol-security' 'sol' 'refused' $script:RefuseBody $charter $manSha -Refusal 'policy_decline'
    $span = Join-Path $d 'spans.jsonl'
    Write-Utf8 $span (Write-SpanLine $runId 'v-sol-security' 'sol' 'error' 'model_refusal')
    $plan = Write-Plan $d @(
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-kimi-security-fb'; voice_id = 'kimi'; transport = 'Invoke-KimiK3' }
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' }
    )
    $outMan = Join-Path $d 'effective.json'
    $r = Invoke-Helper $runId $plan $rc $base $span $outMan $table $scripts
    Assert-True ($r.ExitCode -eq 0) ("exit $($r.ExitCode) raw=$($r.Raw)")
    Assert-True ($r.Summary -like 'review-integrity:*verdict: ok') ("summary: $($r.Summary)")
    Assert-True (Test-Path -LiteralPath $outMan) 'effective missing'
    $eff = [IO.File]::ReadAllText($outMan, $utf8) | ConvertFrom-Json
    $lanes = @($eff.expected_lanes | ForEach-Object { [string]$_ })
    Assert-True ($lanes -contains 'v-sol-security') 'base missing'
    Assert-True (($lanes -contains 'v-glm-security-fb') -or ($lanes -contains 'v-kimi-security-fb')) 'child missing from effective'
    Assert-True (Test-Path -LiteralPath (Join-Path $rc 'v-glm-security-fb.receipt.json')) 'glm receipt'
    Assert-True (Test-Path -LiteralPath (Join-Path $rc 'v-kimi-security-fb.receipt.json')) 'kimi receipt'
    $glmRec = Get-Content -LiteralPath (Join-Path $rc 'v-glm-security-fb.receipt.json') -Raw | ConvertFrom-Json
    Assert-True ([string]$glmRec.fallback_of -ceq 'v-sol-security') 'glm fallback_of'
    $origSha = Get-Sha256File $charter
    Assert-True ([string]$glmRec.charter_sha256 -ceq $origSha) 'child charter hash must match parent snapshot bytes'
    $glmRuntime = Join-Path $rc ('.fleet-charter-runtime-' + $runId)
    Assert-True ([IO.Path]::GetFullPath([string]$glmRec.charter_path) -ceq (Join-Path $glmRuntime 'v-glm-security-fb.charter.snapshot')) 'glm snapshot not in run-scoped runtime directory'
    Assert-True (Test-Path -LiteralPath ([string]$glmRec.charter_path)) 'glm charter snapshot missing'
    $spanText = [IO.File]::ReadAllText($span, $utf8)
    Assert-True ($spanText -match 'v-glm-security-fb') 'glm span'
    Assert-True ($spanText -match 'v-kimi-security-fb') 'kimi span'
    Write-Host ("  integrity: {0}" -f $r.Summary)
    Exit-Lease $runId
  }

  Case 'AC1-refusal-both-refuse-fail-closed' {
    $runId = 'fo-ref-both'; Enter-Lease $runId
    $d = New-CaseDir 'ac1-both'
    $scripts = Join-Path $d 'scripts'
    $table = New-DualKimiGlm $scripts $script:RefuseBody $script:RefuseBody
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    $manSha = Get-Sha256File $base
    Write-SignedParent $rc 'sol' $runId 'v-sol-security' 'sol' 'refused' $script:RefuseBody $charter $manSha -Refusal 'policy_decline'
    $span = Join-Path $d 'spans.jsonl'
    Write-Utf8 $span (Write-SpanLine $runId 'v-sol-security' 'sol' 'error' 'model_refusal')
    $plan = Write-Plan $d @(
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-kimi-security-fb'; voice_id = 'kimi'; transport = 'Invoke-KimiK3' }
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' }
    )
    $outMan = Join-Path $d 'effective.json'
    $r = Invoke-Helper $runId $plan $rc $base $span $outMan $table $scripts
    Assert-True ($r.ExitCode -ne 0) 'both refuse should fail closed'
    Assert-True ($r.Summary -like '*verdict: FAILED*' -or $r.Raw -match 'verdict: FAILED') ("want FAILED: $($r.Summary)")
    $spanText = [IO.File]::ReadAllText($span, $utf8)
    Assert-True ($spanText -match 'v-glm-security-fb') 'glm span on fail'
    Assert-True ($spanText -match 'v-kimi-security-fb') 'kimi span on fail'
    Exit-Lease $runId
  }

  Case 'AC2-transport-single-fallback' {
    $runId = 'fo-tx-ok'; Enter-Lease $runId
    $d = New-CaseDir 'ac2-tx'
    $scripts = Join-Path $d 'scripts'
    New-FakeGlm $scripts $script:OkBody
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-opus-security')
    $manSha = Get-Sha256File $base
    Write-SignedParent $rc 'opus' $runId 'v-opus-security' 'opus' 'failed' 'local transport failed' $charter $manSha -ExitCode 32
    $span = Join-Path $d 'spans.jsonl'
    Write-Utf8 $span (Write-SpanLine $runId 'v-opus-security' 'opus' 'error' 'transport_error')
    $plan = Write-Plan $d @(
      @{ fallback_of = 'v-opus-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' }
    )
    $table = @{ 'Invoke-PiGlm' = (Join-Path $scripts 'Invoke-PiGlm.ps1') }
    $outMan = Join-Path $d 'effective.json'
    $r = Invoke-Helper $runId $plan $rc $base $span $outMan $table $scripts
    $crecPath = Join-Path $rc 'v-glm-security-fb.receipt.json'
    Assert-True (Test-Path -LiteralPath $crecPath) 'child receipt missing'
    $crec = Get-Content -LiteralPath $crecPath -Raw | ConvertFrom-Json
    Assert-True ([string]$crec.fallback_of -ceq 'v-opus-security') 'child fallback_of'
    $key = Get-FleetRunLeaseKey -RunId $runId
    $cv = Test-FleetReceiptSignature -Receipt $crec -ReceiptType 'review_lane' -RunSecret $key.KeyBytes -KeyId $key.KeyId -Signature ([string]$crec.signature)
    Assert-True ($cv.ok) ("child sig: $($cv.reason)")
    $spanText = [IO.File]::ReadAllText($span, $utf8)
    Assert-True ($spanText -match 'v-glm-security-fb') 'child span'
    $d2 = New-CaseDir 'ac2-eff'
    $scripts2 = Join-Path $d2 'scripts'
    $table2 = New-DualKimiGlm $scripts2 $script:RefuseBody $script:OkBody
    $rc2 = Join-Path $d2 'receipts'
    $base2 = Write-Base $d2 $runId @('v-sol-security')
    $manSha2 = Get-Sha256File $base2
    Write-SignedParent $rc2 'sol' $runId 'v-sol-security' 'sol' 'refused' $script:RefuseBody $charter $manSha2 -Refusal 'policy_decline'
    $span2 = Join-Path $d2 'spans.jsonl'
    Write-Utf8 $span2 (Write-SpanLine $runId 'v-sol-security' 'sol' 'error' 'model_refusal')
    $plan2 = Write-Plan $d2 @(
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-kimi-security-fb'; voice_id = 'kimi'; transport = 'Invoke-KimiK3' }
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' }
    )
    $outMan2 = Join-Path $d2 'effective.json'
    $r2 = Invoke-Helper $runId $plan2 $rc2 $base2 $span2 $outMan2 $table2 $scripts2
    Assert-True ($r2.ExitCode -eq 0) ("eff exit $($r2.ExitCode) $($r2.Raw)")
    Assert-True (Test-Path -LiteralPath $outMan2) 'eff missing'
    $eff = [IO.File]::ReadAllText($outMan2, $utf8) | ConvertFrom-Json
    $lanes = @($eff.expected_lanes | ForEach-Object { [string]$_ })
    Assert-True (($lanes -contains 'v-sol-security') -and (($lanes -contains 'v-glm-security-fb') -or ($lanes -contains 'v-kimi-security-fb'))) "eff lanes $lanes"
    Write-Host ("  integrity: {0}" -f $r2.Summary)
    Exit-Lease $runId
  }

  Case 'reject-completed-negative' {
    $runId = 'fo-neg'; Enter-Lease $runId
    $d = New-CaseDir 'neg'
    $scripts = Join-Path $d 'scripts'
    New-FakeGlm $scripts $script:OkBody
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    $manSha = Get-Sha256File $base
    Write-SignedParent $rc 'sol' $runId 'v-sol-security' 'sol' 'completed' $script:BlockBody $charter $manSha
    $span = Join-Path $d 'spans.jsonl'; Write-Utf8 $span (Write-SpanLine $runId 'v-sol-security' 'sol' 'ok')
    $plan = Write-Plan $d @(@{ fallback_of = 'v-sol-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' })
    $table = @{ 'Invoke-PiGlm' = (Join-Path $scripts 'Invoke-PiGlm.ps1') }
    $r = Invoke-Helper $runId $plan $rc $base $span (Join-Path $d 'e.json') $table $scripts
    Assert-True ($r.ExitCode -ne 0) 'negative should reject'
    Assert-True ($r.Raw -match 'completed-negative|negative-verdict|not eligible') ("msg: $($r.Raw)")
    Exit-Lease $runId
  }

  Case 'reject-forged-parent' {
    $runId = 'fo-forge'; Enter-Lease $runId
    $d = New-CaseDir 'forge'
    $scripts = Join-Path $d 'scripts'
    $table = New-DualKimiGlm $scripts $script:OkBody $script:OkBody
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    $manSha = Get-Sha256File $base
    $badSecret = New-Object byte[] 32; for ($i = 0; $i -lt 32; $i++) { $badSecret[$i] = [byte](200 - $i) }
    Write-SignedParent $rc 'sol' $runId 'v-sol-security' 'sol' 'refused' $script:RefuseBody $charter $manSha -Refusal 'policy_decline' -Secret $badSecret -KeyId ('ff' + ('b' * 30))
    $span = Join-Path $d 'spans.jsonl'; Write-Utf8 $span (Write-SpanLine $runId 'v-sol-security' 'sol' 'error' 'model_refusal')
    $plan = Write-Plan $d @(
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-kimi-security-fb'; voice_id = 'kimi'; transport = 'Invoke-KimiK3' }
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' }
    )
    $r = Invoke-Helper $runId $plan $rc $base $span (Join-Path $d 'e.json') $table $scripts
    Assert-True ($r.ExitCode -ne 0) 'forged should reject'
    Assert-True ($r.Raw -match 'forged|unverifiable|signature') ("msg: $($r.Raw)")
    Exit-Lease $runId
  }

  Case 'reject-duplicate-lane-id' {
    $runId = 'fo-dup'; Enter-Lease $runId
    $d = New-CaseDir 'dup'
    $scripts = Join-Path $d 'scripts'
    $table = New-DualKimiGlm $scripts $script:OkBody $script:OkBody
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    $manSha = Get-Sha256File $base
    Write-SignedParent $rc 'sol' $runId 'v-sol-security' 'sol' 'refused' $script:RefuseBody $charter $manSha -Refusal 'policy_decline'
    $span = Join-Path $d 'spans.jsonl'; Write-Utf8 $span (Write-SpanLine $runId 'v-sol-security' 'sol' 'error' 'model_refusal')
    $plan = Write-Plan $d @(
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-same'; voice_id = 'kimi'; transport = 'Invoke-KimiK3' }
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-same'; voice_id = 'glm'; transport = 'Invoke-PiGlm' }
    )
    $r = Invoke-Helper $runId $plan $rc $base $span (Join-Path $d 'e.json') $table $scripts
    Assert-True ($r.ExitCode -ne 0) 'dup should reject'
    Assert-True ($r.Raw -match 'duplicate lane_id') ("msg: $($r.Raw)")
    Exit-Lease $runId
  }

  Case 'reject-byte-different-charter' {
    $runId = 'fo-char'; Enter-Lease $runId
    $d = New-CaseDir 'char'
    $scripts = Join-Path $d 'scripts'
    $table = New-DualKimiGlm $scripts $script:OkBody $script:OkBody
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    $manSha = Get-Sha256File $base
    Write-SignedParent $rc 'sol' $runId 'v-sol-security' 'sol' 'refused' $script:RefuseBody $charter $manSha -Refusal 'policy_decline'
    Write-Utf8 $charter "# charter`nMUTATED BYTES"
    $span = Join-Path $d 'spans.jsonl'; Write-Utf8 $span (Write-SpanLine $runId 'v-sol-security' 'sol' 'error' 'model_refusal')
    $plan = Write-Plan $d @(
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-kimi-security-fb'; voice_id = 'kimi'; transport = 'Invoke-KimiK3' }
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' }
    )
    $r = Invoke-Helper $runId $plan $rc $base $span (Join-Path $d 'e.json') $table $scripts
    Assert-True ($r.ExitCode -ne 0) 'charter mismatch should reject'
    Assert-True ($r.Raw -match 'byte-different charter') ("msg: $($r.Raw)")
    Write-Utf8 $charter "# charter`nfailover selftest body"
    Exit-Lease $runId
  }

  Case 'reject-non-allowlisted-transport' {
    $runId = 'fo-txbad'; Enter-Lease $runId
    $d = New-CaseDir 'txbad'
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    $manSha = Get-Sha256File $base
    Write-SignedParent $rc 'sol' $runId 'v-sol-security' 'sol' 'refused' $script:RefuseBody $charter $manSha -Refusal 'policy_decline'
    $span = Join-Path $d 'spans.jsonl'; Write-Utf8 $span (Write-SpanLine $runId 'v-sol-security' 'sol' 'error' 'model_refusal')
    $plan = Write-Plan $d @(
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-kimi-security-fb'; voice_id = 'kimi'; transport = 'Invoke-Evil' }
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' }
    )
    $r = Invoke-Helper $runId $plan $rc $base $span (Join-Path $d 'e.json') @{} (Join-Path $d 'scripts')
    Assert-True ($r.ExitCode -ne 0) 'evil transport should reject'
    Assert-True ($r.Raw -match 'non-allowlisted transport') ("msg: $($r.Raw)")
    Exit-Lease $runId
  }

  Case 'reject-missing-lease-key' {
    $runId = 'fo-nolease'
    $d = New-CaseDir 'nolease'
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    Write-Utf8 (Join-Path $rc 'sol.json') '{"schema_version":"2","lane_id":"v-sol-security"}'
    $span = Join-Path $d 'spans.jsonl'; Write-Utf8 $span ''
    $plan = Write-Plan $d @(@{ fallback_of = 'v-sol-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' })
    $r = Invoke-Helper $runId $plan $rc $base $span (Join-Path $d 'e.json') @{} (Join-Path $d 'scripts')
    Assert-True ($r.ExitCode -ne 0) 'missing lease should reject'
    Assert-True ($r.Raw -match 'lease key') ("msg: $($r.Raw)")
  }

  Case 'AC4-span-on-failed-child' {
    $runId = 'fo-span-err'; Enter-Lease $runId
    $d = New-CaseDir 'spanerr'
    $scripts = Join-Path $d 'scripts'
    $table = New-DualKimiGlm $scripts 'boom' 'boom'
    # Force nonzero exit on both fakes
    New-FakeKimi $scripts 'boom' 1 | Out-Null
    New-FakeGlm $scripts 'boom' 1 | Out-Null
    $table = @{
      'Invoke-KimiK3' = (Join-Path $scripts 'Invoke-KimiK3.ps1')
      'Invoke-PiGlm' = (Join-Path $scripts 'Invoke-PiGlm.ps1')
    }
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    $manSha = Get-Sha256File $base
    Write-SignedParent $rc 'sol' $runId 'v-sol-security' 'sol' 'refused' $script:RefuseBody $charter $manSha -Refusal 'policy_decline'
    $span = Join-Path $d 'spans.jsonl'
    Write-Utf8 $span (Write-SpanLine $runId 'v-sol-security' 'sol' 'error' 'model_refusal')
    $plan = Write-Plan $d @(
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-kimi-security-fb'; voice_id = 'kimi'; transport = 'Invoke-KimiK3' }
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' }
    )
    $null = Invoke-Helper $runId $plan $rc $base $span (Join-Path $d 'e.json') $table $scripts
    $spanText = [IO.File]::ReadAllText($span, $utf8)
    Assert-True ($spanText -match 'v-glm-security-fb') 'glm span present'
    Assert-True ($spanText -match 'v-kimi-security-fb') 'kimi span present'
    Assert-True ($spanText -match '"status":"error"') 'error status on failed child span'
    Exit-Lease $runId
  }

  Case 'reject-voice-transport-mismatch' {
    $runId = 'fo-vbind'; Enter-Lease $runId
    $d = New-CaseDir 'vbind'
    $scripts = Join-Path $d 'scripts'
    New-FakeGrok $scripts $script:OkBody
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    $manSha = Get-Sha256File $base
    Write-SignedParent $rc 'sol' $runId 'v-sol-security' 'sol' 'refused' $script:RefuseBody $charter $manSha -Refusal 'policy_decline'
    $span = Join-Path $d 'spans.jsonl'; Write-Utf8 $span (Write-SpanLine $runId 'v-sol-security' 'sol' 'error' 'model_refusal')
    $plan = Write-Plan $d @(
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-kimi-security-fb'; voice_id = 'kimi'; transport = 'Invoke-Grok45' }
      @{ fallback_of = 'v-sol-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' }
    )
    $table = @{ 'Invoke-Grok45' = (Join-Path $scripts 'Invoke-Grok45.ps1') }
    $r = Invoke-Helper $runId $plan $rc $base $span (Join-Path $d 'e.json') $table $scripts
    Assert-True ($r.ExitCode -ne 0) 'voice-transport mismatch should reject'
    Assert-True ($r.Raw -match 'voice-transport mismatch') ("msg: $($r.Raw)")
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $rc 'v-kimi-security-fb.receipt.json'))) 'no dispatch receipt'
    Exit-Lease $runId
  }

  Case 'reject-lane-id-path-escape' {
    $runId = 'fo-path'; Enter-Lease $runId
    $d = New-CaseDir 'path'
    $scripts = Join-Path $d 'scripts'
    New-FakeGlm $scripts $script:OkBody
    $rc = Join-Path $d 'receipts'
    $base = Write-Base $d $runId @('v-sol-security')
    $manSha = Get-Sha256File $base
    Write-SignedParent $rc 'sol' $runId 'v-sol-security' 'sol' 'refused' $script:RefuseBody $charter $manSha -Refusal 'policy_decline'
    $span = Join-Path $d 'spans.jsonl'; Write-Utf8 $span (Write-SpanLine $runId 'v-sol-security' 'sol' 'error' 'model_refusal')
    # Grammar rejects separators / rooted escapes.
    $plan = Write-Plan $d @(@{ fallback_of = 'v-sol-security'; lane_id = '..\evil'; voice_id = 'glm'; transport = 'Invoke-PiGlm' })
    $table = @{ 'Invoke-PiGlm' = (Join-Path $scripts 'Invoke-PiGlm.ps1') }
    $r = Invoke-Helper $runId $plan $rc $base $span (Join-Path $d 'e.json') $table $scripts
    Assert-True ($r.ExitCode -ne 0) 'path escape should reject'
    Assert-True ($r.Raw -match 'lane_id grammar|path escapes|receipt leaf') ("msg: $($r.Raw)")
    Exit-Lease $runId
  }

  Case 'charter-snapshot-immune-to-source-mutation' {
    $runId = 'fo-snap'; Enter-Lease $runId
    $d = New-CaseDir 'snap'
    $scripts = Join-Path $d 'scripts'
    $rc = Join-Path $d 'receipts'
    # Transport parent (failed) allows single fallback row.
    $base = Write-Base $d $runId @('v-opus-security')
    $manSha = Get-Sha256File $base
    $localCharter = Join-Path $d 'charter.md'
    $origBody = "# charter`nsnapshot selftest body"
    Write-Utf8 $localCharter $origBody
    $origSha = Get-Sha256Text $origBody
    Write-SignedParent $rc 'opus' $runId 'v-opus-security' 'opus' 'failed' 'local transport failed' $localCharter $manSha -ExitCode 32
    $charLit = $localCharter.Replace("'", "''")
    $respLit = $script:OkBody.Replace("'", "''")
    $fakeBody = @"
param([string]`$Prompt='', [string]`$PromptFile='', [ValidateSet('text','json')][string]`$Mode='text')
[IO.File]::WriteAllText('$charLit', "# charter``nMUTATED DURING DISPATCH")
`$r=[ordered]@{status='ok';model='glm-5.3';observed_model='unobserved';model_evidence='cli-pinned-unobserved';response='$respLit';exit_code=0}
if(`$Mode -eq 'json'){Write-Output (`$r|ConvertTo-Json -Compress)} else {Write-Output `$r.response}
exit 0
"@
    Write-Utf8 (Join-Path $scripts 'Invoke-PiGlm.ps1') $fakeBody
    $span = Join-Path $d 'spans.jsonl'
    Write-Utf8 $span (Write-SpanLine $runId 'v-opus-security' 'opus' 'error' 'transport_error')
    $plan = Write-Plan $d @(@{ fallback_of = 'v-opus-security'; lane_id = 'v-glm-security-fb'; voice_id = 'glm'; transport = 'Invoke-PiGlm' })
    $table = @{ 'Invoke-PiGlm' = (Join-Path $scripts 'Invoke-PiGlm.ps1') }
    $r = Invoke-Helper $runId $plan $rc $base $span (Join-Path $d 'e.json') $table $scripts
    Assert-True (Test-Path -LiteralPath (Join-Path $rc 'v-glm-security-fb.receipt.json')) ("receipt missing raw=$($r.Raw)")
    $crec = Get-Content -LiteralPath (Join-Path $rc 'v-glm-security-fb.receipt.json') -Raw | ConvertFrom-Json
    Assert-True ([string]$crec.charter_sha256 -ceq $origSha) ("signed hash must be pre-mutation; got $($crec.charter_sha256)")
    $snapPath = [string]$crec.charter_path
    Assert-True (Test-Path -LiteralPath $snapPath) 'snapshot path missing'
    Assert-True ((Get-Sha256File $snapPath) -ceq $origSha) 'snapshot bytes mutated'
    Assert-True ((Get-Sha256File $localCharter) -cne $origSha) 'source should have been mutated by fake'
    Exit-Lease $runId
  }
}
finally {
  $env:USERPROFILE = $script:oldProfile
  $env:FLEET_TEST_HARNESS = $script:oldHarness
  if (Test-Path -LiteralPath $script:temp) {
    Remove-Item -LiteralPath $script:temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ("selftest: PASS {0}/{1}" -f $script:passed, $script:total)
if ($script:failed -gt 0) {
  Write-Host ("selftest: FAIL {0}/{1}" -f $script:failed, $script:total)
  exit 1
}
exit 0
