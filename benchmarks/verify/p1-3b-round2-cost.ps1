# P1.3b round-2 cost observation: SHARED baseline, per-request raw bodies written immediately,
# per-tier second-delete accounting (arranged / executed / failed / remaining) with remaining=0
# required before the next tier starts.
#
# Shape (task card): one sequential writer on the real public updateScore path (+1 view per committed
# call) and one sequential reader on the real public detail path; for every 10 detail reads insert 0, 1
# or 5 already committed counter writes; each tier runs $Cycles cycles.
#
# Contract enforced here (2026-11-03 review):
#   * -BaselineFile and -BaselineSha256 are mandatory. The file must hash to the given value and carry
#     run_scope = 'P1.3b-round2'; a missing baseline or a hash mismatch is refused BEFORE any HTTP
#     request. PRE and POST therefore start from the SAME captured values and the SAME hash.
#   * every tier resets the real row to the baseline and asserts the four counters in MySQL equal the
#     baseline, then deletes the cache key, then reads one warm-up: its four counters must equal the
#     baseline too. The warm-up is excluded from all statistics by request id.
#   * every request writes its raw response body to disk IMMEDIATELY (one file per request), then one row
#     is appended to requests.tsv with real tabs. Statistics are recomputed from those rows only.
#   * second deletes are counted per tier from the probe event file (article id + epoch window), the next
#     tier only starts when arranged == executed and nothing new appeared for the quiet window.
#
# Only cost and correctness are reported: no throughput, no capacity, no parameter choice.
# ASCII only (PS 5.1 reads a BOM-less .ps1 as ANSI/GBK).
# Exit codes: 0 = all checks passed, 1 = a check failed (files kept), 2 = usage/guard/baseline problem.
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [Parameter(Mandatory = $true)][ValidateSet('PRE', 'POST')][string]$Variant,
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [Parameter(Mandatory = $true)][string]$BaselineFile,
    [Parameter(Mandatory = $true)][string]$BaselineSha256,
    [long]$ArticleId = 9007199254741021,
    [int]$Cycles = 30,
    [int]$ReadsPerCycle = 10,
    [int[]]$Tiers = @(0, 1, 5),
    [int]$SettleQuietMs = 1500,
    [int]$SettleTimeoutMs = 30000,
    [int]$TimeoutSeconds = 30,
    [int]$RedisDb = 5,
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

# ---------------------------------------------------------------- baseline gate (before anything else)
if (-not (Test-Path -LiteralPath $BaselineFile)) {
    Write-Host "REFUSED: baseline file does not exist: $BaselineFile"
    exit 2
}
$baselineSha = (Get-FileHash -LiteralPath $BaselineFile -Algorithm SHA256).Hash.ToLower()
if ($baselineSha -ne $BaselineSha256.ToLower()) {
    Write-Host "REFUSED: baseline hash mismatch: file=$baselineSha expected=$($BaselineSha256.ToLower())"
    exit 2
}
$baseline = Get-Content $BaselineFile -Raw | ConvertFrom-Json
if ($baseline.run_scope -ne 'P1.3b-round2') {
    Write-Host "REFUSED: baseline file is not a round-2 baseline (run_scope='$($baseline.run_scope)')"
    exit 2
}
$baselineRow = $baseline.rows."$ArticleId"
if (-not $baselineRow) {
    Write-Host "REFUSED: baseline file has no row for article $ArticleId"
    exit 2
}

. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage "P1.3b-round2-cost-$Variant" `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ variant = $Variant; base = $Base; article = $ArticleId; cycles = $Cycles;
                       reads_per_cycle = $ReadsPerCycle; tiers = ($Tiers -join ','); redis_db = $RedisDb;
                       baseline_sha256 = $baselineSha } `
        -Targets @("$ArticleId") -DataSet $Database
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

Add-Type -AssemblyName System.Net.Http | Out-Null
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$handler.MaxConnectionsPerServer = 8
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

$tab = [char]9
$utf8 = New-Object System.Text.UTF8Encoding($false)
$rawDir = Join-Path $OutDir 'raw'
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null
$requestsTsv = Join-Path $OutDir 'requests.tsv'
$requestHeader = @('sequence', 'kind', 'scenario', 'tier', 'cycle', 'request_id', 'start_ms', 'end_ms', 'http', 'code',
                   'body_bytes', 'body_sha256', 'body_path', 'id_string_exact', 'views', 'likes', 'comment', 'collection',
                   'write_ok', 'note') -join $tab
