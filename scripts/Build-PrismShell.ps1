param(
    [string] $ReleaseRoot,
    [string] $OutputPath
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
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $ReleaseRoot '1. setup\nbidal18-client-4.1.2-packwiz.zip'
}
elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $ReleaseRoot $OutputPath
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

$clientRoot = Join-Path $ReleaseRoot '3. modpack\client'
$appearanceRoot = Join-Path $ReleaseRoot '2. appearance\support'
$iconPath = Join-Path $ReleaseRoot '5. development\server-icon.png'
$bootstrapPath = Join-Path $ReleaseRoot '5. development\tools\packwiz-installer-bootstrap.jar'
$syncScript = Join-Path $repoRoot 'client\nbidal18-packwiz-sync.ps1'
$sitePath = Join-Path $repoRoot 'site'

foreach ($required in @(
    (Join-Path $appearanceRoot 'client-options.txt'),
    (Join-Path $appearanceRoot 'client-options.amecsapi.txt'),
    (Join-Path $clientRoot 'servers.dat'),
    $iconPath,
    $bootstrapPath,
    $syncScript,
    (Join-Path $sitePath 'pack.toml'),
    (Join-Path $sitePath 'sync-manifest.json')
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required Prism shell input is missing: $required"
    }
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

if ((Get-Sha256 $bootstrapPath) -ne
        'A8FBB24DC604278E97F4688E82D3D91A318B98EFC08D5DBFCBCBCAB6443D116C') {
    throw 'The Packwiz bootstrap does not match reviewed upstream v0.0.3.'
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$fixedTimestamp = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$stagePath = Join-Path ([IO.Path]::GetTempPath()) ('nbidal18-packwiz-shell-' + [guid]::NewGuid().ToString('N'))

function Write-Utf8([string] $path, [string] $text) {
    $parent = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($path, $text.Replace("`r`n", "`n"), $utf8NoBom)
}

try {
    $minecraft = Join-Path $stagePath 'minecraft'
    New-Item -ItemType Directory -Path $minecraft -Force | Out-Null

    Write-Utf8 (Join-Path $stagePath '.packignore') @'
minecraft/saves
minecraft/screenshots
minecraft/logs
minecraft/crash-reports
minecraft/debug
minecraft/local
minecraft/data
minecraft/dynamic-resource-pack-cache
minecraft/immersive_paintings_cache
minecraft/server-resource-packs
minecraft/usercache.json
minecraft/command_history.txt
minecraft/.mixin.out
minecraft/.nbidal18-packwiz
minecraft/skin_overrides
minecraft/cape_overrides
minecraft/vinurl/downloads
'@
    Write-Utf8 (Join-Path $stagePath 'instance.cfg') @'
[General]
iconKey=server-icon
name=nbidal18-client-4.1.2-packwiz
AutomaticJava=true
InstanceType=OneSix
ExportName=nbidal18-client-4.1.2-packwiz
ExportOptionalFiles=true
ExportSummary=Fabric 1.21.1 adventure modpack with automatic updates
ExportVersion=4.1.2-packwiz
IgnoreJavaCompatibility=false
JoinServerOnLaunch=false
ManagedPack=false
OverrideJavaLocation=false
OverrideMemory=false
OverrideCommands=true
PreLaunchCommand=powershell.exe -NoProfile -ExecutionPolicy Bypass -File nbidal18-packwiz-sync.ps1
UseAccountForInstance=false
'@
    Write-Utf8 (Join-Path $stagePath 'mmc-pack.json') @'
{
  "components": [
    {"cachedName":"LWJGL 3","cachedVersion":"3.3.3","cachedVolatile":true,"dependencyOnly":true,"uid":"org.lwjgl3","version":"3.3.3"},
    {"cachedName":"Minecraft","cachedRequires":[{"suggests":"3.3.3","uid":"org.lwjgl3"}],"cachedVersion":"1.21.1","important":true,"uid":"net.minecraft","version":"1.21.1"},
    {"cachedName":"Intermediary Mappings","cachedRequires":[{"equals":"1.21.1","uid":"net.minecraft"}],"cachedVersion":"1.21.1","cachedVolatile":true,"dependencyOnly":true,"uid":"net.fabricmc.intermediary","version":"1.21.1"},
    {"cachedName":"Fabric Loader","cachedRequires":[{"uid":"net.fabricmc.intermediary"}],"cachedVersion":"0.19.3","uid":"net.fabricmc.fabric-loader","version":"0.19.3"}
  ],
  "formatVersion": 1
}
'@

    Copy-Item -LiteralPath $iconPath -Destination (Join-Path $stagePath 'server-icon.png')
    Copy-Item -LiteralPath $bootstrapPath -Destination (Join-Path $minecraft 'packwiz-installer-bootstrap.jar')
    Copy-Item -LiteralPath $syncScript -Destination (Join-Path $minecraft 'nbidal18-packwiz-sync.ps1')
    Copy-Item -LiteralPath (Join-Path $appearanceRoot 'client-options.txt') -Destination (Join-Path $minecraft 'options.txt')
    Copy-Item -LiteralPath (Join-Path $appearanceRoot 'client-options.amecsapi.txt') -Destination (Join-Path $minecraft 'options.amecsapi.txt')
    Copy-Item -LiteralPath (Join-Path $clientRoot 'servers.dat') -Destination (Join-Path $minecraft 'servers.dat')

    New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }
    $archive = [IO.Compression.ZipFile]::Open($OutputPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $files = @(Get-ChildItem -LiteralPath $stagePath -Recurse -File -Force | Sort-Object FullName)
        foreach ($file in $files) {
            $entryName = $file.FullName.Substring($stagePath.Length).TrimStart('\').Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $fixedTimestamp
            $entry.ExternalAttributes = 0
            $input = [IO.File]::OpenRead($file.FullName)
            try {
                $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose() }
            }
            finally { $input.Dispose() }
        }
    }
    finally { $archive.Dispose() }

    if ((Get-Item -LiteralPath $OutputPath).Length -ge 100MB) {
        throw 'The Prism import ZIP is not below 100 MiB.'
    }
    $publishedZip = Join-Path $sitePath 'nbidal18-client-4.1.2-packwiz.zip'
    Copy-Item -LiteralPath $OutputPath -Destination $publishedZip -Force
    $zipHash = Get-Sha256 $OutputPath
    $packHash = Get-Sha256 (Join-Path $sitePath 'pack.toml')
    Write-Utf8 (Join-Path (Split-Path -Parent $OutputPath) 'SHA256SUMS.txt') "$zipHash  nbidal18-client-4.1.2-packwiz.zip`n"
    Write-Utf8 (Join-Path $sitePath 'SHA256SUMS.txt') "$zipHash  nbidal18-client-4.1.2-packwiz.zip`n$packHash  pack.toml`n"
    Write-Host "Created Prism import: $OutputPath"
    Write-Host "Bytes: $((Get-Item -LiteralPath $OutputPath).Length); SHA-256: $zipHash"
}
finally {
    if (Test-Path -LiteralPath $stagePath) {
        Remove-Item -LiteralPath $stagePath -Recurse -Force
    }
}
