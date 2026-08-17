param(
    [int] $Port = 18088
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '..\nbidal18 v4.1.3-packwiz'))
$zipPath = Join-Path $releaseRoot '1. setup\nbidal18-client-4.1.3-packwiz.zip'
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

function Get-Sha256([string] $path) {
    $stream = [IO.File]::OpenRead($path)
    try {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        }
        finally { $algorithm.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Invoke-Sync([string] $minecraftRoot) {
    Remove-Item Env:INST_JAVA -ErrorAction SilentlyContinue
    $env:INST_MC_DIR = $minecraftRoot
    $env:NBIDAL18_PACK_URL = "http://127.0.0.1:$Port/pack.toml"
    $env:NBIDAL18_MANIFEST_URL = "http://127.0.0.1:$Port/sync-manifest.json"
    $env:NBIDAL18_HEADLESS_TEST = '1'
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $syncOutput = & $javaPath -jar (Join-Path $minecraftRoot 'nbidal18-packwiz-sync.jar') 2>&1
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
    $instanceConfig = [IO.File]::ReadAllText((Join-Path $onlineRoot 'instance.cfg'))
    Assert-True ($instanceConfig.Contains('PreLaunchCommand="$INST_JAVA" -jar nbidal18-packwiz-sync.jar')) 'The Prism command is not cross-platform.'
    Assert-True (-not $instanceConfig.Contains('powershell')) 'The Prism command still depends on Windows PowerShell.'
    Assert-True ((Invoke-Sync $minecraft) -eq 0) 'First online installation failed.'
    Assert-True ((Get-ChildItem -LiteralPath (Join-Path $minecraft 'mods') -File -Filter '*.jar').Count -eq 244) 'First install did not produce 244 mod JARs.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\better-compatability-checker-fabric-21.1.8.jar')) 'BCC was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-integrity-helper-1.0.0+1.21.1.jar')) 'The integrity helper was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-client-tweaks-1.1.0+1.21.1.jar')) 'The Jobs+ plaque-enabled client tweaks were not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-jobs-chat-suppressor-1.0.0+1.21.1.jar')) 'The Jobs+ compatibility helper was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\polytone-1.21-3.12.0-fabric.jar')) 'Nature X Polytone support was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'resourcepacks\Fancy Crops v1.3.zip')) 'Fancy Crops was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'resourcepacks\Nature X - 12.2 [1.21.1].zip')) 'Nature X was not installed.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $minecraft 'resourcepacks') -File -Filter '*.zip').Count -eq 19) 'First install did not produce 19 resource packs.'
    $optionsText = Get-Content -LiteralPath (Join-Path $minecraft 'options.txt') -Raw
    $natureIndex = $optionsText.IndexOf('file/Nature X - 12.2 [1.21.1].zip', [StringComparison]::Ordinal)
    $fancyIndex = $optionsText.IndexOf('file/Fancy Crops v1.3.zip', [StringComparison]::Ordinal)
    Assert-True ($natureIndex -ge 0 -and $fancyIndex -gt $natureIndex) 'Nature X and Fancy Crops are not enabled in the intended priority order.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-jobs-chat-suppressor-1.1.0+1.21.1.jar'))) 'The reset-enabled Jobs+ helper was still installed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-client-tweaks-1.0.0+1.21.1.jar'))) 'The retired client-tweaks artifact was still installed.'
    $jobsConfigText = Get-Content -LiteralPath (Join-Path $minecraft 'config\jobsplus-common.yaml') -Raw
    Assert-True ($jobsConfigText -match '(?m)^\s*show_xp_in_action_bar:\s*false\s*$') 'Jobs+ XP action-bar messages remain enabled.'
    Assert-True ($jobsConfigText -match '(?m)^\s*broadcast_level_up_messages:\s*false\s*$') 'Jobs+ chat level-up broadcasts remain enabled.'
    Assert-True ($jobsConfigText -match '(?m)^\s*amount_of_free_jobs:\s*1\s*$' -and
            $jobsConfigText -match '(?m)^\s*max_jobs:\s*1\s*$') 'Jobs+ is not limited to one active job.'
    Assert-True ($jobsConfigText -match '(?m)^\s*xp_multiplier:\s*0\.25\s*$' -and
            $jobsConfigText -match '(?m)^\s*use_decimal_values_for_xp:\s*true\s*$') 'Jobs+ is not using quarter-speed fractional progression.'
    $jadePlugins = Get-Content -LiteralPath (Join-Path $minecraft 'config\jade\plugins.json') -Raw | ConvertFrom-Json
    Assert-True ($jadePlugins.minecraft.entity_health -eq $false) 'Jade entity health remains enabled in the client.'

    $manifest = Get-Content -LiteralPath (Join-Path $sitePath 'sync-manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($manifest.packVersion -eq '4.1.3-packwiz') 'The generated manifest has the wrong pack version.'
    $expectedPreserved = @(
        'config/autohud.json5',
        'config/voicechat/voicechat-client.properties',
        'config/voicechat/category-volumes.properties',
        'config/voicechat/player-volumes.properties',
        'config/voicechat/username-cache.json',
        'config/iris.properties',
        'shaderpacks/ComplementaryUnbound_r5.8.1.zip.txt',
        'shaderpacks/MakeUp-UltraFast-9.5d.zip.txt',
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
    Assert-True (@($manifest.propertyRules).Count -eq 1) 'The protected shader-property rule is missing.'
    Assert-True ($manifest.propertyRules[0].path -eq 'shaderpacks/ComplementaryUnbound_r5.8.1.zip.txt' -and
            $manifest.propertyRules[0].key -eq 'GLOWING_ORE_MASTER' -and
            $manifest.propertyRules[0].value -eq '0') 'The glowing-ore protection rule is wrong.'
    $manifestDigest = Get-Sha256 (Join-Path $sitePath 'sync-manifest.json')
    foreach ($policyPath in @(
        (Join-Path $releaseRoot '3. modpack\server\config\nbidal18-integrity.properties'),
        (Join-Path $releaseRoot '4. server\2. online-hosting\config\nbidal18-integrity.properties')
    )) {
        $policy = Get-Content -LiteralPath $policyPath -Raw
        Assert-True ($policy -match '(?m)^require-helper=true$') "The helper requirement is not enabled in $policyPath"
        Assert-True ($policy -match "(?m)^expected-manifest-sha256=$manifestDigest$") "Manifest digest mismatch in $policyPath"
    }
    foreach ($bccPath in @(
        (Join-Path $releaseRoot '3. modpack\server\config\bcc-common.toml'),
        (Join-Path $releaseRoot '4. server\2. online-hosting\config\bcc-common.toml')
    )) {
        $bcc = Get-Content -LiteralPath $bccPath -Raw
        Assert-True ($bcc -match '(?m)^\s*modpackVersion\s*=\s*"v4\.1\.3-packwiz"\s*$') "The v4.1.3 BCC requirement is not enabled in $bccPath"
    }

    $extraMod = Join-Path $minecraft 'mods\player-added-extra-mod.jar'
    [IO.File]::WriteAllText($extraMod, 'not an official mod')
    $extraResourcePack = Join-Path $minecraft 'resourcepacks\xray-test.zip'
    [IO.File]::WriteAllText($extraResourcePack, 'not an official resource pack')
    $preservedConfig = Join-Path $minecraft 'config\autohud.json5'
    [IO.File]::WriteAllText($preservedConfig, 'player customized Auto HUD')
    $controllerConfig = Join-Path $minecraft 'config\controlify.json'
    [IO.File]::WriteAllText($controllerConfig, '{"player":"controller preferences"}')
    $managedConfig = Join-Path $minecraft 'config\bcc-common.toml'
    [IO.File]::WriteAllText($managedConfig, 'player changed this managed config')
    $complementaryOptions = Join-Path $minecraft 'shaderpacks\ComplementaryUnbound_r5.8.1.zip.txt'
    [IO.File]::WriteAllText($complementaryOptions, "QUALITY=VERY_HIGH`nGLOWING_ORE_MASTER=2`n")
    $makeupOptions = Join-Path $minecraft 'shaderpacks\MakeUp-UltraFast-9.5d.zip.txt'
    [IO.File]::WriteAllText($makeupOptions, "QUALITY=LOW`nPLAYER_CUSTOMIZED=true`n")
    Assert-True ((Invoke-Sync $minecraft) -eq 0) 'Online repair run failed.'
    Assert-True (-not (Test-Path -LiteralPath $extraMod)) 'The extra mod remained loadable.'
    Assert-True (-not (Test-Path -LiteralPath $extraResourcePack)) 'The extra resource pack remained loadable.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $minecraft '.nbidal18-packwiz\removed-local-files') -Recurse -File | Where-Object Name -eq 'player-added-extra-mod.jar').Count -eq 1) 'The extra mod was not recoverably moved.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $minecraft '.nbidal18-packwiz\removed-local-files') -Recurse -File | Where-Object Name -eq 'xray-test.zip').Count -eq 1) 'The extra resource pack was not recoverably moved.'
    Assert-True ([IO.File]::ReadAllText($preservedConfig) -eq 'player customized Auto HUD') 'The player Auto HUD config was overwritten.'
    Assert-True (Test-Path -LiteralPath $controllerConfig -PathType Leaf) 'The generated controller config was removed.'
    $shaderOptionsText = [IO.File]::ReadAllText($complementaryOptions)
    Assert-True ($shaderOptionsText -match '(?m)^QUALITY=VERY_HIGH\r?$') 'A permitted shader-quality setting was overwritten.'
    Assert-True ($shaderOptionsText -match '(?m)^GLOWING_ORE_MASTER=0\r?$' -and
            $shaderOptionsText -notmatch '(?m)^GLOWING_ORE_MASTER=[12]\r?$') 'Glowing ores were not selectively disabled.'
    Assert-True ([IO.File]::ReadAllText($makeupOptions) -match '(?m)^PLAYER_CUSTOMIZED=true\r?$') 'MakeUp shader settings were overwritten.'
    $installedConfig = [Convert]::ToBase64String([IO.File]::ReadAllBytes($managedConfig))
    $officialConfig = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $sitePath 'config\bcc-common.toml')))
    Assert-True ($installedConfig -eq $officialConfig) 'The managed config was not restored.'

    Stop-Process -Id $server.Id -Force
    $server.WaitForExit()
    $server = $null
    [IO.File]::WriteAllText($complementaryOptions, "QUALITY=LOW`nGLOWING_ORE_MASTER=2`n")
    Assert-True ((Invoke-Sync $minecraft) -eq 0) 'A complete installed release did not start offline.'
    $offlineShaderOptions = [IO.File]::ReadAllText($complementaryOptions)
    Assert-True ($offlineShaderOptions -match '(?m)^QUALITY=LOW\r?$' -and
            $offlineShaderOptions -match '(?m)^GLOWING_ORE_MASTER=0\r?$') 'Offline fallback did not selectively repair glowing ores.'

    $offlineRoot = Join-Path $testRoot 'first-install-offline'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $offlineRoot
    Assert-True ((Invoke-Sync (Join-Path $offlineRoot 'minecraft')) -ne 0) 'An incomplete first install incorrectly started offline.'

    Write-Host 'PASS: v4.1.3 install, Jobs+ balance, hidden Jade mob health, enforced helper and BCC policy, preserved personal configs and shader quality, glowing-ore field repair, exact-match cleanup, managed-file repair, complete offline fallback, and incomplete offline blocking.'
    $testSucceeded = $true
    $global:LASTEXITCODE = 0
}
finally {
    Remove-Item Env:INST_MC_DIR,Env:NBIDAL18_PACK_URL,Env:NBIDAL18_MANIFEST_URL,Env:NBIDAL18_HEADLESS_TEST -ErrorAction SilentlyContinue
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
