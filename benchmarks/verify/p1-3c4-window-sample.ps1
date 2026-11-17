# P1.3c-4 C: window sampling from the real commit onwards (ASCII only).
#
# What is different from the first round of this card (whose terminal-state windows are preserved as-is):
#   * the baseline is a SHARED file captured once; its file, sha256, scope and the three article ids are
#     verified BEFORE any HTTP/SQL/Redis call (B),
#   * every request is written and flushed to requests.jsonl before the next one starts (B),
#   * new detail reads start right after the writer's commit and run WHILE the slow reader is still paused,
#     so the round records the stale window itself, not only the terminal state (C).
#
# A round: restore the three rows to the shared baseline -> cold read (paused between snapshot and setEx) ->
# writer commits -> sampling loop of detail reads until the second delete has settled plus a tail.
# Classification uses the real event times only: tx.after_commit, cache.write.done, second_succeeded.
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard/baseline refusal.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [Parameter(Mandatory = $true)][ValidateSet('c200', 'c500', 'c1500')][string]$Variant,
    [Parameter(Mandatory = $true)][int]$ExpectedDelayMs,
    [Parameter(Mandatory = $true)][int]$RoundIndex,
    [Parameter(Mandatory = $true)][string]$Order,
    [Parameter(Mandatory = $true)][long[]]$TargetIds,
    [Parameter(Mandatory = $true)][string]$BaselineFile,
    [Parameter(Mandatory = $true)][string]$BaselineSha256,
    [int[]]$Pauses = @(300, 1500, 2000),
    [int]$SampleIntervalMs = 60,
    [int]$TailMs = 2500,
    [int]$MaxSampleMs = 12000,
    [int]$EventTimeoutMs = 15000,
    [int]$SettleTimeoutMs = 20000,
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [int]$RedisDb = 5,
    [string]$CacheKeyPrefix = 'article:detail:',
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$env:MYSQL_PWD = $MysqlPassword
$benchDir = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P13c4Evidence.ps1')

# ---------------------------------------------------------------- B: shared baseline gate (BEFORE any call)
$script:run = $null
$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$scriptStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$gateCalls = 0
function Write-GateLog([string]$text) {
    $p = Join-Path $RunRoot ("gate-attempts/" + $RunId + ".log")
    $d = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Add-Content -LiteralPath $p -Value ("{0} {1}" -f (Get-Date -Format 'o'), $text)
}
$baseline = $null
try {
    $baseline = Assert-P13c4Baseline -File $BaselineFile -ExpectedSha256 $BaselineSha256 -ExpectedScope 'P1.3c-4-window-shared' -ExpectedIds $TargetIds
    Write-GateLog "PASS baseline=$BaselineFile sha=$BaselineSha256 external_calls=$gateCalls"
} catch {
    Write-GateLog "REFUSED $($_.Exception.Message) external_calls=$gateCalls"
    Write-Host "BASELINE REFUSED: $($_.Exception.Message)"
    Write-Host 'REFUSED_STAGE=baseline'
    exit 2
}

trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3c-4-window-sampling' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ variant = $Variant; expected_delay_ms = $ExpectedDelayMs; round = $RoundIndex; order = $Order; pauses = ($Pauses -join ','); baseline_sha256 = $BaselineSha256 } `
        -Targets @($TargetIds | ForEach-Object { "$_" }) -DataSet $Database
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-56} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'fail' }), $d
}
function Redis-In([int]$db, [string[]]$a) {
    return ((& $RedisCli (@('-h', '127.0.0.1', '-p', '6379', '-n', "$db") + $a) 2>&1) | Out-String).Trim()
}
function Sql([string]$q) {
    return (((& $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--raw' '-e' $q) 2>&1) | Out-String).Trim()
}
function Db-Fields([long]$id) { return (Sql "SELECT CONCAT_WS('|', views, likes, comment, collection) FROM $Database.ap_article WHERE id=$id;") }
function Views-Of([string]$body) {
    $m = [regex]::Match($body, '"views"\s*:\s*(\d+)')
    if ($m.Success) { return [long]$m.Groups[1].Value }
    return -1
}
function Get-Events { if (Test-Path -LiteralPath $Events) { return @(Get-Content -LiteralPath $Events) } return @() }
function Ev-Time([string]$line) { return [long]([regex]::Match($line, 'epochMs=(\d+)').Groups[1].Value) }
function Wait-Event([string]$pattern, [int]$timeoutMs) {
    # this is also a wait, so tracked requests keep being persisted while we poll for the event
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if ($null -ne $script:tracked) { [void](Service-Tracked) }
        $hit = @(Get-Events | Where-Object { $_ -match $pattern })
        if ($hit.Count -gt 0) { return $hit }
        Start-Sleep -Milliseconds 5
    }
    return @()
}

# ---------------------------------------------------------------- request ledger (B: flushed per request)
$ledger = New-P13c4RequestLedger -Path (Join-Path $outDir 'requests.jsonl') -RunId $RunId
Add-Type -AssemblyName System.Net.Http | Out-Null
# two tracked requests can be in flight at the same time (slow reader + one sample), so raise the per-server
# connection limit explicitly instead of relying on the .NET Framework default of 2
[System.Net.ServicePointManager]::DefaultConnectionLimit = 16
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
$script:seq = 0
# every in-flight tracked request; serviced by Send-P13c4Responsive while any HTTP wait is running
$script:tracked = New-Object System.Collections.ArrayList
function Send-Once([string]$method, [string]$path, [string]$reqId, [string]$kind, [string]$note) {
    $script:seq++
    $started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $rec = [ordered]@{ local_seq = $script:seq; kind = $kind; note = $note; request_id = $reqId; method = $method; path = $path; started_ms = $started }
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::$method, "$Base$path")
        if ($method -eq 'Post') { $req.Content = New-Object System.Net.Http.StringContent('') }
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
        # The wait is sliced (the card's ONE responsive wait): a tracked slow read that completes WHILE this
        # request is still in flight is written and flushed right then, not after this call returns.
        $task = Send-P13c4Responsive -Client $client -Request $req -Tracked $script:tracked -Ledger $ledger `
            -SliceMs 3 -TimeoutMs ($TimeoutSeconds * 1000)
        $rec.ended_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $rec.elapsed_ms = $rec.ended_ms - $started
        $resp = $task.GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $rec.http = [int]$resp.StatusCode
        $rec.bytes = $bytes.Length
        $rec.sha256 = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
        $rec.views = (Views-Of $text)
        $rec.body = $text
        $rec.ok = ($text -match '"ok"\s*:\s*true')
    } catch {
        $rec.http = -1
        $rec.error = $_.Exception.Message
        $rec.failure = $true
        if ($null -eq $rec.ended_ms) {
            $rec.ended_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $rec.elapsed_ms = $rec.ended_ms - $started
        }
    }
    # B: the record is on disk (flushed) BEFORE the caller can issue the next request
    $null = $ledger.Add($rec)
    return [pscustomobject]$rec
}
# the tracked-async and completion-persist logic lives in benchmarks/lib/P13c4Evidence.ps1 so the offline tests
# exercise the very same code with their own client + ledger
function Start-AsyncGet([string]$path, [string]$reqId, [string]$kind) {
    $script:seq++
    $p = Start-P13c4AsyncGet -Client $client -Base $Base -Path $path -ReqId $reqId -Kind $kind -RunId $RunId -LocalSeq $script:seq
    $null = $script:tracked.Add($p)
    return $p
}
function Complete-AsyncGet($pending) {
    return Complete-P13c4Get -Pending $pending -Ledger $ledger
}
function Service-Tracked() {
    return Update-P13c4Tracked -Tracked $script:tracked -Ledger $ledger
}
function Wait-CompletionPersist($pending, [int]$sliceMs, [int]$deadlineMs) {
    return Wait-P13c4CompletionPersist -Pending $pending -Ledger $ledger -SliceMs $sliceMs -DeadlineMs $deadlineMs
}
function Restore-BaselineRows {
    # reset the three rows to the SHARED baseline capture (the baseline itself is never modified)
    $baseDir = Split-Path -Parent $BaselineFile
    $idList = ($TargetIds | ForEach-Object { "$_" }) -join ','
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $del = "DELETE FROM $Database.ap_article WHERE id IN ($idList);"
    $del += "DELETE FROM $Database.ap_article_content WHERE id IN ($idList);"
    $del += "DELETE FROM $Database.ap_article_config WHERE id IN ($idList);"
    $del | & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser $Database 1> (Join-Path $outDir 'reset-delete.log') 2>&1
    foreach ($t in @('ap_article', 'ap_article_content', 'ap_article_config')) {
        foreach ($id in $TargetIds) {
            $f = Join-Path $baseDir ("capture-$id-$t.sql")
            if (Test-Path -LiteralPath $f) {
                Get-Content -LiteralPath $f -Raw | & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser $Database 1>> (Join-Path $outDir 'reset-insert.log') 2>&1
            }
        }
    }
    $ErrorActionPreference = $saved
}

# ---------------------------------------------------------------- pre-round state
$badFields = @()
$baseById = @{}
foreach ($t in $baseline.targets) { $baseById["$($t.article_id)"] = "$($t.fields)" }
foreach ($id in $TargetIds) {
    $cur = Db-Fields $id
    if ($cur -ne $baseById["$id"]) { $badFields += "$id current=$cur baseline=$($baseById["$id"])" }
}
Add-Check 'baseline.fields_match_shared_snapshot' ($badFields.Count -eq 0) `
    $(if ($badFields.Count -eq 0) { "all $($TargetIds.Count) rows equal the shared baseline" } else { ($badFields -join '; ') })

$statsStart = ((Send-Once 'Get' '/p13b/harness/stats' "$RunId-stats-start" 'stats' 'session start').body | ConvertFrom-Json).evict
Add-Check 'baseline.loaded_delay_is_candidate' (([long]$statsStart.second_delete_delay_ms) -eq [long]$ExpectedDelayMs) `
    "second_delete_delay_ms=$($statsStart.second_delete_delay_ms) expected=$ExpectedDelayMs (variant $Variant)"
Add-Check 'baseline.stats_fresh' (([long]$statsStart.accepted) -eq 0 -and ([long]$statsStart.active_now) -eq 0) `
    "accepted=$($statsStart.accepted) active=$($statsStart.active_now) (fresh instance)"

# ---------------------------------------------------------------- rounds: sampling from the real commit
$windowResults = New-Object System.Collections.ArrayList
$wIndex = 0
foreach ($id in $TargetIds) {
    $pause = $Pauses[$wIndex]
    $wIndex++
    $tag = "w$wIndex"
    Restore-BaselineRows
    $afterReset = Db-Fields $id
    Add-Check ("window.$tag.reset_to_baseline") ($afterReset -eq $baseById["$id"]) "id=$id fields=$afterReset (baseline $($baseById["$id"]))"
    $key = "$CacheKeyPrefix$id"
    Redis-In $RedisDb @('DEL', $key) | Out-Null
    Redis-In $RedisDb @('DEL', "${key}:lock") | Out-Null
    $roundStart = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    $readReqId = "$RunId-$tag-read"
    $pending = Start-AsyncGet "/api/v1/article/detail/$id" $readReqId 'slow-reader'
    $delayEv = @(Wait-Event ('requestId=' + [regex]::Escape($readReqId) + ' .*event=cache\.write\.delay\.begin ') $EventTimeoutMs)
    $delaySeen = ($delayEv.Count -ge 1)
    $delayBeginMs = -1
    if ($delaySeen) { $delayBeginMs = Ev-Time $delayEv[0] }
    $write = $null
    if ($delaySeen) { $write = Send-Once 'Post' "/p13b/harness/score?id=$id&view=1&like=1&comment=1&collect=1" "$RunId-$tag-write" 'writer' 'real updateScore commit' }

    # C: wait for the REAL commit of this write, then start sampling immediately, while the reader is paused
    $commitEv = @()
    if ($null -ne $write) {
        $commitEv = @(Wait-Event (' event=tx\.after_commit .* articleId=' + $id + ' ') $EventTimeoutMs |
            Where-Object { (Ev-Time $_) -ge $roundStart })
    }
    $commitMs = -1
    if ($commitEv.Count -ge 1) { $commitMs = Ev-Time $commitEv[0] }

    $samples = New-Object System.Collections.ArrayList
    $sampleStartMs = -1
    $sampleDeadline = $roundStart + $MaxSampleMs
    $secondSuccMs = -1
    $samplingBegin = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    while ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $sampleDeadline) {
        # B: if the slow read has already completed, its record is flushed BEFORE this sample is dispatched
        $null = Service-Tracked
        $slowWasPersisted = $pending.persisted
        # Send-Once waits responsively, so a slow read completing DURING this sample is persisted right then
        $sr = Send-Once 'Get' "/api/v1/article/detail/$id" ("$RunId-$tag-sample" + ($samples.Count + 1)) 'sample' 'post-commit read'
        if ($sampleStartMs -lt 0) { $sampleStartMs = $sr.started_ms }
        $null = $samples.Add([ordered]@{
                sequence = $samples.Count + 1; started_ms = $sr.started_ms; ended_ms = $sr.ended_ms; elapsed_ms = $sr.elapsed_ms
                http = $sr.http; views = $sr.views; sha256 = $sr.sha256; ledger_seq = $sr.seq
                flush_returned_ms = $sr.flush_returned_ms
                slow_completed_ms = $(if ($pending.persisted) { $pending.completed_ms } else { -1 })
                slow_persisted_before_dispatch = $slowWasPersisted
                slow_persisted_ms_before_dispatch = $(if ($slowWasPersisted) { $pending.persisted_ms } else { -1 })
            })
        $null = Service-Tracked
        $succ = @(Get-Events | Where-Object { $_ -match ' event=cache\.evict\.second_succeeded ' -and $_ -match " articleId=$id " -and (Ev-Time $_) -ge $roundStart })
        if ($succ.Count -ge 1 -and $secondSuccMs -lt 0) { $secondSuccMs = Ev-Time $succ[0] }
        if ($secondSuccMs -gt 0 -and ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $secondSuccMs) -ge $TailMs) { break }
        # the interval is sliced as well, so the record never waits for the end of the round
        $slice = 0
        while ($slice -lt $SampleIntervalMs) {
            $null = Service-Tracked
            Start-Sleep -Milliseconds 3
            $slice += 3
        }
    }
    $samplingEnd = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    # the slow reader's own completion is what persisted it; here we only make sure it did complete
    $null = Wait-CompletionPersist $pending 3 20000
    $reader = $pending.record
    if ($null -eq $reader) { $reader = [pscustomobject]@{ http = -1; views = -1; sha256 = ''; body = ''; ended_ms = -1; error = 'slow reader never completed' } }
    $donePattern = 'requestId=' + [regex]::Escape($readReqId) + ' .*event=cache\.write\.done '
    $null = Wait-Event $donePattern $EventTimeoutMs
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $SettleTimeoutMs) {
        $acc = @(Get-Events | Where-Object { $_ -match ' event=cache\.evict\.second_accepted ' -and $_ -match " articleId=$id " -and (Ev-Time $_) -ge $roundStart })
        $succ = @(Get-Events | Where-Object { $_ -match ' event=cache\.evict\.second_succeeded ' -and $_ -match " articleId=$id " -and (Ev-Time $_) -ge $roundStart })
        $fail = @(Get-Events | Where-Object { $_ -match ' event=cache\.evict\.second_failed ' -and $_ -match " articleId=$id " -and (Ev-Time $_) -ge $roundStart })
        if ($acc.Count -ge 1 -and $acc.Count -eq ($succ.Count + $fail.Count)) { break }
        Start-Sleep -Milliseconds 40
    }
    $evAll = @(Get-Events | Where-Object { $_ -match " articleId=$id " -and (Ev-Time $_) -ge $roundStart })
    Write-RunFileText -State $script:run -Path (Join-Path $outDir ("events-" + $tag + ".log")) -Text ((@($evAll)) -join "`r`n")
    $wdoneEv = @($evAll | Where-Object { $_ -match $donePattern })
    $accEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_accepted ' })
    $succEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_succeeded ' })
    $rejEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_rejected ' })
    $firstOkEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.ok ' -and $_ -notmatch 'phase=[^ ]*:second' })
    $wdoneMs = -1
    if ($wdoneEv.Count -ge 1) { $wdoneMs = Ev-Time $wdoneEv[0] }
    if ($succEv.Count -ge 1) { $secondSuccMs = Ev-Time $succEv[0] }

    $dbAfter = Db-Fields $id
    $dbViews = [long](($dbAfter -split '\|')[0])
    $baseViews = [long]($baseById["$id"] -split '\|')[0]
    # classify each sample against the committed value (V1) and the pre-write value (V0);
    # ordering uses when the RESPONSE arrived, because a read may block on the key lock for the whole pause
    foreach ($s in $samples) {
        $s['stale'] = ($s.views -eq $baseViews -and $dbViews -ne $baseViews)
        $s['is_v1'] = ($s.views -eq $dbViews)
        $s['failed'] = ($s.http -ne 200 -or [long]$s.views -lt 0)
        $s['started_since_commit_ms'] = $(if ($commitMs -gt 0) { $s.started_ms - $commitMs } else { -1 })
        $s['ended_since_commit_ms'] = $(if ($commitMs -gt 0) { $s.ended_ms - $commitMs } else { -1 })
    }
    $failedSamples = @($samples | Where-Object { $_.failed })
    $staleSamples = @($samples | Where-Object { $_.stale })
    $v1Samples = @($samples | Where-Object { $_.is_v1 })
    $firstV1 = $null
    foreach ($s in $samples) { if ($s.is_v1) { $firstV1 = $s; break } }
    # stable recovery = first V1 after which every later sample is also V1
    $recovery = $null
    for ($i = 0; $i -lt $samples.Count; $i++) {
        $allAfter = $true
        for ($j = $i; $j -lt $samples.Count; $j++) { if (-not $samples[$j].is_v1) { $allAfter = $false; break } }
        if ($allAfter) { $recovery = $samples[$i]; break }
    }
    $flips = 0
    for ($i = 1; $i -lt $samples.Count; $i++) {
        if ($samples[$i].is_v1 -ne $samples[$i - 1].is_v1) { $flips++ }
    }

    $null = $windowResults.Add([ordered]@{
            tag = $tag; article_id = $id; planned_pause_ms = $pause
            times = [ordered]@{ delay_begin = $delayBeginMs; commit = $commitMs; cache_write_done = $wdoneMs; second_succeeded = $secondSuccMs
                sampling_begin = $samplingBegin; sampling_end = $samplingEnd
                first_sample_since_commit_ms = $(if ($sampleStartMs -gt 0 -and $commitMs -gt 0) { $sampleStartMs - $commitMs } else { -1 })
                second_minus_commit_ms = $(if ($secondSuccMs -gt 0 -and $commitMs -gt 0) { $secondSuccMs - $commitMs } else { -1 })
                backfill_minus_commit_ms = $(if ($wdoneMs -gt 0 -and $commitMs -gt 0) { $wdoneMs - $commitMs } else { -1 }) }
            reader = [ordered]@{ http = $reader.http; views = $reader.views; sha256 = $reader.sha256
                dispatched_ms = $pending.dispatched_ms
                last_incomplete_ms = $pending.last_incomplete_ms
                completed_ms = $pending.completed_ms
                persisted_ms = $pending.persisted_ms
                flush_returned_ms = $pending.flush_returned_ms
                detection_lag_ms = $(if ($pending.persisted) { $pending.persisted_ms - $pending.completed_ms } else { -1 })
                bracket_lag_ms = $(if ($pending.persisted) { $pending.persisted_ms - $pending.last_incomplete_ms } else { -1 })
                flush_bracket_lag_ms = $(if ($pending.persisted) { $pending.flush_returned_ms - $pending.last_incomplete_ms } else { -1 })
                persisted_during_sample_flight = @($samples | Where-Object { $pending.persisted -and $_.started_ms -lt $pending.persisted_ms -and $pending.persisted_ms -lt $_.ended_ms }).Count }
            writer = [ordered]@{ http = $write.http; ok = $write.ok }
            db_before = $baseById["$id"]; db_after = $dbAfter
            second_delete = [ordered]@{ accepted = $accEv.Count; succeeded = $succEv.Count; rejected = $rejEv.Count; first_phase_ok = $firstOkEv.Count }
            samples = @($samples)
            sample_count = $samples.Count
            stale_samples = $staleSamples.Count
            stale_ratio = $(if ($samples.Count -gt 0) { [Math]::Round($staleSamples.Count / $samples.Count, 4) } else { 0 })
            first_v1_sequence = $(if ($null -ne $firstV1) { $firstV1.sequence } else { -1 })
            stable_recovery_sequence = $(if ($null -ne $recovery) { $recovery.sequence } else { -1 })
            stable_recovery_since_commit_ms = $(if ($null -ne $recovery -and $commitMs -gt 0) { $recovery.ended_ms - $commitMs } else { -1 })
            transitions = $flips
            unobserved_lower_bound_ms = $(if ($null -eq $recovery -and $commitMs -gt 0 -and $samplingEnd -gt $commitMs) { $samplingEnd - $commitMs } else { -1 })
            failed_samples = $failedSamples.Count
            median_sample_elapsed_ms = $(if ($samples.Count -gt 0) { [Math]::Round((@($samples | ForEach-Object { $_.elapsed_ms }) | Sort-Object)[[int](($samples.Count - 1) / 2)], 0) } else { -1 })
        })

    Add-Check ("window.$tag.sampling_started_after_commit") ($commitMs -gt 0 -and $sampleStartMs -gt $commitMs -and ($sampleStartMs - $commitMs) -le 500) `
        ("commit={0} first_sample={1} offset={2}ms (sampling begins right after the real commit, not after settle)" -f $commitMs, $sampleStartMs, $(if ($sampleStartMs -gt 0 -and $commitMs -gt 0) { $sampleStartMs - $commitMs } else { -1 }))
    Add-Check ("window.$tag.sampling_overlapped_the_pause") ($samples.Count -ge 1 -and $samplingBegin -lt $pending.completed_ms) `
        ("{0} samples, sampling {1}ms..{2}ms, slow reader completed {3}ms (parallel with the pause; each read may block on the key lock)" -f $samples.Count, $samplingBegin, $samplingEnd, $pending.completed_ms)
    # B: the slow read was persisted at its own completion, and never later than the next dispatched request.
    # The exact transition instant is unknown, so the honest budget uses the bracket: last_incomplete_ms is the
    # last moment the client Task was still incomplete, and Flush must have returned within the budget of it.
    $latePersist = @($samples | Where-Object { $_.started_ms -gt $pending.completed_ms -and -not $_.slow_persisted_before_dispatch })
    $flushBracket = $(if ($pending.persisted) { $pending.flush_returned_ms - $pending.last_incomplete_ms } else { -1 })
    Add-Check ("window.$tag.slow_read_persisted_at_completion") ($pending.persisted -and $flushBracket -le 150 -and $latePersist.Count -eq 0) `
        ("last_incomplete={0}ms completed(observed)={1}ms write_start={2}ms flush_returned={3}ms; real completion -> Flush <= {4}ms; samples dispatched after completion without the record on disk={5}" -f `
        $pending.last_incomplete_ms, $pending.completed_ms, $pending.persisted_ms, $pending.flush_returned_ms, $flushBracket, $latePersist.Count)
    $duringFlight = @($samples | Where-Object { $pending.persisted -and $_.started_ms -lt $pending.persisted_ms -and $pending.persisted_ms -lt $_.ended_ms }).Count
    Add-Check ("window.$tag.slow_read_persisted_while_a_sample_was_blocked") ($pending.persisted -and $duringFlight -ge 1) `
        ("{0} sample(s) had the slow record flushed while they were still in flight (samples={1})" -f $duringFlight, $samples.Count)
    Add-Check ("window.$tag.only_one_writer_delete") ($accEv.Count -eq 1 -and $succEv.Count -eq 1 -and $rejEv.Count -eq 0 -and $firstOkEv.Count -eq 1) `
        ("accepted={0} succeeded={1} rejected={2} first_phase_ok={3}" -f $accEv.Count, $succEv.Count, $rejEv.Count, $firstOkEv.Count)
    Add-Check ("window.$tag.commit_plus_one") ($null -ne $write -and $write.ok -and ([long]($dbAfter -split '\|')[0] - $baseViews) -eq 1) `
        ("writer http={0} db {1} -> {2}" -f $write.http, $baseById["$id"], $dbAfter)

    # The invariant follows the REAL event order, judged by when each response arrived:
    #  * backfill BEFORE the second delete succeeded -> the second delete removes V0, so every later response must be V1
    #  * backfill AFTER  the second delete succeeded -> V0 is written after the delete, so later responses stay V0
    $judged = @($samples | Where-Object { -not $_.failed })
    $branch = 'unknown'
    $consistent = $true
    if ($secondSuccMs -gt 0 -and $wdoneMs -gt 0) {
        if ($wdoneMs -lt $secondSuccMs) {
            $branch = 'backfill_before_second_delete'
            $after = @($judged | Where-Object { $_.ended_ms -gt ($secondSuccMs + 100) })
            if (@($after | Where-Object { $_.stale }).Count -gt 0) { $consistent = $false }
        } else {
            $branch = 'backfill_after_second_delete'
            $after = @($judged | Where-Object { $_.ended_ms -gt ($wdoneMs + 100) })
            if (@($after | Where-Object { -not $_.stale }).Count -gt 0) { $consistent = $false }
        }
    }
    Add-Check ("window.$tag.outcome_matches_event_order") ($branch -ne 'unknown' -and $consistent) `
        ("branch={0} judged={1} stale={2} failures={3} (backfill={4} second_succeeded={5})" -f $branch, $judged.Count, $staleSamples.Count, $failedSamples.Count, $wdoneMs, $secondSuccMs)
}

