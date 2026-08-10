[CmdletBinding()]
param(
    [switch] $RefreshModrinth,
    [string] $PackwizPath,
    [string] $SitePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$releaseRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$updaterRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$clientRoot = Join-Path $releaseRoot '3. modpack\client'
$appearanceRoot = Join-Path $releaseRoot '2. appearance'
$metadataRoot = Join-Path $updaterRoot 'metadata'
$catalogPath = Join-Path $metadataRoot 'modrinth-catalog.json'
$reportPath = Join-Path $metadataRoot 'METADATA-REPORT.csv'
$allowlistPath = Join-Path $metadataRoot 'hosted-files.json'

if ([string]::IsNullOrWhiteSpace($SitePath)) {
    $SitePath = Join-Path $updaterRoot 'site'
}
elseif (-not [IO.Path]::IsPathRooted($SitePath)) {
    $SitePath = Join-Path $updaterRoot $SitePath
}
$SitePath = [IO.Path]::GetFullPath($SitePath)

if ([string]::IsNullOrWhiteSpace($PackwizPath)) {
    $PackwizPath = Join-Path $updaterRoot 'tools\packwiz-current\packwiz.exe'
}
elseif (-not [IO.Path]::IsPathRooted($PackwizPath)) {
    $PackwizPath = Join-Path $updaterRoot $PackwizPath
}
$PackwizPath = [IO.Path]::GetFullPath($PackwizPath)

function Assert-ChildPath([string] $Parent, [string] $Child, [string] $Label) {
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay below $parentFull (resolved value: $childFull)"
    }
}

function Write-Utf8NoBom([string] $Path, [string] $Text) {
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function ConvertTo-TomlString([AllowNull()][string] $Value) {
    if ($null -eq $Value) { return '' }
    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
}

function ConvertTo-Slug([string] $Value) {
    $slug = [Text.RegularExpressions.Regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9]+', '-')
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { return 'file' }
    return $slug
}

function Copy-FilteredTree(
    [string] $Source,
    [string] $Destination,
    [Collections.Generic.HashSet[string]] $Excluded
) {
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File -Force) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\').Replace('\', '/')
        $isExcluded = $false
        foreach ($rule in $Excluded) {
            $normalizedRule = $rule.TrimEnd('/')
            if ($relative.Equals($normalizedRule, [StringComparison]::OrdinalIgnoreCase) -or
                $relative.StartsWith($normalizedRule + '/', [StringComparison]::OrdinalIgnoreCase)) {
                $isExcluded = $true
                break
            }
        }
        if ($isExcluded) { continue }
        $target = Join-Path $Destination $relative.Replace('/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

function Invoke-ModrinthBatch([string[]] $Hashes) {
    $headers = @{ 'User-Agent' = 'nbidal18-packwiz-builder/3.1.0 (maintainer tooling)' }
    $body = @{ hashes = @($Hashes); algorithm = 'sha1' } | ConvertTo-Json -Compress
    $delay = 1
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            return Invoke-RestMethod -Method Post `
                -Uri 'https://api.modrinth.com/v2/version_files' `
                -Headers $headers `
                -ContentType 'application/json' `
                -Body $body
        }
        catch {
            $status = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $status = [int] $_.Exception.Response.StatusCode
            }
            $retryable = ($null -eq $status) -or ($status -eq 429) -or ($status -ge 500)
            if (-not $retryable -or $attempt -eq 5) { throw }
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 8)
        }
    }
}

foreach ($required in @($clientRoot, $appearanceRoot, $metadataRoot, $allowlistPath, $PackwizPath)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required path is missing: $required" }
}

Assert-ChildPath $updaterRoot $SitePath 'SitePath'
$stagePath = Join-Path $updaterRoot ('.site-staging-' + [guid]::NewGuid().ToString('N'))
Assert-ChildPath $updaterRoot $stagePath 'Staging path'

$classificationPath = Join-Path $releaseRoot '3. modpack\support\classification\MOD-CLASSIFICATION.csv'
$classificationRows = @(Import-Csv -LiteralPath $classificationPath)
$classificationByFile = @{}
foreach ($row in $classificationRows) {
    if ($classificationByFile.ContainsKey($row.file)) {
        throw "Duplicate classification row for $($row.file)"
    }
    $classificationByFile[$row.file] = $row
}

