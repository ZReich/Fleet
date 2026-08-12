# Canonical review-charter builder (Sol D1). Every review voice charter is built HERE so the
# verdict grammar block is byte-identical to what the parser enforces — never hand-assembled.
# Prints "charter: <lane_id> <sha256> <path>" and exits nonzero on any missing packet artifact.
[CmdletBinding()]
param(
  # Not [Mandatory]: psvalid invokes `-SelfTest` bare; the CLI path validates below.
  [string]$RunId = '',
  [string]$LaneId = '',
  [string]$Lens = '',
  [string]$PacketDir = '',
  [string]$OutPath = '',
  [string]$Tier = 'STANDARD',
  [string]$ReviewRisk = 'behavior',
  [string]$ExtraInstructions = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FleetReviewGrammar.Helpers.ps1')
$utf8 = New-Object System.Text.UTF8Encoding $false

function Read-PacketArtifact([string]$Dir, [string]$Name) {
  $p = Join-Path $Dir $Name
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "packet artifact missing: $p" }
  $t = [IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding $false))
  if ([string]::IsNullOrWhiteSpace($t)) { throw "packet artifact empty: $p" }
  return $t
}

function New-FleetReviewCharterText {
  param([string]$RunId, [string]$LaneId, [string]$Lens, [string]$Tier, [string]$ReviewRisk,
    [string]$Plan, [string]$Acceptance, [string]$Gates, [string]$Diff, [string]$Extra)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("FROZEN REVIEW - run $RunId, lane $LaneId, tier $Tier, review_risk $ReviewRisk.")
  [void]$sb.AppendLine('You are one blind voice on an adversarial review panel. Attack the diff below against the')
  [void]$sb.AppendLine('locked plan and evidence. Findings need file:line and a concrete fix. Free-form markdown body.')
  [void]$sb.AppendLine()
  [void]$sb.AppendLine('LENS: ' + $Lens)
  if (-not [string]::IsNullOrWhiteSpace($Extra)) { [void]$sb.AppendLine(); [void]$sb.AppendLine($Extra) }
  [void]$sb.AppendLine()
  [void]$sb.AppendLine((Get-FleetReviewGrammarBlock))
  [void]$sb.AppendLine()
  [void]$sb.AppendLine('===== LOCKED PLAN ====='); [void]$sb.AppendLine($Plan)
  [void]$sb.AppendLine('===== ACCEPTANCE EVIDENCE ====='); [void]$sb.AppendLine($Acceptance)
  [void]$sb.AppendLine('===== GATE EVIDENCE ====='); [void]$sb.AppendLine($Gates)
  [void]$sb.AppendLine('===== COMMITTED DIFF ====='); [void]$sb.AppendLine($Diff)
  return $sb.ToString()
}

if ($SelfTest) {
  $fail = 0
  function Check([string]$n, [bool]$ok) { if ($ok) { Write-Output "PASS $n" } else { Write-Output "FAIL $n"; $script:fail++ } }
  $tmp = Join-Path $env:TEMP ('charter-st-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    foreach ($f in @('locked-plan.md', 'acceptance-evidence.md', 'gate-evidence.md', 'final.diff')) {
      [IO.File]::WriteAllText((Join-Path $tmp $f), "content of $f", $utf8)
    }
    $out = Join-Path $tmp 'panel\v-x-charter.txt'
    $line = & $PSCommandPath -RunId 'r1' -LaneId 'v-x' -Lens 'test lens' -PacketDir $tmp -OutPath $out
    Check 'emits charter line' ($line -match '^charter: v-x [0-9a-f]{64} ')
    $txt = [IO.File]::ReadAllText($out, $utf8)
    Check 'grammar block byte-identical' ($txt.Contains((Get-FleetReviewGrammarBlock)))
    Check 'all sections present' ($txt.Contains('===== LOCKED PLAN =====') -and $txt.Contains('===== COMMITTED DIFF =====') -and $txt.Contains('LENS: test lens'))
    Remove-Item -LiteralPath (Join-Path $tmp 'final.diff') -Force
    $threw = $false
    try { $null = & $PSCommandPath -RunId 'r1' -LaneId 'v-y' -Lens 'l' -PacketDir $tmp 2>$null } catch { $threw = $true }
    Check 'missing artifact fails' ($threw -or $LASTEXITCODE -ne 0)
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -eq 0) { Write-Output 'Test-NewFleetReviewCharter: passed (4 checks)'; exit 0 }
  Write-Output "Test-NewFleetReviewCharter: FAILED ($fail)"; exit 1
}

foreach ($req in @(@('RunId', $RunId), @('LaneId', $LaneId), @('Lens', $Lens), @('PacketDir', $PacketDir))) {
  if ([string]::IsNullOrWhiteSpace([string]$req[1])) { throw "$($req[0]) is required" }
}
if ($LaneId -notmatch '^[A-Za-z0-9._-]+$') { throw "invalid LaneId: $LaneId" }
$PacketDir = [IO.Path]::GetFullPath($PacketDir)
$plan = Read-PacketArtifact $PacketDir 'locked-plan.md'
$acc = Read-PacketArtifact $PacketDir 'acceptance-evidence.md'
$gates = Read-PacketArtifact $PacketDir 'gate-evidence.md'
$diff = Read-PacketArtifact $PacketDir 'final.diff'
$text = New-FleetReviewCharterText -RunId $RunId -LaneId $LaneId -Lens $Lens -Tier $Tier -ReviewRisk $ReviewRisk `
  -Plan $plan -Acceptance $acc -Gates $gates -Diff $diff -Extra $ExtraInstructions
if ([string]::IsNullOrWhiteSpace($OutPath)) { $OutPath = Join-Path $PacketDir ('panel\review-charter-' + $LaneId + '.md') }
$parent = Split-Path -Parent $OutPath
if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
[IO.File]::WriteAllText($OutPath, $text, $utf8)
$sha = [Security.Cryptography.SHA256]::Create()
try {
  $hash = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($OutPath)) | ForEach-Object { $_.ToString('x2') })
} finally { $sha.Dispose() }
Write-Output ("charter: {0} {1} {2}" -f $LaneId, $hash, $OutPath)
exit 0
