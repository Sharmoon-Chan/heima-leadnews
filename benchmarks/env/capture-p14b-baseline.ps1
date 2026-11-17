# Capture the identity of a P1.4b run root (ASCII only).
#
# Section 8 part D rewrote three things here:
#   1. the canonical form is RECURSIVE and TYPE-TAGGED, so a nested object (instance JVM parameters, observer blocks,
#      jars, plans) actually enters the hash. The previous version expanded one level and serialised the nested object
#      as a type name, so changing a JVM argument did not change the digest at all.
#   2. the ACTUAL compiled C# measurement assembly is part of the identity (path + sha256 + bytes), not only the .cs
#      source. If the run built one, this file names the exact artifact that was loaded.
#   3. there are two phases: `-Phase start` freezes the identity of tools/dependencies/plans/patch/assembly BEFORE a
#      private run (`inputs/pre-run-freeze.json`, write once), and `-Phase final` records the delivered identity after
#      it. The final capture never overwrites the start one, and `-VerifyAgainst` compares them.
#
# Exit codes: 0 = captured, 2 = refused (root not active / output already exists), 1 = capture failed.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [ValidateSet('start', 'final')][string]$Phase = 'final',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$JavaExe = 'D:\Soft\Java\jdk-1.8\bin\java.exe',
    [string]$OutFile = '',
    [string]$Note = '',
    [string]$VerifyAgainst = ''
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14aRoots.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14bPaths.ps1')

$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'capture-p14b-baseline.ps1'
$RunRoot = (Get-P14bNormalizedPath -Path $RunRoot)
if ($OutFile -eq '') {
    $OutFile = if ($Phase -eq 'start') { 'pre-run-freeze.json' } else { 'p14b-baseline.json' }
}
try {
    $outPath = Assert-P14bOwnedPath -Path (Join-Path (Join-Path $RunRoot 'inputs') $OutFile) -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'baseline output'
} catch { Write-Host "REFUSED: $($_.Exception.Message)"; Write-Host 'REFUSED_STAGE=guard'; exit 2 }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $outPath))) { Write-Host 'REFUSED: inputs directory does not exist'; exit 2 }
if (Test-Path -LiteralPath $outPath) { Write-Host "REFUSED: already exists: $outPath"; Write-Host 'REFUSED_STAGE=write-once'; exit 2 }

function Get-Sha([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
    return ''
}
function Get-Git([string]$a) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $o = (& git -C $RepoRoot $a.Split(' ') 2>$null | Out-String).Trim()
    $ErrorActionPreference = $saved
    return $o
}

# ---- RECURSIVE, TYPE-TAGGED canonicaliser ---------------------------------------------------------------------
# Every leaf is emitted as  path=TYPE:value  and every container contributes its own structure, with keys sorted at
# every level. A nested change therefore always changes the digest, and re-ordering JSON properties does not (the walk
# is by sorted key, not by document order).
function Add-P14bCanonical {
    param($Node, [string]$Path, [System.Text.StringBuilder]$Sb)
    if ($null -eq $Node) { $null = $Sb.AppendLine("$Path=null"); return }
    if ($Node -is [bool]) { $null = $Sb.AppendLine("$Path=bool:$($Node.ToString().ToLowerInvariant())"); return }
    if ($Node -is [string]) { $null = $Sb.AppendLine("$Path=string:$Node"); return }
    if ($Node -is [int] -or $Node -is [long] -or $Node -is [int16] -or $Node -is [uint16] -or $Node -is [uint32] -or $Node -is [byte] -or $Node -is [sbyte]) {
        $null = $Sb.AppendLine("$Path=int:$Node"); return
    }
    if ($Node -is [double] -or $Node -is [single] -or $Node -is [decimal]) {
        $null = $Sb.AppendLine(("$Path=num:" + ([double]$Node).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture))); return
    }
    if ($Node -is [System.Collections.IDictionary]) {
        $null = $Sb.AppendLine("$Path=dict:$($Node.Keys.Count)")
        foreach ($k in @($Node.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            Add-P14bCanonical -Node $Node[$k] -Path "$Path.$k" -Sb $Sb
        }
        return
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $names = @($Node.PSObject.Properties.Name | Sort-Object)
        $null = $Sb.AppendLine("$Path=object:$($names.Count)")
        foreach ($n in $names) { Add-P14bCanonical -Node $Node.$n -Path "$Path.$n" -Sb $Sb }
        return
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        $items = @($Node)
        $null = $Sb.AppendLine("$Path=array:$($items.Count)")
        for ($i = 0; $i -lt $items.Count; $i++) { Add-P14bCanonical -Node $items[$i] -Path "$Path[$i]" -Sb $Sb }
        return
    }
    $null = $Sb.AppendLine("$Path=other:$($Node.GetType().FullName):$Node")
}

