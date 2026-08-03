# Guard test for Invoke-Sol.ps1. Offline by default (AST + behavioral launcher
# resolution + process-launch argv checks; never calls real codex). Pass -Live
# to also run a real -Probe and assert SOL_OK.
param([switch]$Live)

$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot 'Invoke-Sol.ps1'
$fail = 0
$pass = 0
function Check($name, $cond) {
  if ($cond) { Write-Host "PASS $name"; $script:pass++ }
  else { Write-Host "FAIL $name" -ForegroundColor Red; $script:fail++ }
}

Check 'script exists' (Test-Path -LiteralPath $target)

$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
Check 'parses clean' ($errors.Count -eq 0)

$src = Get-Content -Raw -LiteralPath $target
Check 'forces effort override'    ($src -match 'model_reasoning_effort=')
Check 'default effort is high'    ($src -match "\`$Effort\s*=\s*'high'")
Check 'has 0-turn liveness kill'  ($src -match 'FirstOutputSeconds' -and $src -match 'Stop-Tree')
Check 'stdin closed to EOF'       ($src -match 'StandardInput\.Close')
Check 'surfaces model_cache_skew' ($src -match 'supports_reasoning_summaries' -and $src -match 'model_cache_skew')
Check 'CRT argv builder present'  ($src -match 'ConvertTo-WindowsCommandLineArgument')
Check 'cmd launcher refuses unsafe' ($src -match 'cmd launcher refuses unsafe')
Check 'native launcher runs direct' ($src.Contains('$psi.FileName = $launcher') -and $src -match 'ConvertTo-WindowsCommandLine')

# Load production functions (no replica): everything before the main try block.
$fnMatch = [regex]::Match($src, '(?s)(function Resolve-CodexLauncher \{.*?)(?=\r?\ntry \{)')
Check 'production functions extractable' $fnMatch.Success
if (-not $fnMatch.Success) {
  Write-Host "Test-Invoke-Sol: $fail failed"; exit 1
}
Invoke-Expression $fnMatch.Groups[1].Value

$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-sol-test-' + [guid]::NewGuid().ToString('n'))
$oldLauncher = $env:FLEET_CODEX_LAUNCHER
$oldLocalAppData = $env:LOCALAPPDATA
$oldPath = $env:PATH
try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  $fakeLocal = Join-Path $temp 'localappdata'
  $env:LOCALAPPDATA = $fakeLocal
  Remove-Item Env:FLEET_CODEX_LAUNCHER -ErrorAction SilentlyContinue

  $nativeRel = 'nvm\v22.22.2\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin'
  $nativeDir = Join-Path $fakeLocal $nativeRel
  $nativeExe = Join-Path $nativeDir 'codex.exe'
  $cmdShim = Join-Path $fakeLocal 'nvm\v22.22.2\codex.cmd'
  $pathDir = Join-Path $temp 'path-app'
  $pathExe = Join-Path $pathDir 'codex.exe'
  $overrideLeaf = Join-Path $temp 'override-codex.exe'
  $overrideDir = Join-Path $temp 'override-dir'
  New-Item -ItemType Directory -Force -Path $nativeDir, (Split-Path $cmdShim), $pathDir, $overrideDir | Out-Null
  [IO.File]::WriteAllText($nativeExe, 'native')
  [IO.File]::WriteAllText($cmdShim, '@echo cmd-shim')
  [IO.File]::WriteAllText($pathExe, 'path-app')
  [IO.File]::WriteAllText($overrideLeaf, 'override')

  # --- production Resolve-CodexLauncher resolution order ---
  $env:FLEET_CODEX_LAUNCHER = $overrideLeaf
  $env:PATH = $pathDir + ';' + $oldPath
  $got = Resolve-CodexLauncher
  Check 'production Resolve-CodexLauncher: FLEET override wins' ($got -eq $overrideLeaf)

  $env:FLEET_CODEX_LAUNCHER = $overrideDir
  $got = Resolve-CodexLauncher
  Check 'production Resolve-CodexLauncher: directory override rejected' ($got -ne $overrideDir -and $got -eq $nativeExe)

  Remove-Item Env:FLEET_CODEX_LAUNCHER -ErrorAction SilentlyContinue
  $got = Resolve-CodexLauncher
  Check 'production Resolve-CodexLauncher: known native beats PATH' ($got -eq $nativeExe)

  Remove-Item -LiteralPath $nativeExe -Force
  $got = Resolve-CodexLauncher
  Check 'production Resolve-CodexLauncher: PATH application when no native' ($got -eq $pathExe)

  Remove-Item -LiteralPath $pathExe -Force
  # Isolate PATH so host codex cannot mask the known .cmd last-resort path.
  $env:PATH = "$env:SystemRoot\System32"
  $got = Resolve-CodexLauncher
  Check 'production Resolve-CodexLauncher: .cmd last resort' ($got -eq $cmdShim)

  # Restore native for remaining resolution checks
  [IO.File]::WriteAllText($nativeExe, 'native')
  [IO.File]::WriteAllText($pathExe, 'path-app')
  $env:PATH = $pathDir + ';' + "$env:SystemRoot\System32"

  function script:codex { return 'function-shadow' }
  $got = Resolve-CodexLauncher
  Check 'production Resolve-CodexLauncher: function-shadow not selected' (
    $got -ne 'function-shadow' -and (Test-Path -LiteralPath $got -PathType Leaf)
  )
  Remove-Item -Path Function:codex -ErrorAction SilentlyContinue

  Set-Alias -Name codex -Value Get-Date -Scope Script -Force -ErrorAction SilentlyContinue
  $got = Resolve-CodexLauncher
  Check 'production Resolve-CodexLauncher: alias not selected' (
    $got -match '\.(exe|cmd)$' -and (Test-Path -LiteralPath $got -PathType Leaf)
  )
  Remove-Item -Path Alias:codex -ErrorAction SilentlyContinue

  Check 'resolution order: override>native>PATH>.cmd' $true

  # --- CRT quoting unit: CommandLineToArgvW round-trip ---
  Add-Type -Namespace FleetSolArgv -Name Shim -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError=true)]
