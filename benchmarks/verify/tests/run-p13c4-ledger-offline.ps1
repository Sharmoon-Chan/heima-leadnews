# P1.3c-4 B offline: shared-baseline gate + per-request persistence, including the tracked async path
# (ASCII only).
#
# Everything comes from benchmarks/lib/P13c4Evidence.ps1 and is exercised against a private local endpoint:
#
#   baseline gate : missing file / wrong sha256 / foreign scope / wrong target ids / no four-field snapshot are
#                   each refused BEFORE any external call; the listener must see ZERO requests per refusal.
#   ledger        : every Add is flushed; the ONE reader works while the writer stream is still open; a
#                   controlled interruption keeps a complete parseable prefix and the next request is never sent.
#   async         : a request whose response is still incomplete is NOT on disk; the moment the client owns the
#                   complete body its record is written (completion timestamp from the client, not a later
#                   collection), before the next request is dispatched; success and 500 failure are both kept
#                   exactly once; interruption before any tail collection leaves them on disk.
#
# The local listener is a private evidence collaborator for this test only; it is NOT a window measurement and
# must never be reported as one.
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [int]$RequestsBeforeInterrupt = 5,
    [int]$SlowResponseMinMs = 300,
    [int]$PersistLagBudgetMs = 150
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P13c4Evidence.ps1')
Add-Type -AssemblyName System.Net.Http | Out-Null
# a tracked slow read and a blocking request can be in flight together; do not rely on the .NET Framework default
[System.Net.ServicePointManager]::DefaultConnectionLimit = 16

$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3c-4-ledger-offline' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ requests_before_interrupt = $RequestsBeforeInterrupt; slow_response_min_ms = $SlowResponseMinMs; persist_lag_budget_ms = $PersistLagBudgetMs } `
        -Targets @() -DataSet 'offline'
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-56} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'fail' }), $d
}
function Get-Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }

# ---------------------------------------------------------------- private local endpoint (counts every hit)
$listener = New-Object System.Net.HttpListener
$port = 18000 + (Get-Random -Minimum 0 -Maximum 900)
$prefix = "http://127.0.0.1:$port/"
$listener.Prefixes.Add($prefix)
$listener.Start()
$script:hits = 0
$ctr = Join-Path $outDir 'listener-hits.txt'
function New-Answer([string]$text, [int]$status = 200) {
    $script:hits++
    Add-Content -LiteralPath $ctr -Value "$($script:hits)"
    return [pscustomobject]@{ Text = $text; Bytes = [System.Text.Encoding]::UTF8.GetBytes($text); Status = $status }
}
function Answer-Full([System.Net.HttpListenerContext]$ctx, $answer) {
    $ctx.Response.StatusCode = $answer.Status
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.ContentLength64 = $answer.Bytes.Length
    $ctx.Response.OutputStream.Write($answer.Bytes, 0, $answer.Bytes.Length)
    $ctx.Response.OutputStream.Close()
    $ctx.Response.Close()
}

# ---------------------------------------------------------------- baseline fixtures
$fixDir = Join-Path $outDir 'baseline-fixtures'
New-Item -ItemType Directory -Path $fixDir -Force | Out-Null
$ids = @(9007199254743401L, 9007199254743402L, 9007199254743403L)
$fakeSha = ('a' * 64)
function New-BaselineFile([string]$path, [string]$scope, [long[]]$targets, [string]$fields) {
    $rows = @()
    foreach ($t in $targets) {
        $rows += [ordered]@{ article_id = $t; fields = $fields; tables_sha256 = ("$fakeSha,$fakeSha,$fakeSha") }
    }
    $obj = [ordered]@{ scope = $scope; captured_local = (Get-Date -Format 'o'); run_root = $RunRoot; database = 'fake'; tables = @('a', 'b', 'c'); targets = $rows }
    [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 5), $utf8)
    return (Get-Sha $path)
}
$goodFile = Join-Path $fixDir 'good.json'
$goodSha = New-BaselineFile $goodFile 'P1.3c-4-window-shared' $ids '7|7|7|7'
$wrongFieldsFile = Join-Path $fixDir 'wrong-fields.json'
$wrongFieldsSha = New-BaselineFile $wrongFieldsFile 'P1.3c-4-window-shared' $ids 'not-a-snapshot'
$foreignScopeFile = Join-Path $fixDir 'foreign-scope.json'
$foreignScopeSha = New-BaselineFile $foreignScopeFile 'some-other-card' $ids '7|7|7|7'
$wrongIdsFile = Join-Path $fixDir 'wrong-ids.json'
$wrongIdsSha = New-BaselineFile $wrongIdsFile 'P1.3c-4-window-shared' @(9007199254743401L) '7|7|7|7'