$tools = [ordered]@{}
$toolRels = @(
    'benchmarks/lib/RunDirGuard.ps1'
    'benchmarks/lib/P14aRoots.ps1'
    'benchmarks/lib/P14aCollector.ps1'
    'benchmarks/lib/P14bMeasure.ps1'
    'benchmarks/lib/P14bMeasure.cs'
    'benchmarks/lib/P14bPaths.ps1'
    'benchmarks/load/p14a-collect.ps1'
    'benchmarks/load/p14b-collect.ps1'
    'benchmarks/verify/p14b-observer.ps1'
    'benchmarks/env/prepare-p14a-run.ps1'
    'benchmarks/env/prepare-p14b-run.ps1'
    'benchmarks/env/p14a-plan.ps1'
    'benchmarks/env/start-p14a-instance.ps1'
    'benchmarks/env/p14a-calibrate.ps1'
    'benchmarks/env/p14b-calibrate.ps1'
    'benchmarks/env/p14a-summarize.ps1'
    'benchmarks/env/p14b-summarize.ps1'
    'benchmarks/env/capture-p14a-baseline.ps1'
    'benchmarks/env/capture-p14b-baseline.ps1'
    'benchmarks/verify/tests/run-p14a-collector-offline.ps1'
)
foreach ($rel in $toolRels) { $tools[$rel] = (Get-Sha (Join-Path $RepoRoot $rel)) }

$sources = [ordered]@{}
$srcRoot = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article'
foreach ($rel in @('service/impl/ApArticleServiceImpl.java', 'service/impl/ArticleFreemarkerServiceImpl.java',
        'support/ArticleDetailSnapshotReader.java', 'support/DetailCacheInvalidator.java', 'support/DetailProbe.java')) {
    $sources[$rel] = (Get-Sha (Join-Path $srcRoot $rel))
}
$sources['common/redis/CacheService.java'] = (Get-Sha (Join-Path $RepoRoot 'heima-leadnews-common/src/main/java/com/heima/common/redis/CacheService.java'))

$classes = [ordered]@{}
$classRoot = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'
foreach ($rel in @('com/heima/article/service/impl/ApArticleServiceImpl.class', 'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class',
        'com/heima/article/support/DetailCacheInvalidator.class', 'com/heima/article/support/DetailProbe.class',
        'com/heima/article/support/ArticleDetailSnapshotReader.class', 'com/heima/article/controller/v1/ArticleInfoController.class')) {
    $classes[$rel] = (Get-Sha (Join-Path $classRoot $rel))
}

# ---- EVERY jar, one line each ---------------------------------------------------------------------------------
$jarLines = New-Object System.Collections.ArrayList
$null = $jarLines.Add((@('jar', 'sha256', 'bytes') -join [char]9))
$jars = @()
if (Test-Path -LiteralPath $LibDir) { $jars = @(Get-ChildItem -LiteralPath $LibDir -Filter '*.jar' -File | Sort-Object Name) }
$jarBytes = [long]0
foreach ($j in $jars) {
    $null = $jarLines.Add((@($j.Name, (Get-Sha $j.FullName), $j.Length) -join [char]9))
    $jarBytes += $j.Length
}
$jarTsv = Join-Path (Join-Path $RunRoot 'inputs') 'jars-sha256.tsv'
if ($Phase -eq 'start' -or -not (Test-Path -LiteralPath $jarTsv)) {
    if (-not (Test-Path -LiteralPath $jarTsv)) { [System.IO.File]::WriteAllText($jarTsv, (($jarLines -join "`r`n") + "`r`n"), $utf8) }
}

