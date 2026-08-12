# Process launcher kept out of the long pool unit-suite declaration.
function Invoke-PoolScript {
  param(
    [string]$ScriptName,
    [string[]]$ArgList,
    [string]$UserProfile = $fakeProfile
  )
  $scriptPath = Join-Path $scriptsRoot $ScriptName
  $argTokens = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $ArgList
  $quoted = ($argTokens | ForEach-Object {
    $token = [string]$_
    if ($token.Length -eq 0) { '""' }
    elseif ($token -notmatch '[\s"]') { $token }
    else { '"' + ($token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
  }) -join ' '
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = $quoted
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  if ($UserProfile -ne $env:USERPROFILE) { $env:USERPROFILE = $UserProfile }
  $proc = [System.Diagnostics.Process]::Start($psi)
  $outT = $proc.StandardOutput.ReadToEndAsync()
  $errT = $proc.StandardError.ReadToEndAsync()
  $null = $proc.WaitForExit(300000)
  $code = if ($proc.HasExited) { $proc.ExitCode } else { try { $proc.Kill() } catch { }; -1 }
  $stdout = if ($outT.Wait(5000)) { [string]$outT.Result } else { '' }
  $stderr = if ($errT.Wait(5000)) { [string]$errT.Result } else { '' }
  $proc.Dispose()
  return [pscustomobject]@{ ExitCode = $code; Stdout = $stdout.TrimEnd(); Stderr = $stderr.TrimEnd() }
}

function Invoke-FleetPoolUnitLivenessCases {
  param([Parameter(Mandatory)][string]$Repo)
  Case 'H1 CIM query failure is live (fail closed)' {
    function Get-CimInstance { [CmdletBinding()] param(); throw 'injected CIM failure' }
    try { Assert-True (Test-FleetPoolSlotPathInLiveCommandLine -SlotPath $Repo) 'CIM failure must be live' }
    finally { Remove-Item -LiteralPath Function:\Get-CimInstance -ErrorAction SilentlyContinue }
  }
  Case 'null CommandLine and cwd-only process are live' {
    $savedCwdProbe = (Get-Command Get-FleetPoolProcessCurrentDirectory -CommandType Function).ScriptBlock
    $savedSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $script:PoolLivenessRow = [pscustomobject]@{ ProcessId = 424242; SessionId = $savedSession; CommandLine = $null }
    function Get-CimInstance { [CmdletBinding()] param(); return ,$script:PoolLivenessRow }
    function Get-FleetPoolProcessCurrentDirectory { param([int]$ProcessId); return $Repo }
    try { Assert-True (Test-FleetPoolSlotPathInLiveCommandLine -SlotPath $Repo) 'null argv / cwd under slot must be live' }
    finally {
      Remove-Item -LiteralPath Function:\Get-CimInstance -ErrorAction SilentlyContinue
      Set-Item -LiteralPath Function:\Get-FleetPoolProcessCurrentDirectory -Value $savedCwdProbe
      Remove-Variable -Name PoolLivenessRow -Scope Script -ErrorAction SilentlyContinue
    }
  }
  Case 'cross-session fixture worker blocks release liveness' {
    $otherSession = [Diagnostics.Process]::GetCurrentProcess().SessionId + 1
    $script:PoolLivenessRow = [pscustomobject]@{ ProcessId = 424245; SessionId = $otherSession; CommandLine = "worker $Repo" }
    function Get-CimInstance { [CmdletBinding()] param(); return ,$script:PoolLivenessRow }
    try { Assert-True (Test-FleetPoolSlotPathInLiveCommandLine -SlotPath $Repo) 'cross-session worker must be live' }
    finally {
      Remove-Item -LiteralPath Function:\Get-CimInstance -ErrorAction SilentlyContinue
      Remove-Variable -Name PoolLivenessRow -Scope Script -ErrorAction SilentlyContinue
    }
  }
  Case 'CWD probe initialization and StartTime access failures are live' {
    $savedInitProbe = (Get-Command Initialize-FleetPoolNativeCwdProbe -CommandType Function).ScriptBlock
    $savedSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $script:PoolLivenessRow = [pscustomobject]@{ ProcessId = 424244; SessionId = $savedSession; CommandLine = 'fixture' }
    function Get-CimInstance { [CmdletBinding()] param(); return ,$script:PoolLivenessRow }
    function Initialize-FleetPoolNativeCwdProbe { return $false }
    try { Assert-True (Test-FleetPoolSlotPathInLiveCommandLine -SlotPath $Repo) 'CWD probe initialization failure must be live' }
    finally {
      Remove-Item -LiteralPath Function:\Get-CimInstance -ErrorAction SilentlyContinue
      Set-Item -LiteralPath Function:\Initialize-FleetPoolNativeCwdProbe -Value $savedInitProbe
      Remove-Variable -Name PoolLivenessRow -Scope Script -ErrorAction SilentlyContinue
    }
    $fakeProcess = New-Object psobject
    Add-Member -InputObject $fakeProcess -MemberType ScriptProperty -Name StartTime -Value { throw 'injected access denied' }
    function Get-Process { [CmdletBinding()] param([int]$Id); return $fakeProcess }
    try { Assert-True (Test-FleetPoolProcessIdentityLive -ProcessId 424243 -StartUtc '2026-08-10T00:00:00.0000000+00:00') 'inaccessible StartTime must be live' }
    finally { Remove-Item -LiteralPath Function:\Get-Process -ErrorAction SilentlyContinue }
  }
  Case 'residual C-quoted git path is rejected' {
    $rejected = $false
    try { Assert-FleetPoolGitPathNotCQuoted -PathText '"C:\\pool\\caf\303\251"' -Context 'fixture' } catch { $rejected = $true }
    Assert-True $rejected 'C-quoted git path must not be sanitized through'
  }
}
