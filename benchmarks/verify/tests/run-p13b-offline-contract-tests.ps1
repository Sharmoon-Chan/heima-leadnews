# Offline contract tests for the A-D rework (ASCII only).
#
# Two Java checks, both compiled against and run with the POST variant directory that the instances
# actually load, so the subject under test is the delivered class and not a re-implementation:
#   B: P13bZeroRowContract  - DAO returns false -> no static_url.updated, no invalidation; true -> both
#   D: P13bIdFixtureOffline - marked article gets the fixed id, plain article and config/content do not
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = setup/usage problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$JavaHome = 'D:\Soft\Java\jdk-1.8',
    [long]$FixedId = 9007199254741019,
    [string]$MarkerTitle = 'P13b-created'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.3b-offline-contract' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ run_root = $RunRoot; fixed_id = $FixedId; marker = $MarkerTitle } `
        -Targets @("$FixedId") -DataSet '(none)'
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
}

$variant = Join-Path $RunRoot 'build/run-classes-POST'
$templateDir = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/resources/templates'
foreach ($p in @($variant, $templateDir)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "REFUSED: missing input: $p"; exit 2 }
}
$javac = Join-Path $JavaHome 'bin\javac.exe'
$java = Join-Path $JavaHome 'bin\java.exe'
foreach ($p in @($javac, $java)) { if (-not (Test-Path -LiteralPath $p)) { Write-Host "REFUSED: missing $p"; exit 2 } }

$classesDir = Join-Path $OutDir 'classes'
New-Item -ItemType Directory -Force -Path $classesDir | Out-Null
$cp = (@(
        $variant,
        (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-common/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-model/target/classes'),
        "$LibDir\*"
    ) -join ';')

$sources = @(
    (Join-Path $PSScriptRoot 'P13bZeroRowContract.java'),
    (Join-Path $PSScriptRoot 'P13bIdFixtureOffline.java')
)
foreach ($s in $sources) { if (-not (Test-Path -LiteralPath $s)) { Write-Host "REFUSED: missing $s"; exit 2 } }

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$compileLog = & $javac '-encoding' 'UTF-8' '-nowarn' '-cp' $cp '-d' $classesDir $sources 2>&1
$compileCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'compile.log') -Text ((@($compileLog) -join "`r`n"))
Add-Check 'offline.compile' ($compileCode -eq 0) "javac exit=$compileCode sources=2 output=$((@($compileLog) -join ' ').Trim())"
if ($compileCode -ne 0) {
    $counts = Get-RunCheckCounts $script:run
    $script:run.checks | ForEach-Object { "{0,-42} {1,-6} {2}" -f $_.check, $_.status, $_.detail }
    exit (Set-RunStatus -State $script:run -Status 'failed')
}

$runCp = "$classesDir;$cp"

# ---- B: zero-row vs success contract on the delivered POST class ----
$bOut = Join-Path $OutDir 'B-zero-row.txt'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$bLog = & $java '-Dfile.encoding=UTF-8' '-cp' $runCp 'P13bZeroRowContract' $templateDir $bOut 2>&1
$bCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'B-zero-row.console.txt') -Text ((@($bLog) -join "`r`n"))
$bLines = if (Test-Path $bOut) { @(Get-Content -LiteralPath $bOut) } else { @() }
foreach ($line in $bLines) {
    $p = $line -split '\|', 3
    if ($p.Count -eq 3) { Add-Check $p[0] ($p[1] -eq 'PASS') $p[2] }
}
Add-Check 'offline.B_process_exit' ($bCode -eq 0) "java exit=$bCode lines=$($bLines.Count)"

# ---- D: ID fixture scope on the delivered harness class ----
$dOut = Join-Path $OutDir 'D-id-fixture.txt'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$dLog = & $java '-Dfile.encoding=UTF-8' '-cp' $runCp 'P13bIdFixtureOffline' "$FixedId" $MarkerTitle $dOut 2>&1
$dCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'D-id-fixture.console.txt') -Text ((@($dLog) -join "`r`n"))
$dLines = if (Test-Path $dOut) { @(Get-Content -LiteralPath $dOut) } else { @() }
foreach ($line in $dLines) {
    $p = $line -split '\|', 3
    if ($p.Count -eq 3) { Add-Check $p[0] ($p[1] -eq 'PASS') $p[2] }
}
Add-Check 'offline.D_process_exit' ($dCode -eq 0) "java exit=$dCode lines=$($dLines.Count)"

$summary = [ordered]@{
    run_id = $RunId
    variant_classes = $variant
    variant_class_sha256 = [ordered]@{
        ap_article_service = (Get-FileHash (Join-Path $variant 'com/heima/article/service/impl/ApArticleServiceImpl.class') -Algorithm SHA256).Hash.ToLower()
        freemarker = (Get-FileHash (Join-Path $variant 'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class') -Algorithm SHA256).Hash.ToLower()
        harness_config = (Get-FileHash (Join-Path $variant 'com/heima/article/p13b/P13bHarnessConfig.class') -Algorithm SHA256).Hash.ToLower()
    }
    template_dir = $templateDir
    b_lines = $bLines
    d_lines = $dLines
    finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'offline-contract-results.json') -Text ($summary | ConvertTo-Json -Depth 6)

$counts = Get-RunCheckCounts $script:run
$script:run.checks | ForEach-Object { "{0,-42} {1,-6} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
