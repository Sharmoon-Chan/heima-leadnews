# Freeze the START state of P1.3c-1 (delayed-task lifecycle and completion accounting), ASCII only.
#
# Taken BEFORE any edit of this round: the same 19 source files used by earlier rounds, every benchmark
# file currently in the tree, the harness sources actually compiled, the git state, and a diff against
# the P1.3b round-2 start snapshot so the audit can name exactly what changed.
#
# Exit codes: 0 = frozen, 2 = target directory exists / missing input / unexpected count, 1 = copy mismatch.
param(
    [Parameter(Mandatory = $true)][string]$SnapshotDir,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$HarnessSrc = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261101-P1.3b-rework/harness/src',
    [string]$SourceListCsv = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261103-P1.3b-round2-START/source-hashes-at-start.csv',
    [string]$PreviousSnapshot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261103-P1.3b-round2-START',
    # 74 files existed before this card; this freeze entry point itself is the 75th and is included
    [int]$ExpectedBenchmarks = 75,
    [int]$ExpectedSources = 19
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-Sha([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
    return ''
}

if (Test-Path -LiteralPath $SnapshotDir) {
    Write-Host "REFUSED: snapshot directory already exists: $SnapshotDir"
    exit 2
}
foreach ($f in @($HarnessSrc, $SourceListCsv)) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Host "REFUSED: missing input: $f"; exit 2 }
}

New-Item -ItemType Directory -Path $SnapshotDir | Out-Null
$srcDst = Join-Path $SnapshotDir 'source-copies-start'
$benchDst = Join-Path $SnapshotDir 'benchmarks-copies-start'
$harnessDst = Join-Path $SnapshotDir 'harness-copies-start'
New-Item -ItemType Directory -Path $srcDst, $benchDst, $harnessDst | Out-Null

# ---- 1. the same source list used by every earlier round (read-only reference set)
$sourcePaths = @(Get-Content $SourceListCsv | Select-Object -Skip 1 | ForEach-Object { ($_ -split ',')[0] })
if ($sourcePaths.Count -ne $ExpectedSources) {
    Write-Host "REFUSED: expected $ExpectedSources source paths, got $($sourcePaths.Count)"; exit 2
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
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'source-hashes-at-start.csv'),
    ((@('relative_path,sha256,bytes') + @($srcRows | ForEach-Object { "$($_.relative_path),$($_.sha256),$($_.bytes)" })) -join "`r`n"), $utf8)

# ---- 2. every benchmark file currently in the tree
$benchBase = Join-Path $RepoRoot 'benchmarks'
$benchRel = @(Get-ChildItem $benchBase -Recurse -File | ForEach-Object { $_.FullName.Substring($benchBase.Length + 1) -replace '\\', '/' })
if ($benchRel.Count -ne $ExpectedBenchmarks) {
    Write-Host "REFUSED: expected $ExpectedBenchmarks benchmark files, got $($benchRel.Count)"; exit 2
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
    ((@('relative_path,sha256,bytes') + @($benchRows | ForEach-Object { "$($_.relative_path),$($_.sha256),$($_.bytes)" })) -join "`r`n"), $utf8)

# ---- 3. harness sources actually compiled
$harnessRows = @()
foreach ($f in (Get-ChildItem $HarnessSrc -Recurse -File)) {
    $rel = $f.FullName.Substring($HarnessSrc.Length + 1)
    $dst = Join-Path $harnessDst $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    $harnessRows += [pscustomobject]@{ relative_path = $rel; sha256 = (Get-Sha $f.FullName); bytes = $f.Length }
}
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'harness-hashes-at-start.csv'),
    ((@('relative_path,sha256,bytes') + @($harnessRows | ForEach-Object { "$($_.relative_path),$($_.sha256),$($_.bytes)" })) -join "`r`n"), $utf8)

# ---- 4. what differs from the previous start snapshot (informational, no judgement)
$changed = @()
$prevBenchCsv = Join-Path $PreviousSnapshot 'benchmarks-hashes-at-start.csv'
if (Test-Path -LiteralPath $prevBenchCsv) {
    $prev = @{}
    foreach ($line in (Get-Content $prevBenchCsv | Select-Object -Skip 1)) { $p = $line -split ','; $prev[$p[0]] = $p[1] }
    foreach ($r in $benchRows) {
        if (-not $prev.ContainsKey($r.relative_path)) { $changed += "added`t$($r.relative_path)" }
        elseif ($prev[$r.relative_path] -ne $r.sha256) { $changed += "modified`t$($r.relative_path)" }
    }
    foreach ($k in $prev.Keys) { if (-not ($benchRows | Where-Object { $_.relative_path -eq $k })) { $changed += "removed`t$k" } }
}
$prevSrcCsv = Join-Path $PreviousSnapshot 'source-hashes-at-start.csv'
if (Test-Path -LiteralPath $prevSrcCsv) {
    $prevSrc = @{}
    foreach ($line in (Get-Content $prevSrcCsv | Select-Object -Skip 1)) { $p = $line -split ','; $prevSrc[$p[0]] = $p[1] }
    foreach ($r in $srcRows) {
        if ($prevSrc.ContainsKey($r.relative_path) -and $prevSrc[$r.relative_path] -ne $r.sha256) {
            $changed += "source-modified`t$($r.relative_path)"
        }
    }
}
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'diff-vs-p13b-round2-start.txt'), ((@($changed)) -join "`r`n"), $utf8)

# ---- 5. git state
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$gitHead = (& git -C $RepoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
$gitStat = (& git -C $RepoRoot diff --stat 2>&1 | Out-String).Trim()
$gitStatus = (& git -C $RepoRoot status --porcelain 2>&1 | Out-String).Trim()
$ErrorActionPreference = $prevEap
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'git-head.txt'), $gitHead, $utf8)
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'git-diff-stat.txt'), $gitStat, $utf8)
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'git-status-porcelain.txt'), $gitStatus, $utf8)

$summary = [ordered]@{
    snapshot_dir = $SnapshotDir
    taken_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    repo_root = $RepoRoot
    git_head = $gitHead
    source_count = $srcRows.Count
    benchmark_count = $benchRows.Count
    harness_count = $harnessRows.Count
    changes_vs_previous_start = @($changed)
    note = 'copied BEFORE any P1.3c-1 edit; the run root and every writable path must stay outside the sealed roots'
}
[System.IO.File]::WriteAllText((Join-Path $SnapshotDir 'start-snapshot.json'), ($summary | ConvertTo-Json -Depth 5), $utf8)

# ---- 6. verify the copies
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
Write-Host "snapshot=$SnapshotDir sources=$($srcRows.Count) benchmarks=$($benchRows.Count) harness=$($harnessRows.Count) changes_vs_previous=$(@($changed).Count) copies=match"
exit 0
