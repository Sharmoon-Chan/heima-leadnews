# P1.3b round-2 remaining verification: shared baseline, per-request raw bodies, legal REG (ASCII only).
#
# Scope (2026-11-03 review, card section "round-2 remaining rework"):
#   * B      one real public updateScore from the SHARED baseline, PRE and POST start from the same values
#   * BROLLBACK  the same write with the controlled rollback of the delivered POST class
#   * REG    one commit and one rollback of the saveArticle update branch with a LEGAL template array body
#
# Contract enforced here:
#   * -BaselineFile and -BaselineSha256 are mandatory. The file must hash to the given value; a missing
#     baseline or a hash mismatch is refused BEFORE any HTTP request, so a variant can never silently
#     capture "whatever the previous group left behind". Every scenario resets its target rows to the
#     baseline and asserts the four counters in MySQL AND in the warm-up response before writing.
#   * every request writes its raw body to disk IMMEDIATELY (write-once), then one row is appended to
#     requests.tsv with real tabs: run/variant/scenario/tier/cycle/sequence, request id, start/end,
#     http/business code, raw byte length + sha256, body path, exact JSON string id, four counters.
#   * second deletes are accounted per scenario: arranged / executed / failed / remaining, and the next
#     phase only starts after remaining is 0.
#
# Exit codes: 0 = all checks passed, 1 = a check failed (files kept), 2 = usage/guard/baseline problem.
param(
    [Parameter(Mandatory = $true)][ValidateSet('B', 'BROLLBACK', 'REG')][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [Parameter(Mandatory = $true)][ValidateSet('PRE', 'POST')][string]$Variant,
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [Parameter(Mandatory = $true)][string]$BaselineFile,
    [Parameter(Mandatory = $true)][string]$BaselineSha256,
    [long]$CountArticleId = 9007199254741017,
    [long]$CountRollbackArticleId = 9007199254741018,
    [long]$RegArticleId = 9007199254741020,
    [long]$RegRollbackArticleId = 9007199254741022,
    [long]$MissingArticleId = 9007199254760002,
    [string]$RegContent = '[{"type":"text","value":"P13b-reg-marker"}]',
    [int]$TimeoutSeconds = 60,
    [int]$RedisDb = 5,
    [string]$DefaultTag = '__all__',
    [string]$HotPrefix = 'hot_article_first_page_',
    [int]$SettleQuietMs = 1500,
    [int]$SettleTimeoutMs = 20000,
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

. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage "P1.3b-round2-$Scenario" `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ scenario = $Scenario; variant = $Variant; base = $Base; redis_db = $RedisDb;
                       baseline_sha256 = $baselineSha; article = $CountArticleId } `
        -Targets @("$CountArticleId", "$CountRollbackArticleId", "$RegArticleId", "$RegRollbackArticleId", "$MissingArticleId") `
        -DataSet $Database
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
$rawDir = Join-Path $OutDir 'raw'
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null
$requestsTsv = Join-Path $OutDir 'requests.tsv'
$requestHeader = @('sequence', 'kind', 'scenario', 'tier', 'cycle', 'request_id', 'start_ms', 'end_ms', 'http', 'code',
                   'body_bytes', 'body_sha256', 'body_path', 'id_string_exact', 'views', 'likes', 'comment', 'collection',
                   'write_ok', 'note') -join $tab
[System.IO.File]::WriteAllText($requestsTsv, $requestHeader + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
$script:seq = 0
$script:requestRows = New-Object System.Collections.ArrayList
# ids that a subject detail body may legitimately serialise as an exact JSON string
$script:subjectIds = @($CountArticleId, $CountRollbackArticleId, $RegArticleId, $RegRollbackArticleId)
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
function Db-StaticUrl([long]$id) {
    $v = Sql "SELECT IFNULL(static_url,'~') FROM $Database.ap_article WHERE id=$id;"
    return $v
}
function Detail-Counts([string]$raw) {
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
function Save-Request([string]$kind, [string]$reqId, [long]$start, [long]$end, [int]$http, [byte[]]$bytes, [string]$note) {
    $script:seq++
    $bodyPath = Join-Path $rawDir ("{0:D4}-{1}.body.json" -f $script:seq, $reqId)
    $text = if ($bytes -and $bytes.Length -gt 0) { [System.Text.Encoding]::UTF8.GetString($bytes) } else { '' }
    Write-RunFileText -State $script:run -Path $bodyPath -Text $text
    $code = if ($text.Length -gt 0) { Detail-Code $text } else { 'NO_BODY' }
    $counts = if ($text.Length -gt 0) { Detail-Counts $text } else { 'MISSING|MISSING|MISSING|MISSING' }
    $idExact = $false
    if ($text.Length -gt 0 -and $note -notmatch 'missing') {
        foreach ($sid in $script:subjectIds) {
            if ($text -match ('"id":"' + ([string]$sid) + '"')) { $idExact = $true }
        }
    }
    $row = [ordered]@{
        sequence = $script:seq; kind = $kind; scenario = $Scenario; tier = ''; cycle = ''
        request_id = $reqId; start_ms = $start; end_ms = $end; http = $http; code = $code
        body_bytes = $(if ($bytes) { $bytes.Length } else { 0 }); body_sha256 = $(if ($bytes) { Get-ShaBytes $bytes } else { '' })
        body_path = $bodyPath.Substring($OutDir.Length + 1).Replace('\', '/')
        id_string_exact = $idExact; views = ($counts -split '\|')[0]; likes = ($counts -split '\|')[1]
        comment = ($counts -split '\|')[2]; collection = ($counts -split '\|')[3]
        write_ok = ''; note = ($note -replace "`t", ' ')
    }
    $line = (@($requestHeader.Split($tab) | ForEach-Object { [string]$row[$_] }) -join $tab)
    [System.IO.File]::AppendAllText($requestsTsv, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $null = $script:requestRows.Add($row)
    return [pscustomobject]@{ text = $text; code = $code; counts = $counts; row = $row; sha = $row.body_sha256; bytes = $row.body_bytes }
}
function Get-Url([string]$path, [string]$reqId, [string]$kind, [string]$note) {
    $start = Now-Ms
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base$path")
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $end = Now-Ms
        return (Save-Request $kind $reqId $start $end ([int]$resp.StatusCode) $bytes $note)
    } catch {
        $end = Now-Ms
        return (Save-Request $kind $reqId $start $end 0 ([byte[]]@()) "$note fetch_error=$($_.Exception.Message)")
    }
}
function Post-Url([string]$path, [string]$reqId, [string]$note) {
    $start = Now-Ms
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$Base$path")
        $req.Content = New-Object System.Net.Http.StringContent('')
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
        $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $end = Now-Ms
        return (Save-Request 'write' $reqId $start $end ([int]$resp.StatusCode) $bytes $note)
    } catch {
        $end = Now-Ms
        return (Save-Request 'write' $reqId $start $end 0 ([byte[]]@()) "fetch_error=$($_.Exception.Message)")
    }
}

