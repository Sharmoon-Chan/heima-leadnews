# P0 detail-API closed-loop load generator (ASCII only: Windows PowerShell 5.1 reads
# BOM-less .ps1 as ANSI, so keep this file ASCII).
#
# Purpose: produce a repeatable first-pass baseline for GET /api/v1/article/detail/{id}.
# It is a *smoke* driver: fixed concurrency, fixed duration, per-request assertions.
# It is NOT a capacity test and the numbers it prints are only valid for this host.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks/load/p0-detail-load.ps1 `
#     -BaseUrl http://127.0.0.1:51802 -IdFile D:/.../ids-hot.txt -Concurrency 10 `
#     -WarmupSeconds 10 -DurationSeconds 60 -OutDir D:/.../runs/20261028-P0-B01
#
# Exit codes: 0 = all assertions passed, 1 = assertion failures, 2 = driver error.

param(
    [string]$BaseUrl = 'http://127.0.0.1:51802',
    [Parameter(Mandatory = $true)][string]$IdFile,
    [int]$Concurrency = 10,
    [int]$WarmupSeconds = 10,
    [int]$DurationSeconds = 60,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [int]$TimeoutSeconds = 10,
    [string]$ExpectBizCode = '200',
    [string]$RunId = '',
    [string]$ExperimentRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [switch]$SkipWarmup
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# run_id defaults to the last path segment, but the guard still checks it for safety
if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = Split-Path $OutDir -Leaf }

