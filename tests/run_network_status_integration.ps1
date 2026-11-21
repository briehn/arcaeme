param(
    [Parameter(Mandatory)] [string]$Godot,
    [ValidateRange(1024, 65530)] [int]$BasePort = 27100,
    [ValidateRange(2, 4)] [int[]]$PartySizes = @(2, 3, 4),
    [switch]$Native,
    [ValidateSet('statuses', 'modifiers', 'enemies', 'enemy-actions', 'multi-enemy', 'ready', 'multi-enemy-run', 'major-arcana', 'portal-run', 'battle-mage-pool', 'spell-casting', 'spell-casting-run')] [string]$Playtest = 'statuses',
    [ValidateSet('Buff', 'Block')] [string]$EnemyActionFixture = 'Buff',
    [ValidateSet('TwoSlimes', 'GoblinTreant', 'ThreeEnemies', 'Run', 'Defeat')]
    [string]$MultiEnemyFixture = 'ThreeEnemies'
)

$ErrorActionPreference = 'Stop'
$engine = (Resolve-Path -LiteralPath $Godot).Path
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$fixtureScript = switch ($Playtest) {
    'modifiers' { 'network_modifiers_integration.gd' }
    'enemies' { 'network_enemy_patterns_integration.gd' }
    'enemy-actions' { 'network_enemy_actions_integration.gd' }
    'multi-enemy' { 'network_multi_enemy_integration.gd' }
    'ready' { 'network_ready_integration.gd' }
    'multi-enemy-run' { 'network_multi_enemy_run_integration.gd' }
    'major-arcana' { 'network_multi_enemy_run_integration.gd' }
    'portal-run' { 'network_multi_enemy_run_integration.gd' }
    'battle-mage-pool' { 'network_multi_enemy_run_integration.gd' }
    'spell-casting' { 'network_spell_casting_integration.gd' }
    'spell-casting-run' { 'network_spell_casting_integration.gd' }
    default { 'network_status_integration.gd' }
}
$logFolder = Join-Path $env:TEMP ("arcaeme-network-$Playtest-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $logFolder | Out-Null

function Start-Participant([int]$Port, [int]$Size, [int]$Seat, [string]$ReleasePath) {
    $prefix = Join-Path $logFolder "$Port-size$Size-seat$Seat"
    $arguments = @()
    if (-not $Native) { $arguments += '--headless' }
    $arguments += @('--path', ('"' + $project + '"'), '--log-file', ('"' + $prefix + '.log"'),
        '--script', "res://tests/$fixtureScript", '--', $Port, $Size, $Seat,
        ('"' + $ReleasePath + '"'))
    if ($Playtest -eq 'enemy-actions') { $arguments += $EnemyActionFixture }
    if ($Playtest -eq 'multi-enemy') { $arguments += $MultiEnemyFixture }
    if ($Playtest -eq 'major-arcana') { $arguments += 'MajorArcana' }
    if ($Playtest -eq 'portal-run') { $arguments += 'Portals' }
    if ($Playtest -eq 'battle-mage-pool') { $arguments += 'BattleMagePool' }
    if ($Playtest -eq 'spell-casting-run') { $arguments += 'ShortRun' }
    $process = Start-Process -FilePath $engine -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$prefix.stdout" -RedirectStandardError "$prefix.stderr"
    return @{ Process = $process; Output = "$prefix.stdout"; Errors = "$prefix.stderr" }
}

function Wait-Marker($Participant, [string]$Pattern) {
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
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

function Test-Party([int]$Size, [int]$Port) {
    $participants = @()
    $releasePath = Join-Path $logFolder "$Port-size$Size.release"
    try {
        for ($seat = 1; $seat -le $Size; $seat++) {
            $participant = Start-Participant $Port $Size $seat $releasePath
            $participants += $participant
            $null = Wait-Marker $participant "^SEAT_READY $seat$"
        }
        $baseline = Wait-Marker $participants[0] '^RESULT '
        foreach ($participant in ($participants | Select-Object -Skip 1)) {
            if ((Wait-Marker $participant '^RESULT ') -ne $baseline) {
                throw "Public snapshots disagreed for the $Size-player $Playtest encounter. Logs in $logFolder."
            }
        }
        if ($Playtest -eq 'battle-mage-pool') {
            $participantLogs = @($participants | ForEach-Object { $_.Output })
            $takes = 0
            $plays = 0
            foreach ($participant in $participants) {
                $summary = Wait-Marker $participant '^EXPANDED_CARDS \d+ \d+$'
                $counts = $summary.Split(' ')
                $takes += [int]$counts[1]
                $plays += [int]$counts[2]
            }
            if ($takes -lt 1 -or $plays -lt 1) {
                throw "No new Battle Mage card was acquired and played for $Size seats. Logs in $logFolder."
            }
            $firstOffers = @(Select-String -LiteralPath $participantLogs -Pattern '^REWARD_VIEW 1 ' |
                ForEach-Object { $_.Line } | Sort-Object -Unique)
            $secondOffers = @(Select-String -LiteralPath $participantLogs -Pattern '^REWARD_VIEW 2 ' |
                ForEach-Object { $_.Line } | Sort-Object -Unique)
            if ($firstOffers.Count -lt 2 -and $secondOffers.Count -lt 2) {
                throw "No distinct seat-specific reward offers observed for $Size seats. Logs in $logFolder."
            }
        }
        if ($Playtest -eq 'multi-enemy' -and $MultiEnemyFixture -ne 'Defeat') {
            $participantLogs = @($participants | ForEach-Object { $_.Output })
            foreach ($probe in @('UNKNOWN', 'DEAD')) {
                if (-not (Select-String -LiteralPath $participantLogs -Pattern "^PROBE $probe$" -Quiet)) {
                    throw "No $probe target rejection observed for $Size seats. Logs in $logFolder."
                }
            }
        }
        New-Item -ItemType File -Path $releasePath | Out-Null
        foreach ($participant in $participants) {
            if (-not $participant.Process.WaitForExit(5000)) {
                throw "Godot did not exit for $($participant.Output). Logs in $logFolder."
            }
            $errors = Get-Content -LiteralPath $participant.Errors
            if ($participant.Process.ExitCode -ne 0 -or ($errors -match '^SCRIPT ERROR:')) {
                throw (@("Godot failed. Logs in $logFolder.") + $errors -join "`n")
            }
        }
        $mode = if ($Native) { 'native' } else { 'headless' }
        $poolSummary = if ($Playtest -eq 'battle-mage-pool') { " · $takes new cards taken · $plays plays" } else { '' }
        Write-Output ("$Size-player $Playtest ($mode) passed · " + $baseline.Substring(7) + $poolSummary)
    } finally {
        foreach ($participant in $participants) {
            if (-not $participant.Process.HasExited) {
                Stop-Process -Id $participant.Process.Id -ErrorAction SilentlyContinue
            }
        }
    }
}

try {
    $port = $BasePort
    foreach ($size in $PartySizes) {
        Test-Party $size $port
        $port++
    }
} finally {
    Write-Output "Process logs are in $logFolder"
}
