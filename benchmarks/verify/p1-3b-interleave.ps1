# P1.3b read/write interleaving cost observation: one real writer against the public update path,
# several real readers against the public detail path, same fixture, run once per variant.
#
# ASCII only (PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
#
# What is measured (no throughput claim is made anywhere):
#   * correctness: a read is stale when it returns a counter older than the writes that had already
#     committed before the read started. The writer is the real updateScore path (+1 view per call),
#     so the committed version is known exactly without reading the DB inside the loop.
#   * stale window: for each stale read, the time between the commit of the first write it missed and
#     the moment its response was received.
#   * origin reads (rebuild.begin) and cache deletes (cache.evict.ok / cache.evict.fail) counted from
#     the probe event file for this article id inside this run's time window.
#   * DB connection occupancy: MySQL client connections on the experiment schema, sampled on a fixed
#     interval while the readers and the writer are running.
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [Parameter(Mandatory = $true)][ValidateSet('PRE', 'POST')][string]$Variant,
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [long]$ArticleId = 9007199254741021,
    [int]$Readers = 4,
    [int]$DurationSeconds = 30,
    [int]$WriterIntervalMs = 1000,
    [int]$SampleIntervalMs = 250,
    [string]$BaselineFile = '',
    [int]$TimeoutSeconds = 30,
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
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage "P1.3b-interleave-$Variant" `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ variant = $Variant; base = $Base; article = $ArticleId; readers = $Readers;
                       duration_seconds = $DurationSeconds; writer_interval_ms = $WriterIntervalMs } `
        -Targets @("$ArticleId") -DataSet $Database
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

Add-Type -AssemblyName System.Net.Http | Out-Null
function Now-Ms { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Redis-Exact([string[]]$a) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', '0') + $a
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Sql([string]$q) {
    $o = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '-e' $q 2>&1
    return (($o | Out-String).Trim())
}
function Sql-Scalar([string]$q) {
    $v = Sql $q
    if ($v -eq 'NULL') { return '' }
    return $v
}
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
}
function Http-Get([string]$path, [string]$reqId) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base$path")
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    return $client.SendAsync($req).GetAwaiter().GetResult()
}
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$handler.MaxConnectionsPerServer = 40
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

# ---------------------------------------------------------------- fixture
# Every variant starts from the exact same counters/title/cache state. The baseline is captured once
# and reused by the second variant, so PRE and POST are the same fixture.
$key = "$CacheKeyPrefix$ArticleId"
$baselineJson = ''
if ($BaselineFile -ne '' -and (Test-Path -LiteralPath $BaselineFile)) {
    $baselineJson = [System.IO.File]::ReadAllText($BaselineFile)
} else {
    $row = Sql "SELECT CONCAT_WS('|',title,views,likes,comment,collection,IFNULL(static_url,'')) FROM $Database.ap_article WHERE id=$ArticleId;"
    $p = $row -split '\|'
    $baselineJson = ([ordered]@{ article_id = $ArticleId; title = $p[0]; views = [int]$p[1]; likes = [int]$p[2];
                                 comment = [int]$p[3]; collection = [int]$p[4]; static_url = $p[5] } | ConvertTo-Json -Compress)
    if ($BaselineFile -ne '') { [System.IO.File]::WriteAllText($BaselineFile, $baselineJson) }
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'fixture-baseline.json') -Text $baselineJson
$fixture = $baselineJson | ConvertFrom-Json
$viewsBase = [int]$fixture.views

