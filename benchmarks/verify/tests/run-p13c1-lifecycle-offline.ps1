# P1.3c-1 offline L1-L4: real scheduler, real Spring close hook, recording Redis egress (ASCII only).
#
# What runs: the repository's compiled DetailCacheInvalidator (real single-thread scheduler, real 500 ms
# delay, real DisposableBean close via AnnotationConfigApplicationContext.close()). Only the Redis egress
# is a stand-in that records delete(key) calls - it is an offline collaborator and is NOT evidence about
# a real Redis server.
#
# Modes (one JVM each, so counters and threads cannot leak between cases):
#   l1 two normal second deletes            -> accepted/succeeded reconcile, task ids unique, order
#   l2 second delete fails once             -> failed=1, succeeded unchanged, active released
#   l3 20 tasks + close while 1 runs        -> queued cancelled, close receipt, post-close rejection
#   l4 second delete longer than the wait   -> close returns while running, later terminal is honest
#
# Every assertion is recomputed from the observation JSON and the probe event file; nothing is taken
# from the console summary of the run.
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$LibDir = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib',
    [string]$JavaExe = 'D:\Soft\Java\jdk-1.8\bin\java.exe',
    [string]$JavacExe = 'D:\Soft\Java\jdk-1.8\bin\javac.exe'
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$benchDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3c-1-offline-L1-L4' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ modes = 'l1,l2,l3,l4'; delay_ms = 500; close_wait_l1_l2 = 2000; close_wait_l3 = 300; close_wait_l4 = 400 } `
        -Targets @() -DataSet 'offline'
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-52} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'FAIL' }), $d
}
function L($map, [string]$k) {
    if ($null -eq $map) { return $null }
    $p = $map.PSObject.Properties[$k]
    if ($null -eq $p) { return $null }
    return $p.Value
}
function N($map, [string]$k) {
    $v = L $map $k
    if ($null -eq $v) { return -999999 }
    return [long]$v
}

# ---------------------------------------------------------------- compile the probe
$harnessSrc = Join-Path $RunRoot 'probe/src'
$probeClasses = Join-Path $RunRoot 'build/probe-classes'
$classpath = (@(
        (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-common/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-model/target/classes')
    ) + @(Get-ChildItem -LiteralPath $LibDir -Filter *.jar | ForEach-Object { $_.FullName })) -join ';'

$sources = @(Get-ChildItem -LiteralPath $harnessSrc -Recurse -Filter *.java | ForEach-Object { $_.FullName })
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$clog = & $JavacExe '-encoding' 'UTF-8' '-nowarn' '-cp' $classpath '-d' $probeClasses $sources 2>&1
$ccode = $LASTEXITCODE
$ErrorActionPreference = $savedEap
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'javac.log') -Text ((@($clog)) -join "`r`n")
Add-Check 'probe.compiled' ($ccode -eq 0) "javac exit=$ccode sources=$($sources.Count) classes=$((Get-ChildItem $probeClasses -Recurse -File).Count)"
if ($ccode -ne 0) {
    exit (Set-RunStatus -State $script:run -Status 'failed')
}

# ---------------------------------------------------------------- per-mode probe config + event files
$modes = @(
    [ordered]@{ name = 'l1'; wait = 2000; lines = @() },
    [ordered]@{ name = 'l2'; wait = 2000; lines = @('fault.cache.evict.second.9007199254742021=once') },
    [ordered]@{ name = 'l3'; wait = 300;  lines = @(for ($i = 0; $i -lt 20; $i++) { "slow.cache.evict.second.$(9007199254742100 + $i)=800" }) },
    [ordered]@{ name = 'l4'; wait = 400;  lines = @('slow.cache.evict.second.9007199254742031=3000') }
)

$configDir = Join-Path $RunRoot 'configs'
$eventDir = Join-Path $RunRoot 'events'
$observations = @{}
$eventsByMode = @{}

