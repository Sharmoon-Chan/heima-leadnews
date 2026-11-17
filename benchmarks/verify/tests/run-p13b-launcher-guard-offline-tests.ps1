# A: offline proof that the REAL launcher refuses an out-of-root events file before any external call.
#
# The previous 9/9 only covered prepare-p13b-run.ps1 parameters; the review showed the actual start
# path (start-p1-2-instance.ps1) still handed an unsafe probe config to Java. This test therefore
# calls the actual launcher (benchmarks/env/start-p13b-instance.ps1) with a recording stand-in for
# java.exe, so "no external call" is a counted fact, not an absence of class directories.
#
# Cases:
#   P1 positive            : config + events inside the case root -> accepted, java invoked exactly once
#   P2 tampered-after-prep : prepare left a valid config, then events.file was rewritten to a sealed root
#   P3 swapped-config      : the launcher is given a config that lives outside the case root
#   P4 duplicate-tag       : the same tag is started twice -> second run must be refused
#
# Every refusal case must show: exit 2, java invocations 0, no instance manifest/log created, and the
# sealed sentinel byte-identical (hash + size).
#
# Exit codes: 0 = all cases behaved as required, 1 = a case failed, 2 = setup/usage problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [string]$Launcher = 'D:/Code/Java/heima-leadnews/heima-leadnews/benchmarks/env/start-p13b-instance.ps1',
    [string]$SealedSentinelDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261101-P1.3b-rework-START',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$Port = '51999'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

. (Join-Path $PSScriptRoot '..\..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.3b-launcher-guard' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ launcher = $Launcher; run_root = $RunRoot; sentinel_dir = $SealedSentinelDir } `
        -Targets @() -DataSet '(none)'
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
}
function Get-Sha([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
    return ''
}
function Get-DirFingerprint([string]$dir) {
    # hash of "relative path + size + sha256" for every file: detects a created/modified/removed file
    $lines = @(Get-ChildItem $dir -Recurse -File | Sort-Object FullName | ForEach-Object {
        "$($_.FullName.Substring($dir.Length+1))|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower())" })
    $joined = ($lines -join "`n")
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower()
}

if (-not (Test-Path -LiteralPath $Launcher)) { Write-Host "REFUSED: launcher not found: $Launcher"; exit 2 }
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
$caseRoot = Join-Path $RunRoot 'guard-tests/p13b-launcher'
if (Test-Path -LiteralPath $caseRoot) { Write-Host "REFUSED: case root already exists: $caseRoot"; exit 2 }

$srcVariant = Join-Path $RunRoot 'build/run-classes-POST'
$srcHarness = Join-Path $RunRoot 'build/harness-classes'
foreach ($p in @($srcVariant, $srcHarness, $SealedSentinelDir)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "REFUSED: missing input: $p"; exit 2 }
}

# The "sealed sentinel" is a NEW file path inside an already sealed root. Nothing may create it.
$sentinel = Join-Path $SealedSentinelDir 'p13b-launcher-sentinel-events.log'
$sentinelExistedBefore = Test-Path -LiteralPath $sentinel
$sentinelShaBefore = Get-Sha $sentinel
$sentinelSizeBefore = if (Test-Path -LiteralPath $sentinel) { (Get-Item $sentinel).Length } else { -1 }
$sealedFingerprintBefore = Get-DirFingerprint $SealedSentinelDir

