# P1.4b section 8 part A: the INDEPENDENT P1.4b summary (ASCII only).
#
# Why this entry exists: `p14a-summarize.ps1` validates the OLD receipt/business contract. It has no idea about the
# P1.4b stamps, so a copy whose body latency was negative, whose body-ready stamp preceded the dispatch stamp, or whose
# new timing fields were deleted completely still produced exit 0 / problems 0 / validated_tiers=[5] with an identical
# summary hash. That is a P1.4a verdict, not a P1.4b measurement verdict. This entry is the versioned extension that
# reads the raw originals again with the P1.4b rules and keeps the two verdicts separate.
#
# What it reads (always from the ORIGINALS, never from a self-report):
#   * plans/<plan>.json            - the exact slot set, offsets, article ids, declared seconds
#   * plans/ids-truth.json         - the independent truth (four counters, channel, author, content hash/bytes)
#   * runs/<id>/responses.jsonl    - every record verbatim, including the four monotonic stamps
#   * runs/<id>/collect-result.json- the run's own identity, four counters, declared window and observer block
#   * runs/<id>/observer/observer-summary.json - the observer's own summary (identity, gaps, pause interval)
#   * subruns.json (optional)      - the rate/pair/group list of THIS calibration, so every sub-run is preserved
#
# What it refuses (each one is a named problem, never a silent zero):
#   * a record with no new stamp at all while the run claims to be a P1.4b measurement (legacy copies are judged with
#     -Mode legacy and are reported as legacy-only, never mixed into the P1.4b population)
#   * a negative body latency, a body-ready stamp before the dispatch stamp, or an observation before the body stamp
#   * a body window that does not add up to its population
#   * a rate whose pairs are incomplete, or whose ANY pair fails the pre-registered quality gates
#
# Exit codes: 0 = every attempted rate is a validated P1.4b tier, 1 = a measurement/quality problem, 2 = refused.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [ValidateSet('p14b', 'legacy')][string]$Mode = 'p14b',
    [string]$SubRunsFile = '',
    [string]$TruthFile = '',
    [int]$MaxInFlight = 16,
    [double]$DispatchLagP95 = 5.0,
    [double]$DispatchLagP99 = 10.0,
    [double]$DispatchLagMax = 25.0,
    [double]$ObserveLagP95 = 5.0,
    [double]$ObserveLagMax = 25.0,
    [double]$SloP95CandidateMs = 60.0,
    [int]$PlannedSlotBudget = 2000,
    [string]$OutFile = 'p14b-summary.json',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [string[]]$ExtraRunIds = @()
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14aRoots.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14bPaths.ps1')

function Refuse([string]$why) { Write-Host "REFUSED: $why"; Write-Host 'REFUSED_STAGE=guard'; exit 2 }
function Read-SharedLines2([string]$path) {
    $fs = $null; $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
        return @($sr.ReadToEnd() -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    } catch { return @() } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}
