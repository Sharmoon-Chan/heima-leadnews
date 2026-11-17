# TOOL-013 offline: the tail wait must still persist the failure receipt of a FAULTED task (ASCII only).
#
# Scope of this driver:
#   * it calls the FINAL shared helpers (benchmarks/lib/P13c4Evidence.ps1), not a stand-in implementation;
#   * the private endpoint runs in a SEPARATE process and closes a real TCP connection while the declared body
#     length is still unsatisfied, so the client Task faults on a transport error (not an HTTP 500);
#   * every case has its own run_id; nothing here pretends to be a business window.
#
# Cases:
#   A  already-faulted : the task reached Faulted BEFORE the wait was entered (no helper involved yet)
#   B  faulted-in-wait : the wait is already running when the endpoint aborts the connection
#   C  success / 500   : bodies kept and recomputable; a repeated Wait/Complete must not add a row
#   D  still pending   : the original deadline behaviour, and NO terminal receipt is fabricated
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [int]$FaultCases = 3,
    [int]$AbortDelayMs = 120,
    [int]$DeadlineMs = 1200,
    [int]$PersistLagBudgetMs = 150,
    [int]$ReadyTimeoutMs = 60000,
    [int]$EndpointRunMs = 90000
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P13c4Evidence.ps1')
Add-Type -AssemblyName System.Net.Http | Out-Null
[System.Net.ServicePointManager]::DefaultConnectionLimit = 16

$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'TOOL-013-fault-offline' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ fault_cases = $FaultCases; abort_delay_ms = $AbortDelayMs; deadline_ms = $DeadlineMs; persist_lag_budget_ms = $PersistLagBudgetMs } `
        -Targets @() -DataSet 'offline'
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-60} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'fail' }), $d
}
function Get-Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }

# ---------------------------------------------------------------- private endpoint as a SEPARATE process
$port = 19100 + (Get-Random -Minimum 0 -Maximum 700)
$prefix = "http://127.0.0.1:$port/"
$endpointScript = Join-Path $outDir 'endpoint.ps1'
$endpointEvents = Join-Path $outDir 'endpoint-events.jsonl'
$endpointReady = Join-Path $outDir 'endpoint-ready.txt'
$endpointOut = Join-Path $outDir 'endpoint.stdout.txt'
$endpointErr = Join-Path $outDir 'endpoint.stderr.txt'

$endpointSource = @'
# Private retention collaborator for the TOOL-013 offline test. It is NOT a business window.
# It answers with a declared Content-Length and then closes the real TCP connection before the body is complete,
# which makes the client Task fault on a transport error.
param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][string]$ReadyFile,
    [Parameter(Mandatory = $true)][string]$EventsFile,
    [int]$AbortDelayMs = 120,
    [int]$RunMs = 90000
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Ev([string]$text) {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    [System.IO.File]::AppendAllText($EventsFile, ("{0}`t{1}`n" -f $stamp, $text), $utf8)
}
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)
$listener.Start()
[System.IO.File]::WriteAllText($ReadyFile, $prefix, $utf8)
Ev 'endpoint ready'
$bodyOk = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"views":777,"padding":"0123456789abcdef"}')
$body500 = [System.Text.Encoding]::UTF8.GetBytes('{"code":503,"errorMessage":"server busy","views":0}')
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while ($sw.ElapsedMilliseconds -lt $RunMs) {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        Ev ("request " + $path)
        if ($path -like '/ok*') {
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.ContentLength64 = $bodyOk.Length
            $ctx.Response.OutputStream.Write($bodyOk, 0, $bodyOk.Length)
            $ctx.Response.OutputStream.Close()
            $ctx.Response.Close()
            Ev 'complete 200'
        } elseif ($path -like '/fail500*') {
            $ctx.Response.StatusCode = 500
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.ContentLength64 = $body500.Length
            $ctx.Response.OutputStream.Write($body500, 0, $body500.Length)
            $ctx.Response.OutputStream.Close()
            $ctx.Response.Close()
            Ev 'complete 500'
        } elseif ($path -like '/early*') {
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.ContentLength64 = $bodyOk.Length
            $ctx.Response.OutputStream.Write($bodyOk, 0, 1)
            $ctx.Response.OutputStream.Flush()
            Ev 'one byte sent'
            Start-Sleep -Milliseconds 30
            $ctx.Response.Abort()
            Ev 'abort early'
        } elseif ($path -like '/late*') {
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.ContentLength64 = $bodyOk.Length
            $ctx.Response.OutputStream.Write($bodyOk, 0, 1)
            $ctx.Response.OutputStream.Flush()
            Ev 'one byte sent'
            Start-Sleep -Milliseconds $AbortDelayMs
            $ctx.Response.Abort()
            Ev 'abort late'
        } elseif ($path -like '/pending*') {
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'application/json'
            $ctx.Response.ContentLength64 = $bodyOk.Length
            $ctx.Response.OutputStream.Write($bodyOk, 0, 1)
            $ctx.Response.OutputStream.Flush()
            Ev 'hold pending'
            Start-Sleep -Milliseconds 30000
            $ctx.Response.Abort()
            Ev 'abort held'
        } else {
            $ctx.Response.StatusCode = 404
            $ctx.Response.ContentLength64 = 0
            $ctx.Response.Close()
            Ev 'complete 404'
        }
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    Ev 'endpoint stopped'
}
exit 0
'@
[System.IO.File]::WriteAllText($endpointScript, $endpointSource, $utf8)

$endpointProc = $null
$endpointStarted = $false
try {
    $endpointProc = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $endpointOut -RedirectStandardError $endpointErr -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $endpointScript, '-Prefix', $prefix,
        '-ReadyFile', $endpointReady, '-EventsFile', $endpointEvents, '-AbortDelayMs', "$AbortDelayMs", '-RunMs', "$EndpointRunMs")
    $swReady = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $endpointReady) -and $swReady.ElapsedMilliseconds -lt $ReadyTimeoutMs) { Start-Sleep -Milliseconds 25 }
    $endpointStarted = Test-Path -LiteralPath $endpointReady
} catch {
    $endpointStarted = $false
}
Add-Check 'endpoint.started_as_separate_process' ($endpointStarted -and $null -ne $endpointProc) `
    "endpoint pid=$($endpointProc.Id) prefix=$prefix ready=$endpointStarted (separate process, real TCP)"