public static extern System.IntPtr CommandLineToArgvW([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr LocalFree(System.IntPtr hMem);
'@ -ErrorAction SilentlyContinue
  function Script:Parse-CmdLine([string]$Line) {
    $n = 0; $ptr = [FleetSolArgv.Shim]::CommandLineToArgvW($Line, [ref]$n)
    try {
      $o = @()
      for ($k = 0; $k -lt $n; $k++) {
        $sp = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($ptr, $k * [System.IntPtr]::Size)
        $o += [System.Runtime.InteropServices.Marshal]::PtrToStringUni($sp)
      }
      return $o
    } finally { [void][FleetSolArgv.Shim]::LocalFree($ptr) }
  }
  $bsq = 'prefix C:\dir\"quoted" tail'
  $line = 'exe ' + (ConvertTo-WindowsCommandLine -ArgumentTokens @('exec', $bsq))
  $parsed = Parse-CmdLine -Line $line
  Check 'ConvertTo-WindowsCommandLineArgument backslash-quote round-trip' (
    $parsed.Count -eq 3 -and $parsed[2] -eq $bsq
  )

  # --- native launcher behavioral: fake exe records exact argv ---
  $argvFile = Join-Path $temp 'argv-record.txt'
  $csFile = Join-Path $temp 'fake-codex.cs'
  $fakeNative = Join-Path $temp 'fake-codex-native.exe'
  $cs = @'
using System;
using System.IO;
class FakeCodex {
  static int Main(string[] args) {
    var path = Environment.GetEnvironmentVariable("FAKE_CODEX_ARGV_FILE");
    if (!string.IsNullOrEmpty(path)) File.WriteAllText(path, string.Join("\n", args));
    Console.WriteLine("FAKE_CODEX_OK");
    return 0;
  }
}
'@
  [IO.File]::WriteAllText($csFile, $cs)
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
  }
  $cscOk = $false
  if (Test-Path -LiteralPath $csc) {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $csc /nologo /out:$fakeNative $csFile 2>$null | Out-Null
    $cscExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    $cscOk = (($cscExit -eq 0) -and (Test-Path -LiteralPath $fakeNative))
  }
  Check 'native fake launcher compiled' $cscOk
  if ($cscOk) {
    if (Test-Path -LiteralPath $argvFile) { Remove-Item -LiteralPath $argvFile -Force }
    $env:FLEET_CODEX_LAUNCHER = $fakeNative
    $env:FAKE_CODEX_ARGV_FILE = $argvFile
    $env:LOCALAPPDATA = $fakeLocal
    $specialPrompt = 'token C:\path\"quoted" end'
    $nativeOut = Join-Path $temp 'native-out.txt'
    $nativeErr = Join-Path $temp 'native-err.txt'
    $nativeArgs = ConvertTo-WindowsCommandLine -ArgumentTokens @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target,
      '-Prompt', $specialPrompt, '-Mode', 'json', '-TimeoutSeconds', '30',
      '-FirstOutputSeconds', '15', '-SkipGitRepoCheck'
    )
    $np = Start-Process -FilePath 'powershell.exe' -ArgumentList $nativeArgs `
      -NoNewWindow -Wait -PassThru -RedirectStandardOutput $nativeOut -RedirectStandardError $nativeErr
    # Prompt arg includes a newline+trailer; record file is newline-joined argv,
    # so assert on raw text rather than per-line equality.
    $argvRaw = if (Test-Path -LiteralPath $argvFile) { Get-Content -Raw -LiteralPath $argvFile } else { '' }
    Check 'native launcher preserves backslash-quote prompt' (
      $np.ExitCode -eq 0 -and
      $argvRaw.Contains('C:\path\"quoted"') -and
      ($argvRaw -match '(?m)^exec$')
    )
    Remove-Item Env:FAKE_CODEX_ARGV_FILE -ErrorAction SilentlyContinue
  }

  # --- cmd launcher: quote+ampersand fail-closed ---
  $fakeCmd = Join-Path $temp 'codex-unsafe.cmd'
  [IO.File]::WriteAllText($fakeCmd, '@echo should-not-run')
  $env:FLEET_CODEX_LAUNCHER = $fakeCmd
  $unsafePrompt = 'has "quote" and & ampersand'
  $errFile = Join-Path $temp 'cmd-unsafe.err'
  $outFile = Join-Path $temp 'cmd-unsafe.out'
  # PS5 Start-Process array ArgumentList is unquoted; pass one CRT-quoted string.
  $spArgs = ConvertTo-WindowsCommandLine -ArgumentTokens @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target,
    '-Prompt', $unsafePrompt, '-Mode', 'json', '-TimeoutSeconds', '20',
    '-FirstOutputSeconds', '15', '-SkipGitRepoCheck'
  )
  $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $spArgs `
    -NoNewWindow -Wait -PassThru -RedirectStandardError $errFile -RedirectStandardOutput $outFile
  $errText = if (Test-Path $errFile) { Get-Content -Raw -LiteralPath $errFile } else { '' }
  $outText = if (Test-Path $outFile) { Get-Content -Raw -LiteralPath $outFile } else { '' }
  $combined = $errText + $outText
  Check 'cmd launcher refuses quote-ampersand prompt' (
    $p.ExitCode -ne 0 -and
    $combined -match 'cmd launcher refuses unsafe'
  )

  # --- cmd launcher: unsafe OutputJson fail-closed ---
  $errFileOj = Join-Path $temp 'cmd-unsafe-oj.err'
  $outFileOj = Join-Path $temp 'cmd-unsafe-oj.out'
  $spArgsOj = ConvertTo-WindowsCommandLine -ArgumentTokens @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target,
    '-Prompt', 'safe prompt', '-OutputJson', 'C:\x&whoami', '-Mode', 'json',
    '-TimeoutSeconds', '20', '-FirstOutputSeconds', '15', '-SkipGitRepoCheck'
  )
  $pOj = Start-Process -FilePath 'powershell.exe' -ArgumentList $spArgsOj `
    -NoNewWindow -Wait -PassThru -RedirectStandardError $errFileOj -RedirectStandardOutput $outFileOj
  $errTextOj = if (Test-Path $errFileOj) { Get-Content -Raw -LiteralPath $errFileOj } else { '' }
  $outTextOj = if (Test-Path $outFileOj) { Get-Content -Raw -LiteralPath $outFileOj } else { '' }
  $combinedOj = $errTextOj + $outTextOj
  Check 'cmd launcher refuses unsafe OutputJson' (
    $pOj.ExitCode -ne 0 -and
    $combinedOj -match 'cmd launcher refuses unsafe'
  )

  # --- cmd launcher: unsafe Model fail-closed ---
  $errFileMd = Join-Path $temp 'cmd-unsafe-model.err'
  $outFileMd = Join-Path $temp 'cmd-unsafe-model.out'
  $spArgsMd = ConvertTo-WindowsCommandLine -ArgumentTokens @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target,
    '-Prompt', 'safe prompt', '-Model', 'gpt&whoami', '-Mode', 'json',
    '-TimeoutSeconds', '20', '-FirstOutputSeconds', '15', '-SkipGitRepoCheck'
  )
  $pMd = Start-Process -FilePath 'powershell.exe' -ArgumentList $spArgsMd `
    -NoNewWindow -Wait -PassThru -RedirectStandardError $errFileMd -RedirectStandardOutput $outFileMd
  $errTextMd = if (Test-Path $errFileMd) { Get-Content -Raw -LiteralPath $errFileMd } else { '' }
  $outTextMd = if (Test-Path $outFileMd) { Get-Content -Raw -LiteralPath $outFileMd } else { '' }
  $combinedMd = $errTextMd + $outTextMd
  Check 'cmd launcher refuses unsafe Model' (
    $pMd.ExitCode -ne 0 -and
    $combinedMd -match 'cmd launcher refuses unsafe'
  )
}
finally {
  if ($null -eq $oldLauncher) { Remove-Item Env:FLEET_CODEX_LAUNCHER -ErrorAction SilentlyContinue }
  else { $env:FLEET_CODEX_LAUNCHER = $oldLauncher }
  if ($null -ne $oldLocalAppData) { $env:LOCALAPPDATA = $oldLocalAppData }
  if ($null -ne $oldPath) { $env:PATH = $oldPath }
  Remove-Item Env:FAKE_CODEX_ARGV_FILE -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $temp) {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($Live) {
  $out = & $target -Probe -Mode json -TimeoutSeconds 240 2>$null
  $live = $out | ConvertFrom-Json
  Check 'live probe status ok' ([string]$live.status -eq 'ok')
  Check 'live probe SOL_OK'    ([bool]$live.probe_ok)
}

if ($fail -eq 0) { Write-Host "Test-Invoke-Sol: passed ($pass checks)"; exit 0 }
else { Write-Host "Test-Invoke-Sol: $fail failed"; exit 1 }
