# Worktree-pool telemetry sink. Appends one JSONL event per call.
# Mutex-serialized concurrent writers. PS 5.1. UTF-8 no BOM.
# Dot-source to get Get-FleetDirectoryBytes / Write-FleetWorktreeTelemetry;
# run as -File with -Event/-Fields to append once.
[CmdletBinding()]
param(
  [string]$Event,
  [hashtable]$Fields,
  [string]$LedgerPath,
  [switch]$NoExit,
  [ValidateSet('json')]
  [string]$Mode = 'json'
)

$ErrorActionPreference = 'Stop'
$script:FleetWttUtf8 = New-Object System.Text.UTF8Encoding $false
$script:FleetWttDotSourced = ($MyInvocation.InvocationName -eq '.')

if ([string]::IsNullOrWhiteSpace($LedgerPath)) {
  $LedgerPath = Join-Path $env:USERPROFILE '.codex\fleet\worktree-pool.jsonl'
}

$script:FleetWttValidEvents = @(
  'provision_start', 'provision_complete',
  'acquire_start', 'acquire_complete',
  'dependency_reuse', 'dependency_install',
  'sanitize_start', 'release_complete',
  'quarantine', 'reap'
)

$script:FleetWttRequiredFields = @(
  'schema_version', 'timestamp_utc', 'event', 'outcome', 'reason',
  'repo_id', 'repo_key', 'pool_size', 'slot_id', 'run_id', 'branch', 'base_sha',
  'ownership', 'wait_ms', 'duration_ms', 'provision_ms', 'install_ms', 'cleanup_ms',
  'reuse_hit', 'install_reason', 'dependency_fingerprint', 'lockfile_sha256',
  'manifest_sha256', 'toolchain_sha256', 'cache_provider', 'deps_count',
  'node_modules_bytes', 'store_bytes_before', 'store_bytes_after',
  'registered_worker_count', 'quarantine_reason'
)

# Fail-closed secret keys (top-level only; case-insensitive).
$script:FleetWttDeniedKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($deniedName in @(
    'lease_id',
    'env',
    'environment',
    'environment_contents',
    'copied_filenames',
    'copied_files',
    'copied_filenames_list',
    'tokens',
    'prompts',
    'command_output',
    'token',
    'secret',
    'authorization',
    'password',
    'apikey',
    'api_key'
  )) {
  [void]$script:FleetWttDeniedKeys.Add($deniedName)
}

function Get-FleetDirectoryBytes {
  <#
  .SYNOPSIS
    Sum file sizes under a directory without descending into reparse points
    (junctions/symlinks). Prevents a disk walker from following a junction
    into a victim tree.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )
  if ([string]::IsNullOrWhiteSpace($Path)) { return [int64]0 }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [int64]0 }

  # Root itself a reparse point (junction/symlink): do not descend into target.
  try {
    $rootAttrs = [IO.File]::GetAttributes($Path)
    if (($rootAttrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      return [int64]0
    }
  } catch {
    return [int64]0
  }

  $totalBytes = [int64]0
  $dirStack = New-Object System.Collections.Generic.Stack[string]
  $dirStack.Push([IO.Path]::GetFullPath($Path))

  while ($dirStack.Count -gt 0) {
    $currentDir = $dirStack.Pop()
    $entries = $null
    try {
      $entries = [IO.Directory]::EnumerateFileSystemEntries($currentDir)
    } catch {
      continue
    }
    foreach ($entryPath in $entries) {
      try {
        $attrs = [IO.File]::GetAttributes($entryPath)
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          # Skip junction/symlink entirely — do not count or descend.
          continue
        }
        if (($attrs -band [IO.FileAttributes]::Directory) -ne 0) {
          $dirStack.Push($entryPath)
        } else {
          $info = New-Object System.IO.FileInfo $entryPath
          $totalBytes += [int64]$info.Length
        }
      } catch {
        # Race / access denied on single entry — skip.
      }
    }
  }
  return $totalBytes
}

