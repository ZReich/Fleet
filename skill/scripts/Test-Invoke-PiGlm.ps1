# Offline tests for Invoke-PiGlm.ps1 using a fake pi on a temporary PATH.
# No network. Optional -Live switch runs real Pi probe after offline suite.
param(
  [switch]$Live
)

$ErrorActionPreference = "Stop"
$Wrapper = Join-Path $PSScriptRoot "Invoke-PiGlm.ps1"
if (-not (Test-Path -LiteralPath $Wrapper)) {
  throw "Wrapper missing: $Wrapper"
}

$script:Pass = 0
$script:Fail = 0
$script:Results = New-Object System.Collections.Generic.List[string]

function Assert-True {
  param([bool]$Condition, [string]$Name)
  if ($Condition) {
    $script:Pass++
    [void]$script:Results.Add("PASS $Name")
    Write-Host "PASS $Name"
  }
  else {
    $script:Fail++
    [void]$script:Results.Add("FAIL $Name")
    Write-Host "FAIL $Name"
  }
}

function New-FakePiRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-fake-pi-" + [guid]::NewGuid().ToString("n"))
  New-Item -ItemType Directory -Path $root | Out-Null
  return $root
}

function Write-FakePi {
  param(
    [string]$Root,
    [ValidateSet(
      "ok",
      "timeout_child",
      "never_read_stdin",
      "missing_agent_end",
      "malformed_then_ok",
      "wrong_provider",
      "wrong_model",
      "aborted",
      "secret_stderr",
      "large_stream"
    )]
    [string]$Behavior
  )

  # .cmd so Resolve-PiLaunch treats it as Application (not .ps1)
  $cmdPath = Join-Path $Root "pi.cmd"
  $ps1Path = Join-Path $Root "fake-pi-impl.ps1"

  $impl = @'
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$AllArgs
)
$ErrorActionPreference = "Stop"
$behavior = $env:FAKE_PI_BEHAVIOR

if ($env:FAKE_PI_ARGS -notmatch '(^|\s)-p(\s|$)' -or $env:FAKE_PI_ARGS -match '--mode(?:\s|$)') {
  [Console]::Error.WriteLine("bad fake pi args: $($env:FAKE_PI_ARGS)")
  exit 7
}
if ($env:FAKE_PI_ARGS -notmatch '(?:^|\s)--provider\s+zai(?:\s|$)' -or $env:FAKE_PI_ARGS -notmatch '(?:^|\s)--model\s+glm-5\.2(?:\s|$)' -or $env:FAKE_PI_ARGS -notmatch '(?:^|\s)--no-session(?:\s|$)' -or $env:FAKE_PI_ARGS -notmatch '(?:^|\s)--no-extensions(?:\s|$)') { exit 7 }
if ($env:FAKE_PI_ARGS -match '(?:^|\s)--tools(?:\s|$)') {
  if ($env:FAKE_PI_ARGS -notmatch '(?:^|\s)--no-approve(?:\s|$)' -or $env:FAKE_PI_ARGS -notmatch '(?:^|\s)--no-extensions(?:\s|$)' -or $env:FAKE_PI_ARGS -notmatch '(?:^|\s)--tools\s+read,grep,find,ls(?:\s|$)' -or $env:FAKE_PI_ARGS -match '(?:^|\s)--approve(?:\s|$)') { exit 7 }
}
elseif ($env:FAKE_PI_ARGS -match '(?:^|\s)--no-tools(?:\s|$)') {
  if ($env:FAKE_PI_ARGS -notmatch '(?:^|\s)--no-approve(?:\s|$)' -or $env:FAKE_PI_ARGS -match '(?:^|\s)--approve(?:\s|$)') { exit 7 }
}
elseif ($env:FAKE_PI_ARGS -notmatch '(?:^|\s)--approve(?:\s|$)') { exit 7 }

function Emit($obj) {
  ($obj | ConvertTo-Json -Compress -Depth 8)
}

if ($behavior -eq "never_read_stdin") {
  $child = Start-Process -FilePath "ping.exe" -ArgumentList "-n","60","127.0.0.1" -WindowStyle Hidden -PassThru
  Start-Sleep -Seconds 30
  exit 0
}

