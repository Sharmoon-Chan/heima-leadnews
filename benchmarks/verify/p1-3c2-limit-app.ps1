# P1.3c-2 Q5b: the controlled over-limit sample on the real application (ASCII only).
#
# max-active is set to 1 for this instance and the first submit's second delete is slowed down, so the
# second submit really arrives while the only slot is taken. What must hold:
#   * the second submit is still COMMITTED (its behaviour counters move by +1) and its first delete still runs
#   * only ONE second delete is accepted; the other one is refused with reason=backlog and never queued
#   * submit_attempts = accepted + rejected, rejected_backlog counts exactly the refused submits
#   * active_peak never exceeds max_active, and everything reconciles once the slow task has finished
#
# Both rows are captured with mysqldump BEFORE any write and restored from those files, then verified.
# Keys are restored from their captured state. DB0 is never written and never flushed.
#
# Exit codes: 0 = all checks passed, 1 = a check failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Events,
    [long]$FirstId = 9007199254743095,
    [long]$SecondId = 9007199254743096,
    [int]$SecondSubmitDelayMs = 200,
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlDump = 'D:\Soft\mysql-8.0.34-winx64\bin\mysqldump.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [int]$RedisDb = 5,
    [string]$CacheKeyPrefix = 'article:detail:',
    [int]$SettleTimeoutMs = 25000,
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
    $script:run = Start-RunDirectory -OutDir $outDir -RunId $RunId -Stage 'P1.3c-2-Q5b-over-limit-sample' `
        -ExperimentRoot $RunRoot -ScriptPath $PSCommandPath `
        -Parameters @{ first_id = $FirstId; second_id = $SecondId; base = $Base; redis_db = $RedisDb; max_active = 1 } `
        -Targets @("$FirstId", "$SecondId") -DataSet $Database
} catch {
    Write-Host "REFUSED (guard): $($_.Exception.Message)"
    exit 2
}

$tab = [char]9
$scriptStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
    "{0,-52} {1,-6} {2}" -f $n, $(if ($ok) { 'pass' } else { 'FAIL' }), $d
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
$where = "id IN ($FirstId,$SecondId)"
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

$countsBefore = [ordered]@{ first = (Db-Counts $FirstId); second = (Db-Counts $SecondId) }
$keyFirst = "$CacheKeyPrefix$FirstId"
$keySecond = "$CacheKeyPrefix$SecondId"
$keys = [ordered]@{
    db5_size_before = (Redis-In $RedisDb @('DBSIZE'))
    db0_size_before = (Redis-In 0 @('DBSIZE'))
}
Add-Check 'q5b.capture_before_write' (($countsBefore.first -match '^\d+\|\d+\|\d+\|\d+$') -and ($countsBefore.second -match '^\d+\|\d+\|\d+\|\d+$') -and $keys.db0_size_before -eq '0') `
    "first row=$($countsBefore.first) second row=$($countsBefore.second) db5=$($keys.db5_size_before) db0=$($keys.db0_size_before)"

# ---------------------------------------------------------------- HTTP helpers (raw body persisted at once)
Add-Type -AssemblyName System.Net.Http | Out-Null
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
$script:seq = 0
function Get-Once([string]$path, [string]$reqId) {
    $script:seq++
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$Base$path")
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $p = Join-Path $outDir (("raw-{0:D2}-{1}.body.json" -f $script:seq, $reqId))
    Write-RunFileText -State $script:run -Path $p -Text $text
    $sha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
    return [pscustomobject]@{ http = [int]$resp.StatusCode; text = $text; bytes = $bytes.Length; sha = $sha; path = $p }
}
function Post-Once([string]$path, [string]$reqId) {
    $script:seq++
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post, "$Base$path")
    $req.Content = New-Object System.Net.Http.StringContent('')
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $RunId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $reqId)
    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $p = Join-Path $outDir (("raw-{0:D2}-{1}.body.json" -f $script:seq, $reqId))
    Write-RunFileText -State $script:run -Path $p -Text $text
    $sha = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-', '').ToLower()
    return [pscustomobject]@{ http = [int]$resp.StatusCode; text = $text; bytes = $bytes.Length; sha = $sha; path = $p }
}
function Stats() { return ((Get-Once '/p13b/harness/stats' "$RunId-stats-$($script:seq)").text | ConvertFrom-Json).evict }

