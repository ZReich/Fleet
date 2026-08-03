param([switch]$Live)

$ErrorActionPreference = "Stop"
$wrapper = Join-Path $PSScriptRoot "Invoke-Opus48.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("fleet-opus-test-" + [guid]::NewGuid().ToString("n"))
$fakeCmd = Join-Path $temp "claude.cmd"
$fakePs1 = Join-Path $temp "fake-claude.ps1"
$oldPath = $env:PATH
$oldNvmHome = $env:NVM_HOME
$oldAppData = $env:APPDATA
$oldUserProfile = $env:USERPROFILE
$passed = 0
$failed = 0

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Approval([string]$Path, [string]$Version) {
  $manifest = Join-Path $env:USERPROFILE '.codex\fleet\approved-clis.json'
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifest) | Out-Null
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  $sha = (Get-FileHash -LiteralPath $resolved -Algorithm SHA256).Hash.ToLowerInvariant()
  $payload = $resolved
  $packageBinary = Join-Path (Split-Path -Parent $resolved) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
  if (Test-Path -LiteralPath $packageBinary -PathType Leaf) { $payload = (Resolve-Path -LiteralPath $packageBinary).Path }
  $payloadSha = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
  @{ schema_version='1'; clis=@{ claude=@{ path=$resolved; version=$Version; sha256=$sha; payload_path=$payload; payload_sha256=$payloadSha; package_version=$Version; approved_at=(Get-Date).ToString('o'); proof=@{ offline='test'; live='test' } } } } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifest -Encoding UTF8
}