foreach ($m in $modes) {
    $cfg = Join-Path $configDir ("p13c1-probe-" + $m.name + ".properties")
    $evFile = Join-Path $eventDir ("p13c1-events-" + $m.name + ".log")
    $cfgText = (@("# P1.3c-1 offline probe config for mode " + $m.name) + @("events.file=" + ($evFile -replace '\\', '/'))) + @($m.lines) -join "`n"
    [System.IO.File]::WriteAllText($cfg, $cfgText + "`n", $utf8)
    if (Test-Path -LiteralPath $evFile) { throw "event file already exists: $evFile" }

    $stdoutFile = Join-Path $outDir ("stdout-" + $m.name + ".log")
    $stderrFile = Join-Path $outDir ("stderr-" + $m.name + ".log")
    $runCp = $probeClasses + ';' + $classpath
    $ErrorActionPreference = 'Continue'
    & $JavaExe '-Dfile.encoding=UTF-8' '-cp' $runCp 'p13c1probe.P13c1LifecycleProbe' $m.name $cfg $m.wait 1> $stdoutFile 2> $stderrFile
    $jcode = $LASTEXITCODE
    $ErrorActionPreference = $savedEap

    $obsLine = @(Get-Content -LiteralPath $stdoutFile | Where-Object { $_ -like 'P13C1-OBSERVATION:*' }) | Select-Object -Last 1
    Add-Check ("$($m.name).probe_finished") ($jcode -eq 0 -and $null -ne $obsLine) `
        "java exit=$jcode observation_line=$([bool]($null -ne $obsLine)) stderr_lines=$(@(Get-Content -LiteralPath $stderrFile -ErrorAction SilentlyContinue).Count)"
    if ($null -eq $obsLine) {
        Write-RunFileText -State $script:run -Path (Join-Path $outDir ("observation-" + $m.name + ".json")) -Text '{}'
        continue
    }
    $json = $obsLine.Substring('P13C1-OBSERVATION:'.Length)
    Write-RunFileText -State $script:run -Path (Join-Path $outDir ("observation-" + $m.name + ".json")) -Text $json
    $obj = $json | ConvertFrom-Json
    $observations[$m.name] = $obj

    $evLines = @(if (Test-Path -LiteralPath $evFile) { Get-Content -LiteralPath $evFile })
    Write-RunFileText -State $script:run -Path (Join-Path $outDir ("events-" + $m.name + ".log")) -Text ((@($evLines)) -join "`r`n")
    $eventsByMode[$m.name] = $evLines
}

# ---------------------------------------------------------------- event helpers (recount from originals)
function Get-Events([string]$mode) { return @($eventsByMode[$mode]) }
function Ev-Name([string]$line) { $m = [regex]::Match($line, ' event=([^ ]+)'); if ($m.Success) { return $m.Groups[1].Value } return '' }
function Ev-Ms([string]$line) { $m = [regex]::Match($line, ' epochMs=(\d+)'); if ($m.Success) { return [long]$m.Groups[1].Value } return -1 }
function Ev-Task([string]$line) { $m = [regex]::Match($line, 'taskId=([^ ]+)'); if ($m.Success) { return $m.Groups[1].Value } return '' }
function Ev-Article([string]$line) { $m = [regex]::Match($line, 'articleId=(-?\d+)'); if ($m.Success) { return [long]$m.Groups[1].Value } return -1 }
function Ev-Phase([string]$line) { $m = [regex]::Match($line, 'phase=([^ ]+)'); if ($m.Success) { return $m.Groups[1].Value } return '' }

# ---------------------------------------------------------------- L1: normal completion
if ($observations.ContainsKey('l1')) {
    $o = $observations['l1']
    $st = $o.stats_final
    Add-Check 'l1.accepted_and_succeeded' ((N $st 'accepted') -eq 2 -and (N $st 'succeeded') -eq 2 -and (N $st 'failed') -eq 0 -and (N $st 'cancelled') -eq 0 -and (N $st 'rejected') -eq 0) `
        "accepted=$(N $st 'accepted') succeeded=$(N $st 'succeeded') failed=$(N $st 'failed') cancelled=$(N $st 'cancelled') rejected=$(N $st 'rejected')"
    Add-Check 'l1.everything_released' ((N $st 'active_now') -eq 0 -and (N $st 'queued_now') -eq 0 -and (N $st 'running_now') -eq 0) `
        "active=$(N $st 'active_now') queued=$(N $st 'queued_now') running=$(N $st 'running_now')"
    Add-Check 'l1.delay_unchanged' ((N $st 'second_delete_delay_ms') -eq 500) "second_delete_delay_ms=$(N $st 'second_delete_delay_ms') (must stay 500)"
    $ev = Get-Events 'l1'
    $acc = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.second_accepted' })
    $beg = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.second_begin' })
    $suc = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.second_succeeded' })
    $ids = @($acc | ForEach-Object { Ev-Task $_ } | Sort-Object -Unique)
    Add-Check 'l1.task_ids_unique_and_complete' (($acc.Count -eq 2) -and ($ids.Count -eq 2) -and ($beg.Count -eq 2) -and ($suc.Count -eq 2) -and (@($ids | Where-Object { $_ -match ('^t' + $o.pid + '-\d+$') }).Count -eq 2)) `
        "accepted=$($acc.Count) begin=$($beg.Count) succeeded=$($suc.Count) unique_ids=$($ids.Count) prefix_matches_pid=$($o.pid)"
    $orderOk = $true
    foreach ($id in $ids) {
        $a = @($ev | Where-Object { (Ev-Task $_) -eq $id -and (Ev-Name $_) -eq 'cache.evict.second_accepted' })[0]
        $b = @($ev | Where-Object { (Ev-Task $_) -eq $id -and (Ev-Name $_) -eq 'cache.evict.second_begin' })[0]
        $s = @($ev | Where-Object { (Ev-Task $_) -eq $id -and (Ev-Name $_) -eq 'cache.evict.second_succeeded' })[0]
        if ($null -eq $a -or $null -eq $b -or $null -eq $s) { $orderOk = $false; break }
        if (-not ((Ev-Ms $a) -le (Ev-Ms $b) -and (Ev-Ms $b) -le (Ev-Ms $s))) { $orderOk = $false; break }
        $delay = (Ev-Ms $b) - (Ev-Ms $a)
        if ($delay -lt 450) { $orderOk = $false; break }
    }
    Add-Check 'l1.accepted_before_begin_before_succeeded' $orderOk 'per taskId: accepted <= begin <= succeeded, and begin is at least ~500 ms after accepted'
    # success only after the real delete returned
    $calls = @($o.delete_calls)
    $matchOk = $true
    foreach ($s in $suc) {
        $art = Ev-Article $s
        $key = 'article:detail:' + $art
        $cand = @($calls | Where-Object { $_.key -eq $key -and [long]$_.endMs -le (Ev-Ms $s) })
        if ($cand.Count -lt 1) { $matchOk = $false; break }
    }
    Add-Check 'l1.success_only_after_delete_returned' $matchOk "delete calls recorded=$($calls.Count) (2 first + 2 second); every second_succeeded has a matching recorded delete that ended before it"
}