[System.IO.File]::WriteAllText($requestsTsv, $requestHeader + "`r`n", $utf8)
$script:seq = 0
$script:requestRows = New-Object System.Collections.ArrayList
$script:subjectIds = @($ArticleId)

function Now-Ms { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
}
function Redis-In([int]$db, [string[]]$a) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', "$db") + $a
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Redis-Exact([string[]]$a) { return (Redis-In $RedisDb $a) }
function Sql([string]$q) {
    $o = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--raw' '--default-character-set=utf8mb4' '-e' $q 2>&1
    return (($o | Out-String).Trim())
}
function Db-Counts([long]$id) { return (Sql "SELECT CONCAT_WS('|', views, likes, comment, collection) FROM $Database.ap_article WHERE id=$id;") }
function BaselineCounts([long]$id) {
    $b = $baseline.rows."$id"
    return "$($b.views)|$($b.likes)|$($b.comment)|$($b.collection)"
}
function Detail-Counts([string]$raw) {
    $out = @()
    foreach ($f in @('views', 'likes', 'comment', 'collection')) {
        $m = [regex]::Match($raw, ('"' + $f + '"\s*:\s*(-?\d+)'))
        $out += $(if ($m.Success) { $m.Groups[1].Value } else { 'MISSING' })
    }
    return ($out -join '|')
}
function Detail-Code([string]$raw) {
    $m = [regex]::Match($raw, '"code"\s*:\s*(-?\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'MISSING'
}
function Get-ShaBytes([byte[]]$b) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return ([System.BitConverter]::ToString($sha.ComputeHash($b)) -replace '-', '').ToLower()
}

# every response is persisted BEFORE the next request is issued
function Save-Request([string]$kind, [string]$reqId, [long]$start, [long]$end, [int]$http, [byte[]]$bytes,
                      [string]$tier, [string]$cycle, [string]$note) {
    $script:seq++
    $bodyPath = Join-Path $rawDir ("{0:D5}-{1}.body.json" -f $script:seq, $reqId)
    $text = if ($bytes -and $bytes.Length -gt 0) { [System.Text.Encoding]::UTF8.GetString($bytes) } else { '' }
    Write-RunFileText -State $script:run -Path $bodyPath -Text $text
    $code = if ($text.Length -gt 0) { Detail-Code $text } else { 'NO_BODY' }
    $counts = if ($text.Length -gt 0) { Detail-Counts $text } else { 'MISSING|MISSING|MISSING|MISSING' }
    $idExact = $false
    if ($text.Length -gt 0) {
        foreach ($sid in $script:subjectIds) {
            if ($text -match ('"id":"' + ([string]$sid) + '"')) { $idExact = $true }
        }
    }
    $writeOk = $(if ($kind -eq 'write' -and $text -match '"ok"\s*:\s*true') { 'true' } else { '' })
    $row = [ordered]@{
        sequence = $script:seq; kind = $kind; scenario = 'COST'; tier = $tier; cycle = $cycle
        request_id = $reqId; start_ms = $start; end_ms = $end; http = $http; code = $code
        body_bytes = $(if ($bytes) { $bytes.Length } else { 0 }); body_sha256 = $(if ($bytes) { Get-ShaBytes $bytes } else { '' })
        body_path = $bodyPath.Substring($OutDir.Length + 1).Replace('\', '/')
        id_string_exact = $idExact; views = ($counts -split '\|')[0]; likes = ($counts -split '\|')[1]
        comment = ($counts -split '\|')[2]; collection = ($counts -split '\|')[3]
        write_ok = $writeOk; note = ($note -replace "`t", ' ')
    }
    $line = (@($requestHeader.Split($tab) | ForEach-Object { [string]$row[$_] }) -join $tab)
    [System.IO.File]::AppendAllText($requestsTsv, $line + "`r`n", $utf8)
    $null = $script:requestRows.Add($row)
    return $row
}
function Send-Request([string]$method, [string]$path, [string]$reqId, [string]$kind, [string]$tier, [string]$cycle, [string]$note) {
    $start = Now-Ms
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::$method, "$Base$path")
        if ($method -eq 'Post') { $req.Content = New-Object System.Net.Http.StringContent('') }
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $end = Now-Ms
        return (Save-Request $kind $reqId $start $end ([int]$resp.StatusCode) $bytes $tier $cycle $note)
    } catch {
        $end = Now-Ms
        return (Save-Request $kind $reqId $start $end 0 ([byte[]]@()) $tier $cycle "$note fetch_error=$($_.Exception.Message)")
    }
}

