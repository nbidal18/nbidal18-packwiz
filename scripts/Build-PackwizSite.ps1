param(
    [string] $ReleaseRoot,
    [string] $SitePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PackVersion.ps1')
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = Get-ReleaseRoot $repoRoot
}
else {
    $ReleaseRoot = [IO.Path]::GetFullPath($ReleaseRoot)
    Assert-ReleaseRootMatchesVersion $repoRoot $ReleaseRoot
}
if ([string]::IsNullOrWhiteSpace($SitePath)) {
    $SitePath = Join-Path $repoRoot 'site'
}
elseif (-not [IO.Path]::IsPathRooted($SitePath)) {
    $SitePath = Join-Path $repoRoot $SitePath
}
$SitePath = [IO.Path]::GetFullPath($SitePath)

$clientRoot = Join-Path $ReleaseRoot '3. modpack\client'
$packwizPath = Join-Path $ReleaseRoot '5. modpack source\auto-updater tools\packwiz.exe'
$syncSupervisorPath = Join-Path $repoRoot 'client\nbidal18-packwiz-sync.jar'
$updateEnginePath = Join-Path $repoRoot 'client\nbidal18-packwiz-updater.jar'
$bootstrapPath = Join-Path $ReleaseRoot '5. modpack source\auto-updater tools\packwiz-installer-bootstrap.jar'
$installerPath = Join-Path $ReleaseRoot '5. modpack source\auto-updater tools\packwiz-installer.jar'
$prismPackTemplate = Join-Path $repoRoot 'templates\mmc-pack.json'
$landingPage = Join-Path $repoRoot 'templates\index.html'
$stagePath = Join-Path $repoRoot ('.site-staging-' + [guid]::NewGuid().ToString('N'))
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$packVersion = Get-PackVersion $repoRoot
# The version is declared once, in PACK-VERSION.txt. It used to be written out by hand in about
# twenty-five places, and missing one of them at the 4.1.3 cut locked every player out at login.
# Fail the build if any script spells the current version out again, so it cannot silently regrow.
$versionLiterals = @(
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File |
        Where-Object Name -ne 'PackVersion.ps1' |
        ForEach-Object {
            $script = $_
            [IO.File]::ReadAllLines($script.FullName, [Text.Encoding]::UTF8) |
                Where-Object { $_ -like "*$packVersion*" -and $_.TrimStart() -notlike '#*' } |
                ForEach-Object { "$($script.Name): $($_.Trim())" }
        }
)
if ($versionLiterals.Count -ne 0) {
    throw ("These scripts hardcode the pack version instead of reading PACK-VERSION.txt:`n" +
           ($versionLiterals -join "`n"))
}

foreach ($required in @(
    $clientRoot,
    (Join-Path $clientRoot 'mods'),
    (Join-Path $clientRoot 'config'),
    (Join-Path $clientRoot 'datapacks'),
    (Join-Path $clientRoot 'resourcepacks'),
    (Join-Path $clientRoot 'shaderpacks'),
    $packwizPath,
    $syncSupervisorPath,
    $updateEnginePath,
    $bootstrapPath,
    $installerPath,
    $prismPackTemplate,
    $landingPage
)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required Packwiz source is missing: $required"
    }
}

function Write-Utf8([string] $path, [string] $text) {
    $parent = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($path, $text.Replace("`r`n", "`n"), $utf8NoBom)
}

