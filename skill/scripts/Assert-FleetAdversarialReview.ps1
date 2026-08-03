# Gate: Fleet run needs a real adversarial-review receipt covering shipped diff.
# Summary: review: <tier> | voices: N qualified / M candidates / R required | packet: <state> | verdict: ok|FAILED
param(
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$BaseRef,
  [string]$ReviewDir,
  [ValidateSet('MICRO', 'LIGHT', 'STANDARD', 'FULL')][string]$Tier = 'STANDARD',
  [string[]]$PathFilter = @(),
  [ValidateSet('text', 'json')][string]$Mode = 'text'
)
$ErrorActionPreference = 'Stop'
$MinVoiceBytes = 200
$SuccessStatuses = @('ok', 'needs_gate_validation', 'done', 'passed')

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

# A voice is one MODEL, not one file. Grok fans out to three diverse-lens lanes at FULL
# (Spec/Correctness/Regression, review-protocol.md charter 5) and must count as ONE voice -
# three same-family files passing as three voices is the same-family dominance the bias
# controls forbid, and it would let a panel of {opus, glm, grok×3} satisfy "5 required"
# while missing Sol and Terra entirely. Files whose stem carries a known model token
# collapse onto that token; anything else keys on its own stem, so generic lane files
# (v-1, lane-result) stay distinct exactly as before.
$script:KnownModelTokens = @('sol', 'terra', 'opus', 'glm', 'grok', 'kimi', 'gemini', 'spark')
function Get-VoiceModelKey([string]$Stem) {
  $lower = $Stem.ToLowerInvariant()
  foreach ($tok in $script:KnownModelTokens) {
    if ($lower -match ('(^|[^a-z])' + [regex]::Escape($tok) + '([^a-z]|$)')) { return $tok }
  }
  return $lower
}

function Quote-GitArg([string]$Value) {
  if ($null -eq $Value) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  return '"' + ($Value.Replace('"', '\"')) + '"'
}

function Get-ShippedDiffBytes {
  param([string]$RepoPath, [string]$Base, [string[]]$Paths)
  $parts = New-Object System.Collections.ArrayList
  [void]$parts.Add('-C'); [void]$parts.Add((Quote-GitArg $RepoPath))
  [void]$parts.Add('--no-pager'); [void]$parts.Add('diff')
  [void]$parts.Add((Quote-GitArg $Base)); [void]$parts.Add('HEAD')
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

function Find-PacketManifest([string]$Dir) {
  $direct = Join-Path $Dir 'packet-manifest.json'
  if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
  $found = @(Get-ChildItem -LiteralPath $Dir -Filter 'packet-manifest.json' -File -Recurse -ErrorAction SilentlyContinue)
  if ($found.Count -gt 0) { return $found[0].FullName }
  return $null
}

function Find-FinalDiff([string]$Dir, [string]$ManifestPath) {
  $direct = Join-Path $Dir 'final.diff'
  if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
  if ($ManifestPath) {
    $beside = Join-Path (Split-Path -Parent $ManifestPath) 'final.diff'
    if (Test-Path -LiteralPath $beside -PathType Leaf) { return $beside }
  }
  $found = @(Get-ChildItem -LiteralPath $Dir -Filter 'final.diff' -File -Recurse -ErrorAction SilentlyContinue)
  if ($found.Count -gt 0) { return $found[0].FullName }
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

function Test-VoiceContent([string]$Name, [string]$Text, [int64]$Bytes) {
  if ($Bytes -lt $MinVoiceBytes) { return "too small ($Bytes < $MinVoiceBytes bytes)" }
  if ([string]::IsNullOrWhiteSpace($Text)) { return 'blank body' }
  $isJson = ($Name -like '*-review*.json' -or $Name -like '*-result.json')
  if ($isJson) {
    try { $obj = $Text | ConvertFrom-Json -ErrorAction Stop }
    catch { return 'json unparseable' }
    if ($null -eq $obj) { return 'json null' }
    $st = $null
    if ($obj.PSObject.Properties['status']) { $st = [string]$obj.status }
    if ([string]::IsNullOrWhiteSpace($st) -or ($st -notin $SuccessStatuses)) {
      return "json status not success (got '$st')"
    }
    $body = ''
    if ($obj.PSObject.Properties['response']) { $body = [string]$obj.response }
    if ([string]::IsNullOrWhiteSpace($body) -and $obj.PSObject.Properties['verdict']) {
      $body = [string]$obj.verdict
    }
    if ([string]::IsNullOrWhiteSpace($body)) { return 'json missing nonempty response/verdict' }
    return $null
  }
  # markdown voice
  if ($Text -match '(?i)\b(CRITICAL|HIGH|MEDIUM|LOW)\b') { return $null }
  if ($Text -match '(?i)\b(no findings|none material|zero findings|no material findings)\b') { return $null }
  return 'markdown lacks severity token or no-findings statement'
}

function Get-VoiceAssessments([string]$Dir) {
  $rows = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)) {
    $name = $f.Name
    if ($name -eq 'packet-manifest.json' -or $name -eq 'final.diff') { continue }
    $isVoice = ($name -like 'v-*.md' -or $name -like '*-review*.json' -or $name -like '*-result.json')
    if (-not $isVoice) { continue }
    $text = ''
    if ($f.Length -gt 0) { $text = [IO.File]::ReadAllText($f.FullName) }
    $reason = Test-VoiceContent -Name $name -Text $text -Bytes $f.Length
    $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    [void]$rows.Add([pscustomobject]@{
        Name = $name; Stem = $stem; Path = $f.FullName
        Qualified = ($null -eq $reason); Reason = $reason
      })
  }
  return @($rows)
}