# ---------------------------------------------------------------- L2: the second delete fails
if ($observations.ContainsKey('l2')) {
    $o = $observations['l2']
    $st = $o.stats_final
    Add-Check 'l2.failed_once_and_not_succeeded' ((N $st 'accepted') -eq 1 -and (N $st 'failed') -eq 1 -and (N $st 'succeeded') -eq 0) `
        "accepted=$(N $st 'accepted') failed=$(N $st 'failed') succeeded=$(N $st 'succeeded') delete_failures=$(N $st 'delete_failures')"
    Add-Check 'l2.active_released' ((N $st 'active_now') -eq 0 -and (N $st 'queued_now') -eq 0 -and (N $st 'running_now') -eq 0) `
        "active=$(N $st 'active_now') queued=$(N $st 'queued_now') running=$(N $st 'running_now')"
    $ev = Get-Events 'l2'
    $failedEv = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.second_failed' })
    $okSecond = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.ok' -and (Ev-Phase $_) -like '*:second' })
    $okFirst = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.ok' -and (Ev-Phase $_) -notlike '*:second' })
    Add-Check 'l2.failed_event_with_task_and_exception' ($failedEv.Count -eq 1 -and (Ev-Task $failedEv[0]) -ne '') `
        "second_failed=$($failedEv.Count) taskId=$(if ($failedEv.Count -gt 0) { Ev-Task $failedEv[0] } else { '-' })"
    Add-Check 'l2.first_delete_still_worked' ($okFirst.Count -eq 1 -and $okSecond.Count -eq 0) `
        "first-phase ok=$($okFirst.Count) second-phase ok=$($okSecond.Count) (the fault must only hit the second delete)"
    Add-Check 'l2.failure_kept_as_original' (($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.fail' -and (Ev-Phase $_) -like '*:second' }).Count -eq 1) `
        "cache.evict.fail(phase=*:second)=$((@($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.fail' -and (Ev-Phase $_) -like '*:second' })).Count)"
    Add-Check 'l2.failed_delete_never_reached_egress' (@($o.delete_calls).Count -eq 1) `
        "recorded delete calls=$(@($o.delete_calls).Count) (only the first delete reached the egress; the injected failure happens before it)"
}

# ---------------------------------------------------------------- L3: backlog and close
if ($observations.ContainsKey('l3')) {
    $o = $observations['l3']
    $before = $o.stats_before_close
    $atClose = $o.stats_at_close_return
    $final = $o.stats_final
    Add-Check 'l3.backlog_observed_before_close' ((N $before 'queued_now') -eq 19 -and (N $before 'running_now') -eq 1 -and (N $before 'accepted') -eq 20) `
        "before close: accepted=$(N $before 'accepted') queued=$(N $before 'queued_now') running=$(N $before 'running_now') active=$(N $before 'active_now')"
    Add-Check 'l3.close_receipt_recorded' ((N $atClose 'close_finished') -eq 1 -and (N $atClose 'close_wait_ms') -eq 300 -and (N $atClose 'close_queued_before') -eq 19 -and (N $atClose 'close_running_before') -eq 1) `
        "close_finished=$(N $atClose 'close_finished') waitMs=$(N $atClose 'close_wait_ms') waitedMs=$(N $atClose 'close_waited_ms') queuedBefore=$(N $atClose 'close_queued_before') runningBefore=$(N $atClose 'close_running_before') terminated=$(N $atClose 'close_terminated')"
    Add-Check 'l3.queued_tasks_cancelled_not_run' ((N $atClose 'cancelled') -eq 19 -and (N $atClose 'close_cancelled') -eq 19) `
        "cancelled=$(N $atClose 'cancelled') close_cancelled=$(N $atClose 'close_cancelled') (the 19 queued tasks never executed)"
    Add-Check 'l3.post_close_submit_rejected' ((N $o.stats_after_post_close_submit 'rejected_closed') -ge 1 -and (N $o.stats_after_post_close_submit 'submit_attempts') -eq 21 -and (N $o.stats_after_post_close_submit 'accepted') -eq 20) `
        "submit_attempts=$(N $o.stats_after_post_close_submit 'submit_attempts') accepted=$(N $o.stats_after_post_close_submit 'accepted') rejected_closed=$(N $o.stats_after_post_close_submit 'rejected_closed')"
    $sum = (N $final 'succeeded') + (N $final 'failed') + (N $final 'cancelled')
    Add-Check 'l3.counters_reconcile' (((N $final 'accepted') -eq $sum) -and ((N $final 'submit_attempts') -eq ((N $final 'accepted') + (N $final 'rejected'))) -and ((N $final 'active_now') -eq 0)) `
        "accepted=$(N $final 'accepted') = succeeded $(N $final 'succeeded') + failed $(N $final 'failed') + cancelled $(N $final 'cancelled') = $sum; submit_attempts=$(N $final 'submit_attempts') accepted+rejected=$((N $final 'accepted') + (N $final 'rejected')); active=$(N $final 'active_now')"
    Add-Check 'l3.own_thread_released' (@($o.live_evict_threads_final).Count -eq 0) `
        "live p13a-cache-evict threads after close: $(@($o.live_evict_threads_final).Count)"
    $ev = Get-Events 'l3'
    $sb = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.shutdown_begin' })
    $se = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.shutdown_end' })
    $cn = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.second_cancelled' })
    Add-Check 'l3.shutdown_events_and_cancel_events' ($sb.Count -eq 1 -and $se.Count -eq 1 -and $cn.Count -eq 19) `
        "shutdown_begin=$($sb.Count) shutdown_end=$($se.Count) second_cancelled=$($cn.Count)"
    Add-Check 'l3.no_second_begin_after_shutdown' ((@($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.second_begin' -and (Ev-Ms $_) -gt (Ev-Ms $se[0]) })).Count -eq 0) `
        "second_begin after shutdown_end: $(@($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.second_begin' -and (Ev-Ms $_) -gt (Ev-Ms $se[0]) }).Count)"
}

# ---------------------------------------------------------------- L4: running I/O outlives the wait
if ($observations.ContainsKey('l4')) {
    $o = $observations['l4']
    $atClose = $o.stats_at_close_return
    $final = $o.stats_final
    Add-Check 'l4.close_bounded_not_terminated' ([long]$o.close_elapsed_ms -ge 300 -and [long]$o.close_elapsed_ms -lt 2000 -and (N $atClose 'close_terminated') -eq 0) `
        "close elapsed=$($o.close_elapsed_ms)ms waitMs=$(N $atClose 'close_wait_ms') terminated=$(N $atClose 'close_terminated')"
    Add-Check 'l4.close_does_not_claim_completion' ((N $atClose 'running_now') -eq 1 -and (N $atClose 'succeeded') -eq 0 -and (N $atClose 'failed') -eq 0) `
        "at close return: running=$(N $atClose 'running_now') succeeded=$(N $atClose 'succeeded') failed=$(N $atClose 'failed') (still pending, not declared successful)"
    Add-Check 'l4.later_terminal_is_honest' ((N $final 'succeeded') -eq 1 -and (N $final 'failed') -eq 0 -and (N $final 'active_now') -eq 0) `
        "after the slow delete returned: succeeded=$(N $final 'succeeded') failed=$(N $final 'failed') active=$(N $final 'active_now')"
    Add-Check 'l4.own_thread_released' (@($o.live_evict_threads_final).Count -eq 0) `
        "live p13a-cache-evict threads at the end: $(@($o.live_evict_threads_final).Count)"
    $ev = Get-Events 'l4'
    $se = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.shutdown_end' })
    $suc = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.second_succeeded' })
    $pauseB = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.second_pause_begin' })
    $pauseE = @($ev | Where-Object { (Ev-Name $_) -eq 'cache.evict.second_pause_end' })
    Add-Check 'l4.close_returned_before_terminal' ($se.Count -eq 1 -and $suc.Count -eq 1 -and (Ev-Ms $se[0]) -lt (Ev-Ms $suc[0])) `
        "shutdown_end=$($se.Count) succeeded=$($suc.Count) shutdown_end_earlier=$((Ev-Ms $se[0]) -lt (Ev-Ms $suc[0]))"
    Add-Check 'l4.pause_observed' ($pauseB.Count -eq 1 -and $pauseE.Count -eq 1 -and ((Ev-Ms $pauseE[0]) - (Ev-Ms $pauseB[0])) -ge 2500) `
        "pause_begin=$($pauseB.Count) pause_end=$($pauseE.Count) pause_ms=$((Ev-Ms $pauseE[0]) - (Ev-Ms $pauseB[0]))"
}

# ---------------------------------------------------------------- summary
$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    run_root = $RunRoot
    modes = 'l1,l2,l3,l4'
    harness_source = 'probe/src/p13c1probe/P13c1LifecycleProbe.java'
    real_components = 'DetailCacheInvalidator + single-thread ScheduledThreadPoolExecutor + DisposableBean close via AnnotationConfigApplicationContext.close()'
    offline_collaborator = 'RecordingCacheService extends CacheService and overrides delete(String) to record the call; it never talks to Redis and is not evidence about a Redis server'
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'lifecycle-result.json') -Text ($result | ConvertTo-Json -Depth 6)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'lifecycle-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
