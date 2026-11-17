# P1.2 synchronized cold burst collector, round 2 (ASCII only; PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
#
# Changes from round 1 (P1.2 first review R3/R4):
#   * concurrency intervals are keyed by pid+attemptId, because attemptId alone restarts at 1 in every
#     JVM; two instances would otherwise collide and the peak would be wrong
#   * the simulated delay and the real DAO call are counted as separate intervals
#     (rebuild.* covers delay+DAO, db.* covers only the DAO call)
#   * the run records which code variant it hit, so the pairing driver can prove the compare is
#     by code version, not by scenario
#
# It does not decide anything by itself: it records numbers plus per-request correctness, and the
# paired comparison is made from the run files.
#
# Exit codes: 0 = every check passed, 1 = a check failed or an unexpected error (files kept),
#             2 = usage/guard problem (nothing was executed).
param(
    [string]$BaseUrl = 'http://127.0.0.1:51802',
    [Parameter(Mandatory = $true)][long]$ArticleId,
    [Parameter(Mandatory = $true)][int]$Concurrency,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$ExperimentRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261030-P1.2-rework',
    [int]$Requests = 0,
    [int]$TimeoutSeconds = 30,
    [string]$Label = '',
    [string]$Variant = '',
    [string]$InstanceManifest = '',
    [string]$EventsFile = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261030-P1.2/events/main-events.log',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [string]$CacheKeyPrefix = 'article:detail:',
    [string]$ExpectedBizCode = '200',
    [int]$LateGraceMs = 2000,
    [int]$LeadMs = 4000,
    [int]$ArrivalSpreadLimitMs = 250
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
if ($Requests -le 0) { $Requests = $Concurrency }

. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.2-coldburst' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ article_id = $ArticleId; concurrency = $Concurrency; requests = $Requests;
                       label = $Label; variant = $Variant; base_url = $BaseUrl;
                       timeout_seconds = $TimeoutSeconds; lead_ms = $LeadMs;
                       arrival_spread_limit_ms = $ArrivalSpreadLimitMs } `
        -Targets @("$ArticleId")
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

$cacheKey = "$CacheKeyPrefix$ArticleId"
$lockKey = "$cacheKey`:lock"

function Redis-Exact([string[]]$cmdArgs) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', '0') + $cmdArgs
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Now-Utc { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $inv) }

# ---------- which code version is behind this port? ----------
$instance = $null
if (-not [string]::IsNullOrWhiteSpace($InstanceManifest) -and (Test-Path -LiteralPath $InstanceManifest)) {
    $instance = Get-Content -LiteralPath $InstanceManifest -Raw -Encoding UTF8 | ConvertFrom-Json
}
$instanceInfo = [ordered]@{
    manifest          = $InstanceManifest
    tag               = if ($instance) { $instance.tag } else { '' }
    pid               = if ($instance) { $instance.pid } else { $null }
    port              = if ($instance) { $instance.port } else { $null }
    variant_name      = if ($instance) { $instance.variant_name } else { '' }
    variant_classes   = if ($instance) { $instance.variant_classes } else { '' }
    variant_sha256    = if ($instance) { $instance.variant_sha256 } else { '' }
    probe_config_sha256 = if ($instance) { $instance.probe_config_sha256 } else { '' }
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'instance.json') -Text ($instanceInfo | ConvertTo-Json -Depth 4)

# ---------- 1. cold state ----------
$delCache = Redis-Exact @('DEL', $cacheKey)
$delLock = Redis-Exact @('DEL', $lockKey)
$coldState = [ordered]@{
    at_utc              = (Now-Utc)
    cache_key           = $cacheKey
    lock_key            = $lockKey
    del_cache_reply     = $delCache
    del_lock_reply      = $delLock
    cache_exists_before = Redis-Exact @('EXISTS', $cacheKey)
    cache_pttl_before   = Redis-Exact @('PTTL', $cacheKey)
    lock_exists_before  = Redis-Exact @('EXISTS', $lockKey)
    note                = 'only the exact detail/lock keys of this test article are deleted; no KEYS/FLUSHDB'
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'cold-state.json') -Text ($coldState | ConvertTo-Json -Depth 4)

# ---------- 2. synchronized burst ----------
$startAt = [DateTime]::UtcNow.AddMilliseconds($LeadMs)
$startTicks = $startAt.Ticks

