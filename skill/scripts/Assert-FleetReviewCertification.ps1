# Final fail-closed certification. CERTIFIED/UNCERTIFIED last lines; integrity->spans->review[->merge].
# Preflight = unique packet artifact only; private -OutputManifest effective; re-attest => failed: drift.
# PS 5.1; caller -EffectiveManifest has zero authority.
param(
  [Parameter(Mandatory)][ValidateSet('Review', 'MergeReadiness')][string]$ClaimKind,
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$BaseRef,
  [Parameter(Mandatory)][string]$RunId,
  [Parameter(Mandatory)][string]$ReceiptDir,
  [Parameter(Mandatory)][string]$PacketManifest,
  [Parameter(Mandatory)][string]$SpanLedger,
  [Parameter(Mandatory)][string]$BaseManifest,
  [string]$EffectiveManifest = '',
  [string]$LockedPlan = '',
  [Parameter(Mandatory)][string]$OutputPath,
  # Private test injection: override child script paths (default = real Assert-* scripts).
  [string]$GateIntegrity = '',
  [string]$GateSpans = '',
  [string]$GateReview = '',
  [string]$GateMerge = ''
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'FleetReviewPreflight.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetReviewCertification.Attestation.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetReviewPacketReady.Helpers.ps1')
$script:Rid = if ([string]::IsNullOrWhiteSpace($RunId)) { '-' } else { $RunId }
$script:RedOk = 0
$script:RedTot = if ($ClaimKind -eq 'MergeReadiness') { 4 } else { 3 }
$script:ReducerLines = New-Object System.Collections.ArrayList
$script:ChildCodes = [ordered]@{}
$script:ArtifactHashes = [ordered]@{}
$script:AttestPath = [ordered]@{}
$script:AttestSha = [ordered]@{}
$script:ReceiptDirSnap = ''

function Get-FileSha256Hex([string]$Path) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $fs = [IO.File]::OpenRead($Path)
    try { return -join ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) }
    finally { $fs.Dispose() }
  }
  finally { $sha.Dispose() }
}

function Emit-Uncertified([string]$FailedClass, [int]$Code = 1) {
  $line = "certification: UNCERTIFIED | run: $($script:Rid) | failed: $FailedClass | reducers: $($script:RedOk)/$($script:RedTot)"
  Write-Output $line
  exit $Code
}

function Emit-Certified([int]$SpanValid, [int]$SpanExpected) {
  $line = "certification: CERTIFIED | run: $($script:Rid) | packet: match | receipts: signed-v2 | spans: $SpanValid/$SpanExpected | reducers: $($script:RedOk)/$($script:RedTot)"
  Write-Output $line
  exit 0
}

function Get-SummaryLine([string]$Raw, [string]$Prefix) {
  $hit = $null
  foreach ($ln in @($Raw -split "`r?`n")) {
    if ($ln.StartsWith($Prefix)) { $hit = $ln }
  }
  return $hit
}

function Invoke-ChildGate([string]$ScriptPath, [string[]]$GateArgs) {
  if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    return [pscustomobject]@{ ExitCode = 2; Raw = "gate missing: $ScriptPath" }
  }
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($GateArgs)
  $oldEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $raw = & powershell.exe @argList 2>&1
    $code = $LASTEXITCODE
  }
  finally { $ErrorActionPreference = $oldEap }
  $text = (($raw | ForEach-Object { "$_" }) -join "`n")
  return [pscustomobject]@{ ExitCode = [int]$code; Raw = [string]$text }
}

function Resolve-GatePath([string]$Override, [string]$DefaultName) {
  if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
  return (Join-Path $PSScriptRoot $DefaultName)
}

