function Test-GrokBenchmarkRecord($record, [string[]]$required) {
  foreach ($name in $required) {
    if ($record.PSObject.Properties.Name -notcontains $name) { throw "Missing required field: $name" }
  }

  if ($record.primary_status -notin @("done", "partial", "blocked", "timeout", "outage", "excluded") -or $record.grok_status -notin @("done", "partial", "blocked", "timeout", "outage", "excluded")) { throw "Invalid status" }
  if ($record.result -notin @("grok_win", "primary_win", "tie", "no_contest", "excluded_design", "excluded_capability")) { throw "Invalid result" }
  if ($record.task_type -notin @("implementation", "fix", "refactor", "migration", "test", "debug", "analysis", "research", "review", "browser", "design") -or $record.task_complexity -notin @("mechanical", "standard", "hard", "review")) { throw "Invalid task_type or task_complexity" }
  if ($record.comparison_mode -notin @("grok_review_only", "both_review")) { throw "Invalid comparison_mode" }
  if ($record.primary_effort -notin @("low", "medium", "high", "xhigh", "max", "n/a") -or $record.grok_effort -notin @("low", "medium", "high", "xhigh", "max", "n/a") -or $record.grok_review_effort -notin @("low", "medium", "high", "xhigh", "max", "n/a")) { throw "Invalid effort" }
  if ($record.effort_variant -notin @("none", "high", "xhigh") -or $record.selected_candidate -notin @("primary", "grok", "none")) { throw "Invalid effort_variant or selected_candidate" }
  if ($record.adopted -isnot [bool] -or $record.design_flag -isnot [bool] -or $record.primary_self_review_passed -isnot [bool] -or $record.grok_self_review_passed -isnot [bool] -or $record.primary_gate_passed -isnot [bool] -or $record.grok_gate_passed -isnot [bool] -or $record.selected_post_review_gate_passed -isnot [bool]) { throw "adopted, design_flag, self-review, and gate fields must be JSON booleans" }
  foreach ($name in @("primary_charter_sha256", "grok_charter_sha256", "context_sha256", "grok_config_sha256")) {
    if ($record.$name -notmatch '^[a-fA-F0-9]{64}$') { throw "$name must be 64 hexadecimal characters" }
  }
  if ($record.primary_charter_sha256 -ne $record.grok_charter_sha256) { throw "Primary and Grok charter hashes must match" }
  if ([string]::IsNullOrWhiteSpace($record.blind_grader)) { throw "blind_grader is required" }

  foreach ($name in @(
    "primary_retries", "grok_retries", "unique_grok_catches", "primary_files_changed", "grok_files_changed",
    "primary_review_catches", "grok_review_catches", "primary_diff_lines", "grok_diff_lines",
    "primary_scope_violations", "grok_scope_violations", "primary_new_dependencies", "grok_new_dependencies",
    "primary_fallow_new_findings", "grok_fallow_new_findings", "primary_test_failures", "grok_test_failures",
    "changed_files_budget", "diff_line_budget", "max_source_file_lines_budget", "primary_largest_source_file_lines",
    "grok_largest_source_file_lines", "primary_budget_violations", "grok_budget_violations", "final_review_catches_total"
  )) {
    $value = $record.$name
    if (($value -isnot [long] -and $value -isnot [int]) -or $value -lt 0) { throw "$name must be a non-negative integer" }
  }
  foreach ($name in @("primary_first_pass_score", "grok_first_pass_score", "selected_pre_final_review_score", "selected_post_final_review_score")) {
    $value = $record.$name
    if ($null -ne $value -and ($value -lt 0 -or $value -gt 100)) { throw "$name must be null or 0-100" }
  }

  $scoreFields = [ordered]@{ correctness = 40; spec = 25; tests = 15; maintainability = 10; scope = 10 }
  foreach ($side in @("primary", "grok")) {
    foreach ($component in $scoreFields.Keys) {
      $name = "${side}_${component}"
      $value = $record.$name
      if ($null -ne $value -and ($value -lt 0 -or $value -gt $scoreFields[$component])) { throw "$name must be null or 0-$($scoreFields[$component])" }
      if ($record."${side}_status" -eq "done" -and $null -eq $value) { throw "Completed $side requires $name" }
      $firstPassValue = $record."${side}_first_pass_components".$component
      if ($record."${side}_status" -eq "done" -and ($null -eq $firstPassValue -or $firstPassValue -lt 0 -or $firstPassValue -gt $scoreFields[$component])) { throw "Completed $side requires ${side}_first_pass_components.$component in range" }
    }
    if ($record."${side}_status" -eq "done") {
      $total = 0
      foreach ($component in $scoreFields.Keys) { $total += $record."${side}_first_pass_components".$component }
      if ($total -ne $record."${side}_first_pass_score") { throw "${side}_first_pass_score must equal ${side}_first_pass_components sum" }
    }
  }
  foreach ($seconds in @($record.primary_seconds, $record.grok_seconds)) { if ($null -ne $seconds -and $seconds -lt 0) { throw "Durations must be null or non-negative" } }
  foreach ($name in @("primary_review_seconds", "grok_review_seconds")) { if ($null -ne $record.$name -and $record.$name -lt 0) { throw "$name must be null or non-negative" } }
  if (($record.final_review_seconds -isnot [long] -and $record.final_review_seconds -isnot [int] -and $record.final_review_seconds -isnot [double]) -or $record.final_review_seconds -lt 0) { throw "final_review_seconds must be non-negative" }
  foreach ($name in @("sol", "terra", "glm", "grok", "opus")) {
    $value = $record.final_review_catches_by_model.$name
    if (($value -isnot [long] -and $value -isnot [int]) -or $value -lt 0) { throw "final_review_catches_by_model.$name must be a non-negative integer" }
    $status = $record.final_review_execution_status_by_model.$name
    if ($status -notin @("complete", "outage", "excluded", "no_contest", "invalid")) { throw "final_review_execution_status_by_model.$name is invalid" }
    if ($status -ne "complete" -and [string]::IsNullOrWhiteSpace($record.final_review_exclusion_reason_by_model.$name)) { throw "final_review_exclusion_reason_by_model.$name is required when review is not complete" }
    $wall = $record.final_review_wall_seconds_by_model.$name
    if (($wall -isnot [long] -and $wall -isnot [int] -and $wall -isnot [double]) -or $wall -lt 0) { throw "final_review_wall_seconds_by_model.$name must be non-negative" }
    foreach ($metric in @("final_review_unique_catches_by_model", "final_review_false_positives_by_model", "final_review_adopted_findings_by_model")) {
      $metricValue = $record.$metric.$name
      if (($metricValue -isnot [long] -and $metricValue -isnot [int]) -or $metricValue -lt 0) { throw "$metric.$name must be a non-negative integer" }
    }
  }
  if ($record.final_review_catches_total -ne ($record.final_review_catches_by_model.sol + $record.final_review_catches_by_model.terra + $record.final_review_catches_by_model.glm + $record.final_review_catches_by_model.grok + $record.final_review_catches_by_model.opus)) { throw "final_review_catches_total must equal final_review_catches_by_model sum" }
  if ($record.primary_status -eq "done" -and ($null -eq $record.primary_seconds -or $null -eq $record.primary_first_pass_score)) { throw "Completed primary requires duration and first-pass score" }
  if ($record.grok_status -eq "done" -and ($null -eq $record.grok_seconds -or $null -eq $record.grok_first_pass_score -or -not $record.grok_self_review_passed)) { throw "Completed Grok shadow requires duration, first-pass score, and passing self-review" }
  if ($record.grok_status -eq "done" -and $record.grok_model -ne "grok-4.6") { throw "Completed Grok shadow requires grok_model=grok-4.6" }
  if ($record.grok_status -eq "done" -and $record.grok_effort -ne "high") { throw "Completed Grok first pass requires effective effort high; xhigh is currently unsupported" }
  # high is the current convention (the CLI dropped xhigh/max; the wrapper collapses both
  # to high). "max" stays accepted so the 11 pre-2026-07 rows still validate.
  if ($record.grok_status -eq "done" -and $record.grok_review_effort -notin @("high", "max")) { throw "Completed Grok self-review requires grok_review_effort=high (legacy rows may carry max)" }
  if ($record.grok_status -eq "done" -and ([string]::IsNullOrWhiteSpace($record.grok_first_pass_session_id) -or [string]::IsNullOrWhiteSpace($record.grok_review_session_id))) { throw "Completed Grok shadow requires separate first-pass and review session IDs" }
  if ($record.grok_status -eq "done" -and $record.grok_first_pass_session_id -eq $record.grok_review_session_id) { throw "First-pass and review session IDs must differ" }
  if ($record.effort_variant -ne "none" -and [string]::IsNullOrWhiteSpace($record.effort_experiment_id)) { throw "Effort variants require effort_experiment_id" }
  if ($record.effort_variant -ne "none" -and $record.effort_variant -ne $record.grok_effort) { throw "effort_variant must match grok_effort" }
  if ($record.effort_variant -eq "xhigh" -or $record.grok_effort -eq "xhigh") { throw "xhigh is currently unsupported as a distinct Grok effort" }
  if ($record.grok_status -eq "done" -and ([string]::IsNullOrWhiteSpace($record.notes) -or $record.grok_review_seconds -le 0)) { throw "Completed Grok shadow requires self-review notes and positive grok_review_seconds" }
  if ($record.grok_status -eq "done" -and ([string]::IsNullOrWhiteSpace($record.grok_retest_command) -or [string]::IsNullOrWhiteSpace($record.grok_retest_result))) { throw "Completed Grok shadow requires retest command and result evidence" }
  foreach ($side in @("primary", "grok")) {
    if ($record."${side}_gate_passed" -and ($record."${side}_scope_violations" -gt 0 -or $record."${side}_new_dependencies" -gt 0 -or $record."${side}_fallow_new_findings" -gt 0 -or $record."${side}_test_failures" -gt 0 -or $record."${side}_budget_violations" -gt 0)) { throw "${side}_gate_passed cannot be true with hard-gate violations" }
  }
  if ($record.primary_status -eq "done" -and $record.primary_review_seconds -gt $record.primary_seconds) { throw "primary_review_seconds cannot exceed primary_seconds" }
  if ($record.grok_status -eq "done" -and $record.grok_review_seconds -gt $record.grok_seconds) { throw "grok_review_seconds cannot exceed grok_seconds" }
  return $scoreFields
}
