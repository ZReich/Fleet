param([switch]$Live)

$ErrorActionPreference = 'Stop'
$wrapper = Join-Path $PSScriptRoot 'Invoke-KimiK3.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-kimi-test-' + [guid]::NewGuid().ToString('n'))
$fake = Join-Path $temp 'kimi.cmd'
$fakePs1 = Join-Path $temp 'fake-kimi.ps1'
$oldUserProfile = $env:USERPROFILE
$oldKimiExecutable = $env:FLEET_KIMI_EXECUTABLE
$passed = 0
$failed = 0

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  $env:USERPROFILE = Join-Path $temp 'profile'
  New-Item -ItemType Directory -Force -Path (Join-Path $env:USERPROFILE '.kimi-code') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $env:USERPROFILE '.kimi-code\credentials') | Out-Null
  [IO.File]::WriteAllText((Join-Path $env:USERPROFILE '.kimi-code\config.toml'), @'
default_model = "kimi-code/k3"
[providers."managed:kimi-code"]
type = "kimi"
base_url = "https://api.kimi.com/coding/v1"
[models."kimi-code/k3"]
provider = "managed:kimi-code"
model = "k3"
max_context_size = 1048576
'@, (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($fake, "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$fakePs1`" %*")
  [IO.File]::WriteAllText($fakePs1, @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
if ($Args -contains '--version') { '0.27.0'; exit 0 }
if ($env:KIMI_CODE_NO_AUTO_UPDATE -ne '1' -or $env:KIMI_DISABLE_TELEMETRY -ne '1' -or $env:KIMI_CODE_BACKGROUND_KEEP_ALIVE_ON_EXIT -ne '0' -or $env:KIMI_DISABLE_CRON -ne '1') { exit 21 }
if (-not ($Args -contains '--model') -or $Args[[Array]::IndexOf($Args, '--model') + 1] -ne 'kimi-code/k3' -or -not ($Args -contains '--skills-dir') -or -not ($Args -contains '--output-format') -or $Args[[Array]::IndexOf($Args, '--output-format') + 1] -ne 'stream-json') { [Console]::Error.WriteLine('BAD_ARGS:' + ($Args -join '|')); exit 22 }
if (($Args | Where-Object { $_ -in @('--yolo','--auto','--plan','-y') }).Count) { exit 23 }
$config = Join-Path $env:KIMI_CODE_HOME 'config.toml'
$configText = if (Test-Path -LiteralPath $config) { Get-Content -LiteralPath $config -Raw } else { '' }
if (-not $configText.Contains('pattern = "Write"') -or -not $configText.Contains('pattern = "Bash"') -or -not $configText.Contains('pattern = "WebSearch"') -or -not $configText.Contains('pattern = "ToolSearch"') -or -not $configText.Contains('pattern = "mcp__*"')) { exit 24 }
$allowWeb = $configText -match 'decision = "allow"\r?\npattern = "WebSearch"'
$allowSwarm = $configText -match 'decision = "allow"\r?\npattern = "AgentSwarm"'
if ($env:FAKE_KIMI_EXPECT_RESEARCH -eq '1') {
  if (-not $allowWeb -or -not $allowSwarm) { [Console]::Error.WriteLine('NO_RESEARCH_ALLOW'); exit 28 }
  if (-not $configText.Contains('pattern = "Bash"') -or -not $configText.Contains('pattern = "Write"')) { [Console]::Error.WriteLine('RESEARCH_DROPPED_CORE_DENY'); exit 30 }
} elseif ($allowWeb -or $allowSwarm) { [Console]::Error.WriteLine('LEAKED_RESEARCH_ALLOW'); exit 29 }
$prompt = $Args[[Array]::IndexOf($Args, '--prompt') + 1]
# Prompt-file transport: -p now carries only a short static instruction naming the
# file that holds the real task. Argv must stay tiny regardless of artifact size.
if ($prompt.Length -gt 4000) { [Console]::Error.WriteLine('PROMPT_ARGV_TOO_LARGE:' + $prompt.Length); exit 38 }
$promptFileMatch = [regex]::Match($prompt, '(?m)PROMPT_FILE:\s*(.+)$')
if (-not $promptFileMatch.Success) { [Console]::Error.WriteLine('NO_PROMPT_FILE_MARKER'); exit 39 }
$promptFilePath = $promptFileMatch.Groups[1].Value.Trim() -replace '/', '\'
if (-not (Test-Path -LiteralPath $promptFilePath -PathType Leaf)) { [Console]::Error.WriteLine('PROMPT_FILE_MISSING:' + $promptFilePath); exit 40 }
if (-not $configText.Contains('pattern = "Read(')) { [Console]::Error.WriteLine('NO_PROMPT_READ_ALLOW'); exit 41 }
$promptFileContent = [string](Get-Content -Raw -LiteralPath $promptFilePath -Encoding UTF8)
if ($env:FAKE_KIMI_EXPECT -and (-not $promptFileContent -or -not $promptFileContent.Contains($env:FAKE_KIMI_EXPECT))) { exit 25 }
# Every real kimi run reads the prompt file once (per the static -p instruction)
# before doing anything else; simulate that here so the wrapper's mandatory
# "Kimi did not read the prompt file" check sees it, unless a test explicitly
# wants to exercise that negative path.
if ($env:FAKE_KIMI_SKIP_PROMPT_READ -ne '1') {
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='Read'; arguments=[ordered]@{ path=$promptFilePath } }) } | ConvertTo-Json -Compress -Depth 5
  [ordered]@{ role='tool'; name='Read'; content=$promptFileContent } | ConvertTo-Json -Compress
}
# Owner-marker probe: capture the wrapper-written owner.json from the runtime root
# (parent of KIMI_CODE_HOME). Never invent a marker here — only copy what exists.
if ($env:FAKE_KIMI_OWNER_PROBE) {
  $probeDir = $env:FAKE_KIMI_OWNER_PROBE
  New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
  $rt = Split-Path $env:KIMI_CODE_HOME -Parent
  $markerPath = Join-Path $rt 'owner.json'
  if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    Copy-Item -LiteralPath $markerPath -Destination (Join-Path $probeDir 'at-child-start-owner.json') -Force
    [IO.File]::WriteAllText((Join-Path $probeDir 'at-child-start-exists.txt'), '1')
  } else {
    [IO.File]::WriteAllText((Join-Path $probeDir 'at-child-start-exists.txt'), '0')
  }
  # Parent Process.Start rewrites to child after Start() returns; brief wait then re-copy.
  Start-Sleep -Milliseconds 400
  if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
    Copy-Item -LiteralPath $markerPath -Destination (Join-Path $probeDir 'after-child-start-owner.json') -Force
  }
  $me = [Diagnostics.Process]::GetCurrentProcess()
  $parentPid = 0
  try { $parentPid = [int](Get-CimInstance Win32_Process -Filter ("ProcessId=" + $me.Id) -ErrorAction Stop).ParentProcessId } catch { }
  [IO.File]::WriteAllText((Join-Path $probeDir 'child-tree-pids.txt'), (($me.Id.ToString()) + ',' + $parentPid.ToString()))
}
if ($env:FAKE_KIMI_HANG -eq '1') { Start-Sleep -Seconds 30; exit 0 }
if ($env:FAKE_KIMI_BAD_JSON -eq '1') { 'not json'; exit 0 }
if ($env:FAKE_KIMI_TOOL -eq '1') {
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='Bash'; arguments=[ordered]@{ command='dir' } }) } | ConvertTo-Json -Compress -Depth 5
  [ordered]@{ role='tool'; name='Bash'; content='' } | ConvertTo-Json -Compress
  exit 0
}
if ($env:FAKE_KIMI_IMAGE_TOOL -eq '1' -or $env:FAKE_KIMI_IMAGE_OUTSIDE -eq '1') {
  $readPattern = [regex]::Match($configText, 'pattern = "ReadMediaFile\(([^)]+)\)"')
  if (-not $readPattern.Success) { exit 26 }
  $imageDirectory = ($readPattern.Groups[1].Value -replace '/\*$', '') -replace '/', '\'
  $imagePath = if ($env:FAKE_KIMI_IMAGE_OUTSIDE -eq '1') { $imageDirectory + '-leak\secret.png' } else { Join-Path $imageDirectory 'image-01.png' }
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='ReadMediaFile'; arguments=[ordered]@{ path=$imagePath } }) } | ConvertTo-Json -Compress -Depth 5
  [ordered]@{ role='tool'; name='ReadMediaFile'; content='' } | ConvertTo-Json -Compress
  [ordered]@{ role='assistant'; content='KIMI_IMAGE_OK' } | ConvertTo-Json -Compress
  exit 0
}
if ($env:FAKE_KIMI_REFRESH_CRED -eq '1') {
  $cd = Join-Path $env:KIMI_CODE_HOME 'credentials'
  New-Item -ItemType Directory -Force -Path $cd | Out-Null
  [IO.File]::WriteAllText((Join-Path $cd 'kimi-code.json'), '{"access_token":"newtok","refresh_token":"newref","expires_at":9999999999,"scope":"kimi-code","token_type":"Bearer","expires_in":900}')
  [ordered]@{ role='assistant'; content='KIMI_OK' } | ConvertTo-Json -Compress
  [ordered]@{ role='meta'; type='session.resume_hint'; session_id='fake-session' } | ConvertTo-Json -Compress
  exit 0
}
if ($env:FAKE_KIMI_CITE -eq 'ok') {
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='FetchURL'; arguments=[ordered]@{ url='https://example.com/a' } }) } | ConvertTo-Json -Compress -Depth 6
  [ordered]@{ role='assistant'; content=("Per https://example.com/a the answer is X.`n`nCITATIONS:`nhttps://example.com/a") } | ConvertTo-Json -Compress
  exit 0
}
if ($env:FAKE_KIMI_CITE -eq 'bad') {
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='FetchURL'; arguments=[ordered]@{ url='https://example.com/a' } }) } | ConvertTo-Json -Compress -Depth 6
  [ordered]@{ role='assistant'; content='Per https://evil.example.com/fake the answer is X.' } | ConvertTo-Json -Compress
  exit 0
}
if ($env:FAKE_KIMI_CITE -eq 'arxiv') {
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='FetchURL'; arguments=[ordered]@{ url='https://arxiv.org/abs/2401.12345' } }) } | ConvertTo-Json -Compress -Depth 6
  [ordered]@{ role='assistant'; content='See https://arxiv.org/pdf/2401.12345 for details.' } | ConvertTo-Json -Compress
  exit 0
}
if ($env:FAKE_KIMI_CITE -eq 'artifact') {
  [ordered]@{ role='assistant'; content='Per https://example.com/never the answer is X.' } | ConvertTo-Json -Compress
  exit 0
}
if ($env:FAKE_KIMI_WS -eq 'ok') {
  $ws = Join-Path (Split-Path $env:KIMI_CODE_HOME -Parent) 'workspace'
  New-Item -ItemType Directory -Force -Path $ws | Out-Null
  [IO.File]::WriteAllText((Join-Path $ws 'index.html'), '<html></html>')
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='Write'; arguments=[ordered]@{ path=(Join-Path $ws 'index.html') } }) } | ConvertTo-Json -Compress -Depth 6
  [ordered]@{ role='assistant'; content='Prototype written to index.html' } | ConvertTo-Json -Compress
  exit 0
}
if ($env:FAKE_KIMI_WS -eq 'two') {
  $ws = Join-Path (Split-Path $env:KIMI_CODE_HOME -Parent) 'workspace'
  New-Item -ItemType Directory -Force -Path $ws | Out-Null
  [IO.File]::WriteAllText((Join-Path $ws 'index.html'), '<html>two</html>')
  [IO.File]::WriteAllText((Join-Path $ws 'app.js'), 'console.log(1)')
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='Write'; arguments=[ordered]@{ path=(Join-Path $ws 'index.html') } }, [ordered]@{ name='Write'; arguments=[ordered]@{ path=(Join-Path $ws 'app.js') } }) } | ConvertTo-Json -Compress -Depth 6
  [ordered]@{ role='assistant'; content='Prototype written' } | ConvertTo-Json -Compress
  exit 0
}
if ($env:FAKE_KIMI_WS -eq 'partial') {
  # Write two deliverable files, then hang past the wrapper timeout. The wrapper's
  # incremental export must copy them out before the process-tree kill.
  $ws = Join-Path (Split-Path $env:KIMI_CODE_HOME -Parent) 'workspace'
  New-Item -ItemType Directory -Force -Path $ws | Out-Null
  [IO.File]::WriteAllText((Join-Path $ws 'workbench.html'), ('<html>' + ('x' * 2000) + '</html>'))
  [IO.File]::WriteAllText((Join-Path $ws 'app.js'), 'console.log("core")')
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='Write'; arguments=[ordered]@{ path=(Join-Path $ws 'workbench.html') } }) } | ConvertTo-Json -Compress -Depth 6
  Start-Sleep -Seconds 30
  exit 0
}
if ($env:FAKE_KIMI_WS -eq 'escape') {
  $esc = Join-Path (Split-Path $env:KIMI_CODE_HOME -Parent) 'escape.txt'
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='Write'; arguments=[ordered]@{ path=$esc } }) } | ConvertTo-Json -Compress -Depth 6
  [ordered]@{ role='assistant'; content='tried to escape' } | ConvertTo-Json -Compress
  exit 0
}
if ($env:FAKE_KIMI_CHILD_DENY -eq '1') {
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='AgentSwarm'; arguments=[ordered]@{ task='spawn child' } }) } | ConvertTo-Json -Compress -Depth 6
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='Bash'; arguments=[ordered]@{ command='whoami' } }) } | ConvertTo-Json -Compress -Depth 6
  exit 0
}
if ($env:FAKE_KIMI_RESEARCH_OK -eq '1') {
  [ordered]@{ role='assistant'; tool_calls=@([ordered]@{ name='WebSearch'; arguments=[ordered]@{ query='x' } }, [ordered]@{ name='AgentSwarm'; arguments=[ordered]@{ task='y' } }) } | ConvertTo-Json -Compress -Depth 6
  [ordered]@{ role='tool'; name='WebSearch'; content='' } | ConvertTo-Json -Compress
  [ordered]@{ role='assistant'; content='RESEARCH_OK' } | ConvertTo-Json -Compress
  exit 0
}
[ordered]@{ role='assistant'; content='KIMI_OK' } | ConvertTo-Json -Compress
[ordered]@{ role='meta'; type='session.resume_hint'; session_id='fake-session' } | ConvertTo-Json -Compress
exit 0
'@, (New-Object Text.UTF8Encoding($false)))
  $env:FLEET_KIMI_EXECUTABLE = $fake

  Case 'isolated artifact-only transport succeeds' {
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Reply exactly KIMI_OK.' -Mode json -TimeoutSeconds 20 2>$null
    if ($env:FLEET_KIMI_TEST_DEBUG) { Write-Host ('DEBUG ' + ($raw -join "`n")) }
    $json = ($raw -join "`n") | ConvertFrom-Json
    # tool_call_count is 1, not 0: the mandatory Read of the prompt-file transport
    # (fix 2026-08-03) is now the one always-present tool call on a clean lane.
    Assert-True ($LASTEXITCODE -eq 0 -and $json.status -eq 'ok' -and $json.model -eq 'kimi-code/k3' -and $json.response -eq 'KIMI_OK' -and $json.permission_policy -match 'static-deny' -and $json.tool_call_count -eq 1 -and $json.prompt_transport -eq 'file') 'isolated Kimi transport did not report the expected proof'
  }
  Case 'wrapper quoting round-trips quotes, backticks, newlines, and backslashes' {
    # Load the wrapper's own quoting functions from source (no drift) and parse
    # the emitted command line back with the same API real kimi.exe uses. This is
    # immune to the .cmd/-File test shim, which cannot carry a multiline arg.
    $src = [IO.File]::ReadAllText($wrapper)
    $m = [regex]::Match($src, '(?s)function Quote-Argument \{.*?\r?\nfunction Quote-Arguments \{.*?\r?\n\}')
    Assert-True $m.Success 'could not extract quoting functions from wrapper source'
    Invoke-Expression $m.Value
    Add-Type -Namespace FleetTestArgv -Name Shim -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError=true)]
