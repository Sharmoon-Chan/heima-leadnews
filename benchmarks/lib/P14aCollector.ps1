# P1.4a shared collector (ASCII only, dot-sourced by this card's scripts).
#
# One implementation for every caller so the offline tests exercise the SAME code as the calibration:
#
#   New-P14aResponseLedger   per-response persistence. One JSON line per completed (or failed) request is
#                            written and Flush()ed immediately, so an independent process can read it while the
#                            run is still going. FlushFileBuffers (Stream.Flush($true)) is TRIGGERED by a later
#                            append when either -FsyncEveryRecords records have been written or -FsyncEveryMs have
#                            passed since the last fsync. It is not a timer: the interval is a LOWER bound on the
#                            trigger, never a hard upper bound on the un-synced prefix. Dropped-slot records do not
#                            trigger an fsync; Close() flushes and fsyncs the tail. FlushPolicy records all of it.
#                            A killed COLLECTOR process loses nothing that was already Flush()ed; an OS crash can
#                            lose at most the last un-fsynced segment. Both facts are recorded in the result.
#
#   New-P14aPlan             loads the frozen plan file (slot index -> planned offset + article id)
#
#   Get-P14aAssessment       turns one HTTP response into a verdict against the INDEPENDENT truth file:
#                            http status, response code, quoted-string article id, four counters, content sha256
#
#   Invoke-P14aCollection    fixed-arrival collection: slot i is due at planned_offset_ms, the in-flight cap is
#                            honoured, a slot that is due while the cap is full is DROPPED (never queued, never
#                            retried), each request has a per-request timeout, every response is written to the
#                            ledger as soon as it is complete, and resources are sampled at a fixed interval.
#
# Nothing here writes to the database, Redis or the application; the caller owns all connections.

$script:P14aSep = [char]9
. (Join-Path $PSScriptRoot 'P14bMeasure.ps1')

function New-P14aResponseLedger {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RunId,
        [int]$FsyncEveryRecords = 50,
        [int]$FsyncEveryMs = 200
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { throw "ledger directory does not exist: $dir" }
    if (Test-Path -LiteralPath $Path) { throw "ledger file already exists (write once): $Path" }
    # FileShare.ReadWrite: an independent reader may read the file while this writer still holds it open
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.AutoFlush = $false
    $script:__p14aSeq = 0
    $ledger = [pscustomobject]@{
        Path = $Path; RunId = $RunId; Count = 0; Writer = $writer; Stream = $stream
        Sync = (New-Object object)
        FsyncEveryRecords = $FsyncEveryRecords
        FsyncEveryMs = $FsyncEveryMs
        FsyncCount = 0
        LastFsyncMs = [long]0
        OpenedMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Closed = $false
        # Declared, honest wording of the persistence boundary: Flush() makes a record visible at once, fsync is
        # TRIGGERED by a later append (count or elapsed interval), never by a timer, so the interval is a lower bound.
        FlushPolicy = ('per record: WriteLine + Flush() (a record is visible to any other process immediately); FlushFileBuffers (fsync) is triggered by a LATER append once ' + $FsyncEveryRecords + ' records have been written or ' + $FsyncEveryMs + ' ms have passed since the last fsync; it is not a timer, so the un-synced prefix is bounded by the next qualifying append and NOT by a hard ' + $FsyncEveryMs + ' ms deadline. Dropped-slot records do not trigger an fsync. Close() flushes and fsyncs the tail.')
    }
    $ledger | Add-Member -MemberType ScriptMethod -Name Append -Value {
        param($Record)
        if ($null -ne $Record.persisted_ms) { throw 'ledger: record was already persisted once' }
        [System.Threading.Monitor]::Enter($this.Sync)
        try {
            if ($this.Closed) { throw 'ledger: append after close' }
            $script:__p14aSeq++
            $written = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            # P1.4b: the same machine-wide monotonic axis the dispatch/body-ready/observation stamps use
            $monoWrite = [Math]::Round(([System.Diagnostics.Stopwatch]::GetTimestamp() * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency, 3)
            $Record['seq'] = $script:__p14aSeq
            $Record['ledger_written_ms'] = $written
            $Record['persisted_ms'] = $written
            $Record['ledger_written_mono_ms'] = $monoWrite
            $line = $Record | ConvertTo-Json -Compress -Depth 6
            $this.Writer.WriteLine($line)
            # visible to any other process immediately after this Flush()
            $this.Writer.Flush()
            $this.Count = $this.Count + 1
            $since = $written - $this.LastFsyncMs
            if (($this.Count % $this.FsyncEveryRecords) -eq 0 -or $since -ge $this.FsyncEveryMs) {
                $this.Stream.Flush($true)
                $this.FsyncCount = $this.FsyncCount + 1
                $this.LastFsyncMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            }
            $Record['flush_returned_ms'] = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $Record['flush_returned_mono_ms'] = [Math]::Round(([System.Diagnostics.Stopwatch]::GetTimestamp() * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency, 3)
            return $script:__p14aSeq
        } finally {
            [System.Threading.Monitor]::Exit($this.Sync)
        }
    }
    $ledger | Add-Member -MemberType ScriptMethod -Name Drop -Value {
        param($Record)
        # a dropped slot is not a response: it is recorded in the same stream so offered=started+dropped is auditable
        [System.Threading.Monitor]::Enter($this.Sync)
        try {
            if ($this.Closed) { throw 'ledger: append after close' }
            $script:__p14aSeq++
            $written = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $monoWrite = [Math]::Round(([System.Diagnostics.Stopwatch]::GetTimestamp() * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency, 3)
            $Record['seq'] = $script:__p14aSeq
            $Record['ledger_written_ms'] = $written
            $Record['persisted_ms'] = $written
            $Record['ledger_written_mono_ms'] = $monoWrite
            $this.Writer.WriteLine(($Record | ConvertTo-Json -Compress -Depth 6))
            $this.Writer.Flush()
            $this.Count = $this.Count + 1
            return $script:__p14aSeq
        } finally {
            [System.Threading.Monitor]::Exit($this.Sync)
        }
    }
    $ledger | Add-Member -MemberType ScriptMethod -Name Close -Value {
        [System.Threading.Monitor]::Enter($this.Sync)
        try {
            if ($this.Closed) { return }
            $this.Writer.Flush()
            $this.Stream.Flush($true)
            $this.FsyncCount = $this.FsyncCount + 1
            $this.Writer.Dispose()
            $this.Stream.Dispose()
            $this.Closed = $true
        } finally {
            [System.Threading.Monitor]::Exit($this.Sync)
        }
    }
    return $ledger
}

function Read-P14aLedgerLines {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Retries = 5, [int]$RetryDelayMs = 20)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $last = $null
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        $fs = $null; $sr = $null
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

function New-P14aPlan {
    param([Parameter(Mandatory = $true)][string]$PlanFile)
    if (-not (Test-Path -LiteralPath $PlanFile)) { throw "plan file does not exist: $PlanFile" }
    $plan = Get-Content -LiteralPath $PlanFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($plan.slots).Count -lt 1) { throw "plan has no slots: $PlanFile" }
    return $plan
}

function Get-P14aTruth {
    param([Parameter(Mandatory = $true)][string]$TruthFile)
    if (-not (Test-Path -LiteralPath $TruthFile)) { throw "truth file does not exist: $TruthFile" }
    $truth = Get-Content -LiteralPath $TruthFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $byId = @{}
    foreach ($t in $truth.targets) { $byId[[string]$t.article_id] = $t }
    return $byId
}

function Get-P14aSha256([byte[]]$bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLower() }
    finally { $sha.Dispose() }
}

# ---- null-safe diagnostics and LOSSLESS numeric validation -----------------
#
# Turn one response into a verdict. -Truth comes from Get-P14aTruth (may be null for offline cases that only care
# about the transport/business layer). The function NEVER throws: a structural/type problem is a verdict, not an
# exception, because the raw body has already been received and must still be persisted.
#
# Rules (deliberately strict, every one of them was a reported false result):
#   * diagnostics must be null-safe - a null node used to make the diagnostic itself throw, so a COMPLETE response
#     lost its receipt entirely; the loops below now survive that and name 'null';
#   * a number is accepted only when it is FINITE, INTEGRAL and inside the field's range. [int]/[long] casts used to
#     round 199.6 -> 200 and truncate 1.4 -> 1, so a wrong value was compared against the truth and called correct;
#   * `data.article.id` must be a JSON STRING node equal to the expected id - a numeric id in the article node is a
#     failure even when some OTHER node carries the expected id as a string;
#   * every field frozen in the truth file is compared: four counters, channelId, authorId, content UTF-8 length and
#     content sha256; a missing field or a wrong JSON type is a failure, never coerced.
# Null-safe name of a JSON node for diagnostics. NEVER throws.
function Get-P14aNodeType {
    param([AllowNull()]$Node)
    if ($null -eq $Node) { return 'null' }
    if ($Node -is [string]) { return 'String' }
    if ($Node -is [bool]) { return 'Boolean' }
    if ($Node -is [System.Array]) { return 'Array' }
    if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) { return 'Array' }
    try { return $Node.GetType().Name } catch { return 'unknown' }
}

