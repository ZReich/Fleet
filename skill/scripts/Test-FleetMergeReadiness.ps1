# Self-test companion for Assert-FleetMergeReadiness.ps1.
# Exit 0: selftest: PASS k/k. Exit 1 on first failure.
$ErrorActionPreference = 'Stop'
$script:ShaOk = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$script:ShaStale = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$script:Req = @('change-map', 'synthesis', 'adversarial-challenge', 'triage')
$script:AssertPath = Join-Path $PSScriptRoot 'Assert-FleetMergeReadiness.ps1'
if (-not (Test-Path -LiteralPath $script:AssertPath)) {
  $script:AssertPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Assert-FleetMergeReadiness.ps1'
}

function Write-Utf8File([string]$Path, [string]$Text) {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}

# ConvertTo-Json for values; force true JSON arrays for the three array fields (PS5.1 unrolls 1-el).
function ConvertTo-FixtureJson($Obj) {
  $parts = New-Object System.Collections.ArrayList
  foreach ($k in @($Obj.Keys)) {
    $v = $Obj[$k]
    if ($k -in @('findings', 'evidence_refs', 'output_artifacts')) {
      $elems = New-Object System.Collections.ArrayList
      foreach ($item in @($v)) {
        if ($null -eq $item -and @($v).Count -eq 0) { break }
        [void]$elems.Add(($item | ConvertTo-Json -Depth 4 -Compress))
      }
      [void]$parts.Add(('"{0}":[{1}]' -f $k, ($elems -join ',')))
      continue
    }
    if ($null -eq $v) { [void]$parts.Add(('"{0}":null' -f $k)); continue }
    [void]$parts.Add(('"{0}":{1}' -f $k, ($v | ConvertTo-Json -Compress -Depth 2)))
  }
  return '{' + ($parts -join ',') + '}'
}

function New-ReceiptObject {
  param(
    [string]$Stage, [string]$PacketSha, [string]$Status = 'passed',
    [object[]]$Findings = @(), [object[]]$EvidenceRefs = @('trigger:ok'),
    [string]$ObservedModel = 'test-model', [string]$Model = 'test-model',
    [object]$FallbackOf = $null, [object]$FailureCategory = $null,
    [bool]$Required = $true, [string]$RunId = 'selftest',
    [object]$SchemaVersion = '1'
  )
  return [ordered]@{
    schema_version = $SchemaVersion; run_id = $RunId; stage = $Stage; required = $Required
    status = $Status; observed_model = $ObservedModel; effort = 'high'
    input_packet_sha256 = $PacketSha; fallback_of = $FallbackOf
    failure_category = $FailureCategory
    findings = @($Findings); evidence_refs = @($EvidenceRefs); output_artifacts = @()
    started_at = '2026-08-05T00:00:00Z'; completed_at = '2026-08-05T00:01:00Z'
    model = $Model
  }
}

function Write-ReceiptFile([string]$Dir, [string]$Name, $Obj) {
  Write-Utf8File (Join-Path $Dir ($Name + '.receipt.json')) (ConvertTo-FixtureJson $Obj)
}
function Write-RawReceipt([string]$Dir, [string]$Name, [string]$Json) {
  Write-Utf8File (Join-Path $Dir ($Name + '.receipt.json')) $Json
}

function Invoke-Reducer([string]$Dir, [int]$Cap = 3) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:AssertPath,
    '-ReceiptDir', $Dir,
    '-RequiredStages', 'change-map,synthesis,adversarial-challenge,triage',
    '-RoundCap', ([string]$Cap)
  )
  $quoted = ($args | ForEach-Object {
      $t = [string]$_
      if ($t -match '[\s"]') { '"' + ($t -replace '"', '\"') + '"' } else { $t }
    }) -join ' '
  $psi.Arguments = $quoted
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEnd()
  $null = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  $verdict = ''
  if ($stdout -match 'merge-readiness:\s+(\S+)') { $verdict = $Matches[1] }
  return [pscustomobject]@{ ExitCode = $proc.ExitCode; Verdict = $verdict; Stdout = $stdout }
}

function Write-MandatoryPassed([string]$Dir, [string]$Sha, [string[]]$Except = @()) {
  foreach ($s in $script:Req) {
    if ($s -in $Except) { continue }
    Write-ReceiptFile $Dir $s (New-ReceiptObject $s $Sha)
  }
}

