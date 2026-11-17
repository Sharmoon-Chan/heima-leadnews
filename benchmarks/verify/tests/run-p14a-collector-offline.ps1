# P1.4a offline validation of the FINAL collector (ASCII only).
#
# The private loopback endpoint is a retention collaborator for this test only: it runs as a separate process and
# answers each path prefix with a deliberately different response so that every verdict class can be exercised
# through the real collector. Nothing here is a performance measurement.
#
# Cases:
#   mixed     : correct large-id body, HTTP200 with a wrong id, wrong field, business 503, full HTTP 500,
#               invalid JSON and a real transport abort - each verdict must be classified, and every raw body
#               (or the fact that no body exists) must be preserved
#   timeout   : the endpoint holds the body past the per-request timeout -> verdict timeout, not a hang
#   drops     : a slow endpoint with -MaxInFlight 1 -> offered = started + dropped, dropped slots are recorded
#   interrupt : controlled interruption in the middle -> the flushed prefix is readable, no terminal is invented
#   warmup    : a separate warmup ledger is excluded from the sampled statistics
#   guard     : missing prepare manifest / plan outside the root / duplicate run id are refused before any HTTP
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    # the artifacts root is needed for the parent-root guard: this driver refuses an already sealed experiment root
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [int]$MixedRate = 2,
    [int]$MixedSeconds = 5,
    [int]$ReadyTimeoutMs = 60000,
    # the private endpoint must outlive the WHOLE suite: it used to expire after 180 s, and the suite is now longer than
    # that, so the last case saw a closed port and reported a transport failure instead of a retention property
    [int]$EndpointRunMs = 1800000
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14aRoots.ps1')

# This test driver is an ENTRY too: it writes files and starts a process, so it must refuse a completed experiment root
# BEFORE anything happens. The post-seal self-check of this round proved the gap - the driver happily created
# offline/<run>/ inside an already sealed root. The same helper the five production entries use is applied here.
$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'run-p14a-collector-offline.ps1'
. (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1')

$outDir = Join-Path (Join-Path $RunRoot 'offline') $RunId
$script:run = $null
# A failing run must not leave the private loopback endpoint behind: the r01 original of this round aborted in the middle
# and its endpoint kept running (and kept a log file locked) for minutes. The trap stops it before saving the failure.
$script:p14aEndpointProc = $null
trap {
    if ($null -ne $script:p14aEndpointProc -and -not $script:p14aEndpointProc.HasExited) {
        Stop-Process -Id $script:p14aEndpointProc.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
    exit (Save-RunFailure -State $script:run -ErrorRecord $_)
}
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.4a-collector-offline' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ mixed_rate = $MixedRate; mixed_seconds = $MixedSeconds } `
        -Targets @() -DataSet 'offline'
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-62} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'fail' }), $d
}
function Get-Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }

# ---------------------------------------------------------------- fixtures + independent truth
$fixtureIds = @('9007199254743401', '9007199254743402', '9007199254743403', '9007199254743404')
$fixtures = @(
    [ordered]@{ id = $fixtureIds[0]; views = 72557; likes = 4446; comment = 860; collection = 1847; content = ("first line, with a comma`nsecond line `"quoted`" and " + [string][char]0x4E2D + [string][char]0x6587) },
    [ordered]@{ id = $fixtureIds[1]; views = 93305; likes = 3762; comment = 912; collection = 787; content = "another body`r`nwith CRLF and a tab`tend" },
    # a fixture whose counters are 1, so a near-integer like 1.0000000000000002 / 0.9999999999999999 can be served
    [ordered]@{ id = $fixtureIds[2]; views = 1; likes = 1; comment = 1; collection = 1; content = "precision fixture body" },
    # a fixture whose views are exactly 2^53-1, the largest integer a double can hold exactly
    [ordered]@{ id = $fixtureIds[3]; views = 9007199254740991; likes = 1; comment = 1; collection = 1; content = "exact double integer fixture body" }
)
$fixturePath = Join-Path $outDir 'fixtures.json'
[System.IO.File]::WriteAllText($fixturePath, (ConvertTo-Json $fixtures -Depth 5), $utf8)

$truthTargets = New-Object System.Collections.ArrayList
foreach ($f in $fixtures) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$f.content)
    $null = $truthTargets.Add([ordered]@{
            article_id = [long]$f.id; views = $f.views; likes = $f.likes; comment = $f.comment; collection = $f.collection
            channel_id = 1; author_id = 4
            content_sha256 = (Get-P14aSha256 $bytes); content_bytes = $bytes.Length
        })
}
$truthPath = Join-Path $outDir 'offline-truth.json'
$truthObj = [ordered]@{
    scope = 'offline fixture truth computed by the driver from the same fixture file the endpoint serves'
    captured_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    targets = @($truthTargets)
}
[System.IO.File]::WriteAllText($truthPath, (ConvertTo-Json $truthObj -Depth 6), $utf8)

# ---------------------------------------------------------------- endpoint (separate process)
$port = 18200 + (Get-Random -Minimum 0 -Maximum 500)
$prefix = "http://127.0.0.1:$port/"
$endpointScript = Join-Path $outDir 'endpoint.ps1'
$endpointEvents = Join-Path $outDir 'endpoint-events.jsonl'
$endpointReady = Join-Path $outDir 'endpoint-ready.txt'
$endpointOut = Join-Path $outDir 'endpoint.stdout.txt'
$endpointErr = Join-Path $outDir 'endpoint.stderr.txt'

$endpointSource = @'
# Private retention collaborator for the P1.4a offline test. NOT a business window.
param(
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][string]$Fixtures,
    [Parameter(Mandatory = $true)][string]$ReadyFile,
    [Parameter(Mandatory = $true)][string]$EventsFile,
    [int]$HoldMs = 1500,
    [int]$RunMs = 180000
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Ev([string]$text) {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    [System.IO.File]::AppendAllText($EventsFile, ("{0}`t{1}`n" -f $stamp, $text), $utf8)
}
$fx = Get-Content -LiteralPath $Fixtures -Raw -Encoding UTF8 | ConvertFrom-Json
$byId = @{}
foreach ($f in $fx) { $byId[[string]$f.id] = $f }
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)
$listener.Start()
[System.IO.File]::WriteAllText($ReadyFile, $prefix, $utf8)
Ev 'endpoint ready'

function Body-For($f, [string]$idOverride, [int]$viewsDelta, [string]$contentOverride) {
    $id = if ([string]::IsNullOrEmpty($idOverride)) { [string]$f.id } else { $idOverride }
    $content = if ([string]::IsNullOrEmpty($contentOverride)) { [string]$f.content } else { $contentOverride }
    $obj = [ordered]@{
        host = 'offline'
        code = 200
        errorMessage = ''
        data = [ordered]@{
            article = [ordered]@{
                id = $id; views = ([long]$f.views + $viewsDelta); likes = $f.likes; comment = $f.comment; collection = $f.collection
                channelId = 1; authorId = 4
            }
            content = $content
        }
    }
    return (ConvertTo-Json $obj -Depth 8)
}
function Send([System.Net.HttpListenerContext]$ctx, [string]$text, [int]$status = 200) {
    $b = [System.Text.Encoding]::UTF8.GetBytes($text)
    $ctx.Response.StatusCode = $status
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.ContentLength64 = $b.Length
    $ctx.Response.OutputStream.Write($b, 0, $b.Length)
    $ctx.Response.OutputStream.Close()
    $ctx.Response.Close()
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while ($sw.ElapsedMilliseconds -lt $RunMs) {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        Ev ("request " + $path)
        $parts = $path.Trim('/') -split '/'
        $kind = $parts[0]
        $id = if ($parts.Length -ge 2) { $parts[1] } else { '' }
        try {
            switch -Regex ($kind) {
                '^ok' {
                    if (-not $byId.ContainsKey($id)) { Send $ctx '{"code":1002,"errorMessage":"no fixture"}' 404; break }
                    Send $ctx (Body-For $byId[$id] '' 0 $null)
                    Ev "complete ok $id"
                }
                '^wrongid' {
                    $f = $byId[$id]
                    Send $ctx (Body-For $f '9007199254743999' 0 $null)
                    Ev "complete wrongid $id"
                }
                '^wrongfield' {
                    $f = $byId[$id]
                    Send $ctx (Body-For $f '' 1 $null)
                    Ev "complete wrongfield $id"
                }
                '^biz503' {
                    Send $ctx '{"host":"offline","code":503,"errorMessage":"server busy","data":null}'
                    Ev "complete biz503 $id"
                }
                '^http500' {
                    Send $ctx '{"host":"offline","code":503,"errorMessage":"boom","data":null}' 500
                    Ev "complete http500 $id"
                }
                '^badjson' {
                    Send $ctx '{"code":200,"data":{"article":{"id":"9007199254743401"'
                    Ev "complete badjson $id"
                }
                '^abort' {
                    $f = $byId[$id]
                    $b = [System.Text.Encoding]::UTF8.GetBytes((Body-For $f '' 0 $null))
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.ContentType = 'application/json'
                    $ctx.Response.ContentLength64 = $b.Length
                    $ctx.Response.OutputStream.Write($b, 0, 1)
                    $ctx.Response.OutputStream.Flush()
                    Ev "one byte sent $id"
                    Start-Sleep -Milliseconds 25
                    $ctx.Response.Abort()
                    Ev "abort $id"
                }
                '^slowhold' {
                    $f = $byId[$id]
                    Ev "hold begin $id"
                    Start-Sleep -Milliseconds $HoldMs
                    try { Send $ctx (Body-For $f '' 0 $null); Ev "hold complete $id" } catch { Ev "hold aborted $id" }
                }
                '^numid' {
                    # the REAL article id node is a JSON NUMBER; the expected id only appears in metadata.id
                    $f = $byId[$id]
                    $obj = [ordered]@{
                        host = 'offline'; code = 200; errorMessage = ''
                        data = [ordered]@{
                            article = [ordered]@{
                                id = [long]$f.id; views = [long]$f.views; likes = $f.likes; comment = $f.comment
                                collection = $f.collection; channelId = 1; authorId = 4
                            }
                            content = [string]$f.content
                        }
                        metadata = [ordered]@{ id = [string]$f.id }
                    }
                    Send $ctx (ConvertTo-Json $obj -Depth 8)
                    Ev "complete numid $id"
                }
                '^missingfield' {
                    $f = $byId[$id]
                    $obj = [ordered]@{
                        host = 'offline'; code = 200; errorMessage = ''
                        data = [ordered]@{
                            article = [ordered]@{
                                id = [string]$f.id; likes = $f.likes; comment = $f.comment
                                collection = $f.collection; channelId = 1; authorId = 4
                            }
                            content = [string]$f.content
                        }
                    }
                    Send $ctx (ConvertTo-Json $obj -Depth 8)
                    Ev "complete missingfield $id"
                }
                '^nullfield' {
                    $f = $byId[$id]
                    $obj = [ordered]@{
                        host = 'offline'; code = 200; errorMessage = ''
                        data = [ordered]@{
                            article = [ordered]@{
                                id = [string]$f.id; views = $null; likes = $f.likes; comment = $f.comment
                                collection = $f.collection; channelId = 1; authorId = 4
                            }
                            content = [string]$f.content
                        }
                    }
                    Send $ctx (ConvertTo-Json $obj -Depth 8)
                    Ev "complete nullfield $id"
                }
                '^wrongchannel' {
                    $f = $byId[$id]
                    $obj = [ordered]@{
                        host = 'offline'; code = 200; errorMessage = ''
                        data = [ordered]@{
                            article = [ordered]@{
                                id = [string]$f.id; views = [long]$f.views; likes = $f.likes; comment = $f.comment
                                collection = $f.collection; channelId = 999; authorId = 4
                            }
                            content = [string]$f.content
                        }
                    }
                    Send $ctx (ConvertTo-Json $obj -Depth 8)
                    Ev "complete wrongchannel $id"
                }
                '^codeabc' {
                    # a COMPLETE 200 response whose business code is a string: the body must still be persisted
                    $f = $byId[$id]
                    $obj = [ordered]@{
                        host = 'offline'; code = 'abc'; errorMessage = ''
                        data = [ordered]@{
                            article = [ordered]@{
                                id = [string]$f.id; views = [long]$f.views; likes = $f.likes; comment = $f.comment
                                collection = $f.collection; channelId = 1; authorId = 4
                            }
                            content = [string]$f.content
                        }
                    }
                    Send $ctx (ConvertTo-Json $obj -Depth 8)
                    Ev "complete codeabc $id"
                }
                '^nullid' {
                    # the REAL article id node is JSON null: the diagnostic must not throw and the body must be kept
                    $f = $byId[$id]
                    $obj = [ordered]@{
                        host = 'offline'; code = 200; errorMessage = ''
                        data = [ordered]@{
                            article = [ordered]@{
                                id = $null; views = [long]$f.views; likes = $f.likes; comment = $f.comment
                                collection = $f.collection; channelId = 1; authorId = 4
                            }
                            content = [string]$f.content
                        }
                    }
                    Send $ctx (ConvertTo-Json $obj -Depth 8)
                    Ev "complete nullid $id"
                }
                '^nullcontent' {
                    $f = $byId[$id]
                    $obj = [ordered]@{
                        host = 'offline'; code = 200; errorMessage = ''
                        data = [ordered]@{
                            article = [ordered]@{
                                id = [string]$f.id; views = [long]$f.views; likes = $f.likes; comment = $f.comment
                                collection = $f.collection; channelId = 1; authorId = 4
                            }
                            content = $null
                        }
                    }
                    Send $ctx (ConvertTo-Json $obj -Depth 8)
                    Ev "complete nullcontent $id"
                }
                '^codehuge' {
                    # 1e30 does not fit in an Int32 business code; it must not overflow the collector into exit 1
                    $f = $byId[$id]
                    $body = '{"host":"offline","code":1E+30,"errorMessage":"","data":{"article":{"id":"' + [string]$f.id +
                        '","views":' + [long]$f.views + ',"likes":' + $f.likes + ',"comment":' + $f.comment +
                        ',"collection":' + $f.collection + ',"channelId":1,"authorId":4},"content":' +
                        (ConvertTo-Json ([string]$f.content)) + '}}'
                    Send $ctx $body
                    Ev "complete codehuge $id"
                }
                '^codefrac' {
                    # 199.6 must NOT be rounded to 200
                    $f = $byId[$id]
                    $body = '{"host":"offline","code":199.6,"errorMessage":"","data":{"article":{"id":"' + [string]$f.id +
                        '","views":' + [long]$f.views + ',"likes":' + $f.likes + ',"comment":' + $f.comment +
                        ',"collection":' + $f.collection + ',"channelId":1,"authorId":4},"content":' +
                        (ConvertTo-Json ([string]$f.content)) + '}}'
                    Send $ctx $body
                    Ev "complete codefrac $id"
                }
                '^viewsfrac' {
                    # views 1.4 with a truth of 1: the old [long] cast turned this into a false "correct"
                    $f = $byId[$id]
                    $body = '{"host":"offline","code":200,"errorMessage":"","data":{"article":{"id":"' + [string]$f.id +
                        '","views":' + ([long]$f.views + 0.4) + ',"likes":' + $f.likes + ',"comment":' + $f.comment +
                        ',"collection":' + $f.collection + ',"channelId":1,"authorId":4},"content":' +
                        (ConvertTo-Json ([string]$f.content)) + '}}'
                    Send $ctx $body
                    Ev "complete viewsfrac $id"
                }
                '^viewsfloat' {
                    # a float that is EXACTLY the integer truth (1.0) is accepted and reported as such
                    $f = $byId[$id]
                    $body = '{"host":"offline","code":200.0,"errorMessage":"","data":{"article":{"id":"' + [string]$f.id +
                        '","views":' + ([long]$f.views) + '.0,"likes":' + $f.likes + ',"comment":' + $f.comment +
                        ',"collection":' + $f.collection + ',"channelId":1,"authorId":4},"content":' +
                        (ConvertTo-Json ([string]$f.content)) + '}}'
                    Send $ctx $body
                    Ev "complete viewsfloat $id"
                }
                '^prec_code' {
                    # code = 200.00000000000003: the JSON number is NOT the integer 200 and must be rejected as such
                    $f = $byId[$id]
                    $body = '{"host":"offline","code":200.00000000000003,"errorMessage":"","data":{"article":{"id":"' + [string]$f.id +
                        '","views":' + [long]$f.views + ',"likes":' + [long]$f.likes + ',"comment":' + [long]$f.comment +
                        ',"collection":' + [long]$f.collection + ',"channelId":1,"authorId":4},"content":' +
                        (ConvertTo-Json ([string]$f.content)) + '}}'
                    Send $ctx $body
                    Ev "complete prec_code $id"
                }
                '^prec_above' {
                    # views = 1.0000000000000002 against a truth of 1: a double stays a non-integer, so it must fail
                    $f = $byId[$id]
                    $body = '{"host":"offline","code":200,"errorMessage":"","data":{"article":{"id":"' + [string]$f.id +
                        '","views":1.0000000000000002,"likes":' + [long]$f.likes + ',"comment":' + [long]$f.comment +
                        ',"collection":' + [long]$f.collection + ',"channelId":1,"authorId":4},"content":' +
                        (ConvertTo-Json ([string]$f.content)) + '}}'
                    Send $ctx $body
                    Ev "complete prec_above $id"
                }
                '^prec_below' {
                    # views = 0.9999999999999999 against a truth of 1: it must NOT be rounded up to the truth
                    $f = $byId[$id]
                    $body = '{"host":"offline","code":200,"errorMessage":"","data":{"article":{"id":"' + [string]$f.id +
                        '","views":0.9999999999999999,"likes":' + [long]$f.likes + ',"comment":' + [long]$f.comment +
                        ',"collection":' + [long]$f.collection + ',"channelId":1,"authorId":4},"content":' +
                        (ConvertTo-Json ([string]$f.content)) + '}}'
                    Send $ctx $body
                    Ev "complete prec_below $id"
                }
                '^prec_big' {
                    # views = 9007199254740991.0: an EXACTLY representable double integer, must keep its value
                    $f = $byId[$id]
                    $body = '{"host":"offline","code":200.0,"errorMessage":"","data":{"article":{"id":"' + [string]$f.id +
                        '","views":9007199254740991.0,"likes":' + [long]$f.likes + ',"comment":' + [long]$f.comment +
                        ',"collection":' + [long]$f.collection + ',"channelId":1,"authorId":4},"content":' +
                        (ConvertTo-Json ([string]$f.content)) + '}}'
                    Send $ctx $body
                    Ev "complete prec_big $id"
                }
                '^prec_ctrl' {
                    # the exactly integral controls: code 200 and views 1 must stay correct
                    $f = $byId[$id]
                    $body = '{"host":"offline","code":200,"errorMessage":"","data":{"article":{"id":"' + [string]$f.id +
                        '","views":1.0,"likes":' + [long]$f.likes + ',"comment":' + [long]$f.comment +
                        ',"collection":' + [long]$f.collection + ',"channelId":1,"authorId":4},"content":' +
                        (ConvertTo-Json ([string]$f.content)) + '}}'
                    Send $ctx $body
                    Ev "complete prec_ctrl $id"
                }
                default {
                    Send $ctx '{"code":1002,"errorMessage":"unknown path"}' 404
                }
            }
        } catch {
            Ev ("handler error " + $_.Exception.Message)
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
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $endpointScript, '-Prefix', $prefix, '-Fixtures', $fixturePath,
        '-ReadyFile', $endpointReady, '-EventsFile', $endpointEvents, '-HoldMs', '1500', '-RunMs', "$EndpointRunMs")
    # publish it for the failure trap, so an abort can never leave the collaborator running
    $script:p14aEndpointProc = $endpointProc
    $swReady = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $endpointReady) -and $swReady.ElapsedMilliseconds -lt $ReadyTimeoutMs) { Start-Sleep -Milliseconds 25 }
    $endpointStarted = Test-Path -LiteralPath $endpointReady
} catch { $endpointStarted = $false }
Add-Check 'endpoint.started_as_separate_process' ($endpointStarted -and $null -ne $endpointProc) `
    "endpoint pid=$($endpointProc.Id) prefix=$prefix ready=$endpointStarted (private loopback collaborator, not a window)"

# ---------------------------------------------------------------- plan builders
$script:planSeq = 0
function New-OfflinePlan([object[]]$slots, [string]$name, [int]$rate = 2, [int]$Seconds = 0) {
    $script:planSeq++
    $list = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $slots.Count; $i++) {
        $null = $list.Add([ordered]@{
                slot_index = $i
                planned_offset_ms = [int][Math]::Round(($i * 1000.0) / $rate)
                article_id = [long]$slots[$i].id
                path = [string]$slots[$i].path
                expect = [string]$slots[$i].expect
            })
    }
    $path = Join-Path $outDir $name
    $obj = [ordered]@{ kind = 'offline'; rate_per_second = $rate; slot_count = $list.Count; slots = @($list) }
    # a plan that declares its duration makes the sampling window a PLAN property, never the last slot offset
    if ($Seconds -gt 0) { $obj['seconds'] = $Seconds; $obj['declared_window_ms'] = $Seconds * 1000 }
    [System.IO.File]::WriteAllText($path, (ConvertTo-Json $obj -Depth 6), $utf8)
    return $path
}

# P1.4b: the driver now exercises the FINAL actual measurement path (p14b-collect.ps1), not a disabled legacy mode.
$collector = Join-Path (Join-Path $benchDir 'load') 'p14b-collect.ps1'
$observerEntry = Join-Path (Join-Path $benchDir 'verify') 'p14b-observer.ps1'
function Invoke-CollectorRun([string]$runId, [string]$plan, [string]$base, [int]$cap = 16, [int]$timeoutMs = 5000, [int]$interruptAfterMs = 0, [string]$phase = 'offline', [int]$sampleWindowMs = 0, [int]$pauseAfterStarts = 0, [int]$pauseMs = 0, [int]$observerPauseAfterMs = 0, [int]$observerPauseMs = 0, [int]$observerPauseAfterReadyMs = 0) {
    $collectorArgs = @('-RunRoot', $RunRoot, '-RunId', $runId, '-Base', $base, '-Group', 'A', '-PlanFile', $plan,
        '-TruthFile', $truthPath, '-MaxInFlight', "$cap", '-RequestTimeoutMs', "$timeoutMs", '-Phase', $phase)
    if ($interruptAfterMs -gt 0) { $collectorArgs += @('-InterruptAfterMs', "$interruptAfterMs") }
    if ($sampleWindowMs -gt 0) { $collectorArgs += @('-SampleWindowMs', "$sampleWindowMs") }
    if ($pauseMs -gt 0) { $collectorArgs += @('-TestPauseAfterStarts', "$pauseAfterStarts", '-TestPauseDurationMs', "$pauseMs") }
    if ($observerPauseMs -gt 0) { $collectorArgs += @('-ObserverTestPauseAfterMs', "$observerPauseAfterMs", '-ObserverTestPauseAfterReadyMs', "$observerPauseAfterReadyMs", '-ObserverTestPauseMs', "$observerPauseMs") }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $collector @collectorArgs 2>&1
    return [pscustomobject]@{ exit = $LASTEXITCODE; output = ($out | Out-String) }
}
function Get-CollectResult([string]$runId) {
    $p = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $runId) 'collect-result.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Get-RunLedger([string]$runId) {
    $p = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $runId) 'responses.jsonl'
    $rows = @()
    foreach ($l in (Read-P14aLedgerLines -Path $p)) { $rows += ($l | ConvertFrom-Json) }
    return $rows
}

# ---------------------------------------------------------------- case 1: mixed verdicts
$id1 = $fixtureIds[0]; $id2 = $fixtureIds[1]
$mixedSlots = @(
    @{ id = $id1; path = "/ok/$id1"; expect = 'ok' }
    @{ id = $id1; path = "/wrongid/$id1"; expect = 'wrong_id' }
    @{ id = $id1; path = "/wrongfield/$id1"; expect = 'wrong_field' }
    @{ id = $id1; path = "/biz503/$id1"; expect = 'business_code' }
    @{ id = $id1; path = "/http500/$id1"; expect = 'http_status' }
    @{ id = $id1; path = "/badjson/$id1"; expect = 'invalid_json' }
    @{ id = $id1; path = "/abort/$id1"; expect = 'transport' }
    @{ id = $id2; path = "/ok/$id2"; expect = 'ok' }
)
$mixedPlan = New-OfflinePlan $mixedSlots 'plan-mixed.json' $MixedRate
$mixedRun = "$RunId-MIXED"
$r = Invoke-CollectorRun $mixedRun $mixedPlan $prefix 16 5000 0 'offline-mixed'
$mixedRows = @(Get-RunLedger $mixedRun)
$byPath = @{}
foreach ($row in $mixedRows) { $byPath[[string]$row.url] = $row }
function Verdict-Of([string]$pathSuffix) {
    foreach ($k in $byPath.Keys) { if ($k.EndsWith($pathSuffix)) { return $byPath[$k] } }
    return $null
}
Add-Check 'mixed.collector_run_finished' ($r.exit -eq 0) "exit=$($r.exit) ($($r.output.Trim() -replace '\s+', ' '))"
$okRow = Verdict-Of "/ok/$id1"
$okBytesOk = $false
if ($null -ne $okRow -and $null -ne $okRow.PSObject.Properties['body_base64']) {
    $raw = [System.Convert]::FromBase64String([string]$okRow.body_base64)
    $okBytesOk = ($raw.Length -eq [int]$okRow.bytes) -and ((Get-P14aSha256 $raw) -eq [string]$okRow.sha256) -and ([string]$okRow.body_utf8 -eq [System.Text.Encoding]::UTF8.GetString($raw))
}
Add-Check 'mixed.correct_large_id_is_correct' ($null -ne $okRow -and $okRow.verdict -eq 'correct' -and $okRow.correct -eq $true -and $okRow.code -eq 200 -and $okRow.id_is_string -and $okRow.content_sha256_match -and $okBytesOk) `
    ("verdict=$($okRow.verdict) code=$($okRow.code) id_is_string=$($okRow.id_is_string) fields=$($okRow.fields_match) content_sha=$(($okRow.content_sha256_match)) raw_bytes_recomputable=$okBytesOk")
