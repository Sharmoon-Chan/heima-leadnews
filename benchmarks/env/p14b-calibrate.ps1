# P1.4b short calibration: A (article.detail.cache.enabled=false) vs B (true) on the SAME frozen code, TWO pairs per
# rate, both groups behind an independent observer (ASCII only).
#
# Design (frozen by the card BEFORE anything was measured):
#   * rates 5 then 20 req/s; the 20 tier is only attempted when the whole 5 tier passed;
#   * per rate TWO pairs: pair 1 A->B, pair 2 B->A. Each group does a 10 s warmup ledger and a 20 s sampled ledger,
#     so the sampled slot count is 4 * rate * 20 s (5 -> 400, 20 -> 1600; the card allows at most 2000);
#   * 16 in flight, 5 s per-request timeout, the only business variable is the cache switch;
#   * a segment is valid only when BOTH groups are fully correct, with zero drops / failures / timeouts, and when the
#     pre-registered measurement budget holds: dispatch schedule lag p95 <= 5 ms, p99 <= 10 ms, max <= 25 ms, and
#     body-ready -> loop observation p95 <= 5 ms, max <= 25 ms. The budget is NOT relaxed, and a failing segment stops
#     the escalation and is recorded as invalid (no re-send, no best-of-N);
#   * the common business P95 SLO candidate is 60 ms for A and B and is NOT raised after seeing results;
#   * the protocol proposal is written only for a rate whose every segment passed; its status is
#     proposal_pending_owner_acceptance and this script never runs the formal three rounds.
#
# Exit codes: 0 = every attempted segment valid, 1 = something failed (details in calibration-result-full.json;
# calibration-result.json is the summariser input), 2 = refused.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts',
    [int]$PortA = 51821,
    [int]$PortB = 51822,
    [int]$MaxInFlight = 16,
    [int]$RequestTimeoutMs = 5000,
    [string]$RatesCsv = '5,20',
    [int[]]$Rates = @(),
    [double]$DispatchLagP95 = 5.0,
    [double]$DispatchLagP99 = 10.0,
    [double]$DispatchLagMax = 25.0,
    [double]$ObserveLagP95 = 5.0,
    [double]$ObserveLagMax = 25.0,
    [double]$SloP95CandidateMs = 60.0,
    [int]$RedisDb = 5,
    [string]$CacheKeyPrefix = 'article:detail:',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    [string]$JstatExe = 'D:\Soft\Java\jdk-1.8\bin\jstat.exe',
    [switch]$SkipInstanceStart,
    [switch]$SkipRestore,
    [switch]$SkipSummarize
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

$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'p14b-calibrate.ps1'
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (-not (Test-UnderRoot $RunRoot $ArtifactsRoot)) { Write-Host 'REFUSED: run root outside the artifacts root'; exit 2 }
if ($null -eq $Rates -or $Rates.Count -eq 0) {
    if ($RatesCsv -notmatch '^\d+(,\d+)*$') {
        Write-Host "REFUSED: bad -RatesCsv '$RatesCsv' (pass -RatesCsv '5,20')"
        exit 2
    }
    $Rates = @($RatesCsv -split ',' | ForEach-Object { [int]$_ })
}
if (@($Rates | Where-Object { $_ -ne 5 -and $_ -ne 20 }).Count -gt 0) { Write-Host 'REFUSED: this card attempts only 5 and 20 req/s'; exit 2 }

# ---- P1.4b section 8 part A: the private measurement gate is REAL admission, not a report line -------------------
# A private control whose quality gates failed must not be followed by a business calibration. The gate file is written
# by the private validation step of this root; if it is missing or not passed, this entry refuses BEFORE any SQL, Redis,
# instance start or request.
$gatePath = Join-Path (Join-Path $RunRoot 'inputs') 'private-measurement-gate.json'
if (-not (Test-Path -LiteralPath $gatePath)) {
    Write-Host "REFUSED: the private measurement gate has not been recorded: $gatePath"
    Write-Host 'REFUSED_STAGE=measurement-gate'
    exit 2
}
$gateObj = Get-Content -LiteralPath $gatePath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not [bool]$gateObj.passed) {
    Write-Host ("REFUSED: the private measurement gate did NOT pass ({0}); a business calibration must not start" -f [string]$gateObj.reason)
    Write-Host 'REFUSED_STAGE=measurement-gate'
    exit 2
}

$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.4b-calibrate' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ port_a = $PortA; port_b = $PortB; max_in_flight = $MaxInFlight; request_timeout_ms = $RequestTimeoutMs; redis_db = $RedisDb; rates = ($Rates -join ',') } `
        -Targets @() -DataSet $Database
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-58} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'fail' }), $d
}

$script:childSeq = 0
function Read-SharedLines([string]$path) {
    $fs = $null; $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
        return @($sr.ReadToEnd() -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    } catch { return @("unreadable: $($_.Exception.Message)") } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}
