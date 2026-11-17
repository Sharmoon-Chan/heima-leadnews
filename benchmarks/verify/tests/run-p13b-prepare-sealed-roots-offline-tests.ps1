# Offline proof for the TOOL-003 fix: prepare-p13b-run.ps1 must again refuse to build inside the six
# old sealed evidence roots that had been dropped from its sealedRoots list
# (20261031-P1.3a-REVIEW, 20261031-P1.3a-ROUND4-REVIEW, 20261031-P1.3b, 20261031-P1.3b-run-r01/r02/r03).
#
# Everything happens inside a private sentinel archive root created under this run's own directory:
# the six names are simulated there, ArtifactsRoot points at that simulation, and javac is a compiled
# stand-in that appends one line to a counter file and exits with a configurable code. The real old
# roots, the real javac and any business JVM are never touched.
#
# For each simulated sealed root the expectation is: exit 2, a REFUSED message naming that root, the
# stand-in not invoked once, no run directory created, and the whole sentinel tree (paths, bytes and
# hashes) unchanged. One non-sealed control root must NOT be refused - it reaches the stand-in - so a
# blanket refusal would be visible.
#
# ASCII only. Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$FrozenReviewRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261031-P1.3a-ROUND4-REVIEW',
    [string]$HarnessSrc = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261031-P1.3b/harness/src'
)

$ErrorActionPreference = 'Stop'
$benchDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$prepare = Join-Path (Join-Path $benchDir 'env') 'prepare-p13b-run.ps1'

. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
$outDir = Join-Path (Join-Path $ExperimentRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3b-prepare-sealed-roots' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ prepare = 'prepare-p13b-run.ps1'; mode = 'offline-stand-in-javac' } -Targets @() -DataSet ''
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-56} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'FAIL' }), $d
}

# ---- the six roots that must be protected again, plus the four that were still protected
$restored = @(
    '20261031-P1.3a-REVIEW',
    '20261031-P1.3a-ROUND4-REVIEW',
    '20261031-P1.3b',
    '20261031-P1.3b-run-r01',
    '20261031-P1.3b-run-r02',
    '20261031-P1.3b-run-r03'
)
$stillProtectedControls = @('20261031-P1.3a', '20261031-P1.3b-run-r04')

# ---- private sentinel archive root (never the real one)
$sentinel = Join-Path $outDir 'sentinel'
$artifacts = Join-Path $sentinel 'artifacts'
$javaHome = Join-Path $sentinel 'java'
$counterFile = Join-Path $sentinel 'javac-standin-calls.log'
New-Item -ItemType Directory -Force -Path $artifacts, (Join-Path $javaHome 'bin') | Out-Null

# every simulated sealed root gets a marker file and a nested subdirectory, so "unchanged" is testable
foreach ($name in @($restored + $stillProtectedControls)) {
    $dir = Join-Path $artifacts $name
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'audit/deep') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'marker.txt'), "sealed marker for $name`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $dir 'audit/record.json'), "{`"root`":`"$name`",`"sealed`":true}`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $dir 'audit/deep/note.txt'), "do not write here: $name`n", $utf8)
}

