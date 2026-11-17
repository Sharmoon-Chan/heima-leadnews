param(
    [Parameter(Mandatory=$true)][string]$BootstrapServers,
    [Parameter(Mandatory=$true)][string]$DltTopic,
    [Parameter(Mandatory=$true)][ValidateRange(0,2147483647)][int]$Partition,
    [Parameter(Mandatory=$true)][ValidateRange(0,9223372036854775807)][long]$Offset,
    [Parameter(Mandatory=$true)][string]$EventId,
    [Parameter(Mandatory=$true)][string]$TargetTopic,
    [Parameter(Mandatory=$true)][string]$ClassPath,
    [string]$ConfirmTarget,
    [string]$ReplayId,
    [string]$Journal,
    [string]$PayloadSha256,
    [ValidateRange(0.1,1.0)][double]$RatePerSecond = 1.0,
    [switch]$Execute,
    [string]$Java = 'java'
)
$ErrorActionPreference = 'Stop'
# P21ReplayCli must be compiled beforehand with the project's existing kafka-clients 2.5.1.
$arguments = @('-cp', $ClassPath, 'P21ReplayCli', '--bootstrap', $BootstrapServers,
    '--dlt-topic', $DltTopic, '--partition', [string]$Partition, '--offset', [string]$Offset,
    '--event-id', $EventId, '--target-topic', $TargetTopic,
    '--rate', $RatePerSecond.ToString([Globalization.CultureInfo]::InvariantCulture),
    '--execute', $Execute.IsPresent.ToString().ToLowerInvariant())
if ($Execute) {
    if ($ConfirmTarget -cne $TargetTopic) { throw 'ConfirmTarget must exactly equal TargetTopic' }
    if ([string]::IsNullOrWhiteSpace($ReplayId) -or [string]::IsNullOrWhiteSpace($Journal)) {
        throw 'Execute requires a new ReplayId and a shared Journal file'
    }
    if ($PayloadSha256 -cnotmatch '^[0-9a-fA-F]{64}$') {
        throw 'Execute requires PayloadSha256 copied from the confirmed preview'
    }
    $arguments += @('--confirm-target', $ConfirmTarget, '--replay-id', $ReplayId, '--journal', $Journal)
}
if (-not [string]::IsNullOrWhiteSpace($PayloadSha256)) { $arguments += @('--payload-sha256', $PayloadSha256) }
& $Java @arguments
if ($LASTEXITCODE -ne 0) { throw "P21ReplayCli failed with exit code $LASTEXITCODE" }