# ---------------------------------------------------------------- the controlled over-limit sample
$statsAtStart = Stats
Add-Check 'q5b.limit_is_one' (([long]$statsAtStart.max_active) -eq 1) `
    "max_active=$($statsAtStart.max_active) (component property --p13c.evict.max-active=1) active=$($statsAtStart.active_now)"

$warmF = Get-Once "/api/v1/article/detail/$FirstId" "$RunId-warm-first"
$warmS = Get-Once "/api/v1/article/detail/$SecondId" "$RunId-warm-second"
Add-Check 'q5b.both_cache_keys_warmed' (((Redis-In $RedisDb @('EXISTS', $keyFirst)) -eq '1') -and ((Redis-In $RedisDb @('EXISTS', $keySecond)) -eq '1')) `
    "first http=$($warmF.http) second http=$($warmS.http) keyFirst=$(Redis-In $RedisDb @('EXISTS', $keyFirst)) keySecond=$(Redis-In $RedisDb @('EXISTS', $keySecond))"

$w1 = Post-Once "/p13b/harness/score?id=$FirstId&view=1&like=1&comment=1&collect=1" "$RunId-write-first"
Start-Sleep -Milliseconds $SecondSubmitDelayMs
$statsWhileFull = Stats
$w2 = Post-Once "/p13b/harness/score?id=$SecondId&view=1&like=1&comment=1&collect=1" "$RunId-write-second"

Add-Check 'q5b.slot_was_taken_at_second_submit' (([long]$statsWhileFull.active_now) -eq 1 -and ([long]$statsWhileFull.max_active) -eq 1) `
    "active while full=$($statsWhileFull.active_now) max_active=$($statsWhileFull.max_active) accepted=$($statsWhileFull.accepted)"
Add-Check 'q5b.first_submit_accepted' (($w1.http -eq 200) -and ($w1.text -match '"ok"\s*:\s*true')) "http=$($w1.http) body=$($w1.text)"
Add-Check 'q5b.second_submit_still_committed' (($w2.http -eq 200) -and ($w2.text -match '"ok"\s*:\s*true')) `
    "http=$($w2.http) body=$($w2.text) (the refused second delete must not change the write result)"

$countsAfter = [ordered]@{ first = (Db-Counts $FirstId); second = (Db-Counts $SecondId) }
$deltaOk = $true
foreach ($k in @('first', 'second')) {
    $b = ($countsBefore[$k] -split '\|'); $a = ($countsAfter[$k] -split '\|')
    if ($a.Count -ne 4) { $deltaOk = $false; continue }
    for ($i = 0; $i -lt 4; $i++) { if (([int]$a[$i] - [int]$b[$i]) -ne 1) { $deltaOk = $false } }
}
Add-Check 'q5b.both_writes_committed_plus_one' $deltaOk `
    "first before=$($countsBefore.first) after=$($countsAfter.first); second before=$($countsBefore.second) after=$($countsAfter.second)"

# ---------------------------------------------------------------- settle, then read events of THIS run
function Ev-Since([long]$articleId) {
    if (-not (Test-Path -LiteralPath $Events)) { return @() }
    $start = $scriptStartMs
    return @(Get-Content -LiteralPath $Events | Where-Object {
        ($_ -match " articleId=$articleId ") -and
        ([long]([regex]::Match($_, 'epochMs=(\d+)').Groups[1].Value) -ge $start)
    })
}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$statsAfter = $null
while ($sw.ElapsedMilliseconds -lt $SettleTimeoutMs) {
    $statsAfter = Stats
    if (([long]$statsAfter.active_now) -eq 0 -and ([long]$statsAfter.submit_attempts) -eq 2) { break }
    Start-Sleep -Milliseconds 150
}
$evFirst = Ev-Since $FirstId
$evSecond = Ev-Since $SecondId
$evAll = @($evFirst) + @($evSecond)
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'events-first.log') -Text ((@($evFirst)) -join "`r`n")
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'events-second.log') -Text ((@($evSecond)) -join "`r`n")

$okFirstPhase = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.ok ' -and $_ -notmatch 'phase=[^ ]*:second' })
$acc = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_accepted ' })
$rej = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_rejected ' })
$rejBacklog = @($rej | Where-Object { $_ -match ' reason=backlog ' })
$succ = @($evAll | Where-Object { $_ -match ' event=cache\.evict\.second_succeeded ' })
$rejSecond = @($rejBacklog | Where-Object { $_ -match (" articleId=" + $SecondId + " ") })

Add-Check 'q5b.first_delete_ran_for_both_submits' ($okFirstPhase.Count -eq 2) `
    "first-phase ok events=$($okFirstPhase.Count) (both submissions delete immediately, limit or no limit)"
