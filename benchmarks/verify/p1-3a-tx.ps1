# P1.3a transaction-boundary scenarios T1..T6 (ASCII only; PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
#
# One scenario per invocation, one guarded run directory per invocation, every artifact written once.
# The instance under test is the real article service started by start-p1-2-instance.ps1 with a variant
# directory (PRE = frozen pre-fix classes + harness, POST = fixed classes + harness) placed first on the
# classpath. Nothing in the source tree is moved.
#
# What is simulated, and only on this instance / these exact article ids:
#   * pre-commit barrier    tx.hold.before-commit.<id>   (keeps the write transaction open)
#   * refill delay          cache.write.delay.<id>       (pushes a reader's setEx after the commit)
#   * controlled rollback   tx.rollback.<id>             (writer throws after registering the invalidation)
#   * cache delete fault    fault.cache.evict.<id>       (once|always)
# MySQL and Redis are real; no shared service is stopped, flushed or reconfigured.
#
# Exit codes: 0 = every check passed, 1 = a check failed or an unexpected error (files kept),
#             2 = usage/guard problem (nothing was executed).
param(
    [Parameter(Mandatory = $true)][ValidateSet('T1', 'T2', 'T3', 'T4', 'T5', 'T6')][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [Parameter(Mandatory = $true)][string]$Variant,
    [string]$ExperimentRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261031-P1.3a',
    [long]$ArticleId = 9007199254741007,
    [long]$SecondArticleId = 9007199254741008,
    [long]$MissingId = 9007199254741002,
    [long]$BigId16 = 9007199254741000,
    [int]$HoldMs = 3000,
    [int]$WindowMs = 500,
    [int]$TimeoutSeconds = 60,
    [long]$HolderId = 9007199254741014,
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
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage "P1.3a-$Scenario" `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ scenario = $Scenario; base = $Base; variant = $Variant; article_id = $ArticleId;
                       second_article_id = $SecondArticleId; hold_ms = $HoldMs; window_ms = $WindowMs } `
        -Targets @("$ArticleId", "$SecondArticleId") -DataSet $Database
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

$runStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 1000
Add-Type -AssemblyName System.Net.Http | Out-Null
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.MaxConnectionsPerServer = 50
$handler.UseProxy = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
[System.Net.ServicePointManager]::DefaultConnectionLimit = 100

function Now-Utc { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $inv) }
function Add-Check([string]$name, [bool]$ok, [string]$detail) {
    Add-RunCheck -State $script:run -Name $name -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $detail
}
function Redis-Exact([string[]]$cmdArgs) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', '0') + $cmdArgs
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Sql-Scalar([string]$sql) {
    $out = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '-e' $sql 2>&1
    return (($out | Out-String).Trim())
}
function Get-TitleFromDb([long]$id) {
    return Sql-Scalar "SELECT title FROM $Database.ap_article WHERE id=$id;"
}
function New-Request([string]$path, [string]$requestId, [string]$runId) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base$path")
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $runId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $requestId)
    return $req
}
function New-PostRequest([string]$path, [string]$requestId, [string]$runId) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$Base$path")
    $req.Content = New-Object System.Net.Http.StringContent('')
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $runId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $requestId)
    return $req
}
function Save-Response([string]$name, $resp, [double]$elapsedMs) {
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    Write-RunFileBytes -State $script:run -Path (Join-Path $OutDir "$name.body.json") -Bytes $bytes
    $meta = [ordered]@{
        name        = $name
        at_utc      = (Now-Utc)
        http_status = [int]$resp.StatusCode
        bytes       = $bytes.Length
        elapsed_ms  = [math]::Round($elapsedMs, 3)
    }
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir "$name.meta.json") -Text ($meta | ConvertTo-Json -Depth 4)
    return [pscustomobject]$meta
}
function Read-BodyText([string]$name) {
    $p = Join-Path $OutDir "$name.body.json"
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    return [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($p))
}
function Get-Title([string]$raw) {
    $m = [regex]::Match($raw, '"title"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Get-Code([string]$raw) {
    $m = [regex]::Match($raw, '"code"\s*:\s*(-?\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'MISSING'
}
function Read-Events([string]$path, [string]$runId) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path | Where-Object { $_ -match " runId=$([regex]::Escape($runId)) " })
}
function Read-EventsForArticle([string]$path, [long]$id, [long]$sinceMs) {
    # the scheduled second delete runs on a scheduler thread: no request context, so runId=- and
    # requestId=-. Select those lines by article id and by "not older than this run" instead.
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path | Where-Object {
            $_ -match " articleId=$id " -and (Evt-Time $_) -ge $sinceMs })
}

