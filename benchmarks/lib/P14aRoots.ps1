# P1.4a root lifecycle + write-once helpers (ASCII only, dot-sourced by every entry of this card).
#
# Why this file exists: a sub-run directory guard is NOT a parent experiment-root guard. A finished P1.4a root
# (valid prepare manifest + summary + hash manifest + completion marker) must be refused by EVERY entry -
# plan, start, collect, calibrate, summarize - BEFORE any directory creation, any file write, any SQL/Redis/HTTP
# call and any process start. Nothing here talks to the network or a database.

# A root counts as COMPLETED when any of these exist. The marker set is deliberately broad: it is cheaper to
# refuse a live root than to append evidence into a sealed one.
$script:P14aCompleteMarkers = @('artifacts-sha256.tsv', 'summary.json', 'COMPLETE', 'completed.json')

function Get-P14aNormalized([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    return [System.IO.Path]::GetFullPath($p).TrimEnd('\', '/').ToLowerInvariant()
}

function Test-P14aUnderRoot([string]$path, [string]$root) {
    $p = Get-P14aNormalized $path
    $r = Get-P14aNormalized $root
    if ($p -eq '' -or $r -eq '') { return $false }
    return ($p -eq $r) -or $p.StartsWith($r + '\') -or $p.StartsWith($r + '/')
}

# Returns the state of a root WITHOUT writing anything.
#   state = 'missing' | 'not-prepared' | 'active' | 'completed'
function Get-P14aRootState([string]$RunRoot, [string]$ArtifactsRoot) {
    $s = [ordered]@{ run_root = $RunRoot; state = 'missing'; markers = @(); prepare_manifest = $false; reason = '' }
    if (-not (Test-Path -LiteralPath $RunRoot)) { $s.reason = 'run root does not exist'; return $s }
    $full = [System.IO.Path]::GetFullPath($RunRoot)
    if (-not (Test-P14aUnderRoot $full $ArtifactsRoot)) { $s.state = 'not-prepared'; $s.reason = 'run root is outside the artifacts root'; return $s }
    $prep = Join-Path $full 'prepare-manifest.json'
    $s.prepare_manifest = Test-Path -LiteralPath $prep
    $found = @()
    foreach ($m in $script:P14aCompleteMarkers) {
        if (Test-Path -LiteralPath (Join-Path $full $m)) { $found += $m }
    }
    $s.markers = $found
    if (-not $s.prepare_manifest) { $s.state = 'not-prepared'; $s.reason = 'no prepare-manifest.json (not created by prepare-p14a-run.ps1)'; return $s }
    if ($found.Count -gt 0) { $s.state = 'completed'; $s.reason = "root is completed (markers: $($found -join ', '))"; return $s }
    $s.state = 'active'
    return $s
}

# Every entry of this card calls this first. It refuses (exit 2) - and refuses BEFORE any output - when the root
# is missing, was not prepared by prepare-p14a-run.ps1, or is already completed/sealed.
function Assert-P14aActiveRoot {
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][string]$ArtifactsRoot,
        [Parameter(Mandatory = $true)][string]$EntryPoint
    )
    $state = Get-P14aRootState -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot
    if ($state.state -ne 'active') {
        Write-Host "REFUSED: $EntryPoint will not run against this root"
        Write-Host "REFUSED_STAGE=root-state"
        Write-Host "REFUSED_DETAIL=state=$($state.state) reason=$($state.reason)"
        Write-Host ('REFUSED_MARKERS=' + ($state.markers -join ','))
        exit 2
    }
    return $state
}

# Refuse when a root sits inside any OTHER existing direct child of the artifacts root (sealed roots), or when it
# IS one of them other than the intended root.
function Assert-P14aNotInSealedRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ArtifactsRoot,
        [Parameter(Mandatory = $true)][string]$EntryPoint,
        [string]$AllowRoot = ''
    )
    $allow = Get-P14aNormalized $AllowRoot
    foreach ($d in (Get-ChildItem -LiteralPath $ArtifactsRoot -Directory -ErrorAction SilentlyContinue)) {
        $child = Get-P14aNormalized $d.FullName
        if ($child -eq $allow) { continue }
        if (Test-P14aUnderRoot $Path $d.FullName) {
            Write-Host "REFUSED: $EntryPoint path resolves inside a sealed root: $Path (sealed: $($d.Name))"
            Write-Host 'REFUSED_STAGE=sealed-root'
            exit 2
        }
    }
    return $true
}

# Write-once: creates the file with CreateNew semantics. An existing file is a hard refusal (exit 2), so a
# repeated or partially failed run can never rewrite evidence - it must use a new run id / root instead.
function Write-P14aOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$EntryPoint
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { throw "output directory does not exist: $dir" }
    if (Test-Path -LiteralPath $Path) {
        Write-Host "REFUSED: $EntryPoint output already exists (write once): $Path"
        Write-Host 'REFUSED_STAGE=write-once'
        exit 2
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $fs = $null
    try {
        # CreateNew is the atomic write-once guarantee; a racing writer cannot win twice
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = $utf8.GetBytes($Text)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    } catch [System.IO.IOException] {
        Write-Host "REFUSED: $EntryPoint could not create its output (write once): $Path ($($_.Exception.Message))"
        Write-Host 'REFUSED_STAGE=write-once'
        exit 2
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    return $Path
}
