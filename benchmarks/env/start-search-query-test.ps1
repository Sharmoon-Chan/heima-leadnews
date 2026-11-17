param([Parameter(Mandatory=$true)][string]$ConfigFile,[Parameter(Mandatory=$true)][string]$RunDirectory,[int]$Port=51844,[string]$ExtraClassPath='')
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $RunDirectory){throw 'Output directory exists'}
if(@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue).Count){throw 'Query test port occupied'}
$repo='D:/Code/Java/heima-leadnews/heima-leadnews'
$paths=@("$repo/heima-leadnews-service/heima-leadnews-search/target/classes","$repo/heima-leadnews-common/target/classes","$repo/heima-leadnews-model/target/classes",'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261029-P0.1/lib-search/*')
if($ExtraClassPath){$paths=@($ExtraClassPath)+$paths}
$cp=($paths -join ';').Replace('/','\')
New-Item -ItemType Directory -Path $RunDirectory|Out-Null
$a=@('-Xms64m','-Xmx256m','-Dfile.encoding=UTF-8','-Dspring.index.ignore=true','-cp',('"'+$cp+'"'),'com.heima.search.SearchApplication',("--spring.config.additional-location=file:"+$ConfigFile),'--spring.cloud.nacos.config.enabled=false','--spring.cloud.nacos.discovery.enabled=false','--leadnews.search.sync.auto-startup=false')
$p=Start-Process -FilePath 'D:/Soft/Java/jdk-1.8/bin/javaw.exe' -ArgumentList $a -WindowStyle Hidden -WorkingDirectory $repo -RedirectStandardOutput "$RunDirectory/service.out.log" -RedirectStandardError "$RunDirectory/service.err.log" -PassThru
$record=[ordered]@{pid=$p.Id;port=$Port;config=$ConfigFile;created=(Get-Date).ToString('o');ready=$false}
$record|ConvertTo-Json|Set-Content "$RunDirectory/process.json" -Encoding UTF8
$deadline=(Get-Date).AddSeconds(55)
while((Get-Date)-lt$deadline){$p.Refresh();if($p.HasExited){break};$own=@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue|Where-Object {$_.OwningProcess -eq $p.Id});if($own.Count){$record.ready=$true;break};Start-Sleep -Milliseconds 500}
$record|ConvertTo-Json|Set-Content "$RunDirectory/process.json" -Encoding UTF8
$record|ConvertTo-Json -Compress
if(-not$record.ready){exit 1}
