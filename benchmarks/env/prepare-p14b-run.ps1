# Prepare the P1.4b experiment root: steady-state measurement path + independent observer + formal protocol freeze
# (ASCII only).
#
# Contract (same shape as the earlier prepares, shared guard reused, nothing rewritten):
#   * -RunRoot must be a NEW direct child of -ArtifactsRoot; the last segment is the run id;
#   * every directory that already exists directly under -ArtifactsRoot is treated as read-only (sealed);
#   * the shared RunDirGuard creates the directory and the manifest, so an existing root is refused before anything
#     is written, and the directory is never reused;
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

. (Join-Path (Join-Path $RepoRoot 'benchmarks/lib') 'RunDirGuard.ps1')
try {
    $state = Start-RunDirectory -OutDir $RunRoot -RunId $leaf -Stage 'P1.4b-prepare' `
        -ExperimentRoot $ArtifactsRoot -ScriptPath $PSCommandPath `
        -Parameters @{ run_root = $RunRoot; sealed_count = $sealed.Count } `
        -Targets @() -DataSet 'leadnews_article_p1'
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$dirs = @('runs', 'logs', 'configs', 'events', 'inputs', 'plans', 'scripts', 'resources', 'offline', 'protocol')
foreach ($d in $dirs) {
    $full = Join-Path $RunRoot $d
    New-Item -ItemType Directory -Path $full | Out-Null
    if (-not (Test-UnderRoot $full $RunRoot)) {
        Write-Host "REFUSED: created directory escaped the run root: $full"
        exit 2
    }
}

$manifest = [ordered]@{
    run_root       = $RunRoot
    artifacts_root = $ArtifactsRoot
    stage          = 'P1.4b measurement-path convergence (observer outside the dispatch loop, monotonic body-ready stamp) and formal comparison protocol freeze'
    prepared_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    run_guard      = [ordered]@{ version = (Get-RunGuardVersion); guard_sha256 = (Get-FileHash (Join-Path $RepoRoot 'benchmarks/lib/RunDirGuard.ps1') -Algorithm SHA256).Hash.ToLower() }
    sealed_roots   = $sealed
    writable_dirs  = $dirs
    repo_root      = $RepoRoot
    note           = 'read-only article detail scenario only; no writes, no Kafka/MinIO/ES, no Maven, no production change'
}
[System.IO.File]::WriteAllText((Join-Path $RunRoot 'prepare-manifest.json'), ($manifest | ConvertTo-Json -Depth 6), $utf8)

$missing = @()
foreach ($d in $dirs) { if (-not (Test-Path -LiteralPath (Join-Path $RunRoot $d))) { $missing += $d } }
if ($missing.Count -gt 0) { Write-Host "VERIFY FAILED: missing $($missing -join ', ')"; exit 1 }
Write-Host "run_root=$RunRoot sealed=$($sealed.Count) dirs=$($dirs.Count) manifest=prepare-manifest.json"
exit 0