function Get-FleetWorktreeTelemetryMutexName {
  param([string]$FullPath)
  $key = ([string]$FullPath).ToUpperInvariant()
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = [BitConverter]::ToString(
      $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))
    ).Replace('-', '').Substring(0, 24)
  } finally {
    $sha.Dispose()
  }
  return "Global\FleetWorktreePoolTelemetry-$hash"
}

function Write-FleetWorktreeTelemetry {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Event,
    [Parameter(Mandatory = $true)]
    [hashtable]$Fields,
    [string]$LedgerPath,
    [ValidateSet('json')]
    [string]$Mode = 'json'
  )

  if ([string]::IsNullOrWhiteSpace($LedgerPath)) {
    $LedgerPath = Join-Path $env:USERPROFILE '.codex\fleet\worktree-pool.jsonl'
  }
  if ($Mode -ne 'json') {
    throw "Unsupported mode: $Mode"
  }
  if ($script:FleetWttValidEvents -notcontains $Event) {
    throw "Unknown event name: $Event"
  }
  if ($null -eq $Fields) {
    $Fields = @{}
  }

  foreach ($fieldKey in @($Fields.Keys)) {
    if ($script:FleetWttDeniedKeys.Contains([string]$fieldKey)) {
      throw "Denied secret field key: $fieldKey"
    }
  }

  # Copy then force event to match -Event (do not mutate caller hashtable).
  $workFields = @{}
  foreach ($srcKey in @($Fields.Keys)) {
    $workFields[$srcKey] = $Fields[$srcKey]
  }
  $workFields['event'] = $Event

  # Missing required keys: fill empty (robust callers); still emit every required key.
  # timestamp_utc auto-stamp when omitted; outcome defaults to 'ok' only when absent.
  if (-not $workFields.ContainsKey('timestamp_utc') -or [string]::IsNullOrWhiteSpace([string]$workFields['timestamp_utc'])) {
    $workFields['timestamp_utc'] = [datetimeoffset]::UtcNow.ToString('o')
  }
  if (-not $workFields.ContainsKey('outcome')) {
    $workFields['outcome'] = 'ok'
  }
  foreach ($reqKey in $script:FleetWttRequiredFields) {
    if (-not $workFields.ContainsKey($reqKey)) {
      $workFields[$reqKey] = ''
      try { [Console]::Error.WriteLine("Warning: missing required field filled empty: $reqKey") } catch { }
    }
  }

  $payload = [ordered]@{}
  foreach ($reqKey in $script:FleetWttRequiredFields) {
    $payload[$reqKey] = $workFields[$reqKey]
  }
  foreach ($extraKey in @($workFields.Keys)) {
    if (-not $payload.Contains($extraKey)) {
      $payload[$extraKey] = $workFields[$extraKey]
    }
  }

  $line = (([pscustomobject]$payload | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine)
  $fullPath = [IO.Path]::GetFullPath($LedgerPath)
  $parentDir = Split-Path -Parent $fullPath
  if ($parentDir -and -not (Test-Path -LiteralPath $parentDir)) {
    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
  }

  $mutexName = Get-FleetWorktreeTelemetryMutexName $fullPath
  $mutex = New-Object System.Threading.Mutex($false, $mutexName)
  $gotLock = $false
  try {
    $gotLock = $mutex.WaitOne(30000)
    if (-not $gotLock) {
      throw 'Timed out waiting for worktree pool telemetry lock'
    }
    [IO.File]::AppendAllText($fullPath, $line, $script:FleetWttUtf8)
  } finally {
    if ($gotLock) {
      try { $mutex.ReleaseMutex() } catch { }
    }
    $mutex.Dispose()
  }
}

if (-not $script:FleetWttDotSourced -and -not $global:FleetWttSuppressCli) {
  try {
    if ([string]::IsNullOrWhiteSpace($Event)) { throw 'Event is required' }
    if ($null -eq $Fields) { $Fields = @{} }
    Write-FleetWorktreeTelemetry -Event $Event -Fields $Fields -LedgerPath $LedgerPath -Mode $Mode
    if ($NoExit) { return }
    exit 0
  } catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($NoExit) { throw }
    exit 1
  }
}