$worker = {
    param($Client, $BaseUrl, $ArticleId, $Index, $StartTicks, $OutDir, $RunId, $Inv)

    $requestId = 'w{0:d3}' -f $Index
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$BaseUrl/api/v1/article/detail/$ArticleId")
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $requestId)

    while ([DateTime]::UtcNow.Ticks -lt $StartTicks) { Start-Sleep -Milliseconds 1 }
    $firedTicks = [DateTime]::UtcNow.Ticks
    $firedLateMs = [math]::Round((($firedTicks - $StartTicks) / 10000.0), 3)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = -1; $body = ''; $err = ''
    try {
        $resp = $Client.SendAsync($req).GetAwaiter().GetResult()
        $status = [int]$resp.StatusCode
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } catch {
        $err = $_.Exception.GetType().Name + ':' + $_.Exception.Message
    }
    $sw.Stop()

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $bodyPath = Join-Path $OutDir ("{0}.body.json" -f $requestId)
    if (Test-Path -LiteralPath $bodyPath) { throw "refusing to overwrite existing body file: $bodyPath" }
    [System.IO.File]::WriteAllBytes($bodyPath, $bytes)

    $meta = [ordered]@{
        request_id    = $requestId
        worker_index  = $Index
        url           = "$BaseUrl/api/v1/article/detail/$ArticleId"
        started_utc   = ([DateTime]($firedTicks)).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $Inv)
        fired_late_ms = $firedLateMs
        http_status   = $status
        bytes         = $bytes.Length
        latency_ms    = [math]::Round($sw.Elapsed.TotalMilliseconds, 3)
        error         = $err
    }
    return [pscustomobject]$meta
}

[System.Net.ServicePointManager]::DefaultConnectionLimit = 200
[System.Net.ServicePointManager]::Expect100Continue = $false
[System.Net.ServicePointManager]::UseNagleAlgorithm = $false
Add-Type -AssemblyName System.Net.Http | Out-Null
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.MaxConnectionsPerServer = 200
$handler.UseProxy = $false
$sharedClient = New-Object System.Net.Http.HttpClient($handler)
$sharedClient.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

$pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
$pool.Open()
$handles = @()
for ($i = 1; $i -le $Requests; $i++) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($worker).AddArgument($sharedClient).AddArgument($BaseUrl).AddArgument($ArticleId).AddArgument($i).
        AddArgument($startTicks).AddArgument($OutDir).AddArgument($RunId).AddArgument($inv)
    $handles += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Index = $i }
}
Write-Host ("burst released: variant={0} requests={1} concurrency={2} start_utc={3}" -f $Variant, $Requests, $Concurrency, $startAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))

$metas = @()
foreach ($h in $handles) {
    $out = $h.PS.EndInvoke($h.Handle)
    $h.PS.Dispose()
    foreach ($m in $out) { if ($m) { $metas += $m } }
}
[void]$pool.Close()
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'requests-meta.json') -Text (($metas | ConvertTo-Json -Depth 4))

# ---------- 3. wait for the service side to settle, then read the event stream ----------
$settleDeadline = (Get-Date).AddSeconds(30)
do {
    Start-Sleep -Milliseconds 500
    $inflight = 0
    if (Test-Path -LiteralPath $EventsFile) {
        $tail = Get-Content -LiteralPath $EventsFile -Tail 600
        $enters = @($tail | Where-Object { $_ -match " runId=$([regex]::Escape($RunId)) " -and $_ -match ' event=rebuild\.begin ' })
        $exits = @($tail | Where-Object { $_ -match " runId=$([regex]::Escape($RunId)) " -and $_ -match ' event=rebuild\.exit ' })
        $inflight = $enters.Count - $exits.Count
    }
} while ($inflight -gt 0 -and (Get-Date) -lt $settleDeadline)

$runEvents = @()
if (Test-Path -LiteralPath $EventsFile) {
    $runEvents = @(Get-Content -LiteralPath $EventsFile | Where-Object { $_ -match " runId=$([regex]::Escape($RunId)) " })
}
$eventsCopy = Join-Path $OutDir 'app-events.log'
Set-Content -LiteralPath $eventsCopy -Value @($runEvents) -Encoding UTF8

function Get-Field([string]$line, [string]$name) {
    $m = [regex]::Match($line, "(?:^|\s)$name=([^\s]+)")
    return $(if ($m.Success) { $m.Groups[1].Value } else { '' })
}

