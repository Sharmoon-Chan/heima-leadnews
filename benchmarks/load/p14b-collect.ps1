# P1.4b collector entry: one fixed-arrival read run against ONE instance, with an INDEPENDENT resource observer
# (ASCII only).
#
# This is the only load entry of this card. It sends GET requests for existing articles and persists every response
# verbatim. It writes nothing to the database, Redis or the application.
#
# Differences from p14a-collect.ps1 (which is kept unchanged as history):
#   * resource observation is NOT done inside the collection loop. A separate observer process samples at a fixed
#     interval, writes its own CSV and its own summary, and the collector only starts it, waits for its ready marker
#     and reads that summary after the loop ended. A slow sample can therefore not delay a dispatch;
#   * every request carries the dispatcher stamp, the complete-body-available stamp, the loop-observation stamp and
#     the ledger-write stamp on one machine-wide monotonic axis (see benchmarks/lib/P14bMeasure.cs / .ps1);
#   * the legacy dispatched_ms/ended_ms/elapsed_ms fields keep their old meaning. Nothing is back-filled.
#
# Exit codes: 0 = run finished and the ledger is closed, 1 = a check/consistency assertion failed, 2 = refused.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][ValidateSet('A', 'B')][string]$Group,
    [Parameter(Mandatory = $true)][string]$PlanFile,
    [Parameter(Mandatory = $true)][string]$TruthFile,
    [int]$MaxInFlight = 16,
    [int]$RequestTimeoutMs = 5000,
    [int]$TargetPid = 0,
    [int]$IdlePid = 0,
    [int]$ObserverEveryMs = 1000,
    # PRIVATE CONTROL ONLY: make one observer sample slow, and/or stall the main loop once (both declared in the output)
    [int]$ObserverTestPauseAfterMs = 0,
    # section 8: the stall is gated on the ready marker, so it really overlaps the collection window
    [int]$ObserverTestPauseAfterReadyMs = 0,
    [int]$ObserverTestPauseMs = 0,
    [int]$TestPauseAfterStarts = 0,
    [int]$TestPauseDurationMs = 0,
    [int]$InterruptAfterMs = 0,
    [int]$SampleWindowMs = 0,
    [string]$Phase = 'sample',
    [string]$PathTemplate = '/api/v1/article/detail/{id}',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [int]$ObserverReadyTimeoutMs = 30000,
    [int]$ObserverStopTimeoutMs = 20000,
    [switch]$NoObserver
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14aRoots.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14bPaths.ps1')

