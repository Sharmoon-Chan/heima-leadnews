# P1.3c-1 A/B/C offline checks: publication/hand-over races, process-wide task ids, original stats keys.
#
# What runs is the DELIVERED DetailCacheInvalidator with its real single-thread
# ScheduledThreadPoolExecutor and its real DisposableBean close (through
# AnnotationConfigApplicationContext.close()). Two declared fixtures only:
#   * RecordingCacheService - records delete(key), never talks to Redis (offline collaborator);
#   * GatedExecutor - a REAL ScheduledThreadPoolExecutor that can pause the SUBMITTING thread after
#     the task is enqueued and before schedule() returns (installed by reflection for the race cases).
#     It does not mock the executor: the task still runs on the real worker thread.
#
# Modes, one JVM each:
#   race_enqueue_then_close  enqueued-but-unpublished task, close() lands inside that window
#   race_close_then_submit   close() first, then a submission must be refused
#   race_cancel_queued       queued task cancelled by close: no I/O, one terminal, nothing active
#   multi_context            two real contexts in ONE JVM: task ids must not collide
#   stats_fields             every original stats key still present, incl. no_transaction_runs
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
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3c-1-ABC-offline' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ modes = 'race_enqueue_then_close,race_close_then_submit,race_cancel_queued,multi_context,stats_fields'; delay_ms = 500 } `
        -Targets @() -DataSet 'offline'
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-56} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'FAIL' }), $d
}
function L($obj, [string]$k) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$k]
    if ($null -eq $p) { return $null }
    return $p.Value
}
function N($obj, [string]$k) {
    $v = L $obj $k
    if ($null -eq $v) { return -999999 }
    return [long]$v
}

# ---------------------------------------------------------------- compile both probes
$probeSrc = Join-Path $RunRoot 'probe/src'
$probeClasses = Join-Path $RunRoot 'build/probe-classes'
$classpath = (@(
        (Join-Path $RepoRoot 'heima-leadnews-service/heima-leadnews-article/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-common/target/classes'),
        (Join-Path $RepoRoot 'heima-leadnews-model/target/classes')
    ) + @(Get-ChildItem -LiteralPath $LibDir -Filter *.jar | ForEach-Object { $_.FullName })) -join ';'

$sources = @(Get-ChildItem -LiteralPath $probeSrc -Recurse -Filter *.java | ForEach-Object { $_.FullName })
$savedEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$clog = & $JavacExe '-encoding' 'UTF-8' '-nowarn' '-cp' $classpath '-d' $probeClasses $sources 2>&1
$ccode = $LASTEXITCODE
$ErrorActionPreference = $savedEap
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'javac.log') -Text ((@($clog)) -join "`r`n")
Add-Check 'probe.compiled' ($ccode -eq 0) "javac exit=$ccode sources=$($sources.Count)"
if ($ccode -ne 0) { exit (Set-RunStatus -State $script:run -Status 'failed') }

# ---------------------------------------------------------------- run each mode in its own JVM
$modes = @('race_enqueue_then_close', 'race_close_then_submit', 'race_cancel_queued', 'multi_context', 'stats_fields')
$obs = @{}
$configDir = Join-Path $RunRoot 'configs'
$eventDir = Join-Path $RunRoot 'events'
$runCp = $probeClasses + ';' + $classpath