function Evt-Time([string]$line) {
    $m = [regex]::Match($line, 'epochMs=(\d+)')
    if ($m.Success) { return [long]$m.Groups[1].Value }
    return 0
}
function Field([string]$line, [string]$name) {
    $m = [regex]::Match($line, "(?:^|\s)$name=([^\s]+)")
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Evt-First($lines, [string]$pattern) {
    foreach ($l in $lines) { if ($l -match $pattern) { return $l } }
    return ''
}
function Hikari-MaxDuring($task, [int]$limitMs) {
    # sample the harness stats while a request is in flight; the max active connection count is the
    # evidence for "is this request holding a pooled connection?"
    $max = 0
    $samples = 0
    $deadline = (Get-Date).AddMilliseconds($limitMs)
    while ((Get-Date) -lt $deadline -and -not $task.IsCompleted) {
        try {
            $r = $client.SendAsync((New-Request '/p13a/harness/stats' 'hikari-sample' $RunId)).GetAwaiter().GetResult()
            $json = [System.Text.Encoding]::UTF8.GetString($r.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
            $m = [regex]::Match($json, '"conn_active"\s*:\s*(-?\d+)')
            if ($m.Success) {
                $v = [int]$m.Groups[1].Value
                if ($v -gt $max) { $max = $v }
                $samples++
            }
        } catch { }
        Start-Sleep -Milliseconds 60
    }
    return [pscustomobject]@{ max_active = $max; samples = $samples }
}

$result = [ordered]@{ run_id = $RunId; scenario = $Scenario; variant = $Variant; base = $Base; started_utc = (Now-Utc) }

function Get-Stats {
    $r = $client.SendAsync((New-Request '/p13a/harness/stats' 'stats' $RunId)).GetAwaiter().GetResult()
    $json = [System.Text.Encoding]::UTF8.GetString($r.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
    return $json
}
function Set-DbTitle([long]$id, [string]$title, [string]$content) {
    # fixture setup only: puts the known V0 into the isolated test row. This is NOT the write under test;
    # the committed write is always the real saveArticle call through the Spring proxy.
    $sql = "UPDATE $Database.ap_article SET title='$title' WHERE id=$id; UPDATE $Database.ap_article_content SET content='$content' WHERE article_id=$id; SELECT title FROM $Database.ap_article WHERE id=$id;"
    return Sql-Scalar $sql
}
function Get-Detail([string]$name) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $client.SendAsync((New-Request "/api/v1/article/detail/$($script:detailId)" $name $RunId)).GetAwaiter().GetResult()
    $sw.Stop()
    return (Save-Response $name $resp $sw.Elapsed.TotalMilliseconds)
}

switch ($Scenario) {

# =====================================================================
'T1' {
    # Real failure: both deletes happen inside the transaction, the commit comes later, so the cache
    # keeps the pre-commit version after the commit.
    $script:detailId = $ArticleId
    $cacheKey = "$CacheKeyPrefix$ArticleId"
    $v0 = "V0-$RunId"
    $v1 = "V1-$RunId"

    $seed = Set-DbTitle $ArticleId $v0 'content-v0'
    Add-RunStep -State $script:run -Step ('seed V0 through saveArticle (seed: ' + $seed + ')')
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    $warm = Get-Detail 'warm-cache-v0'
    $warmTitle = Get-Title (Read-BodyText 'warm-cache-v0')
    Add-Check 't1.cache_warmed_with_v0' ($warmTitle -eq $v0) "warm title=$warmTitle db=$(Get-TitleFromDb $ArticleId)"

    # writer: real Spring transaction, held before COMMIT by the probe barrier
    $swW = [System.Diagnostics.Stopwatch]::StartNew()
    $taskW = $client.SendAsync((New-PostRequest "/p13a/harness/save?id=$ArticleId&title=$v1&content=content-v1" 'writer' $RunId))

    # wait until the writer is provably inside the transaction (barrier visible in the event stream)
    $evDeadline = (Get-Date).AddSeconds(20)
    $holdSeen = $false
    while ((Get-Date) -lt $evDeadline) {
        $ev = Read-Events $Events $RunId
        if ($ev | Where-Object { $_ -match ' event=tx\.hold\.begin ' }) { $holdSeen = $true; break }
        Start-Sleep -Milliseconds 50
    }
    Add-Check 't1.writer_is_held_before_commit' $holdSeen 'tx.hold.begin observed while the write transaction is still open'

    # wait past the 500 ms second delete of the PRE variant: only then is the reader's refill the last
    # write to the key before the commit, which is exactly the window the pre-fix code misses
    Start-Sleep -Milliseconds 700

    # reader: reads the visible old version while the writer has not committed yet
    $swR = [System.Diagnostics.Stopwatch]::StartNew()
    $taskR = $client.SendAsync((New-Request "/api/v1/article/detail/$ArticleId" 'reader-during-tx' $RunId))
    $respR = $taskR.GetAwaiter().GetResult(); $swR.Stop()
    $metaR = Save-Response 'reader-during-tx' $respR $swR.Elapsed.TotalMilliseconds
    $titleR = Get-Title (Read-BodyText 'reader-during-tx')
    $result['reader_title_during_tx'] = $titleR
    Add-Check 't1.reader_saw_old_version' ($titleR -eq $v0) "reader title during tx=$titleR (expected $v0)"

    $respW = $taskW.GetAwaiter().GetResult(); $swW.Stop()
    $metaW = Save-Response 'writer' $respW $swW.Elapsed.TotalMilliseconds
    $dbTitle = Get-TitleFromDb $ArticleId
    $result['db_title_after_commit'] = $dbTitle
    Add-Check 't1.db_committed_v1' ($dbTitle -eq $v1) "db title=$dbTitle (expected $v1)"

    # let the +500 ms second delete run, then read again: this is where the bug shows up
    Start-Sleep -Milliseconds ($WindowMs + 800)
    $after = Get-Detail 'after-commit'
    $titleAfter = Get-Title (Read-BodyText 'after-commit')
    $codeAfter = Get-Code (Read-BodyText 'after-commit')
    $keyExists = Redis-Exact @('EXISTS', $cacheKey)
    $result['title_after_commit'] = $titleAfter
    $result['cache_key_exists_after'] = $keyExists
    if ($Variant -eq 'PRE') {
        # pre-fix: the deleted key was refilled with the pre-commit value and nothing deletes it again
        Add-Check 't1.prefix_stale_response' ($titleAfter -eq $v0 -and $codeAfter -eq '200') "title=$titleAfter code=$codeAfter db=$dbTitle key_exists=$keyExists"
    } else {
        Add-Check 't1.postfix_fresh_response' ($titleAfter -eq $v1 -and $codeAfter -eq '200') "title=$titleAfter code=$codeAfter db=$dbTitle key_exists=$keyExists"
    }

    # ordering evidence: deletes vs commit
    $ev = @(Read-Events $Events $RunId)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $firstEvict = Evt-First $ev ' event=cache\.evict\.(ok|begin) '
    $afterCommit = Evt-First $ev ' event=tx\.after_commit '
    $holdEnd = Evt-First $ev ' event=tx\.hold\.end '
    $result['evict_first_ms'] = if ($firstEvict) { Evt-Time $firstEvict } else { 0 }
    $result['hold_end_ms'] = if ($holdEnd) { Evt-Time $holdEnd } else { 0 }
    $result['after_commit_ms'] = if ($afterCommit) { Evt-Time $afterCommit } else { 0 }
    if ($Variant -eq 'PRE') {
        Add-Check 't1.prefix_deletes_precede_commit' (($result['evict_first_ms'] -gt 0) -and ($result['evict_first_ms'] -lt $result['hold_end_ms'])) `
            "first evict at $($result['evict_first_ms']) < hold.end $($result['hold_end_ms']) (commit happens after hold.end)"
    } else {
        Add-Check 't1.postfix_evict_after_commit' (($result['after_commit_ms'] -gt 0) -and ($result['evict_first_ms'] -ge $result['after_commit_ms'])) `
            "first evict at $($result['evict_first_ms']) >= afterCommit $($result['after_commit_ms'])"
        $registered = @($ev | Where-Object { $_ -match ' event=cache\.evict\.register ' -and $_ -match 'inTransaction=True' })
        Add-Check 't1.postfix_registered_before_commit' ($registered.Count -ge 1) "register events inside tx=$($registered.Count)"
    }
    $result['writer_http'] = $metaW.http_status
}

# =====================================================================
'T2' {
    # Controlled rollback after the invalidation was registered: no successful-commit callback, no delete.
    $script:detailId = $ArticleId
    $cacheKey = "$CacheKeyPrefix$ArticleId"
    $v0 = "V0-$RunId"
    $v1 = "V1-$RunId"

    $seed = Set-DbTitle $ArticleId $v0 'content-v0'
    Add-RunStep -State $script:run -Step ('seed V0 through saveArticle (seed: ' + $seed + ')')
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    $warm = Get-Detail 'warm-cache-v0'
    Add-Check 't2.cache_warmed_with_v0' ((Get-Title (Read-BodyText 'warm-cache-v0')) -eq $v0) "warm title=$(Get-Title (Read-BodyText 'warm-cache-v0'))"

    $statsBefore = Get-Stats
    $swW = [System.Diagnostics.Stopwatch]::StartNew()
    $respW = $client.SendAsync((New-PostRequest "/p13a/harness/save?id=$ArticleId&title=$v1&content=content-v1" 'writer-rollback' $RunId)).GetAwaiter().GetResult()
    $swW.Stop()
    $metaW = Save-Response 'writer-rollback' $respW $swW.Elapsed.TotalMilliseconds
    $writerBody = Read-BodyText 'writer-rollback'
    $result['writer_body'] = $writerBody
    $result['writer_http'] = $metaW.http_status
    Add-Check 't2.write_failed_as_expected' ($writerBody -match 'controlled rollback' -or $writerBody -match 'IllegalStateException') "writer body=$writerBody"

    $dbTitle = Get-TitleFromDb $ArticleId
    $result['db_title_after_rollback'] = $dbTitle
    Add-Check 't2.db_still_v0' ($dbTitle -eq $v0) "db title=$dbTitle (expected ${v0}: the update was rolled back)"

    Start-Sleep -Milliseconds ($WindowMs + 700)
    $keyAfter = Redis-Exact @('EXISTS', $cacheKey)
    $statsAfter = Get-Stats
    $result['cache_key_exists_after_rollback'] = $keyAfter
    $result['stats_before'] = $statsBefore
    $result['stats_after'] = $statsAfter
    Add-Check 't2.cache_untouched_by_rollback' ($keyAfter -eq '1') "cache key exists=$keyAfter (a rollback must not delete the cache)"

    $ev = @(Read-Events $Events $RunId)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $noEvict = @($ev | Where-Object { $_ -match ' event=cache\.evict\.ok ' -or $_ -match ' event=cache\.evict\.second_begin ' })
    $skip = @($ev | Where-Object { $_ -match ' event=tx\.rollback_skip_evict ' })
    Add-Check 't2.no_evict_executed' ($noEvict.Count -eq 0) "delete events=$($noEvict.Count) (must be 0)"
    Add-Check 't2.rollback_skip_recorded' ($skip.Count -ge 1) "tx.rollback_skip_evict=$($skip.Count)"
}

# =====================================================================
'T3' {
    # Two refill timings after the commit: inside the 500 ms window (covered) and beyond it (residual risk).
    $v0 = "V0-$RunId"
    $v1 = "V1-$RunId"
    $windowCovered = @()
    $windowResidual = @()

    $phases = @(
        @{ name = 'T3a-inside-window'; id = $ArticleId; delay = 0 },
        @{ name = 'T3b-beyond-window'; id = $SecondArticleId; delay = 0 }
    )
    foreach ($ph in $phases) {
        $id = [long]$ph.id
        $key = "$CacheKeyPrefix$id"
        $seed = Set-DbTitle $id $v0 'content-v0'
        Add-RunStep -State $script:run -Step ('seed V0 for ' + $ph.name)
        Redis-Exact @('DEL', $key) | Out-Null
        # warm then delete so the reader is forced to read the DB while the writer is uncommitted
        $swWarm = [System.Diagnostics.Stopwatch]::StartNew()
        $respWarm = $client.SendAsync((New-Request "/api/v1/article/detail/$id" "warm-$($ph.name)" $RunId)).GetAwaiter().GetResult()
        $swWarm.Stop()
        Save-Response "warm-$($ph.name)" $respWarm $swWarm.Elapsed.TotalMilliseconds | Out-Null
        Redis-Exact @('DEL', $key) | Out-Null

        $taskW = $client.SendAsync((New-PostRequest "/p13a/harness/save?id=$id&title=$v1&content=content-v1" "writer-$($ph.name)" $RunId))
        $holdDeadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $holdDeadline) {
            $ev = Read-Events $Events $RunId
            if ($ev | Where-Object { $_ -match ' event=tx\.hold\.begin ' -and $_ -match " articleId=$id " }) { break }
            Start-Sleep -Milliseconds 40
        }
        # the reader's setEx is delayed by cache.write.delay.<id> from the probe config, so it lands at a
        # chosen offset after the commit: inside the window (350 ms) or beyond it (1300 ms)
        $swR = [System.Diagnostics.Stopwatch]::StartNew()
        $respR = $client.SendAsync((New-Request "/api/v1/article/detail/$id" "reader-$($ph.name)" $RunId)).GetAwaiter().GetResult()
        $swR.Stop()
        Save-Response "reader-$($ph.name)" $respR $swR.Elapsed.TotalMilliseconds | Out-Null
        $readerTitle = Get-Title (Read-BodyText "reader-$($ph.name)")

        $respW = $taskW.GetAwaiter().GetResult()
        $commitWall = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Start-Sleep -Milliseconds ($WindowMs + 1200)

        $swA = [System.Diagnostics.Stopwatch]::StartNew()
        $respA = $client.SendAsync((New-Request "/api/v1/article/detail/$id" "after-$($ph.name)" $RunId)).GetAwaiter().GetResult()
        $swA.Stop()
        Save-Response "after-$($ph.name)" $respA $swA.Elapsed.TotalMilliseconds | Out-Null
        $titleAfter = Get-Title (Read-BodyText "after-$($ph.name)")
        $dbTitle = Get-TitleFromDb $id

        $ev = @(Read-Events $Events $RunId)
        # filter by the reader's own request id: the warm-up request also writes the cache and must not be
        # mistaken for the refill whose timing the window argument depends on
        $readerEv = @($ev | Where-Object { $_ -match " requestId=reader-$([regex]::Escape($ph.name)) " })
        $writeDone = Evt-First $readerEv ' event=cache\.write\.done '
        $afterCommit = Evt-First ($ev | Where-Object { $_ -match " articleId=$id " }) ' event=tx\.after_commit '
        $secondBegin = Evt-First (Read-EventsForArticle $Events $id $runStartMs) ' event=cache\.evict\.second_begin '
        $rec = [ordered]@{
            phase          = $ph.name
            article_id     = $id
            reader_title   = $readerTitle
            title_after    = $titleAfter
            db_title       = $dbTitle
            write_done_ms  = if ($writeDone) { Evt-Time $writeDone } else { 0 }
            after_commit_ms = if ($afterCommit) { Evt-Time $afterCommit } else { 0 }
            second_begin_ms = if ($secondBegin) { Evt-Time $secondBegin } else { 0 }
        }
        if ($ph.name -eq 'T3a-inside-window') { $windowCovered += [pscustomobject]$rec } else { $windowResidual += [pscustomobject]$rec }
    }

    $result['inside_window'] = $windowCovered
    $result['beyond_window'] = $windowResidual
    $a = $windowCovered[0]
    Add-Check 't3.inside_window_refill_was_covered' ($a.title_after -eq $v1) `
        "refill at $($a.write_done_ms) after commit $($a.after_commit_ms), second delete at $($a.second_begin_ms); title after=$($a.title_after)"
    $b = $windowResidual[0]
    Add-Check 't3.beyond_window_is_a_known_residual_risk' ($b.title_after -eq $v0) `
        "refill at $($b.write_done_ms) after commit $($b.after_commit_ms), second delete already done at $($b.second_begin_ms); title after=$($b.title_after) (expected stale: this is the residual risk, NOT fixed)"
}

# =====================================================================
'T4' {
    # No transaction: the invalidation must happen immediately, and the second delete must still be scheduled.
    $script:detailId = $ArticleId
    $cacheKey = "$CacheKeyPrefix$ArticleId"
    $v0 = "V0-$RunId"
    $seed = Set-DbTitle $ArticleId $v0 'content-v0'
    Add-RunStep -State $script:run -Step ('seed V0 (seed: ' + $seed + ')')
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    $warm = Get-Detail 'warm-cache-v0'
    $keyBefore = Redis-Exact @('EXISTS', $cacheKey)
    Add-Check 't4.cache_present_before_evict' ($keyBefore -eq '1') "key exists=$keyBefore"

    $statsBefore = Get-Stats
    $resp = $client.SendAsync((New-PostRequest "/p13a/harness/evict?id=$ArticleId" 'evict-no-tx' $RunId)).GetAwaiter().GetResult()
    $body = [System.Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
    $result['evict_body'] = $body
    $keyImmediate = Redis-Exact @('EXISTS', $cacheKey)
    $result['key_exists_immediately_after'] = $keyImmediate
    Add-Check 't4.immediate_evict_without_transaction' ($keyImmediate -eq '0') "key exists instantly after the call=$keyImmediate"

    Start-Sleep -Milliseconds ($WindowMs + 600)
    $statsAfter = Get-Stats
    $result['stats_before'] = $statsBefore
    $result['stats_after'] = $statsAfter
    $noTx = [regex]::Match($statsAfter, '"no_transaction_runs"\s*:\s*(\d+)')
    $sched = [regex]::Match($statsAfter, '"second_delete_scheduled"\s*:\s*(\d+)')
    $done = [regex]::Match($statsAfter, '"second_delete_done"\s*:\s*(\d+)')
    Add-Check 't4.no_transaction_counter' ($noTx.Success -and [int]$noTx.Groups[1].Value -ge 1) "no_transaction_runs=$($noTx.Groups[1].Value)"
    Add-Check 't4.second_delete_was_scheduled' ($sched.Success -and [int]$sched.Groups[1].Value -ge 1) "second_delete_scheduled=$($sched.Groups[1].Value)"
    Add-Check 't4.second_delete_completed' ($done.Success -and [int]$done.Groups[1].Value -ge 1) "second_delete_done=$($done.Groups[1].Value)"

    $ev = @(Read-Events $Events $RunId)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $noTxEv = @($ev | Where-Object { $_ -match ' event=cache\.evict\.no_transaction_immediate ' })
    Add-Check 't4.no_transaction_event' ($noTxEv.Count -ge 1) "no_transaction immediate events=$($noTxEv.Count)"
}

# =====================================================================
'T5' {
    # Redis delete fails AFTER the commit: the MySQL write stays committed, the failure is recorded,
    # and the second delete is still scheduled (and succeeds with mode=once).
    $script:detailId = $ArticleId
    $cacheKey = "$CacheKeyPrefix$ArticleId"
    $v0 = "V0-$RunId"
    $v1 = "V1-$RunId"
    $seed = Set-DbTitle $ArticleId $v0 'content-v0'
    Add-RunStep -State $script:run -Step ('seed V0 (seed: ' + $seed + ')')
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    $warm = Get-Detail 'warm-cache-v0'

    $swW = [System.Diagnostics.Stopwatch]::StartNew()
    $respW = $client.SendAsync((New-PostRequest "/p13a/harness/save?id=$ArticleId&title=$v1&content=content-v1" 'writer-evict-fault' $RunId)).GetAwaiter().GetResult()
    $swW.Stop()
    $metaW = Save-Response 'writer-evict-fault' $respW $swW.Elapsed.TotalMilliseconds
    $writerBody = Read-BodyText 'writer-evict-fault'
    $result['writer_body'] = $writerBody
    $result['writer_http'] = $metaW.http_status
    Add-Check 't5.write_still_succeeded' ((Get-Code $writerBody) -eq '200') "writer code=$(Get-Code $writerBody) http=$($metaW.http_status)"

    $dbTitle = Get-TitleFromDb $ArticleId
    $result['db_title'] = $dbTitle
    Add-Check 't5.mysql_commit_preserved' ($dbTitle -eq $v1) "db title=$dbTitle (the commit must survive a failed cache delete)"

    Start-Sleep -Milliseconds ($WindowMs + 900)
    $stats = Get-Stats
    $result['stats'] = $stats
    $fail = [regex]::Match($stats, '"delete_failures"\s*:\s*(\d+)')
    $done = [regex]::Match($stats, '"second_delete_done"\s*:\s*(\d+)')
    Add-Check 't5.first_delete_failure_counted' ($fail.Success -and [int]$fail.Groups[1].Value -ge 1) "delete_failures=$($fail.Groups[1].Value)"
    Add-Check 't5.second_delete_succeeded' ($done.Success -and [int]$done.Groups[1].Value -ge 1) "second_delete_done=$($done.Groups[1].Value)"

    $ev = @(Read-Events $Events $RunId)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $injected = @($ev | Where-Object { $_ -match ' event=fault\.cache\.evict\.injected ' })
    $failed = @($ev | Where-Object { $_ -match ' event=cache\.evict\.fail ' })
    $secondOk = @(Read-EventsForArticle $Events $ArticleId $runStartMs | Where-Object { $_ -match ' event=cache\.evict\.ok ' -and $_ -match 'phase=.*:second' })
    Add-Check 't5.fault_injected_once' ($injected.Count -eq 1) "fault injections=$($injected.Count)"
    Add-Check 't5.failure_recorded' ($failed.Count -ge 1) "cache.evict.fail events=$($failed.Count)"
    Add-Check 't5.second_delete_recorded' ($secondOk.Count -ge 1) "second delete ok events=$($secondOk.Count)"
    $keyAfter = Redis-Exact @('EXISTS', $cacheKey)
    $result['cache_key_exists_after'] = $keyAfter
}

# =====================================================================
'T6' {
    # Read path: cache hit and lock wait must not hold a pooled connection; plus the P1.2 contract regression.
    $script:detailId = $BigId16
    $cacheKey = "$CacheKeyPrefix$BigId16"
    $seed = Set-DbTitle $BigId16 "T6-$RunId" 'content-t6'
    Add-RunStep -State $script:run -Step ('seed big id (seed: ' + $seed + ')')
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    $warm = Get-Detail 'warm-cache'
    $warmBody = Read-BodyText 'warm-cache'
    $warmTitle = Get-Title $warmBody

    # (1) cache hit: a ~2 ms request cannot be caught by sampling, so the timing-independent evidence is
    # the borrow counter delta (did the request take a pooled connection at all?)
    $statsBeforeHit = Get-Stats
    $taskHit = $client.SendAsync((New-Request "/api/v1/article/detail/$BigId16" 'hit' $RunId))
    $hitSample = Hikari-MaxDuring $taskHit 4000
    $respHit = $taskHit.GetAwaiter().GetResult()
    Save-Response 'hit' $respHit 0 | Out-Null
    $statsAfterHit = Get-Stats
    $result['hit_sample'] = $hitSample
    $b0 = [regex]::Match($statsBeforeHit, '"conn_borrows"\s*:\s*(\d+)')
    $b1 = [regex]::Match($statsAfterHit, '"conn_borrows"\s*:\s*(\d+)')
    $hitBorrowDelta = if ($b0.Success -and $b1.Success) { [int]$b1.Groups[1].Value - [int]$b0.Groups[1].Value } else { -1 }
    $result['hit_borrow_delta'] = $hitBorrowDelta
    $result['stats_before_hit'] = $statsBeforeHit
    $result['stats_after_hit'] = $statsAfterHit
    if ($Variant -eq 'PRE') {
        Add-Check 't6.prefix_cache_hit_borrows_a_connection' ($hitBorrowDelta -ge 1) `
            "connection borrows caused by one cache hit=$hitBorrowDelta (pre-fix: the class-level transaction borrows before any SQL); sampled max active=$($hitSample.max_active)/$($hitSample.samples)"
    } else {
        Add-Check 't6.cache_hit_borrows_no_connection' ($hitBorrowDelta -eq 0) `
            "connection borrows caused by one cache hit=$hitBorrowDelta; sampled max active=$($hitSample.max_active)/$($hitSample.samples)"
    }

    # (2) lock wait: plant a foreign lock so the request waits out its budget and fails with 503
    # force a cache miss: the cache-hit sample above left the key warm, which would answer 200 immediately
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    $lockKey = "$cacheKey`:lock"
    Redis-Exact @('DEL', $lockKey) | Out-Null
    Redis-Exact @('SET', $lockKey, 'p13a-foreign-holder', 'PX', '4000') | Out-Null
    $taskWait = $client.SendAsync((New-Request "/api/v1/article/detail/$BigId16" 'wait' $RunId))
    $waitSample = Hikari-MaxDuring $taskWait 6000
    $respWait = $taskWait.GetAwaiter().GetResult()
    $metaWait = Save-Response 'wait' $respWait 0
    $waitCode = Get-Code (Read-BodyText 'wait')
    $result['wait_sample'] = $waitSample
    $result['wait_code'] = $waitCode
    if ($Variant -eq 'PRE') {
        Add-Check 't6.prefix_lock_wait_holds_a_connection' ($waitSample.max_active -ge 1) `
            "max active connections during the lock wait=$($waitSample.max_active) over $($waitSample.samples) samples (biz=$waitCode)"
    } else {
        Add-Check 't6.lock_wait_holds_no_connection' ($waitSample.max_active -eq 0) `
            "max active connections during the lock wait=$($waitSample.max_active) over $($waitSample.samples) samples (biz=$waitCode)"
    }
    Redis-Exact @('DEL', $lockKey) | Out-Null

    # (3) contract regression: cold/hot byte identical, big id as an exact JSON string, missing id
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    $swCold = [System.Diagnostics.Stopwatch]::StartNew()
    $respCold = $client.SendAsync((New-Request "/api/v1/article/detail/$BigId16" 'cold' $RunId)).GetAwaiter().GetResult()
    $swCold.Stop()
    $metaCold = Save-Response 'cold' $respCold $swCold.Elapsed.TotalMilliseconds
    $swHot = [System.Diagnostics.Stopwatch]::StartNew()
    $respHot = $client.SendAsync((New-Request "/api/v1/article/detail/$BigId16" 'hot' $RunId)).GetAwaiter().GetResult()
    $swHot.Stop()
    $metaHot = Save-Response 'hot' $respHot $swHot.Elapsed.TotalMilliseconds
    $cold = Read-BodyText 'cold'; $hot = Read-BodyText 'hot'
    Add-Check 't6.cold_hot_byte_identical' ($cold -ceq $hot) "len_cold=$($cold.Length) len_hot=$($hot.Length)"
    Add-Check 't6.big_id_is_exact_string' ($cold -match [regex]::Escape('"id":"' + "$BigId16" + '"')) 'article.id serialised as an exact JSON string'

    $swMissing = [System.Diagnostics.Stopwatch]::StartNew()
    $respMissing = $client.SendAsync((New-Request "/api/v1/article/detail/$MissingId" 'missing' $RunId)).GetAwaiter().GetResult()
    $swMissing.Stop()
    Save-Response 'missing' $respMissing $swMissing.Elapsed.TotalMilliseconds | Out-Null
    $missingBody = Read-BodyText 'missing'
    $missingCode = Get-Code $missingBody
    $result['missing_code'] = $missingCode
    Add-Check 't6.missing_id_returns_1002' ($missingCode -eq '1002') "code=$missingCode"
    Redis-Exact @('DEL', "$CacheKeyPrefix$MissingId") | Out-Null

    # (4) connection evidence from the short read snapshot
    $ev = @(Read-Events $Events $RunId)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $snapshot = @($ev | Where-Object { $_ -match ' event=db\.snapshot\.(begin|end) ' })
    $result['snapshot_events'] = $snapshot.Count
    if ($Variant -eq 'PRE') {
        Add-Check 't6.prefix_has_no_short_snapshot' ($snapshot.Count -eq 0) "db.snapshot events=$($snapshot.Count) (pre-fix has no short read transaction: the whole request ran inside the class-level one)"
    } else {
        Add-Check 't6.snapshot_read_tx_recorded' ($snapshot.Count -ge 2) "db.snapshot events=$($snapshot.Count) (two SELECTs inside one read-only transaction)"
    }

    # (4b) C: real transaction/connection identity of the short read transaction (not a caller-written label)
    $coldEv = @($ev | Where-Object { $_ -match ' requestId=cold ' })
    $traces = @($coldEv | Where-Object { $_ -match ' event=tx\.trace ' })
    $result['tx_traces'] = @($traces)
    $traceFirst = @($traces | Where-Object { $_ -match 'phase=before_first_select' })
    $traceSecond = @($traces | Where-Object { $_ -match 'phase=after_second_select' })
    if ($Variant -eq 'PRE') {
        Add-Check 't6.prefix_has_no_short_tx_trace' ($traces.Count -eq 0) "tx.trace events=$($traces.Count) (pre-fix reads inside the class-level transaction; no short read transaction to trace)"
    } else {
        $tf = if ($traceFirst.Count -gt 0) { $traceFirst[0] } else { '' }
        $tl = if ($traceSecond.Count -gt 0) { $traceSecond[0] } else { '' }
        Add-Check 't6.short_tx_is_active_and_read_only' `
            (($tf -match 'txActive=true') -and ($tf -match 'readOnly=true') -and ($tl -match 'txActive=true') -and ($tl -match 'readOnly=true')) `
            "first=$tf ; second=$tl"
        $tfRes = Field $tf 'resourceId'; $tlRes = Field $tl 'resourceId'
        $tfConn = Field $tf 'connId'; $tlConn = Field $tl 'connId'
        $result['tx_resource_first'] = $tfRes
        $result['tx_resource_second'] = $tlRes
        $result['conn_first'] = $tfConn
        $result['conn_second'] = $tlConn
        Add-Check 't6.two_selects_share_one_transaction_resource' `
            (($tfRes -ne '') -and ($tfRes -ne '-') -and ($tfRes -eq $tlRes)) `
            "resourceId first=$tfRes second=$tlRes (one transaction resource for both SELECTs)"
        Add-Check 't6.two_selects_share_one_connection' `
            (($tfConn -ne '') -and ($tfConn -ne '-') -and ($tfConn -eq $tlConn)) `
            "connId first=$tfConn second=$tlConn (identity hash of the same connection object)"
        $iso = Field $tf 'isolation'
        $ac = Field $tf 'autoCommit'
        $result['isolation_actual'] = $iso
        $result['autocommit_actual'] = $ac
        Add-Check 't6.real_isolation_and_autocommit_recorded' `
            (($iso -match '^\d+$') -and ([int]$iso -gt 0) -and ($ac -eq 'false')) `
            "jdbc isolation=$iso (2=READ_COMMITTED, 4=REPEATABLE_READ), autoCommit=$ac"
        $statsAfterCold = Get-Stats
        $actMatch = [regex]::Match($statsAfterCold, '"conn_active"\s*:\s*(\d+)')
        $actAfter = if ($actMatch.Success) { $actMatch.Groups[1].Value } else { '' }
        $result['conn_active_after_cold_read'] = $actAfter
        Add-Check 't6.connection_returned_after_snapshot' ($actAfter -eq '0') `
            "conn_active right after the cold read=$actAfter (the short read transaction released its connection)"
    }

    # (5) C: a normal WAIT_THEN_HIT sample (not the budget-exhausted 503)
    $holderId = $HolderId
    $holderKey = "$CacheKeyPrefix$holderId"
    $holderLock = "$holderKey`:lock"
    Redis-Exact @('DEL', $holderKey) | Out-Null
    Redis-Exact @('DEL', $holderLock) | Out-Null
    $swH = [System.Diagnostics.Stopwatch]::StartNew()
    $taskH = $client.SendAsync((New-Request "/api/v1/article/detail/$holderId" 'holder-slow' $RunId))
    $lockDeadline = (Get-Date).AddSeconds(10)
    $lockSeen = $false
    while ((Get-Date) -lt $lockDeadline) {
        if ((Redis-Exact @('EXISTS', $holderLock)) -eq '1') { $lockSeen = $true; break }
        Start-Sleep -Milliseconds 20
    }
    Add-Check 't6.holder_holds_the_lock_before_waiter' $lockSeen 'the slow holder acquired the lock before the waiter was sent'
    $swWt = [System.Diagnostics.Stopwatch]::StartNew()
    $taskWt = $client.SendAsync((New-Request "/api/v1/article/detail/$holderId" 'waiter-hit' $RunId))
    $wtSample = Hikari-MaxDuring $taskWt 6000
    $respWt = $taskWt.GetAwaiter().GetResult(); $swWt.Stop()
    $metaWt = Save-Response 'waiter-hit' $respWt $swWt.Elapsed.TotalMilliseconds
    $respH = $taskH.GetAwaiter().GetResult(); $swH.Stop()
    Save-Response 'holder-slow' $respH $swH.Elapsed.TotalMilliseconds | Out-Null
    $wtBody = Read-BodyText 'waiter-hit'
    $wtCode = Get-Code $wtBody
    $wtTitle = Get-Title $wtBody
    $result['wait_then_hit'] = [ordered]@{
        http = $metaWt.http_status; code = $wtCode; title = $wtTitle
        elapsed_ms = $metaWt.elapsed_ms; sample = $wtSample
    }
    Add-Check 't6.wait_then_hit_returns_success' (($metaWt.http_status -eq 200) -and ($wtCode -eq '200')) `
        "http=$($metaWt.http_status) biz=$wtCode title=$wtTitle elapsed=$($metaWt.elapsed_ms)ms"
    Add-Check 't6.wait_then_hit_exact_id_string' ($wtBody -match [regex]::Escape('"id":"' + "$holderId" + '"')) `
        'the waiter response carries the exact string id (same contract as cold/hot)'
    $wtEv = @(Read-Events $Events $RunId | Where-Object { $_ -match ' requestId=waiter-hit ' })
    $wtDb = @($wtEv | Where-Object { $_ -match ' event=db\.enter ' -or $_ -match ' event=rebuild\.begin ' })
    $wtFails = @($wtEv | Where-Object { $_ -match ' event=lock\.fail ' })
    $wtHitDuringWait = @($wtEv | Where-Object { $_ -match ' event=wait\.end ' -and $_ -match 'outcome=hit' })
    $wtRecheckHit = @($wtEv | Where-Object { $_ -match ' event=cache\.read ' -and $_ -match 'during_wait=true' -and $_ -match 'hit=true' })
    $wtAcquired = @($wtEv | Where-Object { $_ -match ' event=lock\.acquired ' })
    $wtDoubleCheck = @($wtEv | Where-Object { $_ -match ' stage=recheck_after_lock ' })
    $result['waiter_did_rebuild'] = $wtDb.Count
    $result['waiter_lock_fail_attempts'] = $wtFails.Count
    $result['waiter_hit_during_wait'] = $wtHitDuringWait.Count
    $result['waiter_recheck_hit'] = $wtRecheckHit.Count
    $result['waiter_lock_acquired'] = $wtAcquired.Count
    Add-Check 't6.waiter_really_waited' ($wtFails.Count -ge 2) `
        "lock.fail attempts by the waiter=$($wtFails.Count) (it was really kept waiting, not served immediately)"
    Add-Check 't6.wait_then_hit_no_rebuild_by_waiter' ($wtDb.Count -eq 0) `
        "db.enter/rebuild.begin for the waiter=$($wtDb.Count) (the value must come from the holder's cache write)"
    # Two legitimate "waited then served from cache" endings exist in the read path:
    #   (a) a recheck inside the wait loop hits the cache  -> wait.end outcome=hit
    #   (b) the waiter finally acquires the lock and the post-lock double check hits -> DOUBLE_CHECK_HIT
    # Which one happens depends on whether the holder releases the lock before the waiter's next recheck.
    # Both must be recorded as observed, not asserted as one fixed branch.
    $pathA = ($wtHitDuringWait.Count -ge 1) -or ($wtRecheckHit.Count -ge 1)
    $pathB = ($wtAcquired.Count -ge 1) -and ($wtDoubleCheck.Count -ge 1)
    $result['wait_hit_path'] = if ($pathA) { 'recheck_inside_wait(wait.end outcome=hit)' } elseif ($pathB) { 'post_lock_double_check(DOUBLE_CHECK_HIT)' } else { 'none' }
    Add-Check 't6.waited_then_served_from_cache' ($pathA -or $pathB) `
        "path=$($result['wait_hit_path']) wait.end_hit=$($wtHitDuringWait.Count) recheck_hit=$($wtRecheckHit.Count) lock_acquired=$($wtAcquired.Count) double_check=$($wtDoubleCheck.Count)"
    Add-Check 't6.waiter_holds_no_connection_while_waiting' ($wtSample.max_active -eq 0) `
        "max active connections while the waiter waited=$($wtSample.max_active) over $($wtSample.samples) samples"
    Redis-Exact @('DEL', $holderKey) | Out-Null
    Redis-Exact @('DEL', $holderLock) | Out-Null
}

default { throw "unknown scenario: $Scenario" }
}

$client.Dispose()
$counts = Get-RunCheckCounts $script:run
$result['checks'] = $script:run.checks
$result['counts'] = $counts
$result['finished_utc'] = (Now-Utc)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'scenario-result.json') -Text ($result | ConvertTo-Json -Depth 6)
$script:run.checks | ForEach-Object { "{0,-46} {1,-8} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