$allowlistJson = Get-Content -LiteralPath $allowlistPath -Raw | ConvertFrom-Json
$hostedAllowlist = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in @($allowlistJson.files)) {
    [void] $hostedAllowlist.Add(([string] $entry.path).Replace('\', '/'))
}

$records = New-Object Collections.Generic.List[object]
$clientMods = @(Get-ChildItem -LiteralPath (Join-Path $clientRoot 'mods') -File | Sort-Object Name)
foreach ($file in $clientMods) {
    if (-not $classificationByFile.ContainsKey($file.Name)) {
        throw "Client mod has no classification row: $($file.Name)"
    }
    $classification = $classificationByFile[$file.Name]
    if ($classification.classification -eq 'ACTIVE_SERVER') { $side = 'both' }
    elseif ($classification.classification -like 'CLIENT_ONLY_*') { $side = 'client' }
    else { throw "Unexpected client classification '$($classification.classification)' for $($file.Name)" }

    $records.Add([pscustomobject]@{
        Type = 'mod'
        SourcePath = $file.FullName
        RelativePath = ('mods/' + $file.Name)
        FileName = $file.Name
        DisplayName = if ([string]::IsNullOrWhiteSpace($classification.name)) { $file.BaseName } else { $classification.name }
        StableId = if ([string]::IsNullOrWhiteSpace($classification.mod_id)) { $classification.name } else { $classification.mod_id }
        Side = $side
        Sha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLowerInvariant()
        Sha512 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA512).Hash.ToLowerInvariant()
    })
}

$resourceRoot = Join-Path $appearanceRoot 'resourcepacks'
foreach ($file in Get-ChildItem -LiteralPath $resourceRoot -File | Sort-Object Name) {
    $records.Add([pscustomobject]@{
        Type = 'resourcepack'
        SourcePath = $file.FullName
        RelativePath = ('resourcepacks/' + $file.Name)
        FileName = $file.Name
        DisplayName = $file.BaseName
        StableId = $file.BaseName
        Side = 'client'
        Sha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLowerInvariant()
        Sha512 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA512).Hash.ToLowerInvariant()
    })
}

$shaderRoot = Join-Path $appearanceRoot 'shaderpacks'
$shaderArchives = @(Get-ChildItem -LiteralPath $shaderRoot -File | Where-Object { $_.Extension -ceq '.zip' } | Sort-Object Name)
$expectedShaderNames = @('ComplementaryUnbound_r5.8.1.zip', 'MakeUp-UltraFast-9.4b.zip')
if (($shaderArchives.Name -join '|') -cne ($expectedShaderNames -join '|')) {
    throw "Expected exactly the two reviewed shader archives, found: $($shaderArchives.Name -join ', ')"
}
foreach ($file in $shaderArchives) {
    $records.Add([pscustomobject]@{
        Type = 'shaderpack'
        SourcePath = $file.FullName
        RelativePath = ('shaderpacks/' + $file.Name)
        FileName = $file.Name
        DisplayName = $file.BaseName
        StableId = $file.BaseName
        Side = 'client'
        Sha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLowerInvariant()
        Sha512 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA512).Hash.ToLowerInvariant()
    })
}

$privateDatapackArchives = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
[void] $privateDatapackArchives.Add('Still_Life-1.0-beta1.zip')
$datapackRoot = Join-Path $clientRoot 'datapacks'
foreach ($file in Get-ChildItem -LiteralPath $datapackRoot -File -Filter '*.zip' | Sort-Object Name) {
    if ($privateDatapackArchives.Contains($file.Name)) { continue }
    $records.Add([pscustomobject]@{
        Type = 'datapack'
        SourcePath = $file.FullName
        RelativePath = ('datapacks/' + $file.Name)
        FileName = $file.Name
        DisplayName = $file.BaseName
        StableId = $file.BaseName
        Side = 'both'
        Sha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLowerInvariant()
        Sha512 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA512).Hash.ToLowerInvariant()
    })
}

$chickenDatapack = Join-Path $datapackRoot 'Yeetnado_1000_Chickens_1.21.1.zip'
if (Test-Path -LiteralPath $chickenDatapack -PathType Leaf) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($chickenDatapack)
    try {
        $functionEntry = $archive.GetEntry('data/yeetnado/function/chickens.mcfunction')
        $metadataEntry = $archive.GetEntry('pack.mcmeta')
        if (-not $functionEntry -or -not $metadataEntry) { throw 'The chicken utility datapack is missing its function or metadata.' }
        $reader = [IO.StreamReader]::new($functionEntry.Open())
        try { $commands = @($reader.ReadToEnd() -split "`r?`n" | Where-Object { $_ }) }
        finally { $reader.Dispose() }
        if ($commands.Count -ne 1000 -or @($commands | Where-Object { $_ -ne 'execute at @s run summon chicken ~ ~ ~' }).Count -ne 0) {
            throw 'The chicken utility datapack must target the player running the function; literal player names are not publishable.'
        }
        $reader = [IO.StreamReader]::new($metadataEntry.Open())
        try { $metadataText = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
        if ($metadataText -notmatch 'player running the function') { throw 'The chicken utility datapack description is not generic.' }
    }
    finally { $archive.Dispose() }
}