function Test-SignedV2Receipts([string]$Dir) {
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
  $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('_') })
  if ($files.Count -eq 0) { return $false }
  $anyOk = $false
  foreach ($f in $files) {
    try {
      $obj = [IO.File]::ReadAllText($f.FullName, $utf8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch { return $false }
    $sv = ''; if ($obj.PSObject.Properties['schema_version']) { $sv = [string]$obj.schema_version }
    $sig = ''; if ($obj.PSObject.Properties['signature']) { $sig = [string]$obj.signature }
    if ($sv -cne '2') { return $false }
    if ([string]::IsNullOrWhiteSpace($sig)) { return $false }
    $anyOk = $true
  }
  return $anyOk
}



function Register-Attest([string]$Key, [string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  $h = Get-FileSha256Hex $Path
  $script:AttestPath[$Key] = $Path
  $script:AttestSha[$Key] = $h
  $script:ArtifactHashes[$Key] = $h
  return $true
}

function Snapshot-ReceiptDir([string]$Dir) {
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
  $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Name.StartsWith('_') } | Sort-Object Name)
  $parts = New-Object System.Collections.ArrayList
  foreach ($f in $files) {
    $h = Get-FileSha256Hex $f.FullName
    [void]$parts.Add(($f.Name + '=' + $h))
    $script:AttestPath['receipt:' + $f.Name] = $f.FullName
    $script:AttestSha['receipt:' + $f.Name] = $h
  }
  $script:ReceiptDirSnap = ($parts -join ';')
  $script:ArtifactHashes['receipts_dir'] = $script:ReceiptDirSnap
  return $true
}

function Get-AttestHashNow([string]$Key, [string]$Path) {
  if ($Key.StartsWith('packet_artifact:')) {
    $a = Get-TransportArtifactAttestation $Path
    if ($null -eq $a) { return $null }
    return [string]$a.Sha
  }
  $authorityHash = Get-FleetCertificationAttestHashNow $Key $Path
  if ($null -ne $authorityHash) { return $authorityHash }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return (Get-FileSha256Hex $Path)
}

function Test-AttestIntact {
  foreach ($k in @($script:AttestPath.Keys)) {
    $now = Get-AttestHashNow $k ([string]$script:AttestPath[$k])
    if ($null -eq $now -or $now -cne [string]$script:AttestSha[$k]) { return $false }
  }
  if (-not (Test-Path -LiteralPath $ReceiptDir -PathType Container)) { return $false }
  $files = @(Get-ChildItem -LiteralPath $ReceiptDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { -not $_.Name.StartsWith('_') } | Sort-Object Name)
  $parts = New-Object System.Collections.ArrayList
  foreach ($f in $files) { [void]$parts.Add(($f.Name + '=' + (Get-FileSha256Hex $f.FullName))) }
  if (($parts -join ';') -cne $script:ReceiptDirSnap) { return $false }
  foreach ($k in @($script:AttestSha.Keys)) { $script:ArtifactHashes[$k] = $script:AttestSha[$k] }
  $script:ArtifactHashes['receipts_dir'] = $script:ReceiptDirSnap
  return $true
}

