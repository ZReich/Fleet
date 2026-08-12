# Compose frozen [GROK · TEST-AUDIT] charter prompt. Pure plumbing — no model call.
# Advisory lane only. Manager quotes prompt_path / json metadata.
param(
  [Parameter(Mandatory)][string]$TestFile,
  [string]$ImplFile,
  [string]$StrykerReport,
  [string]$OutputPath,
  [ValidateSet('text', 'json')][string]$Mode = 'text'
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding $false

$checkNames = @(
  'would-fail-if-mutated',
  'independent-oracle',
  'tests-subject-not-mock',
  'real-assertion',
  'deletes-duplicate',
  'boundary'
)

$fleetTerseOutputTrailer = 'OUTPUT STYLE (mandatory): terse ' + [char]0x2014 + ' drop articles, filler, pleasantries, hedging; fragments OK; technical substance exact; code, diffs, JSON, file:line references verbatim and complete. Compress prose, never evidence.'

if ([string]::IsNullOrWhiteSpace($TestFile)) {
  throw 'TestFile is required and must not be empty.'
}
if (-not (Test-Path -LiteralPath $TestFile -PathType Leaf)) {
  throw "TestFile not found or not a file: $TestFile"
}
$testText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $TestFile).Path)
if ([string]::IsNullOrWhiteSpace($testText)) {
  throw "TestFile is empty: $TestFile"
}
$resolvedTest = (Resolve-Path -LiteralPath $TestFile).Path

$hasImpl = $false
$implText = $null
$resolvedImpl = $null
if (-not [string]::IsNullOrWhiteSpace($ImplFile)) {
  if (-not (Test-Path -LiteralPath $ImplFile -PathType Leaf)) {
    throw "ImplFile not found or not a file: $ImplFile"
  }
  $resolvedImpl = (Resolve-Path -LiteralPath $ImplFile).Path
  $implText = [IO.File]::ReadAllText($resolvedImpl)
  $hasImpl = $true
}

$hasStryker = $false
if (-not [string]::IsNullOrWhiteSpace($StrykerReport)) {
  if (-not (Test-Path -LiteralPath $StrykerReport -PathType Leaf)) {
    throw "StrykerReport not found or not a file: $StrykerReport"
  }
  $hasStryker = $true
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path ([IO.Path]::GetTempPath()) ('fleet-test-audit-charter-' + [guid]::NewGuid().ToString('n') + '.md')
}
$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$rubric = @'
LOCKED 6-CHECK RUBRIC (one verdict per test/`it`/table-row):
  1. would-fail-if-mutated — name one plausible bug (flip a comparison, off-by-one, swapped
     constant, missing null). Would an assertion go red? If no concrete bug makes it fail: REJECT.
  2. independent-oracle — expected value comes from a spec/fixture/literal, NOT from calling
     the subject's own code/helpers. `expect(x).toBe(x)` or recompute-from-implementation: REJECT.
  3. tests-subject-not-mock — the module under test is REAL; only collaborators are mocked.
     `vi.mock()`/`jest.mock()` of the subject, or `toHaveBeenCalled` used as a stand-in for the
     real outcome on a pure-logic path: REJECT.
  4. real-assertion — >=1 assertion binding an outcome (return / thrown type+message / visible
     state / HTTP status+body). `toBeDefined()`/`toBeTruthy()`/"renders without throw" ALONE:
     WARN (REJECT on money/auth/PII/compliance paths).
  5. deletes-duplicate — subsumed by, or subsumes, an existing stronger test → merge/delete.
     Shrinking net test count is a desired outcome, not a regression.
  6. boundary — off-by-one / empty / null / max edges of every conditional the test touches.
'@

$outputContract = @'
STRICT OUTPUT CONTRACT — emit one block per audited test, fenced markers, machine-parseable:
===TEST-AUDIT===
test: <relative-or-given path>::<it-name or line ref>
result: PASS | WARN | REJECT
worst_check: would-fail-if-mutated | independent-oracle | tests-subject-not-mock | real-assertion | deletes-duplicate | boundary | none
bug_it_would_catch: <one line, or "none">
action: keep | strengthen | delete | merge
evidence: <file:line>
stryker: <tag>
===END===
'@

if ($hasStryker) {
  $strykerInstruction = 'Stryker report provided. Tag each block with stryker: killed|survived|unknown (mutation-backed verdict). Prefer report evidence when available; use unknown when the test is not covered by the report.'
}
else {
  $strykerInstruction = 'No Stryker report provided. Every block MUST set stryker: n/a.'
}

$implSection = if ($hasImpl) {
  "IMPLEMENTATION FILE: $resolvedImpl`n----- BEGIN IMPL -----`n$implText`n----- END IMPL -----"
}
else {
  'implementation not provided — infer from the test'
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('Adversarial Test Code Evaluator, bank-facing app; reject tests that give false confidence or waste CI.')
[void]$sb.AppendLine('')
[void]$sb.AppendLine($rubric.TrimEnd())
[void]$sb.AppendLine('')
[void]$sb.AppendLine("TEST FILE UNDER AUDIT: $resolvedTest")
[void]$sb.AppendLine('----- BEGIN TEST -----')
[void]$sb.AppendLine($testText.TrimEnd())
[void]$sb.AppendLine('----- END TEST -----')
[void]$sb.AppendLine('')
[void]$sb.AppendLine($implSection)
[void]$sb.AppendLine('')
[void]$sb.AppendLine($outputContract.TrimEnd())
[void]$sb.AppendLine('')
[void]$sb.AppendLine($strykerInstruction)
[void]$sb.AppendLine('')
[void]$sb.AppendLine($fleetTerseOutputTrailer)

$prompt = $sb.ToString()
[IO.File]::WriteAllText($OutputPath, $prompt, $utf8)
$resolvedOut = (Resolve-Path -LiteralPath $OutputPath).Path

if ($Mode -eq 'json') {
  $payload = [ordered]@{
    prompt_path = $resolvedOut
    test_file   = $resolvedTest
    impl_file   = $resolvedImpl
    has_impl    = $hasImpl
    has_stryker = $hasStryker
    checks      = @($checkNames)
  }
  Write-Output (($payload | ConvertTo-Json -Compress -Depth 4))
}
else {
  Write-Output $resolvedOut
}

exit 0