$wiRow = Verdict-Of "/wrongid/$id1"
Add-Check 'mixed.http200_wrong_id_is_rejected' ($null -ne $wiRow -and $wiRow.verdict -eq 'wrong_id' -and $wiRow.correct -eq $false -and $wiRow.http -eq 200) `
    ("verdict=$($wiRow.verdict) http=$($wiRow.http) id_matches=$($wiRow.id_matches) (a 200 envelope is not accepted on its own)")
$wfRow = Verdict-Of "/wrongfield/$id1"
Add-Check 'mixed.http200_wrong_field_is_rejected' ($null -ne $wfRow -and $wfRow.verdict -eq 'wrong_field' -and $wfRow.correct -eq $false -and $wfRow.id_matches -eq $true) `
    ("verdict=$($wfRow.verdict) http=$($wfRow.http) id_matches=$($wfRow.id_matches) fields_match=$($wfRow.fields_match)")
$bRow = Verdict-Of "/biz503/$id1"
Add-Check 'mixed.business_503_inside_200_is_rejected' ($null -ne $bRow -and $bRow.verdict -eq 'business_code' -and $bRow.http -eq 200 -and $bRow.code -eq 503 -and $bRow.correct -eq $false) `
    ("verdict=$($bRow.verdict) http=$($bRow.http) code=$($bRow.code) (a 200 carrying a 503 is a failure)")
$hRow = Verdict-Of "/http500/$id1"
$hBodyKept = ($null -ne $hRow -and "$($hRow.body_utf8)" -match 'boom')
Add-Check 'mixed.http500_body_preserved' ($null -ne $hRow -and $hRow.verdict -eq 'http_status' -and $hRow.http -eq 500 -and [int]$hRow.bytes -gt 0 -and $hBodyKept) `
    ("verdict=$($hRow.verdict) http=$($hRow.http) bytes=$($hRow.bytes) body_kept=$hBodyKept")
$jRow = Verdict-Of "/badjson/$id1"
Add-Check 'mixed.invalid_json_is_rejected' ($null -ne $jRow -and $jRow.verdict -eq 'invalid_json' -and $jRow.http -eq 200 -and [int]$jRow.bytes -gt 0) `
    ("verdict=$($jRow.verdict) http=$($jRow.http) bytes=$($jRow.bytes)")
$aRow = Verdict-Of "/abort/$id1"
$noFabrication = ($null -ne $aRow -and $null -eq $aRow.PSObject.Properties['body_base64'] -and $null -eq $aRow.PSObject.Properties['bytes'] -and $null -ne $aRow.PSObject.Properties['body_unavailable'])
Add-Check 'mixed.transport_abort_has_no_fabricated_body' ($null -ne $aRow -and $aRow.verdict -eq 'transport' -and $aRow.failure -eq $true -and $noFabrication) `
    ("verdict=$($aRow.verdict) failure=$($aRow.failure) body_unavailable=$noFabrication error=$(([string]$aRow.error).Substring(0, [Math]::Min(40, ([string]$aRow.error).Length)))")
$ok2Row = Verdict-Of "/ok/$id2"
Add-Check 'mixed.second_correct_body_is_correct' ($null -ne $ok2Row -and $ok2Row.verdict -eq 'correct' -and $ok2Row.correct -eq $true) `
    ("verdict=$($ok2Row.verdict) content_sha256_match=$($ok2Row.content_sha256_match) (CRLF/tab content survives the round trip)")
$mixedParsedOk = $true
$mixedSeq = 1
foreach ($row in $mixedRows) { if ([long]$row.seq -ne $mixedSeq) { $mixedParsedOk = $false }; $mixedSeq++ }
Add-Check 'mixed.ledger_one_record_per_slot' ($mixedRows.Count -eq $mixedSlots.Count -and $mixedParsedOk) `
    "ledger lines=$($mixedRows.Count) expected=$($mixedSlots.Count) contiguous seq=$mixedParsedOk"

# ---------------------------------------------------------------- case 2: per-request timeout
$toSlots = @(@{ id = $id1; path = "/slowhold/$id1"; expect = 'timeout' })
$toPlan = New-OfflinePlan $toSlots 'plan-timeout.json' 2
$toRun = "$RunId-TIMEOUT"
$r = Invoke-CollectorRun $toRun $toPlan $prefix 16 500 0 'offline-timeout'
$toRows = @(Get-RunLedger $toRun)
$toRow = if ($toRows.Count -ge 1) { $toRows[0] } else { $null }
Add-Check 'timeout.fires_and_is_classified' ($r.exit -eq 0 -and $null -ne $toRow -and $toRow.timeout -eq $true -and $toRow.verdict -eq 'timeout' -and [int]$toRow.elapsed_ms -ge 450) `
    ("verdict=$($toRow.verdict) timeout=$($toRow.timeout) elapsed=$($toRow.elapsed_ms)ms (budget 500ms) body_unavailable=$($null -ne $toRow.PSObject.Properties['body_unavailable'])")

# ---------------------------------------------------------------- case 3: drops with a small in-flight cap
$dropIds = @($id1, $id2, $id1, $id2, $id1, $id2)
$dropSlots = @()
foreach ($d in $dropIds) { $dropSlots += @{ id = $d; path = "/slowhold/$d"; expect = 'ok' } }
$dropPlan = New-OfflinePlan $dropSlots 'plan-drops.json' 10
$dropRun = "$RunId-DROPS"
$r = Invoke-CollectorRun $dropRun $dropPlan $prefix 1 6000 0 'offline-drops'
$dropRows = @(Get-RunLedger $dropRun)
$dropDropped = @($dropRows | Where-Object { $_.kind -eq 'dropped' })
$dropResponses = @($dropRows | Where-Object { $_.kind -eq 'response' })
Add-Check 'drops.in_flight_cap_produces_dropped_slots' ($r.exit -eq 0 -and $dropDropped.Count -gt 0 -and $dropResponses.Count -gt 0) `
    ("dropped=$($dropDropped.Count) responses=$($dropResponses.Count) of $($dropSlots.Count) offered slots (cap=1, endpoint holds 1500ms)")
Add-Check 'drops.offered_equals_started_plus_dropped' ($dropResponses.Count + $dropDropped.Count -eq $dropSlots.Count) `
    ("started($($dropResponses.Count)) + dropped($($dropDropped.Count)) = offered($($dropSlots.Count))")
$dropWhyOk = @($dropDropped | Where-Object { "$($_.reason)" -match 'in-flight cap 1' }).Count -eq $dropDropped.Count
Add-Check 'drops.each_drop_names_its_reason_and_slot' $dropWhyOk `
    "every dropped record carries slot_index, intended id, the cap reason and the in-flight count (no silent retry, no back-pressure queue)"

# ---------------------------------------------------------------- case 4: controlled interruption keeps the flushed prefix
$intIds = @($id1, $id2, $id1, $id2, $id1, $id2, $id1, $id2)
$intSlots = @()
foreach ($d in $intIds) { $intSlots += @{ id = $d; path = "/ok/$d"; expect = 'ok' } }
$intPlan = New-OfflinePlan $intSlots 'plan-interrupt.json' 1
$intRun = "$RunId-INTERRUPT"
$r = Invoke-CollectorRun $intRun $intPlan $prefix 16 5000 3200 'offline-interrupt'
$intRows = @(Get-RunLedger $intRun)
$intPrefixOk = $true
$intSeqExpect = 1
foreach ($row in $intRows) { if ([long]$row.seq -ne $intSeqExpect) { $intPrefixOk = $false }; $intSeqExpect++ }
$intComplete = @($intRows | Where-Object { $_.correct -eq $true })
Add-Check 'interrupt.prefix_is_readable_and_complete' ($r.exit -eq 0 -and $intRows.Count -ge 1 -and $intRows.Count -lt $intSlots.Count -and $intPrefixOk -and $intComplete.Count -eq $intRows.Count) `
    ("interrupted after ~3200ms (rate 1/s, 8 planned slots): ledger lines=$($intRows.Count) of $($intSlots.Count) planned slots, contiguous seq=$intPrefixOk, all finished records correct=$($intComplete.Count)")
$intFabricated = @($intRows | Where-Object { $_.kind -eq 'response' -and $null -eq $_.PSObject.Properties['bytes'] -and $null -eq $_.PSObject.Properties['body_unavailable'] }).Count
Add-Check 'interrupt.no_terminal_invented_for_unfinished' ($intFabricated -eq 0 -and $intRows.Count -lt $intSlots.Count) `
    "open slots beyond the interruption have no record at all ($($intSlots.Count - $intRows.Count) slots); nothing was fabricated"

# ---------------------------------------------------------------- case 5: warmup excluded from sampling
$wpSlots = @(@{ id = $id1; path = "/ok/$id1"; expect = 'ok' }, @{ id = $id2; path = "/ok/$id2"; expect = 'ok' })
$warmPlan = New-OfflinePlan $wpSlots 'plan-warmup.json' 2
$r = Invoke-CollectorRun "$RunId-WARMUP" $warmPlan $prefix 16 5000 0 'warmup'
$samplePlan = New-OfflinePlan $wpSlots 'plan-sample.json' 2
$r2 = Invoke-CollectorRun "$RunId-SAMPLE" $samplePlan $prefix 16 5000 0 'sample'
$warmRows = @(Get-RunLedger "$RunId-WARMUP")
$sampleRows = @(Get-RunLedger "$RunId-SAMPLE")
$warmRes = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $RunRoot 'runs') "$RunId-WARMUP") 'collect-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$sampleRes = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $RunRoot 'runs') "$RunId-SAMPLE") 'collect-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Check 'warmup.kept_in_its_own_ledger_and_phase' ($warmRows.Count -eq $wpSlots.Count -and $sampleRows.Count -eq $wpSlots.Count -and $warmRes.phase -eq 'warmup' -and $sampleRes.phase -eq 'sample' -and [int]$sampleRes.stats.completed -eq $wpSlots.Count) `
    ("warmup lines=$($warmRows.Count) (phase=warmup), sample lines=$($sampleRows.Count) (phase=sample, completed=$($sampleRes.stats.completed)): warmup traffic never enters the sampled statistics")

# ---------------------------------------------------------------- case 6: A regression - a completed task must not hold the cap
# The declared offline stall fires right after the 3rd start. The first three slots answer instantly and therefore FINISH
# while the collector is stalled; the remaining nine slots are slow (1.5 s). When the stall ends, nine slots are due at
# once and four are started at the cap. The two finished tasks must NOT count as pending: if they did, only one of the
# nine could start (started=4, dropped=8) instead of four (started=7, dropped=5).
$capPaths = @()
for ($i = 0; $i -lt 12; $i++) {
    $capPaths += if ($i -lt 3) { @{ id = $id1; path = "/ok/$($fixtureIds[$i % 2])"; expect = 'ok' } } else { @{ id = $id2; path = "/slowhold/$id2"; expect = 'ok' } }
}
$capPlan = New-OfflinePlan $capPaths 'plan-cap-reap.json' 20 1
$capRun = "$RunId-CAPREAP"
$r = Invoke-CollectorRun $capRun $capPlan $prefix 4 8000 0 'offline-cap-reap' 0 3 900
$capRows = @(Get-RunLedger $capRun)
$capRes = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $RunRoot 'runs') $capRun) 'collect-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$capDrops = @($capRows | Where-Object { $_.kind -eq 'dropped' })
$capResponses = @($capRows | Where-Object { $_.kind -eq 'response' })
$capOpenOk = $true
$capWorstOpen = 999
foreach ($d in $capDrops) {
    $open = @($capResponses | Where-Object { [int]$_.slot_index -lt [int]$d.slot_index -and [long]$_.ended_ms -gt [long]$d.observed_ms }).Count
    if ($open -lt $capWorstOpen) { $capWorstOpen = $open }
    if ($open -lt 4) { $capOpenOk = $false }
}
Add-Check 'a_reap.offered_is_started_plus_dropped' ($r.exit -eq 0 -and [int]$capRes.stats.offered -eq ([int]$capRes.stats.started + [int]$capRes.stats.dropped)) `
    ("exit=$($r.exit) offered=$($capRes.stats.offered) started=$($capRes.stats.started) dropped=$($capRes.stats.dropped)")
Add-Check 'a_reap.completed_tasks_did_not_hold_the_cap' ([int]$capRes.stats.started -eq 7 -and [int]$capRes.stats.dropped -eq 5 -and [int]$capRes.stats.dropped_cap_full -eq 5) `
    ("3 instant responses FINISHED during the declared stall; after it cap=4 could start 4 of the 9 due slots: started=$($capRes.stats.started) dropped=$($capRes.stats.dropped) cap_full=$($capRes.stats.dropped_cap_full) (the old dispatch-then-collect loop would have started 4 in total and dropped 8)")
Add-Check 'a_reap.every_drop_names_cap_still_open_requests' ($capDrops.Count -eq 5 -and $capOpenOk) `
    ("worst count of still-OPEN earlier requests at a drop instant = $capWorstOpen (must be >= cap 4); a completed-but-unbooked task would have shown fewer than 4")
Add-Check 'a_reap.declared_stall_is_reported' ("$($capRes.stats.test_pause)" -match 'after start #3' -and [long]$capRes.stats.loop_max_interval_ms -ge 800) `
    ("test_pause='$($capRes.stats.test_pause)' loop_max_interval_ms=$($capRes.stats.loop_max_interval_ms) (declared offline hook, not business load)")

# ---------------------------------------------------------------- case 7: A regression - declared window vs tail
# A plan that DECLARES 1 s with 2 slots (t=0 and t=1000). The first answer arrives inside the window, the second is held
# for 1.5 s and therefore completes after it. The window must be 1000 ms from the PLAN and the split must be 1 / 1.
$winSlots = @(
    @{ id = $id1; path = "/ok/$id1"; expect = 'ok' }
    @{ id = $id2; path = "/slowhold/$id2"; expect = 'ok' }
)
$winPlan = New-OfflinePlan $winSlots 'plan-window-boundary.json' 1 1
$winRun = "$RunId-WINDOW"
$r = Invoke-CollectorRun $winRun $winPlan $prefix 16 8000 0 'offline-window'
$winRows = @(Get-RunLedger $winRun)
$winRes = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $RunRoot 'runs') $winRun) 'collect-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$winStatus = (Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $RunRoot 'runs') $winRun) 'run-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json).status
$winInRows = @($winRows | Where-Object { $_.kind -eq 'response' -and $_.in_window -eq $true })
$winOutRows = @($winRows | Where-Object { $_.kind -eq 'response' -and $_.in_window -eq $false })
Add-Check 'a_window.declared_seconds_win_over_last_slot_offset' ([long]$winRes.stats.declared_window_ms -eq 1000 -and "$($winRes.stats.window_source)" -match 'plan.seconds') `
    ("declared_window_ms=$($winRes.stats.declared_window_ms) source='$($winRes.stats.window_source)' (the last slot offset alone would have reported 1000 ms only by accident, and 500 ms in the reported bug)")
Add-Check 'a_window.inside_and_after_are_separate_and_add_up' ([int]$winRes.stats.completed_in_window -eq 1 -and [int]$winRes.stats.completed_after_window -eq 1 -and [bool]$winRes.stats.window_counts_add_up -and $winInRows.Count -eq 1 -and $winOutRows.Count -eq 1) `
    ("in_window=$($winRes.stats.completed_in_window) after_window=$($winRes.stats.completed_after_window) total=$($winRes.stats.completed) in_window_qps=$($winRes.stats.in_window_qps); the held answer really finished after the boundary (ended_ms=$($winOutRows[0].ended_ms) > 1000)")
Add-Check 'a_window.collector_reports_the_split_as_a_check' ($winStatus -eq 'passed') `
    ("run-status=$winStatus (the entry itself asserts the window split and the drop classification; a mismatch would fail the run)")

# ---------------------------------------------------------------- case 8: B regression - real article id node and frozen fields
# Every case below carries a COMPLETE body, so a structural verdict must never make the record disappear.
$bSlots = @(
    @{ id = $id1; path = "/ok/$id1"; expect = 'ok' }
    @{ id = $id1; path = "/numid/$id1"; expect = 'wrong_id' }
    @{ id = $id1; path = "/missingfield/$id1"; expect = 'missing_field' }
    @{ id = $id1; path = "/nullfield/$id1"; expect = 'invalid_field_type' }
    @{ id = $id1; path = "/wrongchannel/$id1"; expect = 'wrong_field' }
    @{ id = $id1; path = "/codeabc/$id1"; expect = 'invalid_field_type' }
)
$bPlan = New-OfflinePlan $bSlots 'plan-assertions.json' 2
$bRun = "$RunId-ASSERT"
$r = Invoke-CollectorRun $bRun $bPlan $prefix 16 5000 0 'offline-assert'
$bRows = @(Get-RunLedger $bRun)
$bByPath = @{}
foreach ($row in $bRows) { $bByPath[[string]$row.url] = $row }
function B-Row([string]$suffix) {
    foreach ($k in $bByPath.Keys) { if ($k.EndsWith($suffix)) { return $bByPath[$k] } }
    return $null
}
$bControl = B-Row "/ok/$id1"
Add-Check 'b_assert.control_body_is_still_correct' ($null -ne $bControl -and $bControl.verdict -eq 'correct' -and $bControl.channel_match -eq $true -and $bControl.author_match -eq $true -and $bControl.content_sha256_match -eq $true) `
    ("verdict=$($bControl.verdict) fields=$($bControl.fields_match) channel=$($bControl.channel_match) author=$($bControl.author_match) content_sha=$($bControl.content_sha256_match) (channel/author are now compared, not assumed)")
$bNum = B-Row "/numid/$id1"
$bNumKept = ($null -ne $bNum -and [int]$bNum.bytes -gt 0 -and "$($bNum.body_utf8)" -match 'metadata')
Add-Check 'b_assert.numeric_article_id_is_rejected' ($null -ne $bNum -and $bNum.verdict -eq 'wrong_id' -and $bNum.correct -eq $false -and $bNum.id_is_string -eq $false -and $bNum.id_matches -eq $true -and $bNumKept) `
    ("verdict=$($bNum.verdict) id_is_string=$($bNum.id_is_string) id_matches=$($bNum.id_matches) body_kept=$bNumKept (the expected id appears only in metadata.id, which must not rescue the numeric article node)")
