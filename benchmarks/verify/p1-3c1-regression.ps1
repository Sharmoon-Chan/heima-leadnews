# P1.3c-1 L5: minimal application regression on the isolated p1 database and Redis DB5 (ASCII only).
#
# One real public updateScore commit and one controlled rollback, both through the running instance:
#   commit   : four counters +1/+1/+1/+1, first delete + scheduled second delete, detail 200 with exact
#              string id, task accounting reconciles (accepted = succeeded, nothing left active)
#   rollback : counters unchanged, cache key still present, no second delete accepted for that id
#
# Everything writable stays in this run directory. The two rows are captured with mysqldump BEFORE any
# write and restored from those exact files at the end, then verified row by row; the keys are restored
# from their captured state. DB0 is never written and never flushed.
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [long]$CommitId = 9007199254742071,
    [long]$RollbackId = 9007199254742072,
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlDump = 'D:\Soft\mysql-8.0.34-winx64\bin\mysqldump.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [int]$RedisDb = 5,
    [string]$CacheKeyPrefix = 'article:detail:',
    [int]$SettleQuietMs = 1200,
    [int]$SettleTimeoutMs = 20000,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$env:MYSQL_PWD = $MysqlPassword
$benchDir = Split-Path -Parent $PSScriptRoot

. (Join-Path (Join-Path $benchDir 'lib') 'RunDirGuard.ps1')
$outDir = Join-Path (Join-Path $RunRoot 'runs') $RunId
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3c-1-L5-app-regression' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ commit_id = $CommitId; rollback_id = $RollbackId; base = $Base; redis_db = $RedisDb; delay_ms = 500 } `
        -Targets @("$CommitId", "$RollbackId") -DataSet $Database
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
$scriptStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-50} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'FAIL' }), $d
}
function Redis-In([int]$db, [string[]]$a) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', "$db") + $a
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Sql([string]$q) {
    $o = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--raw' '--default-character-set=utf8mb4' '-e' $q 2>&1
    return (($o | Out-String).Trim())
}
function Db-Counts([long]$id) { return (Sql "SELECT CONCAT_WS('|', views, likes, comment, collection) FROM $Database.ap_article WHERE id=$id;") }

# ---------------------------------------------------------------- capture BEFORE any write
$captureDir = Join-Path $outDir 'capture'
New-Item -ItemType Directory -Path $captureDir | Out-Null
$tables = @('ap_article', 'ap_article_content', 'ap_article_config')
$where = "id IN ($CommitId,$RollbackId)"
foreach ($t in $tables) {
    $file = Join-Path $captureDir ("$t.capture.sql")
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $MysqlDump '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '--no-create-info' '--skip-extended-insert' `
        '--complete-insert' '--where' $where $Database $t 1> $file 2> (Join-Path $captureDir "$t.capture.err")
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($code -ne 0) { throw "mysqldump failed for $t (exit $code), see capture/$t.capture.err" }
}
$captureSha = [ordered]@{}
foreach ($t in $tables) { $captureSha[$t] = (Get-FileHash -LiteralPath (Join-Path $captureDir "$t.capture.sql") -Algorithm SHA256).Hash.ToLower() }

$countsBefore = [ordered]@{ commit = (Db-Counts $CommitId); rollback = (Db-Counts $RollbackId) }
$keyCommit = "$CacheKeyPrefix$CommitId"
$keyRollback = "$CacheKeyPrefix$RollbackId"
$keys = [ordered]@{
    commit_exists_before = (Redis-In $RedisDb @('EXISTS', $keyCommit))
    rollback_exists_before = (Redis-In $RedisDb @('EXISTS', $keyRollback))
    db5_size_before = (Redis-In $RedisDb @('DBSIZE'))
    db0_size_before = (Redis-In 0 @('DBSIZE'))
}
Add-Check 'l5.capture_before_write' ($countsBefore.commit -match '^\d+\|\d+\|\d+\|\d+$' -and $countsBefore.rollback -match '^\d+\|\d+\|\d+\|\d+$' -and $keys.db0_size_before -eq '0') `
    "commit row=$($countsBefore.commit) rollback row=$($countsBefore.rollback) db5=$($keys.db5_size_before) db0=$($keys.db0_size_before)"

# ---------------------------------------------------------------- HTTP helper (raw body persisted at once)
Add-Type -AssemblyName System.Net.Http | Out-Null
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
$script:seq = 0
function Get-Once([string]$path, [string]$reqId, [string]$note) {
    $script:seq++
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base$path")
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $p = Join-Path $outDir ("raw-{0:D2}-{1}.body.json" -f $script:seq, $reqId)
    Write-RunFileText -State $script:run -Path $p -Text $text
    $sha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
    return [pscustomobject]@{ http = [int]$resp.StatusCode; text = $text; bytes = $bytes.Length; sha = $sha; path = $p }
}
function Post-Once([string]$path, [string]$reqId, [string]$note) {
    $script:seq++
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$Base$path")
    $req.Content = New-Object System.Net.Http.StringContent('')
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $p = Join-Path $outDir ("raw-{0:D2}-{1}.body.json" -f $script:seq, $reqId)
    Write-RunFileText -State $script:run -Path $p -Text $text
    $sha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
    return [pscustomobject]@{ http = [int]$resp.StatusCode; text = $text; bytes = $bytes.Length; sha = $sha; path = $p }
}

# ---------------------------------------------------------------- L5 commit
$warmA = Get-Once "/api/v1/article/detail/$CommitId" "$RunId-warm-commit" 'warm the cache before the committed write'
Add-Check 'l5.commit_cache_warmed' ((Redis-In $RedisDb @('EXISTS', $keyCommit)) -eq '1') `
    "warm-up http=$($warmA.http) bytes=$($warmA.bytes) sha=$($warmA.sha) key exists=$(Redis-In $RedisDb @('EXISTS', $keyCommit))"