# Match Pi's implementation: UTF-8 decode, then trim piped stdin.
$stdinReader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding($false)), $true)
$promptText = $stdinReader.ReadToEnd().Trim()
if ([string]::IsNullOrEmpty($promptText)) { exit 9 }
if ($env:FAKE_PI_EXPECTED_PROMPT_LENGTH) {
  $actualPromptLength = $promptText.Length
  if ($actualPromptLength -ne [int]$env:FAKE_PI_EXPECTED_PROMPT_LENGTH) {
    [Console]::Error.WriteLine("prompt length mismatch: actual=$actualPromptLength expected=$([int]$env:FAKE_PI_EXPECTED_PROMPT_LENGTH)")
    exit 10
  }
}
if ($env:FAKE_PI_EXPECTED_TEXT -and -not $promptText.Contains($env:FAKE_PI_EXPECTED_TEXT)) { exit 11 }

switch ($behavior) {
  "timeout_child" {
    # spawn a long-lived child so tree-kill is meaningful
    $child = Start-Process -FilePath "ping.exe" -ArgumentList "-n","60","127.0.0.1" -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 30
    exit 0
  }
  "missing_agent_end" {
    exit 0
  }
  "malformed_then_ok" {
    Write-Output "FAKE_OK"
    exit 0
  }
  "wrong_provider" { exit 17 }
  "wrong_model" { exit 18 }
  "aborted" { exit 19 }
  "secret_stderr" {
    [Console]::Error.WriteLine("provider failure key=$($env:ZAI_API_KEY)")
    exit 21
  }
  "large_stream" {
    Write-Output "FAKE_OK"
    exit 0
  }
  default {
    Write-Output "FAKE_OK"
    exit 0
  }
}
'@
  Set-Content -LiteralPath $ps1Path -Value $impl -Encoding UTF8

  $cmd = @"
@echo off
setlocal
set "FAKE_PI_ARGS=%*"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-pi-impl.ps1" %*
exit /b %ERRORLEVEL%
"@
  Set-Content -LiteralPath $cmdPath -Value $cmd -Encoding ASCII
  return $cmdPath
}

function ConvertTo-StartProcessArgumentString {
  param([string[]]$Tokens)
  ($Tokens | ForEach-Object {
    $s = [string]$_
    if ($s -match '[\s"]') {
      '"' + ($s -replace '"', '\"') + '"'
    }
    else { $s }
  }) -join ' '
}

