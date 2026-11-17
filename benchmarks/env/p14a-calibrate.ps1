# P1.4a limited calibration: A (article.detail.cache.enabled=false) vs B (true), same frozen code (ASCII only).
#
# Order of work:
#   1. this session's run directory is created through the shared guard;
#   2. one probe config per group (write once) and BOTH instances start through the single launcher, so A and B
#      load the SAME frozen classes and differ only in the cache switch;
#   3. readiness + identity gate: a real detail read must return a correct body, and the cache key must be ABSENT
#      for A and PRESENT for B - that is the proof the switch really took effect;
#   4. coverage warmup: one serial pass over all 100 ids per group, single-listed, never sampled;
#   5. six segments: 5/s A->B, 20/s B->A, 50/s A->B. Each group gets a 10 s rate warmup ledger and a 20 s sampled
#      ledger. A segment with any wrong verdict, drop, timeout, failure or collector saturation is INVALID and
#      stops the escalation; nothing is re-requested to top up successes;
#   6. the exact Redis key set created by this card is deleted one key at a time (no FLUSHDB) and only the
#      processes this card started are stopped.
#
# Exit codes: 0 = every attempted segment valid, 1 = something failed (details in calibration-result.json),
#             2 = refused before any measurement.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [int]$PortA = 51821,
    [int]$PortB = 51822,
    [int]$MaxInFlight = 16,
    [int]$RequestTimeoutMs = 5000,
    # Only the tiers listed here are attempted; this round re-measures 5 and 20 req/s only (50 is NOT re-run).
    # A -File invocation binds "5,20" as ONE string that [int[]] would read as 520, so the CSV form is the reliable
    # one and it is validated BEFORE any instance, SQL or Redis work.
    [string]$RatesCsv = '5,20,50',
    [int[]]$Rates = @(),
    [int]$RedisDb = 5,
    [string]$CacheKeyPrefix = 'article:detail:',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    [string]$JstatExe = 'D:\Soft\Java\jdk-1.8\bin\jstat.exe',
    [int]$CollectorCpuStopPercent = 80,
    [int]$CollectorCpuStopSeconds = 5,
    [switch]$SkipInstanceStart,
    [switch]$SkipRestore
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$env:MYSQL_PWD = $MysqlPassword
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
function Get-Sha([string]$p) { if (Test-Path -LiteralPath $p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() } return '' }
function Sql([string]$q) { return (((& $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--raw' '-e' $q) 2>&1) | Out-String).Trim() }
function Redis([int]$db, [string[]]$a) { return ((& $RedisCli (@('-h', '127.0.0.1', '-p', '6379', '-n', "$db") + $a) 2>&1) | Out-String).Trim() }

# Parent-root lifecycle FIRST: a completed/sealed root is refused before any SQL, Redis, directory, output or
# process call - and before the child run directory is created.
$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'p14a-calibrate.ps1'
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (-not (Test-UnderRoot $RunRoot $ArtifactsRoot)) { Write-Host 'REFUSED: run root outside the artifacts root'; exit 2 }
# tier selection is validated FIRST, so a bad -RatesCsv costs no instance start, no coverage pass and no Redis key
if ($null -eq $Rates -or $Rates.Count -eq 0) {
    if ($RatesCsv -notmatch '^\d+(,\d+)*$') {
        Write-Host "REFUSED: bad -RatesCsv '$RatesCsv' (a -File invocation binds 5,20 as one string; pass -RatesCsv '5,20')"
        exit 2
    }
    $Rates = @($RatesCsv -split ',' | ForEach-Object { [int]$_ })
}

$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.4a-calibrate' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ port_a = $PortA; port_b = $PortB; max_in_flight = $MaxInFlight; request_timeout_ms = $RequestTimeoutMs; redis_db = $RedisDb } `
        -Targets @() -DataSet $Database
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-56} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'fail' }), $d
}

