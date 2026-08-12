# Dot-sourced helpers for Assert-FleetAdversarialReview.ps1.
# Security identity + model keys from SIGNED receipt fields (not filenames).
. (Join-Path $PSScriptRoot 'FleetLaneRefusal.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetReviewGrammar.Helpers.ps1')

$script:KnownModelTokens = @('sol', 'terra', 'luna', 'opus', 'fable', 'glm', 'grok', 'kimi', 'gemini', 'spark')
$script:OpenWeightKeys = @('glm', 'kimi', 'grok')
$script:FleetVoiceMinBytes = 200
$script:FleetVoiceSuccessStatuses = @('ok', 'done', 'passed')
# Exact voice_key -> allowlisted transport (mismatch fails before dispatch).
$script:FleetVoiceTransportMap = @{
  'kimi' = 'Invoke-KimiK3'; 'glm' = 'Invoke-PiGlm'; 'grok' = 'Invoke-Grok45'
  'sol' = 'Invoke-Sol'; 'terra' = 'Invoke-Sol'; 'luna' = 'Invoke-Sol'
  'opus' = 'Invoke-Opus48'; 'fable' = 'Invoke-Sol'
}
$script:FleetIdGrammar = '^[A-Za-z0-9._-]+$'
# PS 5.1 ConvertFrom-Json does not preserve order; rehydrate before HMAC shape check.
$script:ReviewLaneFieldOrder = @(
  'schema_version','receipt_type','run_id','task_id','lane_id','voice_id','review_role',
  'requested_model','observed_model','model_evidence','emitter_id','input_packet_sha256',
  'expected_lane_manifest_sha256','locked_plan_sha256','review_profile','charter_path',
  'review_tier','result_path','charter_sha256','result_sha256','exit_code','outcome',
  'refusal_reason','fallback_of','started_at','completed_at','sig_alg','key_id','signature'
)