Sql "UPDATE $Database.ap_article SET title='P13b-iw', views=$($fixture.views), likes=$($fixture.likes), comment=$($fixture.comment), collection=$($fixture.collection), static_url=NULL WHERE id=$ArticleId;" | Out-Null
Redis-Exact @('DEL', $key) | Out-Null
Redis-Exact @('DEL', "$key:lock") | Out-Null
$warm = Http-Get "/api/v1/article/detail/$ArticleId" 'warm'
$warmBody = [System.Text.Encoding]::UTF8.GetString($warm.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'warm-detail.body.json') -Text $warmBody
Add-Check 'i.fixture_warmed' (((Redis-Exact @('EXISTS', $key)) -eq '1') -and ($warmBody -match '"views"\s*:\s*' + $viewsBase)) `
    "cache key exists=$(Redis-Exact @('EXISTS', $key)) viewsBase=$viewsBase"

# ---------------------------------------------------------------- concurrent load
$readerScript = {
    param($Base, $Url, $DurationMs, $TimeoutSeconds)
    Add-Type -AssemblyName System.Net.Http | Out-Null
    $h = New-Object System.Net.Http.HttpClientHandler
    $h.UseProxy = $false
    $h.MaxConnectionsPerServer = 40
    $c = New-Object System.Net.Http.HttpClient($h)
    $c.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $out = New-Object System.Collections.ArrayList
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $DurationMs) {
        $start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        try {
            $r = $c.GetAsync($Url).GetAwaiter().GetResult()
            $body = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $end = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $m = [regex]::Match($body, '"views"\s*:\s*(-?\d+)')
            $views = if ($m.Success) { $m.Groups[1].Value } else { '' }
            $null = $out.Add("$start|$end|$views|$([int]$r.StatusCode)")
        } catch {
            $end = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $null = $out.Add("$start|$end|ERR|0")
        }
    }
    $c.Dispose()
    return , $out
}
$writerScript = {
    param($Url, $DurationMs, $IntervalMs, $TimeoutSeconds)
    Add-Type -AssemblyName System.Net.Http | Out-Null
    $h = New-Object System.Net.Http.HttpClientHandler
    $h.UseProxy = $false
    $h.MaxConnectionsPerServer = 4
    $c = New-Object System.Net.Http.HttpClient($h)
    $c.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $out = New-Object System.Collections.ArrayList
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $k = 0
    while ($sw.ElapsedMilliseconds -lt $DurationMs) {
        $start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        try {
            $content = New-Object System.Net.Http.StringContent('')
            $r = $c.PostAsync($Url, $content).GetAwaiter().GetResult()
            $body = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            if (($body -match '"ok"\s*:\s*true')) { $k++ ; $null = $out.Add("$k|$ms|ok") }
            else { $null = $out.Add("0|$ms|bad:$($body -replace '\s+', ' ')") }
        } catch {
            $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $null = $out.Add("0|$ms|error")
        }
        $elapsed = $sw.ElapsedMilliseconds
        $wait = $IntervalMs - ($elapsed % $IntervalMs)
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
    $c.Dispose()
    return , $out
}

$detailUrl = "$Base/api/v1/article/detail/$ArticleId"
$writeUrl = "$Base/p13b/harness/score?id=$ArticleId&view=1&like=1&comment=1&collect=1"
$durationMs = $DurationSeconds * 1000

$readerRuns = @()
for ($i = 0; $i -lt $Readers; $i++) {
    $ps = [powershell]::Create()
    $null = $ps.AddScript([string]$readerScript)
    $null = $ps.AddParameter('Base', $Base)
    $null = $ps.AddParameter('Url', $detailUrl)
    $null = $ps.AddParameter('DurationMs', $durationMs)
    $null = $ps.AddParameter('TimeoutSeconds', $TimeoutSeconds)
    $readerRuns += [pscustomobject]@{ powershell = $ps; handle = $ps.BeginInvoke(); tag = "reader$i" }
}
$writerPs = [powershell]::Create()
$null = $writerPs.AddScript([string]$writerScript)
$null = $writerPs.AddParameter('Url', $writeUrl)
$null = $writerPs.AddParameter('DurationMs', $durationMs)
$null = $writerPs.AddParameter('IntervalMs', $WriterIntervalMs)
$null = $writerPs.AddParameter('TimeoutSeconds', $TimeoutSeconds)
$writerHandle = $writerPs.BeginInvoke()

# connection occupancy sampling runs on this thread while the runspaces work.
# Two series are kept because idle pooled connections of both instances sit on the same schema:
# "active" is what the run really occupies in MySQL (COMMAND != Sleep), "total" also counts the
# idle pool of the instance that is not under test. The sampling connection itself is subtracted.
$connActive = New-Object System.Collections.ArrayList
$connTotal = New-Object System.Collections.ArrayList
$qActive = "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB='$Database' AND COMMAND<>'Sleep';"
$qTotal = "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE DB='$Database';"
$sampleSw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sampleSw.ElapsedMilliseconds -lt $durationMs) {
    try {
        $n = Sql $qActive
        if ($n -match '^\d+$') { $null = $connActive.Add([math]::Max(0, [int]$n - 1)) }
        $n = Sql $qTotal
        if ($n -match '^\d+$') { $null = $connTotal.Add([math]::Max(0, [int]$n - 1)) }
    } catch { }
    Start-Sleep -Milliseconds $SampleIntervalMs
}

$reads = New-Object System.Collections.ArrayList
$readerErrors = New-Object System.Collections.ArrayList
foreach ($rr in $readerRuns) {
    try {
        $res = $rr.powershell.EndInvoke($rr.handle)
        foreach ($item in $res) { foreach ($line in $item) { $null = $reads.Add([string]$line) } }
        if ($rr.powershell.HadErrors) {
            foreach ($e in $rr.powershell.Streams.Error) { $null = $readerErrors.Add("$($rr.tag): $e") }
        }
    } catch { $null = $readerErrors.Add("$($rr.tag): end_invoke failed: $($_.Exception.Message)") }
    $rr.powershell.Dispose()
}
$commits = New-Object System.Collections.ArrayList
try {
    $wres = $writerPs.EndInvoke($writerHandle)
    foreach ($item in $wres) { foreach ($line in $item) { $null = $commits.Add([string]$line) } }
    if ($writerPs.HadErrors) {
        foreach ($e in $writerPs.Streams.Error) { $null = $readerErrors.Add("writer: $e") }
    }
} catch { $null = $readerErrors.Add("writer: end_invoke failed: $($_.Exception.Message)") }
$writerPs.Dispose()
$client.Dispose()

$writeOk = @($commits | Where-Object { ($_ -split '\|')[2] -eq 'ok' })
$writeBad = @($commits | Where-Object { ($_ -split '\|')[2] -ne 'ok' })
$commitTimes = @($writeOk | ForEach-Object { [long]($_ -split '\|')[1] } | Sort-Object)

# ---------------------------------------------------------------- correctness
$readRows = @($reads | Where-Object { $_ -match '^\d+\|\d+\|\d+\|\d+$' })
$readErr = @($reads | Where-Object { $_ -notmatch '^\d+\|\d+\|\d+\|\d+$' }) + @($readerErrors)
$stale = 0
$windows = New-Object System.Collections.ArrayList
$minViews = -1
$maxViews = -1
foreach ($line in $readRows) {
    $p = $line -split '\|'
    $start = [long]$p[0]
    $end = [long]$p[1]
    $views = [int]$p[2]
    if ($minViews -lt 0 -or $views -lt $minViews) { $minViews = $views }
    if ($views -gt $maxViews) { $maxViews = $views }
    # committed version visible at read start: count of commits at or before $start
    $c = 0
    foreach ($t in $commitTimes) { if ($t -le $start) { $c++ } else { break } }
    $expected = $viewsBase + $c
    if ($views -lt $expected) {
        $stale++
        $missed = $expected - $views        # how many committed writes this read did not see
        $idx = $c - $missed + 1             # commit ordinal of the first missed write
        if ($idx -lt 1) { $idx = 1 }
        $window = $end - $commitTimes[$idx - 1]
        if ($window -lt 0) { $window = $end - $start }
        $null = $windows.Add($window)
    }
}
$readCount = $readRows.Count
$staleRatio = if ($readCount -gt 0) { [math]::Round($stale / $readCount, 4) } else { 1 }
function Get-Median($list) {
    $a = @($list | Sort-Object)
    if ($a.Count -eq 0) { return 0 }
    if ($a.Count % 2 -eq 1) { return [long]$a[([int](($a.Count - 1) / 2))] }
    return [long](($a[$a.Count / 2 - 1] + $a[$a.Count / 2]) / 2)
}
$winArr = @($windows)
$winStats = [ordered]@{
    count = $winArr.Count
    min_ms = if ($winArr.Count -gt 0) { [long]($winArr | Measure-Object -Minimum).Minimum } else { 0 }
    median_ms = Get-Median $winArr
    max_ms = if ($winArr.Count -gt 0) { [long]($winArr | Measure-Object -Maximum).Maximum } else { 0 }
}

# ---------------------------------------------------------------- probe events
$runStartMs = [DateTimeOffset]::Parse($script:run.started_utc, $inv).ToUnixTimeMilliseconds()
$evLines = @()
if (Test-Path -LiteralPath $Events) { $evLines = @(Get-Content -LiteralPath $Events) }
$mine = @($evLines | Where-Object { $_ -match " articleId=$ArticleId " -and ($_ -match 'epochMs=(\d+)') -and ([long]([regex]::Match($_, 'epochMs=(\d+)').Groups[1].Value) -ge ($runStartMs - 2000)) })
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events-for-article.log') -Text (@($mine) -join "`r`n")
function Count-Ev([string]$pattern) { return @($mine | Where-Object { $_ -match $pattern }).Count }
$rebuilds = Count-Ev ' event=rebuild\.begin '
$cacheMiss = Count-Ev ' event=cache\.read .*hit=false'
$cacheWrite = Count-Ev ' event=cache\.write\.done '
$evictOk = Count-Ev ' event=cache\.evict\.ok '
$evictFail = Count-Ev ' event=cache\.evict\.fail '
$evictRegister = Count-Ev ' event=cache\.evict\.register '
$afterCommit = Count-Ev ' event=tx\.after_commit '
$lockFail = Count-Ev ' event=lock\.fail '
$budgetExhausted = Count-Ev ' event=wait\.end outcome=budget_exhausted '
$http5xx = @($readRows | Where-Object { ([int](($_ -split '\|')[3])) -ne 200 }).Count

# ---------------------------------------------------------------- connection occupancy
function Get-Series($list) {
    $a = @($list)
    return [ordered]@{
        samples = $a.Count
        min = if ($a.Count -gt 0) { [int]($a | Measure-Object -Minimum).Minimum } else { 0 }
        median = Get-Median $a
        max = if ($a.Count -gt 0) { [int]($a | Measure-Object -Maximum).Maximum } else { 0 }
    }
}
$activeArr = @($connActive)
$totalArr = @($connTotal)
$connStats = [ordered]@{ active = (Get-Series $activeArr); total_including_idle_pool = (Get-Series $totalArr) }

$result = [ordered]@{
    run_id = $RunId
    variant = $Variant
    base = $Base
    article_id = $ArticleId
    readers = $Readers
    duration_seconds = $DurationSeconds
    writer_interval_ms = $WriterIntervalMs
    views_base = $viewsBase
    writes_committed = $writeOk.Count
    writes_failed = $writeBad.Count
    reads = $readCount
    reads_failed = $readErr.Count
    reads_non_200 = $http5xx
    stale_reads = $stale
    stale_ratio = $staleRatio
    stale_window_ms = $winStats
    views_observed_min = $minViews
    views_observed_max = $maxViews
    events = [ordered]@{ rebuild_begin = $rebuilds; cache_read_miss = $cacheMiss; cache_write_done = $cacheWrite;
                         evict_register = $evictRegister;
                         evict_ok = $evictOk; evict_fail = $evictFail; tx_after_commit = $afterCommit;
                         lock_fail = $lockFail; wait_budget_exhausted = $budgetExhausted }
    db_connections = $connStats
    notes = 'no throughput or latency-improvement claim: this run reports correctness, staleness and cost counters only'
}

Add-Check 'i.no_read_errors' (($readErr.Count -eq 0) -and ($http5xx -eq 0)) "reads=$readCount failed=$($readErr.Count) non200=$http5xx first_error='$(if ($readErr.Count -gt 0) { $readErr[0] } else { '-' })'"
Add-Check 'i.writes_all_committed' (($writeOk.Count -ge 5) -and ($writeBad.Count -eq 0)) "committed=$($writeOk.Count) failed=$($writeBad.Count)"
Add-Check 'i.reads_observed' ($readCount -ge 20) "reads=$readCount over ${DurationSeconds}s with $Readers readers"
if ($Variant -eq 'POST') {
    Add-Check 'i.postfix_invalidation_executed' (($evictOk -ge ($writeOk.Count - 1)) -and ($evictFail -eq 0)) `
        "evict.ok=$evictOk for $($writeOk.Count) committed writes, evict.fail=$evictFail, register=$evictRegister, afterCommit=$afterCommit"
    Add-Check 'i.postfix_stale_ratio_low' ($staleRatio -le 0.05) `
        "stale=$stale/$readCount ratio=$staleRatio window_min/median/max=$($winStats.min_ms)/$($winStats.median_ms)/$($winStats.max_ms)ms"
} else {
    Add-Check 'i.prefix_no_invalidation' (($evictOk -eq 0) -and ($evictRegister -eq 0)) `
        "evict.ok=$evictOk register=$evictRegister (TTL only: nothing invalidates on write)"
    Add-Check 'i.prefix_stale_ratio_high' ($staleRatio -ge 0.5) `
        "stale=$stale/$readCount ratio=$staleRatio window_median=$($winStats.median_ms)ms"
}
Add-Check 'i.cost_counters_recorded' ($rebuilds -ge 1) "rebuild.begin=$rebuilds cache.read(miss)=$cacheMiss cache.write.done=$cacheWrite evict.ok=$evictOk evict.fail=$evictFail db_connections(active) min/median/max=$($connStats.active.min)/$($connStats.active.median)/$($connStats.active.max) total_min/median/max=$($connStats.total_including_idle_pool.min)/$($connStats.total_including_idle_pool.median)/$($connStats.total_including_idle_pool.max)"

$result['checks'] = $script:run.checks
$result['counts'] = (Get-RunCheckCounts $script:run)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'scenario-result.json') -Text ($result | ConvertTo-Json -Depth 6)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'reads.tsv') -Text (@('start_ms`tend_ms`tviews`tstatus') + $readRows -join "`r`n")
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'commits.tsv') -Text (@('k`tcommit_ms`tstatus') + @($commits) -join "`r`n")
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'db-connections.tsv') -Text (@('active_connections`ttotal_connections_including_idle_pool') + @(0..([math]::Max(0, $activeArr.Count - 1)) | ForEach-Object { "$($activeArr[$_])`t$($totalArr[$_])" }) -join "`r`n")

$counts = Get-RunCheckCounts $script:run
$script:run.checks | ForEach-Object { "{0,-40} {1,-8} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
