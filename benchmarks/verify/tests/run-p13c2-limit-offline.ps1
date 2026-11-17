# P1.3c-2 offline checks Q1-Q4 + illegal-config refusal (ASCII only).
#
# The DELIVERED DetailCacheInvalidator runs with its real single-thread ScheduledThreadPoolExecutor,
# real 500 ms delay, real state lock and real DisposableBean close (AnnotationConfigApplicationContext.close()).
# One declared offline collaborator: RecordingCacheService records delete(key) and never talks to Redis.
#
# Modes, one JVM each:
#   q1_limit       max-active 2, 20 submissions with a slow second delete
#   q2_release     max-active 1: reject while occupied, capacity returns after success / failure / cancel
#   q3_concurrent  max-active 2, 10 threads racing the same limit
#   q4_close_full  max-active 2 filled, close while full, post-close submission refused
#   q5_invalid     illegal max-active values refused at construction
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
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3c-2-offline-Q1-Q4' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ modes = 'q1_limit,q2_release,q3_concurrent,q4_close_full,q5_invalid'; delay_ms = 500; slow_second_ms = 1200 } `
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

# ---------------------------------------------------------------- compile the probe
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
$specs = @(
    [ordered]@{ name = 'q1_limit'; max = 2; wait = 2000; lines = @(for ($i = 0; $i -lt 20; $i++) { "slow.cache.evict.second.$(9007199254743010 + $i)=1200" }) },
    [ordered]@{ name = 'q2_release'; max = 1; wait = 2000; lines = @(
        'slow.cache.evict.second.9007199254743041=1200',
        'fault.cache.evict.second.9007199254743043=always',
        'slow.cache.evict.second.9007199254743045=3000') },
    [ordered]@{ name = 'q3_concurrent'; max = 2; wait = 2000; lines = @(for ($i = 0; $i -lt 10; $i++) { "slow.cache.evict.second.$(9007199254743060 + $i)=900" }) },
    [ordered]@{ name = 'q4_close_full'; max = 2; wait = 300; lines = @(
        'slow.cache.evict.second.9007199254743081=2500',
        'slow.cache.evict.second.9007199254743082=2500') },
    [ordered]@{ name = 'q5_invalid'; max = 1; wait = 500; lines = @() }
)
$obs = @{}
$configDir = Join-Path $RunRoot 'configs'
$eventDir = Join-Path $RunRoot 'events'
$runCp = $probeClasses + ';' + $classpath

