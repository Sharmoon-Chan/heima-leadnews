# P1.3c-4 build gate: the ONE entry point that may compile an experiment variant (ASCII only).
#
# Why this exists: the earlier cards reused a scratch build script whose -RunRoot default still pointed at
# an already accepted run root, so a copy-with-lazy-substitution compiled into a sealed evidence root and
# wrote fresh logs there (TOOL-012). This gate closes that bypass:
#
#   * -RunRoot is MANDATORY and has NO default value. -RunId is mandatory as well and must equal the leaf.
#   * the root must be an existing NEW direct child of -ArtifactsRoot (created by prepare-p13c4-run.ps1),
#     carrying that prepare's build/prepare-manifest.json. The root may not be, or sit inside, any other
#     direct child of the artifacts root (those are read-only evidence roots).
#   * every writable output (source copy, classes, log, variant manifest) is normalized and must stay under
#     -RunRoot and outside every sealed root. Validation happens BEFORE any write and BEFORE javac.
#   * variants/<name> is created exactly once: an existing variant directory is a hard refusal (no -Force,
#     no delete-and-retry).
#   * the production source is never touched: its hash is captured before and re-checked after the variant
#     source is produced, and the variant is only allowed to change the second-delete delay constant.
#
# Exit codes: 0 = variant built, 2 = refused before any write/compile, 1 = compile or verification failed.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][ValidateSet('POST', 'c200', 'c500', 'c1500')][string]$Variant,
    # optional override for the writable output root; anything outside -RunRoot is refused, so the
    # offline "output outside the run root" case has a real surface to exercise.
    [string]$OutputRoot = '',
    # publish-only mode: no compile, just place an existing variant under build/run-classes-<NAME>
    [switch]$PublishOnly,
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$HarnessSrc = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261101-P1.3b-rework/harness/src',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$JavacExe = 'D:\Soft\Java\jdk-1.8\bin\javac.exe',
    # frozen identity of the production invalidator this round starts from
    [string]$ExpectedSourceSha256 = '39fa53af3dab89fe9150cbc80fd6d2ef7a9b4e2f078eb524c0da7912b53939b1',
    # where the delay candidates come from: the delivered constant
    [string]$DelayConstantPattern = 'SECOND_DELETE_DELAY_MILLIS = 500L',
    [long]$ProductionDelayMs = 500
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
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
function Get-Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
function Refuse([string]$msg) {
    Write-Host "REFUSED: $msg"
    Write-Host "REFUSED_STAGE=$script:stage"
    exit 2
}

$script:stage = 'parameters'
if ([string]::IsNullOrWhiteSpace($RunRoot)) { Refuse 'RunRoot is required (this gate has no default)' }
if ([string]::IsNullOrWhiteSpace($RunId)) { Refuse 'RunId is required' }

$fullRoot = Get-Normalized $RunRoot
$leaf = Split-Path -Path $RunRoot -Leaf
if ($leaf -ne $RunId) { Refuse "RunId '$RunId' does not match the run root leaf '$leaf'" }
if ((Split-Path -Path $fullRoot -Parent) -ne (Get-Normalized $ArtifactsRoot)) {
    Refuse "run root must be a direct child of $ArtifactsRoot"
}
if (-not (Test-Path -LiteralPath $RunRoot)) { Refuse "run root does not exist: $RunRoot (prepare it first)" }

# ---- sealed roots = every OTHER direct child of the artifacts root
$script:stage = 'sealed-roots'
$others = @(Get-ChildItem -LiteralPath $ArtifactsRoot -Directory |
    Where-Object { (Get-Normalized $_.FullName) -ne $fullRoot } |
    ForEach-Object { $_.FullName })
foreach ($s in $others) {
    if (Test-UnderRoot $RunRoot $s) { Refuse "run root sits inside a read-only evidence root: $s" }
}

# ---- the root must carry this card's prepare manifest, and the sealed set must not have grown over it
$script:stage = 'prepare-manifest'
$prepManifest = Join-Path $RunRoot 'build/prepare-manifest.json'
if (-not (Test-Path -LiteralPath $prepManifest)) { Refuse "missing build/prepare-manifest.json in $RunRoot" }
$prep = Get-Content -LiteralPath $prepManifest -Raw | ConvertFrom-Json
if ((Get-Normalized $prep.run_root) -ne $fullRoot) { Refuse "prepare manifest was written for a different root: $($prep.run_root)" }
if (-not (Test-Path -LiteralPath (Join-Path $RunRoot 'run-manifest.json'))) { Refuse 'missing run-manifest.json (guard) in the run root' }
# the root must have been prepared FOR THIS CARD: an older card's root (already accepted, sealed) has a
# prepare manifest too, so the stage marker is what keeps this gate from writing into it (TOOL-012).
if ("$($prep.stage)" -notlike 'P1.3c-4*') {
    Refuse "run root was prepared for '$($prep.stage)', not for P1.3c-4"
}

