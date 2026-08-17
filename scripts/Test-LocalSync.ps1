param(
    [int] $Port = 18088
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '..\nbidal18 v4.1.2-packwiz'))
$zipPath = Join-Path $releaseRoot '1. setup\nbidal18-client-4.1.2-packwiz.zip'
$sitePath = Join-Path $repoRoot 'site'
$packwizPath = Join-Path $releaseRoot '5. development\tools\packwiz-current\packwiz.exe'
$javaPath = 'C:\Users\nizar\AppData\Roaming\PrismLauncher\java\java-runtime-delta\bin\java.exe'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$testRoot = Join-Path $tempBase ('nbidal18-packwiz-test-' + [guid]::NewGuid().ToString('N'))
$server = $null
$testSucceeded = $false

function Assert-True([bool] $condition, [string] $message) {
    if (-not $condition) { throw $message }
}

function Invoke-Sync([string] $minecraftRoot) {
    $env:INST_JAVA = $javaPath
    $env:NBIDAL18_PACK_URL = "http://127.0.0.1:$Port/pack.toml"
    $env:NBIDAL18_MANIFEST_URL = "http://127.0.0.1:$Port/sync-manifest.json"
    $env:NBIDAL18_HEADLESS_TEST = '1'
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $syncOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $minecraftRoot 'nbidal18-packwiz-sync.ps1') 2>&1
    $syncExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorAction
    @($syncOutput | Select-Object -Last 12) | ForEach-Object { Write-Host $_ }
    return [int] $syncExitCode
}

try {
    Assert-True (Test-Path -LiteralPath $zipPath -PathType Leaf) "Missing Prism ZIP: $zipPath"
    Assert-True (Test-Path -LiteralPath $javaPath -PathType Leaf) "Missing Java runtime: $javaPath"
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $serverLog = Join-Path $testRoot 'http-server.log'
    $serverError = Join-Path $testRoot 'http-server-error.log'
    $serverArguments = "serve --basic --port $Port"
    $server = Start-Process -FilePath $packwizPath -ArgumentList $serverArguments -WorkingDirectory $sitePath -WindowStyle Hidden -PassThru -RedirectStandardOutput $serverLog -RedirectStandardError $serverError
    $serverReady = $false
    foreach ($attempt in 1..50) {
        if ($server.HasExited) {
            throw "Local HTTP server exited: $([IO.File]::ReadAllText($serverError))"
        }
        try {
            Invoke-WebRequest -Uri "http://127.0.0.1:$Port/pack.toml" -UseBasicParsing -TimeoutSec 1 | Out-Null
            $serverReady = $true
            break
        }
        catch { Start-Sleep -Milliseconds 100 }
    }
    Assert-True $serverReady 'Local HTTP server did not become ready.'

    $onlineRoot = Join-Path $testRoot 'online'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $onlineRoot
    $minecraft = Join-Path $onlineRoot 'minecraft'
    Assert-True ((Invoke-Sync $minecraft) -eq 0) 'First online installation failed.'
    Assert-True ((Get-ChildItem -LiteralPath (Join-Path $minecraft 'mods') -File -Filter '*.jar').Count -eq 241) 'First install did not produce 241 mod JARs.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\better-compatability-checker-fabric-21.1.8.jar')) 'BCC was not installed.'

    $manifest = Get-Content -LiteralPath (Join-Path $sitePath 'sync-manifest.json') -Raw | ConvertFrom-Json
    $expectedPreserved = @(
        'config/autohud.json5',
        'config/voicechat/voicechat-client.properties',
        'config/voicechat/category-volumes.properties',
        'config/voicechat/player-volumes.properties',
        'config/voicechat/username-cache.json',
        'config/iris.properties',
        'config/sodium-options.json',
        'config/sodium-extra-options.json',
        'config/sodium-extra.properties',
        'config/fzzy_config/keybinds.toml',
        'config/controlify.json'
    )
    Assert-True (@($manifest.localAllowed).Count -eq $expectedPreserved.Count) 'The preserved-config allow-list has the wrong size.'
    foreach ($preservedPath in $expectedPreserved) {
        Assert-True ($preservedPath -in @($manifest.localAllowed)) "Missing preserved-config rule: $preservedPath"
    }

    $extraMod = Join-Path $minecraft 'mods\player-added-extra-mod.jar'
    [IO.File]::WriteAllText($extraMod, 'not an official mod')
    $preservedConfig = Join-Path $minecraft 'config\autohud.json5'
    [IO.File]::WriteAllText($preservedConfig, 'player customized Auto HUD')
    $controllerConfig = Join-Path $minecraft 'config\controlify.json'
    [IO.File]::WriteAllText($controllerConfig, '{"player":"controller preferences"}')
    $managedConfig = Join-Path $minecraft 'config\bcc-common.toml'
    [IO.File]::WriteAllText($managedConfig, 'player changed this managed config')
    Assert-True ((Invoke-Sync $minecraft) -eq 0) 'Online repair run failed.'
    Assert-True (-not (Test-Path -LiteralPath $extraMod)) 'The extra mod remained loadable.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $minecraft '.nbidal18-packwiz\removed-local-files') -Recurse -File | Where-Object Name -eq 'player-added-extra-mod.jar').Count -eq 1) 'The extra mod was not recoverably moved.'
    Assert-True ([IO.File]::ReadAllText($preservedConfig) -eq 'player customized Auto HUD') 'The player Auto HUD config was overwritten.'
    Assert-True (Test-Path -LiteralPath $controllerConfig -PathType Leaf) 'The generated controller config was removed.'
    $installedConfig = [Convert]::ToBase64String([IO.File]::ReadAllBytes($managedConfig))
    $officialConfig = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $sitePath 'config\bcc-common.toml')))
    Assert-True ($installedConfig -eq $officialConfig) 'The managed config was not restored.'

    Stop-Process -Id $server.Id -Force
    $server.WaitForExit()
    $server = $null
    Assert-True ((Invoke-Sync $minecraft) -eq 0) 'A complete installed release did not start offline.'

    $offlineRoot = Join-Path $testRoot 'first-install-offline'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $offlineRoot
    Assert-True ((Invoke-Sync (Join-Path $offlineRoot 'minecraft')) -ne 0) 'An incomplete first install incorrectly started offline.'

    Write-Host 'PASS: first install, preserved personal configs, exact-match cleanup, managed-file repair, complete offline fallback, and incomplete offline blocking.'
    $testSucceeded = $true
    $global:LASTEXITCODE = 0
}
finally {
    Remove-Item Env:NBIDAL18_PACK_URL,Env:NBIDAL18_MANIFEST_URL,Env:NBIDAL18_HEADLESS_TEST -ErrorAction SilentlyContinue
    if ($null -ne $server -and -not $server.HasExited) {
        Stop-Process -Id $server.Id -Force
        $server.WaitForExit()
    }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if ($testSucceeded -and $resolvedTestRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
    elseif (-not $testSucceeded) {
        Write-Warning "Failed test files were preserved at $resolvedTestRoot"
    }
}
