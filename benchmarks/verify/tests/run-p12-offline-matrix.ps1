# P1.2 offline A/B matrix runner (ASCII only; PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
#
# Purpose: the round-2 matrix output was produced by an ad-hoc command that was not saved, so a
# reviewer could not re-derive it. This script makes that step reproducible: it compiles the SAME
# harness (P12OfflineRework.java) against ONE code variant and runs every requested case, writing
# one block per case into a single file that is never overwritten.
#
# The variant is only a directory of .class files placed first on the classpath, so no source file
# in the tree is moved or edited and the comparison really is between compiled code versions.
#
# Exit codes: 0 = every case exited 0, 1 = at least one case failed (output kept), 2 = usage problem.
param(
    [Parameter(Mandatory = $true)][string]$VariantName,
    [Parameter(Mandatory = $true)][string]$VariantClasses,
    [Parameter(Mandatory = $true)][string]$WorkDir,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string[]]$Cases = @('R1-stall', 'R1-late-acquire', 'R1-slow-lock-fail', 'R2-read', 'R2-recheck', 'R2-lock', 'R2-release', 'R2-slow-timeout', 'R3-ok'),
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$JavaExe = 'D:\Soft\Java\jdk-1.8\bin\java.exe',
    [string]$JavacExe = 'D:\Soft\Java\jdk-1.8\bin\javac.exe'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path -LiteralPath $VariantClasses)) { Write-Host "missing variant classes: $VariantClasses"; exit 2 }
if (-not (Test-Path -LiteralPath $LibDir)) { Write-Host "missing lib dir: $LibDir"; exit 2 }
$harness = Join-Path $RepoRoot 'benchmarks/verify/tests/P12OfflineRework.java'
if (-not (Test-Path -LiteralPath $harness)) { Write-Host "missing harness: $harness"; exit 2 }
# write-once: a second run must create a new file, never append to or replace an earlier matrix
if (Test-Path -LiteralPath $OutFile) { Write-Host "refusing to overwrite existing matrix: $OutFile"; exit 2 }

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$classesOut = Join-Path $WorkDir 'harness-classes'
New-Item -ItemType Directory -Force -Path $classesOut | Out-Null

$jars = @(Get-ChildItem -LiteralPath $LibDir -Filter *.jar | ForEach-Object { $_.FullName })
$cp = (@($VariantClasses,
        (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-common/target/classes')) + $jars) -join ';'

$compileLog = & $JavacExe '-encoding' 'UTF-8' '-nowarn' '-cp' $cp '-d' $classesOut $harness 2>&1
$compileExit = $LASTEXITCODE
if ($compileExit -ne 0) {
    Write-Host "harness compile failed (exit $compileExit):"
    $compileLog | Select-Object -First 20 | ForEach-Object { Write-Host $_ }
    exit 2
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# P1.2 offline matrix, variant=$VariantName")
$lines.Add("# variant classes: $VariantClasses")
$lines.Add("# harness: $(Split-Path -Leaf $harness) compiled with -encoding UTF-8")
$svcClass = Join-Path $VariantClasses 'com/heima/article/service/impl/ApArticleServiceImpl.class'
$svcHash = if (Test-Path -LiteralPath $svcClass) { (Get-FileHash -LiteralPath $svcClass -Algorithm SHA256).Hash.ToLower() } else { 'missing' }
$lines.Add("# variant ApArticleServiceImpl.class sha256=$svcHash")
$lines.Add("# cases: $($Cases -join ' ')")
$lines.Add('')

$runCp = $classesOut + ';' + $cp
$caseFailures = 0
foreach ($c in $Cases) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $JavaExe '-Dfile.encoding=UTF-8' '-cp' $runCp 'P12OfflineRework' $c 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) { $caseFailures++ }
    $lines.Add("### variant=$VariantName case=$c exit=$code")
    foreach ($l in @($out)) { $lines.Add(($l | Out-String).TrimEnd()) }
    $lines.Add('')
    Write-Host ("case={0} variant={1} exit={2}" -f $c, $VariantName, $code)
}

$lines.Add("# summary variant=$VariantName cases=$($Cases.Count) failed_cases=$caseFailures")
[System.IO.File]::WriteAllLines($OutFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("variant={0} cases={1} failed={2} out={3}" -f $VariantName, $Cases.Count, $caseFailures, $OutFile)
if ($caseFailures -gt 0) { exit 1 }
exit 0