function Invoke-WrapperUnderFakePi {
  param(
    [string]$Behavior,
    [string[]]$WrapperArgs,
    [int]$ExpectedPromptLength = 0,
    [int]$TimeoutSeconds = 60,
    [switch]$NvmFallback,
    [string]$ExpectedPromptText
  )
  $root = New-FakePiRoot
  $oldPath = $env:PATH
  $oldNvmHome = $env:NVM_HOME
  $oldProfile = $env:USERPROFILE
  $oldExpectedPromptLength = $env:FAKE_PI_EXPECTED_PROMPT_LENGTH
  $oldExpectedPromptText = $env:FAKE_PI_EXPECTED_TEXT
  try {
    $fakePiRoot = if ($NvmFallback) { Join-Path $root "nvm\v22.22.2" } else { $root }
    New-Item -ItemType Directory -Path $fakePiRoot -Force | Out-Null
    Write-FakePi -Root $fakePiRoot -Behavior $Behavior | Out-Null
    $env:FAKE_PI_BEHAVIOR = $Behavior
    if ($ExpectedPromptLength -gt 0) {
      $env:FAKE_PI_EXPECTED_PROMPT_LENGTH = [string]$ExpectedPromptLength
    }
    else {
      Remove-Item Env:FAKE_PI_EXPECTED_PROMPT_LENGTH -ErrorAction SilentlyContinue
    }
    if ($ExpectedPromptText) { $env:FAKE_PI_EXPECTED_TEXT = $ExpectedPromptText }
    else { Remove-Item Env:FAKE_PI_EXPECTED_TEXT -ErrorAction SilentlyContinue }
    if ($NvmFallback) {
      $env:NVM_HOME = Join-Path $root "nvm"
      # A real pi.cmd anywhere on PATH (e.g. od-shims) outranks the NVM fallback the
      # wrapper is supposed to exercise; strip pi-bearing entries so the fixture is
      # deterministic on hosts where pi is installed.
      $env:PATH = (($oldPath -split ';') | Where-Object {
          $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'pi.cmd') -ErrorAction SilentlyContinue)
        }) -join ';'
    }
    else { $env:PATH = $root + ";" + $oldPath }
    # Minimal auth so wrapper does not fail before fake pi
    $authDir = Join-Path $root "auth-home"
    $authPath = Join-Path $authDir ".local\share\opencode\auth.json"
    New-Item -ItemType Directory -Path (Split-Path $authPath) -Force | Out-Null
    '{"zai-coding-plan":{"key":"test-key-not-real"}}' | Set-Content -LiteralPath $authPath -Encoding UTF8

    # Point USERPROFILE to fake home so auth resolves without real secrets
    $env:USERPROFILE = $authDir

    $outFile = Join-Path $root "stdout.txt"
    $errFile = Join-Path $root "stderr.txt"
    $allArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Wrapper) + $WrapperArgs
    # PS5 Start-Process does not quote array ArgumentList; pass one string.
    $argString = ConvertTo-StartProcessArgumentString -Tokens $allArgs
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList $argString `
      -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $stdout = if (Test-Path $outFile) { Get-Content -LiteralPath $outFile -Raw } else { "" }
    $stderr = if (Test-Path $errFile) { Get-Content -LiteralPath $errFile -Raw } else { "" }
    return [pscustomobject]@{
      ExitCode = $p.ExitCode
      StdOut   = $stdout
      StdErr   = $stderr
      Root     = $root
    }
  }
  finally {
    $env:PATH = $oldPath
    $env:NVM_HOME = $oldNvmHome
    $env:USERPROFILE = $oldProfile
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:FAKE_PI_BEHAVIOR -ErrorAction SilentlyContinue
    if ($null -ne $oldExpectedPromptLength) {
      $env:FAKE_PI_EXPECTED_PROMPT_LENGTH = $oldExpectedPromptLength
    }
    else {
      Remove-Item Env:FAKE_PI_EXPECTED_PROMPT_LENGTH -ErrorAction SilentlyContinue
    }
    if ($null -ne $oldExpectedPromptText) { $env:FAKE_PI_EXPECTED_TEXT = $oldExpectedPromptText }
    else { Remove-Item Env:FAKE_PI_EXPECTED_TEXT -ErrorAction SilentlyContinue }
  }
}

Write-Host "=== Offline Invoke-PiGlm tests ==="

# 1) valid completion text mode
$r = Invoke-WrapperUnderFakePi -Behavior ok -WrapperArgs @("-Thinking","off","-Mode","text","-Prompt","hi","-TimeoutSeconds","30","-HeartbeatSeconds","5")
if ($r.ExitCode -ne 0) { Write-Host "INFO first probe failure: exit=$($r.ExitCode) stdout=$($r.StdOut) stderr=$($r.StdErr)" }
Assert-True ($r.ExitCode -eq 0) "text mode exit 0"
Assert-True (([string]$r.StdOut).Trim() -eq "FAKE_OK") "text mode final text only"
Assert-True ($r.StdOut -notmatch "message_update") "text mode excludes event noise"
Assert-True ($r.StdOut -notmatch "test-key-not-real") "auth key absent from stdout"
Assert-True (([string]$r.StdErr) -notmatch "test-key-not-real") "auth key absent from stderr"

# 2) JSON normalized result
$r = Invoke-WrapperUnderFakePi -Behavior ok -WrapperArgs @("-Thinking","off","-Mode","json","-Prompt","hi","-TimeoutSeconds","30","-HeartbeatSeconds","5")
Assert-True ($r.ExitCode -eq 0) "json mode exit 0"
$jsonOk = $false
try {
  $obj = $r.StdOut.Trim() | ConvertFrom-Json
  $jsonOk = ($obj.status -eq "ok" -and $obj.response -eq "FAKE_OK" -and $obj.model -eq "glm-5.2" -and $obj.provider -eq "zai")
} catch { $jsonOk = $false }
Assert-True $jsonOk "json normalized result fields"

# 3) large prompt-file path with spaces; content must travel over print stdin.
$spaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet pi spaces " + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $spaceRoot | Out-Null
try {
  $pf = Join-Path $spaceRoot "my prompt.txt"
  $largePrompt = ("x" * 126000)
  Set-Content -LiteralPath $pf -Value $largePrompt -Encoding UTF8 -NoNewline
  $terseTrailer = 'OUTPUT STYLE (mandatory): terse ' + [char]0x2014 + ' drop articles, filler, pleasantries, hedging; fragments OK; technical substance exact; code, diffs, JSON, file:line references verbatim and complete. Compress prose, never evidence.'
  $expectedLength = (Get-Content -LiteralPath $pf -Raw).Length + 1 + $terseTrailer.Length
  $r = Invoke-WrapperUnderFakePi -Behavior ok -ExpectedPromptLength $expectedLength -WrapperArgs @("-Thinking","off","-Mode","text","-PromptFile",$pf,"-TimeoutSeconds","30","-HeartbeatSeconds","5")
  if ($r.ExitCode -ne 0) { Write-Host "INFO large prompt failure: exit=$($r.ExitCode) stderr=$($r.StdErr)" }
  Assert-True ($r.ExitCode -eq 0 -and $r.StdOut.Trim() -eq "FAKE_OK" -and $expectedLength -gt 100000) "100KB prompt-file with spaces sent intact over print stdin"
}
finally {
  Remove-Item -LiteralPath $spaceRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 4) timeout kills child process tree
$beforePings = @(Get-Process -Name "ping" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$r = Invoke-WrapperUnderFakePi -Behavior timeout_child -WrapperArgs @("-Thinking","off","-Mode","json","-Prompt","hang","-TimeoutSeconds","3","-HeartbeatSeconds","1")
Start-Sleep -Milliseconds 500
$afterPings = @(Get-Process -Name "ping" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$leaked = @($afterPings | Where-Object { $_ -notin $beforePings })
Assert-True ($r.ExitCode -ne 0) "timeout exits nonzero"
$timedOutFlag = $false
try {
  # may be on stderr for text; for json on stdout
  $blob = ($r.StdOut + "`n" + $r.StdErr)
  if ($blob -match '"timed_out"\s*:\s*true' -or $blob -match "Timed out") { $timedOutFlag = $true }
} catch {}
Assert-True $timedOutFlag "timeout sets timed_out"
Assert-True ($leaked.Count -eq 0) "timeout kills spawned child process tree"

