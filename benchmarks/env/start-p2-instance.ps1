param(
    [Parameter(Mandatory = $true)][ValidateSet('article', 'search')][string]$Service,
    [Parameter(Mandatory = $true)][string]$RunDirectory,
    [string]$EnvironmentRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261108-P2.2-MQ-DUP-r01',
    [string]$RepoRoot = 'D:/Code/Java/heima-leadnews/heima-leadnews',
    [switch]$UseLocalConfig
)
$ErrorActionPreference = 'Stop'
$RunDirectory = [System.IO.Path]::GetFullPath($RunDirectory)
if (Test-Path -LiteralPath $RunDirectory) { throw "REFUSED: run directory already exists: $RunDirectory" }
$port = if ($Service -eq 'article') { 51802 } else { 51804 }
if (@(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue).Count) {
    throw "REFUSED: port $port already has a listener"
}
$lib = if ($Service -eq 'article') {
    'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261028-P0-RUN/lib'
} else {
    'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261029-P0.1/lib-search'
}
$app = if ($Service -eq 'article') { 'com.heima.article.ArticleApplication' } else { 'com.heima.search.SearchApplication' }
$configName = if ($Service -eq 'article') { 'article-p1.yml' } else { 'search.yml' }
$config = Join-Path $EnvironmentRoot "local-config/$configName"
$java = 'D:/Soft/Java/jdk-1.8/bin/javaw.exe'
$classes = @(
    (Join-Path $RepoRoot "heima-leadnews-service/heima-leadnews-$Service/target/classes"),
    (Join-Path $RepoRoot 'heima-leadnews-common/target/classes'),
    (Join-Path $RepoRoot 'heima-leadnews-model/target/classes')
)
foreach ($p in @($classes) + @($lib, $java, $config)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "REFUSED: missing $p" }
}
if (@(Get-ChildItem -LiteralPath $lib -Filter 'logback*.jar').Count) { throw 'REFUSED: conflicting logging jars' }
$classpath = (@($classes) + @("$lib/*")) -join ';'
$classpath = $classpath.Replace('/', '\')
$javaArgs = @('-Dfile.encoding=UTF-8', '-Xms128m', '-Xmx384m', '-cp', ('"' + $classpath + '"'), $app)
if ($Service -eq 'article') { $javaArgs += '--spring.profiles.active=p1' }
if ($UseLocalConfig) {
    $javaArgs += ('"--spring.config.additional-location=file:' + $config + '"')
    $javaArgs += '--spring.cloud.nacos.config.enabled=false'
} else {
    $javaArgs += '--spring.cloud.nacos.config.enabled=true'
}
# Test instances must not register their test database with the course application.
$javaArgs += '--spring.cloud.nacos.discovery.enabled=false'
New-Item -ItemType Directory -Path $RunDirectory | Out-Null
$stdout = Join-Path $RunDirectory 'service.out.log'
$stderr = Join-Path $RunDirectory 'service.err.log'
$started = Get-Date
$process = Start-Process -FilePath $java -ArgumentList $javaArgs -WorkingDirectory $RepoRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$ready = $false
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline) {
    $process.Refresh()
    if ($process.HasExited) { break }
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
    if (@($listeners | Where-Object { $_.OwningProcess -eq $process.Id }).Count) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
}
$meta = [ordered]@{
    service = $Service
    process_id = $process.Id
    started_local = $started.ToString('o')
    ready = $ready
    port = $port
    config_mode = if ($UseLocalConfig) { 'generated local config' } else { 'Nacos base plus p1 for article' }
    environment_root = $EnvironmentRoot
    local_config = $config
    local_config_sha256 = (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash.ToLowerInvariant()
    expected_redis_database = if ($Service -eq 'article') { 5 } else { $null }
    expected_xxl_port = if ($Service -eq 'article') { 19998 } else { $null }
    note = 'Expected settings were verified by environment repair; check actual connections if remote configuration changes.'
}
$meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunDirectory 'instance.json') -Encoding UTF8
Write-Output ("service={0} pid={1} ready={2} port={3} run={4}" -f $Service, $process.Id, $ready, $port, $RunDirectory)
if (-not $ready) { exit 1 }