# Accept ONLY a JSON number whose value is a finite integer within [Min, Max], judged WITHOUT any lossy conversion.
#
# Why the double path is separate: `[decimal]$double` ROUNDS to 15 significant digits, so 200.00000000000003 became
# 200 and 0.9999999999999999 became 1 (both then compared "equal" to the truth), and 9007199254740991.0 - an exactly
# representable double - became 9007199254740990. A double is therefore validated entirely in double arithmetic and
# only converted once it is known to be integral and inside the exactly-representable integer range.
#
# Returns { ok, value, reason, rendered, exactly_integral }:
#   ok = $true   for 200, 200.0, 1.0, 9007199254740991.0 (an exact double integer), 9007199254740991 (Int64)
#   ok = $false  for null / Boolean / String / Array / Object, 199.6 and 1.4 (not integral),
#                200.00000000000003 / 1.0000000000000002 / 0.9999999999999999 (not integral as a double),
#                1e30 and anything beyond 2^53-1 (not exactly representable -> out_of_range, never silently changed),
#                NaN / Infinity
# `rendered` is the ROUND-TRIP text of the original node, so a diagnosis never shows a value that differs from the
# one that was received.
function ConvertTo-P14aIntegral {
    param(
        [AllowNull()]$Node,
        [long]$Min = [long]::MinValue,
        [long]$Max = [long]::MaxValue,
        [string]$Field = 'value'
    )
    $r = [ordered]@{ ok = $false; value = [long]0; reason = ''; rendered = ''; exactly_integral = $false }
    if ($null -eq $Node) { $r.reason = "$Field=null"; return $r }
    if ($Node -is [bool]) { $r.reason = "$Field=Boolean"; return $r }
    if ($Node -is [string]) { $r.reason = "$Field=String"; return $r }

    # ---- floating point: validate in the ORIGINAL domain, never through decimal ----
    if (($Node -is [double]) -or ($Node -is [single])) {
        $d = [double]$Node
        $r.rendered = $d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { $r.reason = "$Field=not_finite($($r.rendered))"; return $r }
        # exact double remainder: 200.00000000000003 % 1 is ~2.8e-14, so it is NOT an integer here
        if (($d % 1.0) -ne 0.0) { $r.reason = "$Field=not_an_integer($($r.rendered))"; return $r }
        # only |v| <= 2^53-1 is guaranteed to convert to Int64 without changing the value; beyond that a double
        # cannot represent every integer, so the honest answer is out_of_range rather than a changed number
        $maxSafe = 9007199254740991.0
        if ($d -gt $maxSafe -or $d -lt (-$maxSafe)) {
            $r.reason = "$Field=out_of_range($($r.rendered): beyond the exactly representable integer range 2^53-1)"
            return $r
        }
        if ($d -lt [double]$Min -or $d -gt [double]$Max) { $r.reason = "$Field=out_of_range($($r.rendered))"; return $r }
        $r.value = [long]$d     # exact: the value is integral and inside 2^53-1
        $r.exactly_integral = ($r.rendered -ne $r.value.ToString())
        $r.ok = $true
        return $r
    }

    # ---- integral and decimal nodes are exact already ----
    $isNum = ($Node -is [int]) -or ($Node -is [long]) -or ($Node -is [int16]) -or ($Node -is [uint16]) -or
        ($Node -is [uint32]) -or ($Node -is [uint64]) -or ($Node -is [byte]) -or ($Node -is [sbyte]) -or
        ($Node -is [decimal])
    if (-not $isNum) { $r.reason = "$Field=$(Get-P14aNodeType $Node)"; return $r }
    if ($Node -is [uint64] -and ([uint64]$Node -gt [uint64][long]::MaxValue)) {
        $r.rendered = [string]$Node; $r.reason = "$Field=out_of_range($($r.rendered))"; return $r
    }
    try { $dec = [decimal]$Node } catch { $r.rendered = [string]$Node; $r.reason = "$Field=out_of_range($($r.rendered))"; return $r }
    $r.rendered = if ($Node -is [decimal]) { $Node.ToString([System.Globalization.CultureInfo]::InvariantCulture) } else { [string]$Node }
    if ($dec -ne [decimal][Math]::Floor($dec)) { $r.reason = "$Field=not_an_integer($($r.rendered))"; return $r }
    # the range test happens BEFORE the cast, and decimals are exact, so nothing is rounded or truncated
    if ($dec -lt [decimal]$Min -or $dec -gt [decimal]$Max) { $r.reason = "$Field=out_of_range($($r.rendered))"; return $r }
    $r.value = [long]$dec
    $r.exactly_integral = ($r.rendered -ne $r.value.ToString())
    $r.ok = $true
    return $r
}

