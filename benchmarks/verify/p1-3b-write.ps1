# P1.3b write-path scenarios (A-D rework): S, SROLLBACK, B, BROLLBACK, N, ZERO, REG.
# ASCII only; PS 5.1 reads a BOM-less .ps1 as ANSI/GBK.
#
# Every scenario takes one guarded run directory, writes each artifact once, and reads the DB / Redis
# state independently instead of trusting DEL log lines. The instance under test is the real article
# service started through benchmarks/env/start-p13b-instance.ps1.
#
# What is substituted, and only in this run's assembly: FileStorageService (returns a marked URL and
# records the uploaded HTML) and KafkaTemplate (records the call, sends nothing). The Freemarker
# template, the @Async worker, the DAO, the transaction and the invalidator are the real ones.
#
# Redis: the application runs in the isolated database $RedisDb (course data lives in db 0). Every
# redis-cli call here uses the SAME database, and the isolation itself is asserted (keys present in
# $RedisDb, absent in db 0), not assumed from the command line.
#
# Exit codes: 0 = all checks passed, 1 = a check failed (files kept), 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][ValidateSet('S', 'SROLLBACK', 'B', 'BROLLBACK', 'N', 'ZERO', 'REG')][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [Parameter(Mandatory = $true)][string]$Variant,
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [long]$ArticleId = 9007199254741015,
    [long]$RollbackArticleId = 9007199254741016,
    [long]$CountArticleId = 9007199254741017,
    [long]$CountRollbackArticleId = 9007199254741018,
    [long]$CreateArticleId = 9007199254760001,
    [long]$RegArticleId = 9007199254741020,
    [long]$RegRollbackArticleId = 9007199254741022,
    # both ids are OUTSIDE the generated contiguous block (9007199254741000..9007199254750999), verified absent
    [long]$MissingArticleId = 9007199254760002,
    [string]$MarkerTitle = 'P13b-created',
    [int]$AsyncWaitMs = 15000,
    [int]$TimeoutSeconds = 60,
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

. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage "P1.3b-$Scenario" `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ scenario = $Scenario; base = $Base; variant = $Variant; article = $ArticleId;
                       create_article = $CreateArticleId; redis_db = $RedisDb; missing_article = $MissingArticleId } `
        -Targets @("$ArticleId", "$RollbackArticleId", "$CountArticleId", "$CountRollbackArticleId", "$CreateArticleId", "$MissingArticleId") `
        -DataSet $Database
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

Add-Type -AssemblyName System.Net.Http | Out-Null
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$handler.MaxConnectionsPerServer = 20
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

function Now-Utc { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $inv) }
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
}
function Redis-In([int]$db, [string[]]$a) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', "$db") + $a
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Redis-Exact([string[]]$a) { return (Redis-In $RedisDb $a) }
function Sql([string]$q) {
    $o = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--default-character-set=utf8mb4' '-e' $q 2>&1
    return (($o | Out-String).Trim())
}
function Db-StaticUrl([long]$id) {
    $v = Sql "SELECT IFNULL(static_url,'NULL') FROM $Database.ap_article WHERE id=$id;"
    if ($v -eq 'NULL' -or $v -eq '') { return '' }
    return $v
}
function Db-Counts([long]$id) {
    return (Sql "SELECT CONCAT_WS('|', views, likes, comment, collection) FROM $Database.ap_article WHERE id=$id;")
}
function Db-RowCount([long]$id) {
    $a = Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id=$id;"
    $c = Sql "SELECT COUNT(*) FROM $Database.ap_article_content WHERE article_id=$id;"
    $g = Sql "SELECT COUNT(*) FROM $Database.ap_article_config WHERE article_id=$id;"
    return [pscustomobject]@{ article = $a; content = $c; config = $g }
}
function Post([string]$path, [string]$reqId) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$Base$path")
    $req.Content = New-Object System.Net.Http.StringContent('')
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    return $client.SendAsync($req).GetAwaiter().GetResult()
}
function Get-([string]$path, [string]$reqId) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base$path")
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    return $client.SendAsync($req).GetAwaiter().GetResult()
}
function Body-Of($resp) { return [System.Text.Encoding]::UTF8.GetString($resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()) }
function Save-Artifact([string]$name, [string]$text) {
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir "$name.json") -Text $text
}
function Get-Stats { return (Body-Of (Get- '/p13b/harness/stats' 'stats')) }
function Json-Field([string]$json, [string]$name) {
    $m = [regex]::Match($json, ('"' + $name + '"\s*:\s*(-?\d+)'))
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Detail-Counts([string]$raw) {
    # all four counter fields of the detail response, in a fixed order
    $out = @()
    foreach ($f in @('views', 'likes', 'comment', 'collection')) {
        $m = [regex]::Match($raw, ('"' + $f + '"\s*:\s*(-?\d+)'))
        $out += $(if ($m.Success) { $m.Groups[1].Value } else { 'MISSING' })
    }
    return ($out -join '|')
}
function Detail-Title([string]$raw) {
    $m = [regex]::Match($raw, '"title"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Detail-StaticUrl([string]$raw) {
    $m = [regex]::Match($raw, '"staticUrl"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}
function Detail-Code([string]$raw) {
    $m = [regex]::Match($raw, '"code"\s*:\s*(-?\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'MISSING'
}
function Evt-Time([string]$line) {
    $m = [regex]::Match($line, 'epochMs=(\d+)')
    if ($m.Success) { return [long]$m.Groups[1].Value }
    return 0
}
function Read-Events([string]$path, [string]$runId) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path | Where-Object { $_ -match " runId=$([regex]::Escape($runId)) " })
}
function Read-EventsForArticle([string]$path, [long]$id, [long]$sinceMs) {
    # the @Async worker and the scheduled second delete have no request context: their lines carry
    # runId=- and requestId=-, so they must be selected by article id plus "not older than this run".
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path | Where-Object { $_ -match " articleId=$id " -and (Evt-Time $_) -ge $sinceMs })
}

$runStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 2000
$result = [ordered]@{ run_id = $RunId; scenario = $Scenario; variant = $Variant; base = $Base; redis_db = $RedisDb; started_utc = (Now-Utc) }
$cacheKeyFor = { param($id) "$CacheKeyPrefix$id" }
# the hot-list key really used by updateScore is keyed by the article's own channel, not a fixed value
$ChannelId = [int](Sql "SELECT channel_id FROM $Database.ap_article WHERE id=$CountArticleId;")
$hotKeyChannel = "hot_article_first_page_$ChannelId"
$hotKeyAll = 'hot_article_first_page___all__'

function Warm-Detail([long]$id, [string]$name) {
    Redis-Exact @('DEL', (& $cacheKeyFor $id)) | Out-Null
    Redis-Exact @('DEL', ((& $cacheKeyFor $id) + ':lock')) | Out-Null
    return (Read-Detail $id $name)
}
function Read-Detail([long]$id, [string]$name) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Get- "/api/v1/article/detail/$id" $name
    $sw.Stop()
    $body = Body-Of $resp
    Save-Artifact "$name.body" $body
    return [pscustomobject]@{ code = (Detail-Code $body); title = (Detail-Title $body); staticUrl = (Detail-StaticUrl $body);
                              counts = (Detail-Counts $body); elapsed = $sw.Elapsed.TotalMilliseconds; body = $body }
}

switch ($Scenario) {

# =====================================================================
'S' {
    # PRE: warm detail, then the real async static_url write. DB gets the new URL, the detail cache keeps
    # the old one. POST: the same call registers the invalidation in the worker transaction, so the next
    # detail read sees the new URL.
    $key = & $cacheKeyFor $ArticleId
    # fixture setup only: start from "no static_url yet" so both variants warm the same old value
    Sql "UPDATE $Database.ap_article SET static_url=NULL WHERE id=$ArticleId;" | Out-Null
    $warm = Warm-Detail $ArticleId 'warm-detail'
    Add-Check 's.cache_warmed' ((Redis-Exact @('EXISTS', $key)) -eq '1') "cache key exists=$(Redis-Exact @('EXISTS', $key)) in db $RedisDb warm_staticUrl='$($warm.staticUrl)'"
    $result['warm_static_url'] = $warm.staticUrl

    $statsBefore = Get-Stats
    $uploadsBefore = Json-Field $statsBefore 'html_uploads'
    $content = '[{"type":"text","value":"P13b-marker"}]'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = Post "/p13b/harness/staticize?id=$ArticleId&content=$content" 'staticize'
    $sw.Stop()
    $body = Body-Of $resp
    Save-Artifact 'staticize-call' $body
    $result['staticize_caller_ms'] = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
    Add-Check 's.caller_returns_before_write' ($body -match '"submitted":\s*true') "call body=$body (return means submitted, not written)"
    Add-Check 's.caller_is_fast' ($sw.Elapsed.TotalMilliseconds -lt 200) "caller elapsed=$([math]::Round($sw.Elapsed.TotalMilliseconds,1))ms (the worker does the slow part)"

    $deadline = (Get-Date).AddMilliseconds($AsyncWaitMs)
    $uploaded = $false
    Add-Check 's.cache_key_in_isolated_db' (((Redis-Exact @('EXISTS', $key)) -eq '1') -and ((Redis-In 0 @('EXISTS', $key)).Trim() -eq '0')) `
        "detail key exists in db $RedisDb and not in course db 0 (db0=$((Redis-In 0 @('EXISTS', $key)).Trim()))"
    $dbUrl = ''
    while ((Get-Date) -lt $deadline) {
        $stats = Get-Stats
        $now = Json-Field $stats 'html_uploads'
        $dbUrl = Db-StaticUrl $ArticleId
        if ($now -ne '' -and [int]$now -gt [int]$uploadsBefore -and $dbUrl -ne '') { $uploaded = $true; break }
        Start-Sleep -Milliseconds 100
    }
    $result['db_static_url'] = $dbUrl
    $result['uploads_before'] = $uploadsBefore
    Add-Check 's.async_worker_wrote_html' $uploaded "uploads $uploadsBefore -> $(Json-Field (Get-Stats) 'html_uploads'); db static_url='$dbUrl'"
    Add-Check 's.html_is_marked' ((Get-Stats) -match '"has_marker":\s*true') 'stats show an upload carrying the P13b-marker from the real template'
    Add-Check 's.db_has_marked_url' ($dbUrl -like 'p13b-rebuilt://html/*') "db static_url='$dbUrl'"

    $after = Read-Detail $ArticleId 'after-async'
    $result['after_static_url'] = $after.staticUrl
    if ($Variant -eq 'PRE') {
        Add-Check 's.prefix_detail_still_old' ($after.staticUrl -ne $dbUrl) "detail staticUrl='$($after.staticUrl)' db='$dbUrl' (pre-fix: the worker never invalidated)"
    } else {
        Add-Check 's.postfix_detail_is_new' ($after.staticUrl -eq $dbUrl) "detail staticUrl='$($after.staticUrl)' db='$dbUrl'"
    }
    Add-Check 's.content_and_id_contract_kept' (($after.code -eq '200') -and ($after.body -match [regex]::Escape('"id":"' + "$ArticleId" + '"'))) `
        "code=$($after.code) id-as-string=$(($after.body -match [regex]::Escape('"id":"' + "$ArticleId" + '"')))"

    $ev = @(Read-EventsForArticle $Events $ArticleId $runStartMs)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $staticEvents = @($ev | Where-Object { $_ -match ' event=static_url\.updated ' })
    $skippedEvents = @($ev | Where-Object { $_ -match ' event=static_url\.update_skipped ' })
    $registerEvents = @($ev | Where-Object { $_ -match ' event=cache\.evict\.register ' -and $_ -match 'static_url:afterUpdate' })
    $afterCommit = @($ev | Where-Object { $_ -match ' event=tx\.after_commit ' -and $_ -match 'static_url:afterUpdate' })
    $result['static_url_events'] = $staticEvents.Count
    $result['static_url_registers'] = $registerEvents.Count
    Add-Check 's.worker_wrote_static_url' ($staticEvents.Count -ge 1) "static_url.updated events=$($staticEvents.Count) skipped=$($skippedEvents.Count) first='$(if ($staticEvents.Count -gt 0) { $staticEvents[0] } else { '-' })'"
    if ($Variant -eq 'PRE') {
        Add-Check 's.prefix_no_invalidation' (($registerEvents.Count -eq 0) -and ($afterCommit.Count -eq 0)) `
            "register=$($registerEvents.Count) afterCommit=$($afterCommit.Count) (pre-fix has neither)"
    } else {
        Add-Check 's.postfix_invalidation_after_commit' (($registerEvents.Count -ge 1) -and ($afterCommit.Count -ge 1)) `
            "register=$($registerEvents.Count) afterCommit=$($afterCommit.Count)"
    }
}

# =====================================================================
'SROLLBACK' {
    # The message double throws inside the async worker transaction, so the static_url UPDATE must roll
    # back and no successful-commit invalidation may run.
    $key = & $cacheKeyFor $RollbackArticleId
    $urlBefore = Db-StaticUrl $RollbackArticleId
    $warm = Warm-Detail $RollbackArticleId 'warm-detail'
    $content = '[{"type":"text","value":"P13b-marker-rollback"}]'
    $resp = Post "/p13b/harness/staticize?id=$RollbackArticleId&content=$content" 'staticize-rollback'
    $result['call_body'] = (Body-Of $resp)

    $deadline = (Get-Date).AddMilliseconds($AsyncWaitMs)
    $registerSeen = $false
    while ((Get-Date) -lt $deadline) {
        $ev = @(Read-EventsForArticle $Events $RollbackArticleId $runStartMs)
        if ($ev | Where-Object { $_ -match ' event=cache\.evict\.register ' -and $_ -match 'static_url:afterUpdate' }) { $registerSeen = $true; break }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 800
    $urlAfter = Db-StaticUrl $RollbackArticleId
    $result['db_static_url_before'] = $urlBefore
    $result['db_static_url_after'] = $urlAfter
    $result['register_seen'] = $registerSeen
    Add-Check 'sr.register_happened_before_rollback' $registerSeen 'the worker executed UPDATE and registered the invalidation before the double threw'
    Add-Check 'sr.db_url_unchanged_after_rollback' ($urlAfter -eq $urlBefore) "db static_url before='$urlBefore' after='$urlAfter' (the worker rolled back)"
    $keyExists = Redis-Exact @('EXISTS', $key)
    Add-Check 'sr.cache_untouched_by_rollback' ($keyExists -eq '1') "cache key exists=$keyExists in db $RedisDb"
    $ev = @(Read-EventsForArticle $Events $RollbackArticleId $runStartMs)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $afterCommit = @($ev | Where-Object { $_ -match ' event=tx\.after_commit ' -and $_ -match 'static_url:afterUpdate' })
    $deletes = @($ev | Where-Object { $_ -match ' event=cache\.evict\.ok ' -and $_ -match 'static_url' })
    $result['after_commit_count'] = $afterCommit.Count
    Add-Check 'sr.no_commit_callback' ($afterCommit.Count -eq 0) "afterCommit(static_url)=$($afterCommit.Count)"
    Add-Check 'sr.no_delete_executed' ($deletes.Count -eq 0) "static_url delete events=$($deletes.Count)"
}

# =====================================================================
'B' {
    # One real public updateScore call with the isolated Redis database: counters grow in MySQL, the
    # detail cache is invalidated after commit (POST) or keeps the old value (PRE), and the hot-list keys
    # are written in the ISOLATED db only.
    $key = & $cacheKeyFor $CountArticleId
    $countsBefore = Db-Counts $CountArticleId
    $warm = Warm-Detail $CountArticleId 'warm-detail'
    $result['warm_title'] = $warm.title
    $result['detail_counts_at_warm'] = $warm.counts

    # fixture: give the code an existing hot list so the SET branch really executes, in the isolated db
    $hotSeed = '[{"id":9007199254741000,"score":10,"title":"P13b-hot-seed"}]'
    # -x reads the value from stdin: passing this JSON as an argument lets PowerShell strip the quotes
    $hotSeed | & $RedisCli '-h' '127.0.0.1' '-p' '6379' '-n' "$RedisDb" '-x' 'SET' $hotKeyChannel | Out-Null
    $hotSeed | & $RedisCli '-h' '127.0.0.1' '-p' '6379' '-n' "$RedisDb" '-x' 'SET' $hotKeyAll | Out-Null
    Add-Check 'b.hot_fixture_seeded' ((Redis-Exact @('GET', $hotKeyChannel)) -match '"id"') `
        "seeded hot list in db $RedisDb reads back with quoted field names: $(Redis-Exact @('GET', $hotKeyChannel))"
    $resp = Post "/p13b/harness/score?id=$CountArticleId&view=7&like=3&comment=2&collect=1" 'update-score'
    $body = Body-Of $resp
    Save-Artifact 'update-score-call' $body
    Add-Check 'b.update_score_returned_ok' ($body -match '"ok":\s*true') "call body=$body"

    $countsAfter = Db-Counts $CountArticleId
    $result['counts_before'] = $countsBefore
    $result['counts_after'] = $countsAfter
    $parts = $countsAfter -split '\|'
    $before = $countsBefore -split '\|'
    $deltaOk = ($parts.Count -eq 4) -and ([int]$parts[0] - [int]$before[0] -eq 7) -and ([int]$parts[1] - [int]$before[1] -eq 3) `
        -and ([int]$parts[2] - [int]$before[2] -eq 2) -and ([int]$parts[3] - [int]$before[3] -eq 1)
    Add-Check 'b.db_counters_exact_delta' $deltaOk "before=$countsBefore after=$countsAfter (target +7/+3/+2/+1 per field)"

    # hot-list isolation: the counters path wrote the hot keys in the isolated db, never in course db 0
    $hotChannelDb = Redis-Exact @('GET', $hotKeyChannel)
    $hotAllDb = Redis-Exact @('GET', $hotKeyAll)
    $db0Channel = (Redis-In 0 @('EXISTS', $hotKeyChannel)).Trim()
    $db0All = (Redis-In 0 @('EXISTS', $hotKeyAll)).Trim()
    $result['hot_db_channels'] = "$hotKeyChannel len=$($hotChannelDb.Length) ; $hotKeyAll len=$($hotAllDb.Length)"
    Add-Check 'b.hot_list_written_in_isolated_db' (($hotChannelDb.Length -gt 0) -and ($hotAllDb.Length -gt 0) -and $hotChannelDb.Contains("$CountArticleId")) `
        "db $RedisDb hot keys contain the article: channel_len=$($hotChannelDb.Length) all_len=$($hotAllDb.Length)"
    Add-Check 'b.hot_list_absent_from_course_db' (($db0Channel -eq '0') -and ($db0All -eq '0')) `
        "course db 0 EXISTS: channel=$db0Channel all=$db0All"

    # detail cache state right after the committed write, then a full four-field reconciliation
    $keyExists = Redis-Exact @('EXISTS', $key)
    $result['key_exists_after'] = $keyExists
    $after = Read-Detail $CountArticleId 'after-count'
    $result['detail_counts_after'] = $after.counts
    if ($Variant -eq 'PRE') {
        Add-Check 'b.prefix_cache_stale' ($keyExists -eq '1') "cache key exists=$keyExists right after the committed count write (pre-fix keeps the old value)"
        Add-Check 'b.prefix_detail_is_old_value' ($after.counts -eq $warm.counts) "detail at warm=$($warm.counts) detail after write=$($after.counts) db=$countsAfter"
    } else {
        Add-Check 'b.postfix_cache_invalidated' (($keyExists -eq '0') -or ($after.counts -eq $countsAfter)) `
            "key exists=$keyExists, detail counts=$($after.counts) db=$countsAfter"
        Add-Check 'b.postfix_detail_matches_db_all_fields' ($after.counts -eq $countsAfter) `
            "detail=$($after.counts) db=$countsAfter (views|likes|comment|collection)"
    }
    Add-Check 'b.detail_readable_after' ($after.code -eq '200') "code=$($after.code)"

    $ev = @(Read-Events $Events $RunId)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $countEvents = @($ev | Where-Object { $_ -match ' event=behavior_count\.updated ' })
    $register = @($ev | Where-Object { $_ -match ' event=cache\.evict\.register ' -and $_ -match 'updateScore:afterUpdate' })
    $afterCommit = @($ev | Where-Object { $_ -match ' event=tx\.after_commit ' -and $_ -match 'updateScore:afterUpdate' })
    $result['count_events'] = $countEvents.Count
    $result['register_count'] = $register.Count
    Add-Check 'b.count_event_recorded' ($countEvents.Count -ge 1) "behavior_count.updated=$($countEvents.Count) first='$(if ($countEvents.Count -gt 0) { $countEvents[0] } else { '-' })'"
    if ($Variant -eq 'PRE') {
        Add-Check 'b.prefix_no_invalidation' (($register.Count -eq 0) -and ($afterCommit.Count -eq 0)) "register=$($register.Count) afterCommit=$($afterCommit.Count)"
    } else {
        Add-Check 'b.postfix_invalidation_after_commit' (($register.Count -ge 1) -and ($afterCommit.Count -ge 1)) "register=$($register.Count) afterCommit=$($afterCommit.Count)"
    }
}

# =====================================================================
'BROLLBACK' {
    $key = & $cacheKeyFor $CountRollbackArticleId
    $countsBefore = Db-Counts $CountRollbackArticleId
    $warm = Warm-Detail $CountRollbackArticleId 'warm-detail'
    $resp = Post "/p13b/harness/score?id=$CountRollbackArticleId&view=5&like=2&comment=1&collect=1" 'update-score-rollback'
    $body = Body-Of $resp
    Save-Artifact 'update-score-rollback-call' $body
    Add-Check 'br.write_failed_as_expected' ($body -match 'controlled rollback of the behaviour count') "call body=$body"
    $countsAfter = Db-Counts $CountRollbackArticleId
    $result['counts_before'] = $countsBefore
    $result['counts_after'] = $countsAfter
    Add-Check 'br.db_counters_unchanged' ($countsAfter -eq $countsBefore) "before=$countsBefore after=$countsAfter"
    $keyExists = Redis-Exact @('EXISTS', $key)
    Add-Check 'br.cache_untouched' ($keyExists -eq '1') "cache key exists=$keyExists in db $RedisDb"
    $ev = @(Read-Events $Events $RunId)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $rollback = @($ev | Where-Object { $_ -match ' event=p13b\.controlled_rollback ' })
    $afterCommit = @($ev | Where-Object { $_ -match ' event=tx\.after_commit ' -and $_ -match 'updateScore:afterUpdate' })
    Add-Check 'br.rollback_event_recorded' ($rollback.Count -ge 1) "p13b.controlled_rollback=$($rollback.Count)"
    Add-Check 'br.no_commit_callback' ($afterCommit.Count -eq 0) "afterCommit(updateScore)=$($afterCommit.Count)"
}

# =====================================================================
'ZERO' {
    # B fix, real async entry: the target row does not exist, so the DAO update returns false. The worker
    # must NOT claim a successful write and must NOT register an invalidation; the residual message call
    # (kept on purpose, see the runtime report) is counted.
    $rowsBefore = Db-RowCount $MissingArticleId
    $statsBefore = Get-Stats
    $uploadsBefore = Json-Field $statsBefore 'html_uploads'
    $content = '[{"type":"text","value":"P13b-marker-zero"}]'
    $resp = Post "/p13b/harness/staticize?id=$MissingArticleId&content=$content" 'staticize-zero'
    $body = Body-Of $resp
    Save-Artifact 'staticize-zero-call' $body
    Add-Check 'z.caller_submitted' ($body -match '"submitted":\s*true') "call body=$body"

    $deadline = (Get-Date).AddMilliseconds($AsyncWaitMs)
    $skippedSeen = $false
    while ((Get-Date) -lt $deadline) {
        $ev = @(Read-EventsForArticle $Events $MissingArticleId $runStartMs)
        if ($ev | Where-Object { $_ -match ' event=static_url\.update_skipped ' }) { $skippedSeen = $true; break }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 800
    $rowsAfter = Db-RowCount $MissingArticleId
    $uploadsAfter = Json-Field (Get-Stats) 'html_uploads'
    $result['rows_before'] = $rowsBefore
    $result['rows_after'] = $rowsAfter
    $result['uploads_before'] = $uploadsBefore
    $result['uploads_after'] = $uploadsAfter
    Add-Check 'z.worker_reported_zero_rows' $skippedSeen 'the worker emitted static_url.update_skipped (reason=zero_rows) for the missing article'
    Add-Check 'z.no_rows_created_or_updated' (($rowsAfter.article -eq '0') -and ($rowsAfter.content -eq '0') -and ($rowsAfter.config -eq '0')) `
        "ap_article=$($rowsBefore.article)->$($rowsAfter.article) content=$($rowsBefore.content)->$($rowsAfter.content) config=$($rowsBefore.config)->$($rowsAfter.config)"
    Add-Check 'z.template_still_ran' ([int]$uploadsAfter -gt [int]$uploadsBefore) "html uploads $uploadsBefore -> $uploadsAfter (real template + upload path executed)"

    $ev = @(Read-EventsForArticle $Events $MissingArticleId $runStartMs)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $updated = @($ev | Where-Object { $_ -match ' event=static_url\.updated ' })
    $registers = @($ev | Where-Object { $_ -match ' event=cache\.evict\.register ' })
    $afterCommit = @($ev | Where-Object { $_ -match ' event=tx\.after_commit ' })
    $deletes = @($ev | Where-Object { $_ -match ' event=cache\.evict\.ok ' })
    $sends = @($ev | Where-Object { $_ -match ' event=static_url\.update_skipped ' })
    $result['updated_events'] = $updated.Count
    $result['register_events'] = $registers.Count
    $result['after_commit_events'] = $afterCommit.Count
    $result['delete_events'] = $deletes.Count
    Add-Check 'z.no_success_event' ($updated.Count -eq 0) "static_url.updated=$($updated.Count) (must be 0 on zero rows)"
    Add-Check 'z.no_invalidation_registered' ($registers.Count -eq 0) "cache.evict.register=$($registers.Count)"
    Add-Check 'z.no_commit_callback_and_no_delete' (($afterCommit.Count -eq 0) -and ($deletes.Count -eq 0)) `
        "afterCommit=$($afterCommit.Count) evict.ok=$($deletes.Count)"
    Add-Check 'z.skipped_event_present' ($sends.Count -ge 1) "static_url.update_skipped=$($sends.Count)"
}

# =====================================================================
'N' {
    # dto.id = null through the real create branch. The ID fixture only answers the marked title, so the
    # create request must carry exactly the marker title.
    $key = & $cacheKeyFor $CreateArticleId
    $rowsBefore = Db-RowCount $CreateArticleId
    $result['rows_before'] = $rowsBefore
    Add-Check 'n.target_id_absent_before' (($rowsBefore.article -eq '0') -and ($rowsBefore.content -eq '0')) `
        "ap_article=$($rowsBefore.article) ap_article_content=$($rowsBefore.content) for $CreateArticleId"

    $pre = Warm-Detail $CreateArticleId 'pre-placeholder'
    Add-Check 'n.placeholder_written' (($pre.code -eq '1002') -and ((Redis-Exact @('EXISTS', $key)) -eq '1')) `
        "code=$($pre.code) cache exists=$(Redis-Exact @('EXISTS', $key))"

    $contentEncoded = '%5B%7B%22type%22%3A%22text%22%2C%22value%22%3A%22P13b-marker%22%7D%5D'
    $resp = Post "/p13b/harness/create?title=$([uri]::EscapeDataString($MarkerTitle))&content=$contentEncoded" 'create'
    $body = Body-Of $resp
    Save-Artifact 'create-call' $body
    $result['create_body'] = $body
    Add-Check 'n.dto_id_was_null' ($body -match '"dtoIdWasNull":\s*true') "create call body=$body"
    Add-Check 'n.fixture_produced_target_id' ($body -match ('"data":\s*' + "$CreateArticleId")) "create returned data=$(Json-Field $body 'data')"
    $rowsAfter = Db-RowCount $CreateArticleId
    $result['rows_after'] = $rowsAfter
    Add-Check 'n.three_tables_inserted_with_fixed_id' `
        (($rowsAfter.article -eq '1') -and ($rowsAfter.content -eq '1') -and ([int]$rowsAfter.config -eq ([int]$rowsBefore.config + 1))) `
        "ap_article=$($rowsBefore.article)->$($rowsAfter.article) content=$($rowsBefore.content)->$($rowsAfter.content) config=$($rowsBefore.config)->$($rowsAfter.config)"

    $keyExists = Redis-Exact @('EXISTS', $key)
    $result['key_exists_after_create'] = $keyExists
    Add-Check 'n.null_placeholder_invalidated_after_commit' ($keyExists -eq '0') "cache key exists=$keyExists right after the committed create"

    $after = Read-Detail $CreateArticleId 'read-after-create'
    $result['after_code'] = $after.code
    $result['after_title'] = $after.title
    Add-Check 'n.detail_is_200_after_create' ($after.code -eq '200') "code=$($after.code) title=$($after.title)"
    Add-Check 'n.id_is_exact_string' ($after.body -match [regex]::Escape('"id":"' + "$CreateArticleId" + '"')) 'created article id serialised as an exact JSON string'

    $ev = @(Read-Events $Events $RunId)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    $reg = @($ev | Where-Object { $_ -match ' event=cache\.evict\.register ' -and $_ -match 'saveArticle:create' })
    $afterCommit = @($ev | Where-Object { $_ -match ' event=tx\.after_commit ' -and $_ -match 'saveArticle:create' })
    Add-Check 'n.create_invalidation_after_commit' (($reg.Count -ge 1) -and ($afterCommit.Count -ge 1)) `
        "register=$($reg.Count) afterCommit=$($afterCommit.Count)"
}

