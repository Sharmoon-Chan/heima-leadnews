# Offline proof for the TOOL-010 fix: the round-2 baseline-gate driver must be evidence itself.
#
# Before the fix that driver created its output directory with -Force, deleted any existing case /
# probe directory with Remove-Item -Recurse -Force and rewrote its summary with WriteAllText, so a
# second call with the SAME run id deleted the old sentinel and changed the result hash. This test
# drives the real script three times:
#
#   1. a brand-new run id            -> must pass (the eight-case matrix is unchanged)
#   2. the SAME run id again         -> must be refused before anything happens: non-zero exit, no
#                                       child script invoked, no directory created or deleted, and
#                                       the whole first-run tree (every child case directory, the
#                                       summary and a sentinel file placed inside it) byte-identical
#   3. a different brand-new run id  -> must pass again, so the refusal is about reuse and not about
#                                       a blanket refusal
#
# Everything stays inside this run's own directory; the real archive roots are never touched and no
# business or cost scenario is re-run.
#
# ASCII only. Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$BaselineFile,
    [Parameter(Mandatory = $true)][string]$BaselineSha256,
    [string]$ChildRunIdFirst = 'gate-probe-a',
    [string]$ChildRunIdSecond = 'gate-probe-b'
)

$ErrorActionPreference = 'Stop'
$benchDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$gateDriver = Join-Path $PSScriptRoot 'run-p13b-round2-baseline-gate-offline-tests.ps1'

. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
$outDir = Join-Path (Join-Path $ExperimentRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3b-gate-wrapper-guard' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ gate_driver = 'run-p13b-round2-baseline-gate-offline-tests.ps1'; mode = 'offline' } -Targets @() -DataSet ''
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-52} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'FAIL' }), $d
}
function Get-TreeManifest([string]$root) {
    $items = New-Object System.Collections.ArrayList
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Recurse -Directory | Sort-Object FullName)) {
        $null = $items.Add("dir`t" + $d.FullName.Substring($root.Length + 1).Replace('\', '/'))
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)) {
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        $null = $items.Add("file`t" + $f.FullName.Substring($root.Length + 1).Replace('\', '/') + "`t$($f.Length)`t$h")
    }
    return ($items -join "`n")
}
function Invoke-Gate([string]$probeRoot, [string]$childRunId) {
    $gateArgs = @{
        ExperimentRoot = $probeRoot; RunId = $childRunId
        BaselineFile = $BaselineFile; BaselineSha256 = $BaselineSha256
    }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # children write their own diagnostics to stderr
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $gateDriver @gateArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    return [pscustomobject]@{ code = $code; output = $out }
}

# the probe root and its child run dirs live inside this run, never in a real archive root
$probeRoot = Join-Path $outDir 'probe-root'
New-Item -ItemType Directory -Path $probeRoot | Out-Null

# ---------------------------------------------------------------- 1. brand-new run id must pass
$first = Invoke-Gate $probeRoot $ChildRunIdFirst
$firstDir = Join-Path (Join-Path $probeRoot 'runs') $ChildRunIdFirst
$firstStatus = Join-Path $firstDir 'run-status.json'
$firstOk = ($first.code -eq 0) -and (Test-Path -LiteralPath $firstStatus)
$firstChecks = 0
$firstPassed = 0
if ($firstOk) {
    $j = Get-Content -LiteralPath $firstStatus -Raw | ConvertFrom-Json
    $firstChecks = @($j.checks).Count
    $firstPassed = @($j.checks | Where-Object { $_.status -eq 'pass' }).Count
    $firstOk = ($j.status -eq 'passed') -and ($firstPassed -eq 8) -and ($firstChecks -eq 8)
}
Add-Check 'gate.first_run_passes_unchanged_matrix' $firstOk `
    "exit=$($first.code) status_file=$(Test-Path -LiteralPath $firstStatus) checks=$firstPassed/$firstChecks (the six refusal cases and the two valid-baseline cases)"

# a sentinel inside the first-run tree: a reused run id must not delete or overwrite it
$sentinel = Join-Path $firstDir 'sentinel-do-not-delete.txt'
[System.IO.File]::WriteAllText($sentinel, "sentinel for $ChildRunIdFirst`n", $utf8)
$resultFile = Join-Path $firstDir 'gate-result.json'
$resultHashBefore = (Get-FileHash -LiteralPath $resultFile -Algorithm SHA256).Hash.ToLower()
$treeBefore = Get-TreeManifest $firstDir
$caseDirsBefore = @(Get-ChildItem -LiteralPath (Join-Path $firstDir 'cases') -Directory | ForEach-Object { $_.Name } | Sort-Object)

# ---------------------------------------------------------------- 2. same run id must be refused
$second = Invoke-Gate $probeRoot $ChildRunIdFirst
$treeAfter = Get-TreeManifest $firstDir
$resultHashAfter = (Get-FileHash -LiteralPath $resultFile -Algorithm SHA256).Hash.ToLower()
$caseDirsAfter = @(Get-ChildItem -LiteralPath (Join-Path $firstDir 'cases') -Directory | ForEach-Object { $_.Name } | Sort-Object)
$sentinelIntact = (Test-Path -LiteralPath $sentinel) -and ((Get-Content -LiteralPath $sentinel -Raw).Trim() -eq "sentinel for $ChildRunIdFirst")
$refusedMessage = [bool]($second.output -match 'REFUSED')
$refusedByGuard = [bool]($second.output -match 'refusing to reuse existing output directory')
$noNewCaseDirs = (($caseDirsBefore -join '|') -eq ($caseDirsAfter -join '|'))
$dupOk = ($second.code -eq 2) -and $refusedMessage -and $refusedByGuard -and $sentinelIntact -and
         ($resultHashBefore -eq $resultHashAfter) -and ($treeBefore -eq $treeAfter) -and $noNewCaseDirs
$dupFirst = ($second.output -split "`r?`n" | Where-Object { $_ -match 'REFUSED' } | Select-Object -First 1)
Add-Check 'gate.same_run_id_refused' (($second.code -eq 2) -and $refusedMessage -and $refusedByGuard) `
    "exit=$($second.code) refused=$refusedMessage refuses_reuse=$refusedByGuard :: $dupFirst"
Add-Check 'gate.existing_tree_and_sentinel_untouched' ($sentinelIntact -and ($treeBefore -eq $treeAfter)) `
    "sentinel intact=$sentinelIntact whole-tree identical=$($treeBefore -eq $treeAfter) (paths/bytes/sha256 of every child case file)"
Add-Check 'gate.summary_not_rewritten' (($resultHashBefore -eq $resultHashAfter) -and $noNewCaseDirs) `
    "gate-result.json sha before=$($resultHashBefore.Substring(0, 12)) after=$($resultHashAfter.Substring(0, 12)); child case dirs before=$($caseDirsBefore -join ',') after=$($caseDirsAfter -join ',')"
Add-Check 'gate.no_child_invocation_on_refusal' (@(Get-ChildItem -LiteralPath $firstDir -Recurse -File).Count -eq @($treeBefore -split "`n" | Where-Object { $_ -like 'file*' }).Count) `
    "file count after the refused call equals the manifest it was compared against ($(@($treeBefore -split "`n" | Where-Object { $_ -like 'file*' }).Count) files) - no child script ran, so nothing was created or deleted"

# ---------------------------------------------------------------- 3. a different new run id must pass
$third = Invoke-Gate $probeRoot $ChildRunIdSecond
$secondDir = Join-Path (Join-Path $probeRoot 'runs') $ChildRunIdSecond
$secondStatus = Join-Path $secondDir 'run-status.json'
$thirdOk = ($third.code -eq 0) -and (Test-Path -LiteralPath $secondStatus)
$thirdPassed = 0
$thirdChecks = 0
if ($thirdOk) {
    $j2 = Get-Content -LiteralPath $secondStatus -Raw | ConvertFrom-Json
    $thirdChecks = @($j2.checks).Count
    $thirdPassed = @($j2.checks | Where-Object { $_.status -eq 'pass' }).Count
    $thirdOk = ($j2.status -eq 'passed') -and ($thirdPassed -eq 8) -and ($thirdChecks -eq 8)
}
Add-Check 'gate.new_run_id_after_refusal_passes' $thirdOk `
    "exit=$($third.code) checks=$thirdPassed/$thirdChecks (a new run id still produces the full matrix; the refusal is about reuse only)"
Add-Check 'gate.first_run_still_intact_after_second_success' ((Get-TreeManifest $firstDir) -eq $treeBefore) `
    "the first run's tree is still byte-identical after the third call"

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    gate_driver = $gateDriver
    gate_driver_sha256 = (Get-FileHash -LiteralPath $gateDriver -Algorithm SHA256).Hash.ToLower()
    probe_root = $probeRoot
    child_run_ids = @($ChildRunIdFirst, $ChildRunIdSecond)
    first_run = [ordered]@{ exit_code = $first.code; checks_passed = $firstPassed; checks_total = $firstChecks
                            gate_result_sha256 = $resultHashBefore; case_dirs = $caseDirsBefore }
    duplicate_run = [ordered]@{ exit_code = $second.code; message = "$dupFirst"; tree_unchanged = ($treeBefore -eq $treeAfter)
                                sentinel_intact = $sentinelIntact; summary_sha256_after = $resultHashAfter }
    third_run = [ordered]@{ exit_code = $third.code; checks_passed = $thirdPassed; checks_total = $thirdChecks }
    counts = $counts
    checks = $script:run.checks
    note = 'the three calls are the real driver; every byte they write stays under this run directory'
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'gate-wrapper-guard-result.json') -Text ($result | ConvertTo-Json -Depth 6)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'gate-wrapper-guard-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