# Children must NOT be captured through a pipe. A grandchild (the JVM) inherits the pipe's write handle, so the
# pipe never reaches EOF and the caller blocks forever even though the child already exited. Every child is
# therefore run with stdout/stderr redirected to FILES under this run directory; only the exit code and the tail
# of those files are used here.
$script:childSeq = 0
# A live grandchild (the launched JVM) may hold a handle on these files: open them for SHARED read and never fail
# the run just because a tail could not be read.
function Read-SharedLines([string]$path) {
    $fs = $null; $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
        return @($sr.ReadToEnd() -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    } catch {
        return @("unreadable: $($_.Exception.Message)")
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}
function Invoke-ChildPowerShell([string]$scriptPath, [string[]]$childArgs, [string]$label) {
    $script:childSeq++
    $safe = ($label -replace '[^A-Za-z0-9._-]', '_')
    $o = Join-Path $outDir ("child-{0:d2}-{1}.out" -f $script:childSeq, $safe)
    $e = "$o.err"
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $o -RedirectStandardError $e `
        -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $childArgs)
    # WaitForExit() on the Process object can return before ExitCode is populated in this environment, so poll
    # HasExited, refresh the object and only then read the code (an unknown code is reported as -1, never blank)
    $deadline = (Get-Date).AddSeconds(1200)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $proc.Refresh()
    $exitCode = -1
    try { if ($null -ne $proc.ExitCode) { $exitCode = [int]$proc.ExitCode } } catch { $exitCode = -1 }
    $tail = ''
    # the launched JVM may still hold these files open, so they are read through a SHARED reader, never exclusively
    if (Test-Path -LiteralPath $o) { $tail = (@(Read-SharedLines $o) | Select-Object -Last 6) -join ' | ' }
    if (Test-Path -LiteralPath $e) {
        $et = (@(Read-SharedLines $e) | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 3) -join ' | '
        if ($et) { $tail = "$tail || stderr: $et" }
    }
    return [pscustomobject]@{ exit = $exitCode; output = $tail; out_file = (Split-Path -Leaf $o) }
}

$plansDir = Join-Path $RunRoot 'plans'
$truthFile = Join-Path $plansDir 'ids-truth.json'
$plansIndex = Get-Content -LiteralPath (Join-Path $plansDir 'plans-index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$truth = Get-Content -LiteralPath $truthFile -Raw -Encoding UTF8 | ConvertFrom-Json
$allIds = @($truth.targets | ForEach-Object { [string]$_.article_id })
function Plan-Of([int]$rate, [string]$kind) {
    foreach ($p in $plansIndex.plans) { if ([int]$p.rate -eq $rate -and "$($p.kind)" -eq $kind) { return (Join-Path $RunRoot ($p.path -replace '/', '\')) } }
    throw "no plan for rate=$rate kind=$kind"
}
$collectorEntry = Join-Path (Join-Path $benchDir 'load') 'p14a-collect.ps1'
$launcher = Join-Path $PSScriptRoot 'start-p14a-instance.ps1'

function Get-TruthMismatch {
    $idList = ($allIds | ForEach-Object { "$_" }) -join ','
    $rows = Sql ("SELECT a.id, a.views, a.likes, a.comment, a.collection FROM $Database.ap_article a WHERE a.id IN ($idList) ORDER BY a.id;")
    $cur = @{}
    foreach ($line in ($rows -split "`r?`n")) {
        if ($line.Trim() -eq '') { continue }
        $f = $line -split "`t"
        $cur[[string]$f[0]] = "$($f[1])|$($f[2])|$($f[3])|$($f[4])"
    }
    $bad = New-Object System.Collections.ArrayList
    foreach ($t in $truth.targets) {
        $want = "$($t.views)|$($t.likes)|$($t.comment)|$($t.collection)"
        $id = [string]$t.article_id
        $have = if ($cur.ContainsKey($id)) { $cur[$id] } else { 'MISSING' }
        if ($have -ne $want) { $null = $bad.Add("$id have=$have want=$want") }
    }
    return $bad
}
function Get-KeyState {
    $present = 0
    foreach ($id in $allIds) { if ((Redis $RedisDb @('EXISTS', "$CacheKeyPrefix$id")) -eq '1') { $present++ } }
    return [ordered]@{ db = $RedisDb; prefix = $CacheKeyPrefix; ids_checked = $allIds.Count; ids_present = $present; db_size = (Redis $RedisDb @('DBSIZE')) }
}