# ---------------------------------------------------------------- restore to the shared baseline and verify
Restore-BaselineRows
$restored = @()
foreach ($id in $TargetIds) { $restored += "$id=$(Db-Fields $id)" }
$mismatch = @($TargetIds | Where-Object { (Db-Fields $_) -ne $baseById["$_"] })
foreach ($id in $TargetIds) {
    Redis-In $RedisDb @('DEL', "$CacheKeyPrefix$id") | Out-Null
    Redis-In $RedisDb @('DEL', "$CacheKeyPrefix$id`:lock") | Out-Null
}
$db0After = (Redis-In 0 @('DBSIZE'))
Add-Check 'restore.fields_equal_shared_baseline' ($mismatch.Count -eq 0) (($restored) -join ' ')
Add-Check 'restore.keys_removed_and_db0_untouched' ($db0After -eq '0' -and (Redis-In $RedisDb @('DBSIZE')) -eq '0') `
    "db5=$((Redis-In $RedisDb @('DBSIZE'))) db0=$db0After (DB0 never written, no FLUSHDB)"

$statsEnd = ((Send-Once 'Get' '/p13b/harness/stats' "$RunId-stats-end" 'stats' 'session end').body | ConvertFrom-Json).evict
Add-Check 'session.tail_settled' (([long]$statsEnd.active_now) -eq 0 -and ([long]$statsEnd.failed) -eq 0) `
    "active=$($statsEnd.active_now) accepted=$($statsEnd.accepted) succeeded=$($statsEnd.succeeded) failed=$($statsEnd.failed) rejected_backlog=$($statsEnd.rejected_backlog)"

