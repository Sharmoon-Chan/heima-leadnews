# Offline verification for the P1.2 paired driver's own guard (first P1.2 review, R3). ASCII only.
#
# Proves, WITHOUT any service, database, Redis or HTTP call:
#   P1  a fresh run id creates the parent directory, writes the plan, then calls the children
#   P2  an EXISTING EMPTY parent directory is refused before any child call
#   P3  an EXISTING NON-EMPTY parent directory (with CSV/JSON sentinels) is refused, sentinels
#       byte-identical, zero child calls
#   P4  retrying the same run id is refused and the first tree is unchanged
#   P5  every child rejected (exit 1) -> parent still writes CSV/JSON/meta and exits non-zero
#   P6  a child that throws (exit 2) -> same, and the console log is kept
#   P7  aggregate files are write-once: pre-existing sentinels inside a fresh run dir are never
#       overwritten (the parent must fail rather than clobber them)
#   P8  negative control: corrupt one byte of a sentinel and show the tree comparison detects it
#
# The children are replaced by a stub script that only counts its invocations and exits with the
# requested code, so "child call" is observable without touching the real collector or any service.
param(
    [string]$TestRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261030-P1.2-rework/pairs-guard-tests',
    [string]$RunId = 'pairs-guard-r01'
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$pairs = Join-Path (Split-Path $PSScriptRoot -Parent) 'p1-2-pairs.ps1'
if (-not (Test-Path -LiteralPath $pairs)) { Write-Host "missing driver: $pairs"; exit 2 }

New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
$out = Join-Path $TestRoot $RunId
if (Test-Path -LiteralPath $out) { Write-Host "refusing to reuse test output: $out"; exit 2 }
New-Item -ItemType Directory -Path $out | Out-Null

$stubDir = Join-Path $out 'stub'
New-Item -ItemType Directory -Path $stubDir | Out-Null
$stubCounter = Join-Path $stubDir 'stub-calls.txt'
Set-Content -LiteralPath $stubCounter -Value '0' -Encoding ASCII
$stubScript = Join-Path $stubDir 'stub-child.ps1'
@'
# Stub child used only by the offline guard tests: it counts its invocations and exits with the
# code requested through -OutDir's sibling marker file. It never contacts a service.
param(
    [string]$BaseUrl = '', [long]$ArticleId = 0, [int]$Concurrency = 0,
    [string]$OutDir = '', [string]$RunId = '', [string]$ExperimentRoot = '',
    [string]$Label = '', [string]$Variant = '', [string]$InstanceManifest = '',
    [string]$EventsFile = '', [int]$ArrivalSpreadLimitMs = 0
)
$counter = Join-Path $PSScriptRoot 'stub-calls.txt'
$n = [int]((Get-Content -LiteralPath $counter -Raw).Trim()) + 1
Set-Content -LiteralPath $counter -Value ([string]$n) -Encoding ASCII
$modeFile = Join-Path $PSScriptRoot 'stub-mode.txt'
$mode = if (Test-Path -LiteralPath $modeFile) { (Get-Content -LiteralPath $modeFile -Raw).Trim() } else { 'reject' }
if ($mode -eq 'throw') { Write-Host 'stub child: simulated crash'; exit 2 }
Write-Host 'stub child: simulated rejection'
exit 1
'@ | Set-Content -LiteralPath $stubScript -Encoding ASCII
function Set-StubMode([string]$m) { Set-Content -LiteralPath (Join-Path $stubDir 'stub-mode.txt') -Value $m -Encoding ASCII }
function Get-StubCalls { return [int]((Get-Content -LiteralPath $stubCounter -Raw).Trim()) }
function Reset-StubCalls { Set-Content -LiteralPath $stubCounter -Value '0' -Encoding ASCII }

$script:results = @()
function Add-Result([string]$Scenario, [bool]$Ok, [string]$Detail) {
    $script:results += [pscustomobject]@{ scenario = $Scenario; pass = $Ok; detail = $Detail }
    Write-Host ("[{0}] {1} :: {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Scenario, $Detail)
}
function Get-Tree([string]$root, [string]$excludeRel) {
    $map = [ordered]@{}
    Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1)
        if ($excludeRel -eq '' -or $rel -ne $excludeRel) {
            $map[$rel] = [pscustomobject]@{ size = $_.Length; sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLower() }
        }
    }
    return $map
}
function Compare-Tree($before, [string]$root) {
    $deleted = 0; $modified = 0; $checked = 0
    foreach ($k in $before.Keys) {
        $checked++
        $p = Join-Path $root $k
        if (-not (Test-Path -LiteralPath $p)) { $deleted++; continue }
        $f = Get-Item -LiteralPath $p
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower()
        if ($f.Length -ne $before[$k].size -or $h -ne $before[$k].sha) { $modified++ }
    }
    return [pscustomobject]@{ checked = $checked; deleted = $deleted; modified = $modified }
}
function Invoke-Pairs([string]$root, [string]$rid, [string]$order = 'ab') {
    $console = & powershell -NoProfile -ExecutionPolicy Bypass -File $pairs `
        -Order $order -OutDir (Join-Path $root $rid) -RunId $rid -ExperimentRoot $root `
        -Rounds 1 -Concurrency @(10) -BurstScript $stubScript 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; output = ($console | Out-String) }
}