Add-Check 'data.truth_matches_database' ((Get-TruthMismatch).Count -eq 0) ("all $($allIds.Count) ids match the frozen truth file")
Add-Check 'redis.db0_untouched_at_start' ((Redis 0 @('DBSIZE')) -eq '0') ("db0=$(Redis 0 @('DBSIZE')) db5=$(Redis $RedisDb @('DBSIZE')); keys of db$RedisDb before any read=$(Redis $RedisDb @('DBSIZE'))")

$instances = [ordered]@{}
$jstatProcs = [ordered]@{}
function Start-GroupInstance([string]$group, [int]$port) {
    $tag = "$RunId-$group"
    $cfg = Join-Path (Join-Path $RunRoot 'configs') ("p14a-$RunId-$group.properties")
    # write once: an existing probe config is a hard refusal (exit 2) before any process is started
    $events = Join-Path (Join-Path $RunRoot 'events') ("$tag.log")
    $txt = "# P1.4a $group : read-only detail scenario, no fixtures enabled`r`nevents.file=$($events -replace '\\', '/')`r`n"
    $null = Write-P14aOnce -Path $cfg -Text $txt -EntryPoint 'p14a-calibrate.ps1'
    $child = Invoke-ChildPowerShell $launcher @('-RunRoot', $RunRoot, '-Port', "$port", '-Tag', $tag, '-Group', $group, '-ProbeConfig', $cfg, '-WaitSeconds', '420') ("launch-" + $tag)
    $manPath = Join-Path (Join-Path $RunRoot 'logs') "$tag.instance.json"
    if (-not (Test-Path -LiteralPath $manPath)) {
        throw "launcher produced no instance manifest for group $group (exit $($child.exit)): $($child.output)"
    }
    $manObj = Get-Content -LiteralPath $manPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manObj.listening) {
        throw "instance for group $group never listened (exit $($child.exit)): $($child.output)"
    }
    if ($child.exit -ne 0) { Write-Host "note: the launcher process reported exit $($child.exit); the manifest (listening=true) is authoritative" }
    return [pscustomobject]@{ group = $group; tag = $tag; port = $port; pid = [int]$manObj.pid; manifest = $manPath; events = $events; base = "http://127.0.0.1:$port"; manifestObj = $manObj }
}

# The child process exit code is not reliable here (Start-Process -PassThru can leave ExitCode unknown while a
# grandchild JVM still holds the handle). Every collector run reports its own verdict in
# runs/<runId>/run-status.json, and THAT is what this script uses.
function Get-RunStatus([string]$childRunId) {
    $p = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $childRunId) 'run-status.json'
    if (-not (Test-Path -LiteralPath $p)) { return 'missing' }
    $s = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    return [string]$s.status
}

