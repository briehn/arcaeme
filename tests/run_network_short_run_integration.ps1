param(
    [Parameter(Mandatory)] [string]$Godot,
    [ValidateRange(1024, 65530)] [int]$BasePort = 26800,
    [ValidateSet('take', 'skip', 'mixed', 'lobby-disconnect', 'reward-disconnect')]
    [string[]]$Scenarios = @('take', 'skip', 'mixed', 'lobby-disconnect', 'reward-disconnect'),
    [switch]$Native
)

$ErrorActionPreference = 'Stop'
$engine = (Resolve-Path -LiteralPath $Godot).Path
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$logFolder = Join-Path $env:TEMP ('arcaeme-network-run-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $logFolder | Out-Null

function Start-Participant([string]$Scenario, [int]$Port, [int]$Size, [int]$Seat, [string]$Barrier) {
    $prefix = "$Barrier-seat$Seat"
    $arguments = @()
    if (-not $Native) { $arguments += '--headless' }
    $arguments += @('--path', ('"' + $project + '"'), '--log-file', ('"' + $prefix + '.log"'),
        '--script', 'res://tests/network_run_integration.gd', '--', $Scenario, $Port, $Size, $Seat,
        ('"' + $Barrier + '"'))
    $process = Start-Process -FilePath $engine -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$prefix.stdout" -RedirectStandardError "$prefix.stderr"
    return @{ Process = $process; Output = "$prefix.stdout"; Errors = "$prefix.stderr" }
}

function Wait-Marker($Participant, [string]$Pattern) {
    $deadline = [DateTime]::UtcNow.AddSeconds(35)
    while ($true) {
        $found = @(Select-String -LiteralPath $Participant.Output -Pattern $Pattern)
        if ($found.Count -eq 1) { return $found[0].Line }
        if ($found.Count -gt 1 -or $Participant.Process.HasExited -or [DateTime]::UtcNow -ge $deadline) {
            $output = Get-Content -LiteralPath $Participant.Output, $Participant.Errors
            throw (@("Expected one $Pattern in $($Participant.Output).") + $output -join "`n")
        }
        Start-Sleep -Milliseconds 40
    }
}

function Confirm-Exit($Participant) {
    $process = $Participant.Process
    if (-not $process.WaitForExit(5000)) {
        throw "Godot process $($process.Id) did not exit. Logs in $logFolder."
    }
    $errors = Get-Content -LiteralPath $Participant.Errors
    if ($process.ExitCode -ne 0 -or ($errors -match '^SCRIPT ERROR:')) {
        throw (@("Peer failed. Logs in $logFolder.") + $errors -join "`n")
    }
}

function Confirm-SharedMarker($Participants, [string]$Pattern) {
    $expected = Wait-Marker $Participants[0] $Pattern
    foreach ($participant in ($Participants | Select-Object -Skip 1)) {
        $actual = Wait-Marker $participant $Pattern
        if ($actual -ne $expected) {
            throw "Peers disagree on $Pattern. Logs in $logFolder."
        }
    }
}

function Release-Barrier([string]$Barrier, [string]$Name) {
    New-Item -ItemType File -Path "$Barrier.$Name" | Out-Null
}

function Test-Scenario([string]$Scenario, [int]$Port) {
    $sizes = @{ take = 2; skip = 3; mixed = 4; 'lobby-disconnect' = 3; 'reward-disconnect' = 3 }
    $size = $sizes[$Scenario]
    $lastSeat = if ($Scenario -eq 'lobby-disconnect') { $size - 1 } else { $size }
    $barrier = Join-Path $logFolder "$Port-$Scenario"
    $participants = @()
    try {
        for ($seat = 1; $seat -le $lastSeat; $seat++) {
            $participant = Start-Participant $Scenario $Port $size $seat $barrier
            $participants += $participant
            $null = Wait-Marker $participant "^SEAT_READY $seat$"
        }

        if ($Scenario -eq 'skip') {
            $null = Wait-Marker $participants[0] '^OVERLAP_HOST_READY$'
            Release-Barrier $barrier 'send-overlap'
            foreach ($client in ($participants | Select-Object -Skip 1)) {
                $null = Wait-Marker $client '^OVERLAP_SENT 0$'
            }
            Release-Barrier $barrier 'resolve-overlap'
            Confirm-SharedMarker $participants '^OVERLAP_STATE '
            Release-Barrier $barrier 'continue-opening'
        }

        if ($Scenario -eq 'mixed') {
            $null = Wait-Marker $participants[1] '^REWARD_PROBES_DONE$'
            Release-Barrier $barrier 'continue-rewards'
        }

        if ($Scenario -in @('take', 'skip', 'mixed')) {
            Confirm-SharedMarker $participants '^BOSS_READY '
            Release-Barrier $barrier 'continue-boss'
        }

        Confirm-SharedMarker $participants '^RESULT '
        Release-Barrier $barrier 'finish'
        foreach ($participant in $participants) { Confirm-Exit $participant }
        $mode = if ($Native) { 'native' } else { 'headless' }
        Write-Output ("$size-player $Scenario ($mode) passed · " + (Wait-Marker $participants[0] '^RESULT ').Substring(7))
    } finally {
        foreach ($participant in $participants) {
            if (-not $participant.Process.HasExited) { Stop-Process -Id $participant.Process.Id }
        }
    }
}

try {
    $port = $BasePort
    foreach ($scenario in $Scenarios) {
        Test-Scenario $scenario $port
        $port++
    }
} finally {
    Write-Output "Process logs are in $logFolder"
}