# =====================================================================
'REG' {
    # Minimal regression on the update branch: one commit and one controlled rollback.
    $key = & $cacheKeyFor $RegArticleId
    $warm = Warm-Detail $RegArticleId 'warm-detail'
    $resp = Post "/p13b/harness/save?id=$RegArticleId&title=P13b-reg-commit&content=reg-content" 'reg-commit'
    $body = Body-Of $resp
    Save-Artifact 'reg-commit-call' $body
    Add-Check 'reg.commit_update_ok' ($body -match '"code":\s*200') "call body=$body"
    Add-Check 'reg.commit_cache_invalidated' ((Redis-Exact @('EXISTS', $key)) -eq '0') "cache key exists=$(Redis-Exact @('EXISTS', $key)) after the committed update"
    $after = Read-Detail $RegArticleId 'read-after-commit'
    Add-Check 'reg.commit_detail_new_title' ($after.title -eq 'P13b-reg-commit') "detail title='$($after.title)'"
    $cold = $after.body
    $hot = Body-Of (Get- "/api/v1/article/detail/$RegArticleId" 'reg-hot')
    Save-Artifact 'reg-hot' $hot
    Add-Check 'reg.cold_hot_byte_identical' ($cold -ceq $hot) "len_cold=$($cold.Length) len_hot=$($hot.Length)"
    Add-Check 'reg.big_id_exact_string' ($hot -match [regex]::Escape('"id":"' + "$RegArticleId" + '"')) 'big id serialised as an exact JSON string'
    $missing = Body-Of (Get- "/api/v1/article/detail/9007199254760000" 'reg-missing')
    Add-Check 'reg.missing_id_1002' ((Detail-Code $missing) -eq '1002') "code=$(Detail-Code $missing)"
    Redis-Exact @('DEL', (& $cacheKeyFor 9007199254760000)) | Out-Null

    $keyR = & $cacheKeyFor $RegRollbackArticleId
    $titleBefore = Sql "SELECT title FROM $Database.ap_article WHERE id=$RegRollbackArticleId;"
    $warmR = Warm-Detail $RegRollbackArticleId 'warm-rollback'
    $respR = Post "/p13b/harness/save?id=$RegRollbackArticleId&title=P13b-reg-rollback&content=reg-content" 'reg-rollback'
    $bodyR = Body-Of $respR
    Save-Artifact 'reg-rollback-call' $bodyR
    Add-Check 'reg.rollback_failed_as_expected' ($bodyR -match 'controlled rollback') "call body=$bodyR"
    $titleAfter = Sql "SELECT title FROM $Database.ap_article WHERE id=$RegRollbackArticleId;"
    Add-Check 'reg.rollback_title_unchanged' ($titleAfter -eq $titleBefore) "title before='$titleBefore' after='$titleAfter'"
    # NOTE: the same saveArticle call also triggers the async static_url worker, which has its own
    # transaction and may legitimately commit and delete the cache. The rollback property is therefore
    # asserted on the saveArticle transaction itself.
    $evR = @(Read-EventsForArticle $Events $RegRollbackArticleId $runStartMs)
    $saveAfterCommit = @($evR | Where-Object { $_ -match ' event=tx\.after_commit ' -and $_ -match 'saveArticle:update' })
    Add-Check 'reg.rollback_no_save_after_commit' ($saveAfterCommit.Count -eq 0) "afterCommit(saveArticle:update)=$($saveAfterCommit.Count) (the rolled-back transaction must not run the invalidation)"
    Add-Check 'reg.rollback_no_save_delete' ((@($evR | Where-Object { $_ -match ' event=cache\.evict\.ok ' -and $_ -match 'saveArticle:update:afterCommit' })).Count -eq 0) 'no delete with phase=saveArticle:update:afterCommit for the rolled-back id'

    $ev = @(Read-Events $Events $RunId)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
}

default { throw "unknown scenario: $Scenario" }
}

$client.Dispose()
$counts = Get-RunCheckCounts $script:run
$result['checks'] = $script:run.checks
$result['counts'] = $counts
$result['finished_utc'] = (Now-Utc)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'scenario-result.json') -Text ($result | ConvertTo-Json -Depth 6)
$script:run.checks | ForEach-Object { "{0,-48} {1,-6} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
