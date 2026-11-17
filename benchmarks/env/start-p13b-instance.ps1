# The ONE entry point that may start a P1.3b article instance (ASCII only).
#
# Why a new script instead of the older start-p1-2-instance.ps1: that one only checks that the probe
# config EXISTS and hands it to the JVM. The A-D review proved this can be bypassed - put the probe
# config inside the root but point its events.file at an old sealed log, and the launcher happily
# started Java. This launcher reads the ACTUAL probe config, normalizes the events file and every
# writable output path, and refuses BEFORE any compile, any Java process and any external call.
#
# Contract:
#   * -RunRoot must already exist (created by prepare-p13b-run.ps1 with the shared guard)
#   * every writable path (probe config, events file INSIDE that config, variant classes, harness
#     classes, log/err/instance manifest, child run dir) must normalize to inside -RunRoot
#   * no writable path may normalize into a sealed evidence root (P1.3a / P1.3b / review roots)
#   * an existing instance manifest for the same -Tag is a hard refusal (no reuse, no -Force)
#   * refusal happens before Start-Process; the refusal path writes NO file and counts 0 java calls
#
# Exit codes: 0 = instance started (or, with -SkipPortWait, validation passed and the command was
# issued), 1 = started but the port never listened, 2 = refused before any external call.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$ProbeConfig,
    [Parameter(Mandatory = $true)][ValidateSet('PRE', 'POST', 'C200', 'C500', 'C1500')][string]$VariantName,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$JavaExe = 'D:\Soft\Java\jdk-1.8\bin\java.exe',
    [string]$RunsDir = '',
    [string]$ExtraSpringArgs = '',
    [string]$Profile = 'p1',
    [string]$RedisTimeout = '2000ms',
    [string]$ExpireJitterSeconds = '0',
    # isolated Redis database for the counter/hot-list path; empty = leave the server default.
    # It is passed as a real Spring property and its effect is proved from the client side by the
    # scenario scripts (keys must appear in this DB and be absent from DB 0).
    [string]$RedisDatabase = '',
    [int]$WaitSeconds = 120,
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    # offline tests only: issue the command and return 0 without waiting for a listening port
    [switch]$SkipPortWait
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
    (Join-Path $ArtifactsRoot '20261031-P1.3a-REVIEW'),
    (Join-Path $ArtifactsRoot '20261031-P1.3a-ROUND4-REVIEW'),
    (Join-Path $ArtifactsRoot '20261031-P1.3b'),
    (Join-Path $ArtifactsRoot '20261031-P1.3b-run-r01'),
    (Join-Path $ArtifactsRoot '20261031-P1.3b-run-r02'),
    (Join-Path $ArtifactsRoot '20261031-P1.3b-run-r03'),
    (Join-Path $ArtifactsRoot '20261031-P1.3b-run-r04'),
    (Join-Path $ArtifactsRoot '20261101-P1.3b-REVIEW'),
    (Join-Path $ArtifactsRoot '20261101-P1.3b-rework'),
    (Join-Path $ArtifactsRoot '20261101-P1.3b-rework-start'),
    (Join-Path $ArtifactsRoot '20261101-P1.3b-rework-run-r01'),
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
function Get-Sha([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
    return ''
}
# every refusal funnels through here: message on stdout, exit 2, nothing written, no process started
function Refuse([string]$reason) {
    Write-Host "REFUSED: $reason"
    Write-Host "REFUSED_STAGE=$script:stage"
    exit 2
}

$script:stage = 'inputs'
if (-not (Test-Path -LiteralPath $RunRoot)) { Refuse "run root does not exist: $RunRoot" }
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (-not (Test-UnderRoot $RunRoot $ArtifactsRoot)) { Refuse "run root is outside the artifacts root: $RunRoot" }
foreach ($s in $sealedRoots) {
    if (Test-UnderRoot $RunRoot $s) { Refuse "run root is inside a sealed root: $s" }
}

# ---- 1. the ACTUAL probe config, and the events file INSIDE it ----
$script:stage = 'probe-config'
if (-not (Test-Path -LiteralPath $ProbeConfig)) { Refuse "probe config does not exist: $ProbeConfig" }
$ProbeConfig = [System.IO.Path]::GetFullPath($ProbeConfig)
foreach ($s in $sealedRoots) {
    if (Test-UnderRoot $ProbeConfig $s) { Refuse "probe config is inside a sealed root: $s" }
}
if (-not (Test-UnderRoot $ProbeConfig $RunRoot)) { Refuse "probe config is outside this run root: $ProbeConfig" }

$script:stage = 'events-file'
$eventsLine = @(Get-Content -LiteralPath $ProbeConfig | Where-Object { $_ -match '^\s*events\.file\s*=' })
if ($eventsLine.Count -ne 1) { Refuse "probe config must define exactly one events.file, found $($eventsLine.Count): $ProbeConfig" }
$eventsFile = ($eventsLine[0] -replace '^\s*events\.file\s*=\s*', '').Trim()
if ([string]::IsNullOrWhiteSpace($eventsFile)) { Refuse "probe config has an empty events.file: $ProbeConfig" }
foreach ($s in $sealedRoots) {
    if (Test-UnderRoot $eventsFile $s) { Refuse "events file points into a sealed root: $eventsFile (sealed: $s)" }
}
if (-not (Test-UnderRoot $eventsFile $RunRoot)) {
    Refuse "events file is outside this run root: $eventsFile (root: $RunRoot)"
}

# ---- 2. writable outputs: variant classes, harness classes, logs, child dirs ----
$script:stage = 'variant-classes'
$variantDir = Join-Path $RunRoot ("build/run-classes-" + $VariantName)
if (-not (Test-Path -LiteralPath $variantDir)) { Refuse "variant class directory does not exist: $variantDir" }
if (-not (Test-UnderRoot $variantDir $RunRoot)) { Refuse "variant class directory is outside the run root: $variantDir" }
foreach ($rel in @('com/heima/article/service/impl/ApArticleServiceImpl.class',
                   'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class',
                   'com/heima/article/p13b/P13bHarnessController.class')) {
    $full = Join-Path $variantDir $rel
    if (-not (Test-Path -LiteralPath $full)) { Refuse "variant class directory is missing $rel : $variantDir" }
    if (-not (Test-UnderRoot $full $RunRoot)) { Refuse "loaded class resolves outside the run root: $full" }
}
$harnessClasses = Join-Path $RunRoot 'build/harness-classes'
if (-not (Test-Path -LiteralPath $harnessClasses)) { Refuse "harness class directory does not exist: $harnessClasses" }
if (-not (Test-UnderRoot $harnessClasses $RunRoot)) { Refuse "harness class directory is outside the run root: $harnessClasses" }

$script:stage = 'instance-outputs'
$logDir = Join-Path $RunRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { Refuse "log directory does not exist: $logDir" }
if (-not (Test-UnderRoot $logDir $RunRoot)) { Refuse "log directory is outside the run root: $logDir" }
$logPath = Join-Path $logDir "$Tag.log"
$errPath = Join-Path $logDir "$Tag.log.err"
$manifestPath = Join-Path $logDir "$Tag.instance.json"
foreach ($p in @($logPath, $errPath, $manifestPath)) {
    if (-not (Test-UnderRoot $p $RunRoot)) { Refuse "instance output is outside the run root: $p" }
}
if (Test-Path -LiteralPath $manifestPath) { Refuse "instance manifest already exists (duplicate tag / reused run): $manifestPath" }
if (Test-Path -LiteralPath $logPath) { Refuse "instance log already exists (duplicate tag / reused run): $logPath" }

if ([string]::IsNullOrWhiteSpace($RunsDir)) { $RunsDir = Join-Path $RunRoot 'runs' }
$RunsDir = [System.IO.Path]::GetFullPath($RunsDir)
if (-not (Test-UnderRoot $RunsDir $RunRoot)) { Refuse "child run directory is outside the run root: $RunsDir" }

# read-only inputs may live outside the root
$script:stage = 'read-only-inputs'
$classes = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'
$commonClasses = Join-Path $RepoRoot 'heima-leadnews-common/target/classes'
$modelClasses = Join-Path $RepoRoot 'heima-leadnews-model/target/classes'
foreach ($p in @($classes, $commonClasses, $modelClasses)) {
    if (-not (Test-Path -LiteralPath $p)) { Refuse "missing compiled dependency classes: $p" }
}
$jarCount = @(Get-ChildItem -LiteralPath $LibDir -Filter *.jar -ErrorAction SilentlyContinue).Count
if ($jarCount -lt 1) { Refuse "no jars in lib dir: $LibDir" }
if (@(Get-ChildItem -LiteralPath $LibDir -Filter 'logback*' -ErrorAction SilentlyContinue).Count -ne 0) {
    Refuse "refusing to start: logback jars present in $LibDir (ENV-003)"
}
if (-not (Test-Path -LiteralPath $JavaExe)) { Refuse "missing java executable: $JavaExe" }

# ---- 3. build the exact command (no side effects so far) ----
$classpath = (@($variantDir, $classes, $commonClasses, $modelClasses, "$LibDir\*") -join ';')
$argList = @(
    '-Dfile.encoding=UTF-8',
    '-Xmx512m', '-Xms256m', '-XX:+UseParallelGC',
    "-Darticle.detail.probe.file=$ProbeConfig",
    '-cp', $classpath,
    'com.heima.article.ArticleApplication',
    "--spring.profiles.active=$Profile",
    "--server.port=$Port",
    "--spring.redis.timeout=$RedisTimeout",
    "--article.detail.expire-jitter-seconds=$ExpireJitterSeconds"
)
if (-not [string]::IsNullOrWhiteSpace($RedisDatabase)) {
    $argList += "--spring.redis.database=$RedisDatabase"
}
foreach ($a in ($ExtraSpringArgs -split ' ' | Where-Object { $_ -ne '' })) { $argList += $a }

$eventsShaBefore = Get-Sha $eventsFile
$scriptsSha = Get-Sha $PSCommandPath

# ---- 4. only now: start the process ----
$script:stage = 'start'
$started = Get-Date
$proc = $null
if ($SkipPortWait) {
    $proc = Start-Process -FilePath $JavaExe -ArgumentList $argList -WorkingDirectory $RepoRoot `
        -RedirectStandardOutput $logPath -RedirectStandardError $errPath -PassThru -WindowStyle Hidden
} else {
    $proc = Start-Process -FilePath $JavaExe -ArgumentList $argList -WorkingDirectory $RepoRoot `
        -RedirectStandardOutput $logPath -RedirectStandardError $errPath -PassThru -WindowStyle Hidden
}

$listening = $false
if (-not $SkipPortWait) {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) { break }
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
        if ($conn) { $listening = $true; break }
        Start-Sleep -Milliseconds 500
    }
}