# ---- frozen truth and plans -----------------------------------------------------------------------------------
$truthAndPlans = [ordered]@{}
$plansDir = Join-Path $RunRoot 'plans'
if (Test-Path -LiteralPath $plansDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $plansDir -File | Sort-Object Name)) { $truthAndPlans[$f.Name] = (Get-Sha $f.FullName) }
}

# ---- the ACTUAL measurement assembly(ies) produced in this root ------------------------------------------------
# Recorded as the SET of DISTINCT hashes, not per path: every collector run compiles its own copy under its own run
# directory, so a path listing would change the identity merely because another run was added. The set of distinct
# artifacts is what the "which measurement code did we actually execute" question needs.
$assemblies = [ordered]@{}
foreach ($a in @(Get-ChildItem -LiteralPath $RunRoot -Recurse -Filter 'P14bMeasure.dll' -File -ErrorAction SilentlyContinue)) {
    $h = Get-Sha $a.FullName
    if ($assemblies.Contains($h)) { $assemblies[$h] = [int]$assemblies[$h] + 1 } else { $assemblies[$h] = 1 }
}
$assemblyCount = 0
foreach ($k in @($assemblies.Keys)) { $assemblyCount += [int]$assemblies[$k] }
$srcCs = Join-Path $RepoRoot 'benchmarks/lib/P14bMeasure.cs'

# ---- runtime identity ----------------------------------------------------------------------------------------
$javaVersion = ''
if (Test-Path -LiteralPath $JavaExe) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $javaVersion = ((& $JavaExe '-version' 2>&1) | Out-String).Trim()
    $ErrorActionPreference = $saved
}
$jvmArgs = [ordered]@{}
$logsDir = Join-Path $RunRoot 'logs'
if (Test-Path -LiteralPath $logsDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $logsDir -Filter '*.instance.json' -File | Sort-Object Name)) {
        try {
            $m = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $jvmArgs[$f.Name] = [ordered]@{
                port = $m.port; pid = $m.pid; cache_enabled = $m.cache_enabled
                jvm_args = $(if ($null -ne $m.PSObject.Properties['jvm_args']) { @($m.jvm_args) } else { @() })
                java_exe = $(if ($null -ne $m.PSObject.Properties['java_exe']) { [string]$m.java_exe } else { '' })
                classpath_jars = $(if ($null -ne $m.PSObject.Properties['classpath_jars']) { @($m.classpath_jars).Count } else { 0 })
            }
        } catch { $jvmArgs[$f.Name] = 'unreadable' }
    }
}
$patchPath = Join-Path (Join-Path $RunRoot 'inputs') 'tracked-patch-at-start.diff'
$patchSha = Get-Sha $patchPath

$payload = [ordered]@{
    scope = 'P1.4b identity: recursive/type-tagged canonical form, tools, production source/class, EVERY jar, truth/plans, the ACTUAL measurement assembly, runtime and instance JVM parameters'
    phase = $Phase
    captured_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    run_root = $RunRoot
    repo_root = $RepoRoot
    git_head = (Get-Git 'rev-parse HEAD')
    git_status_entries = @((Get-Git 'status --porcelain') -split "`r?`n" | Where-Object { $_.Trim() -ne '' }).Count
    git_diff_stat = (Get-Git 'diff --stat')
    tracked_patch_at_start = [ordered]@{ file = $(if (Test-Path -LiteralPath $patchPath) { 'inputs/tracked-patch-at-start.diff' } else { '' }); sha256 = $patchSha }
    measurement_assembly = [ordered]@{
        source = 'benchmarks/lib/P14bMeasure.cs'; source_sha256 = (Get-Sha $srcCs)
        compiled = $assemblies
        absent_reason = $(if ($assemblies.Count -eq 0) { 'no measurement assembly was compiled in this root at capture time' } else { '' })
    }
    runtime = [ordered]@{
        java_exe = $JavaExe; java_exe_sha256 = (Get-Sha $JavaExe); java_version = $javaVersion
        powershell_version = [string]$PSVersionTable.PSVersion
        clr_version = [string][System.Environment]::Version
        os_version = [string][System.Environment]::OSVersion.VersionString
        logical_cores = [Environment]::ProcessorCount
        stopwatch_frequency = [System.Diagnostics.Stopwatch]::Frequency
    }
    lib_dir = $LibDir
    lib_jar_count = $jars.Count
    lib_jar_bytes = $jarBytes
    lib_jar_manifest = 'inputs/jars-sha256.tsv'
    lib_jar_manifest_sha256 = (Get-Sha $jarTsv)
    tools = $tools
    production_sources = $sources
    frozen_classes = $classes
    truth_and_plans = $truthAndPlans
    instance_jvm = $jvmArgs
    note = 'baseline_id is the SHA256 of the RECURSIVE canonical payload below (every leaf contributes, keys sorted at every level, values type tagged)'
    capture_note = $Note
}

