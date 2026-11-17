# P1.2 paired cold-burst driver, round 2 (ASCII only; PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
#
# What changed after the first P1.2 review (R3 + R4):
#   * the driver itself now owns a guarded run directory. It refuses an existing directory BEFORE
#     any child run or external call, and writes its manifest / plan / CSV / JSON exactly once.
#     A failed or all-rejected sweep still keeps every file and exits non-zero.
#   * the alternation is between CODE VERSIONS, not between scenarios: round 1 runs slot A then
#     slot B, round 2 runs slot B then slot A, and so on. Each slot has its own port and its own
#     event file, so attribution is unambiguous.
#   * round 3: the SLOT IDENTITY is a parameter (-VariantAName / -VariantBName / labels). The
#     round-2 compare used A = pre-rework baseline classes and B = reworked classes; the round-3
#     compare uses U = rebuilt fixed-value/50 ms control and O = the candidate build. Recorded
#     variant names in every file come from these parameters, so a rebuilt control can never be
#     passed off as an original baseline.
#   * per round it stores P95 and P99; the summary reports median and range over rounds and never
#     averages percentiles.
#
# The collector (p1-2-coldburst.ps1) is unchanged for both variants, so the harness is identical.
#
# Exit codes: 0 = every child run passed, 1 = at least one child failed or was rejected (files kept),
#             2 = usage/guard problem (nothing was executed).
param(
    [Parameter(Mandatory = $true)][ValidateSet('ab', 'ba', 'a-only', 'b-only')][string]$Order,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$ExperimentRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261030-P1.2-rework',
    [int]$Rounds = 3,
    [long]$C1ArticleId = 9007199254741000,
    [long]$C2ArticleId = 9007199254741001,
    [int[]]$Concurrency = @(10, 30),
    [string]$ABase = 'http://127.0.0.1:51810',
    [string]$BBase = 'http://127.0.0.1:51811',
    [string]$AManifest = '',
    [string]$BManifest = '',
    [string]$AEvents = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261030-P1.2-rework/events/A-events.log',
    [string]$BEvents = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261030-P1.2-rework/events/B-events.log',
    [string]$BurstScript = '',
    [int]$ArrivalSpreadLimitMs = 250,
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [string]$VariantAName = 'A',
    [string]$VariantBName = 'B',
    [string]$VariantALabel = 'slot A',
    [string]$VariantBLabel = 'slot B'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
if ([string]::IsNullOrWhiteSpace($BurstScript)) { $BurstScript = Join-Path $PSScriptRoot 'p1-2-coldburst.ps1' }

. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }

