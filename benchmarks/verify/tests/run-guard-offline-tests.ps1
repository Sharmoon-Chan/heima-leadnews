# Offline verification for the run-directory guard (P1.1a, round 2). ASCII only.
#
# Proves, WITHOUT starting Java / MySQL / Redis / the VM and without calling any real endpoint:
#   S1..S9  the original nineteen checks (directory guard, failure retention, response rules, skip)
#   R1      the fixture itself is per-run isolated: every case lives under <TestRoot>/<run_id>/cases,
#           nothing is deleted before a run, and a second run proves the first run's tree is intact
#           (a tree snapshot is written per run; a later run compares against it)
#   R2      the mock call counter really increments (1 call -> 1, one of each kind -> 3), and a
#           deliberately wrong "external call BEFORE the guard" stub is detected by that counter
#   R3      requests.csv keeps its fixed eight-column header and round-trips through Import-Csv
#   R4      data.article.id must be a JSON string exactly equal to the request; a bare number fails
#           even when the same value appears as a string elsewhere; legal JSON whitespace passes
#
# Usage (two runs, the second verifying that the first was not touched):
#   run 1:                              -RunId <r1>
#   add an extra sentinel file inside run 1, then
#   run 2:  -RunId <r2> -VerifyPreviousRunDir <.../<r1>> -ExpectExtraFile cases\<case>\<file>
param(
    [string]$TestRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261029-P1.1a-round2',
    [string]$RunId = '20261029-P1.1a-guardtests-r11',
    [string]$VerifyPreviousRunDir = '',
    [string]$ExpectExtraFile = ''
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

. (Join-Path $PSScriptRoot '..\..\lib\RunDirGuard.ps1')

New-Item -ItemType Directory -Force -Path $TestRoot | Out-Null
$out = Join-Path $TestRoot $RunId
if (Test-Path -LiteralPath $out) { Write-Host "refusing to reuse test output: $out"; exit 2 }
New-Item -ItemType Directory -Path $out | Out-Null

# R1: all cases of THIS run live under this run's own cases root, and nothing is pre-cleaned
$casesRoot = Join-Path $out 'cases'
New-Item -ItemType Directory -Path $casesRoot | Out-Null

$script:results = @()
function Add-Result([string]$Scenario, [bool]$Ok, [string]$Detail) {
    $script:results += [pscustomobject]@{ scenario = $Scenario; pass = $Ok; detail = $Detail }
    $flag = if ($Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} :: {2}" -f $flag, $Scenario, $Detail)
}

# ---------- R2: a counter that really counts ----------
$script:counterFile = Join-Path $out 'external-call-counter.txt'
function Get-Counter {
    if (-not (Test-Path -LiteralPath $script:counterFile)) { return 0 }
    $t = (Get-Content -LiteralPath $script:counterFile -Raw).Trim()
    if ($t -eq '') { return 0 }
    return [int]$t
}
function Reset-Counter { Set-Content -LiteralPath $script:counterFile -Value '0' -Encoding ASCII }
function Add-Call([string]$kind) {
    $n = (Get-Counter) + 1
    Set-Content -LiteralPath $script:counterFile -Value ([string]$n) -Encoding ASCII
    return $n
}
function Mock-Http { return (Add-Call 'http') }
function Mock-RedisDel { return (Add-Call 'redis') }
function Mock-Sql { return (Add-Call 'sql') }

# The same control flow the real collectors use: guard first, external calls only afterwards.
function Invoke-AfterGuardFlow {
    param([string]$OutDir, [string]$RunId, [string]$Stage = 'offline-test')
    $state = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage $Stage -ExperimentRoot $casesRoot
    Mock-Http | Out-Null
    Mock-RedisDel | Out-Null
    Mock-Sql | Out-Null
    return $state
}

# Deliberately WRONG order: the external call happens before the guard. Used to prove the
# counter can actually alarm; it must never be copied into a real collector.
function Invoke-WrongOrderStub {
    param([string]$OutDir)
    Mock-Http | Out-Null
    $leaf = Split-Path $OutDir -Leaf
    $null = Start-RunDirectory -OutDir $OutDir -RunId $leaf -Stage 'wrong-order' -ExperimentRoot $casesRoot
}

function New-Sentinel([string]$dir, [string]$name, [string]$content) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $p = Join-Path $dir $name
    [System.IO.File]::WriteAllText($p, $content, (New-Object System.Text.UTF8Encoding($false)))
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash
}
function Get-TreeSnapshot([string]$root, [string]$excludeRel) {
    $map = [ordered]@{}
    Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length + 1)
        if ($rel -ne $excludeRel) {
            $map[$rel] = [pscustomobject]@{ size = $_.Length; sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLower() }
        }
    }
    return $map
}