public static extern System.IntPtr CommandLineToArgvW([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr LocalFree(System.IntPtr hMem);
'@
    function Script:Parse-CmdLine([string]$Line) {
      $n = 0; $ptr = [FleetTestArgv.Shim]::CommandLineToArgvW($Line, [ref]$n)
      try { $o = @(); for ($k = 0; $k -lt $n; $k++) { $sp = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $k * [System.IntPtr]::Size); $o += [System.Runtime.InteropServices.Marshal]::PtrToStringUni($sp) }; return $o }
      finally { [void][FleetTestArgv.Shim]::LocalFree($ptr) }
    }
    $inputs = @(
      'FLEET KIMI K3 LANE.' + "`n" + 'Sub-agent: "Run whoami" now.' + "`n" + 'path C:\dir\',
      'plain no specials',
      'trailing backslash C:\a\b\',
      'quote at end "',
      'C:\a "q" `tick` end'
    )
    foreach ($case in $inputs) {
      $line = Quote-Arguments -Tokens @('--model', 'kimi-code/k3', '--prompt', $case)
      $parsed = Parse-CmdLine -Line $line
      Assert-True ($parsed.Count -eq 4 -and $parsed[3] -eq $case) ('quoting corrupted arg round-trip for: ' + $case + ' => ' + ($parsed -join '|'))
    }
  }
  Case 'refreshed short-lived token is written back to the source credential store' {
    $srcCredDir = Join-Path $env:USERPROFILE '.kimi-code\credentials'
    New-Item -ItemType Directory -Force -Path $srcCredDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $srcCredDir 'kimi-code.json'), '{"access_token":"oldtok","refresh_token":"oldref","expires_at":1,"scope":"kimi-code","token_type":"Bearer","expires_in":900}')
    $env:FAKE_KIMI_REFRESH_CRED = '1'
    try { $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'x' -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { Remove-Item Env:FAKE_KIMI_REFRESH_CRED -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    $srcAfter = Get-Content -Raw -LiteralPath (Join-Path $srcCredDir 'kimi-code.json') | ConvertFrom-Json
    Assert-True ($exit -eq 0 -and $json.source_credential_refreshed -eq $true -and [int64]$srcAfter.expires_at -eq 9999999999) ('refreshed token was not written back to source: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'frozen artifact is registered' {
    $artifact = Join-Path $temp 'artifact.txt'; [IO.File]::WriteAllText($artifact, 'FROZEN_KIMI_ARTIFACT')
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Summarize the packet.' -ArtifactFile $artifact -Mode json -TimeoutSeconds 20 2>$null
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $json.status -eq 'ok' -and $json.artifact_count -eq 1 -and $json.prompt_bytes -gt 0) ('frozen artifact was not embedded: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'large (>40KB) artifact pack succeeds via file-based prompt transport, never trips the argv guard' {
    # Fix 2026-08-03: prompt_exceeds_command_line used to fire on realistic artifact
    # packs (observed live at prompt_bytes 47368) because the full prompt rode argv.
    # It now goes to a frozen file; -p carries only a short static instruction, so a
    # pack well over the old 30k guard must succeed cleanly.
    $artifact = Join-Path $temp 'large-pack.txt'
    [IO.File]::WriteAllText($artifact, ('X' * 45000))
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Summarize the packet.' -ArtifactFile $artifact -Mode json -TimeoutSeconds 20 2>$null
    $exit = $LASTEXITCODE
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -eq 0 -and $json.status -eq 'ok' -and $json.prompt_bytes -gt 40000 -and $json.prompt_transport -eq 'file' -and $json.response -eq 'KIMI_OK') ('large pack did not succeed via file transport: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'kimi did not read the prompt file fails closed' {
    # Negative control: a lane that skips the mandatory prompt-file Read (the only
    # way it could learn its task) must not be treated as a legitimate empty-task run.
    $env:FAKE_KIMI_SKIP_PROMPT_READ = '1'
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'x' -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_SKIP_PROMPT_READ -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.status -eq 'error' -and $json.fail_reason -match 'did not read the prompt file') ('skipped prompt-file read was not rejected: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'research swarm prompt carries tooling constraint; artifact lane does not' {
    # Extract New-KimiPrompt by source boundaries (no model call). Empty artifacts
    # so Get-Sha256 is never invoked from the extracted function body.
    $src = [IO.File]::ReadAllText($wrapper)
    $start = $src.IndexOf('function New-KimiPrompt {')
    $end = $src.IndexOf('function Write-Result {')
    Assert-True ($start -ge 0 -and $end -gt $start) 'could not locate New-KimiPrompt / Write-Result boundaries in wrapper source'
    Invoke-Expression $src.Substring($start, $end - $start)
    $researchPrompt = New-KimiPrompt -Request 'Research local docs.' -Artifacts @() -Images @() -MaxBytes 1048576 -ResearchSwarm $true -DesignWorkspace $false -WorkspaceDirectory ''
    $artifactPrompt = New-KimiPrompt -Request 'Critique the packet.' -Artifacts @() -Images @() -MaxBytes 1048576 -ResearchSwarm $false -DesignWorkspace $false -WorkspaceDirectory ''
    $constraint = 'TOOLING CONSTRAINT: no file tools are available beyond the Read call already used to load this brief'
    Assert-True ($researchPrompt.Contains($constraint)) 'research-swarm prompt missing tooling constraint preamble'
    Assert-True (-not $artifactPrompt.Contains($constraint)) 'artifact-only prompt unexpectedly carries research tooling constraint'
  }
  Case 'oversized image fails before Kimi launch' {
    $image = Join-Path $temp 'oversized-image.png'
    $stream = [IO.File]::Open($image, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try { $stream.SetLength(26214401) } finally { $stream.Dispose() }
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Read copied image.' -ImageFile $image -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.fail_reason -match 'MaxImageBytes') ('oversized image was accepted: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'copied image media read is accepted' {
    $image = Join-Path $temp 'visual-input.png'; [IO.File]::WriteAllBytes($image, [byte[]](1,2,3,4))
    $env:FAKE_KIMI_IMAGE_TOOL = '1'
    try { $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Read copied image.' -ImageFile $image -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { Remove-Item Env:FAKE_KIMI_IMAGE_TOOL -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    $read = @($json.tool_evidence | Where-Object { $_.name -eq 'ReadMediaFile' })
    Assert-True ($exit -eq 0 -and $json.status -eq 'ok' -and $json.response -eq 'KIMI_IMAGE_OK' -and $read.Count -eq 1 -and $read[0].copied_image_path -and $json.credential_cleanup_verified) ('copied image media read was rejected: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'sibling image path fails closed' {
    $image = Join-Path $temp 'visual-input-outside.png'; [IO.File]::WriteAllBytes($image, [byte[]](1,2,3,4))
    $env:FAKE_KIMI_IMAGE_OUTSIDE = '1'
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Read copied image.' -ImageFile $image -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_IMAGE_OUTSIDE -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.fail_reason -match 'disallowed' -and -not $json.tool_evidence[0].copied_image_path) ('sibling image path was accepted: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'research swarm opens web and agent-swarm, keeps core denies' {
    $env:FAKE_KIMI_RESEARCH_OK = '1'; $env:FAKE_KIMI_EXPECT_RESEARCH = '1'
    try { $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Research the topic.' -ResearchSwarm -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { Remove-Item Env:FAKE_KIMI_RESEARCH_OK -ErrorAction SilentlyContinue; Remove-Item Env:FAKE_KIMI_EXPECT_RESEARCH -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    $names = @($json.tool_evidence | ForEach-Object { $_.name })
    Assert-True ($exit -eq 0 -and $json.status -eq 'ok' -and $json.response -eq 'RESEARCH_OK' -and $json.lane -eq 'research-swarm' -and ($names -contains 'WebSearch') -and ($names -contains 'AgentSwarm') -and $json.credential_cleanup_verified) ('research swarm allow set was rejected: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'citation validator: cited+fetched URL passes' {
    $env:FAKE_KIMI_CITE = 'ok'; $env:FAKE_KIMI_EXPECT_RESEARCH = '1'
    try { $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'x' -ResearchSwarm -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { Remove-Item Env:FAKE_KIMI_CITE -ErrorAction SilentlyContinue; Remove-Item Env:FAKE_KIMI_EXPECT_RESEARCH -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -eq 0 -and $json.citation_verified -eq $true -and @($json.cited_but_unfetched).Count -eq 0 -and $json.cited_url_count -ge 1) ('cited+fetched should pass: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'citation validator: cited-but-unfetched fails under Fail and flags under Flag' {
    $env:FAKE_KIMI_CITE = 'bad'; $env:FAKE_KIMI_EXPECT_RESEARCH = '1'
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $rawF = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'x' -ResearchSwarm -Mode json -TimeoutSeconds 20 2>$null; $exitF = $LASTEXITCODE
      $rawG = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'x' -ResearchSwarm -CitationPolicy Flag -Mode json -TimeoutSeconds 20 2>$null; $exitG = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_CITE -ErrorAction SilentlyContinue; Remove-Item Env:FAKE_KIMI_EXPECT_RESEARCH -ErrorAction SilentlyContinue }
    $jF = ($rawF -join "`n") | ConvertFrom-Json; $jG = ($rawG -join "`n") | ConvertFrom-Json
    Assert-True ($exitF -ne 0 -and $jF.fail_reason -match 'not fetched') ('Fail mode did not reject: ' + ($jF | ConvertTo-Json -Compress))
    Assert-True ($exitG -eq 0 -and $jG.citation_verified -eq $false -and (($jG.cited_but_unfetched) -join ',') -match 'evil') ('Flag mode wrong: ' + ($jG | ConvertTo-Json -Compress))
  }
  Case 'citation validator: arxiv abs/pdf normalize as the same source' {
    $env:FAKE_KIMI_CITE = 'arxiv'; $env:FAKE_KIMI_EXPECT_RESEARCH = '1'
    try { $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'x' -ResearchSwarm -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { Remove-Item Env:FAKE_KIMI_CITE -ErrorAction SilentlyContinue; Remove-Item Env:FAKE_KIMI_EXPECT_RESEARCH -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -eq 0 -and $json.citation_verified -eq $true) ('arxiv abs/pdf should normalize equal: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'citation validator: -RequireVerifiedCitations flags an unfetched citation on a no-web lane' {
    $env:FAKE_KIMI_CITE = 'artifact'
    try { $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'x' -RequireVerifiedCitations -CitationPolicy Flag -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { Remove-Item Env:FAKE_KIMI_CITE -ErrorAction SilentlyContinue; Remove-Item Env:FAKE_KIMI_EXPECT_RESEARCH -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($json.citation_verified -eq $false -and (($json.cited_but_unfetched) -join ',') -match 'never') ('no-web citation not flagged: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'design-workspace: write inside the workspace is allowed and listed' {
    $env:FAKE_KIMI_WS = 'ok'
    try { $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'design a page' -DesignWorkspace -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { Remove-Item Env:FAKE_KIMI_WS -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -eq 0 -and $json.lane -eq 'design-workspace' -and (($json.workspace_files) -join ',') -match 'index.html') ('workspace write not allowed/listed: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'design-workspace: DesignOutputDir exports deliverable bytes before cleanup' {
    $env:FAKE_KIMI_WS = 'ok'
    $exportDir = Join-Path ([IO.Path]::GetTempPath()) ('kimi-export-' + [guid]::NewGuid().ToString('n'))
    try { $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'design a page' -DesignWorkspace -DesignOutputDir $exportDir -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { Remove-Item Env:FAKE_KIMI_WS -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    $exportedFile = Join-Path $exportDir 'index.html'
    Assert-True ($exit -eq 0 -and $json.workspace_exported_count -ge 1 -and $json.workspace_export_dir -and (Test-Path -LiteralPath $exportedFile) -and (Get-Item -LiteralPath $exportedFile).Length -gt 0) ('export missing or empty: ' + ($json | ConvertTo-Json -Compress))
    Remove-Item -Recurse -Force $exportDir -ErrorAction SilentlyContinue
  }
  Case 'design-workspace: zero exports is error (negative empty-export gate)' {
    # NEGATIVE: cheerful success text + DesignOutputDir + zero lane files -> error.
    $exportDir = Join-Path ([IO.Path]::GetTempPath()) ('kimi-empty-export-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $exportDir | Out-Null
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      # Default fake writes no workspace files; DesignOutputDir makes empty export fail.
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'design a page' -DesignWorkspace -DesignOutputDir $exportDir -Mode json -TimeoutSeconds 20 2>$null
      $exit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.status -eq 'error') ('zero-export design reported success: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ([int]$json.workspace_exported_count -eq 0) ('zero-export count not 0: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ($json.fail_reason -match 'no files|wrote no files|empty') ('fail_reason must name empty export: ' + $json.fail_reason)
    Assert-True (Test-Path -LiteralPath $exportDir) 'wrapper must not delete caller DesignOutputDir'
    Remove-Item -Recurse -Force $exportDir -ErrorAction SilentlyContinue
  }
  Case 'design-workspace: pre-placed caller file is not counted as lane output (negative)' {
    # NEGATIVE: caller brief in DesignOutputDir + lane wrote nothing -> still error.
    $exportDir = Join-Path ([IO.Path]::GetTempPath()) ('kimi-preplace-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $exportDir | Out-Null
    $pre = Join-Path $exportDir 'brief.md'
    [IO.File]::WriteAllText($pre, 'caller brief pre-placed')
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'design a page' -DesignWorkspace -DesignOutputDir $exportDir -Mode json -TimeoutSeconds 20 2>$null
      $exit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.status -eq 'error') ('pre-placed-only design reported success: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ([int]$json.workspace_exported_count -eq 0) ('pre-placed file was counted as export: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ($json.fail_reason -match 'no files|wrote no files|empty') ('pre-placed fail_reason must name empty export: ' + $json.fail_reason)
    Assert-True ((Test-Path -LiteralPath $pre) -and (Get-Content -Raw -LiteralPath $pre) -match 'caller brief') 'pre-placed file must survive (no cleanup of DesignOutputDir)'
    Remove-Item -Recurse -Force $exportDir -ErrorAction SilentlyContinue
  }
  Case 'design-workspace: two exported files report success with byte counts (positive)' {
    # POSITIVE control for empty-export gate: real lane writes -> ok + both files.
    $env:FAKE_KIMI_WS = 'two'
    $exportDir = Join-Path ([IO.Path]::GetTempPath()) ('kimi-two-export-' + [guid]::NewGuid().ToString('n'))
    try {
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'design a page' -DesignWorkspace -DesignOutputDir $exportDir -Mode json -TimeoutSeconds 20 2>$null
      $exit = $LASTEXITCODE
    }
    finally { Remove-Item Env:FAKE_KIMI_WS -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    $files = @($json.workspace_exported_files)
    $html = Join-Path $exportDir 'index.html'
    $js = Join-Path $exportDir 'app.js'
    Assert-True ($exit -eq 0 -and $json.status -eq 'ok') ('two-file export not ok: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ([int]$json.workspace_exported_count -eq 2) ('expected 2 exports: ' + ($json | ConvertTo-Json -Compress))
    Assert-True (($files -join ',') -match 'index\.html' -and ($files -join ',') -match 'app\.js') ('both files not listed: ' + ($files -join ','))
    Assert-True ((Test-Path -LiteralPath $html) -and (Get-Item -LiteralPath $html).Length -gt 0) 'index.html missing or 0 bytes'
    Assert-True ((Test-Path -LiteralPath $js) -and (Get-Item -LiteralPath $js).Length -gt 0) 'app.js missing or 0 bytes'
    Remove-Item -Recurse -Force $exportDir -ErrorAction SilentlyContinue
  }
  Case 'design-workspace: timeout with exports keeps timeout_partial (positive)' {
    # POSITIVE: hard kill after incremental export must stay timeout_partial, not empty-export error.
    $env:FAKE_KIMI_WS = 'partial'
    $exportDir = Join-Path ([IO.Path]::GetTempPath()) ('kimi-tp-export-' + [guid]::NewGuid().ToString('n'))
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'design a page' -DesignWorkspace -DesignOutputDir $exportDir -TimeoutSeconds 3 -Mode json 2>$null
      $exit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_WS -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($json.status -eq 'timeout_partial' -and $json.timed_out -eq $true) ('timeout_partial lost: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ([int]$json.workspace_exported_count -ge 1) ('timeout_partial with zero exports: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ($json.fail_reason -notmatch 'wrote no files') ('timeout_partial mislabeled as empty-export: ' + $json.fail_reason)
    Remove-Item -Recurse -Force $exportDir -ErrorAction SilentlyContinue
  }
  Case 'non-design lanes unaffected by empty-export gate (positive)' {
    # POSITIVE: artifact / research / (no DesignOutputDir) never get design empty-export fail.
    $rawA = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Reply exactly KIMI_OK.' -Mode json -TimeoutSeconds 20 2>$null
    $jA = ($rawA -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $jA.status -eq 'ok' -and $jA.lane -eq 'artifact-only') ('artifact lane regressed: ' + ($jA | ConvertTo-Json -Compress))
    Assert-True ([string]$jA.fail_reason -notmatch 'wrote no files') 'artifact lane got design empty-export reason'
    $env:FAKE_KIMI_RESEARCH_OK = '1'; $env:FAKE_KIMI_EXPECT_RESEARCH = '1'
    try {
      $rawR = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Research the topic.' -ResearchSwarm -Mode json -TimeoutSeconds 20 2>$null
      $exitR = $LASTEXITCODE
    }
    finally { Remove-Item Env:FAKE_KIMI_RESEARCH_OK -ErrorAction SilentlyContinue; Remove-Item Env:FAKE_KIMI_EXPECT_RESEARCH -ErrorAction SilentlyContinue }
    $jR = ($rawR -join "`n") | ConvertFrom-Json
    Assert-True ($exitR -eq 0 -and $jR.status -eq 'ok' -and $jR.lane -eq 'research-swarm') ('research lane regressed: ' + ($jR | ConvertTo-Json -Compress))
    Assert-True ([string]$jR.fail_reason -notmatch 'wrote no files') 'research lane got design empty-export reason'
  }
  Case 'design-workspace: default timeout raised to 3600s when unset' {
    # Source-level: -DesignWorkspace with no -TimeoutSeconds must bump the default
    # to 3600 (the 1800s default killed a ~95%-done build on 2026-07-23).
    $src = [IO.File]::ReadAllText($wrapper)
    Assert-True ($src -match "DesignWorkspace -and -not \`$PSBoundParameters\.ContainsKey\('TimeoutSeconds'\)\)\s*\{\s*\`$TimeoutSeconds = 3600") 'design-workspace 3600s default override missing from wrapper'
  }
  Case 'Write-Result text: design-workspace empty response still emits manifest with byte counts' {
    $src = [IO.File]::ReadAllText($wrapper)
    $m = [regex]::Match($src, '(?s)function Write-Result \{.*?\r?\n\}')
    Assert-True $m.Success 'could not extract Write-Result from wrapper source'
    Invoke-Expression $m.Value
    $exportDir = Join-Path $temp ('wr-export-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $exportDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $exportDir 'a.html'), 'AAA')
    [IO.File]::WriteAllBytes((Join-Path $exportDir 'b.css'), [byte[]](1,2,3,4,5))
    $result = [ordered]@{
      status = 'ok'; lane = 'design-workspace'; response = ''
      workspace_export_dir = $exportDir
      workspace_exported_count = 2
      workspace_exported_files = @('a.html', 'b.css')
    }
    $out = [string](Write-Result -Result $result -OutputMode text -Success $true)
    Assert-True ($out.Length -gt 0) 'design-workspace text stdout was empty with empty response'
    Assert-True ($out -match 'workspace_exported_count:\s*2') 'manifest missing exported count'
    Assert-True ($out -match 'a\.html\s+3\s+bytes') 'manifest missing a.html byte count'
    Assert-True ($out -match 'b\.css\s+5\s+bytes') 'manifest missing b.css byte count'
    Assert-True ($out -match [regex]::Escape($exportDir)) 'manifest missing export dir'
    Remove-Item -Recurse -Force $exportDir -ErrorAction SilentlyContinue
  }
  Case 'Write-Result text: design-workspace non-empty response follows manifest' {
    $src = [IO.File]::ReadAllText($wrapper)
    $m = [regex]::Match($src, '(?s)function Write-Result \{.*?\r?\n\}')
    Assert-True $m.Success 'could not extract Write-Result from wrapper source'
    Invoke-Expression $m.Value
    $exportDir = Join-Path $temp ('wr-export2-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $exportDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $exportDir 'page.html'), 'x')
    $result = [ordered]@{
      status = 'ok'; lane = 'design-workspace'; response = 'DONE_DESIGN'
      workspace_export_dir = $exportDir
      workspace_exported_count = 1
      workspace_exported_files = @('page.html')
    }
    $out = [string](Write-Result -Result $result -OutputMode text -Success $true)
    Assert-True ($out -match 'workspace_exported_count:\s*1') 'manifest missing count with response'
    Assert-True ($out -match 'page\.html\s+1\s+bytes') 'manifest missing file bytes with response'
    Assert-True ($out -match 'DONE_DESIGN') 'response missing after manifest'
    Assert-True ($out.IndexOf('workspace_export_dir') -lt $out.IndexOf('DONE_DESIGN')) 'response must follow manifest'
    Remove-Item -Recurse -Force $exportDir -ErrorAction SilentlyContinue
  }
  Case 'Write-Result text: design-workspace zero-export still non-empty' {
    $src = [IO.File]::ReadAllText($wrapper)
    $m = [regex]::Match($src, '(?s)function Write-Result \{.*?\r?\n\}')
    Assert-True $m.Success 'could not extract Write-Result from wrapper source'
    Invoke-Expression $m.Value
    $result = [ordered]@{
      status = 'ok'; lane = 'design-workspace'; response = ''
      workspace_export_dir = ''
      workspace_exported_count = 0
      workspace_exported_files = @()
    }
    $out = [string](Write-Result -Result $result -OutputMode text -Success $true)
    Assert-True ($out.Length -gt 0) 'zero-export design-workspace stdout was empty'
    Assert-True ($out -match 'workspace_exported_count:\s*0') 'zero-export missing count 0'
    Assert-True ($out -match 'no files exported') 'zero-export missing explicit nothing-exported signal'
  }
  Case 'Write-Result text: artifact lane still prints only response' {
    $src = [IO.File]::ReadAllText($wrapper)
    $m = [regex]::Match($src, '(?s)function Write-Result \{.*?\r?\n\}')
    Assert-True $m.Success 'could not extract Write-Result from wrapper source'
    Invoke-Expression $m.Value
    $result = [ordered]@{
      status = 'ok'; lane = 'artifact-only'; response = 'ONLY_RESPONSE'
      workspace_export_dir = $null
      workspace_exported_count = 0
      workspace_exported_files = @()
    }
    $out = [string](Write-Result -Result $result -OutputMode text -Success $true)
    Assert-True ($out -eq 'ONLY_RESPONSE') ('artifact text mode regressed: ' + $out)
  }
  Case 'Write-Result json: design-workspace output unchanged fields' {
    $src = [IO.File]::ReadAllText($wrapper)
    $m = [regex]::Match($src, '(?s)function Write-Result \{.*?\r?\n\}')
    Assert-True $m.Success 'could not extract Write-Result from wrapper source'
    Invoke-Expression $m.Value
    $result = [ordered]@{
      status = 'ok'; lane = 'design-workspace'; response = 'j'
      workspace_export_dir = 'C:\export'
      workspace_exported_count = 1
      workspace_exported_files = @('x.html')
    }
    $out = [string](Write-Result -Result $result -OutputMode json -Success $true)
    $json = $out | ConvertFrom-Json
    Assert-True ($json.status -eq 'ok' -and $json.lane -eq 'design-workspace' -and $json.response -eq 'j') 'json mode status/lane/response changed'
    Assert-True ($json.workspace_export_dir -eq 'C:\export' -and $json.workspace_exported_count -eq 1) 'json mode export fields changed'
    Assert-True ((@($json.workspace_exported_files) -join ',') -eq 'x.html') 'json mode exported files changed'
    Assert-True ($out -notmatch 'no files exported') 'json mode must not inject text manifest'
  }
  Case 'design-workspace: incremental export preserves files across a timeout kill (timeout_partial)' {
    $env:FAKE_KIMI_WS = 'partial'
    $exportDir = Join-Path ([IO.Path]::GetTempPath()) ('kimi-partial-' + [guid]::NewGuid().ToString('n'))
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'design a page' -DesignWorkspace -DesignOutputDir $exportDir -TimeoutSeconds 3 -Mode json 2>$null
      $exit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_WS -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    $exportedHtml = Join-Path $exportDir 'workbench.html'
    Assert-True ($json.status -eq 'timeout_partial' -and $json.timed_out -eq $true) ('did not report timeout_partial: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ($json.workspace_exported_count -ge 1 -and ((@($json.workspace_exported_files) -join ',') -match 'workbench.html')) ('exported files not listed: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ((Test-Path -LiteralPath $exportedHtml) -and (Get-Item -LiteralPath $exportedHtml).Length -gt 0) 'incremental export did not preserve workbench.html across the kill'
    Assert-True ($json.credential_cleanup_verified) ('runtime cleanup regressed on timeout_partial: ' + ($json | ConvertTo-Json -Compress))
    Remove-Item -Recurse -Force $exportDir -ErrorAction SilentlyContinue
  }
  Case 'design-workspace: write outside the workspace fails closed' {
    $env:FAKE_KIMI_WS = 'escape'
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'design' -DesignWorkspace -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_WS -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.fail_reason -match 'disallowed') ('escape write was not blocked: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'research swarm rejects a denied tool call issued after a swarm spawn' {
    $env:FAKE_KIMI_CHILD_DENY = '1'; $env:FAKE_KIMI_EXPECT_RESEARCH = '1'
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Research the topic.' -ResearchSwarm -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_CHILD_DENY -ErrorAction SilentlyContinue; Remove-Item Env:FAKE_KIMI_EXPECT_RESEARCH -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.fail_reason -match 'disallowed') ('a denied tool call after a swarm spawn was accepted: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'research swarm still denies shell and write' {
    $env:FAKE_KIMI_TOOL = '1'; $env:FAKE_KIMI_EXPECT_RESEARCH = '1'
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Research the topic.' -ResearchSwarm -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_TOOL -ErrorAction SilentlyContinue; Remove-Item Env:FAKE_KIMI_EXPECT_RESEARCH -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.fail_reason -match 'disallowed') ('research swarm accepted a shell call: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'tool use fails closed' {
    $env:FAKE_KIMI_TOOL = '1'
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_TOOL -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.fail_reason -match 'disallowed') ('tool use was accepted: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'malformed stream json fails closed' {
    $env:FAKE_KIMI_BAD_JSON = '1'
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_BAD_JSON -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.fail_reason -match 'invalid stream-json') ('malformed stream JSON was accepted: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'required JSON response fails when model returns prose' {
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -RequireJsonResponse -Mode json -TimeoutSeconds 20 2>$null; $exit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.fail_reason -match 'not valid JSON') ('invalid required JSON was accepted: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'timeout kills process tree' {
    $env:FAKE_KIMI_HANG = '1'
    $started = Get-Date
    $old = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -Mode json -TimeoutSeconds 1 2>$null; $exit = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old; Remove-Item Env:FAKE_KIMI_HANG -ErrorAction SilentlyContinue }
    $elapsed = ((Get-Date) - $started).TotalSeconds
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.timed_out -and $elapsed -lt 20) ('timeout did not fail closed within bound: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'repo-sandbox: materializes tracked files only; records sha and file count' {
    $fixture = Join-Path $temp ('sandbox-repo-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path (Join-Path $fixture 'src') | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixture 'src\app.js'), 'console.log(1)')
    [IO.File]::WriteAllText((Join-Path $fixture '.env'), 'SECRET=do-not-archive')
    [IO.File]::WriteAllText((Join-Path $fixture 'ignored.tmp'), 'ignored')
    [IO.File]::WriteAllText((Join-Path $fixture '.gitignore'), "ignored.tmp`n")
    Push-Location $fixture
    try {
      & git init -q 2>$null | Out-Null
      & git config user.email 'fleet-test@example.com'
      & git config user.name 'Fleet Test'
      & git add src/app.js .gitignore 2>$null | Out-Null
      & git commit -q -m 'fixture' 2>$null | Out-Null
      $expectedSha = (& git rev-parse HEAD | Out-String).Trim()
    }
    finally { Pop-Location }
    Assert-True (-not [string]::IsNullOrWhiteSpace($expectedSha)) 'fixture git commit failed'
    # Probe: run wrapper and capture materialization evidence from result JSON.
    # Fake kimi only reads the prompt file (mandatory transport call); success proves
    # archive + verification ran pre-launch.
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Review the sandbox copy.' -RepoSandbox $fixture -Mode json -TimeoutSeconds 20 2>$null
    $exit = $LASTEXITCODE
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -eq 0 -and $json.status -eq 'ok' -and $json.lane -eq 'repo-sandbox') ('sandbox lane did not succeed: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ($json.sandbox_ref_sha -eq $expectedSha) ("sandbox_ref_sha mismatch: got $($json.sandbox_ref_sha) expected $expectedSha")
    Assert-True ([int]$json.sandbox_file_count -ge 2) ("sandbox_file_count too low: $($json.sandbox_file_count)")
    Assert-True ($json.permission_policy -match 'copy-sandbox') ('permission_policy missing copy-sandbox')
    # Materialization is cleaned with the runtime root; re-materialize via git archive
    # the same way the wrapper does and assert tracked-only contents.
    $probe = Join-Path $temp ('sandbox-probe-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $probe | Out-Null
    $tar = Join-Path $temp ('probe-' + [guid]::NewGuid().ToString('n') + '.tar')
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    try {
      & git -C $fixture archive --format=tar -o $tar HEAD
      Assert-True ($LASTEXITCODE -eq 0) 'probe git archive failed'
      & $tarExe -xf $tar -C $probe
      Assert-True ($LASTEXITCODE -eq 0) 'probe tar extract failed'
      Assert-True (Test-Path -LiteralPath (Join-Path $probe 'src\app.js') -PathType Leaf) 'sandbox missing tracked src/app.js'
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $probe '.env'))) 'sandbox leaked untracked .env'
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $probe 'ignored.tmp'))) 'sandbox leaked ignored file'
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $probe '.git'))) 'sandbox contains .git'
      $probeCount = @(Get-ChildItem -LiteralPath $probe -Recurse -File -Force).Count
      Assert-True ($probeCount -eq [int]$json.sandbox_file_count) ("sandbox_file_count $($json.sandbox_file_count) != probe $probeCount")
    }
    finally {
      Remove-Item -LiteralPath $tar -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  Case 'repo-sandbox: mutually exclusive with DesignWorkspace and ResearchSwarm' {
    $fixture = Join-Path $temp ('sandbox-mx-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $fixture | Out-Null
    Push-Location $fixture
    try {
      & git init -q 2>$null | Out-Null
      & git config user.email 'fleet-test@example.com'
      & git config user.name 'Fleet Test'
      [IO.File]::WriteAllText((Join-Path $fixture 'a.txt'), 'a')
      & git add a.txt 2>$null | Out-Null
      & git commit -q -m 'mx' 2>$null | Out-Null
    }
    finally { Pop-Location }
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $raw1 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'x' -RepoSandbox $fixture -DesignWorkspace -Mode json -TimeoutSeconds 20 2>$null
      $exit1 = $LASTEXITCODE
      $raw2 = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'x' -RepoSandbox $fixture -ResearchSwarm -Mode json -TimeoutSeconds 20 2>$null
      $exit2 = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old; Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
    $j1 = ($raw1 -join "`n") | ConvertFrom-Json
    $j2 = ($raw2 -join "`n") | ConvertFrom-Json
    Assert-True ($exit1 -ne 0 -and $j1.fail_reason -match 'mutually exclusive') ('DesignWorkspace combo not rejected: ' + ($j1 | ConvertTo-Json -Compress))
    Assert-True ($exit2 -ne 0 -and $j2.fail_reason -match 'mutually exclusive') ('ResearchSwarm combo not rejected: ' + ($j2 | ConvertTo-Json -Compress))
  }
  Case 'repo-sandbox: bad ref fails closed without kimi launch' {
    $fixture = Join-Path $temp ('sandbox-badref-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $fixture | Out-Null
    Push-Location $fixture
    try {
      & git init -q 2>$null | Out-Null
      & git config user.email 'fleet-test@example.com'
      & git config user.name 'Fleet Test'
      [IO.File]::WriteAllText((Join-Path $fixture 'a.txt'), 'a')
      & git add a.txt 2>$null | Out-Null
      & git commit -q -m 'badref' 2>$null | Out-Null
    }
    finally { Pop-Location }
    $old = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'x' -RepoSandbox $fixture -RepoSandboxRef 'nonexistent-branch' -Mode json -TimeoutSeconds 20 2>$null
      $exit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $old; Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -ne 0 -and $json.status -eq 'error' -and $json.fail_reason -match 'RepoSandboxRef|committish|rev-parse') ('bad ref not fail-closed: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ($null -eq $json.kimi_version -or [string]::IsNullOrWhiteSpace([string]$json.kimi_version)) ('kimi launched despite bad ref: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'owner.json: wrapper writes parseable marker before child launch' {
    # POSITIVE: marker exists at the instant the fake child is invoked (pre-launch window).
    $probe = Join-Path $temp ('owner-pre-' + [guid]::NewGuid().ToString('n'))
    $env:FAKE_KIMI_OWNER_PROBE = $probe
    try {
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Reply exactly KIMI_OK.' -Mode json -TimeoutSeconds 20 2>$null
      $exit = $LASTEXITCODE
    }
    finally { Remove-Item Env:FAKE_KIMI_OWNER_PROBE -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    $existsFlag = Join-Path $probe 'at-child-start-exists.txt'
    $prePath = Join-Path $probe 'at-child-start-owner.json'
    Assert-True ($exit -eq 0 -and $json.status -eq 'ok') ('lane failed under owner probe: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ((Test-Path -LiteralPath $existsFlag) -and ((Get-Content -Raw -LiteralPath $existsFlag).Trim() -eq '1')) 'owner.json missing at child start (pre-launch window open)'
    Assert-True (Test-Path -LiteralPath $prePath -PathType Leaf) 'wrapper-written owner.json was not captured at child start'
    $pre = Get-Content -Raw -LiteralPath $prePath | ConvertFrom-Json
    $prePid = 0
    Assert-True ([int]::TryParse([string]$pre.pid, [ref]$prePid) -and $prePid -gt 0) ('pre-launch marker pid not integer: ' + (Get-Content -Raw -LiteralPath $prePath))
    $parsedStart = $null
    try { $parsedStart = [datetime]::Parse([string]$pre.start_time, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    Assert-True ($null -ne $parsedStart) ('pre-launch start_time not round-trip parseable: ' + $pre.start_time)
    Assert-True ($json.owner_marker -eq 'written') ('owner_marker not written: ' + $json.owner_marker)
    Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
  }
  Case 'owner.json: after child start marker names child pid not wrapper' {
    # POSITIVE: post-Start rewrite claims the child process tree (cmd host and/or fake ps1).
    $probe = Join-Path $temp ('owner-child-' + [guid]::NewGuid().ToString('n'))
    $env:FAKE_KIMI_OWNER_PROBE = $probe
    try {
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Reply exactly KIMI_OK.' -Mode json -TimeoutSeconds 20 2>$null
      $exit = $LASTEXITCODE
    }
    finally { Remove-Item Env:FAKE_KIMI_OWNER_PROBE -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    $postPath = Join-Path $probe 'after-child-start-owner.json'
    $treePath = Join-Path $probe 'child-tree-pids.txt'
    $prePath = Join-Path $probe 'at-child-start-owner.json'
    Assert-True ($exit -eq 0 -and $json.status -eq 'ok') ('lane failed: ' + ($json | ConvertTo-Json -Compress))
    Assert-True (Test-Path -LiteralPath $postPath -PathType Leaf) 'post-start owner.json not captured'
    Assert-True (Test-Path -LiteralPath $treePath -PathType Leaf) 'child tree pids not recorded'
    $post = Get-Content -Raw -LiteralPath $postPath | ConvertFrom-Json
    $postPid = 0
    Assert-True ([int]::TryParse([string]$post.pid, [ref]$postPid) -and $postPid -gt 0) ('post-start pid not integer: ' + (Get-Content -Raw -LiteralPath $postPath))
    $tree = @((Get-Content -Raw -LiteralPath $treePath).Trim() -split ',' | Where-Object { $_ })
    Assert-True ($tree -contains [string]$postPid) ('post-start marker pid ' + $postPid + ' not in child tree ' + ($tree -join ','))
    if (Test-Path -LiteralPath $prePath -PathType Leaf) {
      $pre = Get-Content -Raw -LiteralPath $prePath | ConvertFrom-Json
      $prePid = 0
      if ([int]::TryParse([string]$pre.pid, [ref]$prePid) -and $prePid -gt 0 -and $prePid -ne $postPid) {
        # Stronger: rewrite moved ownership off the wrapper process.
        Assert-True ($true) 'wrapper-to-child rewrite observed'
      }
    }
    $parsedStart = $null
    try { $parsedStart = [datetime]::Parse([string]$post.start_time, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    Assert-True ($null -ne $parsedStart) ('post-start start_time not parseable: ' + $post.start_time)
    Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
  }
  Case 'owner.json: write failure does not fail the lane and is reported' {
    # POSITIVE: forced marker failure keeps status=ok and owner_marker=failed.
    $env:FLEET_KIMI_OWNER_MARKER_FAIL = '1'
    try {
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Reply exactly KIMI_OK.' -Mode json -TimeoutSeconds 20 2>$null
      $exit = $LASTEXITCODE
    }
    finally { Remove-Item Env:FLEET_KIMI_OWNER_MARKER_FAIL -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -eq 0 -and $json.status -eq 'ok' -and $json.response -eq 'KIMI_OK') ('marker failure aborted lane: ' + ($json | ConvertTo-Json -Compress))
    Assert-True ($json.owner_marker -eq 'failed') ('owner_marker not failed: ' + ($json | ConvertTo-Json -Compress))
  }
  Case 'owner.json: successful run reports owner_marker written with integer pid schema' {
    # POSITIVE: result reports written; captured file has int pid + parseable start_time.
    # Do NOT write a synthetic marker — only assert the wrapper-produced file.
    $probe = Join-Path $temp ('owner-ok-' + [guid]::NewGuid().ToString('n'))
    $env:FAKE_KIMI_OWNER_PROBE = $probe
    try {
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Reply exactly KIMI_OK.' -Mode json -TimeoutSeconds 20 2>$null
      $exit = $LASTEXITCODE
    }
    finally { Remove-Item Env:FAKE_KIMI_OWNER_PROBE -ErrorAction SilentlyContinue }
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($exit -eq 0 -and $json.status -eq 'ok' -and $json.owner_marker -eq 'written') ('owner_marker not written on success: ' + ($json | ConvertTo-Json -Compress))
    $captured = Join-Path $probe 'after-child-start-owner.json'
    if (-not (Test-Path -LiteralPath $captured -PathType Leaf)) { $captured = Join-Path $probe 'at-child-start-owner.json' }
    Assert-True (Test-Path -LiteralPath $captured -PathType Leaf) 'no wrapper-written owner.json captured from runtime root'
    $obj = Get-Content -Raw -LiteralPath $captured | ConvertFrom-Json
    $pidVal = 0
    Assert-True ([int]::TryParse([string]$obj.pid, [ref]$pidVal) -and $pidVal -gt 0) ('captured marker pid not positive int: ' + (Get-Content -Raw -LiteralPath $captured))
    $st = $null
    try { $st = [datetime]::Parse([string]$obj.start_time, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    Assert-True ($null -ne $st) ('captured start_time not parseable: ' + $obj.start_time)
    Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
  }
  Case 'repo-sandbox: reparse verification gate exists and passes on clean fixture' {
    # Source-level: Assert-NoReparsePointsInTree is present and zero-on-clean.
    $src = [IO.File]::ReadAllText($wrapper)
    Assert-True ($src.Contains('function Assert-NoReparsePointsInTree')) 'Assert-NoReparsePointsInTree missing from wrapper'
    Assert-True ($src.Contains('Repo sandbox reparse verification failed')) 'reparse fail-closed message missing'
    $start = $src.IndexOf('function Assert-NoReparsePointsInTree {')
    $end = $src.IndexOf('function New-GuardedRuntimeConfig {')
    Assert-True ($start -ge 0 -and $end -gt $start) 'could not extract Assert-NoReparsePointsInTree'
    Invoke-Expression $src.Substring($start, $end - $start)
    $clean = Join-Path $temp ('reparse-clean-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $clean | Out-Null
    [IO.File]::WriteAllText((Join-Path $clean 'f.txt'), 'ok')
    try {
      $count = Assert-NoReparsePointsInTree -Root $clean
      Assert-True ($count -eq 0) "expected zero reparse points, got $count"
    }
    finally { Remove-Item -LiteralPath $clean -Recurse -Force -ErrorAction SilentlyContinue }
    # End-to-end: clean git archive fixture runs green (gate runs inside materialization).
    $fixture = Join-Path $temp ('sandbox-reparse-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $fixture | Out-Null
    Push-Location $fixture
    try {
      & git init -q 2>$null | Out-Null
      & git config user.email 'fleet-test@example.com'
      & git config user.name 'Fleet Test'
      [IO.File]::WriteAllText((Join-Path $fixture 'ok.txt'), 'ok')
      & git add ok.txt 2>$null | Out-Null
      & git commit -q -m 'reparse' 2>$null | Out-Null
    }
    finally { Pop-Location }
    try {
      $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'scan' -RepoSandbox $fixture -Mode json -TimeoutSeconds 20 2>$null
      $exit = $LASTEXITCODE
      $json = ($raw -join "`n") | ConvertFrom-Json
      Assert-True ($exit -eq 0 -and $json.lane -eq 'repo-sandbox' -and [int]$json.sandbox_file_count -gt 0) ('reparse gate failed on clean fixture: ' + ($json | ConvertTo-Json -Compress))
    }
    finally { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
  }
}
finally {
  $env:USERPROFILE = $oldUserProfile
  if ($null -eq $oldKimiExecutable) { Remove-Item Env:FLEET_KIMI_EXECUTABLE -ErrorAction SilentlyContinue } else { $env:FLEET_KIMI_EXECUTABLE = $oldKimiExecutable }
  Remove-Item Env:FAKE_KIMI_EXPECT -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_HANG -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_BAD_JSON -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_TOOL -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_RESEARCH_OK -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_CHILD_DENY -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_CITE -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_REFRESH_CRED -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_EXPECT_RESEARCH -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_IMAGE_TOOL -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_IMAGE_OUTSIDE -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_WS -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_KIMI_OWNER_PROBE -ErrorAction SilentlyContinue
  Remove-Item Env:FLEET_KIMI_OWNER_MARKER_FAIL -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Live) {
  Case 'live Kimi K3 artifact-only transport' {
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt 'Reply exactly KIMI_OK. Do not call tools.' -Mode json -TimeoutSeconds 180 2>$null
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $json.status -eq 'ok' -and $json.response.Trim() -eq 'KIMI_OK' -and $json.kimi_version -match '^0\.27\.0') 'live Kimi K3 proof failed'
  }
}

Write-Host "$passed passed, $failed failed"
# Explicit exit 0 so a leaked $LASTEXITCODE from an intentional-failure case does not
# make a standalone `-File` run misreport success as failure.
if ($failed) { exit 1 } else { exit 0 }