function Get-RelativePath([string] $basePath, [string] $fullPath) {
    $base = [IO.Path]::GetFullPath($basePath).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($fullPath)
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its source root: $full"
    }
    return $full.Substring($base.Length).Replace('\', '/')
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

function Get-NormalizedTextSha256([string] $path) {
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    $text = $strictUtf8.GetString([IO.File]::ReadAllBytes($path))
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

# Which published files the integrity system enforces is decided by an explicit classification
# rather than by "everything under config/ unless someone remembered to allowlist it". See
# scripts\config-classification.json for the classes and the reasoning behind each entry.
$classificationPath = Join-Path $PSScriptRoot 'config-classification.json'
if (-not (Test-Path -LiteralPath $classificationPath -PathType Leaf)) {
    throw "The config classification is missing: $classificationPath"
}
$classification = [IO.File]::ReadAllText($classificationPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$classificationRules = @($classification.rules + $classification.outsideConfig)
foreach ($rule in $classificationRules) {
    if ($rule.class -notin @('gameplay', 'support', 'player')) {
        throw "Unknown classification '$($rule.class)' for $($rule.match)"
    }
    if ([string]::IsNullOrWhiteSpace($rule.reason)) {
        throw "The classification for $($rule.match) has no reason recorded."
    }
}
$duplicateMatches = @($classificationRules | Group-Object match | Where-Object Count -gt 1)
if ($duplicateMatches.Count -ne 0) {
    throw "The config classification lists a path twice: $($duplicateMatches[0].Name)"
}

# Longest matching rule wins; a rule ending in / matches the whole subtree.
function Resolve-ConfigClass([string] $relative) {
    $best = $null
    foreach ($rule in $classificationRules) {
        $matched = if ($rule.match.EndsWith('/')) {
            $relative.StartsWith($rule.match, [StringComparison]::Ordinal)
        }
        else {
            $relative -ceq $rule.match
        }
        if ($matched -and ($null -eq $best -or $rule.match.Length -gt $best.match.Length)) {
            $best = $rule
        }
    }
    return $best
}

$playerMutablePaths = @(
    $classificationRules | Where-Object { $_.class -eq 'player' } | ForEach-Object { $_.match }
)
if ($playerMutablePaths.Count -eq 0) {
    throw 'The config classification defines no player-owned paths.'
}

# support-class files are library, performance, rendering, UI, input or diagnostic state. They are
# not in-game content, so the runtime helper ignores them: editing one can no longer refuse a
# login. The pre-launch updater still restores the published copy, so content stays deterministic.
$supportPaths = @(
    $classificationRules | Where-Object { $_.class -eq 'support' } |
        ForEach-Object { $_.match.TrimEnd('/') }
)

# Gameplay config stays fully enforced, including the files their own mod rewrites at startup.
# Those rewrites are byte-identical - the mod serialises exactly what we published - so enforcing
# them costs nothing and keeps the second line of defence for a client that skips the updater
# entirely. Exempting them would have traded real protection for a hypothetical.
#
# modWritesAtRuntime is therefore a watch list, not an exemption: it records that the mod rewrites
# the file, so the file must be published in the exact form the mod writes back. If a mod update
# ever changes that serialisation, Test-ConfigStability.ps1 catches the drift on a played instance
# before release, rather than every player discovering it as a login refusal.
$modWrittenPaths = @(
    $classificationRules |
        Where-Object {
            $_.class -eq 'gameplay' -and
            ($_.PSObject.Properties.Name -contains 'modWritesAtRuntime') -and
            $_.modWritesAtRuntime
        } |
        ForEach-Object { $_.match.TrimEnd('/') }
)
if ($modWrittenPaths.Count -eq 0) {
    throw 'No gameplay config is marked modWritesAtRuntime; the classification did not load.'
}
$runtimeMutablePaths = @($playerMutablePaths + $supportPaths)

# Preserved in the Packwiz index: never overwritten once installed. Player-owned settings, plus
# the support files their own mod rewrites while Minecraft runs - without this the updater would
# quarantine and redownload those every single launch.
foreach ($rewritten in $classification.rewrittenAtRuntime) {
    $rewrittenRule = Resolve-ConfigClass $rewritten
    if ($null -eq $rewrittenRule -or $rewrittenRule.class -ne 'support') {
        throw "rewrittenAtRuntime lists a path that is not classified as support: $rewritten"
    }
}
$preservedConfigPaths = @($playerMutablePaths + $classification.rewrittenAtRuntime)

# Unmanaged extra files under these roots are tolerated instead of refusing the login. Config
# libraries create their own files during mod init, which the updater cannot delete permanently:
# it removes them, the game recreates them at startup, and the player is locked out for good.
$extraTolerantRoots = @($classification.extraTolerantRoots | ForEach-Object { $_.prefix })
if ($extraTolerantRoots.Count -eq 0) {
    throw 'The config classification defines no extra-tolerant roots.'
}

$excludedPatterns = @(
    'servers.dat',
    'config/sodium-fingerprint.json',
    'vinurl/downloads/*',
    '.nbidal18/*',
    'packwiz.json',
    'packwiz-installer.jar',
    'packwiz-installer-bootstrap.jar',
    'nbidal18-launch-guard.jar',
    'logs/*',
    'crash-reports/*',
    'saves/*',
    'screenshots/*',
    'local/*',
    'skin_overrides/*',
    'cape_overrides/*'
)

try {
    New-Item -ItemType Directory -Path $stagePath | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $clientRoot -Recurse -File -Force) {
        $relative = Get-RelativePath $clientRoot $file.FullName
        $excluded = $false
        foreach ($pattern in $excludedPatterns) {
            if ($relative -like $pattern) {
                $excluded = $true
                break
            }
        }
        if ($excluded) { continue }
        $destination = Join-Path $stagePath $relative.Replace('/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }

    # AutoConfig serializes Inmis without a trailing line break at game startup.
    # Publish that exact stable representation so the integrity helper does not
    # mistake the serializer's one-byte rewrite for a gameplay config change.
    $stagedInmisConfig = Join-Path $stagePath 'config\inmis.json'
    $stagedInmisText = [IO.File]::ReadAllText($stagedInmisConfig, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText(
        $stagedInmisConfig,
        $stagedInmisText.TrimEnd("`r", "`n"),
        $utf8NoBom
    )

    # Packwiz downloads staged launch tools. Once the old updater process has exited, the client
    # helper atomically promotes them over the live copies; Windows will not replace a running JAR.
    Copy-Item -LiteralPath $syncSupervisorPath -Destination (Join-Path $stagePath 'nbidal18-packwiz-sync.next.jar')
    Copy-Item -LiteralPath $updateEnginePath -Destination (Join-Path $stagePath 'nbidal18-packwiz-updater.next.jar')
    Copy-Item -LiteralPath $bootstrapPath -Destination (Join-Path $stagePath 'packwiz-installer-bootstrap.next.jar')
    Copy-Item -LiteralPath $installerPath -Destination (Join-Path $stagePath 'packwiz-installer.next.jar')
    New-Item -ItemType Directory -Path (Join-Path $stagePath 'prism') -Force | Out-Null
    Copy-Item -LiteralPath $prismPackTemplate -Destination (Join-Path $stagePath 'prism\mmc-pack.json')

    Write-Utf8 (Join-Path $stagePath '.packwizignore') @'
/.nojekyll
/.packwizignore
/index.html
/nbidal18-client.zip
/SHA256SUMS.txt
/sync-manifest.json
/pack.toml
/index.toml
'@
    New-Item -ItemType File -Path (Join-Path $stagePath '.nojekyll') | Out-Null
    Copy-Item -LiteralPath $landingPage -Destination (Join-Path $stagePath 'index.html')

    Write-Utf8 (Join-Path $stagePath 'pack.toml') (@'
name = "nbidal18"
version = "__PACK_VERSION__"
description = "Fabric 1.21.1 adventure modpack with automatic Prism updates"
pack-format = "packwiz:1.1.0"

[index]
file = "index.toml"
hash-format = "sha256"
hash = "0000000000000000000000000000000000000000000000000000000000000000"

[versions]
fabric = "0.19.3"
minecraft = "1.21.1"
'@).Replace('__PACK_VERSION__', $packVersion)
    Write-Utf8 (Join-Path $stagePath 'index.toml') @'
hash-format = "sha256"
'@

    Push-Location $stagePath
    try {
        & $packwizPath refresh
        if ($LASTEXITCODE -ne 0) {
            throw "packwiz refresh failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }

    $indexPath = Join-Path $stagePath 'index.toml'
    $packPath = Join-Path $stagePath 'pack.toml'
    $indexText = [IO.File]::ReadAllText($indexPath, [Text.Encoding]::UTF8)
    foreach ($preservedPath in @($preservedConfigPaths | Where-Object {
        Test-Path -LiteralPath (Join-Path $stagePath $_) -PathType Leaf
    })) {
        $pattern = '(?ms)(^\[\[files\]\]\r?\nfile = "' + [regex]::Escape($preservedPath) + '"\r?\nhash = "[0-9a-fA-F]{64}")(\r?\n)'
        $match = [regex]::Match($indexText, $pattern)
        if (-not $match.Success) {
            throw "Preserved config is missing from the Packwiz index: $preservedPath"
        }
        $replacement = $match.Groups[1].Value + "`npreserve = true" + $match.Groups[2].Value
        $indexText = $indexText.Substring(0, $match.Index) + $replacement + $indexText.Substring($match.Index + $match.Length)
    }
    Write-Utf8 $indexPath $indexText

    $packText = [IO.File]::ReadAllText($packPath, [Text.Encoding]::UTF8)
    $indexHash = Get-Sha256 $indexPath
    $hashPattern = '(?m)^(hash = ")[0-9a-fA-F]{64}("\s*)$'
    $packText = [regex]::Replace($packText, $hashPattern, {
        param($match)
        $match.Groups[1].Value + $indexHash + $match.Groups[2].Value
    }, 1)
    Write-Utf8 $packPath $packText
    if ($packText -match 'hash = "0{64}"') {
        throw 'Packwiz did not refresh the index hash.'
    }
    if ($indexText -match '(?i)\.pw\.toml|modrinth|curseforge|https?://') {
        throw 'The Packwiz index contains external metadata or download URLs.'
    }

    $matches = [regex]::Matches(
        $indexText,
        '(?ms)^\[\[files\]\]\r?\nfile = "([^"]+)"\r?\nhash = "([0-9a-fA-F]{64})"'
    )
    if ($matches.Count -eq 0) {
        throw 'No direct files were found in the Packwiz index.'
    }
    $manifestFiles = [Collections.Generic.List[object]]::new()
    foreach ($match in $matches) {
        $manifestFiles.Add([ordered]@{
            path = $match.Groups[1].Value
            sha256 = $match.Groups[2].Value.ToLowerInvariant()
        })
    }
    # Every published config file must carry a deliberate classification. Adding a mod therefore
    # fails the build here instead of silently inheriting hash enforcement - or, worse, shipping a
    # config the mod rewrites at startup and locking every player out at login.
    $unclassified = @(
        $manifestFiles | Where-Object { $_.path -like 'config/*' } |
            Where-Object { $null -eq (Resolve-ConfigClass $_.path) } |
            ForEach-Object { $_.path }
    )
    if ($unclassified.Count -ne 0) {
        throw ("These published config files are not classified in scripts\config-classification.json: " +
               ($unclassified -join ', ') +
               ". Classify each as gameplay, support or player before releasing.")
    }
    # A rule that no longer matches anything is stale; it hides the fact that a mod was removed.
    # player-class paths and rewritten-at-runtime paths are exempt: several are never published at
    # all, they only exist so the updater leaves the copy the game creates on first run alone.
    $stale = @(
        $classificationRules | Where-Object { $_.match -like 'config/*' } |
            Where-Object { $_.class -ne 'player' } |
            Where-Object { $_.match -notin $classification.rewrittenAtRuntime } |
            Where-Object {
                $rule = $_
                $hit = $manifestFiles | Where-Object {
                    if ($rule.match.EndsWith('/')) {
                        $_.path.StartsWith($rule.match, [StringComparison]::Ordinal)
                    }
                    else { $_.path -ceq $rule.match }
                }
                @($hit).Count -eq 0
            } | ForEach-Object { $_.match }
    )
    if ($stale.Count -ne 0) {
        throw ("These classification rules match no published file and should be removed: " +
               ($stale -join ', '))
    }

    $normalizedTextFiles = [Collections.Generic.List[object]]::new()
    foreach ($managedFile in $manifestFiles) {
        if ($managedFile.path -notlike 'config/*') {
            continue
        }
        $normalizedTextFiles.Add([ordered]@{
            path = $managedFile.path
            sha256 = Get-NormalizedTextSha256 (Join-Path $stagePath $managedFile.path)
        })
    }
    if ($normalizedTextFiles.Count -eq 0) {
        throw 'No managed config files received cross-platform normalized text hashes.'
    }

    foreach ($forbidden in @('options.txt', 'options.amecsapi.txt', 'servers.dat')) {
        if (@($manifestFiles | Where-Object path -eq $forbidden).Count -ne 0) {
            throw "$forbidden must be installed once by the Prism shell, not managed by Packwiz."
        }
    }
    foreach ($managedUpdater in @(
        'nbidal18-packwiz-sync.next.jar',
        'nbidal18-packwiz-updater.next.jar',
        'packwiz-installer-bootstrap.next.jar',
        'packwiz-installer.next.jar',
        'prism/mmc-pack.json'
    )) {
        if (@($manifestFiles | Where-Object path -eq $managedUpdater).Count -ne 1) {
            throw "The auto-updatable launch chain is missing $managedUpdater from the manifest."
        }
    }

    $clientMods = @(Get-ChildItem -LiteralPath (Join-Path $stagePath 'mods') -File -Filter '*.jar')
    if ($clientMods.Count -ne 244) {
        throw "The Packwiz client must contain exactly 244 mod JARs; found $($clientMods.Count)."
    }
    $bccJar = Join-Path $stagePath 'mods\better-compatability-checker-fabric-21.1.8.jar'
    $bccConfig = Join-Path $stagePath 'config\bcc-common.toml'
    if (-not (Test-Path -LiteralPath $bccJar -PathType Leaf) -or
            (Get-Content -LiteralPath $bccConfig -Raw) -notmatch ('modpackVersion\s*=\s*"' + [regex]::Escape("v$packVersion") + '"')) {
        throw 'Better Compatibility Checker is missing or has the wrong client identity.'
    }
    # The server MOTD advertises which client version is required, so it is part of the release
    # identity. It sat at v4.1.3 through the whole of 4.2.0 because nothing checked it.
    # All three copies, not just the two that get deployed. The setup copy is the one a player
    # reads when they self-host, and because nothing checked it, it sat at v4.1.3 while the other
    # two moved with every release.
    foreach ($propertiesPath in @(
        (Join-Path $ReleaseRoot '1. setup\server.properties'),
        (Join-Path $ReleaseRoot '3. modpack\server\server.properties'),
        (Join-Path $ReleaseRoot '4. server\2. online-hosting\server.properties')
    )) {
        $motd = @([IO.File]::ReadAllLines($propertiesPath, [Text.Encoding]::UTF8) |
            Where-Object { $_ -like 'motd=*' })
        if ($motd.Count -ne 1) {
            throw "Expected exactly one motd line in $propertiesPath, found $($motd.Count)."
        }
        # Match the release number, not the whole version string. The MOTD is player-facing text and
        # its wording is free -- the guard exists to catch it going stale, not to dictate phrasing,
        # and the "-packwiz" suffix is being retired from the version anyway.
        $releaseNumber = ($packVersion -replace '-packwiz$', '')
        if ($motd[0] -notlike "*$releaseNumber*") {
            throw ("The server MOTD does not advertise this release: $propertiesPath holds " +
                   "'$($motd[0])' but the pack is $releaseNumber.")
        }
    }
    $integrityJar = Join-Path $stagePath 'mods\nbidal18-integrity-helper-1.0.0+1.21.1.jar'
    if (-not (Test-Path -LiteralPath $integrityJar -PathType Leaf)) {
        throw "The v$packVersion integrity helper is missing from the Packwiz client."
    }
    # Derived from the mod's own gradle.properties: a hardcoded version here has broken the build
    # at every client-tweaks bump, which teaches people to edit the assertion rather than read it.
    $tweaksProperties = Join-Path $ReleaseRoot (Join-Path '5. modpack source' (Join-Path 'custom mods' (Join-Path 'nbidal18-client-tweaks' 'gradle.properties')))
    if ([IO.File]::ReadAllText($tweaksProperties, [Text.Encoding]::UTF8) -notmatch '(?m)^mod_version=(.+?)\s*$') {
        throw "Could not read mod_version from $tweaksProperties"
    }
    $expectedTweaksJar = "nbidal18-client-tweaks-$($Matches[1]).jar"
    $clientTweaks = @(Get-ChildItem -LiteralPath (Join-Path $stagePath 'mods') -File -Filter 'nbidal18-client-tweaks-*.jar')
    if ($clientTweaks.Count -ne 1 -or $clientTweaks[0].Name -ne $expectedTweaksJar) {
        throw ("The client-tweaks artifact is missing or duplicated: expected exactly one " +
               "$expectedTweaksJar, found $($clientTweaks.Count) ($($clientTweaks.Name -join ', ')).")
    }
    $expectedDyeableBackpacks = @(
        'inmis:baby_backpack',
        'inmis:frayed_backpack',
        'inmis:plated_backpack',
        'inmis:gilded_backpack',
        'inmis:bejeweled_backpack',
        'inmis:blazing_backpack',
        'inmis:withered_backpack',
        'inmis:endless_backpack'
    )
    foreach ($dyeableTagPath in @(
        (Join-Path $stagePath 'datapacks\custom_recipes_1.21\data\minecraft\tags\item\dyeable.json'),
        (Join-Path $ReleaseRoot '3. modpack\server\datapacks\custom_recipes_1.21\data\minecraft\tags\item\dyeable.json'),
        (Join-Path $ReleaseRoot '4. server\2. online-hosting\datapacks\custom_recipes_1.21\data\minecraft\tags\item\dyeable.json')
    )) {
        $dyeableTag = Get-Content -LiteralPath $dyeableTagPath -Raw | ConvertFrom-Json
        if ($dyeableTag.replace -ne $false -or
                @(Compare-Object $expectedDyeableBackpacks @($dyeableTag.values)).Count -ne 0) {
            throw "The complete Inmis dyeable item tag is missing or malformed in $dyeableTagPath"
        }
    }
    foreach ($inmisConfigPath in @(
        (Join-Path $stagePath 'config\inmis.json'),
        (Join-Path $ReleaseRoot '3. modpack\server\config\inmis.json'),
        (Join-Path $ReleaseRoot '4. server\2. online-hosting\config\inmis.json')
    )) {
        $inmisConfig = Get-Content -LiteralPath $inmisConfigPath -Raw | ConvertFrom-Json
        if (@($inmisConfig.backpacks).Count -ne 8 -or
                @($inmisConfig.backpacks | Where-Object { $_.dyeable -ne $true }).Count -ne 0) {
            throw "All eight Inmis backpack tiers must be dyeable in $inmisConfigPath"
        }
    }
    $jobsSuppressor = Join-Path $stagePath 'mods\nbidal18-jobs-chat-suppressor-1.0.0+1.21.1.jar'
    if (-not (Test-Path -LiteralPath $jobsSuppressor -PathType Leaf)) {
        throw 'The Jobs+ compatibility helper is missing from the Packwiz client.'
    }
    $resourcePacks = @(Get-ChildItem -LiteralPath (Join-Path $stagePath 'resourcepacks') -File -Filter '*.zip')
    $oledBase = @($resourcePacks | Where-Object { $_.Name -like '*OLED*Colourful Containers*.zip' })
    $inmisOledAddon = @($resourcePacks | Where-Object { $_.Name -like '*OLED*Inmis Backpacks Addon*.zip' })
    if ($resourcePacks.Count -ne 17 -or
            -not (Test-Path -LiteralPath (Join-Path $stagePath 'resourcepacks\Fancy Crops v1.3.zip') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $stagePath 'resourcepacks\Enhanced Grass V1_4.zip') -PathType Leaf) -or
            $oledBase.Count -ne 0 -or $inmisOledAddon.Count -ne 0) {
        throw 'The 17-pack resource-pack baseline must include Fancy Crops and Enhanced Grass and exclude the retired Colourful Containers packs.'
    }
    foreach ($jobsConfig in @(
        (Join-Path $stagePath 'config\jobsplus-common.yaml'),
        (Join-Path $ReleaseRoot '3. modpack\server\config\jobsplus-common.yaml'),
        (Join-Path $ReleaseRoot '4. server\2. online-hosting\config\jobsplus-common.yaml')
    )) {
        $jobsText = Get-Content -LiteralPath $jobsConfig -Raw
        if ($jobsText -notmatch '(?m)^\s*show_xp_in_action_bar:\s*false\s*$' -or
                $jobsText -notmatch '(?m)^\s*broadcast_level_up_messages:\s*false\s*$' -or
                $jobsText -notmatch '(?m)^\s*amount_of_free_jobs:\s*1\s*$' -or
                $jobsText -notmatch '(?m)^\s*max_jobs:\s*1\s*$' -or
                $jobsText -notmatch '(?m)^\s*xp_multiplier:\s*0\.25\s*$' -or
                $jobsText -notmatch '(?m)^\s*use_decimal_values_for_xp:\s*true\s*$') {
            throw "Jobs+ notifications or progression balance are wrong in $jobsConfig"
        }
    }
    $jadeClient = Get-Content -LiteralPath (Join-Path $stagePath 'config\jade\plugins.json') -Raw | ConvertFrom-Json
    if ($jadeClient.minecraft.entity_health -ne $false) {
        throw 'Jade entity health is still enabled in the Packwiz client.'
    }
    foreach ($jadeOverride in @(
        (Join-Path $ReleaseRoot '3. modpack\server\config\jade\server-plugin-overrides.json'),
        (Join-Path $ReleaseRoot '4. server\2. online-hosting\config\jade\server-plugin-overrides.json')
    )) {
        $jadeServer = Get-Content -LiteralPath $jadeOverride -Raw | ConvertFrom-Json
        if ($jadeServer.minecraft.entity_health -ne $false) {
            throw "Jade entity health is not server-enforced as disabled in $jadeOverride"
        }
    }

    $manifest = [ordered]@{
        schema = 1
        packVersion = $packVersion
        exactRoots = @('mods', 'config', 'datapacks', 'resourcepacks', 'shaderpacks')
        extraTolerantRoots = @($extraTolerantRoots)
        runtimeMutableRoots = @($runtimeMutablePaths)
        localAllowed = @($preservedConfigPaths)
        propertyRules = @(
            [ordered]@{
                path = 'shaderpacks/ComplementaryUnbound_r5.8.1.zip.txt'
                key = 'GLOWING_ORE_MASTER'
                value = '0'
            }
        )
        normalizedTextFiles = @($normalizedTextFiles)
        files = @($manifestFiles)
    }
    Write-Utf8 (Join-Path $stagePath 'sync-manifest.json') (($manifest | ConvertTo-Json -Depth 6) + "`n")

    $manifestDigest = Get-Sha256 (Join-Path $stagePath 'sync-manifest.json')
    $releaseBaselineDigest = '9515a09d1ce3d751e69da097ff6f3aee9856de3662fa35a69b6422fb845f3b41'
    $canonicalPolicy = Join-Path $ReleaseRoot '3. modpack\server\config\nbidal18-integrity.properties'
    $hostingPolicy = Join-Path $ReleaseRoot '4. server\2. online-hosting\config\nbidal18-integrity.properties'
    $overlayPolicy = Join-Path $ReleaseRoot '4. server\transition-overlay\config\nbidal18-integrity.properties'
    foreach ($policyPath in @($canonicalPolicy, $hostingPolicy, $overlayPolicy)) {
        if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
            throw "The server integrity transition policy is missing: $policyPath"
        }
        $policyText = [IO.File]::ReadAllText($policyPath, [Text.Encoding]::UTF8)
        if ($policyText -notmatch '(?m)^require-helper=(true|false)$' -or
                $policyText -notmatch '(?m)^expected-manifest-sha256=[0-9a-f]{64}$') {
            throw "The server integrity transition policy is malformed: $policyPath"
        }
        $existingExpected = [regex]::Match(
            $policyText,
            '(?m)^expected-manifest-sha256=([0-9a-f]{64})$'
        ).Groups[1].Value
        $rollingDigests = @($releaseBaselineDigest, $existingExpected)
        $existingAccepted = [regex]::Match(
            $policyText,
            '(?m)^accepted-manifest-sha256=([0-9a-f]{64}(?:,[0-9a-f]{64})*)$'
        )
        if ($existingAccepted.Success) {
            $rollingDigests += $existingAccepted.Groups[1].Value.Split(',')
        }
        $rollingDigests = @($rollingDigests | Where-Object {
            $_ -ne $manifestDigest
        } | Select-Object -Unique)
        $policyText = [regex]::Replace(
            $policyText,
            '(?m)^expected-manifest-sha256=[0-9a-f]{64}$',
            "expected-manifest-sha256=$manifestDigest"
        )
        $acceptedLine = 'accepted-manifest-sha256=' + ($rollingDigests -join ',')
        if ($policyText -match '(?m)^accepted-manifest-sha256=') {
            $policyText = [regex]::Replace(
                $policyText,
                '(?m)^accepted-manifest-sha256=.*$',
                $acceptedLine
            )
        }
        else {
            $policyText = $policyText.TrimEnd("`r", "`n") + "`n$acceptedLine`n"
        }
        Write-Utf8 $policyPath $policyText
    }
    if ((Get-Content -LiteralPath $canonicalPolicy -Raw) -notmatch '(?m)^require-helper=true$' -or
            (Get-Content -LiteralPath $hostingPolicy -Raw) -notmatch '(?m)^require-helper=true$' -or
            (Get-Content -LiteralPath $overlayPolicy -Raw) -notmatch '(?m)^require-helper=true$') {
        throw "The enforced v$packVersion release must keep require-helper=true."
    }

    $siteFiles = @(Get-ChildItem -LiteralPath $stagePath -Recurse -File -Force)
    $siteBytes = ($siteFiles | Measure-Object Length -Sum).Sum
    $largest = $siteFiles | Sort-Object Length -Descending | Select-Object -First 1
    if ($siteBytes -ge 1GB) {
        throw "The GitHub Pages site is at least 1 GiB: $siteBytes bytes"
    }
    if ($largest.Length -ge 100MB) {
        throw "A hosted file reaches GitHub's 100 MiB limit: $($largest.FullName)"
    }

    if (Test-Path -LiteralPath $SitePath) {
        Remove-Item -LiteralPath $SitePath -Recurse -Force
    }
    Move-Item -LiteralPath $stagePath -Destination $SitePath
    Write-Host "Created Packwiz site: $SitePath"
    Write-Host "Managed files: $($manifestFiles.Count); mods: $($clientMods.Count); size: $([math]::Round($siteBytes / 1MB, 2)) MiB"
}
finally {
    if (Test-Path -LiteralPath $stagePath) {
        Remove-Item -LiteralPath $stagePath -Recurse -Force
    }
}
