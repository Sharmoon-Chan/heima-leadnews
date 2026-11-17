# P1.4b resource observer: samples process resources OUTSIDE the collector's dispatch/reap loop (ASCII only).
#
# Why a separate process: in P1.4a the collector sampled resources inside its own loop, and a sample cost 166-254 ms,
# so every sample blocked dispatch. Here the sample happens in an independent process with its own PID, and the
# collector only starts it, waits for its ready marker, and reads its summary after the loop ended. The loop never
# waits for a sample or a resource write.
#
# The observer reports, honestly, its own sampling cost and any gap it could not cover (a slow sample, a scheduler
# stall): gaps are recorded as gaps, never filled with a previous value and never silently dropped.
#
# All timestamps are System.Diagnostics.Stopwatch.GetTimestamp() / Stopwatch.Frequency, the same machine-wide
# monotonic axis the collector uses for dispatch / body-ready / observation / persist.
#
# Exit codes: 0 = sampled to completion, 2 = refused (guard / usage), 1 = the observer could not run.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$OutDir = '',
    [int]$CollectorPid = 0,
    [int]$TargetPid = 0,
    [int]$IdlePid = 0,
    [int]$IntervalMs = 1000,
    [int]$DurationMs = 0,
    [string]$StopFile = '',
    [string]$ReadyFile = '',
    # PRIVATE CONTROL ONLY (0 = disabled). The stall is injected AFTER the ready marker, i.e. while the collector is
    # already measuring, and only once -TestPauseAfterReadyMs has elapsed since that marker. `-TestPauseAfterMs` is the
    # legacy knob kept for the earlier callers; when it is set the later of the two conditions wins, so a stall can no
    # longer happen during start-up and be mistaken for an in-window stall.
    [int]$TestPauseAfterMs = 0,
    [int]$TestPauseAfterReadyMs = 0,
    [int]$TestPauseMs = 0,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts'
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $benchDir 'lib') 'P14aRoots.ps1')
. (Join-Path (Join-Path $benchDir 'lib') 'P14bPaths.ps1')

function Refuse([string]$why) {
    Write-Host "REFUSED: $why"
    Write-Host 'REFUSED_STAGE=guard'
    exit 2
}
function Get-MonoMs([AllowNull()]$Ticks) {
    $t = if ($null -eq $Ticks) { [System.Diagnostics.Stopwatch]::GetTimestamp() } else { [long]$Ticks }
    return [Math]::Round(($t * 1000.0) / [System.Diagnostics.Stopwatch]::Frequency, 3)
}

# Parent-root lifecycle FIRST: nothing is created or sampled against a completed root.
$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'p14b-observer.ps1'
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
if ($OutDir -eq '') { $OutDir = Join-Path (Join-Path $RunRoot 'resources') $Tag }

# ---- P1.4b section 8 part C: EVERY real output path of this entry is proven to belong to THIS active root before
# anything is created, sampled or written. A caller supplied -OutDir/-ReadyFile/-StopFile at another (even completed)
# sibling root used to be accepted here, which created three files outside the root.
try {
    $OutDir = Assert-P14bOwnedPath -Path $OutDir -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'observer OutDir'
    if ($ReadyFile -ne '') { $ReadyFile = Assert-P14bOwnedPath -Path $ReadyFile -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'observer ReadyFile' }
    if ($StopFile -ne '') { $StopFile = Assert-P14bOwnedPath -Path $StopFile -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'observer StopFile' }
} catch {
    Refuse $_.Exception.Message
}
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$csvPath = Assert-P14bOwnedPath -Path (Join-Path $OutDir 'resources.csv') -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'observer resources.csv'
$sumPath = Assert-P14bOwnedPath -Path (Join-Path $OutDir 'observer-summary.json') -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -Label 'observer summary'
foreach ($p in @($csvPath, $sumPath)) {
    if (Test-Path -LiteralPath $p) { Refuse "observer output already exists (write once): $p" }
}

$freq = [System.Diagnostics.Stopwatch]::Frequency
$cores = [Environment]::ProcessorCount
$ownPid = $PID