$variantClassHashes = [ordered]@{}
foreach ($rel in @('com/heima/article/service/impl/ApArticleServiceImpl.class',
                   'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class',
                   'com/heima/article/p13b/P13bHarnessConfig.class',
                   'com/heima/article/p13b/P13bHarnessController.class')) {
    $variantClassHashes[$rel] = Get-Sha (Join-Path $variantDir $rel)
}

$manifest = [ordered]@{
    tag                 = $Tag
    port                = $Port
    pid                 = $proc.Id
    started_local       = $started.ToString('yyyy-MM-dd HH:mm:ss zzz', $inv)
    started_utc         = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    listening           = $listening
    exited              = $proc.HasExited
    exit_code           = if ($proc.HasExited) { $proc.ExitCode } else { $null }
    profile             = $Profile
    launcher            = [ordered]@{ path = $PSCommandPath; sha256 = $scriptsSha }
    run_root            = $RunRoot
    validated_paths     = [ordered]@{
        probe_config   = $ProbeConfig
        events_file    = $eventsFile
        variant_classes = $variantDir
        harness_classes = $harnessClasses
        logs_dir       = $logDir
        log            = $logPath
        err            = $errPath
        instance_manifest = $manifestPath
        child_runs     = $RunsDir
    }
    validation          = [ordered]@{
        result = 'accepted'
        events_file_inside_run_root = $true
        events_file_in_sealed_root = $false
        java_invocations = 1
        compile_invocations = 0
    }
    probe_config        = $ProbeConfig
    probe_config_sha256 = (Get-Sha $ProbeConfig)
    events_file_sha256_before_start = $eventsShaBefore
    redis_timeout       = $RedisTimeout
    redis_database_arg  = $RedisDatabase
    expire_jitter       = $ExpireJitterSeconds
    java                = $JavaExe
    lib_dir             = $LibDir
    lib_jar_count       = $jarCount
    classes_dir         = $classes
    common_classes_dir  = $commonClasses
    model_classes_dir   = $modelClasses
    variant_name        = $VariantName
    variant_classes     = $variantDir
    variant_class_sha256 = $variantClassHashes
    classpath           = $classpath
    log                 = $logPath
    jvm_args            = ($argList -join ' ')
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $manifestPath

Write-Host ("tag={0} pid={1} port={2} listening={3} launcher_sha={4}" -f $Tag, $proc.Id, $Port, $listening, $scriptsSha)
if ($SkipPortWait) { exit 0 }
if (-not $listening) { Write-Host 'NOT LISTENING: the process started but the port never accepted connections'; exit 1 }
exit 0