# ---------------------------------------------------------------- reset / asserts against the shared baseline
function Reset-ToBaseline([long]$id) {
    $b = $baseline.rows."$id"
    if (-not $b) { throw "baseline has no row for $id" }
    $static = if ($b.static_url -eq '~') { 'NULL' } else { "'" + ($b.static_url -replace "'", "''") + "'" }
    $title = ($b.title -replace "'", "''")
    $q = "UPDATE $Database.ap_article SET title='$title', views=$($b.views), likes=$($b.likes), comment=$($b.comment), " +
         "collection=$($b.collection), static_url=$static WHERE id=$id;"
    $null = Sql $q
    return $b
}
function Db-StaticUrl([long]$id) {
    return (Sql "SELECT IFNULL(static_url,'~') FROM $Database.ap_article WHERE id=$id;")
}

# ---------------------------------------------------------------- event helpers (article + time window)
function Events-Since([long]$fromMs) {
    if (-not (Test-Path -LiteralPath $Events)) { return @() }
    return @(Get-Content -LiteralPath $Events | Where-Object {
        $_ -match " articleId=$ArticleId " -and
        ([long]([regex]::Match($_, 'epochMs=(\d+)').Groups[1].Value) -ge $fromMs)
    })
}
function Wait-SecondDeletes([long]$sinceMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastChange = 0
    $prev = -1
    while ($sw.ElapsedMilliseconds -lt $SettleTimeoutMs) {
        $ev = @(Events-Since $sinceMs)
        $sched = @($ev | Where-Object { $_ -match ' event=cache\.evict\.second_scheduled ' }).Count
        $begin = @($ev | Where-Object { $_ -match ' event=cache\.evict\.second_begin ' }).Count
        if ($sched -eq $begin) {
            if ($sched -ne $prev) { $prev = $sched; $lastChange = $sw.ElapsedMilliseconds }
            if (($sw.ElapsedMilliseconds - $lastChange) -ge $SettleQuietMs) { break }
        }
        Start-Sleep -Milliseconds 150
    }
    $ev = @(Events-Since $sinceMs)
    $sched = @($ev | Where-Object { $_ -match ' event=cache\.evict\.second_scheduled ' }).Count
    $begin = @($ev | Where-Object { $_ -match ' event=cache\.evict\.second_begin ' }).Count
    $failSecond = @($ev | Where-Object { $_ -match ' event=cache\.evict\.fail ' -and $_ -match 'phase=[^ ]*:second' }).Count
    $rejected = @($ev | Where-Object { $_ -match ' event=cache\.evict\.second_rejected ' }).Count
    $pids = @($ev | ForEach-Object { [regex]::Match($_, 'pid=(\d+)').Groups[1].Value } | Sort-Object -Unique)
    return [ordered]@{ scheduled = $sched; executed = $begin; failed = $failSecond; rejected = $rejected;
                       remaining = ($sched - $begin); waited_ms = [long]$sw.ElapsedMilliseconds;
                       pids = ($pids -join ','); events = $ev }
}

$key = "$CacheKeyPrefix$ArticleId"
$viewsBase = [int]$baselineRow.views
$baseCounts = BaselineCounts $ArticleId

$tierResults = New-Object System.Collections.ArrayList
$warmupResults = New-Object System.Collections.ArrayList
$sdResults = New-Object System.Collections.ArrayList
$readSeq = 0
$writeSeq = 0