# ---- R3: the parent takes its own guarded directory FIRST; nothing else runs before this ----
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.2-pairs' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ order = $Order; rounds = $Rounds; concurrency = ($Concurrency -join ',');
                       a_base = $ABase; b_base = $BBase; arrival_spread_limit_ms = $ArrivalSpreadLimitMs;
                       burst_script = $BurstScript } `
        -Targets @("$C1ArticleId", "$C2ArticleId") -DataSet 'leadnews_article_p1'
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

# ---- child-call counter: a guard refusal or a plan error must leave this at 0 ----
$counterPath = Join-Path $OutDir 'child-invocations.txt'
Set-Content -LiteralPath $counterPath -Value '0' -Encoding ASCII
function Get-ChildCalls { return [int]((Get-Content -LiteralPath $counterPath -Raw).Trim()) }
function Add-ChildCall {
    $n = (Get-ChildCalls) + 1
    Set-Content -LiteralPath $counterPath -Value ([string]$n) -Encoding ASCII
    return $n
}

$va = $VariantAName
$vb = $VariantBName
$variants = @{}
$variants[$va] = [ordered]@{ name = $va; base = $ABase; manifest = $AManifest; events = $AEvents; label = $VariantALabel }
$variants[$vb] = [ordered]@{ name = $vb; base = $BBase; manifest = $BManifest; events = $BEvents; label = $VariantBLabel }

# ---- plan is written once, before any child call ----
$plan = @()
for ($round = 1; $round -le $Rounds; $round++) {
    # AB/BA over CODE VERSIONS: odd rounds A->B, even rounds B->A
    # alternation is over CODE VERSIONS: odd rounds slot A -> slot B, even rounds slot B -> slot A.
    # The slot identity is whatever -VariantAName / -VariantBName say (A/B for the round-2 compare,
    # U/O for the round-3 rebuilt-control compare), so the recorded variant is never a bare guess.
    $seq = switch ($Order) {
        'ab' { if ($round % 2 -eq 1) { @($va, $vb) } else { @($vb, $va) } }
        'ba' { if ($round % 2 -eq 1) { @($vb, $va) } else { @($va, $vb) } }
        'a-only' { @($va) }
        'b-only' { @($vb) }
    }
    foreach ($n in $Concurrency) {
        foreach ($kind in @('C1', 'C2')) {
            foreach ($v in $seq) {
                $childRunId = '{0}-{1}{2}-C{3}-r{4:00}' -f $RunId, $kind, $v, $n, $round
                $plan += [pscustomobject]@{
                    round = $round; kind = $kind; concurrency = $n; variant = $v
                    child_run_id = $childRunId; base = $variants[$v].base
                }
            }
        }
    }
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'child-plan.json') -Text ($plan | ConvertTo-Json -Depth 4)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'variants.json') -Text ($variants | ConvertTo-Json -Depth 4)

function Read-LockState([string]$key) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', '0', 'EXISTS', $key)
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}

$rows = @()
$childFailures = 0
foreach ($step in $plan) {
    $v = $variants[$step.variant]
    $childOut = Join-Path $OutDir ("runs/" + $step.child_run_id)
    $articleId = if ($step.kind -eq 'C1') { $C1ArticleId } else { $C2ArticleId }
    $callNo = Add-ChildCall
    Write-Host ("=== [{0}] round {1} {2} C{3} variant={4} run={5}" -f $callNo, $step.round, $step.kind, $step.concurrency, $step.variant, $step.child_run_id)

    $childArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BurstScript,
        '-BaseUrl', $v.base,
        '-ArticleId', "$articleId",
        '-Concurrency', "$($step.concurrency)",
        '-OutDir', $childOut,
        '-RunId', $step.child_run_id,
        '-ExperimentRoot', $ExperimentRoot,
        '-Label', ("{0}-{1}-C{2}-r{3:00}" -f $step.variant, $step.kind, $step.concurrency, $step.round),
        '-Variant', $step.variant,
        '-EventsFile', $v.events,
        '-ArrivalSpreadLimitMs', "$ArrivalSpreadLimitMs"
    )
    if (-not [string]::IsNullOrWhiteSpace($v.manifest)) { $childArgs += @('-InstanceManifest', $v.manifest) }

    $logPath = Join-Path $OutDir ("child-{0}.console.txt" -f $step.child_run_id)
    # A child that writes to stderr must not abort the driver through NativeCommandError under
    # ErrorActionPreference=Stop (this exact trap killed the first version of this loop).
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $console = & powershell @childArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    Set-Content -LiteralPath $logPath -Value @($console) -Encoding UTF8
    if ($code -ne 0) { $childFailures++ }

    $sumPath = Join-Path $childOut 'burst-summary.json'
    if (-not (Test-Path -LiteralPath $sumPath)) {
        # keep the row so a failed / rejected child is visible and counts, never silently skipped
        $rows += [pscustomobject]@{
            round = $step.round; kind = $step.kind; concurrency = $step.concurrency; variant = $step.variant
            child_run_id = $step.child_run_id; exit = $code; has_summary = $false
            requests = 0; ok_200 = 0; rejected_503 = 0; bad = 0; timeout = 0
            rebuild_attempts = 0; peak_rebuild = 0; db_attempts = 0; peak_db = 0
            lock_acquired = 0; lock_fail = 0; lock_late = 0; wait_budget = 0; wait_interrupted = 0
            p50_ms = $null; p95_ms = $null; p99_ms = $null; max_ms = $null
            arrival_spread_ms = $null; variant_sha256 = ''
        }
        continue
    }
    $s = Get-Content -LiteralPath $sumPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows += [pscustomobject]@{
        round            = $step.round
        kind             = $step.kind
        concurrency      = $step.concurrency
        variant          = $step.variant
        child_run_id     = $step.child_run_id
        exit             = $code
        has_summary      = $true
        requests         = $s.requests
        ok_200           = $s.responses.ok_200_with_id
        rejected_503     = $s.responses.rejected_503
        bad              = $s.responses.bad
        timeout          = $s.responses.timeout
        rebuild_attempts = $s.service_events.rebuild_attempts
        peak_rebuild     = $s.service_events.peak_concurrent_rebuild
        db_attempts      = $s.service_events.db_attempts
        peak_db          = $s.service_events.peak_concurrent_db
        lock_acquired    = $s.service_events.lock_acquired
        lock_fail        = $s.service_events.lock_fail
        lock_late        = $s.service_events.lock_late_acquire
        wait_budget      = $s.service_events.wait_outcomes.budget_exhausted
        wait_interrupted = $s.service_events.wait_outcomes.interrupted
        p50_ms           = $s.latency_ms.p50
        p95_ms           = $s.latency_ms.p95
        p99_ms           = $s.latency_ms.p99
        max_ms           = $s.latency_ms.max
        arrival_spread_ms = $s.synchronization.server_arrival_spread_ms
        variant_sha256   = $s.instance.variant_sha256
    }
}

# ---- write-once aggregate files (never overwrite) ----
function Write-OnceText([string]$path, [string[]]$lines) {
    if (Test-Path -LiteralPath $path) { throw "refusing to overwrite existing aggregate: $path" }
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
}
$csvPath = Join-Path $OutDir 'pairs-rounds.csv'
Write-OnceText $csvPath @($rows | ConvertTo-Csv -NoTypeInformation)

function Median($a) {
    $s = @($a | Where-Object { $null -ne $_ } | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    if ($s.Count % 2 -eq 1) { return [double]$s[($s.Count - 1) / 2] }
    return [math]::Round((([double]$s[$s.Count / 2 - 1] + [double]$s[$s.Count / 2]) / 2.0), 3)
}
function MinMax($a) {
    $s = @($a | Where-Object { $null -ne $_ })
    if ($s.Count -eq 0) { return @{ min = $null; max = $null } }
    return @{ min = ($s | Measure-Object -Minimum).Minimum; max = ($s | Measure-Object -Maximum).Maximum }
}

$groups = $rows | Group-Object kind, concurrency, variant
$table = foreach ($g in $groups) {
    $x = $g.Group
    $p95 = @($x | ForEach-Object { $_.p95_ms })
    $p99 = @($x | ForEach-Object { $_.p99_ms })
    $mm95 = MinMax $p95
    $mm99 = MinMax $p99
    [pscustomobject]@{
        variant        = $x[0].variant
        kind           = $x[0].kind
        concurrency    = $x[0].concurrency
        rounds         = $x.Count
        exits          = (($x | ForEach-Object { $_.exit }) -join ',')
        requests       = ($x | Measure-Object requests -Sum).Sum
        ok_200         = ($x | Measure-Object ok_200 -Sum).Sum
        rejected_503   = ($x | Measure-Object rejected_503 -Sum).Sum
        bad            = ($x | Measure-Object bad -Sum).Sum
        rebuild_attempts = ($x | Measure-Object rebuild_attempts -Sum).Sum
        peak_rebuild_max = ($x | Measure-Object peak_rebuild -Maximum).Maximum
        db_attempts    = ($x | Measure-Object db_attempts -Sum).Sum
        peak_db_max    = ($x | Measure-Object peak_db -Maximum).Maximum
        lock_acquired  = ($x | Measure-Object lock_acquired -Sum).Sum
        lock_fail      = ($x | Measure-Object lock_fail -Sum).Sum
        p95_median     = (Median $p95)
        p95_range      = "$($mm95.min)-$($mm95.max)"
        p99_median     = (Median $p99)
        p99_range      = "$($mm99.min)-$($mm99.max)"
        variant_sha256 = (($x | ForEach-Object { $_.variant_sha256 } | Sort-Object -Unique) -join '|')
    }
}
$table | Sort-Object variant, kind, concurrency | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
Write-OnceText (Join-Path $OutDir 'pairs-summary.json') @($table | Sort-Object variant, kind, concurrency | ConvertTo-Json -Depth 5)

# ---- checks ----
$counts = Get-RunCheckCounts $script:run
Add-RunCheck -State $script:run -Name 'pairs.parent_used_guard' -Status 'pass' -Detail "parent dir created by guard: $OutDir"
Add-RunCheck -State $script:run -Name 'pairs.child_calls_completed' -Status $(if ($childFailures -eq 0 -and (Get-ChildCalls) -gt 0) { 'pass' } else { 'fail' }) -Detail "child_calls=$(Get-ChildCalls) failures=$childFailures"
Add-RunCheck -State $script:run -Name 'pairs.every_child_has_row' -Status $(if ($rows.Count -eq $plan.Count) { 'pass' } else { 'fail' }) -Detail "rows=$($rows.Count) planned=$($plan.Count)"
$variantSeq = ($rows | ForEach-Object { "{0}{1}-r{2}" -f $_.kind, $_.variant, $_.round }) -join ','
Add-RunCheck -State $script:run -Name 'pairs.variant_alternation_recorded' -Status 'pass' -Detail "order=$Order sequence=$variantSeq"
$shaByVariant = @{}
foreach ($r in $rows) { if ($r.variant_sha256) { $shaByVariant[$r.variant] = $r.variant_sha256 } }
$distinctSha = @($shaByVariant.Values | Sort-Object -Unique).Count
Add-RunCheck -State $script:run -Name 'pairs.variants_are_different_builds' -Status $(if ($Order -eq 'ab' -or $Order -eq 'ba') { if ($distinctSha -eq 2) { 'pass' } else { 'fail' } } else { 'skipped' }) -Detail "distinct variant class hashes=$distinctSha (A/B must differ; single-variant runs are not a comparison)"
$aggCounts = Get-RunCheckCounts $script:run
$table | Sort-Object variant, kind, concurrency | ConvertTo-Json -Depth 5
$agg = [ordered]@{
    run_id          = $RunId
    order           = $Order
    child_calls     = (Get-ChildCalls)
    child_failures  = $childFailures
    plan_steps      = $plan.Count
    rows            = $rows.Count
    counts          = $aggCounts
    percentile_rule = 'median and range are computed over the per-round p95/p99 values; percentiles are never averaged'
}
Write-OnceText (Join-Path $OutDir 'pairs-run-meta.json') @(($agg | ConvertTo-Json -Depth 5))
exit (Set-RunStatus -State $script:run -Status $(if ($aggCounts.failed -gt 0) { 'failed' } else { 'passed' }))
