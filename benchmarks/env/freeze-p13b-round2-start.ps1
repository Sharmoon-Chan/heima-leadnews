# Freeze the START state of the P1.3b round-2 remaining rework (ASCII only).
#
# Round 2 touches only experiment scripts (no business source change is expected). This snapshot is
# taken BEFORE any edit so the diff can be audited: 19 source files, the current benchmark files and the
# harness sources actually compiled, plus the git state and a diff against the round-1 start snapshot.
#
# Exit codes: 0 = frozen, 2 = target directory already exists / missing input, 1 = verification failed.
param(
    [Parameter(Mandatory = $true)][string]$SnapshotDir,
    [Parameter(Mandatory = $true)][string]$FrozenReviewRoot,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$HarnessSrc = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261101-P1.3b-rework/harness/src',
    [string]$SourceListCsv = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261101-P1.3b-rework-START/source-hashes-at-start.csv',
    [string]$PreviousSnapshot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261101-P1.3b-rework-START',
    [int]$ExpectedBenchmarks = 67
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
foreach ($f in @($FrozenReviewRoot, $HarnessSrc, $SourceListCsv)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "REFUSED: missing input: $f"; exit 2 }
}

New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null
$srcDst = Join-Path $SnapshotDir 'source-copies-start'
$benchDst = Join-Path $SnapshotDir 'benchmarks-copies-start'
$harnessDst = Join-Path $SnapshotDir 'harness-copies-start'
New-Item -ItemType Directory -Force -Path $srcDst, $benchDst, $harnessDst | Out-Null

# ---- 1. the same 19 source files as round 1 ----
$sourcePaths = @(Get-Content $SourceListCsv | Select-Object -Skip 1 | ForEach-Object { ($_ -split ',')[0] })
if ($sourcePaths.Count -ne 19) { Write-Host "REFUSED: expected 19 source paths, got $($sourcePaths.Count)"; exit 2 }
$srcRows = @()
foreach ($rel in $sourcePaths) {
    $full = Join-Path $RepoRoot ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { Write-Host "REFUSED: missing source: $full"; exit 2 }
    $dst = Join-Path $srcDst ($rel -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $full -Destination $dst -Force
    $srcRows += [pscustomobject]@{ relative_path = $rel; sha256 = (Get-Sha $full); bytes = (Get-Item $full).Length }
}
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'source-hashes-at-start.csv'),
    ((@('relative_path,sha256,bytes') + @($srcRows | ForEach-Object { "$($_.relative_path),$($_.sha256),$($_.bytes)" })) -join "`r`n"),
    (New-Object System.Text.UTF8Encoding($false)))

# ---- 2. every benchmark file currently in the tree ----
$benchBase = Join-Path $RepoRoot 'benchmarks'
$benchRel = @(Get-ChildItem $benchBase -Recurse -File | ForEach-Object { $_.FullName.Substring($benchBase.Length + 1) -replace '\\', '/' })
if ($benchRel.Count -ne $ExpectedBenchmarks) {
    Write-Host "REFUSED: expected $ExpectedBenchmarks benchmark files, got $($benchRel.Count)"
    exit 2
}
$benchRows = @()
foreach ($rel in ($benchRel | Sort-Object)) {
    $full = Join-Path $benchBase ($rel -replace '/', '\')
    $dst = Join-Path $benchDst ($rel -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $full -Destination $dst -Force
    $benchRows += [pscustomobject]@{ relative_path = "benchmarks/$rel"; sha256 = (Get-Sha $full); bytes = (Get-Item $full).Length }
}
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'benchmarks-hashes-at-start.csv'),
    ((@('relative_path,sha256,bytes') + @($benchRows | ForEach-Object { "$($_.relative_path),$($_.sha256),$($_.bytes)" })) -join "`r`n"),
    (New-Object System.Text.UTF8Encoding($false)))

# ---- 3. harness sources actually compiled ----
$harnessRows = @()
foreach ($f in (Get-ChildItem $HarnessSrc -Recurse -File)) {
    $rel = $f.FullName.Substring($HarnessSrc.Length + 1)
    $dst = Join-Path $harnessDst $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    $harnessRows += [pscustomobject]@{ relative_path = $rel; sha256 = (Get-Sha $f.FullName); bytes = $f.Length }
}
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'harness-hashes-at-start.csv'),
    ((@('relative_path,sha256,bytes') + @($harnessRows | ForEach-Object { "$($_.relative_path),$($_.sha256),$($_.bytes)" })) -join "`r`n"),
    (New-Object System.Text.UTF8Encoding($false)))

