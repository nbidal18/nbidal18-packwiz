[CmdletBinding()]
param(
    [string] $JavaPath,
    [string] $PackwizPath,
    [switch] $KeepTemporaryFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$updaterRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$siteRoot = Join-Path $updaterRoot 'site'
$builderPath = Join-Path $releaseRoot '1. setup\support\scripts\build-prism-instance.ps1'
$bootstrapSource = Join-Path $updaterRoot 'tools\packwiz-installer-bootstrap.jar'
$launchGuardSource = Join-Path $updaterRoot 'tools\nbidal18-launch-guard.jar'
$previousReleaseRoot = Join-Path (Split-Path -Parent $releaseRoot) 'nbidal18 v3.2.4'
$previousLaunchGuardSource = Join-Path $previousReleaseRoot '5. updater\tools\nbidal18-launch-guard.jar'
$expectedPreviousLaunchGuardSha256 = '63243A6972BF4B89C0E2DDE79B48F20009781C021AA68D30DCB19063AECCAC45'
$shaderSourceRoot = Join-Path $releaseRoot '2. appearance\shaderpacks'
$privateStillLifeSource = Join-Path $releaseRoot '3. modpack\client\datapacks\Still_Life-1.0-beta1.zip'
$validationReport = Join-Path $updaterRoot 'VALIDATION-REPORT.md'

if ([string]::IsNullOrWhiteSpace($PackwizPath)) {
    $PackwizPath = Join-Path $updaterRoot 'tools\packwiz-current\packwiz.exe'
}
$PackwizPath = [IO.Path]::GetFullPath($PackwizPath)
$applicationData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
if ([string]::IsNullOrWhiteSpace($JavaPath)) {
    $javaCandidates = New-Object Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($applicationData)) {
        $javaCandidates.Add((Join-Path $applicationData 'PrismLauncher\java\java-runtime-delta\bin\java.exe'))
    }
    $pathJava = Get-Command java.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pathJava) { $javaCandidates.Add($pathJava.Source) }
    $resolvedJava = @($javaCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    if ($resolvedJava.Count -eq 0) { throw 'Java was not found in Prism Launcher or PATH. Pass -JavaPath explicitly.' }
    $JavaPath = [string] $resolvedJava[0]
}
$JavaPath = [IO.Path]::GetFullPath($JavaPath)

foreach ($required in @(
    $siteRoot,
    (Join-Path $siteRoot '.nbidal18\strict-manifest.tsv'),
    $builderPath,
    $bootstrapSource,
    $launchGuardSource,
    $previousLaunchGuardSource,
    $shaderSourceRoot,
    $privateStillLifeSource,
    $PackwizPath,
    $JavaPath
)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required path is missing: $required" }
}
if ((Get-FileHash -LiteralPath $previousLaunchGuardSource -Algorithm SHA256).Hash -cne
        $expectedPreviousLaunchGuardSha256) {
    throw "The retained v3.2.4 launch guard is not the exact published artifact: $previousLaunchGuardSource"
}
$shaderArchives = @(Get-ChildItem -LiteralPath $shaderSourceRoot -File -Filter '*.zip' | Sort-Object Name)
if ($shaderArchives.Count -ne 2) { throw "Expected exactly two migration shader ZIPs, found $($shaderArchives.Count)." }

function Write-Utf8NoBom([string] $Path, [string] $Text) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Invoke-PackwizRefresh([string] $WorkingDirectory) {
    Push-Location $WorkingDirectory
    try {
        $output = @(& $PackwizPath refresh 2>&1 | ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0) {
            throw "packwiz refresh failed in $WorkingDirectory`n$($output -join "`n")"
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-LaunchGuard([string] $MinecraftDirectory, [string] $PackUrl) {
    Push-Location $MinecraftDirectory
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $JavaPath -jar '.\nbidal18-launch-guard.jar' $PackUrl 2>&1 | ForEach-Object { "$_" })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($exitCode -ne 0) {
            throw "nbidal18 launch guard failed with exit code $exitCode`n$($output -join "`n")"
        }
        return ,$output
    }
    finally {
        Pop-Location
    }
}

function Invoke-LaunchGuardWithRetry(
    [string] $MinecraftDirectory,
    [string] $PackUrl,
    [ValidateRange(1, 5)] [int] $Attempts = 3
) {
    $failures = New-Object Collections.Generic.List[string]
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try { return (Invoke-LaunchGuard $MinecraftDirectory $PackUrl) }
        catch {
            $failures.Add("Attempt ${attempt}: $($_.Exception.Message)")
            if ($attempt -eq $Attempts) {
                throw "Launch-guard cold install failed after $Attempts attempts.`n$($failures -join "`n")"
            }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
        }
    }
}

function Invoke-LaunchGuardExpectFailure([string] $MinecraftDirectory, [string] $PackUrl) {
    Push-Location $MinecraftDirectory
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $JavaPath -jar '.\nbidal18-launch-guard.jar' $PackUrl 2>&1 | ForEach-Object { "$_" })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($exitCode -eq 0) { throw 'nbidal18 launch guard unexpectedly succeeded during the failure test.' }
        if ($output.Count -eq 0 -or (($output -join "`n") -notmatch '(?i)(failed|error|exception|404|not found|unable)')) {
            throw "Launch-guard failure was not clearly reported.`n$($output -join "`n")"
        }
        return ,$output
    }
    finally {
        Pop-Location
    }
}

function Set-StrictManagedRecords(
    [string] $PackRoot,
    [hashtable] $ManagedFiles,
    [string[]] $RemovePaths = @()
) {
    $manifestPath = Join-Path $PackRoot '.nbidal18\strict-manifest.tsv'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Synthetic Packwiz tree has no strict manifest: $manifestPath"
    }

    $replaceKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relativePath in @($RemovePaths) + @($ManagedFiles.Keys)) {
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
                $relativePath.Contains('\') -or
                $relativePath.StartsWith('/') -or
                $relativePath.Contains("`t") -or
                $relativePath.Contains("`r") -or
                $relativePath.Contains("`n") -or
                $relativePath -match '(^|/)\.\.(/|$)') {
            throw "Unsafe synthetic strict-manifest path: $relativePath"
        }
        [void] $replaceKeys.Add($relativePath)
    }

    $sourceLines = @([IO.File]::ReadAllText($manifestPath) -split "\r?\n")
    if ($sourceLines.Count -eq 0 -or $sourceLines[0] -ne "nbidal18-strict-manifest`t1") {
        throw "Synthetic strict manifest has an unsupported header: $manifestPath"
    }
    $outputLines = New-Object Collections.Generic.List[string]
    $existingManaged = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $sourceLines) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $match = [regex]::Match($line, '^managed\t([0-9a-f]{64})\t(.+)$')
        if ($match.Success) {
            $relativePath = $match.Groups[2].Value
            if (-not $existingManaged.Add($relativePath)) {
                throw "Duplicate managed record in synthetic strict manifest: $relativePath"
            }
            if ($replaceKeys.Contains($relativePath)) { continue }
        }
        $outputLines.Add($line)
    }

    foreach ($relativePath in @($ManagedFiles.Keys | Sort-Object)) {
        $payloadPath = [string] $ManagedFiles[$relativePath]
        if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
            throw "Synthetic managed canary is missing: $payloadPath"
        }
        $sha256 = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $outputLines.Add("managed`t$sha256`t$relativePath")
    }
    Write-Utf8NoBom $manifestPath (($outputLines -join "`n") + "`n")
}

function Get-StrictSeedRules([string] $PackRoot) {
    $manifestPath = Join-Path $PackRoot '.nbidal18\strict-manifest.tsv'
    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        $fields = @($line -split "`t")
        if ($fields.Count -eq 3 -and $fields[0] -eq 'seed') {
            [pscustomobject]@{ Template = $fields[1]; Target = $fields[2] }
        }
    }
}

function Assert-IntegrityAttestation([string] $MinecraftDirectory) {
    $manifestPath = Join-Path $MinecraftDirectory '.nbidal18\strict-manifest.tsv'
    $attestationPath = Join-Path $MinecraftDirectory '.nbidal18\integrity-attestation.tsv'
    if (-not (Test-Path -LiteralPath $attestationPath -PathType Leaf)) {
        throw "Successful launch guard did not write an integrity attestation: $attestationPath"
    }
    $lines = @(Get-Content -LiteralPath $attestationPath)
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($lines.Count -ne 3 -or
            $lines[0] -ne "nbidal18-integrity-attestation`t1" -or
            $lines[1] -ne "manifest-sha256`t$manifestHash" -or
            $lines[2] -notmatch '^verified-at-utc\t\d{4}-\d{2}-\d{2}T') {
        throw 'Integrity attestation is absent, malformed, or does not match the installed strict manifest.'
    }
    return $manifestHash
}

function Assert-AttestationAbsent([string] $MinecraftDirectory) {
    $attestationPath = Join-Path $MinecraftDirectory '.nbidal18\integrity-attestation.tsv'
    if (Test-Path -LiteralPath $attestationPath) {
        throw 'A failed launch guard left a stale integrity attestation.'
    }
}