$ledgerPath = Join-Path $outDir 'requests.jsonl'
$ledger = New-P13c4RequestLedger -Path $ledgerPath -RunId $RunId
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(60)
$script:localSeq = 0

function Read-Rows { return @(Read-P13c4LedgerLines -Path $ledgerPath) }
function Find-Rows([string]$reqId) {
    return @(Read-Rows | Where-Object { $_ -match [regex]::Escape('"' + $reqId + '"') })
}
function New-Tracked([string]$path, [string]$reqId, [string]$kind) {
    $script:localSeq++
    return Start-P13c4AsyncGet -Client $client -Base $prefix -Path $path -ReqId $reqId -Kind $kind -RunId $RunId -LocalSeq $script:localSeq
}

# ---------------------------------------------------------------- A: task already Faulted before the wait
$aResults = New-Object System.Collections.ArrayList
$aOk = $true
for ($i = 1; $i -le $FaultCases; $i++) {
    $reqId = "$RunId-a$i"
    $p = New-Tracked "/early/a$i" $reqId 'slow-reader'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $p.task.IsCompleted -and $sw.ElapsedMilliseconds -lt 20000) { Start-Sleep -Milliseconds 5 }
    $statusBefore = [string]$p.task.Status
    $threw = $false
    $ret = $null
    $errMsg = ''
    try {
        $ret = Wait-P13c4CompletionPersist -Pending $p -Ledger $ledger -SliceMs 3 -DeadlineMs 5000
    } catch {
        $threw = $true
        $errMsg = $_.Exception.Message
    }
    $rows = Find-Rows $reqId
    $rec = $null
    if (@($rows).Count -eq 1) { $rec = @($rows)[0] | ConvertFrom-Json }
    $fieldsOk = ($null -ne $rec -and [string]$rec.request_id -eq $reqId -and [string]$rec.method -eq 'Get' -and
        [string]$rec.path -eq "/early/a$i" -and [long]$rec.started_ms -gt 0 -and [long]$rec.ended_ms -ge [long]$rec.started_ms -and
        [long]$rec.persisted_ms -ge [long]$rec.ended_ms -and [long]$rec.last_incomplete_ms -le [long]$rec.ended_ms)
    $failOk = ($null -ne $rec -and [int]$rec.http -eq -1 -and $rec.failure -eq $true -and "$($rec.error)".Length -gt 0)
    $noBody = ($null -ne $rec -and $null -eq $rec.PSObject.Properties['body'] -and $null -eq $rec.PSObject.Properties['bytes'])
    $ok = ($statusBefore -eq 'Faulted' -and -not $threw -and $ret -eq $true -and @($rows).Count -eq 1 -and $fieldsOk -and $failOk -and $noBody)
    if (-not $ok) { $aOk = $false }
    $null = $aResults.Add([ordered]@{
            case = "a$i"; request_id = $reqId; task_status_before_wait = $statusBefore
            helper_threw = $threw; helper_threw_message = $errMsg; helper_return = $ret
            wait_threw_inside_helper = $p.wait_threw; rows = @($rows).Count
            http = $(if ($null -ne $rec) { $rec.http } else { 'n/a' })
            failure = $(if ($null -ne $rec) { $rec.failure } else { 'n/a' })
            error = $(if ($null -ne $rec) { "$($rec.error)" } else { '' })
            fields_complete = $fieldsOk; body_not_fabricated = $noBody
        })
}
Add-Check 'fault_a.already_faulted_persists_failure_receipt' $aOk `
    ("$FaultCases cases: task was Faulted BEFORE the wait, the helper did not throw, each request has exactly ONE parseable failure receipt with all fields and no fabricated body")
Add-Check 'fault_a.receipt_is_failure_not_business_503' (@($aResults | Where-Object { $_.http -ne -1 }).Count -eq 0 -and @($aResults | Where-Object { -not $_.failure }).Count -eq 0) `
    (($aResults | ForEach-Object { "a$($_.case):http=$($_.http) failure=$($_.failure)" }) -join ' ')