# ---- 4. what changed since the round-1 start snapshot (informational) ----
$changed = @()
$prevBenchCsv = Join-Path $PreviousSnapshot 'benchmarks-hashes-at-start.csv'
if (Test-Path -LiteralPath $prevBenchCsv) {
    $prev = @{}
    foreach ($line in (Get-Content $prevBenchCsv | Select-Object -Skip 1)) {
        $p = $line -split ','
        $prev[$p[0]] = $p[1]
    }
    foreach ($r in $benchRows) {
        if (-not $prev.ContainsKey($r.relative_path)) { $changed += "added`t$($r.relative_path)" }
        elseif ($prev[$r.relative_path] -ne $r.sha256) { $changed += "modified`t$($r.relative_path)" }
    }
    foreach ($k in $prev.Keys) {
        if (-not ($benchRows | Where-Object { $_.relative_path -eq $k })) { $changed += "removed`t$k" }
    }
}
$prevSrcCsv = Join-Path $PreviousSnapshot 'source-hashes-at-start.csv'
if (Test-Path -LiteralPath $prevSrcCsv) {
    $prevSrc = @{}
    foreach ($line in (Get-Content $prevSrcCsv | Select-Object -Skip 1)) {
        $p = $line -split ','
        $prevSrc[$p[0]] = $p[1]
    }
    foreach ($r in $srcRows) {
        if ($prevSrc.ContainsKey($r.relative_path) -and $prevSrc[$r.relative_path] -ne $r.sha256) {
            $changed += "source-modified`t$($r.relative_path)"
        }
    }
}
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'diff-vs-round1-start.txt'), ((@($changed)) -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# ---- 5. git state ----
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$gitHead = (& git -C $RepoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
$gitStat = (& git -C $RepoRoot diff --stat 2>&1 | Out-String).Trim()
$gitStatus = (& git -C $RepoRoot status --porcelain 2>&1 | Out-String).Trim()
$ErrorActionPreference = $prevEap
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'git-head.txt'), $gitHead, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'git-diff-stat.txt'), $gitStat, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'git-status-porcelain.txt'), $gitStatus, (New-Object System.Text.UTF8Encoding($false)))

$summary = [ordered]@{
    snapshot_dir = $SnapshotDir
    taken_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    repo_root = $RepoRoot
    git_head = $gitHead
    git_diff_stat = $gitStat
    source_count = $srcRows.Count
    benchmark_count = $benchRows.Count
    harness_count = $harnessRows.Count
    changes_vs_round1_start = @($changed)
    note = 'copied BEFORE any edit of round 2; business sources are expected to be unchanged from round 1'
}
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'start-snapshot.json'), ($summary | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

# ---- 6. verify copies ----
$bad = 0
foreach ($r in $srcRows) {
    $copy = Join-Path $srcDst ($r.relative_path -replace '/', '\')
    if ((Get-Sha $copy) -ne $r.sha256) { $bad++; Write-Host "MISMATCH copy: $($r.relative_path)" }
}
foreach ($r in $benchRows) {
    $copy = Join-Path $benchDst ($r.relative_path -replace '^benchmarks/', '' -replace '/', '\')
    if ((Get-Sha $copy) -ne $r.sha256) { $bad++; Write-Host "MISMATCH copy: $($r.relative_path)" }
}
foreach ($r in $harnessRows) {
    $copy = Join-Path $harnessDst ($r.relative_path -replace '/', '\')
    if ((Get-Sha $copy) -ne $r.sha256) { $bad++; Write-Host "MISMATCH copy: $($r.relative_path)" }
}
if ($bad -gt 0) { Write-Host "VERIFY FAILED: $bad copy mismatches"; exit 1 }
Write-Host "snapshot=$SnapshotDir sources=$($srcRows.Count) benchmarks=$($benchRows.Count) harness=$($harnessRows.Count) changes_vs_round1=$(@($changed).Count) copies=match"
exit 0
