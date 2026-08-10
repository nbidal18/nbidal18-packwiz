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

foreach ($required in @($siteRoot, $builderPath, $bootstrapSource, $shaderSourceRoot, $privateStillLifeSource, $PackwizPath, $JavaPath)) {
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

function Invoke-Updater([string] $MinecraftDirectory, [string] $PackUrl, [switch] $NoBootstrapUpdate) {
    Push-Location $MinecraftDirectory
    try {
        $arguments = New-Object Collections.Generic.List[string]
        $arguments.Add('-jar')
        $arguments.Add('.\packwiz-installer-bootstrap.jar')
        if ($NoBootstrapUpdate) { $arguments.Add('--bootstrap-no-update') }
        $arguments.Add('-g')
        $arguments.Add($PackUrl)
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $JavaPath @($arguments.ToArray()) 2>&1 | ForEach-Object { "$_" })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($exitCode -ne 0) {
            throw "Packwiz updater failed with exit code $exitCode`n$($output -join "`n")"
        }
        return ,$output
    }
    finally {
        Pop-Location
    }
}

function Invoke-UpdaterWithRetry(
    [string] $MinecraftDirectory,
    [string] $PackUrl,
    [ValidateRange(1, 5)] [int] $Attempts = 3
) {
    $failures = New-Object Collections.Generic.List[string]
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try { return (Invoke-Updater $MinecraftDirectory $PackUrl) }
        catch {
            $failures.Add("Attempt ${attempt}: $($_.Exception.Message)")
            if ($attempt -eq $Attempts) {
                throw "Packwiz cold install failed after $Attempts attempts.`n$($failures -join "`n")"
            }
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
        }
    }
}

