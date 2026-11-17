# P1.3c-4 shared evidence helpers (ASCII only, dot-sourced by the scripts of this card).
#
# Two mechanisms live here so that every script of the card uses the SAME implementation:
#
#   New-P13c4RequestLedger   per-request persistence: one JSON line is appended and FLUSHED to disk as soon as
#                            a request completes or fails. The line carries the four DISTINCT stamps that the audit
#                            needs (dispatched -> last seen incomplete -> completion observed -> write start); the
#                            instant Flush() returned cannot live inside the line it just made durable, so it is
#                            listed separately in the run result as flush_returned_ms. Writers are serialized, each
#                            request is written exactly once, and the file can be read while it is still open.
#
#   Assert-P13c4Baseline     shared-baseline pre-gate: a mandatory baseline file, its SHA256, its scope and its
#                            target article ids/fields are verified BEFORE any HTTP/SQL/Redis work. A missing
#                            file, a hash mismatch or a foreign scope is a hard refusal with zero calls made.
#
#   Update-P13c4Tracked      services every in-flight tracked request: a completed client Task is persisted at
#                            once, an unfinished one only refreshes its "last seen incomplete" mark, which
#                            brackets the real completion from below instead of pretending a poll stamp is it.
#
#   Send-P13c4Responsive     the ONE way this card waits for any HTTP response: it slices the wait, so tracked
#                            requests keep being persisted while a synchronous-looking caller is still blocked.
#
#   Read-P13c4LedgerLines    the ONE reader (defined once, at the end of this file). It opens the file with
#                            FileShare.ReadWrite so it is compatible with the still-open writer stream, reads
#                            UTF-8 (bodies contain Chinese text), and retries briefly on a transient share/lock
#                            error instead of failing the run.
# Nothing here talks to the network, the database or Redis: the callers do that after the gate passes.

function New-P13c4RequestLedger {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RunId
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { throw "ledger directory does not exist: $dir" }
    # FileShare.ReadWrite: a verifier may read the file while this writer still holds it open
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $false
    $script:__p13c4Seq = 0
    $ledger = [pscustomobject]@{
        Path = $Path
        RunId = $RunId
        Count = 0
        Writer = $writer
        Stream = $stream
        Sync = (New-Object object)
    }
    $ledger | Add-Member -MemberType ScriptMethod -Name Add -Value {
        param($Record)
        # one write per request: a record that already carries a persisted marker must never be written twice
        if ($null -ne $Record.persisted_ms) { throw 'ledger: record was already persisted once' }
        [System.Threading.Monitor]::Enter($this.Sync)
        try {
            $script:__p13c4Seq++
            # persisted_ms goes INTO the line: it is the WRITE-START instant of the record (just before serialization).
            # flush_returned_ms cannot live inside the line it just made durable, so it is set on the in-memory
            # record only and listed separately in the run result (see the card's B section).
            $committed = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $Record['seq'] = $script:__p13c4Seq
            $Record['ledger_written_ms'] = $committed
            $Record['persisted_ms'] = $committed
            $line = $Record | ConvertTo-Json -Compress -Depth 6
            $this.Writer.WriteLine($line)
            # flush the managed buffer AND the OS file buffer: the line is on disk before the next request starts
            $this.Writer.Flush()
            $this.Stream.Flush($true)
            $this.Count = $this.Count + 1
            $returned = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $Record['flush_returned_ms'] = $returned
            $Record['flushed_ms'] = $returned
            return $script:__p13c4Seq
        } finally {
            [System.Threading.Monitor]::Exit($this.Sync)
        }
    }
    $ledger | Add-Member -MemberType ScriptMethod -Name Close -Value {
        [System.Threading.Monitor]::Enter($this.Sync)
        try {
            $this.Writer.Flush()
            $this.Stream.Flush($true)
            $this.Writer.Dispose()
            $this.Stream.Dispose()
        } finally {
            [System.Threading.Monitor]::Exit($this.Sync)
        }
    }
    return $ledger
}