# 5) print-mode final text accepted without JSON event parsing
$r = Invoke-WrapperUnderFakePi -Behavior malformed_then_ok -WrapperArgs @("-Thinking","off","-Mode","json","-Prompt","hi","-TimeoutSeconds","30","-HeartbeatSeconds","5")
$malOk = $false
try {
  $obj = $r.StdOut.Trim() | ConvertFrom-Json
  $malOk = ($r.ExitCode -eq 0 -and $obj.status -eq "ok" -and $obj.response -eq "FAKE_OK" -and [int]$obj.malformed_events -eq 0)
} catch { $malOk = $false }
Assert-True $malOk "print-mode final text normalized"

# 6) empty print output fails
$r = Invoke-WrapperUnderFakePi -Behavior missing_agent_end -WrapperArgs @("-Thinking","off","-Mode","json","-Prompt","hi","-TimeoutSeconds","30","-HeartbeatSeconds","5")
Assert-True ($r.ExitCode -ne 0) "empty print output fails"

# 7) nonzero Pi exit fails
$r = Invoke-WrapperUnderFakePi -Behavior wrong_provider -WrapperArgs @("-Thinking","off","-Mode","json","-Prompt","hi","-TimeoutSeconds","30","-HeartbeatSeconds","5")
Assert-True ($r.ExitCode -ne 0) "nonzero Pi exit fails"

# 8) second nonzero Pi exit shape fails
$r = Invoke-WrapperUnderFakePi -Behavior wrong_model -WrapperArgs @("-Thinking","off","-Mode","json","-Prompt","hi","-TimeoutSeconds","30","-HeartbeatSeconds","5")
Assert-True ($r.ExitCode -ne 0) "nonzero Pi exit remains deterministic"

# 9) aborted process exit fails
$r = Invoke-WrapperUnderFakePi -Behavior aborted -WrapperArgs @("-Thinking","off","-Mode","json","-Prompt","hi","-TimeoutSeconds","30","-HeartbeatSeconds","5")
Assert-True ($r.ExitCode -ne 0) "aborted process exit fails"

# 10) print transport requests no cumulative event stream
$r = Invoke-WrapperUnderFakePi -Behavior large_stream -WrapperArgs @("-Thinking","off","-Mode","json","-Prompt","hi","-TimeoutSeconds","60","-HeartbeatSeconds","5")
$largeOk = $false
try {
  $obj = $r.StdOut.Trim() | ConvertFrom-Json
  $outLen = $r.StdOut.Length
  $largeOk = ($r.ExitCode -eq 0 -and $obj.status -eq "ok" -and $obj.prompt_accepted -eq $true -and $obj.events_seen -eq 0 -and $obj.response -eq "FAKE_OK" -and $outLen -lt 50000 -and $obj.raw_bytes -lt 100)
} catch { $largeOk = $false }
Assert-True $largeOk "print transport emits final text only"