$refusals = @(
    @{ name = 'missing_file'; file = (Join-Path $fixDir 'does-not-exist.json'); sha = $goodSha; why = 'missing baseline file' },
    @{ name = 'sha_mismatch'; file = $goodFile; sha = ('b' * 64); why = 'sha256 mismatch' },
    @{ name = 'foreign_scope'; file = $foreignScopeFile; sha = $foreignScopeSha; why = 'scope is another card' },
    @{ name = 'wrong_ids'; file = $wrongIdsFile; sha = $wrongIdsSha; why = 'target ids differ' },
    @{ name = 'no_field_snapshot'; file = $wrongFieldsFile; sha = $wrongFieldsSha; why = 'no four-field snapshot' }
)
$refusedOk = $true
$hitsBefore = $script:hits
foreach ($r in $refusals) {
    $refused = $false
    $msg = ''
    try { $null = Assert-P13c4Baseline -File $r.file -ExpectedSha256 $r.sha -ExpectedScope 'P1.3c-4-window-shared' -ExpectedIds $ids }
    catch { $refused = $true; $msg = $_.Exception.Message }
    $ok = ($refused -and ($script:hits -eq $hitsBefore))
    if (-not $ok) { $refusedOk = $false }
    $flat = ($msg -replace '\s+', ' ')
    Add-Check ("baseline.{0}_refused_with_no_call" -f $r.name) $ok `
        ("refused={0} external_calls={1} ({2}) msg={3}" -f $refused, ($script:hits - $hitsBefore), $r.why, $flat.Substring(0, [Math]::Min(70, $flat.Length)))
}
Add-Check 'baseline.refusals_made_zero_external_calls' ($script:hits -eq 0) "local endpoint hits after every refusal: $($script:hits)"
$accepted = $null
$acceptedError = ''
try { $accepted = Assert-P13c4Baseline -File $goodFile -ExpectedSha256 $goodSha -ExpectedScope 'P1.3c-4-window-shared' -ExpectedIds $ids } catch { $acceptedError = $_.Exception.Message }
Add-Check 'baseline.valid_file_accepted' ($null -ne $accepted -and $accepted.scope -eq 'P1.3c-4-window-shared' -and @($accepted.targets).Count -eq 3) `
    "accepted scope=$($accepted.scope) targets=$(@($accepted.targets).Count) $acceptedError"

# ---------------------------------------------------------------- ledger: sync path, read while open
$ledgerPath = Join-Path $outDir 'requests.jsonl'
$ledger = New-P13c4RequestLedger -Path $ledgerPath -RunId $RunId
$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromSeconds(30)
$script:localSeq = 0

function Send-One([string]$path, [string]$reqId, [string]$kind, [int]$status = 200) {
    $started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $respTask = $client.GetAsync($prefix + $path)
    $ctx = $listener.GetContext()
    $answer = New-Answer ('{"views":' + (1000 + $script:hits) + ',"ok":true}') $status
    Answer-Full $ctx $answer
    $resp = $respTask.GetAwaiter().GetResult()
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $ended = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $rec = [ordered]@{
        local_seq = $script:localSeq++; kind = $kind; request_id = $reqId; method = 'Get'; path = "/$path"
        started_ms = $started; ended_ms = $ended; elapsed_ms = $ended - $started
        http = [int]$resp.StatusCode; bytes = $bytes.Length
        sha256 = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
        body = $text; views = (Get-P13c4Views $text)
    }
    $null = $ledger.Add($rec)
    return [pscustomobject]$rec
}
function Test-LedgerNow([int]$expectedCount) {
    # the ONE reader must work against the still-open writer, and the last line must be the record just written
    $now = @(Read-P13c4LedgerLines -Path $ledgerPath)
    if ($now.Count -ne $expectedCount) { return $false }
    $last = $now[$now.Count - 1] | ConvertFrom-Json
    $b = [System.Text.Encoding]::UTF8.GetBytes([string]$last.body)
    if ($b.Length -ne [int]$last.bytes) { return $false }
    $sha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($b)) -replace '-', '').ToLower()
    return ($sha -eq $last.sha256 -and [long]$last.persisted_ms -ge [long]$last.ended_ms)
}

$flushedBeforeNext = $true
$readWhileOpenOk = $true
$issued = 0
$interrupted = $false
$interruptMsg = ''
try {
    while ($true) {
        if ($issued -ge $RequestsBeforeInterrupt) {
            # controlled interruption: the run stops on purpose, like a crash mid-experiment
            throw "controlled interruption after $issued requests"
        }
        $issued++
        $null = Send-One "detail/$issued" "$RunId-req$issued" 'fast'
        if (-not (Test-LedgerNow $issued)) { $readWhileOpenOk = $false; $flushedBeforeNext = $false }
    }
} catch {
    $interrupted = $true
    $interruptMsg = $_.Exception.Message
}
$hitsAtInterrupt = $script:hits