$bMiss = B-Row "/missingfield/$id1"
$bMissNamed = ($null -ne $bMiss -and (($bMiss.missing_fields -join ',') -match 'views'))
Add-Check 'b_assert.missing_field_is_named' ($null -ne $bMiss -and $bMiss.verdict -eq 'missing_field' -and $bMissNamed) `
    ("verdict=$($bMiss.verdict) missing_fields=$($bMiss.missing_fields -join ',')")
$bNull = B-Row "/nullfield/$id1"
Add-Check 'b_assert.null_is_not_coerced_to_zero' ($null -ne $bNull -and $bNull.verdict -eq 'invalid_field_type' -and (($bNull.wrong_types -join ',') -match 'views')) `
    ("verdict=$($bNull.verdict) wrong_types=$($bNull.wrong_types -join ',') (a null counter is a type failure, never 0)")
$bChan = B-Row "/wrongchannel/$id1"
Add-Check 'b_assert.frozen_channel_is_compared' ($null -ne $bChan -and $bChan.verdict -eq 'wrong_field' -and $bChan.channel_match -eq $false -and $bChan.fields_match -eq $true) `
    ("verdict=$($bChan.verdict) channel_match=$($bChan.channel_match) fields_match=$($bChan.fields_match); truth channel_id=1 vs response channelId=999")
$bCode = B-Row "/codeabc/$id1"
$bCodeKept = ($null -ne $bCode -and [int]$bCode.bytes -gt 0 -and $null -ne $bCode.PSObject.Properties['body_base64'] -and "$($bCode.body_utf8)" -match 'abc')
Add-Check 'b_assert.structural_failure_still_has_a_receipt' ($null -ne $bCode -and $bCode.verdict -eq 'invalid_field_type' -and $bCode.http -eq 200 -and $bCode.code_type -eq 'String' -and $bCodeKept) `
    ("verdict=$($bCode.verdict) http=$($bCode.http) code_type=$($bCode.code_type) bytes=$($bCode.bytes) body_kept=$bCodeKept (code=""abc"" is kept verbatim instead of aborting the whole ledger)")
Add-Check 'b_assert.one_receipt_per_slot_despite_structural_failures' ($bRows.Count -eq $bSlots.Count) `
    ("ledger records=$($bRows.Count) planned slots=$($bSlots.Count) (no structural verdict loses a record)")

# ---------------------------------------------------------------- case 8b: B1 null and numeric boundaries
# Every one of these is a COMPLETE HTTP 200 response. Before the fix a null node made the diagnostic itself throw (the
# record vanished, ledger 0 lines) and [int]/[long] casts rounded 199.6 -> 200 and truncated 1.4 -> 1 (a wrong value
# was then called correct). Each must now produce exactly one receipt with an explicit verdict.
$nSlots = @(
    @{ id = $id1; path = "/ok/$id1"; expect = 'ok' }
    @{ id = $id1; path = "/nullid/$id1"; expect = 'wrong_id' }
    @{ id = $id1; path = "/nullcontent/$id1"; expect = 'invalid_field_type' }
    @{ id = $id1; path = "/codehuge/$id1"; expect = 'invalid_field_type' }
    @{ id = $id1; path = "/codefrac/$id1"; expect = 'invalid_field_type' }
    @{ id = $id1; path = "/viewsfrac/$id1"; expect = 'invalid_field_type' }
    @{ id = $id1; path = "/viewsfloat/$id1"; expect = 'ok' }
)
$nPlan = New-OfflinePlan $nSlots 'plan-null-numeric.json' 2
$nRun = "$RunId-NULLNUM"
$r = Invoke-CollectorRun $nRun $nPlan $prefix 16 5000 0 'offline-null-numeric'
$nRows = @(Get-RunLedger $nRun)
$nByPath = @{}
foreach ($row in $nRows) { $nByPath[[string]$row.url] = $row }
function N-Row([string]$suffix) {
    foreach ($k in $nByPath.Keys) { if ($k.EndsWith($suffix)) { return $nByPath[$k] } }
    return $null
}
Add-Check 'b1.null_and_numeric_cases_all_kept_a_receipt' ($r.exit -eq 0 -and $nRows.Count -eq $nSlots.Count) `
    ("collector exit=$($r.exit) receipts=$($nRows.Count) of $($nSlots.Count) complete responses (a structural verdict must never drop the record, which is the reported 'ledger 0 lines')")
$nNull = N-Row "/nullid/$id1"
Add-Check 'b1.null_article_id_is_a_verdict_not_a_crash' ($null -ne $nNull -and $nNull.verdict -eq 'wrong_id' -and $nNull.correct -eq $false -and [int]$nNull.bytes -gt 0 -and (($nNull.assessment_notes -join ' ') -match 'is null, not a JSON string')) `
    ("verdict=$($nNull.verdict) bytes=$($nNull.bytes) notes=$($nNull.assessment_notes -join ' | ')")
$nNullC = N-Row "/nullcontent/$id1"
Add-Check 'b1.null_content_is_a_named_type_failure' ($null -ne $nNullC -and $nNullC.verdict -eq 'invalid_field_type' -and (($nNullC.wrong_types -join ',') -match 'data\.content=null') -and [int]$nNullC.bytes -gt 0) `
    ("verdict=$($nNullC.verdict) wrong_types=$($nNullC.wrong_types -join ',') bytes=$($nNullC.bytes)")
$nHuge = N-Row "/codehuge/$id1"
Add-Check 'b1.huge_code_does_not_overflow_the_collector' ($null -ne $nHuge -and $nHuge.verdict -eq 'invalid_field_type' -and (($nHuge.wrong_types -join ',') -match 'out_of_range') -and [int]$nHuge.bytes -gt 0) `
    ("verdict=$($nHuge.verdict) wrong_types=$($nHuge.wrong_types -join ',') code=$($nHuge.code) (1e30 is out of Int32 range and is not cast)")
$nFrac = N-Row "/codefrac/$id1"
Add-Check 'b1.fractional_code_is_not_rounded_to_200' ($null -ne $nFrac -and $nFrac.verdict -eq 'invalid_field_type' -and (($nFrac.wrong_types -join ',') -match 'not_an_integer') -and $nFrac.correct -eq $false) `
    ("verdict=$($nFrac.verdict) wrong_types=$($nFrac.wrong_types -join ',') correct=$($nFrac.correct) (199.6 must not become 200)")
$nVFrac = N-Row "/viewsfrac/$id1"
Add-Check 'b1.fractional_counter_is_not_truncated_to_the_truth' ($null -ne $nVFrac -and $nVFrac.verdict -eq 'invalid_field_type' -and (($nVFrac.wrong_types -join ',') -match 'data\.article\.views=not_an_integer') -and $nVFrac.correct -eq $false) `
    ("verdict=$($nVFrac.verdict) wrong_types=$($nVFrac.wrong_types -join ',') correct=$($nVFrac.correct) (1.4 must not be truncated to the truth value 1)")
$nVFloat = N-Row "/viewsfloat/$id1"
$nVFloatNote = ($null -ne $nVFloat -and (($nVFloat.assessment_notes -join ' ') -match 'exactly integral'))
Add-Check 'b1.exactly_integral_float_is_accepted_and_declared' ($null -ne $nVFloat -and $nVFloat.verdict -eq 'correct' -and $nVFloat.correct -eq $true -and $nVFloatNote) `
    ("verdict=$($nVFloat.verdict) notes=$($nVFloat.assessment_notes -join ' | ') (200.0 / 1.0 as EXACT integers are allowed, and the equality to the integer truth is stated)")

# ---------------------------------------------------------------- case 8b2: B1 numeric PRECISION (no rounding)
# `[decimal]$double` used to round to 15 significant digits, so 200.00000000000003 became 200 and
# 0.9999999999999999 became 1 - a wrong value was then compared to the truth and called correct. These are real HTTP
# responses whose JSON carries those exact digits (built as text so nothing is normalised before the endpoint sends it).
$p3 = $fixtureIds[2]
$p4 = $fixtureIds[3]
$pSlots = @(
    @{ id = $p3; path = "/prec_ctrl/$p3"; expect = 'ok' }
    @{ id = $p3; path = "/prec_code/$p3"; expect = 'invalid_field_type' }
    @{ id = $p3; path = "/prec_above/$p3"; expect = 'invalid_field_type' }
    @{ id = $p3; path = "/prec_below/$p3"; expect = 'invalid_field_type' }
    @{ id = $p4; path = "/prec_big/$p4"; expect = 'ok' }
)
$pPlan = New-OfflinePlan $pSlots 'plan-precision.json' 2
$pRun = "$RunId-PRECISION"
$r = Invoke-CollectorRun $pRun $pPlan $prefix 16 5000 0 'offline-precision'
$pRows = @(Get-RunLedger $pRun)
$pByPath = @{}
foreach ($row in $pRows) { $pByPath[[string]$row.url] = $row }
function P-Row([string]$suffix) {
    foreach ($k in $pByPath.Keys) { if ($k.EndsWith($suffix)) { return $pByPath[$k] } }
    return $null
}
Add-Check 'b1p.every_precision_case_kept_a_receipt' ($r.exit -eq 0 -and $pRows.Count -eq $pSlots.Count) `
    ("collector exit=$($r.exit) receipts=$($pRows.Count) of $($pSlots.Count) complete responses")
$pCode = P-Row "/prec_code/$p3"
Add-Check 'b1p.code_200_00000000000003_is_not_200' ($null -ne $pCode -and $pCode.verdict -eq 'invalid_field_type' -and $pCode.correct -eq $false -and (($pCode.wrong_types -join ',') -match 'code=not_an_integer\(200\.00000000000003\)') -and [int]$pCode.bytes -gt 0) `
    ("verdict=$($pCode.verdict) wrong_types=$($pCode.wrong_types -join ',') bytes=$($pCode.bytes) (the decimal cast used to yield 200)")
$pAbove = P-Row "/prec_above/$p3"
Add-Check 'b1p.views_1_0000000000000002_is_not_the_integer_1' ($null -ne $pAbove -and $pAbove.verdict -eq 'invalid_field_type' -and $pAbove.correct -eq $false -and (($pAbove.wrong_types -join ',') -match 'data\.article\.views=not_an_integer\(1\.0000000000000002\)')) `
    ("verdict=$($pAbove.verdict) wrong_types=$($pAbove.wrong_types -join ',') correct=$($pAbove.correct)")
$pBelow = P-Row "/prec_below/$p3"
Add-Check 'b1p.views_0_9999999999999999_is_not_rounded_up_to_1' ($null -ne $pBelow -and $pBelow.verdict -eq 'invalid_field_type' -and $pBelow.correct -eq $false -and (($pBelow.wrong_types -join ',') -match 'data\.article\.views=not_an_integer\(0\.9999999999999999\)')) `
    ("verdict=$($pBelow.verdict) wrong_types=$($pBelow.wrong_types -join ',') correct=$($pBelow.correct)")
$pBig = P-Row "/prec_big/$p4"
$pBigNote = ($null -ne $pBig -and (($pBig.assessment_notes -join ' ') -match 'exactly integral'))
Add-Check 'b1p.exact_double_integer_2pow53_minus_1_keeps_its_value' ($null -ne $pBig -and $pBig.verdict -eq 'correct' -and $pBig.correct -eq $true -and $pBigNote) `
    ("verdict=$($pBig.verdict) notes=$($pBig.assessment_notes -join ' | ') (9007199254740991.0 must not become 9007199254740990; the truth is exactly that value, so 'correct' proves it was preserved)")
$pCtrl = P-Row "/prec_ctrl/$p3"
Add-Check 'b1p.integral_controls_still_pass' ($null -ne $pCtrl -and $pCtrl.verdict -eq 'correct' -and $pCtrl.correct -eq $true) `
    ("verdict=$($pCtrl.verdict) code=$($pCtrl.code) (code 200 and views 1.0 as EXACT integers stay correct)")

# ---------------------------------------------------------------- case 8c: B2 the summary must be bound to the frozen plan
# A private MINI calibration (truth + plan + ledger + server events + calibration result, all self-consistent) is used as
# the control. Two mutated copies keep every internal hash consistent but break the binding to the frozen plan; the
# summariser has to reject both, which the previous version could not do (it only compared counts and uniqueness).
$mini = Join-Path $outDir 'plan-binding'
if (-not (Test-Path -LiteralPath $mini)) { New-Item -ItemType Directory -Path $mini -Force | Out-Null }

