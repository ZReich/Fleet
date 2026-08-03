# Fixture tests for Assert-FleetAdversarialReview.ps1 (adversarial-review receipt gate).
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Assert-FleetAdversarialReview.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('fleet-adv-review-test-' + [guid]::NewGuid().ToString('N'))
$passed = 0; $failed = 0; $skipped = 0
$utf8 = New-Object Text.UTF8Encoding $false
$pad = ('evidence detail line for substantive review body. ' * 6)

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function New-Repo([string]$Name) {
  $repo = Join-Path $root $Name
  New-Item -ItemType Directory -Force -Path $repo | Out-Null
  & git -C $repo init -q | Out-Null
  & git -C $repo -c user.email=fleet-test@example.invalid -c user.name=fleet-test commit --allow-empty -q -m seed | Out-Null
  return $repo
}
function Add-Commit([string]$Repo, [string]$RelPath, [string]$Content, [string]$Message) {
  $full = Join-Path $Repo $RelPath
  $parent = Split-Path -Parent $full
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($full, $Content, $utf8)
  & git -C $Repo add -- $RelPath | Out-Null
  & git -C $Repo -c user.email=fleet-test@example.invalid -c user.name=fleet-test commit -q -m $Message | Out-Null
}
function Quote-GitArg([string]$Value) {
  if ($null -eq $Value) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  return '"' + ($Value.Replace('"', '\"')) + '"'
}
function Write-GitDiffFile([string]$Repo, [string]$BaseRef, [string]$OutFile) {
  $argLine = '-C ' + (Quote-GitArg $Repo) + ' --no-pager diff ' + (Quote-GitArg $BaseRef) + ' HEAD'
  $proc = New-Object System.Diagnostics.Process
  $psi = $proc.StartInfo
  $psi.FileName = 'git'; $psi.Arguments = $argLine
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  [void]$proc.Start()
  $ms = New-Object System.IO.MemoryStream
  try {
    $proc.StandardOutput.BaseStream.CopyTo($ms)
    $err = $proc.StandardError.ReadToEnd(); $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "git diff failed: $err" }
    [IO.File]::WriteAllBytes($OutFile, $ms.ToArray())
  }
  finally { $ms.Dispose(); $proc.Dispose() }
}
function Get-MdVoice([string]$Sev = 'HIGH') { return "## Adversarial review`n### Findings`n- scripts/x.ps1:10 $Sev - problem found. Fix required.`n$pad`n" }
function Get-NoFindingsVoice { return "## Adversarial review`n### Findings`nnone material - no findings after full pass.`n$pad`n" }
function Get-JsonVoice { return (@{ status = 'ok'; response = "Review complete. HIGH: edge case checked. $pad" } | ConvertTo-Json -Compress) }
function Write-Manifest([string]$ReviewDir, [string]$FinalPath, [string]$Body = $null) {
  if ($Body) { [IO.File]::WriteAllText((Join-Path $ReviewDir 'packet-manifest.json'), $Body, $utf8); return }
  $bytes = [IO.File]::ReadAllBytes($FinalPath)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $hex = -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
  $obj = [ordered]@{ schema_version = '1'; review_risk = 'mechanical'; packet_sha256 = ('a' * 64); artifacts = @(@{ name = 'final.diff'; bytes = [int64]$bytes.Length; sha256 = $hex }) }
  [IO.File]::WriteAllText((Join-Path $ReviewDir 'packet-manifest.json'), ($obj | ConvertTo-Json -Compress -Depth 5), $utf8)
}
function Write-ReviewPacket {
  param([string]$Repo, [string]$BaseRef, [string]$ReviewDir, [string[]]$VoiceBodies, [int]$EmptyVoiceCount = 0, [string]$FrozenDiffPath = $null, [string]$ManifestBody = $null, [string[]]$VoiceNames = $null)
  if (-not (Test-Path -LiteralPath $ReviewDir)) { New-Item -ItemType Directory -Force -Path $ReviewDir | Out-Null }
  $finalPath = Join-Path $ReviewDir 'final.diff'
  if ($FrozenDiffPath -and (Test-Path -LiteralPath $FrozenDiffPath)) { Copy-Item -LiteralPath $FrozenDiffPath -Destination $finalPath -Force }
  else { Write-GitDiffFile $Repo $BaseRef $finalPath }
  Write-Manifest $ReviewDir $finalPath $ManifestBody
  $i = 0
  foreach ($body in @($VoiceBodies)) {
    $i++; $name = if ($VoiceNames -and $VoiceNames.Count -ge $i) { $VoiceNames[$i - 1] } else { "v-$i.md" }
    $dest = Join-Path $ReviewDir $name; $parent = Split-Path -Parent $dest
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($dest, $body, $utf8)
  }
  for ($e = 0; $e -lt $EmptyVoiceCount; $e++) { $i++; [IO.File]::WriteAllBytes((Join-Path $ReviewDir ("v-$i.md")), [byte[]]@()) }
}
function Invoke-Gate {
  param([string]$Repo, [string]$BaseRef, [string]$ReviewDir = $null, [string]$Tier = 'STANDARD', [string]$Mode = 'text', [string[]]$PathFilter = @())
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Repo', $Repo, '-BaseRef', $BaseRef, '-Tier', $Tier, '-Mode', $Mode)
  if ($ReviewDir) { $args += @('-ReviewDir', $ReviewDir) }
  if ($PathFilter -and @($PathFilter).Count -gt 0) { $args += '-PathFilter'; $args += $PathFilter }
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @args 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
  return [pscustomobject]@{ ExitCode = $code; Raw = (($raw | ForEach-Object { "$_" }) -join "`n") }
}
function New-Ship([string]$Name, [string]$File = 'f.txt', [string]$Body = "x`n") {
  $repo = New-Repo $Name; $base = (& git -C $repo rev-parse HEAD).Trim(); Add-Commit $repo $File $Body 'ship'
  return [pscustomobject]@{ Repo = $repo; Base = $base; ReviewDir = (Join-Path $repo '.fleet-review') }
}

