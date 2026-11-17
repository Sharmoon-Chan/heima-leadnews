# P1.3b run-root preparation with OUTPUT PATH PROTECTION (ASCII only).
#
# Why this exists: P1.3a reused an old evidence root as its build target and appended events to an old
# log. This script therefore creates ONE new guarded run root and refuses, BEFORE compiling or calling
# anything external, when a writable path would land outside that root or inside a sealed root.
#
# Everything writable lives under <RunRoot>:
#   build/            compiled harness + PRE/POST variant classes
#   harness/src/      the harness sources actually compiled
#   pre-src/          the PRE (pre-fix + probe-only hooks) sources actually compiled
#   configs/          the probe properties actually used (events file inside events/)
#   events/           event streams
#   logs/             instance logs/manifests
#   runs/             scenario sub-outputs
# Only inputs may live outside: the repository, the jar library and the frozen start snapshots.
#
# Exit codes: 0 = run root ready, 1 = build failure, 2 = path/guard refusal (nothing was compiled).
param(
    [string]$InteractionRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$FrozenReviewRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261031-P1.3a-ROUND4-REVIEW',
    [string]$HarnessSrc = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261031-P1.3b/harness/src',
    [string]$JavaHome = 'D:\Soft\Java\jdk-1.8',
    # OPTIONAL, only for the negative test: an explicit events file that must be REJECTED when it is
    # outside the new run root (for example an old sealed log).
    [string]$EventsFileOverride = '',
    # sealed (read-only) evidence roots live under the REAL artifacts root, not under InteractionRoot,
    # so a test that redirects InteractionRoot still refuses a path aimed at a real sealed log
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    # provenance only: the frozen start snapshot of the A-D rework (19 sources, 60 benchmarks, harness)
    [string]$StartSnapshotDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261103-P1.3b-round2-START'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$sealedRoots = @(
    (Join-Path $ArtifactsRoot '20261030-P1.2'),
    (Join-Path $ArtifactsRoot '20261030-P1.2-rework'),
    (Join-Path $ArtifactsRoot '20261031-P1.2-round3'),
    (Join-Path $ArtifactsRoot '20261031-P1.3a'),
    (Join-Path $ArtifactsRoot '20261031-P1.3a-round4'),
    (Join-Path $ArtifactsRoot '20261031-P1.2-ROUND3-REVIEW'),
    # TOOL-003 fix (2026-11-03): these six were dropped from this list while the new roots were added.
    # The launcher kept them, but prepare creates directories and compiles BEFORE the launcher runs,
    # so prepare needs the same read-only protection on its own.
    (Join-Path $ArtifactsRoot '20261031-P1.3a-REVIEW'),
    (Join-Path $ArtifactsRoot '20261031-P1.3a-ROUND4-REVIEW'),
    (Join-Path $ArtifactsRoot '20261031-P1.3b'),
    (Join-Path $ArtifactsRoot '20261031-P1.3b-run-r01'),
    (Join-Path $ArtifactsRoot '20261031-P1.3b-run-r02'),
    (Join-Path $ArtifactsRoot '20261031-P1.3b-run-r03'),
    (Join-Path $ArtifactsRoot '20261031-P1.3b-run-r04'),
    (Join-Path $ArtifactsRoot '20261101-P1.3b-REVIEW'),
    (Join-Path $ArtifactsRoot '20261101-P1.3b-rework'),
    (Join-Path $ArtifactsRoot '20261101-P1.3b-rework-START'),
    (Join-Path $ArtifactsRoot '20261101-P1.3b-rework-run-r01'),
    # round 2: the reviewer root, the start snapshot and every earlier output are read-only
    (Join-Path $ArtifactsRoot '20261102-P1.3b-REWORK-REVIEW'),
    (Join-Path $ArtifactsRoot '20261103-P1.3b-REWORK-REVIEW-r01'),
    (Join-Path $ArtifactsRoot '20261103-P1.3b-round2-START')
)

