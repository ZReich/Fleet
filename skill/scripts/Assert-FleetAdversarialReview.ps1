# Gate: Fleet run needs a real adversarial-review receipt covering shipped diff.
# Summary: review: <tier> | voices: N qualified / M candidates / R required [| profile: ... | security-voices: P/2] [| kimi-seat: ok|excused|MISSING|unknown (FULL only)] | packet: <state> | verdict: ok|FAILED
# Authority: signed review_lane receipts under -ReceiptDir (HMAC via run lease). Filename is display only.
# -ReviewProfile / -Tier optional assertions; signed plan-derived values win; conflict => FAILED.
param(
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$BaseRef,
  [Parameter(Mandatory)][string]$RunId,
  [Parameter(Mandatory)][string]$ReceiptDir,
  [Parameter(Mandatory)][string]$PacketManifest,
  [string]$ReviewDir,
  [ValidateSet('MICRO', 'LIGHT', 'STANDARD', 'FULL')][string]$Tier,
  [ValidateSet('general', 'security-sensitive')][string]$ReviewProfile,
  [string]$LockedPlan,
  [string[]]$PathFilter = @(),
  [ValidateSet('text', 'json')][string]$Mode = 'text'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetReviewVoice.Helpers.ps1')

# Use result_path basename so *.json status (needs_gate_validation) is enforced.
# voice_id/lane_id alone lose the extension and mis-classify JSON as markdown.
function Get-FleetVoiceAssessmentsFromReceipts {
  param([object[]]$Items)
  $rows = New-Object System.Collections.ArrayList
  foreach ($it in @($Items)) {
    $r = $it.Receipt; $req = [string]$r.requested_model; $mk = Get-VoiceModelKey $req
    $isSec = Test-SignedSecurityRole $r
    $secQualRole = ($isSec -and ($mk -in $script:OpenWeightKeys))
    $rp = [string]$it.ResultPath
    $name = [IO.Path]::GetFileName($rp)
    if ([string]::IsNullOrWhiteSpace($name)) {
      $disp = [string]$r.voice_id
      if ([string]::IsNullOrWhiteSpace($disp)) { $disp = [string]$r.lane_id }
      $name = $disp
      if ($name -notmatch '\.') { $name = "$name.md" }
    }
    $bytes = [int64]([Text.Encoding]::UTF8.GetByteCount([string]$it.Content))
    $reason = Test-FleetVoiceContent -Name $name -Text ([string]$it.Content) -Bytes $bytes -IsSecurityRole:([bool]$isSec)
    [void]$rows.Add([pscustomobject]@{
        Name = $name; Stem = [IO.Path]::GetFileNameWithoutExtension($name)
        Path = $rp; Qualified = ($null -eq $reason); Reason = $reason
        ModelKey = $mk; IsSecurityRole = [bool]$secQualRole
        ReviewRole = [string]$r.review_role; RequestedModel = $req
      })
  }
  return @($rows)
}

function Get-Sha256Hex([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) }
  finally { $sha.Dispose() }
}

function Get-RequiredVoiceCount([string]$T) {
  switch ($T) {
    'MICRO' { return 0 }
    'LIGHT' { return 2 }
    'STANDARD' { return 3 }
    'FULL' { return 5 }
    default { throw "Unknown tier: $T" }
  }
}

function Quote-GitArg([string]$Value) {
  if ($null -eq $Value) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  return '"' + ($Value.Replace('"', '\"')) + '"'
}