function Get-Normalized([string]$p) { return [System.IO.Path]::GetFullPath($p).TrimEnd('\', '/').ToLowerInvariant() }
function Test-UnderRoot([string]$path, [string]$root) {
    $p = Get-Normalized $path; $r = Get-Normalized $root
    if ($p -eq '' -or $r -eq '') { return $false }
    return ($p -eq $r) -or $p.StartsWith($r + '\') -or $p.StartsWith($r + '/')
}
function Refuse([string]$why) { Write-Host "REFUSED: $why"; Write-Host 'REFUSED_STAGE=guard'; exit 2 }

# Parent-root lifecycle FIRST: a completed/sealed root is refused before any output, SQL, Redis, HTTP or process call.
$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'p14b-collect.ps1'
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (-not (Test-UnderRoot $PlanFile $RunRoot)) { Refuse "plan file is outside this run root: $PlanFile" }
if (-not (Test-UnderRoot $TruthFile $RunRoot)) { Refuse "truth file is outside this run root: $TruthFile" }
if (-not (Test-Path -LiteralPath $PlanFile)) { Refuse "plan file does not exist: $PlanFile" }
if (-not (Test-Path -LiteralPath $TruthFile)) { Refuse "truth file does not exist: $TruthFile" }

$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId

# ---- P1.4b section 8 part C: EVERY real output path is proven to belong to THIS active root BEFORE any directory is
# created, any assembly is compiled, any sample is taken or any process is started. RunRoot alone is not enough: a
# caller supplied -OutDir/-ReadyFile/-StopFile at another (even completed) sibling root must be refused with no side
# effect at all.
$ledgerPath = Join-Path $outDir 'responses.jsonl'
$observerDir = Join-Path $outDir 'observer'
$observerScript = Join-Path (Join-Path $benchDir 'verify') 'p14b-observer.ps1'
$readyFile = Join-Path $observerDir 'observer-ready.txt'
$stopFile = Join-Path $observerDir 'observer-stop.txt'
$obsOut = Join-Path $observerDir 'observer.stdout.txt'
$observerSummaryPath = Join-Path $observerDir 'observer-summary.json'
$assemblyPath = Join-Path (Join-Path $outDir 'assembly') 'P14bMeasure.dll'
try {
    $null = Assert-P14bOwnedPath -Path $outDir -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'collect run directory'
    $null = Assert-P14bOwnedPath -Path $ledgerPath -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'collect ledger'
    $null = Assert-P14bOwnedPath -Path $observerDir -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'observer OutDir'
    $null = Assert-P14bOwnedPath -Path $readyFile -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'observer ReadyFile'
    $null = Assert-P14bOwnedPath -Path $stopFile -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'observer StopFile'
    $null = Assert-P14bOwnedPath -Path $obsOut -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'observer stdout capture'
    $null = Assert-P14bOwnedPath -Path $observerSummaryPath -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'observer summary'
    $null = Assert-P14bOwnedPath -Path $assemblyPath -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'measurement assembly output'
} catch {
    Refuse $_.Exception.Message
}
$script:run = $null
$script:obsProc = $null
trap {
    if ($null -ne $script:obsProc -and -not $script:obsProc.HasExited) { Stop-Process -Id $script:obsProc.Id -Force -ErrorAction SilentlyContinue }
    exit (Save-RunFailure -State $script:run -ErrorRecord $_)
}
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage ("P1.4b-collect-" + $Phase) `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ base = $Base; group = $Group; plan = (Split-Path -Leaf $PlanFile); max_in_flight = $MaxInFlight; request_timeout_ms = $RequestTimeoutMs; target_pid = $TargetPid; idle_pid = $IdlePid; phase = $Phase; observer = (-not $NoObserver) } `
        -Targets @() -DataSet 'leadnews_article_p1'
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$plan = New-P14aPlan -PlanFile $PlanFile
$truth = Get-P14aTruth -TruthFile $TruthFile
Add-Type -AssemblyName System.Net.Http | Out-Null
[System.Net.ServicePointManager]::DefaultConnectionLimit = [Math]::Max(16, $MaxInFlight)
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$handler.MaxConnectionsPerServer = [Math]::Max(16, $MaxInFlight)
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromMilliseconds($RequestTimeoutMs + 15000)

$ledger = New-P14aResponseLedger -Path $ledgerPath -RunId $RunId

# ---- P1.4b section 8 part D: build the PERSISTENT measurement assembly and load exactly that file -----------------
# The body-ready stamp lives in this DLL. It is compiled into the run root, hashed, and loaded from that path, so the
# run can name its actual measurement artifact instead of only the .cs source hash.
$assemblyInfo = Build-P14bMeasureAssembly -OutputAssembly $assemblyPath
Write-Host ("measurement_assembly={0} sha256={1} bytes={2} source_sha={3}" -f $assemblyInfo.path, $assemblyInfo.sha256, $assemblyInfo.bytes, $assemblyInfo.source_sha256)

# ---- start the independent observer BEFORE the first dispatch ---------------------------------------------------
$observerPid = 0
$observerStarted = $false
$observerProblem = ''
if (-not $NoObserver) {
    if (-not (Test-Path -LiteralPath $observerScript)) { throw "the observer entry is missing: $observerScript" }
    $null = New-Item -ItemType Directory -Path $observerDir -Force
    $obsArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $observerScript,
        '-RunRoot', $RunRoot, '-Tag', $RunId, '-OutDir', $observerDir, '-CollectorPid', "$PID",
        '-TargetPid', "$TargetPid", '-IdlePid', "$IdlePid", '-IntervalMs', "$ObserverEveryMs",
        '-StopFile', $stopFile, '-ReadyFile', $readyFile, '-ArtifactsRoot', $ArtifactsRoot)
    if ($ObserverTestPauseMs -gt 0) { $obsArgs += @('-TestPauseAfterMs', "$ObserverTestPauseAfterMs", '-TestPauseAfterReadyMs', "$ObserverTestPauseAfterReadyMs", '-TestPauseMs', "$ObserverTestPauseMs") }
    $script:obsProc = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $obsArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $obsOut -RedirectStandardError ($obsOut + '.err')
    $observerPid = [int]$script:obsProc.Id
    $swReady = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $readyFile) -and $swReady.ElapsedMilliseconds -lt $ObserverReadyTimeoutMs -and -not $script:obsProc.HasExited) {
        Start-Sleep -Milliseconds 25
    }
    $observerStarted = Test-Path -LiteralPath $readyFile
    if (-not $observerStarted) {
        $observerProblem = "the observer did not become ready within $ObserverReadyTimeoutMs ms (pid=$observerPid)"
        Write-Host "WARNING: $observerProblem"
    }
}