function Get-ProcState([int]$id) {
    $st = [ordered]@{ found = $false; cpu_total_ms = [long]-1; working_set_mb = -1.0; threads = -1; name = '' }
    if ($id -le 0) { return $st }
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $st }
    $st.found = $true
    $st.name = [string]$p.ProcessName
    try { $st.cpu_total_ms = [long]$p.TotalProcessorTime.TotalMilliseconds } catch { $st.cpu_total_ms = [long]-1 }
    try { $st.working_set_mb = [Math]::Round($p.WorkingSet64 / 1MB, 1) } catch { }
    try { $st.threads = $p.Threads.Count } catch { }
    return $st
}

$writer = New-Object System.IO.StreamWriter($csvPath, $false, $utf8)
$writer.WriteLine('local_time,mono_ms,sample_seq,gap_ms,sample_duration_ms,observer_pid,observer_cpu_total_ms,observer_cpu_percent,observer_working_set_mb,observer_threads,target_pid,target_found,target_cpu_total_ms,target_cpu_percent,target_working_set_mb,target_threads,collector_pid,collector_found,collector_cpu_total_ms,collector_cpu_percent,collector_working_set_mb,collector_threads,idle_pid,idle_found,idle_cpu_total_ms,logical_cores,target_core_equivalents,collector_core_equivalents,observer_core_equivalents,note')
$writer.Flush()

$startedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
$startedMono = Get-MonoMs $startedTicks
# The ready marker is written AFTER the first sample completes, so the observer's start-up and first-sample cost are
# never inside the measured window (and the collector only dispatches once the observer is already sampling).


$readyWritten = $false
$readyMono = [double]-1
$seq = 0
$prevMono = $null
$prevCpu = @{ target = [long]-1; collector = [long]-1; observer = [long]-1 }
$gaps = New-Object System.Collections.ArrayList
$costs = New-Object System.Collections.ArrayList
$missing = @{ target = 0; collector = 0; idle = 0 }
$pauseApplied = $false
$pauseAtMono = [double]-1
$pauseEndMono = [double]-1
$pauseSeq = -1
$pauseEndSeq = -1
$notes = New-Object System.Collections.ArrayList
$maxGap = 0.0
$maxCost = 0.0
$nextDueMono = $startedMono + $IntervalMs

