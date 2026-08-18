<#
.SYNOPSIS
    Reports which published config files a real Minecraft instance writes to after syncing.

.DESCRIPTION
    Hash enforcement only works on files the game leaves alone. A config the owning mod rewrites
    during its own startup is rewritten after the pre-launch updater has run, so the moment a mod
    update reorders a key or adds a field, every player is refused at login and reopening the game
    cannot clear it. That is what happened with the chisel config and again with Nullscape.

    This compares a played instance against the published manifest and reports:

      * touched  - the file's timestamp moved after the sync, so the mod writes it at startup.
                   Any gameplay-class file here must carry "modWritesAtRuntime": true. That is a
                   watch list, not an exemption: the file stays enforced, and the flag records
                   that we must publish it in the exact form the mod writes back.
      * drifted  - the content actually differs from the published copy. A gameplay-class file
                   here is an active lockout, whether or not it is flagged - republish it from a
                   played instance so the mod's own serialisation is what ships.
      * extra    - an unmanaged file appeared under an exact root.

    Run it after playing a session, not against a fresh install: a fresh install has not yet had
    the chance to rewrite anything.

.PARAMETER InstancePath
    The Minecraft directory of a played instance. Defaults to the local Prism instance.
#>
param(
    [string] $InstancePath = "$env:APPDATA\PrismLauncher\instances\nbidal18-client\minecraft"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $repoRoot 'site\sync-manifest.json'
$classificationPath = Join-Path $PSScriptRoot 'config-classification.json'

foreach ($required in @($manifestPath, $classificationPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required input is missing: $required"
    }
}
if (-not (Test-Path -LiteralPath $InstancePath -PathType Container)) {
    throw "The instance directory does not exist: $InstancePath"
}

$syncStamp = Join-Path $InstancePath '.nbidal18-packwiz\last-successful-manifest.json'
if (-not (Test-Path -LiteralPath $syncStamp -PathType Leaf)) {
    throw "The instance has never completed a sync: $syncStamp"
}
# Two seconds of slack: the updater writes the stamp and the repaired files in the same pass.
$syncedAt = (Get-Item -LiteralPath $syncStamp).LastWriteTimeUtc.AddSeconds(2)

$manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$classification = [IO.File]::ReadAllText($classificationPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$rules = @($classification.rules + $classification.outsideConfig)

function Resolve-Rule([string] $relative) {
    $best = $null
    foreach ($rule in $rules) {
        $matched = if ($rule.match.EndsWith('/')) {
            $relative.StartsWith($rule.match, [StringComparison]::Ordinal)
        }
        else { $relative -ceq $rule.match }
        if ($matched -and ($null -eq $best -or $rule.match.Length -gt $best.match.Length)) {
            $best = $rule
        }
    }
    return $best
}

function Get-NormalizedTextSha256([string] $path) {
    $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path))
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

$normalized = @{}
foreach ($entry in $manifest.normalizedTextFiles) { $normalized[$entry.path] = $entry.sha256 }

$touched = [Collections.Generic.List[object]]::new()
$drifted = [Collections.Generic.List[object]]::new()

foreach ($entry in $manifest.files) {
    if ($entry.path -notlike 'config/*') { continue }
    $local = Join-Path $InstancePath $entry.path.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $local -PathType Leaf)) { continue }

    $rule = Resolve-Rule $entry.path
    $class = if ($null -eq $rule) { 'UNCLASSIFIED' } else { $rule.class }
    $declared = $null -ne $rule -and $rule.PSObject.Properties.Name -contains 'modWritesAtRuntime' `
        -and $rule.modWritesAtRuntime

    if ((Get-Item -LiteralPath $local).LastWriteTimeUtc -gt $syncedAt) {
        $touched.Add([pscustomobject]@{ Path = $entry.path; Class = $class; Declared = $declared })
    }

    $expected = $normalized[$entry.path]
    if ($expected) {
        $actual = Get-NormalizedTextSha256 $local
    }
    else {
        $expected = $entry.sha256
        $actual = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($actual -ne $expected) {
        $drifted.Add([pscustomobject]@{ Path = $entry.path; Class = $class; Declared = $declared })
    }
}

$managed = @{}
foreach ($entry in $manifest.files) { $managed[$entry.path.ToLowerInvariant()] = $true }
foreach ($allowed in $manifest.localAllowed) { $managed[$allowed.ToLowerInvariant()] = $true }
$extra = [Collections.Generic.List[string]]::new()
foreach ($root in $manifest.exactRoots) {
    $rootPath = Join-Path $InstancePath $root
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force) {
        $relative = $file.FullName.Substring($InstancePath.Length).TrimStart('\').Replace('\', '/')
        if (-not $managed.ContainsKey($relative.ToLowerInvariant())) { $extra.Add($relative) }
    }
}

Write-Host "Instance : $InstancePath"
Write-Host "Synced   : $syncedAt UTC"
Write-Host ''
Write-Host "Rewritten after the sync: $($touched.Count)"
foreach ($item in $touched | Sort-Object Class, Path) {
    Write-Host ("  [{0}] {1}{2}" -f $item.Class, $item.Path, $(if ($item.Class -eq 'gameplay' -and -not $item.Declared) { '   <-- NOT DECLARED' } else { '' }))
}
Write-Host ''
Write-Host "Content differs from the published copy: $($drifted.Count)"
foreach ($item in $drifted | Sort-Object Class, Path) {
    Write-Host ("  [{0}] {1}" -f $item.Class, $item.Path)
}
Write-Host ''
Write-Host "Unmanaged files under an exact root: $($extra.Count)"
foreach ($item in $extra | Sort-Object) { Write-Host "  $item" }
Write-Host ''

# A gameplay file the game rewrites is a lockout waiting for the next mod update, so it has to be
# declared. A support or player file is expected to be rewritten and needs no declaration.
$undeclared = @($touched | Where-Object { $_.Class -eq 'gameplay' -and -not $_.Declared })
$lockouts = @($drifted | Where-Object { $_.Class -eq 'gameplay' })
$unclassified = @(($touched + $drifted) | Where-Object Class -eq 'UNCLASSIFIED')

if ($unclassified.Count -ne 0) {
    throw ("These files are not classified at all: " + (($unclassified.Path | Sort-Object -Unique) -join ', '))
}
if ($lockouts.Count -ne 0) {
    throw ("These enforced gameplay configs no longer match the published copy and will refuse " +
           "every login: " + (($lockouts.Path | Sort-Object -Unique) -join ', '))
}
if ($undeclared.Count -ne 0) {
    throw ("These gameplay configs are rewritten by their mod at startup but are not marked " +
           '"modWritesAtRuntime": true in config-classification.json: ' +
           (($undeclared.Path | Sort-Object -Unique) -join ', '))
}

Write-Host 'Config stability check passed.' -ForegroundColor Green
