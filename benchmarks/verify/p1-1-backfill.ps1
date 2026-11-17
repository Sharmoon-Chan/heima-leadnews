# P1.1 backfill / write-path experiment (ASCII only: PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
#
# Question the card asks (translated from the card, kept ASCII-only): "an inserted or backfilled
# article with the same id must clear the null placeholder; list every write path that can change
# the detail response, including the static_url update, and say which invalidations are covered."
#
# This script produces evidence for three distinct cases, each with its own files:
#
#   B1  null placeholder exists, then the row is inserted *around* the service (direct SQL)
#       -> expected: still 1002 while the placeholder lives  => NOT covered by the code
#   B2  same state, then the row is written *through* the service (POST /api/v1/article/save)
#       -> expected: 200 immediately afterwards             => covered (evictArticleDetailCache)
#   B3  static_url is updated asynchronously by the static-page path (ArticleFreemarkerServiceImpl
#       uses apArticleService.update(...) and never touches the detail cache)
#       -> expected: cached copy keeps the old staticUrl until TTL => NOT covered by the code
#
# Only the exact test key is deleted; the course database is never written to.
param(
    [string]$BaseUrl = 'http://127.0.0.1:51802',
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][long]$BackfillId,
    [string]$Mysql = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [string]$DbName = 'leadnews_article_p1',
    [int]$StaticUrlWaitSeconds = 8,
    [string]$ExperimentRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---- run directory protection (P1.1a): before any HTTP / Redis / SQL call ----
. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap {
    exit (Save-RunFailure -State $script:run -ErrorRecord $_)
}
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.1-backfill' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ backfill_id = $BackfillId; static_url_wait_seconds = $StaticUrlWaitSeconds; db = $DbName } `
        -Targets @("$BackfillId") -DataSet $DbName
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}
$sqlDir = Join-Path $OutDir 'sql'
New-Item -ItemType Directory -Path $sqlDir -ErrorAction Stop | Out-Null