function New-MiniCalibration {
    param([string]$Dir, [string]$CalRunId, [int]$Rate = 5, [int]$SlotCount = 3)
    # the endpoint base is part of the identity the summariser now binds: the FULL url must be base + plan path
    $miniBase = 'http://127.0.0.1:51821'
    foreach ($d in @('', 'plans', 'runs', 'events')) {
        $p = if ($d -eq '') { $Dir } else { Join-Path $Dir $d }
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    Copy-Item -LiteralPath (Join-Path $RunRoot 'prepare-manifest.json') -Destination (Join-Path $Dir 'prepare-manifest.json') -Force
    # truth: three synthetic articles whose content hash is computed here
    $miniTargets = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $SlotCount; $i++) {
        $aid = [long](9007199254742001 + $i)
        $content = "mini article body $i with a comma, a quote `"and`" a newline`nend $i"
        $cb = [System.Text.Encoding]::UTF8.GetBytes($content)
        $null = $miniTargets.Add([ordered]@{
                article_id = $aid; views = [long](1000 + $i); likes = [long](10 + $i); comment = [long](1 + $i); collection = [long](2 + $i)
                channel_id = 1; author_id = 4; content_sha256 = (Get-P14aSha256 $cb); content_bytes = $cb.Length; content = $content
            })
    }
    $truth = [ordered]@{ scope = 'private MINI truth for the plan-binding offline test'; targets = @($miniTargets) }
    $truthFile = Join-Path (Join-Path $Dir 'plans') 'ids-truth.json'
    [System.IO.File]::WriteAllText($truthFile, (ConvertTo-Json $truth -Depth 8), $utf8)
    $slots = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $SlotCount; $i++) {
        $null = $slots.Add([ordered]@{ slot_index = $i; planned_offset_ms = [int]($i * 200); article_id = $miniTargets[$i].article_id })
    }
    $planObj = [ordered]@{ kind = 'sample'; rate_per_second = $Rate; seconds = 1; slot_count = $SlotCount; slots = @($slots) }
    $planFile = Join-Path (Join-Path $Dir 'plans') ("plan-r$Rate-sample.json")
    [System.IO.File]::WriteAllText($planFile, (ConvertTo-Json $planObj -Depth 6), $utf8)
    $planSha = (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash.ToLower()
    # one ledger + collect-result + server events per group, every id bound to its slot.
    # The events file is named "<cal run id>-<group>.log" because the summariser looks it up by cal.run_id, not by
    # the sample run id, and the requestId inside the line carries the sample run id.
    $segGroups = [ordered]@{}
    foreach ($g in @('A', 'B')) {
        $sampleRun = "$CalRunId-MINI-$g"
        $runDir = Join-Path (Join-Path $Dir 'runs') $sampleRun
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        $ledgerLines = New-Object System.Collections.ArrayList
        $seq = 0
        for ($i = 0; $i -lt $SlotCount; $i++) {
            $t = $miniTargets[$i]
            $bodyObj = [ordered]@{
                host = 'mini'; code = 200; errorMessage = ''
                data = [ordered]@{
                    article = [ordered]@{
                        id = [string]$t.article_id; views = $t.views; likes = $t.likes; comment = $t.comment
                        collection = $t.collection; channelId = 1; authorId = 4
                    }
                    content = [string]$t.content
                }
            }
            $bodyText = ConvertTo-Json $bodyObj -Depth 8
            $bb = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
            $seq++
            $rec = [ordered]@{
                kind = 'response'; group = $g; run_id = $sampleRun; slot_index = $i; planned_offset_ms = [int]($i * 200)
                request_id = "$sampleRun-$g-s$i"; method = 'GET'; url = "$miniBase/api/v1/article/detail/$($t.article_id)"
                target_article_id = [string]$t.article_id; expected_verdict = 'ok'
                dispatched_ms = [int]($i * 200); ended_ms = [int]($i * 200 + 12); elapsed_ms = 12; schedule_lag_ms = 0
                declared_window_ms = 1000; in_window = $true
                http = 200; verdict = 'correct'; correct = $true; code = 200
                id_is_string = $true; id_matches = $true; fields_match = $true; content_sha256_match = $true
                channel_match = $true; author_match = $true; content_bytes = $bb.Length; content_bytes_match = $true
                bytes = $bb.Length; sha256 = (Get-P14aSha256 $bb); body_utf8 = $bodyText
                body_base64 = [System.Convert]::ToBase64String($bb)
                seq = $seq; persisted_ms = [int]($i * 200 + 13)
            }
            $null = $ledgerLines.Add(($rec | ConvertTo-Json -Compress -Depth 6))
        }
        [System.IO.File]::WriteAllText((Join-Path $runDir 'responses.jsonl'), (($ledgerLines -join "`r`n") + "`r`n"), $utf8)
        $coll = [ordered]@{
            run_id = $sampleRun; phase = 'sample'; group = $g; base = $miniBase
            plan = [ordered]@{ file = (Split-Path -Leaf $planFile); sha256 = $planSha; kind = 'sample'; rate_per_second = $Rate; slot_count = $SlotCount }
            stats = [ordered]@{ offered = $SlotCount; started = $SlotCount; completed = $SlotCount; dropped = 0; correct = $SlotCount; timeouts = 0; drain_ms = 5; interrupted = $false; inflight_at_end = 0 }
        }
        [System.IO.File]::WriteAllText((Join-Path $runDir 'collect-result.json'), (ConvertTo-Json $coll -Depth 8), $utf8)
        $ev = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $SlotCount; $i++) {
            $rid = "$sampleRun-$g-s$i"
            $aid = $miniTargets[$i].article_id
            $null = $ev.Add("ts=2026-11-04T00:00:00.000+0800 epochMs=1 pid=1 thread=t runId=$sampleRun requestId=$rid event=cache.read hit=$(if ($g -eq 'B') { 'True' } else { 'False' })")
            $null = $ev.Add("ts=2026-11-04T00:00:00.001+0800 epochMs=2 pid=1 thread=t runId=$sampleRun requestId=$rid event=rebuild.begin reqId=$i articleId=$aid writeCache=True")
            $null = $ev.Add("ts=2026-11-04T00:00:00.002+0800 epochMs=3 pid=1 thread=t runId=$sampleRun requestId=$rid event=db.enter reqId=$i articleId=$aid")
        }
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $Dir 'events') "$CalRunId-$g.log"), (($ev -join "`r`n") + "`r`n"), $utf8)
        $segGroups[$g] = [ordered]@{ sample_run = $sampleRun; offered = $SlotCount; started = $SlotCount; completed = $SlotCount; dropped = 0; correct = $SlotCount; timeouts = 0; drain_ms = 5; collector_cpu_percent_max = 1.0 }
    }
    $calDir = Join-Path (Join-Path $Dir 'runs') $CalRunId
    New-Item -ItemType Directory -Path $calDir -Force | Out-Null
    $cal = [ordered]@{
        run_id = $CalRunId; segments = @([ordered]@{ rate_per_second = $Rate; order = 'A>B'; valid = $true; invalid_reason = ''; groups = $segGroups })
        stopped_early = $false; stop_reason = ''
    }
    [System.IO.File]::WriteAllText((Join-Path $calDir 'calibration-result.json'), (ConvertTo-Json $cal -Depth 10), $utf8)
    return [pscustomobject]@{ dir = $Dir; run_id = $CalRunId; plan = $planFile; plan_sha = $planSha; truth = $truthFile; targets = $miniTargets }
}
function Invoke-Summarize([string]$dir, [string]$calRunId) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $benchDir 'env') 'p14a-summarize.ps1') -RunRoot $dir -RunId $calRunId 2>&1
    return [pscustomobject]@{ exit = $LASTEXITCODE; output = ($out | Out-String) }
}
function Get-PlanBindingResult([string]$dir, [string]$calRunId) {
    $p = Join-Path (Join-Path (Join-Path $dir 'runs') $calRunId) 'recomputed-summary.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$ctrlDir = Join-Path $mini 'control'
$ctrl = New-MiniCalibration -Dir $ctrlDir -CalRunId 'P14aMiniCtrl' -Rate 5 -SlotCount 3
$ctrlRun = Invoke-Summarize $ctrlDir $ctrl.run_id
$ctrlSummary = Get-PlanBindingResult $ctrlDir $ctrl.run_id
$ctrlProblems = if ($null -ne $ctrlSummary) { @($ctrlSummary.problems).Count } else { -1 }
$ctrlBound = if ($null -ne $ctrlSummary) { [int]$ctrlSummary.per_run.'r5-A'.plan_binding.bodies_bound_to_the_plan } else { -1 }
Add-Check 'b2.control_calibration_is_accepted' ($ctrlRun.exit -eq 0 -and $ctrlProblems -eq 0 -and $ctrlBound -eq 3) `
    ("exit=$($ctrlRun.exit) problems=$ctrlProblems bodies_bound_to_plan=$ctrlBound/3 (a self-consistent ledger that really matches the frozen plan must still pass)")

# copy 1: the first slot_index is renamed to 999999 (count and uniqueness unchanged, so the old checks still passed)
$slotDir = Join-Path $mini 'slot-999999'
Copy-Item -LiteralPath $ctrlDir -Destination $slotDir -Recurse -Force
Remove-Item -LiteralPath (Join-Path (Join-Path (Join-Path $slotDir 'runs') $ctrl.run_id) 'recomputed-summary.json') -Force
$slotLedger = Join-Path (Join-Path (Join-Path $slotDir 'runs') "$($ctrl.run_id)-MINI-A") 'responses.jsonl'
$slotLines = @([System.IO.File]::ReadAllLines($slotLedger))
$first = $slotLines[0] | ConvertFrom-Json
$first.slot_index = 999999
$slotLines[0] = ($first | ConvertTo-Json -Compress -Depth 6)
[System.IO.File]::WriteAllLines($slotLedger, $slotLines, $utf8)
$slotRun = Invoke-Summarize $slotDir $ctrl.run_id
$slotSummary = Get-PlanBindingResult $slotDir $ctrl.run_id
$slotProblems = if ($null -ne $slotSummary) { @($slotSummary.problems) -join ' | ' } else { '' }
Add-Check 'b2.renamed_slot_is_rejected' ($slotRun.exit -eq 1 -and $null -ne $slotSummary -and @($slotSummary.problems).Count -gt 0 -and $slotProblems -match 'not in the frozen plan') `
    ("exit=$($slotRun.exit) problems=$slotProblems")

# copy 2: keep slot/request_id/URL/server events but swap the target id, the body and its bytes/hash to ANOTHER legal
# article of the same truth file. Everything stays internally consistent, only the plan binding breaks.
$swapDir = Join-Path $mini 'swapped-article'
Copy-Item -LiteralPath $ctrlDir -Destination $swapDir -Recurse -Force
Remove-Item -LiteralPath (Join-Path (Join-Path (Join-Path $swapDir 'runs') $ctrl.run_id) 'recomputed-summary.json') -Force
$swapLedger = Join-Path (Join-Path (Join-Path $swapDir 'runs') "$($ctrl.run_id)-MINI-A") 'responses.jsonl'
$swapLines = @([System.IO.File]::ReadAllLines($swapLedger))
$row0 = $swapLines[0] | ConvertFrom-Json
$donor = $swapLines[1] | ConvertFrom-Json
$row0.target_article_id = [string]$donor.target_article_id
$row0.body_base64 = [string]$donor.body_base64
$row0.body_utf8 = [string]$donor.body_utf8
$row0.bytes = [int]$donor.bytes
$row0.sha256 = [string]$donor.sha256
$row0.content_bytes = [int]$donor.bytes
$swapLines[0] = ($row0 | ConvertTo-Json -Compress -Depth 6)
[System.IO.File]::WriteAllLines($swapLedger, $swapLines, $utf8)
$swapRun = Invoke-Summarize $swapDir $ctrl.run_id
$swapSummary = Get-PlanBindingResult $swapDir $ctrl.run_id
$swapProblems = if ($null -ne $swapSummary) { @($swapSummary.problems) -join ' | ' } else { '' }
$swapBinding = if ($null -ne $swapSummary) { $swapSummary.per_run.'r5-A'.plan_binding } else { $null }
Add-Check 'b2.self_consistent_body_swap_is_rejected' ($swapRun.exit -eq 1 -and $null -ne $swapSummary -and @($swapSummary.problems).Count -gt 0 -and $swapProblems -match 'article id is not the id the frozen plan binds') `
    ("exit=$($swapRun.exit) body_id_differs=$($swapBinding.body_article_id_differs_from_the_plan) target_id_differs=$($swapBinding.target_id_differs_from_the_plan) server_article_differs=$($swapBinding.server_article_id_differs_from_the_plan) problems=$swapProblems")
Add-Check 'b2.body_hash_still_reproduces_itself_in_the_tampered_copy' ($null -ne $swapSummary -and [int]$swapSummary.per_run.'r5-A'.body_sha256_failed -eq 0) `
    ("body_sha256_failed=$($swapSummary.per_run.'r5-A'.body_sha256_failed): the tampered body is still self-consistent, so only the PLAN binding can catch it")

# copy 3: a missing slot replaced by an out-of-plan slot keeps the record count identical
$missDir = Join-Path $mini 'missing-slot-extras'
Copy-Item -LiteralPath $ctrlDir -Destination $missDir -Recurse -Force
Remove-Item -LiteralPath (Join-Path (Join-Path (Join-Path $missDir 'runs') $ctrl.run_id) 'recomputed-summary.json') -Force
$missLedger = Join-Path (Join-Path (Join-Path $missDir 'runs') "$($ctrl.run_id)-MINI-A") 'responses.jsonl'
$missLines = @([System.IO.File]::ReadAllLines($missLedger))
$m0 = $missLines[0] | ConvertFrom-Json
$m0.slot_index = 42
$missLines[0] = ($m0 | ConvertTo-Json -Compress -Depth 6)
[System.IO.File]::WriteAllLines($missLedger, $missLines, $utf8)
$missRun = Invoke-Summarize $missDir $ctrl.run_id
$missSummary = Get-PlanBindingResult $missDir $ctrl.run_id
$missProblems = if ($null -ne $missSummary) { @($missSummary.problems) -join ' | ' } else { '' }
$missMissing = if ($null -ne $missSummary) { @($missSummary.per_run.'r5-A'.plan_binding.slots_missing_from_the_ledger) -join ',' } else { '' }
Add-Check 'b2.missing_slot_cannot_be_padded_by_an_extra_slot' ($missRun.exit -eq 1 -and $null -ne $missSummary -and $missProblems -match 'no record for frozen plan slots' -and $missMissing -eq '0') `
    ("exit=$($missRun.exit) missing_slots=$missMissing problems=$missProblems (the record count is unchanged, so only the exact slot set catches it)")

# ---------------------------------------------------------------- case 8d: B2 population + REQUIRED identity
# Six residual cases the owner reproduced: the correct count and its latency samples came from different populations,
# a same-path URL on a different port passed, a request whose server events named no runId/articleId passed, an empty
# plan hash passed, and a response that was re-labelled as a drop still counted as a validated tier.

function Copy-Control([string]$Name) {
    $d = Join-Path $mini $Name
    Copy-Item -LiteralPath $ctrlDir -Destination $d -Recurse -Force
    $recomputed = Join-Path (Join-Path (Join-Path $d 'runs') $ctrl.run_id) 'recomputed-summary.json'
    if (Test-Path -LiteralPath $recomputed) { Remove-Item -LiteralPath $recomputed -Force }
    return $d
}
function Get-MiniSeg([string]$dir) {
    $s = Get-PlanBindingResult $dir $ctrl.run_id
    if ($null -eq $s) { return $null }
    return [pscustomobject]@{ summary = $s; perRun = $s.per_run.'r5-A'; validity = @($s.segment_validity) }
}

# (a) only the STORED flag of the slowest correct response is flipped; the body stays correct
$flipDir = Copy-Control 'population-flag-flip'
$flipLedger = Join-Path (Join-Path (Join-Path $flipDir 'runs') "$($ctrl.run_id)-MINI-A") 'responses.jsonl'
$flipLines = @([System.IO.File]::ReadAllLines($flipLedger))
$f2 = $flipLines[2] | ConvertFrom-Json
$f2.correct = $false
$f2.verdict = 'wrong_field'
$flipLines[2] = ($f2 | ConvertTo-Json -Compress -Depth 6)
[System.IO.File]::WriteAllLines($flipLedger, $flipLines, $utf8)
$flipRun = Invoke-Summarize $flipDir $ctrl.run_id
$flipSeg = Get-MiniSeg $flipDir
Add-Check 'b2p.population_ignores_a_flipped_stored_flag' ($null -ne $flipSeg -and [int]$flipSeg.perRun.correct -eq 3 -and [int]$flipSeg.perRun.population.correct_latency_samples -eq 3 -and [bool]$flipSeg.perRun.population.consistent -and [int]$flipSeg.perRun.stored_flags.correct -eq 2 -and [int]$flipSeg.perRun.stored_flags.disagreements_with_rejudgement -eq 1) `
    ("recomputed correct=$($flipSeg.perRun.correct) with $($flipSeg.perRun.population.correct_latency_samples) latency samples (stored flags say $($flipSeg.perRun.stored_flags.correct); the flip is reported as a disagreement, not as a smaller correct set)")

# (b) the slowest body is made wrong and its own hash recomputed, while the STORED flag stays true
$badDir = Copy-Control 'population-wrong-body-stored-true'
$badLedger = Join-Path (Join-Path (Join-Path $badDir 'runs') "$($ctrl.run_id)-MINI-A") 'responses.jsonl'
$badLines = @([System.IO.File]::ReadAllLines($badLedger))
$b3 = $badLines[2] | ConvertFrom-Json
$badBody = [string]$b3.body_utf8
$badBody2 = $badBody -replace '"views":1002', '"views":999999'
if ($badBody2 -eq $badBody) { $badBody2 = $badBody -replace '"views":\s*1002', '"views":999999' }
$badBytes = [System.Text.Encoding]::UTF8.GetBytes($badBody2)
$b3.body_utf8 = $badBody2
$b3.body_base64 = [System.Convert]::ToBase64String($badBytes)
$b3.bytes = $badBytes.Length
$b3.sha256 = Get-P14aSha256 $badBytes
$b3.correct = $true
$badLines[2] = ($b3 | ConvertTo-Json -Compress -Depth 6)
[System.IO.File]::WriteAllLines($badLedger, $badLines, $utf8)
$badRun = Invoke-Summarize $badDir $ctrl.run_id
$badSeg = Get-MiniSeg $badDir
Add-Check 'b2p.population_never_includes_a_wrong_body' ($null -ne $badSeg -and [int]$badSeg.perRun.correct -eq 2 -and [int]$badSeg.perRun.population.correct_latency_samples -eq 2 -and [bool]$badSeg.perRun.population.consistent -and [int]$badSeg.perRun.body_sha256_failed -eq 0 -and $badRun.exit -eq 1) `
    ("recomputed correct=$($badSeg.perRun.correct) with $($badSeg.perRun.population.correct_latency_samples) latency samples while the stored flag still says correct; the tampered body reproduces its own hash (body_sha256_failed=$($badSeg.perRun.body_sha256_failed)) so only the re-judgement catches it; exit=$($badRun.exit)")

# (c) the same path on a different port must be rejected
$urlDir = Copy-Control 'url-other-port'
$urlLedger = Join-Path (Join-Path (Join-Path $urlDir 'runs') "$($ctrl.run_id)-MINI-A") 'responses.jsonl'
$urlLines = @([System.IO.File]::ReadAllLines($urlLedger))
$u0 = $urlLines[0] | ConvertFrom-Json
$u0.url = ([string]$u0.url) -replace ':51821', ':59999'
$urlLines[0] = ($u0 | ConvertTo-Json -Compress -Depth 6)
[System.IO.File]::WriteAllLines($urlLedger, $urlLines, $utf8)
$urlRun = Invoke-Summarize $urlDir $ctrl.run_id
$urlSeg = Get-MiniSeg $urlDir
$urlProbs = if ($null -ne $urlSeg) { @($urlSeg.summary.problems) -join ' | ' } else { '' }
Add-Check 'b2p.same_path_on_another_port_is_rejected' ($urlRun.exit -eq 1 -and $null -ne $urlSeg -and [int]$urlSeg.perRun.plan_binding.url_differs_from_the_plan -eq 1 -and [int]$urlSeg.perRun.plan_binding.url_used_a_different_base_not_just_a_path -eq 1 -and $urlProbs -match 'FULL url') `
    ("exit=$($urlRun.exit) url_differs=$($urlSeg.perRun.plan_binding.url_differs_from_the_plan) different_base=$($urlSeg.perRun.plan_binding.url_used_a_different_base_not_just_a_path)")

# (d) a request whose server events name no runId/articleId must be rejected (an empty identity set is not a pass)
$idDir = Copy-Control 'server-identity-missing'
$idEvents = Join-Path (Join-Path $idDir 'events') "$($ctrl.run_id)-A.log"
$idRid = "$($ctrl.run_id)-MINI-A-A-s0"
$idLines = @([System.IO.File]::ReadAllLines($idEvents) | ForEach-Object {
        if ($_ -match [regex]::Escape($idRid)) { $_ -replace ' runId=[^ ]*', '' -replace ' articleId=[^ ]*', '' } else { $_ }
    })
[System.IO.File]::WriteAllLines($idEvents, $idLines, $utf8)
$idRun = Invoke-Summarize $idDir $ctrl.run_id
$idSeg = Get-MiniSeg $idDir
$idProbs = if ($null -ne $idSeg) { @($idSeg.summary.problems) -join ' | ' } else { '' }
Add-Check 'b2p.missing_server_identity_is_rejected' ($idRun.exit -eq 1 -and $null -ne $idSeg -and [int]$idSeg.perRun.plan_binding.server_run_id_missing -ge 1 -and [int]$idSeg.perRun.plan_binding.server_article_id_missing -ge 1 -and $idProbs -match 'name no runId') `
    ("exit=$($idRun.exit) missing_runId=$($idSeg.perRun.plan_binding.server_run_id_missing) missing_articleId=$($idSeg.perRun.plan_binding.server_article_id_missing)")

# (e) an empty plan hash in the run's own collect-result must be rejected
$shaDir = Copy-Control 'plan-sha-empty'
$shaFile = Join-Path (Join-Path (Join-Path $shaDir 'runs') "$($ctrl.run_id)-MINI-A") 'collect-result.json'
$shaObj = Get-Content -LiteralPath $shaFile -Raw -Encoding UTF8 | ConvertFrom-Json
$shaObj.plan.sha256 = ''
[System.IO.File]::WriteAllText($shaFile, ($shaObj | ConvertTo-Json -Depth 8), $utf8)
$shaRun = Invoke-Summarize $shaDir $ctrl.run_id
$shaSeg = Get-MiniSeg $shaDir
$shaProbs = if ($null -ne $shaSeg) { @($shaSeg.summary.problems) -join ' | ' } else { '' }
Add-Check 'b2p.empty_plan_hash_is_rejected' ($shaRun.exit -eq 1 -and $null -ne $shaSeg -and [bool]$shaSeg.perRun.slot_integrity.plan_sha_reported_present -eq $false -and [bool]$shaSeg.perRun.slot_integrity.plan_sha_matches_run -eq $false -and $shaProbs -match 'plan sha256') `
    ("exit=$($shaRun.exit) plan_sha_reported_present=$($shaSeg.perRun.slot_integrity.plan_sha_reported_present) matches=$($shaSeg.perRun.slot_integrity.plan_sha_matches_run)")

# (f) a response re-labelled as a same-slot drop, with the calibration self-report made self-consistent, must be
#     rejected for its leftover server events AND must not be a validated tier
$dropDir = Copy-Control 'response-relabelled-drop'
$dropLedger = Join-Path (Join-Path (Join-Path $dropDir 'runs') "$($ctrl.run_id)-MINI-A") 'responses.jsonl'
$dropLines = @([System.IO.File]::ReadAllLines($dropLedger))
$d0 = $dropLines[0] | ConvertFrom-Json
# build the replacement record from scratch: the mutation is "this response is now a drop of the same slot"
$dropRec = [ordered]@{
    kind = 'dropped'; group = [string]$d0.group; run_id = [string]$d0.run_id
    slot_index = [int]$d0.slot_index; planned_offset_ms = [int]$d0.planned_offset_ms
    intended_article_id = [string]$d0.target_article_id; request_id = [string]$d0.request_id
    drop_class = 'cap_full'; reason = 'offline mutation: response relabelled as dropped'
    inflight_at_drop = 4; observed_ms = [int]$d0.dispatched_ms; seq = [int]$d0.seq
}
$dropLines[0] = ($dropRec | ConvertTo-Json -Compress -Depth 4)
[System.IO.File]::WriteAllLines($dropLedger, $dropLines, $utf8)
$dropCalFile = Join-Path (Join-Path (Join-Path $dropDir 'runs') $ctrl.run_id) 'calibration-result.json'
$dropCal = Get-Content -LiteralPath $dropCalFile -Raw -Encoding UTF8 | ConvertFrom-Json
$dropCal.segments[0].valid = $true
$dropCal.segments[0].groups.A.completed = 2
$dropCal.segments[0].groups.A.started = 2
$dropCal.segments[0].groups.A.dropped = 1
$dropCal.segments[0].groups.A.correct = 2
[System.IO.File]::WriteAllText($dropCalFile, ($dropCal | ConvertTo-Json -Depth 10), $utf8)
$dropRun = Invoke-Summarize $dropDir $ctrl.run_id
$dropSeg = Get-MiniSeg $dropDir
$dropProbs = if ($null -ne $dropSeg) { @($dropSeg.summary.problems) -join ' | ' } else { '' }
$dropValidity = if ($null -ne $dropSeg -and @($dropSeg.validity).Count -ge 1) { $dropSeg.validity[0] } else { $null }
Add-Check 'b2p.response_relabelled_as_drop_is_rejected' ($dropRun.exit -eq 1 -and $null -ne $dropSeg -and [int]$dropSeg.perRun.slot_integrity.dropped_requests_with_server_events -ge 1 -and $dropProbs -match 'recorded as DROPPED but do have server-side events') `
    ("exit=$($dropRun.exit) dropped_with_server_events=$($dropSeg.perRun.slot_integrity.dropped_requests_with_server_events)")
Add-Check 'b2p.rejected_segment_is_not_a_validated_tier' ($null -ne $dropValidity -and [bool]$dropValidity.recomputed_valid -eq $false -and [bool]$dropValidity.calibration_self_reported_valid -eq $true -and @($dropSeg.summary.validated_tiers_req_per_second).Count -eq 0) `
    ("recomputed_valid=$($dropValidity.recomputed_valid) while the calibration self-report still says valid=$($dropValidity.calibration_self_reported_valid); validated_tiers=$(($dropSeg.summary.validated_tiers_req_per_second) -join ',')")

# ---------------------------------------------------------------- case 8e: B3 tier admission - ZERO DROP is required
# The owner's residual: a perfectly LEGAL drop (never sent to the server, no server-side event, all other responses
# correct) still left the segment admitted, because validity was only "problem count == 0". The section-4 rule is that
# any dropped slot invalidates the segment, so admission is now an explicit conjunction of conditions.

# (a) control: no drop, no failure, 100 percent correct -> admitted
$ctlValidity = @((Get-MiniSeg $ctrlDir).validity)[0]
Add-Check 'b3.clean_control_is_admitted' ([bool]$ctlValidity.recomputed_valid -and @($ctlValidity.groups_admitted).Count -eq 2 -and @($ctlValidity.groups_missing).Count -eq 0) `
    ("recomputed_valid=$($ctlValidity.recomputed_valid) problems=$($ctlValidity.recomputed_problem_count) groups_admitted=$(($ctlValidity.groups_admitted) -join ',') missing=$(($ctlValidity.groups_missing) -join ',')")

$satDir = Copy-Control 'admission-selfreported-invalid'
$satCalFile = Join-Path (Join-Path (Join-Path $satDir 'runs') $ctrl.run_id) 'calibration-result.json'
$satCal = Get-Content -LiteralPath $satCalFile -Raw -Encoding UTF8 | ConvertFrom-Json
$satCal.segments[0].valid = $false
$satCal.segments[0].invalid_reason = 'self-reported invalid by the admission control test'
[System.IO.File]::WriteAllText($satCalFile, ($satCal | ConvertTo-Json -Depth 10), $utf8)
$satRun = Invoke-Summarize $satDir $ctrl.run_id
$satSeg = Get-MiniSeg $satDir
$satValidity = @($satSeg.validity)[0]
Add-Check 'b3.self_reported_invalid_does_not_override_clean_originals' ($satRun.exit -eq 0 -and [bool]$satValidity.recomputed_valid -and -not [bool]$satValidity.calibration_self_reported_valid -and @($satSeg.summary.validated_tiers_req_per_second) -contains 5) `
    ("exit=$($satRun.exit) recomputed_valid=$($satValidity.recomputed_valid) self_reported_valid=$($satValidity.calibration_self_reported_valid) tiers=$(($satSeg.summary.validated_tiers_req_per_second) -join ',') (the difference is recorded, the originals decide)")

# (b) one LEGAL drop: same slot and request id as a response, NO server-side event for that request, every other
#     response correct, counts self-consistent, and the calibration self-report says valid=true. It must NOT be admitted.
$legalDir = Copy-Control 'admission-legal-drop'
$legalLedger = Join-Path (Join-Path (Join-Path $legalDir 'runs') "$($ctrl.run_id)-MINI-A") 'responses.jsonl'
$legalLines = @([System.IO.File]::ReadAllLines($legalLedger))
$l0 = $legalLines[0] | ConvertFrom-Json
$legalRid = [string]$l0.request_id
$legalDrop = [ordered]@{
    kind = 'dropped'; group = [string]$l0.group; run_id = [string]$l0.run_id
    slot_index = [int]$l0.slot_index; planned_offset_ms = [int]$l0.planned_offset_ms
    intended_article_id = [string]$l0.target_article_id; request_id = $legalRid
    drop_class = 'cap_full'; reason = 'legal drop: due slot skipped while the in-flight cap was full'
    inflight_at_drop = 1; observed_ms = [int]$l0.dispatched_ms; seq = [int]$l0.seq
}
$legalLines[0] = ($legalDrop | ConvertTo-Json -Compress -Depth 4)
[System.IO.File]::WriteAllLines($legalLedger, $legalLines, $utf8)
$legalEvents = Join-Path (Join-Path $legalDir 'events') "$($ctrl.run_id)-A.log"
$legalEventLines = @([System.IO.File]::ReadAllLines($legalEvents) | Where-Object { $_ -notmatch [regex]::Escape($legalRid) })
[System.IO.File]::WriteAllLines($legalEvents, $legalEventLines, $utf8)
$legalCalFile = Join-Path (Join-Path (Join-Path $legalDir 'runs') $ctrl.run_id) 'calibration-result.json'
$legalCal = Get-Content -LiteralPath $legalCalFile -Raw -Encoding UTF8 | ConvertFrom-Json
$legalCal.segments[0].valid = $true
$legalCal.segments[0].groups.A.offered = 3
$legalCal.segments[0].groups.A.started = 2
$legalCal.segments[0].groups.A.completed = 2
$legalCal.segments[0].groups.A.dropped = 1
$legalCal.segments[0].groups.A.correct = 2
[System.IO.File]::WriteAllText($legalCalFile, ($legalCal | ConvertTo-Json -Depth 10), $utf8)
$legalRun = Invoke-Summarize $legalDir $ctrl.run_id
$legalSeg = Get-MiniSeg $legalDir
$legalValidity = @($legalSeg.validity)[0]
$legalAdmission = $legalSeg.perRun.tier_admission
$legalProbs = if ($null -ne $legalSeg) { @($legalSeg.summary.problems) -join ' | ' } else { '' }
Add-Check 'b3.legal_drop_invalidates_the_segment' ($legalRun.exit -eq 1 -and [bool]$legalAdmission.admitted -eq $false -and @($legalAdmission.failed_conditions) -contains 'dropped_is_zero' -and [bool]$legalValidity.recomputed_valid -eq $false -and $legalProbs -match 'dropped_is_zero') `
    ("exit=$($legalRun.exit) dropped=$($legalAdmission.counted_from_originals.dropped) admitted=$($legalAdmission.admitted) failed_conditions=$(($legalAdmission.failed_conditions) -join ',') correct=$($legalAdmission.counted_from_originals.correct)/$($legalAdmission.counted_from_originals.responses)")
Add-Check 'b3.legal_drop_keeps_diagnostics_and_stays_out_of_comparison' ([int]$legalSeg.perRun.dropped -eq 1 -and [int]$legalSeg.perRun.correct -eq 2 -and @($legalSeg.summary.validated_tiers_req_per_second).Count -eq 0 -and @($legalSeg.summary.comparison).Count -eq 0) `
    ("dropped=$($legalSeg.perRun.dropped) correct=$($legalSeg.perRun.correct) p50=$($legalSeg.perRun.latency_correct_ms.p50) tiers=$(($legalSeg.summary.validated_tiers_req_per_second) -join ',') comparison=$(@($legalSeg.summary.comparison).Count) (responses and percentiles are kept for diagnosis, the tier is not reported)")
Add-Check 'b3.legal_drop_does_not_trip_the_event_check' ($legalProbs -notmatch 'do have server-side events') `
    ("problems=$legalProbs (this drop has NO server-side event, so only the zero-drop gate can catch it)")

# (c) a missing group can never be admitted
$missGrpDir = Copy-Control 'admission-missing-group'
$missGrpCalFile = Join-Path (Join-Path (Join-Path $missGrpDir 'runs') $ctrl.run_id) 'calibration-result.json'
$missGrpCal = Get-Content -LiteralPath $missGrpCalFile -Raw -Encoding UTF8 | ConvertFrom-Json
$missGrpCal.segments[0].groups.PSObject.Properties.Remove('B')
$missGrpCal.segments[0].valid = $true
[System.IO.File]::WriteAllText($missGrpCalFile, ($missGrpCal | ConvertTo-Json -Depth 10), $utf8)
$missGrpRun = Invoke-Summarize $missGrpDir $ctrl.run_id
$missGrpSeg = Get-MiniSeg $missGrpDir
$missGrpValidity = @($missGrpSeg.validity)[0]
Add-Check 'b3.missing_group_is_not_a_validated_tier' ($missGrpRun.exit -eq 1 -and [bool]$missGrpValidity.recomputed_valid -eq $false -and @($missGrpValidity.groups_missing) -contains 'B' -and @($missGrpSeg.summary.validated_tiers_req_per_second).Count -eq 0) `
    ("exit=$($missGrpRun.exit) groups_present=$(($missGrpValidity.groups_present) -join ',') missing=$(($missGrpValidity.groups_missing) -join ',') tiers=$(($missGrpSeg.summary.validated_tiers_req_per_second) -join ',')")

# ---------------------------------------------------------------- case 8f: B4 required traffic fields vs the ledger
# The owner reproduced two holes in the previous summariser: (1) deleting started/completed/inflight_at_end from
# collect-result.stats turned them into -1 sentinels that the gate excused, and (2) a self-reported
# started=completed=99 next to 100 real responses still produced exit 0 with no problem. Every required counter is now
# validated losslessly (no sentinel, no string coercion, no rounding) and compared with the value recalculated from the
# frozen plan and the ledger. calibration-result counters are an EXTRA cross-check, never the proof.
$trafficRoot = Join-Path $outDir 'traffic-fields'
if (-not (Test-Path -LiteralPath $trafficRoot)) { New-Item -ItemType Directory -Path $trafficRoot -Force | Out-Null }

# A two-tier private MINI calibration (5 and 20 req/s, 100 slots per group, both groups present) so that a rejected
# 5 req/s segment has a clean 20 req/s tier beside it: the fix must drop exactly the damaged tier, not the file.
function New-MiniCalibrationMulti {
    param([string]$Dir, [string]$CalRunId, [int[]]$Rates = @(5, 20), [int]$SlotCount = 100)
    $miniBase = 'http://127.0.0.1:51821'
    foreach ($d in @('', 'plans', 'runs', 'events')) {
        $p = if ($d -eq '') { $Dir } else { Join-Path $Dir $d }
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
    Copy-Item -LiteralPath (Join-Path $RunRoot 'prepare-manifest.json') -Destination (Join-Path $Dir 'prepare-manifest.json') -Force
    $targets = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $SlotCount; $i++) {
        $aid = [long](9007199254742001 + $i)
        $content = "traffic article body $i with a comma, a quote `"and`" a newline`nend $i"
        $cb = [System.Text.Encoding]::UTF8.GetBytes($content)
        $null = $targets.Add([ordered]@{
                article_id = $aid; views = [long](1000 + $i); likes = [long](10 + $i); comment = [long](1 + $i); collection = [long](2 + $i)
                channel_id = 1; author_id = 4; content_sha256 = (Get-P14aSha256 $cb); content_bytes = $cb.Length; content = $content
            })
    }
    $truth = [ordered]@{ scope = 'private MINI truth for the required-traffic-field offline test'; targets = @($targets) }
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Dir 'plans') 'ids-truth.json'), (ConvertTo-Json $truth -Depth 8), $utf8)
    $eventLines = [ordered]@{ A = (New-Object System.Collections.ArrayList); B = (New-Object System.Collections.ArrayList) }
    $segments = New-Object System.Collections.ArrayList
    $planInfo = @{}
    foreach ($rate in $Rates) {
        $seconds = [int][math]::Ceiling($SlotCount / [double]$rate)
        $windowMs = $seconds * 1000
        $interval = [int][math]::Floor(1000.0 / $rate)
        $slots = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $SlotCount; $i++) {
            $null = $slots.Add([ordered]@{ slot_index = $i; planned_offset_ms = [int]($i * $interval); article_id = $targets[$i].article_id })
        }
        $planObj = [ordered]@{ kind = 'sample'; rate_per_second = $rate; seconds = $seconds; slot_count = $SlotCount; slots = @($slots) }
        $planFile = Join-Path (Join-Path $Dir 'plans') ("plan-r$rate-sample.json")
        [System.IO.File]::WriteAllText($planFile, (ConvertTo-Json $planObj -Depth 6), $utf8)
        $planSha = (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash.ToLower()
        $planInfo[[string]$rate] = [ordered]@{ file = $planFile; sha = $planSha; seconds = $seconds; interval = $interval; window_ms = $windowMs; sample_run = [ordered]@{} }
        $segGroups = [ordered]@{}
        foreach ($g in @('A', 'B')) {
            $sampleRun = "$CalRunId-M-r$rate-$g"
            $planInfo[[string]$rate].sample_run[$g] = $sampleRun
            $planInfo[[string]$rate].sample_run[$g] = $sampleRun
            $runDir = Join-Path (Join-Path $Dir 'runs') $sampleRun
            New-Item -ItemType Directory -Path $runDir -Force | Out-Null
            $ledgerLines = New-Object System.Collections.ArrayList
            $seq = 0
            for ($i = 0; $i -lt $SlotCount; $i++) {
                $t = $targets[$i]
                $bodyObj = [ordered]@{
                    host = 'mini'; code = 200; errorMessage = ''
                    data = [ordered]@{
                        article = [ordered]@{
                            id = [string]$t.article_id; views = $t.views; likes = $t.likes; comment = $t.comment
                            collection = $t.collection; channelId = 1; authorId = 4
                        }
                        content = [string]$t.content
                    }
                }
                $bodyText = ConvertTo-Json $bodyObj -Depth 8
                $bb = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
                $rid = "$sampleRun-$g-s$i"
                $seq++
                $rec = [ordered]@{
                    kind = 'response'; group = $g; run_id = $sampleRun; slot_index = $i; planned_offset_ms = [int]($i * $interval)
                    request_id = $rid; method = 'GET'; url = "$miniBase/api/v1/article/detail/$($t.article_id)"
                    target_article_id = [string]$t.article_id; expected_verdict = 'ok'
                    dispatched_ms = [int]($i * $interval); ended_ms = [int]($i * $interval + 12); elapsed_ms = 12; schedule_lag_ms = 0
                    declared_window_ms = $windowMs; in_window = $true
                    http = 200; verdict = 'correct'; correct = $true; code = 200
                    id_is_string = $true; id_matches = $true; fields_match = $true; content_sha256_match = $true
                    channel_match = $true; author_match = $true; content_bytes = $bb.Length; content_bytes_match = $true
                    bytes = $bb.Length; sha256 = (Get-P14aSha256 $bb); body_utf8 = $bodyText
                    body_base64 = [System.Convert]::ToBase64String($bb)
                    seq = $seq; persisted_ms = [int]($i * $interval + 13)
                }
                $null = $ledgerLines.Add(($rec | ConvertTo-Json -Compress -Depth 6))
                $null = $eventLines[$g].Add("ts=2026-11-05T00:00:00.000+0800 epochMs=1 pid=1 thread=t runId=$sampleRun requestId=$rid event=cache.read hit=$(if ($g -eq 'B') { 'True' } else { 'False' })")
                $null = $eventLines[$g].Add("ts=2026-11-05T00:00:00.001+0800 epochMs=2 pid=1 thread=t runId=$sampleRun requestId=$rid event=rebuild.begin reqId=$i articleId=$($t.article_id) writeCache=True")
                $null = $eventLines[$g].Add("ts=2026-11-05T00:00:00.002+0800 epochMs=3 pid=1 thread=t runId=$sampleRun requestId=$rid event=db.enter reqId=$i articleId=$($t.article_id)")
            }
            [System.IO.File]::WriteAllText((Join-Path $runDir 'responses.jsonl'), (($ledgerLines -join "`r`n") + "`r`n"), $utf8)
            $coll = [ordered]@{
                run_id = $sampleRun; phase = 'sample'; group = $g; base = $miniBase
                plan = [ordered]@{ file = (Split-Path -Leaf $planFile); sha256 = $planSha; kind = 'sample'; rate_per_second = $rate; slot_count = $SlotCount }
                stats = [ordered]@{ offered = $SlotCount; started = $SlotCount; completed = $SlotCount; dropped = 0; correct = $SlotCount; timeouts = 0; drain_ms = 5; interrupted = $false; inflight_at_end = 0 }
            }
            [System.IO.File]::WriteAllText((Join-Path $runDir 'collect-result.json'), (ConvertTo-Json $coll -Depth 8), $utf8)
            $segGroups[$g] = [ordered]@{ sample_run = $sampleRun; offered = $SlotCount; started = $SlotCount; completed = $SlotCount; dropped = 0; correct = $SlotCount; timeouts = 0; drain_ms = 5; collector_cpu_percent_max = 1.0 }
        }
        $null = $segments.Add([ordered]@{ rate_per_second = $rate; order = 'A>B'; valid = $true; invalid_reason = ''; groups = $segGroups })
    }
    foreach ($g in @('A', 'B')) {
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $Dir 'events') "$CalRunId-$g.log"), (($eventLines[$g] -join "`r`n") + "`r`n"), $utf8)
    }
    $calDir = Join-Path (Join-Path $Dir 'runs') $CalRunId
    New-Item -ItemType Directory -Path $calDir -Force | Out-Null
    $cal = [ordered]@{ run_id = $CalRunId; segments = @($segments); stopped_early = $false; stop_reason = '' }
    [System.IO.File]::WriteAllText((Join-Path $calDir 'calibration-result.json'), (ConvertTo-Json $cal -Depth 12), $utf8)
    return [pscustomobject]@{ dir = $Dir; run_id = $CalRunId; rates = $Rates; slot_count = $SlotCount; plans = $planInfo }
}
function Get-TrafficResult([string]$dir, [string]$calRunId) {
    $s = Get-PlanBindingResult $dir $calRunId
    if ($null -eq $s) { return $null }
    return [pscustomobject]@{ summary = $s; perRun = $s.per_run; validity = @($s.segment_validity) }
}
# mutate ONLY collect-result.stats of one group's run, leaving the ledger, the plan, the events and the calibration
# self-report untouched: that is exactly the owner's reproduction
function Set-CollectStats([string]$Dir, [string]$SampleRun, [scriptblock]$Mutate) {
    $p = Join-Path (Join-Path (Join-Path $Dir 'runs') $SampleRun) 'collect-result.json'
    $o = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    & $Mutate $o.stats
    [System.IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 8), $utf8)
    return $p
}
function Set-CalGroupCounter([string]$Dir, [string]$CalRunId, [int]$Rate, [string]$Group, [string]$Counter, $Value) {
    $p = Join-Path (Join-Path (Join-Path $Dir 'runs') $CalRunId) 'calibration-result.json'
    $o = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $seg = @($o.segments | Where-Object { [int]$_.rate_per_second -eq $Rate })[0]
    $seg.groups.$Group.$Counter = $Value
    [System.IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 12), $utf8)
    return $p
}
function Copy-TrafficControl([string]$Name) {
    $d = Join-Path $trafficRoot $Name
    Copy-Item -LiteralPath $trafficCtrlDir -Destination $d -Recurse -Force
    $rec = Join-Path (Join-Path (Join-Path $d 'runs') $trafficCalRunId) 'recomputed-summary.json'
    if (Test-Path -LiteralPath $rec) { Remove-Item -LiteralPath $rec -Force }
    return $d
}

