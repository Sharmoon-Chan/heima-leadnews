# Prepare the P1.3c-4 experiment root: delay candidates and their window/cost comparison (ASCII only).
#
# Contract (same shape as the earlier prepares, plus the build-gate directories):
#   * -RunRoot must be a NEW direct child of -ArtifactsRoot; the last segment is the run id.
#   * every directory that already exists directly under -ArtifactsRoot is treated as read-only
#     (sealed) for this round: the run root may not be one of them or sit inside one.
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

if ($parent -eq $null) { }
$parentPath = Split-Path -Path $fullRoot -Parent
if ($parentPath -ne $fullArtifacts) {
    Write-Host "REFUSED: run root must be a direct child of $ArtifactsRoot, got parent=$parentPath"
    exit 2
}

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
$parentPath = Split-Path -Path $fullRoot -Parent

. (Join-Path (Join-Path $RepoRoot 'benchmarks/lib') 'RunDirGuard.ps1')
try {
    $state = Start-RunDirectory -OutDir $RunRoot -RunId $leaf -Stage 'P1.3c-4-prepare' `
        -ExperimentRoot $ArtifactsRoot -ScriptPath $PSCommandPath `
        -Parameters @{ run_root = $RunRoot; sealed_count = $sealed.Count } `
        -Targets @() -DataSet 'leadnews_article_p1'
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$dirs = @('harness/src', 'build/probe-classes', 'build/harness-classes',
          'variants', 'gate-tests', 'configs', 'events', 'logs', 'runs', 'source-copies', 'scripts')
foreach ($d in $dirs) {
    $full = Join-Path $RunRoot $d
    New-Item -ItemType Directory -Path $full | Out-Null
    if (-not (Test-UnderRoot $full $RunRoot)) {
        Write-Host "REFUSED: created directory escaped the run root: $full"
        exit 2
    }
}

$manifest = [ordered]@{
    run_root        = $RunRoot
    artifacts_root  = $ArtifactsRoot
    stage           = 'P1.3c-4 build gate first, then the delay candidates 200/500/1500 ms'
    prepared_local  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    run_guard       = [ordered]@{ version = (Get-RunGuardVersion); guard_sha256 = (Get-FileHash (Join-Path $RepoRoot 'benchmarks/lib/RunDirGuard.ps1') -Algorithm SHA256).Hash.ToLower() }
    sealed_roots    = $sealed
    writable_dirs   = $dirs
    repo_root       = $RepoRoot
    start_snapshot  = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261103-P1.3c3-START'
    note            = 'sealed set is computed from the existing direct children at prepare time; nothing outside the run root is written'
}
[System.IO.File]::WriteAllText((Join-Path $RunRoot 'build/prepare-manifest.json'), ($manifest | ConvertTo-Json -Depth 6), $utf8)

$missing = @()
foreach ($d in $dirs) { if (-not (Test-Path -LiteralPath (Join-Path $RunRoot $d))) { $missing += $d } }
if ($missing.Count -gt 0) { Write-Host "VERIFY FAILED: missing $($missing -join ', ')"; exit 1 }
Write-Host "run_root=$RunRoot sealed=$($sealed.Count) dirs=$($dirs.Count) manifest=build/prepare-manifest.json"
exit 0