# ---------------------------------------------------------------- B: the wait is already running when it faults
$bResults = New-Object System.Collections.ArrayList
$bOk = $true
for ($i = 1; $i -le $FaultCases; $i++) {
    $reqId = "$RunId-b$i"
    $p = New-Tracked "/late/b$i" $reqId 'slow-reader'
    $pendingAtEntry = (-not $p.task.IsCompleted)
    $threw = $false
    $ret = $null
    $errMsg = ''
    try {
        $ret = Wait-P13c4CompletionPersist -Pending $p -Ledger $ledger -SliceMs 3 -DeadlineMs 20000
    } catch {
        $threw = $true
        $errMsg = $_.Exception.Message
    }
    $rows = Find-Rows $reqId
    $rec = $null
    if (@($rows).Count -eq 1) { $rec = @($rows)[0] | ConvertFrom-Json }
    $failOk = ($null -ne $rec -and [int]$rec.http -eq -1 -and $rec.failure -eq $true -and "$($rec.error)".Length -gt 0)
    $ok = ($pendingAtEntry -and $p.wait_threw -and -not $threw -and $ret -eq $true -and @($rows).Count -eq 1 -and $failOk)
    if (-not $ok) { $bOk = $false }
    $null = $bResults.Add([ordered]@{
            case = "b$i"; request_id = $reqId; pending_when_wait_entered = $pendingAtEntry
            wait_threw_inside_helper = $p.wait_threw; wait_error = $p.wait_error
            helper_threw = $threw; helper_threw_message = $errMsg; helper_return = $ret
            task_status_after = [string]$p.task.Status; rows = @($rows).Count
            http = $(if ($null -ne $rec) { $rec.http } else { 'n/a' })
            failure = $(if ($null -ne $rec) { $rec.failure } else { 'n/a' })
        })
}
Add-Check 'fault_b.fault_during_wait_persists_failure_receipt' $bOk `
    ("$FaultCases cases: the task was still pending when the wait began, Wait() threw on the transport fault, the helper recovered and wrote exactly ONE failure receipt per request")
Add-Check 'fault_b.wait_really_threw' (@($bResults | Where-Object { -not $_.wait_threw_inside_helper }).Count -eq 0) `
    (($bResults | ForEach-Object { "b$($_.case):wait_threw=$($_.wait_threw_inside_helper) status=$($_.task_status_after)" }) -join ' ')

