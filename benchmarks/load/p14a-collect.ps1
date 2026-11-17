# P1.4a collector entry: one fixed-arrival read run against ONE instance (ASCII only).
#
# This is the ONLY load entry of this card. It performs no writes to the database, no Redis command and no
# application change; it sends GET requests for existing articles and persists every response verbatim.
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
    [int]$ResourceEveryMs = 1000,
    [int]$InterruptAfterMs = 0,
    [int]$SampleWindowMs = 0,
    [int]$TestPauseAfterStarts = 0,
    [int]$TestPauseDurationMs = 0,
    [string]$Phase = 'sample',
    [string]$PathTemplate = '/api/v1/article/detail/{id}',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [switch]$NoResources
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14aRoots.ps1')

function Get-Normalized([string]$p) { return [System.IO.Path]::GetFullPath($p).TrimEnd('\', '/').ToLowerInvariant() }
function Test-UnderRoot([string]$path, [string]$root) {
    $p = Get-Normalized $path; $r = Get-Normalized $root
    if ($p -eq '' -or $r -eq '') { return $false }
    return ($p -eq $r) -or $p.StartsWith($r + '\') -or $p.StartsWith($r + '/')
}
function Refuse([string]$why) { Write-Host "REFUSED: $why"; Write-Host 'REFUSED_STAGE=guard'; exit 2 }

# Parent-root lifecycle FIRST: a completed/sealed P1.4a root is refused before any output, SQL, Redis, HTTP or
# process call. A sub-run directory guard cannot substitute for the parent experiment-root guard.
$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'p14a-collect.ps1'
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (-not (Test-UnderRoot $PlanFile $RunRoot)) { Refuse "plan file is outside this run root: $PlanFile" }
if (-not (Test-UnderRoot $TruthFile $RunRoot)) { Refuse "truth file is outside this run root: $TruthFile" }
if (-not (Test-Path -LiteralPath $PlanFile)) { Refuse "plan file does not exist: $PlanFile" }
if (-not (Test-Path -LiteralPath $TruthFile)) { Refuse "truth file does not exist: $TruthFile" }

$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage ("P1.4a-collect-" + $Phase) `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ base = $Base; group = $Group; plan = (Split-Path -Leaf $PlanFile); max_in_flight = $MaxInFlight; request_timeout_ms = $RequestTimeoutMs; target_pid = $TargetPid; idle_pid = $IdlePid; phase = $Phase; interrupt_after_ms = $InterruptAfterMs } `
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
# the per-request token owns the timeout; the client-level timeout is only a backstop
$client.Timeout = [TimeSpan]::FromMilliseconds($RequestTimeoutMs + 15000)

$ledgerPath = Join-Path $outDir 'responses.jsonl'
$ledger = New-P14aResponseLedger -Path $ledgerPath -RunId $RunId
$resourcePath = if ($NoResources) { '' } else { Join-Path $outDir 'resources.csv' }

$startedLocal = Get-Date
$stats = Invoke-P14aCollection -Client $client -Base $Base -Plan $plan -Ledger $ledger -RunId $RunId -Group $Group `
    -Truth $truth -PathTemplate $PathTemplate -MaxInFlight $MaxInFlight -RequestTimeoutMs $RequestTimeoutMs `
    -TargetPid $TargetPid -IdlePid $IdlePid -ResourceEveryMs $ResourceEveryMs -ResourcePath $resourcePath -InterruptAfterMs $InterruptAfterMs -SampleWindowMs $SampleWindowMs `
    -TestPauseAfterStarts $TestPauseAfterStarts -TestPauseDurationMs $TestPauseDurationMs
$ledger.Close()
$client.Dispose()

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
    limits = [ordered]@{ max_in_flight = $MaxInFlight; request_timeout_ms = $RequestTimeoutMs; slice_ms = 1; resource_every_ms = $ResourceEveryMs; declared_window_ms = $stats.declared_window_ms; window_source = $stats.window_source }
    target_pid = $TargetPid
    resources = $resourcePath
    ledger = [ordered]@{ path = 'responses.jsonl'; sha256 = $ledgerHash; lines = $lines.Count }
    stats = $stats
    script = [ordered]@{ path = $PSCommandPath; sha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLower() }
    collector_lib = [ordered]@{ path = (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1'); sha256 = (Get-FileHash -LiteralPath (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1') -Algorithm SHA256).Hash.ToLower() }
}
$null = Write-P14aOnce -Path (Join-Path $outDir 'collect-result.json') -Text ($result | ConvertTo-Json -Depth 8) -EntryPoint 'p14a-collect.ps1'

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
$ok = $okRecon -and $okDrain -and $okLedger -and $okWindow -and $okDropClass
Write-Host ("run_id={0} group={1} offered={2} started={3} completed={4} dropped={5} correct={6} failures={7} timeouts={8} ledger_lines={9}" -f `
    $RunId, $Group, $stats.offered, $stats.started, $stats.completed, $stats.dropped, $stats.correct, $stats.failures, $stats.timeouts, $lines.Count)
Write-Host ("reconciliation offered=started+dropped:{0} started=completed:{1} ledger_lines=stats_records:{2}" -f `
    $stats.offered_equals_started_plus_dropped, $stats.started_equals_completed, ($lines.Count -eq $stats.ledger_records))
exit (Set-RunStatus -State $script:run -Status $(if ($ok) { 'passed' } else { 'failed' }))
