# P1.1 cache functional experiments (ASCII only: PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
#
# Covers, each as its own scenario with its own run_id and output folder:
#   HOT      normal article: cold read -> hot hit -> (short) TTL expiry -> refill
#   NULL     missing id: first miss -> NULL hit -> (short) null TTL expiry -> miss again
#   JITTER   TTL spread, i.e. the key really gets expire + rand(0, jitter) instead of a fixed value
#   BACKFILL null placeholder then the row appears through a write path; covers both
#            "evicted by the service write path" and "written around the service"
#
# Ground rules taken from the card and the P1.0 review:
#   * ids are 19 digits: compared as STRING literals, never parsed as numbers
#   * each request writes its own files; assertions read those files back
#   * only exact test keys are touched (DEL on the precise key), no KEYS/FLUSHDB
#   * shortened TTLs are functional evidence only; they never stand in for the production TTL
param(
    [string]$BaseUrl = 'http://127.0.0.1:51802',
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Scenario,
    [long]$ArticleId = 0,
    [long]$MissingId = 0,
    [string]$JitterIdsCsv = '',
    [int]$ExpireSeconds = 15,
    [int]$NullExpireSeconds = 8,
    [int]$JitterSeconds = 10,
    [long]$NewIdBase = 9007199254770000,
    [int]$NewIdCount = 200,
    [int]$FirstBatchSize = 20,
    [int]$StepDelayMs = 150,
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [string]$ExperimentRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [string]$ExpectTitle = 'P1 article'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---- run directory protection (P1.1a): must run before any HTTP / Redis call ----
. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap {
    exit (Save-RunFailure -State $script:run -ErrorRecord $_)
}
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.1-cache-func' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ scenario = $Scenario; article_id = $ArticleId; missing_id = $MissingId;
                       expire_seconds = $ExpireSeconds; null_expire_seconds = $NullExpireSeconds;
                       jitter_seconds = $JitterSeconds; new_id_base = $NewIdBase; new_id_count = $NewIdCount }
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

function Redis-Cli([string[]]$cmdArgs) {
    $all = @('-h','127.0.0.1','-p','6379','-n','0') + $cmdArgs
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Now-Utc { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $inv) }

Add-Type -AssemblyName System.Net.Http | Out-Null
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(20)

# checks now go through the shared guard so that pass / fail / skipped are counted separately
function Add-Check([string]$name, [bool]$ok, [string]$detail) {
    Add-RunCheck -State $script:run -Name $name -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $detail
}
function Add-Skipped([string]$name, [string]$detail) {
    Add-RunCheck -State $script:run -Name $name -Status 'skipped' -Detail $detail
}

# one request = its own body file + meta file; assertions later read the file back
function Invoke-Step {
    param([string]$name, [long]$id)
    $url = "$BaseUrl/api/v1/article/detail/$id"
    $key = "article:detail:$id"
    # BEFORE the request: proves whether the key was already expired (expiry evidence must be pre-request)
    $meta = [ordered]@{ step = $name; url = $url; target_id = "$id"; started_utc = (Now-Utc) }
    $meta['redis_exists_before'] = Redis-Cli @('EXISTS', $key)
    $meta['redis_pttl_before_ms'] = Redis-Cli @('PTTL', $key)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $client.GetAsync($url).GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $sw.Stop()
        $meta['http_status'] = [int]$resp.StatusCode
        $meta['bytes'] = $bytes.Length
        Write-RunFileBytes -State $script:run -Path (Join-Path $OutDir "$name.body.json") -Bytes $bytes
    } catch {
        $sw.Stop()
        $meta['http_status'] = -1
        $meta['error'] = "$($_.Exception.Message)"
    }
    $meta['elapsed_ms'] = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
    $meta['finished_utc'] = (Now-Utc)
    $meta['redis_exists'] = Redis-Cli @('EXISTS', $key)
    $meta['redis_pttl_ms'] = Redis-Cli @('PTTL', $key)
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir "$name.meta.json") -Text ($meta | ConvertTo-Json -Depth 4)
    if ($StepDelayMs -gt 0) { Start-Sleep -Milliseconds $StepDelayMs }
    return [pscustomobject]$meta
}

