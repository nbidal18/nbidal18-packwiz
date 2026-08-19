<#
.SYNOPSIS
    Builds the nbidal18_gear_tiers datapack: TieredZ modifiers with the rarity colouring removed,
    reforging killed at the data layer, and Epic Knights shields taught to the tag TieredZ needs.

.DESCRIPTION
    Three things, all derived from the shipped JARs rather than hand-copied, so a TieredZ or Epic
    Knights update cannot silently leave this behind:

      1. Every modifier under data/tiered/item_attributes/ is taken from the TieredZ JAR and
         republished with its style colour set to white. TieredZ's ItemStackClientMixin prepends
         the tier name to the item name and applies the modifier's own style; there is no config
         switch for that, so the datapack is the only place to neutralise it. White is the colour
         an ordinary item name already is, so the tier reads as a plain label rather than a rarity
         badge. The bordered tooltip is turned off separately by tieredTooltip=false.

      2. tiered:reforge_base_item and tiered:reforge_addition ship empty. showReforgingTab=false
         already removes the anvil tab, but emptying the tags means the mechanic is dead even if
         the screen is reached some other way. A tier is rolled once when the item is made; a
         player who dislikes the roll crafts the item again.

      3. Epic Knights shields are added to c:tools/shields. TieredZ's 24 shield modifiers are the
         only ones keyed on a convention tag rather than a vanilla one, and Epic Knights populates
         the vanilla armour and sword tags but ships no c:tools/shields, so without this its
         shields would be the one gear category the tier system skips.
#>
param(
    [string] $ReleaseRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PackVersion.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = Get-ReleaseRoot $repoRoot
}
else {
    $ReleaseRoot = [IO.Path]::GetFullPath($ReleaseRoot)
    Assert-ReleaseRootMatchesVersion $repoRoot $ReleaseRoot
}

$utf8NoBom = New-Object Text.UTF8Encoding($false)
$clientMods = Join-Path $ReleaseRoot '3. modpack\client\mods'

function Resolve-SingleJar([string] $pattern) {
    $found = @(Get-ChildItem -LiteralPath $clientMods -File -Filter $pattern)
    if ($found.Count -ne 1) {
        throw "Expected exactly one $pattern in the client mods folder; found $($found.Count)."
    }
    return $found[0].FullName
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

function Read-ZipEntryText($archive, $entry) {
    $stream = $entry.Open()
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

$tieredJar = Resolve-SingleJar 'tiered-*.jar'
$epicKnightsJar = Resolve-SingleJar 'epic-knights-*.jar'

$datapack = Join-Path $ReleaseRoot '3. modpack\client\datapacks\nbidal18_gear_tiers'
if (Test-Path -LiteralPath $datapack) {
    Remove-Item -LiteralPath $datapack -Recurse -Force
}
New-Item -ItemType Directory -Path $datapack -Force | Out-Null

[IO.File]::WriteAllText((Join-Path $datapack 'pack.mcmeta'), @'
{
  "pack": {
    "pack_format": 48,
    "description": "nbidal18 gear tiers - TieredZ modifiers without rarity colouring"
  }
}
'@, $utf8NoBom)

# --- 1. Modifiers, republished without rarity colour -------------------------------------------
$archive = [IO.Compression.ZipFile]::OpenRead($tieredJar)
try {
    $modifierEntries = @($archive.Entries | Where-Object {
        $_.FullName -like 'data/tiered/item_attributes/*' -and $_.FullName.EndsWith('.json')
    })
    if ($modifierEntries.Count -eq 0) {
        throw "No item_attributes entries were found in $tieredJar."
    }
    foreach ($entry in $modifierEntries) {
        $text = Read-ZipEntryText $archive $entry
        # "color" appears only inside the modifier's style object; the attribute blocks carry
        # type/modifier/operation/amount and no colour of any kind.
        $neutral = [regex]::Replace($text, '"color"\s*:\s*"[a-z_]+"', '"color": "white"')
        if ($neutral -eq $text -and $text -match '"style"') {
            throw "Could not neutralise the style colour in $($entry.FullName)."
        }
        $target = Join-Path $datapack ($entry.FullName -replace '/', '\')
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        [IO.File]::WriteAllText($target, $neutral, $utf8NoBom)
    }
    Write-Host "Republished $($modifierEntries.Count) TieredZ modifiers without rarity colour."
}
finally { $archive.Dispose() }

# --- 2. Reforging dead at the data layer -------------------------------------------------------
$tagDirectory = Join-Path $datapack 'data\tiered\tags\item'
New-Item -ItemType Directory -Path $tagDirectory -Force | Out-Null
foreach ($tag in @('reforge_base_item', 'reforge_addition')) {
    [IO.File]::WriteAllText((Join-Path $tagDirectory "$tag.json"), @'
{
  "replace": true,
  "values": []
}
'@, $utf8NoBom)
}

# --- 3. Epic Knights shields into c:tools/shields ----------------------------------------------
$archive = [IO.Compression.ZipFile]::OpenRead($epicKnightsJar)
try {
    $shields = @($archive.Entries |
        Where-Object { $_.FullName -match '^assets/magistuarmory/models/item/([a-z0-9_]*shield[a-z0-9_]*)\.json$' } |
        ForEach-Object { [regex]::Match($_.FullName, '([a-z0-9_]*shield[a-z0-9_]*)\.json$').Groups[1].Value } |
        Where-Object { -not $_.EndsWith('_blocking') } |
        Sort-Object -Unique)
}
finally { $archive.Dispose() }
if ($shields.Count -eq 0) {
    throw "No Epic Knights shield models were found in $epicKnightsJar."
}

$shieldTagDirectory = Join-Path $datapack 'data\c\tags\item\tools'
New-Item -ItemType Directory -Path $shieldTagDirectory -Force | Out-Null
$shieldValues = ($shields | ForEach-Object { "    { `"id`": `"magistuarmory:$_`", `"required`": false }" }) -join ",`n"
[IO.File]::WriteAllText((Join-Path $shieldTagDirectory 'shields.json'),
    "{`n  `"replace`": false,`n  `"values`": [`n$shieldValues`n  ]`n}`n", $utf8NoBom)
Write-Host "Added $($shields.Count) Epic Knights shields to c:tools/shields."

# --- Mirror to the server payloads and verify ---------------------------------------------------
$mirrors = @(
    (Join-Path $ReleaseRoot '3. modpack\server\datapacks\nbidal18_gear_tiers'),
    (Join-Path $ReleaseRoot '4. server\2. online-hosting\datapacks\nbidal18_gear_tiers')
)
foreach ($mirror in $mirrors) {
    if (Test-Path -LiteralPath $mirror) { Remove-Item -LiteralPath $mirror -Recurse -Force }
    Copy-Item -LiteralPath $datapack -Destination $mirror -Recurse -Force
}

$masterFiles = @(Get-ChildItem -LiteralPath $datapack -Recurse -File)
foreach ($mirror in $mirrors) {
    foreach ($file in $masterFiles) {
        $relative = $file.FullName.Substring($datapack.Length).TrimStart('\')
        $copy = Join-Path $mirror $relative
        if (-not (Test-Path -LiteralPath $copy -PathType Leaf)) {
            throw "The mirrored datapack at $mirror is missing $relative."
        }
        if ((Get-Sha256 $file.FullName) -ne (Get-Sha256 $copy)) {
            throw "The mirrored datapack at $mirror differs from the master at $relative."
        }
    }
}

Write-Host "Gear tiers datapack built and mirrored: $($masterFiles.Count) files in each of three copies." -ForegroundColor Green
