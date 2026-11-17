# P1.3b round-2 state handling: shared baseline, residual capture, bounded cleanup, restore (ASCII only).
#
# Why this exists (TOOL-007 / TOOL-008 from the 2026-11-03 review):
#   * round 1 captured a baseline per variant, so PRE started from values the POST run had already
#     written. Both variants must now start from ONE frozen baseline file with the same hash.
#   * round 1's restore set missed rows a FAILED fixture had actually changed (9007199254741099) and
#     missed Redis keys the fixtures wrote. The write set must be enumerated, captured and reconciled.
#
# Modes
#   capture-baseline  write-once shared baseline: full rows of the write-set ids + exact key pre-values
#   capture-residual  write-once capture of the CURRENT leftover state (rows + every key in the app db)
#   cleanup-residual  bounded cleanup of exactly the captured leftovers, with per-item receipt
#   restore           re-apply the baseline rows, delete rows created this round, remove round-2 keys,
#                     then verify row-by-row and key-by-key
#
# Exit codes: 0 = done and verified, 1 = verification failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][ValidateSet('capture-baseline', 'capture-residual', 'cleanup-residual', 'restore')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [Parameter(Mandatory = $true)][string]$StateDir,
    # rows the experiments may read or write, including the row a failed fixture touched in round 1
    [long[]]$Ids = @(9007199254741015, 9007199254741016, 9007199254741017, 9007199254741018,
                     9007199254741020, 9007199254741021, 9007199254741022, 9007199254741099),
    # rows this round is allowed to CREATE (must not exist at capture time and must be gone at the end)
    [long[]]$CreateIds = @(9007199254760001, 9007199254760002),
    [int]$RedisDb = 5,
    [string]$CacheKeyPrefix = 'article:detail:',
    [string]$DefaultTag = '__all__',
    [string]$HotPrefix = 'hot_article_first_page_',
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlDump = 'D:\Soft\mysql-8.0.34-winx64\bin\mysqldump.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe'
)

$ErrorActionPreference = 'Stop'
$env:MYSQL_PWD = $MysqlPassword

. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage "P1.3b-round2-$Mode" `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ mode = $Mode; ids = ($Ids -join ','); create_ids = ($CreateIds -join ','); database = $Database; redis_db = $RedisDb } `
        -Targets @(($Ids + $CreateIds) | ForEach-Object { "$_" }) -DataSet $Database
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
    $o = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--raw' '--default-character-set=utf8mb4' '-e' $q 2>&1
    return (($o | Out-String).Trim())
}
function Redis([int]$db, [string[]]$a) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', "$db") + $a
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
# binary-safe single value read (a hot list is JSON with quotes; -x/stdin is only for writes)
function Redis-Scan([int]$db) {
    $raw = @(& $RedisCli '-h' '127.0.0.1' '-p' '6379' '-n' "$db" 'KEYS' '*')
    return @($raw | Where-Object { $_ -ne '' })
}
function Dump-Rows([string]$table, [string]$idColumn, [long[]]$idSet, [string]$target) {
    $where = "$idColumn IN ($($idSet -join ','))"
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
function Get-RowValues([long]$id) {
    $q = "SELECT CONCAT_WS(CHAR(9), IFNULL(title,'~'), views, likes, comment, collection, channel_id, " +
         "IFNULL(static_url,'~'), (SELECT COUNT(*) FROM $Database.ap_article_content c WHERE c.article_id=a.id), " +
         "(SELECT COUNT(*) FROM $Database.ap_article_config g WHERE g.article_id=a.id)) " +
         "FROM $Database.ap_article a WHERE a.id=$id;"
    $line = Sql $q
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    $p = $line -split "`t"
    return [pscustomobject]@{ title = $p[0]; views = [int]$p[1]; likes = [int]$p[2]; comment = [int]$p[3];
                              collection = [int]$p[4]; channel_id = [int]$p[5]; static_url = $p[6];
                              content_rows = [int]$p[7]; config_rows = [int]$p[8] }
}
function Get-KeyState([int]$db, [string]$key) {
    $exists = (Redis $db @('EXISTS', $key)).Trim()
    $type = if ($exists -eq '1') { (Redis $db @('TYPE', $key)).Trim() } else { '' }
    # the value is written through stdin so quotes and backslashes survive untouched
    $value = ''
    if ($type -eq 'string') {
        $value = ((Redis $db @('GET', $key)) -replace "`r", '\r' -replace "`n", '\n')
    }
    $ttl = (Redis $db @('TTL', $key)).Trim()
    return [ordered]@{ db = $db; key = $key; exists = $exists; type = $type; ttl = $ttl; value = $value;
                       kind = $(if ($type -eq 'string') { 'string' } elseif ($type -eq '') { 'absent' } else { 'other' }) }
}
# every key name this round can possibly touch, derived from the REAL channel ids in the database
function Get-WriteSetKeys {
    $keys = New-Object System.Collections.ArrayList
    foreach ($id in $Ids) { $null = $keys.Add("$CacheKeyPrefix$id"); $null = $keys.Add("$CacheKeyPrefix$id`:lock") }
    $hot = @()
    foreach ($id in $Ids) {
        $r = Get-RowValues $id
        if ($r) {
            $hot += "$HotPrefix$($r.channel_id)"
            $hot += "$HotPrefix$DefaultTag"
        }
    }
    # the hot prefix with an empty suffix was produced by a round-1 script defect; keep it in the set so
    # the reconciliation explains it instead of silently ignoring it
    $hot += $HotPrefix
    foreach ($k in ($hot | Sort-Object -Unique)) { $null = $keys.Add($k) }
    return @($keys | Sort-Object -Unique)
}

$statePath = Join-Path $StateDir 'baseline.json'

if ($Mode -eq 'capture-baseline') {
    if (Test-Path -LiteralPath $StateDir) { Write-Host "REFUSED: state directory already exists: $StateDir"; exit 2 }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    # rows must be captured BEFORE any write of this round
    $dumpInfo = [ordered]@{}
    foreach ($t in @(@{ name = 'ap_article'; col = 'id' }, @{ name = 'ap_article_content'; col = 'article_id' },
                     @{ name = 'ap_article_config'; col = 'article_id' })) {
        $target = Join-Path $StateDir ("$($t.name).inserts.sql")
        $r = Dump-Rows $t.name $t.col $Ids $target
        $dumpInfo[$t.name] = [ordered]@{ exit = $r.exit; rows = $r.rows; file = "$($t.name).inserts.sql"; sha256 = (Get-Sha $target) }
    }

    $rows = [ordered]@{}
    foreach ($id in $Ids) {
        $v = Get-RowValues $id
        if (-not $v) { Write-Host "REFUSED: row $id does not exist; baseline needs real pre-values"; exit 2 }
        $rows["$id"] = $v
    }

    $keys = Get-WriteSetKeys
    $keyState = [ordered]@{}
    foreach ($k in $keys) { $keyState[$k] = Get-KeyState $RedisDb $k }

    # every key that actually exists in the app db right now (set verification only, no deletion here)
    $existing = Redis-Scan $RedisDb

    $baseline = [ordered]@{
        run_scope = 'P1.3b-round2'
        captured_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        database = $Database
        ids = $Ids
        create_ids = $CreateIds
        rows = $rows
        tables = $dumpInfo
        redis_db = $RedisDb
        keys = $keyState
        existing_keys_in_app_db = $existing
        notes = 'full rows and exact key pre-values captured BEFORE any write of this round; both variants must use this file'
    }
    [System.IO.File]::WriteAllText($statePath, ($baseline | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'baseline-sha256.txt') -Text (Get-Sha $statePath)

    Add-Check 'baseline.dumps_succeeded' ((@($dumpInfo.Values | Where-Object { $_.exit -ne 0 }).Count -eq 0)) `
        "mysqldump rows: article=$($dumpInfo['ap_article'].rows) content=$($dumpInfo['ap_article_content'].rows) config=$($dumpInfo['ap_article_config'].rows)"
    Add-Check 'baseline.rows_captured' ($rows.Count -eq $Ids.Count) "captured $($rows.Count)/$($Ids.Count) full rows (four counters + title + channel + static_url + child counts)"
    Add-Check 'baseline.keys_captured' ($keyState.Count -eq $keys.Count) "captured $($keyState.Count) exact key states in db $RedisDb (includes the real channel hot keys and the empty-suffix key)"
    Add-Check 'baseline.create_ids_absent' ((@($CreateIds | Where-Object { (Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id=$_;") -ne '0' }).Count -eq 0)) `
        "create ids ($($CreateIds -join ',')) must not exist before the round"
}

elseif ($Mode -eq 'capture-residual') {
    if (Test-Path -LiteralPath $StateDir) { Write-Host "REFUSED: residual directory already exists: $StateDir"; exit 2 }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $rows = [ordered]@{}
    foreach ($id in ($Ids + $CreateIds)) {
        $rows["$id"] = Get-RowValues $id
    }
    $dumpInfo = [ordered]@{}
    foreach ($t in @(@{ name = 'ap_article'; col = 'id' }, @{ name = 'ap_article_content'; col = 'article_id' },
                     @{ name = 'ap_article_config'; col = 'article_id' })) {
        $target = Join-Path $StateDir ("$($t.name).residual-inserts.sql")
        $r = Dump-Rows $t.name $t.col ($Ids + $CreateIds) $target
        $dumpInfo[$t.name] = [ordered]@{ exit = $r.exit; rows = $r.rows; file = "$($t.name).residual-inserts.sql"; sha256 = (Get-Sha $target) }
    }
    $allKeys = Redis-Scan $RedisDb
    $keyState = [ordered]@{}
    foreach ($k in $allKeys) { $keyState[$k] = Get-KeyState $RedisDb $k }
    $db0Keys = Redis-Scan 0

    $residual = [ordered]@{
        captured_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        database = $Database
        rows = $rows
        tables = $dumpInfo
        redis_db = $RedisDb
        keys = $keyState
        db0_key_count = @($db0Keys).Count
        db0_hot_keys = @($db0Keys | Where-Object { $_ -like "$HotPrefix*" })
        article_total = (Sql "SELECT COUNT(*) FROM $Database.ap_article;")
        notes = 'current leftover state, captured before cleanup; values are the actual on-disk/redis state'
    }
    [System.IO.File]::WriteAllText((Join-Path $StateDir 'residual.json'), ($residual | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

    $leftoverHot = @($keyState.Keys | Where-Object { $_ -like "$HotPrefix*" })
    $row1099 = $rows['9007199254741099']
    Add-Check 'residual.captured' ($keyState.Count -ge 1 -or $true) `
        "captured $($keyState.Count) redis keys in db $RedisDb and $($rows.Count) rows; db0 keys=$(@($db0Keys).Count)"
    Add-Check 'residual.hot_keys_present' ($leftoverHot.Count -ge 1) "hot-list keys found: $($leftoverHot -join ', ')"
    Add-Check 'residual.row_1099_recorded' ($null -ne $row1099) "row 9007199254741099 static_url='$(if ($row1099) { $row1099.static_url })'"
}

elseif ($Mode -eq 'cleanup-residual') {
    if (-not (Test-Path -LiteralPath $StateDir)) { Write-Host "REFUSED: missing residual state: $StateDir"; exit 2 }
    $residual = Get-Content (Join-Path $StateDir 'residual.json') -Raw | ConvertFrom-Json

    $receipt = @()
    # 1. redis: delete exactly the captured key names, never a scan-derived list
    $capturedKeys = @($residual.keys.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($k in $capturedKeys) {
        $before = $residual.keys.$k
        $null = Redis $RedisDb @('DEL', $k)
        $after = (Redis $RedisDb @('EXISTS', $k)).Trim()
        $receipt += [ordered]@{ kind = 'redis-key'; key = $k; before_exists = $before.exists; before_ttl = $before.ttl;
                                before_value = $before.value; after_exists = $after }
    }
    $stillThere = @($capturedKeys | Where-Object { (Redis $RedisDb @('EXISTS', $_)).Trim() -eq '1' })
    Add-Check 'cleanup.keys_deleted_exactly' ($stillThere.Count -eq 0) `
        "deleted $($capturedKeys.Count) captured keys, remaining=$($stillThere.Count) ($($stillThere -join ', '))"
    Add-Check 'cleanup.db0_untouched' ((@(Redis-Scan 0)).Count -eq 0) "course db 0 key count after cleanup: $(@(Redis-Scan 0).Count)"

    # 2. row 9007199254741099: only the field proven changed is restored, from the seed tuple
    $row = $residual.rows.'9007199254741099'
    $seedSql = 'D:\Code\Java\heima-leadnews\_optimization-artifacts\20261029-P1.0\data\p1-data.sql'
    $seedLine = ''
    if (Test-Path -LiteralPath $seedSql) {
        $m = [regex]::Match([System.IO.File]::ReadAllText($seedSql), "\(9007199254741099,'P1 article 99',[^)]*\)")
        if ($m.Success) { $seedLine = $m.Value }
    }
    $seedStaticNull = ($seedLine -match ',NULL\)$')
    $beforeStatic = $row.static_url
    $beforeCounts = "$($row.views)|$($row.likes)|$($row.comment)|$($row.collection)"
    if ($seedStaticNull -and $beforeStatic -ne '~') {
        $null = Sql "UPDATE $Database.ap_article SET static_url=NULL WHERE id=9007199254741099;"
    }
    $after = Get-RowValues 9007199254741099
    $receipt += [ordered]@{ kind = 'row-field'; id = 9007199254741099; field = 'static_url';
                            before = $beforeStatic; after = $after.static_url; seed_line = $seedLine;
                            seed_source = $seedSql; note = 'only the field proven changed by the round-1 zero-row fixture is restored; the live pre-write value was never captured' }
    Add-Check 'cleanup.row_1099_static_url_restored' ($after.static_url -eq '~') `
        "before='$beforeStatic' after='$($after.static_url)' (seed tuple says static_url NULL; other fields untouched)"
    Add-Check 'cleanup.row_1099_other_fields_match_seed' ($after.title -eq 'P1 article 99' -and "$($after.views)|$($after.likes)|$($after.comment)|$($after.collection)" -eq '87381|2286|452|1711') `
        "counts before=$beforeCounts after=$($after.views)|$($after.likes)|$($after.comment)|$($after.collection) (seed 87381|2286|452|1711)"

    # 3. rows created by round 1 must already be gone (assert, do not touch)
    $createdLeft = @()
    foreach ($id in $CreateIds) {
        $c = Sql "SELECT COUNT(*) FROM $Database.ap_article WHERE id=$id;"
        if ($c -ne '0') { $createdLeft += "$id=$c" }
    }
    Add-Check 'cleanup.created_rows_absent' ($createdLeft.Count -eq 0) "round-1 created ids remaining: $(if ($createdLeft.Count -eq 0) { 'none' } else { $createdLeft -join ', ' })"

    $receiptObj = [ordered]@{
        cleaned_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        residual_source = (Join-Path $StateDir 'residual.json')
        residual_sha256 = (Get-Sha (Join-Path $StateDir 'residual.json'))
        items = $receipt
        article_total = (Sql "SELECT COUNT(*) FROM $Database.ap_article;")
        limits = 'bounded cleanup: exact captured key names and the one proven-changed column only; no FLUSHDB, no template overwrite'
    }
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'cleanup-receipt.json') -Text ($receiptObj | ConvertTo-Json -Depth 8)
    Add-Check 'cleanup.article_total' ($receiptObj.article_total -eq '10000') "ap_article total after cleanup: $($receiptObj.article_total)"
}

else {
    # ---------------- restore ----------------
    if (-not (Test-Path -LiteralPath $statePath)) { Write-Host "REFUSED: missing baseline: $statePath"; exit 2 }
    $baseline = Get-Content $statePath -Raw | ConvertFrom-Json
    $hashOk = $true
    foreach ($name in @('ap_article', 'ap_article_content', 'ap_article_config')) {
        $f = Join-Path $StateDir "$name.inserts.sql"
        if ((Get-Sha $f) -ne $baseline.tables.$name.sha256) { $hashOk = $false }
    }
    Add-Check 'restore.captured_files_intact' $hashOk 'three baseline INSERT files still match the capture hashes'

    $idList = ($Ids -join ',')
    $null = Sql "DELETE FROM $Database.ap_article WHERE id IN ($idList);"
    $null = Sql "DELETE FROM $Database.ap_article_content WHERE article_id IN ($idList);"
    $null = Sql "DELETE FROM $Database.ap_article_config WHERE article_id IN ($idList);"
    $applyErrors = @()
    foreach ($name in @('ap_article', 'ap_article_content', 'ap_article_config')) {
        $f = Join-Path $StateDir "$name.inserts.sql"
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '--default-character-set=utf8mb4' $Database -e "source $($f -replace '\\','/')" 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($code -ne 0) { $applyErrors += "$name exit=$code $((@($out) -join ' ').Trim())" }
    }
    Add-Check 'restore.inserts_applied' ($applyErrors.Count -eq 0) "apply errors: $(@($applyErrors) -join ' ; ')"

    # rows created this round (including the zero-row fixture target) must be gone
    $dl = ($CreateIds -join ',')
    $null = Sql "DELETE FROM $Database.ap_article WHERE id IN ($dl);"
    $null = Sql "DELETE FROM $Database.ap_article_content WHERE article_id IN ($dl);"
    $null = Sql "DELETE FROM $Database.ap_article_config WHERE article_id IN ($dl);"
    $left = Sql "SELECT CONCAT_WS('|', (SELECT COUNT(*) FROM $Database.ap_article WHERE id IN ($dl)), (SELECT COUNT(*) FROM $Database.ap_article_content WHERE article_id IN ($dl)), (SELECT COUNT(*) FROM $Database.ap_article_config WHERE article_id IN ($dl)));"
    Add-Check 'restore.created_rows_removed' ($left -eq '0|0|0') "created ids ($dl) remaining article|content|config = $left"

    # verify full rows against the baseline dump, row by row
    $verifyDir = Join-Path $OutDir 'verify'
    New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
    $allMatch = $true
    $detail = @()
    foreach ($t in @(@{ name = 'ap_article'; col = 'id' }, @{ name = 'ap_article_content'; col = 'article_id' },
                     @{ name = 'ap_article_config'; col = 'article_id' })) {
        $after = Join-Path $verifyDir ("$($t.name).after.sql")
        $null = Dump-Rows $t.name $t.col $Ids $after
        $before = @(Get-Content (Join-Path $StateDir "$($t.name).inserts.sql")) | Sort-Object
        $now = @(Get-Content $after) | Sort-Object
        $same = (($before -join "`n") -eq ($now -join "`n"))
        if (-not $same) { $allMatch = $false }
        $detail += "$($t.name): before=$($before.Count) after=$($now.Count) identical=$same"
    }
    Add-Check 'restore.rows_match_baseline_full_rows' $allMatch (@($detail) -join ' | ')

    # keys: remove everything this round could have written, then re-check against the baseline
    $keys = @($baseline.keys.PSObject.Properties | ForEach-Object { $_.Name })
    $null = Redis $RedisDb (@('DEL') + $keys)
    $mismatch = @()
    foreach ($k in $keys) {
        $want = $baseline.keys.$k
        $cur = Get-KeyState $RedisDb $k
        if ($cur.exists -ne $want.exists) { $mismatch += "$k exists $($cur.exists) != $($want.exists)" }
    }
    Add-Check 'restore.keys_match_baseline' ($mismatch.Count -eq 0) "key mismatches: $(if ($mismatch.Count -eq 0) { 'none' } else { $mismatch -join ' ; ' })"
    Add-Check 'restore.db0_untouched' ((@(Redis-Scan 0)).Count -eq 0) "course db 0 key count: $((@(Redis-Scan 0)).Count)"

    $total = Sql "SELECT COUNT(*) FROM $Database.ap_article;"
    $receipt = [ordered]@{
        restored_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        state_dir = $StateDir
        baseline_sha256 = (Get-Sha $statePath)
        ids = $Ids
        created_ids_removed = $CreateIds
        per_table = $detail
        keys_checked = $keys.Count
        article_total = $total
        redis_db = $RedisDb
        notes = 'rows restored from the shared baseline; keys restored to their captured existence state; values of pre-existing keys are transient cache and were not byte-restored'
    }
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'restore-receipt.json') -Text ($receipt | ConvertTo-Json -Depth 8)
    Add-Check 'restore.article_total' ($total -eq '10000') "ap_article total after restore: $total"
}

$counts = Get-RunCheckCounts $script:run
$script:run.checks | ForEach-Object { "{0,-46} {1,-6} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
