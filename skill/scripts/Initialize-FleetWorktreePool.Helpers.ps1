# Local provisioning utilities kept separate from the pool state transitions.
function Get-FleetPoolDiskBytesLocal([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root)) { return 0 }
  $total = [int64]0
  $stack = New-Object System.Collections.Stack; $stack.Push([IO.Path]::GetFullPath($Root))
  while ($stack.Count -gt 0) {
    $dir = [string]$stack.Pop()
    foreach ($child in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
      if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) { continue }
      if ($child.PSIsContainer) { $stack.Push($child.FullName) }
      else { try { $total += [int64]$child.Length } catch { } }
    }
  }
  return $total
}
