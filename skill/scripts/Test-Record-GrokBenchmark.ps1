param()

$ErrorActionPreference = "Stop"
$recorder = Join-Path $PSScriptRoot "Record-GrokBenchmark.ps1"
$utf8 = [Text.UTF8Encoding]::new($false)

function New-Telemetry {
  [pscustomobject]@{
    status = "unavailable"; source = "unavailable"; session_id = ""; parse_errors = 0
    input_tokens = $null; cached_input_tokens = $null; output_tokens = $null; reasoning_tokens = $null
    total_tokens = $null; inference_ms = $null; ttft_ms_p50 = $null; output_tokens_per_second = $null
    attempts = $null; tool_calls = $null; tool_failures = $null; actual_cost_usd = $null
    actual_cost_source = "not_exposed"; api_equivalent_cost_usd_upper_bound = $null; api_rate_card = ""
    energy_kwh = $null; energy_source = "provider_not_exposed"; energy_method = "unavailable"; hardware = $null
    provider_region = $null; pue = $null; measurement_window_start_utc = $null; measurement_window_end_utc = $null
    measured_at_utc = $null; carbon_gco2e = $null; carbon_source = "requires measured energy"
    carbon_method = "unavailable"; grid_intensity_gco2e_per_kwh = $null; grid_intensity_source = $null
  }
}

function Copy-Record($record) { $record | ConvertTo-Json -Depth 10 | ConvertFrom-Json }
function Write-Record($record, [string]$path) { [IO.File]::WriteAllText($path, ($record | ConvertTo-Json -Depth 10), $utf8) }
function Assert-Rejected($record, [string]$expected, [string]$name, [string]$temp, [string]$log) {
  $input = Join-Path $temp "$name.json"
  Write-Record $record $input
  try {
    & $recorder -RecordPath $input -OutputPath (Join-Path $temp "$name.jsonl") -GrokLogPath $log
    throw "$name accepted"
  } catch {
    if ($_.Exception.Message -notmatch $expected) { throw }
  }
}

$telemetry = New-Telemetry
$primaryComponents = [pscustomobject]@{ correctness = 40; spec = 25; tests = 15; maintainability = 5; scope = 5 }
$grokFirstComponents = [pscustomobject]@{ correctness = 35; spec = 20; tests = 10; maintainability = 5; scope = 5 }
$grokFinalComponents = [pscustomobject]@{ correctness = 38; spec = 22; tests = 10; maintainability = 5; scope = 5 }
$base = [pscustomobject][ordered]@{
  run_id = "synthetic-run"; repo = "synthetic/repo"; base_sha = "abc123"; task_id = "task-1"
  task_type = "implementation"; task_complexity = "standard"; comparison_mode = "grok_review_only"
  design_flag = $false; primary_charter_sha256 = ("a" * 64); grok_charter_sha256 = ("a" * 64)
  context_sha256 = ("b" * 64); blind_grader = "synthetic-grader"; primary_model = "gpt-5.5"
  primary_effort = "high"; primary_status = "done"; grok_model = "grok-4.6"; grok_effort = "high"
  grok_review_effort = "high"; grok_status = "done"; result = "primary_win"; adopted = $false
  primary_seconds = 100; grok_seconds = 120; primary_correctness = 40; grok_correctness = 38
  primary_spec = 25; grok_spec = 22; primary_tests = 15; grok_tests = 10
  primary_maintainability = 5; grok_maintainability = 5; primary_scope = 5; grok_scope = 5
  primary_files_changed = 2; grok_files_changed = 2; primary_retries = 0; grok_retries = 0
  primary_first_pass_score = 90; grok_first_pass_score = 75
  primary_first_pass_components = $primaryComponents; grok_first_pass_components = $grokFirstComponents
  primary_review_seconds = 0; grok_review_seconds = 20; primary_review_catches = 0; grok_review_catches = 2
  primary_self_review_passed = $false; grok_self_review_passed = $true; unique_grok_catches = 2
  primary_gate_passed = $true; grok_gate_passed = $true; grok_retest_command = "synthetic-test"
  grok_retest_result = "pass"; selection_rationale = "Primary scored higher"; exclusion_reason = ""; notes = "Synthetic review"
  grok_first_pass_session_id = "session-first"; grok_review_session_id = "session-review"; grok_config_sha256 = ("c" * 64)
  effort_experiment_id = ""; effort_variant = "none"; effort_escalation_reason = ""
  primary_diff_lines = 20; grok_diff_lines = 20; primary_scope_violations = 0; grok_scope_violations = 0
  primary_new_dependencies = 0; grok_new_dependencies = 0; primary_fallow_new_findings = 0; grok_fallow_new_findings = 0
  primary_test_failures = 0; grok_test_failures = 0; changed_files_budget = 3; diff_line_budget = 100
  max_source_file_lines_budget = 300; primary_largest_source_file_lines = 100; grok_largest_source_file_lines = 100
  primary_budget_violations = 0; grok_budget_violations = 0; selected_candidate = "primary"
  selected_pre_final_review_score = 90; selected_post_final_review_score = 90
  selected_post_review_components = $primaryComponents; final_review_seconds = 5; final_review_catches_total = 0
  final_review_catches_by_model = [pscustomobject]@{ sol = 0; terra = 0; glm = 0; grok = 0; opus = 0 }
  final_review_execution_status_by_model = [pscustomobject]@{ sol = "complete"; terra = "complete"; glm = "complete"; grok = "complete"; opus = "complete" }
  final_review_exclusion_reason_by_model = [pscustomobject]@{ sol = ""; terra = ""; glm = ""; grok = ""; opus = "" }
  final_review_wall_seconds_by_model = [pscustomobject]@{ sol = 1; terra = 1; glm = 1; grok = 1; opus = 1 }
  final_review_unique_catches_by_model = [pscustomobject]@{ sol = 0; terra = 0; glm = 0; grok = 0; opus = 0 }
  final_review_false_positives_by_model = [pscustomobject]@{ sol = 0; terra = 0; glm = 0; grok = 0; opus = 0 }
  final_review_adopted_findings_by_model = [pscustomobject]@{ sol = 0; terra = 0; glm = 0; grok = 0; opus = 0 }
  selected_post_review_gate_passed = $true; primary_first_pass_telemetry = $telemetry; primary_review_telemetry = $telemetry
  final_review_telemetry_by_model = [pscustomobject]@{ sol = $telemetry; terra = $telemetry; glm = $telemetry; grok = $telemetry; opus = $telemetry }
}