# ---- A: a SEALED / COMPLETED root is refused, for BOTH Build and PublishOnly, before any copy,
# directory creation, javac or publish. Matching the stage alone is not enough: a finished P1.3c-4 root
# carries the same stage marker, so the completion markers below are what keep the gate out of it.
$script:stage = 'sealed-completed'
$sealedMarkers = @('artifacts-sha256.tsv', 'summary.json', 'COMPLETE')
foreach ($m in $sealedMarkers) {
    $p = Join-Path $RunRoot $m
    if (Test-Path -LiteralPath $p) {
        Refuse "run root is already sealed/completed ('$m' present); a finished root is read-only: $RunRoot"
    }
}
# a root that already holds another variant's build output is not an active empty root either
# NOTE: an ACTIVE root may hold several variants (that is how one round builds c200/c500/c1500 side by side);
# only a finished root is refused, and each individual variant directory stays write-once.

# ---- writable output root: defaults to the run root, may never point outside it
$script:stage = 'output-root'
$outRoot = $RunRoot
if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
    if (-not (Test-UnderRoot $OutputRoot $RunRoot)) {
        Refuse "output root is outside the run root: $OutputRoot"
    }
    $outRoot = $OutputRoot
}

# ---- publish-only: copy an already built variant into build/run-classes-<NAME> (write-once, no compile)
if ($PublishOnly) {
    $published = Join-Path $RunRoot ('build/run-classes-' + $Variant.ToUpperInvariant())
    $source = Join-Path $RunRoot ('variants/' + $Variant + '/classes')
    if (-not (Test-Path -LiteralPath (Join-Path $RunRoot ('variants/' + $Variant + '/build/variant.json')))) {
        Refuse "publish-only needs a built variant: $source"
    }
    if (-not (Test-Path -LiteralPath $source)) { Refuse "variant classes are missing: $source" }
    if (Test-Path -LiteralPath $published) { Refuse "run-classes directory already published (write-once): $published" }
    if (-not (Test-UnderRoot $published $RunRoot)) { Refuse "publish target escapes the run root: $published" }
    foreach ($s in $others) { if (Test-UnderRoot $published $s) { Refuse "publish target lands in a sealed root: $published" } }
    New-Item -ItemType Directory -Path $published | Out-Null
    Copy-Item (Join-Path $source '*') $published -Recurse -Force
    Write-Host "published=$published source=$source"
    exit 0
}
# ---- the variant directory is write-once
$script:stage = 'variant-dir'
$variantDir = Join-Path $outRoot ('variants/' + $Variant)
if (Test-Path -LiteralPath $variantDir) { Refuse "variant already exists (write-once, no reuse): $variantDir" }

# ---- every writable path must stay under the root and outside the sealed roots
$script:stage = 'writable-paths'
$srcDst = Join-Path $variantDir 'src/com/heima/article/support'
$clsDst = Join-Path $variantDir 'classes'
$logFile = Join-Path $variantDir 'build/javac.log'
foreach ($p in @($variantDir, $srcDst, $clsDst, $logFile)) {
    if (-not (Test-UnderRoot $p $RunRoot)) { Refuse "writable path escapes the run root: $p" }
    foreach ($s in $others) { if (Test-UnderRoot $p $s) { Refuse "writable path lands in a sealed root: $p" } }
}

# ---- frozen inputs
$script:stage = 'inputs'
$prodSrc = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/support/DetailCacheInvalidator.java'
$implDir = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl'
$prodImpl = Join-Path $implDir 'ApArticleServiceImpl.java'
$prodHead = Join-Path $implDir 'ArticleFreemarkerServiceImpl.java'
foreach ($f in @($prodSrc, $prodImpl, $prodHead, $HarnessSrc)) {
    if (-not (Test-Path -LiteralPath $f)) { Refuse "missing input: $f" }
}
$prodShaBefore = Get-Sha $prodSrc
if ($prodShaBefore -ne $ExpectedSourceSha256) {
    Refuse "production invalidator hash $prodShaBefore is not the frozen $ExpectedSourceSha256"
}

$delayMs = $ProductionDelayMs
if ($Variant -ne 'POST') { $delayMs = [long](($Variant -replace '^c', '')) }
if ($Variant -ne 'POST' -and $delayMs -notin @(200, 500, 1500)) { Refuse "unsupported candidate delay: $delayMs" }

# ---- write the variant source (POSIX newline preserved), then prove the production file is untouched
$script:stage = 'source-copy'
$prodText = [System.IO.File]::ReadAllText($prodSrc)
if ($prodText -notmatch [regex]::Escape($DelayConstantPattern)) {
    Refuse "delay constant '$DelayConstantPattern' not found in the production source"
}
$variantText = $prodText
if ($Variant -ne 'POST') {
    $replacement = 'SECOND_DELETE_DELAY_MILLIS = ' + $delayMs + 'L'
    $variantText = $prodText.Replace($DelayConstantPattern, $replacement)
    if ($variantText -eq $prodText -and $delayMs -ne $ProductionDelayMs) {
        Refuse 'variant source identical to production even though the candidate differs (replacement did not apply)'
    }
    if ($variantText -notmatch [regex]::Escape($replacement)) { Refuse 'variant source missing the candidate constant' }
}
$variantDiffers = ($variantText -ne $prodText)
$prodShaAfterCopy = Get-Sha $prodSrc
if ($prodShaAfterCopy -ne $prodShaBefore) { Refuse 'production source changed while producing the variant source' }

