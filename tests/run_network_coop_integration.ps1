param(
    [Parameter(Mandatory)] [string]$Godot,
    [ValidateRange(1024, 65530)] [int]$BasePort = 26604
)

$ErrorActionPreference = 'Stop'
$engine = (Resolve-Path -LiteralPath $Godot).Path
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$logFolder = Join-Path $env:TEMP ('arcaeme-network-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $logFolder | Out-Null

function Start-Participant([string]$Role, [string]$Scenario, [int]$Port) {
    $prefix = Join-Path $logFolder "$Scenario-$Role"
    $arguments = @('--headless', '--path', ('"' + $project + '"'), '--log-file', ('"' + $prefix + '.log"'),
        '--script', 'res://tests/network_coop_integration.gd', '--', $Role, $Scenario, $Port)
    $process = Start-Process -FilePath $engine -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$prefix.stdout" -RedirectStandardError "$prefix.stderr"
    return @{ Process = $process; Output = "$prefix.stdout"; Errors = "$prefix.stderr" }
}

function Read-Result($Participant) {
    $process = $Participant.Process
    if (-not $process.WaitForExit(18000)) {
        throw "Godot process $($process.Id) did not finish. See $logFolder."
    }
    $output = Get-Content -LiteralPath $Participant.Output
    $errors = Get-Content -LiteralPath $Participant.Errors
    $result = $output | Where-Object { $_ -like 'RESULT *' }
    if ($process.ExitCode -ne 0 -or @($result).Count -ne 1 -or ($errors -match '^SCRIPT ERROR:')) {
        throw (@("Peer failed. Logs in $logFolder") + $output + $errors -join "`n")
    }
    $publicState = $output | Where-Object { $_ -like 'PUBLIC_STATE *' }
    return @{ Summary = $result.Substring(7); PublicState = $publicState }
}

try {
    $port = $BasePort
    foreach ($scenario in @('victory', 'survivor', 'defeat', 'host-leaves', 'client-leaves', 'join-failure')) {
        $participants = @()
        try {
            if ($scenario -ne 'join-failure') {
                $hostPeer = Start-Participant 'host' $scenario $port
                $participants += $hostPeer
                $deadline = [DateTime]::UtcNow.AddSeconds(10)
                while (-not (Select-String -LiteralPath $hostPeer.Output -Pattern '^HOST_READY$' -Quiet)) {
                    if ($hostPeer.Process.HasExited -or [DateTime]::UtcNow -ge $deadline) {
                        throw "Host did not start for $scenario. Logs in $logFolder."
                    }
                    Start-Sleep -Milliseconds 60
                }
            }
            $clientPeer = Start-Participant 'client' $scenario $port
            $participants += $clientPeer
            $clientResult = Read-Result $clientPeer
            if ($scenario -ne 'join-failure') {
                $hostResult = Read-Result $hostPeer
                if ($clientResult.Summary -ne $hostResult.Summary -or $clientResult.PublicState -ne $hostResult.PublicState) {
                    throw "Different outcomes in $scenario. Logs in $logFolder."
                }
                if ($scenario -in @('victory', 'survivor', 'defeat') -and -not $clientResult.PublicState) {
                    throw "Missing public-state digest in $scenario. Logs in $logFolder."
                }
            }
            Write-Output "$scenario passed · $($clientResult.Summary)"
        } finally {
            foreach ($participant in $participants) {
                if (-not $participant.Process.HasExited) {
                    Stop-Process -Id $participant.Process.Id
                }
            }
        }
        $port++
    }
} finally {
    Write-Output "Process logs are in $logFolder"
}