function Get-P14aAssessment {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][byte[]]$Bytes,
        [AllowNull()][string]$Text,
        [int]$HttpStatus = -1,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ExpectedId,
        [AllowNull()]$Truth = $null,
        [AllowNull()][string]$TransportError = '',
        [bool]$TimedOut = $false
    )
    $a = [ordered]@{
        verdict = 'unknown'; correct = $false; http = $HttpStatus
        code = -1; code_type = ''; id_is_string = $false; id_matches = $false
        fields_match = $false; content_sha256_match = $false; content_bytes = -1; content_bytes_match = $false
        channel_match = $false; author_match = $false
        invalid_json = $false; missing_fields = @(); wrong_types = @()
        transport_error = $TransportError; timed_out = $TimedOut
        notes = @()
    }
    if ($TimedOut) { $a.verdict = 'timeout'; return $a }
    if ($null -eq $Bytes) {
        $a.verdict = if ($TransportError) { 'transport' } else { 'no_body' }
        return $a
    }
    if ($HttpStatus -ne 200) { $a.verdict = 'http_status'; return $a }
    if ([string]::IsNullOrWhiteSpace($Text)) { $a.verdict = 'empty_body'; return $a }
    $obj = $null
    try { $obj = $Text | ConvertFrom-Json } catch { $a.invalid_json = $true; $a.verdict = 'invalid_json'; return $a }
    if ($null -eq $obj -or $obj -is [string] -or $obj -is [ValueType]) { $a.invalid_json = $true; $a.verdict = 'invalid_json'; return $a }
    if ($null -eq $obj.PSObject.Properties['code']) { $a.verdict = 'invalid_json'; $a.missing_fields += 'code'; return $a }

    # ---- business code: presence, then FINITE/INTEGRAL/Int32-range, then the exact value ----
    $codeNode = $obj.code
    $a.code_type = Get-P14aNodeType $codeNode
    $codeConv = ConvertTo-P14aIntegral -Node $codeNode -Min ([long][int]::MinValue) -Max ([long][int]::MaxValue) -Field 'code'
    if (-not $codeConv.ok) {
        # a string / null / object / fractional / overflowing number where an Int32 code is required is a STRUCTURAL
        # failure; the body is still kept and the exact reason is named. 199.6 is NOT rounded to 200 here.
        $a.verdict = 'invalid_field_type'
        $a.wrong_types += $codeConv.reason
        return $a
    }
    $a.code = [int]$codeConv.value
    if ($codeConv.exactly_integral) { $a.notes += "code=$($codeConv.rendered) is an exactly integral JSON number equal to $($a.code)" }
    if ($a.code -ne 200) { $a.verdict = 'business_code'; return $a }

    # ---- data / article nodes must exist and be JSON objects ----
    if ($null -eq $obj.PSObject.Properties['data'] -or $null -eq $obj.data) { $a.verdict = 'no_data'; $a.missing_fields += 'data'; return $a }
    if (($obj.data -is [string]) -or ($obj.data -is [ValueType]) -or ($obj.data -is [System.Array])) {
        $a.verdict = 'invalid_field_type'; $a.wrong_types += "data=$(Get-P14aNodeType $obj.data)"; return $a
    }
    if ($null -eq $obj.data.PSObject.Properties['article'] -or $null -eq $obj.data.article) { $a.verdict = 'no_data'; $a.missing_fields += 'data.article'; return $a }
    $article = $obj.data.article
    if (($article -is [string]) -or ($article -is [ValueType]) -or ($article -is [System.Array])) {
        $a.verdict = 'invalid_field_type'; $a.wrong_types += "data.article=$(Get-P14aNodeType $article)"; return $a
    }

    # ---- the REAL article id node: a JSON string that equals the expected id ----
    if ($null -eq $article.PSObject.Properties['id']) { $a.verdict = 'wrong_id'; $a.missing_fields += 'data.article.id'; return $a }
    $idNode = $article.id
    # id_is_string and id_matches are reported SEPARATELY on purpose: the value may textually equal the expected id
    # while the JSON node is a number, which is still a failure (both are required for 'correct' below).
    $a.id_is_string = ($idNode -is [string])
    $a.id_matches = ([string]$idNode -ceq $ExpectedId)
    if (-not $a.id_is_string -or -not $a.id_matches) {
        $a.verdict = 'wrong_id'
        # Get-P14aNodeType is null-safe: a null id is named 'null' instead of aborting the whole receipt
        if (-not $a.id_is_string) { $a.notes += "data.article.id is $(Get-P14aNodeType $idNode), not a JSON string" }
        $rendered = if ($null -eq $idNode) { 'null' } else { [string]$idNode }
        $a.notes += "data.article.id=$rendered expected=$ExpectedId"
        return $a
    }

    # ---- content node: present and a JSON string ----
    if ($null -eq $obj.data.PSObject.Properties['content']) { $a.verdict = 'wrong_content'; $a.missing_fields += 'data.content'; return $a }
    $contentNode = $obj.data.content
    if (-not ($contentNode -is [string])) {
        $a.verdict = 'invalid_field_type'
        $a.wrong_types += "data.content=$(Get-P14aNodeType $contentNode)"
        return $a
    }
    $contentBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$contentNode)
    $a.content_bytes = $contentBytes.Length
    $contentSha = Get-P14aSha256 $contentBytes

    # ---- every frozen field: presence, then finite/integral/range, then an EXACT comparison ----
    $required = @('views', 'likes', 'comment', 'collection', 'channelId', 'authorId')
    $nums = @{}
    foreach ($f in $required) {
        if ($null -eq $article.PSObject.Properties[$f]) { $a.missing_fields += "data.article.$f"; continue }
        $conv = ConvertTo-P14aIntegral -Node $article.$f -Min ([long]0) -Max ([long]::MaxValue) -Field "data.article.$f"
        if (-not $conv.ok) { $a.wrong_types += $conv.reason; continue }
        # an exactly integral float is accepted and said so; 1.4 or 0.9999999999999999 is rejected above
        if ($conv.exactly_integral) { $a.notes += "data.article.$f=$($conv.rendered) is an exactly integral JSON number equal to $($conv.value)" }
        $nums[$f] = [long]$conv.value
    }
    if ($a.missing_fields.Count -gt 0) { $a.verdict = 'missing_field'; return $a }
    if ($a.wrong_types.Count -gt 0) { $a.verdict = 'invalid_field_type'; return $a }

    if ($null -ne $Truth -and $Truth.ContainsKey($ExpectedId)) {
        $t = $Truth[$ExpectedId]
        $a.fields_match = ($nums['views'] -eq [long]$t.views) -and ($nums['likes'] -eq [long]$t.likes) -and
            ($nums['comment'] -eq [long]$t.comment) -and ($nums['collection'] -eq [long]$t.collection)
        $a.channel_match = ($nums['channelId'] -eq [long]$t.channel_id)
        $a.author_match = ($nums['authorId'] -eq [long]$t.author_id)
        $a.content_bytes_match = ($a.content_bytes -eq [long]$t.content_bytes)
        $a.content_sha256_match = ($contentSha -eq [string]$t.content_sha256)
        if (-not $a.fields_match) { $a.notes += ("counters={0}|{1}|{2}|{3} expected={4}|{5}|{6}|{7}" -f $nums['views'], $nums['likes'], $nums['comment'], $nums['collection'], $t.views, $t.likes, $t.comment, $t.collection) }
        if (-not $a.channel_match) { $a.notes += "channelId=$($nums['channelId']) expected=$($t.channel_id)" }
        if (-not $a.author_match) { $a.notes += "authorId=$($nums['authorId']) expected=$($t.author_id)" }
        if (-not $a.content_bytes_match) { $a.notes += "content_bytes=$($a.content_bytes) expected=$($t.content_bytes)" }
        if (-not $a.content_sha256_match) { $a.notes += "content_sha256=$contentSha expected=$($t.content_sha256)" }
    }
    $ok = $a.id_is_string -and $a.id_matches -and $a.fields_match -and $a.channel_match -and $a.author_match -and
        $a.content_bytes_match -and $a.content_sha256_match
    if ($ok) { $a.verdict = 'correct'; $a.correct = $true; return $a }
    $a.verdict = if (-not $a.fields_match -or -not $a.channel_match -or -not $a.author_match) { 'wrong_field' } else { 'wrong_content' }
    return $a
}

