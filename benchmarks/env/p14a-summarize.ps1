# P1.4a summariser: recompute every reported number from the ORIGINALS (ASCII only).
#
# It never trusts the collector's own summary: it re-reads each sampled ledger line by line, recomputes the
# percentiles with nearest-rank, recounts verdicts and drops, and joins every request to the server-side probe
# events by X-P1-Request-Id so cache hit / miss / rebuild / DAO counts are attributed per request.
#
# Exit codes: 0 = written, 1 = an inconsistency was found, 2 = usage problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$ProbeEventsDir = '',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts'
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14aRoots.ps1')

function Get-Normalized([string]$p) { return [System.IO.Path]::GetFullPath($p).TrimEnd('\', '/').ToLowerInvariant() }
function Test-UnderRoot([string]$path, [string]$root) {
    $p = Get-Normalized $path; $r = Get-Normalized $root
    if ($p -eq '' -or $r -eq '') { return $false }
    return ($p -eq $r) -or $p.StartsWith($r + '\') -or $p.StartsWith($r + '/')
}
# Parent-root lifecycle FIRST: a completed/sealed P1.4a root is refused before any read, write or output.
$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'p14a-summarize.ps1'
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (-not (Test-UnderRoot $RunRoot $ArtifactsRoot)) { Write-Host 'REFUSED: run root outside artifacts'; exit 2 }
$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$calPath = Join-Path $outDir 'calibration-result.json'
if (-not (Test-Path -LiteralPath $calPath)) { Write-Host "REFUSED: no calibration result at $calPath"; exit 2 }
$cal = Get-Content -LiteralPath $calPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($ProbeEventsDir)) { $ProbeEventsDir = Join-Path $RunRoot 'events' }
# the frozen truth and the fixed plans are re-read here, so the summary never depends on a collector self-report
$truthFileS = Join-Path (Join-Path $RunRoot 'plans') 'ids-truth.json'
$truthById = if (Test-Path -LiteralPath $truthFileS) { Get-P14aTruth -TruthFile $truthFileS } else { @{} }
$truthShaS = if (Test-Path -LiteralPath $truthFileS) { (Get-FileHash -LiteralPath $truthFileS -Algorithm SHA256).Hash.ToLower() } else { '' }

function Read-SharedLines([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $fs = $null; $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
        return @($sr.ReadToEnd() -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

# ---- server-side attribution: one pass over each group's probe events, grouped by the request id header ----
function Get-ProbeByRequest([string]$group) {
    $tag = "$($cal.run_id)-$group"
    $file = Join-Path $ProbeEventsDir "$tag.log"
    $byReq = @{}
    foreach ($line in (Read-SharedLines $file)) {
        $m = [regex]::Match($line, 'requestId=([^ ]*)')
        if (-not $m.Success) { continue }
        $rid = $m.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($rid) -or $rid -eq '-') { continue }
        if (-not $byReq.ContainsKey($rid)) { $byReq[$rid] = [ordered]@{ lines = 0; cache_hit = 0; cache_miss = 0; rebuild = 0; rebuild_write = 0; dao = 0; snapshot_found = 0; run_ids = @{}; article_ids = @{} } }
        $e = $byReq[$rid]
        $e.lines++
        # the SERVER side must also name this run and the article this slot is bound to, so both are collected here
        $mRun = [regex]::Match($line, 'runId=([^ ]*)')
        if ($mRun.Success -and $mRun.Groups[1].Value -ne '') { $e.run_ids[$mRun.Groups[1].Value] = 1 }
        $mArt = [regex]::Match($line, 'articleId=([^ ]*)')
        if ($mArt.Success -and $mArt.Groups[1].Value -ne '' -and $mArt.Groups[1].Value -ne '-') { $e.article_ids[$mArt.Groups[1].Value] = 1 }
        if ($line -match ' event=cache\.read ') { if ($line -match ' hit=True') { $e.cache_hit++ } else { $e.cache_miss++ } }
        if ($line -match ' event=rebuild\.begin ') { $e.rebuild++; if ($line -match ' writeCache=True') { $e.rebuild_write++ } }
        if ($line -match ' event=db\.enter ') { $e.dao++ }
        if ($line -match ' event=db\.snapshot\.end ') { if ($line -match ' found=true') { $e.snapshot_found++ } }
    }
    return [ordered]@{ file = (Split-Path -Leaf $file); requests = $byReq.Count; by_request_id = $byReq }
}

$probe = [ordered]@{}
foreach ($g in @('A', 'B')) { $probe[$g] = Get-ProbeByRequest $g }

# per-segment recomputed problem count, so the validated tier list is derived from the re-judgement and the identity
# checks rather than copied from the calibration self-report
$script:p14aSegmentProblemCount = @{}
$script:p14aGroupAdmission = @{}

# ---- rebuild every sampled statistic from the ledger originals ----
$perRun = [ordered]@{}
$problems = New-Object System.Collections.ArrayList
foreach ($seg in $cal.segments) {
    # segments[].groups is a deserialized JSON object, so iterate its properties (PSObject), not .Keys
    foreach ($gp in $seg.groups.PSObject.Properties) {
        $groupProblemStart = $problems.Count
        $g = $gp.Name
        $info = $gp.Value
        $runId = [string]$info.sample_run
        $ledger = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $runId) 'responses.jsonl'
        $lines = Read-SharedLines $ledger
        $rows = New-Object System.Collections.ArrayList
        $bad = 0
        foreach ($l in $lines) {
            try { $null = $rows.Add(($l | ConvertFrom-Json)) } catch { $bad++ }
        }
        $responses = @($rows | Where-Object { $_.kind -eq 'response' })
        $drops = @($rows | Where-Object { $_.kind -eq 'dropped' })
        # the STORED flags are kept ONLY as a comparison population; no statistic below is derived from them
        $storedCorrect = @($responses | Where-Object { $_.correct -eq $true })
        $storedVerdicts = @{}
        foreach ($r in $responses) { $v = [string]$r.verdict; if ($storedVerdicts.ContainsKey($v)) { $storedVerdicts[$v]++ } else { $storedVerdicts[$v] = 1 } }
        # body integrity: every recorded body must reproduce its own length and sha256
        $bodyOk = 0; $bodyBad = 0
        foreach ($r in $responses) {
            if ($null -eq $r.PSObject.Properties['body_base64']) { continue }
            $raw = [System.Convert]::FromBase64String([string]$r.body_base64)
            if ($raw.Length -eq [int]$r.bytes -and (Get-P14aSha256 $raw) -eq [string]$r.sha256) { $bodyOk++ } else { $bodyBad++ }
        }
        # ---- FROZEN PLAN BINDING ----------------------------------------------------------------
        # The plan file, not the ledger, owns the expected slot set: slot_index -> planned offset, article id and
        # path. Every record (response AND drop) must sit inside that set exactly once, and every id the record or
        # the server names must be the one THIS slot is bound to. A ledger that is internally self-consistent but
        # describes a different slot, or a body/target pair swapped for another legal article, must fail here.
        $planFile = Join-Path (Join-Path $RunRoot 'plans') ('plan-r{0}-sample.json' -f [int]$seg.rate_per_second)
        $planSha = ''
        $declaredWindowMs = [long]0
        $plannedSlots = -1
        $planBySlot = @{}
        $planLoaded = $false
        if (Test-Path -LiteralPath $planFile) {
            $planSha = (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash.ToLower()
            $pobj = Get-Content -LiteralPath $planFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $pobj.PSObject.Properties['seconds']) { $declaredWindowMs = [long]([int]$pobj.seconds * 1000) }
            $plannedSlots = [int]$pobj.slot_count
            foreach ($ps in @($pobj.slots)) {
                $slotPath = if ($null -ne $ps.PSObject.Properties['path'] -and $ps.path) { [string]$ps.path } else { ('/api/v1/article/detail/' + [string]$ps.article_id) }
                $planBySlot[[string][int]$ps.slot_index] = [ordered]@{
                    slot_index = [int]$ps.slot_index; planned_offset_ms = [long]$ps.planned_offset_ms
                    article_id = [string]$ps.article_id; path = $slotPath
                }
            }
            $planLoaded = ($planBySlot.Count -eq $plannedSlots)
        }
        # the run's own collect-result must name THIS plan hash, and an empty / missing value is itself a failure
        $reportedPlanSha = ''
        $collectBase = ''
        $collResultPath = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $runId) 'collect-result.json'
        $collectResultPresent = Test-Path -LiteralPath $collResultPath
        if ($collectResultPresent) {
            $cobj = Get-Content -LiteralPath $collResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $cobj.PSObject.Properties['plan']) { $reportedPlanSha = [string]$cobj.plan.sha256 }
            if ($null -ne $cobj.PSObject.Properties['base']) { $collectBase = [string]$cobj.base }
        }
        $collectBase = $collectBase.TrimEnd('/')

        $reOk = 0; $reBad = 0; $reMismatch = 0; $reVerds = @{}
        $reOkLat = New-Object System.Collections.ArrayList
        $reAllLat = New-Object System.Collections.ArrayList
        $reFailures = 0; $reTimeouts = 0
        $winIn = 0; $winAfter = 0; $seqOk = $true; $seqExpect = 1
        $slotSeen = @{}; $slotDup = 0; $ridSeen = @{}; $ridDup = 0
        $respRidSeen = @{}; $dropRidSeen = @{}
        $recordedWindowMismatch = 0
        $untagged = 0
        $planUnknownSlot = 0; $planIdMismatch = 0; $planUrlMismatch = 0; $planOffsetMismatch = 0
        $planRidMismatch = 0; $planRunMismatch = 0; $planGroupMismatch = 0; $bodyIdMismatch = 0
        $planBoundOk = 0
        $urlNotBound = 0; $urlPortMismatch = 0
        foreach ($row in $rows) {
            if ([long]$row.seq -ne $seqExpect) { $seqOk = $false }
            $seqExpect++
            $sid = [string][int]$row.slot_index
            if ($slotSeen.ContainsKey($sid)) { $slotDup++ } else { $slotSeen[$sid] = 1 }
            $pslot = if ($planBySlot.ContainsKey($sid)) { $planBySlot[$sid] } else { $null }
            if ($null -eq $pslot) { $planUnknownSlot++ }
            if ([string]$row.run_id -ne $runId) { $planRunMismatch++ }
            $rowGroup = if ($null -ne $row.PSObject.Properties['group']) { [string]$row.group } else { '' }
            if ($rowGroup -ne $g) { $planGroupMismatch++ }
            $rowRid = if ($null -ne $row.PSObject.Properties['request_id']) { [string]$row.request_id } else { '' }
            if ($rowRid -ne ('{0}-{1}-s{2}' -f $runId, $g, $sid)) { $planRidMismatch++ }
            if ($rowRid -ne '') {
                if ($ridSeen.ContainsKey($rowRid)) { $ridDup++ } else { $ridSeen[$rowRid] = 1 }
                # the two populations are DIFFERENT on purpose: a response belongs to the client-response set, a drop
                # does not. The server side is matched against the RESPONSE set only, so a request that really
                # reached the server can never be excused as "dropped".
                if ([string]$row.kind -eq 'response') { $respRidSeen[$rowRid] = 1 } else { $dropRidSeen[$rowRid] = 1 }
            }
            if ($null -ne $pslot) {
                if ([long]$row.planned_offset_ms -ne $pslot.planned_offset_ms) { $planOffsetMismatch++ }
                # a dropped slot is checked the same way: its intended id must be the plan's id for this slot
                if ([string]$row.kind -eq 'dropped') {
                    if ([string]$row.intended_article_id -ne $pslot.article_id) { $planIdMismatch++ }
                }
            }
            if ([string]$row.kind -ne 'response') { continue }
            if ($null -ne $pslot) {
                if ([string]$row.target_article_id -ne $pslot.article_id) { $planIdMismatch++ }
                # the FULL url must be the frozen base + the plan path. A same path on another port is a different
                # endpoint and must not pass, so the comparison is exact rather than EndsWith.
                $expectedUrl = if ($collectBase -ne '') { $collectBase + $pslot.path } else { '' }
                $actualUrl = [string]$row.url
                if ($expectedUrl -eq '') {
                    $urlNotBound++
                } elseif ($actualUrl -cne $expectedUrl) {
                    $planUrlMismatch++
                    if ($actualUrl.EndsWith($pslot.path)) { $urlPortMismatch++ }
                }
            }
            $raw2 = $null
            if ($null -ne $row.PSObject.Properties['body_base64']) { $raw2 = [System.Convert]::FromBase64String([string]$row.body_base64) }
            $txt2 = if ($null -ne $raw2) { [System.Text.Encoding]::UTF8.GetString($raw2) } else { $null }
            $timedOut2 = ($null -ne $row.PSObject.Properties['timeout'] -and [bool]$row.timeout)
            $err2 = if ($null -ne $row.PSObject.Properties['error']) { [string]$row.error } else { '' }
            # the EXPECTED id comes from the frozen plan; the ledger's own target is never used as the expectation
            $expectedId = if ($null -ne $pslot) { $pslot.article_id } else { '' }
            $as2 = Get-P14aAssessment -Bytes $raw2 -Text $txt2 -HttpStatus ([int]$row.http) -ExpectedId $expectedId -Truth $truthById -TransportError $err2 -TimedOut $timedOut2
            # ---- the ONE population every statistic below is derived from: the re-judged, plan-bound result ----
            $null = $reAllLat.Add([double]$row.elapsed_ms)
            if ($as2.correct) { $reOk++; $null = $reOkLat.Add([double]$row.elapsed_ms) } else { $reBad++ }
            if ($timedOut2) { $reTimeouts++ }
            if (-not $as2.correct -and -not $timedOut2) { $reFailures++ }
            if ($reVerds.ContainsKey($as2.verdict)) { $reVerds[$as2.verdict]++ } else { $reVerds[$as2.verdict] = 1 }
            if ([string]$as2.verdict -ne [string]$row.verdict -or [bool]$as2.correct -ne ([bool]$row.correct)) { $reMismatch++ }
            if ($null -ne $pslot) {
                if (-not $as2.id_is_string -or -not $as2.id_matches) { $bodyIdMismatch++ } else { $planBoundOk++ }
            }
            if ($null -ne $row.PSObject.Properties['declared_window_ms']) {
                if ([long]$row.declared_window_ms -ne $declaredWindowMs) { $recordedWindowMismatch++ }
            } else { $untagged++ }
            if ([long]$row.ended_ms -le $declaredWindowMs) { $winIn++ } else { $winAfter++ }
        }
        # every frozen slot must be accounted for exactly once (a missing slot cannot be replaced by an extra one)
        $missingSlots = @($planBySlot.Keys | Where-Object { -not $slotSeen.ContainsKey([string]$_) })
        # the reverse direction is matched against the RESPONSE request ids ONLY
        $probeOnly = 0; $dropWithServerEvents = 0
        foreach ($pk in $probe[$g].by_request_id.Keys) {
            if (-not ([string]$pk).StartsWith($runId + '-')) { continue }
            if (-not $respRidSeen.ContainsKey([string]$pk)) {
                $probeOnly++
                if ($dropRidSeen.ContainsKey([string]$pk)) { $dropWithServerEvents++ }
            }
        }
        # join to the server side AND bind the server's own runId/articleId to this slot.
        # An empty identity set is NOT "nothing to check": the server MUST name this run and this slot's article.
        $joined = 0; $hit = 0; $miss = 0; $rebuild = 0; $dao = 0; $direct = 0; $unmatched = 0
        $serverRunMismatch = 0; $serverArticleMismatch = 0; $serverMissingRun = 0; $serverMissingArticle = 0
        foreach ($r in $responses) {
            $rid = [string]$r.request_id
            $sid = [string][int]$r.slot_index
            $pslot = if ($planBySlot.ContainsKey($sid)) { $planBySlot[$sid] } else { $null }
            if ($probe[$g].by_request_id.ContainsKey($rid)) {
                $joined++
                $e = $probe[$g].by_request_id[$rid]
                if ($e.cache_hit -gt 0) { $hit++ }
                if ($e.cache_miss -gt 0) { $miss++ }
                if ($e.rebuild -gt 0) { $rebuild++ }
                if ($e.rebuild -gt 0 -and $e.cache_hit -eq 0 -and $e.cache_miss -eq 0) { $direct++ }
                $dao += [int]$e.dao
                $runKeys = @($e.run_ids.Keys)
                $artKeys = @($e.article_ids.Keys)
                if ($runKeys.Count -eq 0) { $serverMissingRun++ }
                else { foreach ($sr in $runKeys) { if ([string]$sr -ne $runId) { $serverRunMismatch++ } } }
                if ($artKeys.Count -eq 0) { $serverMissingArticle++ }
                elseif ($null -ne $pslot) { foreach ($sa in $artKeys) { if ([string]$sa -ne $pslot.article_id) { $serverArticleMismatch++ } } }
            } else { $unmatched++ }
        }
        $stats = [ordered]@{
            rate_per_second = [int]$seg.rate_per_second
            group = $g
            run_id = $runId
            ledger_lines = $lines.Count
            parsed_rows = $rows.Count
            unparseable = $bad
            responses = $responses.Count
            dropped = $drops.Count
            # ---- one population: everything here comes from the re-judged, plan-bound set ----
            correct = $reOk
            not_correct = $reBad
            failures = $reFailures
            timeouts = $reTimeouts
            latency_all_ms = (Get-P14aPercentiles -Values ([double[]]$reAllLat.ToArray()))
            latency_correct_ms = (Get-P14aPercentiles -Values ([double[]]$reOkLat.ToArray()))
            verdicts = $reVerds
            population = [ordered]@{
                correct = $reOk
                correct_latency_samples = $reOkLat.Count
                consistent = ($reOk -eq $reOkLat.Count)
                rule = 'the correct count, its latency samples, the verdicts, the failures/timeouts, the window split and the tier validity are all derived from the same re-judged + plan-bound population; the stored flags appear ONLY under stored_flags'
            }
            # comparison only - never used for a reported number
            stored_flags = [ordered]@{
                correct = $storedCorrect.Count
                correct_latency_samples = $storedCorrect.Count
                latency_correct_ms = (Get-P14aPercentiles -Values ([double[]]@($storedCorrect | ForEach-Object { [double]$_.elapsed_ms })))
                verdicts = $storedVerdicts
                disagreements_with_rejudgement = $reMismatch
            }
            body_sha256_verified = $bodyOk
            body_sha256_failed = $bodyBad
            server_side = [ordered]@{
                joined_requests = $joined
                unmatched_requests = $unmatched
                cache_hit = $hit
                cache_miss = $miss
                direct_rebuild = $direct
                rebuild_total = $rebuild
                dao_calls_total = $dao
                dao_calls_per_request = $(if ($joined -gt 0) { [Math]::Round($dao / [double]$joined, 3) } else { -1 })
                source = "events/$($probe[$g].file) grouped by X-P1-Request-Id (DAO evidence only; physical SQL was not logged)"
            }
            collector_reported = [ordered]@{ offered = $info.offered; started = $info.started; completed = $info.completed; dropped = $info.dropped; correct = $info.correct; timeouts = $info.timeouts; drain_ms = $info.drain_ms }
            reassessed_from_originals = [ordered]@{
                correct = $reOk
                not_correct = $reBad
                verdicts = $reVerds
                disagreements_with_stored_flags = $reMismatch
                truth_sha256 = $truthShaS
                method = 'each decoded body is re-judged against plans/ids-truth.json by the same assessment function; the stored correct/verdict flags are NOT used'
            }
            window = [ordered]@{
                declared_window_ms = $declaredWindowMs
                in_window = $winIn
                after_window = $winAfter
                add_up = (($winIn + $winAfter) -eq $responses.Count)
                records_without_declared_window = $untagged
                recorded_window_mismatch = $recordedWindowMismatch
            }
            slot_integrity = [ordered]@{
                planned_slots = $plannedSlots
                plan_file = 'plans/plan-r' + [int]$seg.rate_per_second + '-sample.json'
                plan_sha256 = $planSha
                plan_sha256_reported_by_the_run = $reportedPlanSha
                plan_sha_reported_present = ($reportedPlanSha -ne '')
                plan_sha_matches_run = ($planSha -ne '' -and $reportedPlanSha -ne '' -and $planSha -eq $reportedPlanSha)
                plan_loaded_completely = $planLoaded
                collect_result_present = $collectResultPresent
                base = $collectBase
                accounted = ($responses.Count + $drops.Count)
                duplicate_slots = $slotDup
                duplicate_request_ids = $ridDup
                seq_contiguous = $seqOk
                server_events_without_response = $probeOnly
                dropped_requests_with_server_events = $dropWithServerEvents
            }
            plan_binding = [ordered]@{
                expected_source = 'the FROZEN plan file; the ledger''s own target_article_id is never used as the expectation'
                slots_outside_the_plan = $planUnknownSlot
                slots_missing_from_the_ledger = @($missingSlots | ForEach-Object { [int]$_ } | Sort-Object)
                target_id_differs_from_the_plan = $planIdMismatch
                url_differs_from_the_plan = $planUrlMismatch
                url_used_a_different_base_not_just_a_path = $urlPortMismatch
                url_could_not_be_bound = $urlNotBound
                planned_offset_differs_from_the_plan = $planOffsetMismatch
                request_id_not_derived_from_run_group_slot = $planRidMismatch
                record_run_id_mismatch = $planRunMismatch
                record_group_mismatch = $planGroupMismatch
                body_article_id_differs_from_the_plan = $bodyIdMismatch
                bodies_bound_to_the_plan = $planBoundOk
                server_run_id_mismatch = $serverRunMismatch
                server_run_id_missing = $serverMissingRun
                server_article_id_differs_from_the_plan = $serverArticleMismatch
                server_article_id_missing = $serverMissingArticle
            }
            tier_admission = $admission
            collector_cpu_percent_max = $info.collector_cpu_percent_max
            schedule_lag_ms = $info.schedule_lag_ms
        }
# (the per-run entry is stored AFTER the admission gate below, so tier_admission is not empty)
        if ($bad -gt 0) { $null = $problems.Add("$runId has $bad unparseable ledger lines") }
        if ($bodyBad -gt 0) { $null = $problems.Add("$runId has $bodyBad lines whose body does not reproduce its bytes/sha256") }
        if ($responses.Count -ne [int]$info.completed) { $null = $problems.Add("$runId responses=$($responses.Count) but the collector reported completed=$($info.completed)") }
        if ($unmatched -gt 0) { $null = $problems.Add("$runId has $unmatched requests without a matching server-side probe record") }
        if ($reBad -gt 0) { $null = $problems.Add("$runId has $reBad responses that are NOT correct when re-judged from the originals") }
        if ($reMismatch -gt 0) { $null = $problems.Add("$runId has $reMismatch stored flags that disagree with the independent re-judgement") }
        if ($slotDup -gt 0) { $null = $problems.Add("$runId has $slotDup duplicate slot indices") }
        if ($ridDup -gt 0) { $null = $problems.Add("$runId has $ridDup duplicate request ids") }
        if (-not $seqOk) { $null = $problems.Add("$runId ledger seq is not contiguous from 1") }
        if ($recordedWindowMismatch -gt 0) { $null = $problems.Add("$runId has $recordedWindowMismatch records whose declared window differs from the frozen plan") }
        if (-not (($winIn + $winAfter) -eq $responses.Count)) { $null = $problems.Add(('{0} window in={1} after={2} does not add up to {3} responses' -f $runId, $winIn, $winAfter, $responses.Count)) }
        if ($probeOnly -gt 0) { $null = $problems.Add("$runId has $probeOnly server-side request ids without a client response record") }
        # ---- frozen-plan binding: every one of these is an independent reason to reject ----
        if (-not (Test-Path -LiteralPath $planFile)) { $null = $problems.Add("$runId has no frozen plan at $planFile") }
        elseif (-not $planLoaded) { $null = $problems.Add("$runId frozen plan does not declare slots matching slot_count (plan loaded incompletely)") }
        if ($planSha -eq '') { $null = $problems.Add("$runId has no frozen plan file to compare against") }
        elseif ($reportedPlanSha -eq '') { $null = $problems.Add("$runId does not report a plan sha256 in its collect-result (a missing or empty plan hash is not evidence)") }
        elseif ($planSha -ne $reportedPlanSha) { $null = $problems.Add("$runId was collected from plan sha $reportedPlanSha but the frozen plan is $planSha") }
        if (-not $collectResultPresent) { $null = $problems.Add("$runId has no collect-result.json next to its ledger") }
        if ($collectBase -eq '') { $null = $problems.Add("$runId has no endpoint base in its collect-result, so its URLs cannot be bound to the frozen plan") }
        if ($urlNotBound -gt 0) { $null = $problems.Add("$runId has $urlNotBound records whose URL could not be bound (no endpoint base)") }
        if ($planUnknownSlot -gt 0) { $null = $problems.Add("$runId has $planUnknownSlot records whose slot_index is not in the frozen plan") }
        if ($missingSlots.Count -gt 0) { $null = $problems.Add(('{0} ledger has no record for frozen plan slots: {1}' -f $runId, (($missingSlots | Sort-Object) -join ','))) }
        if ($planIdMismatch -gt 0) { $null = $problems.Add("$runId has $planIdMismatch records whose article id is not the id the frozen plan binds to that slot") }
        if ($planUrlMismatch -gt 0) { $null = $problems.Add("$runId has $planUrlMismatch records whose FULL url is not the frozen base plus the plan's path for that slot ($urlPortMismatch of them use the right path on a different base)") }
        if ($planOffsetMismatch -gt 0) { $null = $problems.Add("$runId has $planOffsetMismatch records whose planned offset differs from the frozen plan") }
        if ($planRidMismatch -gt 0) { $null = $problems.Add("$runId has $planRidMismatch request ids that are not run-group-slot derived") }
        if ($planRunMismatch -gt 0) { $null = $problems.Add("$runId has $planRunMismatch records with a foreign run_id") }
        if ($planGroupMismatch -gt 0) { $null = $problems.Add("$runId has $planGroupMismatch records with a foreign group") }
        if ($bodyIdMismatch -gt 0) { $null = $problems.Add("$runId has $bodyIdMismatch bodies whose real article id is not the plan's id for that slot") }
        if ($serverRunMismatch -gt 0) { $null = $problems.Add("$runId has $serverRunMismatch server events naming a different run id") }
        if ($serverArticleMismatch -gt 0) { $null = $problems.Add("$runId has $serverArticleMismatch server events naming an article id the plan does not bind to that slot") }
        if ($serverMissingRun -gt 0) { $null = $problems.Add("$runId has $serverMissingRun joined requests whose server events name no runId at all (an empty identity set is not evidence)") }
        if ($serverMissingArticle -gt 0) { $null = $problems.Add("$runId has $serverMissingArticle joined requests whose server events name no articleId at all") }
        if ($dropWithServerEvents -gt 0) { $null = $problems.Add("$runId has $dropWithServerEvents request ids that are recorded as DROPPED but do have server-side events (the server saw a request the client claims it never sent)") }
        if ($reOk -ne $reOkLat.Count) { $null = $problems.Add(('{0} correct={1} but its correct latency sample count is {2} (the two must come from the same population)' -f $runId, $reOk, $reOkLat.Count)) }
        # ---- TIER ADMISSION (section 9) ---------------------------------------------------------
        # The problem list alone is NOT the admission gate: a perfectly legal drop (never sent to the server, no
        # server-side event) produced no problem at all, so an offered=10/started=1/completed=1/dropped=9 run was
        # reported as a validated tier. The section-4 rule is "any dropped slot invalidates the segment", so the
        # gate is now an explicit conjunction over the re-judged, plan-bound, identity-checked population.
        # ---- the collector's own traffic counters must EXIST, be legal, and match the originals ----------------
        # The previous version read these fields with a -1 sentinel and then excused anything <0 (or, for the
        # in-flight count, <=0). That made a DELETED stats field look reconciled, and it compared started with
        # completed as two self-reported numbers instead of comparing them with the ledger. Both are fixed here:
        # each field is validated losslessly and then compared with the recalculated value from the plan and ledger.
        $trafficFields = @(
            @{ name = 'offered'; kind = 'count' },
            @{ name = 'started'; kind = 'count' },
            @{ name = 'completed'; kind = 'count' },
            @{ name = 'dropped'; kind = 'count' },
            @{ name = 'inflight_at_end'; kind = 'count' },
            @{ name = 'interrupted'; kind = 'bool' }
        )
        $traffic = [ordered]@{}
        $cs = $null
        if ($collectResultPresent -and ($null -ne $cobj.PSObject.Properties['stats'])) { $cs = $cobj.stats }
        foreach ($tf in $trafficFields) {
            $fname = $tf.name
            $st = [ordered]@{ ok = $false; value = $null; reported = $null; reason = '' }
            if ($null -eq $cs) {
                $st.reason = "collect-result.stats is missing, so $fname cannot be checked"
            } elseif ($null -eq $cs.PSObject.Properties[$fname]) {
                $st.reason = "collect-result.stats.$fname is missing"
            } else {
                $node = $cs.$fname
                $st.reported = $node
                if ($tf.kind -eq 'bool') {
                    # a JSON boolean only: a string/number/null is not a reconciliation result
                    if ($node -is [bool]) { $st.ok = $true; $st.value = [bool]$node }
                    else { $st.reason = "collect-result.stats.$fname is $(Get-P14aNodeType $node), not a JSON boolean" }
                } else {
                    # a lossless non-negative integer: no -1 sentinel, no rounding, no string coercion
                    $conv = ConvertTo-P14aIntegral -Node $node -Min ([long]0) -Max ([long]::MaxValue) -Field "collect-result.stats.$fname"
                    if ($conv.ok) { $st.ok = $true; $st.value = [long]$conv.value }
                    else { $st.reason = $conv.reason }
                }
            }
            if (-not $st.ok) { $null = $problems.Add(('{0} group {1}: {2}' -f $runId, $g, $st.reason)) }
            $traffic[$fname] = $st
        }
        $collectorOffered = if ($traffic['offered'].ok) { [long]$traffic['offered'].value } else { [long]-1 }
        $collectorStarted = if ($traffic['started'].ok) { [long]$traffic['started'].value } else { [long]-1 }
        $collectorCompleted = if ($traffic['completed'].ok) { [long]$traffic['completed'].value } else { [long]-1 }
        $collectorDropped = if ($traffic['dropped'].ok) { [long]$traffic['dropped'].value } else { [long]-1 }
        $collectorInflight = if ($traffic['inflight_at_end'].ok) { [long]$traffic['inflight_at_end'].value } else { [long]-1 }
        $collectorInterrupted = if ($traffic['interrupted'].ok) { [bool]$traffic['interrupted'].value } else { $null }
        # what the ORIGINALS say the counters must be
        $expectOffered = [long]$plannedSlots
        $expectAccounted = [long]($responses.Count + $drops.Count)
        $expectStartedCompleted = [long]$responses.Count
        $expectDropped = [long]$drops.Count
        # ---- the calibration file's own counters, cross-checked against the originals (extra evidence only) -------
        # `info` is the calibration self-report for this group; its numbers must not contradict the ledger. A missing
        # field is recorded as not_reported (an older file), but a PRESENT value that differs is a problem.
        $calCounters = [ordered]@{ offered = $null; started = $null; completed = $null; dropped = $null }
        $calCounterMismatch = 0
        foreach ($ck in @('offered', 'started', 'completed', 'dropped')) {
            if ($null -ne $info.PSObject.Properties[$ck]) {
                $calCounters[$ck] = $info.$ck
                $convCal = ConvertTo-P14aIntegral -Node $info.$ck -Min ([long]0) -Max ([long]::MaxValue) -Field "calibration-result.groups.$g.$ck"
                if (-not $convCal.ok) {
                    $calCounterMismatch++
                    $null = $problems.Add(('{0} group {1}: calibration-result counter is illegal: {2}' -f $runId, $g, $convCal.reason))
                } else {
                    $want = switch ($ck) {
                        'offered' { $expectOffered }
                        'started' { $expectStartedCompleted }
                        'completed' { $expectStartedCompleted }
                        'dropped' { $expectDropped }
                    }
                    if ([long]$convCal.value -ne [long]$want) {
                        $calCounterMismatch++
                        $null = $problems.Add(('{0} group {1}: calibration-result {2}={3} but the originals say {4}' -f $runId, $g, $ck, $convCal.value, $want))
                    }
                }
            } else {
                $calCounters[$ck] = 'not_reported'
            }
        }
        $groupProblems = $problems.Count - $groupProblemStart
        $conditions = [ordered]@{
            # every required traffic field is present, typed and non-negative
            traffic_fields_present_and_legal = (@($traffic.Keys | Where-Object { -not $traffic[$_].ok }).Count -eq 0)
            # any drop, however legal and however invisible on the server side, invalidates the segment
            dropped_is_zero = ($drops.Count -eq 0)
            collector_agrees_on_dropped = ($traffic['dropped'].ok -and $collectorDropped -eq $expectDropped)
            # offered: the frozen plan's slot count AND the accounted records AND the collector's own number
            offered_equals_plan_and_accounted = (($expectAccounted -eq $expectOffered) -and $traffic['offered'].ok -and
                ($collectorOffered -eq $expectOffered) -and ($collectorOffered -eq $expectAccounted))
            offered_equals_started_plus_dropped = ($traffic['offered'].ok -and $traffic['started'].ok -and $traffic['dropped'].ok -and
                ($collectorOffered -eq ($collectorStarted + $collectorDropped)))
            # started and completed both equal the ledger's response count, and each other
            started_equals_completed_after_drain = ($traffic['started'].ok -and $traffic['completed'].ok -and
                $traffic['interrupted'].ok -and $traffic['inflight_at_end'].ok -and
                ($collectorStarted -eq $expectStartedCompleted) -and ($collectorCompleted -eq $expectStartedCompleted) -and
                ($collectorStarted -eq $collectorCompleted) -and (-not $collectorInterrupted) -and ($collectorInflight -eq 0))
            # correctness: every completed response is correct, none is a failure or a timeout
            no_failed_responses = ($reBad -eq 0)
            no_timeouts = ($reTimeouts -eq 0)
            correct_rate_is_100_percent = (($responses.Count -gt 0) -and ($reOk -eq $responses.Count))
            correct_equals_its_latency_samples = ($reOk -eq $reOkLat.Count)
            # the calibration file's own counters must not contradict the originals (extra cross-check only)
            calibration_counters_agree_with_originals = ($calCounterMismatch -eq 0)
            # plan / URL / body / server identity / bidirectional events all reconciled
            plan_present_and_hash_matched = ($planLoaded -and $planSha -ne '' -and ($reportedPlanSha -ne '') -and ($planSha -eq $reportedPlanSha))
            no_reconciliation_problem = ($groupProblems -eq 0)
        }
        $failed = @($conditions.Keys | Where-Object { -not [bool]$conditions[$_] })
        $admitted = ($failed.Count -eq 0)
        # every failed admission condition becomes a problem, so this segment can never be reported as valid
        foreach ($fc in $failed) {
            $null = $problems.Add(('{0} group {1} is NOT admitted: {2} (dropped={3} correct={4}/{5} failures={6} timeouts={7})' -f `
                        $runId, $g, $fc, $drops.Count, $reOk, $responses.Count, $reBad, $reTimeouts))
        }
        $admission = [ordered]@{
            admitted = $admitted
            conditions = $conditions
            failed_conditions = @($failed)
            counted_from_originals = [ordered]@{
                planned_slots = $plannedSlots; responses = $responses.Count; dropped = $drops.Count
                correct = $reOk; not_correct = $reBad; timeouts = $reTimeouts
            }
            collector_cross_check = [ordered]@{
                offered = $collectorOffered; started = $collectorStarted; completed = $collectorCompleted
                dropped = $collectorDropped; interrupted = $collectorInterrupted; inflight_at_end = $collectorInflight
                expected_from_originals = [ordered]@{
                    offered = $expectOffered; accounted = $expectAccounted
                    started = $expectStartedCompleted; completed = $expectStartedCompleted; dropped = $expectDropped
                    interrupted = $false; inflight_at_end = 0
                }
                fields = $traffic
                calibration_counters = [ordered]@{ reported = $calCounters; mismatches = $calCounterMismatch }
            }
            rule = 'a group is admitted only when every required collector counter is present, legal and equal to the value recalculated from the frozen plan and the ledger (offered = plan slots = responses + drops, started = completed = responses, dropped = drops, offered = started + dropped, interrupted false, inflight_at_end 0), additionally zero drop, no failure and no timeout, correct = completed = its latency samples, and the plan/URL/body/server-identity/event reconciliation produced no problem; a LEGAL drop still invalidates the group'
        }
        $stats['tier_admission'] = $admission
        $perRun["r$($seg.rate_per_second)-$g"] = $stats
        if (-not $script:p14aGroupAdmission.ContainsKey([int]$seg.rate_per_second)) { $script:p14aGroupAdmission[[int]$seg.rate_per_second] = [ordered]@{} }
        $script:p14aGroupAdmission[[int]$seg.rate_per_second][$g] = $admission
        # the running problem count (now including failed admission conditions) decides this segment's validity
        $script:p14aSegmentProblemCount[[int]$seg.rate_per_second] = [int]$script:p14aSegmentProblemCount[[int]$seg.rate_per_second] + ($problems.Count - $groupProblemStart)
    }
}

# ---- validated tiers are RECOMPUTED from the ORIGINALS ----------------------------------------------------------
# A tier is valid only when BOTH of its groups are admitted by the section-9 gate (no drop at all, no failure, no
# timeout, correct == completed == its latency samples, offered = started + dropped after draining, and the
# plan/URL/body/server-identity/event reconciliation produced no problem). The calibration self-report is kept beside
# it as a comparison, never as the deciding value, and a missing group can never be admitted.
$segmentValidity = New-Object System.Collections.ArrayList
$validTiers = New-Object System.Collections.ArrayList
foreach ($seg in $cal.segments) {
    $rate = [int]$seg.rate_per_second
    $segProblems = if ($script:p14aSegmentProblemCount.ContainsKey($rate)) { [int]$script:p14aSegmentProblemCount[$rate] } else { 0 }
    $groupStates = if ($script:p14aGroupAdmission.ContainsKey($rate)) { $script:p14aGroupAdmission[$rate] } else { [ordered]@{} }
    $groupKeys = @($groupStates.Keys)
    $missingGroups = @(@('A', 'B') | Where-Object { $groupKeys -notcontains $_ })
    $notAdmitted = @($groupKeys | Where-Object { -not [bool]$groupStates[$_].admitted })
    $bothPresent = ($missingGroups.Count -eq 0)
    $recomputedValid = ($segProblems -eq 0) -and $bothPresent -and ($notAdmitted.Count -eq 0)
    $reason = @()
    if ($segProblems -gt 0) { $reason += "$segProblems reconciliation problem(s)" }
    if (-not $bothPresent) { $reason += "missing group(s): $($missingGroups -join ',')" }
    if ($notAdmitted.Count -gt 0) { $reason += "group(s) not admitted: $($notAdmitted -join ',')" }
    $null = $segmentValidity.Add([ordered]@{
            rate_per_second = $rate
            recomputed_valid = $recomputedValid
            recomputed_reason = ($reason -join '; ')
            recomputed_problem_count = $segProblems
            groups_present = @($groupKeys)
            groups_missing = @($missingGroups)
            groups_admitted = @($groupKeys | Where-Object { [bool]$groupStates[$_].admitted })
            groups_not_admitted = @($notAdmitted)
            groups = $groupStates
            calibration_self_reported_valid = [bool]$seg.valid
            calibration_self_reported_reason = [string]$seg.invalid_reason
            note = 'the validated/comparison population is decided by recomputed_valid, which requires both groups to be admitted by the section-9 gate; the self-report is kept only for comparison'
        })
    if (-not $recomputedValid) { $null = $problems.Add(('tier {0} req/s is NOT a validated tier: {1}' -f $rate, ($reason -join '; '))) }
    if ($recomputedValid) { $null = $validTiers.Add($rate) }
}
$comparison = New-Object System.Collections.ArrayList
foreach ($rate in $validTiers) {
    $a = $perRun["r$rate-A"]; $b = $perRun["r$rate-B"]
    if ($null -eq $a -or $null -eq $b) { continue }
    $null = $comparison.Add([ordered]@{
            rate_per_second = $rate
            A = [ordered]@{ p50 = $a.latency_correct_ms.p50; p95 = $a.latency_correct_ms.p95; p99 = $a.latency_correct_ms.p99; correct = $a.correct; dao_per_request = $a.server_side.dao_calls_per_request }
            B = [ordered]@{ p50 = $b.latency_correct_ms.p50; p95 = $b.latency_correct_ms.p95; p99 = $b.latency_correct_ms.p99; correct = $b.correct; dao_per_request = $b.server_side.dao_calls_per_request }
            note = 'single 20 s sample per group per tier: an observation, not a formal comparison; no significance claimed'
        })
}

$summary = [ordered]@{
    run_id = $RunId
    scope = 'P1.4a calibration summary recomputed from the ledger and probe originals, with every slot bound to the frozen plan'
    source_calibration = 'calibration-result.json'
    validated_tiers_req_per_second = @($validTiers)
    segment_validity = @($segmentValidity)
    stopped_early = $cal.stopped_early
    stop_reason = $cal.stop_reason
    per_run = $perRun
    comparison = @($comparison)
    probe_files = [ordered]@{ A = $probe['A'].file; B = $probe['B'].file; requests_with_events = [ordered]@{ A = $probe['A'].requests; B = $probe['B'].requests } }
    percentile_method = 'nearest-rank over the ascending sample (ceil(p/100*n)-th value)'
    problems = @($problems)
    note = 'all numbers above are recomputed from runs/*/responses.jsonl and events/*.log and every record is bound to plans/plan-r<rate>-sample.json (slot set, offset, article id, FULL url = frozen base + plan path, request id, body id and server runId/articleId); the correct count, its latency samples, the verdicts, the failures/timeouts, the window split and the validated tier list all come from that one re-judged population, while the stored flags appear only under stored_flags and the calibration self-report only under segment_validity; server-side DAO counts are DAO evidence, not physical SQL'
}
$summaryPath = Join-Path $outDir 'recomputed-summary.json'
# write once: an existing recomputed summary is a hard refusal (exit 2), never an overwrite
$null = Write-P14aOnce -Path $summaryPath -Text ($summary | ConvertTo-Json -Depth 10) -EntryPoint 'p14a-summarize.ps1'

Write-Host ("recomputed-summary=$summaryPath validated_tiers=$($validTiers -join ',') problems=$($problems.Count)")
foreach ($k in $perRun.Keys) {
    $r = $perRun[$k]
    Write-Host ("  {0,-8} responses={1,4} correct={2,4} dropped={3,3} p50={4,7} p95={5,7} p99={6,7} hit={7,4} miss={8,4} dao/req={9}" -f `
            $k, $r.responses, $r.correct, $r.dropped, $r.latency_correct_ms.p50, $r.latency_correct_ms.p95, $r.latency_correct_ms.p99,
        $r.server_side.cache_hit, $r.server_side.cache_miss, $r.server_side.dao_calls_per_request)
}
if ($problems.Count -gt 0) { $problems | ForEach-Object { Write-Host "PROBLEM: $_" }; exit 1 }
exit 0