# checks go through the shared guard so pass / fail / skipped stay separate
function Add-Check([string]$name, [bool]$ok, [string]$detail) {
    Add-RunCheck -State $script:run -Name $name -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $detail
}
function Now-Utc { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $inv) }
function Redis-Cli([string[]]$cmdArgs) {
    # NOTE: build the argument array in a variable first. Writing
    # `& $RedisCli @('-h',...) + $cmdArgs` makes "+" and $cmdArgs separate arguments,
    # which redis-cli reports as "unknown command '+'".
    $all = @('-h','127.0.0.1','-p','6379','-n','0') + $cmdArgs
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
# password via env var: avoids the "Using a password on the command line" warning, which
# PowerShell would otherwise surface as a NativeCommandError and abort the script.
if ([string]::IsNullOrWhiteSpace($env:MYSQL_PWD)) {
    throw 'Set MYSQL_PWD in the calling environment before running this local experiment.'
}
function Sql([string]$text, [string]$tag) {
    $out = & $Mysql '--host=127.0.0.1' '--port=3306' '--user=root' `
            '--default-character-set=utf8mb4' -N -B $DbName -e $text 2>$null
    $exit = $LASTEXITCODE
    Write-RunFileText -State $script:run -Path (Join-Path $sqlDir "$tag.txt") -Text (($out | Out-String).Trim())
    if ($exit -ne 0) { throw "sql failed (exit=$exit) tag=$tag" }
    return $out
}

Add-Type -AssemblyName System.Net.Http | Out-Null
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(30)

function Get-Detail([string]$tag, [long]$id) {
    $meta = [ordered]@{ step = $tag; url = "$BaseUrl/api/v1/article/detail/$id"; target_id = "$id"; at_utc = (Now-Utc) }
    $key = "article:detail:$id"
    $meta['redis_exists_before'] = Redis-Cli @('EXISTS', $key)
    $resp = $client.GetAsync("$BaseUrl/api/v1/article/detail/$id").GetAwaiter().GetResult()
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $meta['http_status'] = [int]$resp.StatusCode
    $meta['bytes'] = $bytes.Length
    $meta['redis_exists_after'] = Redis-Cli @('EXISTS', $key)
    $meta['redis_pttl_after_ms'] = Redis-Cli @('PTTL', $key)
    Write-RunFileBytes -State $script:run -Path (Join-Path $OutDir "$tag.body.json") -Bytes $bytes
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir "$tag.meta.json") -Text ($meta | ConvertTo-Json -Depth 4)
    Start-Sleep -Milliseconds 200
    return [pscustomobject]$meta
}
function Read-Body([string]$tag) {
    $p = Join-Path $OutDir "$tag.body.json"
    if (-not (Test-Path $p)) { return $null }
    return [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($p))
}
function Get-Code([string]$raw) {
    if ($null -eq $raw) { return 'MISSING' }
    $m = [regex]::Match($raw, '"code"\s*:\s*(-?\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'MISSING'
}

$key = "article:detail:$BackfillId"
$result = [ordered]@{ run_id = $RunId; scenario = 'BACKFILL'; backfill_id = "$BackfillId"; started_utc = (Now-Utc) }

# ---------- clean up any leftovers from a previous attempt ----------
Redis-Cli @('DEL', $key) | Out-Null
Sql "DELETE FROM ap_article_content WHERE article_id=$BackfillId; DELETE FROM ap_article WHERE id=$BackfillId;" '00-preclean' | Out-Null
$result['preclean_deleted_key'] = 'DEL issued on exact key'

# ---------- B0: the row does not exist -> null placeholder is written ----------
$b0 = Get-Detail 'b0-missing-before-insert' $BackfillId
$t0 = Read-Body 'b0-missing-before-insert'
Add-Check 'b0.biz_1002' ((Get-Code $t0) -eq '1002') "code=$(Get-Code $t0)"
Add-Check 'b0.null_placeholder_written' ($b0.redis_exists_after -eq '1') "exists=$($b0.redis_exists_after)"
$result['b0_placeholder_value'] = Redis-Cli @('GET', $key)

# ---------- B1: row inserted AROUND the service (direct SQL) ----------
$ins = Sql "INSERT INTO ap_article (id,title,author_id,author_name,channel_id,channel_name,layout,flag,labels,likes,collection,comment,views,created_time,publish_time,sync_status,origin,static_url) VALUES ($BackfillId,'P1.1 backfill title',1001,'p1a',1,'ch1',0,0,'p1',0,0,0,0,'2026-10-29 12:00:00','2026-10-29 12:00:00',0,0,NULL); INSERT INTO ap_article_content (id,article_id,content) VALUES ($BackfillId,$BackfillId,'P1.1 backfill body plain');" '01-insert-around-service'
$rowExists = Sql "SELECT COUNT(*) FROM ap_article WHERE id=$BackfillId;" '02-row-exists'
$result['b1_row_in_db'] = ($rowExists | Select-Object -First 1)
$b1 = Get-Detail 'b1-after-external-insert' $BackfillId
$t1 = Read-Body 'b1-after-external-insert'
Add-Check 'b1.row_really_in_db' (($rowExists | Select-Object -First 1) -eq '1') "count=$($rowExists | Select-Object -First 1)"
Add-Check 'b1.stale_null_still_returned' ((Get-Code $t1) -eq '1002') "code=$(Get-Code $t1) (placeholder not invalidated by an external write)"

# ---------- B2: row written THROUGH the service -> evict must clear the placeholder ----------
$dto = @{ id = $BackfillId; title = 'P1.1 backfill title v2'; content = '[{"type":"text","value":"P1.1 backfill body v2"}]' } | ConvertTo-Json -Compress
$body = [System.Text.Encoding]::UTF8.GetBytes($dto)
# New-Object with an array argument splats it; use the constructor-friendly StringContent instead
$content = New-Object System.Net.Http.StringContent (($dto), [System.Text.Encoding]::UTF8, 'application/json')
$content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json; charset=utf-8')
$saveResp = $client.PostAsync("$BaseUrl/api/v1/article/save", $content).GetAwaiter().GetResult()
$saveBody = $saveResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
$result['save_http_status'] = [int]$saveResp.StatusCode
$result['save_response'] = $saveBody
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'b2-save.response.json') -Text $saveBody
Add-Check 'b2.save_http_200' ([int]$saveResp.StatusCode -eq 200) "http=$([int]$saveResp.StatusCode) body=$saveBody"

$existsRightAfterSave = Redis-Cli @('EXISTS', $key)
$result['b2_key_exists_right_after_save'] = $existsRightAfterSave
Add-Check 'b2.placeholder_evicted_by_service' ($existsRightAfterSave -eq '0') "exists=$existsRightAfterSave right after POST /save"

$b2 = Get-Detail 'b2-after-service-write' $BackfillId
$t2 = Read-Body 'b2-after-service-write'
Add-Check 'b2.biz_200_after_service_write' ((Get-Code $t2) -eq '200') "code=$(Get-Code $t2)"
Add-Check 'b2.id_exact_string' ($t2 -match [regex]::Escape('"id":"' + $BackfillId + '"')) 'id as string literal'
Add-Check 'b2.updated_content_visible' ($t2 -match 'backfill body v2') 'new content visible right after the write'

# ---------- B3: static_url updated asynchronously, cache not invalidated ----------
$cachedBefore = Redis-Cli @('GET', $key)
$result['b3_cached_value_len_before_wait'] = $cachedBefore.Length
$cachedStaticBefore = if ($cachedBefore -match '"staticUrl"\s*:\s*("(?:[^"\\]|\\.)*"|null)') { $matches[1] } else { 'NO_FIELD' }
$result['b3_cached_static_url_before_wait'] = $cachedStaticBefore

Start-Sleep -Seconds $StaticUrlWaitSeconds

$dbStatic = Sql "SELECT IFNULL(static_url,'NULL') FROM ap_article WHERE id=$BackfillId;" '03-static-url-in-db'
$dbStaticVal = ($dbStatic | Select-Object -First 1)
$result['b3_db_static_url'] = $dbStaticVal

$cachedAfter = Redis-Cli @('GET', $key)
$cachedStaticAfter = if ($cachedAfter -match '"staticUrl"\s*:\s*("(?:[^"\\]|\\.)*"|null)') { $matches[1] } else { 'NO_FIELD' }
$result['b3_cached_static_url_after_wait'] = $cachedStaticAfter

$b3 = Get-Detail 'b3-after-static-url-updated' $BackfillId
$t3 = Read-Body 'b3-after-static-url-updated'
$apiStatic = if ($t3 -match '"staticUrl"\s*:\s*("(?:[^"\\]|\\.)*"|null)') { $matches[1] } else { 'NO_FIELD' }
$result['b3_api_static_url'] = $apiStatic

# The gap exists when DB has a real static_url but API/cache still serves the old value.
$dbHasUrl = ($dbStaticVal -ne 'NULL' -and $dbStaticVal -ne '' -and $dbStaticVal -ne $null)
$result['b3_db_has_static_url'] = $dbHasUrl
if ($dbHasUrl) {
    Add-Check 'b3.static_url_update_NOT_invalidated' ($apiStatic -ne $dbStaticVal) "db=$dbStaticVal api=$apiStatic (expected: cache still serves the stale value until TTL)"
} else {
    # NOT a pass: the asynchronous static-page path never completed, so nothing was verified here.
    Add-RunCheck -State $script:run -Name 'b3.static_url_not_written_by_async_path' -Status 'skipped' `
        -Detail "db still NULL after $StaticUrlWaitSeconds s; async static page did not complete (MinIO/template), so this path was not exercised. Not counted as a pass."
}

# ---------- B4: simulate the exact UPDATE that ArticleFreemarkerServiceImpl issues ----------
# The real async path failed this round (MinIO upload error), so static_url was never written
# through it. To still measure the *cache* behaviour of that write, issue the same statement the
# code issues (ArticleFreemarkerServiceImpl:79-80 -> apArticleService.update(set staticUrl)) and
# then read the detail API again. This is explicitly a SIMULATION of the write, not the freemarker run.
$simUrl = 'http://192.168.200.130:9000/leadnews/p1-sim.html'
Sql "UPDATE ap_article SET static_url='$simUrl' WHERE id=$BackfillId;" '04-simulate-static-url-update' | Out-Null
$dbStatic2 = (Sql "SELECT IFNULL(static_url,'NULL') FROM ap_article WHERE id=$BackfillId;" '05-static-url-after-sim' | Select-Object -First 1)
$result['b4_db_static_url'] = $dbStatic2

$cacheKeyExistsBeforeB4 = Redis-Cli @('EXISTS', $key)
$result['b4_cache_key_exists_before'] = $cacheKeyExistsBeforeB4
$b4 = Get-Detail 'b4-after-simulated-static-url-update' $BackfillId
$t4 = Read-Body 'b4-after-simulated-static-url-update'
$apiStatic4 = if ($t4 -match '"staticUrl"\s*:\s*("(?:[^"\\]|\\.)*"|null)') { $matches[1] } else { 'NO_FIELD' }
$result['b4_api_static_url'] = $apiStatic4

Add-Check 'b4.db_updated' ($dbStatic2 -eq $simUrl) "db=$dbStatic2"
Add-Check 'b4.cache_serves_stale_static_url' ($apiStatic4 -ne ('"' + $simUrl + '"')) "api=$apiStatic4 db=$dbStatic2 => the write path above does not invalidate the detail cache; stale until TTL"

$client.Dispose()
$counts = Get-RunCheckCounts $script:run
$result['checks'] = $script:run.checks
$result['counts'] = $counts
$result['total_checks'] = $counts.total
$result['passed'] = $counts.passed
$result['failed'] = $counts.failed
$result['skipped'] = $counts.skipped
$result['finished_utc'] = (Now-Utc)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'assertions.json') -Text ($result | ConvertTo-Json -Depth 6)
$script:run.checks | ForEach-Object { "{0,-42} {1,-8} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
