# P1.2 lock-lifecycle scenarios C3/C4/C5/C6/C7 (ASCII only).
#
# One scenario per invocation, one run_id per invocation, every artifact written exactly once.
# The service under test is the real article service started by start-p1-2-instance.ps1; the only
# simulated parts are the ones the card allows and each is named explicitly in the output:
#   * a controlled delay in front of the DAO call (simulated slow DB, injected by DetailProbe)
#   * a Redis failure thrown at read / lock / release (simulated Redis fault, opt-in per instance)
#   * an interrupt delivered to a thread that is provably inside the wait loop
# Nothing here stops, flushes or reconfigures the shared MySQL/Redis services.
param(
    [Parameter(Mandatory = $true)][ValidateSet('C3', 'C4', 'C5', 'C6', 'C7', 'R1')][string]$Scenario,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$RunId,
    [string]$ExperimentRoot = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261030-P1.2',
    [string]$MainBase = 'http://127.0.0.1:51802',
    [string]$HolderBase = 'http://127.0.0.1:51803',
    [string]$MainEvents = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261030-P1.2/events/main-events.log',
    [string]$HolderEvents = 'D:/Code/Java/heima-leadnews/_optimization-artifacts/20261030-P1.2/events/holder-events.log',
    [long]$C3ArticleId = 9007199254741002,
    [long]$C4ArticleId = 9007199254741004,
    [long]$C6ArticleId = 9007199254741005,
    [long]$R1ArticleId = 9007199254741006,
    [int]$R1ForeignLockMs = 3000,
    [long]$C7BigId19 = 1234567890123456789,
    [long]$C7MissingId = 9007199254760000,
    [long]$C7BigId16 = 9007199254741000,
    [int]$HolderPid = 0,
    [string]$FaultBase = 'http://127.0.0.1:51803',
    [string]$FaultStage = 'read',
    [string]$RedisCli = 'D:\Soft\Redis\redis-cli.exe',
    [string]$CacheKeyPrefix = 'article:detail:',
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

. (Join-Path $PSScriptRoot '..\lib\RunDirGuard.ps1')
$script:run = $null
trap { exit (Save-RunFailure -State $script:run -ErrorRecord $_) }
try {
    $script:run = Start-RunDirectory -OutDir $OutDir -RunId $RunId -Stage "P1.2-$Scenario" `
        -ExperimentRoot $ExperimentRoot -ScriptPath $PSCommandPath `
        -Parameters @{ scenario = $Scenario; main = $MainBase; holder = $HolderBase; fault_stage = $FaultStage } `
        -Targets @("$C3ArticleId", "$C4ArticleId", "$C6ArticleId")
} catch {
    Write-Host "RUN FAILED (guard): $($_.Exception.Message)"
    exit 2
}

[System.Net.ServicePointManager]::DefaultConnectionLimit = 200
[System.Net.ServicePointManager]::Expect100Continue = $false
Add-Type -AssemblyName System.Net.Http | Out-Null
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.MaxConnectionsPerServer = 200
$handler.UseProxy = $false
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

function Now-Utc { return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $inv) }
function Redis-Exact([string[]]$cmdArgs) {
    $all = @('-h', '127.0.0.1', '-p', '6379', '-n', '0') + $cmdArgs
    return ((& $RedisCli @all 2>&1) | Out-String).Trim()
}
function Add-Check([string]$name, [bool]$ok, [string]$detail) {
    Add-RunCheck -State $script:run -Name $name -Status $(if ($ok) { 'pass' } else { 'fail' }) -Detail $detail
}
function Get-Field([string]$line, [string]$name) {
    $m = [regex]::Match($line, "(?:^|\s)$name=([^\s]+)")
    return $(if ($m.Success) { $m.Groups[1].Value } else { '' })
}
function Read-Events([string]$path, [string]$runId) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path | Where-Object { $_ -match " runId=$([regex]::Escape($runId)) " })
}

$script:samples = @()
function Sample-Lock([string]$label, [string]$key) {
    $s = [ordered]@{
        at_utc = (Now-Utc)
        label  = $label
        exists = (Redis-Exact @('EXISTS', $key))
        value  = (Redis-Exact @('GET', $key))
        pttl   = (Redis-Exact @('PTTL', $key))
    }
    $script:samples += [pscustomobject]$s
    return [pscustomobject]$s
}

function New-Request([string]$base, [long]$id, [string]$requestId, [string]$runId) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, "$base/api/v1/article/detail/$id")
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Run-Id', $runId)
    $null = $req.Headers.TryAddWithoutValidation('X-P1-Request-Id', $requestId)
    return $req
}
function Save-Response([string]$name, $resp, [double]$elapsedMs) {
    $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    [System.IO.File]::WriteAllBytes((Join-Path $OutDir "$name.body.json"), $bytes)
    $meta = [ordered]@{
        name         = $name
        at_utc       = (Now-Utc)
        http_status  = [int]$resp.StatusCode
        bytes        = $bytes.Length
        elapsed_ms   = [math]::Round($elapsedMs, 3)
    }
    Write-RunFileText -State $script:run -Path (Join-Path $OutDir "$name.meta.json") -Text ($meta | ConvertTo-Json -Depth 4)
    return [pscustomobject]$meta
}
function Read-Body([string]$name) {
    $p = Join-Path $OutDir "$name.body.json"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($p))
}
function Get-Code([string]$raw) {
    if ($null -eq $raw) { return 'MISSING' }
    $m = [regex]::Match($raw, '"code"\s*:\s*(-?\d+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'MISSING'
}

$result = [ordered]@{ run_id = $RunId; scenario = $Scenario; started_utc = (Now-Utc) }

switch ($Scenario) {

# =====================================================================
'C3' {
    # A (holder, port 51803) acquires the lock and holds it for 4000 ms > 3000 ms lease.
    # B (main, port 51802) starts at +3200 ms, so A's lease has already expired and B takes a NEW lock.
    # Then A's real finally runs: the pre-fix code deletes whatever is at the key, i.e. B's lock.
    $cacheKey = "$CacheKeyPrefix$C3ArticleId"
    $lockKey = "$cacheKey`:lock"
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    Redis-Exact @('DEL', $lockKey) | Out-Null
    $result['cache_key'] = $cacheKey
    $result['cold'] = [ordered]@{ exists = (Redis-Exact @('EXISTS', $cacheKey)); pttl = (Redis-Exact @('PTTL', $cacheKey)); lock_exists = (Redis-Exact @('EXISTS', $lockKey)) }
    Add-Check 'c3.starts_cold' (($result.cold.exists -eq '0') -and ($result.cold.pttl -eq '-2') -and ($result.cold.lock_exists -eq '0')) "exists=$($result.cold.exists) pttl=$($result.cold.pttl) lock=$($result.cold.lock_exists)"

    # Wait for observable state instead of assuming fixed offsets: the first request on a fresh
    # instance carries JVM/JIT/connection warm-up, so wall-clock guesses are not reliable.
    $swA = [System.Diagnostics.Stopwatch]::StartNew()
    $taskA = $client.SendAsync((New-Request $HolderBase $C3ArticleId 'A-holder' $RunId))
    $acqDeadline = (Get-Date).AddSeconds(10)
    $sA = $null
    while ((Get-Date) -lt $acqDeadline) {
        $sA = Sample-Lock 'poll A hold' $lockKey
        if ($sA.exists -eq '1') { break }
        Start-Sleep -Milliseconds 50
    }
    $tAcquireA = $swA.Elapsed.TotalMilliseconds
    Add-Check 'c3.A_held_the_lock' ($sA.exists -eq '1' -and [int]$sA.pttl -gt 0) "A acquired at ~$([math]::Round($tAcquireA,0))ms, exists=$($sA.exists) pttl=$($sA.pttl)"

    # wait for A's lease to disappear while A is still inside the critical section
    $leaseDeadline = (Get-Date).AddSeconds(10)
    $sLease = $null
    while ((Get-Date) -lt $leaseDeadline) {
        $sLease = Sample-Lock 'poll lease' $lockKey
        if ($sLease.exists -eq '0') { break }
        Start-Sleep -Milliseconds 100
    }
    $tLease = $swA.Elapsed.TotalMilliseconds
    Add-Check 'c3.lease_expired_while_A_worked' ($sLease.exists -eq '0') "lease gone at ~$([math]::Round($tLease,0))ms after A started (A is still running: $(-not $taskA.IsCompleted))"
    Add-Check 'c3.A_still_running_when_lease_gone' (-not $taskA.IsCompleted) "taskA.IsCompleted=$($taskA.IsCompleted)"

    # B starts right after the lease disappeared, so it must be able to take a NEW lock
    $swB = [System.Diagnostics.Stopwatch]::StartNew()
    $taskB = $client.SendAsync((New-Request $MainBase $C3ArticleId 'B-second' $RunId))
    $bDeadline = (Get-Date).AddSeconds(10)
    $sB = $null
    while ((Get-Date) -lt $bDeadline) {
        $sB = Sample-Lock 'poll B hold' $lockKey
        if ($sB.exists -eq '1') { break }
        Start-Sleep -Milliseconds 50
    }
    $tAcquireB = $swB.Elapsed.TotalMilliseconds
    Add-Check 'c3.B_took_a_new_lock' ($sB.exists -eq '1' -and [int]$sB.pttl -gt 0) "B acquired at ~$([math]::Round($tAcquireB,0))ms, exists=$($sB.exists) pttl=$($sB.pttl) value=$($sB.value)"
    $sB2 = Sample-Lock 'B holding' $lockKey

    # A finishes now: its real finally runs and releases the lock. B is still working.
    $respA = $taskA.GetAwaiter().GetResult()
    $swA.Stop()
    $metaA = Save-Response 'A-holder' $respA $swA.Elapsed.TotalMilliseconds
    $sAfterA = Sample-Lock 'after A finally (B still running)' $lockKey

    $respB = $taskB.GetAwaiter().GetResult()
    $swB.Stop()
    $metaB = Save-Response 'B-second' $respB $swB.Elapsed.TotalMilliseconds
    $sEnd = Sample-Lock 'end after B' $lockKey

    $result['timing_ms'] = [ordered]@{ A_acquired = [math]::Round($tAcquireA, 1); lease_gone = [math]::Round($tLease, 1); B_acquired = [math]::Round($tAcquireB, 1) }
    $result['samples'] = $script:samples
    $result['A'] = $metaA
    $result['B'] = $metaB
    $bodyA = Read-Body 'A-holder'; $bodyB = Read-Body 'B-second'
    $rA = Test-DetailResponse -HttpStatus $metaA.http_status -BodyText $bodyA -ExpectId "$C3ArticleId" -ExpectKind 'existing'
    $rB = Test-DetailResponse -HttpStatus $metaB.http_status -BodyText $bodyB -ExpectId "$C3ArticleId" -ExpectKind 'existing'
    Add-RunCheck -State $script:run -Name 'c3.A_correct_response' -Status $rA.status -Detail $rA.reason
    Add-RunCheck -State $script:run -Name 'c3.B_correct_response' -Status $rB.status -Detail $rB.reason

    $evMain = Read-Events $MainEvents $RunId
    $evHold = Read-Events $HolderEvents $RunId
    $all = @($evMain) + @($evHold)
    $relA = @($all | Where-Object { $_ -match ' requestId=A-holder ' -and $_ -match ' event=release ' })
    $relB = @($all | Where-Object { $_ -match ' requestId=B-second ' -and $_ -match ' event=release ' })
    # the discriminating observation: while B is still running, is the key still there after A's finally?
    $result['lock_present_after_A_finally'] = $sAfterA.exists
    $result['lock_value_after_A_finally'] = $sAfterA.value
    $result['lock_value_when_B_held'] = $sB2.value
    $result['release_events_A'] = ($relA -join ' | ')
    $result['release_events_B'] = ($relB -join ' | ')
    Add-Check 'c3.B_lock_survived_A_finally' ($sAfterA.exists -eq '1') "after A finally: exists=$($sAfterA.exists) value=$($sAfterA.value) (B is still running; exists=0 means A deleted B's lock)"
    Add-Check 'c3.no_lock_left_at_end' ($sEnd.exists -eq '0') "end exists=$($sEnd.exists)"

    Set-Content -LiteralPath (Join-Path $OutDir 'events-holder.log') -Value @($evHold) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $OutDir 'events-main.log') -Value @($evMain) -Encoding UTF8
}