function New-BaseJson([string]$Stage, [string]$Sha, [string]$Status = 'passed', [string]$Model = 'test-model') {
  return (@'
{"schema_version":"1","run_id":"selftest","stage":"STAGE","required":true,"status":"STATUS","observed_model":"MODEL","effort":"high","input_packet_sha256":"SHA","fallback_of":null,"failure_category":null,"findings":[],"evidence_refs":["trigger:ok"],"output_artifacts":[],"started_at":"2026-08-05T00:00:00Z","completed_at":"2026-08-05T00:01:00Z","model":"MODEL"}
'@ -creplace 'STAGE', $Stage -creplace 'STATUS', $Status -creplace 'SHA', $Sha -creplace 'MODEL', $Model)
}

$cases = @(
  @{ Name = 'a-ready'; Expect = 'READY'; ExpectExit = 0; Build = { param($d) Write-MandatoryPassed $d $script:ShaOk
    } },
  @{ Name = 'b-missing'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      foreach ($s in @('change-map', 'synthesis', 'adversarial-challenge')) {
        Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk)
      }
    } },
  @{ Name = 'c-blocked'; Expect = 'BLOCKED'; ExpectExit = 4; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'triage') {
          $f = @([pscustomobject]@{ severity = 'CRITICAL'; id = 'C1'; resolved = $false })
          Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk -Findings $f)
        } else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'd-stale'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'triage') { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaStale) }
        else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'e-blank-sha'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      foreach ($s in $script:Req) { Write-ReceiptFile $d $s (New-ReceiptObject $s '') }
    } },
  @{ Name = 'f-mandatory-na'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'change-map') {
          Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk -Status 'not_applicable')
        } else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'g-roundcap4'; Expect = 'USAGE'; ExpectExit = 2; Build = { param($d) Write-MandatoryPassed $d $script:ShaOk
    }; Cap = 4 },
  @{ Name = 'h-fallback-ready'; Expect = 'READY'; ExpectExit = 0; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'triage') {
          $pri = New-ReceiptObject $s $script:ShaOk -Status 'blocked' -FailureCategory 'provider outage' `
            -ObservedModel 'primary-model' -Model 'primary-model'
          $fb = New-ReceiptObject $s $script:ShaOk -Status 'passed' -FallbackOf 'triage:primary-model' `
            -ObservedModel 'fallback-model' -Model 'fallback-model'
          Write-ReceiptFile $d 'triage-primary' $pri
          Write-ReceiptFile $d 'triage-fallback' $fb
        } else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'i-status-blocked'; Expect = 'BLOCKED'; ExpectExit = 4; Build = { param($d)
      foreach ($s in $script:Req) {
        if ($s -eq 'triage') {
          Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk -Status 'blocked')
        } else { Write-ReceiptFile $d $s (New-ReceiptObject $s $script:ShaOk) }
      }
    } },
  @{ Name = 'j-duplicate-root'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'triage-passed' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -Model 'm-pass' -ObservedModel 'm-pass')
      Write-ReceiptFile $d 'triage-blocked' (New-ReceiptObject 'triage' $script:ShaOk -Status 'blocked' -Model 'm-block' -ObservedModel 'm-block')
    } },
  @{ Name = 'k-orphan-fallback'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'triage-orphan' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' `
        -FallbackOf 'triage:nonexistent-model' -Model 'fb-model' -ObservedModel 'fb-model')
    } },
  @{ Name = 'l-unlinked-rescue'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'triage-primary' (New-ReceiptObject 'triage' $script:ShaOk -Status 'failed' `
        -FailureCategory 'provider outage' -Model 'triage-primary' -ObservedModel 'triage-primary')
      Write-ReceiptFile $d 'triage-rescue' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' `
        -FallbackOf 'synthesis:test-model' -Model 'rescue-model' -ObservedModel 'rescue-model')
    } },
  @{ Name = 'm-scalar-arrays'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $base = New-BaseJson 'triage' $script:ShaOk
      $bad = $base -replace '"findings":\[\]', '"findings":"not-an-array"' `
        -replace '"evidence_refs":\["trigger:ok"\]', '"evidence_refs":"scalar-ref"'
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'n-schema-version-true'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = (New-BaseJson 'triage' $script:ShaOk) -replace '"schema_version":"1"', '"schema_version":true'
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'o-schema-version-float'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = (New-BaseJson 'triage' $script:ShaOk) -replace '"schema_version":"1"', '"schema_version":1.2'
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'p-schema-version-01'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = (New-BaseJson 'triage' $script:ShaOk) -replace '"schema_version":"1"', '"schema_version":"01"'
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'q-invalid-duplicate-root'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-ReceiptFile $d 'triage-pass' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -Model 'm-pass' -ObservedModel 'm-pass')
      $bad = (New-BaseJson 'triage' $script:ShaOk 'blocked' 'm-block') -replace '"schema_version":"1"', '"schema_version":true'
      Write-RawReceipt $d 'triage-bad' $bad
    } },
  @{ Name = 'r-repair-0-orphan'; Expect = 'USAGE'; ExpectExit = 2; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk
      Write-RawReceipt $d 'repair-0' (New-BaseJson 'repair-0' $script:ShaOk 'failed')
    } },
  @{ Name = 's-repair-01'; Expect = 'USAGE'; ExpectExit = 2; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk
      Write-RawReceipt $d 'repair-01' ((New-BaseJson 'repair-01' $script:ShaOk -Status 'failed'))
    } },
  @{ Name = 't-repair-index-over-cap'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk
      Write-ReceiptFile $d 'repair-2' (New-ReceiptObject 'repair-2' $script:ShaOk -Status 'passed' -Model 'rep' -ObservedModel 'rep')
      Write-ReceiptFile $d 'verify-2' (New-ReceiptObject 'verify-2' $script:ShaOk -Status 'passed' -Model 'ver' -ObservedModel 'ver')
    }; Cap = 1 },
  @{ Name = 'u-dup-json-member-evidence'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $base = New-BaseJson 'triage' $script:ShaOk
      $bad = $base -replace '"evidence_refs":\["trigger:ok"\]', '"evidence_refs":["trigger:ok"],"evidence_refs":"scalar-hijack"'
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'v-dup-json-member-stage'; Expect = 'USAGE'; ExpectExit = 2; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $base = New-BaseJson 'triage' $script:ShaOk
      $bad = $base -replace '"stage":"triage"', '"stage":"triage","stage":""'
      Write-RawReceipt $d 'triage' $bad
    } },
  @{ Name = 'w-parse-error'; Expect = 'USAGE'; ExpectExit = 2; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk
      Write-RawReceipt $d 'junk' '{not-json'
    } },
  @{ Name = 'x-one-element-array'; Expect = 'READY'; ExpectExit = 0; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk
    } },
  @{ Name = 'y-undeclared-fork-repair'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk
      Write-RawReceipt $d 'repair-1a' (New-BaseJson 'repair-1' $script:ShaOk 'passed' 'model-x')
      Write-RawReceipt $d 'repair-1b' (New-BaseJson 'repair-1' $script:ShaOk 'failed' 'model-y')
    } },
  @{ Name = 'z-numeric-run_id'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      $bad = (New-BaseJson 'triage' $script:ShaOk) -replace '"run_id":"selftest"', '"run_id":123'
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
      Write-ReceiptFile $d 'triage-p' (New-ReceiptObject 'triage' $script:ShaOk -Status 'blocked' -FailureCategory 'provider outage' -Model 'primary' -ObservedModel 'primary' -Required $true)
      Write-ReceiptFile $d 'triage-f' (New-ReceiptObject 'triage' $script:ShaOk -Status 'passed' -FallbackOf 'triage:primary' -Model 'fallback' -ObservedModel 'fallback' -Required $false)
    } },
  @{ Name = 'ad-escaped-dup-status'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-RawReceipt $d 'triage' ((New-BaseJson 'triage' $script:ShaOk 'failed') -replace '"status":"failed"', '"status":"failed","st\u0061tus":"passed"')
    } },
  @{ Name = 'ae-escaped-dup-stage'; Expect = 'NOT_READY'; ExpectExit = 3; Build = { param($d)
      Write-MandatoryPassed $d $script:ShaOk -Except @('triage')
      Write-RawReceipt $d 'triage' ((New-BaseJson 'triage' $script:ShaOk) -replace '"stage":"triage"', '"stage":"triage","st\u0061ge":"triage"')
    } }
)

$pass = 0
$total = $cases.Count
foreach ($c in $cases) {
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('flt-mr-' + $c.Name + '-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  try {
    & $c.Build $dir
    $cap = 3
    if ($c.ContainsKey('Cap')) { $cap = [int]$c.Cap }
    $r = Invoke-Reducer $dir $cap
    $ok = ($r.ExitCode -eq $c.ExpectExit)
    if ($c.Expect -ne 'USAGE') {
      if ($r.Verdict -ne $c.Expect) { $ok = $false }
    }
    if (-not $ok) {
      Write-Output ("selftest: FAIL {0} expect={1}/{2} got={3}/{4}" -f $c.Name, $c.Expect, $c.ExpectExit, $r.Verdict, $r.ExitCode)
      exit 1
    }
    $pass++
  } finally {
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
  }
}
Write-Output ("selftest: PASS {0}/{1}" -f $pass, $total)
exit 0