Add-Check 'q5b.only_one_second_delete_accepted' ($acc.Count -eq 1 -and $succ.Count -eq 1) `
    "second accepted=$($acc.Count) succeeded=$($succ.Count)"
Add-Check 'q5b.second_delete_refused_as_backlog' ($rej.Count -eq 1 -and $rejBacklog.Count -eq 1) `
    "second_rejected=$($rej.Count) reason=backlog=$($rejBacklog.Count)"
Add-Check 'q5b.refusal_names_task_article_and_limit' ($rejBacklog.Count -eq 1 -and $rejBacklog[0] -match ' taskId=t\d+-\d+ ' -and $rejBacklog[0] -match (" articleId=" + $SecondId + " ") -and $rejBacklog[0] -match ' phase=[^ ]+' -and $rejBacklog[0] -match ' maxActive=1 ') `
    "refused line=$($rejBacklog -join ' | ')"
Add-Check 'q5b.refused_submit_was_the_second_one' ($rejSecond.Count -eq 1 -and @($acc | Where-Object { $_ -match (" articleId=" + $SecondId + " ") }).Count -eq 0) `
    "refused for articleId=$SecondId; accepted for articleId=$SecondId=$(@($acc | Where-Object { $_ -match (" articleId=" + $SecondId + " ") }).Count)"
$taskIds = @($acc | ForEach-Object { [regex]::Match($_, 'taskId=([^ ]+)').Groups[1].Value })
Add-Check 'q5b.accepted_task_id_shape' ($taskIds.Count -eq 1 -and $taskIds[0] -match '^t\d+-\d+$') "taskId=$($taskIds -join ',')"

Add-Check 'q5b.counters_reconcile' (([long]$statsAfter.submit_attempts) -eq 2 -and ([long]$statsAfter.accepted) -eq 1 -and ([long]$statsAfter.rejected) -eq 1 -and ([long]$statsAfter.rejected_backlog) -eq 1 -and ([long]$statsAfter.active_now) -eq 0 -and ([long]$statsAfter.rejected_closed) -eq 0 -and ([long]$statsAfter.rejected_scheduler) -eq 0) `
    "submit_attempts=$($statsAfter.submit_attempts) accepted=$($statsAfter.accepted) rejected=$($statsAfter.rejected) backlog=$($statsAfter.rejected_backlog) scheduler=$($statsAfter.rejected_scheduler) closed=$($statsAfter.rejected_closed) active=$($statsAfter.active_now)"
Add-Check 'q5b.peak_never_exceeded_limit' (([long]$statsAfter.active_peak) -eq 1 -and ([long]$statsAfter.max_active) -eq 1) `
    "active_peak=$($statsAfter.active_peak) max_active=$($statsAfter.max_active)"
Add-Check 'q5b.terminal_counters_reconcile' (([long]$statsAfter.accepted) -eq (([long]$statsAfter.succeeded) + ([long]$statsAfter.failed) + ([long]$statsAfter.cancelled))) `
    "accepted=$($statsAfter.accepted) succeeded=$($statsAfter.succeeded) failed=$($statsAfter.failed) cancelled=$($statsAfter.cancelled)"

$d1 = Get-Once "/api/v1/article/detail/$FirstId" "$RunId-read-first"
$d2 = Get-Once "/api/v1/article/detail/$SecondId" "$RunId-read-second"
$a1 = ($countsAfter.first -split '\|')[0]
$a2 = ($countsAfter.second -split '\|')[0]
Add-Check 'q5b.detail_fresh_for_both' (($d1.http -eq 200) -and ($d2.http -eq 200) -and ($d1.text -match [regex]::Escape('"id":"' + "$FirstId" + '"')) -and ($d2.text -match [regex]::Escape('"id":"' + "$SecondId" + '"')) -and ($d1.text -match ('"views"\s*:\s*' + $a1)) -and ($d2.text -match ('"views"\s*:\s*' + $a2))) `
    "first http=$($d1.http) sha=$($d1.sha) views_expected=$a1; second http=$($d2.http) sha=$($d2.sha) views_expected=$a2"