$writeA = Post-Once "/p13b/harness/score?id=$CommitId&view=1&like=1&comment=1&collect=1" "$RunId-write-commit" 'real updateScore commit'
Add-Check 'l5.commit_accepted' (($writeA.http -eq 200) -and ($writeA.text -match '"ok"\s*:\s*true')) "http=$($writeA.http) body=$($writeA.text)"

$countsAfterA = Db-Counts $CommitId
$b = $countsBefore.commit -split '\|'
$a = $countsAfterA -split '\|'
$deltaOk = ($a.Count -eq 4) -and ([int]$a[0] - [int]$b[0] -eq 1) -and ([int]$a[1] - [int]$b[1] -eq 1) -and ([int]$a[2] - [int]$b[2] -eq 1) -and ([int]$a[3] - [int]$b[3] -eq 1)
Add-Check 'l5.commit_counters_plus_one' $deltaOk "before=$($countsBefore.commit) after=$countsAfterA (each field +1)"

# only the events of THIS run: scoped by the article id and by the epoch this process started at
# ($scriptStartMs is set once, right after the guard above, so every event of this run is included)
function Ev-Since([long]$articleId) {
    if (-not (Test-Path -LiteralPath $Events)) { return @() }
    $start = $scriptStartMs
    return @(Get-Content -LiteralPath $Events | Where-Object {
        ($_ -match " articleId=$articleId ") -and
        ([long]([regex]::Match($_, 'epochMs=(\d+)').Groups[1].Value) -ge $start)
    })
}

# wait for the scheduled second delete to settle
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastChange = 0; $prev = -1
while ($sw.ElapsedMilliseconds -lt $SettleTimeoutMs) {
    $ev = Ev-Since $CommitId
    $sched = @($ev | Where-Object { $_ -match ' event=cache\.evict\.second_accepted ' }).Count
    $term = @($ev | Where-Object { $_ -match ' event=cache\.evict\.second_succeeded ' -or $_ -match ' event=cache\.evict\.second_failed ' }).Count
    if ($sched -eq $term) {
        if ($sched -ne $prev) { $prev = $sched; $lastChange = $sw.ElapsedMilliseconds }
        if (($sw.ElapsedMilliseconds - $lastChange) -ge $SettleQuietMs) { break }
    }
    Start-Sleep -Milliseconds 120
}
$evCommit = Ev-Since $CommitId
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'events-commit.log') -Text ((@($evCommit)) -join "`r`n")
$accC = @($evCommit | Where-Object { $_ -match ' event=cache\.evict\.second_accepted ' })
$succC = @($evCommit | Where-Object { $_ -match ' event=cache\.evict\.second_succeeded ' })
$failC = @($evCommit | Where-Object { $_ -match ' event=cache\.evict\.second_failed ' })
$okFirstC = @($evCommit | Where-Object { $_ -match ' event=cache\.evict\.ok ' -and $_ -notmatch 'phase=[^ ]*:second' })
Add-Check 'l5.commit_first_and_second_delete' ($okFirstC.Count -eq 1 -and $accC.Count -eq 1 -and $succC.Count -eq 1 -and $failC.Count -eq 0) `
    "first-phase ok=$($okFirstC.Count) second accepted=$($accC.Count) succeeded=$($succC.Count) failed=$($failC.Count)"
$taskIds = @($accC | ForEach-Object { [regex]::Match($_, 'taskId=([^ ]+)').Groups[1].Value })
Add-Check 'l5.commit_task_id_present' ($taskIds.Count -eq 1 -and $taskIds[0] -match '^t\d+-\d+$') "taskId=$($taskIds -join ',')"

$detailA = Get-Once "/api/v1/article/detail/$CommitId" "$RunId-read-commit" 'detail after the committed write'
Add-Check 'l5.commit_detail_fresh_and_exact_id' (($detailA.http -eq 200) -and ($detailA.text -match [regex]::Escape('"id":"' + "$CommitId" + '"')) -and ($detailA.text -match ('"views"\s*:\s*' + [int]$a[0]))) `
    "http=$($detailA.http) bytes=$($detailA.bytes) sha=$($detailA.sha) views_expected=$($a[0])"

