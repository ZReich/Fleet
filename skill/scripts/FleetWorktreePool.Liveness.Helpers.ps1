function Get-FleetPoolProcessStartUtc([int]$ProcessId) {
  $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if ($null -eq $proc) { return $null }; return ([datetimeoffset]$proc.StartTime.ToUniversalTime()).ToString('o')
}
function Test-FleetPoolProcessIdentityLive {
  param([int]$ProcessId, [string]$StartUtc)
  if ($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($StartUtc)) { return $false }
  $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if ($null -eq $proc) { return $false }
  try {
    $want = [datetimeoffset]::Parse($StartUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
    return ([math]::Abs(($want - ([datetimeoffset]$proc.StartTime.ToUniversalTime())).TotalSeconds) -lt 2.0)
  } catch {
    # A process object exists but StartTime is inaccessible: unknown is live.
    return $true
  }
}
function Test-FleetPoolRegisteredWorkersLive {
  param($Slot)
  foreach ($row in @($Slot.processes)) {
    $rowPid = 0; try { $rowPid = [int]$row.pid } catch { continue }
    if (Test-FleetPoolProcessIdentityLive -ProcessId $rowPid -StartUtc ([string]$row.start_utc)) { return $true }
  }
  return $false
}
function Test-FleetPoolHasRegistration {
  param($Slot)
  try { if ($Slot.ever_registered -eq $true) { return $true } } catch { }
  foreach ($row in @($Slot.processes)) {
    if ($null -eq $row) { continue }; $rowPid = 0; try { $rowPid = [int]$row.pid } catch { continue }
    if ($rowPid -gt 0) { return $true }
  }
  return $false
}
function Test-FleetPoolOwnerLive {
  param($Slot)
  $ownPid = 0; try { if ($null -ne $Slot.owner_pid) { $ownPid = [int]$Slot.owner_pid } } catch { }
  return ($ownPid -gt 0 -and (Test-FleetPoolProcessIdentityLive -ProcessId $ownPid -StartUtc ([string]$Slot.owner_start_utc)))
}
function Test-FleetPoolLeaseLive { param($Slot); return ((Test-FleetPoolOwnerLive -Slot $Slot) -or (Test-FleetPoolRegisteredWorkersLive -Slot $Slot)) }
function Initialize-FleetPoolNativeCwdProbe {
  if ($null -ne ('FleetWorktreePool.NativeCwd' -as [type])) { return $true }
  try { Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace FleetWorktreePool {
  public static class NativeCwd {
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool CloseHandle(IntPtr handle);
    [DllImport("ntdll.dll")] public static extern int NtQueryInformationProcess(IntPtr process, int informationClass, byte[] information, int informationLength, out int returnLength);
  }
}
'@ -ErrorAction Stop
    return $true
  } catch { return $false }
}
function Read-FleetPoolProcessMemory {
  param([IntPtr]$Handle, [IntPtr]$Address, [int]$Count)
  $bytes = New-Object byte[] $Count; $read = [IntPtr]::Zero
  if (-not [FleetWorktreePool.NativeCwd]::ReadProcessMemory($Handle, $Address, $bytes, [IntPtr]$Count, [ref]$read)) { return $null }
  if ($read.ToInt64() -ne $Count) { return $null }
  return ,$bytes
}
function Get-FleetPoolProcessCurrentDirectory {
  # Reads RTL_USER_PROCESS_PARAMETERS.CurrentDirectory from the target PEB. Any
  # failure deliberately returns null; callers treat unknown as live.
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return $null }
  try {
    $null = Initialize-FleetPoolNativeCwdProbe
    $handle = [FleetWorktreePool.NativeCwd]::OpenProcess(0x410, $false, $ProcessId)
    if ($handle -eq [IntPtr]::Zero) { return $null }
    try {
      $is64 = ([IntPtr]::Size -eq 8); $pbiSize = if ($is64) { 48 } else { 24 }; $pbi = New-Object byte[] $pbiSize; $returned = 0
      if ([FleetWorktreePool.NativeCwd]::NtQueryInformationProcess($handle, 0, $pbi, $pbi.Length, [ref]$returned) -ne 0) { return $null }
      $pebOffset = if ($is64) { 8 } else { 4 }; $peb = if ($is64) { [Runtime.InteropServices.Marshal]::ReadInt64($pbi, $pebOffset) } else { [Runtime.InteropServices.Marshal]::ReadInt32($pbi, $pebOffset) }
      if ($peb -eq 0) { return $null }
      $ppOffset = if ($is64) { 0x20 } else { 0x10 }; $ppBytes = Read-FleetPoolProcessMemory -Handle $handle -Address ([IntPtr]($peb + $ppOffset)) -Count ([IntPtr]::Size)
      if ($null -eq $ppBytes) { return $null }
      $paramsPtr = if ($is64) { [Runtime.InteropServices.Marshal]::ReadInt64($ppBytes, 0) } else { [Runtime.InteropServices.Marshal]::ReadInt32($ppBytes, 0) }
      if ($paramsPtr -eq 0) { return $null }
      $cwdOffset = if ($is64) { 0x38 } else { 0x24 }; $usSize = if ($is64) { 16 } else { 8 }; $us = Read-FleetPoolProcessMemory -Handle $handle -Address ([IntPtr]($paramsPtr + $cwdOffset)) -Count $usSize
      if ($null -eq $us) { return $null }
      $len = [Runtime.InteropServices.Marshal]::ReadInt16($us, 0); $bufOffset = if ($is64) { 8 } else { 4 }; $buffer = if ($is64) { [Runtime.InteropServices.Marshal]::ReadInt64($us, $bufOffset) } else { [Runtime.InteropServices.Marshal]::ReadInt32($us, $bufOffset) }
      if ($len -le 0 -or $buffer -eq 0 -or ($len % 2) -ne 0) { return $null }
      $raw = Read-FleetPoolProcessMemory -Handle $handle -Address ([IntPtr]$buffer) -Count $len
      if ($null -eq $raw) { return $null }
      $cwd = [Text.Encoding]::Unicode.GetString($raw)
      if ($cwd.StartsWith('\\?\')) { $cwd = $cwd.Substring(4) }
      if ($cwd.StartsWith('\??\')) { $cwd = $cwd.Substring(4) }
      return [IO.Path]::GetFullPath($cwd).TrimEnd('\')
    } finally { [void][FleetWorktreePool.NativeCwd]::CloseHandle($handle) }
  } catch { return $null }
}
function Test-FleetPoolSlotPathInLiveCommandLine {
  # This is the shared release/reap liveness gate. A failed process query is
  # unsafe, but an unreadable CWD on an otherwise nonmatching process is not
  # evidence that this particular slot is live.
  param([string]$SlotPath)
  $needle = [IO.Path]::GetFullPath($SlotPath).TrimEnd('\')
  try { $rows = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { return $true }
  try { if (-not (Initialize-FleetPoolNativeCwdProbe)) { return $true } } catch { return $true }
  # Unknown process metadata is live. The fixture-only relaxation keeps unrelated
  # desktop processes from masking a test worker; production never enables it.
  $relaxUnrelated = ($env:FLEET_TEST_HARNESS -ceq '1' -and $env:FLEET_POOL_TEST_RELAX_UNRELATED -ceq '1')
  $currentSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
  foreach ($row in $rows) {
    $rowSession = -1; try { $rowSession = [int]$row.SessionId } catch { return $true }
    $rowPid = 0; try { $rowPid = [int]$row.ProcessId } catch { return $true }
    $commandLine = $null; try { $commandLine = $row.CommandLine } catch { return $true }
    if ([string]::IsNullOrWhiteSpace([string]$commandLine)) {
      if (-not $relaxUnrelated) { return $true }
    }
    if (([string]$commandLine).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    if ($rowSession -ne $currentSession) {
      if ($relaxUnrelated) { continue }
      return $true
    }
    $cwd = Get-FleetPoolProcessCurrentDirectory -ProcessId $rowPid
    if ([string]::IsNullOrWhiteSpace([string]$cwd)) {
      if ($relaxUnrelated) { continue }
      return $true
    }
    try { if (Test-UnderRoot -Path $cwd -Root $needle) { return $true } } catch { return $true }
  }
  return $false
}

function Resolve-FleetPoolSlotContext {
  param([Parameter(Mandatory)][string]$WorkingDirectory)
  if ([string]::IsNullOrWhiteSpace($WorkingDirectory) -or -not (Test-Path -LiteralPath $WorkingDirectory)) { return $null }
  $wd = [IO.Path]::GetFullPath($WorkingDirectory).TrimEnd('\'); $canon = Get-FleetPoolCanonicalRoot
  if (-not (Test-UnderRoot -Path $wd -Root $canon)) { return $null }
  # Search pool.json under worktrees root; slot path ancestor of (or equals) wd.
  foreach ($repoDir in @(Get-ChildItem -LiteralPath $canon -Directory -ErrorAction SilentlyContinue)) {
    $statePath = Join-Path $repoDir.FullName '.fleet-pool\pool.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
    $st = $null; try { $st = Read-FleetPoolStateWithRepoPath -StatePath $statePath -RepoKey ([string]$repoDir.Name) } catch { continue }
    if ($null -eq $st) { continue }
    $repoPath = $null; try { if ($st.repo_path) { $repoPath = [string]$st.repo_path } } catch { }
    if ([string]::IsNullOrWhiteSpace($repoPath)) { continue }
    foreach ($slot in @($st.slots)) {
      $spath = [string]$slot.path; if ([string]::IsNullOrWhiteSpace($spath)) { continue }
      try { $sfull = [IO.Path]::GetFullPath($spath).TrimEnd('\'); if (-not (Test-UnderRoot -Path $wd -Root $sfull)) { continue } } catch { continue }
      $lease = [string]$slot.lease_id; if ([string]::IsNullOrWhiteSpace($lease)) { return $null }
      return [pscustomobject]@{ RepoPath = [IO.Path]::GetFullPath($repoPath).TrimEnd('\'); RepoKey = [string]$st.repo_key; SlotId = [string]$slot.id; SlotPath = $sfull; LeaseId = $lease; RunId = [string]$slot.run_id; State = [string]$slot.state }
    }
  }
  return $null
}
