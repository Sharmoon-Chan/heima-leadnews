# Capture the real pre-state of the P1.3b test rows / keys, and restore exactly that state later.
#
# Why not the old "re-insert from the generator" approach: the earlier hand-back could only claim
# "the fields listed in the seed tuple match". The A-D review asked for the actual full-row values of
# the rows we are about to write, saved BEFORE the writes, and restored from those values.
#
# capture: mysqldump (no create info, complete-insert, one row per statement) of the three tables for
#          the id set, plus the Redis key flags (EXISTS / TTL) of the exact keys this round may touch.
# restore: DELETE the id set in the three tables, re-apply the captured INSERT statements, then
#          re-dump and compare the row statements with the captured ones; Redis keys are removed
#          (documented: cache values are transient, presence is restored to "absent", not byte-wise).
#
# ASCII only (PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
# Exit codes: 0 = captured/restored and verified, 1 = verification failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][ValidateSet('capture', 'restore')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    # the capture directory is written once and read by the restore run
    [Parameter(Mandatory = $true)][string]$StateDir,
    [long[]]$Ids = @(9007199254741015, 9007199254741016, 9007199254741017, 9007199254741018,
                     9007199254741019, 9007199254741020, 9007199254741021, 9007199254741022),
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    # rows CREATED by this round (not present at capture time): removed on restore and asserted absent
    [long[]]$DeleteIds = @(9007199254760001),
    [string]$MysqlDump = 'D:\Soft\mysql-8.0.34-winx64\bin\mysqldump.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    # keys that only appear during the round (derived at restore time, e.g. the real hot-list channel key)
    [string[]]$ExtraKeys = @(),
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    # the isolated Redis database this round runs the application in
    [int]$RedisDb = 5,
    [string]$CacheKeyPrefix = 'article:detail:',
    [string[]]$HotKeys = @('hot_article_first_page_1', 'hot_article_first_page___all__')
)

$ErrorActionPreference = 'Stop'
$env:MYSQL_PWD = $MysqlPassword

. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage "P1.3b-pre-state-$Mode" `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ mode = $Mode; ids = ($Ids -join ','); database = $Database; redis_db = $RedisDb; state_dir = $StateDir } `
        -Targets @($Ids | ForEach-Object { "$_" }) -DataSet $Database
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
}
function Get-Sha([string]$p) {
    if ($p -and (Test-Path -LiteralPath $p)) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }
    return ''
}
function Sql([string]$q) {
    $o = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '-e' $q 2>&1
    return (($o | Out-String).Trim())
}
function Redis([int]$db, [string[]]$a) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', "$db") + $a
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Dump-Rows([string]$table, [string]$idColumn, [string]$target) {
    $where = "$idColumn IN ($($Ids -join ','))"
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $MysqlDump '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '--no-create-info' '--complete-insert' `
        '--skip-extended-insert' '--skip-add-locks' '--compact' "--where=$where" $Database $table 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $inserts = @($out | Where-Object { $_ -match '^INSERT INTO' })
    [System.IO.File]::WriteAllText($target, ($inserts -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{ exit = $code; rows = $inserts.Count }
}
function Get-RowCounts {
    $a = Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id IN ($($Ids -join ','));"
    $c = Sql "SELECT COUNT(*) FROM $Database.ap_article_content WHERE article_id IN ($($Ids -join ','));"
    $g = Sql "SELECT COUNT(*) FROM $Database.ap_article_config WHERE article_id IN ($($Ids -join ','));"
    return "$a|$c|$g"
}

$keyNames = @()
foreach ($id in $Ids) { $keyNames += "$CacheKeyPrefix$id"; $keyNames += "$CacheKeyPrefix$id`:lock" }
$keyNames += $HotKeys

if ($Mode -eq 'capture') {
    if (Test-Path -LiteralPath $StateDir) {
        Write-Host "REFUSED: state directory already exists: $StateDir"
        exit 2
    }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $tables = @(
        @{ name = 'ap_article'; col = 'id' },
        @{ name = 'ap_article_content'; col = 'article_id' },
        @{ name = 'ap_article_config'; col = 'article_id' }
    )
    $dumpInfo = [ordered]@{}
    foreach ($t in $tables) {
        $target = Join-Path $StateDir ("$($t.name).inserts.sql")
        $r = Dump-Rows $t.name $t.col $target
        $dumpInfo[$t.name] = [ordered]@{ exit = $r.exit; rows = $r.rows; file = "$($t.name).inserts.sql"; sha256 = (Get-Sha $target) }
    }

    $keyInfo = [ordered]@{}
    foreach ($k in $keyNames) {
        $keyInfo[$k] = [ordered]@{
            app_db_exists = (Redis $RedisDb @('EXISTS', $k))
            app_db_ttl = (Redis $RedisDb @('TTL', $k))
            course_db0_exists = (Redis 0 @('EXISTS', $k))
        }
    }
    $rowCounts = Get-RowCounts

    $state = [ordered]@{
        captured_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        database = $Database
        ids = $Ids
        row_counts = $rowCounts
        tables = $dumpInfo
        redis_db = $RedisDb
        redis_keys = $keyInfo
        note = 'full-row INSERT statements of the three tables, one row per statement; this is the actual pre-state, not a regenerated seed'
    }
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'pre-state.json'), ($state | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'capture-summary.json') -Text ($state | ConvertTo-Json -Depth 6)

    $ok = ($dumpInfo['ap_article'].exit -eq 0) -and ($dumpInfo['ap_article_content'].exit -eq 0) -and ($dumpInfo['ap_article_config'].exit -eq 0)
    Add-Check 'capture.dumps_succeeded' $ok "mysqldump rows: article=$($dumpInfo['ap_article'].rows) content=$($dumpInfo['ap_article_content'].rows) config=$($dumpInfo['ap_article_config'].rows)"
    Add-Check 'capture.rows_present' ($dumpInfo['ap_article'].rows -ge 8) "row counts (article|content|config) = $rowCounts"
    Add-Check 'capture.keys_recorded' ($keyInfo.Count -eq $keyNames.Count) "captured $($keyInfo.Count) exact key states in redis db $RedisDb"
}
else {
    if (-not (Test-Path -LiteralPath $StateDir)) { Write-Host "REFUSED: missing state directory: $StateDir"; exit 2 }
    $statePath = Join-Path $StateDir 'pre-state.json'
    if (-not (Test-Path -LiteralPath $statePath)) { Write-Host "REFUSED: missing pre-state.json: $statePath"; exit 2 }
    $state = Get-Content $statePath -Raw | ConvertFrom-Json

    # 1. captured files must still match the hashes recorded at capture time
    $hashOk = $true
    foreach ($name in @('ap_article', 'ap_article_content', 'ap_article_config')) {
        $f = Join-Path $StateDir "$name.inserts.sql"
        if ((Get-Sha $f) -ne $state.tables.$name.sha256) { $hashOk = $false }
    }
    Add-Check 'restore.captured_files_intact' $hashOk "three INSERT files still match the capture hashes"

    # 2. delete the id set and re-apply the captured full rows
    $idList = ($Ids -join ',')
    $del = Sql "DELETE FROM $Database.ap_article WHERE id IN ($idList); DELETE FROM $Database.ap_article_content WHERE article_id IN ($idList); DELETE FROM $Database.ap_article_config WHERE article_id IN ($idList); SELECT 'deleted';"
    Add-Check 'restore.rows_deleted' ($del -eq 'deleted') "delete of the id set in the three tables: '$del'"

    $applyErrors = @()
    foreach ($name in @('ap_article', 'ap_article_content', 'ap_article_config')) {
        $f = Join-Path $StateDir "$name.inserts.sql"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '--default-character-set=utf8mb4' $Database -e "source $($f -replace '\\','/')" 2>&1
        $code = $LASTEXITCODE
$keyNames += $HotKeys
$keyNames += $ExtraKeys
        if ($code -ne 0) { $applyErrors += "$name exit=$code $((@($out) -join ' ').Trim())" }
    }
    Add-Check 'restore.inserts_applied' ($applyErrors.Count -eq 0) "apply errors: $(@($applyErrors) -join ' ; ')"

    # 2b. rows created by this round must be gone (they did not exist at capture time)
    if ($DeleteIds.Count -gt 0) {
        $dl = ($DeleteIds -join ',')
        $null = Sql "DELETE FROM $Database.ap_article WHERE id IN ($dl);"
        $null = Sql "DELETE FROM $Database.ap_article_content WHERE article_id IN ($dl);"
        $null = Sql "DELETE FROM $Database.ap_article_config WHERE article_id IN ($dl);"
        $leftA = Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id IN ($dl);"
        $leftC = Sql "SELECT COUNT(*) FROM $Database.ap_article_content WHERE article_id IN ($dl);"
        $leftG = Sql "SELECT COUNT(*) FROM $Database.ap_article_config WHERE article_id IN ($dl);"
        Add-Check 'restore.created_rows_removed' (($leftA -eq '0') -and ($leftC -eq '0') -and ($leftG -eq '0')) `
            "ids created this round ($dl) remaining counts: article=$leftA content=$leftC config=$leftG"
    }
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'apply.log') -Text ((@($applyErrors) -join "`r`n"))

    # 3. re-dump and compare the actual row statements
    $verifyDir = Join-Path $OutDir 'verify'
    New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
    $allMatch = $true
    $detailLines = @()
    foreach ($t in @(
            @{ name = 'ap_article'; col = 'id' },
            @{ name = 'ap_article_content'; col = 'article_id' },
            @{ name = 'ap_article_config'; col = 'article_id' })) {
        $after = Join-Path $verifyDir ("$($t.name).after.sql")
        $null = Dump-Rows $t.name $t.col $after
        $before = @(Get-Content (Join-Path $StateDir "$($t.name).inserts.sql")) | Sort-Object
        $now = @(Get-Content $after) | Sort-Object
        $same = (($before -join "`n") -eq ($now -join "`n"))
        if (-not $same) { $allMatch = $false }
        $detailLines += "$($t.name): before=$($before.Count) after=$($now.Count) identical=$same"
    }
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'verify.txt') -Text ((@($detailLines) -join "`r`n"))
    Add-Check 'restore.rows_match_captured_full_rows' $allMatch ((@($detailLines) -join ' | '))

    # 4. Redis keys this round wrote are removed (presence restored to absent); never FLUSHDB
    $null = Redis $RedisDb (@('DEL') + $keyNames)
    $flags = @()
    foreach ($k in $keyNames) { $flags += (Redis $RedisDb @('EXISTS', $k)) }
    Add-Check 'restore.keys_absent' ((@($flags | Where-Object { $_ -eq '1' })).Count -eq 0) "EXISTS flags after DEL: $($flags -join ' ')"
    Add-Check 'restore.course_db_untouched' ((@(foreach ($k in $keyNames) { Redis 0 @('EXISTS', $k) }) | Where-Object { $_ -eq '1' }).Count -eq 0) 'no exact key of this round exists in the course database 0'

    $rowCounts = Get-RowCounts
    $receipt = [ordered]@{
        restored_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        state_dir = $StateDir
        state_sha256 = (Get-Sha $statePath)
        ids = $Ids
        row_counts_after = $rowCounts
        per_table = $detailLines
        recreated = (@($Ids | Where-Object { @($state.tables.ap_article.rows) -ge 0 })).Count
        redis_db = $RedisDb
        redis_note = 'exact keys removed; cache values are transient and were NOT byte-restored'
        mysql_exit_codes = 'applied via mysql source; see apply.log'
    }
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'restore-receipt.json') -Text ($receipt | ConvertTo-Json -Depth 6)
    Add-Check 'restore.row_counts_match_capture' ($rowCounts -eq $state.row_counts) "row counts after=$rowCounts captured=$($state.row_counts)"
}

$counts = Get-RunCheckCounts $script:run
$script:run.checks | ForEach-Object { "{0,-44} {1,-6} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