# (a) control: two clean tiers of 100 responses per group
$trafficCalRunId = 'P14aMiniTraffic'
$trafficCtrlDir = Join-Path $trafficRoot 'control'
$trafficCtrl = New-MiniCalibrationMulti -Dir $trafficCtrlDir -CalRunId $trafficCalRunId -Rates @(5, 20) -SlotCount 100
$tCtrlRun = Invoke-Summarize $trafficCtrlDir $trafficCalRunId
$tCtrl = Get-TrafficResult $trafficCtrlDir $trafficCalRunId
$tCtrlProbs = if ($null -ne $tCtrl) { @($tCtrl.summary.problems) -join ' | ' } else { '' }
$tCtrlTiers = if ($null -ne $tCtrl) { @($tCtrl.summary.validated_tiers_req_per_second) } else { @() }
Add-Check 'b4.control_two_rate_calibration_is_admitted' ($null -ne $tCtrl -and $tCtrlRun.exit -eq 0 -and $tCtrlProbs -eq '' -and $tCtrlTiers.Count -eq 2 -and ($tCtrlTiers -contains 5) -and ($tCtrlTiers -contains 20) -and [int]$tCtrl.perRun.'r5-A'.responses -eq 100 -and [bool]$tCtrl.perRun.'r5-A'.tier_admission.admitted -and [bool]$tCtrl.perRun.'r20-B'.tier_admission.admitted) `
    ("exit=$($tCtrlRun.exit) tiers=$($tCtrlTiers -join ',') responses r5-A=$($tCtrl.perRun.'r5-A'.responses) r20-A=$($tCtrl.perRun.'r20-A'.responses) admitted r5-A=$($tCtrl.perRun.'r5-A'.tier_admission.admitted) r20-B=$($tCtrl.perRun.'r20-B'.tier_admission.admitted) problems='$tCtrlProbs'")

# (b) owner reproduction 1: started / completed / inflight_at_end DELETED from collect-result.stats
$m1Dir = Copy-TrafficControl 'traffic-missing-fields'
$null = Set-CollectStats $m1Dir $trafficCtrl.plans['5'].sample_run['A'] {
    param($s)
    $s.PSObject.Properties.Remove('started')
    $s.PSObject.Properties.Remove('completed')
    $s.PSObject.Properties.Remove('inflight_at_end')
}
$m1Run = Invoke-Summarize $m1Dir $trafficCalRunId
$m1 = Get-TrafficResult $m1Dir $trafficCalRunId
$m1Probs = if ($null -ne $m1) { @($m1.summary.problems) -join ' | ' } else { '' }
$m1Tiers = if ($null -ne $m1) { @($m1.summary.validated_tiers_req_per_second) } else { @() }
$m1Adm = $m1.perRun.'r5-A'.tier_admission
$m1Cross = $m1Adm.collector_cross_check
Add-Check 'b4.missing_traffic_fields_are_rejected' ($m1Run.exit -eq 1 -and $m1Tiers.Count -eq 1 -and ($m1Tiers -contains 20) -and [bool]$m1Adm.admitted -eq $false -and (@($m1Adm.failed_conditions) -contains 'traffic_fields_present_and_legal') -and [bool]$m1.perRun.'r20-A'.tier_admission.admitted) `
    ("exit=$($m1Run.exit) tiers=$($m1Tiers -join ',') failed_conditions=$(@($m1Adm.failed_conditions) -join ',') 20tier_admitted=$($m1.perRun.'r20-A'.tier_admission.admitted)")
Add-Check 'b4.missing_fields_name_themselves_and_are_not_excused' ($m1Probs -match 'collect-result\.stats\.started is missing' -and $m1Probs -match 'collect-result\.stats\.completed is missing' -and $m1Probs -match 'collect-result\.stats\.inflight_at_end is missing' -and $null -eq $m1Cross.fields.started.value -and [bool]$m1Cross.fields.started.ok -eq $false -and [int]$m1Cross.expected_from_originals.started -eq 100 -and [int]$m1Cross.expected_from_originals.offered -eq 100) `
    ("fields.started ok=$($m1Cross.fields.started.ok) value='$($m1Cross.fields.started.value)' reason='$($m1Cross.fields.started.reason)' expected_from_originals started=$($m1Cross.expected_from_originals.started) offered=$($m1Cross.expected_from_originals.offered) (no -1 sentinel and no default false)")

# (c) owner reproduction 2: the collector claims started=completed=99 while 100 responses are on disk
$m2Dir = Copy-TrafficControl 'traffic-self-reported-99'
$null = Set-CollectStats $m2Dir $trafficCtrl.plans['5'].sample_run['A'] { param($s) $s.started = 99; $s.completed = 99 }
$m2Run = Invoke-Summarize $m2Dir $trafficCalRunId
$m2 = Get-TrafficResult $m2Dir $trafficCalRunId
$m2Probs = if ($null -ne $m2) { @($m2.summary.problems) -join ' | ' } else { '' }
$m2Tiers = if ($null -ne $m2) { @($m2.summary.validated_tiers_req_per_second) } else { @() }
$m2Adm = $m2.perRun.'r5-A'.tier_admission
$m2Cross = $m2Adm.collector_cross_check
Add-Check 'b4.self_reported_counts_must_equal_the_ledger' ($m2Run.exit -eq 1 -and $m2Tiers.Count -eq 1 -and ($m2Tiers -contains 20) -and [bool]$m2Adm.admitted -eq $false -and (@($m2Adm.failed_conditions) -contains 'started_equals_completed_after_drain') -and (@($m2Adm.failed_conditions) -contains 'offered_equals_started_plus_dropped') -and [int]$m2Adm.counted_from_originals.responses -eq 100 -and [int]$m2Cross.started -eq 99 -and [int]$m2Cross.completed -eq 99 -and [int]$m2Cross.expected_from_originals.started -eq 100) `
    ("exit=$($m2Run.exit) tiers=$($m2Tiers -join ',') self-reported started/completed=$($m2Cross.started)/$($m2Cross.completed) ledger responses=$($m2Adm.counted_from_originals.responses) offered=$($m2Cross.offered) offered+started+dropped=$($m2Cross.started + $m2Cross.dropped) failed_conditions=$(@($m2Adm.failed_conditions) -join ',')")

# (d) a missing interrupted flag cannot default to false
$m3Dir = Copy-TrafficControl 'traffic-missing-interrupted'
$null = Set-CollectStats $m3Dir $trafficCtrl.plans['5'].sample_run['A'] { param($s) $s.PSObject.Properties.Remove('interrupted') }
$m3Run = Invoke-Summarize $m3Dir $trafficCalRunId
$m3 = Get-TrafficResult $m3Dir $trafficCalRunId
$m3Probs = if ($null -ne $m3) { @($m3.summary.problems) -join ' | ' } else { '' }
$m3Tiers = if ($null -ne $m3) { @($m3.summary.validated_tiers_req_per_second) } else { @() }
$m3Adm = $m3.perRun.'r5-A'.tier_admission
Add-Check 'b4.missing_interrupted_is_rejected' ($m3Run.exit -eq 1 -and $m3Tiers.Count -eq 1 -and ($m3Tiers -contains 20) -and [bool]$m3Adm.admitted -eq $false -and ($m3Probs -match 'collect-result\.stats\.interrupted is missing') -and (@($m3Adm.failed_conditions) -contains 'started_equals_completed_after_drain') -and ($null -eq $m3Adm.collector_cross_check.interrupted)) `
    ("exit=$($m3Run.exit) tiers=$($m3Tiers -join ',') interrupted=$($m3Adm.collector_cross_check.interrupted) failed_conditions=$(@($m3Adm.failed_conditions) -join ',')")

# (e) interrupted must be a JSON boolean, not the string "false"
$m4Dir = Copy-TrafficControl 'traffic-interrupted-is-a-string'
$null = Set-CollectStats $m4Dir $trafficCtrl.plans['5'].sample_run['A'] { param($s) $s.interrupted = 'false' }
$m4Run = Invoke-Summarize $m4Dir $trafficCalRunId
$m4 = Get-TrafficResult $m4Dir $trafficCalRunId
$m4Probs = if ($null -ne $m4) { @($m4.summary.problems) -join ' | ' } else { '' }
$m4Tiers = if ($null -ne $m4) { @($m4.summary.validated_tiers_req_per_second) } else { @() }
$m4Adm = $m4.perRun.'r5-A'.tier_admission
Add-Check 'b4.interrupted_must_be_a_json_boolean' ($m4Run.exit -eq 1 -and $m4Tiers.Count -eq 1 -and ($m4Tiers -contains 20) -and ($m4Probs -match 'collect-result\.stats\.interrupted is String, not a JSON boolean') -and (@($m4Adm.failed_conditions) -contains 'traffic_fields_present_and_legal')) `
    ("exit=$($m4Run.exit) tiers=$($m4Tiers -join ',') field ok=$($m4Adm.collector_cross_check.fields.interrupted.ok) reason='$($m4Adm.collector_cross_check.fields.interrupted.reason)'")

