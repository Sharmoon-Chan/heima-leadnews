# P1.0 / EVID-001 evidence collector (ASCII only: PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
#
# What it does, per the fixed EVID-001 procedure:
#   1. records the fixed environment (base url, ids, exact cache keys, redis endpoint)
#   2. cold key: deletes ONLY the exact test key, records the DEL/EXISTS result
#   3. three sequential requests, each saved to its OWN files (status + headers + raw bytes)
#   4. asserts by RE-READING those files (never from in-memory values)
#   5. records exact-key redis state (EXISTS / PTTL / STRLEN) around the requests
#
# It does NOT parse the 19-digit id as a number anywhere: the id is checked with a
# literal substring match on the raw body, so JS float precision can never mask a defect.
#
# SQL attribution is NOT done here: the app logs one [DETAIL-METRIC] line per request with
# reqId + dbSelect, so per-request SQL is reconciled from the app log afterwards
# (see the P1.0 handoff for the counting rule).
param(
    [string]$BaseUrl = 'http://127.0.0.1:51802',
    [Parameter(Mandatory = $true)][long]$ExistingId,
    [Parameter(Mandatory = $true)][long]$MissingId,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$ExperimentRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [string]$RedisHost = '127.0.0.1',
    [int]$RedisPort = 6379,
    [int]$RedisDb = 0,
    [string]$CacheKeyPrefix = 'article:detail:',
    [string]$ExpectTitle = 'P1 article'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---- run directory protection (P1.1a): before any HTTP / Redis call ----
. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap {
    exit (Save-RunFailure -State $script:run -ErrorRecord $_)
}
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.0-evid001' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ existing_id = $ExistingId; missing_id = $MissingId; redis = "$RedisHost`:$RedisPort/db$RedisDb" } `
        -Targets @("$ExistingId", "$MissingId")
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

function Redis-Cli([string[]]$cmdArgs) {
    $all = @('-h', $RedisHost, '-p', "$RedisPort", '-n', "$RedisDb") + $cmdArgs
    $out = & $RedisCli @all 2>&1
    return ($out | Out-String).Trim()
}
function Get-UtcNow { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $inv) }

$existingKey = "$CacheKeyPrefix$ExistingId"
$missingKey = "$CacheKeyPrefix$MissingId"

# ---------- 1. fixed environment record ----------
$envRecord = [ordered]@{
    run_id              = $RunId
    started_at_utc      = (Get-UtcNow)
    base_url            = $BaseUrl
    endpoint            = '/api/v1/article/detail/{id}'
    existing_article_id = "$ExistingId"
    missing_article_id  = "$MissingId"
    existing_cache_key  = $existingKey
    missing_cache_key   = $missingKey
    redis_endpoint      = "$RedisHost`:$RedisPort db$RedisDb"
    redis_client        = $RedisCli
    id_above_2p53       = ($ExistingId -gt 9007199254740992)
    note                = 'only the two exact test keys are deleted; no KEYS/FLUSHDB is issued'
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'env.json') -Text ($envRecord | ConvertTo-Json -Depth 5)

# ---------- 2. cold key: delete only exact test keys ----------
$existingDel = Redis-Cli @('DEL', $existingKey)
$missingDel = Redis-Cli @('DEL', $missingKey)
$pre = [ordered]@{
    at_utc              = (Get-UtcNow)
    deleted_existing_key_reply = $existingDel
    deleted_missing_key_reply  = $missingDel
    existing_key_exists = Redis-Cli @('EXISTS', $existingKey)
    missing_key_exists  = Redis-Cli @('EXISTS', $missingKey)
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'redis-before.json') -Text ($pre | ConvertTo-Json -Depth 5)

# ---------- 3. three requests, each to its own file ----------
Add-Type -AssemblyName System.Net.Http | Out-Null
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(20)

$requests = @(
    @{ name = 'req1-existing-cold'; id = $ExistingId },
    @{ name = 'req2-existing-hot'; id = $ExistingId },
    @{ name = 'req3-missing'; id = $MissingId }
)

$metas = @()
foreach ($r in $requests) {
    $url = "$BaseUrl/api/v1/article/detail/$($r.id)"
    $meta = [ordered]@{
        request_name = $r.name
        url          = $url
        target_id    = "$($r.id)"
        started_utc  = (Get-UtcNow)
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $client.GetAsync($url).GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $sw.Stop()
        $meta['http_status'] = [int]$resp.StatusCode
        $meta['content_type'] = "$($resp.Content.Headers.ContentType)"
        $meta['content_length_header'] = "$($resp.Content.Headers.ContentLength)"
        $meta['bytes_written'] = $bytes.Length
        $meta['elapsed_ms'] = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
        Write-RunFileBytes -State $script:run -Path (Join-Path $OutDir "$($r.name).body.json") -Bytes $bytes
    } catch {
        $sw.Stop()
        $meta['http_status'] = -1
        $meta['error'] = "$($_.Exception.Message)"
        $meta['elapsed_ms'] = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
    }
    $meta['finished_utc'] = (Get-UtcNow)
    $meta['redis_exists_after'] = Redis-Cli @('EXISTS', $existingKey)
    $meta['redis_pttl_after'] = Redis-Cli @('PTTL', $existingKey)
    $meta['redis_missing_exists_after'] = Redis-Cli @('EXISTS', $missingKey)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir "$($r.name).meta.json") -Text ($meta | ConvertTo-Json -Depth 5)
    $metas += [pscustomobject]$meta
}
$client.Dispose()

