# Ensure slot-local physical node_modules + shared npm cacache (StoreRoot).
# Layout never symlinked/junctioned across slots. PS 5.1 / Windows only.
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Worktree,
  [Parameter(Mandatory)][string]$StoreRoot,
  [string]$PreviousFingerprint = '',
  [string]$InstallCommand,
  [string]$NodeBinDir,
  [switch]$NoInstall,
  [int]$TimeoutSeconds = 1800,
  [ValidateSet('json')][string]$Mode = 'json'
)
$ErrorActionPreference = 'Stop'
$script:SchemaVersion = '1'
$script:PackageManager = 'npm'

function Write-Fail([string]$Message) { [Console]::Error.WriteLine($Message) }

function Test-UnderRoot([string]$Path, [string]$Root) {
  $p = [IO.Path]::GetFullPath($Path).TrimEnd('\'); $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  return $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or ($p + '\').StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-IsReparsePoint([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $item = Get-Item -LiteralPath $Path -Force
  return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)
}

function Get-FileSha256Hex([string]$Path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $stream = [IO.File]::OpenRead($Path)
    try {
      return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    } finally { $stream.Dispose() }
  } finally { $sha.Dispose() }
}

function Get-StringSha256Hex([string]$Text) {
  $enc = New-Object System.Text.UTF8Encoding $false
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($enc.GetBytes($Text))) -replace '-', '').ToLowerInvariant()
  } finally { $sha.Dispose() }
}

function Get-DirBytes([string]$Root) {
  if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path -LiteralPath $Root)) { return [int64]0 }
  [int64]$total = 0
  foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue)) {
    try { $total += [int64]$file.Length } catch { }
  }
  return $total
}
function Get-DepsCount([string]$Root) {
  $nm = Join-Path $Root 'node_modules'
  if (-not (Test-Path -LiteralPath $nm)) { return 0 }
  return @(Get-ChildItem -LiteralPath $nm -Force -ErrorAction SilentlyContinue).Count
}

