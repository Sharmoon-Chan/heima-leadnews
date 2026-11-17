# P1.3b cost observation, rework C: per-request raw records, warm-up excluded, isolated Redis database.
#
# Shape (task card): one sequential writer on the real public updateScore path (+1 view per committed
# call) and one sequential reader on the real public detail path; for every 10 detail reads insert 0, 1
# or 5 already committed counter writes; each tier runs $Cycles cycles. Every tier starts from the same
# field values, an empty detail cache and ONE warm-up read that is recorded separately and excluded
# from all statistics (by its request id AND by its time window, never by "tierStart - 50").
#
# Raw evidence (this is what the review asked for):
#   warmup.json            one record: request id, start/end, http code, business code, four counters, body sha
#   reads.tsv              one row per formal read: tier, cycle, seq, requestId, start, end, http, code,
#                          views, likes, comment, collection, article id string ok, origin_reads, hit
#   writes.tsv             one row per formal write: tier, cycle, seq, requestId, start, end, http, ok,
#                          counters after the commit (as returned by the next read is NOT used here)
#   events-by-request.tsv  requestId -> event counts taken from the probe event file for that request
#   tail.json              per tier: last second-delete timestamp, wait used, pending-second-delete count
#   tiers.tsv / scenario-result.json summaries
#
# Statistics are recomputed from reads.tsv / writes.tsv and the request-attributed event table, so they
# can be independently re-derived. No throughput claim, no parameter choice, no physical SQL count.
#
# ASCII only (PS 5.1 reads a BOM-less .ps1 as ANSI/GBK).
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [Parameter(Mandatory = $true)][ValidateSet('PRE', 'POST')][string]$Variant,
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [long]$ArticleId = 9007199254741021,
    [int]$Cycles = 30,
    [int]$ReadsPerCycle = 10,
    [int[]]$Tiers = @(0, 1, 5),
    [string]$BaselineFile = '',
    [int]$TailQuietMs = 1500,
    [int]$TailTimeoutMs = 10000,
    [int]$TimeoutSeconds = 30,
    [int]$RedisDb = 5,
    [int]$ChannelId = 1,
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [string]$CacheKeyPrefix = 'article:detail:'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$env:MYSQL_PWD = $MysqlPassword

. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage "P1.3b-cost-tiers-$Variant" `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ variant = $Variant; base = $Base; article = $ArticleId; cycles = $Cycles;
                       reads_per_cycle = $ReadsPerCycle; tiers = ($Tiers -join ','); redis_db = $RedisDb } `
        -Targets @("$ArticleId") -DataSet $Database
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

Add-Type -AssemblyName System.Net.Http | Out-Null
function Now-Ms { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
}
function Redis-In([int]$db, [string[]]$a) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', "$db") + $a
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Sql([string]$q) {
    $o = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--default-character-set=utf8mb4' '-e' $q 2>&1
    return (($o | Out-String).Trim())
}
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$handler.MaxConnectionsPerServer = 8
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

$key = "$CacheKeyPrefix$ArticleId"
$baselineJson = ''
if ($BaselineFile -ne '' -and (Test-Path -LiteralPath $BaselineFile)) {
    $baselineJson = [System.IO.File]::ReadAllText($BaselineFile)
} else {
    $row = Sql "SELECT CONCAT_WS('|',title,views,likes,comment,collection) FROM $Database.ap_article WHERE id=$ArticleId;"
    $p = $row -split '\|'
    $baselineJson = ([ordered]@{ article_id = $ArticleId; title = $p[0]; views = [int]$p[1]; likes = [int]$p[2];
                                 comment = [int]$p[3]; collection = [int]$p[4] } | ConvertTo-Json -Compress)
    if ($BaselineFile -ne '') { [System.IO.File]::WriteAllText($BaselineFile, $baselineJson, (New-Object System.Text.UTF8Encoding($false))) }
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'fixture-baseline.json') -Text $baselineJson
$fixture = $baselineJson | ConvertFrom-Json
$viewsBase = [int]$fixture.views

