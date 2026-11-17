# P1.4a: freeze the 100 read IDs, their INDEPENDENT truth, and the fixed request plans (ASCII only).
#
# Everything here is read-only against the isolated test database (leadnews_article_p1). The truth values
# come from a direct SQL read, NOT from the response under test.
#
#   * ids-truth.json  : 100 existing article ids with four counters, channel/author and the SHA256 of the
#                       exact UTF-8 bytes of ap_article_content.content, plus its byte length.
#   * plan-<rate>*.json : slot index -> planned offset (ms) and article id. Warmup and sampling are separate
#                       files so warmup traffic can never be mixed into the sampled statistics.
#
# The plan is PERSISTED and hashed: a replay uses the file, it never regenerates the sequence.
#
# Exit codes: 0 = written, 2 = usage/guard refusal, 1 = verification failure.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [int]$Seed = 20261104,
    [int]$IdCount = 100,
    [int[]]$Rates = @(5, 20, 50),
    [int]$WarmupSeconds = 10,
    [int]$SampleSeconds = 20,
    [string]$Database = 'leadnews_article_p1',
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [string]$ArtifactsRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts'
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$env:MYSQL_PWD = $MysqlPassword
. (Join-Path (Join-Path $RepoRoot 'benchmarks/lib') 'P14aRoots.ps1')

