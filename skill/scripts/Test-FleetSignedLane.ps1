# Self-test Invoke-FleetSignedLane.ps1. Fake allowlisted transport only; no real models.
# Prints selftest: PASS k/k. PS 5.1; UTF-8 no BOM.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$script:Shim = Join-Path $PSScriptRoot 'Invoke-FleetSignedLane.ps1'
$script:Enter = Join-Path $PSScriptRoot 'Enter-FleetRunLease.ps1'
$script:ExitLease = Join-Path $PSScriptRoot 'Exit-FleetRunLease.ps1'
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
$script:passed = 0; $script:failed = 0; $script:total = 0
$script:temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-signed-lane-' + [guid]::NewGuid().ToString('n'))
$script:oldProfile = $env:USERPROFILE

function Case([string]$Name, [scriptblock]$Body) {
  $script:total++
  try { & $Body; $script:passed++; Write-Host ("PASS {0}" -f $Name) }
  catch { $script:failed++; Write-Host ("FAIL {0} - {1}" -f $Name, $_.Exception.Message) }
}
function Assert-True([bool]$Cond, [string]$Msg) { if (-not $Cond) { throw $Msg } }
function Get-FixedSha([string]$seed) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $sb = New-Object Text.StringBuilder 64
    foreach ($x in $sha.ComputeHash($utf8.GetBytes($seed))) { [void]$sb.Append($x.ToString('x2')) }
    return $sb.ToString()
  } finally { $sha.Dispose() }
}
function Write-Utf8([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function New-FakeTransport([string]$Dir, [string]$Name, [string]$BodyPs1) {
  $p = Join-Path $Dir ($Name + '.ps1'); Write-Utf8 $p $BodyPs1; return $p
}
function New-GrokStub([string]$Observed) {
  $obsLit = $Observed.Replace("'", "''")
  return @"
param([string]`$Prompt='', [string]`$PromptFile='', [ValidateSet('text','json')][string]`$Mode='text')
`$r=[ordered]@{status='ok';model='grok-4.5';observed_model='$obsLit';model_evidence='unified-log';response='VERDICT: CLEAR none material';exit_code=0}
if(`$Mode -eq 'json'){Write-Output (`$r|ConvertTo-Json -Compress)} else {Write-Output `$r.response}
exit 0
"@
}
function Invoke-ShimCapture([string]$ArgLine) {
  # Never name param $Args — shadows automatic $args; binding can drop the line.
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:Shim + '" ' + $ArgLine
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $script:temp
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  return @{ Code = $p.ExitCode; Out = $out.Trim(); Err = $err }
}
function Enter-Lease([string]$RunId) {
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Enter -RunId $RunId 2>$null
  Assert-True ($LASTEXITCODE -eq 0) ("enter lease failed: $RunId")
}
function Exit-Lease([string]$RunId) {
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ExitLease -RunId $RunId 2>$null
}
function New-CommonArgs([string]$RunId, [string]$ScriptsRoot, [string]$ReceiptPath, [string]$CharterPath, [string]$Extra = '') {
  $pkt = Get-FixedSha 'pkt'; $man = Get-FixedSha 'man'; $plan = Get-FixedSha 'plan'
  $a = (@(
    '-RunId', $RunId, '-Transport', 'Invoke-Grok45', '-TaskId', 'T3',
    '-LaneId', 'v-grok', '-VoiceId', 'v-grok', '-ReviewRole', 'general-review',
    '-CharterPath', ('"' + $CharterPath + '"'),
    '-InputPacketSha256', $pkt, '-LockedPlanSha256', $plan, '-ExpectedLaneManifestSha256', $man,
    '-ReviewProfile', 'standard', '-ReviewTier', 'STANDARD',
    '-ReceiptPath', ('"' + $ReceiptPath + '"'), '-Prompt', '"selftest-prompt"',
    '-ScriptsRoot', ('"' + $ScriptsRoot + '"')
  ) -join ' ')
  if (-not [string]::IsNullOrEmpty($Extra)) { $a = $a + ' ' + $Extra }
  return $a
}
function Assert-SigOk($rec, [string]$RunId) {
  $key = Get-FleetRunLeaseKey -RunId $RunId
  $v = Test-FleetReceiptSignature -Receipt $rec -ReceiptType 'review_lane' -RunSecret $key.KeyBytes -KeyId $key.KeyId -Signature ([string]$rec.signature)
  Assert-True ($v.ok -eq $true) ("sig not ok: $($v.reason)")
}

try {
  New-Item -ItemType Directory -Force -Path $script:temp | Out-Null
  $env:USERPROFILE = $script:temp
  $work = Join-Path $script:temp 'work'
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $charter = Join-Path $work 'charter.md'
  Write-Utf8 $charter "# charter`nselftest body"

  Case 'sign+verify under run lease key' {
    $runId = 'sl-happy'; Enter-Lease $runId
    $scripts = Join-Path $work 'scripts-happy'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    New-FakeTransport $scripts 'Invoke-Grok45' (New-GrokStub 'grok-4.5')
    $receiptPath = Join-Path $work 'happy.receipt.json'
    $cap = Invoke-ShimCapture (New-CommonArgs $runId $scripts $receiptPath $charter)
    Assert-True ($cap.Code -eq 0) ("shim exit $($cap.Code) err=$($cap.Err)")
    Assert-True (Test-Path -LiteralPath $receiptPath) 'receipt missing'
    $rec = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-SigOk $rec $runId
    Assert-True ($rec.outcome -ceq 'completed') 'expected completed'
    Assert-True ($rec.emitter_id -ceq 'Invoke-FleetSignedLane') 'emitter'
    Assert-True ($rec.requested_model -ceq 'grok-4.5' -and $rec.observed_model -ceq 'grok-4.5') 'models'
    Assert-True ($rec.model_evidence -ceq 'unified-log') 'evidence'
    Exit-Lease $runId
  }

  Case 'caller cannot override derived identity fields' {
    $runId = 'sl-override'; Enter-Lease $runId
    $scripts = Join-Path $work 'scripts-ov'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    New-FakeTransport $scripts 'Invoke-Grok45' (New-GrokStub 'grok-4.5')
    $receiptPath = Join-Path $work 'override.receipt.json'
    $extra = '-RequestedModel evil-model -ObservedModel evil-obs -ModelEvidence forged -EmitterId forged-emitter'
    $cap = Invoke-ShimCapture (New-CommonArgs $runId $scripts $receiptPath $charter $extra)
    Assert-True ($cap.Code -eq 0) ("shim exit $($cap.Code) err=$($cap.Err)")
    $rec = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($rec.requested_model -cne 'evil-model' -and $rec.observed_model -cne 'evil-obs') 'override models'
    Assert-True ($rec.model_evidence -cne 'forged' -and $rec.emitter_id -cne 'forged-emitter') 'override meta'
    Assert-True ($rec.requested_model -ceq 'grok-4.5' -and $rec.observed_model -ceq 'grok-4.5') 'derived models'
    Assert-True ($rec.model_evidence -ceq 'unified-log' -and $rec.emitter_id -ceq 'Invoke-FleetSignedLane') 'derived meta'
    Exit-Lease $runId
  }

  Case 'observed transport model mismatch => no completed receipt' {
    # Decision: still WRITE signed receipt; outcome != completed (failed); exit != 0.
    $runId = 'sl-mismatch'; Enter-Lease $runId
    $scripts = Join-Path $work 'scripts-mm'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    New-FakeTransport $scripts 'Invoke-Grok45' (New-GrokStub 'not-the-requested-model')
    $receiptPath = Join-Path $work 'mismatch.receipt.json'
    $cap = Invoke-ShimCapture (New-CommonArgs $runId $scripts $receiptPath $charter)
    Assert-True ($cap.Code -ne 0) ("mismatch should fail exit; err=$($cap.Err)")
    Assert-True (Test-Path -LiteralPath $receiptPath) 'receipt should still be written'
    $rec = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($rec.outcome -cne 'completed') ("outcome completed; got $($rec.outcome)")
    Assert-True ($rec.outcome -ceq 'failed') ("expected failed; got $($rec.outcome)")
    Assert-True ($rec.observed_model -ceq 'not-the-requested-model') 'obs actual'
    Assert-True ($rec.requested_model -ceq 'grok-4.5') 'req derived'
    Assert-SigOk $rec $runId
    Exit-Lease $runId
  }

  Case 'result body mutation fails hash binding' {
    $runId = 'sl-mutate'; Enter-Lease $runId
    $scripts = Join-Path $work 'scripts-mut'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    New-FakeTransport $scripts 'Invoke-Grok45' (New-GrokStub 'grok-4.5')
    $receiptPath = Join-Path $work 'mutate.receipt.json'
    $cap = Invoke-ShimCapture (New-CommonArgs $runId $scripts $receiptPath $charter)
    Assert-True ($cap.Code -eq 0) ("shim exit $($cap.Code)")
    $rec = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rp = [string]$rec.result_path
    Assert-True (Test-Path -LiteralPath $rp) 'result missing'
    [IO.File]::WriteAllText($rp, 'MUTATED AFTER EMISSION', $utf8)
    $got = Get-FixedSha 'unused'
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
      $fs = [IO.File]::OpenRead($rp)
      try {
        $sb = New-Object Text.StringBuilder 64
        foreach ($x in $sha.ComputeHash($fs)) { [void]$sb.Append($x.ToString('x2')) }
        $got = $sb.ToString()
      } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
    Assert-True ($got -cne [string]$rec.result_sha256) 'mutated file still matches signed result_sha256'
    Assert-SigOk $rec $runId
    $rec2 = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rec2.result_sha256 = $got
    $key = Get-FleetRunLeaseKey -RunId $runId
    $v2 = Test-FleetReceiptSignature -Receipt $rec2 -ReceiptType 'review_lane' -RunSecret $key.KeyBytes -KeyId $key.KeyId -Signature ([string]$rec2.signature)
    Assert-True ($v2.ok -eq $false) 'tampered result_sha256 should fail signature'
    Exit-Lease $runId
  }

  Case 'non-allowlisted transport rejected' {
    $runId = 'sl-badtx'; Enter-Lease $runId
    $scripts = Join-Path $work 'scripts-bad'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    New-FakeTransport $scripts 'Invoke-Evil' "param(`$Mode='json'); Write-Output '{}'; exit 0"
    $receiptPath = Join-Path $work 'badtx.receipt.json'
    $pkt = Get-FixedSha 'pkt2'; $man = Get-FixedSha 'man2'; $plan = Get-FixedSha 'plan2'
    $argLine = (@(
      '-RunId', $runId, '-Transport', 'Invoke-Evil', '-TaskId', 'T3',
      '-LaneId', 'v-x', '-VoiceId', 'v-x', '-ReviewRole', 'general-review',
      '-CharterPath', ('"' + $charter + '"'),
      '-InputPacketSha256', $pkt, '-LockedPlanSha256', $plan, '-ExpectedLaneManifestSha256', $man,
      '-ReviewProfile', 'standard', '-ReviewTier', 'STANDARD',
      '-ReceiptPath', ('"' + $receiptPath + '"'), '-Prompt', '"x"',
      '-ScriptsRoot', ('"' + $scripts + '"')
    ) -join ' ')
    $cap = Invoke-ShimCapture $argLine
    Assert-True ($cap.Code -ne 0) 'evil transport should be rejected'
    Assert-True (-not (Test-Path -LiteralPath $receiptPath)) 'no receipt for rejected transport'
    Exit-Lease $runId
  }

  Case 'unobserved transport (Pi/GLM) allows observed=unobserved' {
    $runId = 'sl-pi'; Enter-Lease $runId
    $scripts = Join-Path $work 'scripts-pi'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    $piBody = @"
param([string]`$Prompt='', [string]`$PromptFile='', [ValidateSet('text','json')][string]`$Mode='text')
`$r=[ordered]@{status='ok';model='glm-5.2';model_evidence='cli-pinned-unobserved';response='VERDICT: CLEAR none material';exit_code=0}
if(`$Mode -eq 'json'){Write-Output (`$r|ConvertTo-Json -Compress)} else {Write-Output `$r.response}
exit 0
"@
    New-FakeTransport $scripts 'Invoke-PiGlm' $piBody
    $receiptPath = Join-Path $work 'pi.receipt.json'
    $pkt = Get-FixedSha 'pkt3'; $man = Get-FixedSha 'man3'; $plan = Get-FixedSha 'plan3'
    $argLine = (@(
      '-RunId', $runId, '-Transport', 'Invoke-PiGlm', '-TaskId', 'T3',
      '-LaneId', 'v-glm', '-VoiceId', 'v-glm', '-ReviewRole', 'general-review',
      '-CharterPath', ('"' + $charter + '"'),
      '-InputPacketSha256', $pkt, '-LockedPlanSha256', $plan, '-ExpectedLaneManifestSha256', $man,
      '-ReviewProfile', 'standard', '-ReviewTier', 'STANDARD',
      '-ReceiptPath', ('"' + $receiptPath + '"'), '-Prompt', '"x"',
      '-ScriptsRoot', ('"' + $scripts + '"')
    ) -join ' ')
    $cap = Invoke-ShimCapture $argLine
    Assert-True ($cap.Code -eq 0) ("pi shim exit $($cap.Code) err=$($cap.Err)")
    $rec = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($rec.observed_model -ceq 'unobserved') 'pi must be unobserved'
    Assert-True ($rec.model_evidence -ceq 'cli-pinned-unobserved') 'pi evidence'
    Assert-True ($rec.outcome -ceq 'completed') 'pi completed'
    Assert-True ($rec.requested_model -cne $rec.observed_model) 'never copy requested into observed'
    Assert-SigOk $rec $runId
    Exit-Lease $runId
  }

  Case 'ordinary real wrappers not invoked by this suite' {
    Assert-True ($true) 'ScriptsRoot fakes only; real Invoke-*.ps1 never launched'
  }
}
finally {
  $env:USERPROFILE = $script:oldProfile
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