function Get-Sha2([string]$p) { if (Test-Path -LiteralPath $p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() } return '' }
function To-Num([AllowNull()]$v) {
    if ($null -eq $v) { return $null }
    if ($v -is [bool]) { return $null }
    $d = 0.0
    if ([double]::TryParse([string]$v, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'p14b-summarize.ps1'
$RunRoot = (Get-P14bNormalizedPath -Path $RunRoot)
$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
try {
    $outPath = Assert-P14bOwnedPath -Path (Join-Path $outDir $OutFile) -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'p14b summary'
} catch { Refuse $_.Exception.Message }
if (-not (Test-Path -LiteralPath $outDir)) { Refuse "the calibration run directory does not exist: $outDir" }
if (Test-Path -LiteralPath $outPath) { Refuse "the summary already exists (write once): $outPath" }

$plansDir = Join-Path $RunRoot 'plans'
# NOTE: PowerShell variable names are case-insensitive, so the local path must NOT be called $truthFile (that would
# overwrite the -TruthFile parameter and make the override below a no-op).
$truthPathLocal = Join-Path $plansDir 'ids-truth.json'
# A private validation root may legitimately have no plans/ids-truth.json (the suite keeps its own truth under offline/).
# In that case the caller must name an explicit truth file: an empty truth set would re-judge every body as wrong and
# look like a data failure instead of a configuration mistake.
if (-not (Test-Path -LiteralPath $truthPathLocal) -and $TruthFile -ne '') {
    $truthPathLocal = if ([System.IO.Path]::IsPathRooted($TruthFile)) { $TruthFile } else { Join-Path $RunRoot $TruthFile }
}
if (-not (Test-Path -LiteralPath $truthPathLocal)) { Refuse "the truth file is missing: $truthPathLocal" }
$truthObj = Get-Content -LiteralPath $truthPathLocal -Raw -Encoding UTF8 | ConvertFrom-Json
$truthById = @{}
foreach ($t in $truthObj.targets) { $truthById[[string]$t.article_id] = $t }

$problems = New-Object System.Collections.ArrayList
$problemsByRun = @{}

# ---- which sub-runs belong to this calibration ----------------------------------------------------------------
$subRuns = New-Object System.Collections.ArrayList
if ($SubRunsFile -ne '') {
    $sf = if ([System.IO.Path]::IsPathRooted($SubRunsFile)) { $SubRunsFile } else { Join-Path $outDir $SubRunsFile }
    if (-not (Test-Path -LiteralPath $sf)) { Refuse "the sub-run list is missing: $sf" }
    $so = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($s in @($so.subruns)) {
        $null = $subRuns.Add([ordered]@{ rate = [int]$s.rate; pair = [int]$s.pair; group = [string]$s.group; run_id = [string]$s.run_id; plan_file = [string]$s.plan_file })
    }
} else {
    # fall back to every sample run directory present, in a stable order (used by the legacy-copy re-judgement)
    foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $RunRoot 'runs') -Directory | Sort-Object Name)) {
        if ($d.Name -eq $RunId) { continue }
        $null = $subRuns.Add([ordered]@{ rate = 0; pair = 0; group = ''; run_id = $d.Name; plan_file = '' })
    }
}
foreach ($x in $ExtraRunIds) { $null = $subRuns.Add([ordered]@{ rate = 0; pair = 0; group = ''; run_id = $x; plan_file = '' }) }

function Add-Problem([string]$runId, [string]$text) {
    $null = $problems.Add($text)
    if (-not $problemsByRun.ContainsKey($runId)) { $problemsByRun[$runId] = New-Object System.Collections.ArrayList }
    $null = $problemsByRun[$runId].Add($text)
}