if (-not $SkipInstanceStart) {
    foreach ($pair in @(@('A', $PortA), @('B', $PortB))) {
        $inst = Start-GroupInstance $pair[0] $pair[1]
        $instances[$pair[0]] = $inst
        Add-Check ("instance.$($pair[0]).started") ($inst.pid -gt 0) ("group=$($pair[0]) port=$($inst.port) pid=$($inst.pid) cache_enabled=$($inst.manifestObj.cache_enabled)")
        if (Test-Path -LiteralPath $JstatExe) {
            $jf = Join-Path (Join-Path $RunRoot 'resources') ("jstat-$($pair[0]).txt")
            $jp = Start-Process -FilePath $JstatExe -ArgumentList @('-gc', "$($inst.pid)", '1000', '1200') -RedirectStandardOutput $jf -RedirectStandardError ($jf + '.err') -PassThru -WindowStyle Hidden
            $jstatProcs[$pair[0]] = [pscustomobject]@{ proc = $jp; file = $jf }
        }
    }
    $sameClasses = ($instances['A'].manifestObj.frozen_class_sha256 | ConvertTo-Json -Compress) -eq ($instances['B'].manifestObj.frozen_class_sha256 | ConvertTo-Json -Compress)
    Add-Check 'instance.a_and_b_load_identical_classes' $sameClasses `
        ("identical frozen class hashes for A and B; only article.detail.cache.enabled differs (A=$($instances['A'].manifestObj.cache_enabled) B=$($instances['B'].manifestObj.cache_enabled))")
} else {
    foreach ($g in @('A', 'B')) {
        $manPath = Join-Path (Join-Path $RunRoot 'logs') "$RunId-$g.instance.json"
        $man = Get-Content -LiteralPath $manPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $instances[$g] = [pscustomobject]@{ group = $g; tag = "$RunId-$g"; port = [int]$man.port; pid = [int]$man.pid; manifest = $manPath; events = (Join-Path (Join-Path $RunRoot 'events') "$RunId-$g.log"); base = "http://127.0.0.1:$($man.port)"; manifestObj = $man }
    }
}

function Invoke-Probe([string]$group, [string]$suffix, [string]$id) {
    $planPath = Join-Path $outDir ("probe-plan-" + $group + "-" + $suffix + ".json")
    $slot = [ordered]@{ slot_index = 0; planned_offset_ms = 0; article_id = [long]$id }
    $obj = [ordered]@{ kind = 'probe'; rate_per_second = 1; slot_count = 1; slots = @($slot) }
    $null = Write-P14aOnce -Path $planPath -Text (ConvertTo-Json $obj -Depth 6) -EntryPoint 'p14a-calibrate.ps1'
    $probeRun = "$RunId-PROBE-$group-$suffix"
    $child = Invoke-ChildPowerShell $collectorEntry @('-RunRoot', $RunRoot, '-RunId', $probeRun,
        '-Base', $instances[$group].base, '-Group', $group, '-PlanFile', $planPath, '-TruthFile', $truthFile,
        '-MaxInFlight', '1', '-RequestTimeoutMs', '15000', '-Phase', 'probe', '-TargetPid', "$($instances[$group].pid)", '-NoResources') 'probe-' + $probeRun
    $ledger = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $probeRun) 'responses.jsonl'
    if (-not (Test-Path -LiteralPath $ledger)) { throw "probe run produced no ledger: $($child.output)" }
    $rows = @(Read-P14aLedgerLines -Path $ledger)
    return ($rows[0] | ConvertFrom-Json)
}

$probeId = $allIds[0]
$probeKey = "$CacheKeyPrefix$probeId"
$keyBeforeProbe = (Redis $RedisDb @('EXISTS', $probeKey))
$probeA = Invoke-Probe 'A' 'ready' $probeId
$keyAfterA = (Redis $RedisDb @('EXISTS', $probeKey))
Add-Check 'gate.a_read_is_correct' ($probeA.verdict -eq 'correct' -and $probeA.code -eq 200 -and $probeA.id_is_string) `
    ("A verdict=$($probeA.verdict) code=$($probeA.code) id_is_string=$($probeA.id_is_string) content_sha256_match=$($probeA.content_sha256_match)")
Add-Check 'gate.a_creates_no_cache_key' ($keyAfterA -eq '0' -and $keyAfterA -eq $keyBeforeProbe) `
    ("EXISTS $probeKey before=$keyBeforeProbe after=$keyAfterA (cache disabled really writes nothing)")

$probeB = Invoke-Probe 'B' 'ready' $probeId
$keyAfterB = (Redis $RedisDb @('EXISTS', $probeKey))
Add-Check 'gate.b_read_is_correct' ($probeB.verdict -eq 'correct' -and $probeB.code -eq 200 -and $probeB.id_is_string) `
    ("B verdict=$($probeB.verdict) code=$($probeB.code) id_is_string=$($probeB.id_is_string) content_sha256_match=$($probeB.content_sha256_match)")
Add-Check 'gate.b_creates_the_cache_key' ($keyAfterB -eq '1') ("EXISTS $probeKey after the B read=$keyAfterB (cache enabled really writes the key)")

$coveragePlan = Plan-Of 1 'coverage'
$coverage = [ordered]@{}
foreach ($g in @('A', 'B')) {
    $covRun = "$RunId-COVERAGE-$g"
    $child = Invoke-ChildPowerShell $collectorEntry @('-RunRoot', $RunRoot, '-RunId', $covRun,
        '-Base', $instances[$g].base, '-Group', $g, '-PlanFile', $coveragePlan, '-TruthFile', $truthFile,
        '-MaxInFlight', "$MaxInFlight", '-RequestTimeoutMs', "$RequestTimeoutMs", '-Phase', 'coverage', '-TargetPid', "$($instances[$g].pid)") 'covering-' + $g
    $covStatus = Get-RunStatus $covRun
    $res = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $RunRoot 'runs') $covRun) 'collect-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $coverage[$g] = [ordered]@{ run_id = $covRun; status = $covStatus; offered = $res.stats.offered; completed = $res.stats.completed; correct = $res.stats.correct; dropped = $res.stats.dropped; failures = $res.stats.failures }
}
$keysAfterCoverage = Get-KeyState
Add-Check 'coverage.warmup_covered_all_ids' ($coverage['A'].correct -eq $allIds.Count -and $coverage['B'].correct -eq $allIds.Count) `
    ("A correct=$($coverage['A'].correct)/$($allIds.Count) B correct=$($coverage['B'].correct)/$($allIds.Count) (single-listed preset, never sampled)")
Add-Check 'coverage.b_cache_built_for_all_ids' ($keysAfterCoverage.ids_present -eq $allIds.Count) `
    ("cache keys present=$($keysAfterCoverage.ids_present)/$($allIds.Count) in db$RedisDb; only this card's ids exist")