function Read-Detail([string]$reqId) {
    $start = Now-Ms
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base/api/v1/article/detail/$ArticleId")
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $body = [System.Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
        $end = Now-Ms
        $vals = @()
        foreach ($f in @('views', 'likes', 'comment', 'collection')) {
            $m = [regex]::Match($body, ('"' + $f + '"\s*:\s*(-?\d+)'))
            $vals += $(if ($m.Success) { $m.Groups[1].Value } else { 'MISSING' })
        }
        $code = [regex]::Match($body, '"code"\s*:\s*(-?\d+)')
        $idOk = $body -match [regex]::Escape('"id":"' + "$ArticleId" + '"')
        $sha = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($body))) -replace '-', ''
        return [pscustomobject]@{ start = $start; end = $end; http = [int]$resp.StatusCode; code = $(if ($code.Success) { $code.Groups[1].Value } else { 'MISSING' });
                                  views = $vals[0]; likes = $vals[1]; comment = $vals[2]; collection = $vals[3];
                                  idOk = $idOk; bodySha = $sha.ToLower(); error = ''; body = $body }
    } catch {
        return [pscustomobject]@{ start = $start; end = (Now-Ms); http = 0; code = 'ERR'; views = 'ERR'; likes = 'ERR';
                                  comment = 'ERR'; collection = 'ERR'; idOk = $false; bodySha = ''; error = $_.Exception.Message; body = '' }
    }
}
function Write-Score([string]$reqId) {
    $start = Now-Ms
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$Base/p13b/harness/score?id=$ArticleId&view=1&like=1&comment=1&collect=1")
        $req.Content = New-Object System.Net.Http.StringContent('')
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $body = [System.Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
        $end = Now-Ms
        return [pscustomobject]@{ start = $start; end = $end; http = [int]$resp.StatusCode; ok = ($body -match '"ok"\s*:\s*true'); body = $body }
    } catch {
        return [pscustomobject]@{ start = $start; end = (Now-Ms); http = 0; ok = $false; body = $_.Exception.Message }
    }
}
function Events-Snapshot([int]$tail = 0) {
    if (-not (Test-Path -LiteralPath $Events)) { return @() }
    $raw = if ($tail -gt 0) { Get-Content -LiteralPath $Events -Tail $tail } else { Get-Content -LiteralPath $Events }
    return @($raw | Where-Object { $_ -match " articleId=$ArticleId " })
}
function Get-EventMs([string]$line) {
    $m = [regex]::Match($line, 'epochMs=(\d+)')
    if ($m.Success) { return [long]$m.Groups[1].Value }
    return 0
}

function Wait-SecondDeletesQuiet([long]$fromMs) {
    # wait until no NEW second-delete line appeared for $TailQuietMs, or the timeout hits
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastNew = -1
    $lastSeen = 0
    while ($sw.ElapsedMilliseconds -lt $TailTimeoutMs) {
        $lines = @(Events-Snapshot -tail 5000 | Where-Object { $_ -match ' event=cache\.evict\.second_begin ' -and (Get-EventMs $_) -ge $fromMs })
        if ($lines.Count -ne $lastSeen) { $lastSeen = $lines.Count; $lastNew = $sw.ElapsedMilliseconds }
        elseif ($lastNew -ge 0 -and ($sw.ElapsedMilliseconds - $lastNew) -ge $TailQuietMs) { break }
        elseif ($lastNew -lt 0 -and $sw.ElapsedMilliseconds -ge $TailQuietMs) { break }
        Start-Sleep -Milliseconds 200
    }
    $all = @(Events-Snapshot -tail 5000 | Where-Object { $_ -match ' event=cache\.evict\.second_begin ' -and (Get-EventMs $_) -ge $fromMs })
    $lastMs = if ($all.Count -gt 0) { [long]([regex]::Match($all[-1], 'epochMs=(\d+)').Groups[1].Value) } else { 0 }
    return [ordered]@{ waited_ms = [long]$sw.ElapsedMilliseconds; second_deletes = $all.Count; last_second_delete_epoch_ms = $lastMs; quiet = $true }
}

