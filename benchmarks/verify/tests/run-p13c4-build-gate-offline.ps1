# P1.3c-4 build-gate offline tests (ASCII only).
#
# Proves the TOOL-012 bypass is closed before any experiment runs. One counter-example plus six refusals,
# all against the REAL gate script:
#   P  positive            a fresh P1.3c-4 root builds c200 once and records the variant
#   N1 missing -RunRoot    the parameter is mandatory, so no default path can be picked up
#   N2 empty -RunRoot      refused by the explicit emptiness check
#   N3 old-card root       a root prepared for an earlier card (carrying its own prepare manifest) is refused
#   N4 real sealed root    the accepted P1.3c-3 root is refused and left byte-identical
#   N5 output outside root -OutputRoot outside -RunRoot is refused, nothing is created there
#   N6 duplicate variant   building the same variant twice is refused (write-once)
#
# "Zero compile, zero external call" is proven three ways per refusal, without any wrapper around javac:
#   * the gate must exit 2 with a REFUSED_STAGE that happens BEFORE the compile stage;
#   * no variant directory (and therefore no classes, no javac log) may appear;
#   * -JavacExe points at a path that does not exist, so any attempt to compile would fail differently.
#
# No real evidence root is written to: the old-card case uses a synthetic root, and the real sealed root is
# only pointed at to prove the refusal happens before any write (its tree is hashed before and after).
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$RealSealedRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261103-P1.3c3-run-r01'
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3c-4-build-gate-offline' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ cases = 'P,N1,N2,N3,N4,N5,N6' } -Targets @() -DataSet 'offline'
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-52} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'fail' }), $d
}
function Get-Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
function Get-TreeSnapshot([string]$dir) {
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Recurse -File | Sort-Object FullName | ForEach-Object {
            $rel = $_.FullName.Substring($dir.Length).TrimStart('\', '/') -replace '\\', '/'
            "$rel|$($_.Length)|$(Get-Sha $_.FullName)"
        })
}

# ---------------------------------------------------------------- private working area (inside the run dir)
$tmp = Join-Path $outDir 'tmp'
$sentinelDir = Join-Path $outDir 'sentinel'
$tmpArtifacts = Join-Path $tmp 'artifacts'
New-Item -ItemType Directory -Path $sentinelDir, $tmpArtifacts | Out-Null
foreach ($f in @('sentinel-a.txt', 'sub/sentinel-b.txt')) {
    $p = Join-Path $sentinelDir $f
    New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
    [System.IO.File]::WriteAllText($p, "sentinel $f`n", $utf8)
}
$sentinelBefore = Get-TreeSnapshot $sentinelDir

$gate = Join-Path $benchDir 'env/build-p13c4-variant.ps1'
$prepare = Join-Path $benchDir 'env/prepare-p13c4-run.ps1'
if (-not (Test-Path -LiteralPath $gate)) { Write-Host "missing gate: $gate"; exit 2 }
if (-not (Test-Path -LiteralPath $prepare)) { Write-Host "missing prepare: $prepare"; exit 2 }
# a javac path that cannot exist: any attempt to compile would fail in a different, visible way
$noJavac = 'X:\p13c4-offline\no-such-javac.exe'
$preCompileStages = @('parameters', 'sealed-roots', 'prepare-manifest', 'output-root', 'variant-dir', 'writable-paths', 'inputs', 'source-copy')