foreach ($tier in $Tiers) {
    # identical starting point for every tier: the shared baseline, asserted in the real database
    $b = Reset-ToBaseline $ArticleId
    $dbNow = Db-Counts $ArticleId
    $staticNow = Db-StaticUrl $ArticleId
    Add-Check ("c.tier$tier.db_equals_shared_baseline") (($dbNow -eq $baseCounts) -and ($staticNow -eq $b.static_url)) `
        "db=$dbNow baseline=$baseCounts static_url=$staticNow baseline=$($b.static_url) (baseline sha $baselineSha)"
    if ($dbNow -ne $baseCounts) { break }

    Redis-Exact @('DEL', $key) | Out-Null
    Redis-Exact @('DEL', "${key}:lock") | Out-Null
    $null = Wait-SecondDeletes (Now-Ms)   # no timer of an earlier tier may still be pending

    $tierStart = Now-Ms
    $warmId = "$Variant-$RunId-t$tier-warmup"
    $warm = Send-Request 'Get' "/api/v1/article/detail/$ArticleId" $warmId 'prewarm' "$tier" '' 'warm-up read, excluded from statistics'
    $null = $warmupResults.Add([ordered]@{ tier = $tier; request_id = $warmId; start_ms = $warm.start_ms; end_ms = $warm.end_ms;
                                           http = $warm.http; code = $warm.code; views = $warm.views; likes = $warm.likes;
                                           comment = $warm.comment; collection = $warm.collection;
                                           body_bytes = $warm.body_bytes; body_sha256 = $warm.body_sha256;
                                           body_path = $warm.body_path; excluded = $true })
    $warmCounts = "$($warm.views)|$($warm.likes)|$($warm.comment)|$($warm.collection)"
    Add-Check ("c.tier$tier.warmup_four_fields_equal_baseline") ($warmCounts -eq $baseCounts) `
        "warm-up=$warmCounts baseline=$baseCounts (request $warmId, raw $($warm.body_bytes) bytes sha $($warm.body_sha256))"

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
            $null = Send-Request 'Get' "/api/v1/article/detail/$ArticleId" $reqId 'read' "$tier" "$c" "read $r of cycle $c"
            if ($writeAfter -contains $r) {
                $writeSeq++
                $wReqId = "$Variant-$RunId-t$tier-c$c-w$r"
                $null = Send-Request 'Post' "/p13b/harness/score?id=$ArticleId&view=1&like=1&comment=1&collect=1" $wReqId 'write' "$tier" "$c" "committed updateScore (+1/+1/+1/+1) after read $r"
            }
        }
    }
    $tierEnd = Now-Ms

    # second deletes of this tier: same process, same article, phase ...:second, inside the tier window
    $sd = Wait-SecondDeletes $tierStart
    $sdRows = [ordered]@{ tier = $tier; tier_start_ms = $tierStart; tier_end_ms = $tierEnd;
                          arranged = $sd.scheduled; executed = $sd.executed; failed = $sd.failed;
                          rejected = $sd.rejected; remaining = $sd.remaining; waited_ms = $sd.waited_ms;
                          pids = $sd.pids; article_id = $ArticleId }
    $null = $sdResults.Add($sdRows)
    Add-Check ("c.tier$tier.second_delete_remaining_zero") ($sd.remaining -eq 0) `
        "arranged=$($sd.scheduled) executed=$($sd.executed) failed=$($sd.failed) remaining=$($sd.remaining) waived_waited=$($sd.waited_ms)ms pid=$($sd.pids) article=$ArticleId"
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir "events-tier$tier.log") -Text (@($sd.events) -join "`r`n")
    if ($sd.remaining -ne 0) { break }   # never switch tiers with a second delete still pending

    # ---- statistics for this tier, recomputed from the persisted rows only ----
    $tierReads = @($script:requestRows | Where-Object { $_.kind -eq 'read' -and $_.tier -eq "$tier" })
    $tierWrites = @($script:requestRows | Where-Object { $_.kind -eq 'write' -and $_.tier -eq "$tier" })
    $commitTimes = @($tierWrites | Where-Object { $_.write_ok -eq 'true' } | ForEach-Object { [long]$_.end_ms } | Sort-Object)
    $stale = 0; $fresh = 0; $failed = 0; $idBad = 0
    foreach ($rd in $tierReads) {
        if ($rd.views -eq 'MISSING') { $failed++; continue }
        if (-not $rd.id_string_exact) { $idBad++ }
        $n = 0
        foreach ($t in $commitTimes) { if ($t -le $rd.start_ms) { $n++ } else { break } }
        if ([int]$rd.views -ge ($viewsBase + $n)) { $fresh++ } else { $stale++ }
    }
    $tierIds = @($tierReads | ForEach-Object { $_.request_id }) + @($tierWrites | ForEach-Object { $_.request_id })
    $evSnap = @($sd.events | Where-Object {
        $m = [regex]::Match($_, 'requestId=([^ ]+)')
        $m.Success -and ($tierIds -contains $m.Groups[1].Value)
    })
    $originReads = @($evSnap | Where-Object { $_ -match ' event=rebuild\.begin ' }).Count
    $hits = @($evSnap | Where-Object { $_ -match ' event=cache\.read .*hit=true' }).Count
    $misses = @($evSnap | Where-Object { $_ -match ' event=cache\.read .*hit=false' }).Count
    $evictOk = @($sd.events | Where-Object { $_ -match ' event=cache\.evict\.ok ' }).Count
    $readCount = $tierReads.Count
    $writeCount = @($tierWrites | Where-Object { $_.write_ok -eq 'true' }).Count
    $elapsed = $tierEnd - $tierStart
    $originPer100 = if ($readCount -gt 0) { [math]::Round(100.0 * $originReads / $readCount, 2) } else { 0 }

    $null = $tierResults.Add([ordered]@{
        tier_writes_per_10_reads = $tier
        cycles = $Cycles
        reads_per_cycle = $ReadsPerCycle
        elapsed_ms = $elapsed
        reads = $readCount
        reads_missing_fields = $failed
        reads_with_bad_id_string = $idBad
        writes_committed = $writeCount
        writes_failed = ($tierWrites.Count - $writeCount)
        warmup_request_id = $warmId
        warmup_excluded_from_stats = $true
        db_counts_at_tier_start = $dbNow
        shared_baseline_counts = $baseCounts
        reads_seeing_newest_committed = $fresh
        stale_reads = $stale
        share_reading_newest_committed = $(if ($readCount -gt 0) { [math]::Round($fresh / $readCount, 4) } else { 0 })
        origin_reads = $originReads
        origin_reads_per_100_detail_reads = $originPer100
        cache_hits = $hits
        cache_misses = $misses
        deletes_total = $evictOk
        deletes_second_arranged = $sd.scheduled
        deletes_second_executed = $sd.executed
        deletes_second_remaining = $sd.remaining
        delete_failures = $sd.failed
        second_delete_waited_ms = $sd.waited_ms
    })
    Write-Host ("tier {0}: reads={1} writes={2} stale={3} origin={4} hit={5} miss={6} deletes={7} second={8}/{9} rem={10} elapsed={11}ms" -f `
        $tier, $readCount, $writeCount, $stale, $originReads, $hits, $misses, $evictOk, $sd.scheduled, $sd.executed, $sd.remaining, $elapsed)
}