foreach ($m in $specs) {
    $cfg = Join-Path $configDir ("p13c2-probe-" + $m.name + ".properties")
    $evFile = Join-Path $eventDir ("p13c2-events-" + $m.name + ".log")
    $cfgText = (@("# P1.3c-2 offline probe config: " + $m.name) + @("events.file=" + ($evFile -replace '\\', '/'))) + @($m.lines) -join "`n"
    [System.IO.File]::WriteAllText($cfg, $cfgText + "`n", $utf8)
    if (Test-Path -LiteralPath $evFile) { throw "event file already exists: $evFile" }

    $stdoutFile = Join-Path $outDir ("stdout-" + $m.name + ".log")
    $stderrFile = Join-Path $outDir ("stderr-" + $m.name + ".log")
    $ErrorActionPreference = 'Continue'
    & $JavaExe '-Dfile.encoding=UTF-8' '-cp' $runCp 'p13c2probe.P13c2LimitProbe' $m.name $cfg $m.wait $m.max 1> $stdoutFile 2> $stderrFile
    $jcode = $LASTEXITCODE
    $ErrorActionPreference = $savedEap

    $line = @(Get-Content -LiteralPath $stdoutFile | Where-Object { $_ -like 'P13C2-OBSERVATION:*' }) | Select-Object -Last 1
    Add-Check ("$($m.name).finished") ($jcode -eq 0 -and $null -ne $line) `
        "java exit=$jcode observation_line=$([bool]($null -ne $line)) stderr_lines=$(@(Get-Content -LiteralPath $stderrFile -ErrorAction SilentlyContinue).Count)"
    if ($null -eq $line) { continue }
    $json = $line.Substring('P13C2-OBSERVATION:'.Length)
    Write-RunFileText -State $script:run -Path (Join-Path $outDir ("observation-" + $m.name + ".json")) -Text $json
    $obs[$m.name] = $json | ConvertFrom-Json

    $evLines = @(if (Test-Path -LiteralPath $evFile) { Get-Content -LiteralPath $evFile })
    Write-RunFileText -State $script:run -Path (Join-Path $outDir ("events-" + $m.name + ".log")) -Text ((@($evLines)) -join "`r`n")
}

function Ev-Of([string]$mode, [string]$name) {
    $path = Join-Path $outDir ("events-" + $mode + ".log")
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path | Where-Object { $_ -match (" event=" + [regex]::Escape($name) + " ") })
}
function Ev-Reason([string]$line) {
    $m = [regex]::Match($line, ' reason=([^ ]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# ---------------------------------------------------------------- Q1: 20 submissions against max-active 2
if ($obs.ContainsKey('q1_limit')) {
    $o = $obs['q1_limit']
    $right = $o.stats_right_after_submits
    $final = $o.stats_final
    Add-Check 'q1.limit_is_configured_value' ((N $right 'max_active') -eq 2) "max_active=$(N $right 'max_active') (frozen test value)"
    Add-Check 'q1.only_limit_accepted' ((N $right 'accepted') -eq 2 -and (N $right 'rejected_backlog') -eq 18 -and (N $right 'submit_attempts') -eq 20) `
        "accepted=$(N $right 'accepted') rejected_backlog=$(N $right 'rejected_backlog') submit_attempts=$(N $right 'submit_attempts') rejected_closed=$(N $right 'rejected_closed') rejected_scheduler=$(N $right 'rejected_scheduler')"
    Add-Check 'q1.no_hidden_queue' ((N $right 'active_now') -eq 2 -and (N $right 'queued_now') -eq 2 -and (N $right 'running_now') -eq 0) `
        "active=$(N $right 'active_now') queued=$(N $right 'queued_now') running=$(N $right 'running_now') (capacity is the whole active set)"
    Add-Check 'q1.first_delete_still_ran_for_all' ((N $final 'delete_attempts') -eq 22) `
        "delete_attempts=$(N $final 'delete_attempts') = 20 first deletes + 2 executed second deletes (rejected ones never reached the egress)"
    $calls = @($o.delete_calls)
    $firstKeys = @($calls | Where-Object { $_.key -notmatch ':second' })
    Add-Check 'q1.egress_matches_first_deletes' ($calls.Count -eq 22) "recorded delete calls=$($calls.Count) for $(@($o.submitted_ids).Count) submissions"
    Add-Check 'q1.counters_reconcile_after_quiesce' (((N $final 'accepted') -eq ((N $final 'succeeded') + (N $final 'failed') + (N $final 'cancelled'))) -and ((N $final 'active_now') -eq 0) -and ((N $final 'submit_attempts') -eq ((N $final 'accepted') + (N $final 'rejected')))) `
        "accepted=$(N $final 'accepted') succeeded=$(N $final 'succeeded') failed=$(N $final 'failed') cancelled=$(N $final 'cancelled') active=$(N $final 'active_now') submit=$(N $final 'submit_attempts') rejected=$(N $final 'rejected')"
    Add-Check 'q1.peak_never_exceeded_limit' ((N $final 'active_peak') -le 2 -and (N $final 'active_peak') -ge 1) "active_peak=$(N $final 'active_peak') (limit 2)"
    $rej = @(Ev-Of 'q1_limit' 'cache.evict.second_rejected')
    $rejBacklog = @($rej | Where-Object { (Ev-Reason $_) -eq 'backlog' })
    $withTask = @($rejBacklog | Where-Object { $_ -match ' taskId=t\d+-\d+ ' -and $_ -match ' articleId=\d+ ' -and $_ -match ' phase=[^ ]+' })
    Add-Check 'q1.rejection_events_named_and_attributed' ($rej.Count -eq 18 -and $rejBacklog.Count -eq 18 -and $withTask.Count -eq 18) `
        "rejected events=$($rej.Count) reason=backlog=$($rejBacklog.Count) with taskId/articleId/phase=$($withTask.Count)"
    Add-Check 'q1.peak_recomputable_from_events' ((@(Ev-Of 'q1_limit' 'cache.evict.second_accepted') | ForEach-Object { [int]([regex]::Match($_, ' active=(\d+)').Groups[1].Value) } | Measure-Object -Maximum).Maximum -le 2) `
        "max active seen in accepted events <= 2 (independently recomputed from the event file)"
}

# ---------------------------------------------------------------- Q2: release and reuse
if ($obs.ContainsKey('q2_release')) {
    $o = $obs['q2_release']
    $full = $o.stats_while_full
    $afterReject = $o.stats_after_reject
    $afterRelease = $o.stats_after_release
    $afterReuse = $o.stats_after_reuse
    $afterFailure = $o.stats_after_failure
    $afterFailureReuse = $o.stats_after_failure_reuse
    $afterClose = $o.stats_after_close
    Add-Check 'q2.reject_when_full' ((N $full 'active_now') -eq 1 -and (N $afterReject 'rejected_backlog') -eq 1 -and (N $afterReject 'accepted') -eq 1) `
        "while full: active=$(N $full 'active_now') -> rejected_backlog=$(N $afterReject 'rejected_backlog') accepted=$(N $afterReject 'accepted')"
    Add-Check 'q2.success_released_slot' ((N $afterRelease 'succeeded') -eq 1 -and (N $afterRelease 'active_now') -eq 0) `
        "after the slow task finished: succeeded=$(N $afterRelease 'succeeded') active=$(N $afterRelease 'active_now')"
    Add-Check 'q2.reuse_after_release' ((N $afterReuse 'accepted') -eq 2) "accepted=$(N $afterReuse 'accepted') (a new task was accepted once capacity returned)"
    Add-Check 'q2.failure_released_slot' ((N $afterFailure 'failed') -eq 1 -and (N $afterFailure 'active_now') -eq 0) `
        "failed=$(N $afterFailure 'failed') active=$(N $afterFailure 'active_now')"
    # accepted so far: 1 slow occupant, 1 after release, 1 failing task -> the post-failure submit is the 4th
    Add-Check 'q2.reuse_after_failure' ((N $afterFailureReuse 'accepted') -eq 4) "accepted=$(N $afterFailureReuse 'accepted') (the post-failure submit was accepted again, so the failure freed the slot)"
    # accepted so far: 4 -> the task submitted just before close makes 5; it is cancelled by close
    Add-Check 'q2.cancel_released_slot' ((N $afterClose 'cancelled') -eq 1 -and (N $afterClose 'active_now') -eq 0 -and (N $afterClose 'accepted') -eq 5) `
        "cancelled=$(N $afterClose 'cancelled') active=$(N $afterClose 'active_now') accepted=$(N $afterClose 'accepted')"
    Add-Check 'q2.final_reconciles' (((N $afterClose 'accepted') -eq ((N $afterClose 'succeeded') + (N $afterClose 'failed') + (N $afterClose 'cancelled'))) -and ((N $afterClose 'submit_attempts') -eq ((N $afterClose 'accepted') + (N $afterClose 'rejected')))) `
        "accepted=$(N $afterClose 'accepted') succeeded=$(N $afterClose 'succeeded') failed=$(N $afterClose 'failed') cancelled=$(N $afterClose 'cancelled') submit=$(N $afterClose 'submit_attempts') rejected=$(N $afterClose 'rejected')"
    Add-Check 'q2.peak_bounded' ((N $afterClose 'active_peak') -le 1) "active_peak=$(N $afterClose 'active_peak') (limit 1)"
}

