# P1.4b section 8 part C: real output-path ownership checks for the NEW entries (ASCII only).
#
# Why this file exists: `p14b-observer.ps1` only checked that RunRoot was an active root and then trusted a caller
# supplied -OutDir, so the owner could point -OutDir at a DIFFERENT, already completed sibling root and three files
# were created there. Checking RunRoot alone is not enough: every path an entry will actually write must be resolved
# and proven to belong to the CURRENT active run root, before any directory is created, any assembly is compiled, any
# sample is taken or any process is started.
#
# Rules enforced here (all of them are refusals, i.e. exit 2 in the callers - never a silent skip):
#   * the path is resolved to its REAL absolute location (relative paths are resolved against the run root, and `..`
#     segments are collapsed FIRST, so a `..` escape is judged by where it really lands);
#   * it must be equal to, or strictly inside, the active run root;
#   * it must NOT be inside any OTHER directory under the artifacts root (a sibling experiment root is refused even if
#     it is not currently marked completed - "not completed yet" is not an ownership proof);
#   * a path that resolves outside the artifacts root at all is refused;
#   * the run root must be active and must not sit inside a completed/other root (delegated to P14aRoots, unchanged).
#
# This helper is intentionally separate from the public RunDirGuard.ps1 / P14aRoots.ps1, which stay byte-identical.

function Get-P14bNormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Base = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path is empty' }
    $raw = $Path
    if (-not [System.IO.Path]::IsPathRooted($raw)) {
        if ([string]::IsNullOrWhiteSpace($Base)) { throw "relative path without a base: $Path" }
        $raw = Join-Path $Base $raw
    }
    # GetFullPath collapses '.' and '..' and normalizes separators, so an escape is judged by the real destination
    $full = [System.IO.Path]::GetFullPath($raw)
    return $full.TrimEnd('\', '/')
}

function Test-P14bUnderPath {
    param([string]$Path, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $p = $Path.ToLowerInvariant()
    $r = $Root.ToLowerInvariant()
    return ($p -eq $r) -or $p.StartsWith($r + '\') -or $p.StartsWith($r + '/')
}

# The one guard every new entry calls for EVERY path it will really write.
# Returns the resolved absolute path, or throws (the caller turns that into exit 2 before doing anything).
function Assert-P14bOwnedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ArtifactsRoot,
        [string]$Label = 'output path',
        [switch]$AllowRunRootItself
    )
    $root = (Get-P14bNormalizedPath -Path $RunRoot)
    $art = (Get-P14bNormalizedPath -Path $ArtifactsRoot)
    $resolved = (Get-P14bNormalizedPath -Path $Path -Base $root)

    if (-not (Test-P14bUnderPath -Path $root -Root $art)) {
        throw "$Label : the run root is outside the artifacts root ($root not under $art)"
    }
    if (-not (Test-P14bUnderPath -Path $resolved -Root $root)) {
        throw "$Label resolves outside the active run root: '$Path' -> '$resolved' (root=$root)"
    }
    if (-not $AllowRunRootItself -and ($resolved.ToLowerInvariant() -eq $root.ToLowerInvariant())) {
        throw "$Label must name a file/directory INSIDE the run root, not the run root itself: $resolved"
    }
    # any OTHER direct child of the artifacts root is off limits, completed or not. An ANCESTOR of the active run root is
    # not "another root" for this purpose: if the active root itself lives inside it, then a path inside the active root
    # is still inside the active root. The exclusion is therefore only applied to roots that do not contain the run root.
    if (Test-Path -LiteralPath $art) {
        foreach ($d in @(Get-ChildItem -LiteralPath $art -Directory -Force)) {
            $other = (Get-P14bNormalizedPath -Path $d.FullName)
            if ($other.ToLowerInvariant() -eq $root.ToLowerInvariant()) { continue }
            if (Test-P14bUnderPath -Path $root -Root $other) { continue }
            if (Test-P14bUnderPath -Path $resolved -Root $other) {
                throw "$Label points into ANOTHER experiment root (read-only): '$resolved' is inside '$other'"
            }
        }
    }
    return $resolved
}

# Convenience wrapper: validate a whole named set of paths in one call, in a stable order.
function Assert-P14bOwnedPaths {
    param(
        [Parameter(Mandatory = $true)]$Paths,
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ArtifactsRoot
    )
    $resolved = [ordered]@{}
    foreach ($k in @($Paths.Keys)) {
        $v = [string]$Paths[$k]
        if ([string]::IsNullOrWhiteSpace($v)) { continue }
        $resolved[$k] = (Assert-P14bOwnedPath -Path $v -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label $k)
    }

    return $resolved
}