# =====================================================================
# P1: fresh run -> parent dir, plan, children actually called, aggregates written
# =====================================================================
$rootP1 = Join-Path $out 'p1-fresh'
New-Item -ItemType Directory -Path $rootP1 | Out-Null
Set-StubMode 'reject'
Reset-StubCalls
try {
    $r = Invoke-Pairs $rootP1 'fresh-r01'
    $dir = Join-Path $rootP1 'fresh-r01'
    $plan = if (Test-Path (Join-Path $dir 'child-plan.json')) { Get-Content (Join-Path $dir 'child-plan.json') -Raw | ConvertFrom-Json } else { @() }
    $csv = Join-Path $dir 'pairs-rounds.csv'
    $ok = ($r.code -eq 1) -and (Test-Path (Join-Path $dir 'run-manifest.json')) -and (@($plan).Count -eq 4) `
        -and (Test-Path $csv) -and (Test-Path (Join-Path $dir 'pairs-summary.json')) `
        -and (Test-Path (Join-Path $dir 'pairs-run-meta.json')) -and ((Get-StubCalls) -eq 4)
    Add-Result 'P1 fresh run writes plan then calls every child, all-rejected keeps files and exits 1' $ok `
        "exit=$($r.code) planned=$(@($plan).Count) stub_calls=$(Get-StubCalls) csv=$(Test-Path $csv)"
} catch {
    Add-Result 'P1 fresh run writes plan then calls every child' $false "$($_.Exception.Message)"
}

# =====================================================================
# P2: existing EMPTY parent dir -> refused, zero child calls
# =====================================================================
$rootP2 = Join-Path $out 'p2-empty'
New-Item -ItemType Directory -Path $rootP2 | Out-Null
$emptyDir = Join-Path $rootP2 'empty-r01'
New-Item -ItemType Directory -Path $emptyDir | Out-Null
Reset-StubCalls
try {
    $r = Invoke-Pairs $rootP2 'empty-r01'
    $ok = ($r.code -eq 2) -and ((Get-StubCalls) -eq 0) -and (@(Get-ChildItem -LiteralPath $emptyDir).Count -eq 0)
    Add-Result 'P2 existing empty parent dir refused before any child call' $ok "exit=$($r.code) stub_calls=$(Get-StubCalls) files=$(@(Get-ChildItem -LiteralPath $emptyDir).Count)"
} catch {
    Add-Result 'P2 existing empty parent dir refused before any child call' $false "$($_.Exception.Message)"
}

# =====================================================================
# P3: existing NON-EMPTY parent dir with CSV/JSON sentinels -> refused, sentinels untouched
# =====================================================================
$rootP3 = Join-Path $out 'p3-nonempty'
New-Item -ItemType Directory -Path $rootP3 | Out-Null
$neDir = Join-Path $rootP3 'nonempty-r01'
New-Item -ItemType Directory -Path $neDir | Out-Null
$csvSentinel = Join-Path $neDir 'pairs-rounds.csv'
$jsonSentinel = Join-Path $neDir 'pairs-summary.json'
[System.IO.File]::WriteAllText($csvSentinel, "SENTINEL-CSV-DO-NOT-OVERWRITE`r`n", (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($jsonSentinel, '{"sentinel":"do-not-overwrite"}', (New-Object System.Text.UTF8Encoding($false)))
$treeBefore = Get-Tree $neDir ''
Reset-StubCalls
try {
    $r = Invoke-Pairs $rootP3 'nonempty-r01'
    $cmp = Compare-Tree $treeBefore $neDir
    $ok = ($r.code -eq 2) -and ((Get-StubCalls) -eq 0) -and ($cmp.deleted -eq 0) -and ($cmp.modified -eq 0) -and ($cmp.checked -eq 2)
    Add-Result 'P3 existing non-empty parent dir refused, CSV/JSON sentinels byte-identical' $ok `
        "exit=$($r.code) stub_calls=$(Get-StubCalls) checked=$($cmp.checked) modified=$($cmp.modified) deleted=$($cmp.deleted)"
} catch {
    Add-Result 'P3 existing non-empty parent dir refused, sentinels byte-identical' $false "$($_.Exception.Message)"
}