# ---------------------------------------------------------------- Q3: concurrent submissions
if ($obs.ContainsKey('q3_concurrent')) {
    $o = $obs['q3_concurrent']
    $race = $o.stats_right_after_race
    $final = $o.stats_final
    Add-Check 'q3.submit_accounting' ((N $race 'submit_attempts') -eq 10 -and ((N $race 'accepted') + (N $race 'rejected')) -eq 10) `
        "submit_attempts=$(N $race 'submit_attempts') accepted=$(N $race 'accepted') rejected=$(N $race 'rejected') backlog=$(N $race 'rejected_backlog')"
    Add-Check 'q3.limit_respected_under_race' ((N $race 'accepted') -le 2 -and (N $race 'active_now') -le 2) `
        "accepted=$(N $race 'accepted') active=$(N $race 'active_now') peak=$(N $race 'active_peak') (limit 2)"
    $acc = @(Ev-Of 'q3_concurrent' 'cache.evict.second_accepted')
    $ids = @($acc | ForEach-Object { [regex]::Match($_, 'taskId=([^ ]+)').Groups[1].Value })
    $arts = @($acc | ForEach-Object { [regex]::Match($_, 'articleId=(-?\d+)').Groups[1].Value })
    Add-Check 'q3.no_duplicate_or_lost_tasks' (($ids.Count -eq 2) -and (@($ids | Sort-Object -Unique).Count -eq 2) -and (@($arts | Sort-Object -Unique).Count -eq 2)) `
        "accepted events=$($ids.Count) unique taskIds=$(@($ids | Sort-Object -Unique).Count) unique articleIds=$(@($arts | Sort-Object -Unique).Count)"
    $rej = @(Ev-Of 'q3_concurrent' 'cache.evict.second_rejected')
    Add-Check 'q3.rejections_named_backlog' ($rej.Count -eq 8 -and @($rej | Where-Object { (Ev-Reason $_) -eq 'backlog' }).Count -eq 8) `
        "rejected events=$($rej.Count) reason=backlog=$(@($rej | Where-Object { (Ev-Reason $_) -eq 'backlog' }).Count)"
    Add-Check 'q3.final_reconciles' ((N $final 'active_now') -eq 0 -and (N $final 'accepted') -eq ((N $final 'succeeded') + (N $final 'failed') + (N $final 'cancelled'))) `
        "final: accepted=$(N $final 'accepted') succeeded=$(N $final 'succeeded') failed=$(N $final 'failed') cancelled=$(N $final 'cancelled') active=$(N $final 'active_now')"
    Add-Check 'q3.first_deletes_all_ran' ((N $final 'delete_attempts') -eq 12) `
        "delete_attempts=$(N $final 'delete_attempts') = 10 first deletes + 2 second deletes"
}