function Assert-P13c4Baseline {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$ExpectedScope,
        [Parameter(Mandatory = $true)][long[]]$ExpectedIds
    )
    if (-not (Test-Path -LiteralPath $File)) { throw "BASELINE REFUSED: missing baseline file: $File" }
    $sha = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLower()
    if ($sha -ne $ExpectedSha256.ToLower()) { throw "BASELINE REFUSED: sha256 $sha != expected $ExpectedSha256" }
    $b = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json
    if ("$($b.scope)" -ne $ExpectedScope) { throw "BASELINE REFUSED: scope '$($b.scope)' != expected '$ExpectedScope'" }
    $have = @($b.targets | ForEach-Object { [long]$_.article_id } | Sort-Object)
    $want = @($ExpectedIds | Sort-Object)
    if (($have -join ',') -ne ($want -join ',')) {
        throw "BASELINE REFUSED: target ids '$($have -join ',')' != expected '$($want -join ',')'"
    }
    foreach ($t in $b.targets) {
        if ("$($t.fields)" -notmatch '^\d+\|\d+\|\d+\|\d+$') {
            throw "BASELINE REFUSED: article $($t.article_id) has no four-field snapshot ('$($t.fields)')"
        }
        if ("$($t.tables_sha256)" -notmatch '^[0-9a-f]{64},[0-9a-f]{64},[0-9a-f]{64}$') {
            throw "BASELINE REFUSED: article $($t.article_id) has no three-table capture hash"
        }
    }
    if (-not $b.captured_local) { throw 'BASELINE REFUSED: baseline carries no capture timestamp' }
    return $b
}

# The ONE reader. Opening with FileShare.ReadWrite is what makes it compatible with the writer stream that is
# still open: a default File.ReadAllText / [System.IO.File]::ReadAllText uses FileShare.Read only and therefore
# fails with a sharing violation against a handle that holds write access.
function Read-P13c4LedgerLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Retries = 5,
        [int]$RetryDelayMs = 20
    )
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $last = $null
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $fs = $null
        $sr = $null
        try {
            $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
            $text = $sr.ReadToEnd()
            return @($text -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
        } catch [System.IO.IOException] {
            $last = $_
            Start-Sleep -Milliseconds $RetryDelayMs
        } finally {
            if ($sr) { $sr.Dispose() }
            if ($fs) { $fs.Dispose() }
        }
    }
    throw "ledger read failed after $Retries attempts: $($last.Exception.Message)"
}

function Get-P13c4Views([string]$body) {
    $m = [regex]::Match($body, '"views"\s*:\s*(\d+)')
    if ($m.Success) { return [long]$m.Groups[1].Value }
    return -1
}

# A request that is dispatched now and whose record is written when the CLIENT owns the complete response.
# SendAsync() defaults to HttpCompletionOption.ResponseContentRead, so the task completes only after the whole
# body has been received. That instant cannot be read back out of the Task, so the record carries a BRACKET
# instead of a claim: the real completion lies in (last_incomplete_ms, task_completed_observed_ms].
function Start-P13c4AsyncGet {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ReqId,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$RunId,
        [int]$LocalSeq = 0,
        [string]$Note = 'slow reader'
    )
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base$Path")
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $ReqId)
    # the start stamp is taken BEFORE dispatch, never after it
    $dispatched = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $task = $Client.SendAsync($req)
    $pending = [pscustomobject]@{
        reqId = $ReqId; path = $Path; kind = $Kind; note = $Note; local_seq = $LocalSeq
        task = $task; record = $null; persisted = $false
        dispatched_ms = $dispatched
        last_incomplete_ms = $dispatched
        completed_ms = -1
        persisted_ms = -1
        write_start_ms = -1
        flush_returned_ms = -1
        # in-memory only: a Task that reached a terminal fault makes Wait() throw instead of returning false
        wait_threw = $false
        wait_error = ''
    }
    return $pending
}

function Complete-P13c4Get {
    param(
        [Parameter(Mandatory = $true)]$Pending,
        [Parameter(Mandatory = $true)]$Ledger
    )
    if ($Pending.persisted) { return $Pending.record }
    if (-not $Pending.task.IsCompleted) { return $null }
    # the client owns the complete response by now; this stamp is "completion OBSERVED", not a proof of the
    # exact transition instant: the record also carries last_incomplete_ms so the moment is bracketed.
    $completed = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $rec = [ordered]@{
        local_seq = $Pending.local_seq; kind = $Pending.kind; note = $Pending.note
        request_id = $Pending.reqId; method = 'Get'; path = $Pending.path
        started_ms = $Pending.dispatched_ms
        last_incomplete_ms = $Pending.last_incomplete_ms
        task_completed_observed_ms = $completed
        ended_ms = $completed
        elapsed_ms = $completed - $Pending.dispatched_ms
    }
    try {
        $resp = $Pending.task.GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $rec.http = [int]$resp.StatusCode
        $rec.bytes = $bytes.Length
        $rec.sha256 = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
        $rec.views = (Get-P13c4Views $text)
        $rec.body = $text
        $rec.ok = ($text -match '"ok"\s*:\s*true')
    } catch {
        $rec.http = -1
        $rec.error = $_.Exception.Message
        $rec.failure = $true
    }
    $null = $Ledger.Add($rec)
    $Pending.record = $rec
    $Pending.completed_ms = $completed
    $Pending.persisted_ms = [long]$rec.persisted_ms
    $Pending.write_start_ms = [long]$rec.persisted_ms
    $Pending.flush_returned_ms = [long]$rec.flush_returned_ms
    $Pending.persisted = $true
    return $rec
}