$stats1 = (Get-Once '/p13b/harness/stats' "$RunId-stats-1" 'invalidator stats after the commit').text | ConvertFrom-Json
$ev1 = $stats1.evict
Add-Check 'l5.commit_task_accounting' (([long]$ev1.accepted) -ge 1 -and ([long]$ev1.succeeded) -eq ([long]$ev1.accepted) -and ([long]$ev1.active_now) -eq 0 -and ([long]$ev1.cancelled) -eq 0 -and ([long]$ev1.failed) -eq 0) `
    "accepted=$($ev1.accepted) succeeded=$($ev1.succeeded) failed=$($ev1.failed) cancelled=$($ev1.cancelled) queued=$($ev1.queued_now) running=$($ev1.running_now) active=$($ev1.active_now) delayMs=$($ev1.second_delete_delay_ms)"
Add-Check 'l5.delay_still_500_and_fields_present' (([long]$ev1.second_delete_delay_ms) -eq 500 -and $null -ne $ev1.submit_attempts -and $null -ne $ev1.rejected -and [long]$ev1.submit_attempts -eq ([long]$ev1.accepted + [long]$ev1.rejected)) `
    "second_delete_delay_ms=$($ev1.second_delete_delay_ms) submit_attempts=$($ev1.submit_attempts) accepted=$($ev1.accepted) rejected=$($ev1.rejected) (original fields kept: second_delete_scheduled=$($ev1.second_delete_scheduled))"

# ---------------------------------------------------------------- L5 rollback
$statsBeforeJson = (Get-Once '/p13b/harness/stats' "$RunId-stats-2" 'stats before the rollback').text | ConvertFrom-Json
$statsBeforeRb = $statsBeforeJson.evict
$warmB = Get-Once "/api/v1/article/detail/$RollbackId" "$RunId-warm-rollback" 'warm the cache before the rolled-back write'
Add-Check 'l5.rollback_cache_warmed' ((Redis-In $RedisDb @('EXISTS', $keyRollback)) -eq '1') `
    "warm-up http=$($warmB.http) key exists=$(Redis-In $RedisDb @('EXISTS', $keyRollback))"

$writeB = Post-Once "/p13b/harness/score?id=$RollbackId&view=1&like=1&comment=1&collect=1" "$RunId-write-rollback" 'controlled rollback of updateScore'
Add-Check 'l5.rollback_failed_as_expected' (($writeB.http -eq 200) -and ($writeB.text -match 'controlled rollback')) "http=$($writeB.http) body=$($writeB.text)"
$countsAfterB = Db-Counts $RollbackId
Add-Check 'l5.rollback_counters_unchanged' ($countsAfterB -eq $countsBefore.rollback) "before=$($countsBefore.rollback) after=$countsAfterB"
Start-Sleep -Milliseconds 900
Add-Check 'l5.rollback_cache_untouched' ((Redis-In $RedisDb @('EXISTS', $keyRollback)) -eq '1') `
    "key exists=$(Redis-In $RedisDb @('EXISTS', $keyRollback)) (a rolled-back write must not delete or schedule)"
$evRb = Ev-Since $RollbackId
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'events-rollback.log') -Text ((@($evRb)) -join "`r`n")
$accR = @($evRb | Where-Object { $_ -match ' event=cache\.evict\.second_accepted ' })
$rollbackEv = @($evRb | Where-Object { $_ -match ' event=p13b\.controlled_rollback ' })
Add-Check 'l5.rollback_no_second_delete' ($accR.Count -eq 0 -and $rollbackEv.Count -eq 1) `
    "second accepted=$($accR.Count) controlled_rollback events=$($rollbackEv.Count)"
$detailB = Get-Once "/api/v1/article/detail/$RollbackId" "$RunId-read-rollback" 'detail after the rolled-back write'
Add-Check 'l5.rollback_detail_still_200' (($detailB.http -eq 200) -and ($detailB.text -match [regex]::Escape('"id":"' + "$RollbackId" + '"'))) `
    "http=$($detailB.http) bytes=$($detailB.bytes) sha=$($detailB.sha)"