# =====================================================================
# S1: fresh legal run id -> directory + manifest, secret redacted, exit 0
# =====================================================================
$s1dir = Join-Path $casesRoot 'case-01-fresh'
Reset-Counter
try {
    $s1 = Start-RunDirectory -OutDir $s1dir -RunId 'case-01-fresh' -Stage 'offline-test' -ExperimentRoot $casesRoot `
        -ScriptPath $PSCommandPath -Parameters @{ note = 'offline'; password = 'should-be-redacted' }
    Mock-Http | Out-Null
    Mock-RedisDel | Out-Null
    Mock-Sql | Out-Null
    $callsInFlow = Get-Counter
    Add-RunCheck -State $s1 -Name 's1.works' -Status 'pass' -Detail 'created'
    $code = Set-RunStatus -State $s1 -Status 'passed'
    $manifest = Get-Content (Join-Path $s1dir 'run-manifest.json') -Raw -Encoding UTF8
    $redacted = ($manifest -match 'redacted') -and ($manifest -notmatch 'should-be-redacted')
    $ok = (Test-Path (Join-Path $s1dir 'run-manifest.json')) -and (Test-Path (Join-Path $s1dir 'run-status.json')) -and ($code -eq 0) -and $redacted -and ($callsInFlow -eq 3)
    Add-Result 'S1 fresh run creates dir+manifest (secret redacted), exit 0, 3 calls counted in-flow' $ok "code=$code redacted=$redacted calls=$callsInFlow"
} catch {
    Add-Result 'S1 fresh run creates dir+manifest (secret redacted), exit 0, 3 calls counted in-flow' $false "$($_.Exception.Message)"
}

# =====================================================================
# S2: existing EMPTY directory is refused, zero external calls
# =====================================================================
$s2dir = Join-Path $casesRoot 'case-02-empty-existing'
New-Item -ItemType Directory -Path $s2dir | Out-Null
Reset-Counter
$before = @(Get-ChildItem -LiteralPath $s2dir).Count
try {
    $null = Invoke-AfterGuardFlow -OutDir $s2dir -RunId 'case-02-empty-existing'
    Add-Result 'S2 existing empty dir refused, 0 external calls' $false 'guard did NOT throw'
} catch {
    $after = @(Get-ChildItem -LiteralPath $s2dir).Count
    $ok = ($_.Exception.Message -match 'refusing to reuse') -and ((Get-Counter) -eq 0) -and ($before -eq $after)
    Add-Result 'S2 existing empty dir refused, 0 external calls' $ok "msg=$($_.Exception.Message) calls=$(Get-Counter) files=$before->$after"
}

# =====================================================================
# S3: existing NON-EMPTY directory with a sentinel is refused, sentinel hash unchanged
# =====================================================================
$s3dir = Join-Path $casesRoot 'case-03-nonempty-existing'
$h3before = New-Sentinel $s3dir 'evidence.body.json' 'ORIGINAL-EVIDENCE-MUST-NOT-CHANGE'
Reset-Counter
try {
    $null = Invoke-AfterGuardFlow -OutDir $s3dir -RunId 'case-03-nonempty-existing'
    Add-Result 'S3 existing non-empty dir refused, sentinel hash unchanged' $false 'guard did NOT throw'
} catch {
    $h3after = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $s3dir 'evidence.body.json')).Hash
    $ok = ($h3before -eq $h3after) -and ((Get-Counter) -eq 0)
    Add-Result 'S3 existing non-empty dir refused, sentinel hash unchanged' $ok "hash_same=$($h3before -eq $h3after) calls=$(Get-Counter)"
}

# =====================================================================
# S4: identity / path violations fail before creating anything.
# R1: the out-of-root case uses a sandbox that belongs to this run, not a global C:/Temp path.
# =====================================================================
$sandboxRoot = Join-Path $out 'sandbox\root'
$sandboxOutside = Join-Path $out 'sandbox\outside'
New-Item -ItemType Directory -Force -Path $sandboxRoot | Out-Null
New-Item -ItemType Directory -Force -Path $sandboxOutside | Out-Null
Reset-Counter
$cases = @(
    @{ name = 'S4a illegal run_id'; out = (Join-Path $casesRoot 'case-04a bad id!'); rid = 'case-04a bad id!'; root = $casesRoot },
    @{ name = 'S4b leaf != run_id'; out = (Join-Path $casesRoot 'case-04b-DIR'); rid = 'case-04b-OTHER'; root = $casesRoot },
    @{ name = 'S4c outside experiment root'; out = (Join-Path $sandboxOutside 'case-04c'); rid = 'case-04c'; root = $sandboxRoot }
)
foreach ($c in $cases) {
    try {
        $null = Start-RunDirectory -OutDir $c.out -RunId $c.rid -Stage 'offline-test' -ExperimentRoot $c.root
        Add-Result $c.name $false 'guard did NOT throw'
    } catch {
        $created = Test-Path -LiteralPath $c.out
        $ok = (-not $created) -and ((Get-Counter) -eq 0)
        Add-Result $c.name $ok "msg=$($_.Exception.Message) created=$created calls=$(Get-Counter)"
    }
}

# =====================================================================
# S5: exception mid-run keeps files, status failed, non-zero code
# =====================================================================
$s5dir = Join-Path $casesRoot 'case-05-midway-failure'
Reset-Counter
$s5code = 0
try {
    $s5 = Start-RunDirectory -OutDir $s5dir -RunId 'case-05-midway-failure' -Stage 'offline-test' -ExperimentRoot $casesRoot
    Write-RunFileText -State $s5 -Path (Join-Path $s5dir 'step-1.body.json') -Text '{"code":200}'
    Add-RunCheck -State $s5 -Name 's5.step1' -Status 'pass' -Detail 'first step ok'
    Mock-Http | Out-Null
    throw 'simulated mid-run failure (upstream 503)'
} catch {
    $s5code = Save-RunFailure -State $s5 -ErrorRecord $_ -ExtraOutput @('captured stdout line', 'captured stderr line')
}
$stepKept = Test-Path (Join-Path $s5dir 'step-1.body.json')
$errKept = Test-Path (Join-Path $s5dir 'run-error.json')
$errOut = Test-Path (Join-Path $s5dir 'run-error-output.txt')
$errJson = if ($errKept) { Get-Content (Join-Path $s5dir 'run-error.json') -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$ok5 = $stepKept -and $errKept -and $errOut -and ($s5code -eq 1) -and ($errJson.status -eq 'failed') -and ((Get-Counter) -eq 1)
Add-Result 'S5 mid-run failure keeps written files, failed status, exit 1' $ok5 "code=$s5code step=$stepKept error=$errKept out=$errOut status=$($errJson.status) calls=$(Get-Counter)"

# =====================================================================
# S6: retry same id refused & old evidence intact; new id works, old preserved
# =====================================================================
Reset-Counter
$h6before = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $s3dir 'evidence.body.json')).Hash
try {
    $null = Invoke-AfterGuardFlow -OutDir $s3dir -RunId 'case-03-nonempty-existing'
    Add-Result 'S6a retry with same id refused, old evidence intact' $false 'guard did NOT throw'
} catch {
    $h6after = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $s3dir 'evidence.body.json')).Hash
    $ok = ($h6before -eq $h6after) -and ((Get-Counter) -eq 0)
    Add-Result 'S6a retry with same id refused, old evidence intact' $ok "hash_same=$($h6before -eq $h6after) calls=$(Get-Counter)"
}

$s6dir = Join-Path $casesRoot 'case-03-nonempty-existing-r02'
try {
    $s6 = Start-RunDirectory -OutDir $s6dir -RunId 'case-03-nonempty-existing-r02' -Stage 'offline-test' -ExperimentRoot $casesRoot
    Add-RunCheck -State $s6 -Name 's6b.works' -Status 'pass' -Detail 'new attempt runs'
    $code6 = Set-RunStatus -State $s6 -Status 'passed'
    $oldStillThere = Test-Path (Join-Path $s3dir 'evidence.body.json')
    Add-Result 'S6b retry with new id creates its own dir, old dir preserved' (($code6 -eq 0) -and $oldStillThere) "code=$code6 old_preserved=$oldStillThere"
} catch {
    Add-Result 'S6b retry with new id creates its own dir, old dir preserved' $false "$($_.Exception.Message)"
}

# =====================================================================
# S7: response evaluation - HTTP 200 alone is not success
# =====================================================================
$goodExisting = '{"host":null,"code":200,"errorMessage":"ok","data":{"article":{"id":"9007199254741007","title":"P1 article"},"content":"x"}}'
$goodMissing = '{"host":null,"code":1002,"errorMessage":"missing","data":null}'
$biz503 = '{"host":null,"code":503,"errorMessage":"server error","data":null}'
$badJson = '{not json'
$idMismatch = '{"host":null,"code":200,"errorMessage":"ok","data":{"article":{"id":"9007199254741008","title":"P1 article"},"content":"x"}}'

$s7 = @(
    @{ name = 'S7a existing ok'; args = @{ HttpStatus = '200'; BodyText = $goodExisting; ExpectId = '9007199254741007'; ExpectKind = 'existing' }; want = 'pass' },
    @{ name = 'S7b missing ok'; args = @{ HttpStatus = '200'; BodyText = $goodMissing; ExpectId = '9007199254741007'; ExpectKind = 'missing' }; want = 'pass' },
    @{ name = 'S7c http 500'; args = @{ HttpStatus = '500'; BodyText = $goodExisting; ExpectId = '9007199254741007'; ExpectKind = 'existing' }; want = 'fail' },
    @{ name = 'S7d business 503 with http 200'; args = @{ HttpStatus = '200'; BodyText = $biz503; ExpectId = '9007199254741007'; ExpectKind = 'existing' }; want = 'fail' },
    @{ name = 'S7e invalid json'; args = @{ HttpStatus = '200'; BodyText = $badJson; ExpectId = '9007199254741007'; ExpectKind = 'existing' }; want = 'fail' },
    @{ name = 'S7f missing body file'; args = @{ HttpStatus = '200'; BodyText = ''; ExpectId = '9007199254741007'; ExpectKind = 'existing' }; want = 'fail' },
    @{ name = 'S7g id mismatch'; args = @{ HttpStatus = '200'; BodyText = $idMismatch; ExpectId = '9007199254741007'; ExpectKind = 'existing' }; want = 'fail' }
)
foreach ($c in $s7) {
    $argSet = $c.args
    $r = Test-DetailResponse @argSet
    Add-Result $c.name ($r.status -eq $c.want) "got=$($r.status) want=$($c.want) reason=$($r.reason)"
}

# =====================================================================
# S8: prerequisite not done -> skipped, never counted as passed
# =====================================================================
$s8dir = Join-Path $casesRoot 'case-08-skipped'
try {
    $s8 = Start-RunDirectory -OutDir $s8dir -RunId 'case-08-skipped' -Stage 'offline-test' -ExperimentRoot $casesRoot
    Add-RunCheck -State $s8 -Name 's8.real_check' -Status 'pass' -Detail 'real work done'
    Add-RunCheck -State $s8 -Name 's8.prerequisite_missing' -Status 'skipped' -Detail 'async static page never ran'
    $code8 = Set-RunStatus -State $s8 -Status 'passed'
    $c8 = Get-RunCheckCounts $s8
    $ok8 = ($c8.passed -eq 1) -and ($c8.skipped -eq 1) -and ($c8.failed -eq 0) -and ($code8 -eq 0)
    Add-Result 'S8 skipped is counted separately and not as a pass' $ok8 "passed=$($c8.passed) skipped=$($c8.skipped) failed=$($c8.failed) code=$code8"

    $s8bdir = Join-Path $casesRoot 'case-08b-only-skipped'
    $s8b = Start-RunDirectory -OutDir $s8bdir -RunId 'case-08b-only-skipped' -Stage 'offline-test' -ExperimentRoot $casesRoot
    Add-RunCheck -State $s8b -Name 's8b.only_skipped' -Status 'skipped' -Detail 'nothing verified'
    $code8b = Set-RunStatus -State $s8b -Status 'passed'
    Add-Result 'S8b a run that verified nothing cannot pass' ($code8b -eq 1) "code=$code8b"
} catch {
    Add-Result 'S8 skipped handling' $false "$($_.Exception.Message)"
}

# =====================================================================
# S9: real collector exit code for an existing directory (guard must win, no HTTP)
# =====================================================================
$existingForChild = Join-Path $casesRoot 'case-09-child-existing'
New-Item -ItemType Directory -Path $existingForChild | Out-Null
$sentinel9 = New-Sentinel $existingForChild 'keep.txt' 'DO-NOT-TOUCH'
$prewarm = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'load\p1-prewarm.ps1'
$idFileForChild = Join-Path $out 'nonexistent-ids.txt'
$childOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $prewarm `
    -IdFile $idFileForChild -OutDir $existingForChild -RunId 'case-09-child-existing' `
    -ExperimentRoot $out 2>&1
$childCode = $LASTEXITCODE
$sentinel9After = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $existingForChild 'keep.txt')).Hash
$ok9 = ($childCode -eq 2) -and ($sentinel9 -eq $sentinel9After) -and (@(Get-ChildItem -LiteralPath $existingForChild).Count -eq 1)
Add-Result 'S9 collector exits 2 on existing dir, files untouched' $ok9 "code=$childCode sentinel_same=$($sentinel9 -eq $sentinel9After) files=$(@(Get-ChildItem -LiteralPath $existingForChild).Count)"

# =====================================================================
# R1: the fixture itself is per-run isolated and never pre-cleaned
# =====================================================================
$srcText = Get-Content -LiteralPath $PSCommandPath -Raw
$rmToken = 'Remove' + '-Item'   # built at runtime so this file never contains the literal itself
$noDelete = -not ($srcText -match [regex]::Escape($rmToken))
$allUnderRun = $true
$stray = @()
foreach ($d in (Get-ChildItem -LiteralPath $casesRoot -Directory)) {
    if ($d.Parent.FullName -ne $casesRoot) { $allUnderRun = $false; $stray += $d.FullName }
}
$topLevel = @(Get-ChildItem -LiteralPath $TestRoot -Directory | Where-Object { $_.Name -ne $RunId })
$okR1 = $noDelete -and $allUnderRun -and (($casesRoot.StartsWith($out, [System.StringComparison]::OrdinalIgnoreCase))) -and (@($stray).Count -eq 0)
Add-Result 'R1 cases live only under this run (no pre-clean, no shared case dirs)' $okR1 "no_preclean=$noDelete cases_under_run=$allUnderRun stray=$(@($stray).Count) case_dirs=$(@(Get-ChildItem -LiteralPath $casesRoot -Directory).Count) other_run_dirs_in_root=$($topLevel.Count)"

# =====================================================================
# R2: counter positive control, and a wrong-order stub is detected
# =====================================================================
Reset-Counter
Mock-Http | Out-Null
$oneCall = Get-Counter
Reset-Counter
Mock-Http | Out-Null
Mock-RedisDel | Out-Null
Mock-Sql | Out-Null
$threeCalls = Get-Counter
$okR2a = ($oneCall -eq 1) -and ($threeCalls -eq 3)
Add-Result 'R2a counter counts real calls (1 -> 1, one of each kind -> 3)' $okR2a "after_one=$oneCall after_three=$threeCalls"

$wrongDir = Join-Path $casesRoot 'case-r02-wrong-order'
New-Item -ItemType Directory -Path $wrongDir | Out-Null
Reset-Counter
$wrongThrew = $false
try { Invoke-WrongOrderStub -OutDir $wrongDir } catch { $wrongThrew = $true }
$wrongCalls = Get-Counter
$okR2b = $wrongThrew -and ($wrongCalls -eq 1)
Add-Result 'R2b wrong-order stub (call before guard) is caught by the counter' $okR2b "guard_threw=$wrongThrew calls=$wrongCalls"

# =====================================================================
# R3: requests.csv keeps its fixed header and round-trips
# =====================================================================
$csvDir = Join-Path $out 'csv-fixture'
New-Item -ItemType Directory -Path $csvDir | Out-Null
$enc = New-Object System.Text.UTF8Encoding($false)
$header = Get-RequestCsvHeader
$rows = @(
    '12:00:00.000,7,9007199254741007,12.345,200,200,true,',
    '12:00:00.100,8,1234567890123456789,15.678,200,200,true,'
)
$csvPath = Join-Path $csvDir 'requests.csv'
[System.IO.File]::WriteAllText($csvPath, (Format-RequestCsv -Rows $rows), $enc)
$parsed = @(Import-Csv -LiteralPath $csvPath)
$cols = if ($parsed.Count -gt 0) { ($parsed[0].PSObject.Properties.Name -join ',') } else { '' }
$firstLine = Get-Content -LiteralPath $csvPath -TotalCount 1
$okR3a = ($parsed.Count -eq 2) -and ($cols -ceq $header) -and ($firstLine -ceq $header) -and ($parsed[0].article_id -ceq '9007199254741007')
Add-Result 'R3a requests.csv has the fixed 8-column header and 2 readable rows' $okR3a "rows=$($parsed.Count) cols=$cols header_first=$($firstLine -ceq $header) id=$($parsed[0].article_id)"

$csvEmpty = Join-Path $csvDir 'requests-empty.csv'
[System.IO.File]::WriteAllText($csvEmpty, (Format-RequestCsv -Rows @()), $enc)
$emptyRecords = @(Import-Csv -LiteralPath $csvEmpty)
$emptyLine = Get-Content -LiteralPath $csvEmpty -TotalCount 1
$okR3b = ($emptyRecords.Count -eq 0) -and ($emptyLine -ceq $header)
Add-Result 'R3b empty run still writes the header only' $okR3b "records=$($emptyRecords.Count) header_only=$($emptyLine -ceq $header)"

# the real load generator must use the same helper, not a hand-built row dump
$loadSrc = Get-Content -LiteralPath (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'load\p0-detail-load.ps1') -Raw
$oldShapeToken = '-Text (($all'   # built at runtime so this file never contains the old shape itself
$okR3c = ($loadSrc -match 'Format-RequestCsv') -and (-not ($loadSrc -match [regex]::Escape($oldShapeToken)))
Add-Result 'R3c load generator writes requests.csv through the shared helper' $okR3c "uses_helper=$($loadSrc -match 'Format-RequestCsv') old_shape=$(($loadSrc -match [regex]::Escape($oldShapeToken)))"

# =====================================================================
# R4: judge the parsed data.article.id itself
# =====================================================================
$idBig = '1234567890123456789'
$r4 = @(
    @{ name = 'R4a bare number id, same value as string elsewhere'; body = '{"code":200,"data":{"article":{"id":9007199254741007},"other":{"id":"9007199254741007"}}}'; id = '9007199254741007'; kind = 'existing'; want = 'fail' },
    @{ name = 'R4b id field missing'; body = '{"code":200,"data":{"article":{"title":"x"}}}'; id = '9007199254741007'; kind = 'existing'; want = 'fail' },
    @{ name = 'R4c id null'; body = '{"code":200,"data":{"article":{"id":null}}}'; id = '9007199254741007'; kind = 'existing'; want = 'fail' },
    @{ name = 'R4d wrong id string'; body = '{"code":200,"data":{"article":{"id":"9007199254741008"}}}'; id = '9007199254741007'; kind = 'existing'; want = 'fail' },
    @{ name = 'R4e legal JSON whitespace and newlines'; body = "{`"code`": 200,`n  `"data`" : { `"article`" : { `"id`" : `"9007199254741007`" } } }"; id = '9007199254741007'; kind = 'existing'; want = 'pass' },
    @{ name = 'R4f 19-digit string id above 2^53-1'; body = '{"code":200,"data":{"article":{"id":"1234567890123456789"}}}'; id = $idBig; kind = 'existing'; want = 'pass' }
)
foreach ($c in $r4) {
    $r = Test-DetailResponse -HttpStatus '200' -BodyText $c.body -ExpectId $c.id -ExpectKind $c.kind
    Add-Result $c.name ($r.status -eq $c.want) "got=$($r.status) want=$($c.want) reason=$($r.reason)"
}