function Get-ShippedDiffBytes {
  # Committed range only: raw bytes of `git diff <base>..HEAD` (never working tree).
  # Coverage binds to this range vs frozen packet final.diff (SHA-256 equality).
  param([string]$RepoPath, [string]$Base, [string[]]$Paths)
  $parts = New-Object System.Collections.ArrayList
  [void]$parts.Add('-C'); [void]$parts.Add((Quote-GitArg $RepoPath))
  [void]$parts.Add('--no-pager'); [void]$parts.Add('diff')
  [void]$parts.Add((Quote-GitArg ($Base + '..HEAD')))
  if ($Paths -and @($Paths).Count -gt 0) {
    [void]$parts.Add('--')
    foreach ($p in @($Paths)) { [void]$parts.Add((Quote-GitArg $p)) }
  }
  $proc = New-Object System.Diagnostics.Process
  $psi = $proc.StartInfo
  $psi.FileName = 'git'; $psi.Arguments = ($parts -join ' ')
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  [void]$proc.Start()
  $ms = New-Object System.IO.MemoryStream
  try {
    $proc.StandardOutput.BaseStream.CopyTo($ms)
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "git diff failed (exit $($proc.ExitCode)): $err" }
    return $ms.ToArray()
  }
  finally { $ms.Dispose(); $proc.Dispose() }
}

function Find-FinalDiff([string]$Dir, [string]$ManifestPath) {
  if (-not [string]::IsNullOrWhiteSpace($Dir)) {
    $direct = Join-Path $Dir 'final.diff'
    if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
  }
  if ($ManifestPath) {
    $beside = Join-Path (Split-Path -Parent $ManifestPath) 'final.diff'
    if (Test-Path -LiteralPath $beside -PathType Leaf) { return $beside }
  }
  if (-not [string]::IsNullOrWhiteSpace($Dir) -and (Test-Path -LiteralPath $Dir -PathType Container)) {
    $found = @(Get-ChildItem -LiteralPath $Dir -Filter 'final.diff' -File -Recurse -ErrorAction SilentlyContinue)
    if ($found.Count -gt 0) { return $found[0].FullName }
  }
  return $null
}

