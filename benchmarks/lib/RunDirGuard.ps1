# Shared run-directory guard for all experiment collectors (ASCII only: PS 5.1 reads
# BOM-less .ps1 as ANSI/GBK, so non-ASCII literals would be corrupted).
#
# Why this exists (TOOL-003):
#   During P1.1 a failed run reused the same -OutDir, the old directory was deleted before the
#   retry, and the failure originals were lost. A written convention was not enough, so the
#   protection is enforced here, in code, and every collector must call it BEFORE doing any
#   HTTP request, Redis command or SQL statement.
#
# Contract enforced by Start-RunDirectory:
#   * -RunId is mandatory and must match a safe pattern
#   * the LAST path segment of -OutDir must equal -RunId
#   * -OutDir must live inside -ExperimentRoot
#   * an existing directory (even an empty one) is a hard failure: no -Force, no delete,
#     no silent suffix; the process exits non-zero and the previous evidence is untouched
#   * a manifest is written immediately after the directory is created
#
# Callers dot-source this file and then:
#   $run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.1' ...
#   ... Write-RunFileText / Write-RunFileBytes / Add-RunCheck ...
#   Set-RunStatus -State $run -Status 'passed'
#
# Exit codes used by the collectors: 0 = all checks passed, 1 = a check failed or an
# unexpected error occurred, 2 = usage/guard problem (nothing was executed).

$script:RunGuardVersion = '1.1.0'
$script:SensitiveKeyPattern = '(?i)(password|passwd|secret|token|accesskey|secretkey)'

function Get-RunGuardVersion { return $script:RunGuardVersion }

function Get-FullPathNormalized([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'path is empty' }
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-SafeRunId([string]$RunId) {
    # letters/digits first, then letters/digits/dot/underscore/dash; 3..80 chars
    return ($RunId -match '^[A-Za-z0-9][A-Za-z0-9._-]{2,79}$')
}

function Format-SanitizedParameters([hashtable]$Parameters) {
    $out = [ordered]@{}
    if ($null -eq $Parameters) { return $out }
    foreach ($k in ($Parameters.Keys | Sort-Object)) {
        $v = $Parameters[$k]
        if ("$k" -match $script:SensitiveKeyPattern) { $out[$k] = '<redacted>' }
        else { $out[$k] = "$v" }
    }
    return $out
}

<#
 .SYNOPSIS
   Validate the run identity, create a brand-new output directory and write its manifest.
 .DESCRIPTION
   Throws (callers exit with 2) when the identity or the path is wrong, or when the target
   directory already exists. Nothing outside this function touches the filesystem, so a failed
   guard leaves zero side effects.
#>
function Start-RunDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$OutDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$ExperimentRoot,
        [string]$ScriptPath = $PSCommandPath,
        [hashtable]$Parameters = @{},
        [string[]]$Targets = @(),
        [string]$DataSet = ''
    )

    # ---- 1. identity checks (no filesystem side effects yet) ----
    if ([string]::IsNullOrWhiteSpace($RunId)) {
        throw 'GUARD: -RunId is required'
    }
    if (-not (Test-SafeRunId $RunId)) {
        throw "GUARD: illegal run_id '$RunId' (allowed: [A-Za-z0-9][A-Za-z0-9._-]{2,79})"
    }

    $fullOut = Get-FullPathNormalized $OutDir
    $fullRoot = Get-FullPathNormalized $ExperimentRoot

    $leaf = Split-Path -Path $fullOut -Leaf
    if ($leaf -cne $RunId) {
        throw "GUARD: last segment of -OutDir ('$leaf') must equal -RunId ('$RunId')"
    }

    $rootWithSep = $fullRoot.TrimEnd('\') + '\'
    if (-not $fullOut.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "GUARD: -OutDir must be inside -ExperimentRoot ($fullRoot). got: $fullOut"
    }

    # ---- 2. refuse to reuse anything that already exists ----
    if (Test-Path -LiteralPath $fullOut) {
        throw "GUARD: refusing to reuse existing output directory: $fullOut (previous evidence must be kept; pick a new run_id)"
    }

    # ---- 3. create + manifest ----
    New-Item -ItemType Directory -Path $fullOut -ErrorAction Stop | Out-Null

    $scriptHash = ''
    if ($ScriptPath -and (Test-Path -LiteralPath $ScriptPath)) {
        $scriptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ScriptPath).Hash.ToLower()
    }

    $state = [pscustomobject]@{
        run_id          = $RunId
        stage           = $Stage
        out_dir         = $fullOut
        experiment_root = $fullRoot
        started_utc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        started_local   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        guard_version   = $script:RunGuardVersion
        script_path     = "$ScriptPath"
        script_sha256   = $scriptHash
        status          = 'running'
        checks          = @()
        completed_steps = @()
    }

    $manifest = [ordered]@{
        run_id          = $RunId
        stage           = $Stage
        started_utc     = $state.started_utc
        started_local   = $state.started_local
        guard_version   = $state.guard_version
        script          = [ordered]@{ path = "$ScriptPath"; sha256 = $scriptHash }
        experiment_root = $fullRoot
        out_dir         = $fullOut
        parameters      = (Format-SanitizedParameters $Parameters)
        targets         = $Targets
        data_set        = $DataSet
        host            = [ordered]@{ name = $env:COMPUTERNAME; ps_version = "$($PSVersionTable.PSVersion)" }
        note            = 'manifest written immediately after directory creation; this directory is never reused'
    }
    Write-RunFileText -State $state -Path (Join-Path $fullOut 'run-manifest.json') -Text ($manifest | ConvertTo-Json -Depth 6)

    return $state
}

