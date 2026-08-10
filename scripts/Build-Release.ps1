[CmdletBinding()]
param(
    [string] $UpdateUrl,
    [switch] $RefreshModrinth,
    [switch] $SkipBehaviorValidation,
    [switch] $SkipRemoteCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$updaterRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$urlPath = Join-Path $updaterRoot 'UPDATE-URL.txt'
$syncPath = Join-Path $PSScriptRoot 'Sync-Packwiz.ps1'
$testPath = Join-Path $PSScriptRoot 'Test-Packwiz.ps1'
$builderPath = Join-Path $releaseRoot '1. setup\support\scripts\build-prism-instance.ps1'
$siteRoot = Join-Path $updaterRoot 'site'
$outputPath = Join-Path $releaseRoot '1. setup\nbidal18-3.1.0-client.zip'

if ([string]::IsNullOrWhiteSpace($UpdateUrl)) {
    if (-not (Test-Path -LiteralPath $urlPath -PathType Leaf)) { throw "Missing update URL file: $urlPath" }
    $UpdateUrl = (Get-Content -LiteralPath $urlPath -Raw).Trim()
}

$uri = $null
if (-not [Uri]::TryCreate($UpdateUrl, [UriKind]::Absolute, [ref] $uri) -or
    $uri.Scheme -ne 'https' -or
    -not $uri.AbsolutePath.EndsWith('/pack.toml', [StringComparison]::OrdinalIgnoreCase) -or
    $uri.Host -in @('localhost', '127.0.0.1', '::1') -or
    $UpdateUrl -match 'OWNER|REPOSITORY|YOUR[_-]?|example\.com') {
    throw 'UPDATE-URL.txt must contain the real anonymous HTTPS URL ending in /pack.toml.'
}

if ($RefreshModrinth) { & $syncPath -RefreshModrinth }
else { & $syncPath }

if (-not $SkipBehaviorValidation) { & $testPath }

if (-not $SkipRemoteCheck) {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nbidal18-remote-check-' + [guid]::NewGuid().ToString('N'))
    $expectedPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\nbidal18-remote-check-'
    $tempRoot = [IO.Path]::GetFullPath($tempRoot)
    if (-not $tempRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe temp path: $tempRoot" }
    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $remotePack = Join-Path $tempRoot 'pack.toml'
        $remoteIndex = Join-Path $tempRoot 'index.toml'
        Invoke-WebRequest -UseBasicParsing -Uri $UpdateUrl -OutFile $remotePack
        $indexUrl = [Uri]::new($uri, 'index.toml').AbsoluteUri
        Invoke-WebRequest -UseBasicParsing -Uri $indexUrl -OutFile $remoteIndex
        foreach ($name in @('pack.toml', 'index.toml')) {
            $local = Join-Path $siteRoot $name
            $remote = Join-Path $tempRoot $name
            if ((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $remote -Algorithm SHA256).Hash) {
                throw "Published $name does not match the local update site. Push the site and wait for GitHub Pages first."
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            if (-not $tempRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe cleanup path: $tempRoot" }
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

& $builderPath -OutputPath $outputPath -UpdateUrl $UpdateUrl
if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw "Release ZIP was not created: $outputPath" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($outputPath)
try {
    $entry = $archive.GetEntry('instance.cfg')
    if (-not $entry) { throw 'Final release ZIP has no instance.cfg.' }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { $instanceCfg = $reader.ReadToEnd() }
    finally { $reader.Dispose() }
    if (-not $instanceCfg.Contains("PreLaunchCommand=`"`$INST_JAVA`" -jar packwiz-installer-bootstrap.jar $UpdateUrl")) {
        throw 'Final release ZIP does not contain the expected public Packwiz URL.'
    }
}
finally {
    $archive.Dispose()
}

[IO.File]::WriteAllText($urlPath, $UpdateUrl.Trim() + "`n", [Text.UTF8Encoding]::new($false))
$hash = Get-FileHash -LiteralPath $outputPath -Algorithm SHA256
Write-Host "Release ZIP ready: $outputPath"
Write-Host "SHA-256: $($hash.Hash)"