# ---- run directory protection (P1.1a): before any HTTP call ----
. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$runState = $null
trap {
    exit (Save-RunFailure -State $runState -ErrorRecord $_)
}
try {
    $runState = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.0-load' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ concurrency = $Concurrency; warmup_seconds = $WarmupSeconds; duration_seconds = $DurationSeconds;
                       expect_biz_code = $ExpectBizCode; id_file = $IdFile } `
        -DataSet $IdFile
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

$ids = Get-Content -Path $IdFile | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }
if ($ids.Count -eq 0) { Write-Host "no ids in $IdFile"; exit 2 }

$runId = $RunId
$startedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)

function New-Worker {
    param([string]$Url, [string[]]$Ids, [int]$Warmup, [int]$Duration, [int]$Timeout, [string]$Expect, [long]$StopAfterMs)
    $HttpClient = $null
    return {
        param($Url, $Ids, $Warmup, $Duration, $Timeout, $Expect, $StopAfterMs)
        Add-Type -AssemblyName System.Net.Http | Out-Null
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
        $sw = [System.Diagnostics.Stopwatch]::new()
        $rows = [System.Collections.Generic.List[string]]::new()
        $rnd = [System.Random]::new([int]($PID + [System.Threading.Thread]::CurrentThread.ManagedThreadId))
        $end = [DateTime]::UtcNow.AddSeconds($Duration)
        $wid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        while ([DateTime]::UtcNow -lt $end) {
            $id = $Ids[$rnd.Next(0, $Ids.Count)]
            # NB: PowerShell variables are case-insensitive; do not name this $url
            # because it would overwrite $Url and grow the URL every iteration.
            $requestUrl = "$Url/api/v1/article/detail/$id"
            $sw.Restart()
            $httpCode = -1; $bizCode = ''; $ok = 'false'; $err = ''
            try {
                $resp = $client.GetAsync($requestUrl).GetAwaiter().GetResult()
                $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $httpCode = [int]$resp.StatusCode
                try {
                    $obj = $body | ConvertFrom-Json
                    $bizCode = [string]$obj.code
                    $returnedId = if ($obj.data -and $obj.data.article) { [string]$obj.data.article.id } else { '' }
                    if ($bizCode -eq $Expect -and $returnedId -eq $id) { $ok = 'true' }
                    elseif ($bizCode -eq $Expect) { $err = 'id_mismatch' }
                    else { $err = "biz_$bizCode" }
                } catch {
                    $err = 'bad_json'
                }
            } catch {
                $err = 'transport'
            }
            $sw.Stop()
            $rows.Add(('{0},{1},{2},{3},{4},{5},{6},{7}' -f [DateTime]::UtcNow.ToString('HH:mm:ss.fff', $inv), $wid, $id, [math]::Round($sw.Elapsed.TotalMilliseconds, 3), $httpCode, $bizCode, $ok, $err))
        }
        return ,$rows
    }
}

# Warmup phase: fixed number of sequential calls, results discarded but counted.
if (-not $SkipWarmup -and $WarmupSeconds -gt 0) {
    Add-Type -AssemblyName System.Net.Http | Out-Null
    $wc = New-Object System.Net.Http.HttpClient
    $wc.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $warmEnd = [DateTime]::UtcNow.AddSeconds($WarmupSeconds)
    $warmCount = 0; $warmErr = 0
    while ([DateTime]::UtcNow -lt $warmEnd) {
        foreach ($id in $ids[0..([Math]::Min(19, $ids.Count - 1))]) {
            try {
                $r = $wc.GetAsync("$BaseUrl/api/v1/article/detail/$id").GetAwaiter().GetResult()
                $b = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $o = $b | ConvertFrom-Json
                if ([string]$o.code -ne $ExpectBizCode) { $warmErr++ }
                $warmCount++
            } catch { $warmErr++ }
            if ([DateTime]::UtcNow -ge $warmEnd) { break }
        }
    }
    $wc.Dispose()
    Write-RunFileText -State $runState -Path (Join-Path $OutDir 'warmup.txt') -Text "warmup_requests=$warmCount warmup_assert_failures=$warmErr"
}

# Resource sampling of the java process while the load runs.
$javaProc = Get-Process -Name java -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -Last 1
$resPath = Join-Path $OutDir 'resources.csv'
Write-RunFileText -State $runState -Path $resPath -Text 'ref_utc,proc_cpu_seconds,ws_mb,threads'

$scriptBlock = (New-Worker -Url $BaseUrl -Ids $ids -Warmup $WarmupSeconds -Duration $DurationSeconds -Timeout $TimeoutSeconds -Expect $ExpectBizCode -StopAfterMs 0)
$pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
$pool.Open()
$handles = @()
$t0 = [DateTime]::UtcNow
for ($i = 0; $i -lt $Concurrency; $i++) {
    $ps = [powershell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($scriptBlock).AddArgument($BaseUrl).AddArgument($ids).AddArgument($WarmupSeconds).AddArgument($DurationSeconds).AddArgument($TimeoutSeconds).AddArgument($ExpectBizCode).AddArgument(0)
    $handles += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
}
$sampler = {
    param($p, $path, $until)
    while ([DateTime]::UtcNow -lt $until) {
        $proc = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
        if ($proc) {
            $line = '{0},{1},{2},{3}' -f [DateTime]::UtcNow.ToString('HH:mm:ss'), [math]::Round($proc.CPU, 2), [math]::Round($proc.WorkingSet64 / 1MB, 1), $proc.Threads.Count
            Add-Content -Path $path -Value $line
            $proc.Dispose()
        }
        Start-Sleep -Seconds 2
    }
}
$sampleEnd = $t0.AddSeconds($DurationSeconds - 1)
if ($javaProc) { & $sampler $javaProc $resPath $sampleEnd }

$all = [System.Collections.Generic.List[string]]::new()
foreach ($h in $handles) {
    $out = $h.PS.EndInvoke($h.Handle)
    $h.PS.Dispose()
    foreach ($r in $out) { if ($r) { foreach ($line in $r) { $all.Add($line) } } }
}
[void]$pool.Close()
$elapsed = ([DateTime]::UtcNow - $t0).TotalSeconds

$csvPath = Join-Path $OutDir 'requests.csv'
# R3: one write, fixed 8-column header first, then the rows (header only when no rows).
Write-RunFileText -State $runState -Path $csvPath -Text (Format-RequestCsv -Rows @($all))


$parsed = $all | ForEach-Object { $p = $_ -split ','; [pscustomobject]@{ latency = [double]$p[3]; http = $p[4]; biz = $p[5]; ok = $p[6]; err = $p[7] } }
$okRows = $parsed | Where-Object { $_.ok -eq 'true' }
$latAll = ($parsed | ForEach-Object { $_.latency } | Sort-Object)
$latOk = ($okRows | ForEach-Object { $_.latency } | Sort-Object)
function Pct($arr, $p) {
    if (-not $arr -or $arr.Count -eq 0) { return $null }
    $idx = [int][Math]::Ceiling(($p / 100.0) * $arr.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    return [math]::Round($arr[$idx], 3)
}
$summary = [ordered]@{
    run_id                = $runId
    stage                 = 'P0'
    base_url              = $BaseUrl
    endpoint              = '/api/v1/article/detail/{id}'
    id_file               = $IdFile
    ids_available         = $ids.Count
    concurrency           = $Concurrency
    warmup_seconds        = if ($SkipWarmup) { 0 } else { $WarmupSeconds }
    duration_seconds_target = $DurationSeconds
    duration_seconds_actual = [math]::Round($elapsed, 2)
    started_at_utc        = $startedAt
    finished_at_utc       = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    requests_total        = $parsed.Count
    requests_assert_ok    = $okRows.Count
    requests_failed       = $parsed.Count - $okRows.Count
    error_breakdown       = @($parsed | Where-Object { $_.ok -ne 'true' } | Group-Object -Property err | ForEach-Object { @{ error = $_.Name; count = $_.Count } })
    success_qps           = if ($elapsed -gt 0) { [math]::Round($okRows.Count / $elapsed, 2) } else { $null }
    total_qps             = if ($elapsed -gt 0) { [math]::Round($parsed.Count / $elapsed, 2) } else { $null }
    latency_ms_all        = @{ p50 = (Pct $latAll 50); p95 = (Pct $latAll 95); p99 = (Pct $latAll 99); max = (Pct $latAll 100); min = (Pct $latAll 0) }
    latency_ms_success_only = @{ p50 = (Pct $latOk 50); p95 = (Pct $latOk 95); p99 = (Pct $latOk 99) }
    correctness           = @{ expected_biz_code = $ExpectBizCode; rule = 'biz code == expected AND data.article.id == requested id' }
    artifacts             = @{ requests_csv = $csvPath; resources_csv = $resPath }
    note                  = 'Closed-loop fixed concurrency, single load-generator on the same host as the service. Not a capacity claim.'
}
$summaryPath = Join-Path $OutDir 'summary.json'
Write-RunFileText -State $runState -Path $summaryPath -Text ($summary | ConvertTo-Json -Depth 6)
$summary | ConvertTo-Json -Depth 6

# aggregate the load run into the shared pass/fail accounting
Add-RunCheck -State $runState -Name 'load.requests_executed' -Status $(if ($parsed.Count -gt 0) { 'pass' } else { 'fail' }) -Detail "total=$($parsed.Count)"
Add-RunCheck -State $runState -Name 'load.all_assertions_ok' -Status $(if ($okRows.Count -eq $parsed.Count) { 'pass' } else { 'fail' }) -Detail "ok=$($okRows.Count) of $($parsed.Count)"
if ($parsed.Count -eq 0) { [void](Save-RunFailure -State $runState -ErrorRecord $null); exit 1 }
exit (Set-RunStatus -State $runState -Status $(if ($okRows.Count -lt $parsed.Count) { 'failed' } else { 'passed' }))
