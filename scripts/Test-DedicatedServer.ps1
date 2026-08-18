<#
.SYNOPSIS
    Boots the server payload in a throwaway copy and checks it reaches "Done" without errors.

.DESCRIPTION
    Nothing here touches the live server; it runs entirely from a temporary directory on ports
    that do not clash with the real one.

    By default the server is stopped automatically once it finishes loading, so the script can be
    run unattended. Pass -Interactive to keep it up and drive the console yourself instead - that
    used to be the only mode, and running it non-interactively simply hung forever.
#>
param(
    [int] $MinecraftPort = 29150,
    [int] $VoicePort = 29151,
    [switch] $Interactive,
    [int] $BootTimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PackVersion.ps1')

# The server keeps latest.log open while it runs, so a plain read fails with a sharing violation.
function Read-SharedText([string] $path) {
    $stream = [IO.FileStream]::new(
        $path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseRoot = Get-ReleaseRoot $repoRoot
$sourceRoot = Join-Path $releaseRoot '3. modpack\server'
$launcher = Join-Path $releaseRoot '4. server\1. self-host\support\runtime\fabric-server-launch.jar'
$javaPath = 'C:\Users\nizar\AppData\Roaming\PrismLauncher\java\java-runtime-delta\bin\java.exe'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $tempBase ('nbidal18-413-server-smoke-' + [guid]::NewGuid().ToString('N'))

foreach ($required in @($sourceRoot, $launcher, $javaPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Dedicated-server smoke-test input is missing: $required"
    }
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $sourceRoot -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $testRoot -Recurse -Force
    }
    Copy-Item -LiteralPath $launcher -Destination (Join-Path $testRoot 'fabric-server-launch.jar')

    $voicePath = Join-Path $testRoot 'config\voicechat\voicechat-server.properties'
    $voiceText = [IO.File]::ReadAllText($voicePath).Replace('port=27051', "port=$VoicePort")
    [IO.File]::WriteAllText($voicePath, $voiceText)
    $propertiesPath = Join-Path $testRoot 'server.properties'
    $propertiesText = [IO.File]::ReadAllText($propertiesPath).Replace(
        'server-port=27050', "server-port=$MinecraftPort")
    # Server Pause sleeps the server thread once nobody is connected, and a paused server does not
    # process the console 'stop' this script sends. Nothing here ever has a player, so turn it off
    # in the throwaway copy; the live server keeps its own setting.
    $propertiesText = [regex]::Replace(
        $propertiesText, '(?m)^pause-when-empty-seconds=.*$', 'pause-when-empty-seconds=0')
    [IO.File]::WriteAllText($propertiesPath, $propertiesText)

    Push-Location $testRoot
    try {
        $serverJar = Join-Path $testRoot 'fabric-server-launch.jar'
        if ($Interactive) {
            & $javaPath -Xms1G -Xmx2G -jar $serverJar nogui
            if ($LASTEXITCODE -ne 0) {
                throw "Dedicated-server smoke test exited with code $LASTEXITCODE"
            }
        }
        else {
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $javaPath
            $startInfo.Arguments = "-Xms1G -Xmx2G -jar `"$serverJar`" nogui"
            $startInfo.WorkingDirectory = $testRoot
            $startInfo.UseShellExecute = $false
            $server = [Diagnostics.Process]::Start($startInfo)
            $logPath = Join-Path $testRoot 'logs\latest.log'
            try {
                # Watch the log rather than stdout, which the process object consumes.
                $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
                $booted = $false
                while ((Get-Date) -lt $deadline -and -not $server.HasExited) {
                    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                        if ((Read-SharedText $logPath) -match
                                '(?m)^\[[^\]]+\] \[Server thread/INFO\]: Done \(') {
                            $booted = $true
                            break
                        }
                    }
                    Start-Sleep -Milliseconds 500
                }
                if (-not $booted) {
                    throw ("The dedicated server never finished loading within " +
                           "$BootTimeoutSeconds seconds. Log: $logPath")
                }
            }
            finally {
                # Killed rather than stopped through the console: the Fabric launcher does not
                # forward redirected stdin, so a 'stop' command is never read. There is nothing to
                # lose - the world is a throwaway in the temp directory this script deletes next.
                if (-not $server.HasExited) {
                    $server.Kill()
                    $server.WaitForExit(30000) | Out-Null
                }
                $server.Dispose()
            }

            # Data-fixer notices and the two empty Moonlight registries are normal on this mod set.
            # Anything else in the log is a real regression, so surface it rather than passing.
            $unexpected = @(
                (Read-SharedText $logPath) -split "`r?`n" |
                    Where-Object { $_ -match '/ERROR\]' } |
                    Where-Object { $_ -notmatch 'No data fixer registered for' } |
                    Where-Object { $_ -notmatch "Registry 'moonlight:[a-z_]+' was empty after loading" }
            )
            if ($unexpected.Count -ne 0) {
                throw ("The dedicated server logged unexpected errors:`n" +
                       (($unexpected | Select-Object -First 10) -join "`n"))
            }
            Write-Host 'Dedicated-server smoke test passed.' -ForegroundColor Green
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTestRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
