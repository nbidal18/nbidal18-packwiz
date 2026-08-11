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
$guardPath = Join-Path $updaterRoot 'tools\nbidal18-launch-guard.jar'
$guardBuildPath = Join-Path $updaterRoot 'source\nbidal18-launch-guard\build.ps1'
$guardSmokePath = Join-Path $updaterRoot 'source\nbidal18-launch-guard\smoke-test.ps1'
$toolProvenancePath = Join-Path $updaterRoot 'TOOL-PROVENANCE.md'
$outputPath = Join-Path $releaseRoot '1. setup\nbidal18-3.2.1-client.zip'
$packCompatSourceRoot = Join-Path $updaterRoot 'source\nbidal18-pack-compat'
$packCompatPropertiesPath = Join-Path $packCompatSourceRoot 'gradle.properties'
$packCompatGradle = Join-Path $packCompatSourceRoot 'gradlew.bat'

function Get-GradleProperty([string] $Path, [string] $Name) {
    $match = @(Get-Content -LiteralPath $Path | Where-Object {
        $_ -match ('^' + [regex]::Escape($Name) + '=(.+)$')
    })
    if ($match.Count -ne 1) { throw "Expected exactly one $Name property in $Path" }
    return ([regex]::Match($match[0], '^[^=]+=(.+)$')).Groups[1].Value.Trim()
}

function Build-AndVerifyPackCompat {
    if (-not (Test-Path -LiteralPath $packCompatGradle -PathType Leaf) -or
        -not (Test-Path -LiteralPath $packCompatPropertiesPath -PathType Leaf)) {
        throw "Missing nbidal18-pack-compat build source under $packCompatSourceRoot"
    }

    $previousJavaHome = $env:JAVA_HOME
    $assignedJavaHome = $false
    if ([string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $prismJavaHome = Join-Path $env:APPDATA 'PrismLauncher\java\java-runtime-delta'
        if (Test-Path -LiteralPath (Join-Path $prismJavaHome 'bin\java.exe') -PathType Leaf) {
            $env:JAVA_HOME = $prismJavaHome
            $assignedJavaHome = $true
        }
    }
    try {
        Push-Location $packCompatSourceRoot
        try {
            $gradleOutput = @(& $packCompatGradle clean test remapJar --no-daemon --rerun-tasks)
            $gradleExitCode = $LASTEXITCODE
            $gradleOutput | ForEach-Object { Write-Host $_ }
            if ($gradleExitCode -ne 0) { throw "nbidal18-pack-compat build/tests failed with exit code $gradleExitCode" }
        }
        finally { Pop-Location }
    }
    finally {
        if ($assignedJavaHome) { $env:JAVA_HOME = $previousJavaHome }
    }

    $archiveBase = Get-GradleProperty $packCompatPropertiesPath 'archives_base_name'
    $modVersion = Get-GradleProperty $packCompatPropertiesPath 'mod_version'
    $fileName = "$archiveBase-$modVersion.jar"
    $builtJar = Join-Path $packCompatSourceRoot "build\libs\$fileName"
    if (-not (Test-Path -LiteralPath $builtJar -PathType Leaf)) {
        throw "The reproducible pack-compat artifact is missing after build: $builtJar"
    }

    $builtHash = (Get-FileHash -LiteralPath $builtJar -Algorithm SHA256).Hash
    foreach ($payloadPath in @(
        (Join-Path $releaseRoot "3. modpack\client\mods\$fileName"),
        (Join-Path $releaseRoot "3. modpack\server\mods\$fileName"),
        (Join-Path $releaseRoot "4. server\2. online-hosting\mods\$fileName")
    )) {
        if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash -ne $builtHash) {
            throw "Rebuild/propagate the exact pack-compat JAR before release; expected $builtHash at $payloadPath"
        }
    }
    return [pscustomobject]@{ FileName = $fileName; BuiltJar = $builtJar; Hash = $builtHash }
}

function Build-AndVerifyLaunchGuard {
    if (-not (Test-Path -LiteralPath $guardBuildPath -PathType Leaf)) {
        throw "Missing launch-guard reproducible build script: $guardBuildPath"
    }
    & $guardBuildPath -OutputPath $guardPath
    if (-not (Test-Path -LiteralPath $guardPath -PathType Leaf)) {
        throw "Launch-guard build did not create: $guardPath"
    }
    $actualHash = (Get-FileHash -LiteralPath $guardPath -Algorithm SHA256).Hash
    $provenance = Get-Content -LiteralPath $toolProvenancePath -Raw
    $section = [regex]::Match(
        $provenance,
        '(?s)## nbidal18 launch guard\s+.*?- SHA-256: `([0-9A-Fa-f]{64})`'
    )
    if (-not $section.Success -or $section.Groups[1].Value -ne $actualHash) {
        throw "TOOL-PROVENANCE.md must record the reproducible launch-guard SHA-256 $actualHash"
    }
}

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