try {
  New-Item -ItemType Directory -Path $temp | Out-Null
  [IO.File]::WriteAllText($fakeCmd, "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$fakePs1`" %*")
  [IO.File]::WriteAllText($fakePs1, @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
if ($env:DISABLE_UPDATES -ne "1") { exit 27 }
if ($Args -contains "--version" -and $env:FAKE_CLAUDE_HANG_VERSION -eq "1") { Start-Sleep -Seconds 30; exit 0 }
if ($Args -contains "--version" -and $env:FAKE_CLAUDE_FAIL_VERSION -eq "1") { exit 28 }
if ($Args -contains "--version") { if ($env:FAKE_CLAUDE_CANDIDATE_VERSION) { "$env:FAKE_CLAUDE_CANDIDATE_VERSION (fake)" } else { "2.1.119 (fake)" }; exit 0 }
if ($Args -contains "--help") {
  if ($env:FAKE_CLAUDE_HANG_HELP -eq "1") { Start-Sleep -Seconds 30; exit 0 }
  "  --tools <tools>"
  "  --setting-sources <sources>"
  "  --disable-slash-commands"
  "  --no-chrome"
  "  --strict-mcp-config"
  "  --mcp-config <configs...>"
  if ($env:FAKE_CLAUDE_SUPPORTS_SAFE -eq "1") { "  --safe-mode  Disable hooks" }
  exit 0
}
$hasSafe = $Args -contains "--safe-mode"
if ($env:FAKE_CLAUDE_SUPPORTS_SAFE -eq "1" -and -not $hasSafe) { exit 21 }
if ($env:FAKE_CLAUDE_SUPPORTS_SAFE -ne "1" -and $hasSafe) { [Console]::Error.WriteLine("unknown option --safe-mode"); exit 22 }
$mcpIndex = [Array]::IndexOf($Args, "--mcp-config")
if (-not ($Args -contains "--setting-sources") -or $Args[[Array]::IndexOf($Args, "--setting-sources") + 1] -ne "user" -or -not ($Args -contains "--disable-slash-commands") -or -not ($Args -contains "--no-chrome") -or -not ($Args -contains "--strict-mcp-config") -or $mcpIndex -lt 0 -or -not (Test-Path -LiteralPath $Args[$mcpIndex + 1])) { exit 25 }
$toolsIndex = [Array]::IndexOf($Args, "--tools")
$toolsValue = if ($toolsIndex -ge 0) { [string]$Args[$toolsIndex + 1] } else { "MISSING" }
if ($env:FAKE_CLAUDE_DESIGN_DIR) {
  # Design lane: tools scoped to the workspace, cwd IS the workspace, --add-dir present.
  if ($toolsValue -ne "Write,Read,Edit") { exit 30 }
  if (-not ($Args -contains "--add-dir")) { exit 31 }
  if ((Get-Location).Path -ne (Resolve-Path -LiteralPath $env:FAKE_CLAUDE_DESIGN_DIR).Path) { exit 32 }
  if ($env:FAKE_CLAUDE_WRITE_FILE -eq "1") {
    [IO.File]::WriteAllText((Join-Path (Get-Location).Path "design-system.html"), "<html></html>")
  }
}
else {
  # Review lane must stay TOOLLESS - a design flag must never leak tools into it.
  if ($toolsValue -ne "") { exit 33 }
  if ((Split-Path -Leaf (Get-Location).Path) -notlike "fleet-opus-cwd-*") { exit 26 }
}
$prompt = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($prompt)) { exit 23 }
if ($env:FAKE_CLAUDE_EXPECT_TEXT -and -not $prompt.Contains($env:FAKE_CLAUDE_EXPECT_TEXT)) { exit 24 }
# PowerShell's binder swallows "--model" before $Args sees it, so read the raw command
# line (the real CLI receives correct argv - this is a harness artifact only).
$rawCommandLine = [Environment]::CommandLine
$modelMatch = [regex]::Match($rawCommandLine, '--model\s+(\S+)')
$requestedModel = if ($modelMatch.Success) { $modelMatch.Groups[1].Value.Trim('"') } else { "claude-opus-4-8" }
@{ subtype="success"; is_error=$false; result="OPUS_OK"; session_id="fake"; total_cost_usd=0; modelUsage=@{ $requestedModel=@{} } } | ConvertTo-Json -Compress -Depth 5
'@)
  $env:PATH = $temp + ";" + $oldPath
  $env:APPDATA = Join-Path $temp 'appdata'
  $env:USERPROFILE = Join-Path $temp 'profile'
  New-Item -ItemType Directory -Force -Path $env:APPDATA | Out-Null

  Case "approved NVM Claude wins over active PATH" {
    $fakeNvm = Join-Path $temp 'nvm'; $newDir = Join-Path $fakeNvm 'v22.0.0'; New-Item -ItemType Directory -Force -Path $newDir | Out-Null
    $newCmd = Join-Path $newDir 'claude.cmd'
    [IO.File]::WriteAllText($newCmd, "@set `"FAKE_CLAUDE_CANDIDATE_VERSION=2.1.207`"`r`n@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$fakePs1`" %*")
    $env:NVM_HOME = $fakeNvm
    Write-Approval -Path $newCmd -Version '2.1.207'
    $env:FAKE_CLAUDE_SUPPORTS_SAFE = '0'
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -Mode json -TimeoutSeconds 30 2>$null
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $json.cli_version -match '^2\.1\.207' -and $json.cli_path -eq $newCmd) 'approved Claude was not selected'
    $env:NVM_HOME = $oldNvmHome
  }

  Case "approved later PATH candidate is discoverable" {
    $oldDir = Join-Path $temp 'path-old'; $newDir = Join-Path $temp 'path-new'
    New-Item -ItemType Directory -Force -Path $oldDir,$newDir | Out-Null
    $oldCmd = Join-Path $oldDir 'claude.cmd'; $newCmd = Join-Path $newDir 'claude.cmd'
    [IO.File]::WriteAllText($oldCmd, "@set `"FAKE_CLAUDE_CANDIDATE_VERSION=2.1.100`"`r`n@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$fakePs1`" %*")
    [IO.File]::WriteAllText($newCmd, "@set `"FAKE_CLAUDE_CANDIDATE_VERSION=2.1.200`"`r`n@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$fakePs1`" %*")
    $env:NVM_HOME = Join-Path $temp 'empty-nvm'; New-Item -ItemType Directory -Force -Path $env:NVM_HOME | Out-Null
    $env:PATH = $oldDir + ';' + $newDir + ';' + $oldPath
    Write-Approval -Path $newCmd -Version '2.1.200'
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -Mode json -TimeoutSeconds 30 2>$null
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $json.cli_path -eq $newCmd) 'later PATH candidate was not discovered'
    $env:PATH = $temp + ';' + $oldPath
    $env:NVM_HOME = $oldNvmHome
  }

  Case "changed package payload is rejected" {
    $tamperDir = Join-Path $temp 'tamper'; New-Item -ItemType Directory -Force -Path $tamperDir | Out-Null
    $tamperCmd = Join-Path $tamperDir 'claude.cmd'
    [IO.File]::WriteAllText($tamperCmd, "@set `"FAKE_CLAUDE_CANDIDATE_VERSION=2.1.119`"`r`n@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$fakePs1`" %*")
    $packageRoot = Join-Path $tamperDir 'node_modules\@anthropic-ai\claude-code'
    New-Item -ItemType Directory -Force -Path (Join-Path $packageRoot 'bin') | Out-Null
    [IO.File]::WriteAllText((Join-Path $packageRoot 'package.json'), '{"version":"2.1.119"}')
    $payload = Join-Path $packageRoot 'bin\claude.exe'; [IO.File]::WriteAllText($payload, 'approved payload')
    Write-Approval -Path $tamperCmd -Version '2.1.119'
    [IO.File]::WriteAllText($payload, 'changed payload')
    $env:NVM_HOME = Join-Path $temp 'empty-nvm'
    $env:PATH = $tamperDir + ';' + $oldPath
    $oldPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -Mode json -TimeoutSeconds 30 2>$null | Out-Null
      $probeExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    Assert-True ($probeExit -ne 0) 'changed package payload was accepted'
    $env:PATH = $temp + ';' + $oldPath
    $env:NVM_HOME = $oldNvmHome
    Write-Approval -Path $fakeCmd -Version '2.1.119'
  }

  Case "unrelated hung nonzero prerelease and corrupt installs cannot affect approved" {
    $badRoot = Join-Path $temp 'bad-candidates'; New-Item -ItemType Directory -Force -Path $badRoot | Out-Null
    $specs = @(
      @{ name='a-hung'; prefix='@set "FAKE_CLAUDE_HANG_VERSION=1"' },
      @{ name='b-nonzero'; prefix='@set "FAKE_CLAUDE_FAIL_VERSION=1"' },
      @{ name='c-prerelease'; prefix='@set "FAKE_CLAUDE_CANDIDATE_VERSION=9.0.0-beta.1"' },
      @{ name='d-corrupt'; prefix='@set "FAKE_CLAUDE_CANDIDATE_VERSION=not-a-version"' }
    )
    $dirs = @()
    foreach ($spec in $specs) {
      $dir = Join-Path $badRoot $spec.name; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $dirs += $dir
      [IO.File]::WriteAllText((Join-Path $dir 'claude.cmd'), "$($spec.prefix)`r`n@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$fakePs1`" %*")
    }
    Write-Approval -Path $fakeCmd -Version '2.1.119'
    $env:NVM_HOME = Join-Path $temp 'empty-nvm'
    $env:PATH = (($dirs + @($temp,$oldPath)) -join ';')
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -Mode json -TimeoutSeconds 30 2>$null
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $json.cli_path -eq $fakeCmd) 'unrelated invalid installs affected approved Claude'
    $env:PATH = $temp + ';' + $oldPath
    $env:NVM_HOME = $oldNvmHome
  }

  Case "hung help probe fails closed within bound" {
    $env:FAKE_CLAUDE_HANG_HELP = '1'
    $started = Get-Date
    $oldPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -Mode json -TimeoutSeconds 30 2>$null | Out-Null
      $probeExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    $elapsed = ((Get-Date) - $started).TotalSeconds
    Assert-True ($probeExit -ne 0 -and $elapsed -lt 18) 'help probe did not fail closed within timeout'
    Remove-Item Env:FAKE_CLAUDE_HANG_HELP -ErrorAction SilentlyContinue
  }

  Case "modern Claude omits removed safe-mode flag" {
    $env:FAKE_CLAUDE_SUPPORTS_SAFE = "0"
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -Mode json -TimeoutSeconds 30 2>$null
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $json.status -eq "ok" -and $json.response -eq "OPUS_OK" -and "--safe-mode" -notin @($json.isolation_flags) -and "--setting-sources" -in @($json.isolation_flags)) "modern compatibility failed"
  }
  Case "legacy Claude uses advertised safe-mode flag" {
    $env:FAKE_CLAUDE_SUPPORTS_SAFE = "1"
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -Mode json -TimeoutSeconds 30 2>$null
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and "--safe-mode" -in @($json.isolation_flags)) "advertised safe-mode not used"
  }
  Case "frozen artifact is embedded over stdin" {
    $env:FAKE_CLAUDE_SUPPORTS_SAFE = "0"
    $env:FAKE_CLAUDE_EXPECT_TEXT = "FROZEN_ARTIFACT_TOKEN"
    $packetDir = Join-Path $temp "review-packet"
    New-Item -ItemType Directory -Force -Path $packetDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $packetDir "base.sha"), (("a" * 40) + [Environment]::NewLine))
    [IO.File]::WriteAllText((Join-Path $packetDir "final.diff"), $env:FAKE_CLAUDE_EXPECT_TEXT)
    [IO.File]::WriteAllText((Join-Path $packetDir "touched-files.txt"), "a.txt`n")
    [IO.File]::WriteAllText((Join-Path $packetDir "locked-plan.md"), "# Plan`n")
    [IO.File]::WriteAllText((Join-Path $packetDir "acceptance-evidence.md"), "# Evidence`n")
    [IO.File]::WriteAllText((Join-Path $packetDir "gate-evidence.md"), "# Gates`n")
    $packetManifest = Join-Path $packetDir "packet-manifest.json"
    $packetBuilder = Join-Path $PSScriptRoot "Get-FleetReviewPacket.ps1"
    $packet = (& $packetBuilder -PacketDir $packetDir -OutputPath $packetManifest | ConvertFrom-Json)
    # Cross the -File boundary with the wrapper's comma-joined ArtifactFile contract:
    # a raw PS array splats positionally and corrupts later params (e.g. -Effort).
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt test -ArtifactFile ($packet.artifact_paths -join ',') -PacketManifest $packetManifest -Mode json -TimeoutSeconds 30 2>$null
    $json = ($raw -join "`n") | ConvertFrom-Json
    Assert-True ($LASTEXITCODE -eq 0 -and $json.status -eq "ok" -and $json.packet_manifest_sha256 -eq $packet.packet_sha256 -and @($json.artifacts).Count -eq 6 -and $json.artifacts[0].bytes -gt 0 -and $json.artifacts[0].sha256.Length -eq 64) "packet was embedded, re-attested, and recorded"
    Remove-Item Env:FAKE_CLAUDE_EXPECT_TEXT -ErrorAction SilentlyContinue
  }
  Case "design lane writes files and reports them" {
    $env:PATH = $temp + ';' + $oldPath
    $env:NVM_HOME = Join-Path $temp 'empty-nvm'; New-Item -ItemType Directory -Force -Path $env:NVM_HOME | Out-Null
    $env:FAKE_CLAUDE_SUPPORTS_SAFE = '0'
    Write-Approval -Path $fakeCmd -Version '2.1.119'
    try {
      # POSITIVE: files written -> ok, manifest reports them.
      $outDir = Join-Path $temp 'design-out'; New-Item -ItemType Directory -Force -Path $outDir | Out-Null
      $env:FAKE_CLAUDE_DESIGN_DIR = $outDir; $env:FAKE_CLAUDE_WRITE_FILE = '1'
      $json = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt "design it" -Model claude-opus-5 -DesignOutputDir $outDir -Mode json -TimeoutSeconds 60 2>$null) -join "`n") | ConvertFrom-Json
      Assert-True ($json.status -eq 'ok' -and $json.design_file_count -eq 1 -and @($json.design_files)[0].bytes -gt 0) "design lane did not report written files"

      # POST-EXIT FILESYSTEM CHECK (2026-07-26 CRITICAL, panel-found): the wrapper
      # assigned the caller's design dir to $ownedWorkingDirectory, and the finally block
      # recurse-deletes that. It reported status=ok with design_files populated and THEN
      # destroyed the directory, including files that pre-dated the run. JSON-only
      # assertions cannot see this - the deliverable must exist after the process exits.
      Assert-True (Test-Path -LiteralPath $outDir) "design output dir was deleted by cleanup"
      Assert-True (Test-Path -LiteralPath (Join-Path $outDir 'design-system.html')) "written deliverable did not survive wrapper exit"
      # A file that pre-dated the run must also survive.
      $preExisting = Join-Path $outDir 'pre-existing.txt'
      [IO.File]::WriteAllText($preExisting, 'keep me')
      $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt "design it" -Model claude-opus-5 -DesignOutputDir $outDir -Mode json -TimeoutSeconds 60 2>$null
      Assert-True (Test-Path -LiteralPath $preExisting) "cleanup destroyed a pre-existing caller file"

      # NEGATIVE: model replies but writes nothing -> not a success.
      $emptyDir = Join-Path $temp 'design-empty'; New-Item -ItemType Directory -Force -Path $emptyDir | Out-Null
      $env:FAKE_CLAUDE_DESIGN_DIR = $emptyDir; $env:FAKE_CLAUDE_WRITE_FILE = '0'
      $json2 = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt "design it" -Model claude-opus-5 -DesignOutputDir $emptyDir -Mode json -TimeoutSeconds 60 2>$null) -join "`n") | ConvertFrom-Json
      Assert-True ($json2.status -eq 'error' -and $json2.design_file_count -eq 0) "empty design lane reported as success"

      # The design transport clause must reach the model (fake exits 24 if absent).
      $env:FAKE_CLAUDE_DESIGN_DIR = $outDir; $env:FAKE_CLAUDE_WRITE_FILE = '1'
      $env:FAKE_CLAUDE_EXPECT_TEXT = 'DELIVERABLE TRANSPORT'
      $json3 = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt "design it" -Model claude-opus-5 -DesignOutputDir $outDir -Mode json -TimeoutSeconds 60 2>$null) -join "`n") | ConvertFrom-Json
      Assert-True ($json3.status -eq 'ok') "design transport clause missing from prompt"
      Remove-Item Env:FAKE_CLAUDE_EXPECT_TEXT -ErrorAction SilentlyContinue

      # Review lane stays TOOLLESS (fake exits 33 on a non-empty --tools).
      Remove-Item Env:FAKE_CLAUDE_DESIGN_DIR -ErrorAction SilentlyContinue
      $json4 = ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt "review it" -Mode json -TimeoutSeconds 60 2>$null) -join "`n") | ConvertFrom-Json
      Assert-True ($json4.status -eq 'ok') "review lane lost its toolless isolation"
    }
    finally {
      Remove-Item Env:FAKE_CLAUDE_DESIGN_DIR -ErrorAction SilentlyContinue
      Remove-Item Env:FAKE_CLAUDE_WRITE_FILE -ErrorAction SilentlyContinue
      Remove-Item Env:FAKE_CLAUDE_EXPECT_TEXT -ErrorAction SilentlyContinue
      $env:NVM_HOME = $oldNvmHome
    }
  }
}
finally {
  $env:PATH = $oldPath
  $env:NVM_HOME = $oldNvmHome
  $env:APPDATA = $oldAppData
  $env:USERPROFILE = $oldUserProfile
  Remove-Item Env:FAKE_CLAUDE_SUPPORTS_SAFE -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_CLAUDE_EXPECT_TEXT -ErrorAction SilentlyContinue
  Remove-Item Env:FAKE_CLAUDE_HANG_HELP -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Live) {
  Case "live Opus transport" {
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Prompt "Reply exactly OPUS_OK" -Mode json -TimeoutSeconds 120
    $json = ($raw -join "`n") | ConvertFrom-Json
    # Same seat-drift trap as Test-FleetExternalLanes: assert the reported seat was observed.
    $seat = [string]$json.model
    Assert-True ($LASTEXITCODE -eq 0 -and $json.status -eq "ok" -and $json.response.Trim() -eq "OPUS_OK" -and $seat -match '^claude-opus-' -and $seat -in @($json.observed_models)) "live Opus proof failed (seat '$seat', observed: $(@($json.observed_models) -join ','))"
  }
}

Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