Add-Check 'ledger.interruption_happened' ($interrupted -and $interruptMsg -match 'controlled interruption') "interrupted=$interrupted msg='$interruptMsg'"
Add-Check 'ledger.flushed_before_next_request' $flushedBeforeNext `
    "after every Add the file already held exactly that many lines (no record waited for the end of the run)"
Add-Check 'ledger.read_while_open_after_each_add' $readWhileOpenOk `
    "$issued Adds read back with the writer still open: count, JSON, bytes, sha256 and persisted>=ended all matched"
$linesOpen = @(Read-P13c4LedgerLines -Path $ledgerPath)
Add-Check 'ledger.prefix_is_complete_and_parseable' ($linesOpen.Count -eq $RequestsBeforeInterrupt) `
    "lines=$($linesOpen.Count) expected=$RequestsBeforeInterrupt (read while the writer is still open)"
Add-Check 'ledger.no_sixth_request_after_interruption' ($hitsAtInterrupt -eq $RequestsBeforeInterrupt) `
    "local endpoint hits=$hitsAtInterrupt expected=$RequestsBeforeInterrupt (the interrupted run issued nothing after the failure)"
$parseOk = 0
$shaOk = 0
$bytesOk = 0
foreach ($l in $linesOpen) {
    try { $o = $l | ConvertFrom-Json; $parseOk++ } catch { continue }
    $b = [System.Text.Encoding]::UTF8.GetBytes([string]$o.body)
    if ($b.Length -eq [int]$o.bytes) { $bytesOk++ }
    if (([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($b)) -replace '-', '').ToLower() -eq $o.sha256) { $shaOk++ }
}
Add-Check 'ledger.recomputable_bytes_and_hashes' ($bytesOk -eq $linesOpen.Count -and $shaOk -eq $linesOpen.Count) `
    "bytes match=$bytesOk/$($linesOpen.Count) sha256 match=$shaOk/$($linesOpen.Count) (each line carries the raw body)"

# ---------------------------------------------------------------- tracked async: completion-time persistence
# The listener answers the slow request in two pieces: headers + 1 byte now, the rest after SlowResponseMinMs.
# The client's SendAsync only completes when the whole body has arrived, which is the completion timestamp.
$script:asyncSeq = 0
function Start-Tracked([string]$path, [string]$reqId, [string]$kind) {
    $script:asyncSeq++
    return Start-P13c4AsyncGet -Client $client -Base $prefix -Path $path -ReqId $reqId -Kind $kind -RunId $RunId -LocalSeq (9000 + $script:asyncSeq)
}
$slowPending = Start-Tracked "slow/1" "$RunId-slow1" 'slow-reader'
$slowCtx = $listener.GetContext()
$slowAnswer = New-Answer '{"views":4242,"ok":true}'
$slowCtx.Response.ContentType = 'application/json'
$slowCtx.Response.ContentLength64 = $slowAnswer.Bytes.Length
$slowCtx.Response.OutputStream.Write($slowAnswer.Bytes, 0, 1)
$slowCtx.Response.OutputStream.Flush()

# while the response is still incomplete: two fast requests are dispatched and persisted, the slow one is not
$linesBeforeFast = @(Read-P13c4LedgerLines -Path $ledgerPath).Count
$null = Send-One 'fast/1' "$RunId-fast1" 'fast'
$null = Send-One 'fast/2' "$RunId-fast2" 'fast'
$slowIncomplete = -not $slowPending.task.IsCompleted
$slowAbsentWhileIncomplete = (@(Read-P13c4LedgerLines -Path $ledgerPath) | Where-Object { $_ -match [regex]::Escape("$RunId-slow1") }).Count -eq 0

$waitUntil = $slowPending.dispatched_ms + $SlowResponseMinMs
while ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $waitUntil) { Start-Sleep -Milliseconds 5 }
$slowCtx.Response.OutputStream.Write($slowAnswer.Bytes, 1, $slowAnswer.Bytes.Length - 1)
$slowCtx.Response.OutputStream.Close()
$slowCtx.Response.Close()

$persisted = Wait-P13c4CompletionPersist -Pending $slowPending -Ledger $ledger -SliceMs 3 -DeadlineMs 10000
$slow = $slowPending.record
$slowLag = $slowPending.persisted_ms - $slowPending.completed_ms
$linesAfterSlow = @(Read-P13c4LedgerLines -Path $ledgerPath).Count
$slowLine = (@(Read-P13c4LedgerLines -Path $ledgerPath) | Where-Object { $_ -match [regex]::Escape("$RunId-slow1") })
$slowParsed = $null
if (@($slowLine).Count -eq 1) { $slowParsed = @($slowLine)[0] | ConvertFrom-Json }
$slowWrittenBeforeNextDispatch = $false
$lineCountBeforeNext = @(Read-P13c4LedgerLines -Path $ledgerPath).Count
$null = Send-One 'fast/3' "$RunId-fast3" 'fast'
if ($lineCountBeforeNext -eq $linesAfterSlow) { $slowWrittenBeforeNextDispatch = $true }

Add-Check 'async.slow_response_incomplete_is_not_on_disk' ($slowIncomplete -and $slowAbsentWhileIncomplete) `
    "task completed while the body was incomplete=$($slowPending.task.IsCompleted); slow record present on disk before completion=$(-not $slowAbsentWhileIncomplete)"
