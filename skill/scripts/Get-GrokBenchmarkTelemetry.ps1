function Get-Median($values) {
  $items = @($values | Where-Object { $null -ne $_ } | Sort-Object)
  if ($items.Count -eq 0) { return $null }
  $middle = [math]::Floor($items.Count / 2)
  if ($items.Count % 2) { return $items[$middle] }
  return ($items[$middle - 1] + $items[$middle]) / 2
}

function Read-SharedTextLines([string]$path, [Text.Encoding]$encoding) {
  $stream = [IO.File]::Open([IO.Path]::GetFullPath($path), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    $reader = [IO.StreamReader]::new($stream, $encoding, $true)
    try { while (-not $reader.EndOfStream) { $reader.ReadLine() } } finally { $reader.Dispose() }
  } finally { $stream.Dispose() }
}

$script:TelemetryFields = @(
  "status", "source", "session_id", "parse_errors", "input_tokens", "cached_input_tokens", "output_tokens",
  "reasoning_tokens", "total_tokens", "inference_ms", "ttft_ms_p50", "output_tokens_per_second", "attempts",
  "tool_calls", "tool_failures", "actual_cost_usd", "actual_cost_source", "api_equivalent_cost_usd_upper_bound",
  "api_rate_card", "energy_kwh", "energy_source", "energy_method", "hardware", "provider_region", "pue",
  "measurement_window_start_utc", "measurement_window_end_utc", "measured_at_utc", "carbon_gco2e",
  "carbon_source", "carbon_method", "grid_intensity_gco2e_per_kwh", "grid_intensity_source"
)

function Test-GrokBenchmarkTelemetry($telemetry, [string]$label) {
  foreach ($name in $script:TelemetryFields) {
    if ($telemetry.PSObject.Properties.Name -notcontains $name) { throw "$label missing field: $name" }
  }
  if ($telemetry.status -notin @("complete", "partial", "unavailable") -or [string]::IsNullOrWhiteSpace($telemetry.source)) { throw "$label has invalid status or source" }
  $coreMetrics = @("input_tokens", "cached_input_tokens", "output_tokens", "reasoning_tokens", "total_tokens", "inference_ms", "ttft_ms_p50", "output_tokens_per_second", "attempts", "tool_calls", "tool_failures")
  foreach ($name in $coreMetrics + @("actual_cost_usd", "api_equivalent_cost_usd_upper_bound", "energy_kwh", "pue", "carbon_gco2e", "grid_intensity_gco2e_per_kwh", "parse_errors")) {
    if ($null -ne $telemetry.$name -and $telemetry.$name -lt 0) { throw "$label.$name must be null or non-negative" }
  }
  if ($telemetry.status -eq "complete" -and @($coreMetrics | Where-Object { $null -eq $telemetry.$_ }).Count -gt 0) { throw "$label complete status requires all core metrics" }
  if ($telemetry.status -eq "unavailable" -and @($coreMetrics | Where-Object { $null -ne $telemetry.$_ }).Count -gt 0) { throw "$label unavailable status cannot carry core metrics" }
  if ($null -ne $telemetry.total_tokens -and $telemetry.total_tokens -ne ($telemetry.input_tokens + $telemetry.output_tokens)) { throw "$label.total_tokens must equal observed input plus completion tokens; reasoning stays separate" }
  if ($null -ne $telemetry.actual_cost_usd -and ([string]::IsNullOrWhiteSpace($telemetry.actual_cost_source) -or $telemetry.actual_cost_source -match "not_exposed|unavailable")) { throw "$label actual cost requires an available source" }
  if ($null -ne $telemetry.api_equivalent_cost_usd_upper_bound -and [string]::IsNullOrWhiteSpace($telemetry.api_rate_card)) { throw "$label API-equivalent cost requires a rate card" }
  if ($null -ne $telemetry.energy_kwh) {
    foreach ($name in @("energy_source", "energy_method", "hardware", "provider_region", "measurement_window_start_utc", "measurement_window_end_utc", "measured_at_utc")) {
      if ([string]::IsNullOrWhiteSpace($telemetry.$name) -or $telemetry.$name -match "not_exposed|unavailable") { throw "$label energy requires available $name" }
    }
    if ($null -eq $telemetry.pue -or $telemetry.pue -le 0) { throw "$label energy requires positive pue" }
  }
  if ($null -ne $telemetry.carbon_gco2e) {
    foreach ($name in @("carbon_source", "carbon_method", "grid_intensity_source")) {
      if ([string]::IsNullOrWhiteSpace($telemetry.$name) -or $telemetry.$name -match "not_exposed|unavailable") { throw "$label carbon requires available $name" }
    }
    if ($null -eq $telemetry.energy_kwh -or $null -eq $telemetry.grid_intensity_gco2e_per_kwh) { throw "$label carbon requires measured energy and grid intensity" }
  }
}