function Test-FleetIdGrammar([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return [bool]($Value -match $script:FleetIdGrammar)
}

function Test-FleetVoiceTransportBinding([string]$VoiceId, [string]$Transport) {
  if ([string]::IsNullOrWhiteSpace($VoiceId) -or [string]::IsNullOrWhiteSpace($Transport)) {
    return @{ Ok = $false; Reason = 'voice/transport blank'; VoiceKey = ''; Want = '' }
  }
  $vk = Get-VoiceModelKey $VoiceId
  if ([string]::IsNullOrWhiteSpace($vk) -or -not $script:FleetVoiceTransportMap.ContainsKey($vk)) {
    return @{ Ok = $false; Reason = ("voice not bound: {0}" -f $VoiceId); VoiceKey = $vk; Want = '' }
  }
  $want = [string]$script:FleetVoiceTransportMap[$vk]
  if ($Transport -cne $want) {
    return @{ Ok = $false; Reason = ("voice-transport mismatch: voice={0} key={1} transport={2} want={3}" -f $VoiceId, $vk, $Transport, $want); VoiceKey = $vk; Want = $want }
  }
  return @{ Ok = $true; Reason = ''; VoiceKey = $vk; Want = $want }
}

function Get-FleetContainedReceiptPath([string]$ReceiptDir, [string]$LeafName) {
  if (-not (Test-FleetIdGrammar $LeafName)) {
    throw ("receipt leaf grammar: {0}" -f $LeafName)
  }
  if ($LeafName.Contains([IO.Path]::DirectorySeparatorChar) -or $LeafName.Contains([IO.Path]::AltDirectorySeparatorChar)) {
    throw ("receipt leaf not single-segment: {0}" -f $LeafName)
  }
  $dirFull = [IO.Path]::GetFullPath($ReceiptDir).TrimEnd('\', '/')
  $combined = [IO.Path]::GetFullPath((Join-Path $dirFull $LeafName))
  $parent = [IO.Path]::GetFullPath((Split-Path -Parent $combined)).TrimEnd('\', '/')
  if ($parent -cne $dirFull) {
    throw ("path escapes receipt dir: leaf={0} parent={1} want={2}" -f $LeafName, $parent, $dirFull)
  }
  return $combined
}

function Assert-FleetPathInReceiptDir([string]$ReceiptDir, [string]$TargetPath) {
  if ([string]::IsNullOrWhiteSpace($TargetPath)) { throw 'target path blank' }
  $dirFull = [IO.Path]::GetFullPath($ReceiptDir).TrimEnd('\', '/')
  $full = [IO.Path]::GetFullPath($TargetPath)
  $parent = [IO.Path]::GetFullPath((Split-Path -Parent $full)).TrimEnd('\', '/')
  if ($parent -cne $dirFull) {
    throw ("path escapes receipt dir: path={0} parent={1} want={2}" -f $TargetPath, $parent, $dirFull)
  }
  $leaf = Split-Path -Leaf $full
  if (-not (Test-FleetIdGrammar $leaf)) { throw ("receipt leaf grammar: {0}" -f $leaf) }
  return $full
}

function Assert-FleetSnapshotAncestorChain([string]$SnapshotPath, [string]$RuntimeRoot, [switch]$RequireSnapshot) {
  # Inspect each entry itself, rather than resolving the complete path first: resolving
  # would follow a malicious parent junction before we could reject it.
  if ([string]::IsNullOrWhiteSpace($SnapshotPath) -or [string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    throw 'snapshot/runtime path blank'
  }
  $rootFull = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\', '/')
  $snapFull = [IO.Path]::GetFullPath($SnapshotPath)
  $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
  if (-not $snapFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw ("snapshot escapes run runtime root: snapshot={0} root={1}" -f $snapFull, $rootFull)
  }

  $current = $snapFull
  while ($true) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ("snapshot ancestor reparse point forbidden: {0}" -f $current)
      }
    } elseif ($current -ceq $snapFull -and $RequireSnapshot) {
      throw ("snapshot missing during dispatch verification: {0}" -f $snapFull)
    } elseif ($current -cne $snapFull) {
      throw ("snapshot ancestor missing: {0}" -f $current)
    }
    if ($current -ceq $rootFull) { break }
    $parent = [IO.Path]::GetFullPath((Split-Path -Parent $current)).TrimEnd('\', '/')
    if ($parent -ceq $current) { throw ("snapshot ancestor walk escaped runtime root: {0}" -f $current) }
    $current = $parent
  }
  return $snapFull
}

function New-FleetCharterSnapshot([string]$SourcePath, [string]$SnapshotPath, [string]$RuntimeRoot) {
  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw ("charter source missing: {0}" -f $SourcePath)
  }
  $parent = Split-Path -Parent $SnapshotPath
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  # Hold the source before reading it: these exact bytes are hashed and copied to the snapshot.
  $source = [IO.File]::Open($SourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $created = $false
  $writer = $null
  $snapshot = $null
  try {
    $bytes = New-Object byte[] $source.Length
    $offset = 0
    while ($offset -lt $bytes.Length) {
      $read = $source.Read($bytes, $offset, $bytes.Length - $offset)
      if ($read -le 0) { throw "charter read truncated: $SourcePath" }
      $offset += $read
    }
    # Creation is short-lived: a durable write handle blocks ordinary FileShare.Read readers.
    $writer = [IO.File]::Open($SnapshotPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $created = $true
    $writer.Write($bytes, 0, $bytes.Length)
    $writer.Flush($true)
    $writer.Dispose()
    $writer = $null
    # The write-close/read-open interval is protected by this path-chain check and the
    # run-scoped exclusive runtime directory.  Verify it before reopening by path.
    $null = Assert-FleetSnapshotAncestorChain -SnapshotPath $SnapshotPath -RuntimeRoot $RuntimeRoot -RequireSnapshot
    # Hold read-only through transport: FileShare.Read admits readers, not writers/deleters.
    $snapshot = [IO.File]::Open($SnapshotPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
      $sb = New-Object Text.StringBuilder 64
      foreach ($x in $sha.ComputeHash($snapshot)) { [void]$sb.Append($x.ToString('x2')) }
      $charterSha = $sb.ToString()
    } finally { $sha.Dispose() }
    $snapshot.Position = 0
  } catch {
    if ($null -ne $writer) { $writer.Dispose(); $writer = $null }
    if ($null -ne $snapshot) { $snapshot.Dispose(); $snapshot = $null }
    if ($created -and (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)) { Remove-Item -LiteralPath $SnapshotPath -Force -ErrorAction SilentlyContinue }
    throw
  } finally { $source.Dispose() }
  # Do not return the hash separately: callers must retain this exact held stream.
  return [pscustomobject]@{ CharterSha256 = $charterSha; Hold = $snapshot }
}

function Write-FleetCreateNewAtomic([string]$Path, [string]$Text, $Encoding) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  $tmp = $Path + '.partial.' + [guid]::NewGuid().ToString('n')
  try {
    $fs = [IO.File]::Open($tmp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      $b = $Encoding.GetBytes($Text)
      $fs.Write($b, 0, $b.Length)
    } finally { $fs.Dispose() }
    [IO.File]::Move($tmp, $Path)
  } catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    throw
  }
}

function ConvertTo-OrderedReviewReceipt($Obj) {
  if ($null -eq $Obj) { return $null }
  $have = @($Obj.PSObject.Properties | ForEach-Object { $_.Name })
  if ($have.Count -ne $script:ReviewLaneFieldOrder.Count) { return $null }
  $o = [ordered]@{}
  foreach ($n in $script:ReviewLaneFieldOrder) {
    if ($n -notin $have) { return $null }
    $o[$n] = $Obj.$n
  }
  return [pscustomobject]$o
}

function Get-VoiceModelKey([string]$ModelOrStem) {
  if ([string]::IsNullOrWhiteSpace($ModelOrStem)) { return '' }
  $lower = $ModelOrStem.ToLowerInvariant()
  foreach ($tok in $script:KnownModelTokens) {
    if ($lower -match ('(^|[^a-z0-9])' + [regex]::Escape($tok) + '([^a-z0-9]|$)')) { return $tok }
  }
  return $lower
}




function Test-FleetVoiceContent([string]$Name, [string]$Text, [int64]$Bytes, [bool]$IsSecurityRole = $false) {
  if ($Bytes -lt $script:FleetVoiceMinBytes) { return "too small ($Bytes < $($script:FleetVoiceMinBytes) bytes)" }
  if ([string]::IsNullOrWhiteSpace($Text)) { return 'blank body' }
  $isJson = ($Name -like '*-review*.json' -or $Name -like '*-result.json')
  $bodyForSub = $Text
  if ($isJson) {
    try { $obj = $Text | ConvertFrom-Json -ErrorAction Stop } catch { return 'json unparseable' }
    if ($null -eq $obj) { return 'json null' }
    $st = $null; if ($obj.PSObject.Properties['status']) { $st = [string]$obj.status }
    if ([string]::IsNullOrWhiteSpace($st) -or ($st -notin $script:FleetVoiceSuccessStatuses)) {
      return "json status not success (got '$st')"
    }
    $body = ''; if ($obj.PSObject.Properties['response']) { $body = [string]$obj.response }
    if ([string]::IsNullOrWhiteSpace($body) -and $obj.PSObject.Properties['verdict']) { $body = [string]$obj.verdict }
    if ([string]::IsNullOrWhiteSpace($body)) { return 'json missing nonempty response/verdict' }
    # JSON envelopes get NO grammar bypass (Sol H2 2026-08-11): the extracted response must
    # satisfy the same single-source verdict grammar as markdown voices.
    $parsedJson = Parse-FleetReviewVerdict $body
    if (-not $parsedJson.valid) { return ('verdict grammar invalid: ' + (@($parsedJson.errors) -join '; ')) }
    $bodyForSub = $body
  } else {
    # Single-source grammar (FleetReviewGrammar.Helpers.ps1): the charter builder pastes the
    # exact grammar this parser enforces, so a failure here is a re-dispatchable defect.
    $parsed = Parse-FleetReviewVerdict $Text
    if (-not $parsed.valid) { return ('verdict grammar invalid: ' + (@($parsed.errors) -join '; ')) }
  }
  # Security-review: bare severity alone is not a completed review.
  if ($IsSecurityRole -and -not (Test-FleetLaneReviewSubstance -Text $bodyForSub)) {
    return 'security voice lacks completed-review substance (VERDICT|evidence finding|no-findings)'
  }
  $refusal = Test-FleetLaneRefusal -Result $Text -ExitCode 0 -IsSecuritySensitive:([bool]$IsSecurityRole)
  if ($refusal.refused) {
    $why = $refusal.reason; if ([string]::IsNullOrWhiteSpace([string]$why)) { $why = 'refused' }
    return "refusal ($why)"
  }
  return $null
}

function Get-LockedPlanReviewProfile([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) {
    return [pscustomobject]@{ Ok = $false; Profile = $null; Error = 'locked-plan path blank' }
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return [pscustomobject]@{ Ok = $false; Profile = $null; Error = "locked-plan missing: $Path" }
  }
  $text = [IO.File]::ReadAllText($Path)
  $hits = [regex]::Matches($text, '(?m)^\s*review_profile\s*:\s*(general|security-sensitive)\s*$')
  if ($hits.Count -eq 0) {
    return [pscustomobject]@{ Ok = $false; Profile = $null; Error = 'locked-plan missing or unparseable review_profile: general|security-sensitive' }
  }
  if ($hits.Count -gt 1) {
    return [pscustomobject]@{ Ok = $false; Profile = $null; Error = 'locked-plan duplicate review_profile lines' }
  }
  return [pscustomobject]@{ Ok = $true; Profile = $hits[0].Groups[1].Value.ToLowerInvariant(); Error = $null }
}

# Preferred: glm|kimi security-review; backup: grok security-review. Signed fields only.
function Get-SecurityVoiceStats([object[]]$Rows) {
  $hasGlm = $false; $hasKimi = $false; $hasGrok = $false
  foreach ($r in @($Rows)) {
    if (-not $r.Qualified) { continue }
    $isSec = $false; if ($r.PSObject.Properties['IsSecurityRole']) { $isSec = [bool]$r.IsSecurityRole }
    if (-not $isSec) { continue }
    $mk = ''; if ($r.PSObject.Properties['ModelKey']) { $mk = [string]$r.ModelKey }
    if ($mk -eq 'glm') { $hasGlm = $true } elseif ($mk -eq 'kimi') { $hasKimi = $true } elseif ($mk -eq 'grok') { $hasGrok = $true }
  }
  $preferred = 0; if ($hasGlm) { $preferred++ }; if ($hasKimi) { $preferred++ }
  return [pscustomobject]@{ Preferred = $preferred; Ok = (($preferred -gt 0) -or $hasGrok) }
}

function Get-VerifiedReviewLaneReceipts {
  param([Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$ReceiptDir)
  $keyInfo = Get-FleetRunLeaseKey -RunId $RunId
  $secret = [byte[]]$keyInfo.KeyBytes; $keyId = [string]$keyInfo.KeyId
  if (-not (Test-Path -LiteralPath $ReceiptDir -PathType Container)) {
    return [pscustomobject]@{ Ok = $false; Error = "ReceiptDir missing: $ReceiptDir"; Items = @(); Profile = $null; Tier = $null }
  }
  $files = @(Get-ChildItem -LiteralPath $ReceiptDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('_') } | Sort-Object Name)
  if ($files.Count -eq 0) {
    return [pscustomobject]@{ Ok = $true; Error = $null; Items = @(); Profile = $null; Tier = $null }
  }
  $items = New-Object System.Collections.ArrayList
  $prof = $null; $tier = $null
  foreach ($f in $files) {
    try { $raw = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json -ErrorAction Stop }
    catch { return [pscustomobject]@{ Ok = $false; Error = "receipt unparseable: $($f.Name)"; Items = @(); Profile = $null; Tier = $null } }
    $obj = ConvertTo-OrderedReviewReceipt $raw
    if ($null -eq $obj) { return [pscustomobject]@{ Ok = $false; Error = "receipt noncanonical: $($f.Name)"; Items = @(); Profile = $null; Tier = $null } }
    $sig = $null; if ($obj.PSObject.Properties['signature']) { $sig = [string]$obj.signature }
    $vr = Test-FleetReceiptSignature -Receipt $obj -ReceiptType 'review_lane' -RunSecret $secret -KeyId $keyId -Signature $sig
    if (-not $vr.ok) { return [pscustomobject]@{ Ok = $false; Error = "signature $($vr.reason): $($f.Name)"; Items = @(); Profile = $null; Tier = $null } }
    if ([string]$obj.run_id -cne $RunId) { return [pscustomobject]@{ Ok = $false; Error = "run_id mismatch: $($f.Name)"; Items = @(); Profile = $null; Tier = $null } }
    $rp = [string]$obj.result_path
    if (-not (Test-Path -LiteralPath $rp -PathType Leaf)) { return [pscustomobject]@{ Ok = $false; Error = "result missing for $($f.Name)"; Items = @(); Profile = $null; Tier = $null } }
    if ((Get-FileSha256Hex $rp).ToLowerInvariant() -cne ([string]$obj.result_sha256).ToLowerInvariant()) {
      return [pscustomobject]@{ Ok = $false; Error = "result hash mismatch: $($f.Name)"; Items = @(); Profile = $null; Tier = $null }
    }
    $rProf = [string]$obj.review_profile; $rTier = [string]$obj.review_tier
    if ($null -eq $prof) { $prof = $rProf } elseif ($prof -cne $rProf) {
      return [pscustomobject]@{ Ok = $false; Error = 'signed review_profile disagree across receipts'; Items = @(); Profile = $null; Tier = $null }
    }
    if ($null -eq $tier) { $tier = $rTier } elseif ($tier -cne $rTier) {
      return [pscustomobject]@{ Ok = $false; Error = 'signed review_tier disagree across receipts'; Items = @(); Profile = $null; Tier = $null }
    }
    [void]$items.Add([pscustomobject]@{ Receipt = $obj; Content = [IO.File]::ReadAllText($rp); ResultPath = $rp; FileName = $f.Name })
  }
  return [pscustomobject]@{ Ok = $true; Error = $null; Items = @($items); Profile = $prof; Tier = $tier }
}

function Get-FleetVoiceAssessmentsFromReceipts {
  param([object[]]$Items)
  $rows = New-Object System.Collections.ArrayList
  foreach ($it in @($Items)) {
    $r = $it.Receipt; $req = [string]$r.requested_model; $mk = Get-VoiceModelKey $req
    $isSec = Test-SignedSecurityRole $r
    $secQualRole = ($isSec -and ($mk -in $script:OpenWeightKeys))
    $disp = [string]$r.voice_id; if ([string]::IsNullOrWhiteSpace($disp)) { $disp = [string]$r.lane_id }
    $name = $disp; if ($name -notmatch '\.') { $name = "$name.md" }
    $bytes = [int64]([Text.Encoding]::UTF8.GetByteCount([string]$it.Content))
    $reason = Test-FleetVoiceContent -Name $name -Text ([string]$it.Content) -Bytes $bytes -IsSecurityRole:([bool]$isSec)
    [void]$rows.Add([pscustomobject]@{
        Name = $name; Stem = [IO.Path]::GetFileNameWithoutExtension($name)
        Path = [string]$it.ResultPath; Qualified = ($null -eq $reason); Reason = $reason
        ModelKey = $mk; IsSecurityRole = [bool]$secQualRole
        ReviewRole = [string]$r.review_role; RequestedModel = $req
      })
  }
  return @($rows)
}

function Resolve-FleetReviewAuthority {
  param($Verified, [string]$LockedPlan, [bool]$HasLockedPlan, $CallerProfile, $CallerTier,
    [string]$DefaultProfile, [string]$DefaultTier)
  $prof = $DefaultProfile; $tier = $DefaultTier
  $signedProf = [string]$Verified.Profile; $signedTier = [string]$Verified.Tier
  if (-not [string]::IsNullOrWhiteSpace($signedProf)) {
    if ($signedProf -ne 'security-sensitive' -and $signedProf -ne 'general') {
      return [pscustomobject]@{ Ok = $false; Error = "unsupported signed review_profile: $signedProf"; Profile = $prof; Tier = $tier }
    }
    $prof = $signedProf
  }
  if (-not [string]::IsNullOrWhiteSpace($signedTier)) {
    if ($signedTier -notin @('MICRO', 'LIGHT', 'STANDARD', 'FULL')) {
      return [pscustomobject]@{ Ok = $false; Error = "unsupported signed review_tier: $signedTier"; Profile = $prof; Tier = $tier }
    }
    $tier = $signedTier
  }
  if ($null -ne $CallerProfile -and -not [string]::IsNullOrWhiteSpace($signedProf) -and ([string]$CallerProfile -ne $prof)) {
    return [pscustomobject]@{ Ok = $false; Error = "review_profile mismatch: signed=$prof caller=$CallerProfile"; Profile = $prof; Tier = $tier }
  }
  if ($null -ne $CallerTier -and -not [string]::IsNullOrWhiteSpace($signedTier) -and ([string]$CallerTier -ne $tier)) {
    return [pscustomobject]@{ Ok = $false; Error = "review_tier mismatch: signed=$tier caller=$CallerTier"; Profile = $prof; Tier = $tier }
  }
  if ($HasLockedPlan) {
    $planProf = Get-LockedPlanReviewProfile $LockedPlan
    if (-not $planProf.Ok) { return [pscustomobject]@{ Ok = $false; Error = [string]$planProf.Error; Profile = $prof; Tier = $tier } }
    if (-not [string]::IsNullOrWhiteSpace($signedProf)) {
      if ([string]$planProf.Profile -ne $prof) {
        return [pscustomobject]@{ Ok = $false; Error = "review_profile mismatch: locked-plan=$($planProf.Profile) signed=$prof"; Profile = $prof; Tier = $tier }
      }
    } else {
      $prof = [string]$planProf.Profile
      if ($null -ne $CallerProfile -and ([string]$CallerProfile -ne $prof)) {
        return [pscustomobject]@{ Ok = $false; Error = "review_profile mismatch: locked-plan=$prof caller=$CallerProfile"; Profile = $prof; Tier = $tier }
      }
    }
  } elseif (($null -ne $CallerProfile) -and [string]::IsNullOrWhiteSpace($signedProf) -and (@($Verified.Items).Count -eq 0)) {
    return [pscustomobject]@{ Ok = $false; Error = 'review_profile supplied without signed receipt or -LockedPlan authority (downgrade)'; Profile = $prof; Tier = $tier }
  }
  return [pscustomobject]@{ Ok = $true; Error = $null; Profile = $prof; Tier = $tier }
}
