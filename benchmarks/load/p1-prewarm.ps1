# P1.0 pre-warm pass (ASCII only: PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
#
# Purpose: put the two A/B groups into the same starting state before measuring.
#   - B (cache enabled): warms every id in the id file so the measurement window is steady-state
#     Cache Aside, not a cold-start burst.
#   - A (cache disabled): same requests, same order, only hits the DB. It changes nothing in Redis,
#     so running the identical procedure keeps the two groups' procedure identical.
#
# It records, per id: http status + business code, and asserts data.article.id equals the requested id.
# Ids are compared as STRINGS (they are 19 digits, above 2^53-1).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File benchmarks/load/p1-prewarm.ps1 `
#     -BaseUrl http://127.0.0.1:51802 -IdFile .../ids-hot.txt -OutDir .../prewarm-A
param(
    [string]$BaseUrl = 'http://127.0.0.1:51802',
    [Parameter(Mandatory = $true)][string]$IdFile,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$RunId = '',
    [string]$ExperimentRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = Split-Path $OutDir -Leaf }

# ---- run directory protection (P1.1a): before any HTTP call ----
. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$runState = $null
trap {
    exit (Save-RunFailure -State $runState -ErrorRecord $_)
}
try {
    $runState = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.1-prewarm' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ id_file = $IdFile; timeout_seconds = $TimeoutSeconds } -DataSet $IdFile
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

$ids = Get-Content -Path $IdFile | Where-Object { $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }
if ($ids.Count -eq 0) { throw "no ids in $IdFile" }

Add-Type -AssemblyName System.Net.Http | Out-Null
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

$rows = [System.Collections.Generic.List[string]]::new()
$ok = 0; $bad = 0
$swAll = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($id in $ids) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = -1; $code = ''; $match = 'false'; $err = ''
    try {
        $resp = $client.GetAsync("$BaseUrl/api/v1/article/detail/$id").GetAwaiter().GetResult()
        $status = [int]$resp.StatusCode
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $m = [regex]::Match($body, '"code"\s*:\s*(-?\d+)')
        if ($m.Success) { $code = $m.Groups[1].Value }
        # id must appear as an exact string literal; never parsed as a number
        if ($body -match [regex]::Escape('"id":"' + $id + '"')) { $match = 'true' }
    } catch {
        $err = 'transport'
    }
    $sw.Stop()
    if ($status -eq 200 -and $code -eq '200' -and $match -eq 'true') { $ok++ } else { $bad++ }
    $rows.Add(('{0},{1},{2},{3},{4},{5}' -f $id, $status, $code, $match, [math]::Round($sw.Elapsed.TotalMilliseconds, 3), $err))
}
$swAll.Stop()
$client.Dispose()

$csv = Join-Path $OutDir 'prewarm.csv'
Write-RunFileText -State $runState -Path $csv -Text ('article_id,http_status,biz_code,id_string_match,latency_ms,error' + [Environment]::NewLine + ($rows -join [Environment]::NewLine))


$summary = [ordered]@{
    base_url        = $BaseUrl
    id_file         = $IdFile
    requests        = $ids.Count
    assertions_ok   = $ok
    assertions_bad  = $bad
    wall_seconds    = [math]::Round($swAll.Elapsed.TotalSeconds, 2)
    finished_at_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
}
Write-RunFileText -State $runState -Path (Join-Path $OutDir 'prewarm-summary.json') -Text ($summary | ConvertTo-Json -Depth 4)
$summary | ConvertTo-Json -Depth 4
Add-RunCheck -State $runState -Name 'prewarm.all_assertions_ok' -Status $(if ($bad -eq 0) { 'pass' } else { 'fail' }) -Detail "ok=$ok bad=$bad of $($ids.Count)"
exit (Set-RunStatus -State $runState -Status $(if ($bad -gt 0) { 'failed' } else { 'passed' }))
