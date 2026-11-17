# Restore the hand-made seed rows used by the P1.3b scenarios.
#
# The scenarios under test write through the real service (static_url, behaviour counters, a real
# create with a fixed id). After the experiments the P1 seed rows must be byte-for-byte what the
# generator produced, otherwise the next stage inherits mutated fixtures.
#
# This script does not guess values: it extracts the original tuples for the requested ids from the
# generator output (p1-data.sql), rewrites those rows
#   DELETE + INSERT  for the three tables (ap_article, ap_article_content, ap_article_config)
# and then verifies the result field by field against the extracted tuples. Redis keys of the ids are
# removed with exact DEL, never FLUSHDB.
#
# ASCII only (PS 5.1 reads BOM-less .ps1 as ANSI/GBK).
# Exit codes: 0 = restored and verified, 1 = verification failed, 2 = usage/guard problem.
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [Parameter(Mandatory = $true)][string]$ExperimentRoot,
    [string]$SeedSql = 'D:\Code\Java\heima-leadnews\_optimization-artifacts\20261029-P1.0\data\p1-data.sql',
    [long[]]$Ids = @(9007199254741015, 9007199254741016, 9007199254741017, 9007199254741018,
                     9007199254741019, 9007199254741020, 9007199254741021, 9007199254741022),
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234',
    [string]$Database = 'leadnews_article_p1',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [string]$CacheKeyPrefix = 'article:detail:'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$env:MYSQL_PWD = $MysqlPassword

. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage 'P1.3b-restore' `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ ids = ($Ids -join ','); database = $Database; seed_sql = $SeedSql } `
        -Targets @($Ids | ForEach-Object { "$_" }) -DataSet $Database
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

function Add-Check([string]$n, [bool]$ok, [string]$d) {
    Add-RunCheck -State $script:run -Name $n -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $d
}
function Sql([string]$q) {
    $o = & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--default-character-set=utf8mb4' '-e' $q 2>&1
    return (($o | Out-String).Trim())
}
function Redis-Exact([string[]]$a) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', '0') + $a
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}

if (-not (Test-Path -LiteralPath $SeedSql)) { throw "seed sql not found: $SeedSql" }
$seedText = [System.IO.File]::ReadAllText($SeedSql)

$rows = @()
foreach ($id in $Ids) {
    $sid = [regex]::Escape("$id")
    $aPattern = "\($sid,'([^']*)',(\d+),'([^']*)',(\d+),'([^']*)',(\d+),(\d+),([^,]+),'([^']*)',(\d+),(\d+),(\d+),(\d+),(\d+),(\d+),(\d+),'([^']*)','([^']*)',(\d+),(\d+),(NULL|'[^']*')\)"
    $a = [regex]::Matches($seedText, $aPattern)
    $c = [regex]::Matches($seedText, "\($sid,$sid,'([^']*)'\)")
    $g = [regex]::Matches($seedText, "\($sid,$sid,(\d+),(\d+),(\d+),(\d+)\)")
    if ($a.Count -ne 1 -or $c.Count -ne 1 -or $g.Count -ne 1) {
        throw "seed tuples for id $id not unique/complete: article=$($a.Count) content=$($c.Count) config=$($g.Count)"
    }
    $am = $a[0]
    $staticUrlRaw = $am.Groups[21].Value
    $rows += [pscustomobject]@{
        id = $id
        article_tuple = $am.Value
        content_tuple = $c[0].Value
        config_tuple = $g[0].Value
        title = $am.Groups[1].Value
        likes = $am.Groups[10].Value
        collection = $am.Groups[11].Value
        comment = $am.Groups[12].Value
        views = $am.Groups[13].Value
        static_url = $(if ($staticUrlRaw -eq 'NULL') { '' } else { $staticUrlRaw.Trim("'") })
        content_length = $c[0].Groups[1].Value.Length
        is_comment = $g[0].Groups[1].Value
        is_forward = $g[0].Groups[2].Value
        is_down = $g[0].Groups[3].Value
        is_delete = $g[0].Groups[4].Value
    }
}
Add-Check 'r.seed_tuples_extracted' ($rows.Count -eq $Ids.Count) "extracted $($rows.Count)/$($Ids.Count) seed row triplets from '$SeedSql'"