$stats2 = ((Get-Once '/p13b/harness/stats' "$RunId-stats-3" 'final stats').text | ConvertFrom-Json).evict
Add-Check 'l5.final_accounting_reconciles' (([long]$stats2.accepted) -eq ([long]$ev1.accepted) -and ([long]$stats2.succeeded) -eq ([long]$stats2.accepted) -and ([long]$stats2.active_now) -eq 0 -and ([long]$stats2.cancelled) -eq 0) `
    "accepted=$($stats2.accepted) (unchanged by the rollback: before=$($ev1.accepted)) succeeded=$($stats2.succeeded) active=$($stats2.active_now) cancelled=$($stats2.cancelled)"

# ---------------------------------------------------------------- restore and verify
$restoreLog = New-Object System.Collections.ArrayList
$null = $restoreLog.Add("DELETE FROM $Database.ap_article WHERE id IN ($CommitId,$RollbackId);")
$null = $restoreLog.Add("DELETE FROM $Database.ap_article_content WHERE id IN ($CommitId,$RollbackId);")
$null = $restoreLog.Add("DELETE FROM $Database.ap_article_config WHERE id IN ($CommitId,$RollbackId);")
$delFile = Join-Path $outDir 'restore-delete.sql'
[System.IO.File]::WriteAllText($delFile, (($restoreLog) -join "`r`n"), $utf8)
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Get-Content -LiteralPath $delFile -Raw | & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser $Database 1> (Join-Path $outDir 'restore-delete.log') 2>&1
$delCode = $LASTEXITCODE
foreach ($t in @('ap_article', 'ap_article_content', 'ap_article_config')) {
    $f = Join-Path $captureDir "$t.capture.sql"
    Get-Content -LiteralPath $f -Raw | & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser $Database 1>> (Join-Path $outDir 'restore-insert.log') 2>&1
}
$ErrorActionPreference = $saved
Add-Check 'l5.restore_applied' ($delCode -eq 0) "delete exit=$delCode; inserts replayed from the captured dump files"

$countsRestored = [ordered]@{ commit = (Db-Counts $CommitId); rollback = (Db-Counts $RollbackId) }
Add-Check 'l5.restore_counters_match_capture' (($countsRestored.commit -eq $countsBefore.commit) -and ($countsRestored.rollback -eq $countsBefore.rollback)) `
    "commit=$($countsRestored.commit) (captured $($countsBefore.commit)) rollback=$($countsRestored.rollback) (captured $($countsBefore.rollback))"
$rowCount = Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id IN ($CommitId,$RollbackId);"
Add-Check 'l5.restore_rows_present_exactly_once' ($rowCount -eq '2') "ap_article rows for the two ids: $rowCount"

Redis-In $RedisDb @('DEL', $keyCommit) | Out-Null
Redis-In $RedisDb @('DEL', $keyRollback) | Out-Null
Redis-In $RedisDb @('DEL', "${keyCommit}:lock") | Out-Null
Redis-In $RedisDb @('DEL', "${keyRollback}:lock") | Out-Null
Add-Check 'l5.keys_restored_and_db0_untouched' `
    (((Redis-In $RedisDb @('EXISTS', $keyCommit)) -eq '0') -and ((Redis-In 0 @('DBSIZE')) -eq '0')) `
    "commit key exists=$(Redis-In $RedisDb @('EXISTS', $keyCommit)) rollback key exists=$(Redis-In $RedisDb @('EXISTS', $keyRollback)) db5=$((Redis-In $RedisDb @('DBSIZE'))) db0=$((Redis-In 0 @('DBSIZE'))) (DB0 was never written, no FLUSHDB)"

$client.Dispose()
$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    base = $Base
    events = $Events
    commit_id = $CommitId
    rollback_id = $RollbackId
    counts_before = $countsBefore
    counts_after_commit = $countsAfterA
    counts_after_rollback = $countsAfterB
    counts_restored = $countsRestored
    capture_sha256 = $captureSha
    stats_after_commit = $stats1
    stats_before_rollback = $statsBeforeRb
    stats_final = $stats2
    first_delete_and_second_delete = [ordered]@{ first_ok = $okFirstC.Count; second_accepted = $accC.Count; second_succeeded = $succC.Count; second_failed = $failC.Count; task_ids = $taskIds }
    keys = $keys
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'l5-result.json') -Text ($result | ConvertTo-Json -Depth 7)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'l5-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