function Test-PacketArtifacts([string]$ManifestPath, $Artifacts) {
  $root = [IO.Path]::GetFullPath((Split-Path -Parent $ManifestPath)).TrimEnd('\')
  foreach ($artifact in @($Artifacts)) {
    try { $path = [IO.Path]::GetFullPath([string]$artifact.path) } catch { return $false }
    if (-not (($path + '\').StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase))) { return $false }
    $actual = Get-TransportArtifactAttestation $path
    if ($null -eq $actual -or $actual.Bytes -ne [int64]$artifact.bytes -or $actual.Sha -cne ([string]$artifact.sha256).ToLowerInvariant()) { return $false }
    $key = 'packet_artifact:' + [string]$artifact.name
    $script:ArtifactHashes[$key] = $actual.Sha
    $script:AttestPath[$key] = $path
    $script:AttestSha[$key] = $actual.Sha
  }
  return $true
}

function Test-FrozenTouchedFiles([string]$RepoPath, $Entries) {
  $backslash = [string][char]92
  $root = [IO.Path]::GetFullPath($RepoPath).TrimEnd($backslash)
  foreach ($entry in @($Entries)) {
    $relative = ([string]$entry.path).Replace('/', $backslash).TrimStart($backslash)
    $full = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not (($full + $backslash).StartsWith($root + $backslash, [StringComparison]::OrdinalIgnoreCase))) { return $false }
    $exists = Test-Path -LiteralPath $full -PathType Leaf
    if ($exists -ne [bool]$entry.exists) { return $false }
    if ($exists -and (Get-FileSha256Hex $full).ToLowerInvariant() -cne ([string]$entry.sha256).ToLowerInvariant()) { return $false }
  }
  return $true
}

function Get-PacketPreflightPath($Artifacts) {
  $hits = @($Artifacts | Where-Object { [string]$_.name -ceq 'review-preflight.json' })
  if ($hits.Count -ne 1) { return $null }
  try { return [IO.Path]::GetFullPath([string]$hits[0].path) } catch { return $null }
}

function Write-ArchiveCreateNew {
  param(
    [string]$Path, [string]$Kind, [int]$SpanValid, [int]$SpanExpected,
    [string[]]$Lines, $Codes, $Hashes
  )
  if (Test-Path -LiteralPath $Path) { return $false }
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $lineArr = New-Object System.Collections.ArrayList
  foreach ($ln in @($Lines)) { if ($null -ne $ln) { [void]$lineArr.Add([string]$ln) } }
  $payload = [ordered]@{
    schema_version   = '1'
    run_id           = $script:Rid
    claim_kind       = $Kind
    timestamp        = [datetimeoffset]::UtcNow.ToString('o')
    reducer_lines    = [string[]]@($lineArr)
    child_exit_codes = $Codes
    artifact_hashes  = $Hashes
    spans_valid      = $SpanValid
    spans_expected   = $SpanExpected
    reducers_ok      = $script:RedOk
    reducers_total   = $script:RedTot
  }
  $json = $payload | ConvertTo-Json -Depth 6 -Compress
  try {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      $bytes = $utf8.GetBytes($json)
      $fs.Write($bytes, 0, $bytes.Length)
    }
    finally { $fs.Dispose() }
  }
  catch { return $false }
  return $true
}

function Parse-SpanCounts([string]$SpanLine) {
  $vv = 0; $nn = 0
  if ($SpanLine -match 'valid:\s*(\d+)') { $vv = [int]$Matches[1] }
  if ($SpanLine -match 'expected:\s*(\d+)') { $nn = [int]$Matches[1] }
  return @{ V = $vv; N = $nn }
}

try {
  if ([string]::IsNullOrWhiteSpace($RunId)) { Emit-Uncertified 'reducer' 2 }
  if ([string]::IsNullOrWhiteSpace($Repo) -or [string]::IsNullOrWhiteSpace($BaseRef)) { Emit-Uncertified 'reducer' 2 }
  if ([string]::IsNullOrWhiteSpace($ReceiptDir) -or [string]::IsNullOrWhiteSpace($PacketManifest)) { Emit-Uncertified 'packet' 2 }
  if ([string]::IsNullOrWhiteSpace($SpanLedger) -or [string]::IsNullOrWhiteSpace($BaseManifest)) { Emit-Uncertified 'spans' 2 }
  if ([string]::IsNullOrWhiteSpace($OutputPath)) { Emit-Uncertified 'archive' 2 }
  if ((-not [string]::IsNullOrWhiteSpace($GateIntegrity) -or -not [string]::IsNullOrWhiteSpace($GateSpans) -or -not [string]::IsNullOrWhiteSpace($GateReview) -or -not [string]::IsNullOrWhiteSpace($GateMerge)) -and $env:FLEET_TEST_HARNESS -cne '1') {
    Emit-Uncertified 'override' 2
  }

  # --- packet ---
  $pkt = Test-PacketManifest $PacketManifest
  if (-not $pkt.Ok) { Emit-Uncertified 'packet' }
  if (-not (Register-Attest 'packet_manifest' $PacketManifest)) { Emit-Uncertified 'packet' }
  if (-not (Test-PacketArtifacts -ManifestPath $PacketManifest -Artifacts $pkt.Artifacts)) { Emit-Uncertified 'packet' }
  if (-not (Test-FrozenTouchedFiles -RepoPath $Repo -Entries $pkt.FrozenTouchedFiles)) { Emit-Uncertified 'packet' }
  if (-not (Register-FleetFrozenTouchedAttestations -RepoPath $Repo -Entries $pkt.FrozenTouchedFiles)) { Emit-Uncertified 'packet' }

  # Preflight sole source = unique packet artifact (never repo-root).
  $pfPath = Get-PacketPreflightPath $pkt.Artifacts
  if ($null -eq $pfPath) { Emit-Uncertified 'preflight' }
  $pfAtt = Get-TransportArtifactAttestation $pfPath
  if ($null -eq $pfAtt -or $pfAtt.Sha -cne $pkt.PreflightSha) { Emit-Uncertified 'preflight' }
  if (-not (Test-FleetPreflightReadyArtifact $pfPath $RunId)) { Emit-Uncertified 'preflight' }
  $script:ArtifactHashes['review_preflight'] = $pfAtt.Sha
  # D2 re-derivation from frozen bytes (Sol H3 2026-08-11): certification repeats the
  # pre-dispatch readiness predicates on the manifest's OWN attested artifacts — canonical
  # status line, single review_profile, RED evidence — never trusting packet-readiness.json.
  try {
    $pfObjCert = Get-Content -LiteralPath $pfPath -Raw | ConvertFrom-Json
    $pfLineCert = ''
    if ($pfObjCert.PSObject.Properties['status_line']) { $pfLineCert = [string]$pfObjCert.status_line }
    if (-not (Test-FleetPreflightStatusLineCanonical $pfLineCert)) { throw 'status_line not canonical' }
  } catch { Emit-Uncertified 'preflight' }
  $lpArt = @($pkt.Artifacts | Where-Object { [string]$_.name -ceq 'locked-plan.md' }) | Select-Object -First 1
  if ($null -ne $lpArt) {
    try { Assert-FleetSingleReviewProfile ([string]$lpArt.path) } catch { Emit-Uncertified 'packet' }
  }
  $trArt = @($pkt.Artifacts | Where-Object { [string]$_.name -ceq 'test-results.json' }) | Select-Object -First 1
  if ($null -ne $trArt) {
    try {
      $trCert = Get-Content -LiteralPath ([string]$trArt.path) -Raw | ConvertFrom-Json
      $trDirCert = Split-Path -Parent ([IO.Path]::GetFullPath([string]$trArt.path))
      Assert-FleetRedEvidence -TestResults $trCert -PacketDir $trDirCert -ReviewRisk ([string]$pkt.ReviewRisk)
    } catch { Emit-Uncertified 'packet' }
  } elseif ([string]$pkt.ReviewRisk -in @('behavior', 'hard')) { Emit-Uncertified 'packet' }

  if (-not (Test-SignedV2Receipts $ReceiptDir)) { Emit-Uncertified 'receipt' }
  if (-not (Snapshot-ReceiptDir $ReceiptDir)) { Emit-Uncertified 'receipt' }
  if (-not (Register-Attest 'span_ledger' $SpanLedger)) { Emit-Uncertified 'spans' }
  if ([string]::IsNullOrWhiteSpace($BaseManifest) -or -not (Test-Path -LiteralPath $BaseManifest -PathType Leaf)) { Emit-Uncertified 'spans' }
  if (-not (Register-Attest 'base_manifest' $BaseManifest)) { Emit-Uncertified 'spans' }
  if (-not (Register-FleetCommitAttestation 'git_commit:HEAD' $Repo 'HEAD')) { Emit-Uncertified 'packet' }
  if (-not (Register-FleetCommitAttestation ('git_commit:' + $BaseRef) $Repo $BaseRef)) { Emit-Uncertified 'packet' }
  if (-not [string]::IsNullOrWhiteSpace($LockedPlan) -and -not (Register-Attest 'locked_plan' $LockedPlan)) { Emit-Uncertified 'packet' }

  $gateIntegrity = Resolve-GatePath $GateIntegrity 'Assert-FleetReviewIntegrity.ps1'
  $gateSpans = Resolve-GatePath $GateSpans 'Assert-FleetLaneSpans.ps1'
  $gateReview = Resolve-GatePath $GateReview 'Assert-FleetAdversarialReview.ps1'
  $gateMerge = Resolve-GatePath $GateMerge 'Assert-FleetMergeReadiness.ps1'

  # Private effective: integrity produces via -OutputManifest; spans consumes. Caller path ignored.
  $privEff = Join-Path ([IO.Path]::GetTempPath()) ('fleet-cert-eff-' + $script:Rid + '-' + [guid]::NewGuid().ToString('N') + '.json')
  if (Test-Path -LiteralPath $privEff) { Remove-Item -LiteralPath $privEff -Force -ErrorAction SilentlyContinue }

  # 1) review-integrity (writes private effective via -OutputManifest)
  $iArgs = @('-ReceiptDir', $ReceiptDir, '-RunId', $RunId, '-SpanLedger', $SpanLedger, '-BaseManifest', $BaseManifest, '-OutputManifest', $privEff, '-ExpectedPacketSha256', $pkt.Sha, '-Mode', 'text')
  if (-not [string]::IsNullOrWhiteSpace($LockedPlan)) { $iArgs += @('-LockedPlan', $LockedPlan) }
  $iRes = Invoke-ChildGate $gateIntegrity $iArgs
  $script:ChildCodes['integrity'] = $iRes.ExitCode
  $iLine = Get-SummaryLine $iRes.Raw 'review-integrity:'
  if ($null -eq $iLine) { Emit-Uncertified 'reducer' }
  Write-Output $iLine
  [void]$script:ReducerLines.Add($iLine)
  if ($iRes.ExitCode -ne 0) { Emit-Uncertified 'integrity' }
  $script:RedOk++
  if (-not (Test-Path -LiteralPath $privEff -PathType Leaf)) { Emit-Uncertified 'spans' }
  if (-not (Register-Attest 'effective_manifest' $privEff)) { Emit-Uncertified 'spans' }

  # 2) lane-spans against integrity-produced effective only
  $sArgs = @('-RunId', $RunId, '-LedgerPath', $SpanLedger, '-ExpectedLaneManifest', $privEff, '-Mode', 'text')
  $sRes = Invoke-ChildGate $gateSpans $sArgs
  $script:ChildCodes['spans'] = $sRes.ExitCode
  $sLine = Get-SummaryLine $sRes.Raw 'lane-spans:'
  if ($null -eq $sLine) { Emit-Uncertified 'reducer' }
  Write-Output $sLine
  [void]$script:ReducerLines.Add($sLine)
  if ($sRes.ExitCode -ne 0) { Emit-Uncertified 'spans' }
  $script:RedOk++
  $spanCounts = Parse-SpanCounts $sLine

  # 3) adversarial-review
  $rArgs = @('-Repo', $Repo, '-BaseRef', $BaseRef, '-RunId', $RunId, '-ReceiptDir', $ReceiptDir, '-PacketManifest', $PacketManifest, '-Mode', 'text')
  if (-not [string]::IsNullOrWhiteSpace($LockedPlan)) { $rArgs += @('-LockedPlan', $LockedPlan) }
  $rRes = Invoke-ChildGate $gateReview $rArgs
  $script:ChildCodes['review'] = $rRes.ExitCode
  $rLine = Get-SummaryLine $rRes.Raw 'review:'
  if ($null -eq $rLine) { Emit-Uncertified 'reducer' }
  Write-Output $rLine
  [void]$script:ReducerLines.Add($rLine)
  if ($rRes.ExitCode -ne 0) { Emit-Uncertified 'review' }
  $script:RedOk++

  # 4) merge-readiness (MergeReadiness only)
  if ($ClaimKind -eq 'MergeReadiness') {
    $mArgs = @('-ReceiptDir', $ReceiptDir, '-RunId', $RunId, '-ExpectedPacketSha256', $pkt.Sha)
    $mRes = Invoke-ChildGate $gateMerge $mArgs
    $script:ChildCodes['merge'] = $mRes.ExitCode
    $mLine = Get-SummaryLine $mRes.Raw 'merge-readiness:'
    if ($null -eq $mLine) { Emit-Uncertified 'reducer' }
    Write-Output $mLine
    [void]$script:ReducerLines.Add($mLine)
    if ($mRes.ExitCode -ne 0) { Emit-Uncertified 'reducer' }
    $script:RedOk++
  }

  if (-not (Test-AttestIntact)) { Emit-Uncertified 'drift' }
  $wrote = Write-ArchiveCreateNew -Path $OutputPath -Kind $ClaimKind `
    -SpanValid $spanCounts.V -SpanExpected $spanCounts.N `
    -Lines @($script:ReducerLines) -Codes $script:ChildCodes -Hashes $script:ArtifactHashes
  if (-not $wrote) { Emit-Uncertified 'archive' }

  Emit-Certified $spanCounts.V $spanCounts.N
}
catch {
  try { Emit-Uncertified 'reducer' } catch { Write-Output "certification: UNCERTIFIED | run: $($script:Rid) | failed: reducer | reducers: $($script:RedOk)/$($script:RedTot)"; exit 1 }
}