function Get-Normalized([string]$p) { return [System.IO.Path]::GetFullPath($p).TrimEnd('\', '/').ToLowerInvariant() }
function Test-UnderRoot([string]$path, [string]$root) {
    $p = Get-Normalized $path; $r = Get-Normalized $root
    if ($p -eq '' -or $r -eq '') { return $false }
    return ($p -eq $r) -or $p.StartsWith($r + '\') -or $p.StartsWith($r + '/')
}
function Refuse([string]$why) { Write-Host "REFUSED: $why"; Write-Host 'REFUSED_STAGE=guard'; exit 2 }
function Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }

# Parent-root lifecycle FIRST: a completed/sealed root is refused before any SQL, directory or output.
$null = Assert-P14aActiveRoot -RunRoot $RunRoot -ArtifactsRoot $ArtifactsRoot -EntryPoint 'p14a-plan.ps1'
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (-not (Test-UnderRoot $RunRoot $ArtifactsRoot)) { Refuse "run root is outside the artifacts root: $RunRoot" }
$planDir = Join-Path $RunRoot 'plans'
if (-not (Test-Path -LiteralPath $planDir)) { Refuse "plans directory is missing: $planDir" }
if (-not (Test-UnderRoot $planDir $RunRoot)) { Refuse "plans directory is outside the run root: $planDir" }

function Sql([string]$q) {
    return (((& $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--raw' '-e' $q) 2>&1) | Out-String).Trim()
}

# ---- 1. candidate ids: existing rows that also have a content row ----
$eligible =@()
$rawIds = Sql "SELECT a.id FROM $Database.ap_article a JOIN $Database.ap_article_content c ON c.article_id=a.id ORDER BY a.id;"
foreach ($line in ($rawIds -split "`r?`n")) {
    if ($line.Trim() -eq '') { continue }
    $eligible += [long]$line.Trim()
}
if ($eligible.Count -lt $IdCount) {
    Write-Host "VERIFY FAILED: only $($eligible.Count) eligible articles with content, need $IdCount"
    exit 1
}

# ---- 2. deterministic selection with the frozen seed (System.Random + seed, recorded in the file) ----
$rnd = New-Object System.Random($Seed)
$pool = New-Object System.Collections.ArrayList
foreach ($i in $eligible) { $null = $pool.Add($i) }
$picked = New-Object System.Collections.ArrayList
for ($k = 0; $k -lt $IdCount; $k++) {
    $idx = $rnd.Next(0, $pool.Count)
    $null = $picked.Add([long]$pool[$idx])
    $pool.RemoveAt($idx)
}
# the frozen order used by every plan: ascending, so A and B see the same sequence
$ids = @($picked | Sort-Object)

# ---- 3. independent truth from a direct SQL read ----
$idList = ($ids | ForEach-Object { "$_" }) -join ','
$rows = Sql ("SELECT a.id, a.views, a.likes, a.comment, a.collection, a.channel_id, a.author_id, " +
    "SHA2(IFNULL(c.content,''),256), LENGTH(IFNULL(c.content,'')) " +
    "FROM $Database.ap_article a LEFT JOIN $Database.ap_article_content c ON c.article_id=a.id " +
    "WHERE a.id IN ($idList) ORDER BY a.id;")
$truthById = @{}
foreach ($line in ($rows -split "`r?`n")) {
    if ($line.Trim() -eq '') { continue }
    $f = $line -split "`t"
    if ($f.Length -lt 9) { Write-Host "VERIFY FAILED: unexpected truth row shape: $line"; exit 1 }
    $truthById[[long]$f[0]] = [ordered]@{
        article_id    = [long]$f[0]
        views         = [long]$f[1]
        likes         = [long]$f[2]
        comment       = [long]$f[3]
        collection    = [long]$f[4]
        channel_id    = [long]$f[5]
        author_id     = [long]$f[6]
        content_sha256 = "$($f[7])".ToLower()
        content_bytes = [long]$f[8]
    }
}
$missing = @($ids | Where-Object { -not $truthById.ContainsKey([long]$_) })
if ($missing.Count -gt 0) { Write-Host "VERIFY FAILED: no truth for ids: $($missing -join ',')"; exit 1 }

$targets = New-Object System.Collections.ArrayList
foreach ($id in $ids) { $null = $targets.Add($truthById[[long]$id]) }

$maxSafe = [long]9007199254740991  # 2^53 - 1
$aboveSafe = @($ids | Where-Object { $_ -gt $maxSafe }).Count
$truth = [ordered]@{
    scope            = 'P1.4a independent truth read directly from the isolated test database (not from the response under test)'
    database         = $Database
    source_query     = 'SELECT a.id, a.views, a.likes, a.comment, a.collection, a.channel_id, a.author_id, SHA2(IFNULL(c.content,''''),256), LENGTH(IFNULL(c.content,'''')) FROM ap_article a LEFT JOIN ap_article_content c ON c.article_id=a.id WHERE a.id IN (...) ORDER BY a.id'
    captured_local   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    seed             = $Seed
    id_count         = $ids.Count
    eligible_count   = $eligible.Count
    ids_above_2pow53_minus_1 = $aboveSafe
    min_id           = ($ids | Measure-Object -Minimum).Minimum
    max_id           = ($ids | Measure-Object -Maximum).Maximum
    note             = 'content hash is SHA256 over the exact UTF-8 bytes of the content column; byte length is LENGTH() from MySQL'
    targets          = @($targets)
}
$truthPath = Join-Path $planDir 'ids-truth.json'
$null = Write-P14aOnce -Path $truthPath -Text ($truth | ConvertTo-Json -Depth 8) -EntryPoint 'p14a-plan.ps1'

# ---- 4. fixed plans per rate: warmup and sampling kept in separate files ----
$plans = New-Object System.Collections.ArrayList
function New-PlanFile([int]$rate, [int]$seconds, [string]$kind) {
    $slots = [int][Math]::Round($rate * $seconds)
    $list = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $slots; $i++) {
        $null = $list.Add([ordered]@{
                slot_index       = $i
                planned_offset_ms = [int][Math]::Round(($i * 1000.0) / $rate)
                article_id       = [long]$ids[$i % $ids.Count]
            })
    }
    $name = "plan-r$rate-$kind.json"
    $path = Join-Path $planDir $name
    $obj = [ordered]@{
        kind            = $kind
        rate_per_second = $rate
        seconds         = $seconds
        slot_count      = $slots
        seed            = $Seed
        id_count        = $ids.Count
        scheduling      = 'fixed arrival: slot i is due at planned_offset_ms = round(i*1000/rate); a slot that is due while the in-flight cap is full is DROPPED and never re-queued'
        note            = 'warmup and sampling are separate files so warmup traffic never enters the sampled statistics'
        slots           = @($list)
    }
    $null = Write-P14aOnce -Path $path -Text ($obj | ConvertTo-Json -Depth 6) -EntryPoint 'p14a-plan.ps1'
    $null = $plans.Add([ordered]@{ path = "plans/$name"; sha256 = (Sha $path); rate = $rate; kind = $kind; slots = $slots })
    return $slots
}

$coverage = New-PlanFile 1 $IdCount 'coverage'   # one serial pass over all 100 ids (single-listed preset)
foreach ($r in $Rates) {
    $null = New-PlanFile $r $WarmupSeconds 'warmup'
    $null = New-PlanFile $r $SampleSeconds 'sample'
}

$index = [ordered]@{
    truth = [ordered]@{ path = 'plans/ids-truth.json'; sha256 = (Sha $truthPath); targets = $ids.Count; ids_above_2pow53_minus_1 = $aboveSafe }
    plans = @($plans)
    coverage_note = 'coverage is a 1 req/s serial pass over all 100 ids; it is reported separately and never used as a sampled measurement'
}
$indexPath = Join-Path $planDir 'plans-index.json'
$null = Write-P14aOnce -Path $indexPath -Text ($index | ConvertTo-Json -Depth 6) -EntryPoint 'p14a-plan.ps1'

Write-Host "truth=$truthPath sha=$((Sha $truthPath)) ids=$($ids.Count) above_2p53=$aboveSafe eligible=$($eligible.Count)"
foreach ($p in $plans) { Write-Host ("  {0}  rate={1} kind={2} slots={3}  {4}" -f $p.sha256, $p.rate, $p.kind, $p.slots, $p.path) }
Write-Host "plans_index=$indexPath sha=$((Sha $indexPath))"
exit 0
