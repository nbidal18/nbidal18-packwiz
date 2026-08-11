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
    $shaderSourceRoot,
    $privateStillLifeSource,
    $PackwizPath,
    $JavaPath
)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required path is missing: $required" }
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
        'datapacks/Still_Life-1.0-beta1.zip',
        'config/controlify.json',
        'config/euphoria_patcher/.data.json',
        'config/etf_warnings.json',
        'config/jade/usernamecache.json',
        'config/presencefootsteps/updater.json',
        'config/resourceful-config-web.json',
        'config/sodium-fingerprint.json',
        'config/voicechat/username-cache.json',
        'CustomSkinLoader/CustomSkinLoader.json',
        'CustomSkinLoader/CustomSkinLoader.log',
        'CustomSkinLoader/CustomSkinAPIPlus-ClientID'
    )) { [void] $forbiddenIndexedFiles.Add($forbidden) }
    $allowedCustomSkinLoaderMarkers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void] $allowedCustomSkinLoaderMarkers.Add('CustomSkinLoader/Plugins/nbidal18-closed.marker')
    [void] $allowedCustomSkinLoaderMarkers.Add('CustomSkinLoader/ExtraList/nbidal18-closed.marker')
    $forbiddenIndexedPrefixes = @(
        'config/crash_assistant/',
        'config/jei/world/',
        'config/spark/tmp/',
        'skin_overrides/',
        'cape_overrides/',
        'vinurl/'
    )
    foreach ($indexedSourcePath in $indexedSourcePaths) {
        if ($forbiddenIndexedFiles.Contains($indexedSourcePath) -or
                ($indexedSourcePath.StartsWith('CustomSkinLoader/', [StringComparison]::OrdinalIgnoreCase) -and
                    -not $allowedCustomSkinLoaderMarkers.Contains($indexedSourcePath)) -or
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
    $expectedCustomSkinLoaderPaths = @(
        'CustomSkinLoader/ExtraList/nbidal18-closed.marker',
        'CustomSkinLoader/Plugins/nbidal18-closed.marker'
    )
    if (($indexedCustomSkinLoaderPaths -join "`n") -cne ($expectedCustomSkinLoaderPaths -join "`n")) {
        throw "The public CustomSkinLoader tree must contain exactly the two inert closed-directory markers; found: $($indexedCustomSkinLoaderPaths -join ', ')"
    }
    $strictManifestLines = @(
        Get-Content -LiteralPath (Join-Path $siteRoot '.nbidal18\strict-manifest.tsv')
    )
    foreach ($markerPath in $expectedCustomSkinLoaderPaths) {
        $markerHash = (Get-FileHash -LiteralPath (Join-Path $siteRoot $markerPath.Replace('/', '\')) -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedManagedRecord = "managed`t$markerHash`t$markerPath"
        if (@($strictManifestLines | Where-Object { $_ -ceq $expectedManagedRecord }).Count -ne 1) {
            throw "The strict manifest must manage the exact closed-directory marker: $markerPath"
        }
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
    $testZip = Join-Path $temporaryRoot 'nbidal18-3.2.2-local-validation.zip'
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
    foreach ($requiredText in @('name=nbidal18-client', 'ExportName=nbidal18-client', 'ExportVersion=3.2.2', 'OverrideCommands=true', "PreLaunchCommand=`"`$INST_JAVA`" -jar nbidal18-launch-guard.jar $packUrl")) {
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
# nbidal18 v3.2.2 Packwiz validation report

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
- Mixed settings are narrowed without resetting unrelated preferences: options.txt receives canonical resource-pack lines, Iris rejects unknown shaders, and Controlify reach-around is forced off.
- Unknown mod, resource-pack, shader, datapack, Moonlight global-datapack, Villager API pack, server-pack cache, CustomSkinLoader plugin/provider, and config canaries are absent from strict roots and remain recoverable under `.nbidal18/quarantine`; the disposable Euphoria-generated shader tree is purged and rebuilt instead of accumulating in quarantine.
- Exact optional Still Life, saves, screenshots, VinURL data, approved shader sidecar settings, JEI/runtime state, and seed-once settings persist byte-for-byte.
- An unchanged release still performs the normal and forced Packwiz passes. The forced pass repairs the sole tampered managed canary, downloads no other managed payload, quarantines a newly added extra, and refreshes a matching attestation.
- A later release adds and removes JAR-named managed-file canaries in `mods/`, overwrites a managed config, updates the strict manifest, and attests the new manifest.
- The changed release reports exactly the added mod, changed config, and strict-manifest downloads plus the one expected managed deletion.
- A deliberately unavailable payload produces a clear nonzero failure, retains the previous Packwiz state, demonstrates the known partial write, leaves no attestation, and is repaired and re-attested by the next successful release.

External release gates are outside this isolated behavior report. `Build-Release.ps1` separately requires the anonymous HTTPS `pack.toml`, `index.toml`, strict manifest, and every reviewed internal-hosted payload to match before it produces the final ZIP. Reaching the Minecraft menu, confirming that a failed pre-launch command blocks Minecraft, and production multiplayer compatibility remain manual checks.

Historical 3.1.0 -> 3.1.1 transition: the old direct-Packwiz Prism instance could not acquire the nbidal18 launch-guard JAR through Packwiz, so that cutover required a one-time import of the 3.1.1 six-file migration ZIP. Existing guarded instances receive 3.2.2 in place on their next successful launch; they do not require another import.

Known limitation: Packwiz is not transaction-wide atomic. In the deliberate failure test, an available managed config was written before a later payload returned 404, although player-controlled/runtime files and the previous Packwiz state remained intact. The guard removed the stale attestation immediately, and the next successful pre-launch run repaired and attested the managed release. Final Prism testing must confirm a nonzero pre-launch result blocks Minecraft from starting.
"@
    Write-Utf8NoBom $validationReport ($reportText.TrimStart() + "`n")
    Write-Host "Packwiz validation passed. Report: $validationReport"
}
catch {
    $failure = $_
    $failedAt = Get-Date
    $failureText = @"
# nbidal18 v3.2.2 Packwiz validation report

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