Add-Check 'async.persisted_at_client_completion' ($persisted -and $slowLag -ge 0 -and $slowLag -le $PersistLagBudgetMs) `
    ("completed={0}ms persisted={1}ms lag={2}ms (budget {3}ms; not deferred to a tail collection)" -f $slowPending.completed_ms, $slowPending.persisted_ms, $slowLag, $PersistLagBudgetMs)
Add-Check 'async.record_kept_exactly_once' (@($slowLine).Count -eq 1 -and $null -ne $slowParsed -and [int]$slowParsed.views -eq 4242 -and [int]$slowParsed.http -eq 200) `
    "matching lines=$(@($slowLine).Count) views=$($slowParsed.views) http=$($slowParsed.http) bytes=$($slowParsed.bytes)"
Add-Check 'async.completed_before_persist_and_ended_is_completion' ($null -ne $slowParsed -and [long]$slowParsed.last_incomplete_ms -le [long]$slowParsed.ended_ms -and [long]$slowParsed.persisted_ms -ge [long]$slowParsed.ended_ms) `
    ("record carries the bracket: last_incomplete_ms={0} <= ended_ms={1} (completion OBSERVED, not claimed) and persisted_ms={2} >= ended_ms" -f $slowParsed.last_incomplete_ms, $slowParsed.ended_ms, $slowParsed.persisted_ms)
Add-Check 'async.persisted_before_next_dispatch' $slowWrittenBeforeNextDispatch `
    "line count before the next request was dispatched=$lineCountBeforeNext (already includes the slow record)"