# =====================================================================
# R1 (cross-run): the second run must not change the first run's tree
# =====================================================================
if ($VerifyPreviousRunDir -ne '') {
    $prev = [System.IO.Path]::GetFullPath($VerifyPreviousRunDir)
    $snapPath = Join-Path $prev 'run-tree-snapshot.tsv'
    if (-not (Test-Path -LiteralPath $snapPath)) {
        Add-Result 'R1x second run leaves the first run tree untouched' $false "missing snapshot: $snapPath"
    } else {
        $deleted = 0; $modified = 0; $checked = 0
        $recorded = @{}
        foreach ($line in (Get-Content -LiteralPath $snapPath)) {
            if ($line.Trim() -eq '') { continue }
            $p = $line -split "`t"
            $recorded[$p[0]] = $true
            $abs = Join-Path $prev $p[0]
            $checked++
            if (-not (Test-Path -LiteralPath $abs)) { $deleted++; Write-Host "  DELETED $($p[0])"; continue }
            $f = Get-Item -LiteralPath $abs
            $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $abs).Hash.ToLower()
            if (($f.Length -ne [long]$p[1]) -or ($h -ne $p[2])) { $modified++; Write-Host "  MODIFIED $($p[0])" }
        }
        $added = 0
        Get-ChildItem -LiteralPath $prev -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($prev.Length + 1)
            if (-not $recorded.ContainsKey($rel)) { $added++; Write-Host "  ADDED $rel" }
        }
        $extraKept = $true
        if ($ExpectExtraFile -ne '') { $extraKept = Test-Path -LiteralPath (Join-Path $prev $ExpectExtraFile) }
        $ok = ($deleted -eq 0) -and ($modified -eq 0) -and ($checked -gt 0) -and $extraKept
        Add-Result 'R1x second run leaves the first run tree untouched, extra sentinel kept' $ok "checked=$checked deleted=$deleted modified=$modified added=$added extra_kept=$extraKept"
    }
}

