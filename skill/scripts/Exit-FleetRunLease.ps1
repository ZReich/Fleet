param([Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9._-]+$')][string]$RunId)

$ErrorActionPreference = 'Stop'
$path = "$env:USERPROFILE\.codex\fleet\run-leases\$RunId.json"
if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
