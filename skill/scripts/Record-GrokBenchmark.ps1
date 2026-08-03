param(
  [Parameter(Mandatory = $true)]
  [string]$RecordPath,
  [string]$OutputPath,
  [string]$GrokLogPath = (Join-Path $HOME ".grok\logs\unified.jsonl")
)

$ErrorActionPreference = "Stop"
# PS 5.1 leaves $PSScriptRoot EMPTY in param defaults, so the ledger default threw
# "Cannot bind argument to parameter 'Path'" on every call that omitted -OutputPath.
# $HOME above is fine - it is an ordinary variable, not a script-scope automatic.
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot "..\BENCH-grok45.jsonl" }
$utf8 = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot "Test-GrokBenchmarkRecord.ps1")
. (Join-Path $PSScriptRoot "Test-GrokBenchmarkOutcome.ps1")
. (Join-Path $PSScriptRoot "Get-GrokBenchmarkTelemetry.ps1")

$record = [IO.File]::ReadAllText([IO.Path]::GetFullPath($RecordPath), $utf8) | ConvertFrom-Json
$required = @(
  "run_id", "repo", "base_sha", "task_id", "task_type", "task_complexity", "comparison_mode",
  "design_flag", "primary_charter_sha256", "grok_charter_sha256", "context_sha256", "blind_grader", "primary_model",
  "primary_effort", "primary_status", "grok_model", "grok_effort", "grok_review_effort", "grok_status",
  "result", "adopted", "primary_seconds", "grok_seconds", "primary_correctness", "grok_correctness",
  "primary_spec", "grok_spec", "primary_tests", "grok_tests", "primary_maintainability", "grok_maintainability",
  "primary_scope", "grok_scope", "primary_files_changed", "grok_files_changed", "primary_retries", "grok_retries",
  "primary_first_pass_score", "grok_first_pass_score", "primary_first_pass_components", "grok_first_pass_components",
  "primary_review_seconds", "grok_review_seconds", "primary_review_catches", "grok_review_catches",
  "primary_self_review_passed", "grok_self_review_passed", "unique_grok_catches", "primary_gate_passed", "grok_gate_passed",
  "grok_retest_command", "grok_retest_result", "selection_rationale", "exclusion_reason", "notes",
  "grok_first_pass_session_id", "grok_review_session_id", "grok_config_sha256", "effort_experiment_id", "effort_variant",
  "effort_escalation_reason", "primary_diff_lines", "grok_diff_lines", "primary_scope_violations", "grok_scope_violations",
  "primary_new_dependencies", "grok_new_dependencies", "primary_fallow_new_findings", "grok_fallow_new_findings",
  "primary_test_failures", "grok_test_failures", "changed_files_budget", "diff_line_budget", "max_source_file_lines_budget",
  "primary_largest_source_file_lines", "grok_largest_source_file_lines", "primary_budget_violations", "grok_budget_violations",
  "selected_candidate", "selected_pre_final_review_score", "selected_post_final_review_score", "selected_post_review_components",
  "final_review_seconds", "final_review_catches_total", "final_review_catches_by_model",
  "final_review_execution_status_by_model", "final_review_exclusion_reason_by_model",
  "final_review_wall_seconds_by_model", "final_review_unique_catches_by_model",
  "final_review_false_positives_by_model", "final_review_adopted_findings_by_model",
  "selected_post_review_gate_passed",
  "primary_first_pass_telemetry", "primary_review_telemetry", "final_review_telemetry_by_model"
)

$scoreFields = Test-GrokBenchmarkRecord $record $required
$outcome = Test-GrokBenchmarkOutcome $record $scoreFields
Test-GrokBenchmarkTelemetry $record.primary_first_pass_telemetry "primary_first_pass_telemetry"
Test-GrokBenchmarkTelemetry $record.primary_review_telemetry "primary_review_telemetry"
foreach ($name in @("sol", "terra", "glm", "grok", "opus")) {
  Test-GrokBenchmarkTelemetry $record.final_review_telemetry_by_model.$name "final_review_telemetry_by_model.$name"
}
$grokFirstPassTelemetry = Get-GrokBenchmarkTelemetry $record.grok_first_pass_session_id $GrokLogPath $utf8
$grokReviewTelemetry = Get-GrokBenchmarkTelemetry $record.grok_review_session_id $GrokLogPath $utf8
Test-GrokBenchmarkTelemetry $grokFirstPassTelemetry "grok_first_pass_telemetry"
Test-GrokBenchmarkTelemetry $grokReviewTelemetry "grok_review_telemetry"

$canonical = [ordered]@{ schema_version = 7; timestamp_utc = (Get-Date).ToUniversalTime().ToString("o") }
foreach ($name in $required | Where-Object { $_ -notin @("primary_first_pass_telemetry", "primary_review_telemetry", "final_review_telemetry_by_model") }) { $canonical[$name] = $record.$name }
$canonical["primary_score"] = $outcome.primary_score
$canonical["grok_score"] = $outcome.grok_score
$canonical["first_pass_result"] = $outcome.first_pass_result
$canonical["phase_telemetry"] = [ordered]@{
  primary_first_pass = $record.primary_first_pass_telemetry
  primary_review = $record.primary_review_telemetry
  grok_first_pass = $grokFirstPassTelemetry
  grok_review = $grokReviewTelemetry
  final_review = $record.final_review_telemetry_by_model
}

$directory = Split-Path -Parent $OutputPath
if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
$fullPath = [IO.Path]::GetFullPath($OutputPath)
$sha = [Security.Cryptography.SHA256]::Create()
try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath))).Replace("-", "").Substring(0, 24) } finally { $sha.Dispose() }
$mutex = [Threading.Mutex]::new($false, "Global\CodexFleetGrokBenchmark-$hash")
try {
  if (-not $mutex.WaitOne(30000)) { throw "Timed out waiting for benchmark ledger lock" }
  if (Test-Path -LiteralPath $fullPath) {
    foreach ($line in [IO.File]::ReadAllLines($fullPath, $utf8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $existing = $line | ConvertFrom-Json
      if ($existing.run_id -eq $record.run_id -and $existing.task_id -eq $record.task_id) { throw "Duplicate benchmark record: $($record.run_id)/$($record.task_id)" }
    }
  }
  [IO.File]::AppendAllText($fullPath, ([pscustomobject]$canonical | ConvertTo-Json -Depth 12 -Compress) + [Environment]::NewLine, $utf8)
} finally {
  try { $mutex.ReleaseMutex() } catch { }
  $mutex.Dispose()
}
