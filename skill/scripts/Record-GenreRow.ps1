param(
  [Parameter(Mandatory)][string]$RunId,
  [Parameter(Mandatory)][string]$Date,
  [Parameter(Mandatory)][string]$Model,
  [Parameter(Mandatory)][ValidateSet('implementation','review','synthesis','extraction','research','visual-evidence','design')][string]$Genre,
  [Parameter(Mandatory)][string]$Effort,
  [Parameter(Mandatory)][ValidateSet('standardized_model','optimized_system')][string]$Estimand,
  [Parameter(Mandatory)][ValidateSet('facts','blind-0-100','pass-fail')][string]$ScoreType,
  [Parameter(Mandatory)][double]$Score,
  [Parameter(Mandatory)][double]$MaxScore,
  $WallSeconds = $null,
  [int]$Retries = 0,
  [int]$Fabrications = 0,
  [string]$Notes = '',
  [string]$LedgerPath
)

# PS 5.1 does not populate $PSScriptRoot in param defaults - resolve in the body.
if (-not $LedgerPath) { $LedgerPath = Join-Path $PSScriptRoot '..\BENCH-genre.jsonl' }
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
function Fail([string]$m) { throw $m }
if ($Score -gt $MaxScore) { Fail "Score ($Score) must be <= MaxScore ($MaxScore)" }
if ($Score -lt 0) { Fail 'Score must be non-negative' }
if ($MaxScore -lt 0) { Fail 'MaxScore must be non-negative' }
if ($Retries -lt 0) { Fail 'Retries must be non-negative' }
if ($Fabrications -lt 0) { Fail 'Fabrications must be non-negative' }
if ($null -ne $WallSeconds -and "$WallSeconds" -ne '' -and [int]$WallSeconds -lt 0) { Fail 'WallSeconds must be non-negative' }
$row = [ordered]@{ run_id=$RunId; date=$Date; model=$Model; genre=$Genre; effort=$Effort; estimand=$Estimand; score_type=$ScoreType; score=$Score; max_score=$MaxScore; wall_seconds=$(if ($null -eq $WallSeconds -or "$WallSeconds" -eq '') { $null } else { [int]$WallSeconds }); retries=[int]$Retries; fabrications=[int]$Fabrications; notes=$(if ([string]::IsNullOrWhiteSpace($Notes)) { $null } else { $Notes }) }
$fullPath = [IO.Path]::GetFullPath($LedgerPath)
$dir = Split-Path -Parent $fullPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$payload = ([pscustomobject]$row | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine
$tmp = [IO.Path]::GetTempFileName()
$hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath.ToLowerInvariant()))
$ledgerHash = -join ($hashBytes[0..7] | ForEach-Object { $_.ToString('x2') })
$mutex = [Threading.Mutex]::new($false, "Global\CodexFleetGenreRow-$ledgerHash")
try {
  if (-not $mutex.WaitOne(30000)) { Fail 'Timed out waiting for genre row ledger lock' }
  [IO.File]::WriteAllText($tmp, $payload, $utf8)
  $rowsTotal = 0; $modelGenreRows = 0; $standardizedRows = 0
  if (Test-Path -LiteralPath $fullPath) {
    foreach ($line in [IO.File]::ReadAllLines($fullPath, $utf8)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $ex = $line | ConvertFrom-Json
      if ([string]$ex.run_id -eq $RunId -and [string]$ex.model -eq $Model -and [string]$ex.genre -eq $Genre) { Fail "Duplicate run_id+model+genre: $RunId / $Model / $Genre" }
      $rowsTotal++
      if ([string]$ex.model -eq $Model -and [string]$ex.genre -eq $Genre) {
        $modelGenreRows++
        if ([string]$ex.estimand -eq 'standardized_model') { $standardizedRows++ }
      }
    }
  }
  [IO.File]::AppendAllText($fullPath, [IO.File]::ReadAllText($tmp, $utf8), $utf8)
} finally {
  try { $mutex.ReleaseMutex() } catch { }
  $mutex.Dispose()
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
$rowsTotal++; $modelGenreRows++
if ($Estimand -eq 'standardized_model') { $standardizedRows++ }
[pscustomobject]@{ rows_total=$rowsTotal; model_genre_rows=$modelGenreRows; standardized_rows=$standardizedRows; graduated=($standardizedRows -ge 10) } | ConvertTo-Json -Compress