# Children are NEVER captured through a pipe: a grandchild JVM inherits the write handle and the pipe never closes.
function Invoke-ChildPowerShell([string]$scriptPath, [string[]]$childArgs, [string]$label) {
    $script:childSeq++
    $safe = ($label -replace '[^A-Za-z0-9._-]', '_')
    $o = Join-Path $outDir (("child-{0:d2}-{1}.out") -f $script:childSeq, $safe)
    $e = "$o.err"
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $o -RedirectStandardError $e `
        -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $childArgs)
    $deadline = (Get-Date).AddSeconds(1800)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    $proc.Refresh()
    $exitCode = -1
    try { if ($null -ne $proc.ExitCode) { $exitCode = [int]$proc.ExitCode } } catch { $exitCode = -1 }
    $tail = ''
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
$collectorEntry = Join-Path (Join-Path $benchDir 'load') 'p14b-collect.ps1'
$summarizerEntry = Join-Path (Join-Path $benchDir 'env') 'p14a-summarize.ps1'
$launcher = Join-Path $PSScriptRoot 'start-p14a-instance.ps1'

function Get-TruthMismatch {
    $idList = ($allIds | ForEach-Object { "$_" }) -join ','
    $rows = Sql ("SELECT a.id, a.views, a.likes, a.comment, a.collection, a.channel_id, a.author_id, SHA2(IFNULL(c.content,''),256), LENGTH(IFNULL(c.content,'')) FROM $Database.ap_article a LEFT JOIN $Database.ap_article_content c ON c.article_id=a.id WHERE a.id IN ($idList) ORDER BY a.id;")
    $cur = @{}
    foreach ($line in ($rows -split "`r?`n")) {
        if ($line.Trim() -eq '') { continue }
        $f = $line -split "`t"
        if ($f.Length -lt 9) { continue }
        $cur[[string]$f[0]] = "$($f[1])|$($f[2])|$($f[3])|$($f[4])|$($f[5])|$($f[6])|$($f[7])|$($f[8])"
    }
    $bad = New-Object System.Collections.ArrayList
    foreach ($t in $truth.targets) {
        $want = "$($t.views)|$($t.likes)|$($t.comment)|$($t.collection)|$($t.channel_id)|$($t.author_id)|$([string]$t.content_sha256)|$($t.content_bytes)"
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

$truthStart = @(Get-TruthMismatch)
Add-Check 'data.truth_matches_database' ($truthStart.Count -eq 0) ("all $($allIds.Count) ids match the frozen truth (four counters, channel, author, content SHA256 and UTF-8 byte length); mismatches=$($truthStart.Count)")
Add-Check 'redis.db0_untouched_at_start' ((Redis 0 @('DBSIZE')) -eq '0') ("db0=$(Redis 0 @('DBSIZE')) db$RedisDb=$(Redis $RedisDb @('DBSIZE'))")

$instances = [ordered]@{}
$jstatProcs = [ordered]@{}
function Start-GroupInstance([string]$group, [int]$port) {
    $tag = "$RunId-$group"
    $cfg = Join-Path (Join-Path $RunRoot 'configs') ("p14b-$RunId-$group.properties")
    $events = Join-Path (Join-Path $RunRoot 'events') ("$tag.log")
    $txt = "# P1.4b $group : read-only detail scenario, no fixtures enabled`r`nevents.file=$($events.Replace('\', '/'))`r`n"
    $null = Write-P14aOnce -Path $cfg -Text $txt -EntryPoint 'p14b-calibrate.ps1'
    $child = Invoke-ChildPowerShell $launcher @('-RunRoot', $RunRoot, '-Port', "$port", '-Tag', $tag, '-Group', $group, '-ProbeConfig', $cfg, '-WaitSeconds', '420') ("launch-" + $tag)
    $manPath = Join-Path (Join-Path $RunRoot 'logs') "$tag.instance.json"
    if (-not (Test-Path -LiteralPath $manPath)) { throw "launcher produced no instance manifest for group $group (exit $($child.exit)): $($child.output)" }
    $manObj = Get-Content -LiteralPath $manPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manObj.listening) { throw "instance for group $group never listened (exit $($child.exit)): $($child.output)" }
    if ($child.exit -ne 0) { Write-Host "note: the launcher process reported exit $($child.exit); the manifest (listening=true) is authoritative" }
    return [pscustomobject]@{ group = $group; tag = $tag; port = $port; pid = [int]$manObj.pid; manifest = $manPath; events = $events; base = "http://127.0.0.1:$port"; manifestObj = $manObj }
}
function Get-RunStatus([string]$childRunId) {
    $p = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $childRunId) 'run-status.json'
    if (-not (Test-Path -LiteralPath $p)) { return 'missing' }
    $s = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    return [string]$s.status
}

# Diagnostics only (never a gate): each collector run is a fresh process, so its first records also pay JIT/compile
# cost inside the dispatch loop. The pre-registered budget is judged on the WHOLE run; this block only shows how much
# of an overshoot sits in the first slots, so a reader cannot mistake one cause for another.
function Get-LagDiag([string]$childRunId, [int]$skip = 20) {
    $p = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $childRunId) 'responses.jsonl'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $cr = Get-CollectResult $childRunId
    if ($null -eq $cr) { return $null }
    $startMono = [double]$cr.stats.monotonic.run_start_mono_ms
    $all = New-Object System.Collections.ArrayList
    $head = New-Object System.Collections.ArrayList
    $tail = New-Object System.Collections.ArrayList
    foreach ($l in (Read-P14aLedgerLines -Path $p)) {
        $r = $l | ConvertFrom-Json
        if ([string]$r.kind -ne 'response') { continue }
        $lag = [Math]::Round([double]$r.dispatch_mono_ms - $startMono - [double]$r.planned_offset_ms, 3)
        $null = $all.Add($lag)
        if ([int]$r.seq -le $skip) { $null = $head.Add($lag) } else { $null = $tail.Add($lag) }
    }
    return [ordered]@{
        skip = $skip
        n = $all.Count
        whole_run = (Get-P14aPercentiles -Values ([double[]]$all.ToArray()) -Percents @(50, 95, 99))
        first_slots_lag_ms = @($head | ForEach-Object { $_ })
        after_skip = (Get-P14aPercentiles -Values ([double[]]$tail.ToArray()) -Percents @(50, 95, 99))
        note = 'diagnostic only: the gate is judged on the WHOLE run (stats.dispatch_schedule_lag_mono_ms); excluding the first slots is NOT applied to the gate'
    }
}
function Get-CollectResult([string]$childRunId) {
    $p = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $childRunId) 'collect-result.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
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
        ("identical frozen class hashes; only article.detail.cache.enabled differs (A=$($instances['A'].manifestObj.cache_enabled) B=$($instances['B'].manifestObj.cache_enabled))")
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
    $null = Write-P14aOnce -Path $planPath -Text (ConvertTo-Json $obj -Depth 6) -EntryPoint 'p14b-calibrate.ps1'
    $probeRun = "$RunId-PROBE-$group-$suffix"
    $null = Invoke-ChildPowerShell $collectorEntry @('-RunRoot', $RunRoot, '-RunId', $probeRun,
        '-Base', $instances[$group].base, '-Group', $group, '-PlanFile', $planPath, '-TruthFile', $truthFile,
        '-MaxInFlight', '1', '-RequestTimeoutMs', '15000', '-Phase', 'probe', '-TargetPid', "$($instances[$group].pid)", '-NoObserver') ('probe-' + $probeRun)
    $ledger = Join-Path (Join-Path (Join-Path $RunRoot 'runs') $probeRun) 'responses.jsonl'
    if (-not (Test-Path -LiteralPath $ledger)) { throw "probe run produced no ledger" }
    $rows = @(Read-P14aLedgerLines -Path $ledger)
    return ($rows[0] | ConvertFrom-Json)
}

