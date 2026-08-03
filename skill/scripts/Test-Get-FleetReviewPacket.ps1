$ErrorActionPreference = "Stop"
$scriptPath = Join-Path $PSScriptRoot "Get-FleetReviewPacket.ps1"
$budgetScriptPath = Join-Path $PSScriptRoot "Get-FleetReviewBudget.ps1"
$manifestAssertionPath = Join-Path $PSScriptRoot "Assert-FleetReviewPacketManifest.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ("fleet-review-packet-test-" + [guid]::NewGuid().ToString("N"))

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function New-ValidPacket([string]$Directory) {
  New-Item -ItemType Directory -Force -Path $Directory | Out-Null
  [IO.File]::WriteAllText((Join-Path $Directory "base.sha"), (("a" * 40) + [Environment]::NewLine))
  [IO.File]::WriteAllText((Join-Path $Directory "final.diff"), "diff --git a/a.txt b/a.txt`n")
  [IO.File]::WriteAllText((Join-Path $Directory "touched-files.txt"), "a.txt`n")
  [IO.File]::WriteAllText((Join-Path $Directory "locked-plan.md"), "# Locked plan`n")
  [IO.File]::WriteAllText((Join-Path $Directory "acceptance-evidence.md"), "# Acceptance evidence`n")
  [IO.File]::WriteAllText((Join-Path $Directory "gate-evidence.md"), "# Gate evidence`n")
}

function Assert-Fails([string]$Directory, [string]$Message) {
  $failed = $false
  try {
    & $scriptPath -PacketDir $Directory | Out-Null
  }
  catch {
    $failed = $true
  }
  Assert-True $failed $Message
}

