# Offline proof of the round-2 baseline gate: both round-2 scripts must REFUSE (exit 2) before any
# database, Redis or HTTP work when the shared baseline is missing, has a different hash, or is not a
# round-2 baseline.
#
# Every case is run with -MysqlExe / -RedisCli pointing at a path that does not exist: if the gate ever
# let execution continue, the script would either fail with a different exit code or invoke a client.
# The experiment root is snapshotted before and after, so a refusal that still created run output is
# visible as a failure.
#
# TOOL-010 fix (2026-11-03): the parent driver itself is now evidence. It calls the shared
# RunDirGuard BEFORE creating any directory, copying any input, deleting anything, writing any
# summary or invoking any child script, so a second run with the same -RunId is refused (exit 2)
# and the first run's tree - including every child case directory and any sentinel placed inside
# it - stays byte-identical. The old "delete the previous case directory and reuse it" branch is
# gone: a failed attempt keeps its files and must use a new -RunId.
#
# ASCII only. Exit codes: 0 = all cases behaved as expected, 1 = a case failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$BaselineFile,
    [Parameter(Mandatory = $true)][string]$BaselineSha256,
    [string[]]$Scripts = @('p1-3b-round2.ps1', 'p1-3b-round2-cost.ps1')
)

$ErrorActionPreference = 'Stop'
$verifyDir = $PSScriptRoot
$benchDir = Split-Path -Parent (Split-Path -Parent $verifyDir)
$tab = [char]9

# ---- guard first: no directory, copy, delete, summary or child call may happen before this ----
. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
$outDir = Join-Path (Join-Path $ExperimentRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3b-round2-baseline-gate' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ baseline_sha256 = $BaselineSha256; scripts = ($Scripts -join ','); mode = 'offline' } `
        -Targets @() -DataSet ''
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$caseRoot = Join-Path $outDir 'cases'
New-Item -ItemType Directory -Path $caseRoot | Out-Null
# a client binary that cannot exist: the gate must exit before anything tries to run it
$deadPath = Join-Path $outDir 'no-such-client.exe'

function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-52} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'FAIL' }), $d
}

function Get-RootFingerprint {
    $items = @(Get-ChildItem -LiteralPath $ExperimentRoot -Directory |
        ForEach-Object { $_.Name } | Sort-Object)
    return ($items -join '|')
}

# ---- case inputs: a tampered copy (different hash) and a wrong-scope copy of the shared baseline
$tmp = Join-Path $outDir 'tmp-baselines'
New-Item -ItemType Directory -Path $tmp | Out-Null
$tampered = Join-Path $tmp 'tampered.json'
$wrongScope = Join-Path $tmp 'wrong-scope.json'
$raw = [System.IO.File]::ReadAllText($BaselineFile)
[System.IO.File]::WriteAllText($tampered, ($raw -replace '"captured_local"', '"captured_local_tampered"'), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($wrongScope, ($raw -replace 'P1\.3b-round2', 'P1.3b-round1'), (New-Object System.Text.UTF8Encoding($false)))
$tamperedSha = (Get-FileHash -LiteralPath $tampered -Algorithm SHA256).Hash.ToLower()
$wrongScopeSha = (Get-FileHash -LiteralPath $wrongScope -Algorithm SHA256).Hash.ToLower()

$cases = @(
    [ordered]@{ name = 'missing-baseline'; file = (Join-Path $tmp 'does-not-exist.json'); sha = $BaselineSha256 },
    [ordered]@{ name = 'hash-mismatch'; file = $tampered; sha = $BaselineSha256 },
    [ordered]@{ name = 'not-round2-scope'; file = $wrongScope; sha = $wrongScopeSha }
)

$rows = New-Object System.Collections.ArrayList
$rootBefore = Get-RootFingerprint
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'   # children write their own diagnostics to stderr
foreach ($script in $Scripts) {
    $scriptPath = Join-Path (Join-Path $benchDir 'verify') $script
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "script not found: $scriptPath" }
    foreach ($case in $cases) {
        # the run guard requires the last path segment to equal the run id; nothing is ever deleted:
        # this run id is new, so every case directory below is new by construction
        $caseId = "$RunId-$($case.name)"
        $caseOut = Join-Path $caseRoot $caseId
        $common = @{
            OutDir = $caseOut; RunId = $caseId; Base = 'http://127.0.0.1:1'
            Events = (Join-Path $outDir 'unused-events.log'); Variant = 'PRE'; ExperimentRoot = $ExperimentRoot
            BaselineFile = $case.file; BaselineSha256 = $case.sha; MysqlExe = $deadPath; RedisCli = $deadPath
        }
        if ($script -eq 'p1-3b-round2.ps1') { $common['Scenario'] = 'B' }
        $startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @common 2>&1 | Out-String
        $code = $LASTEXITCODE
        $elapsed = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $startMs
        $madeOutput = Test-Path -LiteralPath $caseOut
        $refused = [bool]($out -match 'REFUSED:')
        $ok = ($code -eq 2) -and $refused -and (-not $madeOutput)
        $first = ($out -split "`r?`n" | Where-Object { $_ -match 'REFUSED' } | Select-Object -First 1)
        $null = $rows.Add([ordered]@{ script = $script; case = $case.name; exit_code = $code; refused_message = $refused
                                      run_output_created = $madeOutput; elapsed_ms = $elapsed; message = "$first" })
        Add-Check ("$script/$($case.name)") $ok "exit=$code refused=$refused run_output_created=$madeOutput elapsed=${elapsed}ms :: $first"
    }
}

# ---- a valid baseline must NOT be refused (the gate has to pass for the real runs)
$probeId = "$RunId-valid-probe"
$probeOut = Join-Path $caseRoot $probeId
$probeArgs = @{ OutDir = $probeOut; RunId = $probeId; Base = 'http://127.0.0.1:1'
                Events = (Join-Path $outDir 'unused-events.log'); Variant = 'PRE'; ExperimentRoot = $ExperimentRoot
                BaselineFile = $BaselineFile; BaselineSha256 = $BaselineSha256; Scenario = 'B'
                MysqlExe = $deadPath; RedisCli = $deadPath }
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $benchDir 'verify') 'p1-3b-round2.ps1') @probeArgs 2>&1 | Out-String
$code = $LASTEXITCODE
$ErrorActionPreference = $savedEap
$notRefused = -not ($out -match 'REFUSED: baseline')
Add-Check 'p1-3b-round2.ps1/valid-baseline-passes-gate' ($code -ne 2 -and $notRefused) `
    "exit=$code (1 = later failure with a dead DB client, 2 would mean a wrong refusal); the gate itself did not refuse"

$rootAfter = Get-RootFingerprint
Add-Check 'experiment-root-unchanged-outside-this-run' ($rootBefore -eq $rootAfter) `
    "top-level directories before/after identical=$($rootBefore -eq $rootAfter) (this run's own directory is the only addition)"

# ---- summaries: written exactly once by the guard helper (never overwritten)
$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    experiment_root = $ExperimentRoot
    baseline_file = $BaselineFile
    baseline_sha256 = $BaselineSha256
    scripts = $Scripts
    dead_client_path = $deadPath
    case_root = 'cases/'
    cases = $rows
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'gate-result.json') -Text ($result | ConvertTo-Json -Depth 6)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'gate-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