$startedLocal = Get-Date
$stats = Invoke-P14aCollection -Client $client -Base $Base -Plan $plan -Ledger $ledger -RunId $RunId -Group $Group `
    -Truth $truth -PathTemplate $PathTemplate -MaxInFlight $MaxInFlight -RequestTimeoutMs $RequestTimeoutMs `
    -TargetPid $TargetPid -IdlePid $IdlePid -ObserverPid $observerPid -ObserverSummary $observerSummaryPath `
    -ResourceEveryMs $ObserverEveryMs -InterruptAfterMs $InterruptAfterMs -SampleWindowMs $SampleWindowMs `
    -TestPauseAfterStarts $TestPauseAfterStarts -TestPauseDurationMs $TestPauseDurationMs
$ledger.Close()
$client.Dispose()

# ---- stop the observer and read ITS OWN summary ------------------------------------------------------------------
$observerBlock = [ordered]@{ enabled = (-not $NoObserver); pid = $observerPid; ready = $observerStarted; problem = $observerProblem }
if (-not $NoObserver -and $observerPid -gt 0) {
    $null = [System.IO.File]::WriteAllText($stopFile, 'stop', $utf8)
    $swStop = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $script:obsProc.HasExited -and $swStop.ElapsedMilliseconds -lt $ObserverStopTimeoutMs) { Start-Sleep -Milliseconds 50 }
    $observerBlock['stopped'] = $script:obsProc.HasExited
    if (-not $script:obsProc.HasExited) {
        Stop-Process -Id $observerPid -Force -ErrorAction SilentlyContinue
        $observerBlock['forced_stop'] = $true
    }
    if (Test-Path -LiteralPath $observerSummaryPath) {
        $obs = Get-Content -LiteralPath $observerSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $observerBlock['summary'] = 'observer/observer-summary.json'
        $observerBlock['summary_sha256'] = (Get-FileHash -LiteralPath $observerSummaryPath -Algorithm SHA256).Hash.ToLower()
        $observerBlock['samples'] = [int]$obs.samples
        $observerBlock['interval_ms'] = [int]$obs.interval_ms
        $observerBlock['gap_max_ms'] = $obs.gaps.max_ms
        $observerBlock['gaps_over_interval'] = $obs.gaps.over_interval_ms
        $observerBlock['sample_cost_max_ms'] = $obs.sample_cost_ms.max
        $observerBlock['sample_cost_mean_ms'] = $obs.sample_cost_ms.mean
        $observerBlock['pids_not_found'] = $obs.pids_not_found
        $observerBlock['private_control'] = $obs.private_control
        $observerBlock['csv'] = 'observer/resources.csv'
        $observerBlock['observer_pid_from_summary'] = [int]$obs.observer_pid
        $observerBlock['target_pid_from_summary'] = [int]$obs.target_pid
        $observerBlock['collector_pid_from_summary'] = [int]$obs.collector_pid
        $observerBlock['pid_identity_matches'] = ([int]$obs.observer_pid -eq $observerPid) -and ([int]$obs.collector_pid -eq $PID)
    } else {
        $observerBlock['summary'] = 'MISSING'
        $observerBlock['problem'] = 'the observer produced no summary; its resource data is NOT available for this run'
    }
}
$script:obsProc = $null

