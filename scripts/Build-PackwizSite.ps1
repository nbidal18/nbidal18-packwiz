param(
    [string] $ReleaseRoot,
    [string] $SitePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '..\nbidal18 v4.1.3-packwiz'))
}
else {
    $ReleaseRoot = [IO.Path]::GetFullPath($ReleaseRoot)
}
if ([string]::IsNullOrWhiteSpace($SitePath)) {
    $SitePath = Join-Path $repoRoot 'site'
}
elseif (-not [IO.Path]::IsPathRooted($SitePath)) {
    $SitePath = Join-Path $repoRoot $SitePath
}
$SitePath = [IO.Path]::GetFullPath($SitePath)

$clientRoot = Join-Path $ReleaseRoot '3. modpack\client'
$packwizPath = Join-Path $ReleaseRoot '5. development\tools\packwiz-current\packwiz.exe'
$landingPage = Join-Path $repoRoot 'templates\index.html'
$stagePath = Join-Path $repoRoot ('.site-staging-' + [guid]::NewGuid().ToString('N'))
$utf8NoBom = [Text.UTF8Encoding]::new($false)

foreach ($required in @(
    $clientRoot,
    (Join-Path $clientRoot 'mods'),
    (Join-Path $clientRoot 'config'),
    (Join-Path $clientRoot 'datapacks'),
    (Join-Path $clientRoot 'resourcepacks'),
    (Join-Path $clientRoot 'shaderpacks'),
    $packwizPath,
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

$preservedConfigPaths = @(
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

$excludedPatterns = @(
    'servers.dat',
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

    Write-Utf8 (Join-Path $stagePath '.packwizignore') @'
/.nojekyll
/.packwizignore
/index.html
/nbidal18-client-4.1.3-packwiz.zip
/SHA256SUMS.txt
/sync-manifest.json
/pack.toml
/index.toml
'@
    New-Item -ItemType File -Path (Join-Path $stagePath '.nojekyll') | Out-Null
    Copy-Item -LiteralPath $landingPage -Destination (Join-Path $stagePath 'index.html')

    Write-Utf8 (Join-Path $stagePath 'pack.toml') @'
name = "nbidal18"
version = "4.1.3-packwiz"
description = "Fabric 1.21.1 adventure modpack with automatic Prism updates"
pack-format = "packwiz:1.1.0"

[index]
file = "index.toml"
hash-format = "sha256"
hash = "0000000000000000000000000000000000000000000000000000000000000000"

[versions]
fabric = "0.19.3"
minecraft = "1.21.1"
'@
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
    foreach ($preservedPath in @($preservedConfigPaths | Where-Object { $_ -ne 'config/controlify.json' })) {
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

    foreach ($forbidden in @('options.txt', 'options.amecsapi.txt', 'servers.dat')) {
        if (@($manifestFiles | Where-Object path -eq $forbidden).Count -ne 0) {
            throw "$forbidden must be installed once by the Prism shell, not managed by Packwiz."
        }
    }

    $clientMods = @(Get-ChildItem -LiteralPath (Join-Path $stagePath 'mods') -File -Filter '*.jar')
    if ($clientMods.Count -ne 244) {
        throw "The Packwiz client must contain exactly 244 mod JARs; found $($clientMods.Count)."
    }
    $bccJar = Join-Path $stagePath 'mods\better-compatability-checker-fabric-21.1.8.jar'
    $bccConfig = Join-Path $stagePath 'config\bcc-common.toml'
    if (-not (Test-Path -LiteralPath $bccJar -PathType Leaf) -or
            (Get-Content -LiteralPath $bccConfig -Raw) -notmatch 'modpackVersion\s*=\s*"v4\.1\.3-packwiz"') {
        throw 'Better Compatibility Checker is missing or has the wrong client identity.'
    }
    $integrityJar = Join-Path $stagePath 'mods\nbidal18-integrity-helper-1.0.0+1.21.1.jar'
    if (-not (Test-Path -LiteralPath $integrityJar -PathType Leaf)) {
        throw 'The v4.1.3 integrity helper is missing from the Packwiz client.'
    }
    $clientTweaks = @(Get-ChildItem -LiteralPath (Join-Path $stagePath 'mods') -File -Filter 'nbidal18-client-tweaks-*.jar')
    if ($clientTweaks.Count -ne 1 -or $clientTweaks[0].Name -ne 'nbidal18-client-tweaks-1.1.0+1.21.1.jar') {
        throw 'The Jobs+ plaque-enabled client-tweaks artifact is missing or duplicated.'
    }
    $jobsSuppressor = Join-Path $stagePath 'mods\nbidal18-jobs-chat-suppressor-1.0.0+1.21.1.jar'
    if (-not (Test-Path -LiteralPath $jobsSuppressor -PathType Leaf)) {
        throw 'The Jobs+ compatibility helper is missing from the Packwiz client.'
    }
    $polytoneJar = Join-Path $stagePath 'mods\polytone-1.21-3.12.0-fabric.jar'
    if (-not (Test-Path -LiteralPath $polytoneJar -PathType Leaf)) {
        throw 'Nature X requires the client-only Polytone dependency.'
    }
    $resourcePacks = @(Get-ChildItem -LiteralPath (Join-Path $stagePath 'resourcepacks') -File -Filter '*.zip')
    if ($resourcePacks.Count -ne 19 -or
            -not (Test-Path -LiteralPath (Join-Path $stagePath 'resourcepacks\Fancy Crops v1.3.zip') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $stagePath 'resourcepacks\Nature X - 12.2 [1.21.1].zip') -PathType Leaf)) {
        throw 'The 19-pack resource-pack baseline is missing Fancy Crops or Nature X.'
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
        packVersion = '4.1.3-packwiz'
        exactRoots = @('mods', 'config', 'datapacks', 'resourcepacks', 'shaderpacks')
        localAllowed = @($preservedConfigPaths)
        propertyRules = @(
            [ordered]@{
                path = 'shaderpacks/ComplementaryUnbound_r5.8.1.zip.txt'
                key = 'GLOWING_ORE_MASTER'
                value = '0'
            }
        )
        files = @($manifestFiles)
    }
    Write-Utf8 (Join-Path $stagePath 'sync-manifest.json') (($manifest | ConvertTo-Json -Depth 6) + "`n")

    $manifestDigest = Get-Sha256 (Join-Path $stagePath 'sync-manifest.json')
    $canonicalPolicy = Join-Path $ReleaseRoot '3. modpack\server\config\nbidal18-integrity.properties'
    $hostingPolicy = Join-Path $ReleaseRoot '4. server\2. online-hosting\config\nbidal18-integrity.properties'
    foreach ($policyPath in @($canonicalPolicy, $hostingPolicy)) {
        if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
            throw "The server integrity transition policy is missing: $policyPath"
        }
        $policyText = [IO.File]::ReadAllText($policyPath, [Text.Encoding]::UTF8)
        if ($policyText -notmatch '(?m)^require-helper=(true|false)$' -or
                $policyText -notmatch '(?m)^expected-manifest-sha256=[0-9a-f]{64}$') {
            throw "The server integrity transition policy is malformed: $policyPath"
        }
        $policyText = [regex]::Replace(
            $policyText,
            '(?m)^expected-manifest-sha256=[0-9a-f]{64}$',
            "expected-manifest-sha256=$manifestDigest"
        )
        Write-Utf8 $policyPath $policyText
    }
    if ((Get-Content -LiteralPath $canonicalPolicy -Raw) -notmatch '(?m)^require-helper=false$' -or
            (Get-Content -LiteralPath $hostingPolicy -Raw) -notmatch '(?m)^require-helper=false$') {
        throw 'The v4.1.3 testing release must keep require-helper=false.'
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
