# Offline suite for Invoke-ShadowReplay + consumer live path. Temp fixtures only;
# FAKE wrappers via lane-spec. Exit 0 all pass / 1 any fail.
$ErrorActionPreference = 'Stop'
$enqueue = Join-Path $PSScriptRoot 'Enqueue-FleetShadow.ps1'
$start = Join-Path $PSScriptRoot 'Start-FleetAutoShadow.ps1'
$replay = Join-Path $PSScriptRoot 'Invoke-ShadowReplay.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-shadow-replay-' + [guid]::NewGuid().ToString('n'))
$passed = 0; $failed = 0
$utf8 = New-Object Text.UTF8Encoding($false)

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }
function Assert-BytesEqual([byte[]]$A, [byte[]]$B, [string]$Label) {
  Assert-True ($A.Length -eq $B.Length) "$Label length $($A.Length) vs $($B.Length)"
  for ($i = 0; $i -lt $A.Length; $i++) { Assert-True ($A[$i] -eq $B[$i]) "$Label byte $i changed" }
}
function Write-Json([string]$Path, $Obj) {
  $dir = Split-Path -Parent $Path; if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, ($Obj | ConvertTo-Json -Depth 10), $utf8)
}
function New-GitRepo([string]$Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  & git -C $Path init -q; & git -C $Path config user.name t; & git -C $Path config user.email t@t.invalid
  [IO.File]::WriteAllText((Join-Path $Path 'seed.txt'), 'seed')
  & git -C $Path add .; & git -C $Path commit -q -m base | Out-Null
  return (& git -C $Path rev-parse HEAD).Trim()
}
function New-FakeWrapper([string]$Path, [string]$Mode = 'ok') {
  # Mode: ok | fail_gate | timeout | scope | primary_win | challenger_win | tie5 | patch_ok | patch_bad
  # Accepts Sol-family (-Prompt/-Model) and Grok-style (-PromptFile) shapes.
  $body = @'
param([string]$Prompt,[string]$PromptFile,[string]$Model,[string]$WorkingDirectory,[int]$TimeoutSeconds,[string]$Mode,[string]$LaneId,[switch]$ReadOnly)
$m = $env:FAKE_SHADOW_MODE
if ($m -eq 'timeout') { Start-Sleep -Seconds ([math]::Max(20, $TimeoutSeconds + 15)); @{status='ok'} | ConvertTo-Json -Compress; exit 0 }
# Patch-seat only (Invoke-PiGlm passes -ReadOnly); worktree seats keep writing files.
if ($ReadOnly -and $m -eq 'patch_ok') {
  $patch = @"
diff --git a/result.txt b/result.txt
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/result.txt
@@ -0,0 +1 @@
+patched-ok
"@
  @{status='ok';task_status='done';lane=$LaneId;patch=$patch;observed_model='glm-5.3'} | ConvertTo-Json -Compress
  exit 0
}
if ($ReadOnly -and $m -eq 'patch_bad') {
  $patch = @"
diff --git a/outside.txt b/outside.txt
new file mode 100644
index 0000000..1111111
--- /dev/null
+++ b/outside.txt
@@ -0,0 +1 @@
+leak
"@
  @{status='ok';task_status='done';lane=$LaneId;patch=$patch;model='glm-5.3';response=$patch} | ConvertTo-Json -Compress
  exit 0
}
$content = 'ok-content'
if ($m -eq 'scope') { $content = 'x'; $p = Join-Path $WorkingDirectory 'outside.txt'; [IO.File]::WriteAllText($p, 'leak') }
elseif ($m -eq 'fail_gate' -and $LaneId -eq $env:FAKE_FAIL_LANE) { $content = 'BAD' }
elseif ($m -eq 'primary_win' -and $LaneId -eq 'terra') { $content = ('P' * 2) }
elseif ($m -eq 'primary_win' -and $LaneId -eq 'grok') { $content = 'G' }
elseif ($m -eq 'challenger_win' -and $LaneId -eq 'grok') { $content = ('C' * 2) }
elseif ($m -eq 'challenger_win' -and $LaneId -eq 'terra') { $content = 'T' }
elseif ($m -eq 'tie5') { $content = 'same' }
if ($WorkingDirectory) { [IO.File]::WriteAllText((Join-Path $WorkingDirectory 'result.txt'), $content) }
@{status='ok';task_status='done';lane=$LaneId;model=$Model} | ConvertTo-Json -Compress
'@
  $dir = Split-Path -Parent $Path
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [IO.File]::WriteAllText($Path, $body, $utf8)
}
function New-TaskSpec([string]$Gate = "if (-not (Test-Path result.txt)) { exit 1 }; if ((Get-Content result.txt -Raw) -match 'BAD') { exit 1 }", [int]$MaxLines = 50) {
  return @{ id = 't-replay'; prompt = 'Write result.txt'; allowed_paths = @('result.txt'); gate_commands = @($Gate); max_diff_lines = $MaxLines }
}
function EnqSpec([hashtable]$extra) {
  # PS5.1 mangles embedded quotes when splatting args to a native exe (CRT argv
  # lesson); build the command line with CRT escaping + Diagnostics.Process.
  $tokens = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$enqueue)
  foreach ($k in $extra.Keys) {
    $v = $extra[$k]
    if ($k -eq 'Force' -and ($v -eq $true -or "$v" -eq 'true')) { $tokens += '-Force' }
    else { $tokens += @("-$k", [string]$v) }
  }
  $argLine = ($tokens | ForEach-Object { $t = [string]$_; if (-not $t) { '""' } elseif ($t -notmatch '[\s"]') { $t } else { '"' + ($t -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"' } }) -join ' '
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'; $psi.Arguments = $argLine
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit(); $p.Dispose()
  if ($err) { Write-Host $err }
  ($out -join "`n") | ConvertFrom-Json
}

try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  $repo = Join-Path $temp 'repo'; $baseSha = New-GitRepo $repo
  # Fakes must live under a scripts/ dir with allowlisted basenames (B1 trust boundary).
  $fakeScripts = Join-Path $temp 'scripts'
  $fakeSol = Join-Path $fakeScripts 'Invoke-Sol.ps1'
  $fakeGrok = Join-Path $fakeScripts 'Invoke-Grok45.ps1'
  $fakeGlm = Join-Path $fakeScripts 'Invoke-PiGlm.ps1'
  New-FakeWrapper $fakeSol; New-FakeWrapper $fakeGrok; New-FakeWrapper $fakeGlm
  $fake = $fakeGrok
  $laneSpec = Join-Path $temp 'lane-spec.json'
  Write-Json $laneSpec @{ wrappers = @{ terra = $fakeSol; grok = $fakeGrok }; models = @{ terra = 'gpt-5.6-terra'; grok = 'grok-4.6' } }
  $specJson = (New-TaskSpec | ConvertTo-Json -Compress -Depth 6)

  Case 'B1 allowlist reject: unknown basename' {
    $fx = Join-Path $temp 'b1a'; $q = Join-Path $fx 'q'; New-Item -ItemType Directory -Force -Path $q | Out-Null
    $evil = Join-Path $fx 'scripts\evil-wrapper.ps1'; New-FakeWrapper $evil
    $ls = Join-Path $fx 'lane.json'
    Write-Json $ls @{ wrappers = @{ terra = $evil; grok = $fakeGrok } }
    $r = EnqSpec @{ RunId='rB1a'; TaskId='t-b1a'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sB1a'; Challenger='grok'; QueueRoot=$q; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='4' }
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $replay -EntryPath $r.queue_path -RepoRoot $repo -OutputDirectory (Join-Path $fx 'out') -LaneSpecPath $ls | Out-String
    $c = $raw.Trim() | ConvertFrom-Json
    Assert-True ($c.success -eq $false -and $c.status -eq 'error' -and "$($c.error)" -match 'basename not allowed|not allowed') "unknown basename not rejected: $($raw.Trim())"
  }

  Case 'B1 allowlist reject: absolute path outside scripts/' {
    $fx = Join-Path $temp 'b1b'; $q = Join-Path $fx 'q'; New-Item -ItemType Directory -Force -Path $q | Out-Null
    $outside = Join-Path $fx 'not-scripts\Invoke-Grok45.ps1'; New-FakeWrapper $outside
    $ls = Join-Path $fx 'lane.json'
    Write-Json $ls @{ wrappers = @{ terra = $fakeSol; grok = $outside } }
    $r = EnqSpec @{ RunId='rB1b'; TaskId='t-b1b'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sB1b'; Challenger='grok'; QueueRoot=$q; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='4' }
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $replay -EntryPath $r.queue_path -RepoRoot $repo -OutputDirectory (Join-Path $fx 'out') -LaneSpecPath $ls | Out-String
    $c = $raw.Trim() | ConvertFrom-Json
    Assert-True ($c.success -eq $false -and $c.status -eq 'error' -and "$($c.error)" -match 'not under scripts') "outside scripts not rejected: $($raw.Trim())"
  }

  Case 'B1 allowlist reject: non-scripts path' {
    $fx = Join-Path $temp 'b1c'; $q = Join-Path $fx 'q'; New-Item -ItemType Directory -Force -Path $q | Out-Null
    $relish = Join-Path $fx 'elsewhere\Invoke-Sol.ps1'; New-FakeWrapper $relish
    $ls = Join-Path $fx 'lane.json'
    Write-Json $ls @{ wrappers = @{ terra = $relish; grok = $fakeGrok } }
    $r = EnqSpec @{ RunId='rB1c'; TaskId='t-b1c'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sB1c'; Challenger='grok'; QueueRoot=$q; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='4' }
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $replay -EntryPath $r.queue_path -RepoRoot $repo -OutputDirectory (Join-Path $fx 'out') -LaneSpecPath $ls | Out-String
    $c = $raw.Trim() | ConvertFrom-Json
    Assert-True ($c.success -eq $false -and $c.status -eq 'error') "non-scripts path not rejected: $($raw.Trim())"
  }

  Case 'B2 Sol-family launch carries -Model + -Prompt, no -PromptFile' {
    $fx = Join-Path $temp 'b2'; $q = Join-Path $fx 'q'; New-Item -ItemType Directory -Force -Path $q | Out-Null
    $r = EnqSpec @{ RunId='rB2'; TaskId='t-b2'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sB2'; Challenger='grok'; QueueRoot=$q; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='4' }
    $env:FAKE_SHADOW_MODE = 'tie5'
    $out = Join-Path $fx 'out'
    $c = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $replay -EntryPath $r.queue_path -RepoRoot $repo -OutputDirectory $out -LaneSpecPath $laneSpec) -join "`n") | ConvertFrom-Json
    Assert-True ($true -eq $c.success) "replay failed: $($c | ConvertTo-Json -Compress)"
    $terraLaunch = Get-Content -LiteralPath (Join-Path $out 'private\terra.launch.json') -Raw | ConvertFrom-Json
    $args = @($terraLaunch.args)
    Assert-True ($args -contains '-Prompt') "terra missing -Prompt: $($args -join ' ')"
    Assert-True ($args -contains '-Model') "terra missing -Model: $($args -join ' ')"
    Assert-True ($args -notcontains '-PromptFile') "terra must not use -PromptFile: $($args -join ' ')"
    Assert-True ($terraLaunch.requested_model -eq 'gpt-5.6-terra') "terra model=$($terraLaunch.requested_model)"
    $grokLaunch = Get-Content -LiteralPath (Join-Path $out 'private\grok.launch.json') -Raw | ConvertFrom-Json
    Assert-True (@($grokLaunch.args) -contains '-PromptFile') "grok missing -PromptFile"
  }

  Case 'B3 patch seat happy path + bad-scope excluded_capability' {
    $fx = Join-Path $temp 'b3'; $q = Join-Path $fx 'q'; New-Item -ItemType Directory -Force -Path $q | Out-Null
    $ls = Join-Path $fx 'lane.json'
    Write-Json $ls @{ wrappers = @{ terra = $fakeSol; grok = $fakeGlm }; models = @{ terra = 'gpt-5.6-terra'; grok = 'glm-5.3' } }
    # Happy path: patch applies to result.txt
    $r = EnqSpec @{ RunId='rB3h'; TaskId='t-b3h'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sB3h'; Challenger='grok'; QueueRoot=$q; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='4' }
    $env:FAKE_SHADOW_MODE = 'patch_ok'
    $out = Join-Path $fx 'out-ok'
    $c = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $replay -EntryPath $r.queue_path -RepoRoot $repo -OutputDirectory $out -LaneSpecPath $ls) -join "`n") | ConvertFrom-Json
    Assert-True ($null -ne $c.reveal_path -and (Test-Path -LiteralPath $c.reveal_path)) "happy reveal missing: $($c | ConvertTo-Json -Compress)"
    $rev = Get-Content -LiteralPath $c.reveal_path -Raw | ConvertFrom-Json
    $gArt = $rev.challenger_arm.artifacts
    Assert-True ($gArt.status -eq 'eligible' -or $gArt.status -eq 'gate_failed') "patch happy status=$($gArt.status)"
    Assert-True ((Test-Path -LiteralPath (Join-Path $out 'private\grok.patch'))) 'patch file not written'
    # Bad scope: outside.txt => excluded_capability, never a loss for the seat
    $q2 = Join-Path $fx 'q2'; New-Item -ItemType Directory -Force -Path $q2 | Out-Null
    $r2 = EnqSpec @{ RunId='rB3b'; TaskId='t-b3b'; TaskStratum='standard'; BaseSha=$baseSha; Seed='sB3b'; Challenger='grok'; QueueRoot=$q2; Force=$true; TaskSpecJson=$specJson; PrimaryLane='terra'; PrimaryWallSeconds='4' }
    $env:FAKE_SHADOW_MODE = 'patch_bad'
    $out2 = Join-Path $fx 'out-bad'
    $c2 = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $replay -EntryPath $r2.queue_path -RepoRoot $repo -OutputDirectory $out2 -LaneSpecPath $ls) -join "`n") | ConvertFrom-Json
    $rev2 = Get-Content -LiteralPath $c2.reveal_path -Raw | ConvertFrom-Json
    Assert-True ($rev2.challenger_arm.artifacts.status -eq 'excluded_capability') "expected excluded_capability got $($rev2.challenger_arm.artifacts.status)"
    Assert-True ($c2.result -eq 'no_contest' -or $c2.success -eq $false) "excluded seat must not lose: result=$($c2.result)"
  }
}
finally {
  $env:FAKE_SHADOW_MODE = ''; $env:FAKE_FAIL_LANE = ''
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