$readRows = New-Object System.Collections.ArrayList
$writeRows = New-Object System.Collections.ArrayList
$tierResults = @()
$tailResults = @()
$warmupResults = @()
$readSeq = 0
$writeSeq = 0

foreach ($tier in $Tiers) {
    # identical starting point for every tier
    Sql "UPDATE $Database.ap_article SET title='P13b-iw', views=$($fixture.views), likes=$($fixture.likes), comment=$($fixture.comment), collection=$($fixture.collection), static_url=NULL WHERE id=$ArticleId;" | Out-Null
    Redis-In $RedisDb @('DEL', $key) | Out-Null
    Redis-In $RedisDb @('DEL', "$key`:lock") | Out-Null
    $null = Wait-SecondDeletesQuiet (Now-Ms)   # make sure no timer from a previous tier is still pending

    $warmId = "$Variant-$RunId-t$tier-warmup"
    $warm = Read-Detail $warmId
    $warmupResults += [ordered]@{ tier = $tier; request_id = $warmId; start = $warm.start; end = $warm.end; http = $warm.http;
                                  code = $warm.code; views = $warm.views; likes = $warm.likes; comment = $warm.comment;
                                  collection = $warm.collection; id_ok = $warm.idOk; body_sha256 = $warm.bodySha; excluded = $true }
    Start-Sleep -Milliseconds 50

    $tierStart = Now-Ms
    $tierReads = New-Object System.Collections.ArrayList
    $tierWrites = New-Object System.Collections.ArrayList
    # evenly spread the tier's writes over the reads of one cycle
    $writeAfter = @()
    if ($tier -gt 0) {
        for ($k = 1; $k -le $tier; $k++) {
            $pos = [math]::Floor($k * $ReadsPerCycle / $tier)
            if ($pos -lt 1) { $pos = 1 }
            $writeAfter += [int]$pos
        }
    }
    for ($c = 1; $c -le $Cycles; $c++) {
        for ($r = 1; $r -le $ReadsPerCycle; $r++) {
            $readSeq++
            $reqId = "$Variant-$RunId-t$tier-c$c-r$r"
            $rd = Read-Detail $reqId
            $rec = [ordered]@{ tier = $tier; cycle = $c; read_in_cycle = $r; seq = $readSeq; request_id = $reqId;
                               start_ms = $rd.start; end_ms = $rd.end; http = $rd.http; code = $rd.code;
                               views = $rd.views; likes = $rd.likes; comment = $rd.comment; collection = $rd.collection;
                               id_string_ok = $rd.idOk; body_sha256 = $rd.bodySha; error = $rd.error }
            $null = $tierReads.Add($rec)
            $null = $readRows.Add($rec)
            if ($writeAfter -contains $r) {
                $writeSeq++
                $wReqId = "$Variant-$RunId-t$tier-c$c-w$r"
                $w = Write-Score $wReqId
                $wRec = [ordered]@{ tier = $tier; cycle = $c; after_read = $r; seq = $writeSeq; request_id = $wReqId;
                                    start_ms = $w.start; end_ms = $w.end; http = $w.http; ok = $w.ok; body = $w.body }
                $null = $tierWrites.Add($wRec)
                $null = $writeRows.Add($wRec)
            }
        }
    }
    $tierEnd = Now-Ms
    $tail = Wait-SecondDeletesQuiet ($tierStart - 50)
    $tail['tier'] = $tier
    $tail['tier_end_ms'] = $tierEnd
    $tailResults += $tail

    # ---- statistics for this tier, from the saved records only ----
    $commitTimes = @($tierWrites | Where-Object { $_.ok } | ForEach-Object { [long]$_.end_ms } | Sort-Object)
    $stale = 0; $fresh = 0; $failed = 0; $idBad = 0
    foreach ($rd in $tierReads) {
        if ($rd.error -ne '' -or $rd.views -eq 'ERR') { $failed++; continue }
        if (-not $rd.id_string_ok) { $idBad++ }
        $c = 0
        foreach ($t in $commitTimes) { if ($t -le $rd.start_ms) { $c++ } else { break } }
        if ([int]$rd.views -ge ($viewsBase + $c)) { $fresh++ } else { $stale++ }
    }
    # request-attributed events: count only lines whose requestId equals a formal request of this tier
    $tierIds = @($tierReads | ForEach-Object { $_.request_id }) + @($tierWrites | ForEach-Object { $_.request_id })
    $evSnap = @(Events-Snapshot | Where-Object {
        $m = [regex]::Match($_, 'requestId=([^ ]+)')
        $m.Success -and ($tierIds -contains $m.Groups[1].Value)
    })
    $originReads = @($evSnap | Where-Object { $_ -match ' event=rebuild\.begin ' }).Count
    $hits = @($evSnap | Where-Object { $_ -match ' event=cache\.read .*hit=true' }).Count
    $misses = @($evSnap | Where-Object { $_ -match ' event=cache\.read .*hit=false' }).Count
    # deletes belong to the writer's own transaction and to the scheduler (no request context):
    # count them in the tier window and pair them with the committed writes of this tier
    $evWindow = @(Events-Snapshot | Where-Object { ([long]([regex]::Match($_, 'epochMs=(\d+)').Groups[1].Value) -ge $tierStart) -and ([long]([regex]::Match($_, 'epochMs=(\d+)').Groups[1].Value) -le $tail['last_second_delete_epoch_ms'] + 1) })
    $evictOk = @($evWindow | Where-Object { $_ -match ' event=cache\.evict\.ok ' }).Count
    $evictSecond = @($evWindow | Where-Object { $_ -match ' event=cache\.evict\.second_begin ' }).Count
    $evictFail = @($evWindow | Where-Object { $_ -match ' event=cache\.evict\.fail ' }).Count
    $readCount = $tierReads.Count
    $writeCount = @($tierWrites | Where-Object { $_.ok }).Count
    $elapsed = $tierEnd - $tierStart
    $originPer100 = if ($readCount -gt 0) { [math]::Round(100.0 * $originReads / $readCount, 2) } else { 0 }
    $wps = if ($elapsed -gt 0) { [math]::Round(1000.0 * $writeCount / $elapsed, 2) } else { 0 }

    $tierResults += [ordered]@{
        tier_writes_per_10_reads = $tier
        cycles = $Cycles
        reads_per_cycle = $ReadsPerCycle
        elapsed_ms = $elapsed
        reads = $readCount
        reads_failed = $failed
        reads_with_bad_id_string = $idBad
        writes_committed = $writeCount
        writes_failed = ($tierWrites.Count - $writeCount)
        writes_per_second_actual = $wps
        warmup_request_id = $warmId
        warmup_excluded_from_stats = $true
        reads_seeing_newest_committed = $fresh
        stale_reads = $stale
        share_reading_newest_committed = $(if ($readCount -gt 0) { [math]::Round($fresh / $readCount, 4) } else { 0 })
        origin_reads = $originReads
        origin_reads_per_100_detail_reads = $originPer100
        cache_hits = $hits
        cache_misses = $misses
        deletes_immediate_and_second = $evictOk
        deletes_second_phase = $evictSecond
        delete_failures = $evictFail
        tail_waited_ms = $tail['waited_ms']
        tail_second_deletes = $tail['second_deletes']
    }
    Write-Host ("tier {0}: reads={1} writes={2} stale={3} origin={4} hit={5} miss={6} deletes={7}/{8} tail_wait={9}ms elapsed={10}ms" -f `
        $tier, $readCount, $writeCount, $stale, $originReads, $hits, $misses, $evictOk, $evictSecond, $tail['waited_ms'], $elapsed)
}

# ---- TSV writers with REAL tabs ----
$tab = [char]9
function Write-Tsv([string]$path, [string[]]$header, $rows) {
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add(($header -join $tab))
    foreach ($r in $rows) {
        $vals = @()
        foreach ($h in $header) { $vals += [string]$r[$h] }
        $null = $lines.Add(($vals -join $tab))
    }
    Write-RunFileText -State $script:run -Path $path -Text (($lines -join "`r`n") + "`r`n")
}
Write-Tsv (Join-Path $OutDir 'reads.tsv') @('tier', 'cycle', 'read_in_cycle', 'seq', 'request_id', 'start_ms', 'end_ms', 'http', 'code', 'views', 'likes', 'comment', 'collection', 'id_string_ok', 'body_sha256', 'error') $readRows
Write-Tsv (Join-Path $OutDir 'writes.tsv') @('tier', 'cycle', 'after_read', 'seq', 'request_id', 'start_ms', 'end_ms', 'http', 'ok', 'body') $writeRows
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'warmup.json') -Text (([ordered]@{ variant = $Variant; run_id = $RunId; records = $warmupResults }) | ConvertTo-Json -Depth 5)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'tail.json') -Text (([ordered]@{ variant = $Variant; run_id = $RunId; quiet_ms = $TailQuietMs; timeout_ms = $TailTimeoutMs; tiers = $tailResults }) | ConvertTo-Json -Depth 5)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'tiers.tsv') -Text (
    (@('tier' + $tab + 'reads' + $tab + 'writes_committed' + $tab + 'writes_per_second' + $tab + 'stale_reads' + $tab + 'origin_reads' + $tab + 'origin_per_100_reads' + $tab + 'hits' + $tab + 'misses' + $tab + 'deletes_total' + $tab + 'deletes_second' + $tab + 'delete_failures' + $tab + 'elapsed_ms') +
     @($tierResults | ForEach-Object { (@($_.tier_writes_per_10_reads, $_.reads, $_.writes_committed, $_.writes_per_second_actual, $_.stale_reads, $_.origin_reads, $_.origin_reads_per_100_detail_reads, $_.cache_hits, $_.cache_misses, $_.deletes_immediate_and_second, $_.deletes_second_phase, $_.delete_failures, $_.elapsed_ms) -join $tab) })) -join "`r`n")

$result = [ordered]@{
    run_id = $RunId
    variant = $Variant
    base = $Base
    article_id = $ArticleId
    redis_db = $RedisDb
    views_base = $viewsBase
    tiers = $tierResults
    records = [ordered]@{ reads = $readRows.Count; writes = $writeRows.Count; warmups = $warmupResults.Count }
    attribution = 'per-request event counts use requestId= of the probe line; deletes have no request context and are counted in the tier window'
    notes = 'one process, one article, one round: correctness and cost counters only, no throughput or capacity claim'
}

$t0 = $tierResults | Where-Object { $_.tier_writes_per_10_reads -eq 0 }
$t5 = $tierResults | Where-Object { $_.tier_writes_per_10_reads -eq 5 }
Add-Check 'c.tiers_recorded' ($tierResults.Count -eq $Tiers.Count) "tiers: $(@($tierResults | ForEach-Object { $_.tier_writes_per_10_reads }) -join ',') with $Cycles cycles x $ReadsPerCycle reads"
Add-Check 'c.raw_records_saved' (($readRows.Count -eq ($Cycles * $ReadsPerCycle * $Tiers.Count)) -and ($readRows.Count -eq $result.records.reads)) `
    "reads.tsv rows=$($readRows.Count) expected=$(($Cycles * $ReadsPerCycle) * $Tiers.Count) writes.tsv rows=$($writeRows.Count) warmups=$($warmupResults.Count) (warm-ups recorded separately)"
Add-Check 'c.warmup_excluded' ((@($tierResults | Where-Object { $_.warmup_excluded_from_stats -ne $true }).Count -eq 0) -and ((@($warmupResults | Where-Object { $_.excluded -ne $true }).Count) -eq 0)) `
    "every warm-up is marked excluded and no statistics row references a warm-up request id"
Add-Check 'c.no_read_or_write_failures' ((@($tierResults | Where-Object { $_.reads_failed -gt 0 }).Count -eq 0) -and (@($tierResults | Where-Object { $_.writes_failed -gt 0 }).Count -eq 0) -and (@($tierResults | Where-Object { $_.reads_with_bad_id_string -gt 0 }).Count -eq 0)) `
    "failed reads/writes and bad id strings per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.reads_failed)/$($_.writes_failed)/$($_.reads_with_bad_id_string)" }) -join ' ')"
