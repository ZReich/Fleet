# Self-test companion for Assert-FleetMergeReadiness.ps1 (v2 signed receipts).
# Exit 0: selftest: PASS k/k. Exit 1 on first failure. Does not invoke pwsh for suite body.
$ErrorActionPreference = 'Stop'
$script:ShaOk = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:ShaStale = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$script:ShaPlan = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
$script:ShaRes = 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
$script:ShaChar = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
$script:Req = @('change-map', 'synthesis', 'adversarial-challenge', 'triage')
$script:AssertPath = Join-Path $PSScriptRoot 'Assert-FleetMergeReadiness.ps1'
if (-not (Test-Path -LiteralPath $script:AssertPath)) {
  $script:AssertPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Assert-FleetMergeReadiness.ps1'
}
. (Join-Path $PSScriptRoot 'FleetReceiptSignature.Helpers.ps1')
. (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
. (Join-Path $PSScriptRoot 'FleetSignedTest.Helpers.ps1')
$script:TestSecret = New-Object byte[] 32
for ($i = 0; $i -lt 32; $i++) { $script:TestSecret[$i] = [byte](40 + $i) }
$script:TestKeyId = 'abcdef0123456789abcdef0123456789'
$script:TestRunId = 'mr-st-' + [guid]::NewGuid().ToString('n').Substring(0, 12)
$script:LeaseDir = Join-Path $env:USERPROFILE '.codex\fleet\run-leases'
$script:LeasePath = Join-Path $script:LeaseDir ($script:TestRunId + '.json')
$script:StageSetSha = Get-StageSetSha $script:Req @()
$script:Ts0 = '2026-08-05T00:00:00.0000000Z'; $script:Ts1 = '2026-08-05T00:01:00.0000000Z'
$script:Ts2 = '2026-08-05T00:02:00.0000000Z'; $script:Ts3 = '2026-08-05T00:03:00.0000000Z'
# M2: real result file; New-ReceiptObject binds ResultFixturePath + ShaRes.
$script:ResultFixtureDir = Join-Path ([IO.Path]::GetTempPath()) ('flt-mr-res-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:ResultFixtureDir -Force | Out-Null
$script:ResultFixturePath = Join-Path $script:ResultFixtureDir 'result.md'
[IO.File]::WriteAllText($script:ResultFixturePath, "fleet-merge-result-fixture`n", $script:FstUtf8)
$script:ShaRes = Get-FileSha $script:ResultFixturePath
function Invoke-Reducer([string]$Dir, [int]$Cap = 3, [string]$PacketSha = '', [string]$RunId = '') {
  if ([string]::IsNullOrWhiteSpace($PacketSha)) { $PacketSha = $script:ShaOk }
  if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = $script:TestRunId }
  $psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.FileName = 'powershell.exe'
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:AssertPath, '-ReceiptDir', $Dir, '-RunId', $RunId, '-ExpectedPacketSha256', $PacketSha, '-RequiredStages', 'change-map,synthesis,adversarial-challenge,triage', '-RoundCap', ([string]$Cap))
  $quoted = ($args | ForEach-Object { $t = [string]$_; if ($t -match '[\s"]') { '"' + ($t -replace '"', '\"') + '"' } else { $t } }) -join ' '
  $psi.Arguments = $quoted; $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd(); $stderr = $proc.StandardError.ReadToEnd(); $proc.WaitForExit()
  $verdict = ''; if ($stdout -match 'merge-readiness:\s+(\S+)') { $verdict = $Matches[1] }
  return [pscustomobject]@{ ExitCode = $proc.ExitCode; Verdict = $verdict; Stdout = $stdout; Stderr = $stderr }
}
Install-TestLease
try {
$cases = @(
  @{ Name = 'a-ready'; Expect = 'READY'; ExpectExit = 0; Build = { param($d) Write-MandatoryPassed $d $script:ShaOk } },
  @{ Name = 'b-missing'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      foreach ($s in @('change-map', 'synthesis', 'adversarial-challenge')) { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
    } },
  @{ Name = 'c-blocked'; Expect = 'BLOCKED'; ExpectExit = 4; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'triage') { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk -Findings @([pscustomobject]@{ severity = 'CRITICAL'; id = 'C1'; resolved = $false })) }
        else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'd-stale'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'triage') { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaStale) }
        else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'e-blank-sha'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      foreach ($s in $script:Req) { $o = New-ReceiptObject $s $script:ShaOk -Unsigned; $o['input_packet_sha256'] = ''; Write-ReceiptFile $d $s $o }
    } },
  @{ Name = 'f-mandatory-na'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'change-map') { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk -Status 'not_applicable') }
        else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'g-roundcap4'; Expect = 'USAGE'; ExpectExit = 2; Build = { param($d) Write-MandatoryPassed $d $script:ShaOk }; Cap = 4 },
  @{ Name = 'h-fallback-ready'; Expect = 'READY'; ExpectExit = 0; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'triage') {
          Write-ReceiptFile $d 'triage-primary' (New-ReceiptObject $s $script:ShaOk -Status 'blocked' -FailureCategory 'provider outage' -ObservedModel 'primary-model' -Model 'primary-model' -StartedAt $script:Ts0 -CompletedAt $script:Ts1)
          Write-ReceiptFile $d 'triage-fallback' (New-ReceiptObject $s $script:ShaOk -Status 'passed' -FallbackOf 'triage:primary-model' -ObservedModel 'fallback-model' -Model 'fallback-model' -StartedAt $script:Ts1 -CompletedAt $script:Ts2)
        } else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'i-status-blocked'; Expect = 'BLOCKED'; ExpectExit = 4; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'triage') { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk -Status 'blocked') }
        else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'j-duplicate-root'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'triage-passed' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -Model 'm-pass' -ObservedModel 'm-pass')
      Write-ReceiptFile $d 'triage-blocked' (New-ReceiptObject 'triage' $script:ShaOk -Status 'blocked' -Model 'm-block' -ObservedModel 'm-block')
    } },
  @{ Name = 'k-orphan-fallback'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'triage-orphan' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -FallbackOf 'triage:nonexistent-model' -Model 'fb-model' -ObservedModel 'fb-model')
    } },
  @{ Name = 'l-unlinked-rescue'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'triage-primary' (New-ReceiptObject 'triage' $script:ShaOk -Status 'failed' -FailureCategory 'provider outage' -Model 'triage-primary' -ObservedModel 'triage-primary')
      Write-ReceiptFile $d 'triage-rescue' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -FallbackOf 'synthesis:test-model' -Model 'rescue-model' -ObservedModel 'rescue-model')
    } },
  @{ Name = 'm-scalar-arrays'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = (New-BaseJson 'triage' $script:ShaOk) -replace '"findings":\[\]', '"findings":"not-an-array"' -replace '"evidence_refs":\["trigger:ok"\]', '"evidence_refs":"scalar-ref"'
      Write-RawReceipt $d 'triage' ($bad -replace ',"signature":"[0-9a-f]{64}"', '')
    } },
  @{ Name = 'n-schema-version-true'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = ((New-BaseJson 'triage' $script:ShaOk) -replace '"schema_version":"2"', '"schema_version":true') -replace ',"signature":"[0-9a-f]{64}"', ''
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'o-schema-version-float'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = ((New-BaseJson 'triage' $script:ShaOk) -replace '"schema_version":"2"', '"schema_version":1.2') -replace ',"signature":"[0-9a-f]{64}"', ''
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'p-schema-version-01'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = ((New-BaseJson 'triage' $script:ShaOk) -replace '"schema_version":"2"', '"schema_version":"01"') -replace ',"signature":"[0-9a-f]{64}"', ''
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'q-invalid-duplicate-root'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'triage-pass' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -Model 'm-pass' -ObservedModel 'm-pass')
      $bad = ((New-BaseJson 'triage' $script:ShaOk 'blocked' 'm-block') -replace '"schema_version":"2"', '"schema_version":true') -replace ',"signature":"[0-9a-f]{64}"', ''
      Write-RawReceipt $d 'triage-bad' $bad
    } },
  @{ Name = 'r-repair-0-orphan'; Expect = 'USAGE'; ExpectExit = 2; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk; Write-ReceiptFile $d 'repair-0' (New-ReceiptObject 'repair-0' $script:ShaOk -Status 'failed')
    } },
  @{ Name = 's-repair-01'; Expect = 'USAGE'; ExpectExit = 2; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk; Write-ReceiptFile $d 'repair-01' (New-ReceiptObject 'repair-01' $script:ShaOk -Status 'failed')
    } },
  @{ Name = 't-repair-index-over-cap'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk
      Write-ReceiptFile $d 'repair-2' (New-ReceiptObject 'repair-2' $script:ShaOk -Status 'passed' -Model 'rep' -ObservedModel 'rep')
      Write-ReceiptFile $d 'verify-2' (New-ReceiptObject 'verify-2' $script:ShaOk -Status 'passed' -Model 'ver' -ObservedModel 'ver')
    }; Cap = 1 },
  @{ Name = 'u-dup-json-member-evidence'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = ((New-BaseJson 'triage' $script:ShaOk) -replace '"evidence_refs":\["trigger:ok"\]', '"evidence_refs":["trigger:ok"],"evidence_refs":"scalar-hijack"') -replace ',"signature":"[0-9a-f]{64}"', ''
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'v-dup-json-member-stage'; Expect = 'USAGE'; ExpectExit = 2; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = ((New-BaseJson 'triage' $script:ShaOk) -replace '"stage":"triage"', '"stage":"triage","stage":""') -replace ',"signature":"[0-9a-f]{64}"', ''
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'w-parse-error'; Expect = 'USAGE'; ExpectExit = 2; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk; Write-RawReceipt $d 'junk' '{not-json'
    } },
  @{ Name = 'x-one-element-array'; Expect = 'READY'; ExpectExit = 0; Build = { param($d) Write-MandatoryPassed $d $script:ShaOk } },
  @{ Name = 'y-undeclared-fork-repair'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk
      Write-ReceiptFile $d 'repair-1a' (New-ReceiptObject 'repair-1' $script:ShaOk -Status 'passed' -Model 'model-x' -ObservedModel 'model-x')
      Write-ReceiptFile $d 'repair-1b' (New-ReceiptObject 'repair-1' $script:ShaOk -Status 'failed' -Model 'model-y' -ObservedModel 'model-y')
    } },
  @{ Name = 'z-numeric-run_id'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = ((New-BaseJson 'triage' $script:ShaOk) -replace ('"run_id":"' + $script:TestRunId + '"'), '"run_id":123') -replace ',"signature":"[0-9a-f]{64}"', ''
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'aa-undeclared-required-failed'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk
      Write-ReceiptFile $d 'security-audit' (New-ReceiptObject 'security-audit' $script:ShaOk -Status 'failed' -Required $true)
    } },
  @{ Name = 'ab-undeclared-required-passed-still-flagged'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk
      Write-ReceiptFile $d 'security-audit' (New-ReceiptObject 'security-audit' $script:ShaOk -Status 'passed' -Required $true)
    } },
  @{ Name = 'ac-chain-required-mismatch'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'triage-p' (New-ReceiptObject 'triage' $script:ShaOk -Status 'blocked' -FailureCategory 'provider outage' -Model 'primary' -ObservedModel 'primary' -Required $true -StartedAt $script:Ts0 -CompletedAt $script:Ts1)
      Write-ReceiptFile $d 'triage-f' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -FallbackOf 'triage:primary' -Model 'fallback' -ObservedModel 'fallback' -Required $false -StartedAt $script:Ts1 -CompletedAt $script:Ts2)
    } },
  @{ Name = 'ad-escaped-dup-status'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = ((New-BaseJson 'triage' $script:ShaOk 'failed') -replace '"status":"failed"', '"status":"failed","st\u0061tus":"passed"') -replace ',"signature":"[0-9a-f]{64}"', ''
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'ae-escaped-dup-stage'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = ((New-BaseJson 'triage' $script:ShaOk) -replace '"stage":"triage"', '"stage":"triage","st\u0061ge":"triage"') -replace ',"signature":"[0-9a-f]{64}"', ''
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'af-policy-refusal-fallback'; Expect = 'READY'; ExpectExit = 0; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'tp' (New-ReceiptObject 'triage' $script:ShaOk -Status 'failed' -FailureCategory 'policy refusal' -Model 'pm' -ObservedModel 'pm' -StartedAt $script:Ts0 -CompletedAt $script:Ts1)
      Write-ReceiptFile $d 'tf' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -FallbackOf 'triage:pm' -Model 'fm' -ObservedModel 'fm' -StartedAt $script:Ts1 -CompletedAt $script:Ts2)
    } },
  @{ Name = 'ag-fallback-after-passed'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'tp' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -FailureCategory 'provider outage' -Model 'pm' -ObservedModel 'pm' -StartedAt $script:Ts0 -CompletedAt $script:Ts1)
      Write-ReceiptFile $d 'tf' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -FallbackOf 'triage:pm' -Model 'fm' -ObservedModel 'fm' -StartedAt $script:Ts1 -CompletedAt $script:Ts2)
    } },
  @{ Name = 'ah-passed-empty-evidence'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'change-map') { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk -EvidenceRefs @() -OutputArtifacts @()) }
        else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'ai-mandatory-required-false'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'triage') { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk -Required $false) }
        else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'aj-fallback-chrono-violation'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'tp' (New-ReceiptObject 'triage' $script:ShaOk -Status 'failed' -FailureCategory 'provider outage' -Model 'pm' -ObservedModel 'pm' -StartedAt $script:Ts0 -CompletedAt $script:Ts2)
      Write-ReceiptFile $d 'tf' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -FallbackOf 'triage:pm' -Model 'fm' -ObservedModel 'fm' -StartedAt $script:Ts1 -CompletedAt $script:Ts3)
    } },
  @{ Name = 'ak-high-trailing-space'; Expect = 'BLOCKED'; ExpectExit = 4; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'triage') { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk -Findings @([pscustomobject]@{ severity = 'HIGH '; id = 'H1'; resolved = $false })) }
        else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'al-unsigned-NOT_READY'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage'); Write-ReceiptFile $d 'triage' (New-ReceiptObject 'triage' $script:ShaOk -Unsigned)
    } },
  @{ Name = 'am-wrong-key-NOT_READY'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      $wrong = New-Object byte[] 32; for ($i = 0; $i -lt 32; $i++) { $wrong[$i] = [byte](200 - $i) }
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'triage' (New-ReceiptObject 'triage' $script:ShaOk -Secret $wrong)
    } },
  @{ Name = 'an-packet-majority-spoof-NOT_READY'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d) Write-MandatoryPassed $d $script:ShaStale }; PacketSha = $script:ShaOk },
  @{ Name = 'ao-wrong-stage-set-NOT_READY'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -StageSetSha 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
    } },
  @{ Name = 'ap-valid-signed-READY'; Expect = 'READY'; ExpectExit = 0; Build = { param($d) Write-MandatoryPassed $d $script:ShaOk } },
  @{ Name = 'aq-passed-result-missing-NOT_READY'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $missing = Join-Path $d 'no-such-result.md'
      Write-ReceiptFile $d 'triage' (New-ReceiptObject 'triage' $script:ShaOk -ResultPath $missing -ResultSha $script:ShaRes)
    } },
  @{ Name = 'ar-passed-result-hash-mismatch-NOT_READY'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = Join-Path $d 'bad-result.md'; [IO.File]::WriteAllText($bad, "tampered-body`n", $script:FstUtf8)
      Write-ReceiptFile $d 'triage' (New-ReceiptObject 'triage' $script:ShaOk -ResultPath $bad -ResultSha $script:ShaRes)
    } }
)
$pass = 0; $total = $cases.Count
foreach ($c in $cases) {
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('flt-mr-' + $c.Name + '-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  try {
    & $c.Build $dir
    $cap = 3; if ($c.ContainsKey('Cap')) { $cap = [int]$c.Cap }
    $pkt = $script:ShaOk; if ($c.ContainsKey('PacketSha')) { $pkt = [string]$c.PacketSha }
    $r = Invoke-Reducer $dir $cap $pkt
    $ok = ($r.ExitCode -eq $c.ExpectExit)
    if ($c.Expect -ne 'USAGE') { if ($r.Verdict -ne $c.Expect) { $ok = $false } }
    if (-not $ok) {
      Write-Output ("selftest: FAIL {0} expect={1}/{2} got={3}/{4} stderr={5}" -f $c.Name, $c.Expect, $c.ExpectExit, $r.Verdict, $r.ExitCode, $r.Stderr)
      exit 1
    }
    $pass++
  } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
}
Write-Output ("selftest: PASS {0}/{1}" -f $pass, $total)
exit 0
} finally {
  Remove-TestLease
  if ($script:ResultFixtureDir -and (Test-Path -LiteralPath $script:ResultFixtureDir)) {
    Remove-Item -LiteralPath $script:ResultFixtureDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