function Invoke-UpdaterExpectFailure([string] $MinecraftDirectory, [string] $PackUrl) {
    Push-Location $MinecraftDirectory
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& $JavaPath -jar '.\packwiz-installer-bootstrap.jar' --bootstrap-no-update -g $PackUrl 2>&1 | ForEach-Object { "$_" })
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($exitCode -eq 0) { throw 'Packwiz updater unexpectedly succeeded during the failure test.' }
        if ($output.Count -eq 0 -or (($output -join "`n") -notmatch '(?i)(failed|error|exception|404|not found|unable)')) {
            throw "Packwiz updater failure was not clearly reported.`n$($output -join "`n")"
        }
        return ,$output
    }
    finally {
        Pop-Location
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
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Updater removed preserved file: $path" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual -ne $Expected[$path]) { throw "Updater changed preserved file: $path" }
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

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('nbidal18-packwiz-validation-' + [guid]::NewGuid().ToString('N'))
$temporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
$expectedTempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\nbidal18-packwiz-validation-'
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
    foreach ($forbidden in @(
        'file = "datapacks/Still_Life-1.0-beta1.zip"',
        'config/iris.properties',
        'config/iris-excluded.json',
        'config/chat_heads.json5',
        'config/sodium-fingerprint.json',
        'config/presencefootsteps/updater.json',
        'config/presencefootsteps/userconfig.json',
        'config/etf_warnings.json',
        'config/jei/world/',
        'vinurl/',
        'voicechat/voicechat-client.properties',
        'voicechat/player-volumes.properties',
        'voicechat/category-volumes.properties',
        'voicechat/username-cache.json'
    )) {
        if ($indexText.Contains($forbidden)) { throw "Forbidden player/private path is indexed: $forbidden" }
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
    Write-Utf8NoBom (Join-Path $siteA 'config\__validation_overwrite.txt') "release-A`n"
    Write-Utf8NoBom (Join-Path $siteA 'mods\__validation_remove.jar') "validation-mod-A`n"
    Invoke-PackwizRefresh $siteA
    if (-not ([IO.File]::ReadAllText((Join-Path $siteA 'index.toml')).Contains('mods/__validation_remove.jar'))) {
        throw 'Release A canaries were not indexed.'
    }

    Copy-Item -LiteralPath $siteA -Destination $siteB -Recurse
    Write-Utf8NoBom (Join-Path $siteB 'config\__validation_overwrite.txt') "release-B`n"
    Remove-Item -LiteralPath (Join-Path $siteB 'mods\__validation_remove.jar') -Force
    Write-Utf8NoBom (Join-Path $siteB 'mods\__validation_added.jar') "validation-mod-B`n"
    Invoke-PackwizRefresh $siteB
    $indexB = [IO.File]::ReadAllText((Join-Path $siteB 'index.toml'))
    if (-not $indexB.Contains('mods/__validation_added.jar') -or $indexB.Contains('mods/__validation_remove.jar')) {
        throw 'Release B add/remove index assertions failed.'
    }

    Copy-Item -LiteralPath $siteA -Destination $siteFailure -Recurse
    Write-Utf8NoBom (Join-Path $siteFailure 'config\__validation_overwrite.txt') "failed-release-must-not-apply`n"
    Write-Utf8NoBom (Join-Path $siteFailure 'mods\__validation_missing.jar') "unavailable-payload`n"
    Invoke-PackwizRefresh $siteFailure
    Remove-Item -LiteralPath (Join-Path $siteFailure 'mods\__validation_missing.jar') -Force
    Copy-Item -LiteralPath $siteA -Destination $published -Recurse

    # Build a localhost-only migration ZIP for isolated testing.
    $port = Get-FreeTcpPort
    $packUrl = "http://127.0.0.1:$port/pack.toml"
    $testZip = Join-Path $temporaryRoot 'nbidal18-3.1.0-local-validation.zip'
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
    foreach ($requiredText in @('name=nbidal18 3.1.0', 'ExportVersion=3.1.0', 'OverrideCommands=true', "PreLaunchCommand=`"`$INST_JAVA`" -jar packwiz-installer-bootstrap.jar $packUrl")) {
        if (-not $instanceCfg.Contains($requiredText)) { throw "instance.cfg assertion failed: $requiredText" }
    }
    $mmc = Get-Content -LiteralPath (Join-Path $instanceRoot 'mmc-pack.json') -Raw | ConvertFrom-Json
    $minecraftComponent = @($mmc.components | Where-Object { $_.uid -eq 'net.minecraft' })
    $fabricComponent = @($mmc.components | Where-Object { $_.uid -eq 'net.fabricmc.fabric-loader' })
    if ($minecraftComponent.Count -ne 1 -or $minecraftComponent[0].version -ne '1.21.1') { throw 'mmc-pack.json Minecraft version mismatch.' }
    if ($fabricComponent.Count -ne 1 -or $fabricComponent[0].version -ne '0.19.3') { throw 'mmc-pack.json Fabric version mismatch.' }

    # Simulate files added separately by an authorized player or generated at runtime.
    $installedStillLife = Join-Path $minecraft 'datapacks\Still_Life-1.0-beta1.zip'
    New-Item -ItemType Directory -Path (Split-Path -Parent $installedStillLife) -Force | Out-Null
    Copy-Item -LiteralPath $privateStillLifeSource -Destination $installedStillLife -Force
    Write-Utf8NoBom (Join-Path $minecraft 'saves\__validation\keep.txt') "keep-save`n"
    Write-Utf8NoBom (Join-Path $minecraft 'screenshots\__validation.txt') "keep-screenshot`n"
    Write-Utf8NoBom (Join-Path $minecraft 'shaderpacks\__player-shader.zip') "player-shader`n"
    Write-Utf8NoBom (Join-Path $minecraft 'shaderpacks\__player-shader.zip.txt') "player-settings`n"
    Write-Utf8NoBom (Join-Path $minecraft 'vinurl\downloads\__player-audio.ogg') "player-vinurl-download`n"
    Write-Utf8NoBom (Join-Path $minecraft 'vinurl\executables\__runtime-helper.exe') "runtime-vinurl-helper`n"
    Write-Utf8NoBom (Join-Path $minecraft 'mods\__unknown-local.jar') "unknown-local-file`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\iris.properties') "shaderPack=__player-shader.zip`nenableShaders=true`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\voicechat\voicechat-client.properties') "player-voice-setting=true`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\chat_heads.json5') "{ nameAliases: { player: 'custom' } }`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\sodium-fingerprint.json') "{ playerGenerated: true }`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\presencefootsteps\userconfig.json') "{ playerVolume: 42 }`n"
    Write-Utf8NoBom (Join-Path $minecraft 'config\jei\world\__validation\state.ini') "player-world-state=true`n"

    $preservedPaths = New-Object Collections.Generic.List[string]
    foreach ($path in @(
        (Join-Path $minecraft 'saves\__validation\keep.txt'),
        (Join-Path $minecraft 'screenshots\__validation.txt'),
        (Join-Path $minecraft 'shaderpacks\__player-shader.zip'),
        (Join-Path $minecraft 'shaderpacks\__player-shader.zip.txt'),
        $installedStillLife,
        (Join-Path $minecraft 'vinurl\downloads\__player-audio.ogg'),
        (Join-Path $minecraft 'vinurl\executables\__runtime-helper.exe'),
        (Join-Path $minecraft 'mods\__unknown-local.jar'),
        (Join-Path $minecraft 'config\iris.properties'),
        (Join-Path $minecraft 'config\voicechat\voicechat-client.properties'),
        (Join-Path $minecraft 'config\chat_heads.json5'),
        (Join-Path $minecraft 'config\sodium-fingerprint.json'),
        (Join-Path $minecraft 'config\presencefootsteps\userconfig.json'),
        (Join-Path $minecraft 'config\jei\world\__validation\state.ini')
    )) { $preservedPaths.Add($path) }
    $preservationHashes = Get-PreservationHashes @($preservedPaths.ToArray())

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

    $firstOutput = Invoke-UpdaterWithRetry $minecraft $packUrl -Attempts 4
    Write-Utf8NoBom (Join-Path $temporaryRoot 'updater-first.log') (($firstOutput -join "`n") + "`n")
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
        $preservationHashes[$installedShader] = (Get-FileHash -LiteralPath $installedShader -Algorithm SHA256).Hash
    }
    if ([IO.File]::ReadAllText((Join-Path $minecraft 'config\__validation_overwrite.txt')) -ne "release-A`n") { throw 'Release A overwrite canary is wrong.' }
    if ([IO.File]::ReadAllText((Join-Path $minecraft 'mods\__validation_remove.jar')) -ne "validation-mod-A`n") { throw 'Release A managed-mod canary is wrong.' }
    Assert-PreservationHashes $preservationHashes

    # Prove an unchanged launch requests only pack.toml and changes no local bytes.
    $treeHashBeforeNoOp = Get-TreeHash $minecraft
    $stateHashBeforeNoOp = (Get-FileHash -LiteralPath $packwizStatePath -Algorithm SHA256).Hash
    $publishedIndex = Join-Path $published 'index.toml'
    $publishedIndexOffline = Join-Path $published 'index.toml.offline'
    Move-Item -LiteralPath $publishedIndex -Destination $publishedIndexOffline
    try {
        $secondOutput = Invoke-Updater $minecraft $packUrl -NoBootstrapUpdate
        Write-Utf8NoBom (Join-Path $temporaryRoot 'updater-noop.log') (($secondOutput -join "`n") + "`n")
    }
    finally {
        Move-Item -LiteralPath $publishedIndexOffline -Destination $publishedIndex
    }
    if (-not (($secondOutput -join "`n") -match 'Modpack is already up to date!')) { throw 'Second run did not report a no-op.' }
    if ((Get-FileHash -LiteralPath $packwizStatePath -Algorithm SHA256).Hash -ne $stateHashBeforeNoOp) { throw 'No-op run rewrote packwiz.json.' }
    if ((Get-TreeHash $minecraft) -ne $treeHashBeforeNoOp) { throw 'No-op run changed the Minecraft tree.' }

    # Publish a manifest with one unavailable payload and characterize Packwiz's failure behavior.
    foreach ($file in Get-ChildItem -LiteralPath $siteFailure -Recurse -File -Force) {
        $relative = $file.FullName.Substring($siteFailure.Length).TrimStart('\')
        $target = Join-Path $published $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
    $treeHashBeforeFailure = Get-TreeHash $minecraft
    $stateHashBeforeFailure = (Get-FileHash -LiteralPath $packwizStatePath -Algorithm SHA256).Hash
    $failedOutput = Invoke-UpdaterExpectFailure $minecraft $packUrl
    Write-Utf8NoBom (Join-Path $temporaryRoot 'updater-expected-failure.log') (($failedOutput -join "`n") + "`n")
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
    $thirdOutput = Invoke-Updater $minecraft $packUrl -NoBootstrapUpdate
    Write-Utf8NoBom (Join-Path $temporaryRoot 'updater-release-b.log') (($thirdOutput -join "`n") + "`n")
    if ([IO.File]::ReadAllText((Join-Path $minecraft 'config\__validation_overwrite.txt')) -ne "release-B`n") { throw 'Managed local edit was not overwritten by release B.' }
    if (Test-Path -LiteralPath (Join-Path $minecraft 'mods\__validation_remove.jar')) { throw 'Removed managed mod survived release B.' }
    if ([IO.File]::ReadAllText((Join-Path $minecraft 'mods\__validation_added.jar')) -ne "validation-mod-B`n") { throw 'Added release B mod was not installed.' }
    $downloadedPayloads = @($thirdOutput | ForEach-Object {
        if ($_ -match '^\(\d+/\d+\) Downloaded (.+)$') { $Matches[1] }
    } | Sort-Object)
    if (($downloadedPayloads -join '|') -ne '__validation_added.jar|__validation_overwrite.txt') {
        throw "Release B downloaded unexpected payloads: $($downloadedPayloads -join ', ')"
    }
    $deletedPayloads = @($thirdOutput | ForEach-Object {
        if ($_ -match '^Deleted (.+) \(removed from pack\)$') { $Matches[1] }
    })
    if (($deletedPayloads -join '|') -ne '__validation_remove.jar') {
        throw "Release B deleted unexpected payloads: $($deletedPayloads -join ', ')"
    }
    Assert-PreservationHashes $preservationHashes

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
# nbidal18 v3.1.0 Packwiz validation report

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
- Still Life, raw shader archives/sidecars, Iris state, VinURL helpers, player voice settings, Chat Heads aliases, and generated client fingerprints/warnings are absent from the public index.
- The strict thin migration ZIP contains only Prism metadata/icon and the updater bootstrap; it contains no Packwiz-managed payload, VinURL data, Still Life, shaders, or player state.
- The first updater run cold-installs and hash-verifies every managed payload, including the two supplied shaders from their exact official Modrinth files, before recording state.
- A second unchanged launch is a byte-for-byte no-op and does not request index.toml.
- A later release adds and removes JAR-named managed-file canaries in `mods/` and overwrites a managed config correctly.
- The changed release reports exactly the two expected downloaded payloads and the one expected managed deletion.
- A deliberately unavailable payload produces a clear nonzero failure, retains the previous Packwiz manifest, and is repaired by the next successful release.
- Saves, screenshots, managed official and player-added shader files, shader sidecars, Iris selection, voice settings, separately installed Still Life, generated VinURL files, JEI world state, and unknown local mods survive updates unchanged.

External release gates are outside this isolated behavior report. `Build-Release.ps1` separately requires the anonymous HTTPS `pack.toml` and `index.toml` to match before it produces the final ZIP. Reaching the Minecraft menu, confirming that a failed pre-launch command blocks Minecraft, and production multiplayer compatibility remain manual checks.

Known limitation: Packwiz is not transaction-wide atomic. In the deliberate failure test, an available managed config was written before a later payload returned 404, although player-controlled files and the previous manifest remained intact. The next successful pre-launch run repaired the managed release. Final Prism testing must confirm a nonzero pre-launch result blocks Minecraft from starting.
"@
    Write-Utf8NoBom $validationReport ($reportText.TrimStart() + "`n")
    Write-Host "Packwiz validation passed. Report: $validationReport"
}
catch {
    $failure = $_
    $failedAt = Get-Date
    $failureText = @"
# nbidal18 v3.1.0 Packwiz validation report

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