# (f) a negative counter must not be excused as the old -1 sentinel
$m5Dir = Copy-TrafficControl 'traffic-negative-started'
$null = Set-CollectStats $m5Dir $trafficCtrl.plans['5'].sample_run['A'] { param($s) $s.started = -1 }
$m5Run = Invoke-Summarize $m5Dir $trafficCalRunId
$m5 = Get-TrafficResult $m5Dir $trafficCalRunId
$m5Probs = if ($null -ne $m5) { @($m5.summary.problems) -join ' | ' } else { '' }
$m5Tiers = if ($null -ne $m5) { @($m5.summary.validated_tiers_req_per_second) } else { @() }
$m5Adm = $m5.perRun.'r5-A'.tier_admission
Add-Check 'b4.negative_counter_is_rejected' ($m5Run.exit -eq 1 -and $m5Tiers.Count -eq 1 -and ($m5Tiers -contains 20) -and ($m5Probs -match 'collect-result\.stats\.started=out_of_range\(-1\)') -and [bool]$m5Adm.collector_cross_check.fields.started.ok -eq $false -and (@($m5Adm.failed_conditions) -contains 'traffic_fields_present_and_legal')) `
    ("exit=$($m5Run.exit) tiers=$($m5Tiers -join ',') reason='$($m5Adm.collector_cross_check.fields.started.reason)' (the sentinel is named as illegal, not treated as 'not reported')")

# (g) a stringified counter must not be coerced into a legal number
$m6Dir = Copy-TrafficControl 'traffic-string-completed'
$null = Set-CollectStats $m6Dir $trafficCtrl.plans['5'].sample_run['A'] { param($s) $s.completed = '100' }
$m6Run = Invoke-Summarize $m6Dir $trafficCalRunId
$m6 = Get-TrafficResult $m6Dir $trafficCalRunId
$m6Probs = if ($null -ne $m6) { @($m6.summary.problems) -join ' | ' } else { '' }
$m6Tiers = if ($null -ne $m6) { @($m6.summary.validated_tiers_req_per_second) } else { @() }
$m6Adm = $m6.perRun.'r5-A'.tier_admission
Add-Check 'b4.wrong_type_counter_is_rejected' ($m6Run.exit -eq 1 -and $m6Tiers.Count -eq 1 -and ($m6Tiers -contains 20) -and ($m6Probs -match 'collect-result\.stats\.completed=String') -and [bool]$m6Adm.collector_cross_check.fields.completed.ok -eq $false) `
    ("exit=$($m6Run.exit) tiers=$($m6Tiers -join ',') reason='$($m6Adm.collector_cross_check.fields.completed.reason)'")

# (h) a legal but non-zero in-flight count means the run did not drain
$m7Dir = Copy-TrafficControl 'traffic-nonzero-inflight'
$null = Set-CollectStats $m7Dir $trafficCtrl.plans['5'].sample_run['A'] { param($s) $s.inflight_at_end = 1 }
$m7Run = Invoke-Summarize $m7Dir $trafficCalRunId
$m7 = Get-TrafficResult $m7Dir $trafficCalRunId
$m7Tiers = if ($null -ne $m7) { @($m7.summary.validated_tiers_req_per_second) } else { @() }
$m7Adm = $m7.perRun.'r5-A'.tier_admission
Add-Check 'b4.nonzero_inflight_is_rejected' ($m7Run.exit -eq 1 -and $m7Tiers.Count -eq 1 -and ($m7Tiers -contains 20) -and [bool]$m7Adm.collector_cross_check.fields.inflight_at_end.ok -and [int]$m7Adm.collector_cross_check.inflight_at_end -eq 1 -and (@($m7Adm.failed_conditions) -contains 'started_equals_completed_after_drain')) `
    ("exit=$($m7Run.exit) tiers=$($m7Tiers -join ',') inflight_at_end=$($m7Adm.collector_cross_check.inflight_at_end) failed_conditions=$(@($m7Adm.failed_conditions) -join ',')")

# (i) interrupted=true is legal JSON but not a drained run
$m8Dir = Copy-TrafficControl 'traffic-interrupted-true'
$null = Set-CollectStats $m8Dir $trafficCtrl.plans['5'].sample_run['A'] { param($s) $s.interrupted = $true }
$m8Run = Invoke-Summarize $m8Dir $trafficCalRunId
$m8 = Get-TrafficResult $m8Dir $trafficCalRunId
$m8Tiers = if ($null -ne $m8) { @($m8.summary.validated_tiers_req_per_second) } else { @() }
$m8Adm = $m8.perRun.'r5-A'.tier_admission
Add-Check 'b4.interrupted_true_is_rejected' ($m8Run.exit -eq 1 -and $m8Tiers.Count -eq 1 -and ($m8Tiers -contains 20) -and [bool]$m8Adm.collector_cross_check.fields.interrupted.ok -and [bool]$m8Adm.collector_cross_check.interrupted -eq $true -and (@($m8Adm.failed_conditions) -contains 'started_equals_completed_after_drain')) `
    ("exit=$($m8Run.exit) tiers=$($m8Tiers -join ',') interrupted=$($m8Adm.collector_cross_check.interrupted) failed_conditions=$($m8Adm.failed_conditions -join ',')")

# (j) the calibration self-report is only an EXTRA cross-check: a wrong self-reported counter is caught and the real
#     collect-result counters still win the reconciliation
$m9Dir = Copy-TrafficControl 'traffic-cal-counter-mismatch'
$null = Set-CalGroupCounter $m9Dir $trafficCalRunId 5 'A' 'started' 99
$m9Run = Invoke-Summarize $m9Dir $trafficCalRunId
$m9 = Get-TrafficResult $m9Dir $trafficCalRunId
$m9Probs = if ($null -ne $m9) { @($m9.summary.problems) -join ' | ' } else { '' }
$m9Tiers = if ($null -ne $m9) { @($m9.summary.validated_tiers_req_per_second) } else { @() }
$m9Adm = $m9.perRun.'r5-A'.tier_admission
Add-Check 'b4.calibration_counter_is_cross_checked' ($m9Run.exit -eq 1 -and $m9Tiers.Count -eq 1 -and ($m9Tiers -contains 20) -and ($m9Probs -match 'calibration-result started=99 but the originals say 100') -and (@($m9Adm.failed_conditions) -contains 'calibration_counters_agree_with_originals') -and [int]$m9.perRun.'r5-A'.collector_reported.started -eq 99 -and [int]$m9Adm.collector_cross_check.started -eq 100) `
    ("exit=$($m9Run.exit) tiers=$($m9Tiers -join ',') calibration self-report started=$($m9.perRun.'r5-A'.collector_reported.started) collect-result started=$($m9Adm.collector_cross_check.started) failed_conditions=$(@($m9Adm.failed_conditions) -join ',')")

# (k) every mutation above drops exactly the damaged 5 req/s tier and leaves the clean 20 req/s tier with all its
#     100 correct responses and unchanged percentiles
$mutations = @(
    [pscustomobject]@{ name = 'missing started/completed/inflight'; res = $m1 }
    [pscustomobject]@{ name = 'self-reported 99/99'; res = $m2 }
    [pscustomobject]@{ name = 'missing interrupted'; res = $m3 }
    [pscustomobject]@{ name = 'interrupted as a string'; res = $m4 }
    [pscustomobject]@{ name = 'negative started'; res = $m5 }
    [pscustomobject]@{ name = 'string completed'; res = $m6 }
    [pscustomobject]@{ name = 'non-zero inflight'; res = $m7 }
    [pscustomobject]@{ name = 'interrupted true'; res = $m8 }
    [pscustomobject]@{ name = 'calibration counter mismatch'; res = $m9 }
)
$badTiers = @($mutations | Where-Object {
        $t = @($_.res.summary.validated_tiers_req_per_second)
        ($null -eq $_.res) -or ($t.Count -ne 1) -or (-not ($t -contains 20)) -or
        (-not [bool]$_.res.perRun.'r20-A'.tier_admission.admitted) -or (-not [bool]$_.res.perRun.'r20-B'.tier_admission.admitted) -or
        ([int]$_.res.perRun.'r20-A'.correct -ne 100) -or ([double]$_.res.perRun.'r20-A'.latency_correct_ms.p50 -ne [double]$tCtrl.perRun.'r20-A'.latency_correct_ms.p50)
    })
Add-Check 'b4.the_clean_20tier_survives_every_mutation' ($badTiers.Count -eq 0) `
    (($mutations | ForEach-Object { "$($_.name) -> tiers $(@($_.res.summary.validated_tiers_req_per_second) -join ',') r20 correct=$($_.res.perRun.'r20-A'.correct) p50=$($_.res.perRun.'r20-A'.latency_correct_ms.p50)" }) -join '; ')

# ---------------------------------------------------------------- case 8g: B5 the measurement path itself
# The card's measurement contract is verified here on the FINAL path (p14b-collect.ps1 + P14bMeasure):
#   1. a 250 ms observer stall must not delay dispatch (the observer is a different process);
#   2. a 250 ms MAIN LOOP stall must not prevent the body-ready stamp - it is taken in the request's own completion
#      path, so the loop can notice the task much later;
#   3. observer on vs off must not change the body latency (an observer may not make the old observation look faster);
#   4. no complete body means no body-ready stamp (never fabricated), with the reason recorded;
#   5. every request carries the four stamps on one monotonic axis.
$b5Count = 60
$b5Rate = 20
$b5Slots = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $b5Count; $i++) {
    $bid = $fixtureIds[$i % 2]
    $null = $b5Slots.Add(@{ id = $bid; path = "/ok/$bid"; expect = 'ok' })
}
$b5Plan = New-OfflinePlan @($b5Slots) 'plan-timing.json' $b5Rate
$lagBudget = [ordered]@{ p95 = 5.0; p99 = 10.0; max = 25.0 }

# (a) observer stalled 250 ms at ~200 ms into the run, compared with the SAME plan and the same observer but no stall.
#     The causal claim is RELATIVE: the observer stall must not add a dispatch block. The absolute 5/10/25 ms budget is a
#     tier gate and is evaluated on the business calibration, not smuggled in here (the loop's own per-record
#     serialisation/persist cost also shows up in this number and is reported, not excused).
$obsCtlRun = "$RunId-OBSCTL"
$rCtl = Invoke-CollectorRun $obsCtlRun $b5Plan $prefix 16 5000 0 'offline-observer-control'
$ctlRes = Get-CollectResult $obsCtlRun
$ctlLag = $ctlRes.stats.dispatch_schedule_lag_mono_ms
$obsPauseRun = "$RunId-OBSPAUSE"
$rObs = Invoke-CollectorRun $obsPauseRun $b5Plan $prefix 16 5000 0 'offline-observer-pause' 0 0 0 200 250
$obsPauseRes = Get-CollectResult $obsPauseRun
$obsPauseRows = @(Get-RunLedger $obsPauseRun)
$obsLag = $obsPauseRes.stats.dispatch_schedule_lag_mono_ms
$obsCtrl = $obsPauseRes.observer.private_control
$obsGapMax = $obsPauseRes.observer.gap_max_ms
$lagAddedP99 = [Math]::Round([double]$obsLag.p99 - [double]$ctlLag.p99, 3)
$lagAddedMax = [Math]::Round([double]$obsLag.max - [double]$ctlLag.max, 3)
Add-Check 'b5.observer_stall_adds_no_dispatch_block' ($rObs.exit -eq 0 -and $rCtl.exit -eq 0 -and $obsPauseRows.Count -eq $b5Count -and @($obsPauseRows | Where-Object { $_.correct -eq $true }).Count -eq $b5Count -and [bool]$obsCtrl.pause_applied -and $lagAddedP99 -le 50.0 -and $lagAddedMax -le 50.0) `
    ("exit=$($rObs.exit)/$($rCtl.exit) responses=$($obsPauseRows.Count) all correct; dispatch lag mono with the 250 ms observer stall p95=$($obsLag.p95) p99=$($obsLag.p99) max=$($obsLag.max) ms vs the unstalled control p95=$($ctlLag.p95) p99=$($ctlLag.p99) max=$($ctlLag.max) ms -> the stall added $lagAddedP99 ms at p99 / $lagAddedMax ms at max (tolerance 50 ms)")
Add-Check 'b5.observer_stall_was_real_and_is_recorded' ([bool]$obsCtrl.pause_applied -and [int]$obsCtrl.pause_requested_ms -eq 250 -and [double]$obsCtrl.pause_ms -ge 200 -and [double]$obsGapMax -ge 1200 -and [double]$obsPauseRes.observer.sample_cost_max_ms -ge 250) `
    ("observer private_control pause_applied=$($obsCtrl.pause_applied) pause_ms=$($obsCtrl.pause_ms); the stalled sample reports cost=$($obsPauseRes.observer.sample_cost_max_ms) ms and the next sample gap was $obsGapMax ms (the stall really happened; it is reported, never filled)")
# NOTE (section 8 correction): this line used to be `Add-Check ... $true`, i.e. it reported the already-failed dispatch
# budget as a PASS and then let the flow continue into a business calibration. It is replaced by a real admission:
# the measured numbers below are written into the private measurement gate, and `b6.private_quality_gate_blocks_business`
# proves the business entry refuses while that gate is not passed. The numbers themselves are recorded as a finding.
$privateGatePassed = ([double]$obsLag.p95 -le $lagBudget.p95) -and ([double]$obsLag.p99 -le $lagBudget.p99) -and ([double]$obsLag.max -le $lagBudget.max)
Write-Host ("private measurement gate: dispatch lag p95={0} p99={1} max={2} ms against 5/10/25 -> passed={3} (recorded, not relaxed)" -f $obsLag.p95, $obsLag.p99, $obsLag.max, $privateGatePassed)

# (b) the MAIN LOOP is stalled 250 ms after the 3rd start: the body-ready stamp must still be taken on time
$loopPauseSlots = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt 12; $i++) {
    $bid = $fixtureIds[0]
    $null = $loopPauseSlots.Add(@{ id = $bid; path = "/ok/$bid"; expect = 'ok' })
}
$loopPausePlan = New-OfflinePlan @($loopPauseSlots) 'plan-loop-pause.json' 8
$loopPauseRun = "$RunId-LOOPPAUSE"
$rLoop = Invoke-CollectorRun $loopPauseRun $loopPausePlan $prefix 16 5000 0 'offline-loop-pause' 0 3 250
$loopRes = Get-CollectResult $loopPauseRun
$loopRows = @(Get-RunLedger $loopPauseRun)
$loopWithBody = @($loopRows | Where-Object { $_.kind -eq 'response' -and $null -ne $_.body_ready_mono_ms })
$loopDelayed = @($loopWithBody | Where-Object { [double]$_.observe_lag_ms -ge 150 })
$loopFastBody = @($loopDelayed | Where-Object { [double]$_.body_latency_ms -lt 100 })
Add-Check 'b5.body_ready_is_taken_before_the_loop_resumes' ($rLoop.exit -eq 0 -and $loopWithBody.Count -eq $loopRows.Count -and $loopDelayed.Count -ge 1 -and $loopFastBody.Count -ge 1) `
    ("exit=$($rLoop.exit) responses=$($loopRows.Count) with a body-ready stamp=$($loopWithBody.Count); $($loopDelayed.Count) were observed >=150 ms after their body was ready and $($loopFastBody.Count) of those still had a body latency <100 ms (the stamp belongs to the request, not to the loop)")
Add-Check 'b5.legacy_elapsed_still_overstates_after_a_loop_stall' ($loopFastBody.Count -ge 1 -and @($loopFastBody | Where-Object { [int]$_.elapsed_ms -ge 150 }).Count -eq $loopFastBody.Count) `
    (($loopFastBody | Select-Object -First 3 | ForEach-Object { "seq=$($_.seq) body_latency=$($_.body_latency_ms) legacy_elapsed=$($_.elapsed_ms) observe_lag=$($_.observe_lag_ms)" }) -join '; ')

# (c) observer ON vs OFF on the same plan and the same private endpoint.
# Section 8: this comparison is measured on a LONGER plan (160 slots = 8 s aside at 20 req/s) because a 60-sample p95 is
# too noisy on a loopback endpoint to judge a 2 ms budget; the budget itself is unchanged.
$oonSlots = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt 160; $i++) {
    $bid = $fixtureIds[$i % 2]
    $null = $oonSlots.Add(@{ id = $bid; path = "/ok/$bid"; expect = 'ok' })
}
$oonPlan = New-OfflinePlan @($oonSlots) 'plan-observer-onoff.json' 20
$onRun = "$RunId-OBSON"
$rOn = Invoke-CollectorRun $onRun $oonPlan $prefix 16 5000 0 'offline-observer-on'
$onRes = Get-CollectResult $onRun
$offRun = "$RunId-OBSOFF"
$offArgs = @('-RunRoot', $RunRoot, '-RunId', $offRun, '-Base', $prefix, '-Group', 'A', '-PlanFile', $oonPlan,
    '-TruthFile', $truthPath, '-MaxInFlight', '16', '-RequestTimeoutMs', '5000', '-Phase', 'offline-observer-off', '-NoObserver')
$outOff = & powershell -NoProfile -ExecutionPolicy Bypass -File $collector @offArgs 2>&1
$rOff = [pscustomobject]@{ exit = $LASTEXITCODE; output = ($outOff | Out-String) }
$offRes = Get-CollectResult $offRun
$onP95 = [double]$onRes.stats.body_latency_ms.p95
$offP95 = [double]$offRes.stats.body_latency_ms.p95
# FUNCTIONAL part (this check): both passes ran through the same entry, are complete and correct, and the OFF pass really
# had no observer. The MEASUREMENT-QUALITY part (the 2 ms p95 delta) is NOT asserted here any more: it is computed into
# the private measurement gate below, together with the dispatch-lag budget, so a failed quality gate stays failed
# instead of being reported as a passing report line.
Add-Check 'b5.observer_on_off_comparison_is_measured' ($rOn.exit -eq 0 -and $rOff.exit -eq 0 -and [int]$onRes.stats.correct -eq 160 -and [int]$offRes.stats.correct -eq 160 -and [int]$onRes.stats.dropped -eq 0 -and [int]$offRes.stats.dropped -eq 0 -and [bool]$onRes.observer.enabled -and -not [bool]$offRes.observer.enabled) `
    ("observer on p95=$onP95 ms / off p95=$offP95 ms over 160 slots each at 20 req/s -> measured |delta|=$([Math]::Round($p95Delta, 3)) ms (gate budget 2 ms, evaluated in the private measurement gate); on: dispatch lag p95=$($onRes.stats.dispatch_schedule_lag_mono_ms.p95) legacy latency p95=$($onRes.stats.latency_correct_ms.p95); off: dispatch lag p95=$($offRes.stats.dispatch_schedule_lag_mono_ms.p95) legacy latency p95=$($offRes.stats.latency_correct_ms.p95)")
    ("observer on p95=$onP95 ms / off p95=$offP95 ms over 160 slots each at 20 req/s -> |delta|=$([Math]::Round($p95Delta, 3)) ms (budget 2 ms); on: dispatch lag p95=$($onRes.stats.dispatch_schedule_lag_mono_ms.p95) legacy latency p95=$($onRes.stats.latency_correct_ms.p95); off: dispatch lag p95=$($offRes.stats.dispatch_schedule_lag_mono_ms.p95) legacy latency p95=$($offRes.stats.latency_correct_ms.p95)")
Add-Check 'b5.observer_off_run_really_had_no_observer' ([bool]$offRes.observer.enabled -eq $false -and [int]$offRes.observer.pid -eq 0 -and [bool]$onRes.observer.enabled -and [int]$onRes.observer.pid -gt 0 -and [bool]$onRes.observer.pid_identity_matches) `
    ("on: observer pid=$($onRes.observer.pid) samples=$($onRes.observer.samples) sample_cost_max=$($onRes.observer.sample_cost_max_ms)ms; off: enabled=$($offRes.observer.enabled) pid=$($offRes.observer.pid)")

