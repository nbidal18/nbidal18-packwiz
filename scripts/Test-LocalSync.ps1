param(
    [int] $Port = 18088
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '..\nbidal18 v4.1.3-packwiz'))
$zipPath = Join-Path $releaseRoot '1. setup\nbidal18-client.zip'
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
    Assert-True ($instanceConfig.Contains("name=nbidal18-client`n")) 'The Prism display name is not the stable client name.'
    Assert-True ($instanceConfig.Contains("ExportName=nbidal18-client`n")) 'The Prism export name is not the stable client name.'
    Assert-True (-not $instanceConfig.Contains('name=nbidal18-client-4.1.3-packwiz')) 'The Prism display name still contains a release version.'
    Assert-True ((Invoke-Sync $minecraft) -eq 0) 'First online installation failed.'
    Assert-True ((Get-ChildItem -LiteralPath (Join-Path $minecraft 'mods') -File -Filter '*.jar').Count -eq 244) 'First install did not produce 244 mod JARs.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\better-compatability-checker-fabric-21.1.8.jar')) 'BCC was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-integrity-helper-1.0.0+1.21.1.jar')) 'The integrity helper was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-client-tweaks-1.2.6+1.21.1.jar')) 'The chest-free Inmis OLED transition, dyed backpack rendering, corrected slots, grouped Trinkets offhand slots, and Jobs+ plaque-enabled client tweaks were not installed.'
    $installedInmisConfig = [IO.File]::ReadAllText((Join-Path $minecraft 'config\inmis.json'), [Text.Encoding]::UTF8)
    Assert-True (-not $installedInmisConfig.EndsWith("`n")) 'Inmis config must use AutoConfig''s stable no-final-newline serialization.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-jobs-chat-suppressor-1.0.0+1.21.1.jar')) 'The Jobs+ compatibility helper was not installed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $minecraft 'mods\polytone-1.21-3.12.0-fabric.jar'))) 'Retired Nature X Polytone support was still installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'mods\optigui-2.3.0-beta.9+1.21.jar')) 'Colourful Containers OLED OptiGUI support was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'resourcepacks\Fancy Crops v1.3.zip')) 'Fancy Crops was not installed.'
    Assert-True (Test-Path -LiteralPath (Join-Path $minecraft 'resourcepacks\Enhanced Grass V1_4.zip')) 'Enhanced Grass was not installed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $minecraft 'resourcepacks\Nature X - 12.2 [1.21.1].zip'))) 'Retired Nature X was still installed.'
    $installedResourcePacks = @(Get-ChildItem -LiteralPath (Join-Path $minecraft 'resourcepacks') -File -Filter '*.zip')
    Assert-True (@($installedResourcePacks | Where-Object { $_.Name -like '*OLED*Colourful Containers*.zip' }).Count -eq 1) 'Colourful Containers OLED was not installed exactly once.'
    Assert-True (@($installedResourcePacks | Where-Object { $_.Name -like '*OLED*Inmis Backpacks Addon*.zip' }).Count -eq 1) 'The Inmis OLED add-on was not installed exactly once.'
    Assert-True (@($installedResourcePacks | Where-Object { $_.Name -like '*Darkmode*Colourful Containers*.zip' }).Count -eq 0) 'The retired Colourful Containers Darkmode pack was still installed.'
    Assert-True (@($installedResourcePacks | Where-Object { $_.Name -like '*Modded*Containers*Dark*.zip' }).Count -eq 0) 'The retired Modded Containers Dark pack was still installed.'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $minecraft 'resourcepacks') -File -Filter '*.zip').Count -eq 19) 'First install did not produce 19 resource packs.'
    foreach ($managedUpdater in @(
        'nbidal18-packwiz-sync.next.jar',
        'nbidal18-packwiz-updater.next.jar',
        'packwiz-installer-bootstrap.next.jar',
        'packwiz-installer.next.jar',
        'prism/mmc-pack.json'
    )) {
        $installedUpdater = Join-Path $minecraft $managedUpdater
        $publishedUpdater = Join-Path $sitePath $managedUpdater
        Assert-True ((Get-Sha256 $installedUpdater) -eq (Get-Sha256 $publishedUpdater)) "Initial install did not stage $managedUpdater."
    }
    Assert-True ((Get-Sha256 (Join-Path $minecraft 'nbidal18-packwiz-sync.jar')) -eq
            (Get-Sha256 (Join-Path $sitePath 'nbidal18-packwiz-sync.next.jar'))) 'The installed stable supervisor does not match the published supervisor.'
    Assert-True ((Get-Sha256 (Join-Path $minecraft 'nbidal18-packwiz-updater.jar')) -eq
            (Get-Sha256 (Join-Path $sitePath 'nbidal18-packwiz-updater.next.jar'))) 'The installed update engine does not match the staged engine.'
    [IO.File]::WriteAllText((Join-Path $minecraft 'nbidal18-packwiz-updater.jar'), 'obsolete update engine')
    [IO.File]::WriteAllText((Join-Path $minecraft 'packwiz-installer-bootstrap.jar'), 'obsolete bootstrap')
    Assert-True ((Invoke-Sync $minecraft) -eq 0) 'The supervisor did not promote staged launch tools before allowing Minecraft to start.'
    Assert-True ((Get-Sha256 (Join-Path $minecraft 'nbidal18-packwiz-updater.jar')) -eq
            (Get-Sha256 (Join-Path $sitePath 'nbidal18-packwiz-updater.next.jar'))) 'The supervisor did not activate the staged update engine.'
    Assert-True ((Get-Sha256 (Join-Path $minecraft 'packwiz-installer-bootstrap.jar')) -eq
            (Get-Sha256 (Join-Path $sitePath 'packwiz-installer-bootstrap.next.jar'))) 'The supervisor did not activate the staged bootstrap.'
    $optionsText = Get-Content -LiteralPath (Join-Path $minecraft 'options.txt') -Raw
    Assert-True ($optionsText.Contains('file/Enhanced Grass V1_4.zip')) 'Enhanced Grass is not enabled in the default resource-pack list.'
    Assert-True ($optionsText.Contains('file/Fancy Crops v1.3.zip')) 'Fancy Crops is not enabled in the default resource-pack list.'
    Assert-True (-not $optionsText.Contains('file/Nature X - 12.2 [1.21.1].zip')) 'Retired Nature X remains enabled in the default resource-pack list.'
    $section = [char]0x00A7
    $oledIndex = $optionsText.IndexOf("file/${section}0${section}lOLED ${section}f${section}lColourful Containers${section}8.zip", [StringComparison]::Ordinal)
    $inmisOledIndex = $optionsText.IndexOf("file/${section}0${section}lOLED ${section}f${section}lInmis Backpacks Addon${section}8.zip", [StringComparison]::Ordinal)
    Assert-True ($oledIndex -ge 0 -and $inmisOledIndex -gt $oledIndex) 'The Inmis OLED add-on is not enabled above its Colourful Containers OLED base.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-jobs-chat-suppressor-1.1.0+1.21.1.jar'))) 'The reset-enabled Jobs+ helper was still installed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-client-tweaks-1.0.0+1.21.1.jar'))) 'The retired client-tweaks artifact was still installed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-client-tweaks-1.1.0+1.21.1.jar'))) 'The pre-Inmis-OLED client-tweaks artifact was still installed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-client-tweaks-1.2.0+1.21.1.jar'))) 'The detached-OLED-panel client-tweaks artifact was still installed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $minecraft 'mods\nbidal18-client-tweaks-1.2.1+1.21.1.jar'))) 'The chest-seamed Inmis OLED client-tweaks artifact was still installed.'
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
    Assert-True ($manifest.schema -eq 1) 'The generated manifest is not backward-compatible with installed updaters.'
    Assert-True (@($manifest.exactRoots).Count -eq 5 -and
            'config' -in @($manifest.exactRoots)) 'Pre-launch exact config repair is missing.'
    $expectedRuntimeMutable = @(
        'config/autohud.json5',
        'config/voicechat/voicechat-client.properties',
        'config/voicechat/category-volumes.properties',
        'config/voicechat/player-volumes.properties',
        'config/voicechat/username-cache.json',
        'config/iris.properties',
        'shaderpacks/ComplementaryUnbound_r5.8.1.zip.txt',
        'shaderpacks/MakeUp-UltraFast-9.5d.zip.txt',
        'config/fzzy_config/keybinds.toml',
        'config/controlify.json',
        'config/fabric/indigo-renderer.properties',
        'config/naturalist-server.properties',
        'config/crash_assistant',
        'config/jsonem.properties',
        'config/resourceful-config-web.json',
        'config/jade/usernamecache.json',
        'config/jei/ingredient-list-mod-sort-order.ini',
        'config/jei/jei-client.ini',
        'config/jei/recipe-category-sort-order.ini',
        'config/jei/world',
        'config/invmove/unrecognized.json',
        'config/spark/tmp'
    )
    Assert-True (@($manifest.runtimeMutableRoots).Count -eq $expectedRuntimeMutable.Count) 'The runtime exception list has the wrong size.'
    foreach ($runtimePath in $expectedRuntimeMutable) {
        Assert-True ($runtimePath -in @($manifest.runtimeMutableRoots)) "Missing runtime exception: $runtimePath"
    }
    Assert-True ('config' -notin @($manifest.runtimeMutableRoots)) 'The complete config directory is still runtime-mutable.'
    $managedConfigCount = @($manifest.files | Where-Object path -like 'config/*').Count
    Assert-True (@($manifest.normalizedTextFiles).Count -eq $managedConfigCount) 'Not every managed config has a cross-platform normalized text hash.'
    $expectedPreserved = @(
        'config/autohud.json5',
        'config/voicechat/voicechat-client.properties',
        'config/voicechat/category-volumes.properties',
        'config/voicechat/player-volumes.properties',
        'config/voicechat/username-cache.json',
        'config/iris.properties',
        'shaderpacks/ComplementaryUnbound_r5.8.1.zip.txt',
        'shaderpacks/MakeUp-UltraFast-9.5d.zip.txt',
        'config/fzzy_config/keybinds.toml',
        'config/controlify.json',
        'config/fabric/indigo-renderer.properties',
        'config/naturalist-server.properties',
        'config/crash_assistant/modlist.json',
        'config/jsonem.properties',
        'config/resourceful-config-web.json',
        'config/jade/usernamecache.json',
        'config/jei/ingredient-list-mod-sort-order.ini',
        'config/jei/jei-client.ini',
        'config/jei/recipe-category-sort-order.ini',
        'config/jei/world/server/nbidal18_modpack_9c729ef3/lookupHistory.json',
        'config/invmove/unrecognized.json',
        'config/spark/tmp/about.txt'
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
        (Join-Path $releaseRoot '4. server\2. online-hosting\config\nbidal18-integrity.properties'),
        (Join-Path $releaseRoot '4. server\4.1.3-transition-overlay\config\nbidal18-integrity.properties')
    )) {
        $policy = Get-Content -LiteralPath $policyPath -Raw
        Assert-True ($policy -match '(?m)^require-helper=true$') "The helper requirement is not enabled in $policyPath"
        Assert-True ($policy -match "(?m)^expected-manifest-sha256=$manifestDigest$") "Manifest digest mismatch in $policyPath"
        Assert-True ($policy -match '(?m)^accepted-manifest-sha256=.*9515a09d1ce3d751e69da097ff6f3aee9856de3662fa35a69b6422fb845f3b41') "The previous release digest is not accepted during rollout in $policyPath"
    }
    foreach ($bccPath in @(
        (Join-Path $releaseRoot '3. modpack\server\config\bcc-common.toml'),
        (Join-Path $releaseRoot '4. server\2. online-hosting\config\bcc-common.toml')
    )) {
        $bcc = Get-Content -LiteralPath $bccPath -Raw
        Assert-True ($bcc -match '(?m)^\s*modpackVersion\s*=\s*"v4\.1\.3-packwiz"\s*$') "The v4.1.3 BCC requirement is not enabled in $bccPath"
    }

    $optionsPath = Join-Path $minecraft 'options.txt'
    $legacyOptions = [IO.File]::ReadAllText($optionsPath)
    $legacyOptions = $legacyOptions.Replace('file/Enhanced Grass V1_4.zip', 'file/Nature X - 12.2 [1.21.1].zip')
    $legacyOptions = $legacyOptions.Replace(
        "file/${section}0${section}lOLED ${section}f${section}lColourful Containers${section}8.zip",
        "file/${section}8${section}lDarkmode ${section}f${section}lColourful Containers${section}8.zip")
    $legacyOptions = $legacyOptions.Replace(
        "file/${section}0${section}lOLED ${section}f${section}lInmis Backpacks Addon${section}8.zip",
        "file/${section}5${section}lModded ${section}f${section}lContainers ${section}8${section}lDark${section}8.zip")
    $legacyOptions = $legacyOptions.Replace(
        'resourcePacks:["vanilla"',
        'resourcePacks:["vanilla","file/Player Visual Choice.zip"')
    $legacyOptions = $legacyOptions.Replace(
        'incompatibleResourcePacks:[',
        "incompatibleResourcePacks:[`"file/${section}5${section}lModded ${section}f${section}lContainers ${section}8${section}lDark${section}8.zip`",")
    $legacyOptions += "nbidal18TestPersonalOption:true`r`n"
    [IO.File]::WriteAllText($optionsPath, $legacyOptions, [Text.UTF8Encoding]::new($false))

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
    $managedSodium = Join-Path $minecraft 'config\sodium-extra-options.json'
    [IO.File]::WriteAllText($managedSodium, '{"extra_settings":{"show_coords":true}}')
    $complementaryOptions = Join-Path $minecraft 'shaderpacks\ComplementaryUnbound_r5.8.1.zip.txt'
    [IO.File]::WriteAllText($complementaryOptions, "QUALITY=VERY_HIGH`nGLOWING_ORE_MASTER=2`n")
    $makeupOptions = Join-Path $minecraft 'shaderpacks\MakeUp-UltraFast-9.5d.zip.txt'
    [IO.File]::WriteAllText($makeupOptions, "QUALITY=LOW`nPLAYER_CUSTOMIZED=true`n")
    Assert-True ((Invoke-Sync $minecraft) -eq 0) 'Online repair run failed.'
    $migratedOptions = [IO.File]::ReadAllText($optionsPath)
    Assert-True ($migratedOptions.Contains('file/Enhanced Grass V1_4.zip')) 'An existing instance did not migrate Nature X to Enhanced Grass.'
    Assert-True (-not $migratedOptions.Contains('file/Nature X - 12.2 [1.21.1].zip')) 'An existing instance retained the retired Nature X entry.'
    $migratedOledIndex = $migratedOptions.IndexOf("file/${section}0${section}lOLED ${section}f${section}lColourful Containers${section}8.zip", [StringComparison]::Ordinal)
    $migratedInmisIndex = $migratedOptions.IndexOf("file/${section}0${section}lOLED ${section}f${section}lInmis Backpacks Addon${section}8.zip", [StringComparison]::Ordinal)
    Assert-True ($migratedOledIndex -ge 0 -and $migratedInmisIndex -gt $migratedOledIndex) 'An existing instance did not enable the OLED base and Inmis add-on in priority order.'
    Assert-True (-not $migratedOptions.Contains("file/${section}8${section}lDarkmode ${section}f${section}lColourful Containers${section}8.zip")) 'An existing instance retained the old Darkmode container pack entry.'
    Assert-True (-not $migratedOptions.Contains("file/${section}5${section}lModded ${section}f${section}lContainers ${section}8${section}lDark${section}8.zip")) 'An existing instance retained the old modded-container pack entry.'
    Assert-True ($migratedOptions.Contains('file/Player Visual Choice.zip')) 'The resource-pack migration removed an unrelated player pack preference.'
    Assert-True ($migratedOptions.Contains('nbidal18TestPersonalOption:true')) 'The resource-pack migration overwrote an unrelated personal option.'
    $optionsAfterFirstMigration = $migratedOptions
    Assert-True ((Invoke-Sync $minecraft) -eq 0) 'The idempotence update run failed.'
    Assert-True ([IO.File]::ReadAllText($optionsPath) -eq $optionsAfterFirstMigration) 'The options migration was not idempotent.'
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
    $installedSodium = [Convert]::ToBase64String([IO.File]::ReadAllBytes($managedSodium))
    $officialSodium = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $sitePath 'config\sodium-extra-options.json')))
    Assert-True ($installedSodium -eq $officialSodium) 'A gameplay-relevant Sodium config was not restored.'

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

    Write-Host 'PASS: version-neutral Prism naming, pre-launch supervisor promotion and validation, updater/bootstrap staging, existing-instance resource-pack migration, v4.1.3 install, Jobs+ balance, hidden Jade mob health, narrow runtime config exceptions, enforced helper and BCC policy, preserved personal configs and shader quality, glowing-ore field repair, exact-match cleanup, managed gameplay-config repair, complete offline fallback, and incomplete offline blocking.'
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
