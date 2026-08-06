# Self-test for New-FleetMergeReadinessReceipt.ps1 (+ reducer accept path). v2 signed.
# Exit 0: selftest: PASS k/k. Exit 1 on first failure.
$ErrorActionPreference = 'Stop'
$script:ShaOk = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:ShaPlan = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
$script:ShaChar = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
$script:Emitter = Join-Path $PSScriptRoot 'New-FleetMergeReadinessReceipt.ps1'
$script:Assert = Join-Path $PSScriptRoot 'Assert-FleetMergeReadiness.ps1'
$script:Stages = @('change-map', 'synthesis', 'adversarial-challenge', 'triage')
$script:pass = 0; $script:total = 0
$script:TestSecret = New-Object byte[] 32
for ($i = 0; $i -lt 32; $i++) { $script:TestSecret[$i] = [byte](50 + $i) }
$script:TestKeyId = 'fedcba9876543210fedcba9876543210'
$script:TestRunId = 'emr-st-' + [guid]::NewGuid().ToString('n').Substring(0, 12)
$script:LeaseDir = Join-Path $env:USERPROFILE '.codex\fleet\run-leases'
$script:LeasePath = Join-Path $script:LeaseDir ($script:TestRunId + '.json')
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetSignedTest.Helpers.ps1')
$script:StageSetSha = Get-StageSetSha $script:Stages
# M2: real result file; result_sha256 must match file bytes (not phantom C:\tmp\result.md).
$script:ResultFixtureDir = Join-Path ([IO.Path]::GetTempPath()) ('flt-emr-res-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:ResultFixtureDir -Force | Out-Null
$script:ResultFixturePath = Join-Path $script:ResultFixtureDir 'result.md'
[IO.File]::WriteAllText($script:ResultFixturePath, "fleet-emr-result-fixture`n", $script:FstUtf8)
$script:ShaRes = Get-FileSha $script:ResultFixturePath
function Fail([string]$Msg) { Write-Output ("selftest: FAIL {0}" -f $Msg); exit 1 }
function Pass([string]$Name) { $script:pass++; Write-Output ("PASS {0}" -f $Name) }
function New-TempDir([string]$Tag) {
  $d = Join-Path ([IO.Path]::GetTempPath()) ('flt-emr-' + $Tag + '-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path $d -Force | Out-Null; return $d
}
function Invoke-Emitter {
  param(
    [string]$RunId = '', [string]$Stage, [string]$Required = 'true',
    [string]$Status = 'passed', [string]$ObservedModel = 'test-model',
    [string]$Effort = 'high', [string]$InputPacketSha256 = $script:ShaOk,
    [string]$FallbackOf = '', [string]$FailureCategory = '',
    [string]$FindingsPath = '', [string[]]$EvidenceRef = @('trigger:ok'),
    [string[]]$OutputArtifact = @(),
    [string]$StartedAt = '2026-08-05T00:00:00Z', [string]$CompletedAt = '2026-08-05T00:01:00Z',
    [string]$Model = 'test-model', [string]$OutputPath,
    [string]$StageSetSha256 = '', [string]$TaskId = 'task-1', [string]$LaneId = 'lane-1'
  )
  if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = $script:TestRunId }
  if ([string]::IsNullOrWhiteSpace($StageSetSha256)) { $StageSetSha256 = $script:StageSetSha }
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Emitter,
    '-RunId', $RunId, '-TaskId', $TaskId, '-LaneId', $LaneId, '-Stage', $Stage, '-Required', $Required,
    '-Status', $Status, '-Model', $Model, '-ObservedModel', $ObservedModel, '-ModelEvidence', 'test-evidence',
    '-Effort', $Effort, '-InputPacketSha256', $InputPacketSha256, '-EmitterId', 'test-emitter',
    '-LockedPlanSha256', $script:ShaPlan, '-StageSetSha256', $StageSetSha256,
    '-ReviewTier', 'STANDARD', '-ReviewProfile', 'standard',
    '-CharterPath', 'C:\tmp\charter.md', '-ResultPath', $script:ResultFixturePath,
    '-ResultSha256', $script:ShaRes, '-CharterSha256', $script:ShaChar, '-ExitCode', '0', '-Outcome', 'completed',
    '-StartedAt', $StartedAt, '-CompletedAt', $CompletedAt, '-OutputPath', $OutputPath
  )
  if (-not [string]::IsNullOrWhiteSpace($FallbackOf)) { $args += '-FallbackOf'; $args += $FallbackOf }
  if (-not [string]::IsNullOrWhiteSpace($FailureCategory)) { $args += '-FailureCategory'; $args += $FailureCategory }
  if (-not [string]::IsNullOrWhiteSpace($FindingsPath)) { $args += '-FindingsPath'; $args += $FindingsPath }
  if ($null -ne $EvidenceRef -and @($EvidenceRef).Count -gt 0) { $args += '-EvidenceRef'; $args += $EvidenceRef }
  if ($null -ne $OutputArtifact -and @($OutputArtifact).Count -gt 0) { $args += '-OutputArtifact'; $args += $OutputArtifact }
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @args 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old }
  return [pscustomobject]@{ ExitCode = $code; Raw = (($raw | ForEach-Object { "$_" }) -join "`n") }
}
function Invoke-Reducer([string]$Dir, [string]$PacketSha = '') {
  if ([string]::IsNullOrWhiteSpace($PacketSha)) { $PacketSha = $script:ShaOk }
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Assert,
    '-ReceiptDir', $Dir, '-RunId', $script:TestRunId, '-ExpectedPacketSha256', $PacketSha,
    '-RequiredStages', 'change-map,synthesis,adversarial-challenge,triage', '-RoundCap', '3'
  )
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @args 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old }
  $verdict = ''; $text = (($raw | ForEach-Object { "$_" }) -join "`n")
  if ($text -match 'merge-readiness:\s+(READY|NOT_READY|BLOCKED)\s*\|') { $verdict = $Matches[1] }
  return [pscustomobject]@{ ExitCode = $code; Verdict = $verdict; Stdout = $text }
}
function Assert-NoFile([string]$Path, [string]$Label) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) { Fail ("{0}: file written on validation fail: {1}" -f $Label, $Path) }
}
function Emit-BaseStages([string]$Dir, [string]$Skip = '') {
  foreach ($s in $script:Stages) {
    if ($s -eq $Skip) { continue }
    $r = Invoke-Emitter -Stage $s -OutputPath (Join-Path $Dir ($s + '.receipt.json'))
    if ($r.ExitCode -ne 0) { Fail ("base {0}: {1}" -f $s, $r.Raw) }
  }
}
Install-TestLease
try {
$script:total = 12
$dir1 = New-TempDir 'ready'
try {
  foreach ($s in $script:Stages) {
    $out = Join-Path $dir1 ($s + '.receipt.json'); $r = Invoke-Emitter -Stage $s -OutputPath $out
    if ($r.ExitCode -ne 0) { Fail ("emit-ready {0}: exit={1} {2}" -f $s, $r.ExitCode, $r.Raw) }
    if (-not (Test-Path -LiteralPath $out)) { Fail ("emit-ready missing file {0}" -f $out) }
  }
  $red = Invoke-Reducer $dir1
  if ($red.ExitCode -ne 0 -or $red.Verdict -ne 'READY') { Fail ("reducer-ready expect READY/0 got {0}/{1} {2}" -f $red.Verdict, $red.ExitCode, $red.Stdout) }
  Pass 'emitted-root-accepted-READY'
} finally { Remove-Item -Recurse -Force $dir1 -ErrorAction SilentlyContinue }
$dir2 = New-TempDir 'fb'
try {
  Emit-BaseStages $dir2 'triage'
  $r1 = Invoke-Emitter -Stage 'triage' -Status 'failed' -FailureCategory 'policy refusal' -ObservedModel 'primary-model' -Model 'primary-model' -StartedAt '2026-08-05T00:00:00Z' -CompletedAt '2026-08-05T00:01:00Z' -OutputPath (Join-Path $dir2 'triage-primary.receipt.json')
  if ($r1.ExitCode -ne 0) { Fail ("fb-primary: {0}" -f $r1.Raw) }
  $r2 = Invoke-Emitter -Stage 'triage' -Status 'passed' -FallbackOf 'triage:primary-model' -ObservedModel 'fallback-model' -Model 'fallback-model' -StartedAt '2026-08-05T00:01:00Z' -CompletedAt '2026-08-05T00:02:00Z' -OutputPath (Join-Path $dir2 'triage-fallback.receipt.json')
  if ($r2.ExitCode -ne 0) { Fail ("fb-fallback: {0}" -f $r2.Raw) }
  $red = Invoke-Reducer $dir2
  if ($red.ExitCode -ne 0 -or $red.Verdict -ne 'READY') { Fail ("policy-refusal-chain expect READY/0 got {0}/{1}" -f $red.Verdict, $red.ExitCode) }
  Pass 'policy-refusal-fallback-READY'
} finally { Remove-Item -Recurse -Force $dir2 -ErrorAction SilentlyContinue }
$dir3 = New-TempDir 'arr'
try {
  $out = Join-Path $dir3 'change-map.receipt.json'; $r = Invoke-Emitter -Stage 'change-map' -EvidenceRef @('only-one-ref') -OutputPath $out
  if ($r.ExitCode -ne 0) { Fail ("arr-emit: {0}" -f $r.Raw) }
  $raw = [IO.File]::ReadAllText($out, $script:FstUtf8)
  if ($raw -notmatch '"findings"\s*:\s*\[') { Fail 'findings not JSON array' }
  if ($raw -notmatch '"evidence_refs"\s*:\s*\[') { Fail 'evidence_refs not JSON array' }
  if ($raw -match '"evidence_refs"\s*:\s*"') { Fail 'evidence_refs scalar string' }
  if ($raw -notmatch '"output_artifacts"\s*:\s*\[') { Fail 'output_artifacts not JSON array' }
  if ($raw -notmatch '"evidence_refs"\s*:\s*\[\s*"only-one-ref"\s*\]') { Fail ("one-el evidence_refs bad: {0}" -f $raw) }
  Pass 'empty-and-one-el-arrays'
} finally { Remove-Item -Recurse -Force $dir3 -ErrorAction SilentlyContinue }
$dir4 = New-TempDir 'bad'
try {
  $pSha = Join-Path $dir4 'bad-sha.receipt.json'; $r = Invoke-Emitter -Stage 'change-map' -InputPacketSha256 'not-a-sha' -OutputPath $pSha
  if ($r.ExitCode -eq 0) { Fail 'bad-sha should fail' }; Assert-NoFile $pSha 'bad-sha'
  $pSt = Join-Path $dir4 'bad-status.receipt.json'; $r = Invoke-Emitter -Stage 'change-map' -Status 'nope' -OutputPath $pSt
  if ($r.ExitCode -eq 0) { Fail 'bad-status should fail' }; Assert-NoFile $pSt 'bad-status'
  $findPath = Join-Path $dir4 'bad-findings.json'
  [IO.File]::WriteAllText($findPath, '[{"severity":"HIGH","id":"X"}]', $script:FstUtf8)
  $pFind = Join-Path $dir4 'bad-find.receipt.json'; $r = Invoke-Emitter -Stage 'change-map' -FindingsPath $findPath -OutputPath $pFind
  if ($r.ExitCode -eq 0) { Fail 'malformed-finding should fail' }; Assert-NoFile $pFind 'malformed-finding'
  $pTs = Join-Path $dir4 'bad-ts.receipt.json'
  $r = Invoke-Emitter -Stage 'change-map' -StartedAt '2026-08-05T02:00:00Z' -CompletedAt '2026-08-05T01:00:00Z' -OutputPath $pTs
  if ($r.ExitCode -eq 0) { Fail 'timestamp-order should fail' }; Assert-NoFile $pTs 'timestamp-order'
  Pass 'validation-rejects-no-write'
} finally { Remove-Item -Recurse -Force $dir4 -ErrorAction SilentlyContinue }
$dir5 = New-TempDir 'ow'
try {
  $out = Join-Path $dir5 'change-map.receipt.json'; $r1 = Invoke-Emitter -Stage 'change-map' -OutputPath $out
  if ($r1.ExitCode -ne 0) { Fail ("ow-first: {0}" -f $r1.Raw) }
  $before = [IO.File]::ReadAllText($out); $r2 = Invoke-Emitter -Stage 'change-map' -Status 'failed' -OutputPath $out
  if ($r2.ExitCode -eq 0) { Fail 'overwrite should be refused' }
  if ($before -ne [IO.File]::ReadAllText($out)) { Fail 'overwrite mutated existing file' }
  Pass 'overwrite-refused'
} finally { Remove-Item -Recurse -Force $dir5 -ErrorAction SilentlyContinue }
$dir6 = New-TempDir 'order'
try {
  $out = Join-Path $dir6 'change-map.receipt.json'; $r = Invoke-Emitter -Stage 'change-map' -OutputPath $out
  if ($r.ExitCode -ne 0) { Fail ("order-emit: {0}" -f $r.Raw) }
  $raw = [IO.File]::ReadAllText($out, $script:FstUtf8); $want = $script:FstMsFields; $pos = 0
  foreach ($k in $want) {
    $i = $raw.IndexOf('"' + $k + '"', $pos); if ($i -lt 0) { Fail ("missing field {0}" -f $k) }; $pos = $i + 1
  }
  if ($raw -notmatch '"schema_version"\s*:\s*"2"') { Fail 'schema_version not 2' }
  if ($raw -notmatch '"receipt_type"\s*:\s*"merge_stage"') { Fail 'receipt_type not merge_stage' }
  if ($raw -notmatch '"signature"\s*:\s*"[0-9a-f]{64}"') { Fail 'missing signature hex' }
  if ($raw -notmatch '"requested_model"\s*:\s*"test-model"') { Fail 'requested_model missing' }
  if ($raw -notmatch '"model"\s*:\s*"test-model"') { Fail 'model missing' }
  Pass 'field-order-v2-signed'
} finally { Remove-Item -Recurse -Force $dir6 -ErrorAction SilentlyContinue }
$dir7 = New-TempDir 'fb-pass'
try {
  Emit-BaseStages $dir7 'triage'
  $r1 = Invoke-Emitter -Stage 'triage' -Status 'passed' -FailureCategory 'provider outage' -ObservedModel 'primary-model' -Model 'primary-model' -StartedAt '2026-08-05T00:00:00Z' -CompletedAt '2026-08-05T00:01:00Z' -OutputPath (Join-Path $dir7 'triage-primary.receipt.json')
  if ($r1.ExitCode -ne 0) { Fail ("fbpass-primary: {0}" -f $r1.Raw) }
  $r2 = Invoke-Emitter -Stage 'triage' -Status 'passed' -FallbackOf 'triage:primary-model' -ObservedModel 'fallback-model' -Model 'fallback-model' -StartedAt '2026-08-05T00:01:00Z' -CompletedAt '2026-08-05T00:02:00Z' -OutputPath (Join-Path $dir7 'triage-fallback.receipt.json')
  if ($r2.ExitCode -ne 0) { Fail ("fbpass-fallback: {0}" -f $r2.Raw) }
  $red = Invoke-Reducer $dir7
  if ($red.ExitCode -ne 3 -or $red.Verdict -ne 'NOT_READY') { Fail ("fallback-after-passed expect NOT_READY/3 got {0}/{1}" -f $red.Verdict, $red.ExitCode) }
  Pass 'fallback-after-passed-NOT_READY'
} finally { Remove-Item -Recurse -Force $dir7 -ErrorAction SilentlyContinue }
$dir8 = New-TempDir 'high-sp'
try {
  Emit-BaseStages $dir8 'triage'
  $findPath = Join-Path $dir8 'findings.json'
  [IO.File]::WriteAllText($findPath, '[{"severity":"HIGH ","id":"H1","resolved":false}]', $script:FstUtf8)
  $out = Join-Path $dir8 'triage.receipt.json'; $r = Invoke-Emitter -Stage 'triage' -FindingsPath $findPath -OutputPath $out
  if ($r.ExitCode -ne 0) { Fail ("highsp-emit: {0}" -f $r.Raw) }
  $raw = [IO.File]::ReadAllText($out, $script:FstUtf8)
  if ($raw -notmatch '"severity"\s*:\s*"HIGH"') { Fail ("highsp not canonicalized: {0}" -f $raw) }
  $red = Invoke-Reducer $dir8
  if ($red.ExitCode -ne 4 -or $red.Verdict -ne 'BLOCKED') { Fail ("high-trailing-space expect BLOCKED/4 got {0}/{1}" -f $red.Verdict, $red.ExitCode) }
  Pass 'high-trailing-space-BLOCKED'
} finally { Remove-Item -Recurse -Force $dir8 -ErrorAction SilentlyContinue }
$dir9 = New-TempDir 'unsigned'
try {
  foreach ($s in $script:Stages) {
    $out = Join-Path $dir9 ($s + '.receipt.json'); $r = Invoke-Emitter -Stage $s -OutputPath $out
    if ($r.ExitCode -ne 0) { Fail ("unsigned-base {0}: {1}" -f $s, $r.Raw) }
    if ($s -eq 'triage') {
      $raw = ([IO.File]::ReadAllText($out, $script:FstUtf8)) -replace ',"signature":"[0-9a-f]{64}"', ''
      [IO.File]::WriteAllText($out, $raw, $script:FstUtf8)
    }
  }
  $red = Invoke-Reducer $dir9
  if ($red.ExitCode -ne 3 -or $red.Verdict -ne 'NOT_READY') { Fail ("unsigned expect NOT_READY/3 got {0}/{1}" -f $red.Verdict, $red.ExitCode) }
  Pass 'unsigned-stage-NOT_READY'
} finally { Remove-Item -Recurse -Force $dir9 -ErrorAction SilentlyContinue }
$dir10 = New-TempDir 'wrongkey'
try {
  foreach ($s in $script:Stages) {
    $out = Join-Path $dir10 ($s + '.receipt.json'); $r = Invoke-Emitter -Stage $s -OutputPath $out
    if ($r.ExitCode -ne 0) { Fail ("wk-base {0}: {1}" -f $s, $r.Raw) }
    if ($s -eq 'triage') {
      $raw = [IO.File]::ReadAllText($out, $script:FstUtf8)
      if ($raw -match '"signature"\s*:\s*"([0-9a-f]{64})"') {
        $sig = $Matches[1]
        if ($sig[0] -eq 'a') { $flipped = 'b' + $sig.Substring(1) } else { $flipped = 'a' + $sig.Substring(1) }
        $raw = $raw -replace $sig, $flipped; [IO.File]::WriteAllText($out, $raw, $script:FstUtf8)
      } else { Fail 'wk no signature to flip' }
    }
  }
  $red = Invoke-Reducer $dir10
  if ($red.ExitCode -ne 3 -or $red.Verdict -ne 'NOT_READY') { Fail ("wrong-key expect NOT_READY/3 got {0}/{1}" -f $red.Verdict, $red.ExitCode) }
  Pass 'wrong-key-NOT_READY'
} finally { Remove-Item -Recurse -Force $dir10 -ErrorAction SilentlyContinue }
$dir11 = New-TempDir 'pktspoof'
try {
  $stale = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  foreach ($s in $script:Stages) {
    $r = Invoke-Emitter -Stage $s -InputPacketSha256 $stale -OutputPath (Join-Path $dir11 ($s + '.receipt.json'))
    if ($r.ExitCode -ne 0) { Fail ("spoof-emit {0}: {1}" -f $s, $r.Raw) }
  }
  $red = Invoke-Reducer $dir11 $script:ShaOk
  if ($red.ExitCode -ne 3 -or $red.Verdict -ne 'NOT_READY') { Fail ("packet-spoof expect NOT_READY/3 got {0}/{1}" -f $red.Verdict, $red.ExitCode) }
  Pass 'packet-majority-spoof-NOT_READY'
} finally { Remove-Item -Recurse -Force $dir11 -ErrorAction SilentlyContinue }
$dir12 = New-TempDir 'ssbad'
try {
  $badSs = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
  foreach ($s in $script:Stages) {
    $r = Invoke-Emitter -Stage $s -StageSetSha256 $badSs -OutputPath (Join-Path $dir12 ($s + '.receipt.json'))
    if ($r.ExitCode -ne 0) { Fail ("ss-emit {0}: {1}" -f $s, $r.Raw) }
  }
  $red = Invoke-Reducer $dir12
  if ($red.ExitCode -ne 3 -or $red.Verdict -ne 'NOT_READY') { Fail ("wrong-stage-set expect NOT_READY/3 got {0}/{1}" -f $red.Verdict, $red.ExitCode) }
  Pass 'wrong-stage-set-NOT_READY'
} finally { Remove-Item -Recurse -Force $dir12 -ErrorAction SilentlyContinue }
if ($script:pass -ne $script:total) { Fail ("count mismatch pass={0} total={1}" -f $script:pass, $script:total) }
Write-Output ("selftest: PASS {0}/{1}" -f $script:pass, $script:total)
exit 0
} finally {
  Remove-TestLease
  if ($script:ResultFixtureDir -and (Test-Path -LiteralPath $script:ResultFixtureDir)) {
    Remove-Item -LiteralPath $script:ResultFixtureDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
