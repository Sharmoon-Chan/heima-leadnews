# Capture the SINGLE identity baseline of a P1.4a run root (ASCII only).
#
# One protected capture, written once to inputs/p14a-baseline.json, that pins:
#   * the git HEAD, the tracked patch size and the number of dirty status entries,
#   * the hash of every tool that can produce or consume evidence in this card,
#   * the production sources and the frozen classes actually loaded by A and B,
#   * the library directory and its jar count,
#   * the truth file and every request plan (once p14a-plan.ps1 has frozen them),
#   * the JVM executable used by the single launcher.
#
# baseline_id is the SHA256 of the canonical key=value payload below, so any later run can be compared by identity
# instead of by a self-declared "nothing changed" sentence.
#
# Exit codes: 0 = captured, 2 = refused (root not active / baseline already exists), 1 = capture failed.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$JavaExe = 'D:\Soft\Java\jdk-1.8\bin\java.exe',
    # a second capture (after a tool fix) must NOT overwrite the first one: it uses its own file name
    [string]$OutFile = 'p14a-baseline.json',
    [string]$Note = ''
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14aRoots.ps1')

$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'capture-p14a-baseline.ps1'
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
$outPath = Join-Path (Join-Path $RunRoot 'inputs') $OutFile
if (-not (Test-Path -LiteralPath (Split-Path -Parent $outPath))) {
    Write-Host "REFUSED: inputs directory does not exist: $(Split-Path -Parent $outPath)"
    exit 2
}

function Get-Sha([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
    return ''
}
function Get-Git([string]$a) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $o = (& git -C $RepoRoot $a.Split(' ') 2>&1 | Out-String).Trim()
    $ErrorActionPreference = $saved
    return $o
}

$tools = [ordered]@{
    'benchmarks/lib/RunDirGuard.ps1'                       = (Get-Sha (Join-Path $RepoRoot 'benchmarks/lib/RunDirGuard.ps1'))
    'benchmarks/lib/P14aRoots.ps1'                         = (Get-Sha (Join-Path $RepoRoot 'benchmarks/lib/P14aRoots.ps1'))
    'benchmarks/lib/P14aCollector.ps1'                     = (Get-Sha (Join-Path $RepoRoot 'benchmarks/lib/P14aCollector.ps1'))
    'benchmarks/load/p14a-collect.ps1'                     = (Get-Sha (Join-Path $RepoRoot 'benchmarks/load/p14a-collect.ps1'))
    'benchmarks/env/prepare-p14a-run.ps1'                  = (Get-Sha (Join-Path $RepoRoot 'benchmarks/env/prepare-p14a-run.ps1'))
    'benchmarks/env/p14a-plan.ps1'                         = (Get-Sha (Join-Path $RepoRoot 'benchmarks/env/p14a-plan.ps1'))
    'benchmarks/env/start-p14a-instance.ps1'               = (Get-Sha (Join-Path $RepoRoot 'benchmarks/env/start-p14a-instance.ps1'))
    'benchmarks/env/p14a-calibrate.ps1'                    = (Get-Sha (Join-Path $RepoRoot 'benchmarks/env/p14a-calibrate.ps1'))
    'benchmarks/env/p14a-summarize.ps1'                    = (Get-Sha (Join-Path $RepoRoot 'benchmarks/env/p14a-summarize.ps1'))
    'benchmarks/env/capture-p14a-baseline.ps1'             = (Get-Sha (Join-Path $RepoRoot 'benchmarks/env/capture-p14a-baseline.ps1'))
    'benchmarks/verify/tests/run-p14a-collector-offline.ps1' = (Get-Sha (Join-Path $RepoRoot 'benchmarks/verify/tests/run-p14a-collector-offline.ps1'))
}

