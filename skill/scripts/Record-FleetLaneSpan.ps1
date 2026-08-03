param(
  [Parameter(Mandatory = $true)]
  [string]$RecordPath,
  [string]$OutputPath
)

# PS 5.1 does not populate $PSScriptRoot in param defaults - resolve in the body.
if (-not $OutputPath) { $OutputPath = Join-Path $PSScriptRoot '..\BENCH-lanes.jsonl' }

$ErrorActionPreference = "Stop"
$utf8 = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot "Test-FleetLaneSpanRecord.ps1")

if (-not ("FleetPathNative" -as [type])) {
  Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class FleetPathNative {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern SafeFileHandle CreateFile(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern int GetFinalPathNameByHandle(SafeFileHandle hFile, StringBuilder lpszFilePath, int cchFilePath, uint dwFlags);
  const uint GENERIC_READ = 0x80000000;
  const uint FILE_SHARE_ALL = 0x7;
  const uint OPEN_EXISTING = 3;
  const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
  public static string GetFinalPath(string path) {
    using (var h = CreateFile(path, GENERIC_READ, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero)) {
      if (h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
      var sb = new StringBuilder(512);
      int n = GetFinalPathNameByHandle(h, sb, sb.Capacity, 0);
      if (n <= 0) throw new Win32Exception(Marshal.GetLastWin32Error());
      if (n >= sb.Capacity) { sb.EnsureCapacity(n + 1); n = GetFinalPathNameByHandle(h, sb, sb.Capacity, 0); }
      string p = sb.ToString();
      if (p.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + p.Substring(8);
      if (p.StartsWith(@"\\?\", StringComparison.Ordinal)) return p.Substring(4);
      return p;
    }
  }
}
"@
}

function Get-LaneLedgerMutexKey([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path)
  $existing = $full
  $parts = New-Object System.Collections.ArrayList
  while ($existing -and -not (Test-Path -LiteralPath $existing)) {
    $leaf = Split-Path -Leaf $existing
    $parent = Split-Path -Parent $existing
    if (-not $parent -or $parent -eq $existing) { break }
    [void]$parts.Insert(0, $leaf)
    $existing = $parent
  }
  if ($existing -and (Test-Path -LiteralPath $existing)) {
    $resolved = [FleetPathNative]::GetFinalPath($existing)
  } else {
    $resolved = $full
  }
  foreach ($part in $parts) { $resolved = Join-Path $resolved $part }
  return ([string]$resolved).ToUpperInvariant()
}

try {
  if (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
    throw "RecordPath not found: $RecordPath"
  }
  $raw = [IO.File]::ReadAllText([IO.Path]::GetFullPath($RecordPath), $utf8)
  $record = $raw | ConvertFrom-Json
  $canonical = ConvertTo-CanonicalLaneSpan $record
  $line = ([pscustomobject]$canonical | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine

  $directory = Split-Path -Parent $OutputPath
  if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
  $fullPath = [IO.Path]::GetFullPath($OutputPath)
  $mutexKey = Get-LaneLedgerMutexKey $fullPath
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($mutexKey))).Replace("-", "").Substring(0, 24)
  } finally {
    $sha.Dispose()
  }
  $mutex = [Threading.Mutex]::new($false, "Global\CodexFleetLaneSpan-$hash")
  try {
    if (-not $mutex.WaitOne(30000)) { throw "Timed out waiting for lane span ledger lock" }
    if (Test-Path -LiteralPath $fullPath) {
      foreach ($existingLine in [IO.File]::ReadAllLines($fullPath, $utf8)) {
        if ([string]::IsNullOrWhiteSpace($existingLine)) { continue }
        $existing = $existingLine | ConvertFrom-Json
        if ([string]$existing.run_id -eq [string]$canonical.run_id -and [string]$existing.lane_id -eq [string]$canonical.lane_id) {
          throw "Duplicate lane span record: $($canonical.run_id)/$($canonical.lane_id)"
        }
      }
    }
    [IO.File]::AppendAllText($fullPath, $line, $utf8)
  } finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
  }
  exit 0
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