function Get-P14aPercentiles {
    param([AllowNull()][double[]]$Values, [int[]]$Percents = @(50, 95, 99))
    if ($null -eq $Values -or $Values.Count -eq 0) {
        $empty = [ordered]@{ count = 0 }
        foreach ($p in $Percents) { $empty["p$p"] = -1 }
        return $empty
    }
    $sorted = @($Values | Sort-Object)
    $res = [ordered]@{ count = $sorted.Count; method = 'nearest-rank: ceil(p/100 * n)-th value of the ascending sample' }
    foreach ($p in $Percents) {
        $rank = [int][Math]::Ceiling(($p / 100.0) * $sorted.Count)
        if ($rank -lt 1) { $rank = 1 }
        if ($rank -gt $sorted.Count) { $rank = $sorted.Count }
        $res["p$p"] = [Math]::Round($sorted[$rank - 1], 3)
    }
    $res['min'] = [Math]::Round($sorted[0], 3)
    $res['max'] = [Math]::Round($sorted[$sorted.Count - 1], 3)
    return $res
}

function Get-P14aResourceSample {
    param([int]$TargetPid, [int]$IdlePid = 0, [string]$CollectorLabel = 'collector')
    $row = [ordered]@{
        local_time = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fff')
        target_pid = $TargetPid
        target_cpu_percent = -1
        target_working_set_mb = -1
        target_threads = -1
        idle_pid = $IdlePid
        idle_cpu_percent = -1
        idle_working_set_mb = -1
        idle_threads = -1
        collector_cpu_percent = -1
        collector_working_set_mb = -1
        note = ''
    }
    $cores = [Environment]::ProcessorCount
    $tp = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    $ip = if ($IdlePid -gt 0) { Get-Process -Id $IdlePid -ErrorAction SilentlyContinue } else { $null }
    $cp = Get-Process -Id $PID -ErrorAction SilentlyContinue
    $row['collector_cpu_total_ms'] = if ($cp) { [long]$cp.TotalProcessorTime.TotalMilliseconds } else { -1 }
    $row['target_cpu_total_ms'] = if ($tp) { [long]$tp.TotalProcessorTime.TotalMilliseconds } else { -1 }
    $row['idle_cpu_total_ms'] = if ($ip) { [long]$ip.TotalProcessorTime.TotalMilliseconds } else { -1 }
    if ($tp) {
        $row['target_working_set_mb'] = [Math]::Round($tp.WorkingSet64 / 1MB, 1)
        $row['target_threads'] = $tp.Threads.Count
    } else {
        $row['note'] = "target pid $TargetPid not found"
    }
    if ($ip) {
        $row['idle_working_set_mb'] = [Math]::Round($ip.WorkingSet64 / 1MB, 1)
        $row['idle_threads'] = $ip.Threads.Count
    }
    if ($cp) { $row['collector_working_set_mb'] = [Math]::Round($cp.WorkingSet64 / 1MB, 1) }
    $row['logical_cores'] = $cores
    return $row
}