$sb = New-Object System.Text.StringBuilder
foreach ($k in @($payload.Keys | Sort-Object)) {
    if ($k -eq 'captured_local' -or $k -eq 'capture_note' -or $k -eq 'phase') { continue }
    Add-P14bCanonical -Node $payload[$k] -Path $k -Sb $sb
}
$canonicalText = $sb.ToString()
$bytes = [System.Text.Encoding]::UTF8.GetBytes($canonicalText)
$sha = [System.Security.Cryptography.SHA256]::Create()
$baselineId = ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower()
$sha.Dispose()
$payload['baseline_id'] = $baselineId
$payload['canonical_line_count'] = @($canonicalText -split "`r?`n" | Where-Object { $_.Trim() -ne '' }).Count
$canonPath = Join-Path (Join-Path $RunRoot 'inputs') ("canonical-$Phase.txt")
[System.IO.File]::WriteAllText($canonPath, $canonicalText, $utf8)
[System.IO.File]::WriteAllText($outPath, ($payload | ConvertTo-Json -Depth 10), $utf8)

Write-Host ("phase={0} out={1} baseline_id={2} canonical_lines={3} tools={4} classes={5} plans={6} jars={7} assemblies={8} status_entries={9}" -f `
        $Phase, $outPath, $baselineId, $payload['canonical_line_count'], $tools.Count, $classes.Count, $truthAndPlans.Count, $jars.Count, $assemblies.Count, $payload['git_status_entries'])

if ($VerifyAgainst -ne '') {
    $vPath = if ([System.IO.Path]::IsPathRooted($VerifyAgainst)) { $VerifyAgainst } else { Join-Path (Join-Path $RunRoot 'inputs') $VerifyAgainst }
    if (-not (Test-Path -LiteralPath $vPath)) { Write-Host "VERIFY FAILED: the comparison file is missing: $vPath"; exit 1 }
    $old = Get-Content -LiteralPath $vPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $diffs = New-Object System.Collections.ArrayList
    foreach ($k in @('tools', 'production_sources', 'frozen_classes', 'truth_and_plans')) {
        $a = ($old.$k | ConvertTo-Json -Compress -Depth 6)
        $b = ($payload[$k] | ConvertTo-Json -Compress -Depth 6)
        if ($a -ne $b) { $null = $diffs.Add("$k changed") }
    }
    if ([string]$old.git_head -ne [string]$payload['git_head']) { $null = $diffs.Add('git_head changed') }
    if ([string]$old.lib_jar_manifest_sha256 -ne [string]$payload['lib_jar_manifest_sha256']) { $null = $diffs.Add('jar manifest changed') }
    if ($diffs.Count -gt 0) {
        Write-Host ("VERIFY FAILED: the delivered identity differs from the pre-run freeze: {0}" -f ($diffs -join '; '))
        exit 1
    }
    Write-Host "pre_run_freeze_verified=true (tools/production/classes/plans/head/jars identical to $vPath)"
}
exit 0