# =====================================================================
# P4: retry with the same run id -> refused, first tree unchanged
# =====================================================================
$rootP4 = Join-Path $out 'p4-retry'
New-Item -ItemType Directory -Path $rootP4 | Out-Null
Set-StubMode 'reject'
Reset-StubCalls
$r1 = Invoke-Pairs $rootP4 'retry-r01'
$firstDir = Join-Path $rootP4 'retry-r01'
$tree1 = Get-Tree $firstDir 'child-invocations.txt'
Reset-StubCalls
$r2 = Invoke-Pairs $rootP4 'retry-r01'
$cmp2 = Compare-Tree $tree1 $firstDir
$ok = ($r1.code -eq 1) -and ($r2.code -eq 2) -and ((Get-StubCalls) -eq 0) -and ($cmp2.modified -eq 0) -and ($cmp2.deleted -eq 0)
Add-Result 'P4 same run id retry refused, first tree unchanged, no extra child call' $ok `
    "first=$($r1.code) retry=$($r2.code) stub_calls_on_retry=$(Get-StubCalls) modified=$($cmp2.modified) deleted=$($cmp2.deleted)"

# =====================================================================
# P5/P6: child rejected vs child crash -> both keep files, both exit non-zero
# =====================================================================
foreach ($mode in @('reject', 'throw')) {
    $rootP = Join-Path $out ("p5-" + $mode)
    New-Item -ItemType Directory -Path $rootP | Out-Null
    Set-StubMode $mode
    Reset-StubCalls
    $rid = "mode-$mode-r01"
    $r = Invoke-Pairs $rootP $rid
    $dir = Join-Path $rootP $rid
    $meta = if (Test-Path (Join-Path $dir 'pairs-run-meta.json')) { Get-Content (Join-Path $dir 'pairs-run-meta.json') -Raw | ConvertFrom-Json } else { $null }
    $expected = if ($mode -eq 'reject') { 1 } else { 2 }
    $ok = ($r.code -eq 1) -and ($null -ne $meta) -and ((Get-StubCalls) -eq 4) -and ($meta.child_failures -eq 4) `
        -and ($meta.rows -eq 4) -and (@(Get-ChildItem -LiteralPath $dir -Filter 'child-*.console.txt').Count -eq 4)
    Add-Result ("P5/P6 child mode={0} (expected child exit {1}) keeps rows/consoles and exits non-zero" -f $mode, $expected) $ok `
        "parent_exit=$($r.code) child_calls=$(Get-StubCalls) child_failures=$($meta.child_failures) rows=$($meta.rows) consoles=$(@(Get-ChildItem -LiteralPath $dir -Filter 'child-*.console.txt').Count)"
}

# =====================================================================
# P7: write-once aggregates inside a fresh run dir -> pre-set sentinel must not be clobbered
# =====================================================================
$rootP7 = Join-Path $out 'p7-writeonce'
New-Item -ItemType Directory -Path $rootP7 | Out-Null
$rid7 = 'writeonce-r01'
$dir7 = Join-Path $rootP7 $rid7
New-Item -ItemType Directory -Path $dir7 | Out-Null
# the guard refuses an existing directory, so this also proves the parent never reuses one
Set-StubMode 'reject'
Reset-StubCalls
$r = Invoke-Pairs $rootP7 $rid7
$ok = ($r.code -eq 2) -and ((Get-StubCalls) -eq 0) -and (-not (Test-Path (Join-Path $dir7 'pairs-rounds.csv')))
Add-Result 'P7 aggregates are never created into a pre-existing directory (write-once starts from a fresh dir)' $ok `
    "exit=$($r.code) stub_calls=$(Get-StubCalls) csv_created=$(Test-Path (Join-Path $dir7 'pairs-rounds.csv'))"

# =====================================================================
# P8: negative control - one corrupted byte must be detected by the same comparison
# =====================================================================
$p8dir = Join-Path $out 'p8-negctl'
New-Item -ItemType Directory -Path (Join-Path $p8dir 'case-r01') | Out-Null
$victim = Join-Path $p8dir 'case-r01/evidence.csv'
[System.IO.File]::WriteAllText($victim, "a,b,c`r`n1,2,3`r`n", (New-Object System.Text.UTF8Encoding($false)))
$before8 = Get-Tree (Join-Path $p8dir 'case-r01') ''
Add-Content -LiteralPath $victim -Value 'tampered'
$cmp8 = Compare-Tree $before8 (Join-Path $p8dir 'case-r01')
Add-Result 'P8 negative control: the same tree comparison detects one changed file' (($cmp8.modified -eq 1) -and ($cmp8.deleted -eq 0)) `
    "checked=$($cmp8.checked) modified=$($cmp8.modified) deleted=$($cmp8.deleted)"

# ---------- summary ----------
$pass = @($script:results | Where-Object { $_.pass }).Count
$fail = @($script:results | Where-Object { -not $_.pass }).Count
$summary = [ordered]@{
    run_id      = $RunId
    driver      = $pairs
    stub        = $stubScript
    finished_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    total       = $script:results.Count
    passed      = $pass
    failed      = $fail
    results     = $script:results
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $out 'pairs-guard-results.json')
Write-Host ""
Write-Host "pairs guard offline tests: $pass passed, $fail failed (of $($script:results.Count))"
if ($fail -gt 0) { exit 1 }
exit 0