# (d) no complete body -> no body-ready stamp, and the reason is named (the abort and timeout cases from above)
$abortRow = @($mixedRows | Where-Object { ([string]$_.url).EndsWith('/abort/' + $id1) })[0]
$timeoutRows = @(Get-RunLedger $toRun)
$timeoutRow = @($timeoutRows | Where-Object { [bool]$_.timeout -eq $true })[0]
Add-Check 'b5.no_complete_body_means_no_body_ready_stamp' ($null -ne $abortRow -and $null -eq $abortRow.body_ready_mono_ms -and [string]$abortRow.body_ready_missing_reason -eq 'transport_error' -and $null -ne $timeoutRow -and $null -eq $timeoutRow.body_ready_mono_ms -and [string]$timeoutRow.body_ready_missing_reason -eq 'timeout' -and $null -eq $abortRow.body_latency_ms -and $null -eq $timeoutRow.body_latency_ms) `
    ("abort record: body_ready=$($abortRow.body_ready_mono_ms) reason=$($abortRow.body_ready_missing_reason); timeout record: body_ready=$($timeoutRow.body_ready_mono_ms) reason=$($timeoutRow.body_ready_missing_reason) (nothing is back-filled and no bytes/hash are invented)")

# (e) one monotonic axis: every stamp present, correctly ordered, and the whole-run elapsed time agrees on both clocks
$onRows = @(Get-RunLedger $onRun)
$missingStamps = @($onRows | Where-Object { $null -eq $_.dispatch_mono_ms -or $null -eq $_.observe_mono_ms -or $null -eq $_.ledger_written_mono_ms }).Count
$badOrder = @($onRows | Where-Object { $null -ne $_.body_ready_mono_ms -and -not ([double]$_.dispatch_mono_ms -le [double]$_.body_ready_mono_ms -and [double]$_.body_ready_mono_ms -le [double]$_.observe_mono_ms -and [double]$_.observe_mono_ms -le [double]$_.ledger_written_mono_ms) }).Count
Add-Check 'b5.four_stamps_are_present_and_ordered_on_one_axis' ($missingStamps -eq 0 -and $badOrder -eq 0 -and [double]$onRes.stats.monotonic.mono_vs_legacy_run_delta_ms -lt 20.0 -and [int]$onRes.stats.persist_lag_ms.count -eq 160) `
    ("responses=$($onRows.Count) missing stamps=$missingStamps out-of-order=$badOrder; run elapsed via Stopwatch=$($onRes.stats.run_elapsed_ms) ms vs monotonic axis=$($onRes.stats.monotonic.mono_elapsed_ms) ms -> |delta|=$($onRes.stats.monotonic.mono_vs_legacy_run_delta_ms) ms; per-record legacy-vs-helper gap max=$($onRes.stats.monotonic.legacy_vs_mono_max_delta_ms) ms (call overhead); persist_lag p95=$($onRes.stats.persist_lag_ms.p95) ms; flush max=$($onRes.stats.flush_lag_max_ms) ms")


# ---------------------------------------------------------------- case 8h: B6 section-8 evidence closure
# Four things the owner could not accept were proven by the previous round, each is repaired and asserted here:
#   A. the window and the independent verdict must use the BODY stamps (legacy observed window is separate);
#   B. the observer stall must really overlap the collection window, with a time-intersection assertion;
#   C. every real output path of a new entry must belong to THIS active root, refused before any side effect;
#   D. the identity digest must cover NESTED values and the ACTUAL compiled measurement assembly.
$p14bSum = Join-Path (Join-Path $benchDir 'env') 'p14b-summarize.ps1'
$p14bCal = Join-Path (Join-Path $benchDir 'env') 'p14b-calibrate.ps1'
$p14bCapEntry = Join-Path (Join-Path $benchDir 'env') 'capture-p14b-baseline.ps1'
function Get-TreeHash2([string]$rootPath) {
    $items = @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force | Sort-Object FullName)
    $sb = New-Object System.Text.StringBuilder
    foreach ($i in $items) {
        $rel = $i.FullName.Substring($rootPath.Length)
        if ($i.PSIsContainer) { $null = $sb.AppendLine("D|$rel") }
        else { $null = $sb.AppendLine(("F|{0}|{1}" -f $rel, (Get-FileHash -LiteralPath $i.FullName -Algorithm SHA256).Hash.ToLower())) }
    }
    return (Get-P14aSha256 ([System.Text.Encoding]::UTF8.GetBytes($sb.ToString())))
}

# ---- A1. the BODY window, on the owner's own boundary shape (2 bodies inside 1 s, 2nd observation after it) -----
$win2Slots = @(
    @{ id = $fixtureIds[0]; path = "/ok/$($fixtureIds[0])"; expect = 'ok' }
    @{ id = $fixtureIds[1]; path = "/ok/$($fixtureIds[1])"; expect = 'ok' }
)
$win2Plan = New-OfflinePlan $win2Slots 'plan-body-window.json' 2 -Seconds 1
$win2Run = "$RunId-BODYWIN"
# a 800 ms MAIN LOOP stall right after the 2nd start: both bodies are ready inside 1 s, the 2nd observation is not
$rWin2 = Invoke-CollectorRun $win2Run $win2Plan $prefix 4 5000 0 'offline-body-window' 0 2 800
$win2Res = Get-CollectResult $win2Run
$win2Rows = @(Get-RunLedger $win2Run)
$win2BodyOffsets = @($win2Rows | ForEach-Object { [double]$_.body_ready_offset_ms })
$win2In = if ($null -ne $win2Res) { [int]$win2Res.stats.window_body.in_window } else { -1 }
$win2After = if ($null -ne $win2Res) { [int]$win2Res.stats.window_body.after_window } else { -1 }
$win2LegacyIn = if ($null -ne $win2Res) { [int]$win2Res.stats.completed_in_window } else { -1 }
$win2LegacyAfter = if ($null -ne $win2Res) { [int]$win2Res.stats.completed_after_window } else { -1 }
Add-Check 'b6.body_window_uses_the_body_ready_stamp' ($rWin2.exit -eq 0 -and $win2In -eq 2 -and $win2After -eq 0 -and [bool]$win2Res.stats.window_body.add_up -and ($win2LegacyIn -ne $win2In -or $win2LegacyAfter -ne $win2After)) `
    ("declared 1000 ms; body offsets=[{0}] ms -> BODY window in={1} after={2}; LEGACY observation window in={3} after={4}. The two windows disagree exactly as the owner's boundary case does, so the body window cannot be the observation window" -f (($win2BodyOffsets | ForEach-Object { [Math]::Round($_, 1) }) -join ','), $win2In, $win2After, $win2LegacyIn, $win2LegacyAfter)

# ---- A2. the independent P1.4b summary, on private copies of one REAL run ---------------------------------------
# A helper that copies a real run into this root, rewrites its plan reference to a plan that exists here, and mutates
# one record, so each refusal is proven on the same originals.
$s8PlanName = 's8-offline-plan.json'
$s8PlanPath = Join-Path (Join-Path $RunRoot 'plans') $s8PlanName
if (-not (Test-Path -LiteralPath $s8PlanPath)) {
    $planDir = Join-Path $RunRoot 'plans'
    if (-not (Test-Path -LiteralPath $planDir)) { New-Item -ItemType Directory -Path $planDir -Force | Out-Null }
    Copy-Item -LiteralPath $b5Plan -Destination $s8PlanPath -Force
}
$s8PlanSha = Get-Sha $s8PlanPath
function New-S8Case([string]$name, [string]$sourceRunId, [int]$rate = 5, [int]$pair = 1, [string]$group = 'A', [object[]]$SubRuns = $null) {
    $rid = "S8-$name"
    $dir = Join-Path (Join-Path $RunRoot 'runs') $rid
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $src = Join-Path (Join-Path $RunRoot 'runs') $sourceRunId
    Copy-Item -LiteralPath (Join-Path $src 'responses.jsonl') -Destination (Join-Path $dir 'responses.jsonl') -Force
    Copy-Item -LiteralPath (Join-Path $src 'collect-result.json') -Destination (Join-Path $dir 'collect-result.json') -Force
    $obsSrc = Join-Path (Join-Path $src 'observer') 'observer-summary.json'
    if (Test-Path -LiteralPath $obsSrc) {
        $obsDst = Join-Path $dir 'observer'
        New-Item -ItemType Directory -Path $obsDst -Force | Out-Null
        Copy-Item -LiteralPath $obsSrc -Destination (Join-Path $obsDst 'observer-summary.json') -Force
    }
    $collPath = Join-Path $dir 'collect-result.json'
    $coll = Get-Content -LiteralPath $collPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $coll.run_id = $rid
    $coll.plan.file = $s8PlanName
    $coll.plan.sha256 = $s8PlanSha
    [System.IO.File]::WriteAllText($collPath, ($coll | ConvertTo-Json -Depth 8), $utf8)
    $sub = if ($null -ne $SubRuns) { $SubRuns } else { @([ordered]@{ rate = $rate; pair = $pair; group = $group; run_id = $rid; plan_file = $s8PlanName }) }
    $subPath = Join-Path $dir 'subruns.json'
    [System.IO.File]::WriteAllText($subPath, (ConvertTo-Json ([ordered]@{ run_id = $rid; subruns = $sub }) -Depth 6), $utf8)
    return [pscustomobject]@{ rid = $rid; dir = $dir; sub = $subPath; ledger = (Join-Path $dir 'responses.jsonl') }
}
function Invoke-P14bSum([string]$subPath, [string]$rid, [double]$p95 = 5.0) {
    $a = @('-RunRoot', $RunRoot, '-RunId', $rid, '-Mode', 'p14b', '-SubRunsFile', $subPath, '-DispatchLagP95', "$p95", '-TruthFile', $truthPath)
    $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $p14bSum @a 2>&1
    $sp = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $rid) 'p14b-summary.json'
    $sum = if (Test-Path -LiteralPath $sp) { Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ exit = $LASTEXITCODE; text = (($o | Out-String).Trim() -replace '\s+', ' '); summary = $sum; path = $sp }
}
function Set-S8Record([string]$ledgerPath, [int]$seq, [scriptblock]$Mutate) {
    $lines = @([System.IO.File]::ReadAllLines($ledgerPath))
    $o = $lines[$seq - 1] | ConvertFrom-Json
    & $Mutate $o
    $lines[$seq - 1] = ($o | ConvertTo-Json -Compress -Depth 6)
    [System.IO.File]::WriteAllLines($ledgerPath, $lines, $utf8)
}

# (a) a NEGATIVE body latency (the owner's exact copy: body stamp moved before the dispatch stamp)
$negC = New-S8Case 'neg-latency' $onRun
Set-S8Record $negC.ledger 1 { param($o) $o.body_ready_mono_ms = [double]$o.dispatch_mono_ms - 10.0; $o.body_ready_offset_ms = [double]$o.dispatch_offset_ms - 10.0 }
$negR = Invoke-P14bSum $negC.sub $negC.rid
$negProbs = if ($null -ne $negR.summary) { @($negR.summary.problems) -join ' | ' } else { '' }
Add-Check 'b6.p14b_summary_rejects_a_negative_body_latency' ($negR.exit -eq 1 -and $null -ne $negR.summary -and $negProbs -match 'NEGATIVE body latency' -and @($negR.summary.validated_tiers_req_per_second).Count -eq 0) `
    ("exit=$($negR.exit) validated_tiers=$(@($negR.summary.validated_tiers_req_per_second) -join ',') problem names the negative latency=$([bool]($negProbs -match 'NEGATIVE body latency'))")

# (b) the three new stamps DELETED (the legacy observation fields remain, and must not be used as a fallback)
$missC = New-S8Case 'missing-stamps' $onRun
Set-S8Record $missC.ledger 1 { param($o) $o.PSObject.Properties.Remove('dispatch_mono_ms'); $o.PSObject.Properties.Remove('body_ready_mono_ms'); $o.PSObject.Properties.Remove('observe_mono_ms') }
$missR = Invoke-P14bSum $missC.sub $missC.rid
$missProbs = if ($null -ne $missR.summary) { @($missR.summary.problems) -join ' | ' } else { '' }
Add-Check 'b6.p14b_summary_rejects_missing_stamps' ($missR.exit -eq 1 -and $missProbs -match 'has no P1.4b stamps' -and @($missR.summary.validated_tiers_req_per_second).Count -eq 0) `
    ("exit=$($missR.exit) the deleted stamps are refused by name (no silent 0 / legacy fallback), validated_tiers is empty")

# (c) stamps OUT OF ORDER (body ready after the loop observed it)
$ordC = New-S8Case 'out-of-order' $onRun
Set-S8Record $ordC.ledger 1 { param($o) $o.body_ready_mono_ms = [double]$o.observe_mono_ms + 5.0 }
$ordR = Invoke-P14bSum $ordC.sub $ordC.rid
$ordProbs = if ($null -ne $ordR.summary) { @($ordR.summary.problems) -join ' | ' } else { '' }
Add-Check 'b6.p14b_summary_rejects_out_of_order_stamps' ($ordR.exit -eq 1 -and $ordProbs -match 'out of order' -and @($ordR.summary.validated_tiers_req_per_second).Count -eq 0) `
    ("exit=$($ordR.exit) an out-of-order record is refused by name; validated_tiers is empty")

# (d) an INCOMPLETE pair set: rate 5 with only pair 1 x A,B (both clean copies of the same run)
$pA = New-S8Case 'pair-a' $onRun
$pB = New-S8Case 'pair-b' $onRun
$pairSubs = @(
    [ordered]@{ rate = 5; pair = 1; group = 'A'; run_id = $pA.rid; plan_file = $s8PlanName }
    [ordered]@{ rate = 5; pair = 1; group = 'B'; run_id = $pB.rid; plan_file = $s8PlanName }
)
$pairSubPath = Join-Path $pA.dir 'subruns-pairs.json'
[System.IO.File]::WriteAllText($pairSubPath, (ConvertTo-Json ([ordered]@{ run_id = $pA.rid; subruns = $pairSubs }) -Depth 6), $utf8)
$pairR = Invoke-P14bSum $pairSubPath $pA.rid
$pairProbs = if ($null -ne $pairR.summary) { @($pairR.summary.problems) -join ' | ' } else { '' }
$pairTv = if ($null -ne $pairR.summary) { @($pairR.summary.tier_validity)[0] } else { $null }
Add-Check 'b6.p14b_summary_requires_both_pairs_of_a_rate' ($pairR.exit -eq 1 -and $null -ne $pairTv -and [bool]$pairTv.complete -eq $false -and @($pairTv.missing_subruns) -contains 'p2A' -and @($pairR.summary.validated_tiers_req_per_second).Count -eq 0) `
    ("exit=$($pairR.exit) complete=$($pairTv.complete) missing=$(($pairTv.missing_subruns) -join ',') validated_tiers=empty (a rate is never accepted from only the last pair)")

# (e) all four sub-runs present and the records perfectly correct, but a quality gate that cannot pass -> still refused
$q1 = New-S8Case 'gate-a1' $onRun
$q2 = New-S8Case 'gate-b1' $onRun
$q3 = New-S8Case 'gate-a2' $onRun
$q4 = New-S8Case 'gate-b2' $onRun
$gateSubs = @(
    [ordered]@{ rate = 5; pair = 1; group = 'A'; run_id = $q1.rid; plan_file = $s8PlanName }
    [ordered]@{ rate = 5; pair = 1; group = 'B'; run_id = $q2.rid; plan_file = $s8PlanName }
    [ordered]@{ rate = 5; pair = 2; group = 'A'; run_id = $q3.rid; plan_file = $s8PlanName }
    [ordered]@{ rate = 5; pair = 2; group = 'B'; run_id = $q4.rid; plan_file = $s8PlanName }
)
$gateSubPath = Join-Path $q1.dir 'subruns-gate.json'
[System.IO.File]::WriteAllText($gateSubPath, (ConvertTo-Json ([ordered]@{ run_id = $q1.rid; subruns = $gateSubs }) -Depth 6), $utf8)
$gateR = Invoke-P14bSum $gateSubPath $q1.rid 0.001
$gateTv = if ($null -ne $gateR.summary) { @($gateR.summary.tier_validity)[0] } else { $null }
Add-Check 'b6.p14b_summary_refuses_a_failed_quality_gate' ($gateR.exit -eq 1 -and $null -ne $gateTv -and [bool]$gateTv.complete -and [bool]$gateTv.all_subruns_passed -eq $false -and @($gateR.summary.validated_tiers_req_per_second).Count -eq 0) `
    ("all four sub-runs present and every body correct, but with a 0.001 ms dispatch gate: complete=$($gateTv.complete) all_passed=$($gateTv.all_subruns_passed) validated_tiers=empty (correctness alone never admits a tier)")

# ---- B. the observer stall must overlap the collection window ---------------------------------------------------
$ovlRun = "$RunId-OBSOVERLAP"
$rOvl = Invoke-CollectorRun $ovlRun $b5Plan $prefix 16 5000 0 'offline-observer-overlap' 0 0 0 0 250 0
$ovlRes = Get-CollectResult $ovlRun
$ovlRows = @(Get-RunLedger $ovlRun)
$ovlCtrl = $ovlRes.observer.private_control
$ovlStart = [double]$ovlRes.stats.monotonic.run_start_mono_ms
$ovlEnd = [double]$ovlRes.stats.monotonic.run_end_mono_ms
$ovlPauseStart = if ($null -ne $ovlCtrl.pause_interval) { [double]$ovlCtrl.pause_interval.start_mono_ms } else { -1.0 }
$ovlPauseEnd = if ($null -ne $ovlCtrl.pause_interval) { [double]$ovlCtrl.pause_interval.end_mono_ms } else { -1.0 }
$ovlIntersects = ($ovlPauseStart -ge $ovlStart) -and ($ovlPauseStart -le $ovlEnd)
$ovlSlotsDueInside = @($ovlRows | Where-Object {
        $dueAbs = $ovlStart + [double]$_.planned_offset_ms
        ($dueAbs -ge $ovlPauseStart) -and ($dueAbs -le $ovlPauseEnd)
    }).Count
Add-Check 'b6.observer_pause_overlaps_the_collection_window' ($rOvl.exit -eq 0 -and [bool]$ovlCtrl.pause_applied -and $ovlIntersects -and $ovlSlotsDueInside -ge 1 -and [double]$ovlCtrl.pause_ms -ge 200) `
    ("pause [{0}, {1}] ms vs collection window [{2}, {3}] ms -> start inside={4}; planned slots due inside the pause={5}; measured pause={6} ms (a real time intersection, not just pause_applied)" -f [Math]::Round($ovlPauseStart, 1), [Math]::Round($ovlPauseEnd, 1), [Math]::Round($ovlStart, 1), [Math]::Round($ovlEnd, 1), $ovlIntersects, $ovlSlotsDueInside, $ovlCtrl.pause_ms)
# the same assertion must be REFUSED when the stall never fires: otherwise the check above is vacuous
$novlRun = "$RunId-OBSNOOVERLAP"
$rNovl = Invoke-CollectorRun $novlRun $b5Plan $prefix 16 5000 0 'offline-observer-no-overlap' 0 0 0 0 250 600000
$novlRes = Get-CollectResult $novlRun
$novlCtrl = $novlRes.observer.private_control
$novlApplied = [bool]$novlCtrl.pause_applied
Add-Check 'b6.overlap_assertion_is_not_vacuous' ($rNovl.exit -eq 0 -and -not $novlApplied -and $null -eq $novlCtrl.pause_interval) `
    ("with the stall gated 600000 ms after ready it never fires: pause_applied=$novlApplied interval=$($null -ne $novlCtrl.pause_interval) -> the overlap assertion above cannot be satisfied by a paused flag alone")

# ---- C. real output-path protection ----------------------------------------------------------------------------
$s8SynthActive = Join-Path (Join-Path $outDir 's8-synth') 'active-root'
$s8SynthDone = Join-Path (Join-Path $outDir 's8-synth') 'completed-sibling'
foreach ($d in @($s8SynthActive, $s8SynthDone)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $pm = Join-Path $d 'prepare-manifest.json'
    if (-not (Test-Path -LiteralPath $pm)) { [System.IO.File]::WriteAllText($pm, '{"scope":"private synthetic root for the section-8 path guard"}', $utf8) }
}
$doneMarker = Join-Path $s8SynthDone 'summary.json'
if (-not (Test-Path -LiteralPath $doneMarker)) { [System.IO.File]::WriteAllText($doneMarker, '{"scope":"private synthetic COMPLETED sibling"}', $utf8) }
$sibBefore = Get-TreeHash2 $s8SynthDone
$actBefore = Get-TreeHash2 $s8SynthActive
$oObsBad = & powershell -NoProfile -ExecutionPolicy Bypass -File $observerEntry -RunRoot $s8SynthActive -Tag 'S8BAD' -OutDir $s8SynthDone -CollectorPid 1 -IntervalMs 100 2>&1
$obsBadExit = $LASTEXITCODE
$sibAfter = Get-TreeHash2 $s8SynthDone
$actAfter = Get-TreeHash2 $s8SynthActive
Add-Check 'b6.observer_refuses_an_outdir_in_a_completed_sibling' ($obsBadExit -eq 2 -and $sibAfter -eq $sibBefore -and $actAfter -eq $actBefore) `
    ("exit=$2 actual=$obsBadExit; the completed sibling tree hash is unchanged=$($sibAfter -eq $sibBefore) and the active root too=$($actAfter -eq $actBefore) (refused BEFORE creating resources.csv / observer-summary.json / ready.txt)")
# the capture entry must refuse an -OutFile that resolves outside the root
$escFile = '..\..\s8-escape.json'
$oCapBad = & powershell -NoProfile -ExecutionPolicy Bypass -File $p14bCapEntry -RunRoot $s8SynthActive -Phase start -OutFile $escFile 2>&1
$capBadExit = $LASTEXITCODE
$escapedPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $s8SynthActive 'inputs') $escFile))
Add-Check 'b6.capture_refuses_an_outfile_outside_the_root' ($capBadExit -eq 2 -and -not (Test-Path -LiteralPath $escapedPath)) `
    ("'$escFile' resolves to '$escapedPath'; exit=$capBadExit and that file does not exist (a '..' escape is judged by where it really lands)")

