# Capture the SINGLE shared baseline for the P1.3c-4 window sampling (ASCII only).
#
# One protected capture, written once: the three article ids used by every candidate get their three tables
# dumped and their four behaviour fields recorded, and the file carries a scope plus its own SHA256. Every
# later session verifies that file, hash, scope and target ids BEFORE it issues any HTTP/SQL/Redis call.
#
# Exit codes: 0 = baseline written, 2 = refused (missing input / existing baseline), 1 = capture failed.
param(
    [Parameter(Mandatory = $true)][string]$RunRoot,
    # comma-separated on the command line so that "-File" invocation cannot mis-bind extra ids to later params
    [Parameter(Mandatory = $true)][string]$TargetIdsCsv,
    [long[]]$TargetIds = @(),
    [string]$Scope = 'P1.3c-4-window-shared',
    [string]$Database = 'leadnews_article_p1',
    [string]$MysqlExe = 'D:\Soft\mysql-8.0.34-winx64\bin\mysql.exe',
    [string]$MysqlDump = 'D:\Soft\mysql-8.0.34-winx64\bin\mysqldump.exe',
    [string]$MysqlUser = 'root',
    [string]$MysqlPassword = '1234'
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$env:MYSQL_PWD = $MysqlPassword

$baseDir = Join-Path $RunRoot 'baselines'
$baseFile = Join-Path $baseDir 'p13c4-window-baseline.json'
if (Test-Path -LiteralPath $baseFile) {
    Write-Host "REFUSED: baseline already exists (write-once): $baseFile"
    exit 2
}
if (-not (Test-Path -LiteralPath $RunRoot)) { Write-Host "REFUSED: missing run root: $RunRoot"; exit 2 }
New-Item -ItemType Directory -Path $baseDir -Force | Out-Null

$tables = @('ap_article', 'ap_article_content', 'ap_article_config')
if ($TargetIds.Count -eq 0) {
    if ($TargetIdsCsv -notmatch '^\d+(,\d+)*$') { Write-Host "REFUSED: bad -TargetIdsCsv '$TargetIdsCsv'"; exit 2 }
    $TargetIds = @($TargetIdsCsv -split ',' | ForEach-Object { [long]$_ })
}
$idList = ($TargetIds | ForEach-Object { "$_" }) -join ','
$targets = New-Object System.Collections.ArrayList

foreach ($id in $TargetIds) {
    $shas = @()
    foreach ($t in $tables) {
        $f = Join-Path $baseDir ("capture-$id-$t.sql")
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $MysqlDump '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '--no-create-info' '--skip-extended-insert' `
            '--complete-insert' '--where' "id=$id" $Database $t 1> $f 2> ($f + '.err')
        $code = $LASTEXITCODE
        $ErrorActionPreference = $saved
        if ($code -ne 0) { Write-Host "CAPTURE FAILED: mysqldump $t id=$id exit=$code"; exit 1 }
        $shas += (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
    }
    $fields = (((& $MysqlExe '-h' '127.0.0.1' '-P' '3306' '-u' $MysqlUser '-N' '-B' '--raw' '-e' `
                "SELECT CONCAT_WS('|', views, likes, comment, collection) FROM $Database.ap_article WHERE id=$id;") 2>&1) | Out-String).Trim()
    if ($fields -notmatch '^\d+\|\d+\|\d+\|\d+$') { Write-Host "CAPTURE FAILED: id=$id fields='$fields'"; exit 1 }
    $null = $targets.Add([pscustomobject]@{ article_id = [long]$id; fields = $fields; tables_sha256 = ($shas -join ',') })
}

$baseline = [ordered]@{
    scope = $Scope
    captured_local = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    run_root = $RunRoot
    database = $Database
    tables = $tables
    targets = $targets
    note = 'single protected capture shared by every candidate session; the sessions verify this file, its sha256, its scope and these ids before any external call'
}
[System.IO.File]::WriteAllText($baseFile, ($baseline | ConvertTo-Json -Depth 6), $utf8)
$sha = (Get-FileHash -LiteralPath $baseFile -Algorithm SHA256).Hash.ToLower()
Write-Host "baseline=$baseFile sha256=$sha targets=$($TargetIds.Count) scope=$Scope"
exit 0