function Assert-QuarantinedFiles([string] $MinecraftDirectory, [hashtable] $ExpectedHashes) {
    $quarantineRoot = Join-Path $MinecraftDirectory '.nbidal18\quarantine'
    foreach ($relativePath in $ExpectedHashes.Keys) {
        $livePath = Join-Path $MinecraftDirectory $relativePath.Replace('/', '\')
        if (Test-Path -LiteralPath $livePath) {
            throw "Unauthorized strict content survived outside quarantine: $relativePath"
        }
        $matches = @(
            if (Test-Path -LiteralPath $quarantineRoot -PathType Container) {
                foreach ($run in Get-ChildItem -LiteralPath $quarantineRoot -Directory -Force) {
                    $candidate = Join-Path $run.FullName $relativePath.Replace('/', '\')
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate -Force }
                }
            }
        )
        if ($matches.Count -eq 0) {
            throw "Unauthorized strict content was not recoverably quarantined: $relativePath"
        }
        $matchingHashes = @($matches | Where-Object {
            (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $ExpectedHashes[$relativePath]
        })
        if ($matchingHashes.Count -eq 0) {
            throw "Quarantined content does not match its original bytes: $relativePath"
        }
    }
}

function Get-TreeHash([string] $Root) {
    $lines = New-Object Collections.Generic.List[string]
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines.Add("$relative`t$hash")
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PreservationHashes([string[]] $Paths) {
    $result = @{}
    foreach ($path in $Paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Preservation sentinel is missing: $path" }
        $result[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    return $result
}

function Assert-PreservationHashes([hashtable] $Expected) {
    foreach ($path in $Expected.Keys) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Launch guard removed preserved file: $path" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual -ne $Expected[$path]) { throw "Launch guard changed preserved file: $path" }
    }
}

function Get-IndexedInstallRecords([string] $PackRoot) {
    $indexPath = Join-Path $PackRoot 'index.toml'
    $indexContent = [IO.File]::ReadAllText($indexPath)
    $fileMatches = [regex]::Matches($indexContent, '(?m)^file = "([^"]+)"\r?$')
    if ($fileMatches.Count -eq 0) { throw "Packwiz index contains no files: $indexPath" }

    foreach ($fileMatch in $fileMatches) {
        $indexedPath = $fileMatch.Groups[1].Value
        if ($indexedPath.StartsWith('/') -or $indexedPath.Contains('\') -or $indexedPath -match '(^|/)\.\.(/|$)') {
            throw "Unsafe Packwiz index path: $indexedPath"
        }
        $sourcePath = Join-Path $PackRoot $indexedPath.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Indexed Packwiz source is missing: $indexedPath"
        }

        if ($indexedPath.EndsWith('.pw.toml', [StringComparison]::OrdinalIgnoreCase)) {
            $metadataText = [IO.File]::ReadAllText($sourcePath)
            $filenameMatch = [regex]::Match($metadataText, '(?m)^filename = "([^"]+)"\r?$')
            $hashFormatMatch = [regex]::Match($metadataText, '(?m)^hash-format = "([^"]+)"\r?$')
            $hashMatch = [regex]::Match($metadataText, '(?m)^hash = "([0-9a-fA-F]+)"\r?$')
            if (-not $filenameMatch.Success -or -not $hashFormatMatch.Success -or -not $hashMatch.Success) {
                throw "Incomplete Packwiz metadata: $indexedPath"
            }
            $filename = $filenameMatch.Groups[1].Value
            if ($filename.Contains('/') -or $filename.Contains('\') -or $filename -in @('.', '..')) {
                throw "Unsafe Packwiz download filename in ${indexedPath}: $filename"
            }
            $parent = [IO.Path]::GetDirectoryName($indexedPath.Replace('/', '\'))
            $targetPath = if ([string]::IsNullOrWhiteSpace($parent)) {
                $filename
            }
            else {
                $parent.Replace('\', '/') + '/' + $filename
            }
            [pscustomobject]@{
                TargetPath = $targetPath
                HashAlgorithm = $hashFormatMatch.Groups[1].Value.ToUpperInvariant()
                ExpectedHash = $hashMatch.Groups[1].Value.ToLowerInvariant()
            }
        }
        else {
            [pscustomobject]@{
                TargetPath = $indexedPath
                HashAlgorithm = 'SHA256'
                ExpectedHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }
}

function Assert-ManagedInstall([string] $MinecraftDirectory, [object[]] $ExpectedRecords) {
    if ($ExpectedRecords.Count -eq 0) { throw 'No managed install records were supplied.' }
    foreach ($record in $ExpectedRecords) {
        $installedPath = Join-Path $MinecraftDirectory $record.TargetPath.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
            throw "Cold install is missing managed file: $($record.TargetPath)"
        }
        $actualHash = (Get-FileHash -LiteralPath $installedPath -Algorithm $record.HashAlgorithm).Hash.ToLowerInvariant()
        if ($actualHash -ne $record.ExpectedHash) {
            throw "Cold install hash mismatch: $($record.TargetPath)"
        }
    }
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint] $listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('n18v-' + [guid]::NewGuid().ToString('N'))
$temporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
$expectedTempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\n18v-'
if (-not $temporaryRoot.StartsWith($expectedTempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe validation directory: $temporaryRoot"
}

$serverProcess = $null
$startedAt = Get-Date
$failure = $null

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null

    # Static site freshness and privacy gates.
    $freshnessCopy = Join-Path $temporaryRoot 'freshness-site'
    Copy-Item -LiteralPath $siteRoot -Destination $freshnessCopy -Recurse
    $packBefore = (Get-FileHash -LiteralPath (Join-Path $freshnessCopy 'pack.toml') -Algorithm SHA256).Hash
    $indexBefore = (Get-FileHash -LiteralPath (Join-Path $freshnessCopy 'index.toml') -Algorithm SHA256).Hash
    Invoke-PackwizRefresh $freshnessCopy
    $packAfter = (Get-FileHash -LiteralPath (Join-Path $freshnessCopy 'pack.toml') -Algorithm SHA256).Hash
    $indexAfter = (Get-FileHash -LiteralPath (Join-Path $freshnessCopy 'index.toml') -Algorithm SHA256).Hash
    if ($packBefore -ne $packAfter -or $indexBefore -ne $indexAfter) {
        throw 'The published Packwiz site is stale; packwiz refresh changed pack.toml or index.toml.'
    }

    $indexText = [IO.File]::ReadAllText((Join-Path $siteRoot 'index.toml'))
    $indexedSourcePaths = @([regex]::Matches($indexText, '(?m)^file = "([^"]+)"\r?$') | ForEach-Object { $_.Groups[1].Value })
    $forbiddenIndexedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($seedRule in @(Get-StrictSeedRules $siteRoot)) { [void] $forbiddenIndexedFiles.Add($seedRule.Target) }
    foreach ($forbidden in @(
        'nbidal18-launch-guard.jar',
        'packwiz-installer-bootstrap.jar',
        'datapacks/Still_Life-1.0-beta1.zip',
        'config/controlify.json',
        'config/euphoria_patcher/.data.json',
        'config/etf_warnings.json',
        'config/jade/usernamecache.json',
        'config/presencefootsteps/updater.json',
        'config/resourceful-config-web.json',
        'config/sodium-fingerprint.json',
        'config/voicechat/username-cache.json'
    )) { [void] $forbiddenIndexedFiles.Add($forbidden) }
    $forbiddenIndexedPrefixes = @(
        'config/crash_assistant/',
        'config/jei/world/',
        'config/spark/tmp/',
        'CustomSkinLoader/',
        'skin_overrides/',
        'cape_overrides/',
        'vinurl/'
    )
    foreach ($indexedSourcePath in $indexedSourcePaths) {
        if ($forbiddenIndexedFiles.Contains($indexedSourcePath) -or
                @($forbiddenIndexedPrefixes | Where-Object {
                    $indexedSourcePath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0) {
            throw "Forbidden player/private path is indexed: $indexedSourcePath"
        }
    }
    $indexedCustomSkinLoaderPaths = @(
        $indexedSourcePaths |
            Where-Object { $_.StartsWith('CustomSkinLoader/', [StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object
    )
    if ($indexedCustomSkinLoaderPaths.Count -ne 0) {
        throw "The retired CustomSkinLoader tree must be absent from the public index; found: $($indexedCustomSkinLoaderPaths -join ', ')"
    }
    $strictManifestLines = @(
        Get-Content -LiteralPath (Join-Path $siteRoot '.nbidal18\strict-manifest.tsv')
    )
    foreach ($standaloneTool in @('nbidal18-launch-guard.jar', 'packwiz-installer-bootstrap.jar')) {
        if (@($strictManifestLines | Where-Object {
                    $_ -match ('(?i)\t' + [regex]::Escape($standaloneTool) + '$')
                }).Count -ne 0) {
            throw "The standalone launcher tool must not enter the strict manifest: $standaloneTool"
        }
    }
    if (@($strictManifestLines | Where-Object { $_ -ceq "strict-dir`tCustomSkinLoader" }).Count -ne 1) {
        throw 'The retired CustomSkinLoader root must remain an exact-empty strict directory.'
    }
    $customSkinLoaderExceptions = @($strictManifestLines | Where-Object {
        $_ -cne "strict-dir`tCustomSkinLoader" -and $_ -match '(?i)\tCustomSkinLoader(?:/|$)'
    })
    if ($customSkinLoaderExceptions.Count -ne 0) {
        throw "The retired CustomSkinLoader root must have no managed, personal, runtime, or prefix exceptions: $($customSkinLoaderExceptions -join '; ')"
    }
    if ($indexText -match 'file = "shaderpacks/[^"]+\.zip(?:\.txt)?"') {
        throw 'A raw shader archive or sidecar entered the Packwiz index instead of official metadata.'
    }
    if (Test-Path -LiteralPath (Join-Path $siteRoot 'datapacks\Still_Life-1.0-beta1.zip')) {
        throw 'Still Life is physically present in the public update site.'
    }
    $publishedShaderRoot = Join-Path $siteRoot 'shaderpacks'
    $rawPublishedShaders = @(
        if (Test-Path -LiteralPath $publishedShaderRoot -PathType Container) {
            Get-ChildItem -LiteralPath $publishedShaderRoot -File | Where-Object { $_.Extension -ieq '.zip' -or $_.Name -like '*.zip.txt' }
        }
    )
    if ($rawPublishedShaders.Count -gt 0) {
        throw "Raw shader content is physically present in the public update site: $($rawPublishedShaders.Name -join ', ')"
    }

    foreach ($metadata in Get-ChildItem -LiteralPath $siteRoot -Recurse -Filter '*.pw.toml' -File) {
        $urlLine = Select-String -LiteralPath $metadata.FullName -Pattern '^url = "([^"]+)"$' | Select-Object -First 1
        if (-not $urlLine) { throw "Metadata has no download URL: $($metadata.FullName)" }
        $url = $urlLine.Matches[0].Groups[1].Value
        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref] $uri) -or $uri.Scheme -ne 'https') {
            throw "Metadata URL is not absolute HTTPS: $url"
        }
        if ($url -match 'OWNER|REPOSITORY|localhost|127\.0\.0\.1|example\.com') {
            throw "Metadata URL contains a placeholder or local host: $url"
        }
    }

    # Create A/B manifests to prove add, overwrite, and removal behavior.
    $siteA = Join-Path $temporaryRoot 'site-a'
    $siteB = Join-Path $temporaryRoot 'site-b'
    $siteFailure = Join-Path $temporaryRoot 'site-failure'
    $published = Join-Path $temporaryRoot 'published'
    Copy-Item -LiteralPath $siteRoot -Destination $siteA -Recurse
    $siteAConfigCanary = Join-Path $siteA 'config\__validation_overwrite.txt'
    $siteARemoveCanary = Join-Path $siteA 'mods\__validation_remove.jar'
    Write-Utf8NoBom $siteAConfigCanary "release-A`n"
    Write-Utf8NoBom $siteARemoveCanary "validation-mod-A`n"
    Set-StrictManagedRecords $siteA @{
        'config/__validation_overwrite.txt' = $siteAConfigCanary
        'mods/__validation_remove.jar' = $siteARemoveCanary
    }
    Invoke-PackwizRefresh $siteA
    if (-not ([IO.File]::ReadAllText((Join-Path $siteA 'index.toml')).Contains('mods/__validation_remove.jar'))) {
        throw 'Release A canaries were not indexed.'
    }

    Copy-Item -LiteralPath $siteA -Destination $siteB -Recurse
    $siteBConfigCanary = Join-Path $siteB 'config\__validation_overwrite.txt'
    $siteBAddedCanary = Join-Path $siteB 'mods\__validation_added.jar'
    Write-Utf8NoBom $siteBConfigCanary "release-B`n"
    Remove-Item -LiteralPath (Join-Path $siteB 'mods\__validation_remove.jar') -Force
    Write-Utf8NoBom $siteBAddedCanary "validation-mod-B`n"
    Set-StrictManagedRecords $siteB @{
        'config/__validation_overwrite.txt' = $siteBConfigCanary
        'mods/__validation_added.jar' = $siteBAddedCanary
    } -RemovePaths @('mods/__validation_remove.jar')
    Invoke-PackwizRefresh $siteB
    $indexB = [IO.File]::ReadAllText((Join-Path $siteB 'index.toml'))
    if (-not $indexB.Contains('mods/__validation_added.jar') -or $indexB.Contains('mods/__validation_remove.jar')) {
        throw 'Release B add/remove index assertions failed.'
    }

    Copy-Item -LiteralPath $siteA -Destination $siteFailure -Recurse
    $siteFailureConfigCanary = Join-Path $siteFailure 'config\__validation_overwrite.txt'
    $siteFailureMissingCanary = Join-Path $siteFailure 'mods\__validation_missing.jar'
    Write-Utf8NoBom $siteFailureConfigCanary "failed-release-must-not-apply`n"
    Write-Utf8NoBom $siteFailureMissingCanary "unavailable-payload`n"
    Set-StrictManagedRecords $siteFailure @{
        'config/__validation_overwrite.txt' = $siteFailureConfigCanary
        'mods/__validation_missing.jar' = $siteFailureMissingCanary
    }
    Invoke-PackwizRefresh $siteFailure
    Remove-Item -LiteralPath $siteFailureMissingCanary -Force
    Copy-Item -LiteralPath $siteA -Destination $published -Recurse

    # Build a localhost-only migration ZIP for isolated testing.
    $port = Get-FreeTcpPort
    $packUrl = "http://127.0.0.1:$port/pack.toml"
    $testZip = Join-Path $temporaryRoot 'nbidal18-client-local-validation.zip'
    & $builderPath -OutputPath $testZip -UpdateUrl $packUrl -AllowInsecureLocalhost
    if (-not (Test-Path -LiteralPath $testZip -PathType Leaf)) { throw 'Migration test ZIP was not created.' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($testZip)
    try {
        $requiredEntries = @(
            '.packignore',
            'instance.cfg',
            'mmc-pack.json',
            'server-icon.png',
            'minecraft/nbidal18-launch-guard.jar',
            'minecraft/packwiz-installer-bootstrap.jar'
        )
        $allowedEntries = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($requiredEntry in $requiredEntries) { [void] $allowedEntries.Add($requiredEntry) }
        $entryNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name.Contains('\') -or $name.StartsWith('/') -or $name -match '(^|/)\.\.(/|$)') {
                throw "Unsafe ZIP entry: $name"
            }
            if (-not $entryNames.Add($name)) { throw "Case-insensitive duplicate ZIP entry: $name" }
            if (-not $allowedEntries.Contains($name)) {
                throw "Thin migration ZIP contains a managed, private, player-state, or unexpected payload: $name"
            }
        }
        foreach ($allowedEntry in $allowedEntries) {
            if (-not $entryNames.Contains($allowedEntry)) { throw "Migration ZIP entry is missing: $allowedEntry" }
        }
        if ($entryNames.Count -ne $allowedEntries.Count) { throw 'Thin migration ZIP entry count does not match its strict allowlist.' }
    }
    finally {
        $archive.Dispose()
    }

    $instanceRoot = Join-Path $temporaryRoot 'instance'
    [IO.Compression.ZipFile]::ExtractToDirectory($testZip, $instanceRoot)
    $minecraft = Join-Path $instanceRoot 'minecraft'

    $bootstrapInstalled = Join-Path $minecraft 'packwiz-installer-bootstrap.jar'
    if ((Get-FileHash -LiteralPath $bootstrapInstalled -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $bootstrapSource -Algorithm SHA256).Hash) {
        throw 'Migration ZIP bootstrap JAR does not match the official local source.'
    }
    $launchGuardInstalled = Join-Path $minecraft 'nbidal18-launch-guard.jar'
    if ((Get-FileHash -LiteralPath $launchGuardInstalled -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $launchGuardSource -Algorithm SHA256).Hash) {
        throw 'Migration ZIP launch-guard JAR does not match the reviewed local source.'
    }
    foreach ($unexpectedThinPath in @(
        'mods',
        'resourcepacks',
        'shaderpacks',
        'datapacks',
        'config',
        'defaultconfigs',
        'vinurl',
        'options.txt',
        'options.amecsapi.txt',
        'servers.dat',
        'credits.txt',
        'THIRD-PARTY-NOTICES.md',
        'licenses'
    )) {
        if (Test-Path -LiteralPath (Join-Path $minecraft $unexpectedThinPath)) {
            throw "Thin migration extraction already contains a managed/private/player payload: $unexpectedThinPath"
        }
    }
    $instanceCfg = [IO.File]::ReadAllText((Join-Path $instanceRoot 'instance.cfg'))
    if ($instanceCfg -match '(?m)^ConfigVersion=') {
        throw 'Migration instance.cfg declares ConfigVersion before Prism has serialized the quoted pre-launch command.'
    }
    $preLaunchLines = @($instanceCfg -split "\r?\n" | Where-Object { $_ -match '^PreLaunchCommand=' })
    if ($preLaunchLines.Count -ne 1 -or $preLaunchLines[0].Contains('packwiz-installer-bootstrap.jar')) {
        throw 'Migration instance must have exactly one guarded pre-launch command, never the legacy direct-Packwiz command.'
    }
    foreach ($requiredText in @('name=nbidal18-client', 'ExportName=nbidal18-client', 'ExportVersion=3.2.8', 'OverrideCommands=true', "PreLaunchCommand=`"`$INST_JAVA`" -jar nbidal18-launch-guard.jar $packUrl")) {
        if (-not $instanceCfg.Contains($requiredText)) { throw "instance.cfg assertion failed: $requiredText" }
    }
    $mmc = Get-Content -LiteralPath (Join-Path $instanceRoot 'mmc-pack.json') -Raw | ConvertFrom-Json
    $minecraftComponent = @($mmc.components | Where-Object { $_.uid -eq 'net.minecraft' })
    $fabricComponent = @($mmc.components | Where-Object { $_.uid -eq 'net.fabricmc.fabric-loader' })
    if ($minecraftComponent.Count -ne 1 -or $minecraftComponent[0].version -ne '1.21.1') { throw 'mmc-pack.json Minecraft version mismatch.' }
    if ($fabricComponent.Count -ne 1 -or $fabricComponent[0].version -ne '0.19.3') { throw 'mmc-pack.json Fabric version mismatch.' }

    # Seed/player/runtime state must survive, while every unknown strict-root file
    # must be moved to a recoverable quarantine before attestation.
    $seedRules = @(Get-StrictSeedRules $siteA)
    if ($seedRules.Count -eq 0) { throw 'Synthetic release A has no seed-once settings.' }
    $seedTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($seedRule in $seedRules) {
        if (-not $seedTargets.Add($seedRule.Target)) { throw "Duplicate seed target: $($seedRule.Target)" }
    }
    foreach ($requiredSeedTarget in @('options.txt', 'config/iris.properties')) {
        if (-not $seedTargets.Contains($requiredSeedTarget)) { throw "Required mixed-setting seed is absent: $requiredSeedTarget" }
    }

    $installedStillLife = Join-Path $minecraft 'datapacks\Still_Life-1.0-beta1.zip'
    New-Item -ItemType Directory -Path (Split-Path -Parent $installedStillLife) -Force | Out-Null
    Copy-Item -LiteralPath $privateStillLifeSource -Destination $installedStillLife -Force
    Write-Utf8NoBom (Join-Path $minecraft 'saves\__validation\keep.txt') "keep-save`n"
    Write-Utf8NoBom (Join-Path $minecraft 'screenshots\__validation.txt') "keep-screenshot`n"
    Write-Utf8NoBom (Join-Path $minecraft 'vinurl\downloads\__player-audio.ogg') "player-vinurl-download`n"
    Write-Utf8NoBom (Join-Path $minecraft 'vinurl\executables\__runtime-helper.exe') "runtime-vinurl-helper`n"
    Write-Utf8NoBom (Join-Path $minecraft 'skin_overrides\__validation-player.txt') "player-skin-selection`n"
    Write-Utf8NoBom (Join-Path $minecraft 'skin_overrides\library\__validation-player.png') "player-skin-library`n"
    Write-Utf8NoBom (Join-Path $minecraft 'cape_overrides\__validation-player.txt') "player-cape-selection`n"
    Write-Utf8NoBom (Join-Path $minecraft 'cape_overrides\library\__validation-player.png') "player-cape-library`n"
    Write-Utf8NoBom (Join-Path $minecraft "shaderpacks\$($shaderArchives[0].Name).txt") "approved-shader-sidecar-setting`n"
    Write-Utf8NoBom (Join-Path $minecraft 'options.txt') "resourcePacks:[`"file/__unauthorized.zip`"]`nincompatibleResourcePacks:[`"file/__unauthorized.zip`"]`nkey_key.forward:key.keyboard.up`nvalidationPreference:keep`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\iris.properties') "shaderPack=__unauthorized.zip`nenableShaders=true`nallowUnknownShaders=true`nvalidationPreference=keep`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\controlify.json') "{`n  `"global`": { `"reach_around`": `"ON`" },`n  `"validationController`": `"keep`"`n}`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\voicechat\voicechat-client.properties') "player-voice-setting=true`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\sodium-fingerprint.json') "{ playerGenerated: true }`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\euphoria_patcher\.data.json') "{ runtimeGenerated: true }`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\jei\world\__validation\state.ini') "player-world-state=true`n"
    foreach ($generatedCacheCanary in @(
        '.fabric/processedMods/__validation-cache.jar',
        '.fabric/remappedJars/__validation-cache.jar',
        '.fabric/tmp/__validation-cache.tmp',
        'dynamic-resource-pack-cache/__validation/generated.json'
    )) {
        Write-Utf8NoBom (Join-Path $minecraft $generatedCacheCanary.Replace('/', '\')) "generated-cache-canary`n"
    }
    $preservedFabricState = Join-Path $minecraft '.fabric\preserved-state\keep.txt'
    Write-Utf8NoBom $preservedFabricState "unrelated-fabric-state`n"

    $euphoriaGeneratedRelative = 'shaderpacks/ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3'
    Write-Utf8NoBom (Join-Path $minecraft "$($euphoriaGeneratedRelative.Replace('/', '\'))\__validation-stale.txt") "disposable-generated-shader-tree`n"
    $unauthorizedRelativePaths = @(
        'mods/__unknown-local.jar',
        'resourcepacks/__unknown-local.zip',
        'shaderpacks/__unknown-local.zip',
        'datapacks/__unknown-local.zip',
        'moonlight-global-datapacks/__unknown-global.zip',
        'villagerpacks/__unknown-villager-pack.zip',
        'server-resource-packs/__unknown-server-pack.zip',
        'CustomSkinLoader/CustomSkinLoader.json',
        'CustomSkinLoader/Core/CustomSkinLoader-Common.jar',
        'CustomSkinLoader/ProfileCache/__stale-profile.json',
        'CustomSkinLoader/Plugins/__unknown-plugin.jar',
        'CustomSkinLoader/ExtraList/__unknown-provider.json',
        'config/__unknown-local.toml'
    )
    foreach ($relativePath in $unauthorizedRelativePaths) {
        Write-Utf8NoBom (Join-Path $minecraft $relativePath.Replace('/', '\')) "unauthorized-$relativePath`n"
    }
    $quarantineHashes = @{}
    foreach ($relativePath in $unauthorizedRelativePaths) {
        $quarantineHashes[$relativePath] = (Get-FileHash -LiteralPath (Join-Path $minecraft $relativePath.Replace('/', '\')) -Algorithm SHA256).Hash
    }

    $preservedPaths = New-Object Collections.Generic.List[string]
    foreach ($path in @(
        (Join-Path $minecraft 'saves\__validation\keep.txt'),
        (Join-Path $minecraft 'screenshots\__validation.txt'),
        (Join-Path $minecraft "shaderpacks\$($shaderArchives[0].Name).txt"),
        $installedStillLife,
        (Join-Path $minecraft 'vinurl\downloads\__player-audio.ogg'),
        (Join-Path $minecraft 'vinurl\executables\__runtime-helper.exe'),
        (Join-Path $minecraft 'skin_overrides\__validation-player.txt'),
        (Join-Path $minecraft 'skin_overrides\library\__validation-player.png'),
        (Join-Path $minecraft 'cape_overrides\__validation-player.txt'),
        (Join-Path $minecraft 'cape_overrides\library\__validation-player.png'),
        (Join-Path $minecraft 'config\voicechat\voicechat-client.properties'),
        (Join-Path $minecraft 'config\sodium-fingerprint.json'),
        (Join-Path $minecraft 'config\euphoria_patcher\.data.json'),
        (Join-Path $minecraft 'config\jei\world\__validation\state.ini'),
        $preservedFabricState
    )) { $preservedPaths.Add($path) }
    $preservationHashes = Get-PreservationHashes @($preservedPaths.ToArray())

    $expectedSeededTargets = @($seedRules | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $minecraft $_.Target.Replace('/', '\')))
    } | ForEach-Object { $_.Target })

    $expectedManagedRecords = @(Get-IndexedInstallRecords $siteA)
    $expectedManagedTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($expectedRecord in $expectedManagedRecords) {
        if (-not $expectedManagedTargets.Add($expectedRecord.TargetPath)) {
            throw "Multiple Packwiz index entries install the same path: $($expectedRecord.TargetPath)"
        }
    }
    $retiredAutoHudBridgeRecords = @($expectedManagedRecords | Where-Object {
        $_.TargetPath -match '^mods/nbidal18-autohud-(?:thermoo-bridge|vitals-sync)-[^/]+\.jar$'
    })
    if ($retiredAutoHudBridgeRecords.Count -ne 0) {
        throw "Retired loose Auto HUD bridge JARs remain indexed: $($retiredAutoHudBridgeRecords.TargetPath -join ', ')"
    }

    # Serve A and prove that a thin import cold-installs every managed payload.
    $serverOut = Join-Path $temporaryRoot 'packwiz-server.out.log'
    $serverErr = Join-Path $temporaryRoot 'packwiz-server.err.log'
    $serverProcess = Start-Process -FilePath $PackwizPath `
        -ArgumentList @('serve', '--basic', '--port', "$port") `
        -WorkingDirectory $published `
        -WindowStyle Hidden `
        -RedirectStandardOutput $serverOut `
        -RedirectStandardError $serverErr `
        -PassThru

    $serverReady = $false
    for ($attempt = 0; $attempt -lt 80; $attempt++) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $packUrl -TimeoutSec 2
            if ($response.StatusCode -eq 200) { $serverReady = $true; break }
        }
        catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $serverReady) { throw "Local Packwiz server did not become ready. Logs: $serverOut $serverErr" }

    $firstOutput = Invoke-LaunchGuardWithRetry $minecraft $packUrl -Attempts 4
    Write-Utf8NoBom (Join-Path $temporaryRoot 'launch-guard-first.log') (($firstOutput -join "`n") + "`n")
    $firstPasses = @($firstOutput | Where-Object { $_ -match '^\[nbidal18-launch-guard\] Running Packwiz (normal update|forced hash-validation) pass\.\.\.$' })
    if ($firstPasses.Count -ne 2) { throw 'Cold install did not complete both launch-guard Packwiz passes.' }
    if (-not (Test-Path -LiteralPath (Join-Path $minecraft 'packwiz-installer.jar'))) { throw 'First run did not download packwiz-installer.jar.' }
    $packwizStatePath = Join-Path $minecraft 'packwiz.json'
    if (-not (Test-Path -LiteralPath $packwizStatePath)) { throw 'First run did not create packwiz.json.' }
    Get-Content -LiteralPath $packwizStatePath -Raw | ConvertFrom-Json | Out-Null
    Assert-ManagedInstall $minecraft $expectedManagedRecords
    $installedAutoHudConfig = Get-Content -LiteralPath (Join-Path $minecraft 'config\autohud.json5') -Raw | ConvertFrom-Json
    if ($installedAutoHudConfig.ticksRevealed -ne 250) {
        throw "Release 3.2.8 must install the 250-tick Auto HUD reveal timeout; found $($installedAutoHudConfig.ticksRevealed)."
    }
    $installedVoiceServerConfig = @(Get-Content -LiteralPath (Join-Path $minecraft 'config\voicechat\voicechat-server.properties'))
    if (@($installedVoiceServerConfig | Where-Object { $_ -ceq 'port=27051' }).Count -ne 1 -or
            @($installedVoiceServerConfig | Where-Object { $_ -match '^port=(?!27051$)' }).Count -ne 0) {
        throw 'Release 3.2.8 must install exactly voice-chat UDP port 27051.'
    }
    foreach ($shaderArchive in $shaderArchives) {
        $installedShader = Join-Path (Join-Path $minecraft 'shaderpacks') $shaderArchive.Name
        if ((Get-FileHash -LiteralPath $installedShader -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $shaderArchive.FullName -Algorithm SHA256).Hash) {
            throw "Packwiz-installed shader differs from the reviewed official source: $($shaderArchive.Name)"
        }
    }
    if ([IO.File]::ReadAllText((Join-Path $minecraft 'config\__validation_overwrite.txt')) -ne "release-A`n") { throw 'Release A overwrite canary is wrong.' }
    if ([IO.File]::ReadAllText((Join-Path $minecraft 'mods\__validation_remove.jar')) -ne "validation-mod-A`n") { throw 'Release A managed-mod canary is wrong.' }
    Assert-PreservationHashes $preservationHashes
    Assert-QuarantinedFiles $minecraft $quarantineHashes
    foreach ($purgedCacheRoot in @(
        '.fabric\processedMods',
        '.fabric\remappedJars',
        '.fabric\tmp',
        'dynamic-resource-pack-cache',
        $euphoriaGeneratedRelative.Replace('/', '\')
    )) {
        if (Test-Path -LiteralPath (Join-Path $minecraft $purgedCacheRoot)) {
            throw "Generated loadable cache survived the launch guard: $purgedCacheRoot"
        }
    }
    $generatedQuarantineMatches = @(Get-ChildItem -LiteralPath (Join-Path $minecraft '.nbidal18\quarantine') `
        -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -in @('__validation-stale.txt', 'generated.json')
        })
    if ($generatedQuarantineMatches.Count -ne 0) {
        throw 'Disposable generated cache content accumulated in quarantine.'
    }

    foreach ($seedRule in $seedRules) {
        $targetPath = Join-Path $minecraft $seedRule.Target.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            throw "Launch guard did not materialize seed-once setting: $($seedRule.Target)"
        }
        $preservationHashes[$targetPath] = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
    }
    foreach ($expectedSeededTarget in $expectedSeededTargets) {
        if (($firstOutput -join "`n") -notmatch [regex]::Escape("Seeded first-run player setting: $expectedSeededTarget")) {
            throw "Launch guard did not report seeding an absent setting: $expectedSeededTarget"
        }
    }

    $optionsRule = @($seedRules | Where-Object { $_.Target -eq 'options.txt' })
    $irisRule = @($seedRules | Where-Object { $_.Target -eq 'config/iris.properties' })
    if ($optionsRule.Count -ne 1 -or $irisRule.Count -ne 1) { throw 'Mixed-setting seed rules are ambiguous.' }
    $optionsTemplateLines = @(Get-Content -LiteralPath (Join-Path $minecraft $optionsRule[0].Template.Replace('/', '\')))
    $installedOptionsLines = @(Get-Content -LiteralPath (Join-Path $minecraft 'options.txt'))
    foreach ($key in @('resourcePacks', 'incompatibleResourcePacks')) {
        $canonical = @($optionsTemplateLines | Where-Object { $_.StartsWith("${key}:", [StringComparison]::Ordinal) })
        $installed = @($installedOptionsLines | Where-Object { $_.StartsWith("${key}:", [StringComparison]::Ordinal) })
        if ($canonical.Count -ne 1 -or $installed.Count -ne 1 -or $installed[0] -ne $canonical[0]) {
            throw "Launch guard did not enforce the canonical options.txt ${key} line."
        }
    }
    if ($installedOptionsLines -notcontains 'validationPreference:keep') {
        throw 'Launch guard reset an unrelated options.txt player preference.'
    }

    $irisTemplateLines = @(Get-Content -LiteralPath (Join-Path $minecraft $irisRule[0].Template.Replace('/', '\')))
    $installedIrisLines = @(Get-Content -LiteralPath (Join-Path $minecraft 'config\iris.properties'))
    $canonicalShader = @($irisTemplateLines | Where-Object { $_ -match '^shaderPack=' })
    $installedShaderSetting = @($installedIrisLines | Where-Object { $_ -match '^shaderPack=' })
    if ($canonicalShader.Count -ne 1 -or $installedShaderSetting.Count -ne 1 -or $installedShaderSetting[0] -ne $canonicalShader[0]) {
        throw 'Launch guard did not replace an unapproved Iris shader selection with the canonical selection.'
    }
    if (@($installedIrisLines | Where-Object { $_ -eq 'allowUnknownShaders=false' }).Count -ne 1 -or
            $installedIrisLines -notcontains 'validationPreference=keep') {
        throw 'Launch guard did not enforce Iris policy while retaining unrelated player settings.'
    }

    $controlifyPath = Join-Path $minecraft 'config\controlify.json'
    $controlify = Get-Content -LiteralPath $controlifyPath -Raw | ConvertFrom-Json
    if ($controlify.global.reach_around -ne 'OFF' -or $controlify.validationController -ne 'keep') {
        throw 'Launch guard did not disable Controlify reach-around while preserving controller state.'
    }
    $preservationHashes[$controlifyPath] = (Get-FileHash -LiteralPath $controlifyPath -Algorithm SHA256).Hash
    $releaseAManifestHash = Assert-IntegrityAttestation $minecraft

    # Prove that an already-guarded instance can receive the reviewed next
    # guard from the managed companion without reimporting or changing Prism's
    # outer shell. Fabric calls this same package-private updater from the
    # client entrypoint; the tiny harness exercises the production method with
    # only the installed companion on its classpath.
    $companionRecords = @($expectedManagedRecords | Where-Object {
        $_.TargetPath -match '^mods/nbidal18-pack-compat-[^/]+\.jar$'
    })
    if ($companionRecords.Count -ne 1) {
        throw 'Expected exactly one installed nbidal18 pack-compat companion for guard migration.'
    }
    if ($companionRecords[0].TargetPath -cne 'mods/nbidal18-pack-compat-1.1.12+1.21.1.jar') {
        throw "Release 3.2.8 must install pack-compat 1.1.12+1.21.1; found $($companionRecords[0].TargetPath)"
    }
    $installedCompanion = Join-Path $minecraft $companionRecords[0].TargetPath.Replace('/', '\')
    $requiredAutoHudEntries = @(
        'dev/nbidal18/packcompat/autohud/Nbidal18AutoHudApi.class',
        'dev/nbidal18/packcompat/autohud/AutoHudRenderGate.class',
        'dev/nbidal18/packcompat/autohud/mixin/AutoHudVitalsSyncMixin.class',
        'dev/nbidal18/packcompat/autohud/mixin/ImmersiveAircraftOverlayMixin.class',
        'dev/nbidal18/packcompat/autohud/mixin/ImmersiveMachineryOverlayMixin.class',
        'dev/nbidal18/packcompat/autohud/mixin/ArtifactsCooldownOverlayMixin.class',
        'dev/nbidal18/packcompat/autohud/mixin/ArtifactsHeliumOverlayMixin.class',
        'dev/nbidal18/packcompat/autohud/mixin/SodiumExtraHudMixin.class',
        'nbidal18-pack-compat.client.mixins.json'
    )
    $companionArchive = [IO.Compression.ZipFile]::OpenRead($installedCompanion)
    try {
        $companionEntryNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $companionArchive.Entries) { [void] $companionEntryNames.Add($entry.FullName) }
        foreach ($requiredEntry in $requiredAutoHudEntries) {
            if (-not $companionEntryNames.Contains($requiredEntry)) {
                throw "Pack-compat 1.1.12 is missing required Auto HUD integration entry: $requiredEntry"
            }
        }
        if ($companionEntryNames.Contains('dev/nbidal18/packcompat/autohud/mixin/AutoHudRenderGate.class')) {
            throw 'Pack-compat illegally places AutoHudRenderGate in the package reserved for Mixin classes.'
        }
    }
    finally { $companionArchive.Dispose() }
    $reviewedGuardHash = (Get-FileHash -LiteralPath $launchGuardSource -Algorithm SHA256).Hash
    $shellHashes = Get-PreservationHashes @(
        (Join-Path $instanceRoot 'instance.cfg'),
        (Join-Path $instanceRoot 'mmc-pack.json'),
        (Join-Path $instanceRoot 'server-icon.png'),
        $bootstrapInstalled
    )
    Copy-Item -LiteralPath $previousLaunchGuardSource -Destination $launchGuardInstalled -Force
    $installedPreviousGuardHash = (Get-FileHash -LiteralPath $launchGuardInstalled -Algorithm SHA256).Hash
    if ($installedPreviousGuardHash -cne $expectedPreviousLaunchGuardSha256) {
        throw 'The migration fixture did not install the exact published v3.2.4 launch guard.'
    }
    if ($installedPreviousGuardHash -eq $reviewedGuardHash) {
        throw 'The published v3.2.4 guard unexpectedly matches the reviewed current guard.'
    }

    $javacPath = Join-Path (Split-Path -Parent $JavaPath) 'javac.exe'
    if (-not (Test-Path -LiteralPath $javacPath -PathType Leaf)) {
        throw "Java compiler required for the guard-migration harness was not found: $javacPath"
    }
    $harnessRoot = Join-Path $temporaryRoot 'guard-migration-harness'
    $harnessSourceDirectory = Join-Path $harnessRoot 'src\dev\nbidal18\packcompat'
    $harnessClasses = Join-Path $harnessRoot 'classes'
    New-Item -ItemType Directory -Path $harnessSourceDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $harnessClasses -Force | Out-Null
    $harnessSource = Join-Path $harnessSourceDirectory 'LaunchGuardMigrationHarness.java'
    Write-Utf8NoBom $harnessSource @'
package dev.nbidal18.packcompat;

import java.nio.file.Path;

public final class LaunchGuardMigrationHarness {
    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            throw new IllegalArgumentException("Expected the Minecraft game directory");
        }
        System.out.print(LaunchGuardUpdater.install(Path.of(args[0])).name());
    }
}
'@
    $oneClickHarnessSource = Join-Path $harnessSourceDirectory 'OneClickReleaseHarness.java'
    Write-Utf8NoBom $oneClickHarnessSource @'
package dev.nbidal18.packcompat;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;

/** Release-only caller of the production package-private one-click primitives. */
public final class OneClickReleaseHarness {
    private static final String INSTANCE_ID = "nbidal18-client";
    private static final String NONCE = "0123456789abcdef0123456789abcdef";
    private static final long MINECRAFT_PID = 424242L;
    private static final Instant MINECRAFT_STARTED = Instant.parse("2026-08-12T08:00:00Z");
    private static final Instant ARMED_AT = Instant.parse("2026-08-12T08:01:00Z");

    public static void main(String[] args) throws Exception {
        if (args.length == 0) throw new IllegalArgumentException("Expected a harness mode");
        switch (args[0]) {
            case "bridge" -> bridge(args);
            case "noop" -> noOp();
            case "suppress" -> suppress(args);
            default -> throw new IllegalArgumentException("Unknown harness mode: " + args[0]);
        }
    }

    private static void bridge(String[] args) throws Exception {
        if (args.length != 5) {
            throw new IllegalArgumentException("bridge requires game, Prism executable, launcher root, and guard hash");
        }
        Path game = Path.of(args[1]).toAbsolutePath().normalize();
        Path prism = Path.of(args[2]).toAbsolutePath().normalize();
        Path launcher = Path.of(args[3]).toAbsolutePath().normalize();
        String guard = args[4];

        if (!PrismRelaunchState.shouldPrepareRelaunch(
                LaunchGuardUpdater.UpdateResult.REPLACED, false)) {
            throw new AssertionError("The v3.2.4 replacement did not request the one-time relaunch");
        }
        PrismRelaunchState.RelaunchMarker armed = PrismRelaunchState.arm(
                game, guard, INSTANCE_ID, ARMED_AT, NONCE);
        if (armed.state() != PrismRelaunchState.MarkerState.ARMED
                || !armed.nonce().equals(NONCE)
                || !armed.guardSha256().equals(guard)
                || armed.acknowledgedAtUtc() != null) {
            throw new AssertionError("The deterministic production relaunch marker is not exactly armed");
        }

        PrismRelaunchHelper.Arguments original = new PrismRelaunchHelper.Arguments(
                prism, launcher, game, INSTANCE_ID, MINECRAFT_PID, MINECRAFT_STARTED, NONCE, guard);
        PrismRelaunchHelper.Arguments parsed = PrismRelaunchHelper.Arguments.parse(original.serialize());
        if (!parsed.equals(original)) {
            throw new AssertionError("The production helper argument round trip changed an exact path or identity");
        }
        FakeOperations operations = new FakeOperations(parsed);
        int exitCode = PrismRelaunchHelper.run(parsed, operations);
        if (exitCode != 0 || operations.launches != 1 || operations.exitWaits != 1
                || operations.ackWaits != 1 || operations.deletes != 1
                || Files.exists(game.resolve(PrismRelaunchState.RELATIVE_PATH), LinkOption.NOFOLLOW_LINKS)) {
            throw new AssertionError("The production helper did not complete one exact acknowledged handoff");
        }
        System.out.print("BRIDGE_RELAUNCH_ACK_CONSUMED");
    }

    private static void noOp() {
        if (PrismRelaunchState.shouldPrepareRelaunch(
                    LaunchGuardUpdater.UpdateResult.UP_TO_DATE, false)
                || PrismRelaunchState.shouldPrepareRelaunch(
                    LaunchGuardUpdater.UpdateResult.UP_TO_DATE, true)
                || PrismRelaunchState.shouldPrepareRelaunch(
                    LaunchGuardUpdater.UpdateResult.REPLACED, true)) {
            throw new AssertionError("An up-to-date or already handed-off guard would create a restart loop");
        }
        System.out.print("UP_TO_DATE_NO_RELAUNCH");
    }

    private static void suppress(String[] args) throws Exception {
        if (args.length != 7) {
            throw new IllegalArgumentException(
                    "suppress requires game, companion, guard hash, clock instant, expectation, and label");
        }
        boolean expected = Boolean.parseBoolean(args[5]);
        boolean consumed = LaunchGuardHandoff.consumeIfMatching(
                Path.of(args[1]),
                Path.of(args[2]),
                args[3],
                Clock.fixed(Instant.parse(args[4]), java.time.ZoneOffset.UTC)
        );
        if (consumed != expected
                || PrismRelaunchState.shouldPrepareRelaunch(
                    LaunchGuardUpdater.UpdateResult.REPLACED, consumed) == expected) {
            throw new AssertionError("Unexpected handoff suppression decision for " + args[6]);
        }
        System.out.print(consumed ? "HANDOFF_CONSUMED_NO_RELAUNCH" : "HANDOFF_REJECTED_RELAUNCH");
    }

    private static final class FakeOperations implements PrismRelaunchHelper.Operations {
        private final PrismRelaunchHelper.Arguments expected;
        int launches;
        int exitWaits;
        int ackWaits;
        int deletes;

        FakeOperations(PrismRelaunchHelper.Arguments expected) {
            this.expected = expected;
        }

        @Override
        public void requirePlainRegularFile(Path path, String label) throws IOException {
            if (!path.equals(expected.prismExecutable()) || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)
                    || !"Prism executable".equals(label)) {
                throw new AssertionError("Helper validated a different Prism executable");
            }
        }

        @Override
        public void requirePlainDirectory(Path path, String label) throws IOException {
            boolean expectedPath = path.equals(expected.launcherRoot()) || path.equals(expected.gameDirectory());
            if (!expectedPath || !Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
                throw new AssertionError("Helper validated an unexpected directory: " + label);
            }
        }

        @Override
        public boolean waitForExactProcessExit(long pid, Instant startedAt, Duration timeout) {
            exitWaits++;
            if (pid != MINECRAFT_PID || !startedAt.equals(MINECRAFT_STARTED)
                    || !timeout.equals(PrismRelaunchHelper.MINECRAFT_EXIT_TIMEOUT)) {
                throw new AssertionError("Helper lost the exact Minecraft PID/start-time identity");
            }
            return true;
        }

        @Override
        public void sleep(Duration duration) {
            if (!duration.equals(PrismRelaunchHelper.PRISM_SETTLE_DELAY)) {
                throw new AssertionError("Unexpected helper settle delay");
            }
        }

        @Override
        public void startPrism(Path executable, Path launcherRoot, String instanceId) {
            launches++;
            if (!executable.equals(expected.prismExecutable())
                    || !launcherRoot.equals(expected.launcherRoot())
                    || !instanceId.equals(INSTANCE_ID)) {
                throw new AssertionError("Helper attempted to launch a different Prism instance");
            }
        }

        @Override
        public boolean waitForAcknowledgment(
                PrismRelaunchHelper.Arguments arguments, Duration timeout) {
            ackWaits++;
            if (!arguments.equals(expected) || !timeout.equals(PrismRelaunchHelper.ACK_TIMEOUT)) {
                throw new AssertionError("Helper waited for a different request or timeout");
            }
            try {
                PrismRelaunchState.RelaunchMarker marker = PrismRelaunchState.read(expected.gameDirectory());
                PrismRelaunchState.RelaunchMarker acknowledged = new PrismRelaunchState.RelaunchMarker(
                        PrismRelaunchState.MarkerState.ACKNOWLEDGED,
                        marker.nonce(),
                        marker.guardSha256(),
                        marker.instanceIdBase64(),
                        marker.armedAtUtc(),
                        marker.armedAtUtc().plusSeconds(1)
                );
                Files.write(
                        expected.gameDirectory().resolve(PrismRelaunchState.RELATIVE_PATH),
                        acknowledged.serialize(),
                        StandardOpenOption.TRUNCATE_EXISTING,
                        StandardOpenOption.WRITE,
                        LinkOption.NOFOLLOW_LINKS
                );
                return PrismRelaunchState.acknowledgedMatches(
                        expected.gameDirectory(), NONCE, expected.guardSha256(), INSTANCE_ID);
            } catch (IOException | IntegrityException failure) {
                throw new AssertionError("Could not simulate the exact guard acknowledgement", failure);
            }
        }

        @Override
        public void deleteAcknowledgment(PrismRelaunchHelper.Arguments arguments)
                throws IOException, IntegrityException {
            deletes++;
            if (!arguments.equals(expected)) throw new AssertionError("Helper consumed a different request");
            PrismRelaunchState.RelaunchMarker marker = PrismRelaunchState.read(expected.gameDirectory());
            PrismRelaunchState.deleteMatching(expected.gameDirectory(), marker);
        }
    }
}
'@
    $compilerOutput = @(& $javacPath '-encoding' 'UTF-8' '-cp' $installedCompanion '-d' $harnessClasses $harnessSource $oneClickHarnessSource 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "Guard-migration harness compilation failed: $($compilerOutput -join [Environment]::NewLine)"
    }
    $harnessClassPath = "$harnessClasses;$installedCompanion"
    $migrationOutput = @(& $JavaPath '-cp' $harnessClassPath 'dev.nbidal18.packcompat.LaunchGuardMigrationHarness' $minecraft 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or ($migrationOutput -join '').Trim() -ne 'REPLACED') {
        throw "Managed companion did not replace the exact published v3.2.4 guard: $($migrationOutput -join [Environment]::NewLine)"
    }
    if ((Get-FileHash -LiteralPath $launchGuardInstalled -Algorithm SHA256).Hash -ne $reviewedGuardHash) {
        throw 'Managed companion installed launch-guard bytes that differ from the reviewed tool.'
    }
    if (@(Get-ChildItem -LiteralPath $minecraft -Force -File -Filter '.nbidal18-launch-guard-*.tmp').Count -ne 0) {
        throw 'Guard migration left a staging file in the Minecraft root.'
    }
    Assert-PreservationHashes $shellHashes
    [void] (Assert-IntegrityAttestation $minecraft)

    # Exercise the JDK-only production relaunch primitives without opening a
    # real Prism process. The fake boundary verifies that exact normalized
    # paths, instance ID, nonce, PID, and process start time flow through the
    # serialized helper request, then simulates the new guard's exact ACK.
    $fakeLauncherRoot = Join-Path $temporaryRoot 'fake-prism-root'
    New-Item -ItemType Directory -Path $fakeLauncherRoot -Force | Out-Null
    $fakePrismExecutable = Join-Path $fakeLauncherRoot 'prismlauncher.exe'
    Write-Utf8NoBom $fakePrismExecutable "validation-placeholder`n"
    $bridgeOutput = @(& $JavaPath '-cp' $harnessClassPath 'dev.nbidal18.packcompat.OneClickReleaseHarness' `
        'bridge' $minecraft $fakePrismExecutable $fakeLauncherRoot ($reviewedGuardHash.ToLowerInvariant()) `
        2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or ($bridgeOutput -join '').Trim() -cne 'BRIDGE_RELAUNCH_ACK_CONSUMED') {
        throw "One-click v3.2.4 bridge harness failed: $($bridgeOutput -join [Environment]::NewLine)"
    }
    $relaunchMarkerPath = Join-Path $minecraft '.nbidal18\prism-relaunch.tsv'
    if (Test-Path -LiteralPath $relaunchMarkerPath) {
        throw 'The acknowledged one-click Prism relaunch marker was not consumed.'
    }

    $guardMtime = (Get-Item -LiteralPath $launchGuardInstalled).LastWriteTimeUtc
    $noOpOutput = @(& $JavaPath '-cp' $harnessClassPath 'dev.nbidal18.packcompat.LaunchGuardMigrationHarness' $minecraft 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or ($noOpOutput -join '').Trim() -ne 'UP_TO_DATE' -or
            (Get-Item -LiteralPath $launchGuardInstalled).LastWriteTimeUtc -ne $guardMtime) {
        throw 'A matching launch guard was not a byte/metadata-preserving migration no-op.'
    }
    $noRestartOutput = @(& $JavaPath '-cp' $harnessClassPath 'dev.nbidal18.packcompat.OneClickReleaseHarness' `
        'noop' 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or ($noRestartOutput -join '').Trim() -cne 'UP_TO_DATE_NO_RELAUNCH' -or
            (Test-Path -LiteralPath $relaunchMarkerPath)) {
        throw "An UP_TO_DATE guard could enter a relaunch loop: $($noRestartOutput -join [Environment]::NewLine)"
    }

    # Future guard generations write this proof during the child handoff. A
    # fresh exact proof suppresses a restart and is consumed atomically; stale
    # or hash-mismatched proofs remain untrusted and cannot suppress relaunch.
    $handoffPath = Join-Path $minecraft '.nbidal18\launch-guard-handoff.tsv'
    $companionHash = (Get-FileHash -LiteralPath $installedCompanion -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifestHash = (Get-FileHash -LiteralPath (Join-Path $minecraft '.nbidal18\strict-manifest.tsv') -Algorithm SHA256).Hash.ToLowerInvariant()
    $guardHashLower = $reviewedGuardHash.ToLowerInvariant()
    $handoffClock = [DateTimeOffset]::UtcNow
    $handoffClockText = $handoffClock.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)

    function Write-HandoffFixture([string] $GuardHash, [DateTimeOffset] $VerifiedAt) {
        $verifiedText = $VerifiedAt.ToUniversalTime().ToString(
            'yyyy-MM-ddTHH:mm:ss.fffZ',
            [Globalization.CultureInfo]::InvariantCulture
        )
        Write-Utf8NoBom $handoffPath ((@(
            "nbidal18-launch-guard-handoff`t1",
            "guard-sha256`t$GuardHash",
            "companion-sha256`t$companionHash",
            "manifest-sha256`t$manifestHash",
            "verified-at-utc`t$verifiedText"
        ) -join "`n") + "`n")
    }

    Write-HandoffFixture $guardHashLower $handoffClock
    $freshHandoffOutput = @(& $JavaPath '-cp' $harnessClassPath 'dev.nbidal18.packcompat.OneClickReleaseHarness' `
        'suppress' $minecraft $installedCompanion $guardHashLower $handoffClockText 'true' 'fresh-exact' `
        2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or ($freshHandoffOutput -join '').Trim() -cne 'HANDOFF_CONSUMED_NO_RELAUNCH' -or
            (Test-Path -LiteralPath $handoffPath)) {
        throw "Fresh exact guard handoff did not suppress and atomically consume: $($freshHandoffOutput -join [Environment]::NewLine)"
    }

    Write-HandoffFixture $guardHashLower ($handoffClock.AddMinutes(-11))
    $staleHandoffOutput = @(& $JavaPath '-cp' $harnessClassPath 'dev.nbidal18.packcompat.OneClickReleaseHarness' `
        'suppress' $minecraft $installedCompanion $guardHashLower $handoffClockText 'false' 'stale' `
        2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or ($staleHandoffOutput -join '').Trim() -cne 'HANDOFF_REJECTED_RELAUNCH' -or
            -not (Test-Path -LiteralPath $handoffPath -PathType Leaf)) {
        throw "A stale guard handoff incorrectly suppressed relaunch: $($staleHandoffOutput -join [Environment]::NewLine)"
    }

    Write-HandoffFixture ('0' * 64) $handoffClock
    $mismatchedHandoffOutput = @(& $JavaPath '-cp' $harnessClassPath 'dev.nbidal18.packcompat.OneClickReleaseHarness' `
        'suppress' $minecraft $installedCompanion $guardHashLower $handoffClockText 'false' 'guard-mismatch' `
        2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or ($mismatchedHandoffOutput -join '').Trim() -cne 'HANDOFF_REJECTED_RELAUNCH' -or
            -not (Test-Path -LiteralPath $handoffPath -PathType Leaf)) {
        throw "A mismatched guard handoff incorrectly suppressed relaunch: $($mismatchedHandoffOutput -join [Environment]::NewLine)"
    }
    Remove-Item -LiteralPath $handoffPath -Force

    $approvedGeneratedShader = 'ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3'
    $irisPath = Join-Path $minecraft 'config\iris.properties'
    Write-Utf8NoBom $irisPath "allowUnknownShaders=false`nshaderPack=$approvedGeneratedShader`nvalidationPreference=keep`n"
    $preservationHashes[$irisPath] = (Get-FileHash -LiteralPath $irisPath -Algorithm SHA256).Hash

    # An unchanged release still runs a normal pass and a forced hash-validation
    # pass. Tamper one managed canary and add one unknown file to prove that the
    # forced pass repairs only the canary and strict cleanup quarantines the extra.
    $managedCanaryPath = Join-Path $minecraft 'config\__validation_overwrite.txt'
    Write-Utf8NoBom $managedCanaryPath "tampered-between-launches`n"
    $unchangedExtraRelative = 'mods/__validation_unchanged_extra.jar'
    $unchangedExtraPath = Join-Path $minecraft $unchangedExtraRelative.Replace('/', '\')
    Write-Utf8NoBom $unchangedExtraPath "unknown-on-unchanged-release`n"
    $unchangedQuarantineHash = @{
        $unchangedExtraRelative = (Get-FileHash -LiteralPath $unchangedExtraPath -Algorithm SHA256).Hash
    }
    $unchangedManagedHashes = @{}
    foreach ($record in $expectedManagedRecords) {
        if ($record.TargetPath -eq 'config/__validation_overwrite.txt') { continue }
        $path = Join-Path $minecraft $record.TargetPath.Replace('/', '\')
        $unchangedManagedHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }

    $secondOutput = Invoke-LaunchGuard $minecraft $packUrl
    Write-Utf8NoBom (Join-Path $temporaryRoot 'launch-guard-unchanged.log') (($secondOutput -join "`n") + "`n")
    $secondPasses = @($secondOutput | Where-Object { $_ -match '^\[nbidal18-launch-guard\] Running Packwiz (normal update|forced hash-validation) pass\.\.\.$' })
    if ($secondPasses.Count -ne 2 -or -not (($secondOutput -join "`n") -match 'Modpack is already up to date!')) {
        throw 'Unchanged launch did not perform the expected normal no-op plus forced validation passes.'
    }
    if (-not (Select-String -LiteralPath (Join-Path $minecraft 'config\iris.properties') -SimpleMatch "shaderPack=$approvedGeneratedShader")) {
        throw 'The companion-installed launch guard did not preserve the exact generated Euphoria selection on the following Play.'
    }
    if ([IO.File]::ReadAllText($managedCanaryPath) -ne "release-A`n") {
        throw 'Forced validation did not repair the tampered managed canary.'
    }
    $unchangedDownloads = @($secondOutput | ForEach-Object {
        if ($_ -match '^\(\d+/\d+\) Downloaded (.+)$') {
            [IO.Path]::GetFileName($Matches[1].Replace('/', '\'))
        }
    } | Sort-Object)
    if (($unchangedDownloads -join '|') -ne '__validation_overwrite.txt') {
        throw "Forced unchanged validation downloaded unexpected payloads: $($unchangedDownloads -join ', ')"
    }
    Assert-PreservationHashes $unchangedManagedHashes
    Assert-PreservationHashes $preservationHashes
    Assert-QuarantinedFiles $minecraft $unchangedQuarantineHash
    if ((Assert-IntegrityAttestation $minecraft) -ne $releaseAManifestHash) {
        throw 'Unchanged release attested a different strict manifest.'
    }

    # Publish a manifest with one unavailable payload and characterize Packwiz's failure behavior.
    foreach ($file in Get-ChildItem -LiteralPath $siteFailure -Recurse -File -Force) {
        $relative = $file.FullName.Substring($siteFailure.Length).TrimStart('\')
        $target = Join-Path $published $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    $treeHashBeforeFailure = Get-TreeHash $minecraft
    $stateHashBeforeFailure = (Get-FileHash -LiteralPath $packwizStatePath -Algorithm SHA256).Hash
    $failedOutput = Invoke-LaunchGuardExpectFailure $minecraft $packUrl
    Write-Utf8NoBom (Join-Path $temporaryRoot 'launch-guard-expected-failure.log') (($failedOutput -join "`n") + "`n")
    Assert-AttestationAbsent $minecraft
    if ((Get-FileHash -LiteralPath $packwizStatePath -Algorithm SHA256).Hash -ne $stateHashBeforeFailure) { throw 'Failed update advanced packwiz.json instead of retaining the previous manifest.' }
    if ((Get-TreeHash $minecraft) -eq $treeHashBeforeFailure) { throw 'Failure scenario no longer demonstrates Packwiz partial-write behavior; review the documented limitation.' }
    if ([IO.File]::ReadAllText((Join-Path $minecraft 'config\__validation_overwrite.txt')) -ne "failed-release-must-not-apply`n") { throw 'Failure scenario did not apply the available managed config before the later missing payload failed.' }
    if (-not (Test-Path -LiteralPath (Join-Path $minecraft 'mods\__validation_remove.jar'))) { throw 'Failed release removed the prior managed mod unexpectedly.' }
    if (Test-Path -LiteralPath (Join-Path $minecraft 'mods\__validation_missing.jar')) { throw 'Unavailable validation payload unexpectedly exists.' }
    Assert-PreservationHashes $preservationHashes

    # Publish B, locally edit one managed file, and prove overwrite/removal/addition.
    foreach ($file in Get-ChildItem -LiteralPath $siteB -Recurse -File -Force) {
        $relative = $file.FullName.Substring($siteB.Length).TrimStart('\')
        $target = Join-Path $published $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    Write-Utf8NoBom (Join-Path $minecraft 'config\__validation_overwrite.txt') "player-local-edit`n"
    $thirdOutput = Invoke-LaunchGuardWithRetry $minecraft $packUrl -Attempts 3
    Write-Utf8NoBom (Join-Path $temporaryRoot 'launch-guard-release-b.log') (($thirdOutput -join "`n") + "`n")
    if ([IO.File]::ReadAllText((Join-Path $minecraft 'config\__validation_overwrite.txt')) -ne "release-B`n") { throw 'Managed local edit was not overwritten by release B.' }
    if (Test-Path -LiteralPath (Join-Path $minecraft 'mods\__validation_remove.jar')) { throw 'Removed managed mod survived release B.' }
    if ([IO.File]::ReadAllText((Join-Path $minecraft 'mods\__validation_added.jar')) -ne "validation-mod-B`n") { throw 'Added release B mod was not installed.' }
    $downloadedPayloads = @($thirdOutput | ForEach-Object {
        if ($_ -match '^\(\d+/\d+\) Downloaded (.+)$') {
            [IO.Path]::GetFileName($Matches[1].Replace('/', '\'))
        }
    } | Sort-Object)
    if (($downloadedPayloads -join '|') -ne '__validation_added.jar|__validation_overwrite.txt|strict-manifest.tsv') {
        throw "Release B downloaded unexpected payloads: $($downloadedPayloads -join ', ')"
    }
    $deletedPayloads = @($thirdOutput | ForEach-Object {
        if ($_ -match '^Deleted (.+) \(removed from pack\)$') {
            [IO.Path]::GetFileName($Matches[1].Replace('/', '\'))
        }
    })
    if (($deletedPayloads -join '|') -ne '__validation_remove.jar') {
        throw "Release B deleted unexpected payloads: $($deletedPayloads -join ', ')"
    }
    $expectedManagedRecordsB = @(Get-IndexedInstallRecords $siteB)
    Assert-ManagedInstall $minecraft $expectedManagedRecordsB
    Assert-PreservationHashes $preservationHashes
    $releaseBManifestHash = Assert-IntegrityAttestation $minecraft
    if ($releaseBManifestHash -eq $releaseAManifestHash) { throw 'Release B retained release A strict-manifest attestation.' }

    $metadataReport = Import-Csv -LiteralPath (Join-Path $updaterRoot 'metadata\METADATA-REPORT.csv')
    $modrinthModCount = @($metadataReport | Where-Object { $_.management -eq 'modrinth' -and $_.type -eq 'mod' }).Count
    $modrinthResourcepackCount = @($metadataReport | Where-Object { $_.management -eq 'modrinth' -and $_.type -eq 'resourcepack' }).Count
    $modrinthDatapackCount = @($metadataReport | Where-Object { $_.management -eq 'modrinth' -and $_.type -eq 'datapack' }).Count
    $modrinthShaderpackCount = @($metadataReport | Where-Object { $_.management -eq 'modrinth' -and $_.type -eq 'shaderpack' }).Count
    $hostedModCount = @($metadataReport | Where-Object { $_.management -eq 'internal-hosted' -and $_.type -eq 'mod' }).Count
    $hostedResourcepackCount = @($metadataReport | Where-Object { $_.management -eq 'internal-hosted' -and $_.type -eq 'resourcepack' }).Count
    $hostedReportDatapackCount = @($metadataReport | Where-Object { $_.management -eq 'internal-hosted' -and $_.type -eq 'datapack' }).Count
    $hostedShaderpackCount = @($metadataReport | Where-Object { $_.management -eq 'internal-hosted' -and $_.type -eq 'shaderpack' }).Count
    if ($hostedShaderpackCount -ne 0) { throw 'Shader packs must be delivered directly through official Modrinth metadata.' }
    $hostedManifest = Get-Content -LiteralPath (Join-Path $updaterRoot 'metadata\hosted-files.json') -Raw | ConvertFrom-Json
    $hostedDatapackCount = @($hostedManifest.files | Where-Object { $_.path -like 'datapacks/*' }).Count
    $siteFiles = @(Get-ChildItem -LiteralPath $siteRoot -Recurse -File -Force)
    $completedAt = Get-Date
    $reportText = @"
# nbidal18 v3.2.8 Packwiz validation report

- Result: PASS
- Started: $($startedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))
- Completed: $($completedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))
- Packwiz site files: $($siteFiles.Count)
- Exact Modrinth-managed archives: $($modrinthModCount + $modrinthResourcepackCount + $modrinthDatapackCount + $modrinthShaderpackCount) ($modrinthModCount mods, $modrinthResourcepackCount resource packs, $modrinthDatapackCount datapack, $modrinthShaderpackCount shader packs)
- Reviewed internal-hosted archives: $($hostedModCount + $hostedResourcepackCount + $hostedReportDatapackCount + $hostedShaderpackCount) ($hostedModCount mods, $hostedResourcepackCount resource packs, $hostedReportDatapackCount datapacks, $hostedShaderpackCount shader packs)
- Hosted datapack allowlist entries: $hostedDatapackCount
- Migration-only external files in the public manifest: 0

Validated:

- Packwiz refresh is reproducible and the checked-in manifest is current.
- Still Life, raw shader archives/sidecars, seed targets, Controlify state, Iris state, VinURL helpers, voice state, runtime caches, fingerprints, and warnings are absent from the public index; only reviewed seed templates are published.
- The six-file thin migration ZIP contains only Prism metadata/icon, the Packwiz bootstrap, and the exact reviewed launch-guard JAR; it contains no Packwiz-managed payload, VinURL data, Still Life, shaders, or player state.
- The first guarded launch performs both Packwiz passes, cold-installs and hash-verifies every managed payload, seeds absent settings once, and writes an attestation matching the installed strict manifest.
- Generated Fabric nested/remapped-mod caches and Moonlight's loadable dynamic resource-pack cache are purged before attestation, while unrelated `.fabric` state remains byte-preserved.
- Mixed settings are narrowed without resetting unrelated preferences: options.txt receives canonical resource-pack lines, Iris rejects unknown shaders while retaining the exact generated Euphoria selection, and Controlify reach-around is forced off.
- The managed companion contains the exact reviewed launch guard. The exact published v3.2.4 guard artifact (SHA-256 $expectedPreviousLaunchGuardSha256) is atomically replaced through the production client updater without changing Prism metadata/bootstrap files; a second updater call is a true no-op, and the following guarded launch preserves the generated Euphoria selection.
- A production package-private one-click harness proves the v3.2.4 replacement chooses relaunch, round-trips the exact Prism executable/root/game/instance/PID/start-time/nonce helper request, consumes one matching acknowledgement, and refuses every UP_TO_DATE or already-handed-off restart decision. A fresh exact guard/companion/manifest handoff proof is consumed and suppresses relaunch; stale and guard-mismatched proofs remain untrusted.
- The launch-guard producer smoke separately executes a byte-distinct, identity-valid next guard as a child in the same pre-launch, checks exact child-exit propagation, one-generation depth enforcement, immutable hash-named staging, malformed-descriptor rejection, and the exact hash-bound handoff-attestation and Prism-marker schemas. This is an isolated JVM test, not a real Prism process handoff.
- Unknown mod, resource-pack, shader, datapack, Moonlight global-datapack, Villager API pack, server-pack cache, retired CustomSkinLoader runtime/core/cache/plugin/provider, and config canaries are absent from strict roots and remain recoverable under `.nbidal18/quarantine`; the disposable Euphoria-generated shader tree is purged and rebuilt instead of accumulating in quarantine.
- Exact optional Still Life, saves, screenshots, Skin Overrides skin/cape selections and libraries, VinURL data, approved shader sidecar settings, JEI/runtime state, and seed-once settings persist byte-for-byte.
- An unchanged release still performs the normal and forced Packwiz passes. The forced pass repairs the sole tampered managed canary, downloads no other managed payload, quarantines a newly added extra, and refreshes a matching attestation.
- A later release adds and removes JAR-named managed-file canaries in `mods/`, overwrites a managed config, updates the strict manifest, and attests the new manifest.
- The changed release reports exactly the added mod, changed config, and strict-manifest downloads plus the one expected managed deletion.
- A deliberately unavailable payload produces a clear nonzero failure, retains the previous Packwiz state, demonstrates the known partial write, leaves no attestation, and is repaired and re-attested by the next successful release.

External release gates are outside this isolated behavior report. `Build-Release.ps1` separately requires the anonymous HTTPS `pack.toml`, `index.toml`, strict manifest, and every reviewed internal-hosted payload to match before it produces the final ZIP. Reaching the Minecraft menu, confirming that a failed pre-launch command blocks Minecraft, and production multiplayer compatibility remain manual checks.

Historical 3.1.0 -> 3.1.1 transition: the old direct-Packwiz Prism instance could not acquire the nbidal18 launch-guard JAR or Prism pre-launch command through Packwiz, so that cutover required a one-time import of the 3.1.1 six-file migration ZIP. Existing runnable guarded instances receive 3.2.8 and companion 1.1.12 in place. Version 3.2.5 bridged to launch guard 1.1.0 through a controlled exact-instance Prism relaunch; version 3.2.6 fixed its Windows child-output pipe deadlock by disconnecting all three standard streams. Version 3.2.8 fixes the v3.2.7 Auto HUD Mixin-package runtime crash and retains the consolidated integration. The companion regression floods both stdout and stderr beyond pipe capacity, requires the exact acknowledgment, and completes without changing the validated Prism arguments or bounded retries. Later guard updates self-handoff during pre-launch. Missing/corrupt guards and command/filename changes still require the recovery ZIP. The isolated behavior test verifies the embedded guard migration and next guarded launch; a real Prism process handoff remains a final end-to-end release check.

Known limitation: Packwiz is not transaction-wide atomic. In the deliberate failure test, an available managed config was written before a later payload returned 404, although player-controlled/runtime files and the previous Packwiz state remained intact. The guard removed the stale attestation immediately, and the next successful pre-launch run repaired and attested the managed release. Final Prism testing must confirm a nonzero pre-launch result blocks Minecraft from starting.
"@
    Write-Utf8NoBom $validationReport ($reportText.TrimStart() + "`n")
    Write-Host "Packwiz validation passed. Report: $validationReport"
}
catch {
    $failure = $_
    $failedAt = Get-Date
    $failureText = @"
# nbidal18 v3.2.8 Packwiz validation report

- Result: FAIL
- Started: $($startedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))
- Failed: $($failedAt.ToString('yyyy-MM-dd HH:mm:ss zzz'))

Error:

````text
$($_.Exception.Message)
````
"@
    Write-Utf8NoBom $validationReport ($failureText.TrimStart() + "`n")
}
finally {
    if ($serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force
        $serverProcess.WaitForExit()
    }
    if (-not $KeepTemporaryFiles -and (Test-Path -LiteralPath $temporaryRoot)) {
        if (-not $temporaryRoot.StartsWith($expectedTempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing unsafe cleanup path: $temporaryRoot"
        }
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

if ($failure) { throw $failure }
