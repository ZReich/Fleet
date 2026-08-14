$ErrorActionPreference = "Stop"
$runner = Join-Path $PSScriptRoot "Run-TerraGrokComparison.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("terra-grok-wrapper-pair-" + [guid]::NewGuid().ToString("n"))
try {
  $repo = Join-Path $temp "repo"; $scripts = Join-Path $temp "scripts"; $out = Join-Path $temp "out"
  New-Item -ItemType Directory -Force -Path $repo, $scripts | Out-Null
  & git -C $repo init | Out-Null; & git -C $repo config user.name test; & git -C $repo config user.email test@example.invalid
  [IO.File]::WriteAllText((Join-Path $repo "result.txt"), "base`n")
  & git -C $repo add .; & git -C $repo commit -m baseline | Out-Null

  # Fake write-capable wrapper (mirrors Grok-style worktree edit)
  [IO.File]::WriteAllText((Join-Path $scripts "Invoke-Grok45.ps1"), @'
param([string]$PromptFile,[string]$WorkingDirectory,[string]$BashCapability,[switch]$IsolatedWorktree,[switch]$LeanSystemPrompt,[int]$TimeoutSeconds,[string]$Mode,[string]$Effort)
$prompt = [IO.File]::ReadAllText($PromptFile)
if ($Mode -ne 'json' -or $prompt -notmatch '^SHADOW_COVERED:') { exit 42 }
[IO.File]::WriteAllText((Join-Path $WorkingDirectory "result.txt"), "from-write-arm`n")
$obs = if ($env:FAKE_ARM_A_MODEL) { $env:FAKE_ARM_A_MODEL } else { "grok-4.6" }
@{status="ok";task_status="done";observed_model=$obs;model_evidence="fake"} | ConvertTo-Json -Compress
'@)
  # Fake patch-transport wrappers — REAL canonical shape: model + response (diff inside response), not observed_model+patch.
  $patchBody = @'
param([string]$PromptFile,[string]$Mode,[int]$TimeoutSeconds,[string]$Thinking,[switch]$ReadOnly)
$prompt = [IO.File]::ReadAllText($PromptFile)
if ($Mode -ne 'json' -or $prompt -notmatch '^SHADOW_COVERED:') { exit 42 }
$model = if ($env:FAKE_PATCH_MODEL) { $env:FAKE_PATCH_MODEL } else { "glm-5.3" }
$mode = $env:FAKE_PATCH_MODE
if ($mode -eq "bad-model") { $model = "wrong-model" }
$patch = if ($mode -eq "bad-scope") {
  @"
diff --git a/secret.txt b/secret.txt
--- a/secret.txt
+++ b/secret.txt
@@ -0,0 +1 @@
+leaked
"@
} elseif ($mode -eq "empty") { "" } elseif ($mode -eq "invalid") { "not a patch" } elseif ($mode -eq "no-trailing-nl") {
  # Intentionally omit final newline (model/here-string drop) — runner must normalize.
  "diff --git a/result.txt b/result.txt`n--- a/result.txt`n+++ b/result.txt`n@@ -1 +1 @@`n-base`n+from-patch-no-nl"
} elseif ($mode -eq "fenced") {
  "Here is the fix:`n``````diff`ndiff --git a/result.txt b/result.txt`n--- a/result.txt`n+++ b/result.txt`n@@ -1 +1 @@`n-base`n+from-patch-arm`n``````"
} else {
  @"
diff --git a/result.txt b/result.txt
--- a/result.txt
+++ b/result.txt
@@ -1 +1 @@
-base
+from-patch-arm
"@
}
# Canonical PiGlm/KimiK3 shape: model + response (unified diff lives in response text).
@{status="ok";task_status="done";model=$model;model_evidence="fake";response=$patch} | ConvertTo-Json -Compress
'@
  [IO.File]::WriteAllText((Join-Path $scripts "Invoke-PiGlm.ps1"), $patchBody)
  [IO.File]::WriteAllText((Join-Path $scripts "Invoke-KimiK3.ps1"), $patchBody.Replace('glm-5.3','kimi-code/k3').Replace('FAKE_PATCH_MODEL','FAKE_K3_MODEL').Replace('FAKE_PATCH_MODE','FAKE_K3_MODE'))

  function New-V2Tasks([string]$ModeA = "", [string]$ModeB = "", [string]$ModelA = "grok-4.6", [string]$ModelB = "glm-5.3") {
    return @{ tasks = @(
      @{ id="pair1"; prompt="Bounded pair one."; allowed_paths=@("result.txt"); max_diff_lines=20; gate_commands=@('if (-not (Test-Path result.txt)) { exit 1 }')
        lane_a=@{name="arm_a";wrapper="Invoke-Grok45.ps1";model=$ModelA;effort="high"}
        lane_b=@{name="arm_b";wrapper="Invoke-PiGlm.ps1";model=$ModelB;effort="high"} },
      @{ id="pair2"; prompt="Bounded pair two."; allowed_paths=@("result.txt"); max_diff_lines=20; gate_commands=@('if (-not (Test-Path result.txt)) { exit 1 }')
        lane_a=@{name="arm_a";wrapper="Invoke-Grok45.ps1";model=$ModelA;effort="high"}
        lane_b=@{name="arm_b";wrapper="Invoke-PiGlm.ps1";model=$ModelB;effort="high"} }
    ) }
  }
  function Invoke-Runner([string]$OutDir, [string]$TaskPath) {
    # EAP=Stop + native stderr = NativeCommandError (git "Preparing worktree" chatter);
    # force Continue and branch on $LASTEXITCODE (same pattern as the v1 suite).
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -TaskFile $TaskPath -OutputDirectory $OutDir -ScriptsDirectory $scripts 2>$null | Out-Null; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    return $code
  }

  # --- happy path: both arms via wrappers; patch applied; blind echo fields ---
  $taskFile = Join-Path $temp "tasks-v2.json"
  [IO.File]::WriteAllText($taskFile, ((New-V2Tasks) | ConvertTo-Json -Depth 8))
  $code = Invoke-Runner $out $taskFile
  if ($code -ne 0) { throw "wrapper_pair runner failed exit=$code" }
  $report = Get-Content (Join-Path $out "private\reveal.json") -Raw | ConvertFrom-Json
  if (@($report.results).Count -ne 2) { throw "expected two wrapper_pair results" }
  foreach ($result in @($report.results)) {
    if ($result.comparison_mode -ne "wrapper_pair") { throw "comparison_mode not wrapper_pair" }
    if ($result.estimand -ne "optimized_system") { throw "wrapper_pair result missing estimand=optimized_system got=$($result.estimand)" }
    if ($result.arm_a.run.transport_status -ne "ok") { throw "arm_a transport not ok: $($result.arm_a.run.transport_status)" }
    if ($result.arm_b.run.transport_status -ne "ok") { throw "arm_b transport not ok" }
    if ($result.arm_a.run.requested_model -ne "grok-4.6" -or $result.arm_b.run.requested_model -ne "glm-5.3") { throw "requested model pin missing" }
    if ($result.arm_a.run.observed_model -ne "grok-4.6" -or $result.arm_b.run.observed_model -ne "glm-5.3") { throw "observed model missing (must accept model field)" }
    if ($result.arm_a.artifacts.status -ne "eligible" -or $result.arm_b.artifacts.status -ne "eligible") { throw "arms not eligible: a=$($result.arm_a.artifacts.status) b=$($result.arm_b.artifacts.status)" }
    $diffB = Get-Content (Join-Path $out "private\$($result.task_id)\arm_b.diff") -Raw
    if ($diffB -notmatch 'from-patch-arm') { throw "patch content missing from arm_b diff (response-embedded diff)" }
    if (-not $result.runtime_fingerprints.arm_a_wrapper_sha256 -or -not $result.runtime_fingerprints.arm_b_wrapper_sha256) { throw "wrapper sha256 fingerprints missing" }
    $packet = Get-Content (Join-Path $out "blind\$($result.task_id)\packet.json") -Raw | ConvertFrom-Json
    if ($packet.comparison_mode -ne "wrapper_pair") { throw "blind comparison_mode wrong" }
    if (-not $packet.candidate_a.wrapper -or -not $packet.candidate_a.requested_model) { throw "blind missing lane-spec echo on candidate_a" }
    if (-not $packet.candidate_b.wrapper -or -not $packet.candidate_b.requested_model) { throw "blind missing lane-spec echo on candidate_b" }
    if (-not (Test-Path (Join-Path $out "blind\$($result.task_id)\candidate-a.diff"))) { throw "blind diffs missing" }
  }
  $blindText = (Get-ChildItem (Join-Path $out "blind") -File -Recurse | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
  if ($blindText -match 'blind_mapping|observed_model|arm_a\.stdout|arm_b\.stdout') { throw "blind packet leaks identity" }
  Write-Output "PASS v2 wrapper_pair launches both arms, applies patch, blind echo fields, fingerprints"

  # --- observed-model mismatch => transport error, not a grade ---
  $env:FAKE_PATCH_MODE = "bad-model"
  $badOut = Join-Path $temp "bad-model"
  [IO.File]::WriteAllText($taskFile, ((New-V2Tasks) | ConvertTo-Json -Depth 8))
  $code = Invoke-Runner $badOut $taskFile
  if ($code -ne 0) { throw "mismatch run should still exit 0 with complete evidence, got $code" }
  $badReport = Get-Content (Join-Path $badOut "private\reveal.json") -Raw | ConvertFrom-Json
  $br = $badReport.results[0]
  if ($br.arm_b.run.transport_status -ne "error") { throw "model mismatch must be transport error" }
  if ($br.arm_b.artifacts.status -eq "eligible" -and $br.arm_b.run.transport_status -eq "ok") { throw "mismatch must not be gradeable ok" }
  $bp = Get-Content (Join-Path $badOut "blind\pair1\packet.json") -Raw | ConvertFrom-Json
  $badCand = @($bp.candidate_a, $bp.candidate_b) | Where-Object { $_.requested_model -eq "glm-5.3" } | Select-Object -First 1
  if ($badCand.adoption_status -eq "eligible") { throw "mismatch arm must not be adoption-eligible" }
  Write-Output "PASS observed-model mismatch => transport error, never a grade"
  $env:FAKE_PATCH_MODE = ""

  # --- allowlist rejections: distinct errors ---
  function Assert-Reject([hashtable]$LaneA, [hashtable]$LaneB, [string]$Needle, [string]$Label) {
    $tf = Join-Path $temp "reject-$Label.json"
    $body = @{ tasks = @(
      @{ id="r1"; prompt="x"; allowed_paths=@("result.txt"); lane_a=$LaneA; lane_b=$LaneB },
      @{ id="r2"; prompt="y"; allowed_paths=@("result.txt"); lane_a=$LaneA; lane_b=$LaneB }
    ) }
    [IO.File]::WriteAllText($tf, ($body | ConvertTo-Json -Depth 8))
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
      $err = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Repo $repo -TaskFile $tf -OutputDirectory (Join-Path $temp "rej-$Label") -ScriptsDirectory $scripts 2>&1 | Out-String
      $ec = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($ec -eq 0) { throw "$Label accepted" }
    if ($err -notmatch [regex]::Escape($Needle)) { throw "$Label wrong error (want '$Needle'): $err" }
    Write-Output "PASS allowlist reject: $Label"
  }
  Assert-Reject @{name="a";wrapper="Invoke-Missing.ps1";model="m"} @{name="b";wrapper="Invoke-Grok45.ps1";model="g"} "unknown wrapper name" "unknown-name"
  Assert-Reject @{name="a";wrapper="C:\Windows\System32\cmd.exe";model="m"} @{name="b";wrapper="Invoke-Grok45.ps1";model="g"} "absolute path" "absolute-path"
  Assert-Reject @{name="a";wrapper="codex.exe";model="m"} @{name="b";wrapper="Invoke-Grok45.ps1";model="g"} "non-scripts executable" "non-scripts"
  Assert-Reject @{name="a";wrapper="..\Invoke-Grok45.ps1";model="m"} @{name="b";wrapper="Invoke-Grok45.ps1";model="g"} "path-like name" "path-like"

  # --- invalid / out-of-scope patch => excluded_capability, never a loss ---
  foreach ($case in @(@{mode="bad-scope";reason="patch_scope_violation"}, @{mode="invalid";reason="patch_apply_check_failed"}, @{mode="empty";reason="empty_patch"})) {
    $env:FAKE_PATCH_MODE = $case.mode
    $exOut = Join-Path $temp "excl-$($case.mode)"
    [IO.File]::WriteAllText($taskFile, ((New-V2Tasks) | ConvertTo-Json -Depth 8))
    $code = Invoke-Runner $exOut $taskFile
    if ($code -ne 0) { throw "excluded_capability run must exit 0, got $code for $($case.mode)" }
    $exReport = Get-Content (Join-Path $exOut "private\reveal.json") -Raw | ConvertFrom-Json
    $er = $exReport.results[0]
    if ($er.arm_b.artifacts.status -ne "excluded_capability") { throw "$($case.mode): expected excluded_capability got $($er.arm_b.artifacts.status)" }
    if ($er.arm_b.artifacts.exclusion_reason -ne $case.reason) { throw "$($case.mode): reason want $($case.reason) got $($er.arm_b.artifacts.exclusion_reason)" }
    $ep = Get-Content (Join-Path $exOut "blind\pair1\packet.json") -Raw | ConvertFrom-Json
    $exCand = @($ep.candidate_a, $ep.candidate_b) | Where-Object { $_.scoring_status -eq "excluded_capability" } | Select-Object -First 1
    if ($null -eq $exCand) { throw "$($case.mode): blind missing excluded_capability" }
    if ($exCand.adoption_status -ne "excluded_capability") { throw "$($case.mode): adoption must be excluded_capability not a loss" }
    Write-Output "PASS patch $($case.mode) => excluded_capability (never a loss)"
  }
  $env:FAKE_PATCH_MODE = ""

  # --- patch without trailing newline applies cleanly (regression: corrupt patch at last line) ---
  $env:FAKE_PATCH_MODE = "no-trailing-nl"
  $nlOut = Join-Path $temp "no-trailing-nl"
  [IO.File]::WriteAllText($taskFile, ((New-V2Tasks) | ConvertTo-Json -Depth 8))
  $code = Invoke-Runner $nlOut $taskFile
  if ($code -ne 0) { throw "no-trailing-nl runner failed exit=$code" }
  $nlReport = Get-Content (Join-Path $nlOut "private\reveal.json") -Raw | ConvertFrom-Json
  $nlr = $nlReport.results[0]
  if ($nlr.arm_b.artifacts.status -ne "eligible") { throw "no-trailing-nl: arm_b not eligible: $($nlr.arm_b.artifacts.status) reason=$($nlr.arm_b.artifacts.exclusion_reason)" }
  $nlDiff = Get-Content (Join-Path $nlOut "private\$($nlr.task_id)\arm_b.diff") -Raw
  if ($nlDiff -notmatch 'from-patch-no-nl') { throw "no-trailing-nl: patch content missing from arm_b diff" }
  Write-Output "PASS patch without trailing newline applies cleanly"
  $env:FAKE_PATCH_MODE = ""
  Write-Output "PASS all wrapper_pair suite cases"
}
finally {
  $env:FAKE_PATCH_MODE = ""; $env:FAKE_K3_MODE = ""; $env:FAKE_ARM_A_MODEL = ""; $env:FAKE_PATCH_MODEL = ""
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