# B: the ledger must hold every request exactly once, in write order, with completion before persistence.
# The read happens while every write is complete but the ordering evidence comes from the records themselves,
# not from a tail total: seq must be 1..N, request ids unique, and each record's persisted_ms >= completed_ms.
$onDiskOpen = @(Read-P13c4LedgerLines -Path (Join-Path $outDir 'requests.jsonl'))
Add-Check 'ledger.readable_while_stream_open' ($onDiskOpen.Count -eq $script:seq -and $onDiskOpen.Count -gt 0) `
    "read with the writer still open: lines=$($onDiskOpen.Count) issued=$($script:seq) (no sharing violation, no early close)"
$ledger.Close()
$onDisk = @(Read-P13c4LedgerLines -Path (Join-Path $outDir 'requests.jsonl'))
$parsed = 0
$badJson = 0
$seqOk = $true
$orderOk = $true
$ids = New-Object System.Collections.ArrayList
$expected = 1
foreach ($l in $onDisk) {
    try { $o = $l | ConvertFrom-Json } catch { $badJson++; continue }
    $parsed++
    if ([long]$o.seq -ne $expected) { $seqOk = $false }
    $expected++
    $null = $ids.Add([string]$o.request_id)
    if ($null -eq $o.ended_ms -or $null -eq $o.persisted_ms -or [long]$o.persisted_ms -lt [long]$o.ended_ms) { $orderOk = $false }
}
$uniqueIds = @($ids | Sort-Object -Unique).Count
Add-Check 'ledger.every_request_on_disk' ($onDisk.Count -eq $script:seq -and $badJson -eq 0 -and $onDisk.Count -gt 0) `
    "ledger lines=$($onDisk.Count) issued=$($script:seq) parseable=$parsed unparseable=$badJson (flushed per request, nothing held in memory)"
Add-Check 'ledger.one_record_per_request_in_order' ($seqOk -and $uniqueIds -eq $onDisk.Count -and $onDisk.Count -gt 0) `
    "seq is 1..$($onDisk.Count)=$seqOk unique request ids=$uniqueIds of $($onDisk.Count) (one write per request, no duplicates)"
Add-Check 'ledger.completion_recorded_before_persist' $orderOk `
    "every record has ended_ms and persisted_ms with persisted >= ended (completion timestamp is the client's, not the collector's)"
$client.Dispose()

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId; variant = $Variant; expected_delay_ms = $ExpectedDelayMs; round = $RoundIndex; order = $Order
    base = $Base; events = $Events
    baseline_file = $BaselineFile; baseline_sha256 = $BaselineSha256; baseline_scope = 'P1.3c-4-window-shared'
    target_ids = @($TargetIds); pauses = @($Pauses)
    sample_interval_ms = $SampleIntervalMs; tail_ms = $TailMs; max_sample_ms = $MaxSampleMs
    stats_start = $statsStart; stats_end = $statsEnd
    windows = @($windowResults)
    ledger_lines = $onDisk.Count
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'window-sampling-result.json') -Text ($result | ConvertTo-Json -Depth 9)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'window-sampling-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