function Get-GrokBenchmarkTelemetry([string]$sessionId, [string]$logPath, [Text.Encoding]$encoding) {
  $empty = [ordered]@{
    status = "unavailable"; source = "unavailable"; session_id = $sessionId; parse_errors = 0; inference_turns = 0
    input_tokens = $null; cached_input_tokens = $null; output_tokens = $null; reasoning_tokens = $null
    total_tokens = $null; inference_ms = $null; ttft_ms_p50 = $null; output_tokens_per_second = $null
    attempts = $null; tool_calls = $null; tool_failures = $null; actual_cost_usd = $null
    actual_cost_source = "not_exposed_by_grok_build_oauth"; api_equivalent_cost_usd_upper_bound = $null
    api_rate_card = "grok-4.5 2026-07-08: USD 2/M input, USD 6/M output; cached input and reasoning charged conservatively for upper bound"
    energy_kwh = $null; energy_source = "provider_not_exposed"; energy_method = "unavailable"; hardware = $null
    provider_region = $null; pue = $null; measurement_window_start_utc = $null; measurement_window_end_utc = $null
    measured_at_utc = $null; carbon_gco2e = $null; carbon_source = "requires measured energy plus grid-intensity provenance"
    carbon_method = "unavailable"; grid_intensity_gco2e_per_kwh = $null; grid_intensity_source = $null
  }
  if ([string]::IsNullOrWhiteSpace($sessionId) -or -not (Test-Path -LiteralPath $logPath)) { return [pscustomobject]$empty }
  $events = @()
  $parseErrors = 0
  foreach ($line in Read-SharedTextLines $logPath $encoding) {
    if (-not $line.Contains($sessionId)) { continue }
    try {
      $event = $line | ConvertFrom-Json
      if ($event.sid -eq $sessionId) { $events += $event }
    } catch { $parseErrors++ }
  }
  $inference = @($events | Where-Object { $_.msg -eq "shell.turn.inference_done" })
  $empty.parse_errors = $parseErrors
  if ($inference.Count -eq 0) {
    if ($parseErrors -gt 0) { $empty.status = "partial" }
    return [pscustomobject]$empty
  }
  foreach ($event in $inference) {
    foreach ($name in @("prompt_tokens", "cached_prompt_tokens", "completion_tokens", "reasoning_tokens", "model_elapsed_ms", "ttft_ms", "attempts")) {
      if ($event.ctx.PSObject.Properties.Name -notcontains $name -or $null -eq $event.ctx.$name -or $event.ctx.$name -isnot [ValueType]) {
        $empty.status = "partial"
        $empty.source = "grok_unified_log_missing_fields"
        return [pscustomobject]$empty
      }
    }
  }
  $promptTokens = ($inference.ctx.prompt_tokens | Measure-Object -Sum).Sum
  $cachedTokens = ($inference.ctx.cached_prompt_tokens | Measure-Object -Sum).Sum
  $completionTokens = ($inference.ctx.completion_tokens | Measure-Object -Sum).Sum
  $reasoningTokens = ($inference.ctx.reasoning_tokens | Measure-Object -Sum).Sum
  $inferenceMs = ($inference.ctx.model_elapsed_ms | Measure-Object -Sum).Sum
  $toolEvents = @($events | Where-Object { $_.msg -eq "shell.tool.exec_done" })
  $empty.status = if ($parseErrors -gt 0 -or $inferenceMs -le 0) { "partial" } else { "complete" }
  $empty.source = "grok_unified_log"
  $empty.inference_turns = $inference.Count
  $empty.input_tokens = $promptTokens
  $empty.cached_input_tokens = $cachedTokens
  $empty.output_tokens = $completionTokens
  $empty.reasoning_tokens = $reasoningTokens
  $empty.total_tokens = $promptTokens + $completionTokens
  $empty.inference_ms = $inferenceMs
  $empty.ttft_ms_p50 = Get-Median $inference.ctx.ttft_ms
  $empty.output_tokens_per_second = if ($inferenceMs -gt 0) { [math]::Round($completionTokens * 1000 / $inferenceMs, 2) } else { $null }
  $empty.attempts = ($inference.ctx.attempts | Measure-Object -Sum).Sum
  $empty.tool_calls = $toolEvents.Count
  $empty.tool_failures = @($toolEvents | Where-Object { -not $_.ctx.success }).Count
  $empty.api_equivalent_cost_usd_upper_bound = [math]::Round((($promptTokens * 2) + (($completionTokens + $reasoningTokens) * 6)) / 1000000, 6)
  return [pscustomobject]$empty
}