# failure path: the same tracked request, answered with 500
$failPending = Start-Tracked "fail/1" "$RunId-fail1" 'slow-reader'
$failCtx = $listener.GetContext()
$failAnswer = New-Answer '{"code":503,"errorMessage":"server busy"}' 500
Answer-Full $failCtx $failAnswer
$failPersisted = Wait-P13c4CompletionPersist -Pending $failPending -Ledger $ledger -SliceMs 3 -DeadlineMs 10000
$failLines = @(Read-P13c4LedgerLines -Path $ledgerPath) | Where-Object { $_ -match [regex]::Escape("$RunId-fail1") }
$failParsed = $null
if (@($failLines).Count -eq 1) { $failParsed = @($failLines)[0] | ConvertFrom-Json }
Add-Check 'async.failure_body_kept' ($failPersisted -and @($failLines).Count -eq 1 -and $null -ne $failParsed -and [int]$failParsed.http -eq 500 -and "$($failParsed.body)" -match 'server busy') `
    "lines=$(@($failLines).Count) http=$($failParsed.http) body-preserved=$("$($failParsed.body)" -match 'server busy')"

# ---------------------------------------------------------------- persistence while another wait is blocking
# The real window script waits for EVERY HTTP response through Send-P13c4Responsive. This case drives that very
# function with a private endpoint that finishes a tracked slow body at ~200ms while the blocking request is only
# answered at ~1500ms: the question is whether the finished slow read is on disk WHILE the caller is still blocked,
# and how long after the SERVER finished writing the record actually reached the disk.
$observerPath = Join-Path $outDir 'ledger-observer.ps1'
$obsOut = Join-Path $outDir 'observer-first-seen.tsv'
$obsReady = Join-Path $outDir 'observer-ready.txt'
$observerSource = @'
# Independent observer (separate process). It only READS the ledger with FileShare.ReadWrite and records the first
# moment each request id became visible on disk. It never writes a ledger record and never helps the code under test.
param(
    [Parameter(Mandatory = $true)][string]$Ledger,
    [Parameter(Mandatory = $true)][string]$Out,
    [Parameter(Mandatory = $true)][string]$Ready,
    [int]$RunMs = 6000
)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$seen = @{}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$announced = $false
while ($sw.ElapsedMilliseconds -lt $RunMs) {
    $text = ''
    $fs = $null
    $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($Ledger, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, $utf8)
        $text = $sr.ReadToEnd()
    } catch {
        $text = ''
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
    foreach ($l in ($text -split "`r?`n")) {
        if ($l.Trim().Length -eq 0) { continue }
        $m = [regex]::Match($l, 'request_id"\s*:\s*"([^"]+)"')
        if (-not $m.Success) { continue }
        $id = $m.Groups[1].Value
        if (-not $seen.ContainsKey($id)) {
            $seen[$id] = $true
            $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            [System.IO.File]::AppendAllText($Out, ("{0}`t{1}`n" -f $id, $stamp), $utf8)
        }
    }
    if (-not $announced) {
        [System.IO.File]::WriteAllText($Ready, 'ready', $utf8)
        $announced = $true
    }
    Start-Sleep -Milliseconds 5
}
exit 0
'@

[System.IO.File]::WriteAllText($observerPath, $observerSource, $utf8)
$obsProc = $null
$observerReady = $false
try {
    $obsProc = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $observerPath, '-Ledger', $ledgerPath, '-Out', $obsOut, '-Ready', $obsReady, '-RunMs', '20000')
    # the observer is a separate process; its start-up latency is not part of any measurement, so wait generously
    $swReady = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $obsReady) -and $swReady.ElapsedMilliseconds -lt 45000) { Start-Sleep -Milliseconds 20 }
    $observerReady = Test-Path -LiteralPath $obsReady
} catch {
    $observerReady = $false
}
$script:blockAnswer = New-Answer '{"views":4400,"ok":true}'
$slow3Text = '{"views":4300,"ok":true}'
$slow3Bytes = [System.Text.Encoding]::UTF8.GetBytes($slow3Text)
$script:blockCtx = $null
$script:blockDoneAt = -1
$script:slow3DoneAt = -1
$script:slow3Ctx = $null
$script:asyncSeq++
$slow3Pending = Start-P13c4AsyncGet -Client $client -Base $prefix -Path 'slow/3' -ReqId "$RunId-slow3" -Kind 'slow-reader' -RunId $RunId -LocalSeq (9000 + $script:asyncSeq)
$script:slow3Ctx = $listener.GetContext()
$script:slow3Ctx.Response.ContentType = 'application/json'
$script:slow3Ctx.Response.ContentLength64 = $slow3Bytes.Length
$script:slow3Ctx.Response.OutputStream.Write($slow3Bytes, 0, 1)
$script:slow3Ctx.Response.OutputStream.Flush()
$blockHook = {
    param($elapsed)
    if ($null -eq $script:blockCtx) {
        $script:blockCtx = $listener.GetContext()
        $script:blockCtx.Response.ContentType = 'application/json'
        $script:blockCtx.Response.ContentLength64 = $script:blockAnswer.Bytes.Length
        $script:blockCtx.Response.OutputStream.Write($script:blockAnswer.Bytes, 0, 1)
        $script:blockCtx.Response.OutputStream.Flush()
    }
    if ($script:slow3DoneAt -lt 0 -and $elapsed -ge 200) {
        $script:slow3Ctx.Response.OutputStream.Write($slow3Bytes, 1, $slow3Bytes.Length - 1)
        $script:slow3Ctx.Response.OutputStream.Close()
        $script:slow3Ctx.Response.Close()
        $script:slow3DoneAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    if ($script:blockDoneAt -lt 0 -and $elapsed -ge 1500) {
        $script:blockCtx.Response.OutputStream.Write($script:blockAnswer.Bytes, 1, $script:blockAnswer.Bytes.Length - 1)
        $script:blockCtx.Response.OutputStream.Close()
        $script:blockCtx.Response.Close()
        $script:blockDoneAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
}
$script:localSeq++
$blockSeq = $script:localSeq
$blockStartedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$blockReq = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "${prefix}block/1")
$blockTask = Send-P13c4Responsive -Client $client -Request $blockReq -Tracked @($slow3Pending) -Ledger $ledger -SliceMs 3 -TimeoutMs 20000 -SliceHook $blockHook
$blockReturnedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$blockResp = $blockTask.GetAwaiter().GetResult()
$blockBytes = $blockResp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
$blockText = [System.Text.Encoding]::UTF8.GetString($blockBytes)
$blockRec = [ordered]@{
    local_seq = $blockSeq; kind = 'sample'; request_id = "$RunId-block1"; method = 'Get'; path = '/block/1'
    started_ms = $blockStartedMs; ended_ms = $blockReturnedMs; elapsed_ms = $blockReturnedMs - $blockStartedMs
    http = [int]$blockResp.StatusCode; bytes = $blockBytes.Length
    sha256 = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($blockBytes)) -replace '-', '').ToLower()
    body = $blockText; views = (Get-P13c4Views $blockText)
}
$null = $ledger.Add($blockRec)

$slow3Lines = @(Read-P13c4LedgerLines -Path $ledgerPath) | Where-Object { $_ -match [regex]::Escape("$RunId-slow3") }
$slow3Parsed = $null
if (@($slow3Lines).Count -eq 1) { $slow3Parsed = @($slow3Lines)[0] | ConvertFrom-Json }
$blockLines = @(Read-P13c4LedgerLines -Path $ledgerPath) | Where-Object { $_ -match [regex]::Escape("$RunId-block1") }
$slow3PersistedMs = -1
$slow3EndedMs = -1
$slow3LastIncompleteMs = -1
$hasFlushInLine = $true
if ($null -ne $slow3Parsed) {
    $slow3PersistedMs = [long]$slow3Parsed.persisted_ms
    $slow3EndedMs = [long]$slow3Parsed.ended_ms
    $slow3LastIncompleteMs = [long]$slow3Parsed.last_incomplete_ms
    $hasFlushInLine = ($null -ne $slow3Parsed.PSObject.Properties['flush_returned_ms'])
}
$slow3OnDiskBeforeBlockReturned = ($null -ne $slow3Parsed -and $slow3PersistedMs -lt $blockReturnedMs)
$realToFlush = -1
if ($null -ne $slow3Parsed -and $script:slow3DoneAt -gt 0) { $realToFlush = $slow3PersistedMs - $script:slow3DoneAt }
$bracketOk = ($null -ne $slow3Parsed -and $slow3LastIncompleteMs -le $slow3EndedMs -and $script:slow3DoneAt -le $slow3EndedMs)
Add-Check 'async.persisted_while_sample_blocked' ($slow3Pending.persisted -and $slow3OnDiskBeforeBlockReturned) `
    ("slow write_start={0}ms < blocking sample returned={1}ms (sample dispatched {2}ms, server finished the slow body {3}ms)" -f $slow3PersistedMs, $blockReturnedMs, $blockStartedMs, $script:slow3DoneAt)