foreach ($m in $modes) {
    $cfg = Join-Path $configDir ("p13c1-abc-" + $m + ".properties")
    $evFile = Join-Path $eventDir ("p13c1-abc-" + $m + ".log")
    $cfgText = @("# P1.3c-1 A/B/C offline probe config: " + $m) +
               @("events.file=" + ($evFile -replace '\\', '/')) -join "`n"
    [System.IO.File]::WriteAllText($cfg, $cfgText + "`n", $utf8)
    if (Test-Path -LiteralPath $evFile) { throw "event file already exists: $evFile" }

    $stdoutFile = Join-Path $outDir ("stdout-" + $m + ".log")
    $stderrFile = Join-Path $outDir ("stderr-" + $m + ".log")
    # race cases need a longer close wait so the closer thread is not the one blocking the handover
    $wait = if ($m -like 'race_*') { 2000 } else { 2000 }
    $ErrorActionPreference = 'Continue'
    & $JavaExe '-Dfile.encoding=UTF-8' '-cp' $runCp 'p13c1probe.P13c1RaceProbe' $m $cfg $wait 1> $stdoutFile 2> $stderrFile
    $jcode = $LASTEXITCODE
    $ErrorActionPreference = $savedEap

    $line = @(Get-Content -LiteralPath $stdoutFile | Where-Object { $_ -like 'P13C1RACE-OBSERVATION:*' }) | Select-Object -Last 1
    Add-Check ("$m.finished") ($jcode -eq 0 -and $null -ne $line) `
        "java exit=$jcode observation_line=$([bool]($null -ne $line)) stderr_lines=$(@(Get-Content -LiteralPath $stderrFile -ErrorAction SilentlyContinue).Count)"
    if ($null -eq $line) { continue }
    $json = $line.Substring('P13C1RACE-OBSERVATION:'.Length)
    Write-RunFileText -State $script:run -Path (Join-Path $outDir ("observation-" + $m + ".json")) -Text $json
    $obs[$m] = $json | ConvertFrom-Json

    $evLines = @(if (Test-Path -LiteralPath $evFile) { Get-Content -LiteralPath $evFile })
    Write-RunFileText -State $script:run -Path (Join-Path $outDir ("events-" + $m + ".log")) -Text ((@($evLines)) -join "`r`n")
}

function Ev-Of([string]$mode, [string]$name) {
    $path = Join-Path $outDir ("events-" + $mode + ".log")
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path | Where-Object { $_ -match (" event=" + [regex]::Escape($name) + " ") })
}

# ---------------------------------------------------------------- A1: enqueued, then close lands in the window
if ($obs.ContainsKey('race_enqueue_then_close')) {
    $o = $obs['race_enqueue_then_close']
    $during = $o.stats_while_submitter_paused
    $after = $o.stats_after_close
    Add-Check 'race1.window_reproduced' ([bool]$o.task_enqueued_before_publish -and [bool]$o.closure_started_during_handover -and [bool]$o.submitter_finished -and [bool]$o.closer_finished) `
        "task_enqueued_before_publish=$($o.task_enqueued_before_publish) closure_started_during_handover=$($o.closure_started_during_handover) submitter_finished=$($o.submitter_finished) closer_finished=$($o.closer_finished)"
    Add-Check 'race1.no_residue_after_close' ((N $after 'accepted') -eq 1 -and (N $after 'active_now') -eq 0 -and (N $after 'queued_now') -eq 0 -and (N $after 'running_now') -eq 0) `
        "accepted=$(N $after 'accepted') active=$(N $after 'active_now') queued=$(N $after 'queued_now') running=$(N $after 'running_now') succeeded=$(N $after 'succeeded') cancelled=$(N $after 'cancelled')"
    $sum = (N $after 'succeeded') + (N $after 'failed') + (N $after 'cancelled')
    Add-Check 'race1.counters_conserved' (((N $after 'accepted') -eq $sum) -and ((N $after 'submit_attempts') -eq ((N $after 'accepted') + (N $after 'rejected')))) `
        "accepted=$(N $after 'accepted') = succeeded $(N $after 'succeeded') + failed $(N $after 'failed') + cancelled $(N $after 'cancelled') = $sum; submit_attempts=$(N $after 'submit_attempts')"
    Add-Check 'race1.task_ended_as_cancelled_or_succeeded_once' ((N $after 'cancelled') + (N $after 'succeeded') -eq 1) `
        "cancelled=$(N $after 'cancelled') succeeded=$(N $after 'succeeded') (exactly one terminal, none left queued)"
    $acc = @(Ev-Of 'race_enqueue_then_close' 'cache.evict.second_accepted')
    $beg = @(Ev-Of 'race_enqueue_then_close' 'cache.evict.second_begin')
    $term = @(Ev-Of 'race_enqueue_then_close' 'cache.evict.second_succeeded') + @(Ev-Of 'race_enqueue_then_close' 'cache.evict.second_cancelled') + @(Ev-Of 'race_enqueue_then_close' 'cache.evict.second_failed')
    Add-Check 'race1.accepted_before_begin_and_single_terminal' ($acc.Count -eq 1 -and $acc.Count -ge $beg.Count -and $term.Count -eq 1) `
        "accepted=$($acc.Count) begin=$($beg.Count) terminals=$($term.Count) (publish/accept precedes execution, one terminal only)"
    Add-Check 'race1.own_thread_released' (@($o.live_evict_threads).Count -eq 0) `
        "live p13a-cache-evict threads after close: $(@($o.live_evict_threads).Count)"
    $deletes = @($o.delete_calls)
    $secondDeletes = @($deletes | Where-Object { [long]$_.endMs -ge 0 })
    Add-Check 'race1.no_second_io_for_cancelled_task' ($beg.Count -eq 0) `
        "begin events=$($beg.Count) recorded delete calls=$($deletes.Count) (a cancelled task must not reach the egress)"
}