function Invoke-Ps([string]$scriptPath, [string[]]$argList) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scriptPath @argList 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    return [pscustomobject]@{ exit = $code; text = ((@($out)) -join "`r`n") }
}
function Get-RefusedStage([string]$text) {
    $m = [regex]::Match($text, 'REFUSED_STAGE=([^\r\n]+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

$gateLog = New-Object System.Collections.ArrayList
function Invoke-Gate([string]$label, [string[]]$argList) {
    $r = Invoke-Ps $gate $argList
    $null = $gateLog.Add(("[{0}] exit={1} stage={2}`r`n{3}" -f $label, $r.exit, (Get-RefusedStage $r.text), $r.text))
    return $r
}
function Assert-Refused([string]$name, $result, [string]$variantDirPath, [string]$extra) {
    $stage = Get-RefusedStage $result.text
    $ok = ($result.exit -eq 2) -and ($preCompileStages -contains $stage) -and (-not (Test-Path -LiteralPath $variantDirPath))
    Add-Check $name $ok ("exit={0} stage={1} variant_dir_created={2} {3}" -f $result.exit, $stage, [bool](Test-Path -LiteralPath $variantDirPath), $extra)
    return $ok
}

# ---------------------------------------------------------------- P: positive
$t1 = Join-Path $tmpArtifacts 'T-ONE'
$p1 = Invoke-Ps $prepare @('-RunRoot', $t1, '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot)
Add-Check 'gate.prepare_counter_root' ($p1.exit -eq 0) "prepare exit=$($p1.exit) root=T-ONE"
$r = Invoke-Gate 'P' @('-RunRoot', $t1, '-RunId', 'T-ONE', '-Variant', 'c200',
    '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot)
$variantDir = Join-Path $t1 'variants/c200'
$recordFile = Join-Path $variantDir 'build/variant.json'
$clsDst = Join-Path $variantDir 'classes'
$varCls = Join-Path $clsDst 'com/heima/article/support/DetailCacheInvalidator.class'
Add-Check 'gate.positive_built' ($r.exit -eq 0 -and (Test-Path -LiteralPath $recordFile) -and (Test-Path -LiteralPath $varCls)) `
    "exit=$($r.exit) variant.json=$([bool](Test-Path -LiteralPath $recordFile)) invalidator-class=$([bool](Test-Path -LiteralPath $varCls))"

$record = $null
if (Test-Path -LiteralPath $recordFile) { $record = Get-Content -LiteralPath $recordFile -Raw | ConvertFrom-Json }
$prodCls = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes/com/heima/article/support/DetailCacheInvalidator.class'
$prodHash = Get-Sha $prodCls
$varHash = ''
if (Test-Path -LiteralPath $varCls) { $varHash = Get-Sha $varCls }
Add-Check 'gate.positive_variant_differs_from_production' ($null -ne $record -and $varHash -ne '' -and $varHash -ne $prodHash -and $record.delay_ms -eq 200 -and $record.delay_constant -eq 'SECOND_DELETE_DELAY_MILLIS = 200L') `
    "production=$($prodHash.Substring(0,16)) variant=$(if ($varHash) { $varHash.Substring(0,16) } else { 'missing' }) delay_ms=$($record.delay_ms)"
$bizSame = $true
foreach ($rel in @('com/heima/article/service/impl/ApArticleServiceImpl.class', 'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class')) {
    $a = Join-Path $clsDst $rel
    if (-not (Test-Path -LiteralPath $a)) { $bizSame = $false; continue }
    if ((Get-Sha $a) -ne (Get-Sha (Join-Path $RepoRoot "heima-leadnews-service/heima-leadnews-article/target/classes/$rel"))) { $bizSame = $false }
}
Add-Check 'gate.positive_business_classes_identical' $bizSame 'both business classes byte-identical to target/classes (only the delay constant changed)'
$srcDiff = ''
$srcDir = Join-Path $variantDir 'src'
if (Test-Path -LiteralPath $srcDir) {
    $srcDiff = @(Get-ChildItem -LiteralPath $srcDir -Recurse -Filter *.java | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join ''
}
Add-Check 'gate.positive_only_delay_constant_changed' ($srcDiff -match 'SECOND_DELETE_DELAY_MILLIS = 200L' -and $srcDiff -notmatch 'SECOND_DELETE_DELAY_MILLIS = 500L') `
    'variant source carries the 200 ms constant and no longer the 500 ms one'

# ---------------------------------------------------------------- N1: missing -RunRoot
$n1 = Invoke-Ps $gate @()
Add-Check 'gate.missing_runroot_refused' ($n1.exit -ne 0) "exit=$($n1.exit) (a mandatory parameter with no default cannot be satisfied)"
$null = $gateLog.Add("[N1] exit=$($n1.exit)`r`n$($n1.text)")

# ---------------------------------------------------------------- N2: empty -RunRoot
$n2 = Invoke-Gate 'N2' @('-RunRoot', '', '-RunId', 'x', '-Variant', 'c200', '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot, '-JavacExe', $noJavac)
# an empty string is rejected by the binding layer itself (mandatory parameter), which also means no
# default path can ever be picked up; either way the gate must not create or compile anything.
$stage2 = Get-RefusedStage $n2.text
$n2Ok = ($n2.exit -ne 0) -and (($stage2 -eq '') -or ($preCompileStages -contains $stage2)) -and (-not (Test-Path -LiteralPath (Join-Path $tmpArtifacts 'x/variants/c200')))
Add-Check 'gate.empty_runroot_refused' $n2Ok ("exit={0} stage={1} variant_dir_created={2} (empty -RunRoot is refused before any write or compile)" -f $n2.exit, $(if ($stage2) { $stage2 } else { 'binding-mandatory' }), [bool](Test-Path -LiteralPath (Join-Path $tmpArtifacts 'x/variants/c200')))

# ---------------------------------------------------------------- N3: a root prepared for an earlier card
$oldRoot = Join-Path $tmpArtifacts 'OLD-P1.3c-3-style'
New-Item -ItemType Directory -Path (Join-Path $oldRoot 'build') -Force | Out-Null
$oldManifest = [ordered]@{ run_root = $oldRoot; stage = 'P1.3c-3 backfill window inside and beyond the fixed 500 ms second delete'; prepared_local = (Get-Date -Format 'o') }
[System.IO.File]::WriteAllText((Join-Path $oldRoot 'build/prepare-manifest.json'), ($oldManifest | ConvertTo-Json -Depth 4), $utf8)
[System.IO.File]::WriteAllText((Join-Path $oldRoot 'run-manifest.json'), '{"run_id":"OLD-P1.3c-3-style"}', $utf8)
[System.IO.File]::WriteAllText((Join-Path $oldRoot 'sealed-evidence.txt'), "accepted evidence`n", $utf8)
$oldBefore = Get-TreeSnapshot $oldRoot
$n3 = Invoke-Gate 'N3' @('-RunRoot', $oldRoot, '-RunId', 'OLD-P1.3c-3-style', '-Variant', 'c200', '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot, '-JavacExe', $noJavac)
$oldAfter = Get-TreeSnapshot $oldRoot
$stage3 = Get-RefusedStage $n3.text
Add-Check 'gate.old_card_root_refused_and_untouched' ($n3.exit -eq 2 -and $stage3 -eq 'prepare-manifest' -and ((@($oldBefore) -join "`n") -eq (@($oldAfter) -join "`n")) -and -not (Test-Path -LiteralPath (Join-Path $oldRoot 'variants'))) `
    "exit=$($n3.exit) stage=$stage3 tree_unchanged=$((@($oldBefore) -join "`n") -eq (@($oldAfter) -join "`n")) variants_created=$([bool](Test-Path -LiteralPath (Join-Path $oldRoot 'variants')))"

# ---------------------------------------------------------------- N4: the real accepted P1.3c-3 root
if (Test-Path -LiteralPath $RealSealedRoot) {
    $realLeaf = Split-Path $RealSealedRoot -Leaf
    $realBefore = Get-TreeSnapshot $RealSealedRoot
    $n4 = Invoke-Gate 'N4' @('-RunRoot', $RealSealedRoot, '-RunId', $realLeaf, '-Variant', 'c200', '-ArtifactsRoot', $ArtifactsRoot, '-RepoRoot', $RepoRoot, '-JavacExe', $noJavac)
    $realAfter = Get-TreeSnapshot $RealSealedRoot
    $stage4 = Get-RefusedStage $n4.text
    Add-Check 'gate.real_sealed_root_refused_untouched' ($n4.exit -eq 2 -and $stage4 -eq 'prepare-manifest' -and ((@($realBefore) -join "`n") -eq (@($realAfter) -join "`n"))) `
        "exit=$($n4.exit) stage=$stage4 tree_unchanged=$((@($realBefore) -join "`n") -eq (@($realAfter) -join "`n")) root=$realLeaf files=$(@($realBefore).Count)"
} else {
    Add-Check 'gate.real_sealed_root_refused_untouched' $false "missing sealed root to point at: $RealSealedRoot"
}

# ---------------------------------------------------------------- N5: output root outside the run root
$t2 = Join-Path $tmpArtifacts 'T-TWO'
$p2 = Invoke-Ps $prepare @('-RunRoot', $t2, '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot)
$outside = Join-Path $tmp 'outside-output'
$n5 = Invoke-Gate 'N5' @('-RunRoot', $t2, '-RunId', 'T-TWO', '-Variant', 'c200', '-OutputRoot', $outside,
    '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot, '-JavacExe', $noJavac)
$stage5 = Get-RefusedStage $n5.text
Add-Check 'gate.output_outside_root_refused' ($p2.exit -eq 0 -and $n5.exit -eq 2 -and $stage5 -eq 'output-root' -and -not (Test-Path -LiteralPath $outside) -and -not (Test-Path -LiteralPath (Join-Path $t2 'variants/c200'))) `
    "prepare_exit=$($p2.exit) exit=$($n5.exit) stage=$stage5 outside_created=$([bool](Test-Path -LiteralPath $outside)) variant_created=$([bool](Test-Path -LiteralPath (Join-Path $t2 'variants/c200')))"

# ---------------------------------------------------------------- N6: duplicate variant
$recordHashBefore = Get-Sha $recordFile
$treeBefore = Get-TreeSnapshot $variantDir
$n6 = Invoke-Gate 'N6' @('-RunRoot', $t1, '-RunId', 'T-ONE', '-Variant', 'c200', '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot, '-JavacExe', $noJavac)
$stage6 = Get-RefusedStage $n6.text
$treeAfter = Get-TreeSnapshot $variantDir
Add-Check 'gate.duplicate_variant_refused' ($n6.exit -eq 2 -and $stage6 -eq 'variant-dir' -and (Get-Sha $recordFile) -eq $recordHashBefore -and ((@($treeBefore) -join "`n") -eq (@($treeAfter) -join "`n"))) `
    "exit=$($n6.exit) stage=$stage6 first_build_unchanged=$((Get-Sha $recordFile) -eq $recordHashBefore)"

# ---------------------------------------------------------------- A: same-card SEALED root, Build and PublishOnly
# A synthetic but valid P1.3c-4 root that is already finished: same stage marker as an active root, plus the
# completion evidence a finished round leaves behind. Matching the stage alone must NOT be enough.
$sealedRoot = Join-Path $tmpArtifacts 'SEALED-P13c4'
New-Item -ItemType Directory -Path (Join-Path $sealedRoot 'build'),(Join-Path $sealedRoot 'variants/c200/classes/com/heima/article/support') -Force | Out-Null
$sealedManifest = [ordered]@{ run_root = $sealedRoot; stage = 'P1.3c-4 build gate first, then the delay candidates 200/500/1500 ms'; prepared_local = (Get-Date -Format 'o') }
[System.IO.File]::WriteAllText((Join-Path $sealedRoot 'build/prepare-manifest.json'), ($sealedManifest | ConvertTo-Json -Depth 4), $utf8)
[System.IO.File]::WriteAllText((Join-Path $sealedRoot 'run-manifest.json'), '{"run_id":"SEALED-P13c4"}', $utf8)
New-Item -ItemType Directory -Path (Join-Path $sealedRoot 'variants/c200/build') -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $sealedRoot 'variants/c200/build/variant.json'), '{"variant":"c200"}', $utf8)
[System.IO.File]::WriteAllText((Join-Path $sealedRoot 'variants/c200/classes/com/heima/article/support/DetailCacheInvalidator.class'), 'sealed-class', $utf8)
[System.IO.File]::WriteAllText((Join-Path $sealedRoot 'artifacts-sha256.tsv'), "sha256`tbytes`tpath`n", $utf8)
[System.IO.File]::WriteAllText((Join-Path $sealedRoot 'summary.json'), '{"stage":"sealed"}', $utf8)
[System.IO.File]::WriteAllText((Join-Path $sealedRoot 'logs-finished.txt'), "done`n", $utf8)
$sealedBefore = Get-TreeSnapshot $sealedRoot

# A1: Build against the sealed same-card root
$a1 = Invoke-Gate 'A1' @('-RunRoot', $sealedRoot, '-RunId', 'SEALED-P13c4', '-Variant', 'c500', '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot, '-JavacExe', $noJavac)
$stageA1 = Get-RefusedStage $a1.text
$sealedAfterA1 = Get-TreeSnapshot $sealedRoot
Add-Check 'gate.same_card_sealed_root_build_refused' ($a1.exit -eq 2 -and $stageA1 -eq 'sealed-completed' -and ((@($sealedBefore) -join "`n") -eq (@($sealedAfterA1) -join "`n"))) `
    "exit=$($a1.exit) stage=$stageA1 tree_unchanged=$((@($sealedBefore) -join "`n") -eq (@($sealedAfterA1) -join "`n")) c500_variant_created=$([bool](Test-Path -LiteralPath (Join-Path $sealedRoot 'variants/c500')))"

# A2: PublishOnly against the same sealed root (this is the path that used to exit 0 and add 13 classes)
$a2 = Invoke-Gate 'A2' @('-RunRoot', $sealedRoot, '-RunId', 'SEALED-P13c4', '-Variant', 'c200', '-PublishOnly', '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot, '-JavacExe', $noJavac)
$stageA2 = Get-RefusedStage $a2.text
$sealedAfterA2 = Get-TreeSnapshot $sealedRoot
Add-Check 'gate.same_card_sealed_root_publish_refused' ($a2.exit -eq 2 -and $stageA2 -eq 'sealed-completed' -and ((@($sealedBefore) -join "`n") -eq (@($sealedAfterA2) -join "`n")) -and -not (Test-Path -LiteralPath (Join-Path $sealedRoot 'build/run-classes-C200'))) `
    "exit=$($a2.exit) stage=$stageA2 tree_unchanged=$((@($sealedBefore) -join "`n") -eq (@($sealedAfterA2) -join "`n")) run_classes_created=$([bool](Test-Path -LiteralPath (Join-Path $sealedRoot 'build/run-classes-C200')))"

# A3: the REAL finished root of this card is read-only for PublishOnly too (its 424-entry manifest is present)
$realCardRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261103-P1.3c4-run-r01'
if (Test-Path -LiteralPath $realCardRoot) {
    $realCardBefore = Get-TreeSnapshot $realCardRoot
    $a3 = Invoke-Gate 'A3' @('-RunRoot', $realCardRoot, '-RunId', '20261103-P1.3c4-run-r01', '-Variant', 'c200', '-PublishOnly', '-ArtifactsRoot', $ArtifactsRoot, '-RepoRoot', $RepoRoot, '-JavacExe', $noJavac)
    $stageA3 = Get-RefusedStage $a3.text
    $realCardAfter = Get-TreeSnapshot $realCardRoot
    Add-Check 'gate.real_finished_card_root_refused' ($a3.exit -eq 2 -and $stageA3 -eq 'sealed-completed' -and ((@($realCardBefore) -join "`n") -eq (@($realCardAfter) -join "`n"))) `
        "exit=$($a3.exit) stage=$stageA3 tree_unchanged=$((@($realCardBefore) -join "`n") -eq (@($realCardAfter) -join "`n")) files=$(@($realCardBefore).Count)"
} else {
    Add-Check 'gate.real_finished_card_root_refused' $false "missing finished card root: $realCardRoot"
}

# A4: an ACTIVE (unsealed) root may still add a not-yet-built variant, and may publish it
$a4 = Invoke-Gate 'A4' @('-RunRoot', $t1, '-RunId', 'T-ONE', '-Variant', 'c500', '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot)
Add-Check 'gate.active_root_still_accepts_new_variant' ($a4.exit -eq 0 -and (Test-Path -LiteralPath (Join-Path $t1 'variants/c500/build/variant.json'))) `
    "exit=$($a4.exit) c500_built=$([bool](Test-Path -LiteralPath (Join-Path $t1 'variants/c500/build/variant.json'))) (an unsealed active root keeps working)"
$a5 = Invoke-Gate 'A5' @('-RunRoot', $t1, '-RunId', 'T-ONE', '-Variant', 'c500', '-PublishOnly', '-ArtifactsRoot', $tmpArtifacts, '-RepoRoot', $RepoRoot, '-JavacExe', $noJavac)
Add-Check 'gate.active_root_publish_still_works' ($a5.exit -eq 0 -and (Test-Path -LiteralPath (Join-Path $t1 'build/run-classes-C500/com/heima/article/support/DetailCacheInvalidator.class'))) `
    "exit=$($a5.exit) published=$([bool](Test-Path -LiteralPath (Join-Path $t1 'build/run-classes-C500')))"

# ---------------------------------------------------------------- aggregate invariants
$allRefusedBeforeCompile = $n2Ok
foreach ($pair in @(@('N3', $n3), @('N5', $n5), @('N6', $n6))) {
    if (-not ($preCompileStages -contains (Get-RefusedStage $pair[1].text))) { $allRefusedBeforeCompile = $false }
}
Add-Check 'gate.all_refusals_stop_before_compile' $allRefusedBeforeCompile `
    "every refusal names a stage that precedes 'compile' ($($preCompileStages -join ', ')); javac was pointed at a nonexistent path in all of them"
Add-Check 'gate.sentinel_untouched' ((@($sentinelBefore) -join "`n") -eq (@(Get-TreeSnapshot $sentinelDir) -join "`n")) `
    "private sentinel tree ($(@($sentinelBefore).Count) files) byte-identical after every refusal"
Add-Check 'gate.production_source_and_class_unchanged' `
    ((Get-Sha (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/support/DetailCacheInvalidator.java')) -eq '39fa53af3dab89fe9150cbc80fd6d2ef7a9b4e2f078eb524c0da7912b53939b1' -and $prodHash -eq '5bd778a4e2aeb14f57a4d1cc71de5ecf29d86e92990e6ede4ce500e00a1824f3') `
    "delivered source 39fa53af... and class 5bd778a4... untouched by any variant build"

Write-RunFileText -State $script:run -Path (Join-Path $outDir 'gate-invocations.log') -Text ((@($gateLog)) -join "`r`n")
$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    gate_sha256 = Get-Sha $gate
    prepare_sha256 = Get-Sha $prepare
    cases = [ordered]@{
        positive = [ordered]@{ exit = $r.exit; variant = 'c200'; record = $record }
        n1_missing_runroot = $n1.exit
        n2_empty_runroot = [ordered]@{ exit = $n2.exit; stage = (Get-RefusedStage $n2.text) }
        n3_old_card_root = [ordered]@{ exit = $n3.exit; stage = (Get-RefusedStage $n3.text) }
        n4_real_sealed_root = [ordered]@{ exit = $n4.exit; stage = (Get-RefusedStage $n4.text) }
        n5_output_outside = [ordered]@{ exit = $n5.exit; stage = (Get-RefusedStage $n5.text) }
        n6_duplicate_variant = [ordered]@{ exit = $n6.exit; stage = (Get-RefusedStage $n6.text) }
        a1_same_card_sealed_build = [ordered]@{ exit = $a1.exit; stage = (Get-RefusedStage $a1.text) }
        a2_same_card_sealed_publish = [ordered]@{ exit = $a2.exit; stage = (Get-RefusedStage $a2.text) }
        a3_real_finished_card_root = [ordered]@{ exit = $a3.exit; stage = (Get-RefusedStage $a3.text) }
        a4_active_root_new_variant = $a4.exit
        a5_active_root_publish = $a5.exit
    }
    production_invalidator_sha256 = (Get-Sha (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/support/DetailCacheInvalidator.java'))
    production_class_sha256 = $prodHash
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'gate-offline-result.json') -Text ($result | ConvertTo-Json -Depth 8)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'gate-offline-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