$sources = [ordered]@{
    'article/service/impl/ApArticleServiceImpl.java'   = (Get-Sha (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl/ApArticleServiceImpl.java'))
    'article/service/impl/ArticleFreemarkerServiceImpl.java' = (Get-Sha (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl/ArticleFreemarkerServiceImpl.java'))
    'article/support/ArticleDetailSnapshotReader.java' = (Get-Sha (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/support/ArticleDetailSnapshotReader.java'))
    'article/support/DetailCacheInvalidator.java'      = (Get-Sha (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/support/DetailCacheInvalidator.java'))
    'article/support/DetailProbe.java'                 = (Get-Sha (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/support/DetailProbe.java'))
    'common/redis/CacheService.java'                   = (Get-Sha (Join-Path $RepoRoot 'heima-leadnews-common/src/main/java/com/heima/common/redis/CacheService.java'))
}

$classesDir = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'
$classes = [ordered]@{}
foreach ($rel in @(
        'com/heima/article/service/impl/ApArticleServiceImpl.class',
        'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class',
        'com/heima/article/support/DetailCacheInvalidator.class',
        'com/heima/article/support/DetailProbe.class',
        'com/heima/article/support/ArticleDetailSnapshotReader.class',
        'com/heima/article/controller/v1/ArticleInfoController.class')) {
    $classes[$rel] = (Get-Sha (Join-Path $classesDir $rel))
}

$plansDir = Join-Path $RunRoot 'plans'
$plans = [ordered]@{}
if (Test-Path -LiteralPath $plansDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $plansDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $plans[$f.Name] = Get-Sha $f.FullName
    }
}

$jarCount = 0
if (Test-Path -LiteralPath $LibDir) { $jarCount = @(Get-ChildItem -LiteralPath $LibDir -Filter *.jar).Count }

$gitStatus = Get-Git 'status --porcelain'
$statusEntries = @($gitStatus -split "`r?`n" | Where-Object { $_.Trim() -ne '' }).Count

$baseline = [ordered]@{
    scope = 'P1.4a baseline identity (collector + entries + driver + production source/class + jar set + truth/plans)'
    captured_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    run_root = $RunRoot
    repo_root = $RepoRoot
    git_head = (Get-Git 'rev-parse HEAD')
    git_status_entries = $statusEntries
    git_diff_stat = (Get-Git 'diff --stat')
    java_exe = $JavaExe
    java_exe_sha256 = (Get-Sha $JavaExe)
    lib_dir = $LibDir
    lib_jar_count = $jarCount
    tools = $tools
    production_sources = $sources
    frozen_classes = $classes
    truth_and_plans = $plans
    note = 'baseline_id is the SHA256 of the canonical key=value payload; it changes if any tool, source, class, jar set, truth or plan changes'
    capture_note = $Note
}

$canonical = New-Object System.Collections.ArrayList
foreach ($k in $tools.Keys) { $null = $canonical.Add(('tool|{0}|{1}' -f $k, $tools[$k])) }
foreach ($k in $sources.Keys) { $null = $canonical.Add(('source|{0}|{1}' -f $k, $sources[$k])) }
foreach ($k in $classes.Keys) { $null = $canonical.Add(('class|{0}|{1}' -f $k, $classes[$k])) }
foreach ($k in $plans.Keys) { $null = $canonical.Add(('plan|{0}|{1}' -f $k, $plans[$k])) }
$null = $canonical.Add(('git|head|{0}' -f $baseline['git_head']))
$null = $canonical.Add(('git|status_entries|{0}' -f $statusEntries))
$null = $canonical.Add(('lib|jars|{0}|{1}' -f $LibDir, $jarCount))
$null = $canonical.Add(('java|{0}' -f $JavaExe))
$canonicalText = ($canonical -join "`n") + "`n"
$baseline['baseline_id'] = (Get-P14aSha256 ([System.Text.Encoding]::UTF8.GetBytes($canonicalText)))

$missing = @($tools.Keys | Where-Object { $tools[$_] -eq '' })
$missingSources = @($sources.Keys | Where-Object { $sources[$_] -eq '' })
if ($missing.Count -gt 0 -or $missingSources.Count -gt 0 -or $jarCount -lt 1) {
    Write-Host "CAPTURE FAILED: missing tool/source hashes (tools: $($missing -join ', '); sources: $($missingSources -join ', ')) or jars=$jarCount"
    exit 1
}

$null = Write-P14aOnce -Path $outPath -Text ($baseline | ConvertTo-Json -Depth 6) -EntryPoint 'capture-p14a-baseline.ps1'
Write-Host ("baseline={0} baseline_id={1} tools={2} classes={3} plans={4} jars={5} status_entries={6}" -f `
        $outPath, $baseline['baseline_id'], $tools.Count, $classes.Count, $plans.Count, $jarCount, $statusEntries)
exit 0
