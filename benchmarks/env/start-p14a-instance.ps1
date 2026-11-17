# The ONE entry point that may start a P1.4a article instance (ASCII only).
#
# Contract:
#   * -RunRoot must already exist and be a direct child of -ArtifactsRoot (created by prepare-p14a-run.ps1)
#     with its prepare-manifest.json; any existing direct child of -ArtifactsRoot is treated as sealed.
#   * every writable path (probe config, the events.file INSIDE that config, log, err, instance manifest)
#     must normalize to inside -RunRoot and outside every sealed root.
#   * an existing instance manifest / log for the same -Tag is a hard refusal (no reuse, no -Force).
#   * -Group selects the ONLY experimental variable: A = article.detail.cache.enabled=false, B = true.
#     Both groups load the SAME frozen classes from target/classes; there is no variant directory.
#   * refusal happens before Start-Process, writes no file and issues no java invocation.
#
# Exit codes: 0 = instance started (or, with -SkipPortWait, validation passed and the command was issued),
#             1 = started but the port never listened, 2 = refused before any external call.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][ValidateSet('A', 'B')][string]$Group,
    [Parameter(Mandatory = $true)][string]$ProbeConfig,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$JavaExe = 'D:\Soft\Java\jdk-1.8\bin\java.exe',
    [string]$Profile = 'p1',
    [string]$RedisTimeout = '2000ms',
    [string]$RedisDatabase = '5',
    [string]$ExpireJitterSeconds = '0',
    [string]$ExtraSpringArgs = '',
    [int]$WaitSeconds = 420,
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [switch]$SkipPortWait
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

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
function Refuse([string]$reason) {
    Write-Host "REFUSED: $reason"
    Write-Host "REFUSED_STAGE=$script:stage"
    exit 2
}

$script:stage = 'run-root'
if (-not (Test-Path -LiteralPath $RunRoot)) { Refuse "run root does not exist: $RunRoot" }
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (-not (Test-UnderRoot $RunRoot $ArtifactsRoot)) { Refuse "run root is outside the artifacts root: $RunRoot" }
# Parent-root lifecycle FIRST (the same helper every other entry uses): a completed/sealed P1.4a root is refused
# before any file write and before Start-Process, so a finished experiment can never gain another JVM.
. (Join-Path (Join-Path $RepoRoot 'benchmarks/lib') 'P14aRoots.ps1')
$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'start-p14a-instance.ps1'
# sealed = every OTHER existing direct child of the artifacts root
$sealedRoots = @(Get-ChildItem -LiteralPath $ArtifactsRoot -Directory |
    Where-Object { (Get-Normalized $_.FullName) -ne (Get-Normalized $RunRoot) } |
    ForEach-Object { $_.FullName })

# ---- 1. the ACTUAL probe config and the events file INSIDE it ----
$script:stage = 'probe-config'
if (-not (Test-Path -LiteralPath $ProbeConfig)) { Refuse "probe config does not exist: $ProbeConfig" }
$ProbeConfig = [System.IO.Path]::GetFullPath($ProbeConfig)
if (-not (Test-UnderRoot $ProbeConfig $RunRoot)) { Refuse "probe config is outside this run root: $ProbeConfig" }
foreach ($s in $sealedRoots) {
    if (Test-UnderRoot $ProbeConfig $s) { Refuse "probe config is inside a sealed root: $s" }
}

$script:stage = 'events-file'
$eventsLine = @(Get-Content -LiteralPath $ProbeConfig | Where-Object { $_ -match '^\s*events\.file\s*=' })
if ($eventsLine.Count -ne 1) { Refuse "probe config must define exactly one events.file, found $($eventsLine.Count): $ProbeConfig" }
$eventsFile = ($eventsLine[0] -replace '^\s*events\.file\s*=\s*', '').Trim()
if ([string]::IsNullOrWhiteSpace($eventsFile)) { Refuse "probe config has an empty events.file: $ProbeConfig" }
if (-not (Test-UnderRoot $eventsFile $RunRoot)) { Refuse "events file is outside this run root: $eventsFile" }
foreach ($s in $sealedRoots) {
    if (Test-UnderRoot $eventsFile $s) { Refuse "events file points into a sealed root: $s" }
}

# ---- 2. writable outputs ----
$script:stage = 'instance-outputs'
$logDir = Join-Path $RunRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { Refuse "log directory does not exist: $logDir" }
$logPath = Join-Path $logDir "$Tag.log"
$errPath = Join-Path $logDir "$Tag.log.err"
$manifestPath = Join-Path $logDir "$Tag.instance.json"
foreach ($p in @($logPath, $errPath, $manifestPath)) {
    if (-not (Test-UnderRoot $p $RunRoot)) { Refuse "instance output is outside the run root: $p" }
    foreach ($s in $sealedRoots) { if (Test-UnderRoot $p $s) { Refuse "instance output is inside a sealed root: $s" } }
}
if (Test-Path -LiteralPath $manifestPath) { Refuse "instance manifest already exists (duplicate tag / reused run): $manifestPath" }
if (Test-Path -LiteralPath $logPath) { Refuse "instance log already exists (duplicate tag / reused run): $logPath" }
if (Test-Path -LiteralPath $errPath) { Refuse "instance err log already exists (duplicate tag / reused run): $errPath" }

