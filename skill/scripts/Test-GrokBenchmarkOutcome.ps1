function Test-GrokBenchmarkOutcome($record, $scoreFields) {
  function Get-Score([string]$side) {
    if ($record."${side}_status" -ne "done") { return $null }
    $total = 0
    foreach ($component in $scoreFields.Keys) { $total += $record."${side}_${component}" }
    return $total
  }
  $primaryScore = Get-Score "primary"
  $grokScore = Get-Score "grok"
  $firstPassResult = $null
  if ($record.primary_status -eq "done" -and $record.grok_status -eq "done") {
    if ($record.primary_first_pass_score -gt $record.grok_first_pass_score) { $firstPassResult = "primary_win" }
    elseif ($record.grok_first_pass_score -gt $record.primary_first_pass_score) { $firstPassResult = "grok_win" }
    else { $firstPassResult = "tie" }
  }
  if ($record.comparison_mode -eq "grok_review_only") {
    if ($record.primary_self_review_passed -or $record.primary_review_seconds -ne 0 -or $record.primary_review_catches -ne 0) { throw "grok_review_only requires no primary self-review" }
    if ($record.primary_status -eq "done" -and $primaryScore -ne $record.primary_first_pass_score) { throw "Unreviewed primary final score must equal first-pass score" }
  }
  if ($record.comparison_mode -eq "both_review" -and $record.primary_status -eq "done" -and (-not $record.primary_self_review_passed -or $record.primary_review_seconds -le 0)) { throw "both_review requires primary_self_review_passed=true and primary_review_seconds greater than zero" }
  $contest = $record.result -in @("grok_win", "primary_win", "tie")
  if ($contest -and ($record.primary_status -ne "done" -or $record.grok_status -ne "done")) { throw "Contested results require both workers done" }
  if ($record.result -eq "grok_win" -and $grokScore -le $primaryScore) { throw "grok_win requires grok_score greater than primary_score" }
  if ($record.result -eq "primary_win" -and $primaryScore -le $grokScore) { throw "primary_win requires primary_score greater than grok_score" }
  if ($record.result -eq "tie" -and $primaryScore -ne $grokScore) { throw "tie requires equal scores" }
  $primaryClean = $record.primary_gate_passed -and $record.primary_scope_violations -eq 0 -and $record.primary_new_dependencies -eq 0 -and $record.primary_fallow_new_findings -eq 0 -and $record.primary_test_failures -eq 0 -and $record.primary_budget_violations -eq 0
  $grokClean = $record.grok_gate_passed -and $record.grok_scope_violations -eq 0 -and $record.grok_new_dependencies -eq 0 -and $record.grok_fallow_new_findings -eq 0 -and $record.grok_test_failures -eq 0 -and $record.grok_budget_violations -eq 0
  $expectedSelection = "none"
  if ($contest -and $primaryClean -and $grokClean) {
    if ($grokScore -gt $primaryScore) { $expectedSelection = "grok" }
    elseif ($primaryScore -gt $grokScore) { $expectedSelection = "primary" }
    elseif ($record.selected_candidate -in @("primary", "grok")) { $expectedSelection = $record.selected_candidate }
  } elseif ($contest -and $primaryClean) { $expectedSelection = "primary" }
  elseif ($contest -and $grokClean) { $expectedSelection = "grok" }
  if ($contest -and $primaryClean -and $grokClean -and $primaryScore -eq $grokScore -and $record.selected_candidate -eq "none") { throw "Clean tied candidates require primary or Grok selection" }
  if ($record.selected_candidate -ne $expectedSelection) { throw "selected_candidate must be the highest-scoring hard-gate-clean candidate, or none when neither is clean" }
  if ($record.adopted -and ($record.selected_candidate -ne "grok" -or -not $record.selected_post_review_gate_passed)) { throw "adopted=true requires a selected Grok candidate that passes final review" }
  if ($record.selected_candidate -eq "grok" -and $record.selected_post_review_gate_passed -and -not $record.adopted) { throw "Passing selected Grok candidate requires adopted=true" }
  if (-not $contest -and $record.selected_candidate -ne "none") { throw "Non-contested results require selected_candidate=none" }
  $hasSelection = $record.selected_candidate -ne "none"
  if ($hasSelection -and ($null -eq $record.selected_pre_final_review_score -or $null -eq $record.selected_post_final_review_score)) { throw "Selected candidates require pre/post final-review scores" }
  if ($hasSelection) {
    $selectedWorkerScore = if ($record.selected_candidate -eq "primary") { $primaryScore } else { $grokScore }
    if ($record.selected_pre_final_review_score -ne $selectedWorkerScore) { throw "selected_pre_final_review_score must equal the selected worker-final score" }
  }
  foreach ($component in $scoreFields.Keys) {
    $value = $record.selected_post_review_components.$component
    if ($hasSelection -and ($null -eq $value -or $value -lt 0 -or $value -gt $scoreFields[$component])) { throw "selected_post_review_components.$component must be 0-$($scoreFields[$component])" }
  }
  if ($hasSelection) {
    $postTotal = 0
    foreach ($component in $scoreFields.Keys) { $postTotal += $record.selected_post_review_components.$component }
    if ($postTotal -ne $record.selected_post_final_review_score) { throw "selected_post_final_review_score must equal selected_post_review_components sum" }
  }
  foreach ($side in @("primary", "grok")) {
    $expected = 0
    if ($record."${side}_files_changed" -gt $record.changed_files_budget) { $expected++ }
    if ($record."${side}_diff_lines" -gt $record.diff_line_budget) { $expected++ }
    if ($record."${side}_largest_source_file_lines" -gt $record.max_source_file_lines_budget) { $expected++ }
    if ($record."${side}_budget_violations" -lt $expected) { throw "${side}_budget_violations misses a line or monolith budget breach" }
  }
  if ($hasSelection) {
    $selected = $record.selected_candidate
    if ($record."${selected}_scope_violations" -gt 0 -or $record."${selected}_new_dependencies" -gt 0 -or $record."${selected}_fallow_new_findings" -gt 0 -or $record."${selected}_test_failures" -gt 0 -or $record."${selected}_budget_violations" -gt 0) { throw "Selected candidate has hard gate violations" }
  }
  if ($contest -and [string]::IsNullOrWhiteSpace($record.notes)) { throw "Contested results require notes" }
  if ($contest -and [string]::IsNullOrWhiteSpace($record.selection_rationale)) { throw "Contested results require selection_rationale" }
  if ($record.design_flag -and $record.result -ne "excluded_design") { throw "Design tasks must use excluded_design" }
  if ($record.result -eq "excluded_design" -and (-not $record.design_flag -or $record.grok_status -ne "excluded")) { throw "excluded_design requires design_flag=true and grok_status=excluded" }
  if ($record.result -eq "excluded_capability" -and $record.grok_status -ne "excluded") { throw "excluded_capability requires grok_status=excluded" }
  if ($record.result -eq "no_contest" -and $record.primary_status -eq "done" -and $record.grok_status -eq "done") { throw "no_contest requires at least one incomplete worker" }
  if ($record.result -in @("no_contest", "excluded_design", "excluded_capability") -and [string]::IsNullOrWhiteSpace($record.exclusion_reason)) { throw "Non-contested and excluded results require exclusion_reason" }
  if (-not $hasSelection) {
    if ($null -ne $record.selected_pre_final_review_score -or $null -ne $record.selected_post_final_review_score -or $record.final_review_seconds -ne 0 -or $record.final_review_catches_total -ne 0 -or $record.selected_post_review_gate_passed) { throw "Non-contested results cannot report selected-candidate final-review outcomes" }
    foreach ($component in $scoreFields.Keys) { if ($null -ne $record.selected_post_review_components.$component) { throw "Non-contested results require null selected_post_review_components" } }
  }
  return [pscustomobject]@{ primary_score = $primaryScore; grok_score = $grokScore; first_pass_result = $firstPassResult }
}