try {
    while ($true) {
        $nowTicks = [System.Diagnostics.Stopwatch]::GetTimestamp()
        $nowMono = Get-MonoMs $nowTicks
        if ($DurationMs -gt 0 -and ($nowMono - $startedMono) -ge $DurationMs) { break }
        if ($StopFile -ne '' -and (Test-Path -LiteralPath $StopFile)) { break }
        if ($nowMono -lt $nextDueMono) {
            $wait = $nextDueMono - $nowMono
            if ($wait -gt 1) { [System.Threading.Thread]::Sleep([int][Math]::Floor($wait)) }
            continue
        }
        $seq++
        $costStart = [System.Diagnostics.Stopwatch]::GetTimestamp()
        $gap = if ($null -eq $prevMono) { 0.0 } else { [Math]::Round($nowMono - $prevMono, 3) }
        if ($null -ne $prevMono) {
            $null = $gaps.Add($gap)
            if ($gap -gt $maxGap) { $maxGap = $gap }
        }
        $obs = Get-ProcState $ownPid
        $tgt = Get-ProcState $TargetPid
        $col = Get-ProcState $CollectorPid
        $idl = Get-ProcState $IdlePid
        if ($TargetPid -gt 0 -and -not $tgt.found) { $missing.target++ }
        if ($CollectorPid -gt 0 -and -not $col.found) { $missing.collector++ }
        if ($IdlePid -gt 0 -and -not $idl.found) { $missing.idle++ }
        # machine-normalized percent over the ACTUAL interval since the previous sample (never assumed to be 1 s)
        $span = if ($null -eq $prevMono) { [double]$IntervalMs } else { [Math]::Max([double]1, $gap) }
        $tpct = -1; $cpct = -1; $opct = -1; $tcore = -1; $ccore = -1; $ocore = -1
        if ($prevCpu.target -ge 0 -and $tgt.cpu_total_ms -ge 0) {
            $tpct = [Math]::Round((($tgt.cpu_total_ms - $prevCpu.target) / $span) * 100.0 / [double]$cores, 2)
            $tcore = [Math]::Round($tpct * $cores / 100.0, 3)
        }
        if ($prevCpu.collector -ge 0 -and $col.cpu_total_ms -ge 0) {
            $cpct = [Math]::Round((($col.cpu_total_ms - $prevCpu.collector) / $span) * 100.0 / [double]$cores, 2)
            $ccore = [Math]::Round($cpct * $cores / 100.0, 3)
        }
        if ($prevCpu.observer -ge 0 -and $obs.cpu_total_ms -ge 0) {
            $opct = [Math]::Round((($obs.cpu_total_ms - $prevCpu.observer) / $span) * 100.0 / [double]$cores, 2)
            $ocore = [Math]::Round($opct * $cores / 100.0, 3)
        }
        $prevCpu.target = $tgt.cpu_total_ms; $prevCpu.collector = $col.cpu_total_ms; $prevCpu.observer = $obs.cpu_total_ms
        $note = ''
        if ($TargetPid -gt 0 -and -not $tgt.found) { $note = "target pid $TargetPid not found" }
        if ($CollectorPid -gt 0 -and -not $col.found) { $note = ("$note collector pid $CollectorPid not found").Trim() }
        # PRIVATE CONTROL: make THIS sample expensive on purpose, exactly once, and ONLY after the ready marker has
        # been written (i.e. while the collector is already measuring). The row's sample cost includes the stall, so the
        # observer never reports a cheap sample that was actually slow. The exact interval is recorded so the caller can
        # assert a real time intersection with the collection window instead of trusting a boolean.
        $pauseGateOpen = $readyWritten -and ($readyMono -gt 0) -and (($nowMono - $readyMono) -ge $TestPauseAfterReadyMs) -and (($nowMono - $startedMono) -ge $TestPauseAfterMs)
        if ($TestPauseMs -gt 0 -and -not $pauseApplied -and $pauseGateOpen) {
            $pauseApplied = $true
            $pauseAtMono = $nowMono
            $pauseSeq = $seq
            [System.Threading.Thread]::Sleep($TestPauseMs)
            $pauseEndMono = Get-MonoMs ([System.Diagnostics.Stopwatch]::GetTimestamp())
            $pauseEndSeq = $seq
            $null = $notes.Add(("private control: sample #{0} was made slow by sleeping {1} ms, starting {2} ms after ready and {3} ms after observer start" -f $seq, $TestPauseMs, [Math]::Round($nowMono - $readyMono, 3), [Math]::Round($nowMono - $startedMono, 3)))
        }
        $cost = [Math]::Round((Get-MonoMs ([System.Diagnostics.Stopwatch]::GetTimestamp())) - $nowMono, 3)
        $row = @(
            ([DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ss.fff')), $nowMono, $seq, $gap, $cost,
            $ownPid, $obs.cpu_total_ms, $opct, $obs.working_set_mb, $obs.threads,
            $TargetPid, $tgt.found, $tgt.cpu_total_ms, $tpct, $tgt.working_set_mb, $tgt.threads,
            $CollectorPid, $col.found, $col.cpu_total_ms, $cpct, $col.working_set_mb, $col.threads,
            $IdlePid, $idl.found, $idl.cpu_total_ms, $cores, $tcore, $ccore, $ocore, ('"' + ($note -replace '"', '""') + '"')
        )
        $writer.WriteLine(($row -join ','))
        $writer.Flush()
        $null = $costs.Add($cost)
        if ($cost -gt $maxCost) { $maxCost = $cost }
        $prevMono = $nowMono
        if (-not $readyWritten -and $ReadyFile -ne '') {
            [System.IO.File]::WriteAllText($ReadyFile, ("$ownPid`r`n"), $utf8)
            $readyWritten = $true
            $readyMono = Get-MonoMs ([System.Diagnostics.Stopwatch]::GetTimestamp())
            $readySeq = $seq
        }
        # the next sample is due one interval after the END of this one, so a slow sample shows up as a real gap
        $afterMono = Get-MonoMs ([System.Diagnostics.Stopwatch]::GetTimestamp())
        $nextDueMono = $afterMono + $IntervalMs
    }
} finally {
    try { $writer.Flush(); $writer.Dispose() } catch { }
}

$finishedMono = Get-MonoMs ([System.Diagnostics.Stopwatch]::GetTimestamp())
$summary = [ordered]@{
    tag = $Tag
    scope = 'P1.4b resource observer: samples processes from its OWN process so the collector loop never waits for it'
    observer_pid = $ownPid
    collector_pid = $CollectorPid
    target_pid = $TargetPid
    idle_pid = $IdlePid
    interval_ms = $IntervalMs
    samples = $seq
    started_mono_ms = $startedMono
    finished_mono_ms = $finishedMono
    elapsed_ms = [Math]::Round($finishedMono - $startedMono, 3)
    monotonic = [ordered]@{ source = 'System.Diagnostics.Stopwatch.GetTimestamp() / Stopwatch.Frequency'; frequency = $freq }
    logical_cores = $cores
    gaps = [ordered]@{
        count = $gaps.Count
        max_ms = [Math]::Round($maxGap, 3)
        median_ms = $(if ($gaps.Count -gt 0) { [Math]::Round((@($gaps | Sort-Object))[[int][Math]::Floor($gaps.Count / 2)], 3) } else { -1 })
        over_interval_ms = @($gaps | Where-Object { $_ -gt ($IntervalMs * 1.5) }).Count
        note = 'a gap larger than 1.5x the interval is a sample this observer could NOT take in time; it is reported, never filled with a previous value'
    }
    sample_cost_ms = [ordered]@{
        max = [Math]::Round($maxCost, 3)
        mean = $(if ($costs.Count -gt 0) { [Math]::Round((($costs | Measure-Object -Average).Average), 3) } else { -1 })
        note = 'cost of ONE sample as measured inside the observer; it can no longer block dispatch because dispatch runs elsewhere'
    }
    pids_not_found = $missing
    private_control = [ordered]@{
        pause_applied = $pauseApplied
        pause_at_mono_ms = $pauseAtMono
        pause_end_mono_ms = $pauseEndMono
        pause_ms = $(if ($pauseApplied) { [Math]::Round($pauseEndMono - $pauseAtMono, 3) } else { 0 })
        pause_requested_ms = $TestPauseMs
        pause_gate = 'injected only after the ready marker is written (at least -TestPauseAfterReadyMs after it), i.e. while the collector is already measuring'
        pause_after_ready_ms = $TestPauseAfterReadyMs
        pause_after_start_ms = $TestPauseAfterMs
        pause_sample_seq = $pauseSeq
        ready_mono_ms = $readyMono
        ready_sample_seq = $readySeq
        pause_interval = $(if ($pauseApplied) { [ordered]@{ start_mono_ms = $pauseAtMono; end_mono_ms = $pauseEndMono; start_after_ready_ms = [Math]::Round($pauseAtMono - $readyMono, 3) } } else { $null })
        notes = @($notes)
    }
    csv = 'resources.csv'
    note = 'this process is the ONLY resource observer of this run; the collector neither samples nor writes resources'
}
$null = Write-P14aOnce -Path $sumPath -Text ($summary | ConvertTo-Json -Depth 8) -EntryPoint 'p14b-observer.ps1'
Write-Host ("observer tag={0} pid={1} samples={2} max_gap_ms={3} max_cost_ms={4} pause={5}" -f $Tag, $ownPid, $seq, ([Math]::Round($maxGap, 3)), ([Math]::Round($maxCost, 3)), $pauseApplied)
exit 0