# ---------- 4. assert by re-reading the saved files ----------
# checks go through the shared guard so pass / fail / skipped stay separate
function Add-Check([string]$name, [bool]$ok, [string]$detail) {
    Add-RunCheck -State $script:run -Name $name -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $detail
}

foreach ($m in $metas) {
    $bodyPath = Join-Path $OutDir "$($m.request_name).body.json"
    if (-not (Test-Path $bodyPath)) {
        Add-Check "$($m.request_name).file_exists" $false 'missing body file'
        continue
    }
    $raw = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($bodyPath))

    Add-Check "$($m.request_name).http_200" ($m.http_status -eq 200) "http=$($m.http_status)"

    # business code, read as text from the file (no numeric coercion of ids)
    $codeMatch = [regex]::Match($raw, '"code"\s*:\s*(-?\d+)')
    $code = if ($codeMatch.Success) { $codeMatch.Groups[1].Value } else { 'MISSING' }
    Add-Check "$($m.request_name).no_503" ($code -ne '503') "business code=$code"

    if ($m.request_name -like 'req3-*') {
        Add-Check "$($m.request_name).biz_code_1002" ($code -eq '1002') "business code=$code"
        Add-Check "$($m.request_name).data_null" ($raw -match '"data"\s*:\s*null') 'data should be null'
    } else {
        Add-Check "$($m.request_name).biz_code_200" ($code -eq '200') "business code=$code"
        # exact id as a STRING literal: this is the whole point of the 19-digit check
        $idLiteral = '"id":"' + $m.target_id + '"'
        Add-Check "$($m.request_name).id_exact_string" ($raw -match [regex]::Escape($idLiteral)) "looked for $idLiteral"
        Add-Check "$($m.request_name).id_not_bare_number" (-not ($raw -match ('"id"\s*:\s*' + [regex]::Escape($m.target_id)))) 'id must not appear as a JSON number'
        Add-Check "$($m.request_name).title_ok" ($raw -match [regex]::Escape($ExpectTitle)) "expected title contains '$ExpectTitle'"
        Add-Check "$($m.request_name).content_present" ($raw -match 'P1 synthetic article body') 'expected fixed body text'
    }
}

# cold/hot contract equality: compare the two existing responses field by field on the raw text
$b1p = Join-Path $OutDir 'req1-existing-cold.body.json'
$b2p = Join-Path $OutDir 'req2-existing-hot.body.json'
if ((Test-Path $b1p) -and (Test-Path $b2p)) {
    $t1 = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($b1p))
    $t2 = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($b2p))
    Add-Check 'contract.cold_hot_byte_identical' ($t1 -ceq $t2) "len_cold=$($t1.Length) len_hot=$($t2.Length)"
    # also compare the set of JSON field names, to catch null-vs-absent differences even if bytes matched
    $f1 = ([regex]::Matches($t1, '"([A-Za-z_][A-Za-z0-9_]*)"\s*:') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','
    $f2 = ([regex]::Matches($t2, '"([A-Za-z_][A-Za-z0-9_]*)"\s*:') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ','
    Add-Check 'contract.cold_hot_same_fields' ($f1 -ceq $f2) "fields_cold=$f1 | fields_hot=$f2"
}

# ---------- 5. redis exact-key state after ----------
$post = [ordered]@{
    at_utc                      = (Get-UtcNow)
    existing_key_exists         = Redis-Cli @('EXISTS', $existingKey)
    existing_key_pttl_ms        = Redis-Cli @('PTTL', $existingKey)
    existing_key_type           = Redis-Cli @('TYPE', $existingKey)
    existing_key_len            = Redis-Cli @('STRLEN', $existingKey)
    missing_key_exists          = Redis-Cli @('EXISTS', $missingKey)
    missing_key_pttl_ms         = Redis-Cli @('PTTL', $missingKey)
    missing_key_value           = Redis-Cli @('GET', $missingKey)
    existing_key_head_120       = (Redis-Cli @('GET', $existingKey))
}
if ($post.existing_key_head_120.Length -gt 120) { $post.existing_key_head_120 = $post.existing_key_head_120.Substring(0, 120) }
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'redis-after.json') -Text ($post | ConvertTo-Json -Depth 5)

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id          = $RunId
    finished_at_utc = (Get-UtcNow)
    total_checks    = $counts.total
    passed          = $counts.passed
    failed          = $counts.failed
    skipped         = $counts.skipped
    checks          = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'assertions.json') -Text ($result | ConvertTo-Json -Depth 6)
$script:run.checks | Where-Object { $_.status -eq 'fail' } | ForEach-Object { "FAILED: $($_.check) :: $($_.detail)" }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