# The collection loop. Returns a stats object; every response is already on disk when it returns.
#
# Scheduling discipline (fixes the reported false "cap full" and the window/tail miscount):
#   * a task that already ran to completion is REAPED before the in-flight cap is judged, and AGAIN immediately
#     before every single due slot, so a finished-but-not-yet-booked task never occupies the cap;
#   * every SendAsync is preceded by its own fresh monotonic read plus a wall-clock ISO stamp, and THOSE are the
#     dispatched time of that request - a batch of late slots never shares the loop's opening timestamp;
#   * the sampling window is the duration the PLAN declares (plan.seconds), not the offset of the last slot;
#     completions inside and after that boundary are counted separately and always add up to the total;
#   * drops are classified: dropped_cap_full requires a genuinely PENDING count at the cap. Missed-schedule drops
#     are a separate, explicitly disabled policy in this card, so dropped_scheduler_missed stays 0.
function Invoke-P14aCollection {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)]$Ledger,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$Group,
        [AllowNull()]$Truth = $null,
        [string]$PathTemplate = '/api/v1/article/detail/{id}',
        [int]$MaxInFlight = 16,
        [int]$RequestTimeoutMs = 5000,
        [int]$SliceMs = 1,
        # Resource observation is NOT done here any more (P1.4b): the separate observer process owns it and the main
        # loop never waits for a sample or a resource write. The parameters below are kept so callers written against
        # the P1.4a signature still bind, and they only describe the inherited limits.
        [int]$ResourceEveryMs = 1000,
        [string]$ResourcePath = '',
        # exact PIDs of THIS run's processes; they are recorded and attributed, never guessed from "the newest java"
        [int]$TargetPid = 0,
        [int]$IdlePid = 0,
        [int]$ObserverPid = 0,
        [string]$ObserverSummary = '',
        [int]$InterruptAfterMs = 0,
        [int]$SampleWindowMs = 0,
        # OFFLINE REGRESSION HOOK ONLY (0 = disabled). It stalls the MAIN LOOP right after the N-th request has been
        # started, so the private control can prove the body-ready stamp is taken independently of the loop.
        [int]$TestPauseAfterStarts = 0,
        [int]$TestPauseDurationMs = 0,
        [switch]$NoResources
    )
    # The P1.4b measurement helper owns the request: its continuation takes the body-ready stamp in the request's own
    # completion path, which a PowerShell script block cannot do (no runspace on a thread-pool thread).
    $null = Initialize-P14bMeasure
    $slots = @($Plan.slots)
    $offered = 0; $started = 0; $dropped = 0
    $droppedCapFull = 0; $droppedSchedulerMissed = 0
    $completed = 0; $completedInWindow = 0; $completedAfterWindow = 0
    $failures = 0; $timeouts = 0; $correct = 0
    $verdicts = @{}
    $latenciesAll = New-Object System.Collections.ArrayList
    $latenciesCorrect = New-Object System.Collections.ArrayList
    $dispatchLag = New-Object System.Collections.ArrayList
    $droppedSlots = New-Object System.Collections.ArrayList
    $inflight = New-Object System.Collections.ArrayList
    # P1.4b: the NEW timing population. body_latency = dispatch -> complete body available in the client;
    # observe_lag = body available -> the main loop observed the task; persist_lag = observed -> ledger write.
    $bodyLatencyAll = New-Object System.Collections.ArrayList
    $bodyLatencyCorrect = New-Object System.Collections.ArrayList
    $observeLag = New-Object System.Collections.ArrayList
    $dispatchLagMono = New-Object System.Collections.ArrayList
    $persistLag = New-Object System.Collections.ArrayList
    $flushLags = New-Object System.Collections.ArrayList
    $flushLagMax = 0.0
    $axisMaxDeltaMs = 0.0
    $bodyReadyMissing = 0
    $bodyReadyMissingReasons = @{}
    # P1.4b section 8: the BODY-READY window population, kept beside the legacy observation window
    $bodyWinIn = 0
    $bodyWinAfter = 0
    $bodyStampBad = 0

    # ---- declared sampling window (NEVER the offset of the last slot when the plan states its duration) ----
    $declaredWindowMs = [long]0
    $windowSource = ''
    if ($SampleWindowMs -gt 0) {
        $declaredWindowMs = [long]$SampleWindowMs
        $windowSource = 'parameter -SampleWindowMs'
    } elseif ($null -ne $Plan.PSObject.Properties['seconds'] -and [int]$Plan.seconds -gt 0) {
        $declaredWindowMs = [long]([int]$Plan.seconds * 1000)
        $windowSource = 'plan.seconds (the duration the frozen plan declares)'
    } else {
        $rate = 0
        if ($null -ne $Plan.PSObject.Properties['rate_per_second']) { $rate = [int]$Plan.rate_per_second }
        $lastOffset = [long]$slots[$slots.Count - 1].planned_offset_ms
        $interval = if ($rate -gt 0) { [long][Math]::Ceiling(1000.0 / $rate) } else { [long]0 }
        $declaredWindowMs = $lastOffset + $interval
        $windowSource = 'fallback: last slot offset + one inter-arrival interval (the plan declares no duration)'
    }

    # Resource observation is NOT performed here: the separate observer process samples on its own PID and writes its
    # own file, so this loop never waits for a sample or a resource write (P1.4b section 3).
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # the mono origin is read IMMEDIATELY after the Stopwatch object exists, so (dispatch_mono_ms - monoStartMs) and the
    # legacy $sw.ElapsedMilliseconds describe the same instant to within the cost of one clock read
    $swStartTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $loopIterations = 0
    $monoFreq = [System.Diagnostics.Stopwatch]::Frequency
    $monoStartMs = [Math]::Round((([double]$swStartTicks) * 1000.0) / $monoFreq, 3)
    $maxLoopIntervalMs = [long]0
    $lastLoopNow = [long]0
    $pauseApplied = $false
    $pauseAtMs = [long]-1
    $pauseAfterStarts = 0
    $interrupted = $false
    $interruptMsg = ''
    $index = 0
    $drainStartMs = [long]-1
    $drainEndMs = [long]-1

    # Bookkeeping for ONE completed task. Dot-sourced (". $reapCompleted"), so it mutates the loop's own
    # counters and list instead of a copy - reaping and dispatch must agree on the SAME pending set.
    $reapCompleted = {
        for ($k = $inflight.Count - 1; $k -ge 0; $k--) {
            $p = $inflight[$k]
            if (-not $p.task.IsCompleted) {
                $waited = [long]$sw.ElapsedMilliseconds - [long]$p.dispatchedMs
                if ($waited -ge ($RequestTimeoutMs + 5000)) {
                    # defensive only: the cancellation token owns the timeout; block for 0 ms and never invent a result
                    try { $null = $p.task.Wait(0) } catch { }
                }
                continue
            }
            $ended = [long]$sw.ElapsedMilliseconds
            $rec = [ordered]@{
                kind = 'response'; group = $Group; run_id = $RunId
                slot_index = $p.slotIndex; planned_offset_ms = $p.plannedMs
                request_id = $p.reqId; method = 'GET'; url = "$Base$($p.path)"
                target_article_id = $p.articleId; expected_verdict = $p.expect
                dispatched_ms = [long]$p.dispatchedMs; dispatched_local_iso = $p.dispatchedLocal
                ended_ms = $ended; completion_observed_ms = $ended
                elapsed_ms = [long]($ended - [long]$p.dispatchedMs)
                schedule_lag_ms = [long]([long]$p.dispatchedMs - [long]$p.plannedMs)
                declared_window_ms = $declaredWindowMs
                in_window = ($ended -le $declaredWindowMs)
                observe_mono_ms = [Math]::Round((([double][System.Diagnostics.Stopwatch]::GetTimestamp()) * 1000.0) / $monoFreq, 3)
                elapsed_is = 'LEGACY: dispatched_ms (monotonic read taken immediately before the send) to ended_ms (the first collection-loop observation of task completion). Kept unchanged for comparability; it OVERSTATES latency by the loop observation delay. The P1.4b candidate latency is body_latency_ms = dispatch_mono_ms to body_ready_mono_ms'
                timing_source = 'P1.4b: System.Diagnostics.Stopwatch.GetTimestamp() / Stopwatch.Frequency, one machine-wide monotonic axis; dispatch and body-ready stamps come from the measurement helper, the observation stamp from this loop'
            }
            $hit = $null; $bytes = $null; $text = $null; $status = -1; $timedOut = $false; $transportError = ''
            try {
                $hit = $p.task.GetAwaiter().GetResult()
            } catch {
                $inner = $_.Exception
                while ($inner.InnerException) { $inner = $inner.InnerException }
                if ($inner -is [System.OperationCanceledException] -or $inner -is [System.Threading.Tasks.TaskCanceledException]) { $timedOut = $true } else { $transportError = $inner.Message }
                $rec['task_await_error'] = $inner.Message
            }
            if ($null -ne $hit) {
                $status = [int]$hit.StatusCode
                if ([string]$hit.BodyState -eq 'complete' -and $null -ne $hit.Body) {
                    $bytes = [byte[]]$hit.Body
                    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
                }
                $timedOut = [bool]$hit.TimedOut
                if (-not $timedOut -and [string]$hit.Error -ne '') { $transportError = [string]$hit.Error }
                if ([string]$hit.Headers -ne '') { $rec['headers'] = [string]$hit.Headers }
                $dispatchMono = [Math]::Round((([double]$hit.DispatchTicks) * 1000.0) / $monoFreq, 3)
                $rec['dispatch_mono_ms'] = $dispatchMono
                $rec['body_state'] = [string]$hit.BodyState
                $axisDelta = [Math]::Abs(($dispatchMono - $monoStartMs) - [double]$p.dispatchedMs)
                if ($axisDelta -gt $axisMaxDeltaMs) { $axisMaxDeltaMs = $axisDelta }
                $null = $dispatchLagMono.Add([Math]::Round($dispatchMono - $monoStartMs - [double]$p.plannedMs, 3))
                $dispatchOffset = [Math]::Round($dispatchMono - $monoStartMs, 3)
                $rec['dispatch_offset_ms'] = $dispatchOffset
                if ($hit.BodyReadyTicks -gt 0) {
                    $br = [Math]::Round((([double]$hit.BodyReadyTicks) * 1000.0) / $monoFreq, 3)
                    $brOffset = [Math]::Round($br - $monoStartMs, 3)
                    $bl = [Math]::Round($br - $dispatchMono, 3)
                    $rec['body_ready_mono_ms'] = $br
                    $rec['body_ready_offset_ms'] = $brOffset
                    $rec['body_latency_ms'] = $bl
                    $rec['observe_lag_ms'] = [Math]::Round([double]$rec['observe_mono_ms'] - $br, 3)
                    # ---- P1.4b section 8: the BODY-READY window, computed from the body stamp and the frozen
                    # monotonic origin. The legacy in_window above stays exactly as it was (observation based).
                    $inBodyWindow = ($brOffset -le $declaredWindowMs)
                    $rec['in_window_body'] = $inBodyWindow
                    $rec['body_window_offset_ms'] = $brOffset
                    if ($inBodyWindow) { $bodyWinIn++ } else { $bodyWinAfter++ }
                    $null = $bodyLatencyAll.Add([double]$bl)
                    $null = $observeLag.Add([double]$rec['observe_lag_ms'])
                    # ---- integrity of the four stamps (a self-consistent but impossible record must be refused) ----
                    if ($bl -lt 0) {
                        $bodyStampBad++
                        $rec['stamp_problem'] = "body_latency_ms is negative ($bl): the body-ready stamp precedes the dispatch stamp"
                    } elseif (-not ($dispatchMono -le $br -and $br -le [double]$rec['observe_mono_ms'])) {
                        $bodyStampBad++
                        $rec['stamp_problem'] = ('stamps out of order: dispatch={0} body_ready={1} observe={2} (require dispatch <= body_ready <= observe)' -f $dispatchMono, $br, $rec['observe_mono_ms'])
                    }
                } else {
                    # NO complete body: the stamp is honestly absent. Nothing is back-filled and no bytes are invented.
                    $why = if ($timedOut) { 'timeout' } elseif ($transportError -ne '') { 'transport_error' } else { 'no_complete_body' }
                    $rec['body_ready_mono_ms'] = $null
                    $rec['body_ready_offset_ms'] = $null
                    $rec['body_latency_ms'] = $null
                    $rec['observe_lag_ms'] = $null
                    $rec['in_window_body'] = $null
                    $rec['body_ready_missing_reason'] = $why
                    $bodyReadyMissing++
                    if ($bodyReadyMissingReasons.ContainsKey($why)) { $bodyReadyMissingReasons[$why] = $bodyReadyMissingReasons[$why] + 1 } else { $bodyReadyMissingReasons[$why] = 1 }
                }
            }
            $assessment = Get-P14aAssessment -Bytes $bytes -Text $text -HttpStatus $status -ExpectedId $p.articleId -Truth $Truth -TransportError $transportError -TimedOut $timedOut
            $rec['http'] = $status
            $rec['verdict'] = $assessment.verdict
            $rec['correct'] = [bool]$assessment.correct
            $rec['code'] = $assessment.code
            $rec['id_is_string'] = $assessment.id_is_string
            $rec['id_matches'] = $assessment.id_matches
            $rec['fields_match'] = $assessment.fields_match
            $rec['content_sha256_match'] = $assessment.content_sha256_match
            $rec['channel_match'] = $assessment.channel_match
            $rec['author_match'] = $assessment.author_match
            $rec['content_bytes'] = $assessment.content_bytes
            $rec['content_bytes_match'] = $assessment.content_bytes_match
            $rec['code_type'] = $assessment.code_type
            if ($assessment.missing_fields.Count -gt 0) { $rec['missing_fields'] = @($assessment.missing_fields) }
            if ($assessment.wrong_types.Count -gt 0) { $rec['wrong_types'] = @($assessment.wrong_types) }
            if ($timedOut) { $rec['timeout'] = $true; $rec['error'] = "request exceeded $RequestTimeoutMs ms and was cancelled" }
            if ($transportError) { $rec['failure'] = $true; $rec['error'] = $transportError }
            if ($assessment.notes.Count -gt 0) { $rec['assessment_notes'] = $assessment.notes }
            if ($null -ne $bytes) {
                # the RAW bytes are preserved verbatim (base64) so any reader can recompute length and hash
                $rec['bytes'] = $bytes.Length
                $rec['sha256'] = Get-P14aSha256 $bytes
                $rec['body_utf8'] = $text
                $rec['body_base64'] = [System.Convert]::ToBase64String($bytes)
            } else {
                $rec['body_unavailable'] = 'the transport failed before a complete body could be read; nothing is fabricated'
            }
            if ($assessment.correct -and $p.expect -ne 'ok') { $rec['unexpected'] = "expected $($p.expect) but the response was fully correct" }
            if (-not $assessment.correct -and $p.expect -ne 'ok' -and $assessment.verdict -ne $p.expect) { $rec['unexpected'] = "expected $($p.expect) but got $($assessment.verdict)" }
            $null = $Ledger.Append($rec)
            # the flush stamp cannot live inside the line it follows, so the observe->persist / persist->flush lags are
            # aggregated here from the in-memory record and reported in collect-result (never back-filled into the file)
            if ($null -ne $rec['ledger_written_mono_ms']) {
                $null = $persistLag.Add([double][Math]::Round([double]$rec['ledger_written_mono_ms'] - [double]$rec['observe_mono_ms'], 3))
            }
            if ($null -ne $rec['flush_returned_mono_ms'] -and $null -ne $rec['ledger_written_mono_ms']) {
                $fl = [double][Math]::Round([double]$rec['flush_returned_mono_ms'] - [double]$rec['ledger_written_mono_ms'], 3)
                if ($fl -gt $flushLagMax) { $flushLagMax = $fl }
                $null = $flushLags.Add($fl)
            }
            $completed++
            if ($ended -le $declaredWindowMs) { $completedInWindow++ } else { $completedAfterWindow++ }
            $latenciesAll.Add([double]$rec.elapsed_ms) | Out-Null
            if ($assessment.correct) { $correct++; $latenciesCorrect.Add([double]$rec.elapsed_ms) | Out-Null; if ($null -ne $rec['body_latency_ms']) { $null = $bodyLatencyCorrect.Add([double]$rec['body_latency_ms']) } } else { $failures++ }
            if ($timedOut) { $timeouts++ }
            if ($verdicts.ContainsKey($assessment.verdict)) { $verdicts[$assessment.verdict] = $verdicts[$assessment.verdict] + 1 } else { $verdicts[$assessment.verdict] = 1 }
            $p.cts.Dispose()
            $inflight.RemoveAt($k)
        }
    }

    try {
        while ($true) {
            $loopIterations++
            $now = [long]$sw.ElapsedMilliseconds
            if ($loopIterations -gt 1) {
                $gap = $now - $lastLoopNow
                if ($gap -gt $maxLoopIntervalMs) { $maxLoopIntervalMs = $gap }
            }
            $lastLoopNow = $now
            if ($InterruptAfterMs -gt 0 -and $now -ge $InterruptAfterMs) {
                $interrupted = $true
                $interruptMsg = "controlled interruption after ${now}ms"
                break
            }
            # ---- 1. reap BEFORE the cap is judged: a task that already ran to completion is not pending ----
            $null = . $reapCompleted
            # ---- 2. dispatch every slot that is due ----
            while ($index -lt $slots.Count -and [int]$slots[$index].planned_offset_ms -le $now) {
                # re-reap before EVERY single due slot: a catch-up burst must never judge the cap on a stale set
                $null = . $reapCompleted
                $pending = $inflight.Count
                $slot = $slots[$index]
                $offered++
                if ($pending -ge $MaxInFlight) {
                    $dropped++
                    $droppedCapFull++
                    $dropAt = [long]$sw.ElapsedMilliseconds
                    $rec = [ordered]@{
                        kind = 'dropped'; group = $Group; run_id = $RunId
                        slot_index = [int]$slot.slot_index; planned_offset_ms = [int]$slot.planned_offset_ms
                        intended_article_id = [string]$slot.article_id
                        request_id = ('{0}-{1}-s{2}' -f $RunId, $Group, [int]$slot.slot_index)
                        drop_class = 'cap_full'
                        reason = "in-flight cap $MaxInFlight was full: $pending requests were genuinely PENDING (not completed) at this slot"
                        inflight_at_drop = $pending
                        observed_ms = $dropAt
                        schedule_lag_ms = [long]($dropAt - [long]$slot.planned_offset_ms)
                        drop_policy = 'cap_full only: a due slot is dropped when the PENDING count equals the in-flight cap; no queue, no retry, no back-fill'
                    }
                    $null = $Ledger.Drop($rec)
                    $null = $droppedSlots.Add($rec)
                    $index++
                    continue
                }
                $reqId = '{0}-{1}-s{2}' -f $RunId, $Group, [int]$slot.slot_index
                $path = if ($null -ne $slot.PSObject.Properties['path'] -and $slot.path) { [string]$slot.path } else { $PathTemplate.Replace('{id}', [string]$slot.article_id) }
                $expect = if ($null -ne $slot.PSObject.Properties['expect'] -and $slot.expect) { [string]$slot.expect } else { 'ok' }
                $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base$path")
                $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
                $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
                $cts = New-Object System.Threading.CancellationTokenSource
                $cts.CancelAfter($RequestTimeoutMs)
                # a FRESH read for THIS send: a late batch does not inherit the loop's opening timestamp
                $dispatchedLocal = [DateTimeOffset]::Now.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
                $dispatched = [long]$sw.ElapsedMilliseconds
                $task = [P14b.Hit]::SendAsync($Client, $req, $cts.Token)
                $null = $inflight.Add([pscustomobject]@{
                        reqId = $reqId; slotIndex = [int]$slot.slot_index; articleId = [string]$slot.article_id
                        path = $path; expect = $expect
                        plannedMs = [int]$slot.planned_offset_ms; dispatchedMs = $dispatched; dispatchedLocal = $dispatchedLocal
                        task = $task; cts = $cts
                    })
                $started++
                # offline regression hook: a declared stall right after the N-th start (0 = disabled)
                if ($TestPauseDurationMs -gt 0 -and -not $pauseApplied -and $started -ge $TestPauseAfterStarts) {
                    $pauseApplied = $true
                    $pauseAtMs = [long]$sw.ElapsedMilliseconds
                    $pauseAfterStarts = $started
                    [System.Threading.Thread]::Sleep($TestPauseDurationMs)
                    $now = [long]$sw.ElapsedMilliseconds
                }
                $null = $dispatchLag.Add([double]($dispatched - [long]$slot.planned_offset_ms))
                $index++
            }
            # ---- 3. resource observation happens OUTSIDE this loop (separate observer process, own PID, own file) ----
            # There is deliberately nothing here: the loop never samples a process, never formats a resource row and
            # never flushes a resource file, so a slow sample cannot delay a dispatch. The observer's own summary is
            # attached to the stats AFTER the loop ends.
            # ---- 4. done? ----
            if ($index -ge $slots.Count -and $drainStartMs -lt 0) { $drainStartMs = $now }
            if ($index -ge $slots.Count -and $inflight.Count -eq 0) { break }
            # Thread.Sleep(1) is a 15.6 ms timer tick on Windows, which would dominate every measured elapsed_ms.
            # While requests are in flight the loop therefore busy-polls for at most 2 ms (busy CPU is measured and
            # reported); with nothing in flight it sleeps normally.
            if ($inflight.Count -gt 0) {
                $spinFreq = [System.Diagnostics.Stopwatch]::Frequency
                $spinStart = [System.Diagnostics.Stopwatch]::GetTimestamp()
                do {
                    $elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $spinStart
                } while ((($elapsedTicks * 1000.0) / $spinFreq) -lt 2 -and $inflight.Count -gt 0)
            } else {
                [System.Threading.Thread]::Sleep($SliceMs)
            }
        }
    } finally {
        # nothing is flushed here: this loop owns no resource writer
    }
    $drainEndMs = [long]$sw.ElapsedMilliseconds
    # whole-run proof that the two readings are the same clock: the elapsed time measured by the Stopwatch and by the
    # monotonic axis must agree; the per-record legacy_vs_mono delta only bounds the PowerShell->.NET call overhead.
    $monoEndMs = [Math]::Round((([double][System.Diagnostics.Stopwatch]::GetTimestamp()) * 1000.0) / $monoFreq, 3)
    $monoElapsedMs = [Math]::Round($monoEndMs - $monoStartMs, 3)
    $axisRunDeltaMs = [Math]::Round([Math]::Abs($monoElapsedMs - [double]$drainEndMs), 3)
    $stats = [ordered]@{
        run_id = $RunId; group = $Group
        offered = $offered; started = $started; dropped = $dropped; completed = $completed
        dropped_cap_full = $droppedCapFull
        dropped_scheduler_missed = $droppedSchedulerMissed
        drop_policy = 'cap_full only (pending count == max_in_flight). Missed-schedule dropping is a separate policy and is DISABLED in this card, so dropped_scheduler_missed stays 0; a late slot is offered late and counted in schedule_lag_ms instead.'
        correct = $correct; failures = $failures; timeouts = $timeouts
        offered_equals_started_plus_dropped = ($offered -eq ($started + $dropped))
        started_equals_completed = ($started -eq $completed)
        inflight_at_end = $inflight.Count
        declared_window_ms = $declaredWindowMs
        window_source = $windowSource
        completed_in_window = $completedInWindow
        completed_after_window = $completedAfterWindow
        window_counts_add_up = (($completedInWindow + $completedAfterWindow) -eq $completed)
        in_window_qps = $(if ($declaredWindowMs -gt 0) { [Math]::Round($completedInWindow / ($declaredWindowMs / 1000.0), 3) } else { -1 })
        planned_window_ms = $declaredWindowMs
        # ---- P1.4b section 8: the BODY-READY window, computed from body_ready_offset_ms vs the frozen declared
        # boundary. The legacy observation window above is kept unchanged and may disagree (the owner's boundary case
        # is exactly that disagreement: body 2/0 vs observation 1/1).
        window_body = [ordered]@{
            declared_window_ms = $declaredWindowMs
            in_window = $bodyWinIn
            after_window = $bodyWinAfter
            add_up = (($bodyWinIn + $bodyWinAfter) -eq $bodyLatencyAll.Count)
            population = $bodyLatencyAll.Count
            excluded_no_body = $bodyReadyMissing
            stamp_defects = $bodyStampBad
            basis = 'body_ready_offset_ms (body_ready_mono_ms minus the frozen run monotonic origin) compared with the declared window boundary; rows without a complete body are excluded and counted, never imputed'
            legacy_basis = 'completed_in_window/completed_after_window use ended_ms (loop observation) and are kept as the OLD window'
            disagree_with_legacy = (($bodyWinIn -ne $completedInWindow) -or ($bodyWinAfter -ne $completedAfterWindow))
        }
        window_body_adds_up = (($bodyWinIn + $bodyWinAfter) -eq $bodyLatencyAll.Count)
        body_window_consistent = (($bodyStampBad -eq 0) -and ($bodyReadyMissing -eq ($completed - $bodyLatencyAll.Count)))
        run_elapsed_ms = [int]$drainEndMs
        drain_started_ms = [int]$drainStartMs
        drain_finished_ms = [int]$drainEndMs
        drain_ms = $(if ($drainStartMs -ge 0) { [int]($drainEndMs - $drainStartMs) } else { 0 })
        max_in_flight = $MaxInFlight
        request_timeout_ms = $RequestTimeoutMs
        request_timeout_fired = $timeouts
        interrupted = $interrupted
        interruption_message = $interruptMsg
        verdict_counts = $verdicts
        latency_all_ms = (Get-P14aPercentiles -Values ([double[]]$latenciesAll.ToArray()))
        latency_correct_ms = (Get-P14aPercentiles -Values ([double[]]$latenciesCorrect.ToArray()))
        schedule_lag_ms = (Get-P14aPercentiles -Values ([double[]]$dispatchLag.ToArray()) -Percents @(50, 95, 99))
        # ---- P1.4b: the NEW timing populations, all on the one monotonic axis ----
        dispatch_schedule_lag_mono_ms = (Get-P14aPercentiles -Values ([double[]]$dispatchLagMono.ToArray()) -Percents @(50, 95, 99))
        body_latency_ms = (Get-P14aPercentiles -Values ([double[]]$bodyLatencyAll.ToArray()) -Percents @(50, 95, 99))
        body_latency_correct_ms = (Get-P14aPercentiles -Values ([double[]]$bodyLatencyCorrect.ToArray()) -Percents @(50, 95, 99))
        observe_lag_ms = (Get-P14aPercentiles -Values ([double[]]$observeLag.ToArray()) -Percents @(50, 95, 99))
        persist_lag_ms = (Get-P14aPercentiles -Values ([double[]]$persistLag.ToArray()) -Percents @(50, 95, 99))
        flush_lag_ms = (Get-P14aPercentiles -Values ([double[]]$flushLags.ToArray()) -Percents @(50, 95, 99))
        flush_lag_max_ms = [Math]::Round($flushLagMax, 3)
        body_ready_missing = $bodyReadyMissing
        body_ready_missing_reasons = $bodyReadyMissingReasons
        body_latency_population_consistent = (($correct -eq $bodyLatencyCorrect.Count) -and ($bodyReadyMissing -eq ($completed - $bodyLatencyAll.Count)) -and ($bodyStampBad -eq 0))
        body_stamp_defects = $bodyStampBad
        monotonic = [ordered]@{
            source = 'System.Diagnostics.Stopwatch.GetTimestamp() with Stopwatch.Frequency (one machine-wide monotonic axis)'
            frequency = $monoFreq
            run_start_mono_ms = $monoStartMs
            dispatch_stamp = 'taken inside the measurement helper immediately before SendAsync (dispatch_mono_ms)'
            body_ready_stamp = 'taken inside the measurement helper immediately after the COMPLETE body bytes are in client memory (body_ready_mono_ms); absent when there is no complete body'
            observation_stamp = 'taken by this loop when it first observed the task completed (observe_mono_ms)'
            persist_stamp = 'taken by the ledger immediately before the line is written (ledger_written_mono_ms); the flush completion stamp cannot be inside the line it follows, so it is aggregated in flush_lag_ms'
            legacy_vs_mono_max_delta_ms = [Math]::Round($axisMaxDeltaMs, 3)
            legacy_vs_mono_note = 'per record, the helper''s dispatch stamp is taken microseconds after the collector read its legacy Stopwatch value; this delta is the PowerShell->.NET call overhead bound, NOT a clock-axis difference. The axis itself is proved by mono_elapsed_ms vs run_elapsed_ms.'
            run_end_mono_ms = $monoEndMs
            mono_elapsed_ms = $monoElapsedMs
            mono_vs_legacy_run_delta_ms = $axisRunDeltaMs
            not_a_server_measurement = 'body_ready includes the client-side completion continuation / thread-pool scheduling; it is NOT server service time and NOT the last TCP byte'
        }
        body_latency_is = 'dispatch_mono_ms -> body_ready_mono_ms; the correct subset uses the same re-judged population as correct/latency_correct_ms'
        observe_lag_is = 'body_ready_mono_ms -> observe_mono_ms (how long the main loop needed to notice the completed task)'
        timing_semantics = 'legacy elapsed_ms stays as before (dispatch -> loop observation). The P1.4b candidate latency is body_latency_ms (dispatch -> complete body available), computed on the same monotonic axis as observe_lag_ms/persist_lag_ms; loop_max_interval_ms still bounds the observation lag'
        loop_iterations = $loopIterations
        loop_max_interval_ms = $maxLoopIntervalMs
        test_pause = $(if ($TestPauseDurationMs -gt 0) { "collector MAIN LOOP paused $TestPauseDurationMs ms after start #$pauseAfterStarts at ${pauseAtMs}ms (offline regression hook, NOT business load, never used in a calibration)" } else { '' })
        observer_pid = $ObserverPid
        observer_summary_path = $ObserverSummary
        resource_observation = 'performed by the separate observer process, never by this loop (see the observer block attached by the entry point)'
        resource_cpu_semantics = 'cpu percent is machine normalized (share of ALL logical cores); core_equivalents = percent * logical_cores / 100'
        dropped_slots = @($droppedSlots)
        ledger_records = $Ledger.Count
        ledger_fsync_count = $Ledger.FsyncCount
        ledger_flush_policy = $Ledger.FlushPolicy
    }
    return $stats
}
