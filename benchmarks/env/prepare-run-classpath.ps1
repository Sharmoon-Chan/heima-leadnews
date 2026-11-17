# Build a runnable classpath directory for a module, with the known-fatal logback jars removed.
#
# Why this exists (ENV-003):
#   The project uses log4j2 (root pom excludes spring-boot-starter-logging), but
#   spring-boot-starter-freemarker transitively brings logback-classic. When both bindings are on
#   the classpath the app dies at startup with:
#     IllegalArgumentException: LoggerFactory is not a Logback LoggerContext but Logback is on the classpath
#   The agreed P0 workaround is to strip the logback jars from the *run* classpath instead of
#   editing poms. Doing that by hand once is not enough: re-copying dependencies re-introduces them
#   (this actually happened during P1.0), so this script always re-applies the exclusion.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks/env/prepare-run-classpath.ps1 `
#     -ModulePath heima-leadnews-service/heima-leadnews-article `
#     -LibDir D:/Code/Java/heima-leadnews/_optimization-artifacts/lib
param(
    [Parameter(Mandatory = $true)][string]$ModulePath,
    [Parameter(Mandatory = $true)][string]$LibDir,
    [string]$MavenCmd = 'D:/Soft/apache-maven-3.6.1/bin/mvn.cmd'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $LibDir | Out-Null

$cpFile = Join-Path $LibDir 'cp.txt'
if (Test-Path $cpFile) { Remove-Item $cpFile -Force }

Write-Host "resolving dependencies for $ModulePath ..."
& $MavenCmd -q -pl $ModulePath dependency:build-classpath "-Dmdep.outputFile=$cpFile" 2>&1 | Out-Null
if (-not (Test-Path $cpFile)) { throw "classpath file not produced: $cpFile" }

$jars = (Get-Content $cpFile -Raw).Trim() -split ';' | Where-Object { $_ -like '*.jar' }
$copied = 0
$updated = 0
foreach ($j in $jars) {
    $dest = Join-Path $LibDir (Split-Path $j -Leaf)
    if (-not (Test-Path $dest)) {
        Copy-Item $j $dest
        $copied++
    } elseif ((Get-FileHash -Algorithm SHA256 $j).Hash -ne (Get-FileHash -Algorithm SHA256 $dest).Hash) {
        # a module we just rebuilt (e.g. heima-leadnews-model) must not stay stale here
        Copy-Item $j $dest -Force
        $updated++
    }
}

# ENV-003: must run after every copy, otherwise a classpath refresh silently reintroduces them
$removed = @()
foreach ($pat in @('logback-classic-*.jar', 'logback-core-*.jar')) {
    Get-ChildItem $LibDir -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
        $removed += $_.Name
        Remove-Item $_.FullName -Force
    }
}

$jarCount = (Get-ChildItem $LibDir -Filter *.jar).Count
$logbackLeft = (Get-ChildItem $LibDir -Filter 'logback*' -ErrorAction SilentlyContinue).Count

[ordered]@{
    module            = $ModulePath
    lib_dir           = $LibDir
    jars_present      = $jarCount
    jars_copied       = $copied
    jars_updated      = $updated
    logback_removed   = $removed
    logback_remaining = $logbackLeft
} | ConvertTo-Json -Depth 4

if ($logbackLeft -ne 0) { throw "logback jars still present in $LibDir" }
if ($jarCount -lt 1) { throw "no jars in $LibDir" }
exit 0