if ($RefreshModrinth) {
    $versionByHash = @{}
    for ($offset = 0; $offset -lt $records.Count; $offset += 100) {
        $last = [Math]::Min($offset + 99, $records.Count - 1)
        $hashes = @($records[$offset..$last] | ForEach-Object { $_.Sha1 })
        $response = Invoke-ModrinthBatch $hashes
        foreach ($property in $response.PSObject.Properties) {
            $versionByHash[$property.Name.ToLowerInvariant()] = $property.Value
        }
    }

    $catalogEntries = New-Object Collections.Generic.List[object]
    foreach ($record in $records) {
        if (-not $versionByHash.ContainsKey($record.Sha1)) { continue }
        $version = $versionByHash[$record.Sha1]
        $matches = @($version.files | Where-Object {
            $_.hashes.sha1 -and $_.hashes.sha1.ToLowerInvariant() -eq $record.Sha1
        })
        if ($matches.Count -ne 1) {
            throw "Expected exactly one Modrinth file matching $($record.RelativePath); found $($matches.Count)."
        }
        $remote = $matches[0]
        if ($remote.hashes.sha512.ToLowerInvariant() -ne $record.Sha512) {
            throw "Modrinth SHA-512 mismatch for $($record.RelativePath)"
        }
        if (-not ([uri] $remote.url).Scheme.Equals('https', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Non-HTTPS Modrinth URL for $($record.RelativePath): $($remote.url)"
        }
        if ($record.Type -in @('mod', 'datapack', 'shaderpack') -and $remote.filename -cne $record.FileName) {
            throw "Modrinth filename mismatch for $($record.FileName): $($remote.filename)"
        }
        $catalogEntries.Add([ordered]@{
            relativePath = $record.RelativePath
            sha1 = $record.Sha1
            sha512 = $record.Sha512
            projectId = [string] $version.project_id
            versionId = [string] $version.id
            versionName = [string] $version.name
            versionNumber = [string] $version.version_number
            remoteFilename = [string] $remote.filename
            url = [string] $remote.url
        })
    }
    $catalog = [ordered]@{
        schemaVersion = 1
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        entries = $catalogEntries.ToArray()
    }
    Write-Utf8NoBom $catalogPath (($catalog | ConvertTo-Json -Depth 8) + "`n")
}

if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) {
    throw "Modrinth catalog is missing. Run this script once with -RefreshModrinth."
}
$catalogJson = [IO.File]::ReadAllText($catalogPath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
$catalogByHash = @{}
foreach ($entry in @($catalogJson.entries)) {
    $key = ([string] $entry.sha1).ToLowerInvariant()
    if ($catalogByHash.ContainsKey($key)) { throw "Duplicate Modrinth catalog hash: $key" }
    $catalogByHash[$key] = $entry
}

$configExclusions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($path in @(
    'iris.properties',
    'iris-excluded.json',
    'chat_heads.json5',
    'sodium-fingerprint.json',
    'presencefootsteps/updater.json',
    'presencefootsteps/userconfig.json',
    'etf_warnings.json',
    'voicechat/voicechat-client.properties',
    'voicechat/player-volumes.properties',
    'voicechat/category-volumes.properties',
    'voicechat/username-cache.json',
    'jei/world'
)) { [void] $configExclusions.Add($path) }

$datapackExclusions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($privateName in $privateDatapackArchives) { [void] $datapackExclusions.Add($privateName) }
foreach ($record in $records | Where-Object { $_.Type -eq 'datapack' }) { [void] $datapackExclusions.Add($record.FileName) }

$report = New-Object Collections.Generic.List[object]
$blocking = New-Object Collections.Generic.List[string]
$usedMetadataNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

try {
    New-Item -ItemType Directory -Path $stagePath -Force | Out-Null

    Copy-FilteredTree (Join-Path $clientRoot 'config') (Join-Path $stagePath 'config') $configExclusions
    Copy-FilteredTree $datapackRoot (Join-Path $stagePath 'datapacks') $datapackExclusions
    Copy-FilteredTree (Join-Path $clientRoot 'defaultconfigs') (Join-Path $stagePath 'defaultconfigs') ([Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase))

    Copy-Item -LiteralPath (Join-Path $clientRoot 'servers.dat') -Destination (Join-Path $stagePath 'servers.dat') -Force
    Copy-Item -LiteralPath (Join-Path $clientRoot 'credits.txt') -Destination (Join-Path $stagePath 'credits.txt') -Force
    Copy-Item -LiteralPath (Join-Path $clientRoot 'THIRD-PARTY-NOTICES.md') -Destination (Join-Path $stagePath 'THIRD-PARTY-NOTICES.md') -Force
    Copy-FilteredTree (Join-Path $clientRoot 'licenses') (Join-Path $stagePath 'licenses') ([Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase))
    Copy-Item -LiteralPath (Join-Path $appearanceRoot 'support\client-options.txt') -Destination (Join-Path $stagePath 'options.txt') -Force
    Copy-Item -LiteralPath (Join-Path $appearanceRoot 'support\client-options.amecsapi.txt') -Destination (Join-Path $stagePath 'options.amecsapi.txt') -Force

    foreach ($record in $records) {
        if ($catalogByHash.ContainsKey($record.Sha1)) {
            $entry = $catalogByHash[$record.Sha1]
            if ([string] $entry.sha512 -ne $record.Sha512 -or [string] $entry.relativePath -ne $record.RelativePath) {
                throw "Stale Modrinth catalog entry for $($record.RelativePath); rerun with -RefreshModrinth."
            }
            if ($record.RelativePath -eq 'datapacks/Realistic Health v3.6.zip' -and
                (([string] $entry.projectId) -ne 'tVXpaKa8' -or ([string] $entry.versionId) -ne '4eO6dWtQ')) {
                throw 'Realistic Health must resolve to the reviewed Modrinth project tVXpaKa8, version 4eO6dWtQ.'
            }
            if ($record.RelativePath -eq 'shaderpacks/ComplementaryUnbound_r5.8.1.zip' -and
                (([string] $entry.projectId) -ne 'R6NEzAwj' -or ([string] $entry.versionId) -ne 'VMHXIk50')) {
                throw 'Complementary Unbound must resolve to the reviewed Modrinth project R6NEzAwj, version VMHXIk50.'
            }
            if ($record.RelativePath -eq 'shaderpacks/MakeUp-UltraFast-9.4b.zip' -and
                (([string] $entry.projectId) -ne 'izsIPI7a' -or ([string] $entry.versionId) -ne 'CQSkSzPv')) {
                throw 'MakeUp Ultra Fast must resolve to the reviewed Modrinth project izsIPI7a, version CQSkSzPv.'
            }
            $slug = ConvertTo-Slug $record.StableId
            $metadataName = "$slug.pw.toml"
            if (-not $usedMetadataNames.Add("$($record.Type)/$metadataName")) {
                $metadataName = "$slug-$(([string] $entry.projectId).ToLowerInvariant()).pw.toml"
                if (-not $usedMetadataNames.Add("$($record.Type)/$metadataName")) {
                    throw "Metadata filename collision for $($record.RelativePath)"
                }
            }
            $folder = switch ($record.Type) {
                'mod' { 'mods' }
                'resourcepack' { 'resourcepacks' }
                'datapack' { 'datapacks' }
                'shaderpack' { 'shaderpacks' }
                default { throw "Unsupported record type: $($record.Type)" }
            }
            $metadataPath = Join-Path (Join-Path $stagePath $folder) $metadataName
            $toml = @"
name = "$(ConvertTo-TomlString $record.DisplayName)"
filename = "$(ConvertTo-TomlString $record.FileName)"
side = "$($record.Side)"

[download]
hash-format = "sha512"
hash = "$($record.Sha512)"
url = "$(ConvertTo-TomlString ([string] $entry.url))"

[update.modrinth]
mod-id = "$(ConvertTo-TomlString ([string] $entry.projectId))"
version = "$(ConvertTo-TomlString ([string] $entry.versionId))"
"@
            Write-Utf8NoBom $metadataPath ($toml.TrimStart() + "`n")
            $report.Add([pscustomobject]@{
                path = $record.RelativePath
                type = $record.Type
                side = $record.Side
                management = 'modrinth'
                sha1 = $record.Sha1
                sha512 = $record.Sha512
                project_id = [string] $entry.projectId
                version_id = [string] $entry.versionId
                metadata_file = "$folder/$metadataName"
                note = if ([string] $entry.remoteFilename -cne $record.FileName) { "Remote filename: $($entry.remoteFilename)" } else { '' }
            })
            continue
        }

        if ($hostedAllowlist.Contains($record.RelativePath)) {
            $destination = Join-Path $stagePath $record.RelativePath.Replace('/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $record.SourcePath -Destination $destination -Force
            $report.Add([pscustomobject]@{
                path = $record.RelativePath
                type = $record.Type
                side = $record.Side
                management = 'internal-hosted'
                sha1 = $record.Sha1
                sha512 = $record.Sha512
                project_id = ''
                version_id = ''
                metadata_file = ''
                note = 'Explicitly approved by metadata/hosted-files.json'
            })
            continue
        }

        $management = 'unmanaged-blocking'
        $report.Add([pscustomobject]@{
            path = $record.RelativePath
            type = $record.Type
            side = $record.Side
            management = $management
            sha1 = $record.Sha1
            sha512 = $record.Sha512
            project_id = ''
            version_id = ''
            metadata_file = ''
            note = 'No exact Modrinth match and not approved for public raw hosting.'
        })
        $blocking.Add($record.RelativePath)
    }

    $report | Sort-Object type,path | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
    if ($blocking.Count -gt 0) {
        throw "Unapproved non-Modrinth archives block the update site: $($blocking -join ', ')"
    }

    Write-Utf8NoBom (Join-Path $stagePath '.packwizignore') @'
/.nojekyll
/.packwizignore
/pack.toml
/index.toml
/shaderpacks/*.zip
/shaderpacks/*.zip.txt
/vinurl/
/datapacks/Still_Life-1.0-beta1.zip
/config/iris.properties
/config/iris-excluded.json
/config/chat_heads.json5
/config/sodium-fingerprint.json
/config/presencefootsteps/updater.json
/config/presencefootsteps/userconfig.json
/config/etf_warnings.json
/config/voicechat/voicechat-client.properties
/config/voicechat/player-volumes.properties
/config/voicechat/category-volumes.properties
/config/voicechat/username-cache.json
/config/jei/world/
'@
    Write-Utf8NoBom (Join-Path $stagePath '.nojekyll') ''
    Write-Utf8NoBom (Join-Path $stagePath 'index.toml') ('hash-format = "sha256"' + "`n")
    Write-Utf8NoBom (Join-Path $stagePath 'pack.toml') @'
name = "nbidal18"
version = "3.1.0"
description = "Fabric 1.21.1 adventure modpack with incremental Prism updates"
pack-format = "packwiz:1.1.0"

[index]
file = "index.toml"
hash-format = "sha256"
hash = "0000000000000000000000000000000000000000000000000000000000000000"

[versions]
fabric = "0.19.3"
minecraft = "1.21.1"
'@

    Push-Location $stagePath
    try {
        & $PackwizPath refresh
        if ($LASTEXITCODE -ne 0) { throw "packwiz refresh failed with exit code $LASTEXITCODE" }
    }
    finally {
        Pop-Location
    }

    $packText = Get-Content -LiteralPath (Join-Path $stagePath 'pack.toml') -Raw
    if ($packText -match 'hash = "0{64}"') { throw 'packwiz did not refresh the index hash.' }
    $privateIndexMatches = @(Select-String -LiteralPath (Join-Path $stagePath 'index.toml') -Pattern 'file = "datapacks/Still_Life-1\.0-beta1\.zip"|file = "shaderpacks/[^"]+\.zip(?:\.txt)?"|config/iris.properties|config/jei/world/|vinurl/')
    if ($privateIndexMatches.Count -gt 0) {
        throw "Private or player-controlled content entered index.toml: $($privateIndexMatches.Line -join '; ')"
    }

    if (Test-Path -LiteralPath $SitePath) {
        Assert-ChildPath $updaterRoot $SitePath 'Existing site path'
        Remove-Item -LiteralPath $SitePath -Recurse -Force
    }
    Move-Item -LiteralPath $stagePath -Destination $SitePath

    $managedCount = @($report | Where-Object { $_.management -in @('modrinth', 'internal-hosted') }).Count
    $modrinthCount = @($report | Where-Object { $_.management -eq 'modrinth' }).Count
    $hostedCount = @($report | Where-Object { $_.management -eq 'internal-hosted' }).Count
    $unmanagedCount = @($report | Where-Object { $_.management -like 'unmanaged-*' }).Count
    Write-Host "Created Packwiz site: $SitePath"
    Write-Host "Managed downloadable archives: $managedCount ($modrinthCount Modrinth, $hostedCount internal hosted)"
    Write-Host "Unmanaged downloadable archives: $unmanagedCount"
    Write-Host "Metadata report: $reportPath"
}
finally {
    if (Test-Path -LiteralPath $stagePath) {
        Assert-ChildPath $updaterRoot $stagePath 'Cleanup staging path'
        Remove-Item -LiteralPath $stagePath -Recurse -Force
    }
}