$ledgerHash = (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash.ToLower()
$lines = @(Read-P14aLedgerLines -Path $ledgerPath)
$result = [ordered]@{
    run_id = $RunId
    phase = $Phase
    group = $Group
    base = $Base
    started_local = $startedLocal.ToString('yyyy-MM-ddTHH:mm:sszzz')
    finished_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    plan = [ordered]@{ file = (Split-Path -Leaf $PlanFile); sha256 = (Get-FileHash -LiteralPath $PlanFile -Algorithm SHA256).Hash.ToLower(); kind = $plan.kind; rate_per_second = $plan.rate_per_second; slot_count = @($plan.slots).Count }
    truth = [ordered]@{ file = (Split-Path -Leaf $TruthFile); sha256 = (Get-FileHash -LiteralPath $TruthFile -Algorithm SHA256).Hash.ToLower(); targets = $truth.Count }
    limits = [ordered]@{ max_in_flight = $MaxInFlight; request_timeout_ms = $RequestTimeoutMs; slice_ms = 1; observer_every_ms = $ObserverEveryMs; declared_window_ms = $stats.declared_window_ms; window_source = $stats.window_source }
    pids = [ordered]@{ collector = $PID; observer = $observerPid; target = $TargetPid; idle = $IdlePid }
    observer = $observerBlock
    ledger = [ordered]@{ path = 'responses.jsonl'; sha256 = $ledgerHash; lines = $lines.Count }
    stats = $stats
    script = [ordered]@{ path = $PSCommandPath; sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLower() }
    collector_lib = [ordered]@{ path = (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1'); sha256 = (Get-FileHash -LiteralPath (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1') -Algorithm SHA256).Hash.ToLower() }
    measure_lib = [ordered]@{
        ps1 = [ordered]@{ path = (Join-Path (Join-Path $benchDir 'lib') 'P14bMeasure.ps1'); sha256 = (Get-FileHash -LiteralPath (Join-Path (Join-Path $benchDir 'lib') 'P14bMeasure.ps1') -Algorithm SHA256).Hash.ToLower() }
        cs = [ordered]@{ path = (Join-Path (Join-Path $benchDir 'lib') 'P14bMeasure.cs'); sha256 = (Get-FileHash -LiteralPath (Join-Path (Join-Path $benchDir 'lib') 'P14bMeasure.cs') -Algorithm SHA256).Hash.ToLower() }
        # section 8 part D: the ACTUAL compiled measurement artifact this run loaded, hashed after compilation
        assembly = [ordered]@{
            path = ('assembly/' + (Split-Path -Leaf $assemblyInfo.path))
            absolute_path = $assemblyInfo.path
            sha256 = $assemblyInfo.sha256
            bytes = $assemblyInfo.bytes
            loaded_from_that_file = [bool]$assemblyInfo.loaded
            source_sha256 = $assemblyInfo.source_sha256
            compiler = 'Add-Type (in-box CSharp code provider of Windows PowerShell)'
            note = 'the body-ready stamp is produced by this DLL, loaded from the recorded path; the source hash alone was not evidence of the actual artifact'
        }
    }
}
$null = Write-P14aOnce -Path (Join-Path $outDir 'collect-result.json') -Text ($result | ConvertTo-Json -Depth 8) -EntryPoint 'p14b-collect.ps1'

$okRecon = $stats.offered_equals_started_plus_dropped
$okDrain = ($stats.interrupted -or $stats.started_equals_completed)
$okLedger = ($lines.Count -eq $stats.ledger_records)
Add-RunCheck -State $script:run -Name 'collector.offered_equals_started_plus_dropped' -Status $(if ($okRecon) { 'pass' } else { 'fail' }) `
    -Detail ("offered={0} started={1} dropped={2}" -f $stats.offered, $stats.started, $stats.dropped)
Add-RunCheck -State $script:run -Name 'collector.started_equals_completed_after_drain' -Status $(if ($okDrain) { 'pass' } else { 'fail' }) `
    -Detail ("started={0} completed={1} interrupted={2} inflight_at_end={3} drainMs={4}" -f $stats.started, $stats.completed, $stats.interrupted, $stats.inflight_at_end, $stats.drain_ms)
Add-RunCheck -State $script:run -Name 'collector.ledger_lines_match_records' -Status $(if ($okLedger) { 'pass' } else { 'fail' }) `
    -Detail ("ledger lines={0} records={1}" -f $lines.Count, $stats.ledger_records)
$okWindow = [bool]$stats.window_counts_add_up
Add-RunCheck -State $script:run -Name 'collector.window_and_tail_are_counted_separately' -Status $(if ($okWindow) { 'pass' } else { 'fail' }) `
    -Detail ("declared_window_ms={0} source={1} in_window={2} after_window={3} total={4}" -f $stats.declared_window_ms, $stats.window_source, $stats.completed_in_window, $stats.completed_after_window, $stats.completed)
