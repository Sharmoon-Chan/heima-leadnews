# Freeze the START state of the P1.3b A-D rework, BEFORE any edit of this round (ASCII only).
#
# Why a separate step: the A-D rework changes one business file (ArticleFreemarkerServiceImpl) and the
# experiment harness. If the start snapshot were taken by the run-root preparation script, it would
# already contain the edited files and the diff could not be audited. So this script runs first, writes
# a brand-new directory, copies the 19 source files, the 60 benchmark files and the harness sources,
# and records hashes plus the git state.
#
# Exit codes: 0 = frozen, 2 = directory already exists (refuse to reuse), 1 = verification failed.
param(
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [Parameter(Mandatory = $true)][string]$SnapshotDir,
    [Parameter(Mandatory = $true)][string]$FrozenReviewRoot,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$HarnessSrc = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261031-P1.3b/harness/src',
    # the reviewer's frozen copy of the 19 source files as they were BEFORE the A-D rework
    [string]$SourceReferenceDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261101-P1.3b-REVIEW/source-before-review',
    # reference copy of the 60 benchmark files as the reviewer froze them; when given, the start list is
    # exactly those 60, so scripts added DURING this round are not silently counted as the start state
    [string]$BenchmarksReferenceDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261101-P1.3b-REVIEW/audit-r02/benchmarks-before-review/benchmarks',
    # the file this round modifies, in addition to the 18 frozen P1.3a sources
    [string]$ExtraSource = 'heima-leadnews-service/heima-leadnews-article/src/main/java/com/heima/article/service/impl/ArticleFreemarkerServiceImpl.java'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Get-Sha([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
    return ''
}

if (Test-Path -LiteralPath $SnapshotDir) {
    Write-Host "REFUSED: snapshot directory already exists: $SnapshotDir"
    exit 2
}
$frozenCsv = Join-Path $FrozenReviewRoot 'source-hashes-after-P1.3a-round4.csv'
$benchCsv = Join-Path $FrozenReviewRoot 'benchmarks-hashes-after-P1.3a-round4.csv'
foreach ($f in @($frozenCsv, $benchCsv, $HarnessSrc)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "REFUSED: missing input: $f"; exit 2 }
}

New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null
$srcDst = Join-Path $SnapshotDir 'source-copies-start'
$benchDst = Join-Path $SnapshotDir 'benchmarks-copies-start'
$harnessDst = Join-Path $SnapshotDir 'harness-copies-start'
New-Item -ItemType Directory -Force -Path $srcDst, $benchDst, $harnessDst | Out-Null

# ---- 1. the 19 source files: the reviewer already froze this exact set before the rework ----
$sourcePaths = @(Get-ChildItem $SourceReferenceDir -Recurse -File | ForEach-Object {
    $_.FullName.Substring($SourceReferenceDir.Length + 1) -replace '\\', '/' })
if ($sourcePaths.Count -ne 19) { Write-Host "REFUSED: expected 19 start sources, got $($sourcePaths.Count)"; exit 2 }
$startMismatch = @()
foreach ($rel in $sourcePaths) {
    $ref = Join-Path $SourceReferenceDir ($rel -replace '/', '\')
    $full = Join-Path $RepoRoot ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { Write-Host "REFUSED: missing source: $full"; exit 2 }
    if ((Get-Sha $ref) -ne (Get-Sha $full)) {
        $startMismatch += "$rel ref=$((Get-Sha $ref)) now=$((Get-Sha $full))"
    }
}
if ($startMismatch.Count -gt 0) {
    Write-Host 'VERIFY FAILED: the working tree no longer matches the reviewer frozen start copies:'
    $startMismatch | ForEach-Object { Write-Host "  $_" }
    Remove-Item -LiteralPath $SnapshotDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
$srcRows = @()
foreach ($rel in $sourcePaths) {
    $full = Join-Path $RepoRoot ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { Write-Host "REFUSED: missing source: $full"; exit 2 }
    $dst = Join-Path $srcDst ($rel -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $full -Destination $dst -Force
    $srcRows += [pscustomobject]@{ relative_path = $rel; sha256 = (Get-Sha $full); bytes = (Get-Item $full).Length }
}
$srcCsv = Join-Path $SnapshotDir 'source-hashes-at-start.csv'
[System.IO.File]::WriteAllText($srcCsv, ((@('relative_path,sha256,bytes') + @($srcRows | ForEach-Object { "$($_.relative_path),$($_.sha256),$($_.bytes)" })) -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# ---- 2. the 60 benchmark files ----
$benchBase = Join-Path $RepoRoot 'benchmarks'
if ($BenchmarksReferenceDir -ne '' -and (Test-Path -LiteralPath $BenchmarksReferenceDir)) {
    $benchRel = @(Get-ChildItem $BenchmarksReferenceDir -Recurse -File | ForEach-Object {
        $_.FullName.Substring($BenchmarksReferenceDir.Length + 1) -replace '\\', '/' })
    Write-Host "start benchmark list taken from the reviewer frozen copy: $($benchRel.Count) files"
} else {
    $benchRel = @(Get-ChildItem $benchBase -Recurse -File | ForEach-Object {
        $_.FullName.Substring($benchBase.Length + 1) -replace '\\', '/' })
}
if ($benchRel.Count -ne 60) { Write-Host "REFUSED: expected 60 start benchmarks, got $($benchRel.Count)"; exit 2 }
$benchRows = @()
foreach ($rel in ($benchRel | Sort-Object)) {
    $full = Join-Path (Join-Path $RepoRoot 'benchmarks') ($rel -replace '/', '\')
    $dst = Join-Path $benchDst ($rel -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $full -Destination $dst -Force
    $benchRows += [pscustomobject]@{ relative_path = "benchmarks/$rel"; sha256 = (Get-Sha $full); bytes = (Get-Item $full).Length }
}
$benchCsvOut = Join-Path $SnapshotDir 'benchmarks-hashes-at-start.csv'
[System.IO.File]::WriteAllText($benchCsvOut, ((@('relative_path,sha256,bytes') + @($benchRows | ForEach-Object { "$($_.relative_path),$($_.sha256),$($_.bytes)" })) -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# ---- 3. harness sources as they are at the start of this round ----
$harnessRows = @()
foreach ($f in (Get-ChildItem $HarnessSrc -Recurse -File)) {
    $rel = $f.FullName.Substring($HarnessSrc.Length + 1)
    $dst = Join-Path $harnessDst $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    $harnessRows += [pscustomobject]@{ relative_path = $rel; sha256 = (Get-Sha $f.FullName); bytes = $f.Length }
}
$harnessCsv = Join-Path $SnapshotDir 'harness-hashes-at-start.csv'
[System.IO.File]::WriteAllText($harnessCsv, ((@('relative_path,sha256,bytes') + @($harnessRows | ForEach-Object { "$($_.relative_path),$($_.sha256),$($_.bytes)" })) -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$gitHead = (& git -C $RepoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
$gitStat = (& git -C $RepoRoot diff --stat 2>&1 | Out-String).Trim()
$gitStatus = (& git -C $RepoRoot status --porcelain 2>&1 | Out-String).Trim()
$ErrorActionPreference = $prevEap
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'git-diff-stat.txt'), $gitStat, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'git-status-porcelain.txt'), $gitStatus, (New-Object System.Text.UTF8Encoding($false)))

$summary = [ordered]@{
    snapshot_dir = $SnapshotDir
    taken_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    repo_root = $RepoRoot
    git_head = $gitHead
    source_count = $srcRows.Count
    benchmark_count = $benchRows.Count
    harness_count = $harnessRows.Count
    frozen_review_source_csv = $frozenCsv
    frozen_review_source_csv_sha256 = (Get-Sha $frozenCsv)
    note = 'copied BEFORE any edit of this round; the 18 frozen P1.3a sources must still match their frozen hashes'
}
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'start-snapshot.json'), ($summary | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

# ---- 5. verify the copies byte-for-byte and the 18 frozen hashes ----
$bad = 0
foreach ($r in $srcRows) {
    $copy = Join-Path $srcDst ($r.relative_path -replace '/', '\')
    if ((Get-Sha $copy) -ne $r.sha256) { $bad++; Write-Host "MISMATCH copy: $($r.relative_path)" }
}
foreach ($r in $benchRows) {
    $copy = Join-Path $benchDst (($r.relative_path -replace '^benchmarks/', '') -replace '/', '\')
    if ((Get-Sha $copy) -ne $r.sha256) { $bad++; Write-Host "MISMATCH copy: $($r.relative_path)" }
}
if ($bad -gt 0) { Write-Host "VERIFY FAILED: $bad copy mismatches"; exit 1 }
Write-Host "snapshot=$SnapshotDir sources=$($srcRows.Count) benchmarks=$($benchRows.Count) harness=$($harnessRows.Count) reviewer-reference=match copies=match"
exit 0
exit 0
