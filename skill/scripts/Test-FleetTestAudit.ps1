# Focused suite for New-FleetTestAuditCharter + Read-FleetTestAuditVerdict.
# Case/Assert-True style matches Test-FleetContract.ps1 / Test-ClearStaleKimiK3Runtime.ps1.
# BOTH DIRECTIONS: charter compose + verdict parse. Real test-shaped fixtures in temp dir.
$ErrorActionPreference = 'Stop'
$passed = 0; $failed = 0; $skipped = 0
function Case([string]$n, [scriptblock]$b) {
  try { & $b; $script:passed++; Write-Host "PASS $n" }
  catch { $script:failed++; Write-Host "FAIL $n - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }

$charterScript = Join-Path $PSScriptRoot 'New-FleetTestAuditCharter.ps1'
$parseScript = Join-Path $PSScriptRoot 'Read-FleetTestAuditVerdict.ps1'
$utf8 = New-Object System.Text.UTF8Encoding $false
$backslash = [string][char]92

function New-TestRoot {
  $root = Join-Path ([IO.Path]::GetTempPath()) ('fleet-test-audit-' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  return $root
}

function Write-Utf8([string]$Path, [string]$Text) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Invoke-PsFile {
  param([string]$Script, [string[]]$ExtraArgs = @())
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + @($ExtraArgs)
  $old = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $raw = & powershell.exe @argList 2>&1
    $code = $LASTEXITCODE
  }
  finally { $ErrorActionPreference = $old }
  $text = (($raw | ForEach-Object { "$_" }) -join "`n")
  return [pscustomobject]@{ ExitCode = $code; Raw = $text }
}

$sixChecks = @(
  'would-fail-if-mutated',
  'independent-oracle',
  'tests-subject-not-mock',
  'real-assertion',
  'deletes-duplicate',
  'boundary'
)

# --- CHARTER: embeds 6 checks + contract; missing/empty TestFile fails closed ---
Case 'charter embeds 6 check names and TEST-AUDIT contract' {
  $root = New-TestRoot
  try {
    $testFile = Join-Path $root 'sample.test.ts'
    Write-Utf8 $testFile @"
import { add } from './add';
describe('add', () => {
  it('sums two numbers', () => {
    expect(add(1, 2)).toBe(3);
  });
});
"@
    $out = Join-Path $root 'prompt.md'
    $r = Invoke-PsFile -Script $charterScript -ExtraArgs @('-TestFile', $testFile, '-OutputPath', $out, '-Mode', 'text')
    Assert-True ($r.ExitCode -eq 0) "charter exit $($r.ExitCode): $($r.Raw)"
    Assert-True (Test-Path -LiteralPath $out) 'prompt file missing'
    $prompt = [IO.File]::ReadAllText($out)
    foreach ($chk in $sixChecks) {
      Assert-True ($prompt.Contains($chk)) "missing check name: $chk"
    }
    Assert-True ($prompt.Contains('===TEST-AUDIT===')) 'missing ===TEST-AUDIT=== marker'
    Assert-True ($prompt.Contains('===END===')) 'missing ===END=== marker'
    Assert-True ($prompt.Contains('result: PASS | WARN | REJECT')) 'missing result contract'
    Assert-True ($prompt.Contains('Adversarial Test Code Evaluator')) 'missing role line'
    Assert-True ($prompt.Contains('OUTPUT STYLE (mandatory): terse')) 'missing terse trailer'
    Assert-True ($prompt.Contains('sums two numbers')) 'test body not embedded'
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Case 'charter missing TestFile fails closed' {
  $r = Invoke-PsFile -Script $charterScript -ExtraArgs @('-TestFile', 'C:\nonexistent-fleet-test-audit-xyz.test.ts')
  Assert-True ($r.ExitCode -ne 0) 'expected non-zero exit for missing TestFile'
  Assert-True ($r.Raw -match 'not found|TestFile') "unexpected error text: $($r.Raw)"
}

Case 'charter empty TestFile fails closed' {
  $root = New-TestRoot
  try {
    $empty = Join-Path $root 'empty.test.ts'
    Write-Utf8 $empty ''
    $r = Invoke-PsFile -Script $charterScript -ExtraArgs @('-TestFile', $empty)
    Assert-True ($r.ExitCode -ne 0) 'expected non-zero exit for empty TestFile'
    Assert-True ($r.Raw -match 'empty') "expected empty message: $($r.Raw)"
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- CHARTER: ImplFile embedded vs not-provided line ---
Case 'charter with ImplFile embeds impl; without has not-provided line' {
  $root = New-TestRoot
  try {
    $testFile = Join-Path $root 'calc.test.ts'
    $implFile = Join-Path $root 'calc.ts'
    Write-Utf8 $testFile "it('doubles', () => { expect(double(2)).toBe(4); });"
    Write-Utf8 $implFile "export function double(n) { return n * 2; }"
    $withImpl = Join-Path $root 'with-impl.md'
    $noImpl = Join-Path $root 'no-impl.md'
    $r1 = Invoke-PsFile -Script $charterScript -ExtraArgs @('-TestFile', $testFile, '-ImplFile', $implFile, '-OutputPath', $withImpl)
    Assert-True ($r1.ExitCode -eq 0) "with impl exit $($r1.ExitCode)"
    $p1 = [IO.File]::ReadAllText($withImpl)
    Assert-True ($p1.Contains('export function double')) 'impl body missing'
    Assert-True ($p1.Contains('BEGIN IMPL')) 'impl fence missing'
    Assert-True (-not $p1.Contains('implementation not provided')) 'should not say not provided when impl given'

    $r2 = Invoke-PsFile -Script $charterScript -ExtraArgs @('-TestFile', $testFile, '-OutputPath', $noImpl)
    Assert-True ($r2.ExitCode -eq 0) "no impl exit $($r2.ExitCode)"
    $p2 = [IO.File]::ReadAllText($noImpl)
    Assert-True ($p2.Contains('implementation not provided')) 'missing not-provided line'
    Assert-True ($p2.Contains('infer from the test')) 'missing infer phrase'
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- CHARTER: Stryker tag instruction ---
Case 'charter with StrykerReport asks for tag; without says n/a' {
  $root = New-TestRoot
  try {
    $testFile = Join-Path $root 's.test.ts'
    $stryker = Join-Path $root 'stryker.json'
    Write-Utf8 $testFile "it('ok', () => { expect(1).toBe(1); });"
    Write-Utf8 $stryker '{"files":[]}'
    $withS = Join-Path $root 'with-s.md'
    $noS = Join-Path $root 'no-s.md'
    $r1 = Invoke-PsFile -Script $charterScript -ExtraArgs @('-TestFile', $testFile, '-StrykerReport', $stryker, '-OutputPath', $withS)
    Assert-True ($r1.ExitCode -eq 0) "with stryker exit $($r1.ExitCode)"
    $p1 = [IO.File]::ReadAllText($withS)
    Assert-True ($p1 -match 'stryker:\s*killed\|survived\|unknown') 'missing killed|survived|unknown instruction'
    Assert-True ($p1.Contains('Stryker report provided')) 'missing stryker-provided line'

    $r2 = Invoke-PsFile -Script $charterScript -ExtraArgs @('-TestFile', $testFile, '-OutputPath', $noS)
    Assert-True ($r2.ExitCode -eq 0) "no stryker exit $($r2.ExitCode)"
    $p2 = [IO.File]::ReadAllText($noS)
    Assert-True ($p2.Contains('stryker: n/a')) 'missing n/a instruction'
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Case 'charter Mode json emits metadata' {
  $root = New-TestRoot
  try {
    $testFile = Join-Path $root 'j.test.ts'
    $implFile = Join-Path $root 'j.ts'
    Write-Utf8 $testFile "it('x', () => {});"
    Write-Utf8 $implFile "export const x = 1;"
    $out = Join-Path $root 'j.md'
    $r = Invoke-PsFile -Script $charterScript -ExtraArgs @('-TestFile', $testFile, '-ImplFile', $implFile, '-OutputPath', $out, '-Mode', 'json')
    Assert-True ($r.ExitCode -eq 0) "json charter exit $($r.ExitCode): $($r.Raw)"
    $obj = $r.Raw | ConvertFrom-Json
    Assert-True ($obj.has_impl -eq $true) 'has_impl should be true'
    Assert-True ($obj.has_stryker -eq $false) 'has_stryker should be false'
    Assert-True ($obj.checks.Count -eq 6) "checks count $($obj.checks.Count)"
    Assert-True (Test-Path -LiteralPath $obj.prompt_path) 'prompt_path missing on disk'
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- PARSE: well-formed PASS + REJECT ---
Case 'parse well-formed PASS + REJECT to 2 rows, summary correct, exit 0' {
  $root = New-TestRoot
  try {
    $lane = Join-Path $root 'lane.md'
    Write-Utf8 $lane @'
Some prose from the model.

===TEST-AUDIT===
test: sample.test.ts::sums two numbers
result: PASS
worst_check: none
bug_it_would_catch: none
action: keep
evidence: sample.test.ts:4
stryker: n/a
===END===

===TEST-AUDIT===
test: sample.test.ts::tautology
result: REJECT
worst_check: independent-oracle
bug_it_would_catch: expect(x).toBe(x) never fails on mutation
action: delete
evidence: sample.test.ts:12
stryker: n/a
===END===
'@
    $r = Invoke-PsFile -Script $parseScript -ExtraArgs @('-LaneOutputPath', $lane, '-Mode', 'json')
    Assert-True ($r.ExitCode -eq 0) "parse exit $($r.ExitCode) (advisory must be 0): $($r.Raw)"
    $obj = $r.Raw | ConvertFrom-Json
    Assert-True ($obj.audited -eq 2) "audited=$($obj.audited)"
    Assert-True ($obj.pass -eq 1) "pass=$($obj.pass)"
    Assert-True ($obj.reject -eq 1) "reject=$($obj.reject)"
    Assert-True ($obj.warn -eq 0) "warn=$($obj.warn)"
    Assert-True ($obj.invalid_count -eq 0) "invalid_count=$($obj.invalid_count)"
    Assert-True ($obj.summary -match 'test-audit:\s*2 audited, 1 reject, 0 warn, 1 pass, 0 invalid') "bad summary: $($obj.summary)"
    $rowList = @($obj.rows)
    Assert-True ($rowList.Count -eq 2) "rows count $($rowList.Count)"
    Assert-True ($rowList[0].result -eq 'PASS') 'first row PASS'
    Assert-True ($rowList[1].result -eq 'REJECT') 'second row REJECT'
    Assert-True ($rowList[1].action -eq 'delete') 'second action delete'
    Assert-True ($rowList[1].worst_check -eq 'independent-oracle') 'second worst_check'
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- PARSE NEGATIVE: vacuous REJECT invalid ---
Case 'parse NEGATIVE vacuous REJECT (none/none/keep) is INVALID' {
  $root = New-TestRoot
  try {
    $lane = Join-Path $root 'vacuous.md'
    Write-Utf8 $lane @'
===TEST-AUDIT===
test: bad.test.ts::noop
result: REJECT
worst_check: none
bug_it_would_catch: none
action: keep
evidence: bad.test.ts:1
stryker: n/a
===END===
'@
    $r = Invoke-PsFile -Script $parseScript -ExtraArgs @('-LaneOutputPath', $lane, '-Mode', 'json')
    Assert-True ($r.ExitCode -eq 0) "vacuous still advisory exit 0, got $($r.ExitCode)"
    $obj = $r.Raw | ConvertFrom-Json
    Assert-True ($obj.audited -eq 0) "vacuous must not count as audited: $($obj.audited)"
    Assert-True ($obj.invalid_count -eq 1) "invalid_count=$($obj.invalid_count)"
    Assert-True ($obj.reject -eq 0) 'vacuous must not count as reject'
    $inv = @($obj.invalid)
    Assert-True ($inv.Count -eq 1) 'invalid list empty'
    Assert-True ($inv[0].reason -match 'worst_check|bug_it_would_catch|REJECT') "reason: $($inv[0].reason)"
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- PARSE NEGATIVE: missing result ---
Case 'parse NEGATIVE missing result is INVALID not dropped' {
  $root = New-TestRoot
  try {
    $lane = Join-Path $root 'missing-result.md'
    Write-Utf8 $lane @'
===TEST-AUDIT===
test: bad.test.ts::no-result
worst_check: real-assertion
bug_it_would_catch: no assertion
action: delete
evidence: bad.test.ts:2
stryker: n/a
===END===
'@
    $r = Invoke-PsFile -Script $parseScript -ExtraArgs @('-LaneOutputPath', $lane, '-Mode', 'json')
    Assert-True ($r.ExitCode -eq 0) "missing-result exit $($r.ExitCode)"
    $obj = $r.Raw | ConvertFrom-Json
    Assert-True ($obj.audited -eq 0) 'missing result must not audit'
    Assert-True ($obj.invalid_count -eq 1) "invalid_count=$($obj.invalid_count)"
    $inv = @($obj.invalid)
    Assert-True ($inv.Count -eq 1) 'invalid list missing entry'
    Assert-True ($inv[0].reason -match 'missing result') "reason: $($inv[0].reason)"
    Assert-True ($null -ne $inv[0].raw -and $inv[0].raw.Contains('===TEST-AUDIT===')) 'raw block not preserved'
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- PARSE: json mode same counts as text mode ---
Case 'parse json mode counts match text mode' {
  $root = New-TestRoot
  try {
    $lane = Join-Path $root 'modes.md'
    Write-Utf8 $lane @'
===TEST-AUDIT===
test: a.test.ts::ok
result: PASS
worst_check: none
bug_it_would_catch: none
action: keep
evidence: a.test.ts:1
stryker: n/a
===END===
===TEST-AUDIT===
test: a.test.ts::weak
result: WARN
worst_check: real-assertion
bug_it_would_catch: only toBeTruthy
action: strengthen
evidence: a.test.ts:8
stryker: unknown
===END===
'@
    $rj = Invoke-PsFile -Script $parseScript -ExtraArgs @('-LaneOutputPath', $lane, '-Mode', 'json')
    $rt = Invoke-PsFile -Script $parseScript -ExtraArgs @('-LaneOutputPath', $lane, '-Mode', 'text')
    Assert-True ($rj.ExitCode -eq 0 -and $rt.ExitCode -eq 0) 'both modes exit 0'
    $obj = $rj.Raw | ConvertFrom-Json
    Assert-True ($rt.Raw.Contains($obj.summary)) "text missing summary $($obj.summary)`n---text---`n$($rt.Raw)"
    Assert-True ($obj.audited -eq 2 -and $obj.pass -eq 1 -and $obj.warn -eq 1 -and $obj.reject -eq 0) 'json counts wrong'
    Assert-True ($obj.summary -match '2 audited, 0 reject, 1 warn, 1 pass, 0 invalid') "summary: $($obj.summary)"
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Case 'parse json is valid when a verdict field carries a control char' {
  # Live defect (2026-08-07): a Grok verdict field held a raw 0x1A (SUB); PS 5.1
  # ConvertTo-Json emitted it unescaped, so every downstream json parser rejected the
  # output. The parser must sanitize control chars on capture.
  $root = New-TestRoot
  try {
    $lane = Join-Path $root 'ctrl.md'
    $sub = [char]0x1A
    $content = "===TEST-AUDIT===`ntest: a.test.ts::x`nresult: WARN`nworst_check: real-assertion`nbug_it_would_catch: rate 0.015${sub}0.01 mismatch`naction: strengthen`nevidence: a.test.ts:4`nstryker: n/a`n===END===`n"
    Write-Utf8 $lane $content
    $rj = Invoke-PsFile -Script $parseScript -ExtraArgs @('-LaneOutputPath', $lane, '-Mode', 'json')
    Assert-True ($rj.ExitCode -eq 0) 'advisory parser must exit 0'
    # No raw C0/C1 control char (except CR/LF/TAB) may survive into the JSON output.
    $bad = [regex]::Match($rj.Raw, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]')
    Assert-True (-not $bad.Success) 'raw control char leaked into JSON output'
    $obj = $rj.Raw | ConvertFrom-Json
    Assert-True ($obj.audited -eq 1 -and $obj.warn -eq 1) "counts wrong: $($rj.Raw)"
    Assert-True (-not ($obj.rows[0].bug_it_would_catch -match "$sub")) 'control char not stripped from field'
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

Case 'json output is pure ASCII (transport-safe) when a field holds a non-ASCII char' {
  # Live defect (2026-08-07): the lane's free-text held a printable non-ASCII char (a "->"
  # arrow U+2192). PS 5.1 emitted it as a raw multibyte char; a parent process re-decoding
  # the child stdout, or a non-UTF-8 `> file` redirect, corrupted it to a control byte and
  # broke every downstream JSON parser. The transport-independent guarantee: the JSON is
  # pure ASCII (every non-ASCII char escaped to \uXXXX), so ANY correct decode yields valid
  # JSON. Assert that on the in-process output (how the fleet calls it) AND that the arrow
  # round-trips as its escape.
  $root = New-TestRoot
  try {
    $arrow = [char]0x2192
    $lane = Join-Path $root 'arrow.md'
    $content = "===TEST-AUDIT===`ntest: a.test.ts::x`nresult: WARN`nworst_check: would-fail-if-mutated`nbug_it_would_catch: rate 0.015 ${arrow} 0.01 drift`naction: strengthen`nevidence: a.test.ts:4`nstryker: n/a`n===END===`n"
    Write-Utf8 $lane $content
    $r = Invoke-PsFile -Script $parseScript -ExtraArgs @('-LaneOutputPath', $lane, '-Mode', 'json')
    Assert-True ($r.ExitCode -eq 0) 'advisory parser must exit 0'
    $nonAscii = [regex]::Match($r.Raw, '[^\x09\x0A\x0D\x20-\x7E]')
    Assert-True (-not $nonAscii.Success) "non-ASCII byte in JSON output (not transport-safe): $($r.Raw)"
    Assert-True ($r.Raw.Contains('\u2192')) 'arrow was not escaped to backslash-u2192 in the JSON'
    $obj = $r.Raw | ConvertFrom-Json
    Assert-True ($obj.audited -eq 1 -and $obj.warn -eq 1) "counts wrong: $($r.Raw)"
    Assert-True ($obj.rows[0].bug_it_would_catch -match ([regex]::Escape($arrow))) 'arrow did not decode back'
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- ROUND-TRIP: fixture markers match charter contract ---
Case 'round-trip charter contract markers parse cleanly' {
  $root = New-TestRoot
  try {
    $testFile = Join-Path $root 'round.test.ts'
    Write-Utf8 $testFile @"
import { mul } from './mul';
it('multiplies', () => { expect(mul(3, 4)).toBe(12); });
it('tautology', () => { const x = mul(1, 1); expect(x).toBe(x); });
"@
    $promptPath = Join-Path $root 'charter.md'
    $cr = Invoke-PsFile -Script $charterScript -ExtraArgs @('-TestFile', $testFile, '-OutputPath', $promptPath, '-Mode', 'text')
    Assert-True ($cr.ExitCode -eq 0) "charter exit $($cr.ExitCode)"
    $prompt = [IO.File]::ReadAllText($promptPath)
    # Build lane output from the same markers the charter demands.
    Assert-True ($prompt.Contains('===TEST-AUDIT===')) 'charter must demand open marker'
    Assert-True ($prompt.Contains('===END===')) 'charter must demand close marker'
    Assert-True ($prompt.Contains('worst_check:')) 'charter must demand worst_check'
    Assert-True ($prompt.Contains('bug_it_would_catch:')) 'charter must demand bug field'
    Assert-True ($prompt.Contains('action:')) 'charter must demand action'
    Assert-True ($prompt.Contains('evidence:')) 'charter must demand evidence'
    Assert-True ($prompt.Contains('stryker:')) 'charter must demand stryker'

    $lane = Join-Path $root 'lane-out.md'
    # Construct blocks using exact field names from charter contract.
    $blockPass = @(
      '===TEST-AUDIT===',
      'test: round.test.ts::multiplies',
      'result: PASS',
      'worst_check: none',
      'bug_it_would_catch: none',
      'action: keep',
      'evidence: round.test.ts:2',
      'stryker: n/a',
      '===END==='
    ) -join "`n"
    $blockReject = @(
      '===TEST-AUDIT===',
      'test: round.test.ts::tautology',
      'result: REJECT',
      'worst_check: independent-oracle',
      'bug_it_would_catch: expected value is the subject output itself',
      'action: delete',
      'evidence: round.test.ts:3',
      'stryker: n/a',
      '===END==='
    ) -join "`n"
    Write-Utf8 $lane ($blockPass + "`n`n" + $blockReject)
    $pr = Invoke-PsFile -Script $parseScript -ExtraArgs @('-LaneOutputPath', $lane, '-Mode', 'json')
    Assert-True ($pr.ExitCode -eq 0) "parse exit $($pr.ExitCode)"
    $obj = $pr.Raw | ConvertFrom-Json
    Assert-True ($obj.audited -eq 2) "round-trip audited=$($obj.audited)"
    Assert-True ($obj.invalid_count -eq 0) "round-trip invalid=$($obj.invalid_count)"
    Assert-True ($obj.pass -eq 1 -and $obj.reject -eq 1) 'round-trip counts'
    $rowList = @($obj.rows)
    Assert-True ($rowList[0].test -eq 'round.test.ts::multiplies') 'pass test id'
    Assert-True ($rowList[1].test -eq 'round.test.ts::tautology') 'reject test id'
  }
  finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}

$total = $passed + $failed + $skipped
Write-Host ("test-audit-suite: {0} passed, {1} failed, {2} skipped, {3} total" -f $passed, $failed, $skipped, $total)
if ($failed -gt 0 -or $total -eq 0) { exit 1 }
exit 0