# =====================================================================
'C4' {
    # Only the holder process created for this experiment is killed; its finally never runs.
    # After the lease expires another executor must be able to rebuild.
    if ($HolderPid -le 0) { throw 'C4 needs -HolderPid of the holder instance started by this experiment' }
    $cacheKey = "$CacheKeyPrefix$C4ArticleId"
    $lockKey = "$cacheKey`:lock"
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    Redis-Exact @('DEL', $lockKey) | Out-Null
    $result['cold'] = [ordered]@{ exists = (Redis-Exact @('EXISTS', $cacheKey)); pttl = (Redis-Exact @('PTTL', $cacheKey)); lock_exists = (Redis-Exact @('EXISTS', $lockKey)) }
    Add-Check 'c4.starts_cold' (($result.cold.lock_exists -eq '0') -and ($result.cold.exists -eq '0')) "lock=$($result.cold.lock_exists) cache=$($result.cold.exists)"

    $swH = [System.Diagnostics.Stopwatch]::StartNew()
    $taskH = $client.SendAsync((New-Request $HolderBase $C4ArticleId 'H-crash' $RunId))
    Start-Sleep -Milliseconds 1500
    $sHeld = Sample-Lock 't+1500 holder inside critical section' $lockKey
    Add-Check 'c4.holder_owns_the_lock' ($sHeld.exists -eq '1') "exists=$($sHeld.exists) pttl=$($sHeld.pttl)"

    # kill only our own holder process: the JVM cannot run finally blocks when it is terminated
    $proc = Get-Process -Id $HolderPid -ErrorAction SilentlyContinue
    if (-not $proc) { throw "holder process $HolderPid not found (refusing to kill anything else)" }
    $result['killed_pid'] = $HolderPid
    $result['killed_process_name'] = $proc.ProcessName
    if ($proc.ProcessName -ne 'java') { throw "refusing to kill non-java process $HolderPid ($($proc.ProcessName))" }
    Stop-Process -Id $HolderPid -Force
    Start-Sleep -Milliseconds 300
    $sAfterKill = Sample-Lock 'after kill' $lockKey
    Add-Check 'c4.lock_survives_crash' ($sAfterKill.exists -eq '1') "exists=$($sAfterKill.exists) pttl=$($sAfterKill.pttl) => the dead holder cannot release; only the lease can free the key"

    # wait for the lease to disappear, then let the main instance recover
    $deadline = (Get-Date).AddSeconds(10)
    $freed = $false
    while ((Get-Date) -lt $deadline) {
        if ((Redis-Exact @('EXISTS', $lockKey)) -eq '0') { $freed = $true; break }
        Start-Sleep -Milliseconds 200
    }
    $sFreed = Sample-Lock 'lease expired' $lockKey
    Add-Check 'c4.lease_eventually_frees_the_key' $freed "exists=$($sFreed.exists) pttl=$($sFreed.pttl)"

    $swR = [System.Diagnostics.Stopwatch]::StartNew()
    $respR = $client.SendAsync((New-Request $MainBase $C4ArticleId 'R-recover' $RunId)).GetAwaiter().GetResult()
    $swR.Stop()
    $metaR = Save-Response 'R-recover' $respR $swR.Elapsed.TotalMilliseconds
    $bodyR = Read-Body 'R-recover'
    $rR = Test-DetailResponse -HttpStatus $metaR.http_status -BodyText $bodyR -ExpectId "$C4ArticleId" -ExpectKind 'existing'
    Add-RunCheck -State $script:run -Name 'c4.other_executor_recovers' -Status $rR.status -Detail "$($rR.reason); http=$($metaR.http_status)"
    $result['samples'] = $script:samples

    $evMain = Read-Events $MainEvents $RunId
    Set-Content -LiteralPath (Join-Path $OutDir 'events-main.log') -Value @($evMain) -Encoding UTF8
    $acq = @($evMain | Where-Object { $_ -match ' requestId=R-recover ' -and $_ -match ' event=lock\.acquired ' })
    Add-Check 'c4.recovery_acquired_a_new_lock' ($acq.Count -eq 1) "lock.acquired events for R-recover=$($acq.Count)"
    if (Test-Path -LiteralPath $HolderEvents) {
        Set-Content -LiteralPath (Join-Path $OutDir 'events-holder.log') -Value @(Read-Events $HolderEvents $RunId) -Encoding UTF8
    }
}

