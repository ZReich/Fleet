# Fixture mutation matrix for Assert-FleetReviewCertification.ps1.
# Mock child gates via -GateTable; never needs live receipts. Prints selftest: PASS k/k.
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
$assert = Join-Path $PSScriptRoot 'Assert-FleetReviewCertification.ps1'
$root = Join-Path $env:TEMP ('fleet-cert-' + [guid]::NewGuid().ToString('N'))
$pass = 0; $total = 0; $failed = $false
$oldHarness = $env:FLEET_TEST_HARNESS

function Write-Utf8([string]$Path, [string]$Text) {
  $p = Split-Path -Parent $Path
  if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Get-LastLine([string]$Raw) {
  $last = ''
  foreach ($ln in @($Raw -split "`r?`n")) { if (-not [string]::IsNullOrWhiteSpace($ln)) { $last = $ln } }
  return $last
}

function Invoke-Cert([string[]]$ExtraArgs) {
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $assert) + @($ExtraArgs)
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @argList 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old }
  return [pscustomobject]@{ ExitCode = [int]$code; Raw = (($raw | ForEach-Object { "$_" }) -join "`n") }
}

function Get-ReadyPreflightJson([string]$RunId = 'cert-run-1') {
  $line = 'review-preflight: READY | selected: 3 | passed: 3 | cached: 0 | failed: 0'
  return (@{
    schema_version = '1'; run_id = $RunId; status = 'READY'; status_line = $line
    selected = 3; passed = 3; cached = 0; failed = 0
  } | ConvertTo-Json -Compress -Depth 3)
}