# Build first so source/binary drift cannot be hidden by a successful site
# refresh. Sync consumes the already-verified canonical client artifact.
Build-AndVerifyLaunchGuard
$packCompat = Build-AndVerifyPackCompat

if ($RefreshModrinth) { & $syncPath -RefreshModrinth }
else { & $syncPath }

& $guardSmokePath

$sitePackCompat = Join-Path $siteRoot "mods\$($packCompat.FileName)"
if (-not (Test-Path -LiteralPath $sitePackCompat -PathType Leaf) -or
    (Get-FileHash -LiteralPath $sitePackCompat -Algorithm SHA256).Hash -ne $packCompat.Hash) {
    throw "Generated updater site pack-compat JAR differs from the reproducible build: $sitePackCompat"
}

if (-not (Test-Path -LiteralPath $guardPath -PathType Leaf)) {
    throw "Build the reproducible launch guard before packaging: $guardPath"
}

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
        $remoteStrictManifest = Join-Path $tempRoot 'strict-manifest.tsv'
        Invoke-WebRequest -UseBasicParsing -Uri $UpdateUrl -OutFile $remotePack
        $indexUrl = [Uri]::new($uri, 'index.toml').AbsoluteUri
        Invoke-WebRequest -UseBasicParsing -Uri $indexUrl -OutFile $remoteIndex
        $strictManifestUrl = [Uri]::new($uri, '.nbidal18/strict-manifest.tsv').AbsoluteUri
        Invoke-WebRequest -UseBasicParsing -Uri $strictManifestUrl -OutFile $remoteStrictManifest
        foreach ($pair in @(
            @{ Local = (Join-Path $siteRoot 'pack.toml'); Remote = $remotePack; Label = 'pack.toml' },
            @{ Local = (Join-Path $siteRoot 'index.toml'); Remote = $remoteIndex; Label = 'index.toml' },
            @{ Local = (Join-Path $siteRoot '.nbidal18\strict-manifest.tsv'); Remote = $remoteStrictManifest; Label = 'strict-manifest.tsv' }
        )) {
            $local = $pair.Local
            $remote = $pair.Remote
            if ((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $remote -Algorithm SHA256).Hash) {
                throw "Published $($pair.Label) does not match the local update site. Push the site and wait for GitHub Pages first."
            }
        }
        $hostedRows = @(Import-Csv -LiteralPath (Join-Path $updaterRoot 'metadata\METADATA-REPORT.csv') |
            Where-Object { $_.management -eq 'internal-hosted' })
        for ($hostedIndex = 0; $hostedIndex -lt $hostedRows.Count; $hostedIndex++) {
            $hostedRow = $hostedRows[$hostedIndex]
            if ($hostedRow.sha512 -notmatch '^[0-9a-f]{128}$') {
                throw "Invalid internal-hosted SHA-512 in metadata report: $($hostedRow.path)"
            }
            $remoteHosted = Join-Path $tempRoot ("internal-hosted-$hostedIndex.bin")
            $hostedUrl = [Uri]::new($uri, $hostedRow.path).AbsoluteUri
            Invoke-WebRequest -UseBasicParsing -Uri $hostedUrl -OutFile $remoteHosted
            if ((Get-FileHash -LiteralPath $remoteHosted -Algorithm SHA512).Hash.ToLowerInvariant() -ne $hostedRow.sha512) {
                throw "Published internal-hosted payload differs from reviewed metadata: $($hostedRow.path)"
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
    $guardEntry = $archive.GetEntry('minecraft/nbidal18-launch-guard.jar')
    if (-not $guardEntry) { throw 'Final release ZIP has no launch guard JAR.' }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { $instanceCfg = $reader.ReadToEnd() }
    finally { $reader.Dispose() }
    if (-not $instanceCfg.Contains("PreLaunchCommand=`"`$INST_JAVA`" -jar nbidal18-launch-guard.jar $UpdateUrl")) {
        throw 'Final release ZIP does not contain the expected guarded public Packwiz URL.'
    }
    $guardHash = [Security.Cryptography.SHA256]::Create()
    $guardStream = $guardEntry.Open()
    try {
        $guardEntryHash = ([BitConverter]::ToString($guardHash.ComputeHash($guardStream))).Replace('-', '')
    }
    finally {
        $guardStream.Dispose()
        $guardHash.Dispose()
    }
    if ($guardEntryHash -ne (Get-FileHash -LiteralPath $guardPath -Algorithm SHA256).Hash) {
        throw 'Final release ZIP launch guard differs from the reproducible local build.'
    }
}
finally {
    $archive.Dispose()
}

[IO.File]::WriteAllText($urlPath, $UpdateUrl.Trim() + "`n", [Text.UTF8Encoding]::new($false))
$hash = Get-FileHash -LiteralPath $outputPath -Algorithm SHA256
Write-Host "Release ZIP ready: $outputPath"
Write-Host "SHA-256: $($hash.Hash)"