New-Item -ItemType Directory -Path $srcDst, $clsDst, (Join-Path $variantDir 'build') | Out-Null
$variantSrc = Join-Path $srcDst 'DetailCacheInvalidator.java'
[System.IO.File]::WriteAllText($variantSrc, $variantText, $utf8)
if (-not (Test-UnderRoot $variantSrc $RunRoot)) { Refuse "variant source escaped the run root: $variantSrc" }

# ---- compile: dependencies resolved from read-only inputs, ALL output inside the variant directory
$script:stage = 'compile'
$jars = @(Get-ChildItem -LiteralPath $LibDir -Filter *.jar | ForEach-Object { $_.FullName })
$depCp = (@(
        (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-common/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-model/target/classes')
    ) + $jars) -join ';'
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $JavacExe '-encoding' 'UTF-8' '-nowarn' '-g' '-parameters' '-cp' $depCp '-d' $clsDst @($variantSrc, $prodImpl, $prodHead) 1> $logFile 2> ($logFile + '.err')
$code = $LASTEXITCODE
$ErrorActionPreference = $savedEap
if ($code -ne 0) {
    Get-Content -LiteralPath $logFile, ($logFile + '.err') -ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object { Write-Host $_ }
    Write-Host "BUILD FAILED: javac exit=$code"
    exit 1
}

# harness classes ride along so ONE classpath entry covers both
$script:stage = 'harness'
Copy-Item (Join-Path $HarnessSrc '*') (Join-Path $variantDir 'harness-src') -Recurse -Force -ErrorAction SilentlyContinue
$harnessDst = Join-Path $variantDir 'harness-classes'
New-Item -ItemType Directory -Path $harnessDst | Out-Null
$harnessSources = @(Get-ChildItem -LiteralPath $HarnessSrc -Recurse -Filter *.java | ForEach-Object { $_.FullName })
$ErrorActionPreference = 'Continue'
& $JavacExe '-encoding' 'UTF-8' '-nowarn' '-cp' $depCp '-d' $harnessDst $harnessSources 1> ($logFile + '.harness') 2> ($logFile + '.harness.err')
$hcode = $LASTEXITCODE
$ErrorActionPreference = $savedEap
if ($hcode -ne 0) { Write-Host "BUILD FAILED: harness javac exit=$hcode"; exit 1 }
Copy-Item (Join-Path $harnessDst '*') $clsDst -Recurse -Force

$script:stage = 'verify'
$need = @('com/heima/article/support/DetailCacheInvalidator.class',
          'com/heima/article/service/impl/ApArticleServiceImpl.class',
          'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class',
          'com/heima/article/p13b/P13bHarnessConfig.class',
          'com/heima/article/p13b/P13bHarnessController.class')
$hashes = [ordered]@{}
foreach ($rel in $need) {
    $full = Join-Path $clsDst $rel
    if (-not (Test-Path -LiteralPath $full)) { Refuse "variant is missing $rel" }
    if (-not (Test-UnderRoot $full $RunRoot)) { Refuse "compiled class escaped the run root: $full" }
    $hashes[$rel] = Get-Sha $full
}
# the two business classes must still be the delivered ones, byte for byte
$target = Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'
foreach ($rel in @('com/heima/article/service/impl/ApArticleServiceImpl.class',
                   'com/heima/article/service/impl/ArticleFreemarkerServiceImpl.class')) {
    $same = (Get-Sha (Join-Path $target $rel)) -eq $hashes[$rel]
    if (-not $same) { Refuse "variant $rel is not byte-identical to target/classes" }
}
# and the production source must be exactly what the gate read
if ((Get-Sha $prodSrc) -ne $ExpectedSourceSha256) { Refuse 'production source changed during the build' }

$record = [ordered]@{
    variant = $Variant
    delay_ms = $delayMs
    production_delay_ms = $ProductionDelayMs
    run_root = $RunRoot
    run_id = $RunId
    built_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    production_source_sha256 = $ExpectedSourceSha256
    variant_source_sha256 = (Get-Sha $variantSrc)
    variant_source_differs = $variantDiffers
    delay_constant = ('SECOND_DELETE_DELAY_MILLIS = ' + $delayMs + 'L')
    class_sha256 = $hashes
    javac = [ordered]@{ exit = $code; log = 'build/javac.log'; log_sha256 = (Get-Sha $logFile); harness_exit = $hcode }
    classes_dir = $clsDst
    note = 'write-once variant; the production source and target/classes were never overwritten'
}
$recordFile = Join-Path $variantDir 'build/variant.json'
[System.IO.File]::WriteAllText($recordFile, ($record | ConvertTo-Json -Depth 6), $utf8)

Write-Host "variant=$Variant delay_ms=$delayMs classes=$clsDst"
Write-Host "invalidator_class=$($hashes['com/heima/article/support/DetailCacheInvalidator.class']) source=$($record.variant_source_sha256)"
Write-Host "record=variants/$Variant/build/variant.json"
exit 0