function Test-ManifestShape([string]$Path) {
  try { $m = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
  catch { return "manifest unparseable: $($_.Exception.Message)" }
  if ($null -eq $m) { return 'manifest empty' }
  $names = @($m.PSObject.Properties.Name)
  foreach ($req in @('schema_version', 'packet_sha256', 'review_risk', 'artifacts')) {
    if ($req -notin $names) { return "manifest missing field: $req" }
  }
  if ([string]::IsNullOrWhiteSpace([string]$m.schema_version)) { return 'manifest schema_version blank' }
  if ([string]::IsNullOrWhiteSpace([string]$m.packet_sha256)) { return 'manifest packet_sha256 blank' }
  if ([string]::IsNullOrWhiteSpace([string]$m.review_risk)) { return 'manifest review_risk blank' }
  if ($null -eq $m.artifacts -or $m.artifacts -is [string] -or $m.artifacts -isnot [Collections.IEnumerable]) {
    return 'manifest artifacts must be an array'
  }
  $arts = @($m.artifacts)
  if ($arts.Count -eq 0) { return 'manifest artifacts[] empty' }
  foreach ($a in $arts) {
    if ($null -eq $a) { return 'manifest artifact entry null' }
    $an = @($a.PSObject.Properties.Name)
    foreach ($f in @('name', 'bytes', 'sha256')) {
      if ($f -notin $an) { return "manifest artifact missing $f" }
    }
    if ([string]::IsNullOrWhiteSpace([string]$a.name)) { return 'manifest artifact name blank' }
    if ([string]::IsNullOrWhiteSpace([string]$a.sha256)) { return 'manifest artifact sha256 blank' }
  }
  return $null
}

function Format-Summary([string]$T, [int]$Q, [int]$C, [int]$R, [string]$P, [string]$V, [string]$Prof = 'general', [int]$SecP = 0, [string]$KimiSeat = '') {
  $seat = if ([string]::IsNullOrWhiteSpace($KimiSeat)) { '' } else { " | kimi-seat: $KimiSeat" }
  if ($Prof -eq 'security-sensitive') {
    return "review: $T | voices: $Q qualified / $C candidates / $R required | profile: security-sensitive | security-voices: $SecP/2$seat | packet: $P | verdict: $V"
  }
  return "review: $T | voices: $Q qualified / $C candidates / $R required$seat | packet: $P | verdict: $V"
}

function Write-Result {
  param(
    [string]$Summary, [string]$Verdict, [string]$Packet, [int]$Qualified, [int]$Candidates,
    [int]$Required, [object[]]$VoiceRows, [string]$Message = $null, [string]$VoicesNote = $null,
    [string]$KimiSeat = ''
  )
  $qualifiedNames = @($VoiceRows | Where-Object { $_.Qualified } | ForEach-Object { $_.Name } | Select-Object -Unique)
  if ($Mode -eq 'json') {
    $details = @($VoiceRows | ForEach-Object {
        $d = [ordered]@{ name = $_.Name; stem = $_.Stem; qualified = [bool]$_.Qualified }
        if (-not $_.Qualified -and $_.Reason) { $d['reason'] = $_.Reason }
        $d
      })
    $obj = [ordered]@{
      tier              = $Tier
      voices            = $Qualified
      voices_qualified  = $Qualified
      voices_candidates = $Candidates
      voices_required   = $Required
      packet            = $Packet
      verdict           = $Verdict
      voice_files       = @($qualifiedNames)
      voices_detail     = @($details)
    }
    if (-not [string]::IsNullOrWhiteSpace($KimiSeat)) { $obj['kimi_seat'] = $KimiSeat }
    if ($Message) { $obj['message'] = $Message }
    if ($VoicesNote) { $obj['voices_note'] = $VoicesNote }
    Write-Output (($obj | ConvertTo-Json -Compress -Depth 6))
  }
  else {
    if ($Message) { Write-Output $Message }
    if ($VoicesNote) { Write-Output $VoicesNote }
    Write-Output $Summary
  }
}

function Emit-Fail([string]$Msg, [string]$T, [int]$Req, [string]$Prof, [string]$Pkt = 'missing') {
  # FULL lines always carry the seat segment; pre-analysis failures cannot know it.
  $seat = if ($T -eq 'FULL') { 'unknown' } else { '' }
  $summary = Format-Summary $T 0 0 $Req $Pkt 'FAILED' $Prof 0 $seat
  Write-Result -Summary $summary -Verdict 'FAILED' -Packet $Pkt -Qualified 0 -Candidates 0 `
    -Required $Req -VoiceRows @() -Message $Msg -KimiSeat $seat
  exit 1
}

# --- main ---
$callerTier = $PSBoundParameters.ContainsKey('Tier')
$callerProfile = $PSBoundParameters.ContainsKey('ReviewProfile')
$hasLockedPlan = -not [string]::IsNullOrWhiteSpace($LockedPlan)
if (-not $callerTier) { $Tier = 'STANDARD' }
if (-not $callerProfile) { $ReviewProfile = 'general' }
if ($PathFilter -and @($PathFilter).Count -gt 0) { Emit-Fail 'PathFilter is not supported for committed certification coverage' $Tier $required $ReviewProfile }
$resolvedRepo = (Resolve-Path -LiteralPath $Repo).Path
if ([string]::IsNullOrWhiteSpace($ReviewDir)) { $ReviewDir = Join-Path $resolvedRepo '.fleet-review' }
$shippedBytes = Get-ShippedDiffBytes -RepoPath $resolvedRepo -Base $BaseRef -Paths $PathFilter
$nonEmpty = ($null -ne $shippedBytes -and $shippedBytes.Length -gt 0)

# L1: BaseRef==HEAD or empty shipped diff is not "nothing to review ok" for non-MICRO / security.
$baseIsHead = $false
try {
  $headSha = (& git -C $resolvedRepo rev-parse HEAD 2>$null | Out-String).Trim()
  $baseSha = (& git -C $resolvedRepo rev-parse $BaseRef 2>$null | Out-String).Trim()
  if ($headSha -and $baseSha -and ($headSha -eq $baseSha)) { $baseIsHead = $true }
} catch { }

if (-not $nonEmpty) {
  $required = Get-RequiredVoiceCount $Tier
  if ($Tier -ne 'MICRO') {
    Emit-Fail "empty shipped diff vs $BaseRef (non-MICRO requires real diff; zero-telemetry rejected)" $Tier $required $ReviewProfile
  }
  if ($ReviewProfile -eq 'security-sensitive') {
    Emit-Fail "security-sensitive empty shipped diff vs $BaseRef (FAILED, not nothing-to-review)" $Tier $required $ReviewProfile
  }
  $note = 'voices were not required'
  Write-Result -Summary (Format-Summary $Tier 0 0 $required 'match' 'ok' $ReviewProfile 0) -Verdict 'ok' `
    -Packet 'match' -Qualified 0 -Candidates 0 -Required $required -VoiceRows @() `
    -Message "nothing to review (empty shipped diff vs $BaseRef)" -VoicesNote $note
  exit 0
}
if ($baseIsHead -and $Tier -ne 'MICRO') {
  Emit-Fail "BaseRef resolves to HEAD (no real diff) for non-MICRO review" $Tier (Get-RequiredVoiceCount $Tier) $ReviewProfile
}

try { $verified = Get-VerifiedReviewLaneReceipts -RunId $RunId -ReceiptDir $ReceiptDir }
catch { Emit-Fail ("lease/receipt load failed: " + $_.Exception.Message) $Tier (Get-RequiredVoiceCount $Tier) $ReviewProfile }
if (-not $verified.Ok) { Emit-Fail ([string]$verified.Error) $Tier (Get-RequiredVoiceCount $Tier) $ReviewProfile }

$auth = Resolve-FleetReviewAuthority -Verified $verified -LockedPlan $LockedPlan -HasLockedPlan:$hasLockedPlan `
  -CallerProfile $(if ($callerProfile) { $PSBoundParameters['ReviewProfile'] } else { $null }) `
  -CallerTier $(if ($callerTier) { $PSBoundParameters['Tier'] } else { $null }) `
  -DefaultProfile $ReviewProfile -DefaultTier $Tier
if (-not $auth.Ok) { Emit-Fail ([string]$auth.Error) $Tier (Get-RequiredVoiceCount $Tier) $ReviewProfile }
$ReviewProfile = [string]$auth.Profile; $Tier = [string]$auth.Tier
$required = Get-RequiredVoiceCount $Tier

# L3: bind LockedPlan file hash to signed locked_plan_sha256 (security receipts).
if ($hasLockedPlan) {
  if (-not (Test-Path -LiteralPath $LockedPlan -PathType Leaf)) {
    Emit-Fail "LockedPlan missing: $LockedPlan" $Tier $required $ReviewProfile
  }
  $planFileSha = (Get-FileSha256Hex $LockedPlan).ToLowerInvariant()
  foreach ($it in @($verified.Items)) {
    $rr = $it.Receipt
    if (-not (Test-SignedSecurityRole $rr)) { continue }
    $signedPlan = ''; if ($rr.PSObject.Properties['locked_plan_sha256']) { $signedPlan = ([string]$rr.locked_plan_sha256).ToLowerInvariant() }
    if ($signedPlan -cne $planFileSha) {
      Emit-Fail "locked_plan_sha256 mismatch for security receipt (signed=$signedPlan file=$planFileSha)" $Tier $required $ReviewProfile
    }
  }
}

if (-not (Test-Path -LiteralPath $PacketManifest -PathType Leaf)) {
  Emit-Fail "PacketManifest missing: $PacketManifest" $Tier $required $ReviewProfile
}
$finalDiffPath = Find-FinalDiff $ReviewDir $PacketManifest
$packetStatus = 'missing'; $packetMsg = $null
$shapeErr = Test-ManifestShape $PacketManifest
if ($shapeErr) { $packetMsg = "review packet manifest invalid: $shapeErr" }
elseif (-not $finalDiffPath) { $packetMsg = 'review packet incomplete (need final.diff beside PacketManifest or under ReviewDir)' }
else {
  $shippedHash = Get-Sha256Hex $shippedBytes; $frozenHash = Get-Sha256Hex ([IO.File]::ReadAllBytes($finalDiffPath))
  if ($shippedHash -eq $frozenHash) { $packetStatus = 'match' }
  else { $packetStatus = 'MISMATCH'; $packetMsg = "review predates the shipped changes: frozen final.diff SHA-256 does not match shipped diff vs $BaseRef" }
}

$voiceRows = @(Get-FleetVoiceAssessmentsFromReceipts -Items $verified.Items)
$candidates = $voiceRows.Count
$qualifiedModels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($row in $voiceRows) {
  if ($row.Qualified -and -not [string]::IsNullOrWhiteSpace([string]$row.ModelKey)) {
    [void]$qualifiedModels.Add([string]$row.ModelKey)
  }
}
$voiceCount = $qualifiedModels.Count
$voicesOk = ($voiceCount -ge $required); if ($Tier -eq 'MICRO' -and $required -eq 0) { $voicesOk = $true }
$secPreferred = 0; $securityOk = $true
if ($ReviewProfile -eq 'security-sensitive') {
  $secStats = Get-SecurityVoiceStats $voiceRows
  $secPreferred = [int]$secStats.Preferred
  $securityOk = ($Tier -eq 'FULL') -and [bool]$secStats.Ok
  if (-not $packetMsg) {
    if ($Tier -ne 'FULL') { $packetMsg = "security-sensitive profile requires Tier=FULL (got $Tier)" }
    elseif (-not $secStats.Ok) { $packetMsg = 'security-sensitive: need >=1 qualified open-weights security identity (glm|kimi preferred; grok backup)' }
  }
}
# FULL: the Kimi K3 seat is REQUIRED, first-class (owner 2026-08-15) — dispatch-mandatory-
# or-excused. A kimi receipt must EXIST: qualified => 'ok' (counts as a voice like any
# other), present-but-unqualified (provider flake / refusal / format loss) => 'excused'
# (never sinks the run), NO kimi receipt at all => 'MISSING' => FAILED. Silence is the
# only failure mode; a flaked dispatch leaves a receipt and is excused.
$kimiSeatOk = $true; $kimiSeat = ''
if ($Tier -eq 'FULL') {
  $kimiRows = @($voiceRows | Where-Object { [string]$_.ModelKey -eq 'kimi' })
  if ($kimiRows.Count -eq 0) {
    $kimiSeatOk = $false; $kimiSeat = 'MISSING'
    if (-not $packetMsg) { $packetMsg = 'FULL requires the Kimi K3 seat: no kimi receipt found. Dispatch it (Invoke-KimiK3.ps1 -RepoSandbox <repo> for repo-wide review); a flaked lane leaves a receipt and is excused - silent non-dispatch is the failure.' }
  }
  elseif (@($kimiRows | Where-Object { $_.Qualified }).Count -gt 0) { $kimiSeat = 'ok' }
  else { $kimiSeat = 'excused' }
}
$verdict = 'FAILED'
if ($packetStatus -eq 'match' -and $voicesOk -and $securityOk -and $kimiSeatOk) { $verdict = 'ok' }
$note = $null; if ($Tier -eq 'MICRO' -and $required -eq 0) { $note = 'voices were not required' }
Write-Result -Summary (Format-Summary $Tier $voiceCount $candidates $required $packetStatus $verdict $ReviewProfile $secPreferred $kimiSeat) `
  -Verdict $verdict -Packet $packetStatus -Qualified $voiceCount -Candidates $candidates -Required $required `
  -VoiceRows $voiceRows -Message $packetMsg -VoicesNote $note -KimiSeat $kimiSeat
if ($verdict -eq 'ok') { exit 0 }
exit 1