function Format-Summary([string]$T, [int]$Q, [int]$C, [int]$R, [string]$P, [string]$V) {
  return "review: $T | voices: $Q qualified / $C candidates / $R required | packet: $P | verdict: $V"
}

function Write-Result {
  param(
    [string]$Summary, [string]$Verdict, [string]$Packet, [int]$Qualified, [int]$Candidates,
    [int]$Required, [object[]]$VoiceRows, [string]$Message = $null, [string]$VoicesNote = $null
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

# --- main ---
$resolvedRepo = (Resolve-Path -LiteralPath $Repo).Path
if ([string]::IsNullOrWhiteSpace($ReviewDir)) {
  $ReviewDir = Join-Path $resolvedRepo '.fleet-review'
}

$required = Get-RequiredVoiceCount $Tier
$shippedBytes = Get-ShippedDiffBytes -RepoPath $resolvedRepo -Base $BaseRef -Paths $PathFilter

if ($null -eq $shippedBytes -or $shippedBytes.Length -eq 0) {
  $summary = Format-Summary $Tier 0 0 $required 'match' 'ok'
  $msg = "nothing to review (empty shipped diff vs $BaseRef)"
  $note = $null; if ($Tier -eq 'MICRO') { $note = 'voices were not required' }
  Write-Result -Summary $summary -Verdict 'ok' -Packet 'match' -Qualified 0 -Candidates 0 `
    -Required $required -VoiceRows @() -Message $msg -VoicesNote $note
  exit 0
}

if (-not (Test-Path -LiteralPath $ReviewDir -PathType Container)) {
  $summary = Format-Summary $Tier 0 0 $required 'missing' 'FAILED'
  $msg = "no review happened: ReviewDir missing: $ReviewDir"
  Write-Result -Summary $summary -Verdict 'FAILED' -Packet 'missing' -Qualified 0 -Candidates 0 `
    -Required $required -VoiceRows @() -Message $msg
  exit 1
}

$manifestPath = Find-PacketManifest $ReviewDir
$finalDiffPath = Find-FinalDiff $ReviewDir $manifestPath
$packetStatus = 'missing'
$packetMsg = $null

if (-not $manifestPath -or -not $finalDiffPath) {
  $packetStatus = 'missing'
  $packetMsg = "review packet incomplete under $ReviewDir (need packet-manifest.json and final.diff)"
}
else {
  $shapeErr = Test-ManifestShape $manifestPath
  if ($shapeErr) {
    $packetStatus = 'missing'
    $packetMsg = "review packet manifest invalid: $shapeErr"
  }
  else {
    $frozenBytes = [IO.File]::ReadAllBytes($finalDiffPath)
    $shippedHash = Get-Sha256Hex $shippedBytes
    $frozenHash = Get-Sha256Hex $frozenBytes
    if ($shippedHash -eq $frozenHash) { $packetStatus = 'match' }
    else {
      $packetStatus = 'MISMATCH'
      $packetMsg = "review predates the shipped changes: frozen final.diff SHA-256 does not match shipped diff vs $BaseRef"
    }
  }
}

$voiceRows = @(Get-VoiceAssessments $ReviewDir)
$candidates = $voiceRows.Count
# Count DISTINCT MODELS among qualified voices, not distinct files: Grok's three fan-out
# lanes share the `grok` key and collapse to one voice here (see Get-VoiceModelKey).
$qualifiedModels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($row in $voiceRows) {
  if ($row.Qualified) { [void]$qualifiedModels.Add((Get-VoiceModelKey $row.Stem)) }
}
$voiceCount = $qualifiedModels.Count
$voicesOk = ($voiceCount -ge $required)
if ($Tier -eq 'MICRO' -and $required -eq 0) { $voicesOk = $true }

$verdict = 'FAILED'
if ($packetStatus -eq 'match' -and $voicesOk) { $verdict = 'ok' }

$summary = Format-Summary $Tier $voiceCount $candidates $required $packetStatus $verdict
$note = $null
if ($Tier -eq 'MICRO' -and $required -eq 0) { $note = 'voices were not required' }
Write-Result -Summary $summary -Verdict $verdict -Packet $packetStatus -Qualified $voiceCount `
  -Candidates $candidates -Required $required -VoiceRows $voiceRows -Message $packetMsg -VoicesNote $note

if ($verdict -eq 'ok') { exit 0 }
exit 1