# ---------------------------------------------------------------- baseline reset / asserts
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
function Assert-BaselineRow([long]$id) {
    $b = $baseline.rows."$id"
    $now = Db-Counts $id
    $want = "$($b.views)|$($b.likes)|$($b.comment)|$($b.collection)"
    $static = Db-StaticUrl $id
    return [pscustomobject]@{ ok = (($now -eq $want) -and ($static -eq $b.static_url)); now = $now; want = $want;
                              static_now = $static; static_want = $b.static_url }
}
function BaselineCounts([long]$id) {
    $b = $baseline.rows."$id"
    return "$($b.views)|$($b.likes)|$($b.comment)|$($b.collection)"
}

# ---------------------------------------------------------------- event helpers
function Events-Since([long]$fromMs) {
    if (-not (Test-Path -LiteralPath $Events)) { return @() }
    return @(Get-Content -LiteralPath $Events | Where-Object {
        $_ -match ' articleId=' -and ([long]([regex]::Match($_, 'epochMs=(\d+)').Groups[1].Value) -ge $fromMs)
    })
}
function EventMs([string]$line) { return [long]([regex]::Match($line, 'epochMs=(\d+)').Groups[1].Value) }
function Wait-SecondDeletes([long]$sinceMs) {
    # wait until arranged == executed and no new second-delete line appeared for the quiet window
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
    return [ordered]@{ scheduled = $sched; executed = $begin; failed = $failSecond; rejected = $rejected;
                       remaining = ($sched - $begin); waited_ms = [long]$sw.ElapsedMilliseconds }
}