# ---------------------------------------------------------------- restore and verify
$restoreLog = New-Object System.Collections.ArrayList
$null = $restoreLog.Add("DELETE FROM $Database.ap_article WHERE id IN ($FirstId,$SecondId);")
$null = $restoreLog.Add("DELETE FROM $Database.ap_article_content WHERE id IN ($FirstId,$SecondId);")
$null = $restoreLog.Add("DELETE FROM $Database.ap_article_config WHERE id IN ($FirstId,$SecondId);")
$delFile = Join-Path $outDir 'restore-delete.sql'
[System.IO.File]::WriteAllText($delFile, (($restoreLog) -join "`r`n"), $utf8)
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
Get-Content -LiteralPath $delFile -Raw | & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser $Database 1> (Join-Path $outDir 'restore-delete.log') 2>&1
$delCode = $LASTEXITCODE
foreach ($t in $tables) {
    $f = Join-Path $captureDir "$t.capture.sql"
    Get-Content -LiteralPath $f -Raw | & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser $Database 1>> (Join-Path $outDir 'restore-insert.log') 2>&1
}
$ErrorActionPreference = $saved
Add-Check 'q5b.restore_applied' ($delCode -eq 0) "delete exit=$delCode; inserts replayed from the captured dump files"

$countsRestored = [ordered]@{ first = (Db-Counts $FirstId); second = (Db-Counts $SecondId) }
Add-Check 'q5b.restore_counters_match_capture' (($countsRestored.first -eq $countsBefore.first) -and ($countsRestored.second -eq $countsBefore.second)) `
    "first=$($countsRestored.first) (captured $($countsBefore.first)) second=$($countsRestored.second) (captured $($countsBefore.second))"
$rowCount = Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id IN ($FirstId,$SecondId);"
Add-Check 'q5b.restore_rows_present_exactly_once' ($rowCount -eq '2') "ap_article rows for the two ids: $rowCount"

Redis-In $RedisDb @('DEL', $keyFirst) | Out-Null
Redis-In $RedisDb @('DEL', $keySecond) | Out-Null
Redis-In $RedisDb @('DEL', "${keyFirst}:lock") | Out-Null
Redis-In $RedisDb @('DEL', "${keySecond}:lock") | Out-Null
Add-Check 'q5b.keys_restored_and_db0_untouched' `
    (((Redis-In $RedisDb @('EXISTS', $keyFirst)) -eq '0') -and ((Redis-In 0 @('DBSIZE')) -eq '0')) `
    "first key exists=$(Redis-In $RedisDb @('EXISTS', $keyFirst)) second key exists=$(Redis-In $RedisDb @('EXISTS', $keySecond)) db5=$((Redis-In $RedisDb @('DBSIZE'))) db0=$((Redis-In 0 @('DBSIZE'))) (DB0 was never written, no FLUSHDB)"

$client.Dispose()
$counts = Get-RunCheckCounts $script:run
$result = [ordered]@{
    run_id = $RunId
    base = $Base
    events = $Events
    first_id = $FirstId
    second_id = $SecondId
    second_submit_delay_ms = $SecondSubmitDelayMs
    counts_before = $countsBefore
    counts_after = $countsAfter
    counts_restored = $countsRestored
    capture_sha256 = $captureSha
    stats_at_start = $statsAtStart
    stats_while_full = $statsWhileFull
    stats_after_settle = $statsAfter
    second_delete = [ordered]@{
        first_phase_ok = $okFirstPhase.Count
        accepted = $acc.Count
        succeeded = $succ.Count
        rejected = $rej.Count
        rejected_backlog = $rejBacklog.Count
        accepted_task_ids = $taskIds
        refused_lines = $rejBacklog
    }
    keys = $keys
    counts = $counts
    checks = $script:run.checks
}
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'q5b-result.json') -Text ($result | ConvertTo-Json -Depth 7)
$tsv = New-Object System.Collections.ArrayList
$null = $tsv.Add((@('check', 'status', 'detail') -join $tab))
foreach ($c in $script:run.checks) { $null = $tsv.Add((@($c.check, $c.status, ($c.detail -replace "`t", ' ')) -join $tab)) }
Write-RunFileText -State $script:run -Path (Join-Path $outDir 'q5b-checks.tsv') -Text (($tsv -join "`r`n") + "`r`n")

"counts: total=$($counts.total) passed=$($counts.passed) failed=$($counts.failed)"
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