# Service EVERY in-flight tracked request. A completed client Task is written and flushed at once; an unfinished
# one only refreshes its "last seen incomplete" mark. This is what keeps persistence moving while a caller is
# still blocked inside a synchronous-looking HTTP wait.
function Update-P13c4Tracked {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()]$Tracked,
        [Parameter(Mandatory = $true)][AllowNull()]$Ledger
    )
    if ($null -eq $Tracked) { return 0 }
    $done = 0
    foreach ($p in @($Tracked)) {
        if ($null -eq $p) { continue }
        if ($p.persisted) { continue }
        if ($p.task.IsCompleted) {
            if ($null -ne (Complete-P13c4Get -Pending $p -Ledger $Ledger)) { $done++ }
        } else {
            $p.last_incomplete_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }
    }
    return $done
}

# The ONE responsive wait of this card: the caller looks synchronous, but the wait is sliced so every tracked
# request keeps being persisted while it runs. -SliceHook exists only for the offline tests' private endpoint
# (it advances a fake server response); it never touches the ledger.
function Send-P13c4Responsive {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)]$Request,
        [AllowNull()]$Tracked = $null,
        [AllowNull()]$Ledger = $null,
        [int]$SliceMs = 3,
        [int]$TimeoutMs = 30000,
        [AllowNull()][scriptblock]$SliceHook = $null
    )
    $task = $Client.SendAsync($Request)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $task.IsCompleted) {
        if ($null -ne $Tracked) { [void](Update-P13c4Tracked -Tracked $Tracked -Ledger $Ledger) }
        if ($null -ne $SliceHook) { & $SliceHook $sw.ElapsedMilliseconds }
        if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { throw "request timed out after $TimeoutMs ms: $($Request.RequestUri)" }
        try {
            [void]$task.Wait($SliceMs)
        } catch {
            # The awaited task faulted on a real transport failure (the connection was aborted while the body was
            # still arriving). A tracked request that already completed must still be served before this exception
            # leaves: the caller reports its own sample failure, and the finished records stay on disk.
            if ($null -ne $Tracked) { [void](Update-P13c4Tracked -Tracked $Tracked -Ledger $Ledger) }
            throw
        }
    }
    if ($null -ne $Tracked) { [void](Update-P13c4Tracked -Tracked $Tracked -Ledger $Ledger) }
    return $task
}

function Wait-P13c4CompletionPersist {
    param(
        [Parameter(Mandatory = $true)]$Pending,
        [Parameter(Mandatory = $true)]$Ledger,
        [int]$SliceMs = 3,
        [int]$DeadlineMs = 20000
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $DeadlineMs) {
        if ($null -ne (Complete-P13c4Get -Pending $Pending -Ledger $Ledger)) { return $true }
        $Pending.last_incomplete_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        # A Task that has ALREADY reached a terminal fault makes Wait() throw instead of returning false. That
        # exception is not a licence to drop the request: the terminal FAILURE RECEIPT is still produced by
        # Complete-P13c4Get, which owns the failure serialization. Only the Wait call itself is wrapped, so a
        # failure of the baseline gate, of Ledger.Add, of WriteLine or of Flush still surfaces unchanged.
        try {
            [void]$Pending.task.Wait($SliceMs)
        } catch {
            $Pending.wait_threw = $true
            $Pending.wait_error = $_.Exception.Message
            if ($null -ne (Complete-P13c4Get -Pending $Pending -Ledger $Ledger)) { return $true }
            # the task is not terminal after all: do not swallow, keep the previous behaviour
            throw
        }
    }
    return ($null -ne (Complete-P13c4Get -Pending $Pending -Ledger $Ledger))
}
