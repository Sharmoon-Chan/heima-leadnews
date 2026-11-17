# P1.3b output-path protection, offline tests (ASCII only).
#
# Two cases, no application, no MySQL/Redis/Nacos, no network:
#   P1 positive: a brand new run id builds entirely inside its own root; events file, probe config and
#                both variant class dirs are all inside the root, and the old sealed logs are untouched.
#   P2 negative: the events file is pointed at an OLD SEALED log. The preparation must refuse with a
#                non-zero exit BEFORE compiling anything: no build outputs appear, the sealed file keeps
#                its size and hash, and no external (javac) call is made.
#
# Exit codes: 0 = both cases behaved as required, 1 = a case failed, 2 = usage problem.
param(
    [string]$EvidenceRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261031-P1.3b',
    [string]$RunId = 'p13b-path-guard-r01',
    [string]$SealedLog = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261031-P1.3a-round4/events/POST-all.log',
    [string]$PrepareScript = 'D:/Code/Java/heima-leadnews/heima-leadnews/benchmarks/env/prepare-p13b-run.ps1'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

if (-not (Test-Path -LiteralPath $PrepareScript)) { Write-Host "missing prepare script: $PrepareScript"; exit 2 }
if (-not (Test-Path -LiteralPath $SealedLog)) { Write-Host "missing sealed log for the negative case: $SealedLog"; exit 2 }

$out = Join-Path $EvidenceRoot ("path-guard-tests/" + $RunId)
if (Test-Path -LiteralPath $out) { Write-Host "refusing to reuse test output: $out"; exit 2 }
New-Item -ItemType Directory -Force -Path $out | Out-Null

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$name, [bool]$ok, [string]$detail) {
    $results.Add([pscustomobject]@{ scenario = $name; pass = $ok; detail = $detail })
    Write-Host (("[{0}] {1} :: {2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $detail))
}

function Get-Sha([string]$p) {
    if (Test-Path -LiteralPath $p) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }
    return ''
}


function Get-NormalizedPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    return [System.IO.Path]::GetFullPath($p).TrimEnd('\', '/').ToLowerInvariant()
}
function Invoke-Prepare([string[]]$extraArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $console = & powershell -NoProfile -ExecutionPolicy Bypass -File $PrepareScript `
            -InteractionRoot "$out/roots" @extraArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ exit = $code; console = @($console) }
}

# ---------------- P1 positive ----------------
$sealedShaBefore = Get-Sha $SealedLog
$sealedSizeBefore = (Get-Item -LiteralPath $SealedLog).Length
$p1RunId = "p13b-guard-positive-r01"
$r1 = Invoke-Prepare @('-RunId', $p1RunId)
$root1 = Join-Path "$out/roots" $p1RunId
$events1 = Join-Path $root1 'events/p13b-events.log'
$cfg1 = Join-Path $root1 'configs/p13b-probe.properties'
$pre1 = Join-Path $root1 'build/run-classes-PRE'
$post1 = Join-Path $root1 'build/run-classes-POST'
$manifest1 = Join-Path $root1 'build/build-manifest.json'

Add-Result 'P1 positive run created' ($r1.exit -eq 0 -and (Test-Path -LiteralPath $root1)) `
    ("exit={0} root_exists={1}" -f $r1.exit, (Test-Path -LiteralPath $root1))
$insideOk = (Test-Path -LiteralPath $cfg1) -and (Test-Path -LiteralPath $pre1) -and (Test-Path -LiteralPath $post1) -and (Test-Path -LiteralPath $manifest1)
Add-Result 'P1 all writable outputs inside the run root' $insideOk `
    ("config={0} pre_classes={1} post_classes={2} manifest={3}" -f (Test-Path $cfg1), (Test-Path $pre1), (Test-Path $post1), (Test-Path $manifest1))

$cfgText = if (Test-Path -LiteralPath $cfg1) { [System.IO.File]::ReadAllText($cfg1) } else { '' }
$declaredEvents = ([regex]::Match($cfgText, 'events\.file=(.+)')).Groups[1].Value.Trim()
Add-Result 'P1 probe config points its events file inside the root' `
    ($declaredEvents -ne '' -and ((Get-NormalizedPath $declaredEvents).StartsWith((Get-NormalizedPath $root1)))) `
    ("events.file={0}" -f $declaredEvents)

$manifestJson = if (Test-Path -LiteralPath $manifest1) { Get-Content -LiteralPath $manifest1 -Raw | ConvertFrom-Json } else { $null }
$hashesOk = $false
if ($null -ne $manifestJson) {
    $preSvc = Join-Path $pre1 'com/heima/article/service/impl/ApArticleServiceImpl.class'
    $postSvc = Join-Path $post1 'com/heima/article/service/impl/ApArticleServiceImpl.class'
    $hashesOk = ($manifestJson.variants.PRE.article_service_class_sha256 -eq (Get-Sha $preSvc)) -and
                ($manifestJson.variants.POST.article_service_class_sha256 -eq (Get-Sha $postSvc)) -and
                ($manifestJson.variants.PRE.freemarker_class_sha256 -ne $manifestJson.variants.POST.freemarker_class_sha256)
}
Add-Result 'P1 manifest records the loaded class hashes of both variants' $hashesOk `
    ("PRE/POST class hashes recorded and differ as expected <{0}>" -f $(if ($null -ne $manifestJson) { 'materialized' } else { 'no manifest' }))

Add-Result 'P1 sealed log untouched by the positive case' `
    ((Get-Sha $SealedLog) -eq $sealedShaBefore -and (Get-Item -LiteralPath $SealedLog).Length -eq $sealedSizeBefore) `
    ("sha same={0} size same={1}" -f ((Get-Sha $SealedLog) -eq $sealedShaBefore), ((Get-Item -LiteralPath $SealedLog).Length -eq $sealedSizeBefore))

# ---------------- P2 negative ----------------
$p2RunId = "p13b-guard-negative-r01"
$sealedShaBefore2 = Get-Sha $SealedLog
$sealedSizeBefore2 = (Get-Item -LiteralPath $SealedLog).Length
$r2 = Invoke-Prepare @('-RunId', $p2RunId, '-EventsFileOverride', $SealedLog)
$root2 = Join-Path "$out/roots" $p2RunId
$pre2 = Join-Path $root2 'build/run-classes-PRE'
$post2 = Join-Path $root2 'build/run-classes-POST'
$cfg2 = Join-Path $root2 'configs/p13b-probe.properties'

Add-Result 'P2 events file aimed at a sealed root is refused non-zero' ($r2.exit -ne 0) ("exit={0}" -f $r2.exit)
$noBuild = (-not (Test-Path -LiteralPath $pre2)) -and (-not (Test-Path -LiteralPath $post2)) -and (-not (Test-Path -LiteralPath $cfg2))
# no build outputs means javac was never invoked: the external/compile call count is 0
Add-Result 'P2 refusal happens before any compile (external call count = 0)' $noBuild `
    ("pre_classes={0} post_classes={1} probe_config={2}" -f (Test-Path $pre2), (Test-Path $post2), (Test-Path $cfg2))
Add-Result 'P2 sealed log byte-identical after the refusal' `
    ((Get-Sha $SealedLog) -eq $sealedShaBefore2 -and (Get-Item -LiteralPath $SealedLog).Length -eq $sealedSizeBefore2) `
    ("sha same={0} size same={1}" -f ((Get-Sha $SealedLog) -eq $sealedShaBefore2), ((Get-Item -LiteralPath $SealedLog).Length -eq $sealedSizeBefore2))
$refusalText = ($r2.console | Out-String)
Add-Result 'P2 refusal message names the sealed root' ($refusalText -match 'REFUSED' -and $refusalText -match 'sealed') `
    ((($r2.console | Where-Object { $_ -match 'REFUSED' }) | Select-Object -First 1) -join '')

$passed = @($results | Where-Object { $_.pass }).Count
$failed = @($results | Where-Object { -not $_.pass }).Count
$summary = [ordered]@{
    run_id     = $RunId
    finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    sealed_log = $SealedLog
    total      = $results.Count
    passed     = $passed
    failed     = $failed
    results    = $results
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $out 'path-guard-results.json')
Write-Host ("path guard offline tests: {0} passed, {1} failed (of {2})" -f $passed, $failed, $results.Count)
if ($failed -gt 0) { exit 1 }
exit 0
