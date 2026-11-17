# Prepare the P1.3c-3 experiment root: the backfill window beyond the fixed 500 ms second delete (ASCII only).
#
# Contract:
#   * -RunRoot must be a NEW direct child of -ArtifactsRoot; the last segment is the run id.
#   * every directory that already exists directly under -ArtifactsRoot is treated as read-only
#     (sealed) for this round: the run root may not be one of them or sit inside one. This covers
#     every earlier run/review root and the START snapshot without hard-coding a list that can rot.
#   * the shared RunDirGuard creates the directory and the manifest, so an existing root is refused
#     before anything is written, and the directory is never reused.
#   * writable paths are created only inside the new root, then re-checked.
#
# Exit codes: 0 = prepared, 2 = refused (nothing created), 1 = verification failed.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews'
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

$fullRoot = Get-Normalized $RunRoot
$fullArtifacts = Get-Normalized $ArtifactsRoot
$leaf = Split-Path -Path $RunRoot -Leaf

# ---- 1. the run root must be a direct child of the artifacts root
$parent = Split-Path -Path $fullRoot -Parent
if ($parent -ne $fullArtifacts) {
    Write-Host "REFUSED: run root must be a direct child of $ArtifactsRoot, got parent=$parent"
    exit 2
}

# ---- 2. sealed set = every existing direct child directory of the artifacts root
$sealed = @()
if (Test-Path -LiteralPath $ArtifactsRoot) {
    $sealed = @(Get-ChildItem -LiteralPath $ArtifactsRoot -Directory | ForEach-Object { $_.FullName })
}
foreach ($s in $sealed) {
    if (Test-UnderRoot $fullRoot $s) {
        Write-Host "REFUSED: run root would be inside an existing (read-only) artifact root: $s"
        exit 2
    }
}

# ---- 3. guard: create the directory + manifest, refuse an existing one
. (Join-Path (Join-Path $RepoRoot 'benchmarks/lib') 'RunDirGuard.ps1')
try {
    $state = Start-RunDirectory -OutDir $RunRoot -RunId $leaf -Stage 'P1.3c-3-prepare' `
        -ExperimentRoot $ArtifactsRoot -ScriptPath $PSCommandPath `
        -Parameters @{ run_root = $RunRoot; sealed_count = $sealed.Count } `
        -Targets @() -DataSet 'leadnews_article_p1'
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

# ---- 4. the writable layout, created only inside the new root
$dirs = @('harness/src', 'build/probe-classes', 'build/run-classes-POST', 'build/harness-classes',
          'configs', 'events', 'logs', 'runs', 'source-copies', 'scripts')
foreach ($d in $dirs) {
    $full = Join-Path $RunRoot $d
    New-Item -ItemType Directory -Path $full | Out-Null
    if (-not (Test-UnderRoot $full $RunRoot)) {
        Write-Host "REFUSED: created directory escaped the run root: $full"
        exit 2
    }
}

# ---- 5. manifest: what is writable, what is read-only, and the frozen inputs
$manifest = [ordered]@{
    run_root        = $RunRoot
    artifacts_root  = $ArtifactsRoot
    stage           = 'P1.3c-3 backfill window inside and beyond the fixed 500 ms second delete'
    prepared_local  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    run_guard       = [ordered]@{ version = (Get-RunGuardVersion); guard_sha256 = (Get-FileHash (Join-Path $RepoRoot 'benchmarks/lib/RunDirGuard.ps1') -Algorithm SHA256).Hash.ToLower() }
    sealed_roots    = $sealed
    writable_dirs   = $dirs
    repo_root       = $RepoRoot
    start_snapshot  = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261103-P1.3c2-START'
    note            = 'sealed set is computed from the existing direct children at prepare time; nothing outside the run root is written'
}
[System.IO.File]::WriteAllText((Join-Path $RunRoot 'build/prepare-manifest.json'), ($manifest | ConvertTo-Json -Depth 6), $utf8)

# ---- 6. verify the layout
$missing = @()
foreach ($d in $dirs) { if (-not (Test-Path -LiteralPath (Join-Path $RunRoot $d))) { $missing += $d } }
if ($missing.Count -gt 0) { Write-Host "VERIFY FAILED: missing $($missing -join ', ')"; exit 1 }
Write-Host "run_root=$RunRoot sealed=$($sealed.Count) dirs=$($dirs.Count) manifest=build/prepare-manifest.json"
exit 0