function Sync-PacketHash([string]$Path) {
  $packet = [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json
  $material = "review_risk|$([string]$packet.review_risk)`n" + (($packet.artifacts | ForEach-Object { "$($_.name)|$($_.bytes)|$($_.sha256)" }) -join "`n") + "`nfrozen_touched_files`n" + (($packet.frozen_touched_files | ForEach-Object { "$($_.path)|$($_.exists)|$($_.sha256)" }) -join "`n")
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $packet.packet_sha256 = -join ($sha.ComputeHash($utf8.GetBytes($material)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
  Write-Utf8 $Path (($packet | ConvertTo-Json -Compress -Depth 6) + "`n")
}

function New-MockGate([string]$Dir, [string]$Name, [string]$SummaryLine, [int]$ExitCode = 0, [switch]$WriteOutputManifest, [string]$MutatePath = '', [switch]$MutateExpectedManifest, [string]$MutateHeadRepo = '') {
  $path = Join-Path $Dir ($Name + '.ps1')
  $mut = if ([string]::IsNullOrWhiteSpace($MutatePath)) { '' } else { $MutatePath.Replace("'", "''") }
  $writeEff = if ($WriteOutputManifest) { '1' } else { '0' }
  $mutEff = if ($MutateExpectedManifest) { '1' } else { '0' }
  $mutHead = if ([string]::IsNullOrWhiteSpace($MutateHeadRepo)) { '' } else { $MutateHeadRepo.Replace("'", "''") }
  $body = @"
param(
  [string]`$OutputManifest = '',
  [string]`$ExpectedLaneManifest = '',
  [Parameter(ValueFromRemainingArguments=`$true)]`$Rest
)
if ('$mut' -ne '') { [IO.File]::WriteAllText('$mut', 'mutated-during-reducer') }
if ('$mutHead' -ne '') { & git -C '$mutHead' commit --allow-empty --quiet -m 'reducer-head-drift' }
if ('$mutEff' -eq '1' -and -not [string]::IsNullOrWhiteSpace(`$ExpectedLaneManifest)) { [IO.File]::WriteAllText(`$ExpectedLaneManifest, '{"run_id":"cert-run-1","expected_lanes":["MUTATED"]}') }
if ('$writeEff' -eq '1' -and -not [string]::IsNullOrWhiteSpace(`$OutputManifest)) {
  `$parent = Split-Path -Parent `$OutputManifest
  if (`$parent -and -not (Test-Path -LiteralPath `$parent)) { New-Item -ItemType Directory -Force -Path `$parent | Out-Null }
  [IO.File]::WriteAllText(`$OutputManifest, '{"run_id":"cert-run-1","expected_lanes":["v-sol"]}')
}
if (-not [string]::IsNullOrWhiteSpace(`$ExpectedLaneManifest) -and (Test-Path -LiteralPath `$ExpectedLaneManifest -PathType Leaf)) {
  `$t = [IO.File]::ReadAllText(`$ExpectedLaneManifest)
  if (`$t -match 'FORGED') { Write-Output 'lane-spans: cert-run-1 | expected: 1 | valid: 0 | missing: 1 | duplicate: 0 | unexpected: 0 | invalid: 0 | verdict: FAILED'; exit 1 }
}
Write-Output '$SummaryLine'
exit $ExitCode
"@
  Write-Utf8 $path $body
  return $path
}

function New-MockGateNoLine([string]$Dir, [string]$Name) {
  $path = Join-Path $Dir ($Name + '.ps1')
  Write-Utf8 $path "param([Parameter(ValueFromRemainingArguments=`$true)]`$Rest)`nWrite-Output 'noise only'`nexit 0`n"
  return $path
}

function New-GoodFixture([string]$Name, [switch]$Merge, [switch]$SkipArchive) {
  $fx = Join-Path $root $Name
  $repo = Join-Path $fx 'repo'
  $rc = Join-Path $fx 'receipts'
  $gates = Join-Path $fx 'gates'
  $artDir = Join-Path $fx 'packet-artifacts'
  New-Item -ItemType Directory -Force -Path $repo, $rc, $gates, $artDir, (Join-Path $repo '.fleet') | Out-Null
  $runId = 'cert-run-1'
  $pktSha = ''
  $pkt = Join-Path $fx 'packet-manifest.json'
  # Packet-only preflight artifact (not repo-root). Distractor at repo .fleet is ignored.
  $preflightPath = Join-Path $artDir 'review-preflight.json'
  Write-Utf8 $preflightPath ((Get-ReadyPreflightJson $runId) + "`n")
  Write-Utf8 (Join-Path $repo '.fleet\review-preflight.json') "review-preflight: BLOCKED | selected: 9 | passed: 0 | failed: 9 | substitution: REQUIRED`n"
  $trackedPath = Join-Path $repo 'tracked.txt'
  Write-Utf8 $trackedPath 'frozen source'
  $auxPath = Join-Path $fx 'packet-context.md'
  Write-Utf8 $auxPath 'frozen packet context'
  $preflightSha = (Get-FileHash -LiteralPath $preflightPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $auxSha = (Get-FileHash -LiteralPath $auxPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $trackedSha = (Get-FileHash -LiteralPath $trackedPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $preflightBytes = [IO.File]::ReadAllBytes($preflightPath).Length
  $auxBytes = [IO.File]::ReadAllBytes($auxPath).Length
  $artifacts = @(@{ name = 'review-preflight.json'; path = $preflightPath; bytes = $preflightBytes; sha256 = $preflightSha }, @{ name = 'packet-context.md'; path = $auxPath; bytes = $auxBytes; sha256 = $auxSha })
  $frozen = @(@{ path = 'tracked.txt'; exists = $true; sha256 = $trackedSha })
  $material = "review_risk|mechanical`n" + (($artifacts | ForEach-Object { "$($_.name)|$($_.bytes)|$($_.sha256)" }) -join "`n") + "`nfrozen_touched_files`n" + (($frozen | ForEach-Object { "$($_.path)|$($_.exists)|$($_.sha256)" }) -join "`n")
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $pktSha = -join ($sha.ComputeHash($utf8.GetBytes($material)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
  Write-Utf8 $pkt (@{ schema_version = '1'; review_risk = 'mechanical'; packet_sha256 = $pktSha; artifacts = $artifacts; frozen_touched_files = $frozen } | ConvertTo-Json -Compress -Depth 4)
  # Certification attests the resolved commit range, so fixtures are real repositories.
  & git -C $repo init --quiet
  & git -C $repo config user.name 'Fleet Test'
  & git -C $repo config user.email 'fleet-test@local'
  & git -C $repo add -- tracked.txt
  & git -C $repo commit --quiet -m 'fixture baseline'
  Write-Utf8 (Join-Path $rc 'lane1.json') '{"schema_version":"2","receipt_type":"review_lane","run_id":"cert-run-1","signature":"deadbeef"}'
  $baseMan = Join-Path $fx 'base-manifest.json'
  Write-Utf8 $baseMan ('{"run_id":"' + $runId + '","expected_lanes":["v-sol"]}')
  # Forged caller effective: zero authority (spans fail if this path is used)
  $effMan = Join-Path $fx 'forged-effective.json'
  Write-Utf8 $effMan '{"run_id":"cert-run-1","expected_lanes":["FORGED"],"note":"FORGED"}'
  $span = Join-Path $fx 'spans.jsonl'
  Write-Utf8 $span '{}'
  $iLine = "review-integrity: $runId | hosted: 1 | refused: 0 | open-weight-failovers: 0/0 | verdict: ok"
  $sLine = "lane-spans: $runId | expected: 1 | valid: 1 | missing: 0 | duplicate: 0 | unexpected: 0 | invalid: 0 | verdict: ok"
  $rLine = 'review: FULL | voices: 5 qualified / 5 candidates / 5 required | packet: match | verdict: ok'
  $mLine = 'merge-readiness: READY | required: 4 | valid: 4 | missing: 0 | stale: 0 | unresolved: 0'
  $gI = New-MockGate $gates 'integrity' $iLine 0 -WriteOutputManifest
  $gS = New-MockGate $gates 'spans' $sLine 0
  $gR = New-MockGate $gates 'review' $rLine 0
  $gM = New-MockGate $gates 'merge' $mLine 0
  $out = Join-Path $fx 'archive.json'
  if ($SkipArchive) { $out = Join-Path $fx 'archive-collide.json' }
  $claim = if ($Merge) { 'MergeReadiness' } else { 'Review' }
  $fxArgs = @(
    '-ClaimKind', $claim, '-Repo', $repo, '-BaseRef', 'HEAD', '-RunId', $runId,
    '-ReceiptDir', $rc, '-PacketManifest', $pkt, '-SpanLedger', $span,
    '-BaseManifest', $baseMan, '-EffectiveManifest', $effMan, '-OutputPath', $out,
    '-GateIntegrity', $gI, '-GateSpans', $gS, '-GateReview', $gR, '-GateMerge', $gM
  )
  return [pscustomobject]@{
    Args = $fxArgs; Out = $out; Repo = $repo; ReceiptDir = $rc; Packet = $pkt
    Base = $baseMan; Eff = $effMan; Span = $span; Gates = $gates
    RunId = $runId; ILine = $iLine; SLine = $sLine; RLine = $rLine; MLine = $mLine; TrackedPath = $trackedPath
    AuxPath = $auxPath; PreflightPath = $preflightPath; ArtDir = $artDir
    IntegrityGate = $gI; SpansGate = $gS; ReviewGate = $gR; MergeGate = $gM
  }
}

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  $script:total++
  if ($Ok) { $script:pass++; Write-Output ("PASS {0}" -f $Name) }
  else { $script:failed = $true; Write-Output ("FAIL {0}: {1}" -f $Name, $Detail) }
}

function Expect-Uncertified([string]$Name, $Res, [string]$FailedClass) {
  $last = Get-LastLine $Res.Raw
  $want = "certification: UNCERTIFIED | run: cert-run-1 | failed: $FailedClass | reducers:"
  $ok = ($Res.ExitCode -ne 0) -and ($last -like "$want*") -and ($last -match "failed: $FailedClass")
  Check $Name $ok ("exit=$($Res.ExitCode) last=$last")
}

try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $env:FLEET_TEST_HARNESS = '1'
  if (-not (Test-Path -LiteralPath $assert -PathType Leaf)) { throw 'Assert-FleetReviewCertification.ps1 missing' }

  # --- good path: CERTIFIED, archive once, reducer lines byte-identical ---
  $good = New-GoodFixture 'good-review'
  $r0 = Invoke-Cert $good.Args
  $last0 = Get-LastLine $r0.Raw
  $certWant = 'certification: CERTIFIED | run: cert-run-1 | packet: match | receipts: signed-v2 | spans: 1/1 | reducers: 3/3'
  Check 'good-review CERTIFIED exit0' (($r0.ExitCode -eq 0) -and ($last0 -ceq $certWant)) $last0
  Check 'good-review archive written' (Test-Path -LiteralPath $good.Out -PathType Leaf) $good.Out
  Check 'good-review re-emit integrity' ($r0.Raw.Contains($good.ILine)) 'missing integrity line'
  Check 'good-review re-emit spans' ($r0.Raw.Contains($good.SLine)) 'missing spans line'
  Check 'good-review re-emit review' ($r0.Raw.Contains($good.RLine)) 'missing review line'
  # byte-identical: exact line appears as standalone (split and match)
  $foundI = $false
  foreach ($ln in @($r0.Raw -split "`r?`n")) { if ($ln -ceq $good.ILine) { $foundI = $true; break } }
  Check 'good-review integrity line byte-identical' $foundI $good.ILine

  $env:FLEET_TEST_HARNESS = $null
  Expect-Uncertified 'gate override refused outside harness' (Invoke-Cert $good.Args) 'override'
  $env:FLEET_TEST_HARNESS = '1'

  # second run same OutputPath => archive
  $r1 = Invoke-Cert $good.Args
  Expect-Uncertified 'archive-collision' $r1 'archive'

  # merge path 4/4
  $gm = New-GoodFixture 'good-merge' -Merge
  $rm = Invoke-Cert $gm.Args
  $lastM = Get-LastLine $rm.Raw
  $certM = 'certification: CERTIFIED | run: cert-run-1 | packet: match | receipts: signed-v2 | spans: 1/1 | reducers: 4/4'
  Check 'good-merge CERTIFIED 4/4' (($rm.ExitCode -eq 0) -and ($lastM -ceq $certM)) $lastM
  Check 'good-merge re-emit merge line' ($rm.Raw.Contains($gm.MLine)) 'missing merge line'

  # --- mutation matrix ---
  $fxP = New-GoodFixture 'mut-packet-missing'
  $argsP = @($fxP.Args)
  for ($i = 0; $i -lt $argsP.Count; $i++) {
    if ($argsP[$i] -eq '-PacketManifest') { $argsP[$i + 1] = (Join-Path $fxP.Repo 'no-packet.json'); break }
  }
  Expect-Uncertified 'packet-missing' (Invoke-Cert $argsP) 'packet'

  $fxPm = New-GoodFixture 'mut-packet-mismatch'
  Write-Utf8 $fxPm.Packet '{"schema_version":"1","packet_sha256":"not-a-valid-sha"}'
  Expect-Uncertified 'packet-mismatch' (Invoke-Cert $fxPm.Args) 'packet'

  # preflight absent from packet artifact path
  $fxPa = New-GoodFixture 'mut-preflight-absent'
  Remove-Item -LiteralPath $fxPa.PreflightPath -Force
  Expect-Uncertified 'preflight-absent' (Invoke-Cert $fxPa.Args) 'packet'

  # preflight not READY (packet artifact; hash rewritten so READY class fires)
  $fxPn = New-GoodFixture 'mut-preflight-blocked'
  $blocked = @{ schema_version = '1'; run_id = 'cert-run-1'; status = 'BLOCKED'; status_line = 'review-preflight: BLOCKED | selected: 3 | passed: 1 | failed: 2 | substitution: REQUIRED'; selected = 3; passed = 1; cached = 0; failed = 2 } | ConvertTo-Json -Compress
  Write-Utf8 $fxPn.PreflightPath ($blocked + "`n")
  $pnBytes = [IO.File]::ReadAllBytes($fxPn.PreflightPath).Length
  $pnSha = (Get-FileHash -LiteralPath $fxPn.PreflightPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $pnMan = [IO.File]::ReadAllText($fxPn.Packet, $utf8) | ConvertFrom-Json
  foreach ($a in @($pnMan.artifacts)) {
    if ([string]$a.name -ceq 'review-preflight.json') { $a.bytes = $pnBytes; $a.sha256 = $pnSha }
  }
  Write-Utf8 $fxPn.Packet (($pnMan | ConvertTo-Json -Compress -Depth 6) + "`n")
  Sync-PacketHash $fxPn.Packet
  Expect-Uncertified 'preflight-not-READY' (Invoke-Cert $fxPn.Args) 'preflight'

  # packet artifact bytes/hash swap
  $fxPs = New-GoodFixture 'mut-preflight-swapped'
  Write-Utf8 $fxPs.PreflightPath ((Get-ReadyPreflightJson) + "`nswapped`n")
  Expect-Uncertified 'preflight-hash-swapped' (Invoke-Cert $fxPs.Args) 'packet'

  # repo-root preflight swap must NOT be consulted (packet READY still wins)
  $fxRr = New-GoodFixture 'mut-repo-root-swap'
  Write-Utf8 (Join-Path $fxRr.Repo '.fleet\review-preflight.json') ((Get-ReadyPreflightJson) + " | swapped-repo`n")
  $rRr = Invoke-Cert $fxRr.Args
  $lastRr = Get-LastLine $rRr.Raw
  Check 'repo-root preflight not consulted' (($rRr.ExitCode -eq 0) -and ($lastRr -like 'certification: CERTIFIED*')) $lastRr

  # forged caller EffectiveManifest ignored (fixture default is FORGED; integrity product used)
  $fxFg = New-GoodFixture 'mut-forged-eff'
  $rFg = Invoke-Cert $fxFg.Args
  Check 'forged EffectiveManifest ignored' (($rFg.ExitCode -eq 0) -and ((Get-LastLine $rFg.Raw) -like 'certification: CERTIFIED*')) (Get-LastLine $rFg.Raw)

  # missing integrity -OutputManifest product => UNCERTIFIED spans
  $fxEm = New-GoodFixture 'mut-eff-product-missing'
  $noEffI = New-MockGate $fxEm.Gates 'integrity-no-eff' $fxEm.ILine 0
  $argsEm = @(
    '-ClaimKind', 'Review', '-Repo', $fxEm.Repo, '-BaseRef', 'HEAD', '-RunId', 'cert-run-1',
    '-ReceiptDir', $fxEm.ReceiptDir, '-PacketManifest', $fxEm.Packet, '-SpanLedger', $fxEm.Span,
    '-BaseManifest', $fxEm.Base, '-EffectiveManifest', $fxEm.Eff, '-OutputPath', (Join-Path $fxEm.Repo 'a.json'),
    '-GateIntegrity', $noEffI, '-GateSpans', $fxEm.SpansGate, '-GateReview', $fxEm.ReviewGate, '-GateMerge', $fxEm.MergeGate
  )
  Expect-Uncertified 'missing OutputManifest product' (Invoke-Cert $argsEm) 'spans'

  # duplicate preflight artifact names => packet UNCERTIFIED
  $fxDup = New-GoodFixture 'mut-dup-preflight'
  $dupObj = [IO.File]::ReadAllText($fxDup.Packet, $utf8) | ConvertFrom-Json
  $arts = @($dupObj.artifacts) + @($dupObj.artifacts[0])
  $dupObj.artifacts = $arts
  Write-Utf8 $fxDup.Packet (($dupObj | ConvertTo-Json -Compress -Depth 6) + "`n")
  Expect-Uncertified 'duplicate preflight artifact' (Invoke-Cert $fxDup.Args) 'packet'

  # malformed preflight JSON (valid hash recompute so content fails READY)
  $fxMf = New-GoodFixture 'mut-malformed-preflight'
  Write-Utf8 $fxMf.PreflightPath "not-json`n"
  $mfBytes = [IO.File]::ReadAllBytes($fxMf.PreflightPath).Length
  $mfSha = (Get-FileHash -LiteralPath $fxMf.PreflightPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $mfMan = [IO.File]::ReadAllText($fxMf.Packet, $utf8) | ConvertFrom-Json
  foreach ($a in @($mfMan.artifacts)) {
    if ([string]$a.name -ceq 'review-preflight.json') { $a.bytes = $mfBytes; $a.sha256 = $mfSha }
  }
  Write-Utf8 $fxMf.Packet (($mfMan | ConvertTo-Json -Compress -Depth 6) + "`n")
  Sync-PacketHash $fxMf.Packet
  Expect-Uncertified 'malformed preflight JSON' (Invoke-Cert $fxMf.Args) 'preflight'

  # reducer-time mutation of packet artifact => failed: drift
  $fxDr = New-GoodFixture 'mut-reducer-drift'
  $mutI = New-MockGate $fxDr.Gates 'integrity-mutate' $fxDr.ILine 0 -WriteOutputManifest -MutatePath $fxDr.AuxPath
  $argsDr = @(
    '-ClaimKind', 'Review', '-Repo', $fxDr.Repo, '-BaseRef', 'HEAD', '-RunId', 'cert-run-1',
    '-ReceiptDir', $fxDr.ReceiptDir, '-PacketManifest', $fxDr.Packet, '-SpanLedger', $fxDr.Span,
    '-BaseManifest', $fxDr.Base, '-EffectiveManifest', $fxDr.Eff, '-OutputPath', (Join-Path $fxDr.Repo 'a.json'),
    '-GateIntegrity', $mutI, '-GateSpans', $fxDr.SpansGate, '-GateReview', $fxDr.ReviewGate, '-GateMerge', $fxDr.MergeGate
  )
  Expect-Uncertified 'reducer-time artifact drift' (Invoke-Cert $argsDr) 'drift'

  # Complete authoritative input set: each reducer must leave ledger, frozen files,
  # and the resolved HEAD/range exactly as snapshotted before the first reducer.
  $fxSl = New-GoodFixture 'mut-span-ledger-drift'
  $mutSl = New-MockGate $fxSl.Gates 'integrity-mutate-span' $fxSl.ILine 0 -WriteOutputManifest -MutatePath $fxSl.Span
  $argsSl = @(
    '-ClaimKind', 'Review', '-Repo', $fxSl.Repo, '-BaseRef', 'HEAD', '-RunId', 'cert-run-1',
    '-ReceiptDir', $fxSl.ReceiptDir, '-PacketManifest', $fxSl.Packet, '-SpanLedger', $fxSl.Span,
    '-BaseManifest', $fxSl.Base, '-EffectiveManifest', $fxSl.Eff, '-OutputPath', (Join-Path $fxSl.Repo 'span.json'),
    '-GateIntegrity', $mutSl, '-GateSpans', $fxSl.SpansGate, '-GateReview', $fxSl.ReviewGate, '-GateMerge', $fxSl.MergeGate
  )
  Expect-Uncertified 'reducer-time span-ledger drift' (Invoke-Cert $argsSl) 'drift'

  $fxTs = New-GoodFixture 'mut-touched-reducer-drift'
  $mutTs = New-MockGate $fxTs.Gates 'integrity-mutate-touched' $fxTs.ILine 0 -WriteOutputManifest -MutatePath $fxTs.TrackedPath
  $argsTs = @(
    '-ClaimKind', 'Review', '-Repo', $fxTs.Repo, '-BaseRef', 'HEAD', '-RunId', 'cert-run-1',
    '-ReceiptDir', $fxTs.ReceiptDir, '-PacketManifest', $fxTs.Packet, '-SpanLedger', $fxTs.Span,
    '-BaseManifest', $fxTs.Base, '-EffectiveManifest', $fxTs.Eff, '-OutputPath', (Join-Path $fxTs.Repo 'touched.json'),
    '-GateIntegrity', $mutTs, '-GateSpans', $fxTs.SpansGate, '-GateReview', $fxTs.ReviewGate, '-GateMerge', $fxTs.MergeGate
  )
  Expect-Uncertified 'reducer-time frozen-touched drift' (Invoke-Cert $argsTs) 'drift'

  $fxHd = New-GoodFixture 'mut-head-reducer-drift'
  $mutHd = New-MockGate $fxHd.Gates 'integrity-mutate-head' $fxHd.ILine 0 -WriteOutputManifest -MutateHeadRepo $fxHd.Repo
  $argsHd = @(
    '-ClaimKind', 'Review', '-Repo', $fxHd.Repo, '-BaseRef', 'HEAD', '-RunId', 'cert-run-1',
    '-ReceiptDir', $fxHd.ReceiptDir, '-PacketManifest', $fxHd.Packet, '-SpanLedger', $fxHd.Span,
    '-BaseManifest', $fxHd.Base, '-EffectiveManifest', $fxHd.Eff, '-OutputPath', (Join-Path $fxHd.Repo 'head.json'),
    '-GateIntegrity', $mutHd, '-GateSpans', $fxHd.SpansGate, '-GateReview', $fxHd.ReviewGate, '-GateMerge', $fxHd.MergeGate
  )
  Expect-Uncertified 'reducer-time resolved-HEAD drift' (Invoke-Cert $argsHd) 'drift'

  $fxEd = New-GoodFixture 'mut-effective-drift'
  $mutS = New-MockGate $fxEd.Gates 'spans-mutate-effective' $fxEd.SLine 0 -MutateExpectedManifest
  $argsEd = @(
    '-ClaimKind', 'Review', '-Repo', $fxEd.Repo, '-BaseRef', 'HEAD', '-RunId', 'cert-run-1',
    '-ReceiptDir', $fxEd.ReceiptDir, '-PacketManifest', $fxEd.Packet, '-SpanLedger', $fxEd.Span,
    '-BaseManifest', $fxEd.Base, '-EffectiveManifest', $fxEd.Eff, '-OutputPath', (Join-Path $fxEd.Repo 'effective.json'),
    '-GateIntegrity', $fxEd.IntegrityGate, '-GateSpans', $mutS, '-GateReview', $fxEd.ReviewGate, '-GateMerge', $fxEd.MergeGate
  )
  Expect-Uncertified 'reducer-time effective-manifest drift' (Invoke-Cert $argsEd) 'drift'

  $fxTf = New-GoodFixture 'mut-touched-source'
  Write-Utf8 $fxTf.TrackedPath 'drifted source'
  Expect-Uncertified 'frozen-touched-source-drift' (Invoke-Cert $fxTf.Args) 'packet'

  $fxArt = New-GoodFixture 'mut-packet-artifact'
  Write-Utf8 $fxArt.AuxPath 'drifted packet context'
  Expect-Uncertified 'packet-artifact-drift' (Invoke-Cert $fxArt.Args) 'packet'

  # Rebinding artifact evidence without recomputing packet_sha256 cannot reuse old receipts.
  $fxRb = New-GoodFixture 'mut-packet-rebind'
  Write-Utf8 $fxRb.AuxPath 'rebound packet context'
  $rb = [IO.File]::ReadAllText($fxRb.Packet, $utf8) | ConvertFrom-Json
  $rbAux = Get-FileHash -LiteralPath $fxRb.AuxPath -Algorithm SHA256
  foreach ($a in @($rb.artifacts)) { if ([string]$a.name -ceq 'packet-context.md') { $a.bytes = [IO.File]::ReadAllBytes($fxRb.AuxPath).Length; $a.sha256 = $rbAux.Hash.ToLowerInvariant() } }
  Write-Utf8 $fxRb.Packet (($rb | ConvertTo-Json -Compress -Depth 6) + "`n")
  Expect-Uncertified 'packet-rebind-old-hash' (Invoke-Cert $fxRb.Args) 'packet'

  $fxRu = New-GoodFixture 'mut-receipt-unsigned'
  Write-Utf8 (Join-Path $fxRu.ReceiptDir 'lane1.json') '{"schema_version":"2","receipt_type":"review_lane","run_id":"cert-run-1","signature":""}'
  Expect-Uncertified 'receipt-unsigned' (Invoke-Cert $fxRu.Args) 'receipt'

  $fxRi = New-GoodFixture 'mut-receipt-invalid'
  Write-Utf8 (Join-Path $fxRi.ReceiptDir 'lane1.json') '{"schema_version":"1","signature":"x"}'
  Expect-Uncertified 'receipt-invalid' (Invoke-Cert $fxRi.Args) 'receipt'

  $fxIg = New-GoodFixture 'mut-integrity-fail'
  $badI = New-MockGate $fxIg.Gates 'integrity-fail' 'review-integrity: cert-run-1 | hosted: 0 | refused: 0 | open-weight-failovers: 0/0 | verdict: FAILED' 1
  $argsIg = @(
    '-ClaimKind', 'Review', '-Repo', $fxIg.Repo, '-BaseRef', 'HEAD', '-RunId', 'cert-run-1',
    '-ReceiptDir', $fxIg.ReceiptDir, '-PacketManifest', $fxIg.Packet, '-SpanLedger', $fxIg.Span,
    '-BaseManifest', $fxIg.Base, '-EffectiveManifest', $fxIg.Eff, '-OutputPath', (Join-Path $fxIg.Repo 'a.json'),
    '-GateIntegrity', $badI, '-GateSpans', $fxIg.SpansGate, '-GateReview', $fxIg.ReviewGate, '-GateMerge', $fxIg.MergeGate
  )
  $resIg = Invoke-Cert $argsIg
  $lastIg = Get-LastLine $resIg.Raw
  Check 'integrity-fail UNCERTIFIED' (($resIg.ExitCode -ne 0) -and ($lastIg -match 'failed: integrity') -and ($lastIg -match 'reducers: 0/3')) $lastIg
  Check 'integrity-fail still re-emits line' ($resIg.Raw -match 'review-integrity:.*verdict: FAILED') $resIg.Raw

  $fxSp = New-GoodFixture 'mut-span-fail'
  $badS = New-MockGate $fxSp.Gates 'spans-fail' 'lane-spans: cert-run-1 | expected: 1 | valid: 0 | missing: 1 | duplicate: 0 | unexpected: 0 | invalid: 0 | verdict: FAILED' 1
  $argsSp = @(
    '-ClaimKind', 'Review', '-Repo', $fxSp.Repo, '-BaseRef', 'HEAD', '-RunId', 'cert-run-1',
    '-ReceiptDir', $fxSp.ReceiptDir, '-PacketManifest', $fxSp.Packet, '-SpanLedger', $fxSp.Span,
    '-BaseManifest', $fxSp.Base, '-EffectiveManifest', $fxSp.Eff, '-OutputPath', (Join-Path $fxSp.Repo 'a.json'),
    '-GateIntegrity', $fxSp.IntegrityGate, '-GateSpans', $badS, '-GateReview', $fxSp.ReviewGate, '-GateMerge', $fxSp.MergeGate
  )
  $resSp = Invoke-Cert $argsSp
  $lastSp = Get-LastLine $resSp.Raw
  Check 'spans-fail UNCERTIFIED' (($resSp.ExitCode -ne 0) -and ($lastSp -match 'failed: spans') -and ($lastSp -match 'reducers: 1/3')) $lastSp

  $fxRv = New-GoodFixture 'mut-review-fail'
  $badR = New-MockGate $fxRv.Gates 'review-fail' 'review: FULL | voices: 0 qualified / 5 candidates / 5 required | packet: match | verdict: FAILED' 1
  $argsRv = @(
    '-ClaimKind', 'Review', '-Repo', $fxRv.Repo, '-BaseRef', 'HEAD', '-RunId', 'cert-run-1',
    '-ReceiptDir', $fxRv.ReceiptDir, '-PacketManifest', $fxRv.Packet, '-SpanLedger', $fxRv.Span,
    '-BaseManifest', $fxRv.Base, '-EffectiveManifest', $fxRv.Eff, '-OutputPath', (Join-Path $fxRv.Repo 'a.json'),
    '-GateIntegrity', $fxRv.IntegrityGate, '-GateSpans', $fxRv.SpansGate, '-GateReview', $badR, '-GateMerge', $fxRv.MergeGate
  )
  $resRv = Invoke-Cert $argsRv
  $lastRv = Get-LastLine $resRv.Raw
  Check 'review-fail UNCERTIFIED' (($resRv.ExitCode -ne 0) -and ($lastRv -match 'failed: review') -and ($lastRv -match 'reducers: 2/3')) $lastRv

  $fxRd = New-GoodFixture 'mut-reducer-absent'
  $noLine = New-MockGateNoLine $fxRd.Gates 'integrity-noline'
  $argsRd = @(
    '-ClaimKind', 'Review', '-Repo', $fxRd.Repo, '-BaseRef', 'HEAD', '-RunId', 'cert-run-1',
    '-ReceiptDir', $fxRd.ReceiptDir, '-PacketManifest', $fxRd.Packet, '-SpanLedger', $fxRd.Span,
    '-BaseManifest', $fxRd.Base, '-EffectiveManifest', $fxRd.Eff, '-OutputPath', (Join-Path $fxRd.Repo 'a.json'),
    '-GateIntegrity', $noLine, '-GateSpans', $fxRd.SpansGate, '-GateReview', $fxRd.ReviewGate, '-GateMerge', $fxRd.MergeGate
  )
  Expect-Uncertified 'reducer-line-absent' (Invoke-Cert $argsRd) 'reducer'

  $fxEr = New-GoodFixture 'mut-empty-receipts'
  Get-ChildItem -LiteralPath $fxEr.ReceiptDir -File | Remove-Item -Force
  Expect-Uncertified 'receipt-empty-dir' (Invoke-Cert $fxEr.Args) 'receipt'

  $defBody = [IO.File]::ReadAllText($assert, $utf8)
  Check 'default gates use real Assert names' (
    ($defBody -match 'Assert-FleetReviewIntegrity\.ps1') -and
    ($defBody -match 'Assert-FleetLaneSpans\.ps1') -and
    ($defBody -match 'Assert-FleetAdversarialReview\.ps1') -and
    ($defBody -match 'Assert-FleetMergeReadiness\.ps1')
  ) 'missing real gate defaults'
  Check 'cert derives private OutputManifest' ($defBody -match 'OutputManifest') 'missing OutputManifest wiring'
  Check 'cert re-attests after reducers' (($defBody -match 'Test-AttestIntact') -and ($defBody -match "failed: 'drift'|Emit-Uncertified 'drift'")) 'missing drift re-attest'
}
catch {
  $failed = $true
  Write-Output ("harness FAIL: {0}" -f $_.Exception.Message)
}
finally {
  $env:FLEET_TEST_HARNESS = $oldHarness
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

if ((-not $failed) -and ($pass -eq $total) -and ($total -gt 0)) {
  Write-Output ("selftest: PASS {0}/{1}" -f $pass, $total)
  exit 0
}
Write-Output ("selftest: FAIL {0}/{1}" -f $pass, $total)
exit 1