# ---------------------------------------------------------------- C: normal success and an HTTP 500
$okP = New-Tracked '/ok/c1' "$RunId-ok1" 'slow-reader'
$okR = Wait-P13c4CompletionPersist -Pending $okP -Ledger $ledger -SliceMs 3 -DeadlineMs 20000
$okRows = Find-Rows "$RunId-ok1"
$okRec = $null
if (@($okRows).Count -eq 1) { $okRec = @($okRows)[0] | ConvertFrom-Json }
$okSha = $false
$okBytes = -1
if ($null -ne $okRec) {
    $b = [System.Text.Encoding]::UTF8.GetBytes([string]$okRec.body)
    $okBytes = $b.Length
    $okSha = (([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($b)) -replace '-', '').ToLower() -eq [string]$okRec.sha256)
}
Add-Check 'success.body_and_hash_preserved' ($okR -eq $true -and $null -ne $okRec -and [int]$okRec.http -eq 200 -and $okBytes -eq [int]$okRec.bytes -and $okSha -and [int]$okRec.views -eq 777) `
    ("http=$($okRec.http) bytes=$okBytes/$($okRec.bytes) sha256-recomputable=$okSha views=$($okRec.views)")

$fP = New-Tracked '/fail500/c1' "$RunId-500-1" 'slow-reader'
$fR = Wait-P13c4CompletionPersist -Pending $fP -Ledger $ledger -SliceMs 3 -DeadlineMs 20000
$fRows = Find-Rows "$RunId-500-1"
$fRec = $null
if (@($fRows).Count -eq 1) { $fRec = @($fRows)[0] | ConvertFrom-Json }
$fSha = $false
if ($null -ne $fRec) {
    $fb = [System.Text.Encoding]::UTF8.GetBytes([string]$fRec.body)
    $fSha = (([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($fb)) -replace '-', '').ToLower() -eq [string]$fRec.sha256)
}
Add-Check 'http500.body_and_hash_preserved' ($fR -eq $true -and $null -ne $fRec -and [int]$fRec.http -eq 500 -and "$($fRec.body)" -match 'server busy' -and $fSha -and $null -eq $fRec.PSObject.Properties['failure']) `
    ("http=$($fRec.http) body-kept=$("$($fRec.body)" -match 'server busy') sha256-recomputable=$fSha (an HTTP 500 is a normal business response, not a transport fault)")

$rowsBeforeRepeat = (Read-Rows).Count
$null = Wait-P13c4CompletionPersist -Pending $okP -Ledger $ledger -SliceMs 3 -DeadlineMs 2000
$null = Complete-P13c4Get -Pending $okP -Ledger $ledger
$null = Wait-P13c4CompletionPersist -Pending $fP -Ledger $ledger -SliceMs 3 -DeadlineMs 2000
$null = Complete-P13c4Get -Pending $fP -Ledger $ledger
$rowsAfterRepeat = (Read-Rows).Count
Add-Check 'repeat_wait_and_complete_add_no_rows' ($rowsBeforeRepeat -eq $rowsAfterRepeat) `
    "rows before=$rowsBeforeRepeat after=$rowsAfterRepeat (one record per request is enforced by the ledger itself)"

# ---------------------------------------------------------------- D: still pending keeps the old deadline behaviour
$dP = New-Tracked '/pending/d1' "$RunId-d1" 'slow-reader'
$swD = [System.Diagnostics.Stopwatch]::StartNew()
$dRet = Wait-P13c4CompletionPersist -Pending $dP -Ledger $ledger -SliceMs 3 -DeadlineMs $DeadlineMs
$dElapsed = $swD.ElapsedMilliseconds
$dRows = Find-Rows "$RunId-d1"
$dStatus = [string]$dP.task.Status
Add-Check 'pending.deadline_returns_false_without_receipt' ($dRet -eq $false -and @($dRows).Count -eq 0 -and $dStatus -ne 'Faulted' -and $dElapsed -ge $DeadlineMs) `
    ("returned=$dRet after ${dElapsed}ms (deadline $DeadlineMs), rows=$(@($dRows).Count), task status=$dStatus : still-pending keeps the old deadline behaviour and fabricates nothing")

