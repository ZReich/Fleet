#requires -Version 5
# Runs the scrub/gate/routing self-checks in Publish-Public.ps1 (no git, no network).
# Discovered and run by Test-FleetAll.ps1.
& (Join-Path $PSScriptRoot 'Publish-Public.ps1') -SelfTest
exit $LASTEXITCODE
