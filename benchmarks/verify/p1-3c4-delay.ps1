# P1.3c-4: one (candidate, round) session - window rounds plus a cost block (ASCII only).
#
# The instance for this session has ALREADY been started by start-p13b-instance.ps1 with this candidate's
# variant classes, so the second-delete delay is a property of the loaded code. This script proves that,
# then measures:
#   D-W  three controlled window rounds (reader paused 300 / 1500 / 2000 ms between snapshot and setEx,
#        writer = real updateScore). Classified ONLY by the actual events (commit, cache.write.done,
#        second_succeeded): if the backfill lands AFTER the second delete succeeded, new detail reads must
#        be stale; if it lands BEFORE, they must be fresh. That invariant is what is checked, not the plan.
#   D-C  one cost block: 30 loops x (10 real detail reads + 5 real writes). Reads that hit the cache and
#        reads that go back to the database are separated by the real db.snapshot.begin events inside the
#        block window for the block's own article ids.
#
# Everything writable stays in this run directory. The 13 rows are captured with mysqldump BEFORE any write
# and restored from those exact files, then verified. DB0 is never written and never flushed.
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [Parameter(Mandatory = $true)][ValidateSet('c200', 'c500', 'c1500')][string]$Variant,
    [Parameter(Mandatory = $true)][int]$ExpectedDelayMs,
    [Parameter(Mandatory = $true)][int]$RoundIndex,
    [Parameter(Mandatory = $true)][string]$Order,
    [Parameter(Mandatory = $true)][long[]]$WindowIds,
    [Parameter(Mandatory = $true)][long[]]$CostIds,
    [int[]]$WindowPauses = @(300, 1500, 2000),
    [int]$CostLoops = 30,
    [int]$WritesPerLoop = 5,
    [int]$NewReadCount = 3,
    [int]$NewReadGapMs = 350,
    [int]$EventTimeoutMs = 15000,
    [int]$SettleTimeoutMs = 30000,
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlDump = 'D:\Soft\mysql-8.0.34-winx64\bin\mysqldump.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [int]$RedisDb = 5,
    [string]$CacheKeyPrefix = 'article:detail:',
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$env:MYSQL_PWD = $MysqlPassword
$benchDir = Split-Path -Parent $PSScriptRoot

. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3c-4-delay-session' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ variant = $Variant; expected_delay_ms = $ExpectedDelayMs; round = $RoundIndex; order = $Order; window_pauses = ($WindowPauses -join ','); cost_loops = $CostLoops } `
        -Targets @(($WindowIds + $CostIds) | ForEach-Object { "$_" }) -DataSet $Database
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-54} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'fail' }), $d
}
function Redis-In([int]$db, [string[]]$a) {
    return ((& $RedisCli (@('-h', '127.0.0.1', '-p', '6379', '-n', "$db") + $a) 2>&1) | Out-String).Trim()
}
function Sql([string]$q) {
    return (((& $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--raw' '--default-character-set=utf8mb4' '-e' $q) 2>&1) | Out-String).Trim()
}
function Db-Counts([long]$id) { return (Sql "SELECT CONCAT_WS('|', views, likes, comment, collection) FROM $Database.ap_article WHERE id=$id;") }
function Views-Of([string]$body) {
    $m = [regex]::Match($body, '"views"\s*:\s*(\d+)')
    if ($m.Success) { return [long]$m.Groups[1].Value }
    return -1
}
function Get-Events { if (Test-Path -LiteralPath $Events) { return @(Get-Content -LiteralPath $Events) } return @() }
function Ev-Time([string]$line) { return [long]([regex]::Match($line, 'epochMs=(\d+)').Groups[1].Value) }
function Wait-Event([string]$pattern, [int]$timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $hit = @(Get-Events | Where-Object { $_ -match $pattern })
        if ($hit.Count -gt 0) { return $hit }
        Start-Sleep -Milliseconds 20
    }
    return @()
}

# ---------------------------------------------------------------- capture BEFORE any write
$allIds = @($WindowIds) + @($CostIds)
$captureDir = Join-Path $outDir 'capture'
New-Item -ItemType Directory -Path $captureDir | Out-Null
$tables = @('ap_article', 'ap_article_content', 'ap_article_config')
$idList = $allIds -join ','
foreach ($t in $tables) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $MysqlDump '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '--no-create-info' '--skip-extended-insert' `
        '--complete-insert' '--where' "id IN ($idList)" $Database $t 1> (Join-Path $captureDir "$t.capture.sql") 2> (Join-Path $captureDir "$t.capture.err")
    $dcode = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($dcode -ne 0) { throw "mysqldump failed for $t (exit $dcode)" }
}
$captureSha = [ordered]@{}
foreach ($t in $tables) { $captureSha[$t] = (Get-FileHash -LiteralPath (Join-Path $captureDir "$t.capture.sql") -Algorithm SHA256).Hash.ToLower() }
$dbBefore = [ordered]@{}
foreach ($id in $allIds) { $dbBefore["$id"] = (Db-Counts $id) }
$rowsBefore = (Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id IN ($idList);")
$db0Before = (Redis-In 0 @('DBSIZE'))
Add-Check 'baseline.capture_before_write' (@($dbBefore.Values | Where-Object { $_ -match '^\d+\|\d+\|\d+\|\d+$' }).Count -eq $allIds.Count -and $rowsBefore -eq "$($allIds.Count)" -and $db0Before -eq '0') `
    "rows=$rowsBefore of $($allIds.Count) db0=$db0Before (13 rows captured with mysqldump)"

# ---------------------------------------------------------------- HTTP with per-request metadata log
Add-Type -AssemblyName System.Net.Http | Out-Null
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
$script:seq = 0
$requestLog = New-Object System.Collections.ArrayList
function Send-Once([string]$method, [string]$path, [string]$reqId) {
    $script:seq++
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::$method, "$Base$path")
    if ($method -eq 'Post') { $req.Content = New-Object System.Net.Http.StringContent('') }
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    $started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $sha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
    $obj = [ordered]@{
        seq = $script:seq; request_id = $reqId; method = $method; path = $path
        at_ms = $started; http = [int]$resp.StatusCode; bytes = $bytes.Length; sha256 = $sha
        views = (Views-Of $text); body = $text
    }
    $null = $requestLog.Add($obj)
    return [pscustomobject]$obj
}
function Start-AsyncGet([string]$path, [string]$reqId) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base$path")
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    return [pscustomobject]@{ reqId = $reqId; path = $path; task = $client.SendAsync($req); started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
}
function Finish-AsyncGet($pending) {
    $script:seq++
    $resp = $pending.task.GetAwaiter().GetResult()
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $sha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
    $obj = [ordered]@{
        seq = $script:seq; request_id = $pending.reqId; method = 'Get'; path = $pending.path
        at_ms = $pending.started; http = [int]$resp.StatusCode; bytes = $bytes.Length; sha256 = $sha
        views = (Views-Of $text); body = $text
    }
    $null = $requestLog.Add($obj)
    return [pscustomobject]$obj
}
function Stats() { return ((Send-Once 'Get' '/p13b/harness/stats' "$RunId-stats-$($script:seq)").body | ConvertFrom-Json).evict }

# ---------------------------------------------------------------- the loaded variant must be the candidate
$statsStart = Stats
Add-Check 'baseline.loaded_delay_is_candidate' (([long]$statsStart.second_delete_delay_ms) -eq [long]$ExpectedDelayMs) `
    "second_delete_delay_ms=$($statsStart.second_delete_delay_ms) expected=$ExpectedDelayMs (variant $Variant)"
Add-Check 'baseline.max_active_is_256' (([long]$statsStart.max_active) -eq 256) "max_active=$($statsStart.max_active) (production default, unchanged)"
Add-Check 'baseline.stats_fresh' (([long]$statsStart.accepted) -eq 0 -and ([long]$statsStart.submit_attempts) -eq 0 -and ([long]$statsStart.active_now) -eq 0) `
    "accepted=$($statsStart.accepted) submit_attempts=$($statsStart.submit_attempts) active=$($statsStart.active_now) (a fresh instance: no earlier session leaked in)"

# ---------------------------------------------------------------- D-W: three window rounds
$windowResults = New-Object System.Collections.ArrayList
$wIndex = 0
foreach ($id in $WindowIds) {
    $pause = $WindowPauses[$wIndex]
    $wIndex++
    $tag = "w$wIndex"
    $roundStart = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $key = "$CacheKeyPrefix$id"
    Redis-In $RedisDb @('DEL', $key) | Out-Null
    Redis-In $RedisDb @('DEL', "${key}:lock") | Out-Null
    $readReqId = "$RunId-$tag-read"
    $pending = Start-AsyncGet "/api/v1/article/detail/$id" $readReqId
    $delayEv = @(Wait-Event ('requestId=' + [regex]::Escape($readReqId) + ' .*event=cache\.write\.delay\.begin ') $EventTimeoutMs)
    $delaySeen = ($delayEv.Count -ge 1)
    $delayBeginMs = -1
    if ($delaySeen) { $delayBeginMs = Ev-Time $delayEv[0] }
    $write = $null
    if ($delaySeen) { $write = Send-Once 'Post' "/p13b/harness/score?id=$id&view=1&like=1&comment=1&collect=1" "$RunId-$tag-write" }
    $reader = Finish-AsyncGet $pending
    $donePattern = 'requestId=' + [regex]::Escape($readReqId) + ' .*event=cache\.write\.done '
    $null = Wait-Event $donePattern $EventTimeoutMs
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $SettleTimeoutMs) {
        $acc0 = @(Get-Events | Where-Object { $_ -match ' event=cache\.evict\.second_accepted ' -and $_ -match " articleId=$id " -and (Ev-Time $_) -ge $roundStart })
        $succ0 = @(Get-Events | Where-Object { $_ -match ' event=cache\.evict\.second_succeeded ' -and $_ -match " articleId=$id " -and (Ev-Time $_) -ge $roundStart })
        $fail0 = @(Get-Events | Where-Object { $_ -match ' event=cache\.evict\.second_failed ' -and $_ -match " articleId=$id " -and (Ev-Time $_) -ge $roundStart })
        if ($acc0.Count -ge 1 -and $acc0.Count -eq ($succ0.Count + $fail0.Count)) { break }
        Start-Sleep -Milliseconds 50
    }
    $evAll = @(Get-Events | Where-Object { $_ -match " articleId=$id " -and (Ev-Time $_) -ge $roundStart })
    Write-RunFileText -State $script:run -Path (Join-Path $outDir ("events-" + $tag + ".log")) -Text ((@($evAll)) -join "`r`n")
    $commitEv = @($evAll | Where-Object { $_ -match ' event=tx\.after_commit ' })
    $wdoneEv = @($evAll | Where-Object { $_ -match $donePattern })
    $accEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_accepted ' })
    $succEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_succeeded ' })
    $rejEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_rejected ' })
    $firstOkEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.ok ' -and $_ -notmatch 'phase=[^ ]*:second' })
    $commitMs = if ($commitEv.Count -ge 1) { Ev-Time $commitEv[0] } else { -1 }
    $wdoneMs = if ($wdoneEv.Count -ge 1) { Ev-Time $wdoneEv[0] } else { -1 }
    $succMs = if ($succEv.Count -ge 1) { Ev-Time $succEv[0] } else { -1 }
    $backfillAfterSecond = ($wdoneMs -gt $succMs -and $succMs -gt 0 -and $wdoneMs -gt 0)
    $dbAfter = Db-Counts $id
    $newReads = New-Object System.Collections.ArrayList
    for ($k = 1; $k -le $NewReadCount; $k++) {
        $nr = Send-Once 'Get' "/api/v1/article/detail/$id" "$RunId-$tag-newread$k"
        $null = $newReads.Add([ordered]@{ sequence = $k; at_ms = $nr.at_ms; http = $nr.http; views = $nr.views; sha256 = $nr.sha256; ttl = (Redis-In $RedisDb @('TTL', $key)) })
        if ($k -lt $NewReadCount) { Start-Sleep -Milliseconds $NewReadGapMs }
    }
    $dbViews = [long](($dbAfter -split '\|')[0])
    $staleCount = @($newReads | Where-Object { $_.views -ne $dbViews }).Count
    $staleSpanMs = [long]$newReads[$newReads.Count - 1].at_ms - [long]$newReads[0].at_ms
    $null = $windowResults.Add([ordered]@{
            tag = $tag; article_id = $id; planned_pause_ms = $pause
            times = [ordered]@{ delay_begin = $delayBeginMs; commit = $commitMs; cache_write_done = $wdoneMs; second_succeeded = $succMs
                backfill_minus_commit_ms = $(if ($wdoneMs -gt 0 -and $commitMs -gt 0) { $wdoneMs - $commitMs } else { -1 })
                second_minus_commit_ms = $(if ($succMs -gt 0 -and $commitMs -gt 0) { $succMs - $commitMs } else { -1 }) }
            reader = [ordered]@{ http = $reader.http; views = $reader.views; bytes = $reader.bytes; sha256 = $reader.sha256 }
            writer = [ordered]@{ http = $write.http; ok = ($write.body -match '"ok"\s*:\s*true') }
            db_before = $dbBefore["$id"]; db_after = $dbAfter
            second_delete = [ordered]@{ accepted = $accEv.Count; succeeded = $succEv.Count; rejected = $rejEv.Count; first_phase_ok = $firstOkEv.Count }
            backfill_after_second_delete = $backfillAfterSecond
            new_reads = @($newReads); stale_reads = $staleCount; stale_span_ms = $staleSpanMs
        })
    $orderOk = ($delaySeen -and $commitMs -gt $delayBeginMs -and $wdoneMs -gt $commitMs -and $succMs -gt $commitMs)
    Add-Check ("window.$tag.timeline_attributable") $orderOk `
        ("pause={0}ms delay_begin={1} commit={2} write_done={3} second_succeeded={4} (backfill-commit={5}ms second-commit={6}ms)" -f `
        $pause, $delayBeginMs, $commitMs, $wdoneMs, $succMs, $(if ($wdoneMs -gt 0 -and $commitMs -gt 0) { $wdoneMs - $commitMs } else { -1 }), $(if ($succMs -gt 0 -and $commitMs -gt 0) { $succMs - $commitMs } else { -1 }))
    Add-Check ("window.$tag.only_one_writer_delete") ($accEv.Count -eq 1 -and $rejEv.Count -eq 0 -and $firstOkEv.Count -eq 1 -and $succEv.Count -eq 1) `
        ("accepted={0} succeeded={1} rejected={2} first_phase_ok={3}" -f $accEv.Count, $succEv.Count, $rejEv.Count, $firstOkEv.Count)
    $expectStale = $backfillAfterSecond
    $matches = ($staleCount -eq $NewReadCount) -eq $expectStale
    Add-Check ("window.$tag.stale_matches_event_order") $matches `
        ("backfill_after_second_delete={0} -> expected stale={1}, observed stale={2}/{3} (db views={4}, reader views={5})" -f `
        $backfillAfterSecond, $expectStale, $staleCount, $NewReadCount, $dbViews, $reader.views)
}

# ---------------------------------------------------------------- D-C: one cost block
$costStart = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$statsBeforeBlock = Stats
foreach ($id in $CostIds) {
    Redis-In $RedisDb @('DEL', "$CacheKeyPrefix$id") | Out-Null
    Redis-In $RedisDb @('DEL', "$CacheKeyPrefix$id`:lock") | Out-Null
}
# warm-up reads: reported separately, never counted in the block statistics
$warmReads = 0
foreach ($id in $CostIds) { $null = Send-Once 'Get' "/api/v1/article/detail/$id" "$RunId-warm-$id"; $warmReads++ }
$statsWarm = Stats
$blockStart = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$readsIssued = 0; $writesIssued = 0; $readFailures = 0; $writeFailures = 0
for ($loop = 1; $loop -le $CostLoops; $loop++) {
    foreach ($id in $CostIds) {
        $r = Send-Once 'Get' "/api/v1/article/detail/$id" "$RunId-c$loop-r$id"
        $readsIssued++
        if ($r.http -ne 200 -or $r.views -lt 0) { $readFailures++ }
    }
    for ($w = 0; $w -lt $WritesPerLoop; $w++) {
        $idx = (($loop - 1) * $WritesPerLoop + $w) % $CostIds.Count
        $id = $CostIds[$idx]
        $wr = Send-Once 'Post' "/p13b/harness/score?id=$id&view=1&like=1&comment=1&collect=1" "$RunId-c$loop-w$w"
        $writesIssued++
        if ($wr.http -ne 200 -or $wr.body -notmatch '"ok"\s*:\s*true') { $writeFailures++ }
    }
}
$blockEnd = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$statsAfterBlock = $statsBeforeBlock
while ($sw.ElapsedMilliseconds -lt $SettleTimeoutMs) {
    $statsAfterBlock = Stats
    if (([long]$statsAfterBlock.active_now) -eq 0) { break }
    Start-Sleep -Milliseconds 100
}
$settleEnd = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

$costIdPattern = '^(' + (($CostIds | ForEach-Object { "$_" }) -join '|') + ')$'
$backfills = 0
foreach ($line in (Get-Events)) {
    if ($line -notmatch ' event=db\.snapshot\.begin ') { continue }
    $aid = [regex]::Match($line, ' articleId=(\d+) ').Groups[1].Value
    if ($aid -notmatch $costIdPattern) { continue }
    $ms = Ev-Time $line
    if ($ms -ge $blockStart -and $ms -le $blockEnd) { $backfills++ }
}
$hits = $readsIssued - $backfills
$blockMs = $blockEnd - $blockStart
$dAccepted = [long]$statsAfterBlock.accepted - [long]$statsBeforeBlock.accepted
$dDeletes = [long]$statsAfterBlock.delete_attempts - [long]$statsBeforeBlock.delete_attempts
$dRejected = [long]$statsAfterBlock.rejected - [long]$statsBeforeBlock.rejected
$blockResult = [ordered]@{
    block_start_ms = $blockStart; block_end_ms = $blockEnd; settle_end_ms = $settleEnd
    elapsed_ms = $blockMs; settle_ms = $settleEnd - $blockEnd
    warm_reads = $warmReads
    reads = $readsIssued; hits = $hits; backfills = $backfills; read_failures = $readFailures
    hit_rate = $(if ($readsIssued -gt 0) { [Math]::Round($hits / $readsIssued, 4) } else { 0 })
    writes = $writesIssued; write_failures = $writeFailures
    reads_per_sec = $(if ($blockMs -gt 0) { [Math]::Round($readsIssued * 1000.0 / $blockMs, 2) } else { 0 })
    writes_per_sec = $(if ($blockMs -gt 0) { [Math]::Round($writesIssued * 1000.0 / $blockMs, 2) } else { 0 })
    accepted_delta = $dAccepted; deletes_delta = $dDeletes; rejected_delta = $dRejected
    active_peak = [long]$statsAfterBlock.active_peak
    active_now_after_settle = [long]$statsAfterBlock.active_now
    succeeded_total = [long]$statsAfterBlock.succeeded; failed_total = [long]$statsAfterBlock.failed; cancelled_total = [long]$statsAfterBlock.cancelled
    stats_before_block = $statsBeforeBlock; stats_after_warmup = $statsWarm; stats_after_block = $statsAfterBlock
}
Add-Check 'cost.block_issued_as_planned' ($readsIssued -eq ($CostLoops * $CostIds.Count) -and $writesIssued -eq ($CostLoops * $WritesPerLoop) -and $readFailures -eq 0 -and $writeFailures -eq 0) `
    "reads=$readsIssued writes=$writesIssued read_failures=$readFailures write_failures=$writeFailures elapsed=$($blockMs)ms"
Add-Check 'cost.no_limit_rejection' ($dRejected -eq 0 -and ([long]$statsAfterBlock.rejected_backlog) -eq 0) `
    "rejected_delta=$dRejected rejected_backlog=$($statsAfterBlock.rejected_backlog) (no refusal perturbed the delay comparison)"
Add-Check 'cost.deletes_match_two_per_write' ($dDeletes -eq (2 * $writesIssued)) `
    "delete_attempts_delta=$dDeletes for $writesIssued writes (first + second delete each)"
Add-Check 'cost.tail_settled' (([long]$statsAfterBlock.active_now) -eq 0 -and ([long]$statsAfterBlock.accepted) -eq (([long]$statsAfterBlock.succeeded) + ([long]$statsAfterBlock.failed) + ([long]$statsAfterBlock.cancelled)) -and ([long]$statsAfterBlock.failed) -eq 0) `
    "active=$($statsAfterBlock.active_now) accepted=$($statsAfterBlock.accepted) succeeded=$($statsAfterBlock.succeeded) failed=$($statsAfterBlock.failed) cancelled=$($statsAfterBlock.cancelled) after $($blockResult.settle_ms)ms of settling"
Add-Check 'cost.backfill_and_hits_attributed' ($hits -ge 0 -and $backfills -ge 0 -and ($hits + $backfills) -eq $readsIssued) `
    "reads=$readsIssued hits=$hits backfills=$backfills (backfills counted from the real db.snapshot.begin events inside the block window)"

# ---------------------------------------------------------------- restore and verify
$restoreLog = New-Object System.Collections.ArrayList
foreach ($t in $tables) { $null = $restoreLog.Add("DELETE FROM $Database.$t WHERE id IN ($idList);") }
$delFile = Join-Path $outDir 'restore-delete.sql'
[System.IO.File]::WriteAllText($delFile, (($restoreLog) -join "`r`n"), $utf8)
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Get-Content -LiteralPath $delFile -Raw | & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser $Database 1> (Join-Path $outDir 'restore-delete.log') 2>&1
$delCode = $LASTEXITCODE
foreach ($t in $tables) {
    Get-Content -LiteralPath (Join-Path $captureDir "$t.capture.sql") -Raw | & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser $Database 1>> (Join-Path $outDir 'restore-insert.log') 2>&1
}
$ErrorActionPreference = $saved
$dbRestored = [ordered]@{}
foreach ($id in $allIds) { $dbRestored["$id"] = (Db-Counts $id) }
$mismatch = @($allIds | Where-Object { $dbRestored["$_"] -ne $dbBefore["$_"] })
$rowsAfter = (Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id IN ($idList);")
foreach ($id in $allIds) {
    Redis-In $RedisDb @('DEL', "$CacheKeyPrefix$id") | Out-Null
    Redis-In $RedisDb @('DEL', "$CacheKeyPrefix$id`:lock") | Out-Null
}
$db0After = (Redis-In 0 @('DBSIZE'))
Add-Check 'restore.applied_and_fields_match' ($delCode -eq 0 -and $mismatch.Count -eq 0 -and $rowsAfter -eq "$($allIds.Count)") `
    "delete_exit=$delCode mismatched_rows=$($mismatch.Count) rows=$rowsAfter of $($allIds.Count)"
Add-Check 'restore.keys_removed_and_db0_untouched' ($db0After -eq '0' -and (Redis-In $RedisDb @('DBSIZE')) -eq '0') `
    "db5=$((Redis-In $RedisDb @('DBSIZE'))) db0=$db0After (DB0 never written, no FLUSHDB)"

Write-RunFileText -State $script:run -Path (Join-Path $outDir 'requests.jsonl') -Text ((@($requestLog) | ForEach-Object { ($_ | ConvertTo-Json -Compress -Depth 4) }) -join "`r`n")
$client.Dispose()
$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId; variant = $Variant; expected_delay_ms = $ExpectedDelayMs; round = $RoundIndex; order = $Order
    base = $Base; events = $Events
    window_ids = @($WindowIds); cost_ids = @($CostIds); window_pauses = @($WindowPauses)
    db_before = $dbBefore; db_restored = $dbRestored; capture_sha256 = $captureSha
    stats_start = $statsStart
    windows = @($windowResults)
    cost = $blockResult
    requests = $requestLog.Count
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'session-result.json') -Text ($result | ConvertTo-Json -Depth 9)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'session-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