$dbEnters = @(); $dbExits = @{}; $rebuildBegins = @(); $rebuildExits = @{}
$lockAcquired = @(); $lockFail = 0; $lockLate = 0; $cacheHits = 0; $waits = @{}
$releases = @(); $interrupts = 0; $ioErrors = @(); $faultInjected = 0
foreach ($line in $runEvents) {
    $ev = Get-Field $line 'event'
    $evPid = Get-Field $line 'pid'   # NOT $pid: that name is a read-only automatic variable
    $att = Get-Field $line 'attemptId'
    $key = "$evPid/$att"
    switch ($ev) {
        'db.enter' {
            $dbEnters += [pscustomobject]@{
                key = $key; pid = $evPid; attemptId = $att
                epochMs = [long](Get-Field $line 'epochMs')
                thread  = (Get-Field $line 'thread')
            }
        }
        'db.exit' { $dbExits[$key] = [long](Get-Field $line 'epochMs') }
        'rebuild.begin' {
            $rebuildBegins += [pscustomobject]@{ key = $key; epochMs = [long](Get-Field $line 'epochMs'); delayMs = (Get-Field $line 'simulatedDelayMs') }
        }
        'rebuild.exit' { $rebuildExits[$key] = [long](Get-Field $line 'epochMs') }
        'lock.acquired' { $lockAcquired += $line }
        'lock.fail' { $lockFail++ }
        'lock.late_acquire' { $lockLate++ }
        'cache.read' { if ((Get-Field $line 'hit') -eq 'true') { $cacheHits++ } }
        'wait.end' {
            $o = Get-Field $line 'outcome'
            if (-not $waits.ContainsKey($o)) { $waits[$o] = 0 }
            $waits[$o]++
        }
        'release' { $releases += $line }
        'interrupt_caught' { $interrupts++ }
        'io.error' { $ioErrors += $line }
        'fault.redis.injected' { $faultInjected++ }
    }
}

function Get-Peak($begins, $exitMap) {
    if ($begins.Count -eq 0) { return 0 }
    $now = [long]((Get-Date).ToUniversalTime().Subtract([datetime]'1970-01-01')).TotalMilliseconds
    $edge = @()
    foreach ($b in $begins) {
        $end = if ($exitMap.ContainsKey($b.key)) { $exitMap[$b.key] } else { $now }
        $edge += [pscustomobject]@{ t = $b.epochMs; d = 1 }
        $edge += [pscustomobject]@{ t = $end + 1; d = -1 }
    }
    $peak = 0; $cur = 0
    foreach ($e in ($edge | Sort-Object t, d)) { $cur += $e.d; if ($cur -gt $peak) { $peak = $cur } }
    return $peak
}
$peakDb = Get-Peak $dbEnters $dbExits
$peakRebuild = Get-Peak $rebuildBegins $rebuildExits
$pids = @($dbEnters | ForEach-Object { $_.pid } | Sort-Object -Unique)

# ---------- 4. assertions read the saved files back ----------
function Add-Check([string]$name, [bool]$ok, [string]$detail) {
    Add-RunCheck -State $script:run -Name $name -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $detail
}
function Read-Body([string]$name) {
    $p = Join-Path $OutDir "$name.body.json"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($p))
}

$biz = @{}; $ok200 = 0; $rejected503 = 0; $bad = 0; $timeouts = 0; $nulls = 0
foreach ($m in $metas) {
    if ($m.error -ne '') {
        if ($m.error -match 'TaskCanceled|Timeout|timeout') { $timeouts++ } else { $bad++ }
        continue
    }
    $body = Read-Body $m.request_id
    $code = 'MISSING'
    if ($body) {
        $mm = [regex]::Match($body, '"code"\s*:\s*(-?\d+)')
        if ($mm.Success) { $code = $mm.Groups[1].Value }
    }
    if (-not $biz.ContainsKey($code)) { $biz[$code] = 0 }
    $biz[$code]++
    if ($code -eq $ExpectedBizCode) {
        $r = Test-DetailResponse -HttpStatus $m.http_status -BodyText $body -ExpectId "$ArticleId" -ExpectKind 'existing'
        if ($r.status -eq 'pass') { $ok200++ } else { $bad++; Write-Host ("  FAIL {0}: {1}" -f $m.request_id, $r.reason) }
    } elseif ($code -eq '503') {
        $rejected503++
    } elseif ($code -eq '1002') {
        $nulls++
    } else {
        $bad++
    }
}

Add-Check 'burst.cold_before_request' (($coldState.cache_exists_before -eq '0') -and ($coldState.cache_pttl_before -eq '-2')) "exists=$($coldState.cache_exists_before) pttl=$($coldState.cache_pttl_before)"
Add-Check 'burst.all_requests_answered' (($ok200 + $rejected503 + $bad + $timeouts) -eq $Requests) "ok=$ok200 rejected503=$rejected503 bad=$bad timeouts=$timeouts of $Requests"
Add-Check 'burst.no_unexpected_error' (($bad -eq 0) -and ($timeouts -eq 0)) "bad=$bad timeouts=$timeouts"
Add-Check 'burst.success_or_explicit_503' (($ok200 + $rejected503) -eq $Requests) "success=$ok200 explicit503=$rejected503"
Add-Check 'burst.no_null_response' ($nulls -eq 0) "1002 count=$nulls (this article exists)"