# ---- javac stand-in: counts its invocations, never compiles anything
$standInSrc = Join-Path $sentinel 'JavacStandIn.cs'
[System.IO.File]::WriteAllText($standInSrc, @'
public class JavacStandIn {
    public static int Main(string[] args) {
        string counter = System.Environment.GetEnvironmentVariable("P13B_JAVAC_COUNTER");
        if (counter != null && counter.Length > 0) {
            System.IO.File.AppendAllText(counter, "called " + System.DateTime.UtcNow.ToString("o") + "\r\n");
        }
        string code = System.Environment.GetEnvironmentVariable("P13B_JAVAC_EXIT");
        if (code != null && code.Length > 0) { return int.Parse(code); }
        return 0;
    }
}
'@, $utf8)
Add-Type -Path $standInSrc -OutputAssembly (Join-Path $javaHome 'bin/javac.exe') -OutputType ConsoleApplication
Add-Check 'standin.javac_built' (Test-Path -LiteralPath (Join-Path $javaHome 'bin/javac.exe')) `
    "compiled stand-in at $javaHome\bin\javac.exe (invocations are appended to sentinel/javac-standin-calls.log)"

[System.IO.File]::WriteAllText($counterFile, '', $utf8)

function Get-CallCount { return @(Get-Content -LiteralPath $counterFile -ErrorAction SilentlyContinue).Count }

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

function Invoke-Prepare([string]$interactionRoot, [string]$childRunId) {
    $prepareArgs = @{
        RunId = $childRunId; InteractionRoot = $interactionRoot; ArtifactsRoot = $artifacts
        RepoRoot = $RepoRoot; LibDir = $LibDir; FrozenReviewRoot = $FrozenReviewRoot
        HarnessSrc = $HarnessSrc; JavaHome = $javaHome
    }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $prepare @prepareArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    return [pscustomobject]@{ code = $code; output = $out }
}

# the stand-in reads these two variables from its own process environment
$env:P13B_JAVAC_COUNTER = $counterFile
$env:P13B_JAVAC_EXIT = '0'

# ---- negative cases: one per restored sealed root, plus the two control roots that were never dropped
$rows = New-Object System.Collections.ArrayList
foreach ($name in @($restored + $stillProtectedControls)) {
    $sealedDir = Join-Path $artifacts $name
    $before = Get-TreeManifest $sealedDir
    $callsBefore = Get-CallCount
    $probeRunId = 'probe'
    $runRootWouldBe = Join-Path $sealedDir $probeRunId

    $r = Invoke-Prepare $sealedDir $probeRunId
    $callsAfter = Get-CallCount
    $after = Get-TreeManifest $sealedDir
    $created = Test-Path -LiteralPath $runRootWouldBe
    $named = $r.output -match [regex]::Escape($name)
    $refused = $r.output -match 'REFUSED: run root would be inside a sealed root'
    $ok = ($r.code -eq 2) -and $refused -and $named -and (-not $created) -and ($callsAfter -eq $callsBefore) -and ($before -eq $after)
    $first = ($r.output -split "`r?`n" | Where-Object { $_ -match 'REFUSED' } | Select-Object -First 1)
    $null = $rows.Add([ordered]@{
        case = $name; kind = $(if ($restored -contains $name) { 'restored' } else { 'still-protected-control' })
        exit_code = $r.code; refused = $refused; message_names_root = $named
        standin_calls_before = $callsBefore; standin_calls_after = $callsAfter
        run_root_created = $created; sealed_tree_unchanged = ($before -eq $after); message = "$first"
    })
    Add-Check ("prepare/$name/refused") $ok `
        "exit=$($r.code) refused=$refused names-root=$named standin_calls=$callsBefore->$callsAfter run_root_created=$created tree_unchanged=$($before -eq $after) :: $first"
}

# ---- positive control: a non-sealed interaction root must NOT be refused
$positiveRoot = Join-Path $artifacts 'not-sealed-control'
$callsBefore = Get-CallCount
$r = Invoke-Prepare $positiveRoot 'probe-ok'
$callsAfter = Get-CallCount
$notRefusedAsSealed = -not ($r.output -match 'run root would be inside a sealed root')
$created = Test-Path -LiteralPath (Join-Path $positiveRoot 'probe-ok')
$null = $rows.Add([ordered]@{
    case = 'not-sealed-control'; kind = 'positive-control'; exit_code = $r.code
    refused = (-not $notRefusedAsSealed); standin_calls_before = $callsBefore; standin_calls_after = $callsAfter
    run_root_created = $created; sealed_tree_unchanged = $true
    message = (($r.output -split "`r?`n" | Where-Object { $_ -match 'BUILD FAILED|REFUSED|run_root=' } | Select-Object -First 1))
})
Add-Check 'prepare/not-sealed-control/not-refused' ($notRefusedAsSealed -and $created -and ($callsAfter -gt $callsBefore)) `
    "exit=$($r.code) not-refused-as-sealed=$notRefusedAsSealed run_root_created=$created standin_calls=$callsBefore->$callsAfter (the stand-in ran; it compiles nothing, so the run stops at the missing-class check)"

# ---- the refusal must happen before ANY output: the sentinel root may only gain the control run
$unexpected = @(Get-ChildItem -LiteralPath $artifacts -Directory |
    Where-Object { -not (($restored -contains $_.Name) -or ($stillProtectedControls -contains $_.Name) -or ($_.Name -eq 'not-sealed-control')) } |
    ForEach-Object { $_.Name })
$noProbeDirs = @(Get-ChildItem -LiteralPath $artifacts -Directory -Filter 'probe*').Count -eq 0
Add-Check 'prepare/no_stray_output_in_sentinel' (($unexpected.Count -eq 0) -and $noProbeDirs) `
    "unexpected top-level entries: $(if ($unexpected.Count -eq 0) { 'none' } else { $unexpected -join ', ' }); probe dirs directly under the simulated archive root: $(if ($noProbeDirs) { 0 } else { 'present' })"

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    prepare_script = $prepare
    prepare_sha256 = (Get-FileHash -LiteralPath $prepare -Algorithm SHA256).Hash.ToLower()
    simulated_artifacts_root = $artifacts
    restored_roots = $restored
    still_protected_controls = $stillProtectedControls
    javac_standin = (Join-Path $javaHome 'bin/javac.exe')
    javac_standin_call_log = $counterFile
    cases = $rows
    counts = $counts
    checks = $script:run.checks
    note = 'the six restored roots and the two controls are simulated inside this run directory only; the real archive roots were never written'
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'prepare-sealed-roots-result.json') -Text ($result | ConvertTo-Json -Depth 6)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'prepare-sealed-roots-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
