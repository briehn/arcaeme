param(
    [Parameter(Mandatory)] [string]$Godot,
    [ValidateRange(1024, 65520)] [int]$BasePort = 26604,
    [ValidateRange(2, 4)] [int[]]$PartySizes = @(2, 3, 4),
    [ValidateSet('victory', 'survivor', 'defeat', 'host-leaves', 'client-leaves', 'join-failure')]
    [string[]]$Scenarios = @('victory', 'survivor', 'defeat', 'host-leaves', 'client-leaves', 'join-failure'),
    [switch]$Native
)

$ErrorActionPreference = 'Stop'
$engine = (Resolve-Path -LiteralPath $Godot).Path
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$logFolder = Join-Path $env:TEMP ('arcaeme-network-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $logFolder | Out-Null

function Start-Participant([string]$Role, [string]$Scenario, [int]$Port, [int]$Size, [int]$Seat, [string]$ReleasePath) {
    $prefix = Join-Path $logFolder "$Size-$Scenario-seat$Seat"
    $arguments = @()
    if (-not $Native) { $arguments += '--headless' }
    $arguments += @('--path', ('"' + $project + '"'), '--log-file', ('"' + $prefix + '.log"'),
        '--script', 'res://tests/network_coop_integration.gd', '--', $Role, $Scenario, $Port, $Size, $Seat,
        ('"' + $ReleasePath + '"'))
    $process = Start-Process -FilePath $engine -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$prefix.stdout" -RedirectStandardError "$prefix.stderr"
    return @{ Process = $process; Output = "$prefix.stdout"; Errors = "$prefix.stderr" }
}

function Wait-Marker($Participant, [string]$Pattern) {
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (-not (Select-String -LiteralPath $Participant.Output -Pattern $Pattern -Quiet)) {
        if ($Participant.Process.HasExited -or [DateTime]::UtcNow -ge $deadline) {
            $output = Get-Content -LiteralPath $Participant.Output, $Participant.Errors
            throw (@("Missing $Pattern. Logs in $logFolder") + $output -join "`n")
        }
        Start-Sleep -Milliseconds 60
    }
}

function Read-Result($Participant) {
    Wait-Marker $Participant '^RESULT '
    $output = Get-Content -LiteralPath $Participant.Output
    $result = $output | Where-Object { $_ -like 'RESULT *' }
    if (@($result).Count -ne 1) {
        throw "Expected one outcome from $($Participant.Output). Logs in $logFolder."
    }
    $publicState = $output | Where-Object { $_ -like 'PUBLIC_STATE *' }
    return @{ Summary = $result.Substring(7); PublicState = $publicState }
}

function Confirm-Exit($Participant) {
    $process = $Participant.Process
    if (-not $process.WaitForExit(5000)) {
        throw "Godot process $($process.Id) did not exit after the test. Logs in $logFolder."
    }
    $errors = Get-Content -LiteralPath $Participant.Errors
    if ($process.ExitCode -ne 0 -or ($errors -match '^SCRIPT ERROR:')) {
        throw (@("Peer failed. Logs in $logFolder") + $errors -join "`n")
    }
}

function Test-Scenario([int]$Size, [string]$Scenario, [int]$Port) {
    $participants = @()
    $releasePath = Join-Path $logFolder "$Size-$Scenario.release"
    try {
        if ($Scenario -eq 'join-failure') {
            $participants += Start-Participant 'client' $Scenario $Port $Size 2 $releasePath
        } else {
            $hostPeer = Start-Participant 'host' $Scenario $Port $Size 1 $releasePath
            $participants += $hostPeer
            Wait-Marker $hostPeer '^HOST_READY$'
            for ($seat = 2; $seat -le $Size; $seat++) {
                $clientPeer = Start-Participant 'client' $Scenario $Port $Size $seat $releasePath
                $participants += $clientPeer
                Wait-Marker $clientPeer ("^SEAT_READY $seat$")
                if ($Size -eq 3 -and $Scenario -eq 'survivor' -and $seat -eq 2) {
                    # A seated client must wait beyond the original five-second connect timeout.
                    Start-Sleep -Milliseconds 5600
                }
            }
        }

        $baseline = Read-Result $participants[0]
        if ($Scenario -in @('victory', 'survivor', 'defeat') -and -not $baseline.PublicState) {
            throw "Missing authoritative public-state digest. Logs in $logFolder."
        }
        foreach ($participant in ($participants | Select-Object -Skip 1)) {
            $result = Read-Result $participant
            if ($result.Summary -ne $baseline.Summary -or $result.PublicState -ne $baseline.PublicState) {
                throw "Different outcomes in $Size-player $Scenario. Logs in $logFolder."
            }
        }

        if ($Size -eq 4 -and $Scenario -eq 'victory') {
            $latePeer = Start-Participant 'client' 'late-join' $Port $Size ($Size + 1) $releasePath
            $participants += $latePeer
            $lateResult = Read-Result $latePeer
            if ($lateResult.Summary -ne 'late join refused') {
                throw "Expected the occupied session to refuse a late join. Logs in $logFolder."
            }
            Write-Output '4-player late join passed · fifth instance refused without a seat'
        }

        New-Item -ItemType File -Path $releasePath | Out-Null
        foreach ($participant in $participants) { Confirm-Exit $participant }
        Write-Output "$Size-player $Scenario passed · $($baseline.Summary)"
    } finally {
        foreach ($participant in $participants) {
            if (-not $participant.Process.HasExited) { Stop-Process -Id $participant.Process.Id }
        }
    }
}

try {
    $port = $BasePort
    foreach ($size in $PartySizes) {
        foreach ($scenario in $Scenarios) {
            if ($scenario -eq 'join-failure' -and $size -ne $PartySizes[0]) { continue }
            Test-Scenario $size $scenario $port
            $port++
        }
    }
} finally {
    Write-Output "Process logs are in $logFolder"
}