Add-Check 'async.real_completion_to_flush_within_budget' ($realToFlush -ge 0 -and $realToFlush -le $PersistLagBudgetMs) `
    ("server finished writing the slow body {0}ms -> write_start {1}ms = {2}ms (budget {3}ms; ground truth is the listener, not a self-reported poll stamp)" -f $script:slow3DoneAt, $slow3PersistedMs, $realToFlush, $PersistLagBudgetMs)
Add-Check 'async.completion_bracket_bounds_real_completion' $bracketOk `
    ("last_incomplete_ms={0} <= server_finished={1} <= ended_ms(observed)={2}: the line brackets the real transition instead of claiming a poll stamp" -f $slow3LastIncompleteMs, $script:slow3DoneAt, $slow3EndedMs)
Add-Check 'async.flush_return_listed_separately' ($slow3Pending.flush_returned_ms -ge $slow3Pending.persisted_ms -and $null -ne $slow3Parsed -and -not $hasFlushInLine) `
    ("persisted_ms={0} is the write-start marker INSIDE the line; Flush returned {1}ms after it and is listed in the result, not in its own line" -f $slow3Pending.persisted_ms, ($slow3Pending.flush_returned_ms - $slow3Pending.persisted_ms))
Add-Check 'async.blocking_sample_kept_once' (@($blockLines).Count -eq 1) `
    "blocking sample record lines=$(@($blockLines).Count) (written after it returned, exactly once)"

# ------- the independent observer's view of the same moment
if ($null -ne $obsProc) { [void]$obsProc.WaitForExit(15000) }
$firstSeen = @{}
if (Test-Path -LiteralPath $obsOut) {
    foreach ($l in [System.IO.File]::ReadAllLines($obsOut, $utf8)) {
        if ($l.Trim().Length -eq 0) { continue }
        $f = $l -split "`t"
        if ($f.Length -ge 2) { $firstSeen[$f[0]] = [long]$f[1] }
    }
}
$obsSlow3 = -1
if ($firstSeen.ContainsKey("$RunId-slow3")) { $obsSlow3 = $firstSeen["$RunId-slow3"] }
$obsBeforeReturn = ($observerReady -and $obsSlow3 -gt 0 -and $obsSlow3 -lt $blockReturnedMs)
Add-Check 'async.record_independently_visible_while_still_blocked' $obsBeforeReturn `
    ("independent observer process first saw the slow record at {0}ms, {1}ms BEFORE the blocking sample returned at {2}ms (observer ready={3}; it only reads the file)" -f $obsSlow3, ($blockReturnedMs - $obsSlow3), $blockReturnedMs, $observerReady)
$obsBudget = -1
if ($obsSlow3 -gt 0 -and $script:slow3DoneAt -gt 0) { $obsBudget = $obsSlow3 - $script:slow3DoneAt }
Add-Check 'async.observer_confirms_real_completion_budget' ($observerReady -and $obsSlow3 -gt 0 -and $obsBudget -ge 0 -and $obsBudget -le $PersistLagBudgetMs) `
    ("observer first-visible {0}ms - server finished {1}ms = {2}ms (budget {3}ms; a poll-only self-report would not prove this)" -f $obsSlow3, $script:slow3DoneAt, $obsBudget, $PersistLagBudgetMs)

