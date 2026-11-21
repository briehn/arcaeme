param(
    [Parameter(Mandatory)] [string]$Godot,
    [string]$OutputRoot = (Join-Path $env:LOCALAPPDATA 'Arcaeme/builds')
)

$ErrorActionPreference = 'Stop'
$engineVersion = '4.7.2.stable.official.ed1daf0bf'
$templateVersion = '4.7.2.stable'
$releaseTemplateHash = 'D34D36F3BE1A6C49C56525AE86469B92E4F417DDF0B43CF00DD80C385C4B0562'
$godotExe = (Resolve-Path -LiteralPath $Godot).Path
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
if ($output.Equals($project, [StringComparison]::OrdinalIgnoreCase) -or
    $output.StartsWith($project + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose an output directory outside the repository.'
}

$templates = Join-Path $env:APPDATA "Godot/export_templates/$templateVersion"
$releaseTemplate = Join-Path $templates 'windows_release_x86_64.exe'
$versionFile = Join-Path $templates 'version.txt'
if (-not (Test-Path -LiteralPath $releaseTemplate -PathType Leaf) -or
    -not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
    throw "Missing official $templateVersion Windows x64 templates at $templates."
}
if ((Get-Content -LiteralPath $versionFile -Raw).Trim() -ne $templateVersion -or
    (Get-FileHash -LiteralPath $releaseTemplate -Algorithm SHA256).Hash -ne $releaseTemplateHash) {
    throw "Windows x64 release template does not match the pinned official $templateVersion build."
}

$projectText = Get-Content -LiteralPath (Join-Path $project 'project.godot') -Raw
if ($projectText -notmatch '(?m)^config/version="(?<version>[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+)"\r?$') {
    throw 'Set application/config/version to a version such as 0.1.0-alpha.23.'
}
$version = $Matches.version
$stem = "Arcaeme-$version-windows-x64"
$zip = Join-Path $output "$stem.zip"
if (Test-Path -LiteralPath $zip) {
    throw "The package already exists at $zip. Use another output directory or a new build version."
}
$work = Join-Path $output ("build-" + [Guid]::NewGuid().ToString('N'))
$package = Join-Path $work $stem
New-Item -ItemType Directory -Force -Path $package | Out-Null

function Invoke-CheckedGodot($Executable, $Arguments, $LogName) {
    $stdout = Join-Path $work "$LogName.out.log"
    $stderr = Join-Path $work "$LogName.err.log"
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $work -Wait -PassThru `
        -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if ($process.ExitCode -ne 0 -or (Select-String -LiteralPath $stdout,$stderr -Pattern '^\s*(SCRIPT ERROR|ERROR):' -Quiet)) {
        throw "$LogName failed (exit $($process.ExitCode)). See $stdout and $stderr."
    }
    return $stdout
}

$versionLog = Invoke-CheckedGodot $godotExe '--headless --version' 'toolchain'
if ((Get-Content -LiteralPath $versionLog -Raw).Trim() -ne $engineVersion) {
    throw "Expected Godot $engineVersion. See $versionLog."
}
$exe = Join-Path $package 'Arcaeme.exe'
$pack = Join-Path $package 'Arcaeme.pck'
$null = Invoke-CheckedGodot $godotExe "--headless --path `"$project`" --export-release `"Windows Alpha`" `"$exe`"" 'export'
foreach ($path in @($exe, $pack)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
        throw "The export did not produce $path."
    }
}
$windowsVersion = $version.Replace('-alpha.', '.')
$fileVersionInfo = (Get-Item -LiteralPath $exe).VersionInfo
if ($fileVersionInfo.FileVersion -ne $windowsVersion -or $fileVersionInfo.ProductVersion -ne $windowsVersion) {
    throw "The Windows Alpha preset must set both Windows versions to $windowsVersion."
}

$verifier = Join-Path $project 'tests/verify_windows_alpha_pack.gd'
$notices = Join-Path $package 'GODOT-NOTICES.txt'
$verificationLog = Invoke-CheckedGodot $godotExe (
    "--headless --path `"$package`" --main-pack `"$pack`" --script `"$verifier`" -- `"$notices`"") 'pack-verification'
if (-not (Select-String -LiteralPath $verificationLog -Pattern '^Windows alpha pack: \d+ checks, 0 failures\.$' -Quiet)) {
    throw "Pack verification did not finish. See $verificationLog."
}

$runtimeLog = Join-Path $work 'release-smoke.log'
$null = Invoke-CheckedGodot $exe "--headless --quit-after 30 --log-file `"$runtimeLog`"" 'release-smoke'
if (-not (Test-Path -LiteralPath $runtimeLog -PathType Leaf) -or
    -not (Select-String -LiteralPath $runtimeLog -SimpleMatch "Arcaeme $version | Godot $engineVersion" -Quiet) -or
    (Select-String -LiteralPath $runtimeLog -Pattern '^\s*(SCRIPT ERROR|ERROR):' -Quiet)) {
    throw "Release build did not report the expected game and engine versions. See $runtimeLog."
}

@"
Arcaeme $version | Windows x64

Extract the entire ZIP before opening Arcaeme.exe. Keep the files together.
Choose Start Battle Mage Short Run. Spell drawing is enabled.
Use Hold Left Click or Toggle Drawing (X) to trace the rune.
After victory, take or skip the card reward, then click a portal.
This package is for solo play. Network co-op is a localhost development test.

If something goes wrong, include the build ID, your Windows version, the steps to
reproduce it, and the log at %APPDATA%\Godot\app_userdata\Arcaeme\logs\godot.log.
Copy the log before relaunching so the relevant session is easy to find.

Godot: $engineVersion
"@ | Set-Content -LiteralPath (Join-Path $package 'START HERE.txt') -Encoding utf8

Get-ChildItem -LiteralPath $package -File | Sort-Object Name | ForEach-Object {
    "$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)"
} | Set-Content -LiteralPath (Join-Path $package 'SHA256SUMS.txt') -Encoding ascii

# Stable entry names, order, and timestamps allow fresh exports to have the same ZIP hash.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stagedZip = Join-Path $work "$stem.zip"
$archive = [IO.Compression.ZipFile]::Open($stagedZip, [IO.Compression.ZipArchiveMode]::Create)
$timestamp = [DateTimeOffset]::Parse('2000-01-01T00:00:00+00:00')
try {
    foreach ($file in (Get-ChildItem -LiteralPath $package -File | Sort-Object Name)) {
        $entry = $archive.CreateEntry("$stem/$($file.Name)", [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $timestamp
        $source = [IO.File]::OpenRead($file.FullName)
        try {
            $destination = $entry.Open()
            try { $source.CopyTo($destination) }
            finally { $destination.Dispose() }
        }
        finally { $source.Dispose() }
    }
}
finally {
    $archive.Dispose()
}
[IO.File]::Move($stagedZip, $zip)

Get-Content -LiteralPath $verificationLog -Tail 1
Write-Output "Package: $zip"
Write-Output "SHA-256: $((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash)"
Write-Output "Local unpacked build: $package"
