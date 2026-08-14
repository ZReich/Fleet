# Fixture tests for Assert-FleetAdversarialReview.ps1 (signed receipt identity).
# Signs fixtures under a test lease key. Prints selftest: PASS k/k.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Assert-FleetAdversarialReview.ps1'
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetSignedTest.Helpers.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('fleet-adv-review-test-' + [guid]::NewGuid().ToString('N'))
$leaseHome = Join-Path $root 'home'; $script:LeaseHome = $leaseHome
$passed = 0; $failed = 0; $skipped = 0
$utf8 = $script:FstUtf8; $pad = ('evidence detail line for substantive review body. ' * 6)
$script:RunSeq = 0; $script:FixedSha = ('a' * 64); $script:LeaseFields = $script:FstRlFields; $script:BoundPlanSha = ''
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw "ASSERTION FAILED: $m" } }
function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" } catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Get-BareHighVoice { return ("HIGH`n" + $pad) }
function EmptyManJson { return '{"schema_version":"1","packet_sha256":"' + $script:FixedSha + '","review_risk":"m","artifacts":[{"name":"x","bytes":0,"sha256":"' + $script:FixedSha + '"}]}' }
try {
  New-Item -ItemType Directory -Force -Path $root, $leaseHome | Out-Null
  $md3 = @((Get-MdVoice 'HIGH'), (Get-MdVoice 'MEDIUM'), (Get-MdVoice 'LOW'))
  $sum3 = 'voices: 3 qualified / 3 candidates / 3 required'; $bs = [string][char]92
  $n3 = @('v-sol.md','v-terra.md','v-opus.md')
  Case 'NEGATIVE: shipped diff, no review dir -> exit 1' {
    $s = New-Ship 'no-review-dir' 'shipped.txt' "hello`n"; New-Item -ItemType Directory -Force -Path $s.ReceiptDir | Out-Null
    $man = Join-Path $s.Repo 'missing-man.json'; [IO.File]::WriteAllText($man, '{}', $utf8)
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -Tier 'STANDARD' -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest $man -LockedPlan $s.LockedPlan
    Assert-True ($run.ExitCode -eq 1) "no-dir: $($run.Raw)"
  }
  Case 'NEGATIVE: receipts for older commit -> exit 1, predates' {
    $repo = New-Repo 'stale-packet'; $base = (& git -C $repo rev-parse HEAD).Trim(); Add-Commit $repo 'a.txt' "one`n" 'first'
    $rd = Join-Path $repo '.fleet-review'; $rc = Join-Path $repo '.fleet-receipts'
    Write-LockedPlan -Path (Join-Path $repo 'locked-plan.md') -Profile 'general'; $lease = New-TestLease
    $paths = Write-ReviewPacket -Repo $repo -BaseRef $base -ReviewDir $rd -VoiceBodies $md3
    Write-ReceiptsForVoices -ReceiptDir $rc -Lease $lease -VoicePaths $paths -Profile 'general' -Tier 'STANDARD'; Add-Commit $repo 'b.txt' "two`n" 'second'
    $run = Ig $repo $base $rd 'STANDARD' $lease.RunId $rc
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'predate' -and $run.Raw -match 'packet: MISMATCH') "stale: $($run.Raw)"
  }
  Case 'NEGATIVE: packet matches, only 2 voices at FULL -> exit 1' {
    $s = New-Ship 'full-two-voices' 'x.txt'; Finish-Ship $s @((Get-MdVoice 'HIGH'), (Get-MdVoice 'LOW')) -Tier 'FULL' | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'voices: 2 qualified / 2 candidates / 5 required') "full2: $($run.Raw)"
  }
  Case 'NEGATIVE: 5 voice files, three 0-byte -> count 2, exit 1' {
    $s = New-Ship 'empty-voices' 'y.txt'
    $paths = Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @((Get-MdVoice 'HIGH'), (Get-MdVoice 'MEDIUM')) -EmptyVoiceCount 3
    Write-ReceiptsForVoices -ReceiptDir $s.ReceiptDir -Lease $s.Lease -VoicePaths $paths -Tier 'FULL'
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir).Raw -match 'voices: 2 qualified / 5 candidates / 5 required') 'empty-voices'
  }
  Case 'POSITIVE: packet matches and tier voice count met -> exit 0' {
    $s = New-Ship 'happy-path' 'z.txt'; Finish-Ship $s $md3 -Names $n3 | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'packet: match' -and $run.Raw -match [regex]::Escape($sum3)) "happy: $($run.Raw)"
  }
  Case 'NEGATIVE: FULL with grok fan-out but only 3 models -> exit 1' {
    $s = New-Ship 'grok-fanout-thin' 'gf1.txt'
    Finish-Ship $s @($md3[0], $md3[1], $md3[2], (Get-MdVoice 'HIGH'), (Get-MdVoice 'LOW')) -Names @('v-opus5.md','v-glm.md','v-grok-spec.md','v-grok-correctness.md','v-grok-regression.md') -Tier 'FULL' | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'voices: 3 qualified / 5 candidates / 5 required') "fanout-thin: $($run.Raw)"
  }
  Case 'POSITIVE: FULL with grok fan-out and 5 distinct models -> exit 0' {
    $s = New-Ship 'grok-fanout-full' 'gf2.txt'
    Finish-Ship $s @($md3[0], $md3[1], $md3[2], (Get-MdVoice 'HIGH'), (Get-MdVoice 'MEDIUM'), (Get-MdVoice 'LOW'), (Get-MdVoice 'HIGH')) -Names @('v-sol.md','v-terra.md','v-opus5.md','v-glm.md','v-grok-spec.md','v-grok-correctness.md','v-grok-regression.md') -Tier 'FULL' | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'voices: 5 qualified / 7 candidates / 5 required') "fanout-full: $($run.Raw)"
  }
  Case 'NEGATIVE: empty diff non-MICRO -> FAILED (L1 zero-telemetry)' {
    $repo = New-Repo 'empty-diff'; $base = (& git -C $repo rev-parse HEAD).Trim(); $lease = New-TestLease
    $rc = Join-Path $repo '.fleet-receipts'; New-Item -ItemType Directory -Force -Path $rc | Out-Null
    $man = Join-Path $repo 'pm.json'; [IO.File]::WriteAllText($man, (EmptyManJson), $utf8)
    $run = Invoke-Gate -Repo $repo -BaseRef $base -Tier 'STANDARD' -RunId $lease.RunId -ReceiptDir $rc -PacketManifest $man -OmitLockedPlan
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'empty shipped diff|BaseRef resolves to HEAD|zero-telemetry|verdict: FAILED') "empty-std: $($run.Raw)"
  }
  Case 'POSITIVE: empty diff MICRO -> exit 0, nothing to review' {
    $repo = New-Repo 'empty-micro'; $base = (& git -C $repo rev-parse HEAD).Trim(); $lease = New-TestLease
    $rc = Join-Path $repo '.fleet-receipts'; New-Item -ItemType Directory -Force -Path $rc | Out-Null
    $man = Join-Path $repo 'pm.json'; [IO.File]::WriteAllText($man, (EmptyManJson), $utf8)
    $run = Invoke-Gate -Repo $repo -BaseRef $base -Tier 'MICRO' -RunId $lease.RunId -ReceiptDir $rc -PacketManifest $man -OmitLockedPlan
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'nothing to review|not required') "empty-micro: $($run.Raw)"
  }
  Case 'NEGATIVE: empty diff security-sensitive -> FAILED' {
    $repo = New-Repo 'empty-sec'; $base = (& git -C $repo rev-parse HEAD).Trim(); $lease = New-TestLease
    $rc = Join-Path $repo '.fleet-receipts'; New-Item -ItemType Directory -Force -Path $rc | Out-Null
    $man = Join-Path $repo 'pm.json'; [IO.File]::WriteAllText($man, (EmptyManJson), $utf8)
    $lp = Join-Path $repo 'locked-plan.md'; Write-LockedPlan -Path $lp -Profile 'security-sensitive'
    $run = Invoke-Gate -Repo $repo -BaseRef $base -Tier 'FULL' -ReviewProfile 'security-sensitive' -LockedPlan $lp -RunId $lease.RunId -ReceiptDir $rc -PacketManifest $man
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'empty shipped|security-sensitive|verdict: FAILED') "empty-sec: $($run.Raw)"
  }
  Case 'POSITIVE: MICRO tier 0 voices -> exit 0, not required' {
    $s = New-Ship 'micro-zero' 'm.txt'; Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @() | Out-Null
    New-Item -ItemType Directory -Force -Path $s.ReceiptDir | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'MICRO' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'not required|voices were not required') "micro: $($run.Raw)"
  }
  Case 'json mode parses, same fields and exit code' {
    $s = New-Ship 'json-mode' 'j.txt'; Finish-Ship $s $md3 -Names $n3 | Out-Null
    $ok = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD' -Mode 'json' -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest (Join-Path $s.ReviewDir 'packet-manifest.json')
    $obj = $ok.Raw | ConvertFrom-Json
    Assert-True ($ok.ExitCode -eq 0 -and $obj.tier -eq 'STANDARD' -and $obj.voices -eq 3 -and $obj.packet -eq 'match') "json: $($ok.Raw)"
  }
  Case 'PathFilter is rejected for committed coverage' {
    $s = New-Ship 'path-filter' 'pf.txt'; Finish-Ship $s $md3 -Names $n3 | Out-Null
    $blocked = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'STANDARD' -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest (Join-Path $s.ReviewDir 'packet-manifest.json') -PathFilter @('pf.txt')
    Assert-True ($blocked.ExitCode -ne 0 -and $blocked.Raw -match 'PathFilter is not supported') "path-filter: $($blocked.Raw)"
  }
  Case 'NEGATIVE: incident manifest {} + three x files -> FAILED' {
    $s = New-Ship 'incident-x' 'i.txt'
    $paths = Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @('x','x','x') -ManifestBody '{}' -VoiceNames $n3
    Write-ReceiptsForVoices -ReceiptDir $s.ReceiptDir -Lease $s.Lease -VoicePaths $paths
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir).ExitCode -eq 1) 'incident-x'
  }
  Case 'NEGATIVE: valid manifest, three x files -> voices unqualified' {
    $s = New-Ship 'x-voices' 'xonly.txt'
    $paths = Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @('x','x','x') -VoiceNames $n3
    Write-ReceiptsForVoices -ReceiptDir $s.ReceiptDir -Lease $s.Lease -VoicePaths $paths
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'voices: 0 qualified / 3 candidates / 3 required') "x: $($run.Raw)"
  }
  Case 'NEGATIVE: manifest missing artifacts[] -> FAILED' {
    $s = New-Ship 'no-artifacts' 'na.txt'
    $badMan = '{"schema_version":"1","packet_sha256":"' + ('b' * 64) + '","review_risk":"mechanical"}'
    $paths = Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies $md3 -ManifestBody $badMan -VoiceNames $n3
    Write-ReceiptsForVoices -ReceiptDir $s.ReceiptDir -Lease $s.Lease -VoicePaths $paths
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir).ExitCode -eq 1) 'no-arts'
  }
  Case 'NEGATIVE: same review stem under three paths -> fewer distinct' {
    $s = New-Ship 'dup-stem' 'd.txt'; $body = Get-MdVoice 'HIGH'
    $paths = Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies @($body,$body,$body) -VoiceNames @(("a{0}v-1.md" -f $bs),("b{0}v-1.md" -f $bs),("c{0}v-1.md" -f $bs))
    Write-ReceiptsForVoices -ReceiptDir $s.ReceiptDir -Lease $s.Lease -VoicePaths $paths -ModelOverride @{ 'v-1.md' = 'sol' }
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.Raw -match 'voices: 1 qualified / 3 candidates / 3 required') "dup-stem: $($run.Raw)"
  }
  Case 'POSITIVE: three substantive markdown severity reviews -> ok' {
    $s = New-Ship 'md-sev' 's.txt'; Finish-Ship $s $md3 -Names $n3 | Out-Null; Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir).ExitCode -eq 0) 'md-sev'
  }
  Case 'POSITIVE: markdown no-findings statement qualifies' {
    $s = New-Ship 'no-find' 'nf.txt'; Finish-Ship $s @((Get-NoFindingsVoice),(Get-MdVoice 'HIGH'),(Get-MdVoice 'LOW')) -Names $n3 | Out-Null; Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir).ExitCode -eq 0) 'no-find'
  }
  Case 'POSITIVE: wrapper result JSON qualifies' {
    $s = New-Ship 'json-voice' 'jv.txt'
    Finish-Ship $s @((Get-JsonVoice),(Get-MdVoice 'HIGH'),(Get-MdVoice 'MEDIUM')) -Names @('lane-result.json','v-2.md','v-3.md') -ModelOverride @{ 'lane-result.json' = 'sol'; 'v-2.md' = 'terra'; 'v-3.md' = 'opus' } | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir).ExitCode -eq 0) 'json-voice'
  }
  Case 'POSITIVE: general FULL with 5 models unchanged' {
    $s = New-Ship 'gen-full5' 'gf.txt'; Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames) -Tier 'FULL' | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'voices: 5 qualified / 5 candidates / 5 required' -and $run.Raw -notmatch 'security-voices:') "gen-full: $($run.Raw)"
  }
  Case 'NEGATIVE: security-FULL 5 models no security identity -> FAIL' {
    $s = New-Ship 'sec-no-id' 'sn.txt' -Profile 'security-sensitive'; Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames) -Tier 'FULL' | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir).Raw -match 'security-voices: 0/2') "sec-no-id"
  }
  Case 'NEGATIVE: security-FULL generic v-glm + v-kimi not *-security -> FAIL' {
    $s = New-Ship 'sec-generic' 'sg.txt' -Profile 'security-sensitive'
    Finish-Ship $s (Get-FullFiveBodies) -Names @('v-sol.md','v-terra.md','v-opus.md','v-glm.md','v-kimi.md') -Tier 'FULL' | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir).Raw -match 'security-voices: 0/2') 'sec-gen'
  }
  Case 'POSITIVE: security-FULL only v-glm-security (1/2) -> PASS' {
    $s = New-Ship 'sec-glm1' 's1.txt' -Profile 'security-sensitive'; Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames -Glm 'v-glm-security.md') -Tier 'FULL' | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir).Raw -match 'security-voices: 1/2') "sec-1"
  }
  Case 'POSITIVE: security-FULL v-glm-security + v-kimi-security (2/2) -> PASS' {
    $s = New-Ship 'sec-both' 's2.txt' -Profile 'security-sensitive'
    Finish-Ship $s (Get-FullFiveBodies) -Names @('v-sol.md','v-terra.md','v-opus.md','v-glm-security.md','v-kimi-security.md') -Tier 'FULL' | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir).Raw -match 'security-voices: 2/2') 'sec-2'
  }
  Case 'POSITIVE: security-FULL neither preferred but v-grok-security backup -> PASS' {
    $s = New-Ship 'sec-grok-bak' 'sb.txt' -Profile 'security-sensitive'; Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames -Grok 'v-grok-security.md') -Tier 'FULL' | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir).Raw -match 'security-voices: 0/2') "sec-bak"
  }
  Case 'NEGATIVE: security-sensitive at LIGHT -> FAIL' {
    $s = New-Ship 'sec-light' 'sl.txt' -Profile 'security-sensitive'
    Finish-Ship $s @((Get-MdVoice 'HIGH'),(Get-MdVoice 'LOW')) -Names @('v-glm-security.md','v-kimi-security.md') -Tier 'LIGHT' | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'LIGHT' $s.Lease.RunId $s.ReceiptDir).ExitCode -eq 1) 'sec-light'
  }
  Case 'NEGATIVE: security-sensitive at STANDARD -> FAIL' {
    $s = New-Ship 'sec-std' 'ss.txt' -Profile 'security-sensitive'
    Finish-Ship $s $md3 -Names @('v-glm-security.md','v-kimi-security.md','v-sol.md') -Tier 'STANDARD' | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir).ExitCode -eq 1) 'sec-std'
  }
  Case 'NEGATIVE: FILENAME+REFUSAL SPOOF v-glm-security-review.json -> 0/2 FAIL' {
    $s = New-Ship 'sec-refuse-spoof' 'srs.txt' -Profile 'security-sensitive'
    Finish-Ship $s @((Get-MdVoice 'HIGH'),(Get-MdVoice 'MEDIUM'),(Get-MdVoice 'LOW'),(Get-RefusalJsonVoice),(Get-MdVoice 'HIGH')) -Names @('v-sol.md','v-terra.md','v-opus.md','v-glm-security-review.json','v-grok.md') -Tier 'FULL' | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir).Raw -match 'security-voices: 0/2') 'spoof'
  }
  Case 'POSITIVE: v-glm-security real + v-kimi-security refusal -> 1/2 PASS' {
    $s = New-Ship 'sec-one-real' 'sor.txt' -Profile 'security-sensitive'
    Finish-Ship $s @((Get-MdVoice 'HIGH'),(Get-MdVoice 'MEDIUM'),(Get-MdVoice 'LOW'),(Get-MdVoice 'HIGH'),(Get-MdVoice 'MEDIUM'),(Get-RefusalJsonVoice)) -Names @('v-sol.md','v-terra.md','v-opus.md','v-glm-security.md','v-grok.md','v-kimi-security-review.json') -Tier 'FULL' | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir).Raw -match 'security-voices: 1/2') 'one-real'
  }
  Case 'NEGATIVE: locked-plan security-sensitive vs caller general -> FAIL' {
    $s = New-Ship 'lp-mismatch' 'lpm.txt' -Profile 'security-sensitive'
    Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames -Glm 'v-glm-security.md') -Tier 'FULL' | Out-Null
    $lp = Join-Path $s.Repo 'locked-plan.md'; Write-LockedPlan -Path $lp -Profile 'security-sensitive'
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL' -ReviewProfile 'general' -LockedPlan $lp -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest (Join-Path $s.ReviewDir 'packet-manifest.json')
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'verdict: FAILED' -and $run.Raw -match 'mismatch|review_profile') "lp-mm: $($run.Raw)"
  }
  Case 'POSITIVE: locked-plan security, no caller profile -> enforces security' {
    $s = New-Ship 'lp-auth' 'lpa.txt' -Profile 'security-sensitive'
    Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames -Glm 'v-glm-security.md') -Tier 'FULL' | Out-Null
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL' -LockedPlan $s.LockedPlan -OmitProfile -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest (Join-Path $s.ReviewDir 'packet-manifest.json')
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'verdict: ok' -and $run.Raw -match 'security-voices: 1/2' -and $run.Raw -match 'profile: security-sensitive') "lp-auth: $($run.Raw)"
  }
  Case 'NEGATIVE: locked-plan missing review_profile -> FAIL' {
    $s = New-Ship 'lp-missing' 'lpx.txt'; Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames) -Tier 'FULL' | Out-Null
    $lp = Join-Path $s.Repo 'locked-plan.md'; Write-LockedPlan -Path $lp -OmitProfile
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL' -LockedPlan $lp -OmitProfile -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest (Join-Path $s.ReviewDir 'packet-manifest.json')
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'verdict: FAILED' -and $run.Raw -match 'locked-plan|review_profile') "lp-miss: $($run.Raw)"
  }
  Case 'NEGATIVE: locked-plan duplicate review_profile -> FAIL' {
    $s = New-Ship 'lp-dup' 'lpd.txt'; Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames) -Tier 'FULL' | Out-Null
    $lp = Join-Path $s.Repo 'locked-plan.md'; Write-LockedPlan -Path $lp -Profile 'general' -Duplicate
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL' -LockedPlan $lp -OmitProfile -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest (Join-Path $s.ReviewDir 'packet-manifest.json')
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'verdict: FAILED' -and $run.Raw -match 'duplicate|review_profile') "lp-dup: $($run.Raw)"
  }
  Case 'NEGATIVE: needs_gate_validation-only security voice not qualified' {
    $s = New-Ship 'sec-ngv' 'sng.txt' -Profile 'security-sensitive'
    Finish-Ship $s @((Get-MdVoice 'HIGH'),(Get-MdVoice 'MEDIUM'),(Get-MdVoice 'LOW'),(Get-NgvJsonVoice),(Get-MdVoice 'HIGH')) -Names @('v-sol.md','v-terra.md','v-opus.md','v-glm-security-review.json','v-grok.md') -Tier 'FULL' | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'verdict: FAILED' -and $run.Raw -match 'security-voices: 0/2') "ngv: $($run.Raw)"
  }
  Case 'NEGATIVE: lp-omitted-caller-general -> FAILED' {
    $s = New-Ship 'lp-omit-caller' 'loc.txt'; New-Item -ItemType Directory -Force -Path $s.ReceiptDir | Out-Null
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies (Get-FullFiveBodies) -VoiceNames (Get-FullFiveNames) | Out-Null
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL' -ReviewProfile 'general' -OmitLockedPlan -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest (Join-Path $s.ReviewDir 'packet-manifest.json')
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'without signed receipt or -LockedPlan authority|downgrade') "lp-omit-caller: $($run.Raw)"
  }
  Case 'NEGATIVE: lp-omitted-nonempty-diff-FULL -> FAILED' {
    $s = New-Ship 'lp-omit-full' 'lof.txt'; New-Item -ItemType Directory -Force -Path $s.ReceiptDir | Out-Null
    Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies (Get-FullFiveBodies) -VoiceNames (Get-FullFiveNames) | Out-Null
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL' -OmitProfile -OmitLockedPlan -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest (Join-Path $s.ReviewDir 'packet-manifest.json')
    Assert-True ($run.ExitCode -eq 1) "lp-omit-full: $($run.Raw)"
  }
  Case 'POSITIVE: lp-present-matching general enforces' {
    $s = New-Ship 'lp-match-gen' 'lmg.txt'; Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames) -Tier 'FULL' | Out-Null
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL' -ReviewProfile 'general' -LockedPlan $s.LockedPlan -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest (Join-Path $s.ReviewDir 'packet-manifest.json')
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'verdict: ok') "lp-match: $($run.Raw)"
  }
  Case 'NEGATIVE: five v-fable-* collapse to ONE model' {
    $s = New-Ship 'fable-one' 'fb.txt'
    Finish-Ship $s (Get-FullFiveBodies) -Names @('v-fable-1.md','v-fable-2.md','v-fable-3.md','v-fable-4.md','v-fable-5.md') -Tier 'FULL' | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'voices: 1 qualified / 5 candidates / 5 required') "fable: $($run.Raw)"
  }
  Case 'R3: hosted model under v-glm-security filename NOT security voice' {
    $s = New-Ship 'r3-hosted-glm' 'r3a.txt' -Profile 'security-sensitive'
    Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames -Glm 'v-glm-security.md') -Tier 'FULL' -ModelOverride @{ 'v-glm-security.md' = 'sol' } -RoleOverride @{ 'v-glm-security.md' = 'security-review' } | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'security-voices: 0/2') "r3-hosted: $($run.Raw)"
  }
  Case 'R3: v-glm generic prefix is not security' {
    $s = New-Ship 'r3-prefix' 'r3b.txt' -Profile 'security-sensitive'
    Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames -Glm 'v-glm.md') -Tier 'FULL' -RoleOverride @{ 'v-glm.md' = 'general-review' } | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'security-voices: 0/2') "r3-prefix: $($run.Raw)"
  }
  Case 'R3: multi-token filename identity from signed field only' {
    $s = New-Ship 'r3-multi' 'r3c.txt' -Profile 'security-sensitive'
    Finish-Ship $s (Get-FullFiveBodies) -Names @('v-sol.md','v-terra.md','v-opus.md','v-glm-kimi-security-spoof.md','v-grok.md') -Tier 'FULL' -ModelOverride @{ 'v-glm-kimi-security-spoof.md' = 'sol' } -RoleOverride @{ 'v-glm-kimi-security-spoof.md' = 'general-review' } | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'security-voices: 0/2') "r3-multi: $($run.Raw)"
  }
  Case 'R3: unsigned security voice FAILED' {
    $s = New-Ship 'r3-unsigned' 'r3d.txt' -Profile 'security-sensitive'
    $paths = Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies (Get-FullFiveBodies) -VoiceNames (Get-FullFiveNames -Glm 'v-glm-security.md')
    New-Item -ItemType Directory -Force -Path $s.ReceiptDir | Out-Null
    $p = $paths | Where-Object { $_ -like '*glm-security*' } | Select-Object -First 1
    $bad = @{ schema_version = '1'; lane_id = 'v-glm-security'; requested_model = 'glm-5.3'; result_path = $p; result_sha256 = (Get-FileSha $p) }
    [IO.File]::WriteAllText((Join-Path $s.ReceiptDir 'unsigned.json'), ($bad | ConvertTo-Json -Compress), $utf8)
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'signature|FAILED|verdict: FAILED') "r3-unsigned: $($run.Raw)"
  }
  Case 'R3: wrong-key security voice FAILED' {
    $s = New-Ship 'r3-wrongkey' 'r3e.txt' -Profile 'security-sensitive'
    $paths = Write-ReviewPacket -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -VoiceBodies (Get-FullFiveBodies) -VoiceNames (Get-FullFiveNames -Glm 'v-glm-security.md')
    $wrong = New-Object byte[] 32; for ($i = 0; $i -lt 32; $i++) { $wrong[$i] = [byte](255 - $i) }
    Write-ReceiptsForVoices -ReceiptDir $s.ReceiptDir -Lease $s.Lease -VoicePaths $paths -Profile 'security-sensitive' -Tier 'FULL' -SecretOverride $wrong
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'signature|bad_signature|FAILED') "r3-wrongkey: $($run.Raw)"
  }
  Case 'R3: valid signed open-weights security voice qualifies' {
    $s = New-Ship 'r3-valid-sec' 'r3f.txt' -Profile 'security-sensitive'; Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames -Glm 'v-glm-security.md') -Tier 'FULL' | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'security-voices: 1/2' -and $run.Raw -match 'verdict: ok') "r3-valid: $($run.Raw)"
  }
  Case 'NEGATIVE: security voice bare HIGH only not qualified' {
    $s = New-Ship 'sec-bare-high' 'sbh.txt' -Profile 'security-sensitive'
    Finish-Ship $s @((Get-MdVoice 'HIGH'),(Get-MdVoice 'MEDIUM'),(Get-MdVoice 'LOW'),(Get-BareHighVoice),(Get-MdVoice 'HIGH')) -Names @('v-sol.md','v-terra.md','v-opus.md','v-glm-security.md','v-grok.md') -Tier 'FULL' | Out-Null
    Assert-True ((Ig $s.Repo $s.Base $s.ReviewDir 'FULL' $s.Lease.RunId $s.ReceiptDir).Raw -match 'security-voices: 0/2') "bare-high"
  }
  Case 'NEGATIVE: locked-plan hash mismatch on security receipt -> FAILED' {
    $s = New-Ship 'lp-hash-mm' 'lph.txt' -Profile 'security-sensitive'
    Finish-Ship $s (Get-FullFiveBodies) -Names (Get-FullFiveNames -Glm 'v-glm-security.md') -Tier 'FULL' | Out-Null
    $lp = Join-Path $s.Repo 'locked-plan.md'; Write-LockedPlan -Path $lp -Profile 'security-sensitive'
    [IO.File]::WriteAllText($lp, "# locked plan mutated`nreview_profile: security-sensitive`nextra: 1`n", $utf8)
    $run = Invoke-Gate -Repo $s.Repo -BaseRef $s.Base -ReviewDir $s.ReviewDir -Tier 'FULL' -ReviewProfile 'security-sensitive' -LockedPlan $lp -RunId $s.Lease.RunId -ReceiptDir $s.ReceiptDir -PacketManifest (Join-Path $s.ReviewDir 'packet-manifest.json')
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'locked_plan_sha256|verdict: FAILED') "lp-hash: $($run.Raw)"
  }
  Case 'POSITIVE: committed branch range binds frozen final.diff -> exit 0' {
    $s = New-Ship 'committed-bind' 'cb.txt' "committed-body`n"; Finish-Ship $s $md3 -Names $n3 | Out-Null
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 0 -and $run.Raw -match 'packet: match' -and $run.Raw -match 'verdict: ok') "cbind: $($run.Raw)"
  }
  Case 'NEGATIVE: base==HEAD empty committed range -> FAILED' {
    $repo = New-Repo 'base-eq-head'; $base = (& git -C $repo rev-parse HEAD).Trim(); $lease = New-TestLease
    $rc = Join-Path $repo '.fleet-receipts'; New-Item -ItemType Directory -Force -Path $rc | Out-Null
    $man = Join-Path $repo 'pm.json'; [IO.File]::WriteAllText($man, (EmptyManJson), $utf8)
    $run = Invoke-Gate -Repo $repo -BaseRef $base -Tier 'STANDARD' -RunId $lease.RunId -ReceiptDir $rc -PacketManifest $man -OmitLockedPlan
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'empty shipped diff|BaseRef resolves to HEAD|zero-telemetry|verdict: FAILED') "beqh: $($run.Raw)"
  }
  Case 'NEGATIVE: packet from uncommitted-only changes -> MISMATCH' {
    $s = New-Ship 'unc-only' 'uo.txt' "committed`n"; Finish-Ship $s $md3 -Names $n3 | Out-Null
    $tracked = Join-Path $s.Repo 'uo.txt'
    [IO.File]::WriteAllText($tracked, "committed`nplus-uncommitted`n", $utf8)
    $fd = Join-Path $s.ReviewDir 'final.diff'
    $p = New-Object System.Diagnostics.Process; $psi = $p.StartInfo
    $psi.FileName = 'git'; $psi.Arguments = ('-C "' + $s.Repo.Replace('"', '\"') + '" --no-pager diff ' + $s.Base)
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    [void]$p.Start(); $ms = New-Object System.IO.MemoryStream
    try { $p.StandardOutput.BaseStream.CopyTo($ms); [void]$p.WaitForExit(); [IO.File]::WriteAllBytes($fd, $ms.ToArray()) } finally { $ms.Dispose(); $p.Dispose() }
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'packet: MISMATCH|predate') "unc: $($run.Raw)"
  }
  Case 'NEGATIVE: wrong base ref -> MISMATCH' {
    $repo = New-Repo 'wrong-base'; $base0 = (& git -C $repo rev-parse HEAD).Trim()
    Add-Commit $repo 'a.txt' "one`n" 'first'; $base1 = (& git -C $repo rev-parse HEAD).Trim()
    Add-Commit $repo 'b.txt' "two`n" 'second'
    $rd = Join-Path $repo '.fleet-review'; $rc = Join-Path $repo '.fleet-receipts'
    Write-LockedPlan -Path (Join-Path $repo 'locked-plan.md') -Profile 'general'; $lease = New-TestLease
    $paths = Write-ReviewPacket -Repo $repo -BaseRef $base1 -ReviewDir $rd -VoiceBodies $md3 -VoiceNames $n3
    Write-ReceiptsForVoices -ReceiptDir $rc -Lease $lease -VoicePaths $paths -Profile 'general' -Tier 'STANDARD'
    $run = Ig $repo $base0 $rd 'STANDARD' $lease.RunId $rc
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'packet: MISMATCH|predate') "wbase: $($run.Raw)"
  }
  Case 'NEGATIVE: single-byte mutation of frozen final.diff -> MISMATCH' {
    $s = New-Ship 'mut-diff' 'md.txt' "body`n"; Finish-Ship $s $md3 -Names $n3 | Out-Null
    $fd = Join-Path $s.ReviewDir 'final.diff'; $bytes = [IO.File]::ReadAllBytes($fd)
    Assert-True ($bytes.Length -gt 0) 'mut-diff empty final.diff'
    $bytes[$bytes.Length - 1] = [byte](($bytes[$bytes.Length - 1] + 1) % 256)
    [IO.File]::WriteAllBytes($fd, $bytes)
    $run = Ig $s.Repo $s.Base $s.ReviewDir 'STANDARD' $s.Lease.RunId $s.ReceiptDir
    Assert-True ($run.ExitCode -eq 1 -and $run.Raw -match 'packet: MISMATCH|predate') "mut: $($run.Raw)"
  }
}
finally { if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } }
$total = $passed + $failed + $skipped
Write-Host ("DENOMINATOR: cases run=$total passed=$passed failed=$failed skipped=$skipped")
if ($total -eq 0 -or $failed -gt 0) { Write-Host ("selftest: FAIL {0}/{1}" -f $passed, $total); exit 1 }
Write-Host ("selftest: PASS {0}/{0}" -f $total); exit 0