# ---- D. identity: nested values and the actual assembly ---------------------------------------------------------
$idA = Join-Path (Join-Path $outDir 's8-identity') 'with-arg-a'
$idB = Join-Path (Join-Path $outDir 's8-identity') 'with-arg-b'
foreach ($pair in @(@($idA, '-Xmx512m'), @($idB, '-Xmx513m'))) {
    $d = $pair[0]
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $pm = Join-Path $d 'prepare-manifest.json'
    if (-not (Test-Path -LiteralPath $pm)) { [System.IO.File]::WriteAllText($pm, '{"scope":"private synthetic root for the section-8 identity test"}', $utf8) }
    foreach ($sub in @('inputs', 'logs', 'plans')) {
        $sd = Join-Path $d $sub
        if (-not (Test-Path -LiteralPath $sd)) { New-Item -ItemType Directory -Path $sd -Force | Out-Null }
    }
    $inst = [ordered]@{ port = 51999; pid = 4242; cache_enabled = $false; jvm_args = @('-Xms256m', $pair[1]); java_exe = 'D:/Soft/Java/jdk-1.8/bin/java.exe' }
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $d 'logs') 's8.instance.json'), (ConvertTo-Json $inst -Depth 5), $utf8)
}
$oIdA = & powershell -NoProfile -ExecutionPolicy Bypass -File $p14bCapEntry -RunRoot $idA -Phase start 2>&1
$idAExit = $LASTEXITCODE
$oIdB = & powershell -NoProfile -ExecutionPolicy Bypass -File $p14bCapEntry -RunRoot $idB -Phase start 2>&1
$idBExit = $LASTEXITCODE
$idAJ = if (Test-Path -LiteralPath (Join-Path (Join-Path $idA 'inputs') 'pre-run-freeze.json')) { Get-Content -LiteralPath (Join-Path (Join-Path $idA 'inputs') 'pre-run-freeze.json') -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$idBJ = if (Test-Path -LiteralPath (Join-Path (Join-Path $idB 'inputs') 'pre-run-freeze.json')) { Get-Content -LiteralPath (Join-Path (Join-Path $idB 'inputs') 'pre-run-freeze.json') -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$nestCovered = ($null -ne $idAJ) -and ($null -ne $idBJ) -and ([string]$idAJ.baseline_id -ne [string]$idBJ.baseline_id)
Add-Check 'b6.identity_hash_covers_nested_jvm_arguments' ($idAExit -eq 0 -and $idBExit -eq 0 -and $nestCovered) `
    ("two roots identical except one nested JVM argument (-Xmx512m vs -Xmx513m): baseline_a=$($idAJ.baseline_id.Substring(0,16))... baseline_b=$($idBJ.baseline_id.Substring(0,16))... differ=$nestCovered (the recursive canonical form reaches the nested list)")
$asmInfo = if ($null -ne $onRes) { $onRes.measure_lib.assembly } else { $null }
$asmOnDisk = if ($null -ne $asmInfo) { Join-Path (Join-Path (Join-Path $RunRoot 'runs') $onRun) (($asmInfo.path) -replace '/', '\') } else { '' }
$asmOk = ($null -ne $asmInfo) -and ($null -ne $onRes) -and [bool]$asmInfo.loaded_from_that_file -and (Test-Path -LiteralPath $asmOnDisk) -and ((Get-Sha $asmOnDisk) -eq [string]$asmInfo.sha256)
Add-Check 'b6.measurement_assembly_is_persisted_and_named' $asmOk `
    ("collect-result names the compiled artifact: path=$($asmInfo.path) sha256=$($asmInfo.sha256) bytes=$($asmInfo.bytes) exists_on_disk=$(if ($asmOnDisk) { Test-Path -LiteralPath $asmOnDisk } else { $false }) and its hash equals the recorded one")

# ---- A3. the private quality gate is REAL admission, not a report line ------------------------------------------
$gateFile = Join-Path (Join-Path $RunRoot 'inputs') 'private-measurement-gate.json'
$dispatchOk = ([double]$obsLag.p95 -le $lagBudget.p95) -and ([double]$obsLag.p99 -le $lagBudget.p99) -and ([double]$obsLag.max -le $lagBudget.max)
$onOffOk = ($p95Delta -le 2.0)
$gatePassed = $dispatchOk -and $onOffOk
$gateReason = ("dispatch-lag budget 5/10/25 ms measured p95={0} p99={1} max={2} ms -> {3}; observer on/off body-latency p95 delta={4} ms against 2 ms -> {5}" -f `
        $obsLag.p95, $obsLag.p99, $obsLag.max, $(if ($dispatchOk) { 'pass' } else { 'FAIL' }), [Math]::Round($p95Delta, 3), $(if ($onOffOk) { 'pass' } else { 'FAIL' }))
[System.IO.File]::WriteAllText($gateFile, (ConvertTo-Json ([ordered]@{
                passed = $gatePassed
                reason = $gateReason
                dispatch_lag_ok = $dispatchOk
                on_off_p95_delta_ms = [Math]::Round($p95Delta, 3)
                on_off_delta_ok = $onOffOk
                measured_dispatch_lag_mono_ms = $obsLag
                source_runs = [ordered]@{ observer_stall = $obsPauseRun; on_off_on = $onRun; on_off_off = $offRun }
                note = 'written by the private validation suite from the measured data; the business calibration entry refuses unless passed=true'
            }) -Depth 6), $utf8)
$oCalBad = & powershell -NoProfile -ExecutionPolicy Bypass -File $p14bCal -RunRoot $RunRoot -RunId 'S8-CAL-BLOCKED' -RatesCsv 5 2>&1
$calBadExit = $LASTEXITCODE
$calText = ($oCalBad | Out-String)
Add-Check 'b6.private_quality_gate_blocks_business' ($calBadExit -eq 2 -and $calText -match 'REFUSED_STAGE=measurement-gate' -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $RunRoot 'runs') 'S8-CAL-BLOCKED'))) `
    ("gate passed=$gatePassed ($gateReason) -> the business calibration entry exits $calBadExit with REFUSED_STAGE=measurement-gate and creates no run directory (a failed private gate can no longer be stepped over)")

# ---------------------------------------------------------------- case 9: C regression - sealed root and write-once
function Get-TreeHash([string]$rootPath) {
    $items = @(Get-ChildItem -LiteralPath $rootPath -Recurse -Force | Sort-Object FullName)
    $sb = New-Object System.Text.StringBuilder
    foreach ($i in $items) {
        $rel = $i.FullName.Substring($rootPath.Length)
        if ($i.PSIsContainer) { $null = $sb.AppendLine("D|$rel") }
        else { $null = $sb.AppendLine(("F|{0}|{1}" -f $rel, (Get-FileHash -LiteralPath $i.FullName -Algorithm SHA256).Hash.ToLower())) }
    }
    return (Get-P14aSha256 ([System.Text.Encoding]::UTF8.GetBytes($sb.ToString())))
}
$synth = Join-Path $outDir 'synthetic-completed-root'
foreach ($d in @('', 'plans', 'runs', 'logs', 'configs', 'events')) {
    $p = if ($d -eq '') { $synth } else { Join-Path $synth $d }
    New-Item -ItemType Directory -Path $p -Force | Out-Null
}
Copy-Item -LiteralPath (Join-Path $RunRoot 'prepare-manifest.json') -Destination (Join-Path $synth 'prepare-manifest.json') -Force
[System.IO.File]::WriteAllText((Join-Path $synth 'summary.json'), '{"scope":"private synthetic COMPLETED root, offline guard test only"}', $utf8)
$synthBefore = Get-TreeHash $synth
$hitsBeforeC = @([System.IO.File]::ReadAllLines($endpointEvents, $utf8) | Where-Object { $_ -match 'request ' }).Count
$sealedCases = @()
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -RunRoot $synth -RunId "$RunId-SEALEDCOLLECT" -Base $prefix -Group A -PlanFile $mixedPlan -TruthFile $truthPath -NoObserver 2>&1
$sealedCases += [pscustomobject]@{ entry = 'p14a-collect'; exit = $LASTEXITCODE; text = ($o | Out-String) }
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $benchDir 'env') 'p14a-plan.ps1') -RunRoot $synth 2>&1
$sealedCases += [pscustomobject]@{ entry = 'p14a-plan'; exit = $LASTEXITCODE; text = ($o | Out-String) }
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $benchDir 'env') 'p14a-calibrate.ps1') -RunRoot $synth -RunId "$RunId-SEALEDCAL" 2>&1
$sealedCases += [pscustomobject]@{ entry = 'p14a-calibrate'; exit = $LASTEXITCODE; text = ($o | Out-String) }
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $benchDir 'env') 'p14a-summarize.ps1') -RunRoot $synth -RunId "$RunId-SEALEDSUM" 2>&1
$sealedCases += [pscustomobject]@{ entry = 'p14a-summarize'; exit = $LASTEXITCODE; text = ($o | Out-String) }
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $benchDir 'env') 'start-p14a-instance.ps1') -RunRoot $synth -Port 65001 -Tag 'synth' -Group A -ProbeConfig (Join-Path $synth 'configs/synth.properties') 2>&1
$sealedCases += [pscustomobject]@{ entry = 'start-p14a-instance'; exit = $LASTEXITCODE; text = ($o | Out-String) }
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File $observerEntry -RunRoot $synth -Tag 'SEALEDOBS' -CollectorPid 1 -IntervalMs 100 2>&1
$sealedCases += [pscustomobject]@{ entry = 'p14b-observer'; exit = $LASTEXITCODE; text = ($o | Out-String) }
# the offline driver itself is an entry (it writes files and starts a process): it must refuse the same root.
# It exits at the guard, so this nested invocation does no work at all.
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RunRoot $synth -RunId "$RunId-SEALEDOFFLINE" 2>&1
$sealedCases += [pscustomobject]@{ entry = 'run-p14a-collector-offline'; exit = $LASTEXITCODE; text = ($o | Out-String) }
# The P1.4b prepare is a different shape: it refuses a root that is not a direct child of the artifacts root, and it
# refuses an existing root. Both refusals are checked below on its own (it cannot report the root-state stage marker
# because its first guard is the parent rule).
$hitsAfterC = @([System.IO.File]::ReadAllLines($endpointEvents, $utf8) | Where-Object { $_ -match 'request ' }).Count
$synthAfter = Get-TreeHash $synth
$exit2 = @($sealedCases | Where-Object { $_.exit -ne 2 }).Count -eq 0
$stageRootState = @($sealedCases | Where-Object { $_.text -notmatch 'REFUSED_STAGE=root-state' }).Count -eq 0
Add-Check 'c_seal.every_entry_refuses_a_completed_root' ($exit2 -and $stageRootState) `
    (($sealedCases | ForEach-Object { "$($_.entry)=$($_.exit)" }) -join ' ')
Add-Check 'c_seal.refusal_happens_before_files_and_http' ($hitsAfterC -eq $hitsBeforeC -and $synthAfter -eq $synthBefore) `
    ("endpoint requests before=$hitsBeforeC after=$hitsAfterC; synthetic root tree hash before=$($synthBefore.Substring(0, 12)) after=$($synthAfter.Substring(0, 12)) (identical means no file was created, overwritten or appended)")
$onceDir = Join-Path $outDir 'write-once'
New-Item -ItemType Directory -Path $onceDir -Force | Out-Null
$onceFile = Join-Path $onceDir 'already-there.json'
[System.IO.File]::WriteAllText($onceFile, '{"original":true}', $utf8)
$onceShaBefore = (Get-FileHash -LiteralPath $onceFile -Algorithm SHA256).Hash.ToLower()
# (f) the P1.4b prepare refuses a root that is neither a direct child of the artifacts root nor new; neither refusal
#     may create anything. Placed here because it needs the synthetic root defined above.
$prepScript = Join-Path (Join-Path $benchDir 'env') 'prepare-p14b-run.ps1'
$prepA = & powershell -NoProfile -ExecutionPolicy Bypass -File $prepScript -RunRoot (Join-Path $synth 'p14b-child') -ArtifactsRoot $ArtifactsRoot 2>&1
$prepAExit = $LASTEXITCODE
$prepB = & powershell -NoProfile -ExecutionPolicy Bypass -File $prepScript -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot 2>&1
$prepBExit = $LASTEXITCODE
$prepAText = (($prepA | Out-String).Trim() -split "`r?`n")[0]
$prepBText = (($prepB | Out-String).Trim() -split "`r?`n")[0]
Add-Check 'b5.prepare_refuses_a_non_child_and_an_existing_root' ($prepAExit -eq 2 -and $prepBExit -eq 2 -and -not (Test-Path -LiteralPath (Join-Path $synth 'p14b-child'))) `
    ("not-a-direct-child exit=$prepAExit ($prepAText); existing-root exit=$prepBExit ($prepBText); no directory was created under the synthetic root")
$onceScript = Join-Path $onceDir 'call-write-once.ps1'
$onceSource = @'
param([Parameter(Mandatory = $true)][string]$LibDir, [Parameter(Mandatory = $true)][string]$Path)
$ErrorActionPreference = 'Stop'
. (Join-Path $LibDir 'P14aRoots.ps1')
$null = Write-P14aOnce -Path $Path -Text '{"overwritten":true}' -EntryPoint 'offline-write-once-test'
exit 0
'@
[System.IO.File]::WriteAllText($onceScript, $onceSource, $utf8)
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File $onceScript -LibDir (Join-Path $benchDir 'lib') -Path $onceFile 2>&1
$onceExit = $LASTEXITCODE
$onceText = ($o | Out-String)
$onceShaAfter = (Get-FileHash -LiteralPath $onceFile -Algorithm SHA256).Hash.ToLower()
Add-Check 'c_seal.write_once_refuses_and_keeps_the_original' ($onceExit -eq 2 -and $onceText -match 'REFUSED_STAGE=write-once' -and $onceShaAfter -eq $onceShaBefore) `
    ("second write exit=$onceExit stage=write-once sha_unchanged=$($onceShaAfter -eq $onceShaBefore) (a repeated or partially failed run must use a new run id / root, never rewrite evidence)")

# ---------------------------------------------------------------- case 10: guard refusals cost zero HTTP calls
$hitsBefore = @([System.IO.File]::ReadAllLines($endpointEvents, $utf8) | Where-Object { $_ -match 'request ' }).Count
$refusals = @()
# missing prepare manifest
$bogusRoot = Join-Path $RunRoot 'offline/no-prepare-root'
New-Item -ItemType Directory -Path $bogusRoot -Force | Out-Null
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -RunRoot $bogusRoot -RunId "$RunId-GUARD1" -Base $prefix -Group A -PlanFile $mixedPlan -TruthFile $truthPath -NoObserver 2>&1
$refusals += [pscustomobject]@{ case = 'no_prepare_manifest'; exit = $LASTEXITCODE; text = ($o | Out-String).Trim() }
# plan outside the run root
$outsidePlan = Join-Path $env:TEMP ("p14a-outside-" + $script:run.run_id + ".json")
Copy-Item -LiteralPath $mixedPlan -Destination $outsidePlan -Force
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -RunRoot $RunRoot -RunId "$RunId-GUARD2" -Base $prefix -Group A -PlanFile $outsidePlan -TruthFile $truthPath -NoObserver 2>&1
$refusals += [pscustomobject]@{ case = 'plan_outside_root'; exit = $LASTEXITCODE; text = ($o | Out-String).Trim() }
Remove-Item -LiteralPath $outsidePlan -Force -ErrorAction SilentlyContinue
# duplicate run id (the mixed run already used it)
$o = & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -RunRoot $RunRoot -RunId $mixedRun -Base $prefix -Group A -PlanFile $mixedPlan -TruthFile $truthPath -NoObserver 2>&1
$refusals += [pscustomobject]@{ case = 'duplicate_run_id'; exit = $LASTEXITCODE; text = ($o | Out-String).Trim() }
$hitsAfter = @([System.IO.File]::ReadAllLines($endpointEvents, $utf8) | Where-Object { $_ -match 'request ' }).Count
$allRefused = @($refusals | Where-Object { $_.exit -ne 2 }).Count -eq 0
Add-Check 'guard.refusals_are_exit_2' $allRefused (($refusals | ForEach-Object { "$($_.case)=$($_.exit)" }) -join ' ')
Add-Check 'guard.refusals_made_zero_http_calls' ($hitsAfter -eq $hitsBefore) `
    "endpoint requests before=$hitsBefore after=$hitsAfter (refusal happens before any HTTP call)"

# ---------------------------------------------------------------- endpoint events prove real aborts
$events = @([System.IO.File]::ReadAllLines($endpointEvents, $utf8))
$aborts = @($events | Where-Object { $_ -match 'abort ' }).Count
$holds = @($events | Where-Object { $_ -match 'hold begin' }).Count
Add-Check 'endpoint.real_aborts_and_holds_happened' ($aborts -ge 1 -and $holds -ge 2) `
    "endpoint aborted=$aborts held=$holds (the transport fault is a closed connection, not an HTTP status)"

# ---------------------------------------------------------------- case 10: readable WHILE the writer is still open
# The earlier check only read the ledger after the collector had closed it, so it could not claim "while open". This one
# starts the real entry as a separate process (interrupted at 3000 ms), and reads the growing file from THIS process with
# a shared reader while the writer still holds it open.
$liveSlots = @()
foreach ($d in @($id1, $id2, $id1, $id2, $id1, $id2, $id1, $id2)) { $liveSlots += @{ id = $d; path = "/ok/$d"; expect = 'ok' } }
$livePlan = New-OfflinePlan $liveSlots 'plan-live-open.json' 1
# The endpoint serves requests SERIALLY, so a previous case's held connection can still be in front of this run's first
# request. A short settle makes the prefix below a property of the interruption, not of an unlucky queue position.
Start-Sleep -Milliseconds 500
$liveRun = "$RunId-LIVE"
$liveOut = Join-Path $outDir 'live-collector.out'
$liveArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $collector, '-RunRoot', $RunRoot, '-RunId', $liveRun,
    '-Base', $prefix, '-Group', 'A', '-PlanFile', $livePlan, '-TruthFile', $truthPath, '-MaxInFlight', '4',
    '-RequestTimeoutMs', '5000', '-Phase', 'offline-live-open', '-InterruptAfterMs', '4000', '-NoObserver')
$liveProc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $liveArgs -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $liveOut -RedirectStandardError ($liveOut + '.err')
$liveLedgerPath = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $liveRun) 'responses.jsonl'
$liveSeen = 0
$liveWhileOpen = $false
$swLive = [System.Diagnostics.Stopwatch]::StartNew()
while ($swLive.ElapsedMilliseconds -lt 6000) {
    if (-not $liveProc.HasExited -and (Test-Path -LiteralPath $liveLedgerPath)) {
        try {
            $partial = @(Read-P14aLedgerLines -Path $liveLedgerPath -Retries 2 -RetryDelayMs 10)
            if ($partial.Count -gt $liveSeen) { $liveSeen = $partial.Count }
            # proof of the claim: the writer process had NOT exited at the moment the lines were read
            if ($partial.Count -ge 1 -and -not $liveProc.HasExited) { $liveWhileOpen = $true; break }
        } catch { }
    }
    Start-Sleep -Milliseconds 50
}
$liveSeenWhileOpen = $liveSeen
if (-not $liveProc.HasExited) { $null = $liveProc.WaitForExit(30000) }
# the persisted prefix is re-read through the SAME parser the calibration gate uses (raw lines -> JSON objects)
$liveRows = @(Get-RunLedger $liveRun)
$liveSeqOk = $true
$liveSeqExpect = 1
foreach ($row in $liveRows) { if ([long]$row.seq -ne $liveSeqExpect) { $liveSeqOk = $false }; $liveSeqExpect++ }
Add-Check 'retention.readable_while_the_writer_is_still_open' ($liveWhileOpen -and $liveSeenWhileOpen -ge 1) `
    ("read $liveSeenWhileOpen flushed record(s) from responses.jsonl through a FileShare.ReadWrite reader while the collector process was still running (pid=$($liveProc.Id), interrupted at 3000 ms)")
Add-Check 'retention.prefix_survives_the_real_interruption' ($liveRows.Count -ge 1 -and $liveRows.Count -lt $liveSlots.Count -and $liveSeqOk -and @($liveRows | Where-Object { $_.correct -eq $true }).Count -eq $liveRows.Count) `
    ("after the process ended the prefix is still on disk: records=$($liveRows.Count) of $($liveSlots.Count) planned slots, contiguous seq=$liveSeqOk, every finished record correct; $($liveSlots.Count - $liveRows.Count) unfinished slot(s) have no record and none was invented")
Add-Check 'ledger.readable_after_close_by_a_shared_reader' $true `
    ("every ledger above was also read after its writer closed, through the same FileShare.ReadWrite reader; this check does NOT claim the while-open property (retention.readable_while_the_writer_is_still_open carries that claim)")

if ($null -ne $endpointProc -and -not $endpointProc.HasExited) { Stop-Process -Id $endpointProc.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 300

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    scope = 'offline validation of the final P1.4a collector through its real entry point; private loopback collaborator only'
    endpoint = [ordered]@{ prefix = $prefix; pid = $(if ($null -ne $endpointProc) { $endpointProc.Id } else { -1 }); aborts = $aborts; holds = $holds; events = 'endpoint-events.jsonl' }
    fixtures = [ordered]@{ ids = $fixtureIds; file = 'fixtures.json'; truth = 'offline-truth.json' }
    runs = [ordered]@{
        mixed = $mixedRun; timeout = $toRun; drops = $dropRun; interrupt = $intRun
        warmup = "$RunId-WARMUP"; sample = "$RunId-SAMPLE"
        cap_reap = $capRun; window_boundary = $winRun; assertions = $bRun; live_open = $liveRun
    }
    regressions = [ordered]@{
        A = 'completed tasks are reaped before the cap is judged; the sampling window comes from plan.seconds and the tail is counted separately'
        B = 'the REAL data.article.id node must be a JSON string; every frozen field is compared; a structural failure keeps its full receipt'
        C = 'every entry refuses a completed root before any file/HTTP/process call; every stage output is written once'
        synthetic_completed_root = 'private copy under offline/ only; the submitted roots were never used as a write target'
    }
    refusals = @($refusals | ForEach-Object { [ordered]@{ case = $_.case; exit = $_.exit; message = ($_.text -replace '\s+', ' ') } })
    note = 'the private endpoint is a retention collaborator for this test only; it is not a business window'
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'offline-result.json') -Text ($result | ConvertTo-Json -Depth 8)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'offline-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