# ---- one sub-run, judged from the originals -------------------------------------------------------------------
function Get-SubRunResult([string]$subRunId, [int]$rate, [int]$pair, [string]$group) {
    $dir = Join-Path (Join-Path $RunRoot 'runs') $subRunId
    $ledgerPath = Join-Path $dir 'responses.jsonl'
    $collPath = Join-Path $dir 'collect-result.json'
    $obsPath = Join-Path (Join-Path $dir 'observer') 'observer-summary.json'
    $res = [ordered]@{
        run_id = $subRunId; rate = $rate; pair = $pair; group = $group
        present = (Test-Path -LiteralPath $ledgerPath) -and (Test-Path -LiteralPath $collPath)
        plan_file = ''; plan_sha256 = ''; planned_slots = -1; declared_window_ms = -1
        responses = 0; dropped = 0; correct = 0; failures = 0; timeouts = 0
        body_population = 0; body_correct_population = 0
        legacy_only_records = 0; missing_stamp_records = 0; negative_latency = 0; out_of_order = 0
        body_window = $null; observe_window_legacy = $null
        body_latency_correct_ms = $null; body_latency_all_ms = $null
        observe_lag_ms = $null; dispatch_lag_mono_ms = $null; persist_lag_ms = $null
        observer = $null; observer_interval = $null
        gates = [ordered]@{}; failed_gates = @()
        problems = @()
    }
    if (-not $res.present) {
        Add-Problem $subRunId "$subRunId has no responses.jsonl and/or collect-result.json"
        $res.problems = @($problemsByRun[$subRunId])
        return $res
    }
    $coll = Get-Content -LiteralPath $collPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $res.plan_file = [string]$coll.plan.file
    $res.plan_sha256 = [string]$coll.plan.sha256
    $planPath = Join-Path $plansDir $res.plan_file
    $planBySlot = @{}
    if (-not (Test-Path -LiteralPath $planPath)) {
        Add-Problem $subRunId "$subRunId names plan '$($res.plan_file)' which is not in plans/"
    } else {
        $planObj = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $res.planned_slots = [int]$planObj.slot_count
        if ($null -ne $planObj.PSObject.Properties['seconds']) { $res.declared_window_ms = [long]([int]$planObj.seconds * 1000) }
        foreach ($s in @($planObj.slots)) { $planBySlot[[string][int]$s.slot_index] = $s }
        if ((Get-Sha2 $planPath) -ne $res.plan_sha256) { Add-Problem $subRunId "$subRunId was collected from a different plan hash than the frozen file" }
    }

    $rows = New-Object System.Collections.ArrayList
    $unparseable = 0
    foreach ($l in (Read-SharedLines2 $ledgerPath)) {
        try { $null = $rows.Add(($l | ConvertFrom-Json)) } catch { $unparseable++ }
    }
    if ($unparseable -gt 0) { Add-Problem $subRunId "$subRunId has $unparseable unparseable ledger lines" }
    $resp = @($rows | Where-Object { [string]$_.kind -eq 'response' })
    $drops = @($rows | Where-Object { [string]$_.kind -eq 'dropped' })
    $res.responses = $resp.Count
    $res.dropped = $drops.Count

    $bodyLatAll = New-Object System.Collections.ArrayList
    $bodyLatOk = New-Object System.Collections.ArrayList
    $obsLag = New-Object System.Collections.ArrayList
    $dispLag = New-Object System.Collections.ArrayList
    $pers = New-Object System.Collections.ArrayList
    $winIn = 0; $winAfter = 0

    foreach ($r in $resp) {
        $sid = [string][int]$r.slot_index
        $pslot = if ($planBySlot.ContainsKey($sid)) { $planBySlot[$sid] } else { $null }
        $expectedId = if ($null -ne $pslot) { [string]$pslot.article_id } else { '' }
        $bytes = $null
        if ($null -ne $r.PSObject.Properties['body_base64'] -and $r.body_base64) { $bytes = [System.Convert]::FromBase64String([string]$r.body_base64) }
        $text = if ($null -ne $bytes) { [System.Text.Encoding]::UTF8.GetString($bytes) } else { $null }
        $timedOut = ($null -ne $r.PSObject.Properties['timeout'] -and [bool]$r.timeout)
        $err = if ($null -ne $r.PSObject.Properties['error']) { [string]$r.error } else { '' }
        $as = Get-P14aAssessment -Bytes $bytes -Text $text -HttpStatus ([int]$r.http) -ExpectedId $expectedId -Truth $truthById -TransportError $err -TimedOut $timedOut
        if ([bool]$as.correct) { $res.correct++ } else { $res.failures++ }
        # the DISPATCH LAG is measured from the frozen run origin, exactly as the collector does it. Using the absolute
        # monotonic stamp against a planned offset (which starts at 0) would report a huge number instead of a lag.
        $dispOffset = To-Num $r.dispatch_offset_ms
        if ($null -eq $dispOffset) {
            $origin0 = To-Num $coll.stats.monotonic.run_start_mono_ms
            if ($null -eq $origin0) {
                Add-Problem $subRunId ("$subRunId slot $sid has no dispatch_offset_ms and the run records no monotonic origin")
                continue
            }
            $dispOffset = $disp - $origin0
        }
        if ($null -ne $pslot) { $null = $dispLag.Add([Math]::Round($dispOffset - [double]$pslot.planned_offset_ms, 3)) }
        if ($timedOut) { $res.timeouts++ }

        $dispRaw = $r.PSObject.Properties['dispatch_mono_ms']
        $bodyRaw = $r.PSObject.Properties['body_ready_mono_ms']
        $obsRaw = $r.PSObject.Properties['observe_mono_ms']
        $hasNew = ($null -ne $dispRaw) -and ($null -ne $bodyRaw) -and ($null -ne $obsRaw)
        if (-not $hasNew) {
            if ($Mode -eq 'p14b') {
                $res.missing_stamp_records++
                Add-Problem $subRunId ("$subRunId slot $sid has no P1.4b stamps (dispatch/body_ready/observe); a P1.4b measurement cannot be judged from the legacy observation fields and is NOT defaulted to 0")
            } else { $res.legacy_only_records++ }
            continue
        }
        $disp = To-Num $r.dispatch_mono_ms
        $obs = To-Num $r.observe_mono_ms
        if ($null -eq $disp -or $null -eq $obs) {
            Add-Problem $subRunId ("$subRunId slot $sid has a non-numeric dispatch/observe stamp")
            continue
        }
        $lag = [Math]::Round($disp - [double]$pslot.planned_offset_ms, 3)
        if ($null -ne $pslot) { $null = $dispLag.Add($lag) }
        if ($null -ne $r.PSObject.Properties['ledger_written_mono_ms'] -and $null -ne (To-Num $r.ledger_written_mono_ms)) {
            $null = $pers.Add([Math]::Round((To-Num $r.ledger_written_mono_ms) - $obs, 3))
        }
        $bodyNumeric = To-Num $r.body_ready_mono_ms
        if ($null -eq $bodyNumeric) {
            # an honest "no complete body" row: excluded from the body population and counted, never imputed
            if ($null -eq $r.PSObject.Properties['body_ready_missing_reason']) {
                Add-Problem $subRunId ("$subRunId slot $sid has body_ready_mono_ms=null with no body_ready_missing_reason")
            }
            continue
        }
        $bl = [Math]::Round($bodyNumeric - $disp, 3)
        if ($bl -lt 0) {
            $res.negative_latency++
            Add-Problem $subRunId ("$subRunId slot $sid has a NEGATIVE body latency ($bl ms): body_ready precedes dispatch")
            continue
        }
        if (-not ($disp -le $bodyNumeric -and $bodyNumeric -le $obs)) {
            $res.out_of_order++
            Add-Problem $subRunId ("$subRunId slot $sid stamps are out of order: dispatch=$disp body_ready=$bodyNumeric observe=$obs")
            continue
        }
        $res.body_population++
        $null = $bodyLatAll.Add($bl)
        if ([bool]$as.correct) { $res.body_correct_population++; $null = $bodyLatOk.Add($bl) }
        $null = $obsLag.Add([Math]::Round($obs - $bodyNumeric, 3))
        if ($null -ne $r.PSObject.Properties['body_ready_offset_ms'] -and $null -ne (To-Num $r.body_ready_offset_ms)) {
            if ((To-Num $r.body_ready_offset_ms) -le $res.declared_window_ms) { $winIn++ } else { $winAfter++ }
        } else {
            # no offset stamp: derive it from the run's frozen origin and refuse if that is impossible
            $origin = To-Num $coll.stats.monotonic.run_start_mono_ms
            if ($null -eq $origin) {
                Add-Problem $subRunId ("$subRunId slot $sid has no body_ready_offset_ms and the run records no monotonic origin")
            } else {
                if (($bodyNumeric - $origin) -le $res.declared_window_ms) { $winIn++ } else { $winAfter++ }
            }
        }
    }

    $res.body_window = [ordered]@{
        declared_window_ms = $res.declared_window_ms; in_window = $winIn; after_window = $winAfter
        population = $res.body_population
        add_up = (($winIn + $winAfter) -eq $res.body_population)
        basis = 'body_ready_mono_ms (or its frozen offset) vs the plan.seconds boundary - NOT ended_ms'
    }
    $res.observe_window_legacy = [ordered]@{
        in_window = [int]$coll.stats.completed_in_window; after_window = [int]$coll.stats.completed_after_window
        basis = 'ended_ms (loop observation) - the OLD window, kept only as a separate figure'
    }
    if (-not $res.body_window.add_up) {
        Add-Problem $subRunId ("$subRunId body window {0}+{1} does not add up to its population {2}" -f $winIn, $winAfter, $res.body_population)
    }
    $res.body_latency_all_ms = (Get-P14aPercentiles -Values ([double[]]$bodyLatAll.ToArray()) -Percents @(50, 95, 99))
    $res.body_latency_correct_ms = (Get-P14aPercentiles -Values ([double[]]$bodyLatOk.ToArray()) -Percents @(50, 95, 99))
    $res.observe_lag_ms = (Get-P14aPercentiles -Values ([double[]]$obsLag.ToArray()) -Percents @(50, 95, 99))
    $res.dispatch_lag_mono_ms = (Get-P14aPercentiles -Values ([double[]]$dispLag.ToArray()) -Percents @(50, 95, 99))
    $res.persist_lag_ms = (Get-P14aPercentiles -Values ([double[]]$pers.ToArray()) -Percents @(50, 95, 99))

    # observer identity + its own interval
    $obs = $null
    if (Test-Path -LiteralPath $obsPath) {
        $obs = Get-Content -LiteralPath $obsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $res.observer = [ordered]@{
            pid = [int]$obs.observer_pid; collector_pid = [int]$obs.collector_pid
            interval_ms = [int]$obs.interval_ms; samples = [int]$obs.samples
            gap_max_ms = $obs.gaps.max_ms; sample_cost_max_ms = $obs.sample_cost_ms.max
            pause_applied = [bool]$obs.private_control.pause_applied
            pause_interval = $obs.private_control.pause_interval
            summary_sha256 = (Get-Sha2 $obsPath)
        }
        if ([int]$coll.pids.collector -ne [int]$obs.collector_pid) {
            Add-Problem $subRunId "$subRunId observer summary does not name this run's collector pid"
        }
    } elseif ($Mode -eq 'legacy') {
        # a pre-P1.4b copy has no observer by construction: that is a property of the copy, not a failed measurement
        $res['observer_legacy_absent'] = $true
    } else {
        Add-Problem $subRunId "$subRunId has no observer summary (its resource data cannot be attributed)"
    }

    # ---- the pre-registered quality gates ---------------------------------------------------------------
    $g = [ordered]@{
        has_plan = ($res.planned_slots -gt 0)
        zero_dropped = ($res.dropped -eq 0)
        zero_failures = ($res.failures -eq 0)
        zero_timeouts = ($res.timeouts -eq 0)
        correct_is_100_percent = (($res.correct -eq $res.responses) -and ($res.responses -gt 0))
        body_population_complete = ($res.body_population -gt 0)
        no_missing_stamps = ($res.missing_stamp_records -eq 0)
        no_negative_latency = ($res.negative_latency -eq 0)
        no_out_of_order_stamps = ($res.out_of_order -eq 0)
        body_window_adds_up = [bool]$res.body_window.add_up
        dispatch_lag_p95 = ($null -ne $res.dispatch_lag_mono_ms -and [double]$res.dispatch_lag_mono_ms.p95 -le $DispatchLagP95)
        dispatch_lag_p99 = ($null -ne $res.dispatch_lag_mono_ms -and [double]$res.dispatch_lag_mono_ms.p99 -le $DispatchLagP99)
        dispatch_lag_max = ($null -ne $res.dispatch_lag_mono_ms -and [double]$res.dispatch_lag_mono_ms.max -le $DispatchLagMax)
        observe_lag_p95 = ($null -ne $res.observe_lag_ms -and [double]$res.observe_lag_ms.p95 -le $ObserveLagP95)
        observe_lag_max = ($null -ne $res.observe_lag_ms -and [double]$res.observe_lag_ms.max -le $ObserveLagMax)
        slo_p95_candidate = ($null -ne $res.body_latency_correct_ms -and [double]$res.body_latency_correct_ms.p95 -le $SloP95CandidateMs)
        observer_identity_present = ($null -ne $res.observer)
    }
    $res.gates = $g
    $failed = @($g.Keys | Where-Object { -not [bool]$g[$_] })
    $res.failed_gates = $failed
    if ($failed.Count -gt 0) {
        Add-Problem $subRunId ("$subRunId is NOT a valid P1.4b measurement: failed $($failed -join ',')")
    }
    $res.problems = @($problemsByRun[$subRunId])
    return $res
}

