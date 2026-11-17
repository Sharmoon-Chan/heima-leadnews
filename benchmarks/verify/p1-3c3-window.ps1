# P1.3c-3: the backfill window inside and beyond the fixed 500 ms second delete (ASCII only).
#
# Each round runs ONE real reader and ONE sequential real writer on the same article:
#   reader : GET /api/v1/article/detail/<id>  -> real snapshot transaction, real rebuild, real setEx.
#            The probe pauses between the snapshot and the setEx (cache.write.delay.<id>), so the backfill
#            lands at a chosen time after the writer commits.
#   writer : POST /p13b/harness/score?id=..&view=1&like=1&comment=1&collect=1 -> real public updateScore,
#            real transaction, real first delete, real 500 ms second delete (unchanged).
#
# W1 (inside the window)  : pause 300 ms  -> backfill happens BEFORE the second delete succeeds -> the second
#                           delete removes the stale value -> a new detail read returns V1.
# W2 (beyond the window)  : pause 1500 ms -> the second delete already succeeded BEFORE the backfill -> the
#                           stale V0 is written afterwards -> new detail reads keep returning V0 while the
#                           database already holds V1.
#
# Classification uses the ACTUAL event times (commit, cache.write.done, second_succeeded), never the planned sleep.
# Every round fails loudly if a limit rejection or an extra delete shows up for the article.
#
# The three tables for all round ids are captured with mysqldump BEFORE any write and restored from those
# exact files, then verified field by field. DB0 is never written and never flushed.
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [long[]]$W1Ids = @(9007199254743101, 9007199254743102, 9007199254743103),
    [long[]]$W2Ids = @(9007199254743111, 9007199254743112, 9007199254743113),
    [int]$W1PauseMs = 300,
    [int]$W2PauseMs = 1500,
    [int]$StaleReadCount = 3,
    [int]$StaleReadGapMs = 400,
    [int]$EventTimeoutMs = 12000,
    [int]$SettleTimeoutMs = 15000,
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlDump = 'D:\Soft\mysql-8.0.34-winx64\bin\mysqldump.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [int]$RedisDb = 5,
    [string]$CacheKeyPrefix = 'article:detail:',
    [int]$TimeoutSeconds = 90
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
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3c-3-window' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ w1_ids = ($W1Ids -join ','); w2_ids = ($W2Ids -join ','); w1_pause_ms = $W1PauseMs; w2_pause_ms = $W2PauseMs; base = $Base; redis_db = $RedisDb; delay_ms = 500 } `
        -Targets @(($W1Ids + $W2Ids) | ForEach-Object { "$_" }) -DataSet $Database
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-52} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'FAIL' }), $d
}
function Redis-In([int]$db, [string[]]$a) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', "$db") + $a
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Sql([string]$q) {
    $o = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--raw' '--default-character-set=utf8mb4' '-e' $q 2>&1
    return (($o | Out-String).Trim())
}
function Db-Counts([long]$id) { return (Sql "SELECT CONCAT_WS('|', views, likes, comment, collection) FROM $Database.ap_article WHERE id=$id;") }
function Views-Of([string]$body) {
    $m = [regex]::Match($body, '"views"\s*:\s*(\d+)')
    if ($m.Success) { return [long]$m.Groups[1].Value }
    return -1
}
function Key-Ttl([string]$key) { return (Redis-In $RedisDb @('TTL', $key)) }
function Key-Value([string]$key) { return (Redis-In $RedisDb @('GET', $key)) }