$probeId = $allIds[0]
$probeKey = "$CacheKeyPrefix$probeId"
$keyBeforeProbe = (Redis $RedisDb @('EXISTS', $probeKey))
$probeA = Invoke-Probe 'A' 'ready' $probeId
$keyAfterA = (Redis $RedisDb @('EXISTS', $probeKey))
Add-Check 'gate.a_read_is_correct' ($probeA.verdict -eq 'correct' -and $probeA.code -eq 200 -and $probeA.id_is_string) ("A verdict=$($probeA.verdict) code=$($probeA.code) body_ready_ms=$($probeA.body_latency_ms)")
Add-Check 'gate.a_creates_no_cache_key' ($keyAfterA -eq '0' -and $keyAfterA -eq $keyBeforeProbe) ("EXISTS $probeKey before=$keyBeforeProbe after=$keyAfterA")
$probeB = Invoke-Probe 'B' 'ready' $probeId
$keyAfterB = (Redis $RedisDb @('EXISTS', $probeKey))
Add-Check 'gate.b_read_is_correct' ($probeB.verdict -eq 'correct' -and $probeB.code -eq 200 -and $probeB.id_is_string) ("B verdict=$($probeB.verdict) code=$($probeB.code) body_ready_ms=$($probeB.body_latency_ms)")
Add-Check 'gate.b_creates_the_cache_key' ($keyAfterB -eq '1') ("EXISTS $probeKey after the B read=$keyAfterB")

$coveragePlan = Plan-Of 1 'coverage'
$coverage = [ordered]@{}
foreach ($g in @('A', 'B')) {
    $covRun = "$RunId-COVERAGE-$g"
    $null = Invoke-ChildPowerShell $collectorEntry @('-RunRoot', $RunRoot, '-RunId', $covRun,
        '-Base', $instances[$g].base, '-Group', $g, '-PlanFile', $coveragePlan, '-TruthFile', $truthFile,
        '-MaxInFlight', "$MaxInFlight", '-RequestTimeoutMs', "$RequestTimeoutMs", '-Phase', 'coverage', '-TargetPid', "$($instances[$g].pid)") ('covering-' + $g)
    $covStatus = Get-RunStatus $covRun
    $res = Get-CollectResult $covRun
    $coverage[$g] = [ordered]@{ run_id = $covRun; status = $covStatus; offered = $res.stats.offered; completed = $res.stats.completed; correct = $res.stats.correct; dropped = $res.stats.dropped; failures = $res.stats.failures }
}
$keysAfterCoverage = Get-KeyState
Add-Check 'coverage.warmup_covered_all_ids' ($coverage['A'].correct -eq $allIds.Count -and $coverage['B'].correct -eq $allIds.Count) ("A correct=$($coverage['A'].correct)/$($allIds.Count) B correct=$($coverage['B'].correct)/$($allIds.Count) (single-listed preset, never sampled)")
Add-Check 'coverage.b_cache_built_for_all_ids' ($keysAfterCoverage.ids_present -eq $allIds.Count) ("cache keys present=$($keysAfterCoverage.ids_present)/$($allIds.Count) in db$RedisDb")

# ---- the frozen pair schedule: per rate pair1 A->B, pair2 B->A ------------------------------------------------
$schedule = New-Object System.Collections.ArrayList
foreach ($rate in $Rates) {
    $null = $schedule.Add([ordered]@{ rate = [int]$rate; pair = 1; order = @('A', 'B') })
    $null = $schedule.Add([ordered]@{ rate = [int]$rate; pair = 2; order = @('B', 'A') })
}
$segmentResults = New-Object System.Collections.ArrayList
$stoppedEarly = $false
$stopReason = ''
$sampleSlots = 0
# the calibration self-report consumed by p14a-summarize (group self-report is filled from the sample runs)
$segmentsForSummary = [ordered]@{}