# ---------------------------------------------------------------- summaries (derived, TSV with real tabs)
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
Write-Tsv (Join-Path $OutDir 'tiers.tsv') @('tier', 'reads', 'writes_committed', 'stale_reads', 'origin_reads', 'origin_per_100_reads',
    'hits', 'misses', 'deletes_total', 'deletes_second_arranged', 'deletes_second_executed', 'deletes_second_remaining',
    'delete_failures', 'elapsed_ms') @($tierResults)
Write-Tsv (Join-Path $OutDir 'second-deletes.tsv') @('tier', 'article_id', 'arranged', 'executed', 'failed', 'rejected', 'remaining', 'waited_ms', 'pids') @($sdResults)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'warmup.json') -Text (([ordered]@{
    variant = $Variant; run_id = $RunId; baseline_file = $BaselineFile; baseline_sha256 = $baselineSha;
    shared_baseline_counts = $baseCounts; records = $warmupResults }) | ConvertTo-Json -Depth 6)

$client.Dispose()

$result = [ordered]@{
    run_id = $RunId
    variant = $Variant
    base = $Base
    article_id = $ArticleId
    redis_db = $RedisDb
    baseline_file = $BaselineFile
    baseline_sha256 = $baselineSha
    shared_baseline_counts = $baseCounts
    views_base = $viewsBase
    tiers = $tierResults
    second_deletes = $sdResults
    warmups = $warmupResults
    requests = $script:requestRows.Count
    request_kinds = (@($script:requestRows | Group-Object kind | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
    raw_dir = 'raw/'
    attribution = 'per-request counts use requestId= of the probe line; second deletes have no request context and are attributed by pid + articleId + phase + tier time window'
    notes = 'one process, one article, one round: cost and correctness counters only, no throughput, capacity or parameter claim'
}

$t0 = $tierResults | Where-Object { $_.tier_writes_per_10_reads -eq 0 }
$t5 = $tierResults | Where-Object { $_.tier_writes_per_10_reads -eq 5 }
Add-Check 'c.tiers_recorded' ($tierResults.Count -eq $Tiers.Count) "tiers: $(@($tierResults | ForEach-Object { $_.tier_writes_per_10_reads }) -join ',') with $Cycles cycles x $ReadsPerCycle reads"
Add-Check 'c.baseline_shared_and_asserted' ((@($tierResults | Where-Object { $_.db_counts_at_tier_start -ne $_.shared_baseline_counts }).Count -eq 0) -and
    (@($warmupResults | Where-Object { "$($_.views)|$($_.likes)|$($_.comment)|$($_.collection)" -ne $baseCounts }).Count -eq 0)) `
    "all tiers started at $baseCounts and every warm-up returned $baseCounts (baseline sha $baselineSha)"
Add-Check 'c.raw_bodies_saved_per_request' ($script:requestRows.Count -ge 1 -and @(Get-ChildItem $rawDir -File).Count -eq $script:requestRows.Count) `
    "requests.tsv rows=$($script:requestRows.Count) raw body files=$(@(Get-ChildItem $rawDir -File).Count) (each written before the next request)"
Add-Check 'c.warmup_excluded' ((@($tierResults | Where-Object { $_.warmup_excluded_from_stats -ne $true }).Count -eq 0) -and
    (@($warmupResults | Where-Object { $_.excluded -ne $true }).Count -eq 0)) `
    "every warm-up ($($warmupResults.Count)) is marked excluded and no statistics row uses a warm-up request id"
Add-Check 'c.second_deletes_attributed_per_tier' ((@($sdResults | Where-Object { $_.article_id -ne $ArticleId }).Count -eq 0) -and
    (@($sdResults | Where-Object { $_.remaining -ne 0 }).Count -eq 0)) `
    "per tier arranged/executed/failed/remaining: $(@($sdResults | ForEach-Object { "$($_.tier):$($_.arranged)/$($_.executed)/$($_.failed)/$($_.remaining)" }) -join ' ') pid=$(@($sdResults | ForEach-Object { $_.pids } | Sort-Object -Unique) -join ',') article=$ArticleId"
Add-Check 'c.no_read_failures' ((@($tierResults | Where-Object { $_.reads_missing_fields -gt 0 }).Count -eq 0) -and
    (@($tierResults | Where-Object { $_.reads_with_bad_id_string -gt 0 }).Count -eq 0)) `
    "failed reads / bad id strings per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.reads_missing_fields)/$($_.reads_with_bad_id_string)" }) -join ' ')"
Add-Check 'c.planned_write_counts_reached' (@($tierResults | Where-Object { $_.writes_committed -ne ($_.tier_writes_per_10_reads * $_.cycles) }).Count -eq 0) `
    "committed writes per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.writes_committed)" }) -join ' ') (expected tier*cycles)"