# ---------------------------------------------------------------- capture BEFORE any write
$allIds = @($W1Ids) + @($W2Ids)
$captureDir = Join-Path $outDir 'capture'
New-Item -ItemType Directory -Path $captureDir | Out-Null
$tables = @('ap_article', 'ap_article_content', 'ap_article_config')
$where = "id IN ($($allIds -join ','))"
foreach ($t in $tables) {
    $file = Join-Path $captureDir "$t.capture.sql"
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $MysqlDump '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '--no-create-info' '--skip-extended-insert' `
        '--complete-insert' '--where' $where $Database $t 1> $file 2> (Join-Path $captureDir "$t.capture.err")
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($code -ne 0) { throw "mysqldump failed for $t (exit $code), see capture/$t.capture.err" }
}
$captureSha = [ordered]@{}
foreach ($t in $tables) { $captureSha[$t] = (Get-FileHash -LiteralPath (Join-Path $captureDir "$t.capture.sql") -Algorithm SHA256).Hash.ToLower() }

$dbBefore = [ordered]@{}
$keyBefore = [ordered]@{}
foreach ($id in $allIds) {
    $dbBefore["$id"] = (Db-Counts $id)
    $key = "$CacheKeyPrefix$id"
    $keyBefore["$id"] = [ordered]@{ exists = (Redis-In $RedisDb @('EXISTS', $key)); ttl = (Key-Ttl $key) }
}
$db0Before = (Redis-In 0 @('DBSIZE'))
$db5Before = (Redis-In $RedisDb @('DBSIZE'))
$rowsBefore = (Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id IN ($($allIds -join ','));")
Add-Check 'setup.capture_before_write' (@($dbBefore.Values | Where-Object { $_ -match '^\d+\|\d+\|\d+\|\d+$' }).Count -eq $allIds.Count -and $rowsBefore -eq "$($allIds.Count)" -and $db0Before -eq '0') `
    "rows=$rowsBefore of $($allIds.Count) db5=$db5Before db0=$db0Before states=$(($dbBefore.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ' ')"

# ---------------------------------------------------------------- HTTP
Add-Type -AssemblyName System.Net.Http | Out-Null
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
$script:seq = 0

function New-DetailRequest([string]$path, [string]$reqId) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base$path")
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    return $req
}
function Save-Response([System.Net.Http.HttpResponseMessage]$resp, [string]$tag) {
    $script:seq++
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $p = Join-Path $outDir (("raw-{0:D2}-{1}.body.json" -f $script:seq, $tag))
    Write-RunFileText -State $script:run -Path $p -Text $text
    $sha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
    return [pscustomobject]@{ http = [int]$resp.StatusCode; text = $text; bytes = $bytes.Length; sha = $sha; path = $p; views = (Views-Of $text) }
}
function Get-Once([string]$path, [string]$reqId) {
    $resp = $client.SendAsync((New-DetailRequest $path $reqId)).GetAwaiter().GetResult()
    return (Save-Response $resp $reqId)
}
function Post-Once([string]$path, [string]$reqId) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$Base$path")
    $req.Content = New-Object System.Net.Http.StringContent('')
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    return (Save-Response $resp $reqId)
}
function Start-AsyncGet([string]$path, [string]$reqId) {
    return [pscustomobject]@{ reqId = $reqId; task = $client.SendAsync((New-DetailRequest $path $reqId)) }
}
function Finish-AsyncGet($pending) {
    $resp = $pending.task.GetAwaiter().GetResult()
    return (Save-Response $resp $pending.reqId)
}

# ---------------------------------------------------------------- event helpers (read the real probe log)
function Get-Events { if (Test-Path -LiteralPath $Events) { return @(Get-Content -LiteralPath $Events) } return @() }
function Wait-Event([string]$pattern, [int]$timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        $hit = @(Get-Events | Where-Object { $_ -match $pattern })
        if ($hit.Count -gt 0) { return $hit }
        Start-Sleep -Milliseconds 20
    }
    return @()
}
function Ev-Time([string]$line) { return [long]([regex]::Match($line, 'epochMs=(\d+)').Groups[1].Value) }
function Ev-First([string]$articleId, [string]$name, [long]$since) {
    $pat = ' event=' + [regex]::Escape($name) + ' '
    return @(Get-Events | Where-Object {
        $_ -match $pat -and $_ -match (" articleId=" + $articleId + " ") -and ([long]([regex]::Match($_, 'epochMs=(\d+)').Groups[1].Value) -ge $since)
    })
}

# ---------------------------------------------------------------- one round
$rounds = New-Object System.Collections.ArrayList
function Invoke-Round([string]$group, [int]$index, [long]$id, [int]$pauseMs) {
    $tag = "r$index"
    $roundStart = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $key = "$CacheKeyPrefix$id"
    $readReqId = "$RunId-$group$tag-read"
    $writeReqId = "$RunId-$group$tag-write"

    # a clean read: remove only this exact key so the reader really rebuilds from the database
    Redis-In $RedisDb @('DEL', $key) | Out-Null
    Redis-In $RedisDb @('DEL', "${key}:lock") | Out-Null

    $pending = Start-AsyncGet "/api/v1/article/detail/$id" $readReqId
    $delayBegin = @(Wait-Event ('requestId=' + [regex]::Escape($readReqId) + ' .*event=cache\.write\.delay\.begin ') $EventTimeoutMs)
    $delaySeen = ($delayBegin.Count -ge 1)
    $delayBeginMs = -1
    if ($delaySeen) { $delayBeginMs = Ev-Time $delayBegin[0] }

    # the writer only starts once the reader really is paused between snapshot and setEx
    $write = $null
    if ($delaySeen) {
        $write = Post-Once "/p13b/harness/score?id=$id&view=1&like=1&comment=1&collect=1" $writeReqId
    }
    $reader = Finish-AsyncGet $pending

    # wait for the round to settle: backfill done + second delete finished
    $writeDonePattern = 'requestId=' + [regex]::Escape($readReqId) + ' .*event=cache\.write\.done '
    $null = Wait-Event $writeDonePattern $EventTimeoutMs
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $SettleTimeoutMs) {
        $acc = @(Ev-First "$id" 'cache.evict.second_accepted' $roundStart)
        $succ = @(Ev-First "$id" 'cache.evict.second_succeeded' $roundStart)
        $fail = @(Ev-First "$id" 'cache.evict.second_failed' $roundStart)
        if (($acc.Count -eq $succ.Count + $fail.Count) -and $acc.Count -ge 1) { break }
        Start-Sleep -Milliseconds 60
    }
    $evAll = @(Get-Events | Where-Object {
        $_ -match (" articleId=" + $id + " ") -and ([long]([regex]::Match($_, 'epochMs=(\d+)').Groups[1].Value) -ge $roundStart)
    })
    Write-RunFileText -State $script:run -Path (Join-Path $outDir ("events-" + $group + "-" + $tag + ".log")) -Text ((@($evAll)) -join "`r`n")

    $commitEv = @($evAll | Where-Object { $_ -match ' event=tx\.after_commit ' })
    $writeDoneEv = @($evAll | Where-Object { $_ -match $writeDonePattern })
    $accEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_accepted ' })
    $succEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_succeeded ' })
    $failEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_failed ' })
    $rejEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_rejected ' })
    $firstOkEv = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.ok ' -and $_ -notmatch 'phase=[^ ]*:second' })
    $commitMs = if ($commitEv.Count -ge 1) { Ev-Time $commitEv[0] } else { -1 }
    $writeDoneMs = if ($writeDoneEv.Count -ge 1) { Ev-Time $writeDoneEv[0] } else { -1 }
    $succMs = if ($succEv.Count -ge 1) { Ev-Time $succEv[0] } else { -1 }

    $dbAfter = (Db-Counts $id)
    $before = ($dbBefore["$id"] -split '\|')
    $after = ($dbAfter -split '\|')

    # new detail reads AFTER the backfill: the point of the round
    $newReads = New-Object System.Collections.ArrayList
    for ($k = 1; $k -le $StaleReadCount; $k++) {
        $nrReqId = "$RunId-$group$tag-newread$k"
        $ttlBefore = Key-Ttl $key
        $atMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $nr = Get-Once "/api/v1/article/detail/$id" $nrReqId
        $ttlAfter = Key-Ttl $key
        $null = $newReads.Add([ordered]@{
                sequence = $k; request_id = $nrReqId; at_ms = $atMs; http = $nr.http; views = $nr.views
                stale = ($nr.views -ne [long]$after[0]); ttl_before = $ttlBefore; ttl_after = $ttlAfter
                bytes = $nr.bytes; sha256 = $nr.sha; key_views = (Views-Of (Key-Value $key))
            })
        if ($k -lt $StaleReadCount) { Start-Sleep -Milliseconds $StaleReadGapMs }
    }
    $staleCount = @($newReads | Where-Object { $_.stale }).Count
    # the measured span between the first and the last new read (planned gaps are NOT used as evidence)
    $staleSpanMs = [long]$newReads[$newReads.Count - 1].at_ms - [long]$newReads[0].at_ms
    $dCommit = -1; $dSecond = -1; $dBackfill = -1
    if ($writeDoneMs -ge 0 -and $commitMs -ge 0) { $dCommit = $writeDoneMs - $commitMs }
    if ($succMs -ge 0 -and $commitMs -ge 0) { $dSecond = $succMs - $commitMs }
    if ($succMs -ge 0 -and $writeDoneMs -ge 0) { $dBackfill = $succMs - $writeDoneMs }
    $writerResult = $null
    if ($null -ne $write) {
        $writerResult = [ordered]@{ http = $write.http; ok = ($write.text -match '"ok"\s*:\s*true'); text = $write.text }
    }

    $result = [ordered]@{
        group = $group; index = $index; round = "$group-$tag"; article_id = $id; planned_pause_ms = $pauseMs
        read_request_id = $readReqId; write_request_id = $writeReqId
        delay_begin_seen = $delaySeen
        times = [ordered]@{
            delay_begin = $delayBeginMs; commit = $commitMs; cache_write_done = $writeDoneMs; second_succeeded = $succMs
            backfill_minus_commit_ms = $dCommit
            second_succeeded_minus_commit_ms = $dSecond
            second_succeeded_minus_backfill_ms = $dBackfill
        }
        reader = [ordered]@{ http = $reader.http; views = $reader.views; bytes = $reader.bytes; sha256 = $reader.sha }
        writer = $writerResult
        db_before = $dbBefore["$id"]; db_after = $dbAfter
        second_delete = [ordered]@{ accepted = $accEv.Count; succeeded = $succEv.Count; failed = $failEv.Count; rejected = $rejEv.Count; first_phase_ok = $firstOkEv.Count }
        new_reads = @($newReads)
        stale_reads = $staleCount; stale_observation_span_ms = $staleSpanMs
    }
    $null = $rounds.Add($result)
    return $result
}

# ---------------------------------------------------------------- W1: inside the window
$w1 = New-Object System.Collections.ArrayList
$i = 0
foreach ($id in $W1Ids) {
    $i++
    $r = Invoke-Round 'W1' $i $id $W1PauseMs
    $null = $w1.Add($r)
    $t = $r.times
    $okOrder = ($t.delay_begin -ge 0) -and ($t.commit -gt $t.delay_begin) -and ($t.cache_write_done -gt $t.commit) -and ($t.second_succeeded -gt $t.cache_write_done)
    Add-Check ("w1.r{0}.timeline_backfill_before_second_delete" -f $i) $okOrder `
        ("delay_begin={0} commit={1} cache_write_done={2} second_succeeded={3} (backfill-commit={4}ms, second-backfill={5}ms)" -f `
        $t.delay_begin, $t.commit, $t.cache_write_done, $t.second_succeeded, $t.backfill_minus_commit_ms, $t.second_succeeded_minus_backfill_ms)
    Add-Check ("w1.r{0}.reader_was_stale_snapshot" -f $i) ($r.reader.http -eq 200 -and $r.reader.views -eq [long](($r.db_before -split '\|')[0])) `
        ("reader http={0} views={1} (snapshot taken before the write: {2})" -f $r.reader.http, $r.reader.views, ($r.db_before -split '\|')[0])
    Add-Check ("w1.r{0}.writer_committed_plus_one" -f $i) ($null -ne $r.writer -and $r.writer.ok -and $r.db_after -match '^\d+\|\d+\|\d+\|\d+$' -and `
            (([long]($r.db_after -split '\|')[0] - [long](($r.db_before -split '\|')[0])) -eq 1)) `
        ("writer http={0} db {1} -> {2}" -f $r.writer.http, $r.db_before, $r.db_after)
    Add-Check ("w1.r{0}.second_delete_succeeded_once" -f $i) ($r.second_delete.accepted -eq 1 -and $r.second_delete.succeeded -eq 1 -and $r.second_delete.failed -eq 0 -and $r.second_delete.first_phase_ok -eq 1) `
        ("accepted={0} succeeded={1} failed={2} first_phase_ok={3}" -f $r.second_delete.accepted, $r.second_delete.succeeded, $r.second_delete.failed, $r.second_delete.first_phase_ok)
    Add-Check ("w1.r{0}.no_limit_rejection_or_extra_delete" -f $i) ($r.second_delete.rejected -eq 0 -and $r.second_delete.first_phase_ok -eq 1) `
        ("second_rejected={0} first_phase_ok={1} (exactly one writer delete in the round)" -f $r.second_delete.rejected, $r.second_delete.first_phase_ok)
    Add-Check ("w1.r{0}.new_read_sees_v1" -f $i) ($r.stale_reads -eq 0 -and $r.new_reads[0].http -eq 200) `
        ("new reads={0} stale={1} first views={2} db views={3} ttl={4}" -f $r.new_reads.Count, $r.stale_reads, $r.new_reads[0].views, ($r.db_after -split '\|')[0], $r.new_reads[0].ttl_after)
}

# ---------------------------------------------------------------- W2: beyond the window
$w2 = New-Object System.Collections.ArrayList
$i = 0
foreach ($id in $W2Ids) {
    $i++
    $r = Invoke-Round 'W2' $i $id $W2PauseMs
    $null = $w2.Add($r)
    $t = $r.times
    $okOrder = ($t.delay_begin -ge 0) -and ($t.commit -gt $t.delay_begin) -and ($t.second_succeeded -gt $t.commit) -and ($t.cache_write_done -gt $t.second_succeeded)
    Add-Check ("w2.r{0}.timeline_second_delete_before_backfill" -f $i) $okOrder `
        ("delay_begin={0} commit={1} second_succeeded={2} cache_write_done={3} (second-commit={4}ms, backfill-second={5}ms)" -f `
        $t.delay_begin, $t.commit, $t.second_succeeded, $t.cache_write_done, $t.second_succeeded_minus_commit_ms, (-1 * $t.second_succeeded_minus_backfill_ms))
    Add-Check ("w2.r{0}.reader_was_stale_snapshot" -f $i) ($r.reader.http -eq 200 -and $r.reader.views -eq [long](($r.db_before -split '\|')[0])) `
        ("reader http={0} views={1} (snapshot taken before the write)" -f $r.reader.http, $r.reader.views)
    Add-Check ("w2.r{0}.writer_committed_plus_one" -f $i) ($null -ne $r.writer -and $r.writer.ok -and `
            (([long]($r.db_after -split '\|')[0] - [long](($r.db_before -split '\|')[0])) -eq 1)) `
        ("writer http={0} db {1} -> {2}" -f $r.writer.http, $r.db_before, $r.db_after)
    Add-Check ("w2.r{0}.second_delete_succeeded_once" -f $i) ($r.second_delete.accepted -eq 1 -and $r.second_delete.succeeded -eq 1 -and $r.second_delete.failed -eq 0 -and $r.second_delete.first_phase_ok -eq 1) `
        ("accepted={0} succeeded={1} failed={2} first_phase_ok={3}" -f $r.second_delete.accepted, $r.second_delete.succeeded, $r.second_delete.failed, $r.second_delete.first_phase_ok)
    Add-Check ("w2.r{0}.no_limit_rejection_or_extra_delete" -f $i) ($r.second_delete.rejected -eq 0 -and $r.second_delete.first_phase_ok -eq 1) `
        ("second_rejected={0} first_phase_ok={1}" -f $r.second_delete.rejected, $r.second_delete.first_phase_ok)
    Add-Check ("w2.r{0}.new_read_is_stale_v0" -f $i) ($r.stale_reads -eq $StaleReadCount -and $r.new_reads[0].views -eq [long](($r.db_before -split '\|')[0])) `
        ("new reads={0} stale={1} views={2} (db holds {3}) ttl={4}" -f $r.new_reads.Count, $r.stale_reads, $r.new_reads[0].views, ($r.db_after -split '\|')[0], $r.new_reads[0].ttl_after)
    Add-Check ("w2.r{0}.stale_observed_for_at_least_span" -f $i) ($r.stale_reads -eq $StaleReadCount -and $r.stale_observation_span_ms -gt 0 -and $r.new_reads[0].ttl_after -match '^\d+$' -and [int]$r.new_reads[0].ttl_after -gt 0) `
        ("all {0} reads stale across >= {1}ms; ttl={2}s (no expiry claim is made)" -f $r.stale_reads, $r.stale_observation_span_ms, $r.new_reads[0].ttl_after)
}

# ---------------------------------------------------------------- restore and verify
$restoreLog = New-Object System.Collections.ArrayList
foreach ($t in $tables) { $null = $restoreLog.Add("DELETE FROM $Database.$t WHERE id IN ($($allIds -join ','));") }
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
Add-Check 'restore.applied' ($delCode -eq 0) "delete exit=$delCode; inserts replayed from the captured dump files"

$dbRestored = [ordered]@{}
foreach ($id in $allIds) { $dbRestored["$id"] = (Db-Counts $id) }
$mismatch = @($allIds | Where-Object { $dbRestored["$_"] -ne $dbBefore["$_"] })
$rowsAfter = (Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id IN ($($allIds -join ','));")
Add-Check 'restore.fields_match_capture' ($mismatch.Count -eq 0) ("all $($allIds.Count) rows back to the captured four fields: $(($dbRestored.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ' ')")
Add-Check 'restore.rows_present_exactly_once' ($rowsAfter -eq "$($allIds.Count)") "ap_article rows for the round ids: $rowsAfter"

foreach ($id in $allIds) {
    $key = "$CacheKeyPrefix$id"
    Redis-In $RedisDb @('DEL', $key) | Out-Null
    Redis-In $RedisDb @('DEL', "${key}:lock") | Out-Null
}
$db0After = (Redis-In 0 @('DBSIZE'))
$db5After = (Redis-In $RedisDb @('DBSIZE'))
$leftKeys = @($allIds | Where-Object { (Redis-In $RedisDb @('EXISTS', "$CacheKeyPrefix$_")) -ne '0' })
Add-Check 'restore.keys_removed_and_db0_untouched' ($leftKeys.Count -eq 0 -and $db0After -eq '0') `
    "round keys left=$($leftKeys.Count) db5=$db5After db0=$db0After (DB0 was never written, no FLUSHDB)"

$client.Dispose()
$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    base = $Base
    events = $Events
    fixed_delay_ms = 500
    w1_pause_ms = $W1PauseMs
    w2_pause_ms = $W2PauseMs
    stale_read_count = $StaleReadCount
    stale_read_gap_ms = $StaleReadGapMs
    db_before = $dbBefore
    db_restored = $dbRestored
    capture_sha256 = $captureSha
    rounds = @($rounds)
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'window-result.json') -Text ($result | ConvertTo-Json -Depth 9)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'window-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