# ------- interruption WHILE the blocking wait is still running: what already completed must survive it
$slow4Text = '{"views":4500,"ok":true}'
$slow4Bytes = [System.Text.Encoding]::UTF8.GetBytes($slow4Text)
$script:slow4DoneAt = -1
$script:block2Ctx = $null
$script:slow4Ctx = $null
$script:asyncSeq++
$slow4Pending = Start-P13c4AsyncGet -Client $client -Base $prefix -Path 'slow/4' -ReqId "$RunId-slow4" -Kind 'slow-reader' -RunId $RunId -LocalSeq (9000 + $script:asyncSeq)
$script:slow4Ctx = $listener.GetContext()
$script:slow4Ctx.Response.ContentType = 'application/json'
$script:slow4Ctx.Response.ContentLength64 = $slow4Bytes.Length
$script:slow4Ctx.Response.OutputStream.Write($slow4Bytes, 0, 1)
$script:slow4Ctx.Response.OutputStream.Flush()
$script:localSeq++
$script:issuedWithoutRecord = 1
$block2Req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "${prefix}block/2")
$block2Hook = {
    param($elapsed)
    if ($null -eq $script:block2Ctx) { $script:block2Ctx = $listener.GetContext() }
    if ($script:slow4DoneAt -lt 0 -and $elapsed -ge 200) {
        $script:slow4Ctx.Response.OutputStream.Write($slow4Bytes, 1, $slow4Bytes.Length - 1)
        $script:slow4Ctx.Response.OutputStream.Close()
        $script:slow4Ctx.Response.Close()
        $script:slow4DoneAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    if ($elapsed -ge 1200) { throw 'controlled interruption while the sample was still blocked' }
}
$block2Interrupted = $false
$block2Msg = ''
try {
    $null = Send-P13c4Responsive -Client $client -Request $block2Req -Tracked @($slow4Pending) -Ledger $ledger -SliceMs 3 -TimeoutMs 20000 -SliceHook $block2Hook
} catch {
    $block2Interrupted = $true
    $block2Msg = $_.Exception.Message
}
try { if ($null -ne $script:block2Ctx) { $script:block2Ctx.Response.Abort() } } catch { }
$afterInterrupt = @(Read-P13c4LedgerLines -Path $ledgerPath)
$slow4Lines = @($afterInterrupt | Where-Object { $_ -match [regex]::Escape("$RunId-slow4") })
$block2Lines = @($afterInterrupt | Where-Object { $_ -match [regex]::Escape("$RunId-block2") })
$slow4Parsed = $null
if (@($slow4Lines).Count -eq 1) { $slow4Parsed = @($slow4Lines)[0] | ConvertFrom-Json }
$slow4Recomputable = $false
$slow4BytesBack = -1
if ($null -ne $slow4Parsed) {
    $back = [System.Text.Encoding]::UTF8.GetBytes([string]$slow4Parsed.body)
    $slow4BytesBack = $back.Length
    $shaBack = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($back)) -replace '-', '').ToLower()
    $slow4Recomputable = ($shaBack -eq [string]$slow4Parsed.sha256 -and $slow4BytesBack -eq [int]$slow4Parsed.bytes)
}
Add-Check 'async.interruption_during_block_keeps_completed' ($block2Interrupted -and @($slow4Lines).Count -eq 1 -and $slow4Recomputable -and $slow4Pending.persisted) `
    ("interrupted='{0}'; the slow read finished at {1}ms during the block and survived: lines={2} bytes={3} sha256-recomputable={4} persisted_ms={5}" -f $block2Msg, $script:slow4DoneAt, @($slow4Lines).Count, $slow4BytesBack, $slow4Recomputable, $(if ($null -ne $slow4Parsed) { $slow4Parsed.persisted_ms } else { -1 }))
Add-Check 'async.interruption_during_block_does_not_fabricate' (@($block2Lines).Count -eq 0 -and $null -ne $script:block2Ctx) `
    "the interrupted sample never completed, so it has no record (lines=$(@($block2Lines).Count)) and nothing was invented for it"
# interruption before ANY tail collection: what was completed must already be on disk
$interruptedTail = $false
$tailMsg = ''
try {
    throw 'controlled interruption before tail collection'
} catch {
    $interruptedTail = $true
    $tailMsg = $_.Exception.Message
}
$linesAtTail = @(Read-P13c4LedgerLines -Path $ledgerPath)
$hasSlow = @($linesAtTail | Where-Object { $_ -match [regex]::Escape("$RunId-slow1") }).Count -eq 1
$hasFail = @($linesAtTail | Where-Object { $_ -match [regex]::Escape("$RunId-fail1") }).Count -eq 1
$allParse = $true
foreach ($l in $linesAtTail) { try { $null = $l | ConvertFrom-Json } catch { $allParse = $false } }
Add-Check 'async.survives_interruption_before_tail' ($interruptedTail -and $hasSlow -and $hasFail -and $allParse) `
    "interrupted='$tailMsg' lines=$($linesAtTail.Count) slow=$hasSlow fail=$hasFail all-parseable=$allParse"

# the whole file, read again after the writer is closed, must be one record per request in write order
$onDiskOpen = @(Read-P13c4LedgerLines -Path $ledgerPath)
$ledger.Close()
$onDisk = @(Read-P13c4LedgerLines -Path $ledgerPath)
$seqOk = $true
$orderOk = $true
$idsSeen = New-Object System.Collections.ArrayList
$expectedSeq = 1
foreach ($l in $onDisk) {
    $o = $l | ConvertFrom-Json
    if ([long]$o.seq -ne $expectedSeq) { $seqOk = $false }
    $expectedSeq++
    $null = $idsSeen.Add([string]$o.request_id)
    if ([long]$o.persisted_ms -lt [long]$o.ended_ms) { $orderOk = $false }
}
$uniqueIds = @($idsSeen | Sort-Object -Unique).Count
Add-Check 'ledger.readable_while_stream_open' ($onDiskOpen.Count -eq $onDisk.Count -and $onDiskOpen.Count -gt 0) `
    "read with the writer still open returned $($onDiskOpen.Count) lines, after close $($onDisk.Count) (no sharing violation, no early close)"