# ---------------------------------------------------------------- Q4: close while full
if ($obs.ContainsKey('q4_close_full')) {
    $o = $obs['q4_close_full']
    $full = $o.stats_full
    $afterClose = $o.stats_after_close
    $afterPost = $o.stats_after_post_close
    Add-Check 'q4.full_before_close' ((N $full 'active_now') -eq 2 -and (N $full 'accepted') -eq 2 -and (N $full 'rejected_backlog') -eq 1) `
        "full: active=$(N $full 'active_now') accepted=$(N $full 'accepted') rejected_backlog=$(N $full 'rejected_backlog')"
    Add-Check 'q4.close_releases_and_accounts' ((N $afterClose 'active_now') -eq 0 -and (N $afterClose 'cancelled') -eq 2 -and (N $afterClose 'close_finished') -eq 1) `
        "after close: cancelled=$(N $afterClose 'cancelled') active=$(N $afterClose 'active_now') close_finished=$(N $afterClose 'close_finished') close_cancelled=$(N $afterClose 'close_cancelled')"
    Add-Check 'q4.post_close_refused' ((N $afterPost 'rejected_closed') -eq 1 -and (N $afterPost 'accepted') -eq 2) `
        "post-close submit: rejected_closed=$(N $afterPost 'rejected_closed') accepted=$(N $afterPost 'accepted')"
    Add-Check 'q4.own_thread_released' (@($o.live_evict_threads).Count -eq 0) "live p13a-cache-evict threads: $(@($o.live_evict_threads).Count)"
    # 4 first deletes: the three inside the limit (a, b, c) plus the post-close submit; no second delete ran
    Add-Check 'q4.first_deletes_ran' ((N $afterPost 'delete_attempts') -eq 4) "delete_attempts=$(N $afterPost 'delete_attempts') = 4 first deletes (3 in-limit + 1 post-close), no second delete executed"
}

# ---------------------------------------------------------------- Q5: illegal configuration refused
if ($obs.ContainsKey('q5_invalid')) {
    $o = $obs['q5_invalid']
    $attempts = @($o.invalid_attempts)
    Add-Check 'q5.illegal_values_refused' ($attempts.Count -eq 2 -and @($attempts | Where-Object { $_.refused -eq $true }).Count -eq 2) `
        "attempts=$($attempts.Count) refused=$(@($attempts | Where-Object { $_.refused -eq $true }).Count) messages=$(($attempts | ForEach-Object { "[$($_.value)] $($_.message)" }) -join ' | ')"
}

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    run_root = $RunRoot
    modes = @($specs | ForEach-Object { $_.name })
    frozen_test_values = [ordered]@{ max_active = @(2, 1); slow_second_ms = 1200; close_wait_ms = @(2000, 300); delay_ms = 500 }
    probe_source = 'probe/src/p13c2probe/P13c2LimitProbe.java'
    real_components = 'delivered DetailCacheInvalidator + real single-thread ScheduledThreadPoolExecutor + real state lock + real DisposableBean close'
    fixtures = 'RecordingCacheService (records delete(key), never Redis); slow/fault second-delete knobs are the delivered DetailProbe test-only switches keyed by exact articleId'
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'q1-q4-result.json') -Text ($result | ConvertTo-Json -Depth 6)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'q1-q4-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