# read a saved body back from disk; returns text
function Read-Body([string]$name) {
    $p = Join-Path $OutDir "$name.body.json"
    if (-not (Test-Path $p)) { return $null }
    return [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($p))
}
function Get-BizCode([string]$raw) {
    if ($null -eq $raw) { return 'MISSING' }
    $m = [regex]::Match($raw, '"code"\s*:\s*(-?\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'MISSING'
}

$result = [ordered]@{ run_id = $RunId; scenario = $Scenario; started_utc = (Now-Utc) }

switch ($Scenario) {

  'HOT' {
    $key = "article:detail:$ArticleId"
    $delReply = Redis-Cli @('DEL', $key)
    $result['deleted_key_reply'] = $delReply

    $s1 = Invoke-Step 'hot-1-cold' $ArticleId
    $s2 = Invoke-Step 'hot-2-hit'  $ArticleId
    $ttl = [int]$s2.redis_pttl_ms
    # wait past expire + a small margin
    $waitMs = ($ExpireSeconds + 2) * 1000
    $result['wait_ms_before_expiry_probe'] = $waitMs
    Start-Sleep -Milliseconds $waitMs
    $s3 = Invoke-Step 'hot-3-after-expiry' $ArticleId
    $s4 = Invoke-Step 'hot-4-refilled-hit' $ArticleId

    $b1 = Read-Body 'hot-1-cold'; $b2 = Read-Body 'hot-2-hit'
    $b3 = Read-Body 'hot-3-after-expiry'; $b4 = Read-Body 'hot-4-refilled-hit'

    # one shared evaluator: HTTP status + business code + exact string id, parsed from the saved file
    foreach ($pair in @(@('hot-1-cold', $s1, $b1), @('hot-2-hit', $s2, $b2), @('hot-3-after-expiry', $s3, $b3), @('hot-4-refilled-hit', $s4, $b4))) {
        $r = Test-DetailResponse -HttpStatus $pair[1].http_status -BodyText $pair[2] -ExpectId "$ArticleId" -ExpectKind 'existing'
        Add-RunCheck -State $script:run -Name "$($pair[0]).response" -Status $r.status -Detail $r.reason
    }

    Add-Check 'hot1.title' ($b1 -match [regex]::Escape($ExpectTitle)) "contains $ExpectTitle"
    Add-Check 'hot1.wrote_cache' ($s1.redis_exists -eq '1') "exists=$($s1.redis_exists) pttl=$($s1.redis_pttl_ms)"
    Add-Check 'hot2.byte_identical_to_cold' ($b1 -ceq $b2) 'cold vs hot body'
    Add-Check 'hot2.ttl_shrank' ($ttl -gt 0 -and $ttl -le $ExpireSeconds * 1000) "pttl=$ttl (expire=$($ExpireSeconds)s, jitter=0)"
    Add-Check 'hot3.key_expired_before_request' ($s3.redis_exists_before -eq '0') "exists_before=$($s3.redis_exists_before) pttl_before=$($s3.redis_pttl_before_ms)"
    Add-Check 'hot3.content_same_after_refill' ($b1 -ceq $b3) 'cold vs after-expiry body'
    Add-Check 'hot3.refilled_cache' ($s3.redis_exists -eq '1') "exists=$($s3.redis_exists)"
    Add-Check 'hot4.hit_after_refill' ($s4.redis_exists -eq '1') "exists=$($s4.redis_exists)"
    $result['steps'] = @($s1,$s2,$s3,$s4)
  }

  'NULL' {
    $key = "article:detail:$MissingId"
    $delReply = Redis-Cli @('DEL', $key)
    $result['deleted_key_reply'] = $delReply

    $s1 = Invoke-Step 'null-1-first-miss' $MissingId
    $s2 = Invoke-Step 'null-2-null-hit'   $MissingId
    $result['null_ttl_sample_ms'] = $s2.redis_pttl_ms
    Start-Sleep -Milliseconds (($NullExpireSeconds + 2) * 1000)
    $s3 = Invoke-Step 'null-3-after-expiry' $MissingId
    $s4 = Invoke-Step 'null-4-null-hit-again' $MissingId

    $b1 = Read-Body 'null-1-first-miss'; $b2 = Read-Body 'null-2-null-hit'
    $b3 = Read-Body 'null-3-after-expiry'; $b4 = Read-Body 'null-4-null-hit-again'

    foreach ($pair in @(@('null-1-first-miss', $s1, $b1), @('null-2-null-hit', $s2, $b2), @('null-3-after-expiry', $s3, $b3), @('null-4-null-hit-again', $s4, $b4))) {
        $r = Test-DetailResponse -HttpStatus $pair[1].http_status -BodyText $pair[2] -ExpectId "$MissingId" -ExpectKind 'missing'
        Add-RunCheck -State $script:run -Name "$($pair[0]).response" -Status $r.status -Detail $r.reason
    }

    Add-Check 'null1.placeholder_written' ($s1.redis_exists -eq '1') "exists=$($s1.redis_exists)"
    Add-Check 'null1.placeholder_ttl' ([int]$s1.redis_pttl_ms -gt 0 -and [int]$s1.redis_pttl_ms -le $NullExpireSeconds * 1000) "pttl=$($s1.redis_pttl_ms) (null-expire=$($NullExpireSeconds)s)"
    Add-Check 'null2.byte_identical' ($b1 -ceq $b2) 'first miss vs null hit'
    Add-Check 'null2.still_cached' ($s2.redis_exists -eq '1') "exists=$($s2.redis_exists)"
    Add-Check 'null3.placeholder_expired_before_request' ($s3.redis_exists_before -eq '0') "exists_before=$($s3.redis_exists_before) pttl_before=$($s3.redis_pttl_before_ms)"
    Add-Check 'null3.rewritten' ($s3.redis_exists -eq '1') "exists=$($s3.redis_exists)"
    $result['steps'] = @($s1,$s2,$s3,$s4)
  }

  'JITTER' {
    # For each id: cold read (writes cache with TTL = expire + rand(0,jitter)), then read PTTL once.
    $samples = @()
    foreach ($id in ($JitterIdsCsv -split ',' | Where-Object { $_.Trim() -ne '' })) {
        $key = "article:detail:$id"
        Redis-Cli @('DEL', $key) | Out-Null
        $s = Invoke-Step ("jitter-$id") $id
        $pttl = [int]$s.redis_pttl_ms
        $samples += [pscustomobject]@{ id = "$id"; http = $s.http_status; pttl_ms = $pttl; ttl_s = [math]::Round($pttl / 1000.0, 1) }
    }
    $ttls = $samples | ForEach-Object { $_.ttl_s }
    $min = ($ttls | Measure-Object -Minimum).Minimum
    $max = ($ttls | Measure-Object -Maximum).Maximum
    $distinct = ($ttls | Sort-Object -Unique).Count
    $result['samples'] = $samples
    $result['min_ttl_s'] = $min
    $result['max_ttl_s'] = $max
    $result['distinct_ttl_values'] = $distinct

    # every saved jitter body must also pass the shared response check (not just HTTP 200)
    $jitterFail = 0
    foreach ($id in ($JitterIdsCsv -split ',' | Where-Object { $_.Trim() -ne '' })) {
        $body = Read-Body ("jitter-" + $id)
        $metaPath = Join-Path $OutDir ("jitter-" + $id + '.meta.json')
        $hs = if (Test-Path $metaPath) { (Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json).http_status } else { -1 }
        $r = Test-DetailResponse -HttpStatus $hs -BodyText $body -ExpectId "$id" -ExpectKind 'existing'
        if ($r.status -ne 'pass') { $jitterFail++; Add-RunCheck -State $script:run -Name ("jitter." + $id + '.response') -Status 'fail' -Detail $r.reason }
    }
    Add-RunCheck -State $script:run -Name 'jitter.all_responses_valid' -Status $(if ($jitterFail -eq 0) { 'pass' } else { 'fail' }) -Detail "bad=$jitterFail of $(($JitterIdsCsv -split ',' | Where-Object { $_.Trim() -ne '' }).Count)"
    Add-Check 'jitter.min_ge_expire' ($min -ge ($ExpireSeconds - 1)) "min=$min expire=$ExpireSeconds"
    Add-Check 'jitter.max_lt_expire_plus_jitter' ($max -le ($ExpireSeconds + $JitterSeconds)) "max=$max bound=$($ExpireSeconds + $JitterSeconds)"
    Add-Check 'jitter.not_a_single_fixed_value' ($distinct -gt 1) "distinct=$distinct"
  }

  'RANDOMNEW' {
    # Does the null cache protect ids that were never requested before? No: each first touch still
    # costs a DB round trip. Two disjoint batches make that explicit.
    $batchA = @(); $batchB = @()
    # batch A: small, so the repeat pass still falls inside the null-placeholder TTL
    for ($i = 0; $i -lt $FirstBatchSize; $i++) { $batchA += [string]($NewIdBase + $i) }
    # batch B: larger, every id is requested exactly once (never-seen traffic)
    for ($i = 0; $i -lt $NewIdCount; $i++) { $batchB += [string]($NewIdBase + 10000 + $i) }
    $firstPass = @(); $secondPass = @()
    foreach ($id in $batchA) {
        $s = Invoke-Step ("random-new-1-$id") ([long]$id)
        $firstPass += [pscustomobject]@{ id = $id; http = $s.http_status; exists_after = $s.redis_exists }
    }
    foreach ($id in $batchA) {
        $s = Invoke-Step ("random-new-2-$id") ([long]$id)
        $secondPass += [pscustomobject]@{ id = $id; http = $s.http_status; exists_before = $s.redis_exists_before }
    }
    $freshNeverSeen = @()
    foreach ($id in $batchB) {
        $s = Invoke-Step ("random-new-3-$id") ([long]$id)
        $freshNeverSeen += [pscustomobject]@{ id = $id; http = $s.http_status }
    }
    $result['batch_a_size'] = $batchA.Count
    $result['note_repeat_window'] = 'batch A is kept small so that the repeat pass stays inside the null-placeholder TTL'
    $result['batch_b_size'] = $batchB.Count
    $result['first_pass_all_200'] = (($firstPass | Where-Object { $_.http -ne 200 }).Count -eq 0)
    # HTTP 200 alone is not success: every saved body must also be a valid 1002/null response
    $badResp = 0
    foreach ($id in $batchA) {
        foreach ($prefix in 'random-new-1-', 'random-new-2-') {
            $body = Read-Body ($prefix + $id)
            $mp = Join-Path $OutDir ($prefix + $id + '.meta.json')
            $hs = if (Test-Path $mp) { (Get-Content $mp -Raw -Encoding UTF8 | ConvertFrom-Json).http_status } else { -1 }
            $r = Test-DetailResponse -HttpStatus $hs -BodyText $body -ExpectId "$id" -ExpectKind 'missing'
            if ($r.status -ne 'pass') { $badResp++ }
        }
    }
    foreach ($id in $batchB) {
        $body = Read-Body ('random-new-3-' + $id)
        $mp = Join-Path $OutDir ('random-new-3-' + $id + '.meta.json')
        $hs = if (Test-Path $mp) { (Get-Content $mp -Raw -Encoding UTF8 | ConvertFrom-Json).http_status } else { -1 }
        $r = Test-DetailResponse -HttpStatus $hs -BodyText $body -ExpectId "$id" -ExpectKind 'missing'
        if ($r.status -ne 'pass') { $badResp++ }
    }
    Add-RunCheck -State $script:run -Name 'randomnew.all_responses_valid_1002' -Status $(if ($badResp -eq 0) { 'pass' } else { 'fail' }) -Detail "bad=$badResp of $($firstPass.Count * 2 + $freshNeverSeen.Count)"
    Add-Check 'randomnew.first_pass_all_placeholders_written' (($firstPass | Where-Object { $_.exists_after -ne '1' }).Count -eq 0) "n=$($firstPass.Count)"
    Add-Check 'randomnew.second_pass_all_served_by_cache' (($secondPass | Where-Object { $_.exists_before -ne '1' }).Count -eq 0) "n=$($secondPass.Count) (placeholder present before the 2nd request => served from cache)"
    $result['note'] = 'first touch of each new id still hits the DB; the null cache only helps REPEATED requests for the same missing id'
  }

  default { throw "unknown scenario: $Scenario" }
}

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
$script:run.checks | Where-Object { $_.status -eq 'fail' } | ForEach-Object { "FAILED: $($_.check) :: $($_.detail)" }
$script:run.checks | Where-Object { $_.status -eq 'skipped' } | ForEach-Object { "SKIPPED: $($_.check) :: $($_.detail)" }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