try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $md3 = @((Get-MdVoice 'HIGH'), (Get-MdVoice 'MEDIUM'), (Get-MdVoice 'LOW'))
  $sum3 = 'voices: 3 qualified / 3 candidates / 3 required'
  $bs = [string][char]92

  Case 'NEGATIVE: shipped diff, no review dir -> exit 1' {
    $s = New-Ship 'no-review-dir' 'shipped.txt' "hello`n"
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'no review happened|ReviewDir missing|missing' -and $run.Raw -match 'verdict: FAILED') "no-dir: $($run.Raw)"
  }
  Case 'NEGATIVE: receipts for older commit -> exit 1, predates' {
    $repo = New-Repo 'stale-packet'; $base = (& git -C $repo rev-parse HEAD).Trim()
    Add-Commit $repo 'a.txt' "one`n" 'first'; $rd = Join-Path $repo '.fleet-review'
    Write-ReviewPacket -Repo $repo -BaseRef $base -ReviewDir $rd -VoiceBodies $md3
    Add-Commit $repo 'b.txt' "two`n" 'second'
    $run = Invoke-Gate -Repo $repo -BaseRef $base -ReviewDir $rd -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'predate' -and $run.Raw -match 'packet: MISMATCH') "stale: $($run.Raw)"
  }
  Case 'NEGATIVE: packet matches, only 2 voices at FULL -> exit 1' {
    $s = New-Ship 'full-two-voices' 'x.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @((Get-MdVoice 'HIGH'), (Get-MdVoice 'LOW'))
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL'
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'voices: 2 qualified / 2 candidates / 5 required' -and $run.Raw -match 'verdict: FAILED') "full2: $($run.Raw)"
  }
  Case 'NEGATIVE: 5 voice files, three 0-byte -> count 2, exit 1' {
    $s = New-Ship 'empty-voices' 'y.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @((Get-MdVoice 'HIGH'), (Get-MdVoice 'MEDIUM')) -EmptyVoiceCount 3
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL'
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'voices: 2 qualified / 5 candidates / 5 required') "empty: $($run.Raw)"
  }
  Case 'POSITIVE: packet matches and tier voice count met -> exit 0' {
    $s = New-Ship 'happy-path' 'z.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies $md3
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'packet: match' -and $run.Raw -match 'verdict: ok' -and $run.Raw -match [regex]::Escape($sum3)) "happy: $($run.Raw)"
  }
  Case 'NEGATIVE: FULL with grok fan-out but only 3 models -> exit 1' {
    # {opus, glm, grok×3} is 5 files but 3 models; the fan-out must not let a panel
    # missing Sol and Terra pass "5 required".
    $s = New-Ship 'grok-fanout-thin' 'gf1.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir `
      -VoiceBodies @($md3[0], $md3[1], $md3[2], (Get-MdVoice 'HIGH'), (Get-MdVoice 'LOW')) `
      -VoiceNames @('v-opus5.md', 'v-glm.md', 'v-grok-spec.md', 'v-grok-correctness.md', 'v-grok-regression.md')
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL'
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'voices: 3 qualified / 5 candidates / 5 required' -and $run.Raw -match 'verdict: FAILED') "fanout-thin: $($run.Raw)"
  }
  Case 'POSITIVE: FULL with grok fan-out and 5 distinct models -> exit 0' {
    # sol+terra+opus+glm + grok×3 = 7 files, 5 models. Grok collapses to one voice; the
    # panel still meets 5 required.
    $s = New-Ship 'grok-fanout-full' 'gf2.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir `
      -VoiceBodies @($md3[0], $md3[1], $md3[2], (Get-MdVoice 'HIGH'), (Get-MdVoice 'MEDIUM'), (Get-MdVoice 'LOW'), (Get-MdVoice 'HIGH')) `
      -VoiceNames @('v-sol.md', 'v-terra.md', 'v-opus5.md', 'v-glm.md', 'v-grok-spec.md', 'v-grok-correctness.md', 'v-grok-regression.md')
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL'
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'voices: 5 qualified / 7 candidates / 5 required' -and $run.Raw -match 'verdict: ok') "fanout-full: $($run.Raw)"
  }
  Case 'POSITIVE: empty diff -> exit 0, nothing to review' {
    $repo = New-Repo 'empty-diff'; $base = (& git -C $repo rev-parse HEAD).Trim()
    $run = Invoke-Gate -Repo $repo -BaseRef $base -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'nothing to review') "empty: $($run.Raw)"
  }
  Case 'POSITIVE: MICRO tier 0 voices -> exit 0, not required' {
    $s = New-Ship 'micro-zero' 'm.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @()
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'MICRO'
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'not required|voices were not required' -and $run.Raw -match 'verdict: ok') "micro: $($run.Raw)"
  }
  Case 'json mode parses, same fields and exit code' {
    $s = New-Ship 'json-mode' 'j.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies $md3
    $ok = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD' -Mode 'json'
    Assert-True ($ok.ExitCode -eq 0) "json exit: $($ok.Raw)"
    $obj = $ok.Raw | ConvertFrom-Json
    Assert-True ($obj.tier -eq 'STANDARD' -and $obj.voices -eq 3 -and $obj.voices_required -eq 3 -and $obj.voices_qualified -eq 3 -and $obj.voices_candidates -eq 3) 'voice fields'
    Assert-True ($obj.packet -eq 'match' -and $obj.verdict -eq 'ok' -and @($obj.voice_files).Count -eq 3) 'packet/files'
    $bad = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir (Join-Path $s.Repo 'no-such-review') -Tier 'STANDARD' -Mode 'json'
    $badObj = $bad.Raw | ConvertFrom-Json
    Assert-True ($bad.ExitCode -eq 1 -and $badObj.packet -eq 'missing' -and $badObj.verdict -eq 'FAILED') 'missing fields'
  }
  Case 'NEGATIVE: incident manifest {} + three x files -> FAILED' {
    $s = New-Ship 'incident-x' 'i.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @('x', 'x', 'x') -ManifestBody '{}'
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'verdict: FAILED' -and $run.Raw -match 'packet: missing|manifest invalid|missing field') "incident: $($run.Raw)"
  }
  Case 'NEGATIVE: valid manifest, three x files -> voices unqualified' {
    $s = New-Ship 'x-voices' 'xonly.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @('x', 'x', 'x')
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'voices: 0 qualified / 3 candidates / 3 required' -and $run.Raw -match 'packet: match') "x: $($run.Raw)"
    $jo = (Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD' -Mode 'json').Raw | ConvertFrom-Json
    Assert-True ($jo.verdict -eq 'FAILED' -and $jo.voices_qualified -eq 0 -and @($jo.voices_detail | Where-Object { -not $_.qualified -and $_.reason }).Count -ge 3) 'reasons'
  }
  Case 'NEGATIVE: manifest missing artifacts[] -> FAILED' {
    $s = New-Ship 'no-artifacts' 'na.txt'
    $badMan = '{"schema_version":"1","packet_sha256":"' + ('b' * 64) + '","review_risk":"mechanical"}'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies $md3 -ManifestBody $badMan
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'artifacts|manifest invalid|missing field' -and $run.Raw -match 'verdict: FAILED') "arts: $($run.Raw)"
  }
  Case 'NEGATIVE: same review stem under three paths -> fewer distinct' {
    $s = New-Ship 'dup-stem' 'd.txt'; $body = Get-MdVoice 'HIGH'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @($body, $body, $body) -VoiceNames @(("a{0}v-1.md" -f $bs), ("b{0}v-1.md" -f $bs), ("c{0}v-1.md" -f $bs))
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'voices: 1 qualified / 3 candidates / 3 required') "stem: $($run.Raw)"
  }
  Case 'POSITIVE: three substantive markdown severity reviews -> ok' {
    $s = New-Ship 'md-sev' 's.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies $md3
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match [regex]::Escape($sum3)) "md: $($run.Raw)"
  }
  Case 'POSITIVE: markdown no-findings statement qualifies' {
    $s = New-Ship 'no-find' 'nf.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @((Get-NoFindingsVoice), (Get-MdVoice 'HIGH'), (Get-MdVoice 'LOW'))
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match [regex]::Escape($sum3)) "nf: $($run.Raw)"
  }
  Case 'POSITIVE: wrapper result JSON qualifies' {
    $s = New-Ship 'json-voice' 'jv.txt'
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @((Get-JsonVoice), (Get-MdVoice 'HIGH'), (Get-MdVoice 'MEDIUM')) -VoiceNames @('lane-result.json', 'v-2.md', 'v-3.md')
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD'
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match [regex]::Escape($sum3)) "jv: $($run.Raw)"
  }
}
finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
$total = $passed + $failed + $skipped
Write-Host ""
Write-Host "DENOMINATOR: cases run=$total passed=$passed failed=$failed skipped=$skipped"
if ($total -eq 0) { Write-Host "FAIL: suite collected 0 cases"; exit 1 }
if ($failed -gt 0) { exit 1 }
exit 0
