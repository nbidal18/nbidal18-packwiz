[CmdletBinding()]
param(
    [string] $UpdateUrl,
    [switch] $RefreshModrinth,
    [switch] $SkipBehaviorValidation,
    [switch] $SkipRemoteCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

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
$outputPath = Join-Path $releaseRoot '1. setup\nbidal18-client.zip'
$packCompatSourceRoot = Join-Path $updaterRoot 'source\nbidal18-pack-compat'
$packCompatPropertiesPath = Join-Path $packCompatSourceRoot 'gradle.properties'
$packCompatGradle = Join-Path $packCompatSourceRoot 'gradlew.bat'
$expectedReleaseVersion = '3.2.6'
$expectedPackCompatVersion = '1.1.10+1.21.1'
$expectedLaunchGuardVersion = '1.1.0'
$publishedV324LaunchGuardSha256 = '63243A6972BF4B89C0E2DDE79B48F20009781C021AA68D30DCB19063AECCAC45'
$reviewedLaunchGuardSha256 = '7BE9B87B00B92307A2F9B830C6D5FB2E5D74D583E5AB9FF3A9779AB7FF8FA79A'
$reviewedPackCompatSha256 = 'DADDAF7BE02F93A9F714D74158C291C3C782FA3077A5FC86FC2AD0CEFF08B0C8'

function Get-GradleProperty([string] $Path, [string] $Name) {
    $match = @(Get-Content -LiteralPath $Path | Where-Object {
        $_ -match ('^' + [regex]::Escape($Name) + '=(.+)$')
    })
    if ($match.Count -ne 1) { throw "Expected exactly one $Name property in $Path" }
    return ([regex]::Match($match[0], '^[^=]+=(.+)$')).Groups[1].Value.Trim()
}

function Assert-EmbeddedLaunchGuard([string] $CompanionJar, [string] $ExpectedGuard, [string] $Label) {
    if (-not (Test-Path -LiteralPath $CompanionJar -PathType Leaf)) {
        throw "Missing $Label companion JAR: $CompanionJar"
    }
    if (-not (Test-Path -LiteralPath $ExpectedGuard -PathType Leaf)) {
        throw "Missing reviewed launch guard for $Label verification: $ExpectedGuard"
    }

    $expectedFile = Get-Item -LiteralPath $ExpectedGuard
    $expectedHash = (Get-FileHash -LiteralPath $ExpectedGuard -Algorithm SHA256).Hash.ToLowerInvariant()
    $payloadName = 'META-INF/nbidal18/nbidal18-launch-guard.jar'
    $descriptorName = 'META-INF/nbidal18/launch-guard.tsv'
    $archive = [IO.Compression.ZipFile]::OpenRead($CompanionJar)
    try {
        $payloadEntries = @($archive.Entries | Where-Object { $_.FullName -ceq $payloadName })
        $descriptorEntries = @($archive.Entries | Where-Object { $_.FullName -ceq $descriptorName })
        if ($payloadEntries.Count -ne 1 -or $descriptorEntries.Count -ne 1) {
            throw "$Label must contain exactly one embedded launch guard and descriptor."
        }
        if ($payloadEntries[0].Length -ne $expectedFile.Length) {
            throw "$Label embedded launch-guard size differs from the reviewed tool."
        }

        $algorithm = [Security.Cryptography.SHA256]::Create()
        $payloadStream = $payloadEntries[0].Open()
        try { $payloadHashBytes = $algorithm.ComputeHash($payloadStream) }
        finally {
            $payloadStream.Dispose()
            $algorithm.Dispose()
        }
        $payloadHash = (($payloadHashBytes | ForEach-Object { $_.ToString('x2') }) -join '')
        if ($payloadHash -cne $expectedHash) {
            throw "$Label embedded launch guard differs from the reviewed tool: $payloadHash"
        }

        $descriptorStream = $descriptorEntries[0].Open()
        $reader = [IO.StreamReader]::new($descriptorStream, [Text.UTF8Encoding]::new($false, $true), $true)
        try { $descriptor = $reader.ReadToEnd() }
        finally {
            $reader.Dispose()
            $descriptorStream.Dispose()
        }
        $expectedDescriptor = "nbidal18-launch-guard`t1`nsha256`t$expectedHash`nsize`t$($expectedFile.Length)`n"
        if ($descriptor -cne $expectedDescriptor -or $descriptor.Contains('\t')) {
            throw "$Label launch-guard descriptor is not the exact reviewed tab-delimited record."
        }
    }
    finally { $archive.Dispose() }
}

function Assert-CompanionRelaunchPayload([string] $CompanionJar, [string] $Label) {
    $archive = [IO.Compression.ZipFile]::OpenRead($CompanionJar)
    try {
        foreach ($requiredClass in @(
            'dev/nbidal18/packcompat/LaunchGuardHandoff.class',
            'dev/nbidal18/packcompat/PrismAutoRelaunch.class',
            'dev/nbidal18/packcompat/PrismLaunchContext.class',
            'dev/nbidal18/packcompat/PrismRelaunchHelper.class',
            'dev/nbidal18/packcompat/PrismRelaunchStandalone.class',
            'dev/nbidal18/packcompat/PrismRelaunchState.class'
        )) {
            if ($null -eq $archive.GetEntry($requiredClass)) {
                throw "$Label is missing the one-click migration component: $requiredClass"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
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
    if ($modVersion -cne $expectedPackCompatVersion) {
        throw "Pack-compat version must be $expectedPackCompatVersion for release $expectedReleaseVersion; found $modVersion"
    }
    $fileName = "$archiveBase-$modVersion.jar"
    $builtJar = Join-Path $packCompatSourceRoot "build\libs\$fileName"
    if (-not (Test-Path -LiteralPath $builtJar -PathType Leaf)) {
        throw "The reproducible pack-compat artifact is missing after build: $builtJar"
    }

    $builtHash = (Get-FileHash -LiteralPath $builtJar -Algorithm SHA256).Hash
    Assert-EmbeddedLaunchGuard $builtJar $guardPath 'Reproducible pack-compat'
    Assert-CompanionRelaunchPayload $builtJar 'Reproducible pack-compat'
    $builtHash = (Get-FileHash -LiteralPath $builtJar -Algorithm SHA256).Hash
    if ($builtHash -cne $reviewedPackCompatSha256) {
        throw "Reproducible pack-compat differs from the frozen reviewed artifact: $builtHash"
    }
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
    $guardArchive = [IO.Compression.ZipFile]::OpenRead($guardPath)
    try {
        $manifestEntry = $guardArchive.GetEntry('META-INF/MANIFEST.MF')
        if (-not $manifestEntry) { throw 'Launch-guard JAR has no META-INF/MANIFEST.MF.' }
        $manifestReader = [IO.StreamReader]::new($manifestEntry.Open())
        try { $manifestText = $manifestReader.ReadToEnd() }
        finally { $manifestReader.Dispose() }
        if ($manifestText -notmatch "(?m)^Implementation-Version: $([regex]::Escape($expectedLaunchGuardVersion))\r?$") {
            throw "Launch-guard Implementation-Version must be $expectedLaunchGuardVersion for release $expectedReleaseVersion."
        }
    }
    finally { $guardArchive.Dispose() }
    $actualHash = (Get-FileHash -LiteralPath $guardPath -Algorithm SHA256).Hash
    if ($actualHash -cne $reviewedLaunchGuardSha256) {
        throw "Reproducible launch guard differs from the frozen reviewed artifact: $actualHash"
    }
    if ($actualHash -ceq $publishedV324LaunchGuardSha256) {
        throw 'Launch guard 1.1.0 is byte-identical to the published v3.2.4 guard; the migration bridge would be untestable.'
    }
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

$generatedPack = Get-Content -LiteralPath (Join-Path $siteRoot 'pack.toml') -Raw
if ($generatedPack -notmatch "(?m)^version = `"$([regex]::Escape($expectedReleaseVersion))`"\r?$") {
    throw "Generated pack.toml is not release $expectedReleaseVersion."
}
$generatedIndex = Get-Content -LiteralPath (Join-Path $siteRoot 'index.toml') -Raw
$generatedStrictManifest = Get-Content -LiteralPath (Join-Path $siteRoot '.nbidal18\strict-manifest.tsv') -Raw
if ($generatedIndex -match '(?im)^file = "nbidal18-launch-guard\.jar"\r?$' -or
        $generatedStrictManifest -match '(?im)\tnbidal18-launch-guard\.jar\r?$' -or
        (Test-Path -LiteralPath (Join-Path $siteRoot 'nbidal18-launch-guard.jar'))) {
    throw 'The standalone launch guard entered the Packwiz site; it must remain only in the Prism shell and embedded companion.'
}

& $guardSmokePath
if ($LASTEXITCODE -ne 0) {
    throw "Launch-guard producer smoke left a nonzero native exit code: $LASTEXITCODE"
}

$sitePackCompat = Join-Path $siteRoot "mods\$($packCompat.FileName)"
if (-not (Test-Path -LiteralPath $sitePackCompat -PathType Leaf) -or
    (Get-FileHash -LiteralPath $sitePackCompat -Algorithm SHA256).Hash -ne $packCompat.Hash) {
    throw "Generated updater site pack-compat JAR differs from the reproducible build: $sitePackCompat"
}
Assert-EmbeddedLaunchGuard $sitePackCompat $guardPath 'Generated updater-site pack-compat'
Assert-CompanionRelaunchPayload $sitePackCompat 'Generated updater-site pack-compat'

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
    foreach ($requiredIdentity in @(
        'name=nbidal18-client',
        'ExportName=nbidal18-client',
        "ExportVersion=$expectedReleaseVersion"
    )) {
        if (-not $instanceCfg.Contains($requiredIdentity)) {
            throw "Final release ZIP instance identity is missing: $requiredIdentity"
        }
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
