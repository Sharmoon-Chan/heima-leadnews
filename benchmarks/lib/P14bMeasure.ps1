# P1.4b measurement path: loader, PERSISTENT assembly build, and monotonic clock helpers (ASCII only).
#
# Dot-sourced by benchmarks/lib/P14aCollector.ps1 and by the P1.4b entries. Nothing here samples resources: the separate
# observer process (benchmarks/verify/p14b-observer.ps1) owns that, so the dispatch/reap loop never waits for a sample.
#
# Section 8 part D adds the persistent-measurement-assembly path: the C# helper used for the body-ready stamp is no
# longer only compiled in memory. `Build-P14bMeasureAssembly` compiles benchmarks/lib/P14bMeasure.cs into a real DLL at
# a caller-chosen path (which the caller must already have proven belongs to the active run root), returns its SHA256,
# and loads THAT file - so the run can name the exact measurement artifact it used instead of just the source hash.

function Initialize-P14bMeasure {
    param([string]$Path = '')
    if ($null -ne ('P14b.Hit' -as [type])) { return $true }
    $src = if ($Path -ne '') { $Path } else { Join-Path $PSScriptRoot 'P14bMeasure.cs' }
    if (-not (Test-Path -LiteralPath $src)) { throw "the P1.4b measurement helper source is missing: $src" }
    Add-Type -Path $src -ReferencedAssemblies 'System.Net.Http' -ErrorAction Stop
    if ($null -eq ('P14b.Hit' -as [type])) { throw "the P1.4b measurement helper did not compile: $src" }
    return $true
}

# Compile the measurement helper into a PERSISTENT assembly and load exactly that file.
# Returns { ok, path, sha256, bytes, source, source_sha256, already_existed, loaded }.
function Build-P14bMeasureAssembly {
    param(
        [Parameter(Mandatory = $true)][string]$OutputAssembly,
        [string]$SourcePath = '',
        [switch]$ReuseExisting
    )
    $src = if ($SourcePath -ne '') { $SourcePath } else { Join-Path $PSScriptRoot 'P14bMeasure.cs' }
    if (-not (Test-Path -LiteralPath $src)) { throw "the P1.4b measurement helper source is missing: $src" }
    $dir = Split-Path -Parent $OutputAssembly
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $res = [ordered]@{
        ok = $false; path = $OutputAssembly; sha256 = ''; bytes = 0
        source = $src; source_sha256 = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLower()
        already_existed = $false; loaded = $false
    }
    if (Test-Path -LiteralPath $OutputAssembly) {
        if (-not $ReuseExisting) { throw "the measurement assembly already exists (write once): $OutputAssembly" }
        $res.already_existed = $true
    } else {
        Add-Type -Path $src -OutputAssembly $OutputAssembly -ReferencedAssemblies 'System.Net.Http' -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $OutputAssembly)) { throw "the measurement assembly was not produced: $OutputAssembly" }
    $res.sha256 = (Get-FileHash -LiteralPath $OutputAssembly -Algorithm SHA256).Hash.ToLower()
    $res.bytes = (Get-Item -LiteralPath $OutputAssembly).Length
    # load EXACTLY this file (never a stale in-memory copy) and prove the expected type is there
    if ($null -eq ('P14b.Hit' -as [type])) {
        $asm = [System.Reflection.Assembly]::LoadFile($OutputAssembly)
        if ($null -eq $asm) { throw "could not load the measurement assembly: $OutputAssembly" }
    }
    if ($null -eq ('P14b.Hit' -as [type])) { throw "the loaded measurement assembly does not expose P14b.Hit: $OutputAssembly" }
    $res.loaded = $true
    $res.ok = $true
    return $res
}

# Monotonic milliseconds on the shared axis (ms since an unspecified machine-wide origin). Never derived from UTC and
# never compared with a wall-clock value.
function Get-P14bMonoMs {
    param([AllowNull()]$Ticks = $null)
    $t = if ($null -eq $Ticks) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { [long]$Ticks }
    return [Math]::Round(($t * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency, 3)
}

function Get-P14bMonoFrequency {
    return [System.Diagnostics.Stopwatch]::Frequency
}