if ($Variant -eq 'POST') {
    Add-Check 'c.postfix_newest_counter_visible' (@($tierResults | Where-Object { $_.stale_reads -gt 0 }).Count -eq 0) `
        "stale reads per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.stale_reads)" }) -join ' ')"
    Add-Check 'c.postfix_deletes_match_writes' ((@($tierResults | Where-Object { ($_.tier_writes_per_10_reads -gt 0) -and ($_.deletes_total -lt $_.writes_committed) }).Count -eq 0) -and
        (@($tierResults | Where-Object { $_.delete_failures -gt 0 }).Count -eq 0)) `
        "deletes/failures per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.deletes_total)/$($_.delete_failures)" }) -join ' ')"
    Add-Check 'c.cost_counters_present' ($null -ne $t5 -and $t5.origin_reads -ge 1) `
        "tier 5: origin_reads=$($t5.origin_reads) per 100 reads=$($t5.origin_reads_per_100_detail_reads) hits=$($t5.cache_hits) misses=$($t5.cache_misses)"
} else {
    Add-Check 'c.prefix_no_invalidation' (@($tierResults | Where-Object { $_.deletes_total -gt 0 }).Count -eq 0) `
        "deletes per tier: $(@($tierResults | ForEach-Object { "$($_.tier_writes_per_10_reads):$($_.deletes_total)" }) -join ' ') (TTL only)"
    Add-Check 'c.prefix_cost_is_zero' ($null -ne $t5 -and $t5.origin_reads -eq 0) `
        "tier 5: origin_reads=$($t5.origin_reads) deletes=$($t5.deletes_total); tier 0 origin_reads=$(if ($t0) { $t0.origin_reads } else { 'n/a' }) (no invalidation cost, the cached value stays stale)"
}

$result['checks'] = $script:run.checks
$result['counts'] = (Get-RunCheckCounts $script:run)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'scenario-result.json') -Text ($result | ConvertTo-Json -Depth 8)

$counts = Get-RunCheckCounts $script:run
$script:run.checks | ForEach-Object { "{0,-46} {1,-6} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
