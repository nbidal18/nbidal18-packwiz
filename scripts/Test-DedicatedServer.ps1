param(
    [int] $MinecraftPort = 29150,
    [int] $VoicePort = 29151
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '..\nbidal18 v4.2.0-packwiz'))
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
    [IO.File]::WriteAllText($propertiesPath, $propertiesText)

    Push-Location $testRoot
    try {
        & $javaPath -Xms1G -Xmx2G -jar (Join-Path $testRoot 'fabric-server-launch.jar') nogui
        if ($LASTEXITCODE -ne 0) {
            throw "Dedicated-server smoke test exited with code $LASTEXITCODE"
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
