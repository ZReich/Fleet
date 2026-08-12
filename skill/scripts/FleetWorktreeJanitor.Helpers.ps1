# Small, side-effect-free janitor admission checks.
function Test-JanitorUnderRoot([string]$Path, [string]$Root) {
  $p = [IO.Path]::GetFullPath($Path).TrimEnd('\'); $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
  return $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or ($p + '\').StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Ensure-JanitorCwdHelper {
  if ($script:JanitorCwdReady) { return }
  try {
    Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Text;
public static class FleetJanitorProcCwd {
  const uint ACCESS=0x0410;
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint a,bool i,int p);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h,IntPtr a,byte[] b,int n,out int r);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h,int c,ref PBI p,int s,out int r);
  [StructLayout(LayoutKind.Sequential)] struct PBI { public IntPtr R1,Peb,R2,R3,Pid,R4; }
  static IntPtr ToPtr(byte[] b,int o){return IntPtr.Size==8?new IntPtr(BitConverter.ToInt64(b,o)):new IntPtr(BitConverter.ToInt32(b,o));}
  public static string Get(int pid){
    IntPtr h=OpenProcess(ACCESS,false,pid); if(h==IntPtr.Zero) return null;
    try{
      var pbi=new PBI(); int rl;
      if(NtQueryInformationProcess(h,0,ref pbi,Marshal.SizeOf(typeof(PBI)),out rl)!=0) return null;
      byte[] pb=new byte[IntPtr.Size]; int rd;
      if(!ReadProcessMemory(h,IntPtr.Add(pbi.Peb,IntPtr.Size==8?0x20:0x10),pb,pb.Length,out rd)) return null;
      IntPtr pp=ToPtr(pb,0); byte[] us=new byte[IntPtr.Size==8?16:8];
      if(!ReadProcessMemory(h,IntPtr.Add(pp,IntPtr.Size==8?0x38:0x24),us,us.Length,out rd)) return null;
      ushort len=BitConverter.ToUInt16(us,0); IntPtr buf=ToPtr(us,IntPtr.Size==8?8:4);
      if(len==0||buf==IntPtr.Zero) return null; byte[] s=new byte[len];
      if(!ReadProcessMemory(h,buf,s,len,out rd)) return null;
      return Encoding.Unicode.GetString(s).TrimEnd('\\');
    } finally { CloseHandle(h); }
  }
}
'@ -ErrorAction Stop
    $script:JanitorCwdReady = $true
  } catch { $script:JanitorCwdReady = $false }
}
function Get-JanitorProcessCwd([int]$ProcessId) {
  if ($ProcessId -le 0) { return $null }
  Ensure-JanitorCwdHelper
  if (-not $script:JanitorCwdReady) { return $null }
  try { return [FleetJanitorProcCwd]::Get($ProcessId) } catch { return $null }
}
function Test-JanitorLiveProcessHit([string]$CandidatePath) {
  $needle = [IO.Path]::GetFullPath($CandidatePath).TrimEnd('\')
  $relaxUnrelated = ($env:FLEET_TEST_HARNESS -ceq '1')
  try { $rows = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch { return $true }
  if ($null -eq $rows -or $rows.Count -lt 1) { return $true }
  foreach ($row in $rows) {
    try {
      # Only a process class that can plausibly hold a repository working
      # directory turns otherwise-unrelated protected-process metadata into a hold.
      $treeCapable = ([string]$row.Name -match '^(powershell|pwsh|cmd|git|node|python|codex|grok|claude|kimi|dotnet|msbuild|java|javaw|cargo|go|rustc|bun|deno|esbuild)\.exe$')
      $cl = $row.CommandLine
      if ([string]::IsNullOrWhiteSpace([string]$cl)) {
        if ($treeCapable -and -not $relaxUnrelated) { return $true }
        continue
      }
      if (([string]$cl).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
      $pidVal = 0; try { $pidVal = [int]$row.ProcessId } catch { return $true }
      $cwd = Get-JanitorProcessCwd -ProcessId $pidVal
      if ([string]::IsNullOrWhiteSpace([string]$cwd)) {
        if ($treeCapable -and -not $relaxUnrelated) { return $true }
        continue
      }
      if (Test-JanitorUnderRoot -Path $cwd -Root $needle) { return $true }
    } catch { return $true }
  }
  return $false
}
# TRUE when the directory is a bare orphan: no .git entry AND git does not recognize it as
# inside any work tree. Any error = NOT an orphan (fail closed toward skip).
function Test-JanitorBareOrphan([string]$Path) {
  try {
    if (Test-Path -LiteralPath (Join-Path $Path '.git')) { return $false }
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $out = @(& git -C $Path rev-parse --is-inside-work-tree 2>$null)
      if ($LASTEXITCODE -eq 0 -and $out.Count -gt 0 -and ([string]$out[0]).Trim() -eq 'true') { return $false }
    } finally { $ErrorActionPreference = $prev }
    return $true
  } catch { return $false }
}
function Get-JanitorQuarantineRoot([string]$WorktreeRoot) { return (Join-Path $WorktreeRoot '.fleet-quarantine') }
function Test-JanitorIsReparse([string]$Path) {
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
  } catch { return $true }
}
# Move (atomic same-volume rename) an orphan into quarantine and stamp the clock marker.
# Refuses a reparse-point candidate or quarantine root (Terra H5 2026-08-11): a junction
# quarantine root would redirect the move outside the worktree root.
function Move-JanitorToQuarantine([string]$Path, [string]$WorktreeRoot) {
  if (Test-JanitorIsReparse $Path) { throw "quarantine refused: candidate is a reparse point: $Path" }
  $qroot = Get-JanitorQuarantineRoot $WorktreeRoot
  if (-not (Test-Path -LiteralPath $qroot)) { New-Item -ItemType Directory -Force -Path $qroot | Out-Null }
  if (Test-JanitorIsReparse $qroot) { throw "quarantine refused: quarantine root is a reparse point: $qroot" }
  $leaf = Split-Path -Leaf $Path
  $dest = Join-Path $qroot ($leaf + '-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
  [IO.Directory]::Move([IO.Path]::GetFullPath($Path), $dest)
  $marker = @{ schema_version = '1'; quarantined_utc = [datetimeoffset]::UtcNow.ToString('o'); original_path = $Path } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText(($dest + '.quarantined.json'), $marker, (New-Object System.Text.UTF8Encoding $false))
  return $dest
}
# Age in hours since quarantine, from the sibling marker. Missing/invalid marker: with
# -AllowStamp (Apply mode) stamp NOW and report 0 — the purge clock only ever starts from an
# explicit marker; without it (Report mode) mutate NOTHING and report 0 (Terra M5 2026-08-11).
function Get-JanitorQuarantineAgeHours([string]$QuarantinedDir, [bool]$AllowStamp = $false) {
  $marker = $QuarantinedDir + '.quarantined.json'
  try {
    $obj = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $t = [datetimeoffset]::Parse([string]$obj.quarantined_utc).UtcDateTime
    return [math]::Round(([datetime]::UtcNow - $t).TotalHours, 3)
  } catch {
    if ($AllowStamp) {
      $stamp = @{ schema_version = '1'; quarantined_utc = [datetimeoffset]::UtcNow.ToString('o'); original_path = '' } | ConvertTo-Json -Compress
      try { [IO.File]::WriteAllText($marker, $stamp, (New-Object System.Text.UTF8Encoding $false)) } catch { }
    }
    return 0.0
  }
}
function Test-JanitorLegacyName([string]$Name) {
  return ($Name -like 'grok-*' -or $Name -like 'fleet-*' -or $Name -match '-20260[0-9]{4}')
}
function Get-JanitorSidecarPath([string]$TreePath) { return ([IO.Path]::GetFullPath($TreePath).TrimEnd('\') + '.fleet-run.json') }
function Read-JanitorSidecar([string]$TreePath) {
  $sp = Get-JanitorSidecarPath $TreePath
  if (-not (Test-Path -LiteralPath $sp -PathType Leaf)) { return $null }
  try {
    $obj = Get-Content -LiteralPath $sp -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([string]$obj.schema_version -ne '1' -or [string]$obj.ownership -ne 'run-owned' -or [string]::IsNullOrWhiteSpace([string]$obj.run_id) -or [string]$obj.run_id -notmatch '^[A-Za-z0-9._-]+$') {
      return [pscustomobject]@{ invalid = $true }
    }
    return $obj
  } catch { return $null }
}
# TRUE only when `git status --porcelain` conclusively prints nothing. Any error/output = dirty.
function Test-JanitorTreeClean([string]$Path) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $out = @(& git -C $Path status --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) { return $false }
    foreach ($l in $out) { if (-not [string]::IsNullOrWhiteSpace([string]$l)) { return $false } }
    return $true
  } catch { return $false } finally { $ErrorActionPreference = $prev }
}
# TRUE only when every commit on HEAD is reachable from some OTHER branch or remote ref, so
# removing this worktree (and later its branch) cannot orphan work. Any error = unmerged (fail closed).
function Test-JanitorNoUnmergedCommits([string]$Path, [string]$Branch) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $gitArgs = @('-C', $Path, 'rev-list', '--count', 'HEAD', '--not')
    # --exclude globs are matched relative to refs/heads/ when applied to --branches: bare name.
    if (-not [string]::IsNullOrWhiteSpace($Branch) -and $Branch -cne 'HEAD') { $gitArgs += ('--exclude=' + $Branch) }
    $gitArgs += @('--branches', '--remotes')
    $out = @(& git @gitArgs 2>$null)
    if ($LASTEXITCODE -ne 0 -or $out.Count -lt 1) { return $false }
    $n = 0
    if (-not [int]::TryParse([string]$out[0], [ref]$n)) { return $false }
    return ($n -eq 0)
  } catch { return $false } finally { $ErrorActionPreference = $prev }
}
function Test-JanitorPoolMarker([string]$Path) {
  try {
    $cur = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    while (-not [string]::IsNullOrEmpty($cur)) {
      if (Test-Path -LiteralPath (Join-Path $cur '.fleet-pool\pool.json') -PathType Leaf) { return $true }
      $parent = Split-Path -Parent $cur
      if ([string]::IsNullOrEmpty($parent) -or $parent.Equals($cur, [StringComparison]::OrdinalIgnoreCase)) { break }
      $cur = $parent
    }
  } catch { return $true }
  return $false
}
function Test-JanitorLiveLease([string]$RunId) {
  # LIVE unless lease absent or owner CONCLUSIVELY dead. Malformed/unreadable = LIVE.
  if ([string]::IsNullOrWhiteSpace($RunId)) { return $false }
  if ($RunId -notmatch '^[A-Za-z0-9._-]+$') { return $true }
  $leasePath = Join-Path $env:USERPROFILE ('.codex\fleet\run-leases\' + $RunId + '.json')
  if (-not (Test-Path -LiteralPath $leasePath -PathType Leaf)) { return $false }
  try {
    $lease = Get-Content -LiteralPath $leasePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([string]$lease.schema_version -cne '2' -or [string]$lease.run_id -cne $RunId) { return $true }
    . (Join-Path $PSScriptRoot 'RunLease.Helpers.ps1')
    return -not (Test-FleetOwnerConclusivelyDead $lease ([datetimeoffset]::Now) 2)
  } catch { return $true }
}

# Quarantine purge sweep (moved from the main script at the size split). Operates on the
# caller's candidate list; uses Invoke-JanitorDelete/New-JanitorRow defined by the caller.
function Invoke-JanitorQuarantineSweep {
  param([Parameter(Mandatory)][string]$WorktreeRoot, [Parameter(Mandatory)][string]$Mode,
    [Parameter(Mandatory)][int]$PurgeAgeHours, [Parameter(Mandatory)]$Candidates, [Parameter(Mandatory)][ref]$Scanned)
  # Quarantine purge sweep: quarantined dirs whose marker clock exceeded the purge age.
  $qroot = Get-JanitorQuarantineRoot $WorktreeRoot
  if ((Test-Path -LiteralPath $qroot -PathType Container) -and (Test-JanitorIsReparse $qroot)) {
    [void]$Candidates.Add((New-JanitorRow -Path $qroot -Action 'skip' -Reason 'quarantine_root_reparse' -Ownership 'quarantined'))
  } elseif (Test-Path -LiteralPath $qroot -PathType Container) {
    foreach ($q in @(Get-ChildItem -LiteralPath $qroot -Directory -Force -ErrorAction SilentlyContinue)) {
      $Scanned.Value++
      $qfull = [IO.Path]::GetFullPath($q.FullName).TrimEnd('\')
      if (Test-JanitorIsReparse $qfull) {
        [void]$Candidates.Add((New-JanitorRow -Path $qfull -Action 'skip' -Reason 'reparse_quarantine_entry' -Ownership 'quarantined')); continue
      }
      $qage = Get-JanitorQuarantineAgeHours $qfull ($Mode -eq 'Apply')
      if ($qage -lt [double]$PurgeAgeHours) {
        [void]$Candidates.Add((New-JanitorRow -Path $qfull -Action 'skip' -Reason 'quarantine_holding' -Ownership 'quarantined' -AgeHours $qage)); continue
      }
      if (Test-JanitorLiveProcessHit $qfull) {
        [void]$Candidates.Add((New-JanitorRow -Path $qfull -Action 'skip' -Reason 'live_process' -Ownership 'quarantined' -AgeHours $qage)); continue
      }
      $qbytes = Get-JanitorBytesEstimate $qfull
      if ($Mode -eq 'Report') {
        [void]$Candidates.Add((New-JanitorRow -Path $qfull -Action 'would_remove' -Reason 'quarantine_expired' -Ownership 'quarantined' -AgeHours $qage -Bytes $qbytes -DeleteVia 'purge_orphan_tree')); continue
      }
      try {
        $del = Invoke-JanitorDelete -Path $qfull -Registered:$false -RepoPath ''
        try { Remove-Item -LiteralPath ($qfull + '.quarantined.json') -Force -ErrorAction Stop } catch { }
        [void]$Candidates.Add((New-JanitorRow -Path $qfull -Action 'removed' -Reason 'quarantine_expired' -Ownership 'quarantined' -AgeHours $qage -Bytes $qbytes -DeleteVia $del.Via -Command $del.Command))
      } catch {
        [void]$Candidates.Add((New-JanitorRow -Path $qfull -Action 'skip' -Reason ('delete_failed: ' + $_.Exception.Message) -Ownership 'quarantined' -AgeHours $qage -Bytes $qbytes))
      }
    }
  }

}