$okDropClass = ([int]$stats.dropped_cap_full + [int]$stats.dropped_scheduler_missed -eq [int]$stats.dropped)
Add-RunCheck -State $script:run -Name 'collector.drops_are_classified' -Status $(if ($okDropClass) { 'pass' } else { 'fail' }) `
    -Detail ("dropped={0} cap_full={1} scheduler_missed={2}" -f $stats.dropped, $stats.dropped_cap_full, $stats.dropped_scheduler_missed)
# P1.4b: the new timing populations must be internally consistent for this run
$okBodyPop = [bool]$stats.body_latency_population_consistent
Add-RunCheck -State $script:run -Name 'timing.body_latency_population_is_consistent' -Status $(if ($okBodyPop) { 'pass' } else { 'fail' }) `
    -Detail ("correct={0} body_latency_correct={1} completed={2} body_latency_all={3} body_ready_missing={4} ({5})" -f $stats.correct, $stats.body_latency_correct_ms.count, $stats.completed, $stats.body_latency_ms.count, $stats.body_ready_missing, (($stats.body_ready_missing_reasons.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ','))
$okAxis = ([double]$stats.monotonic.mono_vs_legacy_run_delta_ms -lt 20.0)
Add-RunCheck -State $script:run -Name 'timing.one_monotonic_axis' -Status $(if ($okAxis) { 'pass' } else { 'fail' }) `
    -Detail ("run elapsed measured twice: Stopwatch {0} ms, monotonic axis {1} ms -> |delta|={2} ms (budget 20 ms); the per-record legacy-vs-helper gap max was {3} ms, which is the PowerShell->.NET call overhead, not an axis difference" -f $stats.run_elapsed_ms, $stats.monotonic.mono_elapsed_ms, $stats.monotonic.mono_vs_legacy_run_delta_ms, $stats.monotonic.legacy_vs_mono_max_delta_ms)
$okObserver = $true
$obsDetail = 'observer disabled for this run'
if (-not $NoObserver) {
    $okObserver = [bool]$observerStarted -and ($observerBlock['summary'] -ne 'MISSING') -and [bool]$observerBlock['pid_identity_matches']
    $obsDetail = ("observer pid={0} ready={1} stopped={2} samples={3} interval={4}ms gap_max={5}ms over_interval={6} sample_cost_max={7}ms summary={8}" -f `
            $observerPid, $observerStarted, $observerBlock['stopped'], $observerBlock['samples'], $observerBlock['interval_ms'], $observerBlock['gap_max_ms'], $observerBlock['gaps_over_interval'], $observerBlock['sample_cost_max_ms'], $observerBlock['summary'])
}
Add-RunCheck -State $script:run -Name 'observer.lifecycle_and_identity' -Status $(if ($okObserver) { 'pass' } else { 'fail' }) -Detail $obsDetail
# P1.4b section 8: the BODY-READY window population and the stamp integrity, plus the actual measurement artifact
$okBodyWin = ([bool]$stats.window_body_adds_up -and [bool]$stats.body_window_consistent)
Add-RunCheck -State $script:run -Name 'timing.body_window_and_stamps_are_consistent' -Status $(if ($okBodyWin) { 'pass' } else { 'fail' }) `
    -Detail ("body window in={0} after={1} population={2} excluded_no_body={3} stamp_defects={4} add_up={5}; legacy observation window in={6} after={7} (they may legitimately differ)" -f $stats.window_body.in_window, $stats.window_body.after_window, $stats.window_body.population, $stats.body_ready_missing, $stats.body_stamp_defects, $stats.window_body_adds_up, $stats.completed_in_window, $stats.completed_after_window)
$okAsm = ($assemblyInfo.ok -and $assemblyInfo.loaded -and [string]$assemblyInfo.sha256 -ne '' -and (Test-Path -LiteralPath $assemblyInfo.path))
Add-RunCheck -State $script:run -Name 'measurement.assembly_is_persisted_hashed_and_loaded' -Status $(if ($okAsm) { 'pass' } else { 'fail' }) `
    -Detail ("assembly={0} sha256={1} bytes={2} loaded_from_file={3} source_sha256={4}" -f $assemblyInfo.path, $assemblyInfo.sha256, $assemblyInfo.bytes, $assemblyInfo.loaded, $assemblyInfo.source_sha256)
$ok = $okRecon -and $okDrain -and $okLedger -and $okWindow -and $okDropClass -and $okBodyPop -and $okAxis -and $okObserver -and $okBodyWin -and $okAsm
Write-Host ("run_id={0} group={1} offered={2} started={3} completed={4} dropped={5} correct={6} failures={7} timeouts={8} ledger_lines={9}" -f `
    $RunId, $Group, $stats.offered, $stats.started, $stats.completed, $stats.dropped, $stats.correct, $stats.failures, $stats.timeouts, $lines.Count)
Write-Host ("body_latency_ms p50={0} p95={1} p99={2} max={3} | observe_lag p95={4} max={5} | legacy latency p95={6} | dispatch lag p95={7} max={8}" -f `
    $stats.body_latency_ms.p50, $stats.body_latency_ms.p95, $stats.body_latency_ms.p99, $stats.body_latency_ms.max,
    $stats.observe_lag_ms.p95, $stats.observe_lag_ms.max, $stats.latency_correct_ms.p95,
    $stats.dispatch_schedule_lag_mono_ms.p95, $stats.dispatch_schedule_lag_mono_ms.max)
exit (Set-RunStatus -State $script:run -Status $(if ($ok) { 'passed' } else { 'failed' }))