function New-Case([string]$name) {
    $root = Join-Path $caseRoot "$name/root"
    foreach ($d in @('build', 'logs', 'configs', 'events', 'runs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null
    }
    Copy-Item -LiteralPath $srcVariant -Destination (Join-Path $root 'build/run-classes-POST') -Recurse -Force
    Copy-Item -LiteralPath $srcHarness -Destination (Join-Path $root 'build/harness-classes') -Recurse -Force
    return $root
}
function Write-Probe([string]$root, [string]$eventsPath) {
    $cfg = Join-Path $root 'configs/p13b-probe.properties'
    $expected = "$((Get-Sha (Join-Path $root 'build/run-classes-POST/com/heima/article/service/impl/ApArticleServiceImpl.class')))"
    $text = "# launcher guard case config (ASCII only)`n" +
            "events.file=$($eventsPath -replace '\\\\','/')`n" +
            "launcher.case.expected_service_class=$expected`n"
    [System.IO.File]::WriteAllText($cfg, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $cfg
}
function New-Stub([string]$caseDir) {
    # stand-in for java.exe: appends one line per invocation to calls.txt and the arguments to
    # args.txt, never listens on a port. The redirect is put FIRST on the line because
    # "echo %*>>file" breaks when an argument is quoted by Start-Process.
    $bat = Join-Path $caseDir 'rec-java.bat'
    $q = [char]34
    $calls = Join-Path $caseDir 'calls.txt'
    $argsFile = Join-Path $caseDir 'args.txt'
    $lines = @(
        '@echo off',
        ">>$q$calls$q echo invoked",
        ">>$q$argsFile$q echo %*",
        'exit /b 0'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($bat, $lines + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    return $bat
}
function Get-CallCount([string]$caseDir) {
    $f = Join-Path $caseDir 'calls.txt'
    if (-not (Test-Path -LiteralPath $f)) { return 0 }
    return @(Get-Content -LiteralPath $f).Count
}
function Invoke-Launcher([string]$root, [string]$tag, [string]$config, [string]$stub, [switch]$SkipWait) {
    # NOTE: never use $args here - it is the automatic variable for unbound function arguments
    $launchArgs = @{
        RunRoot = $root; Port = [int]$Port; Tag = $tag; ProbeConfig = $config; VariantName = 'POST'
        RepoRoot = $RepoRoot; LibDir = $LibDir; JavaExe = $stub
    }
    if ($SkipWait) { $launchArgs['SkipPortWait'] = $true }
    # *>&1 also captures Write-Host (information stream), so the refusal text is kept as evidence
    $out = & $Launcher @launchArgs *>&1
    return [pscustomobject]@{ exit = $LASTEXITCODE; output = (($out | Out-String).Trim()) }
}

$results = @()

# ============================================================ P1 positive
$p1 = Join-Path $caseRoot 'P1'
$root1 = New-Case 'P1'
$events1 = Join-Path $root1 'events/p13b-events.log'
$cfg1 = Write-Probe $root1 $events1
$stub1 = New-Stub $p1
$evShaBefore = Get-Sha $events1
$r1 = Invoke-Launcher $root1 'guard-P1' $cfg1 $stub1 -SkipWait
Start-Sleep -Milliseconds 1500
$manifest1 = Join-Path $root1 'logs/guard-P1.instance.json'
$calls1 = Get-CallCount $p1
$m1 = if (Test-Path $manifest1) { Get-Content $manifest1 -Raw | ConvertFrom-Json } else { $null }
$allInside = $false
if ($m1) {
    $allInside = $true
    foreach ($vp in $m1.validated_paths.PSObject.Properties) {
        $v = ([string]$vp.Value -replace '/', '\')
        if (-not $v.ToLowerInvariant().StartsWith($root1.ToLowerInvariant())) { $allInside = $false }
    }
}
$results += [pscustomobject]@{
    case = 'P1 positive'; exit = $r1.exit; java_calls = $calls1
    pass = ($r1.exit -eq 0 -and $calls1 -eq 1 -and $null -ne $m1 -and $allInside -and
            $m1.validation.result -eq 'accepted' -and $m1.validation.java_invocations -eq 1 -and
            $m1.validation.compile_invocations -eq 0 -and ((Get-Sha $events1) -eq $evShaBefore))
    detail = "exit=$($r1.exit) java_calls=$calls1 manifest=$($null -ne $m1) paths_inside=$allInside events_file_unchanged=$((Get-Sha $events1) -eq $evShaBefore) output=$($r1.output -replace "`r?`n", ' | ')"
}

# ============================================================ P2 events file tampered AFTER prepare
$p2 = Join-Path $caseRoot 'P2'
$root2 = New-Case 'P2'
$cfg2 = Write-Probe $root2 (Join-Path $root2 'events/p13b-events.log')
$stub2 = New-Stub $p2
# the "prepare" step is done; now rewrite ONLY the events line of the ACTUAL config to a sealed root
$tampered = Get-Content -LiteralPath $cfg2 | ForEach-Object {
    if ($_ -match '^\s*events\.file\s*=') { "events.file=$($sentinel -replace '\\','/')" } else { $_ }
}
[System.IO.File]::WriteAllText($cfg2, (($tampered -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
$calls2 = Get-CallCount $p2
$r2 = Invoke-Launcher $root2 'guard-P2' $cfg2 $stub2 -SkipWait
$results += [pscustomobject]@{
    case = 'P2 tampered config -> sealed root'; exit = $r2.exit; java_calls = $calls2
    pass = ($r2.exit -eq 2 -and $calls2 -eq 0 -and
            -not (Test-Path (Join-Path $root2 'logs/guard-P2.instance.json')) -and
            -not (Test-Path (Join-Path $root2 "logs/guard-P2.log")) -and
            $r2.output -match 'sealed root')
    detail = "exit=$($r2.exit) java_calls=$calls2 manifest_created=$((Test-Path (Join-Path $root2 'logs/guard-P2.instance.json'))) output=$($r2.output -replace "`r?`n", ' | ')"
}

# ============================================================ P3 config that lives outside the root
$p3 = Join-Path $caseRoot 'P3'
$root3 = New-Case 'P3'
$outsideDir = Join-Path $p3 'outside'
New-Item -ItemType Directory -Force -Path $outsideDir | Out-Null
$outsideCfg = Join-Path $outsideDir 'p13b-probe.properties'
$outsideEvents = Join-Path $outsideDir 'p13b-events.log'
[System.IO.File]::WriteAllText($outsideCfg, ("# config outside the run root`nevents.file=$($outsideEvents -replace '\\\\','/')`n"), (New-Object System.Text.UTF8Encoding($false)))
$stub3 = New-Stub $p3
$r3 = Invoke-Launcher $root3 'guard-P3' $outsideCfg $stub3 -SkipWait
$calls3 = Get-CallCount $p3
$results += [pscustomobject]@{
    case = 'P3 config outside run root'; exit = $r3.exit; java_calls = $calls3
    pass = ($r3.exit -eq 2 -and $calls3 -eq 0 -and -not (Test-Path (Join-Path $root3 'logs/guard-P3.instance.json')) -and
            -not (Test-Path -LiteralPath $outsideEvents) -and $r3.output -match 'outside this run root')
    detail = "exit=$($r3.exit) java_calls=$calls3 outside_events_created=$((Test-Path -LiteralPath $outsideEvents)) output=$($r3.output -replace "`r?`n", ' | ')"
}

# ============================================================ P4 duplicate tag on the accepted root
$r4 = Invoke-Launcher $root1 'guard-P1' $cfg1 $stub1 -SkipWait
Start-Sleep -Milliseconds 500
$calls4 = Get-CallCount $p1
$results += [pscustomobject]@{
    case = 'P4 duplicate tag'; exit = $r4.exit; java_calls = $calls4
    pass = ($r4.exit -eq 2 -and $calls4 -eq 1 -and $r4.output -match 'already exists')
    detail = "exit=$($r4.exit) java_calls_after_second_attempt=$calls4 (first P1 run already used 1) output=$($r4.output -replace "`r?`n", ' | ')"
}

# ============================================================ sealed root untouched
$sentinelExistedAfter = Test-Path -LiteralPath $sentinel
$sealedFingerprintAfter = Get-DirFingerprint $SealedSentinelDir
$results += [pscustomobject]@{
    case = 'sealed root untouched'; exit = $null; java_calls = $null
    pass = ((-not $sentinelExistedBefore) -and (-not $sentinelExistedAfter) -and ($sealedFingerprintBefore -eq $sealedFingerprintAfter))
    detail = "sentinel_existed_before=$sentinelExistedBefore sentinel_existed_after=$sentinelExistedAfter sealed_directory_fingerprint_same=$($sealedFingerprintBefore -eq $sealedFingerprintAfter)"
}

foreach ($r in $results) {
    Add-Check ("launcher." + ($r.case -replace '[^A-Za-z0-9]+', '_').ToLower()) $r.pass $r.detail
}

$summary = [ordered]@{
    run_id = $RunId
    launcher = [ordered]@{ path = $Launcher; sha256 = (Get-Sha $Launcher) }
    run_root = $RunRoot
    case_root = $caseRoot
    sealed_sentinel = $sentinel
    sealed_fingerprint_before = $sealedFingerprintBefore
    sealed_fingerprint_after = $sealedFingerprintAfter
    cases = $results
    finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'launcher-guard-results.json') -Text ($summary | ConvertTo-Json -Depth 6)

$counts = Get-RunCheckCounts $script:run
$script:run.checks | ForEach-Object { "{0,-42} {1,-6} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