# =====================================================================
'C5' {
    # The instance behind -FaultBase was started with a probe config that throws at one Redis step.
    # This is a SIMULATED Redis failure; the real Redis service is untouched.
    $id = $C3ArticleId
    $cacheKey = "$CacheKeyPrefix$id"
    $lockKey = "$cacheKey`:lock"
    $result['fault_stage'] = $FaultStage
    $result['fault_is_simulated'] = $true
    $result['fault_base'] = $FaultBase

    if ($FaultStage -eq 'read' -or $FaultStage -eq 'lock') {
        Redis-Exact @('DEL', $cacheKey) | Out-Null
        Redis-Exact @('DEL', $lockKey) | Out-Null
    } else {
        # release fault: the cache must be cold so the request actually takes the lock and rebuilds
        Redis-Exact @('DEL', $cacheKey) | Out-Null
        Redis-Exact @('DEL', $lockKey) | Out-Null
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null; $err = ''
    try {
        $resp = $client.SendAsync((New-Request $FaultBase $id "F-$FaultStage" $RunId)).GetAwaiter().GetResult()
    } catch {
        $err = $_.Exception.GetType().Name + ':' + $_.Exception.Message
    }
    $sw.Stop()

    if ($resp -ne $null) {
        $meta = Save-Response "F-$FaultStage" $resp $sw.Elapsed.TotalMilliseconds
        $body = Read-Body "F-$FaultStage"
        $code = Get-Code $body
        $result['http_status'] = $meta.http_status
        $result['biz_code'] = $code
        Add-Check 'c5.request_answered' $true "http=$($meta.http_status) biz=$code elapsed=$($meta.elapsed_ms)ms"
        if ($FaultStage -eq 'release') {
            # a release fault happens AFTER the response is decided: preserving the success is the requirement
            Add-Check 'c5.success_preserved_despite_release_fault' ($code -eq '200') "biz=$code (the original result must survive a release failure)"
        } else {
            Add-Check 'c5.no_silent_success' (-not ($code -eq '200')) "biz=$code (a simulated Redis fault at $FaultStage must not produce a normal success)"
        }
    } else {
        $result['transport_error'] = $err
        Add-Check 'c5.request_answered' $false "transport error: $err"
        Add-Check 'c5.no_silent_success' $true 'request failed at transport level, so nothing was silently served'
    }

    $lockAfter = Sample-Lock 'after fault' $lockKey
    $result['samples'] = $script:samples
    $result['lock_after'] = $lockAfter
    $ev = @(Read-Events $HolderEvents $RunId) + @(Read-Events $MainEvents $RunId)
    Set-Content -LiteralPath (Join-Path $OutDir 'events.log') -Value @($ev) -Encoding UTF8
    $injected = @($ev | Where-Object { $_ -match ' event=fault\.redis\.injected ' })
    Add-Check 'c5.fault_was_injected_once' ($injected.Count -eq 1) "injected=$($injected.Count) stage=$FaultStage"
    if ($FaultStage -eq 'release') {
        # the original request result must survive a release failure, and the leftover lock is bounded by the lease
        $body = Read-Body "F-$FaultStage"
        $r = Test-DetailResponse -HttpStatus $result.http_status -BodyText $body -ExpectId "$id" -ExpectKind 'existing'
        Add-RunCheck -State $script:run -Name 'c5.release_failure_keeps_success_response' -Status $r.status -Detail "$($r.reason); leftover lock exists=$($lockAfter.exists) pttl=$($lockAfter.pttl) (bounded by the lease)"
    }

    # R2: the injection point sits inside the same try as the real I/O call, so a failure must always
    # leave an io.error line that names the stage and the exception class. These checks verify that
    # per-stage classification, instead of inferring it from a global 503.
    $faultReq = "F-$FaultStage"
    $mine = @($ev | Where-Object { $_ -match " requestId=$([regex]::Escape($faultReq)) " })
    $begin = @($mine | Where-Object { $_ -match ' event=io\.begin ' -and $_ -match " stage=$FaultStage( |$)" })
    $ioErr = @($mine | Where-Object { $_ -match ' event=io\.error ' -and $_ -match " stage=$FaultStage( |$)" })
    $classified = @($ioErr | Where-Object { $_ -match ' error=[A-Za-z]' })
    $dbAfterFault = @($mine | Where-Object { $_ -match ' event=db\.enter ' })
    $result['io_begin_count'] = $begin.Count
    $result['io_error_count'] = $ioErr.Count
    $result['io_error_lines'] = @($ioErr)
    Add-Check 'c5.io_begin_at_actual_io' ($begin.Count -ge 1) "io.begin stage=$FaultStage count=$($begin.Count)"
    Add-Check 'c5.io_error_classified_by_stage' ($ioErr.Count -ge 1) "io.error stage=$FaultStage count=$($ioErr.Count); first=$(if ($ioErr.Count -gt 0) { $ioErr[0] } else { '-' })"
    Add-Check 'c5.io_error_names_the_exception' ($classified.Count -ge 1) "io.error carrying a concrete exception class=$($classified.Count) (injected and real failures share this path)"
    if ($FaultStage -ne 'release') {
        Add-Check 'c5.no_lock_free_dao_after_fault' ($dbAfterFault.Count -eq 0) "db.enter=$($dbAfterFault.Count) (a failed $FaultStage must not degrade into an unlocked rebuild)"
    }
}

# =====================================================================
'C6' {
    # A holds the lock; B waits; the probe interrupts B's thread while it is inside the wait loop.
    $id = $C6ArticleId
    $cacheKey = "$CacheKeyPrefix$id"
    $lockKey = "$cacheKey`:lock"
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    Redis-Exact @('DEL', $lockKey) | Out-Null
    $result['cold'] = [ordered]@{ exists = (Redis-Exact @('EXISTS', $cacheKey)); lock_exists = (Redis-Exact @('EXISTS', $lockKey)) }
    Add-Check 'c6.starts_cold' (($result.cold.exists -eq '0') -and ($result.cold.lock_exists -eq '0')) "cache=$($result.cold.exists) lock=$($result.cold.lock_exists)"

    # Deterministic order: A must be the holder. The first request on a freshly started instance
    # is slow (JVM/JIT/connection setup), so "send A first" alone does not make A the holder -
    # wait until A's lock actually exists before releasing the waiter.
    $swA = [System.Diagnostics.Stopwatch]::StartNew()
    $taskA = $client.SendAsync((New-Request $MainBase $id 'A-rebuild' $RunId))
    $holdDeadline = (Get-Date).AddSeconds(10)
    $lockSeen = $false
    while ((Get-Date) -lt $holdDeadline) {
        if ((Redis-Exact @('EXISTS', $lockKey)) -eq '1') { $lockSeen = $true; break }
        Start-Sleep -Milliseconds 20
    }
    Add-Check 'c6.holder_holds_the_lock_before_waiter_starts' $lockSeen 'A acquired the lock before B was sent'

    $swB = [System.Diagnostics.Stopwatch]::StartNew()
    $taskB = $client.SendAsync((New-Request $MainBase $id 'B-waiter-interrupted' $RunId))

    $respB = $taskB.GetAwaiter().GetResult(); $swB.Stop()
    $metaB = Save-Response 'B-waiter-interrupted' $respB $swB.Elapsed.TotalMilliseconds
    $respA = $taskA.GetAwaiter().GetResult(); $swA.Stop()
    $metaA = Save-Response 'A-rebuild' $respA $swA.Elapsed.TotalMilliseconds

    $bodyA = Read-Body 'A-rebuild'; $bodyB = Read-Body 'B-waiter-interrupted'
    $codeB = Get-Code $bodyB
    $result['A'] = $metaA; $result['B'] = $metaB
    $result['B_biz_code'] = $codeB

    $rA = Test-DetailResponse -HttpStatus $metaA.http_status -BodyText $bodyA -ExpectId "$id" -ExpectKind 'existing'
    Add-RunCheck -State $script:run -Name 'c6.holder_still_succeeds' -Status $rA.status -Detail $rA.reason
    Add-Check 'c6.interrupted_request_did_not_succeed' (-not ($codeB -eq '200')) "biz=$codeB http=$($metaB.http_status) elapsed=$($metaB.elapsed_ms)ms"

    $ev = @(Read-Events $MainEvents $RunId)
    Set-Content -LiteralPath (Join-Path $OutDir 'events-main.log') -Value @($ev) -Encoding UTF8
    $inj = @($ev | Where-Object { $_ -match ' requestId=B-waiter-interrupted ' -and $_ -match ' event=interrupt\.injected ' })
    $abort = @($ev | Where-Object { $_ -match ' requestId=B-waiter-interrupted ' -and $_ -match ' event=wait\.end ' -and $_ -match 'outcome=interrupted' })
    $bDb = @($ev | Where-Object { $_ -match ' requestId=B-waiter-interrupted ' -and $_ -match ' event=db\.enter ' })
    $caught = @($ev | Where-Object { $_ -match ' requestId=B-waiter-interrupted ' -and $_ -match ' event=interrupt_caught ' })
    $result['interrupt_events'] = $inj.Count
    $result['abort_events'] = $abort.Count
    $result['waiter_db_attempts'] = $bDb.Count
    $result['interrupt_caught_events'] = $caught.Count
    Add-Check 'c6.interrupt_reached_the_waiting_thread' ($inj.Count -ge 1) "interrupt.injected=$($inj.Count)"
    # R2: interrupt_caught records the caught InterruptedException itself; the interrupt flag is
    # already cleared by Thread.sleep, so it must not be re-derived from the flag.
    Add-Check 'c6.interrupt_caught_recorded' ($caught.Count -eq 1) "interrupt_caught=$($caught.Count)"
    Add-Check 'c6.wait_terminated_as_interrupted' ($abort.Count -eq 1) "wait.end outcome=interrupted=$($abort.Count)"
    Add-Check 'c6.no_lock_free_db_after_interrupt' ($bDb.Count -eq 0) "db.enter for the interrupted request=$($bDb.Count) (must be 0)"
}

# =====================================================================
'R1' {
    # Card item R1: the wait budget must really close BEFORE another lock attempt is issued.
    # The instance behind -MainBase runs with --article.detail.lock.wait-budget-millis=100.
    # A FOREIGN lock is planted under the same key first, so the very first SET NX fails; the wait
    # loop then sleeps and stalls 150 ms (probe fixture wait.stall.<id>), which is longer than the
    # whole budget. The next iteration must notice the deadline before issuing any second SET NX.
    $id = $R1ArticleId
    $cacheKey = "$CacheKeyPrefix$id"
    $lockKey = "$cacheKey`:lock"
    Redis-Exact @('DEL', $cacheKey) | Out-Null
    Redis-Exact @('DEL', $lockKey) | Out-Null
    Redis-Exact @('SET', $lockKey, 'p1-2-r1-foreign-holder', 'PX', "$R1ForeignLockMs") | Out-Null
    $planted = Sample-Lock 'foreign lock planted' $lockKey
    Add-Check 'r1.foreign_lock_in_place' (($planted.exists -eq '1') -and ($planted.value -eq 'p1-2-r1-foreign-holder')) "exists=$($planted.exists) value=$($planted.value) pttl=$($planted.pttl)"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $client.SendAsync((New-Request $MainBase $id 'R1-budget' $RunId)).GetAwaiter().GetResult()
    $sw.Stop()
    $meta = Save-Response 'R1-budget' $resp $sw.Elapsed.TotalMilliseconds
    $body = Read-Body 'R1-budget'
    $code = Get-Code $body
    $result['http_status'] = $meta.http_status
    $result['biz_code'] = $code
    $result['elapsed_ms'] = $meta.elapsed_ms
    Add-Check 'r1.explicit_failure' (-not ($code -eq '200')) "biz=$code http=$($meta.http_status) elapsed=$($meta.elapsed_ms)ms"

    $after = Sample-Lock 'foreign lock after request' $lockKey
    Add-Check 'r1.foreign_lock_untouched' (($after.exists -eq '1') -and ($after.value -eq 'p1-2-r1-foreign-holder')) "exists=$($after.exists) value=$($after.value) (a waiter that never acquired the lock must not delete it)"

    $ev = @(Read-Events $MainEvents $RunId)
    Set-Content -LiteralPath (Join-Path $OutDir 'events-main.log') -Value @($ev) -Encoding UTF8
    $mine = @($ev | Where-Object { $_ -match ' requestId=R1-budget ' })
    $attempts = @($mine | Where-Object { $_ -match ' event=lock\.attempt ' })
    $late = @($mine | Where-Object { $_ -match ' event=lock\.late_acquire ' })
    $ended = @($mine | Where-Object { $_ -match ' event=wait\.end ' -and $_ -match 'outcome=budget_exhausted' })
    $byAttempt = @($ended | Where-Object { $_ -match 'phase=before_attempt' -and $_ -match 'attempts=1' })
    $stalls = @($mine | Where-Object { $_ -match ' event=wait\.stall\.begin ' })
    $db = @($mine | Where-Object { $_ -match ' event=db\.enter ' })
    $result['lock_attempts'] = $attempts.Count
    $result['stall_events'] = $stalls.Count
    $result['wait_end'] = @($ended)
    Add-Check 'r1.stall_fixture_ran' ($stalls.Count -ge 1) "wait.stall.begin=$($stalls.Count)"
    Add-Check 'r1.single_lock_attempt' ($attempts.Count -eq 1) "lock.attempt=$($attempts.Count) (100 ms budget, 150 ms stall after the first sleep)"
    Add-Check 'r1.no_late_acquire' ($late.Count -eq 0) "lock.late_acquire=$($late.Count) (the loop must not even get near a second SET NX)"
    Add-Check 'r1.budget_phase_before_attempt' ($byAttempt.Count -eq 1) "wait.end: $(@($ended) -join ' | ')"
    Add-Check 'r1.no_dao_after_budget' ($db.Count -eq 0) "db.enter=$($db.Count) (a budget-exhausted waiter must not fall back to the DAO)"
}

# =====================================================================
'C7' {
    # Contract regression: cold/hot, missing (first and repeated), 16-digit and 19-digit ids.
    $cases = @(
        @{ name = 'c7-cold-16digit'; id = $C7BigId16; kind = 'existing'; cold = $true },
        @{ name = 'c7-hot-16digit'; id = $C7BigId16; kind = 'existing'; cold = $false },
        @{ name = 'c7-cold-19digit'; id = $C7BigId19; kind = 'existing'; cold = $true },
        @{ name = 'c7-hot-19digit'; id = $C7BigId19; kind = 'existing'; cold = $false },
        @{ name = 'c7-missing-first'; id = $C7MissingId; kind = 'missing'; cold = $true },
        @{ name = 'c7-missing-repeat'; id = $C7MissingId; kind = 'missing'; cold = $false }
    )
    foreach ($c in $cases) {
        $k = "$CacheKeyPrefix$($c.id)"
        if ($c.cold) { Redis-Exact @('DEL', $k) | Out-Null; Redis-Exact @('DEL', "$k`:lock") | Out-Null }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $client.SendAsync((New-Request $MainBase $c.id $c.name $RunId)).GetAwaiter().GetResult()
        $sw.Stop()
        $meta = Save-Response $c.name $resp $sw.Elapsed.TotalMilliseconds
        $body = Read-Body $c.name
        $r = Test-DetailResponse -HttpStatus $meta.http_status -BodyText $body -ExpectId "$($c.id)" -ExpectKind $c.kind
        Add-RunCheck -State $script:run -Name "$($c.name).response" -Status $r.status -Detail "$($r.reason); http=$($meta.http_status) elapsed=$($meta.elapsed_ms)ms"
        if ($c.kind -eq 'missing') {
            $exists = (Redis-Exact @('EXISTS', $k))
            Add-Check "$($c.name).placeholder" ($exists -eq '1') "null placeholder exists=$exists"
        }
    }
    $cold = Read-Body 'c7-cold-16digit'; $hot = Read-Body 'c7-hot-16digit'
    Add-Check 'c7.cold_hot_byte_identical_16' ($cold -ceq $hot) "len_cold=$($cold.Length) len_hot=$($hot.Length)"
    $cold19 = Read-Body 'c7-cold-19digit'; $hot19 = Read-Body 'c7-hot-19digit'
    Add-Check 'c7.cold_hot_byte_identical_19' ($cold19 -ceq $hot19) "len_cold=$($cold19.Length) len_hot=$($hot19.Length)"
    Add-Check 'c7.19digit_is_string_literal' ($cold19 -match [regex]::Escape('"id":"' + "$C7BigId19" + '"')) 'id serialised as an exact JSON string'
    $ev = @(Read-Events $MainEvents $RunId)
    Set-Content -LiteralPath (Join-Path $OutDir 'events-main.log') -Value @($ev) -Encoding UTF8
    $hotDb = @($ev | Where-Object { $_ -match ' requestId=c7-hot-16digit ' -and $_ -match ' event=db\.enter ' })
    $hot19Db = @($ev | Where-Object { $_ -match ' requestId=c7-hot-19digit ' -and $_ -match ' event=db\.enter ' })
    Add-Check 'c7.hot_reads_did_not_query_db' (($hotDb.Count -eq 0) -and ($hot19Db.Count -eq 0)) "hot16 db=$($hotDb.Count) hot19 db=$($hot19Db.Count)"
}

default { throw "unknown scenario: $Scenario" }
}

$client.Dispose()
$counts = Get-RunCheckCounts $script:run
$result['samples'] = $script:samples
$result['checks'] = $script:run.checks
$result['counts'] = $counts
$result['finished_utc'] = (Now-Utc)
Write-RunFileText -State $script:run -Path (Join-Path $OutDir 'scenario-result.json') -Text ($result | ConvertTo-Json -Depth 6)
$script:run.checks | ForEach-Object { "{0,-44} {1,-8} {2}" -f $_.check, $_.status, $_.detail }
exit (Set-RunStatus -State $script:run -Status $(if ($counts.failed -gt 0) { 'failed' } else { 'passed' }))