Add-Check 'c.planned_write_counts_reached' (@($tierResults | Where-Object { $_.writes_committed -ne ($_.tier_writes_per_10_reads * $_.cycles) }).Count -eq 0) `
    "committed writes per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.writes_committed)" }) -join ' ') (expected tier*cycles)"
Add-Check 'c.second_delete_tail_confirmed' (@($tierResults | Where-Object { $_.deletes_second_phase -gt 0 -and $_.tail_waited_ms -lt 1 }).Count -eq 0) `
    "tail wait per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.tail_waited_ms)ms/$($_.tail_second_deletes)" }) -join ' ') (waited until the scheduled second deletes went quiet)"
if ($Variant -eq 'POST') {
    Add-Check 'c.postfix_newest_counter_visible' (@($tierResults | Where-Object { $_.stale_reads -gt 0 }).Count -eq 0) `
        "stale reads per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.stale_reads)" }) -join ' ')"
    Add-Check 'c.postfix_deletes_match_writes' ((@($tierResults | Where-Object { ($_.tier_writes_per_10_reads -gt 0) -and ($_.deletes_immediate_and_second -lt $_.writes_committed) }).Count -eq 0) -and (@($tierResults | Where-Object { $_.delete_failures -gt 0 }).Count -eq 0)) `
        "deletes/failures per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.deletes_immediate_and_second)/$($_.delete_failures)" }) -join ' ')"
} else {
    Add-Check 'c.prefix_no_invalidation' (@($tierResults | Where-Object { $_.deletes_immediate_and_second -gt 0 }).Count -eq 0) `
        "deletes per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.deletes_immediate_and_second)" }) -join ' ') (TTL only)"
}
if ($Variant -eq 'POST') {
    Add-Check 'c.cost_counters_present' ($null -ne $t5 -and $t5.origin_reads -ge 1) `
        "tier 5: origin_reads=$($t5.origin_reads) per 100 reads=$($t5.origin_reads_per_100_detail_reads) hits=$($t5.cache_hits) misses=$($t5.cache_misses)"
} else {
    # TTL only: nothing invalidates, so the cache stays warm and the formal reads cost no origin read
    Add-Check 'c.prefix_cost_is_zero' ($null -ne $t5 -and $t5.origin_reads -eq 0) `
        "tier 5: origin_reads=$($t5.origin_reads) deletes=$($t5.deletes_immediate_and_second) (no invalidation cost, the cached value stays stale)"
}

$result['checks'] = $script:run.checks
$result['counts'] = (Get-RunCheckCounts $script:run)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'scenario-result.json') -Text ($result | ConvertTo-Json -Depth 8)

$client.Dispose()
$counts = Get-RunCheckCounts $script:run
$script:run.checks | ForEach-Object { "{0,-40} {1,-6} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