$runResults = New-Object System.Collections.ArrayList
$budget = [ordered]@{ planned_slots = [long]0; offered = [long]0; runs = 0 }
foreach ($s in $subRuns) {
    $r = Get-SubRunResult $s.run_id $s.rate $s.pair $s.group
    $null = $runResults.Add($r)
    $budget.planned_slots += [long][Math]::Max(0, $r.planned_slots)
    $budget.runs++
    if (Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $RunRoot 'runs') $s.run_id) 'collect-result.json')) {
        $c = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $RunRoot 'runs') $s.run_id) 'collect-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $budget.offered += [long]$c.stats.offered
    }
}

# ---- tier admission: a rate needs EVERY (pair, group) present and passing -------------------------------------
$tiers = New-Object System.Collections.ArrayList
$tierValidity = New-Object System.Collections.ArrayList
$validatedTiers = New-Object System.Collections.ArrayList
$rateGroups = @{}
foreach ($r in $runResults) {
    if ($r.rate -le 0) { continue }
    if (-not $rateGroups.ContainsKey([int]$r.rate)) { $rateGroups[[int]$r.rate] = New-Object System.Collections.ArrayList }
    $null = $rateGroups[[int]$r.rate].Add($r)
}
foreach ($rate in @($rateGroups.Keys | Sort-Object)) {
    $rs = @($rateGroups[$rate])
    $expected = @()
    foreach ($p in @(1, 2)) { foreach ($g in @('A', 'B')) { $expected += "p$p$g" } }
    $have = @($rs | ForEach-Object { "p$($_.pair)$($_.group)" })
    $missing = @($expected | Where-Object { $have -notcontains $_ })
    $dupes = @($have | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    $bad = @($rs | Where-Object { $_.failed_gates.Count -gt 0 })
    $complete = ($missing.Count -eq 0) -and ($dupes.Count -eq 0) -and ($rs.Count -eq 4)
    $allPass = ($bad.Count -eq 0)
    $valid = $complete -and $allPass
    $reason = @()
    if ($missing.Count -gt 0) { $reason += "missing sub-run(s): $($missing -join ',')" }
    if ($dupes.Count -gt 0) { $reason += "duplicated sub-run(s): $($dupes -join ',')" }
    if ($bad.Count -gt 0) { $reason += "sub-run(s) failed the quality gates: $(($bad | ForEach-Object { $_.run_id }) -join ',')" }
    $null = $tierValidity.Add([ordered]@{
            rate_per_second = [int]$rate
            expected_subruns = @($expected); present_subruns = @($have)
            missing_subruns = @($missing); duplicated_subruns = @($dupes)
            complete = $complete; all_subruns_passed = $allPass
            p14b_valid = $valid; reason = ($reason -join '; ')
            subruns = @($rs | ForEach-Object { [ordered]@{ run_id = $_.run_id; pair = $_.pair; group = $_.group; failed_gates = @($_.failed_gates); body_latency_correct_ms = $_.body_latency_correct_ms; dispatch_lag_mono_ms = $_.dispatch_lag_mono_ms; body_window = $_.body_window } })
        })
    if ($valid) { $null = $validatedTiers.Add([int]$rate) }
    else { $null = $problems.Add("tier $rate req/s is NOT a validated P1.4b tier: $($reason -join '; ')") }
}

$budgetOk = ($budget.planned_slots -le $PlannedSlotBudget)
$summary = [ordered]@{
    run_id = $RunId
    mode = $Mode
    scope = 'P1.4b INDEPENDENT measurement summary: body-ready window, four-stamp integrity, quality gates and per rate/pair/group retention. Separate from the P1.4a business verdict.'
    out_path = $outPath
    quality_gates = [ordered]@{
        dispatch_lag = [ordered]@{ p95 = $DispatchLagP95; p99 = $DispatchLagP99; max = $DispatchLagMax }
        observe_lag = [ordered]@{ p95 = $ObserveLagP95; max = $ObserveLagMax }
        slo_p95_candidate_ms = $SloP95CandidateMs
        note = 'pre-registered by the card; never relaxed after seeing results. A rate with ANY failed gate is not a validated P1.4b tier.'
    }
    budget = [ordered]@{
        planned_slot_budget = $PlannedSlotBudget
        planned_slots_counted = $budget.planned_slots
        offered_counted = $budget.offered
        runs_counted = $budget.runs
        within_budget = $budgetOk
        basis = 'planned slots and offered requests per sub-run, NOT completed responses; the card budget is for all attempts together'
    }
    validated_tiers_req_per_second = @($validatedTiers)
    tier_validity = @($tierValidity)
    subruns = @($runResults)
    problems = @($problems)
    summary_sha256_note = 'the file hash is recorded in the root manifest; a self-referential hash is not embedded'
}
if (-not $budgetOk) { $null = $problems.Add("the planned-slot budget is exceeded: $($budget.planned_slots) > $PlannedSlotBudget") }
$summary['problems'] = @($problems)

$null = Write-P14aOnce -Path $outPath -Text ($summary | ConvertTo-Json -Depth 12) -EntryPoint 'p14b-summarize.ps1'
Write-Host ("p14b-summary={0} mode={1} subruns={2} validated_tiers={3} problems={4} planned_slots={5} budget_ok={6}" -f `
        $outPath, $Mode, $runResults.Count, ($validatedTiers -join ','), $problems.Count, $budget.planned_slots, $budgetOk)
foreach ($t in $tierValidity) { Write-Host ("  rate {0}: p14b_valid={1} complete={2} all_passed={3} {4}" -f $t.rate_per_second, $t.p14b_valid, $t.complete, $t.all_subruns_passed, $t.reason) }
if ($problems.Count -gt 0) { $problems | ForEach-Object { Write-Host "PROBLEM: $_" }; exit 1 }
exit 0