# synchronization evidence: a "burst" that is really a stagger must not be trusted
$lates = @($metas | Where-Object { $_.PSObject.Properties['fired_late_ms'] } | ForEach-Object { [double]$_.fired_late_ms } | Sort-Object)
$within25 = @($lates | Where-Object { $_ -le 25 }).Count
$arrivals = @($runEvents | Where-Object { $_ -match ' event=request\.start ' } | ForEach-Object { [long](([regex]::Match($_, 'epochMs=(\d+)')).Groups[1].Value) } | Sort-Object)
$arrivalSpreadMs = if ($arrivals.Count -ge 2) { $arrivals[-1] - $arrivals[0] } else { $null }
$syncStats = [ordered]@{
    lead_ms                 = $LeadMs
    workers                 = $metas.Count
    fired_within_25ms       = $within25
    fired_late_max_ms       = if ($lates.Count -gt 0) { $lates[-1] } else { $null }
    fired_late_p50_ms       = if ($lates.Count -gt 0) { $lates[[int][Math]::Ceiling(0.5 * $lates.Count) - 1] } else { $null }
    server_request_starts   = $arrivals.Count
    server_arrival_spread_ms = $arrivalSpreadMs
    arrival_spread_limit_ms = $ArrivalSpreadLimitMs
    frozen_before_runs      = $true
    rule                    = "client: >=90% of workers fire within 25 ms of the shared instant; server: arrival spread <= $ArrivalSpreadLimitMs ms (guarantees the burst hits the cold key on this host)"
}
Add-Check 'burst.synchronized_start' (($metas.Count -gt 0) -and ($within25 -ge [math]::Ceiling($metas.Count * 0.9))) "within25ms=$within25 of $($metas.Count) max_late=$($syncStats.fired_late_max_ms)ms"
Add-Check 'burst.arrived_together' (($arrivals.Count -eq $Requests) -and ($null -ne $arrivalSpreadMs) -and ($arrivalSpreadMs -le $ArrivalSpreadLimitMs)) "request_start=$($arrivals.Count) of $Requests spread=$arrivalSpreadMs ms (<=$ArrivalSpreadLimitMs ms)"

$lat = @($metas | ForEach-Object { $_.latency_ms } | Sort-Object)
function Pct($arr, $p) {
    if (-not $arr -or $arr.Count -eq 0) { return $null }
    $idx = [int][Math]::Ceiling(($p / 100.0) * $arr.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    return [math]::Round($arr[$idx], 3)
}

$summary = [ordered]@{
    run_id            = $RunId
    label             = $Label
    variant           = $Variant
    instance          = $instanceInfo
    article_id        = "$ArticleId"
    base_url          = $BaseUrl
    concurrency       = $Concurrency
    requests          = $Requests
    start_utc         = $startAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    finished_utc      = (Now-Utc)
    cold_state        = $coldState
    responses         = [ordered]@{
        ok_200_with_id = $ok200
        rejected_503   = $rejected503
        null_1002      = $nulls
        bad            = $bad
        timeout        = $timeouts
        biz_code_hist  = $biz
    }
    service_events    = [ordered]@{
        source_file          = $EventsFile
        lines_for_run        = $runEvents.Count
        cache_read_hits      = $cacheHits
        lock_acquired        = $lockAcquired.Count
        lock_fail            = $lockFail
        lock_late_acquire    = $lockLate
        wait_outcomes        = $waits
        rebuild_attempts     = $rebuildBegins.Count
        rebuild_completed    = $rebuildExits.Count
        peak_concurrent_rebuild = $peakRebuild
        db_attempts          = $dbEnters.Count
        db_completed         = $dbExits.Count
        peak_concurrent_db   = $peakDb
        release_events       = $releases.Count
        interrupt_caught     = $interrupts
        io_errors            = $ioErrors.Count
        fault_injected       = $faultInjected
        pids                 = $pids
        interval_key         = 'pid/attemptId (attemptId alone restarts per JVM, so it is not cross-process safe)'
    }
    latency_ms        = [ordered]@{ p50 = (Pct $lat 50); p95 = (Pct $lat 95); p99 = (Pct $lat 99); max = (Pct $lat 100) }
    counting_note     = 'db_attempts counts DAO-level entry events (one per getById); rebuild_attempts includes the simulated delay. Neither is a physical SQL count. Peaks come from enter/exit intervals across processes.'
    synchronization   = $syncStats
    lead_ms           = $LeadMs
    late_grace_ms     = $LateGraceMs
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'burst-summary.json') -Text ($summary | ConvertTo-Json -Depth 6)
$summary | ConvertTo-Json -Depth 6
$counts = Get-RunCheckCounts $script:run
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))