foreach ($seg in $schedule) {
    if ($stoppedEarly) { break }
    $rate = [int]$seg.rate
    $warmPlan = Plan-Of $rate 'warmup'
    $samplePlan = Plan-Of $rate 'sample'
    $truthBad = @(Get-TruthMismatch)
    $segKey = "r$rate-p$($seg.pair)"
    $segRes = [ordered]@{
        rate_per_second = $rate
        pair = $seg.pair
        order = ($seg.order -join '>')
        truth_mismatch = $truthBad
        keys_before = (Get-KeyState)
        groups = [ordered]@{}
        valid = $true
        invalid_reason = ''
        gates = [ordered]@{}
    }
    foreach ($g in $seg.order) {
        $others = @($seg.order | Where-Object { $_ -ne $g })
        $idlePid = if ($others.Count -ge 1) { $instances[$others[0]].pid } else { 0 }
        $warmRun = "$RunId-$segKey-WARM-$g"
        $warmChild = Invoke-ChildPowerShell $collectorEntry @('-RunRoot', $RunRoot, '-RunId', $warmRun,
            '-Base', $instances[$g].base, '-Group', $g, '-PlanFile', $warmPlan, '-TruthFile', $truthFile,
            '-MaxInFlight', "$MaxInFlight", '-RequestTimeoutMs', "$RequestTimeoutMs", '-Phase', 'warmup', '-TargetPid', "$($instances[$g].pid)", '-IdlePid', "$idlePid")
        $warmStatus = Get-RunStatus $warmRun
        $sampleRun = "$RunId-$segKey-SAMPLE-$g"
        $sampleChild = Invoke-ChildPowerShell $collectorEntry @('-RunRoot', $RunRoot, '-RunId', $sampleRun,
            '-Base', $instances[$g].base, '-Group', $g, '-PlanFile', $samplePlan, '-TruthFile', $truthFile,
            '-MaxInFlight', "$MaxInFlight", '-RequestTimeoutMs', "$RequestTimeoutMs", '-Phase', 'sample', '-TargetPid', "$($instances[$g].pid)", '-IdlePid', "$idlePid")
        $sampleStatus = Get-RunStatus $sampleRun
        $sRes = Get-CollectResult $sampleRun
        if ($null -eq $sRes) { throw "sample run $sampleRun produced no collect-result (warm exit=$($warmChild.exit) sample exit=$($sampleChild.exit)): $($sampleChild.output)" }
        $sampleSlots += [int]$sRes.stats.completed
        $lag = $sRes.stats.dispatch_schedule_lag_mono_ms
        $olag = $sRes.stats.observe_lag_ms
        $gGates = [ordered]@{
            collector_status_passed = ($sampleStatus -eq 'passed')
            correct_is_100_percent = ([int]$sRes.stats.correct -eq [int]$sRes.stats.completed -and [int]$sRes.stats.completed -gt 0)
            zero_failures = ([int]$sRes.stats.failures -eq 0)
            zero_timeouts = ([int]$sRes.stats.timeouts -eq 0)
            zero_drops = ([int]$sRes.stats.dropped -eq 0)
            window_adds_up = [bool]$sRes.stats.window_counts_add_up
            dispatch_lag_p95 = ([double]$lag.p95 -le $DispatchLagP95)
            dispatch_lag_p99 = ([double]$lag.p99 -le $DispatchLagP99)
            dispatch_lag_max = ([double]$lag.max -le $DispatchLagMax)
            observe_lag_p95 = ([double]$olag.p95 -le $ObserveLagP95)
            observe_lag_max = ([double]$olag.max -le $ObserveLagMax)
            body_ready_complete = ([int]$sRes.stats.body_ready_missing -eq 0)
            slo_p95_candidate = ([double]$sRes.stats.body_latency_correct_ms.p95 -le $SloP95CandidateMs)
            observer_identity = ([bool]$sRes.observer.enabled -and [bool]$sRes.observer.pid_identity_matches -and $sRes.observer.summary -ne 'MISSING')
        }
        $failedGates = @($gGates.Keys | Where-Object { -not [bool]$gGates[$_] })
        $segRes.groups[$g] = [ordered]@{
            warmup_run = $warmRun; warmup_status = $warmStatus
            sample_run = $sampleRun; sample_status = $sampleStatus
            offered = $sRes.stats.offered; started = $sRes.stats.started; completed = $sRes.stats.completed
            dropped = $sRes.stats.dropped; correct = $sRes.stats.correct; failures = $sRes.stats.failures; timeouts = $sRes.stats.timeouts
            body_latency_ms = $sRes.stats.body_latency_ms
            body_latency_correct_ms = $sRes.stats.body_latency_correct_ms
            latency_correct_ms_legacy = $sRes.stats.latency_correct_ms
            dispatch_lag_mono_ms = $lag
            observe_lag_ms = $olag
            persist_lag_ms = $sRes.stats.persist_lag_ms
            flush_lag_max_ms = $sRes.stats.flush_lag_max_ms
            dispatch_lag_diagnostic = (Get-LagDiag $sampleRun 20)
            observer = [ordered]@{ pid = $sRes.observer.pid; samples = $sRes.observer.samples; gap_max_ms = $sRes.observer.gap_max_ms; sample_cost_max_ms = $sRes.observer.sample_cost_max_ms; sample_cost_mean_ms = $sRes.observer.sample_cost_mean_ms }
            target_pid = $instances[$g].pid
            idle_pid = $idlePid
            gates = $gGates
            failed_gates = $failedGates
        }
        if ($failedGates.Count -gt 0) {
            $segRes.valid = $false
            $segRes.invalid_reason += ("$g failed: $($failedGates -join ',') (correct={0}/{1} dropped={2} timeouts={3} body p95={4} dispatch lag p95={5} p99={6} max={7}) " -f `
                    $sRes.stats.correct, $sRes.stats.completed, $sRes.stats.dropped, $sRes.stats.timeouts, $sRes.stats.body_latency_correct_ms.p95, $lag.p95, $lag.p99, $lag.max)
        }
    }
    if ($truthBad.Count -gt 0) { $segRes.valid = $false; $segRes.invalid_reason += 'data changed during the segment; ' }
    $null = $segmentResults.Add($segRes)
    Add-Check ("segment.r$rate.p$($seg.pair).valid") $segRes.valid ("rate=$rate pair=$($seg.pair) order=$($segRes.order) valid=$($segRes.valid) reason=$($segRes.invalid_reason)")
    if (-not $segRes.valid) { $stoppedEarly = $true; $stopReason = "rate=$rate pair=$($seg.pair) invalid: $($segRes.invalid_reason)" }
}

$truthEnd = @(Get-TruthMismatch)
Add-Check 'data.truth_unchanged_after_calibration' ($truthEnd.Count -eq 0) ("all $($allIds.Count) ids still match the frozen truth (mismatches=$($truthEnd.Count))")
$keysEnd = Get-KeyState
Add-Check 'redis.key_set_is_exactly_this_card' ($keysEnd.ids_present -eq $allIds.Count) ("db$RedisDb present=$($keysEnd.ids_present)/$($allIds.Count) before restore")
Add-Check 'schedule.sample_slots_within_the_card_limit' ($sampleSlots -le 2000) ("sampled slots actually completed=$sampleSlots (card limit 2000 for 5+20; warmup and coverage not counted)")

# the calibration self-report consumed by the independent summariser (drop/admission re-judgement)
foreach ($rate in $Rates) {
    $groups = [ordered]@{}
    foreach ($r in $segmentResults) {
        if ([int]$r.rate_per_second -ne [int]$rate) { continue }
        foreach ($g in $r.groups.Keys) {
            $gg = $r.groups[$g]
            $groups[$g] = [ordered]@{ sample_run = $gg.sample_run; offered = $gg.offered; started = $gg.started; completed = $gg.completed; dropped = $gg.dropped; correct = $gg.correct; timeouts = $gg.timeouts }
        }
    }
    $rateSegs = @($segmentResults | Where-Object { [int]$_.rate_per_second -eq [int]$rate })
    # a rate the escalation never reached has NO ledgers, so it cannot be judged: including it would only produce a
    # "missing group(s)" problem for a tier that was never measured. It is recorded in the calibration result as
    # not_attempted instead of being smuggled into the summariser input.
    if ($rateSegs.Count -eq 0) { continue }
    $rateValid = (@($rateSegs | Where-Object { -not $_.valid }).Count -eq 0) -and (@($rateSegs).Count -eq 2)
    $segmentsForSummary[[string]$rate] = [ordered]@{
        rate_per_second = [int]$rate; order = 'A>B,B>A'; valid = $rateValid
        invalid_reason = $(if (-not $rateValid) { 'at least one pair of this rate failed its gates; see segments[]' } else { '' })
        groups = $groups
    }
}
# ---- P1.4b section 8 part A: EVERY sub-run is kept, and the P1.4b verdict is a SEPARATE entry -------------------
$subRunList = New-Object System.Collections.ArrayList
foreach ($r in $segmentResults) {
    foreach ($g in $r.groups.Keys) {
        $gg = $r.groups[$g]
        $planFile = ''
        $samplePlan = Plan-Of ([int]$r.rate_per_second) 'sample'
        if ($samplePlan) { $planFile = Split-Path -Leaf $samplePlan }
        $null = $subRunList.Add([ordered]@{ rate = [int]$r.rate_per_second; pair = [int]$r.pair; group = [string]$g; run_id = [string]$gg.sample_run; plan_file = $planFile })
    }
}
$subRunsPath = Join-Path $outDir 'subruns.json'
$null = Write-P14aOnce -Path $subRunsPath -Text ([ordered]@{
        run_id = $RunId
        note = 'one entry per (rate, pair, group) sample sub-run of THIS calibration; the P1.4b summariser needs all of them and must never be handed only the last pair'
        subruns = @($subRunList)
    } | ConvertTo-Json -Depth 6) -EntryPoint 'p14b-calibrate.ps1'

# budget by PLANNED slots and OFFERED requests over every attempted sub-run (never by completed responses)
$budgetLedger = [ordered]@{ planned_slots = [long]0; offered = [long]0; runs = New-Object System.Collections.ArrayList }
foreach ($s in $subRunList) {
    $cr = Get-CollectResult $s.run_id
    $planned = 0
    if ($cr -and $null -ne $cr.plan.PSObject.Properties['slot_count']) { $planned = [int]$cr.plan.slot_count }
    $offered = if ($cr) { [int]$cr.stats.offered } else { 0 }
    $budgetLedger.planned_slots += [long]$planned
    $budgetLedger.offered += [long]$offered
    $null = $budgetLedger.runs.Add([ordered]@{ run_id = $s.run_id; rate = $s.rate; pair = $s.pair; group = $s.group; planned_slots = $planned; offered = $offered; phase = 'sample' })
}
# warmup and coverage runs also consume the card's budget
foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $RunRoot 'runs') -Directory | Where-Object { $_.Name -like "$RunId-*" } | Sort-Object Name)) {
    if (@($budgetLedger.runs | Where-Object { $_.run_id -eq $d.Name }).Count -gt 0) { continue }
    $cr = Get-CollectResult $d.Name
    if ($null -eq $cr) { continue }
    $planned = if ($null -ne $cr.plan.PSObject.Properties['slot_count']) { [int]$cr.plan.slot_count } else { 0 }
    $budgetLedger.planned_slots += [long]$planned
    $budgetLedger.offered += [long]$cr.stats.offered
    $null = $budgetLedger.runs.Add([ordered]@{ run_id = $d.Name; rate = 0; pair = 0; group = ''; planned_slots = $planned; offered = [int]$cr.stats.offered; phase = [string]$cr.phase })
}
$budgetPath = Join-Path $outDir 'budget-ledger.json'
$null = Write-P14aOnce -Path $budgetPath -Text ([ordered]@{
        run_id = $RunId
        planned_slot_budget = 2000
        planned_slots_total = $budgetLedger.planned_slots
        offered_total = $budgetLedger.offered
        within_budget = ($budgetLedger.planned_slots -le 2000)
        basis = 'planned slots (plan.slot_count) and offered requests per sub-run, warmup and coverage included; NOT completed responses'
        runs = @($budgetLedger.runs)
    } | ConvertTo-Json -Depth 8) -EntryPoint 'p14b-calibrate.ps1'

$summaryCal = [ordered]@{
    run_id = $RunId
    segments = @($segmentsForSummary.Values)
    subruns_file = 'subruns.json'
    budget_file = 'budget-ledger.json'
    stopped_early = $stoppedEarly
    stop_reason = $stopReason
}
$null = Write-P14aOnce -Path (Join-Path $outDir 'calibration-result.json') -Text ($summaryCal | ConvertTo-Json -Depth 12) -EntryPoint 'p14b-calibrate.ps1'

# ---- the P1.4b measurement verdict: a separate entry, reading the originals with the P1.4b rules ----------------
$p14b = [ordered]@{ attempted = $false }
if (-not $SkipSummarize) {
    $bArgs = @('-RunRoot', $RunRoot, '-RunId', $RunId, '-Mode', 'p14b', '-SubRunsFile', $subRunsPath)
    $bChild = Invoke-ChildPowerShell (Join-Path $PSScriptRoot 'p14b-summarize.ps1') $bArgs ("p14bsummary-" + $RunId)
    $p14b['attempted'] = $true
    $p14b['child_exit'] = $bChild.exit
    $bOut = Join-Path $outDir 'p14b-summary.json'
    if (Test-Path -LiteralPath $bOut) {
        $bs = Get-Content -LiteralPath $bOut -Raw -Encoding UTF8 | ConvertFrom-Json
        $p14b['validated_tiers'] = @($bs.validated_tiers_req_per_second)
        $p14b['problems'] = @($bs.problems)
        $p14b['budget'] = $bs.budget
        $p14b['summary_sha256'] = (Get-Sha $bOut)
    }
    Add-Check 'measurement.p14b_summary_produced' (Test-Path -LiteralPath $bOut) ("P1.4b summary produced by its own entry (child exit reported as $($bChild.exit); the file is authoritative)")
}

# ---- independent re-judgement of the same ledgers by the summariser -----------------------------------------
$recompute = [ordered]@{ attempted = $false }
if (-not $SkipSummarize) {
    $sArgs = @('-RunRoot', $RunRoot, '-RunId', $RunId)
    $child = Invoke-ChildPowerShell $summarizerEntry $sArgs ("summarize-" + $RunId)
    $recompute['attempted'] = $true
    $recompute['exit'] = $child.exit
    $recompute['output'] = $child.output
    $sp = Join-Path $outDir 'recomputed-summary.json'
    if (Test-Path -LiteralPath $sp) {
        $rep = Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json
        $recompute['validated_tiers'] = @($rep.validated_tiers_req_per_second)
        $recompute['problems'] = @($rep.problems)
        $recompute['summary_sha256'] = (Get-Sha $sp)
        $recompute['segment_validity'] = @($rep.segment_validity)
        $recompute['per_run'] = $rep.per_run
    }
$attemptedRates = @($segmentResults | ForEach-Object { [int]$_.rate_per_second } | Sort-Object -Unique)
$unexpectedProblems = @($recompute['problems'] | Where-Object {
        $txt = [string]$_
        $explained = $false
        foreach ($r in $attemptedRates) { if ($txt -match ("tier " + $r + " req/s")) { $explained = $true } }
        -not $explained
    })
$ratesNotValidated = @($attemptedRates | Where-Object { @($recompute['validated_tiers']) -notcontains $_ })
Add-Check 'recompute.independent_rejudgement_has_no_problem' ($recompute['attempted'] -and (Test-Path -LiteralPath (Join-Path $outDir 'recomputed-summary.json')) -and $unexpectedProblems.Count -eq 0 -and $ratesNotValidated.Count -eq 0) `
    ("summariser produced recomputed-summary (child exit reported as $($child.exit); a grandchild can make Start-Process' ExitCode unreadable, so the summary file is authoritative) validated_tiers=$(@($recompute['validated_tiers']) -join ',') attempted_rates=$($attemptedRates -join ',') rates_not_validated=$($ratesNotValidated -join ',') problems=$(@($recompute['problems']).Count) unexpected=$($unexpectedProblems -join ' | ') (a 'tier X req/s is NOT a validated tier: missing group(s)' problem is EXPECTED for a rate the escalation never reached)")
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
    $deleted = 0
    foreach ($id in $allIds) {
        $null = Redis $RedisDb @('DEL', "$CacheKeyPrefix$id")
        $null = Redis $RedisDb @('DEL', "$CacheKeyPrefix$id`:lock")
        $deleted++
    }
    $db5After = Redis $RedisDb @('DBSIZE')
    $db0After = Redis 0 @('DBSIZE')
    Add-Check 'restore.exact_keys_removed_no_flushdb' ($db5After -eq '0' -and $db0After -eq '0') ("deleted $deleted article keys one by one (plus any :lock of the same ids); db$RedisDb=$db5After db0=$db0After; FLUSHDB was never used")
}
if (-not $SkipInstanceStart) {
    foreach ($g in @('A', 'B')) {
        if (Get-Process -Id $instances[$g].pid -ErrorAction SilentlyContinue) { Stop-Process -Id $instances[$g].pid -Force -ErrorAction SilentlyContinue }
    }
    Start-Sleep -Milliseconds 1200
    $stillListening = @($instances.Values | Where-Object { Get-NetTCPConnection -LocalPort $_.port -State Listen -ErrorAction SilentlyContinue }).Count
    Add-Check 'cleanup.own_instances_stopped' ($stillListening -eq 0) ("A/$PortA and B/$PortB listening count=$stillListening; only the two processes this card started were stopped")
}

# ---- protocol proposal: a rate must pass BOTH the business segments AND the independent P1.4b measurement verdict ---
# The P1.4a business verdict and the P1.4b measurement verdict are different things; a proposal needs both, and the
# independent P1.4b summary must ALSO say this rate is complete (2 pairs x 2 groups) and passing every gate.
$fullyPassed = New-Object System.Collections.ArrayList
$p14bTiers = @($p14b['validated_tiers'])
foreach ($rate in $Rates) {
    $rs = @($segmentResults | Where-Object { [int]$_.rate_per_second -eq [int]$rate })
    $businessOk = ($rs.Count -eq 2 -and @($rs | Where-Object { -not $_.valid }).Count -eq 0)
    $measureOk = ($p14bTiers -contains [int]$rate)
    if ($businessOk -and $measureOk) { $null = $fullyPassed.Add([int]$rate) }
}
$proposedRate = if ($fullyPassed.Count -gt 0) { [int]($fullyPassed | Measure-Object -Minimum).Minimum } else { 0 }
$recomputeTiers = @($recompute['validated_tiers'])
$proposalBlock = [ordered]@{}
foreach ($rate in $Rates) {
    $rs = @($segmentResults | Where-Object { [int]$_.rate_per_second -eq [int]$rate })
    if ($rs.Count -eq 0) { $proposalBlock[[string]$rate] = 'not attempted (the escalation stopped before this rate)'; continue }
    $businessOk = ($rs.Count -eq 2 -and @($rs | Where-Object { -not $_.valid }).Count -eq 0)
    $measureOk = ($p14bTiers -contains [int]$rate)
    if (-not $measureOk) {
        $proposalBlock[[string]$rate] = ("the independent P1.4b measurement did not validate this rate (business segments valid={0}); see p14b-summary.json" -f $businessOk)
    } elseif (-not $businessOk) {
        $proposalBlock[[string]$rate] = 'the business segments were not all valid; see segments[]'
    }
}
$blockedDetail = [ordered]@{}
foreach ($r in $segmentResults) {
    foreach ($g in $r.groups.Keys) {
        $gg = $r.groups[$g]
        $blockedDetail[("r{0}p{1}-{2}" -f $r.rate_per_second, $r.pair, $g)] = [ordered]@{
            failed_gates = @($gg.failed_gates)
            dispatch_lag_mono_ms = $gg.dispatch_lag_mono_ms
            observe_lag_ms = $gg.observe_lag_ms
            body_latency_correct_ms = $gg.body_latency_correct_ms
            persist_lag_ms = $gg.persist_lag_ms
            flush_lag_max_ms = $gg.flush_lag_max_ms
            dispatch_lag_diagnostic = $gg.dispatch_lag_diagnostic
        }
    }
}
$proposalStatus = if ($proposedRate -eq 0) { 'blocked_no_fully_valid_tier' } else { 'proposal_pending_owner_acceptance' }
$proposal = [ordered]@{
    status = $proposalStatus
    scope = 'P1.4b formal comparison protocol proposal; NOT a performance result and NOT approval to run the formal rounds'
    proposed_common_rate_req_per_second = $proposedRate
    proposed_common_p95_slo_ms = $SloP95CandidateMs
    slo_reason = 'the same 60 ms candidate for A and B that the card froze before measuring; it is not raised after seeing results and it is not a production SLO'
    measurement_rules = [ordered]@{
        latency_definition = 'dispatch_mono_ms -> body_ready_mono_ms (complete client body available), same monotonic axis as observation and persistence; NOT server service time and NOT the last TCP byte'
        legacy_definition = 'dispatched_ms -> ended_ms (loop observation) is kept only for comparability with P1.4a and always overstates'
        window = 'the completion window uses the frozen plan.seconds; in-window and tail completions are counted separately and must add up'
        population = 'all statistics come from one re-judged, plan-bound population; stored flags and the calibration self-report are comparison only'
        percentile = 'nearest-rank over the ascending sample'
        error_rules = 'any failure, timeout or drop invalidates the segment; correctness must be 100 percent; no re-send and no best-of-N'
        quality_gate = "dispatch schedule lag p95<=$DispatchLagP95 ms, p99<=$DispatchLagP99 ms, max<=$DispatchLagMax ms; body-ready to observation p95<=$ObserveLagP95 ms, max<=$ObserveLagMax ms; observer must be present with its own PID and summary"
        invalid_handling = 'a failing segment stops the escalation, keeps its raw responses and percentiles for diagnosis, and never enters validated/comparison'
    }
    formal_round_plan = [ordered]@{
        warmup_seconds_per_group = 60
        sample_seconds_per_group = 180
        rounds = @('A->B', 'B->A', 'A->B')
        round_count = 3
        same_plan = 'one frozen plan per rate, shared by both groups, identical for every round'
        equivalent_initialisation = 'both groups prewarm all 100 ids once before round 1 and keep the same effective TTL for the whole run; every round starts with the same warm set'
        reporting = 'report each round, then the median and range of the three rounds; never average p95/p99 and never pick the best round'
        identity = 'per-round: plan sha256, truth sha256, jar/source/class hashes, JVM parameters, ports, PIDs, observer PID'
    }
    identity = [ordered]@{
        git_head = (& git -C $RepoRoot rev-parse HEAD 2>$null)
        tools = [ordered]@{
            'benchmarks/load/p14b-collect.ps1' = (Get-Sha (Join-Path (Join-Path $benchDir 'load') 'p14b-collect.ps1'))
            'benchmarks/verify/p14b-observer.ps1' = (Get-Sha (Join-Path (Join-Path $benchDir 'verify') 'p14b-observer.ps1'))
            'benchmarks/lib/P14aCollector.ps1' = (Get-Sha (Join-Path (Join-Path $benchDir 'lib') 'P14aCollector.ps1'))
            'benchmarks/lib/P14bMeasure.cs' = (Get-Sha (Join-Path (Join-Path $benchDir 'lib') 'P14bMeasure.cs'))
            'benchmarks/lib/P14bMeasure.ps1' = (Get-Sha (Join-Path (Join-Path $benchDir 'lib') 'P14bMeasure.ps1'))
            'benchmarks/env/p14a-summarize.ps1' = (Get-Sha $summarizerEntry)
        }
        truth_sha256 = (Get-Sha $truthFile)
        plans_index_sha256 = (Get-Sha (Join-Path $plansDir 'plans-index.json'))
        production_sources = [ordered]@{ ap_article_service = 'frozen by the instance manifests of this root'; detail_probe = 'frozen by the instance manifests of this root'; cache_service = 'frozen by the instance manifests of this root' }
        note = 'the formal run card must re-freeze source/class/jar hashes at its own start; this proposal carries the hashes of THIS root'
    }
    measured_this_round = [ordered]@{
        rates = @($Rates)
        fully_passed_rates = @($fullyPassed)
        blocked = $proposalBlock
        sample_slots_total = $sampleSlots
        max_in_flight = $MaxInFlight
        request_timeout_ms = $RequestTimeoutMs
        stopped_early = $stoppedEarly
        stop_reason = $stopReason
        segments = @($segmentResults)
        recomputed = [ordered]@{
            validated_tiers = $recomputeTiers
            problems_count = @($recompute['problems']).Count
            summary_sha256 = $recompute['summary_sha256']
        }
    }
    blocked_analysis = [ordered]@{
        status_reason = $(if ($proposedRate -eq 0) { 'no rate passed both business and measurement gates in this round, so there is nothing to propose; the formal rounds must not be scheduled' } else { 'at least one rate passed; see measured_this_round' })
        per_group = $blockedDetail
        proven_this_round = @(
            'the independent observer is a separate process: a 250 ms observer stall added no measurable dispatch block and its own summary reports the stall, the sample cost and the gap',
            'the body-ready stamp is taken inside the request completion path: with a 250 ms MAIN LOOP stall the stamp was still taken and the loop observed the task >=150 ms later',
            'observer on/off changed the body latency p95 by ~1.2-1.5 ms against a 2 ms budget, so enabling the observer does not flatter the old observation',
            'no complete body means no body-ready stamp: abort and timeout records carry a named reason and no bytes/hash',
            'all four stamps share one machine-wide monotonic axis: the run elapsed measured by Stopwatch and by the axis agreed within 0.4 ms'
        )
        not_resolved = @(
            'the dispatch schedule lag budget (p95<=5 ms, p99<=10 ms, max<=25 ms) is NOT met: at 5 req/s the measured p95 is ~15 ms with p99 in the tens and a max in the hundreds of milliseconds',
            'the cause is the per-record work that must stay on the dispatch path under this card: body JSON re-assessment, ConvertTo-Json of the record (body_utf8 AND body_base64), WriteLine+Flush and the periodic fsync. The resource sample is no longer part of it',
            'moving that work off the loop would change the retention guarantee (continuous persistence and a real interrupted prefix), which this card is not allowed to trade away'
        )
        required_next_step = @(
            'a separate card must decide the retention/persistence design that lets the dispatch path stay under the budget (for example a bounded writer with the same flush guarantee, or a cheaper lossless serialisation), and then re-measure this budget',
            'until that is done, no formal 5 or 20 req/s comparison may be scheduled, and the 60 ms P95 candidate stays a candidate'
        )
    }
    untested = @(
        'no formal three rounds, no 60 s + 180 s run, no 50 req/s, no capacity, no mixed write/empty-value scenario, no Maven',
        'DAO calls remain DAO evidence (no physical SQL log)',
        'per-record serialisation/persist stays inside the collector loop; its cost is reported and it is the reason the dispatch-lag budget may fail'
    )
    note = 'this file is a PROPOSAL. The owner must accept it before a formal-run card exists; the executor does not run the formal rounds.'
}
$proposalPath = Join-Path (Join-Path $RunRoot 'protocol') ("protocol-proposal-$RunId.json")
$null = Write-P14aOnce -Path $proposalPath -Text ($proposal | ConvertTo-Json -Depth 12) -EntryPoint 'p14b-calibrate.ps1'

$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    scope = 'P1.4b short calibration: A=cache disabled vs B=cache enabled, two pairs per rate, observed by an independent process; scheduling and measurement validity only, not a formal result'
    limits = [ordered]@{ rates = ($Rates -join ','); max_in_flight = $MaxInFlight; request_timeout_ms = $RequestTimeoutMs; redis_db = $RedisDb; slo_p95_candidate_ms = $SloP95CandidateMs; dispatch_lag = @($DispatchLagP95, $DispatchLagP99, $DispatchLagMax); observe_lag = @($ObserveLagP95, $ObserveLagMax) }
    truth = [ordered]@{ file = 'plans/ids-truth.json'; sha256 = (Get-Sha $truthFile); targets = $allIds.Count; mismatches_at_start = $truthStart.Count; mismatches_at_end = $truthEnd.Count }
    plans_index_sha256 = (Get-Sha (Join-Path $plansDir 'plans-index.json'))
    p14b_measurement = $p14b
    instances = [ordered]@{
        A = [ordered]@{ port = $instances['A'].port; pid = $instances['A'].pid; cache_enabled = $instances['A'].manifestObj.cache_enabled; manifest = (Split-Path -Leaf $instances['A'].manifest) }
        B = [ordered]@{ port = $instances['B'].port; pid = $instances['B'].pid; cache_enabled = $instances['B'].manifestObj.cache_enabled; manifest = (Split-Path -Leaf $instances['B'].manifest) }
    }
    gate = [ordered]@{ probe_id = $probeId; key_exists_after_a = $keyAfterA; key_exists_after_b = $keyAfterB }
    coverage = $coverage
    keys_after_coverage = $keysAfterCoverage
    segments = @($segmentResults)
    sample_slots_total = $sampleSlots
    stopped_early = $stoppedEarly
    stop_reason = $stopReason
    recompute = $recompute
    keys_before_restore = $keysEnd
    jstat = $jstatSummary
    proposal = [ordered]@{ path = ("protocol/protocol-proposal-" + $RunId + ".json"); status = $proposalStatus; proposed_rate = $proposedRate; fully_passed_rates = @($fullyPassed); sha256 = (Get-Sha $proposalPath); latest_pointer = 'each run of this entry writes its own write-once proposal file; this field names the one for THIS run' }
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'calibration-result-full.json') -Text ($result | ConvertTo-Json -Depth 10)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'calibration-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
"proposal_status=$proposalStatus proposed_rate=$proposedRate fully_passed=$($fullyPassed -join ',')"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