<#
 .SYNOPSIS
   Write a file exactly once. Throws if the target already exists (never overwrites).
#>
function Write-RunFileText {
    param(
        $State,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    if (Test-Path -LiteralPath $Path) {
        throw "GUARD: refusing to overwrite existing evidence file: $Path"
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Write-RunFileBytes {
    param(
        $State,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    if (Test-Path -LiteralPath $Path) {
        throw "GUARD: refusing to overwrite existing evidence file: $Path"
    }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

<#
 .SYNOPSIS
   Record one check. Status is pass / fail / skipped.
   skipped is NOT counted as passed: it means "prerequisite not met, nothing was verified".
#>
function Add-RunCheck {
    param(
        $State,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'skipped')][string]$Status,
        [string]$Detail = ''
    )
    if ($null -eq $State) { throw 'GUARD: Add-RunCheck needs the state object returned by Start-RunDirectory' }
    $State.checks += [pscustomobject]@{ check = $Name; status = $Status; detail = $Detail }
}

function Get-RunCheckCounts($State) {
    $p = 0; $f = 0; $s = 0
    if ($null -ne $State) {
        foreach ($c in $State.checks) {
            switch ($c.status) {
                'pass' { $p++ }
                'fail' { $f++ }
                'skipped' { $s++ }
            }
        }
    }
    return [pscustomobject]@{ passed = $p; failed = $f; skipped = $s; total = ($p + $f + $s) }
}

function Add-RunStep {
    param($State, [Parameter(Mandatory = $true)][string]$Step)
    if ($null -ne $State) { $State.completed_steps += $Step }
}

<#
 .SYNOPSIS
   The single fixed contract for requests.csv (R3): eight named columns.
   Both the load generator and the offline tests use these helpers, so the header
   cannot silently regress to "no header" again.
#>
$script:RequestCsvHeader = 'utc_time,worker,article_id,latency_ms,http_code,biz_code,ok,error'

function Get-RequestCsvHeader { return $script:RequestCsvHeader }

<#
 .SYNOPSIS
   Build the complete requests.csv content in ONE string: header line first, then every row.
   An empty data set still yields the header line only, so the file always parses.
   Single string => the caller writes the file exactly once (write-once stays intact).
#>
function Format-RequestCsv {
    param([string[]]$Rows = @())
    $nl = [Environment]::NewLine
    if ($null -eq $Rows -or $Rows.Count -eq 0) { return $script:RequestCsvHeader }
    return ($script:RequestCsvHeader + $nl + ($Rows -join $nl))
}

<#
 .SYNOPSIS
   Evaluate one saved detail response. Used by collectors AND by the offline tests,
   so the pass/fail rule has a single implementation.
 .PARAMETER ExpectKind
   'existing' -> HTTP 200, business code 200, exact string id, data.article object
   'missing'  -> HTTP 200, business code 1002, data null
#>
function Test-DetailResponse {
    param(
        [string]$HttpStatus,
        [AllowNull()][AllowEmptyString()][string]$BodyText,
        [string]$ExpectId,
        [Parameter(Mandatory = $true)][ValidateSet('existing', 'missing')][string]$ExpectKind
    )

    if ([string]::IsNullOrWhiteSpace($BodyText)) {
        return [pscustomobject]@{ status = 'fail'; reason = 'response body file missing or empty' }
    }
    if ("$HttpStatus" -ne '200') {
        return [pscustomobject]@{ status = 'fail'; reason = "http status $HttpStatus (expected 200)" }
    }
    try {
        $obj = ConvertFrom-Json -InputObject $BodyText -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ status = 'fail'; reason = 'body is not valid JSON' }
    }
    if ($null -eq $obj -or $null -eq $obj.PSObject.Properties['code']) {
        return [pscustomobject]@{ status = 'fail'; reason = 'body has no business code field' }
    }
    $code = "$($obj.code)"

    if ($ExpectKind -eq 'missing') {
        if ($code -ne '1002') { return [pscustomobject]@{ status = 'fail'; reason = "business code $code (expected 1002)" } }
        if ($null -ne $obj.data) { return [pscustomobject]@{ status = 'fail'; reason = 'data must be null for a missing id' } }
        return [pscustomobject]@{ status = 'pass'; reason = 'business code 1002 with data null' }
    }

    if ($code -ne '200') { return [pscustomobject]@{ status = 'fail'; reason = "business code $code (expected 200)" } }
    if ($null -eq $obj.data) { return [pscustomobject]@{ status = 'fail'; reason = 'data is null for an existing id' } }
    if ($null -eq $obj.data.article) { return [pscustomobject]@{ status = 'fail'; reason = 'data.article is missing' } }

    # R4: judge the parsed property itself, never a substring elsewhere in the document.
    # A bare JSON number is a real defect even when another field carries the same value
    # as a string, and legal JSON whitespace must not turn a correct string into a failure.
    $idProp = $obj.data.article.PSObject.Properties['id']
    if ($null -eq $idProp) {
        return [pscustomobject]@{ status = 'fail'; reason = 'data.article has no id field' }
    }
    $returnedId = $idProp.Value
    if ($null -eq $returnedId) {
        return [pscustomobject]@{ status = 'fail'; reason = 'data.article.id is null' }
    }
    if ($returnedId -isnot [string]) {
        return [pscustomobject]@{ status = 'fail'; reason = "data.article.id is $($returnedId.GetType().Name), not a JSON string" }
    }
    if ($returnedId -cne "$ExpectId") {
        return [pscustomobject]@{ status = 'fail'; reason = "article id '$returnedId' does not match requested '$ExpectId'" }
    }
    return [pscustomobject]@{ status = 'pass'; reason = 'business code 200 with data.article.id as an exactly matching JSON string' }
}

<#
 .SYNOPSIS
   Persist a failure without deleting anything, then return the exit code the caller should use.
#>
function Save-RunFailure {
    param(
        $State,
        $ErrorRecord,
        [string[]]$ExtraOutput = @()
    )
    $msg = 'unknown error'
    $stack = ''
    if ($null -ne $ErrorRecord) {
        $msg = "$($ErrorRecord.Exception.Message)"
        $stack = "$($ErrorRecord.ScriptStackTrace)"
    }
    if ($null -eq $State) {
        # guard failed before any directory existed: nothing to write
        Write-Host "RUN FAILED (before any output directory was created): $msg"
        return 2
    }
    $counts = Get-RunCheckCounts $State
    $payload = [ordered]@{
        run_id          = $State.run_id
        stage           = $State.stage
        status          = 'failed'
        failed_utc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        error           = $msg
        stack           = $stack
        completed_steps = $State.completed_steps
        counts          = $counts
        checks          = $State.checks
        note            = 'files written before the failure are kept; this directory is never reused'
    }
    try {
        Write-RunFileText -State $State -Path (Join-Path $State.out_dir 'run-error.json') -Text ($payload | ConvertTo-Json -Depth 6)
    } catch {
        Write-Host "could not write run-error.json: $($_.Exception.Message)"
    }
    if ($ExtraOutput -and $ExtraOutput.Count -gt 0) {
        try {
            Write-RunFileText -State $State -Path (Join-Path $State.out_dir 'run-error-output.txt') -Text ($ExtraOutput -join [Environment]::NewLine)
        } catch {
            Write-Host "could not write run-error-output.txt: $($_.Exception.Message)"
        }
    }
    $State.status = 'failed'
    Write-Host "RUN FAILED: $msg"
    Write-Host "evidence preserved in: $($State.out_dir)"
    return 1
}

<#
 .SYNOPSIS
   Write the final status file and return the exit code (0 only when nothing failed and
   at least one check actually ran).
#>
function Set-RunStatus {
    param(
        $State,
        [Parameter(Mandatory = $true)][ValidateSet('passed', 'failed')][string]$Status
    )
    if ($null -eq $State) { throw 'GUARD: Set-RunStatus needs the state object' }
    $counts = Get-RunCheckCounts $State
    if ($counts.failed -gt 0) { $Status = 'failed' }
    # a run that verified nothing must not be reported as passed: skipped checks are not passes
    if ($counts.passed -eq 0) { $Status = 'failed' }

    $payload = [ordered]@{
        run_id          = $State.run_id
        stage           = $State.stage
        status          = $Status
        started_utc     = $State.started_utc
        finished_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        counts          = $counts
        checks          = $State.checks
        completed_steps = $State.completed_steps
    }
    Write-RunFileText -State $State -Path (Join-Path $State.out_dir 'run-status.json') -Text ($payload | ConvertTo-Json -Depth 6)
    $State.status = $Status

    Write-Host "run_id=$($State.run_id) stage=$($State.stage) status=$Status passed=$($counts.passed) failed=$($counts.failed) skipped=$($counts.skipped)"
    if ($Status -eq 'passed') { return 0 }
    return 1
}