# ---- 3. read-only inputs: the frozen current classes (same for A and B) ----
$script:stage = 'read-only-inputs'
$classes = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'
$commonClasses = Join-Path $RepoRoot 'heima-leadnews-common/target/classes'
$modelClasses = Join-Path $RepoRoot 'heima-leadnews-model/target/classes'
foreach ($p in @($classes, $commonClasses, $modelClasses)) {
    if (-not (Test-Path -LiteralPath $p)) { Refuse "missing compiled dependency classes: $p" }
}
$classRels = @(
    'com/heima/article/service/impl/ApArticleServiceImpl.class',
    'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class',
    'com/heima/article/support/DetailCacheInvalidator.class',
    'com/heima/article/support/DetailProbe.class',
    'com/heima/article/support/ArticleDetailSnapshotReader.class',
    'com/heima/article/controller/v1/ArticleInfoController.class'
)
$classHashes = [ordered]@{}
foreach ($rel in $classRels) {
    $full = Join-Path $classes $rel
    if (-not (Test-Path -LiteralPath $full)) { Refuse "frozen classes are missing $rel : $classes" }
    $classHashes[$rel] = Get-Sha $full
}
$jarCount = @(Get-ChildItem -LiteralPath $LibDir -Filter *.jar -ErrorAction SilentlyContinue).Count
if ($jarCount -lt 1) { Refuse "no jars in lib dir: $LibDir" }
if (@(Get-ChildItem -LiteralPath $LibDir -Filter 'logback*' -ErrorAction SilentlyContinue).Count -ne 0) {
    Refuse "refusing to start: logback jars present in $LibDir (ENV-003)"
}
if (-not (Test-Path -LiteralPath $JavaExe)) { Refuse "missing java executable: $JavaExe" }

# ---- 4. build the exact command: the ONLY difference between groups is the cache switch ----
$cacheEnabled = if ($Group -eq 'B') { 'true' } else { 'false' }
$classpath = (@($classes, $commonClasses, $modelClasses, "$LibDir\*") -join ';')
$argList = @(
    '-Dfile.encoding=UTF-8',
    '-Xmx512m', '-Xms256m', '-XX:+UseParallelGC',
    "-Darticle.detail.probe.file=$ProbeConfig",
    '-cp', $classpath,
    'com.heima.article.ArticleApplication',
    "--spring.profiles.active=$Profile",
    "--server.port=$Port",
    "--spring.redis.timeout=$RedisTimeout",
    "--spring.redis.database=$RedisDatabase",
    "--article.detail.expire-jitter-seconds=$ExpireJitterSeconds",
    "--article.detail.cache.enabled=$cacheEnabled"
)
foreach ($a in ($ExtraSpringArgs -split ' ' | Where-Object { $_ -ne '' })) { $argList += $a }

$eventsShaBefore = Get-Sha $eventsFile
$launcherSha = Get-Sha $PSCommandPath
# java -version writes to stderr; with ErrorActionPreference=Stop that would become a terminating
# NativeCommandError, so this one observation runs with Continue and never changes the outcome
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$javaVersion = (& $JavaExe -version 2>&1 | Out-String).Trim()
$ErrorActionPreference = $savedEap

# ---- 5. only now: start the process ----
$script:stage = 'start'
$started = Get-Date
$proc = Start-Process -FilePath $JavaExe -ArgumentList $argList -WorkingDirectory $RepoRoot `
    -RedirectStandardOutput $logPath -RedirectStandardError $errPath -PassThru -WindowStyle Hidden

$listening = $false
if (-not $SkipPortWait) {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) { break }
        if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { $listening = $true; break }
        Start-Sleep -Milliseconds 500
    }
}

$manifest = [ordered]@{
    tag                  = $Tag
    group                = $Group
    cache_enabled        = $cacheEnabled
    port                 = $Port
    pid                  = $proc.Id
    started_local        = $started.ToString('yyyy-MM-dd HH:mm:ss zzz', $inv)
    started_utc          = $started.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    listening            = $listening
    exited               = $proc.HasExited
    exit_code            = if ($proc.HasExited) { $proc.ExitCode } else { $null }
    profile              = $Profile
    launcher             = [ordered]@{ path = $PSCommandPath; sha256 = $launcherSha }
    run_root             = $RunRoot
    validated_paths      = [ordered]@{
        probe_config      = $ProbeConfig
        events_file       = $eventsFile
        log_dir           = $logDir
        log               = $logPath
        err               = $errPath
        instance_manifest = $manifestPath
    }
    validation           = [ordered]@{ result = 'accepted'; events_file_inside_run_root = $true; events_file_in_sealed_root = $false; java_invocations = 1; compile_invocations = 0 }
    probe_config         = $ProbeConfig
    probe_config_sha256  = (Get-Sha $ProbeConfig)
    events_file_sha256_before_start = $eventsShaBefore
    redis_timeout        = $RedisTimeout
    redis_database_arg   = $RedisDatabase
    expire_jitter        = $ExpireJitterSeconds
    java                 = $JavaExe
    java_version         = $javaVersion
    lib_dir              = $LibDir
    lib_jar_count        = $jarCount
    classes_dir          = $classes
    common_classes_dir   = $commonClasses
    model_classes_dir    = $modelClasses
    frozen_class_sha256  = $classHashes
    classpath            = $classpath
    log                  = $logPath
    jvm_args             = ($argList -join ' ')
    note                 = 'A and B load the SAME frozen classes; the only experimental variable is article.detail.cache.enabled'
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $manifestPath

Write-Host ("tag={0} group={1} cache_enabled={2} pid={3} port={4} listening={5} launcher_sha={6}" -f $Tag, $Group, $cacheEnabled, $proc.Id, $Port, $listening, $launcherSha)
if ($SkipPortWait) { exit 0 }
if (-not $listening) { Write-Host 'NOT LISTENING: the process started but the port never accepted connections'; exit 1 }
exit 0