$temp = Join-Path $env:TEMP ("fleet-benchmark-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
  $log = Join-Path $temp "grok.jsonl"
  $events = @(
    [pscustomobject]@{ sid = "session-first"; msg = "shell.turn.inference_done"; ctx = [pscustomobject]@{ prompt_tokens = 100; cached_prompt_tokens = 20; completion_tokens = 30; reasoning_tokens = 40; model_elapsed_ms = 2000; ttft_ms = 100; attempts = 1 } },
    [pscustomobject]@{ sid = "session-first"; msg = "shell.tool.exec_done"; ctx = [pscustomobject]@{ success = $true } },
    [pscustomobject]@{ sid = "session-review"; msg = "shell.turn.inference_done"; ctx = [pscustomobject]@{ prompt_tokens = 50; cached_prompt_tokens = 10; completion_tokens = 15; reasoning_tokens = 20; model_elapsed_ms = 1000; ttft_ms = 80; attempts = 1 } },
    [pscustomobject]@{ sid = "session-missing"; msg = "shell.turn.inference_done"; ctx = [pscustomobject]@{ prompt_tokens = 50; cached_prompt_tokens = 10; reasoning_tokens = 20; model_elapsed_ms = 1000; ttft_ms = 80; attempts = 1 } }
  )
  [IO.File]::WriteAllLines($log, @($events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }), $utf8)

  $input = Join-Path $temp "valid.json"
  $output = Join-Path $temp "ledger.jsonl"
  Write-Record $base $input
  & $recorder -RecordPath $input -OutputPath $output -GrokLogPath $log
  $saved = [IO.File]::ReadAllText($output, $utf8) | ConvertFrom-Json
  if ($saved.schema_version -ne 7 -or $saved.phase_telemetry.grok_first_pass.status -ne "complete" -or $saved.phase_telemetry.grok_review.status -ne "complete") { throw "Valid v7 telemetry append failed" }
  if ($saved.phase_telemetry.final_review.opus -isnot [pscustomobject] -or $saved.final_review_execution_status_by_model.opus -ne "complete") { throw "Nested five-voice telemetry was not preserved" }
  if ($saved.phase_telemetry.grok_first_pass.total_tokens -ne 130 -or $saved.phase_telemetry.grok_first_pass.reasoning_tokens -ne 40 -or $saved.phase_telemetry.grok_first_pass.api_equivalent_cost_usd_upper_bound -ne 0.00062) { throw "Token or cost telemetry calculation failed" }
  try { & $recorder -RecordPath $input -OutputPath $output -GrokLogPath $log; throw "Duplicate accepted" } catch { if ($_.Exception.Message -notmatch "Duplicate benchmark") { throw } }

  $case = Copy-Record $base
  $case.run_id = "opus-outage"; $case.final_review_execution_status_by_model.opus = "outage"
  $case.final_review_exclusion_reason_by_model.opus = "Claude unavailable"
  Write-Record $case $input
  & $recorder -RecordPath $input -OutputPath (Join-Path $temp "opus-outage.jsonl") -GrokLogPath $log

  $case = Copy-Record $base
  $case.run_id = "opus-outage-no-reason"; $case.final_review_execution_status_by_model.opus = "outage"
  Assert-Rejected $case "final_review_exclusion_reason_by_model.opus" "opus-outage-no-reason" $temp $log

  $case = Copy-Record $base
  $case.run_id = "opus-invalid-status"; $case.final_review_execution_status_by_model.opus = "maybe"
  Assert-Rejected $case "final_review_execution_status_by_model.opus" "opus-invalid-status" $temp $log

  $case = Copy-Record $base
  $case.run_id = "opus-negative-false-positive"; $case.final_review_false_positives_by_model.opus = -1
  Assert-Rejected $case "final_review_false_positives_by_model.opus" "opus-negative-false-positive" $temp $log

  $case = Copy-Record $base
  $case.run_id = "xhigh"; $case.grok_effort = "xhigh"
  Assert-Rejected $case "xhigh is currently unsupported" "xhigh" $temp $log

  $case = Copy-Record $base
  $case.run_id = "no-contest"; $case.result = "no_contest"; $case.grok_status = "partial"; $case.selected_candidate = "none"; $case.exclusion_reason = "worker incomplete"
  Assert-Rejected $case "cannot report selected-candidate final-review outcomes" "no-contest" $temp $log

  $case.selected_pre_final_review_score = $null; $case.selected_post_final_review_score = $null
  foreach ($name in @("correctness", "spec", "tests", "maintainability", "scope")) { $case.selected_post_review_components.$name = $null }
  $case.final_review_seconds = 0; $case.final_review_catches_total = 0; $case.selected_post_review_gate_passed = $false
  Write-Record $case $input
  & $recorder -RecordPath $input -OutputPath (Join-Path $temp "valid-no-contest.jsonl") -GrokLogPath $log

  $case = Copy-Record $base
  $case.run_id = "hard-gate"; $case.primary_scope_violations = 1; $case.primary_gate_passed = $false
  Assert-Rejected $case "highest-scoring hard-gate-clean" "hard-gate" $temp $log

  $case = Copy-Record $base
  $case.run_id = "wrong-selected-pre"; $case.selected_pre_final_review_score = 89
  Assert-Rejected $case "selected worker-final score" "wrong-selected-pre" $temp $log

  $case = Copy-Record $base
  $case.run_id = "lower-clean-selection"; $case.selected_candidate = "grok"; $case.adopted = $true
  $case.selected_pre_final_review_score = 80; $case.selected_post_final_review_score = 80; $case.selected_post_review_components = $grokFinalComponents
  Assert-Rejected $case "highest-scoring hard-gate-clean" "lower-clean-selection" $temp $log

  $case = Copy-Record $base
  $case.run_id = "winner-swap"; $case.primary_scope_violations = 1; $case.primary_gate_passed = $false
  $case.selected_candidate = "grok"; $case.adopted = $true; $case.selected_pre_final_review_score = 80
  $case.selected_post_final_review_score = 80; $case.selected_post_review_components = $grokFinalComponents
  Write-Record $case $input
  & $recorder -RecordPath $input -OutputPath (Join-Path $temp "winner-swap.jsonl") -GrokLogPath $log

  $case = Copy-Record $base
  $case.run_id = "both-dirty"; $case.primary_scope_violations = 1; $case.grok_scope_violations = 1
  $case.primary_gate_passed = $false; $case.grok_gate_passed = $false; $case.selected_candidate = "none"
  $case.selected_pre_final_review_score = $null; $case.selected_post_final_review_score = $null
  foreach ($name in @("correctness", "spec", "tests", "maintainability", "scope")) { $case.selected_post_review_components.$name = $null }
  $case.final_review_seconds = 0; $case.selected_post_review_gate_passed = $false
  Write-Record $case $input
  & $recorder -RecordPath $input -OutputPath (Join-Path $temp "both-dirty.jsonl") -GrokLogPath $log

  $case = Copy-Record $base
  $case.run_id = "failed-final-review"; $case.selected_post_review_gate_passed = $false
  Write-Record $case $input
  & $recorder -RecordPath $input -OutputPath (Join-Path $temp "failed-final-review.jsonl") -GrokLogPath $log

  $case = Copy-Record $base
  $case.run_id = "provenance"; $case.primary_first_pass_telemetry.actual_cost_usd = 1; $case.primary_first_pass_telemetry.actual_cost_source = "not_exposed"
  Assert-Rejected $case "actual cost requires an available source" "provenance" $temp $log

  $case = Copy-Record $base
  $case.run_id = "energy-provenance"; $case.primary_first_pass_telemetry.energy_kwh = 0.1
  Assert-Rejected $case "energy requires available" "energy-provenance" $temp $log

  $case = Copy-Record $base
  $case.run_id = "partial"; $case.grok_first_pass_session_id = "session-missing"
  Write-Record $case $input
  & $recorder -RecordPath $input -OutputPath (Join-Path $temp "partial.jsonl") -GrokLogPath $log
  $partial = [IO.File]::ReadAllText((Join-Path $temp "partial.jsonl"), $utf8) | ConvertFrom-Json
  if ($partial.phase_telemetry.grok_first_pass.status -ne "partial" -or $partial.phase_telemetry.grok_first_pass.source -ne "grok_unified_log_missing_fields") { throw "Missing-token telemetry was not marked partial" }

  "PASS: v7 append, duplicate, xhigh, no-contest, gate selection, failed final review, token/cost, provenance, partial telemetry"
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force
}