function Get-Normalized([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    return [System.IO.Path]::GetFullPath($p).TrimEnd('\', '/').ToLowerInvariant()
}

function Test-UnderRoot([string]$path, [string]$root) {
    $p = Get-Normalized $path
    $r = Get-Normalized $root
    if ($p -eq '' -or $r -eq '') { return $false }
    return ($p -eq $r) -or $p.StartsWith($r + '\') -or $p.StartsWith($r + '/')
}

$runRoot = Join-Path $InteractionRoot $RunId
if (Test-Path -LiteralPath $runRoot) {
    Write-Host "REFUSED: run root already exists: $runRoot"
    exit 2
}

# ---- 1. every sealed root is read-only this round ----
foreach ($s in $sealedRoots) {
    if (Test-UnderRoot $runRoot $s) {
        Write-Host "REFUSED: run root would be inside a sealed root: $s"
        exit 2
    }
}

# ---- 2. the events file must be inside the new run root (checked BEFORE any compile) ----
$eventsDir = Join-Path $runRoot 'events'
$eventsFile = if ([string]::IsNullOrWhiteSpace($EventsFileOverride)) {
    Join-Path $eventsDir 'p13b-events.log'
} else {
    $EventsFileOverride
}
foreach ($s in $sealedRoots) {
    if (Test-UnderRoot $eventsFile $s) {
        Write-Host "REFUSED: events file would point into a sealed root: $eventsFile"
        Write-Host "  sealed root: $s"
        exit 2
    }
}
if (-not (Test-UnderRoot $eventsFile $runRoot)) {
    Write-Host "REFUSED: events file must be inside this run root: $eventsFile (root: $runRoot)"
    exit 2
}
$probeConfig = Join-Path $runRoot 'configs/p13b-probe.properties'
if (-not (Test-UnderRoot $probeConfig $runRoot)) {
    Write-Host "REFUSED: probe config must be inside this run root: $probeConfig"
    exit 2
}

# ---- 3. inputs must exist (read-only, may be outside the root) ----
foreach ($required in @($RepoRoot, $LibDir, $FrozenReviewRoot, $HarnessSrc)) {
    if (-not (Test-Path -LiteralPath $required)) {
        Write-Host "REFUSED: missing required input: $required"
        exit 2
    }
}
$javac = Join-Path $JavaHome 'bin\javac.exe'
if (-not (Test-Path -LiteralPath $javac)) {
    Write-Host "REFUSED: missing javac: $javac"
    exit 2
}

# ---- 4. create the root and only inside it ----
foreach ($d in @('build', 'harness/src', 'pre-src', 'configs', 'events', 'logs', 'runs')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $runRoot $d) | Out-Null
}
$created = Get-ChildItem -LiteralPath $runRoot -Directory | ForEach-Object { $_.FullName }
foreach ($c in $created) {
    if (-not (Test-UnderRoot $c $runRoot)) {
        Write-Host "REFUSED: created directory escaped the run root: $c"
        exit 2
    }
}

$jars = @(Get-ChildItem -LiteralPath $LibDir -Filter *.jar | ForEach-Object { $_.FullName })
$depCp = (@(
        (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-common/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-model/target/classes')
    ) + $jars) -join ';'

function Get-Sha([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }
    return ''
}

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

# ---- 5. harness classes (inside build/) ----
$harnessSrcDst = Join-Path $runRoot 'harness/src'
Copy-Item (Join-Path $HarnessSrc '*') $harnessSrcDst -Recurse -Force
$harnessClasses = Join-Path $runRoot 'build/harness-classes'
New-Item -ItemType Directory -Force -Path $harnessClasses | Out-Null
$hlog = & $javac '-encoding' 'UTF-8' '-nowarn' '-cp' $depCp '-d' $harnessClasses `
    (Get-ChildItem $harnessSrcDst -Recurse -Filter *.java | ForEach-Object { $_.FullName }) 2>&1
$hcode = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($hcode -ne 0) {
    Write-Host "BUILD FAILED: harness compile exit=$hcode"
    $hlog | Select-Object -First 15 | ForEach-Object { Write-Host $_ }
    exit 1
}

# ---- 6. PRE sources = frozen pre-fix files + probe-only hooks (inside pre-src/) ----
$preSrcDir = Join-Path $runRoot 'pre-src'
$frozenSvc = Join-Path $FrozenReviewRoot 'source-copies-after-P1.3a/heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl/ApArticleServiceImpl.java'
if (-not (Test-Path -LiteralPath $frozenSvc)) {
    Write-Host "REFUSED: missing frozen service source: $frozenSvc"
    exit 2
}
$svcText = [System.IO.File]::ReadAllText($frozenSvc).Replace("`r`n", "`n")

$countAnchor = "        ApArticle apArticle = updateArticle(mess);`n"
if ($svcText.IndexOf($countAnchor) -lt 0) { Write-Host 'BUILD FAILED: count anchor not found'; exit 1 }
$svcText = $svcText.Replace($countAnchor, $countAnchor + @"
        //P1.3b PRE instrumentation: identical event as POST, but NO invalidation is registered
        probe.event("behavior_count.updated", 0L, apArticle.getId(),
                "views=" + apArticle.getViews() + " likes=" + apArticle.getLikes()
                        + " comments=" + apArticle.getComment() + " collections=" + apArticle.getCollection());

"@)

$freemarkerSrc = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl/ArticleFreemarkerServiceImpl.java'
# the pre-fix Freemarker file is the one from git HEAD (unmodified before this card)
$headFreemarker = & git -C $RepoRoot show 'HEAD:heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl/ArticleFreemarkerServiceImpl.java' 2>&1
$headText = ($headFreemarker | Out-String).Replace("`r`n", "`n")
if ($headText.IndexOf('buildArticleToMinIO') -lt 0) { Write-Host 'BUILD FAILED: cannot read HEAD Freemarker source'; exit 1 }
$autowiredAnchor = "    @Autowired`n    private ApArticleService apArticleService;`n"
if ($headText.IndexOf($autowiredAnchor) -lt 0) { Write-Host 'BUILD FAILED: Freemarker field anchor not found'; exit 1 }
$headText = $headText.Replace($autowiredAnchor, $autowiredAnchor + "`n    /** P1.3b PRE instrumentation */`n    @Autowired`n    private com.heima.article.support.DetailProbe probe;`n")
$staticAnchor = ".set(ApArticle::getStaticUrl,path));`n"
if ($headText.IndexOf($staticAnchor) -lt 0) { Write-Host 'BUILD FAILED: static_url anchor not found'; exit 1 }
$headText = $headText.Replace($staticAnchor, $staticAnchor + @"
            //P1.3b PRE instrumentation: identical event as POST, but NO invalidation is registered
            probe.event("static_url.updated", 0L, apArticle.getId(),
                    "path=" + path + " inAsyncWorker=true"
                            + " txActive=" + org.springframework.transaction.support.TransactionSynchronizationManager.isActualTransactionActive());

"@)

$preImplDir = Join-Path $preSrcDir 'com/heima/article/service/impl'
New-Item -ItemType Directory -Force -Path $preImplDir | Out-Null
[System.IO.File]::WriteAllText((Join-Path $preImplDir 'ApArticleServiceImpl.java'), $svcText.Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $preImplDir 'ArticleFreemarkerServiceImpl.java'), $headText.Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# ---- 7. compile both variants into build/run-classes-<V> ----
$variants = @{}
foreach ($variant in @('PRE', 'POST')) {
    $outDir = Join-Path $runRoot ("build/run-classes-" + $variant)
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $sources = @()
    if ($variant -eq 'PRE') {
        $sources = @(
            (Join-Path $preImplDir 'ApArticleServiceImpl.java'),
            (Join-Path $preImplDir 'ArticleFreemarkerServiceImpl.java')
        )
    } else {
        $sources = @(
            (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl/ApArticleServiceImpl.java'),
            (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl/ArticleFreemarkerServiceImpl.java')
        )
    }
    $prevEap2 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $log = & $javac '-encoding' 'UTF-8' '-nowarn' '-cp' $depCp '-d' $outDir $sources 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEap2
    if ($code -ne 0) {
        Write-Host "BUILD FAILED: $variant compile exit=$code"
        $log | Select-Object -First 15 | ForEach-Object { Write-Host $_ }
        exit 1
    }
    # harness classes ride along so ONE classpath entry covers both
    Copy-Item (Join-Path $harnessClasses '*') $outDir -Recurse -Force
    foreach ($f in @('com/heima/article/service/impl/ApArticleServiceImpl.class',
                     'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class')) {
        $full = Join-Path $outDir $f
        if (-not (Test-Path -LiteralPath $full)) {
            Write-Host "BUILD FAILED: $variant missing compiled class $f"
            exit 1
        }
        if (-not (Test-UnderRoot $full $runRoot)) {
            Write-Host "REFUSED: compiled class escaped the run root: $full"
            exit 2
        }
    }
    $variants[$variant] = [ordered]@{
        classes_dir = $outDir
        article_service_class_sha256 = (Get-Sha (Join-Path $outDir 'com/heima/article/service/impl/ApArticleServiceImpl.class'))
        freemarker_class_sha256 = (Get-Sha (Join-Path $outDir 'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class'))
    }
}

# ---- 8. probe config: events file lives inside this run root ----
$probeText = @"
# P1.3b probe config, generated by prepare-p13b-run.ps1 for run $RunId. ASCII only.
events.file=$($eventsFile -replace '\\','/')
# N: the fixed article id used by the create scenario (set at launch time; empty = no fixture)
"@
[System.IO.File]::WriteAllText($probeConfig, $probeText, (New-Object System.Text.UTF8Encoding($false)))

# ---- 9. manifest: everything actually used, with hashes ----
$manifest = [ordered]@{
    run_id          = $RunId
    created_local   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    start_snapshot  = $StartSnapshotDir
    run_root        = $runRoot
    repo_root       = $RepoRoot
    lib_dir         = $LibDir
    frozen_review   = $FrozenReviewRoot
    sealed_roots    = $sealedRoots
    events_file     = $eventsFile
    probe_config    = $probeConfig
    probe_config_sha256 = (Get-Sha $probeConfig)
    harness_src     = $harnessSrcDst
    harness_classes = $harnessClasses
    pre_src         = $preSrcDir
    pre_service_sha256      = (Get-Sha (Join-Path $preImplDir 'ApArticleServiceImpl.java'))
    pre_freemarker_sha256   = (Get-Sha (Join-Path $preImplDir 'ArticleFreemarkerServiceImpl.java'))
    post_service_sha256     = (Get-Sha (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl/ApArticleServiceImpl.java'))
    post_freemarker_sha256  = (Get-Sha (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl/ArticleFreemarkerServiceImpl.java'))
    variants        = $variants
    writable_roots  = @('build', 'harness', 'pre-src', 'configs', 'events', 'logs', 'runs')
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $runRoot 'build/build-manifest.json')

Write-Host "run_root=$runRoot"
Write-Host "events_file=$eventsFile"
Write-Host "probe_config=$probeConfig"
foreach ($k in $variants.Keys) {
    Write-Host ("variant={0} articleService={1} freemarker={2}" -f $k, $variants[$k].article_service_class_sha256, $variants[$k].freemarker_class_sha256)
}
exit 0