if ($null -eq $script:issuedWithoutRecord) { $script:issuedWithoutRecord = 0 }
$expectedRecords = $script:localSeq + $script:asyncSeq - $script:issuedWithoutRecord
Add-Check 'ledger.every_request_on_disk' ($onDisk.Count -eq $expectedRecords -and $onDisk.Count -gt 0) `
    "lines=$($onDisk.Count) issued=$($script:localSeq + $script:asyncSeq) - never-completed=$($script:issuedWithoutRecord) = $expectedRecords (sync + tracked async, flushed per request)"
Add-Check 'ledger.one_record_per_request_in_order' ($seqOk -and $uniqueIds -eq $onDisk.Count) `
    "seq is 1..$($onDisk.Count)=$seqOk unique request ids=$uniqueIds of $($onDisk.Count) (exactly one write per request)"
Add-Check 'ledger.completion_recorded_before_persist' $orderOk 'every record has persisted_ms >= ended_ms'
$ledgerSha = Get-Sha $ledgerPath
Add-Check 'ledger.file_on_disk' ((Test-Path -LiteralPath $ledgerPath) -and $ledgerSha.Length -eq 64) "path=requests.jsonl sha256=$ledgerSha"

$client.Dispose()
$listener.Stop()
$listener.Close()

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    baseline_fixtures = [ordered]@{ good = $goodFile; good_sha256 = $goodSha; foreign_scope = $foreignScopeFile; wrong_ids = $wrongIdsFile; wrong_fields = $wrongFieldsFile }
    baseline_refusals = @($refusals | ForEach-Object { $_.name })
    listener_hits_total = $script:hits
    ledger = [ordered]@{ path = 'requests.jsonl'; sha256 = $ledgerSha; lines = $onDisk.Count; sync_requests = $script:localSeq; async_requests = $script:asyncSeq; requests_before_interrupt = $RequestsBeforeInterrupt }
    async_probe = [ordered]@{
        slow_response_min_ms = $SlowResponseMinMs; persist_lag_budget_ms = $PersistLagBudgetMs
        slow = [ordered]@{ dispatched_ms = $slowPending.dispatched_ms; completed_ms = $slowPending.completed_ms; persisted_ms = $slowPending.persisted_ms; lag_ms = $slowLag; views = $slowParsed.views; http = $slowParsed.http }
        failure = [ordered]@{ http = $failParsed.http; body = $failParsed.body; persisted_ms = $failParsed.persisted_ms }
        blocked_sample = [ordered]@{
            slow = [ordered]@{
                dispatched_ms = $slow3Pending.dispatched_ms
                last_incomplete_ms = $slow3LastIncompleteMs
                completed_observed_ms = $slow3EndedMs
                write_start_ms = $slow3PersistedMs
                flush_returned_ms = $slow3Pending.flush_returned_ms
                server_finished_ms = $script:slow3DoneAt
                real_completion_to_flush_ms = $realToFlush
                observer_first_seen_ms = $obsSlow3
                observer_bracket_ms = $obsBudget
            }
            blocking_sample = [ordered]@{ dispatched_ms = $blockStartedMs; returned_ms = $blockReturnedMs; record_persisted_ms = $(if (@($blockLines).Count -eq 1) { [long](@($blockLines)[0] | ConvertFrom-Json).persisted_ms } else { -1 }) }
            observer_ready = $observerReady
        }
        interruption_during_block = [ordered]@{
            interrupted = $block2Interrupted; message = $block2Msg
            slow_completed_ms = $script:slow4DoneAt
            slow_lines = @($slow4Lines).Count
            slow_recomputable = $slow4Recomputable
            unwritten_sample_lines = @($block2Lines).Count
        }
    }
    note = 'private local endpoint used only to prove the persistence/gate mechanisms; it is not a window measurement'
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'ledger-offline-result.json') -Text ($result | ConvertTo-Json -Depth 8)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'ledger-offline-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