# ---------- per-run tree snapshot (consumed by a later run's R1x check) ----------
$snapName = 'run-tree-snapshot.tsv'
$snap = Get-TreeSnapshot -root $out -excludeRel $snapName
$snapLines = @()
foreach ($k in $snap.Keys) { $snapLines += ("{0}`t{1}`t{2}" -f $k, $snap[$k].size, $snap[$k].sha) }
Set-Content -LiteralPath (Join-Path $out $snapName) -Value $snapLines -Encoding ASCII

# ---------- summary ----------
$pass = @($script:results | Where-Object { $_.pass }).Count
$fail = @($script:results | Where-Object { -not $_.pass }).Count
$summary = [ordered]@{
    run_id                       = $RunId
    round                        = 2
    guard_version                = (Get-RunGuardVersion)
    test_root                    = [System.IO.Path]::GetFullPath($TestRoot)
    run_dir                      = $out
    cases_root                   = $casesRoot
    verified_previous_run        = $VerifyPreviousRunDir
    finished_utc                 = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $inv)
    total                        = $script:results.Count
    passed                       = $pass
    failed                       = $fail
    results                      = $script:results
    external_calls_on_rejection  = 'zero in S2/S3/S4/S6a (counter file, positive control in R2)'
    csv_header                   = (Get-RequestCsvHeader)
    tree_snapshot                = (Join-Path $out $snapName)
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $out 'guard-test-results.json')
Write-Host ""
Write-Host "offline guard tests (round 2): $pass passed, $fail failed (of $($script:results.Count))"
if ($fail -gt 0) { exit 1 }
exit 0