$allSegments = @(
    [ordered]@{ rate = 5; order = @('A', 'B') },
    [ordered]@{ rate = 20; order = @('B', 'A') },
    [ordered]@{ rate = 50; order = @('A', 'B') }
)
$segments = @($allSegments | Where-Object { $Rates -contains [int]$_.rate })
if ($segments.Count -lt 1) { Write-Host "REFUSED: -Rates produced no segment (given: $($Rates -join ','))"; exit 2 }
$segmentResults = New-Object System.Collections.ArrayList
$stoppedEarly = $false
$stopReason = ''
foreach ($seg in $segments) {
    if ($stoppedEarly) { break }
    $rate = [int]$seg.rate
    $warmPlan = Plan-Of $rate 'warmup'
    $samplePlan = Plan-Of $rate 'sample'
    $truthBad = Get-TruthMismatch
    $segRes = [ordered]@{
        rate_per_second = $rate
        order = ($seg.order -join '>')
        truth_mismatch = @($truthBad)
        keys_before = (Get-KeyState)
        groups = [ordered]@{}
        valid = $true
        invalid_reason = ''
    }
    foreach ($g in $seg.order) {
        $others = @($seg.order | Where-Object { $_ -ne $g })
        $idlePid = if ($others.Count -ge 1) { $instances[$others[0]].pid } else { 0 }
        $warmRun = "$RunId-R$rate-WARM-$g"
        $warmChild = Invoke-ChildPowerShell $collectorEntry @('-RunRoot', $RunRoot, '-RunId', $warmRun,
            '-Base', $instances[$g].base, '-Group', $g, '-PlanFile', $warmPlan, '-TruthFile', $truthFile,
            '-MaxInFlight', "$MaxInFlight", '-RequestTimeoutMs', "$RequestTimeoutMs", '-Phase', 'warmup', '-TargetPid', "$($instances[$g].pid)", '-IdlePid', "$idlePid")
        $warmStatus = Get-RunStatus $warmRun
        $sampleRun = "$RunId-R$rate-SAMPLE-$g"
        $sampleChild = Invoke-ChildPowerShell $collectorEntry @('-RunRoot', $RunRoot, '-RunId', $sampleRun,
            '-Base', $instances[$g].base, '-Group', $g, '-PlanFile', $samplePlan, '-TruthFile', $truthFile,
            '-MaxInFlight', "$MaxInFlight", '-RequestTimeoutMs', "$RequestTimeoutMs", '-Phase', 'sample', '-TargetPid', "$($instances[$g].pid)", '-IdlePid', "$idlePid")
        $sampleStatus = Get-RunStatus $sampleRun
        $sRes = Get-Content -LiteralPath (Join-Path (Join-Path (Join-Path $RunRoot 'runs') $sampleRun) 'collect-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $saturated = $false
        $ccpuMax = -1
        $resCsv = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $sampleRun) 'resources.csv'
        if (Test-Path -LiteralPath $resCsv) {
            $rows = @(Import-Csv -LiteralPath $resCsv)
            $streak = 0
            foreach ($row in $rows) {
                $v = 0.0
                [void][double]::TryParse([string]$row.collector_cpu_percent, [ref]$v)
                if ($v -gt $ccpuMax) { $ccpuMax = $v }
                if ($v -ge $CollectorCpuStopPercent) { $streak++ } else { $streak = 0 }
                if ($streak -ge $CollectorCpuStopSeconds) { $saturated = $true }
            }
        }
        $segRes.groups[$g] = [ordered]@{
            warmup_run = $warmRun; warmup_status = $warmStatus
            sample_run = $sampleRun; sample_status = $sampleStatus
            offered = $sRes.stats.offered; started = $sRes.stats.started; completed = $sRes.stats.completed
            dropped = $sRes.stats.dropped; correct = $sRes.stats.correct; failures = $sRes.stats.failures; timeouts = $sRes.stats.timeouts
            verdicts = $sRes.stats.verdict_counts
            latency_correct_ms = $sRes.stats.latency_correct_ms
            schedule_lag_ms = $sRes.stats.schedule_lag_ms
            drain_ms = $sRes.stats.drain_ms
            declared_window_ms = $sRes.stats.declared_window_ms
            window_source = $sRes.stats.window_source
            completed_in_window = $sRes.stats.completed_in_window
            completed_after_window = $sRes.stats.completed_after_window
            in_window_qps = $sRes.stats.in_window_qps
            dropped_cap_full = $sRes.stats.dropped_cap_full
            dropped_scheduler_missed = $sRes.stats.dropped_scheduler_missed
            loop_max_interval_ms = $sRes.stats.loop_max_interval_ms
            resource_sample_max_cost_ms = $sRes.stats.resource_sample_max_cost_ms
            ledger_flush_policy = $sRes.stats.ledger_flush_policy
            idle_pid = $idlePid
            collector_cpu_percent_max = $ccpuMax
            collector_saturated = $saturated
        }
        if ($warmStatus -ne 'passed' -or $sampleStatus -ne 'passed') { $segRes.valid = $false; $segRes.invalid_reason += "$g collector status warm=$warmStatus sample=$sampleStatus; " }
        if ([int]$sRes.stats.correct -ne [int]$sRes.stats.completed) { $segRes.valid = $false; $segRes.invalid_reason += "$g correct=$($sRes.stats.correct)/$($sRes.stats.completed); " }
        if ([int]$sRes.stats.dropped -gt 0) { $segRes.valid = $false; $segRes.invalid_reason += "$g dropped=$($sRes.stats.dropped); " }
        if ([int]$sRes.stats.timeouts -gt 0) { $segRes.valid = $false; $segRes.invalid_reason += "$g timeouts=$($sRes.stats.timeouts); " }
        if (-not [bool]$sRes.stats.window_counts_add_up) { $segRes.valid = $false; $segRes.invalid_reason += ('{0} window counts do not add up (in={1} after={2} total={3}); ' -f $g, $sRes.stats.completed_in_window, $sRes.stats.completed_after_window, $sRes.stats.completed) }
        if ($saturated) { $segRes.valid = $false; $segRes.invalid_reason += "$g collector cpu >= $CollectorCpuStopPercent% for >= $CollectorCpuStopSeconds s; " }
    }
    if (@($segRes.truth_mismatch).Count -gt 0) { $segRes.valid = $false; $segRes.invalid_reason += 'data changed during the segment; ' }
    $null = $segmentResults.Add($segRes)
    Add-Check ("segment.r$rate.valid") $segRes.valid ("rate=$rate order=$($segRes.order) valid=$($segRes.valid) reason=$($segRes.invalid_reason)")
    if (-not $segRes.valid) { $stoppedEarly = $true; $stopReason = "rate=$rate invalid: $($segRes.invalid_reason)" }
}