# ---------------------------------------------------------------- A2: close first, submit afterwards
if ($obs.ContainsKey('race_close_then_submit')) {
    $o = $obs['race_close_then_submit']
    $afterClose = $o.stats_after_close
    $afterSubmit = $o.stats_after_post_close_submit
    Add-Check 'race2.post_close_submit_refused' ((N $afterSubmit 'rejected_closed') -eq 1 -and (N $afterSubmit 'accepted') -eq (N $afterClose 'accepted') -and (N $afterSubmit 'submit_attempts') -eq ((N $afterClose 'submit_attempts') + 1)) `
        "submit_attempts=$(N $afterClose 'submit_attempts')->$(N $afterSubmit 'submit_attempts') accepted=$(N $afterSubmit 'accepted') rejected_closed=$(N $afterSubmit 'rejected_closed')"
    Add-Check 'race2.nothing_active_after_refusal' ((N $afterSubmit 'active_now') -eq 0 -and (N $afterSubmit 'queued_now') -eq 0) `
        "active=$(N $afterSubmit 'active_now') queued=$(N $afterSubmit 'queued_now')"
    Add-Check 'race2.own_thread_released' (@($o.live_evict_threads).Count -eq 0) "live threads: $(@($o.live_evict_threads).Count)"
}

# ---------------------------------------------------------------- A3: queued task cancelled, no I/O
if ($obs.ContainsKey('race_cancel_queued')) {
    $o = $obs['race_cancel_queued']
    $justBefore = $o.stats_just_before_close
    $after = $o.stats_after_close
    Add-Check 'race3.queued_at_close' ((N $justBefore 'queued_now') -eq 1 -and (N $justBefore 'running_now') -eq 0) `
        "just before close: queued=$(N $justBefore 'queued_now') running=$(N $justBefore 'running_now') accepted=$(N $justBefore 'accepted')"
    Add-Check 'race3.cancelled_without_io' ((N $after 'cancelled') -eq 1 -and (N $after 'succeeded') -eq 0 -and (N $after 'active_now') -eq 0 -and (@($o.delete_calls).Count -eq 1)) `
        "cancelled=$(N $after 'cancelled') succeeded=$(N $after 'succeeded') active=$(N $after 'active_now') recorded deletes=$(@($o.delete_calls).Count) (only the first delete; the queued second delete never ran)"
    $beg = @(Ev-Of 'race_cancel_queued' 'cache.evict.second_begin')
    $can = @(Ev-Of 'race_cancel_queued' 'cache.evict.second_cancelled')
    Add-Check 'race3.single_terminal_no_begin' ($beg.Count -eq 0 -and $can.Count -eq 1) `
        "begin=$($beg.Count) cancelled=$($can.Count)"
}

# ---------------------------------------------------------------- B: two real contexts, one JVM
if ($obs.ContainsKey('multi_context')) {
    $o = $obs['multi_context']
    $s1 = $o.stats_first_context
    $s2 = $o.stats_second_context
    $p1 = "$($o.task_id_prefix_first)"
    $p2 = "$($o.task_id_prefix_second)"
    $acceptedAll = @(Ev-Of 'multi_context' 'cache.evict.second_accepted')
    $ids = @($acceptedAll | ForEach-Object { [regex]::Match($_, 'taskId=([^ ]+)').Groups[1].Value })
    $uniqueIds = @($ids | Where-Object { $_ -ne '' } | Sort-Object -Unique)
    $idByArticle = @{}
    foreach ($line in $acceptedAll) {
        $art = [regex]::Match($line, 'articleId=(-?\d+)').Groups[1].Value
        $tid = [regex]::Match($line, 'taskId=([^ ]+)').Groups[1].Value
        if ($art -ne '' -and $tid -ne '') { $idByArticle[$art] = $tid }
    }
    $idA = if ($idByArticle.ContainsKey('9007199254743041')) { $idByArticle['9007199254743041'] } else { '' }
    $idB = if ($idByArticle.ContainsKey('9007199254743042')) { $idByArticle['9007199254743042'] } else { '' }
    Add-Check 'multi.two_contexts_same_jvm' ([bool]$o.same_pid -and $p1 -eq $p2 -and $p1 -ne '') `
        "pid both contexts=$($o.pid) same_pid=$($o.same_pid) task_id_prefix=$p1 (both beans share the same pid prefix by design)"
    Add-Check 'multi.task_ids_unique_across_contexts' ($acceptedAll.Count -eq 2 -and $uniqueIds.Count -eq 2 -and $idA -ne '' -and $idB -ne '' -and $idA -ne $idB) `
        "accepted events=$($acceptedAll.Count) unique task ids=$($uniqueIds.Count) first-context id=$idA second-context id=$idB (must differ inside one JVM)"
    Add-Check 'multi.task_ids_use_process_prefix' (@($uniqueIds | Where-Object { $_ -match ('^' + [regex]::Escape($p1) + '[0-9]+$') }).Count -eq $uniqueIds.Count) `
        "ids=$($uniqueIds -join ',') all start with $p1"
    Add-Check 'multi.each_context_accounts_own_tasks' ((N $s1 'accepted') -eq 1 -and (N $s2 'accepted') -eq 1 -and (N $s1 'succeeded') -eq 1 -and (N $s2 'succeeded') -eq 1) `
        "context A accepted=$(N $s1 'accepted') succeeded=$(N $s1 'succeeded'); context B accepted=$(N $s2 'accepted') succeeded=$(N $s2 'succeeded') (business counters stay per Bean)"
    Add-Check 'multi.both_threads_released' (@($o.live_evict_threads).Count -eq 0) "live threads: $(@($o.live_evict_threads).Count)"
}

# ---------------------------------------------------------------- C: original stats keys
if ($obs.ContainsKey('stats_fields')) {
    $o = $obs['stats_fields']
    $initial = $o.stats_initial
    $afterCall = $o.stats_after_no_transaction_call
    $required = @('delete_attempts', 'delete_failures', 'second_delete_scheduled', 'second_delete_done',
                  'second_delete_failures', 'no_transaction_runs', 'after_commit_runs', 'rollback_skips',
                  'second_delete_delay_ms')
    $missing = @($required | Where-Object { $null -eq (L $afterCall $_) })
    Add-Check 'stats.all_original_keys_present' ($missing.Count -eq 0) `
        "missing keys: $(if ($missing.Count -eq 0) { 'none' } else { $missing -join ', ' }) (checked on $(@($required).Count) original names)"
    Add-Check 'stats.no_transaction_runs_counts_0_to_1' ((N $initial 'no_transaction_runs') -eq 0 -and (N $afterCall 'no_transaction_runs') -eq 1) `
        "no_transaction_runs: initial=$(N $initial 'no_transaction_runs') after one no-transaction write=$(N $afterCall 'no_transaction_runs')"
    Add-Check 'stats.delay_and_accounting_unchanged' ((N $afterCall 'second_delete_delay_ms') -eq 500 -and (N $o.stats_final 'succeeded') -eq 1 -and (N $o.stats_final 'active_now') -eq 0) `
        "second_delete_delay_ms=$(N $afterCall 'second_delete_delay_ms') succeeded=$(N $o.stats_final 'succeeded') active=$(N $o.stats_final 'active_now')"
    Add-Check 'stats.own_thread_released' (@($o.live_evict_threads).Count -eq 0) "live threads: $(@($o.live_evict_threads).Count)"
}

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    run_root = $RunRoot
    modes = $modes
    probe_source = 'probe/src/p13c1probe/P13c1RaceProbe.java'
    real_components = 'delivered DetailCacheInvalidator + real single-thread ScheduledThreadPoolExecutor + real DisposableBean close via AnnotationConfigApplicationContext.close()'
    fixtures = 'RecordingCacheService (records delete(key), never Redis) and GatedExecutor (real ScheduledThreadPoolExecutor whose schedule() return can be paused on the submitting thread; installed by reflection for the race cases)'
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'abc-result.json') -Text ($result | ConvertTo-Json -Depth 6)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'abc-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