function Assert-ContainedReparseGraph {
  param([string]$ScanRoot, [string]$SlotRoot)
  if (-not (Test-Path -LiteralPath $ScanRoot)) { return }
  $slotFull = [IO.Path]::GetFullPath($SlotRoot).TrimEnd('\')
  $stack = New-Object System.Collections.Stack
  $stack.Push([IO.Path]::GetFullPath($ScanRoot).TrimEnd('\'))
  while ($stack.Count -gt 0) {
    $dir = [string]$stack.Pop()
    foreach ($child in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
      $isReparse = (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)
      if ($isReparse) {
        $targetRaw = $null; try { $targetRaw = (Get-Item -LiteralPath $child.FullName -Force).Target } catch { }
        $anyTarget = $false
        foreach ($cand in @($targetRaw)) {
          if ([string]::IsNullOrWhiteSpace([string]$cand)) { continue }
          $anyTarget = $true
          $resolved = if ([IO.Path]::IsPathRooted([string]$cand)) { [string]$cand } else { Join-Path (Split-Path -Parent $child.FullName) ([string]$cand) }
          $tFull = try { [IO.Path]::GetFullPath($resolved).TrimEnd('\') } catch { [string]$resolved }
          if (-not (Test-UnderRoot -Path $tFull -Root $slotFull)) {
            throw "Reparse point '$($child.FullName)' escapes slot to '$tFull'."
          }
        }
        if (-not $anyTarget) { throw "Unresolvable reparse point at '$($child.FullName)'." }
        continue
      }
      if ($child.PSIsContainer) { $stack.Push([string]$child.FullName) }
    }
  }
}

function Get-TrackedRelPaths([string]$Root) {
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $raw = @(& git -C $Root ls-files 2>$null); $code = $LASTEXITCODE
  $ErrorActionPreference = $prevEap
  if ($code -ne 0) { throw "git ls-files failed under $Root (exit $code)" }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($line in $raw) {
    $rel = ([string]$line).Trim().Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($rel)) { continue }
    $baseName = [IO.Path]::GetFileName($rel)
    if ($baseName -eq 'package.json' -or $baseName -eq 'package-lock.json' -or $baseName -eq 'npm-shrinkwrap.json') {
      [void]$out.Add($rel)
    }
  }
  return @($out)
}

function Get-SortedFileEntries([string]$Root, [string[]]$RelPaths, [string[]]$Names) {
  $nameSet = @{}; foreach ($nm in @($Names)) { $nameSet[$nm.ToLowerInvariant()] = $true }
  $entries = New-Object System.Collections.Generic.List[string]
  foreach ($rel in @($RelPaths | Sort-Object { $_.ToLowerInvariant() })) {
    $baseName = [IO.Path]::GetFileName($rel).ToLowerInvariant()
    if (-not $nameSet.ContainsKey($baseName)) { continue }
    $full = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    [void]$entries.Add(($rel.Replace('\', '/') + '=' + (Get-FileSha256Hex -Path $full)))
  }
  return @($entries)
}

function Resolve-Toolchain([string]$BinDir) {
  $nodePath = $null; $nodeVer = 'unknown'; $npmVer = 'unknown'
  if (-not [string]::IsNullOrWhiteSpace($BinDir)) {
    $cand = Join-Path $BinDir.TrimEnd('\') 'node.exe'
    if (Test-Path -LiteralPath $cand -PathType Leaf) { $nodePath = [IO.Path]::GetFullPath($cand) }
  }
  if ([string]::IsNullOrWhiteSpace($nodePath)) {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $nodePath = [string]$cmd.Source } else { $nodePath = 'node' }
  }
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  if ($nodePath -ne 'node' -or (Get-Command node -ErrorAction SilentlyContinue)) {
    $nv = @(& $nodePath -v 2>$null)
    if ($nv -and $nv.Count -gt 0) { $nodeVer = ([string]$nv[0]).Trim() }
  }
  $ErrorActionPreference = $prevEap
  # Prefer npm next to resolved node (stable vs PATH shims that only implement install).
  # Fingerprint must match across init (PATH mock) and enter (system PATH) when node is same.
  $npmCmd = $null
  if ($nodePath -ne 'node' -and -not [string]::IsNullOrWhiteSpace($nodePath)) {
    $nodeDir = Split-Path -Parent $nodePath
    foreach ($nm in @('npm.cmd', 'npm.exe', 'npm')) {
      $candNpm = Join-Path $nodeDir $nm
      if (Test-Path -LiteralPath $candNpm -PathType Leaf) { $npmCmd = $candNpm; break }
    }
  }
  $prevPath = $env:PATH
  try {
    if (-not [string]::IsNullOrWhiteSpace($BinDir)) { $env:PATH = $BinDir.TrimEnd('\') + ';' + $prevPath }
    $prevEap2 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    if (-not [string]::IsNullOrWhiteSpace($npmCmd)) {
      $mv = @(& $npmCmd -v 2>$null)
    } else {
      $mv = @(& npm -v 2>$null)
    }
    $ErrorActionPreference = $prevEap2
    if ($mv -and $mv.Count -gt 0) {
      $candVer = ([string]$mv[0]).Trim()
      # Reject non-semver noise from mock npm.cmd that only echoes args
      if ($candVer -match '^\d+\.\d+') { $npmVer = $candVer }
    }
    if ($npmVer -eq 'unknown') {
      $mv2 = @(& npm -v 2>$null)
      if ($mv2 -and $mv2.Count -gt 0) {
        $candVer2 = ([string]$mv2[0]).Trim()
        if ($candVer2 -match '^\d+\.\d+') { $npmVer = $candVer2 }
      }
    }
  } finally { $env:PATH = $prevPath }
  $arch = [string][Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
  if ([string]::IsNullOrWhiteSpace($arch)) { $arch = 'unknown' }
  return @{
    NodePath = $nodePath; NodeVersion = $nodeVer; NpmVersion = $npmVer
    Os = [string][Environment]::OSVersion.Platform; Arch = $arch
  }
}

function Build-InstallCommandText([string]$Custom, [string]$Root, [string]$CacheRoot) {
  if (-not [string]::IsNullOrWhiteSpace($Custom)) { return $Custom.Trim() }
  $cacheArg = '"' + $CacheRoot.TrimEnd('\') + '"'
  $hasLock = (Test-Path -LiteralPath (Join-Path $Root 'package-lock.json') -PathType Leaf) -or
    (Test-Path -LiteralPath (Join-Path $Root 'npm-shrinkwrap.json') -PathType Leaf)
  if ($hasLock) { return "npm ci --cache $cacheArg --prefer-offline --no-audit --fund=false" }
  return "npm install --cache $cacheArg --prefer-offline --no-audit --fund=false"
}

function Get-NpmrcFingerprintBytes([string]$Root) {
  $npmrc = Join-Path $Root '.npmrc'
  if (-not (Test-Path -LiteralPath $npmrc -PathType Leaf)) { return 'npmrc=absent' }
  return ('npmrc=' + (Get-FileSha256Hex -Path $npmrc))
}
function Build-Fingerprint([string]$InstallCmd, [string[]]$LockEntries, [string[]]$PkgEntries, [hashtable]$Tool, [string]$NpmrcLine = 'npmrc=absent') {
  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add("schema_version=$($script:SchemaVersion)"); [void]$lines.Add("package_manager=$($script:PackageManager)")
  [void]$lines.Add("install_command=$InstallCmd"); [void]$lines.Add('lockfiles:')
  foreach ($entry in @($LockEntries)) { [void]$lines.Add($entry) }
  [void]$lines.Add('package_jsons:')
  foreach ($entry in @($PkgEntries)) { [void]$lines.Add($entry) }
  [void]$lines.Add($NpmrcLine)
  [void]$lines.Add("node=$($Tool.NodePath)|$($Tool.NodeVersion)"); [void]$lines.Add("npm=$($Tool.NpmVersion)")
  [void]$lines.Add("os=$($Tool.Os)|$($Tool.Arch)")
  return Get-StringSha256Hex -Text ($lines -join "`n")
}

# Gather lock/pkg entries + install command + fingerprint for current slot disk state.
# Callers re-run after install so returned depFp includes generated lockfiles / cmd flip.
function Get-DependencyFingerprintState {
  param(
    [string]$Root,
    [string]$CustomInstall,
    [string]$CacheRoot,
    [string]$BinDir
  )
  $tracked = Get-TrackedRelPaths -Root $Root
  $lockEntries = Get-SortedFileEntries -Root $Root -RelPaths $tracked -Names @('package-lock.json', 'npm-shrinkwrap.json')
  $pkgEntries = Get-SortedFileEntries -Root $Root -RelPaths $tracked -Names @('package.json')
  $tool = Resolve-Toolchain -BinDir $BinDir
  $installCmdText = Build-InstallCommandText -Custom $CustomInstall -Root $Root -CacheRoot $CacheRoot
  $npmrcLine = Get-NpmrcFingerprintBytes -Root $Root
  $manifestSha = Get-StringSha256Hex -Text (($pkgEntries -join "`n"))
  $lockSha = if ($lockEntries.Count -gt 0) { Get-StringSha256Hex -Text (($lockEntries -join "`n")) } else { '' }
  $toolchainSha = Get-StringSha256Hex -Text ("node=$($tool.NodePath)|$($tool.NodeVersion)`nnpm=$($tool.NpmVersion)`nos=$($tool.Os)|$($tool.Arch)")
  $depFp = Build-Fingerprint -InstallCmd $installCmdText -LockEntries $lockEntries -PkgEntries $pkgEntries -Tool $tool -NpmrcLine $npmrcLine
  return [pscustomobject]@{
    InstallCmdText = $installCmdText
    ManifestSha    = $manifestSha
    LockSha        = $lockSha
    ToolchainSha   = $toolchainSha
    DepFp          = $depFp
  }
}

function Stop-Tree([System.Diagnostics.Process]$Process) {
  if ($null -eq $Process) { return }
  try { $processId = $Process.Id } catch { return }
  try { & taskkill.exe /PID $processId /T /F 2>$null | Out-Null } catch { }
  try { $null = $Process.WaitForExit(5000) } catch { }
}

function Invoke-Install([string]$WorktreeRoot, [string]$Command, [string]$BinDir, [string]$CacheRoot, [bool]$CustomCommand, [int]$TimeoutSec) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'cmd.exe'; $psi.Arguments = "/d /c $Command"; $psi.WorkingDirectory = $WorktreeRoot
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  if (-not [string]::IsNullOrWhiteSpace($BinDir)) {
    $psi.EnvironmentVariables['PATH'] = $BinDir.TrimEnd('\') + ';' + $psi.EnvironmentVariables['PATH']
  }
  if ($CustomCommand) {
    $psi.EnvironmentVariables['npm_config_cache'] = $CacheRoot.TrimEnd('\')
    $psi.EnvironmentVariables['npm_config_prefer_offline'] = 'true'
  }
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync(); $stderrTask = $proc.StandardError.ReadToEndAsync()
  if (-not $proc.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
    Stop-Tree -Process $proc; try { $null = $proc.WaitForExit(5000) } catch { }
    $null = $stdoutTask.Wait(2000); $null = $stderrTask.Wait(2000); $proc.Dispose()
    throw "Install timed out after ${TimeoutSec}s: $Command"
  }
  $code = $proc.ExitCode
  $errText = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { '' }
  $outText = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { '' }
  $proc.Dispose()
  if ($code -ne 0) {
    if ($errText) { Write-Fail $errText.TrimEnd() }
    if ($outText) { Write-Fail $outText.TrimEnd() }
    throw "Install exited ${code}: $Command"
  }
}

function Emit-Result {
  param(
    [string]$Status, [string]$DepFp, [string]$ManifestSha, [string]$ToolchainSha,
    [string]$InstallReason, [int64]$InstallMs, [string]$LockSha, [int]$DepsCount,
    [int64]$NmBytes, [int64]$StoreBefore, [int64]$StoreAfter
  )
  $obj = [ordered]@{
    status = $Status; layout = 'slot-local-physical'; cache_provider = 'npm-cacache'
    dependency_fingerprint = $DepFp; manifest_sha256 = $ManifestSha; toolchain_sha256 = $ToolchainSha
    install_reason = $InstallReason; install_ms = $InstallMs; lockfile_sha256 = $LockSha
    deps_count = $DepsCount; node_modules_bytes = $NmBytes
    store_bytes_before = $StoreBefore; store_bytes_after = $StoreAfter
  }
  Write-Output (($obj | ConvertTo-Json -Compress))
}

$storeBefore = [int64]0; $storeAfter = [int64]0; $installMs = [int64]0
$installReason = ''; $depFp = ''; $manifestSha = ''; $toolchainSha = ''; $lockSha = ''
$depsCount = 0; $nmBytes = [int64]0; $slot = $null; $store = $null

try {
  if ([string]::IsNullOrWhiteSpace($Worktree)) { throw 'Worktree is required.' }
  if ([string]::IsNullOrWhiteSpace($StoreRoot)) { throw 'StoreRoot is required.' }
  $slot = [IO.Path]::GetFullPath($Worktree).TrimEnd('\')
  if (-not (Test-Path -LiteralPath $slot -PathType Container)) { throw "Worktree path does not exist: $slot" }
  $store = [IO.Path]::GetFullPath($StoreRoot).TrimEnd('\')
  if (-not (Test-Path -LiteralPath $store)) { New-Item -ItemType Directory -Force -Path $store | Out-Null }
  $storeBefore = Get-DirBytes -Root $store

  # Pre-install fingerprint: reuse/mismatch decision must use CURRENT (pre-install) state.
  $isCustom = -not [string]::IsNullOrWhiteSpace($InstallCommand)
  $fpState = Get-DependencyFingerprintState -Root $slot -CustomInstall $InstallCommand -CacheRoot $store -BinDir $NodeBinDir
  $installCmdText = [string]$fpState.InstallCmdText
  $manifestSha = [string]$fpState.ManifestSha
  $lockSha = [string]$fpState.LockSha
  $toolchainSha = [string]$fpState.ToolchainSha
  $depFp = [string]$fpState.DepFp

  $nmPath = Join-Path $slot 'node_modules'
  if ((Test-Path -LiteralPath $nmPath) -and (Test-IsReparsePoint -Path $nmPath)) {
    throw "node_modules root is a reparse point (symlink/junction forbidden): $nmPath"
  }

  $nmNonempty = (Get-DepsCount -Root $slot) -gt 0
  $fpMatch = (-not [string]::IsNullOrWhiteSpace($PreviousFingerprint)) -and ($PreviousFingerprint -eq $depFp)
  $reparseOk = $true; $reparseErr = ''
  if ($nmNonempty) {
    try { Assert-ContainedReparseGraph -ScanRoot $nmPath -SlotRoot $slot }
    catch { $reparseOk = $false; $reparseErr = $_.Exception.Message }
  }

  if ($NoInstall) {
    $depsCount = Get-DepsCount -Root $slot; $nmBytes = Get-DirBytes -Root $nmPath; $storeAfter = Get-DirBytes -Root $store
    Emit-Result -Status 'skipped' -DepFp $depFp -ManifestSha $manifestSha -ToolchainSha $toolchainSha `
      -InstallReason 'no-install' -InstallMs 0 -LockSha $lockSha -DepsCount $depsCount `
      -NmBytes $nmBytes -StoreBefore $storeBefore -StoreAfter $storeAfter
    exit 0
  }

  if ($fpMatch -and $nmNonempty -and $reparseOk) {
    $depsCount = Get-DepsCount -Root $slot; $nmBytes = Get-DirBytes -Root $nmPath; $storeAfter = Get-DirBytes -Root $store
    Emit-Result -Status 'reuse-hit' -DepFp $depFp -ManifestSha $manifestSha -ToolchainSha $toolchainSha `
      -InstallReason 'fingerprint-match' -InstallMs 0 -LockSha $lockSha -DepsCount $depsCount `
      -NmBytes $nmBytes -StoreBefore $storeBefore -StoreAfter $storeAfter
    exit 0
  }

  if (-not $reparseOk -and $nmNonempty -and $fpMatch) { throw $reparseErr }

  if ([string]::IsNullOrWhiteSpace($PreviousFingerprint)) { $installReason = 'previous-empty' }
  elseif (-not $fpMatch) { $installReason = 'fingerprint-mismatch' }
  elseif (-not (Test-Path -LiteralPath $nmPath)) { $installReason = 'missing-node-modules' }
  elseif (-not $nmNonempty) { $installReason = 'hollow-node-modules' }
  else { $installReason = 'refresh-required' }

  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    Invoke-Install -WorktreeRoot $slot -Command $installCmdText -BinDir $NodeBinDir `
      -CacheRoot $store -CustomCommand $isCustom -TimeoutSec $TimeoutSeconds
  } catch {
    $sw.Stop(); $installMs = [int64]$sw.ElapsedMilliseconds; $installReason = $_.Exception.Message
    $depsCount = Get-DepsCount -Root $slot; $nmBytes = Get-DirBytes -Root $nmPath; $storeAfter = Get-DirBytes -Root $store
    Write-Fail $installReason
    Emit-Result -Status 'failed' -DepFp $depFp -ManifestSha $manifestSha -ToolchainSha $toolchainSha `
      -InstallReason $installReason -InstallMs $installMs -LockSha $lockSha -DepsCount $depsCount `
      -NmBytes $nmBytes -StoreBefore $storeBefore -StoreAfter $storeAfter
    exit 1
  }
  $sw.Stop(); $installMs = [int64]$sw.ElapsedMilliseconds

  if ((Test-Path -LiteralPath $nmPath) -and (Test-IsReparsePoint -Path $nmPath)) {
    throw "Install produced reparse-point node_modules root (forbidden): $nmPath"
  }
  if ((Get-DepsCount -Root $slot) -le 0) {
    $installReason = 'install-exited-0-hollow-node-modules'
    $depsCount = 0; $nmBytes = Get-DirBytes -Root $nmPath; $storeAfter = Get-DirBytes -Root $store
    Write-Fail $installReason
    Emit-Result -Status 'failed' -DepFp $depFp -ManifestSha $manifestSha -ToolchainSha $toolchainSha `
      -InstallReason $installReason -InstallMs $installMs -LockSha $lockSha -DepsCount $depsCount `
      -NmBytes $nmBytes -StoreBefore $storeBefore -StoreAfter $storeAfter
    exit 1
  }
  Assert-ContainedReparseGraph -ScanRoot $nmPath -SlotRoot $slot
  # Post-install recompute: npm install may generate package-lock.json and flip default cmd
  # to npm ci; returned fingerprint must match next acquire or reuse-hit never fires.
  $fpStateAfter = Get-DependencyFingerprintState -Root $slot -CustomInstall $InstallCommand -CacheRoot $store -BinDir $NodeBinDir
  $manifestSha = [string]$fpStateAfter.ManifestSha
  $lockSha = [string]$fpStateAfter.LockSha
  $toolchainSha = [string]$fpStateAfter.ToolchainSha
  $depFp = [string]$fpStateAfter.DepFp
  $depsCount = Get-DepsCount -Root $slot; $nmBytes = Get-DirBytes -Root $nmPath; $storeAfter = Get-DirBytes -Root $store
  Emit-Result -Status 'installed' -DepFp $depFp -ManifestSha $manifestSha -ToolchainSha $toolchainSha `
    -InstallReason $installReason -InstallMs $installMs -LockSha $lockSha -DepsCount $depsCount `
    -NmBytes $nmBytes -StoreBefore $storeBefore -StoreAfter $storeAfter
  exit 0
} catch {
  Write-Fail $_.Exception.Message
  if ([string]::IsNullOrWhiteSpace($installReason)) { $installReason = $_.Exception.Message }
  try {
    if ($slot) { $depsCount = Get-DepsCount -Root $slot; $nmBytes = Get-DirBytes -Root (Join-Path $slot 'node_modules') }
    if ($store) { $storeAfter = Get-DirBytes -Root $store }
  } catch { }
  try {
    Emit-Result -Status 'failed' -DepFp $depFp -ManifestSha $manifestSha -ToolchainSha $toolchainSha `
      -InstallReason $installReason -InstallMs $installMs -LockSha $lockSha -DepsCount $depsCount `
      -NmBytes $nmBytes -StoreBefore $storeBefore -StoreAfter $storeAfter
  } catch { }
  exit 1
}