$truthBadEnd = Get-TruthMismatch
Add-Check 'data.truth_unchanged_after_calibration' ($truthBadEnd.Count -eq 0) ("all $($allIds.Count) ids still match the frozen truth ($($truthBadEnd.Count) mismatches)")
$keysEnd = Get-KeyState
Add-Check 'redis.key_set_is_exactly_this_card' ($keysEnd.ids_present -eq $allIds.Count) `
    ("db$RedisDb present=$($keysEnd.ids_present)/$($allIds.Count) before restore (no other key created)")

$resourceSummary = [ordered]@{}
foreach ($seg in $segmentResults) {
    foreach ($g in $seg.groups.Keys) {
        $sampleRun = $seg.groups[$g].sample_run
        $csv = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $sampleRun) 'resources.csv'
        if (-not (Test-Path -LiteralPath $csv)) { continue }
        $rows = @(Import-Csv -LiteralPath $csv)
        $tcpu = @(); $ccpu = @(); $tws = @(); $icpu = @(); $tcore = @(); $ccore = @(); $scost = @(); $sdur = @()
        foreach ($r in $rows) {
            if ("$($r.target_cpu_percent)" -ne '') { $tcpu += [double]$r.target_cpu_percent }
            if ("$($r.collector_cpu_percent)" -ne '') { $ccpu += [double]$r.collector_cpu_percent }
            if ("$($r.target_working_set_mb)" -ne '') { $tws += [double]$r.target_working_set_mb }
            if ("$($r.idle_cpu_total_ms)" -ne '') { $icpu += [long]$r.idle_cpu_total_ms }
            if ("$($r.collector_core_equivalents)" -ne '') { $ccore += [double]$r.collector_core_equivalents }
            if ("$($r.target_core_equivalents)" -ne '') { $tcore += [double]$r.target_core_equivalents }
            if ("$($r.sample_cost_ms)" -ne '') { $scost += [long]$r.sample_cost_ms }
            if ("$($r.sample_duration_ms)" -ne '') { $sdur += [long]$r.sample_duration_ms }
        }
        $resourceSummary["r$($seg.rate_per_second)-$g"] = [ordered]@{
            sample_run = $sampleRun
            rows = $rows.Count
            target_cpu_percent_max = $(if ($tcpu.Count -gt 0) { ($tcpu | Measure-Object -Maximum).Maximum } else { -1 })
            collector_cpu_percent_max = $(if ($ccpu.Count -gt 0) { ($ccpu | Measure-Object -Maximum).Maximum } else { -1 })
            target_working_set_mb_max = $(if ($tws.Count -gt 0) { ($tws | Measure-Object -Maximum).Maximum } else { -1 })
            collector_core_equivalents_max = $(if ($ccore.Count -gt 0) { ($ccore | Measure-Object -Maximum).Maximum } else { -1 })
            target_core_equivalents_max = $(if ($tcore.Count -gt 0) { ($tcore | Measure-Object -Maximum).Maximum } else { -1 })
            resource_sample_cost_ms_max = $(if ($scost.Count -gt 0) { ($scost | Measure-Object -Maximum).Maximum } else { -1 })
            resource_sample_duration_ms_max = $(if ($sdur.Count -gt 0) { ($sdur | Measure-Object -Maximum).Maximum } else { -1 })
            idle_instance_cpu_total_ms_first_last = $(if ($icpu.Count -gt 0) { "$($icpu[0])->$($icpu[$icpu.Count - 1])" } else { 'n/a' })
            note = 'idle_* columns describe the OTHER group instance (same build, not receiving load in this segment)'
        }
    }
}

$jstatSummary = [ordered]@{}
foreach ($g in @('A', 'B')) {
    if ($jstatProcs.Contains($g)) {
        $p = $jstatProcs[$g].proc
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 200
        $jstatSummary[$g] = [ordered]@{ file = (Split-Path -Leaf $jstatProcs[$g].file); lines = @([System.IO.File]::ReadAllLines($jstatProcs[$g].file)).Count }
    }
}

if (-not $SkipRestore) {
    $deletedIds = 0
    foreach ($id in $allIds) {
        $null = Redis $RedisDb @('DEL', "$CacheKeyPrefix$id")
        $null = Redis $RedisDb @('DEL', "$CacheKeyPrefix$id`:lock")
        $deletedIds++
    }
    $db5After = Redis $RedisDb @('DBSIZE')
    $db0After = Redis 0 @('DBSIZE')
    Add-Check 'restore.exact_keys_removed_no_flushdb' ($db5After -eq '0' -and $db0After -eq '0') `
        ("deleted the $deletedIds article keys one by one (plus any :lock of the same ids); db$RedisDb=$db5After db0=$db0After; FLUSHDB was never used")
}
if (-not $SkipInstanceStart) {
    foreach ($g in @('A', 'B')) {
        if (Get-Process -Id $instances[$g].pid -ErrorAction SilentlyContinue) { Stop-Process -Id $instances[$g].pid -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 1200
    $stillListening = @($instances.Values | Where-Object { Get-NetTCPConnection -LocalPort $_.port -State Listen -ErrorAction SilentlyContinue }).Count
    Add-Check 'cleanup.own_instances_stopped' ($stillListening -eq 0) ("A/$PortA and B/$PortB listening count=$stillListening; only the two processes this card started were stopped")
}

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    scope = 'P1.4a limited calibration: A=article.detail.cache.enabled=false vs B=true on the SAME frozen code; scheduling observations only, not formal performance results'
    limits = [ordered]@{ rates = ($Rates -join ','); max_in_flight = $MaxInFlight; request_timeout_ms = $RequestTimeoutMs; collector_cpu_stop_percent = $CollectorCpuStopPercent; collector_cpu_stop_seconds = $CollectorCpuStopSeconds; redis_db = $RedisDb }
    truth = [ordered]@{ file = 'plans/ids-truth.json'; sha256 = (Get-Sha $truthFile); targets = $allIds.Count }
    plans_index_sha256 = (Get-Sha (Join-Path $plansDir 'plans-index.json'))
    instances = [ordered]@{
        A = [ordered]@{ port = $instances['A'].port; pid = $instances['A'].pid; cache_enabled = $instances['A'].manifestObj.cache_enabled; manifest = (Split-Path -Leaf $instances['A'].manifest); events = (Split-Path -Leaf $instances['A'].events) }
        B = [ordered]@{ port = $instances['B'].port; pid = $instances['B'].pid; cache_enabled = $instances['B'].manifestObj.cache_enabled; manifest = (Split-Path -Leaf $instances['B'].manifest); events = (Split-Path -Leaf $instances['B'].events) }
    }
    gate = [ordered]@{ probe_id = $probeId; a = $probeA; b = $probeB; key_exists_before = $keyBeforeProbe; key_exists_after_a = $keyAfterA; key_exists_after_b = $keyAfterB }
    coverage = $coverage
    keys_after_coverage = $keysAfterCoverage
    segments = @($segmentResults)
    stopped_early = $stoppedEarly
    stop_reason = $stopReason
    keys_before_restore = $keysEnd
    resources = $resourceSummary
    jstat = $jstatSummary
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'calibration-result.json') -Text ($result | ConvertTo-Json -Depth 10)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'calibration-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
