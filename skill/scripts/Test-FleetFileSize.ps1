# Offline suite for Assert-FleetFileSize.ps1 (incl. untracked >cap blind-spot fix).
$ErrorActionPreference = 'Stop'
$assert = Join-Path $PSScriptRoot 'Assert-FleetFileSize.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fleet-filesize-' + [guid]::NewGuid().ToString('n'))
$passed = 0; $failed = 0

function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Assert-True([bool]$c, [string]$m) { if (-not $c) { throw $m } }

try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  $repo = Join-Path $temp 'repo'
  New-Item -ItemType Directory -Force -Path $repo | Out-Null
  & git -C $repo init -q
  & git -C $repo config user.name t
  & git -C $repo config user.email t@t.invalid
  [IO.File]::WriteAllText((Join-Path $repo 'seed.txt'), "seed`n")
  & git -C $repo add .
  & git -C $repo commit -q -m base | Out-Null
  $base = (& git -C $repo rev-parse HEAD).Trim()

  Case 'clean tree: 0 violations' {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $assert -BaseRef $base -RepoPath $repo 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE out=$out"
    Assert-True ($out -match 'filesize: 0 violations') "summary=$out"
  }

  Case 'untracked >300-line source file is a violation' {
    $monster = Join-Path $repo 'monster.ps1'
    $lines = 1..310 | ForEach-Object { "line-$_" }
    [IO.File]::WriteAllText($monster, ($lines -join "`n") + "`n")
    # Deliberately NOT git-add'd — LESSONS 2026-07-29 blind spot.
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $assert -BaseRef $base -RepoPath $repo 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 1) "expected exit 1, got $LASTEXITCODE out=$out"
    Assert-True ($out -match 'VIOLATION') "missing VIOLATION: $out"
    Assert-True ($out -match 'monster\.ps1') "missing path: $out"
    Assert-True ($out -match 'filesize: [1-9]\d* violations') "summary=$out"
    Remove-Item -LiteralPath $monster -Force
  }

  Case 'untracked under-cap source is not a violation' {
    $small = Join-Path $repo 'small.ps1'
    [IO.File]::WriteAllText($small, "Write-Host hi`n")
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $assert -BaseRef $base -RepoPath $repo 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE out=$out"
    Assert-True ($out -match 'filesize: 0 violations') "summary=$out"
    Remove-Item -LiteralPath $small -Force
  }
}
finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "$passed passed, $failed failed"
if ($failed) { exit 1 } else { exit 0 }