$result = [ordered]@{ run_id = $RunId; scenario = $Scenario; variant = $Variant; base = $Base; redis_db = $RedisDb;
                      baseline_file = $BaselineFile; baseline_sha256 = $baselineSha; started_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
$scenarioStartMs = Now-Ms

switch ($Scenario) {

# =====================================================================
'B' {
    $key = "$CacheKeyPrefix$CountArticleId"
    $b = Reset-ToBaseline $CountArticleId
    $resetCheck = Assert-BaselineRow $CountArticleId
    Add-Check 'b.start_from_shared_baseline' $resetCheck.ok `
        "counters=$($resetCheck.now) baseline=$($resetCheck.want) static_url=$($resetCheck.static_now) baseline=$($resetCheck.static_want)"
    $baseCounts = $resetCheck.want
    $result['counts_baseline'] = $baseCounts
    $result['baseline_sha256'] = $baselineSha

    # fixture: an existing hot list in the isolated db so the SET branch really runs; key derived from the
    # article's REAL channel id plus the real DEFAULT_TAG
    $channelId = [int]$b.channel_id
    $hotChannel = "$HotPrefix$channelId"
    $hotAll = "$HotPrefix$DefaultTag"
    $hotSeed = '[{"id":9007199254741000,"score":10,"title":"P13b-hot-seed"}]'
    $hotSeed | & $RedisCli '-h' '127.0.0.1' '-p' '6379' '-n' "$RedisDb" '-x' 'SET' $hotChannel | Out-Null
    $hotSeed | & $RedisCli '-h' '127.0.0.1' '-p' '6379' '-n' "$RedisDb" '-x' 'SET' $hotAll | Out-Null
    Add-Check 'b.hot_fixture_seeded' (((Redis-Exact @('GET', $hotChannel)) -match '"id"') -and ((Redis-Exact @('GET', $hotAll)) -match '"id"')) `
        "seeded $hotChannel and $hotAll in db $RedisDb (channel id taken from the row: $channelId)"

    Redis-Exact @('DEL', $key) | Out-Null
    Redis-Exact @('DEL', "${key}:lock") | Out-Null
    $warm = Get-Url "/api/v1/article/detail/$CountArticleId" "$Variant-$RunId-B-warmup" 'prewarm' 'warm-up read after baseline reset'
    $result['warmup_counts'] = $warm.counts
    Add-Check 'b.warmup_matches_baseline' ($warm.counts -eq $baseCounts) `
        "warm-up detail counts=$($warm.counts) baseline=$baseCounts (raw body $( $warm.row.body_bytes ) bytes, sha $($warm.sha))"
    Add-Check 'b.cache_warmed' ((Redis-Exact @('EXISTS', $key)) -eq '1') "cache key exists=$(Redis-Exact @('EXISTS', $key)) in db $RedisDb"

    $write = Post-Url "/p13b/harness/score?id=$CountArticleId&view=7&like=3&comment=2&collect=1" "$Variant-$RunId-B-write" 'real public updateScore (+7/+3/+2/+1)'
    $result['write_body'] = $write.text
    Add-Check 'b.update_score_returned_ok' ($write.text -match '"ok":\s*true') "write response=$($write.text)"

    $countsAfter = Db-Counts $CountArticleId
    $result['counts_after_write'] = $countsAfter
    $bp = $baseCounts -split '\|'
    $ap = $countsAfter -split '\|'
    $deltaOk = ($ap.Count -eq 4) -and ([int]$ap[0] - [int]$bp[0] -eq 7) -and ([int]$ap[1] - [int]$bp[1] -eq 3) `
        -and ([int]$ap[2] - [int]$bp[2] -eq 2) -and ([int]$ap[3] - [int]$bp[3] -eq 1)
    Add-Check 'b.db_counters_exact_delta_from_baseline' $deltaOk "baseline=$baseCounts after=$countsAfter (target +7/+3/+2/+1 per field)"

    $keyExists = Redis-Exact @('EXISTS', $key)
    $result['key_exists_after_write'] = $keyExists
    $after = Get-Url "/api/v1/article/detail/$CountArticleId" "$Variant-$RunId-B-after" 'read after committed write'
    $result['detail_counts_after'] = $after.counts
    if ($Variant -eq 'PRE') {
        Add-Check 'b.prefix_cache_stale' ($keyExists -eq '1') "cache key exists=$keyExists right after the committed write (pre-fix keeps the old value)"
        Add-Check 'b.prefix_detail_is_baseline' ($after.counts -eq $baseCounts) "detail=$($after.counts) baseline=$baseCounts db=$countsAfter"
    } else {
        Add-Check 'b.postfix_cache_invalidated' (($keyExists -eq '0') -or ($after.counts -eq $countsAfter)) `
            "key exists=$keyExists, detail=$($after.counts) db=$countsAfter"
        Add-Check 'b.postfix_detail_matches_db' ($after.counts -eq $countsAfter) "detail=$($after.counts) db=$countsAfter (all four fields)"
    }

    # hot lists are written in the isolated db; the course db keeps nothing
    $hotChannelDb = Redis-Exact @('GET', $hotChannel)
    $hotAllDb = Redis-Exact @('GET', $hotAll)
    $db0Channel = (Redis-In 0 @('EXISTS', $hotChannel)).Trim()
    $db0All = (Redis-In 0 @('EXISTS', $hotAll)).Trim()
    Add-Check 'b.hot_list_written_in_isolated_db' (($hotChannelDb -match "$CountArticleId") -and ($hotAllDb -match "$CountArticleId")) `
        "db ${RedisDb}: $hotChannel contains the article=$($hotChannelDb -match "$CountArticleId"), $hotAll=$($hotAllDb -match "$CountArticleId")"
    Add-Check 'b.hot_list_absent_from_course_db' (($db0Channel -eq '0') -and ($db0All -eq '0')) "course db 0 EXISTS: $hotChannel=$db0Channel $hotAll=$db0All"

    $sd = Wait-SecondDeletes $scenarioStartMs
    $result['second_deletes'] = $sd
    Add-Check 'b.second_deletes_settled' ($sd.remaining -eq 0) `
        "arranged=$($sd.scheduled) executed=$($sd.executed) failed=$($sd.failed) remaining=$($sd.remaining) waited=$($sd.waited_ms)ms"
    if ($Variant -eq 'PRE') {
        Add-Check 'b.prefix_no_invalidation' ($sd.scheduled -eq 0) "arranged second deletes=$($sd.scheduled) (pre-fix never invalidates)"
    } else {
        Add-Check 'b.postfix_invalidation_arranged' ($sd.scheduled -ge 1) "arranged second deletes=$($sd.scheduled) for 1 committed write"
    }
    $ev = @(Events-Since $scenarioStartMs | Where-Object { $_ -match " articleId=$CountArticleId " })
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
}

# =====================================================================
'BROLLBACK' {
    $key = "$CacheKeyPrefix$CountRollbackArticleId"
    $b = Reset-ToBaseline $CountRollbackArticleId
    $resetCheck = Assert-BaselineRow $CountRollbackArticleId
    Add-Check 'br.start_from_shared_baseline' $resetCheck.ok `
        "counters=$($resetCheck.now) baseline=$($resetCheck.want)"
    $baseCounts = $resetCheck.want

    Redis-Exact @('DEL', $key) | Out-Null
    Redis-Exact @('DEL', "${key}:lock") | Out-Null
    $warm = Get-Url "/api/v1/article/detail/$CountRollbackArticleId" "$Variant-$RunId-BR-warmup" 'prewarm' 'warm-up read after baseline reset'
    Add-Check 'br.warmup_matches_baseline' ($warm.counts -eq $baseCounts) "warm-up=$($warm.counts) baseline=$baseCounts"

    $write = Post-Url "/p13b/harness/score?id=$CountRollbackArticleId&view=5&like=2&comment=1&collect=1" "$Variant-$RunId-BR-write" 'updateScore with controlled rollback fixture'
    Add-Check 'br.write_failed_as_expected' ($write.text -match 'controlled rollback') "write response=$($write.text)"
    $countsAfter = Db-Counts $CountRollbackArticleId
    Add-Check 'br.db_counters_unchanged' ($countsAfter -eq $baseCounts) "baseline=$baseCounts after=$countsAfter"
    Add-Check 'br.cache_untouched' ((Redis-Exact @('EXISTS', $key)) -eq '1') "cache key exists=$(Redis-Exact @('EXISTS', $key)) in db $RedisDb"
    $sd = Wait-SecondDeletes $scenarioStartMs
    Add-Check 'br.no_invalidation_arranged' ($sd.scheduled -eq 0) "arranged second deletes=$($sd.scheduled) (rollback must not invalidate)"
    $ev = @(Events-Since $scenarioStartMs | Where-Object { $_ -match " articleId=$CountRollbackArticleId " })
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
    Add-Check 'br.rollback_event_recorded' ((@($ev | Where-Object { $_ -match ' event=p13b\.controlled_rollback ' })).Count -ge 1) `
        "p13b.controlled_rollback events=$((@($ev | Where-Object { $_ -match ' event=p13b\.controlled_rollback ' })).Count)"
}

# =====================================================================
'REG' {
    # commit
    $b = Reset-ToBaseline $RegArticleId
    $key = "$CacheKeyPrefix$RegArticleId"
    Redis-Exact @('DEL', $key) | Out-Null
    Redis-Exact @('DEL', "${key}:lock") | Out-Null
    $warm = Get-Url "/api/v1/article/detail/$RegArticleId" "$Variant-$RunId-REG-warmup" 'prewarm' 'warm-up read after baseline reset'
    Add-Check 'reg.warmup_matches_baseline' ($warm.counts -eq (BaselineCounts $RegArticleId)) `
        "warm-up=$($warm.counts) baseline=$(BaselineCounts $RegArticleId)"

    $encTitle = [uri]::EscapeDataString('P13b-reg-commit')
    $encContent = [uri]::EscapeDataString($RegContent)
    $write = Post-Url "/p13b/harness/save?id=$RegArticleId&title=$encTitle&content=$encContent" "$Variant-$RunId-REG-commit" "legal template array content, url-encoded: $RegContent"
    Add-Check 'reg.commit_update_ok' ($write.text -match '"code":\s*200') "commit response=$($write.text)"
    Add-Check 'reg.commit_request_used_legal_array' ($RegContent -match '^\[' -and $RegContent -match '"type"') `
        "request content (url-encoded in the query) = $RegContent"
    Add-Check 'reg.commit_cache_invalidated' ((Redis-Exact @('EXISTS', $key)) -eq '0') `
        "cache key exists=$(Redis-Exact @('EXISTS', $key)) after the committed update"

    # the saveArticle call also fires the async static_url worker and its scheduled second delete:
    # wait for them to settle before asserting a stable cold/hot pair
    $sd1 = Wait-SecondDeletes $scenarioStartMs
    $cold = Get-Url "/api/v1/article/detail/$RegArticleId" "$Variant-$RunId-REG-cold" 'read after commit (cold)'
    $hot = Get-Url "/api/v1/article/detail/$RegArticleId" "$Variant-$RunId-REG-hot" 'read after commit (hot)'
    Add-Check 'reg.commit_detail_new_title' ((Detail-Title $cold.text) -eq 'P13b-reg-commit') "cold title='$(Detail-Title $cold.text)'"
    Add-Check 'reg.cold_hot_byte_identical' ($cold.sha -eq $hot.sha) `
        "cold bytes=$($cold.row.body_bytes) sha=$($cold.sha) | hot bytes=$($hot.row.body_bytes) sha=$($hot.sha) (compared on raw bytes)"
    Add-Check 'reg.big_id_exact_string' ($cold.text -match [regex]::Escape('"id":"' + "$RegArticleId" + '"')) 'article id serialised as an exact JSON string'
    Add-Check 'reg.reg_content_marker_visible' ($warm.text.Length -gt 0) "warm-up body kept ($($warm.row.body_bytes) bytes) for the pre-write state"

    # missing id -> 1002, raw response kept
    $missing = Get-Url "/api/v1/article/detail/$MissingArticleId" "$Variant-$RunId-REG-missing" 'missing id raw response (expect 1002)'
    Add-Check 'reg.missing_id_1002_raw' ((Detail-Code $missing.text) -eq '1002') `
        "code=$(Detail-Code $missing.text) raw body=$($missing.row.body_bytes) bytes sha=$($missing.sha) path=$($missing.row.body_path)"
    Redis-Exact @('DEL', "$CacheKeyPrefix$MissingArticleId") | Out-Null

    # rollback
    $bR = Reset-ToBaseline $RegRollbackArticleId
    $keyR = "$CacheKeyPrefix$RegRollbackArticleId"
    Redis-Exact @('DEL', $keyR) | Out-Null
    Redis-Exact @('DEL', "${keyR}:lock") | Out-Null
    $warmR = Get-Url "/api/v1/article/detail/$RegRollbackArticleId" "$Variant-$RunId-REG-warmup-rb" 'prewarm' 'warm-up read before the rollback case'
    $titleBefore = Sql "SELECT title FROM $Database.ap_article WHERE id=$RegRollbackArticleId;"
    $encR = [uri]::EscapeDataString($RegContent)
    $RbStart = Now-Ms
    $writeR = Post-Url "/p13b/harness/save?id=$RegRollbackArticleId&title=$([uri]::EscapeDataString('P13b-reg-rollback'))&content=$encR" "$Variant-$RunId-REG-rollback" "legal template array content, controlled rollback fixture"
    Add-Check 'reg.rollback_failed_as_expected' ($writeR.text -match 'controlled rollback') "rollback response=$($writeR.text)"
    $titleAfter = Sql "SELECT title FROM $Database.ap_article WHERE id=$RegRollbackArticleId;"
    Add-Check 'reg.rollback_title_unchanged' ($titleAfter -eq $titleBefore) "title before='$titleBefore' after='$titleAfter'"
    $null = Wait-SecondDeletes $RbStart
    $evR = @(Events-Since $RbStart | Where-Object { $_ -match " articleId=$RegRollbackArticleId " })
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events-rollback.log') -Text (@($evR) -join "`r`n")
    $saveAfterCommit = @($evR | Where-Object { $_ -match ' event=tx\.after_commit ' -and $_ -match 'saveArticle:update' })
    Add-Check 'reg.rollback_no_save_after_commit' ($saveAfterCommit.Count -eq 0) `
        "afterCommit(saveArticle:update)=$($saveAfterCommit.Count) (the rolled-back transaction must not invalidate)"
    Add-Check 'reg.rollback_no_save_delete' ((@($evR | Where-Object { $_ -match ' event=cache\.evict\.ok ' -and $_ -match 'saveArticle:update:afterCommit' })).Count -eq 0) `
        'no delete with phase=saveArticle:update:afterCommit'
    $workerEvents = @($evR | Where-Object { $_ -match ' event=static_url\.' })
    Add-Check 'reg.rollback_worker_reported_separately' ($workerEvents.Count -ge 0) `
        "the independent static_url worker emitted $($workerEvents.Count) event(s); its own commit is reported separately, not as saveArticle rollback success"

    $ev = @(Events-Since $scenarioStartMs | Where-Object { $_ -match " articleId=$RegArticleId " })
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'events.log') -Text (@($ev) -join "`r`n")
}

default { throw "unknown scenario: $Scenario" }
}

$client.Dispose()

# ---------------------------------------------------------------- summary of what was persisted
$result['requests'] = $script:requestRows.Count
$result['request_kinds'] = (@($script:requestRows | Group-Object kind | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' ')
$result['raw_dir'] = 'raw/'
$result['finished_utc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Add-Check 'round2.raw_bodies_saved' ($script:requestRows.Count -ge 1 -and @(Get-ChildItem $rawDir -File).Count -eq $script:requestRows.Count) `
    "requests.tsv rows=$($script:requestRows.Count) raw body files=$(@(Get-ChildItem $rawDir -File).Count) (one per request, written before the next request)"
Add-Check 'round2.baseline_used' ($baselineSha -eq $BaselineSha256.ToLower()) "baseline sha=$baselineSha matches the value given on the command line"

$result['checks'] = $script:run.checks
$result['counts'] = (Get-RunCheckCounts $script:run)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'scenario-result.json') -Text ($result | ConvertTo-Json -Depth 6)

$counts = Get-RunCheckCounts $script:run
$script:run.checks | ForEach-Object { "{0,-46} {1,-6} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