try {
  $valid = Join-Path $root "valid"
  New-ValidPacket $valid
  $manifest = Join-Path $valid "packet-manifest.json"
  $packet = (& $scriptPath -PacketDir $valid -OutputPath $manifest | ConvertFrom-Json)
  Assert-True ($packet.schema_version -eq "1") "schema version"
  Assert-True ($packet.review_risk -eq "mechanical") "default review_risk mechanical"
  Assert-True ($packet.artifact_paths.Count -eq 6) "required artifact count"
  Assert-True ($packet.artifact_paths[0] -like "*base.sha") "stable artifact ordering"
  Assert-True ($packet.packet_sha256 -match '^[0-9a-f]{64}$') "packet hash"
  Assert-True (Test-Path -LiteralPath $manifest -PathType Leaf) "manifest write"
  $prompt = Join-Path $root "review-prompt.md"
  [IO.File]::WriteAllText($prompt, "Review frozen packet.")
  $budget = (& $budgetScriptPath -PromptFile $prompt -ArtifactFile @($packet.artifact_paths) -PacketManifest $manifest -ReviewRisk mechanical | ConvertFrom-Json)
  Assert-True ($budget.packet_manifest_sha256 -eq $packet.packet_sha256) "budget manifest attestation"
  for ($i = 0; $i -lt $packet.artifacts.Count; $i++) {
    Assert-True ($packet.artifacts[$i].bytes -eq $budget.artifacts[$i].bytes -and $packet.artifacts[$i].sha256 -eq $budget.artifacts[$i].sha256) "packet transport hash parity for artifact $i"
  }
  $attestation = (& $manifestAssertionPath -ManifestPath $manifest -ArtifactFile @($packet.artifact_paths) | ConvertFrom-Json)
  Assert-True ($attestation.status -eq "ok" -and $attestation.packet_sha256 -eq $packet.packet_sha256) "manifest attestation"

  # A packet is only frozen if editing an artifact AFTER the freeze is detected: without
  # this, the manifest proves what the builder saw, not what the reviewer is handed.
  $tamperDir = Join-Path $root "tamper"
  New-ValidPacket $tamperDir
  $tamperManifest = Join-Path $tamperDir "packet-manifest.json"
  $tamperPacket = (& $scriptPath -PacketDir $tamperDir -OutputPath $tamperManifest | ConvertFrom-Json)
  [IO.File]::WriteAllText((Join-Path $tamperDir "final.diff"), "tampered after freeze")
  $tamperBlocked = $false
  try { & $budgetScriptPath -PromptFile $prompt -ArtifactFile @($tamperPacket.artifact_paths) -PacketManifest $tamperManifest -ReviewRisk mechanical | Out-Null }
  catch { $tamperBlocked = $true }
  Assert-True $tamperBlocked "artifact edited after freeze fails closed against the manifest"

  $collisionBlocked = $false
  try {
    & $scriptPath -PacketDir $valid -OutputPath (Join-Path $valid "final.diff") | Out-Null
  }
  catch {
    $collisionBlocked = $true
  }
  Assert-True $collisionBlocked "manifest output cannot overwrite a frozen artifact"

  [IO.File]::AppendAllText((Join-Path $valid "final.diff"), "# drift")
  $driftBlocked = $false
  try {
    & $manifestAssertionPath -ManifestPath $manifest -ArtifactFile @($packet.artifact_paths) | Out-Null
  }
  catch {
    $driftBlocked = $true
  }
  Assert-True $driftBlocked "changed review packet must stop dispatch"

  $artifactArgument = $packet.artifact_paths -join ","
  $opusWrapper = Join-Path $PSScriptRoot "Invoke-Opus48.ps1"
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $opusOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $opusWrapper -Prompt "review" -ArtifactFile $artifactArgument -PacketManifest $manifest -Mode json 2>&1
    $opusExitCode = $LASTEXITCODE
    $glmWrapper = Join-Path $PSScriptRoot "Invoke-PiGlm.ps1"
    $glmOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $glmWrapper -Prompt "review" -ArtifactFile $artifactArgument -PacketManifest $manifest -Mode json 2>&1
    $glmExitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  $opusBlocked = ($opusExitCode -ne 0 -and (($opusOutput -join "`n") -match "Frozen review packet manifest mismatch"))
  Assert-True $opusBlocked "Opus wrapper blocks a drifted packet before provider launch"

  $glmBlocked = ($glmExitCode -ne 0 -and (($glmOutput -join "`n") -match "Frozen review packet manifest mismatch"))
  Assert-True $glmBlocked "GLM wrapper blocks a drifted packet before provider launch"

  # A8: mechanical remains compatible without -ReviewRisk and without gate artifacts.
  $mechanical = Join-Path $root "mechanical-compat"
  New-ValidPacket $mechanical
  $mechManifest = Join-Path $mechanical "packet-manifest.json"
  $mechPacket = (& $scriptPath -PacketDir $mechanical -OutputPath $mechManifest | ConvertFrom-Json)
  Assert-True ($mechPacket.review_risk -eq "mechanical" -and $mechPacket.artifact_paths.Count -eq 6) "mechanical default without risk param"
  $mechAttest = (& $manifestAssertionPath -ManifestPath $mechManifest -ArtifactFile @($mechPacket.artifact_paths) | ConvertFrom-Json)
  Assert-True ($mechAttest.status -eq "ok") "mechanical re-attestation"

  # A7: behavior/hard require test-results.json + fallow-results.json; order and hash include review_risk.
  $hard = Join-Path $root "hard-packet"
  New-ValidPacket $hard
  $hardBlocked = $false
  try { & $scriptPath -PacketDir $hard -ReviewRisk hard | Out-Null } catch { $hardBlocked = $true }
  Assert-True $hardBlocked "hard packet without gate artifacts must fail"

  $testResults = @{
    schema_version = "1"
    status = "passed"
    commands = @(@{ command = "powershell -NoProfile -File scripts/Test-FleetContract.ps1"; exit_code = 0; status = "passed"; sample = "14 cases" })
  } | ConvertTo-Json -Depth 5 -Compress
  $fallowResults = @{ schema_version = "1"; status = "passed"; findings = @(); summary = @{ new_findings = 0 } } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText((Join-Path $hard "test-results.json"), $testResults + "`n")
  [IO.File]::WriteAllText((Join-Path $hard "fallow-results.json"), $fallowResults + "`n")
  [IO.File]::WriteAllText((Join-Path $hard "caller-context.md"), "# callers`n")
  $hardManifest = Join-Path $hard "packet-manifest.json"
  $hardPacket = (& $scriptPath -PacketDir $hard -ReviewRisk hard -OutputPath $hardManifest | ConvertFrom-Json)
  Assert-True ($hardPacket.review_risk -eq "hard") "hard review_risk field"
  Assert-True ($hardPacket.artifact_paths.Count -eq 9) "hard packet artifact count with caller+gates"
  $names = @($hardPacket.artifacts | ForEach-Object { $_.name })
  Assert-True ($names[0] -eq "base.sha" -and $names[6] -eq "caller-context.md" -and $names[7] -eq "test-results.json" -and $names[8] -eq "fallow-results.json") "stable artifact order"
  $hardAttest = (& $manifestAssertionPath -ManifestPath $hardManifest -ArtifactFile @($hardPacket.artifact_paths) | ConvertFrom-Json)
  Assert-True ($hardAttest.status -eq "ok" -and $hardAttest.packet_sha256 -eq $hardPacket.packet_sha256) "hard re-attestation"

  # review_risk participates in packet hash: same artifacts, different risk => different hash.
  $behaviorPacket = (& $scriptPath -PacketDir $hard -ReviewRisk behavior | ConvertFrom-Json)
  Assert-True ($behaviorPacket.packet_sha256 -ne $hardPacket.packet_sha256) "review_risk must affect packet_sha256"

  # EVIDENCE INTEGRITY: pass sample needs a nonzero digit count; digit-free prose is false green.
  foreach ($case in @(
    @{ dir = "no-sample"; entry = @{ command = "npx vitest run"; exit_code = 0; status = "passed" }; fail = $true; label = "passed command without sample must fail" },
    @{ dir = "zero-sample"; entry = @{ command = "npx vitest run"; exit_code = 0; status = "passed"; sample = "0 tests" }; fail = $true; label = "passed command with zero sample must fail" },
    @{ dir = "blank-sample"; entry = @{ command = "npx vitest run"; exit_code = 0; status = "passed"; sample = "  " }; fail = $true; label = "passed command with blank sample must fail" },
    @{ dir = "digitfree-sample"; entry = @{ command = "npx vitest run"; exit_code = 0; status = "passed"; sample = "all tests green" }; fail = $true; label = "digit-free sample must fail" },
    @{ dir = "sample-274"; entry = @{ command = "npx vitest run"; exit_code = 0; status = "passed"; sample = "274 tests" }; fail = $false; label = "sample 274 tests succeeds" },
    @{ dir = "sample-8of8"; entry = @{ command = "npx vitest run"; exit_code = 0; status = "passed"; sample = "8/8 documents" }; fail = $false; label = "sample 8/8 documents succeeds" }
  )) {
    $evDir = Join-Path $root $case.dir
    New-ValidPacket $evDir
    $ev = @{ schema_version = "1"; status = "passed"; commands = @($case.entry) } | ConvertTo-Json -Depth 5 -Compress
    [IO.File]::WriteAllText((Join-Path $evDir "test-results.json"), $ev + "`n")
    [IO.File]::WriteAllText((Join-Path $evDir "fallow-results.json"), $fallowResults + "`n")
    $evBlocked = $false
    try { & $scriptPath -PacketDir $evDir -ReviewRisk behavior | Out-Null } catch { $evBlocked = $true }
    if ($case.fail) { Assert-True $evBlocked $case.label }
    else { Assert-True (-not $evBlocked) $case.label }
  }

  # A failed command needs no sample (nothing to prove about a failure).
  $failDir = Join-Path $root "failed-no-sample"
  New-ValidPacket $failDir
  $failEv = @{ schema_version = "1"; status = "failed"; commands = @(@{ command = "npx vitest run"; exit_code = 1; status = "failed" }) } | ConvertTo-Json -Depth 5 -Compress
  [IO.File]::WriteAllText((Join-Path $failDir "test-results.json"), $failEv + "`n")
  [IO.File]::WriteAllText((Join-Path $failDir "fallow-results.json"), $fallowResults + "`n")
  Assert-True ((& $scriptPath -PacketDir $failDir -ReviewRisk behavior | ConvertFrom-Json).review_risk -eq "behavior") "failed command without sample stays valid"

  # Fallow not_measured: explicit skip with reason; no new_findings claim.
  $goodTests = @{ schema_version = "1"; status = "passed"; commands = @(@{ command = "npx vitest run"; exit_code = 0; status = "passed"; sample = "274 tests" }) } | ConvertTo-Json -Depth 5 -Compress
  $nmOk = Join-Path $root "fallow-not-measured"
  New-ValidPacket $nmOk
  [IO.File]::WriteAllText((Join-Path $nmOk "test-results.json"), $goodTests + "`n")
  [IO.File]::WriteAllText((Join-Path $nmOk "fallow-results.json"), (@{ schema_version = "1"; status = "not_measured"; reason = "Fallow targets JS/TS; this repo is PowerShell" } | ConvertTo-Json -Compress) + "`n")
  Assert-True ((& $scriptPath -PacketDir $nmOk -ReviewRisk hard | ConvertFrom-Json).review_risk -eq "hard") "fallow not_measured with reason succeeds"
  foreach ($case in @(
    @{ dir = "fallow-nm-no-reason"; body = @{ schema_version = "1"; status = "not_measured" }; label = "not_measured missing reason must fail" },
    @{ dir = "fallow-nm-empty-reason"; body = @{ schema_version = "1"; status = "not_measured"; reason = "  " }; label = "not_measured empty reason must fail" },
    @{ dir = "fallow-nm-zero-findings"; body = @{ schema_version = "1"; status = "not_measured"; reason = "Fallow targets JS/TS; this repo is PowerShell"; new_findings = 0 }; label = "not_measured with new_findings 0 must fail" }
  )) {
    $fDir = Join-Path $root $case.dir
    New-ValidPacket $fDir
    [IO.File]::WriteAllText((Join-Path $fDir "test-results.json"), $goodTests + "`n")
    [IO.File]::WriteAllText((Join-Path $fDir "fallow-results.json"), (($case.body | ConvertTo-Json -Compress) + "`n"))
    $fBlocked = $false
    try { & $scriptPath -PacketDir $fDir -ReviewRisk hard | Out-Null } catch { $fBlocked = $true }
    Assert-True $fBlocked $case.label
  }

  # Fallow allowlist: native audit + legacy fleet pass; junk / contradictory shapes fail.
  foreach ($case in @(
    @{ dir = "fallow-native-pass"; body = @{ schema_version = 7; kind = "audit"; verdict = "pass"; summary = @{ dead_code_issues = 0; complexity_findings = 0; duplication_clone_groups = 0 } }; fail = $false; label = "fallow native audit pass succeeds" },
    @{ dir = "fallow-native-fail"; body = @{ schema_version = 7; kind = "audit"; verdict = "fail"; summary = @{ dead_code_issues = 2; complexity_findings = 1; duplication_clone_groups = 0 } }; fail = $false; label = "fallow native audit fail with counters succeeds" },
    @{ dir = "fallow-native-pass-nonzero"; body = @{ schema_version = 7; kind = "audit"; verdict = "pass"; summary = @{ dead_code_issues = 1; complexity_findings = 0; duplication_clone_groups = 0 } }; fail = $true; label = "fallow native pass with nonzero counter must fail" },
    @{ dir = "fallow-legacy-pass"; body = @{ schema_version = "1"; status = "passed"; findings = @(); summary = @{ new_findings = 0 } }; fail = $false; label = "fallow legacy measured passed empty findings succeeds" },
    @{ dir = "fallow-legacy-fail"; body = @{ schema_version = "1"; status = "failed"; findings = @(@{ rule = "dead-code"; path = "a.ts" }); summary = @{ new_findings = 1 } }; fail = $false; label = "fallow legacy measured failed with findings succeeds" },
    @{ dir = "fallow-ok-true"; body = @{ ok = $true }; fail = $true; label = "fallow {ok:true} must fail" },
    @{ dir = "fallow-garbage"; body = @{ garbage = @(1, 2, 3) }; fail = $true; label = "fallow {garbage:[...]} must fail" },
    @{ dir = "fallow-empty-obj"; bodyJson = "{}"; fail = $true; label = "fallow {} must fail" },
    @{ dir = "fallow-no-status"; body = @{ schema_version = "1" }; fail = $true; label = "fallow missing status must fail" },
    @{ dir = "fallow-top-new-findings"; body = @{ status = "passed"; new_findings = 0 }; fail = $true; label = "fallow top-level new_findings must fail" },
    @{ dir = "fallow-passed-nonzero"; body = @{ schema_version = "1"; status = "passed"; findings = @(); summary = @{ new_findings = 3 } }; fail = $true; label = "fallow passed with new_findings>0 must fail" },
    @{ dir = "fallow-failed-zero"; body = @{ schema_version = "1"; status = "failed"; findings = @(); summary = @{ new_findings = 0 } }; fail = $true; label = "fallow failed with new_findings=0 must fail" }
  )) {
    $fDir = Join-Path $root $case.dir
    New-ValidPacket $fDir
    [IO.File]::WriteAllText((Join-Path $fDir "test-results.json"), $goodTests + "`n")
    if ($case.bodyJson) {
      [IO.File]::WriteAllText((Join-Path $fDir "fallow-results.json"), ($case.bodyJson + "`n"))
    } else {
      [IO.File]::WriteAllText((Join-Path $fDir "fallow-results.json"), (($case.body | ConvertTo-Json -Depth 5 -Compress) + "`n"))
    }
    $fBlocked = $false
    try { & $scriptPath -PacketDir $fDir -ReviewRisk hard | Out-Null } catch { $fBlocked = $true }
    if ($case.fail) { Assert-True $fBlocked $case.label }
    else { Assert-True (-not $fBlocked) $case.label }
  }

  # invalid test-results.json fails closed
  $badTests = Join-Path $root "bad-tests"
  New-ValidPacket $badTests
  [IO.File]::WriteAllText((Join-Path $badTests "test-results.json"), "{`"not`":`"schema`"}`n")
  [IO.File]::WriteAllText((Join-Path $badTests "fallow-results.json"), "{`"ok`":true}`n")
  $badBlocked = $false
  try { & $scriptPath -PacketDir $badTests -ReviewRisk behavior | Out-Null } catch { $badBlocked = $true }
  Assert-True $badBlocked "invalid test-results schema must fail"

  # True pre-D4 legacy fixture: no review_risk field, hash without review_risk| prefix.
  $legacy = Join-Path $root "legacy-manifest"
  New-ValidPacket $legacy
  $legacyPacket = (& $scriptPath -PacketDir $legacy | ConvertFrom-Json)
  $utf8Legacy = [Text.UTF8Encoding]::new($false)
  $legacyMaterial = (($legacyPacket.artifacts | ForEach-Object { "$($_.name)|$($_.bytes)|$($_.sha256)" }) -join "`n")
  $shaLegacy = [Security.Cryptography.SHA256]::Create()
  try {
    $legacyHash = -join ($shaLegacy.ComputeHash($utf8Legacy.GetBytes($legacyMaterial)) | ForEach-Object { $_.ToString("x2") })
  }
  finally {
    $shaLegacy.Dispose()
  }
  Assert-True ($legacyHash -ne $legacyPacket.packet_sha256) "legacy hash must differ from review_risk-prefixed hash"
  $legacyManifestPath = Join-Path $legacy "packet-manifest.json"
  $legacyOrdered = [ordered]@{
    schema_version = "1"
    packet_dir = $legacyPacket.packet_dir
    artifact_paths = @($legacyPacket.artifact_paths)
    artifacts = @($legacyPacket.artifacts)
    packet_sha256 = $legacyHash
  }
  $legacyJson = ($legacyOrdered | ConvertTo-Json -Depth 5 -Compress)
  [IO.File]::WriteAllText($legacyManifestPath, $legacyJson + "`n")
  $legacyAttest = (& $manifestAssertionPath -ManifestPath $legacyManifestPath -ArtifactFile @($legacyPacket.artifact_paths) | ConvertFrom-Json)
  Assert-True ($legacyAttest.status -eq "ok" -and $legacyAttest.packet_sha256 -eq $legacyHash) "true pre-D4 legacy manifest re-attests clean"

  # Present empty/whitespace machine gate artifacts fail at mechanical risk (D4).
  $mechEmpty = Join-Path $root "mechanical-empty-tests"
  New-ValidPacket $mechEmpty
  [IO.File]::WriteAllText((Join-Path $mechEmpty "test-results.json"), "")
  Assert-Fails $mechEmpty "present empty test-results.json must fail for mechanical"

  $mechWs = Join-Path $root "mechanical-ws-fallow"
  New-ValidPacket $mechWs
  [IO.File]::WriteAllText((Join-Path $mechWs "fallow-results.json"), "   `n")
  Assert-Fails $mechWs "present whitespace fallow-results.json must fail for mechanical"

  $mechInvalid = Join-Path $root "mechanical-invalid-tests"
  New-ValidPacket $mechInvalid
  [IO.File]::WriteAllText((Join-Path $mechInvalid "test-results.json"), "not-json`n")
  Assert-Fails $mechInvalid "present invalid test-results.json must fail for mechanical"

  $missing = Join-Path $root "missing"
  New-ValidPacket $missing
  Remove-Item -LiteralPath (Join-Path $missing "acceptance-evidence.md") -Force
  Assert-Fails $missing "missing evidence must stop dispatch"

  $empty = Join-Path $root "empty"
  New-ValidPacket $empty
  [IO.File]::WriteAllText((Join-Path $empty "locked-plan.md"), "")
  Assert-Fails $empty "empty locked plan must stop dispatch"

  $invalidSha = Join-Path $root "invalid-sha"
  New-ValidPacket $invalidSha
  [IO.File]::WriteAllText((Join-Path $invalidSha "base.sha"), "not-a-git-id")
  Assert-Fails $invalidSha "invalid base SHA must stop dispatch"

  # PLAN SCOPE: name-status STATUS\tpath; bare=basename; /=\.
  $tab = [string][char]9; $bs = [string][char]92; $ns = "M${tab}scripts/Invoke-Grok45.ps1`n"
  foreach ($case in @(
    @{ d = "sc-miss"; p = "# Plan`nAttack " + '`Missing-Thing.ps1`'; t = $ns; f = $true; n = "Missing-Thing.ps1"; l = "bare Missing-Thing.ps1 absent fails" },
    @{ d = "sc-bare"; p = "# Plan`nAttack " + '`Invoke-Grok45.ps1`'; t = $ns; f = $false; n = $null; l = "bare Invoke-Grok45.ps1 name-status succeeds" },
    @{ d = "sc-slash"; p = "# Plan`nAttack " + '`scripts/Invoke-Grok45.ps1`'; t = $ns; f = $false; n = $null; l = "qualified slash name-status succeeds" },
    @{ d = "sc-bs"; p = "# Plan`nAttack " + ('`scripts' + $bs + 'Invoke-Grok45.ps1`'); t = $ns; f = $false; n = $null; l = "qualified backslash name-status succeeds" },
    @{ d = "sc-abs"; p = "# Plan`nAttack " + '`scripts/Absent.ps1`'; t = $ns; f = $true; n = "scripts/Absent.ps1"; l = "qualified Absent.ps1 fails" },
    @{ d = "sc-bare-abs"; p = "# Plan`nAttack " + '`Absent.ps1`'; t = $ns; f = $true; n = "Absent.ps1"; l = "bare Absent.ps1 fails" },
    @{ d = "sc-ren"; p = "# Plan`nAttack " + '`scripts/New.ps1`'; t = "R100${tab}scripts/Old.ps1${tab}scripts/New.ps1`n"; f = $false; n = $null; l = "rename target New.ps1 succeeds" },
    @{ d = "sc-plain"; p = "# Plan`nAttack " + '`scripts/Invoke-Grok45.ps1`'; t = "scripts/Invoke-Grok45.ps1`n"; f = $false; n = $null; l = "plain list full path succeeds" },
    @{ d = "sc-prose"; p = "# Plan`nFlags " + '`not_measured`' + " and " + '`-ExpectLane`'; t = $ns; f = $false; n = $null; l = "non-file backticks ignored" },
    @{ d = "sc-none"; p = "# Plan`nNo file claims here."; t = $ns; f = $false; n = $null; l = "plan with no file claims succeeds" }
  )) {
    $sDir = Join-Path $root $case.d; New-ValidPacket $sDir
    [IO.File]::WriteAllText((Join-Path $sDir "touched-files.txt"), $case.t)
    [IO.File]::WriteAllText((Join-Path $sDir "locked-plan.md"), $case.p + "`n")
    $err = $null; try { & $scriptPath -PacketDir $sDir | Out-Null } catch { $err = $_.Exception.Message }
    if ($case.f) { Assert-True ($null -ne $err) $case.l; Assert-True ($err -like "*$($case.n)*") ($case.l + " names missing") }
    else { Assert-True ($null -eq $err) ($case.l + $(if ($err) { ": $err" } else { "" })) }
  }

  Write-Output "PASS Test-Get-FleetReviewPacket"
}
finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

exit 0