# 11) exclusive prompt args
$r = Invoke-WrapperUnderFakePi -Behavior ok -WrapperArgs @("-Thinking","off","-Prompt","a","-PromptFile","nope.txt")
Assert-True ($r.ExitCode -ne 0) "both Prompt and PromptFile rejected"

# 12) ReadOnly flag accepted (fake pi ignores tools)
$r = Invoke-WrapperUnderFakePi -Behavior ok -WrapperArgs @("-Thinking","off","-Mode","text","-Prompt","hi","-ReadOnly","-TimeoutSeconds","30","-HeartbeatSeconds","5")
Assert-True ($r.ExitCode -eq 0) "ReadOnly switch accepted"

# 13) child stderr cannot leak auth key
$r = Invoke-WrapperUnderFakePi -Behavior secret_stderr -WrapperArgs @("-Thinking","off","-Mode","json","-Prompt","hi","-TimeoutSeconds","30","-HeartbeatSeconds","5")
$secretBlob = ([string]$r.StdOut) + ([string]$r.StdErr)
Assert-True ($r.ExitCode -ne 0 -and $secretBlob -notmatch "test-key-not-real" -and $secretBlob -match "\[REDACTED\]") "child stderr auth key redacted"

# 14) stdin write itself is deadline-bounded when child never reads the pipe
$blockedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet blocked stdin " + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $blockedRoot | Out-Null
try {
  $blockedPrompt = Join-Path $blockedRoot "five meg prompt.txt"
  Set-Content -LiteralPath $blockedPrompt -Value ("z" * 5000000) -Encoding ASCII -NoNewline
  $beforeBlockedPings = @(Get-Process -Name "ping" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  $r = Invoke-WrapperUnderFakePi -Behavior never_read_stdin -WrapperArgs @("-Thinking","off","-Mode","json","-PromptFile",$blockedPrompt,"-TimeoutSeconds","3","-HeartbeatSeconds","1")
  Start-Sleep -Milliseconds 500
  $afterBlockedPings = @(Get-Process -Name "ping" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  $blockedLeaks = @($afterBlockedPings | Where-Object { $_ -notin $beforeBlockedPings })
  $blockedTimedOut = (([string]$r.StdOut + [string]$r.StdErr) -match '"timed_out"\s*:\s*true')
  Assert-True ($r.ExitCode -ne 0 -and $blockedTimedOut -and $blockedLeaks.Count -eq 0) "blocked stdin write times out and kills process tree"
}
finally {
  Remove-Item -LiteralPath $blockedRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# 15) frozen-artifact review disables all tools and project approval
$r = Invoke-WrapperUnderFakePi -Behavior ok -WrapperArgs @("-Thinking","low","-Mode","text","-Prompt","frozen diff","-NoTools","-TimeoutSeconds","30","-HeartbeatSeconds","5")
Assert-True ($r.ExitCode -eq 0 -and $r.StdOut.Trim() -eq "FAKE_OK") "NoTools frozen-artifact review flags accepted"

# 16) Pi can live under an inactive NVM version while repo keeps current Node.
$r = Invoke-WrapperUnderFakePi -Behavior ok -NvmFallback -WrapperArgs @("-Thinking","off","-Mode","json","-Prompt","hi","-TimeoutSeconds","30","-HeartbeatSeconds","5")
$nvmOk = $false
try {
  $obj = $r.StdOut.Trim() | ConvertFrom-Json
  $nvmOk = ($r.ExitCode -eq 0 -and $obj.status -eq "ok" -and $obj.pi_path -match 'v22\.22\.2[\\/]pi\.cmd$')
} catch { $nvmOk = $false }
Assert-True $nvmOk "inactive NVM Pi fallback resolves without switching active Node"

# 17) No-tools frozen review packet is embedded over stdin with manifest evidence.
$artifactRoot = Join-Path ([IO.Path]::GetTempPath()) ("fleet-pi-artifact-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $artifactRoot | Out-Null
try {
  [IO.File]::WriteAllText((Join-Path $artifactRoot "base.sha"), (("a" * 40) + [Environment]::NewLine))
  [IO.File]::WriteAllText((Join-Path $artifactRoot "final.diff"), "PI_FROZEN_ARTIFACT_TOKEN")
  [IO.File]::WriteAllText((Join-Path $artifactRoot "touched-files.txt"), "a.txt`n")
  [IO.File]::WriteAllText((Join-Path $artifactRoot "locked-plan.md"), "# Plan`n")
  [IO.File]::WriteAllText((Join-Path $artifactRoot "acceptance-evidence.md"), "# Evidence`n")
  [IO.File]::WriteAllText((Join-Path $artifactRoot "gate-evidence.md"), "# Gates`n")
  $packetManifest = Join-Path $artifactRoot "packet-manifest.json"
  $packetBuilder = Join-Path $PSScriptRoot "Get-FleetReviewPacket.ps1"
  $packet = (& $packetBuilder -PacketDir $artifactRoot -OutputPath $packetManifest | ConvertFrom-Json)
  # -ArtifactFile is [string[]] behind a -File boundary: separate tokens spill onto
  # positional params (2026-07-18 Opus lesson). Callers MUST comma-join.
  $wrapperArgs = @("-Thinking","off","-Mode","json","-Prompt","review charter","-ArtifactFile",(@($packet.artifact_paths) -join ","),"-PacketManifest",$packetManifest,"-NoTools","-TimeoutSeconds","30")
  $r = Invoke-WrapperUnderFakePi -Behavior ok -ExpectedPromptText "PI_FROZEN_ARTIFACT_TOKEN" -WrapperArgs $wrapperArgs
  $artifactOk = $false
  try {
    $obj = $r.StdOut.Trim() | ConvertFrom-Json
    $artifactOk = ($r.ExitCode -eq 0 -and $obj.packet_manifest_sha256 -eq $packet.packet_sha256 -and @($obj.artifacts).Count -eq 6 -and $obj.artifacts[0].bytes -gt 0 -and $obj.artifacts[0].sha256.Length -eq 64)
  } catch { $artifactOk = $false }
  Assert-True $artifactOk "frozen packet embedded, re-attested, and hashed for no-tools GLM"
}
finally { Remove-Item -LiteralPath $artifactRoot -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
Write-Host "Offline: $($script:Pass) passed, $($script:Fail) failed"

if ($Live) {
  Write-Host ""
  Write-Host "=== Live Pi proofs ==="
  $liveArgs = @(
    "-NoProfile","-ExecutionPolicy","Bypass","-File",$Wrapper,
    "-Thinking","off","-Mode","text","-Prompt","Reply exactly PI_GLM_OK","-TimeoutSeconds","120","-HeartbeatSeconds","15"
  )
  $outFile = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-pi-live-" + [guid]::NewGuid().ToString("n") + ".out")
  $errFile = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-pi-live-" + [guid]::NewGuid().ToString("n") + ".err")
  try {
    $p = Start-Process -FilePath "powershell.exe" -ArgumentList (ConvertTo-StartProcessArgumentString -Tokens $liveArgs) -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout = Get-Content -LiteralPath $outFile -Raw
    $stderr = Get-Content -LiteralPath $errFile -Raw
    Assert-True ($p.ExitCode -eq 0) "live text probe exit 0"
    Assert-True ($stdout.Trim() -eq "PI_GLM_OK") "live text probe body"
    Assert-True ($stdout.Length -lt 500) "live output compact"

    $liveJsonArgs = @(
      "-NoProfile","-ExecutionPolicy","Bypass","-File",$Wrapper,
      "-Thinking","off","-Mode","json","-Prompt","Reply exactly PI_JSON_OK","-TimeoutSeconds","120","-HeartbeatSeconds","15"
    )
    $p2 = Start-Process -FilePath "powershell.exe" -ArgumentList (ConvertTo-StartProcessArgumentString -Tokens $liveJsonArgs) -NoNewWindow -Wait -PassThru `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout2 = Get-Content -LiteralPath $outFile -Raw
    $obj2 = $null
    try { $obj2 = $stdout2.Trim() | ConvertFrom-Json } catch {}
    Assert-True ($p2.ExitCode -eq 0 -and $null -ne $obj2 -and $obj2.response -match "PI_JSON_OK" -and $obj2.model -eq "glm-5.2" -and $obj2.provider -eq "zai" -and $obj2.model_evidence -eq "cli-pinned-unobserved" -and -not $obj2.model_verified) "live json configured model proof"

    $leftover = @(Get-Process -Name "node" -ErrorAction SilentlyContinue | Where-Object {
      try { $_.MainModule.FileName -match "pi-coding-agent" } catch { $false }
    })
    # Not a hard fail if other pi work running; informational
    Write-Host "INFO live leftover pi-ish node procs: $($leftover.Count)"
  }
  finally {
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "TOTAL: $($script:Pass) passed, $($script:Fail) failed"
if ($script:Fail -gt 0) { exit 1 }
exit 0
