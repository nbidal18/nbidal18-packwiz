param(
    [string] $ReleaseRoot,
    [string] $SitePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '..\nbidal18 v4.1.2-packwiz'))
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
/nbidal18-client-4.1.2-packwiz.zip
/SHA256SUMS.txt
/sync-manifest.json
/pack.toml
/index.toml
'@
    New-Item -ItemType File -Path (Join-Path $stagePath '.nojekyll') | Out-Null
    Copy-Item -LiteralPath $landingPage -Destination (Join-Path $stagePath 'index.html')

    Write-Utf8 (Join-Path $stagePath 'pack.toml') @'
name = "nbidal18"
version = "4.1.2-packwiz"
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

    $packText = [IO.File]::ReadAllText((Join-Path $stagePath 'pack.toml'), [Text.Encoding]::UTF8)
    if ($packText -match 'hash = "0{64}"') {
        throw 'Packwiz did not refresh the index hash.'
    }
    $indexText = [IO.File]::ReadAllText((Join-Path $stagePath 'index.toml'), [Text.Encoding]::UTF8)
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
    if ($clientMods.Count -ne 241) {
        throw "The Packwiz client must contain exactly 241 mod JARs; found $($clientMods.Count)."
    }
    $bccJar = Join-Path $stagePath 'mods\better-compatability-checker-fabric-21.1.8.jar'
    $bccConfig = Join-Path $stagePath 'config\bcc-common.toml'
    if (-not (Test-Path -LiteralPath $bccJar -PathType Leaf) -or
            (Get-Content -LiteralPath $bccConfig -Raw) -notmatch 'modpackVersion\s*=\s*"v4\.1\.2-packwiz"') {
        throw 'Better Compatibility Checker is missing or has the wrong client identity.'
    }

    $manifest = [ordered]@{
        schema = 1
        packVersion = '4.1.2-packwiz'
        exactRoots = @('mods', 'config', 'datapacks', 'resourcepacks', 'shaderpacks')
        localAllowed = @()
        files = @($manifestFiles)
    }
    Write-Utf8 (Join-Path $stagePath 'sync-manifest.json') (($manifest | ConvertTo-Json -Depth 6) + "`n")

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