$idList = ($Ids -join ',')
$sql = New-Object System.Text.StringBuilder
[void]$sql.AppendLine("SET NAMES utf8mb4;")
[void]$sql.AppendLine("DELETE FROM ``ap_article`` WHERE ``id`` IN ($idList);")
[void]$sql.AppendLine("DELETE FROM ``ap_article_content`` WHERE ``article_id`` IN ($idList);")
[void]$sql.AppendLine("DELETE FROM ``ap_article_config`` WHERE ``article_id`` IN ($idList);")
[void]$sql.AppendLine("INSERT INTO ``ap_article`` (``id``,``title``,``author_id``,``author_name``,``channel_id``,``channel_name``,``layout``,``flag``,``images``,``labels``,``likes``,``collection``,``comment``,``views``,``province_id``,``city_id``,``county_id``,``created_time``,``publish_time``,``sync_status``,``origin``,``static_url``) VALUES")
[void]$sql.AppendLine((@($rows | ForEach-Object { $_.article_tuple }) -join ',' ) + ';')
[void]$sql.AppendLine("INSERT INTO ``ap_article_content`` (``id``,``article_id``,``content``) VALUES")
[void]$sql.AppendLine((@($rows | ForEach-Object { $_.content_tuple }) -join ',') + ';')
[void]$sql.AppendLine("INSERT INTO ``ap_article_config`` (``id``,``article_id``,``is_comment``,``is_forward``,``is_down``,``is_delete``) VALUES")
[void]$sql.AppendLine((@($rows | ForEach-Object { $_.config_tuple }) -join ',') + ';')
$sqlText = $sql.ToString()
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'restore.sql') -Text $sqlText

$apply = $sqlText | & $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '--default-character-set=utf8mb4' $Database 2>&1
$applyCode = $LASTEXITCODE
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'apply.log') -Text ((@($apply) -join "`r`n"))
Add-Check 'r.sql_applied' ($applyCode -eq 0) "mysql exit=$applyCode output='$((@($apply) -join ' ').Trim())'"
$verify = @()
$allOk = $true
foreach ($row in $rows) {
    $q = "SELECT CONCAT_WS('|', a.title, a.likes, a.collection, a.comment, a.views, IFNULL(a.static_url,''), " +
         "(SELECT LENGTH(c.content) FROM $Database.ap_article_content c WHERE c.article_id=a.id), " +
         "(SELECT COUNT(*) FROM $Database.ap_article_content c WHERE c.article_id=a.id), " +
         "(SELECT COUNT(*) FROM $Database.ap_article_config g WHERE g.article_id=a.id), " +
         "(SELECT CONCAT_WS(',',g.is_comment,g.is_forward,g.is_down,g.is_delete) FROM $Database.ap_article_config g WHERE g.article_id=a.id), " +
         "(SELECT COUNT(*) FROM $Database.ap_article x WHERE x.id=a.id)) FROM $Database.ap_article a WHERE a.id=$($row.id);"
    $got = Sql $q
    $expected = (@($row.title, $row.likes, $row.collection, $row.comment, $row.views, $row.static_url,
                    "$($row.content_length)", '1', '1',
                    "$($row.is_comment),$($row.is_forward),$($row.is_down),$($row.is_delete)", '1') -join '|')
    $ok = ($got -ceq $expected)
    if (-not $ok) { $allOk = $false }
    $verify += [pscustomobject]@{ id = $row.id; ok = $ok; expected = $expected; got = $got }
    $null = Redis-Exact @('DEL', "$CacheKeyPrefix$($row.id)")
    $null = Redis-Exact @('DEL', "$CacheKeyPrefix$($row.id):lock")
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'verify.tsv') -Text (
    (@('id`tresult`ttitle|likes|collection|comment|views|static_url|content_len|content_rows|config_rows|config_flags|article_rows') +
     @($verify | ForEach-Object { "$($_.id)`t$(if ($_.ok) { 'match' } else { 'MISMATCH' })`t$($_.got)" })) -join "`r`n")
Add-Check 'r.rows_match_seed' $allOk "$(@($verify | Where-Object { $_.ok }).Count)/$($verify.Count) ids match the seed tuples field by field"

$total = Sql "SELECT CONCAT_WS('|', (SELECT COUNT(*) FROM $Database.ap_article), (SELECT COUNT(*) FROM $Database.ap_article_content), (SELECT COUNT(*) FROM $Database.ap_article_config));"
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'table-counts.txt') -Text "ap_article|ap_article_content|ap_article_config = $total"
$keys = @(Redis-Exact (@('EXISTS') + @($Ids | ForEach-Object { "$CacheKeyPrefix$_" })))
$leftKeys = ($keys -join '').Split(' ') | Where-Object { $_ -eq '1' }
Add-Check 'r.cache_keys_removed' ($leftKeys.Count -eq 0) "EXISTS flags for the restored ids: '$($keys -join ' ')'"

$receipt = [ordered]@{
    restored_ids = @($rows | ForEach-Object { $_.id })
    seed_sql = $SeedSql
    seed_sql_sha256 = (Get-FileHash -LiteralPath $SeedSql -Algorithm SHA256).Hash
    database = $Database
    sql_file = 'restore.sql'
    mysql_exit_code = $applyCode
    per_id = $verify
    table_counts = $total
    redis_exists_flags = ($keys -join ' ')
    finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'restore-receipt.json') -Text ($receipt | ConvertTo-Json -Depth 6)

$counts = Get-RunCheckCounts $script:run
$script:run.checks | ForEach-Object { "{0,-32} {1,-8} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