# the endpoint is stopped with the held response still open; the abandoned task must not gain a receipt later
if ($null -ne $endpointProc -and -not $endpointProc.HasExited) { Stop-Process -Id $endpointProc.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 400
$dRowsAfter = Find-Rows "$RunId-d1"
Add-Check 'pending.abandoned_request_never_gains_a_receipt' (@($dRowsAfter).Count -eq 0) `
    ("after the endpoint was stopped the never-completed request still has 0 rows (status=$([string]$dP.task.Status))")

# ---------------------------------------------------------------- ledger integrity
$onDisk = Read-Rows
$parsed = 0
$badJson = 0
$seqOk = $true
$expectedSeq = 1
$ids = New-Object System.Collections.ArrayList
foreach ($l in $onDisk) {
    try { $o = $l | ConvertFrom-Json } catch { $badJson++; continue }
    $parsed++
    if ([long]$o.seq -ne $expectedSeq) { $seqOk = $false }
    $expectedSeq++
    $null = $ids.Add([string]$o.request_id)
}
$uniqueIds = @($ids | Sort-Object -Unique).Count
$expectedRows = ($FaultCases * 2) + 2
Add-Check 'ledger.every_completed_request_on_disk' ($onDisk.Count -eq $expectedRows -and $badJson -eq 0) `
    "lines=$($onDisk.Count) expected=$expectedRows (A$FaultCases + B$FaultCases + success + 500) parseable=$parsed unparseable=$badJson"
Add-Check 'ledger.one_record_per_request_in_order' ($seqOk -and $uniqueIds -eq $onDisk.Count) `
    "seq is 1..$($onDisk.Count)=$seqOk unique request ids=$uniqueIds of $($onDisk.Count)"
# the ledger writer keeps its stream open on purpose; close it exactly once before hashing the file on disk
$openRowsCount = (Read-Rows).Count
$ledger.Close()
$ledgerSha = Get-Sha $ledgerPath
Add-Check 'ledger.readable_while_stream_open_then_closed_once' ($openRowsCount -eq $onDisk.Count -and $ledgerSha.Length -eq 64) `
    "read with the writer still open returned $openRowsCount lines, after a single Close the file hashes to $ledgerSha (no sharing violation, no early close)"

$endpointEventsText = @()
if (Test-Path -LiteralPath $endpointEvents) { $endpointEventsText = @([System.IO.File]::ReadAllLines($endpointEvents, $utf8)) }
$abortsEarly = @($endpointEventsText | Where-Object { $_ -match 'abort early' }).Count
$abortsLate = @($endpointEventsText | Where-Object { $_ -match 'abort late' }).Count
Add-Check 'endpoint.aborted_real_tcp_connections' ($abortsEarly -ge $FaultCases -and $abortsLate -ge $FaultCases) `
    "endpoint aborted early=$abortsEarly late=$abortsLate (>= $FaultCases each; the fault is a closed real connection, not an HTTP status)"

$client.Dispose()
# (the ledger was already closed exactly once above, before its hash was taken)
if ($null -ne $endpointProc -and -not $endpointProc.HasExited) { Stop-Process -Id $endpointProc.Id -Force -ErrorAction SilentlyContinue }

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    scope = 'final shared helper; private endpoint closes a real TCP connection before the declared body length'
    parameters = [ordered]@{ fault_cases = $FaultCases; abort_delay_ms = $AbortDelayMs; deadline_ms = $DeadlineMs; persist_lag_budget_ms = $PersistLagBudgetMs }
    endpoint = [ordered]@{ prefix = $prefix; pid = $(if ($null -ne $endpointProc) { $endpointProc.Id } else { -1 }); events = 'endpoint-events.jsonl'; aborts_early = $abortsEarly; aborts_late = $abortsLate }
    case_a = @($aResults)
    case_b = @($bResults)
    case_c = [ordered]@{ success = $okRec; http500 = $fRec; rows_before_repeat = $rowsBeforeRepeat; rows_after_repeat = $rowsAfterRepeat }
    case_d = [ordered]@{ returned = $dRet; elapsed_ms = $dElapsed; deadline_ms = $DeadlineMs; rows = @($dRows).Count; rows_after_endpoint_stopped = @($dRowsAfter).Count; task_status = [string]$dP.task.Status }
    ledger = [ordered]@{ path = 'requests.jsonl'; sha256 = $ledgerSha; lines = $onDisk.Count }
    note = 'this endpoint is a retention collaborator for the offline test only; it is not a business window'
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'fault-offline-result.json') -Text ($result | ConvertTo-Json -Depth 9)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'fault-offline-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
