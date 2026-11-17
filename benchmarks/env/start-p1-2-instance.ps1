# Start one P1.2 article instance for the experiments (ASCII only).
#
# Why a dedicated script: the experiment needs TWO identifiable executors on the same host
# (a main instance on 51802 and a holder instance on 51803) plus, for C5, instances started
# with a simulated-Redis-fault probe config. Everything else (profile, classpath, encoding,
# logback exclusion) follows the already-validated P1.0/P1.1 way of starting the service.
#
# This script only starts a process and waits for the port; it does not touch data.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks/env/start-p1-2-instance.ps1 `
#     -Port 51802 -Tag main -ProbeConfig benchmarks/config/p1-2-probe.main.properties `
#     -LogDir D:/Code/Java/heima-leadnews/_optimization-artifacts/20261030-P1.2/logs
param(
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$LogDir,
    [string]$ProbeConfig = '',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$JavaExe = 'D:\Soft\Java\jdk-1.8\bin\java.exe',
    [string]$Profile = 'p1',
    [string]$RedisTimeout = '2000ms',
    [string]$ExpireJitterSeconds = '0',
    [string]$ExtraSpringArgs = '',
    [string]$VariantName = '',
    [string]$VariantClasses = '',
    [int]$WaitSeconds = 120
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$logPath = Join-Path $LogDir "$Tag.log"
if (Test-Path -LiteralPath $logPath) {
    Write-Host "refusing to overwrite an existing instance log: $logPath"
    exit 2
}

$classes = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'
if (-not (Test-Path -LiteralPath $classes)) { Write-Host "missing compiled classes: $classes"; exit 2 }
# The common module is changed in P1.2 (narrow Lua release method). Its target/classes must come
# BEFORE the jars, otherwise the stale heima-leadnews-common jar from the local repository wins.
$commonClasses = Join-Path $RepoRoot 'heima-leadnews-common/target/classes'
if (-not (Test-Path -LiteralPath $commonClasses)) { Write-Host "missing compiled classes: $commonClasses"; exit 2 }
$jarCount = @(Get-ChildItem -LiteralPath $LibDir -Filter *.jar).Count
if ($jarCount -lt 1) { Write-Host "no jars in $LibDir"; exit 2 }
$logback = @(Get-ChildItem -LiteralPath $LibDir -Filter 'logback*' -ErrorAction SilentlyContinue).Count
if ($logback -ne 0) { Write-Host "refusing to start: logback jars present in $LibDir (ENV-003)"; exit 2 }

$cpParts = @()
if (-not [string]::IsNullOrWhiteSpace($VariantClasses)) {
    # R4: a variant baseline (A = pre-rework, B = reworked) must win over the module classes,
    # so its directory goes first on the classpath. Nothing in the tree is moved or edited.
    if (-not (Test-Path -LiteralPath $VariantClasses)) { Write-Host "missing variant classes: $VariantClasses"; exit 2 }
    $cpParts += $VariantClasses
}
$cpParts += $classes
$cpParts += $commonClasses
$cpParts += "$LibDir\*"
$classpath = ($cpParts -join ';')

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

# extra Spring command-line properties (experiment config only, e.g. connection pool size)
foreach ($a in ($ExtraSpringArgs -split ' ' | Where-Object { $_ -ne '' })) { $argList += $a }

$started = Get-Date
$proc = Start-Process -FilePath $JavaExe -ArgumentList $argList -WorkingDirectory $RepoRoot `
    -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err" -PassThru -WindowStyle Hidden

# wait for the port to accept connections
$listening = $false
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) { break }
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) { $listening = $true; break }
    Start-Sleep -Milliseconds 500
}

function Get-FileSha([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }
    return ''
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
    probe_config        = $ProbeConfig
    probe_config_sha256 = (Get-FileSha $ProbeConfig)
    redis_timeout       = $RedisTimeout
    expire_jitter       = $ExpireJitterSeconds
    java                = $JavaExe
    lib_dir             = $LibDir
    lib_jar_count       = $jarCount
    classes_dir         = $classes
    variant_name        = $VariantName
    variant_classes     = $VariantClasses
    variant_sha256      = ''
    classpath           = $classpath
    classes_sha256      = ''
    log                 = $logPath
    jvm_args            = ($argList -join ' ')
}
# hash the class actually loaded first on the classpath (variant baseline when present)
$loadedRoot = if (-not [string]::IsNullOrWhiteSpace($VariantClasses)) { $VariantClasses } else { $classes }
$svcClass = Join-Path $loadedRoot 'com/heima/article/service/impl/ApArticleServiceImpl.class'
if (Test-Path -LiteralPath $svcClass) { $manifest.classes_sha256 = (Get-FileSha $svcClass); $manifest.variant_sha256 = $manifest.classes_sha256 }
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $LogDir "$Tag.instance.json")

Write-Host ("tag={0} pid={1} port={2} listening={3}" -f $Tag, $proc.Id, $Port, $listening)
if (-not $listening) { exit 1 }
exit 0
