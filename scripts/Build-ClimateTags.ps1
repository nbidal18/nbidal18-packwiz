<#
.SYNOPSIS
    Generates the pack's biome climate classification: one tag and one environment per band.

.DESCRIPTION
    Thermoo authors temperature in datapacks. An environment definition binds a biome selector to a
    provider, the provider gives degrees, and Frostiful and Scorchful ship both - keyed on climate
    tags built entirely out of convention tags like #c:is_snowy, #c:is_taiga and #c:is_hill. A biome
    that joins none of those matches no climate and has no temperature behaviour at all.

    v4.4.3 filled that gap by hand and got it wrong. Its audit asked each mod which biomes it named
    explicitly and concluded 82 of 95 had nothing; it missed tag-of-tag chains, and Terralith routes
    its own biomes into #c:is_cold/overworld, #c:is_taiga and #c:is_hill. 33 already had a climate
    and 11 were given a contradicting second one - alpine_highlands was cool to Frostiful and
    temperate to us at once, which is why a mountain cabin read a cold-side base in spring.

    ### Why this does not use the mods' climate tags at all

    The obvious fix was to keep feeding their extension tags and add every biome to the
    is_not_climate tag of every other climate. **That was built, and it silently destroyed
    temperature on 14 biomes.** Frostiful's is_not_climate/cold contains #frostiful:is_climate/
    freezing - membership, not effective classification. A snowy Terralith biome is a freezing
    member through a convention tag, so excluding it from freezing still leaves it excluded from
    cold, and it falls out of every band. siberian_taiga and snowy_badlands ended up with no
    climate whatsoever. Nothing in the test suite catches that: the server boots, the tags parse,
    and the biome is simply inert.

    So the mods' tags are left completely alone, and this pack states its own answer instead:
    **six band tags of our own, and six environment definitions that use them.**

    ### Priority is what makes it deterministic

    Thermoo applies every matching environment in priority order, highest first, onto one shared
    component builder - and a climate provider SETS the temperature rather than adding to it. So
    the last one applied wins, and lower priority means later. The mods ship theirs at the default
    1000. These are 500, so wherever a mod also claims a biome, this pack's answer overwrites it.
    Altitude (100) and shelter (90) are lower still and shift on top of whatever won.

    No exclusions, no fighting anyone's tag chain, exactly one base per biome.

    ### Two faults fix themselves as a result

    Scorchful's apply_shade_for_time sets a flat 20 C whenever sky light is under 13 in daylight,
    and its night branch does the same in humid biomes. Both reached cold biomes only because those
    biomes sat in a Scorchful climate. The cold bands below use Frostiful's modifier list instead,
    which carries the daylight sun bonus and nothing else - so an unheated hut in a blizzard is no
    longer room temperature, and night is no longer warmer than day on a mountain. The warm bands
    keep Scorchful's list, because shade genuinely should save you in a desert.

    Scope is modded overworld biomes. Vanilla is left to the mods, which already agree on it.

    Writes the client master only; Build-Temperature.ps1 runs next and mirrors to both server
    copies, verifying every file by hash.
#>
param(
    [string] $ReleaseRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PackVersion.ps1')

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = Get-ReleaseRoot $repoRoot
}
else {
    $ReleaseRoot = [IO.Path]::GetFullPath($ReleaseRoot)
    Assert-ReleaseRootMatchesVersion $repoRoot $ReleaseRoot
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$modsDir = Join-Path $ReleaseRoot '3. modpack\client\mods'
$datapackRoot = Join-Path $ReleaseRoot '3. modpack\client\datapacks\nbidal18_temperature\data'

<#
    Boundaries are vanilla mechanics rather than round numbers:

      -0.15  separates the peaks and snowy taigas (-0.3 to -0.7) from the snowy lowlands
       0.15  THE SNOW LINE. Below this vanilla drops snow instead of rain and water freezes. A
             biome where it snows is not "cool" - and v4.4.3 put this boundary at 0.05, which
             classified siberian_taiga (0.13), snowy_maple_forest (0.10) and cold_shrubland (0.14)
             as merely cool while snow visibly fell on them
       0.45  above taiga (0.25) and windswept hills (0.2)
       1.00  above plains (0.8) and jungle (0.95)
       2.00  desert and badlands sit exactly here

    Terralith's own reference/temperature tags were read and deliberately NOT used. They disagree
    with a numeric derivation on 58 of the 78 biomes they cover, and the disagreements show what
    they are: worldgen region labels, not felt temperature. snowy_badlands is in their "warm" list,
    with a temperature of 0.0 and snow falling on it. The numeric value drives snow, freezing and
    foliage colour, so it is the closer proxy - and it needs nothing from a future mod beyond the
    biome file it already ships.

    provider  - referenced by id from the owning mod, so the pack inherits their seasonal curves
                rather than restating numbers that would then drift.
    modifiers - Frostiful's list for the cold bands (daylight sun bonus), Scorchful's for the warm
                ones (shade cools, night drops). See the header for why that split matters.
#>
$bands = @(
    @{ name = 'freezing';  below = -0.15;              provider = 'frostiful:set_temperature/freezing_climate';  modifiers = '#frostiful:temperature_modifiers' }
    @{ name = 'cold';      below =  0.15;              provider = 'frostiful:set_temperature/cold_climate';      modifiers = '#frostiful:temperature_modifiers' }
    @{ name = 'cool';      below =  0.45;              provider = 'frostiful:set_temperature/cool_climate';      modifiers = '#frostiful:temperature_modifiers' }
    @{ name = 'temperate'; below =  1.00;              provider = $null;                                          modifiers = '#frostiful:temperature_modifiers' }
    @{ name = 'warm';      below =  2.00;              provider = 'scorchful:set_temperature/warm_climate';      modifiers = $null }
    @{ name = 'scorching'; below = [double]::MaxValue; provider = 'scorchful:set_temperature/scorching_climate'; modifiers = $null }
)

<#
    Temperate has no usable provider to borrow. Frostiful's defines only winter and Scorchful's
    only summer, so between them spring and autumn write nothing at all and the band silently falls
    back on Thermoo's 20 C default - which is why a temperate biome behaved differently in April
    than in July for reasons no one could see. Stated outright here instead, at the values the two
    mods already imply.
#>
$temperateSeasons = @{ spring = 20.0; summer = 30.0; autumn = 20.0; winter = 5.0 }

# --- read every modded biome ------------------------------------------------------------------

$biomes = @{}
$otherDimension = New-Object 'System.Collections.Generic.HashSet[string]'

foreach ($jar in Get-ChildItem -LiteralPath $modsDir -File -Filter '*.jar' | Sort-Object Name) {
    $zip = [IO.Compression.ZipFile]::OpenRead($jar.FullName)
    try {
        foreach ($entry in $zip.Entries) {
            $n = $entry.FullName
            if ($n -match '^data/([^/]+)/worldgen/biome/(.+)\.json$') {
                $id = "$($Matches[1]):$($Matches[2])"
                $reader = New-Object IO.StreamReader($entry.Open())
                try { $json = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                if ($null -ne $json -and $json.PSObject.Properties.Name -contains 'temperature') {
                    $biomes[$id] = [double] $json.temperature
                }
                continue
            }
            if ($n -match '^data/c/tags/worldgen/biome/is_(nether|end)\.json$') {
                $reader = New-Object IO.StreamReader($entry.Open())
                try { $json = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                foreach ($v in $json.values) {
                    $vid = if ($v -is [string]) { $v } else { $v.id }
                    if (-not $vid.StartsWith('#')) { [void] $otherDimension.Add($vid) }
                }
            }
        }
    }
    finally { $zip.Dispose() }
}

<#
    Incendium and Nullscape reach #c:is_nether and #c:is_end through their own tag chains rather
    than by naming biomes, so they are dropped by namespace - and the script fails loudly below if
    that ever leaves nothing, rather than silently classifying another dimension.

    Vanilla is dropped too, which is less obvious than it sounds: Terralith ships 45 overrides of
    vanilla biomes under data/minecraft/worldgen/biome/, so a jar scan picks them up as ordinary
    modded files. Both temperature mods already agree on vanilla and nobody has reported it wrong.
    Widening scope later means deleting 'minecraft' from this list and re-testing, nothing more.
#>
$outOfScopeNamespaces = @('incendium', 'nullscape', 'minecraft')
foreach ($id in @($biomes.Keys)) {
    if ($outOfScopeNamespaces -contains $id.Split(':')[0] -or $otherDimension.Contains($id)) {
        $biomes.Remove($id)
    }
}
if ($biomes.Count -eq 0) { throw 'No modded overworld biomes were found; the jar scan must be wrong.' }

# --- classify ---------------------------------------------------------------------------------

$byBand = @{}
foreach ($b in $bands) { $byBand[$b.name] = New-Object 'System.Collections.Generic.List[string]' }
foreach ($id in ($biomes.Keys | Sort-Object)) {
    $t = $biomes[$id]
    foreach ($b in $bands) {
        if ($t -lt $b.below) { $byBand[$b.name].Add($id); break }
    }
}

# --- write ------------------------------------------------------------------------------------

function Write-Json([string] $relative, [string[]] $lines) {
    $path = Join-Path $datapackRoot ($relative -replace '/', '\')
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($path, ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
}

$PACK_PRIORITY = 500

foreach ($b in $bands) {
    $members = @($byBand[$b.name])

    # the band tag
    $tag = New-Object 'System.Collections.Generic.List[string]'
    $tag.Add('{')
    $tag.Add('  "__comment": [')
    $tag.Add('    "GENERATED by scripts/Build-ClimateTags.ps1 - do not hand-edit.",')
    $tag.Add("    `"The pack's $($b.name) biomes, derived from each biome's own vanilla temperature value.`"")
    $tag.Add('  ],')
    $tag.Add('  "replace": false,')
    if ($members.Count -eq 0) { $tag.Add('  "values": []') }
    else {
        $tag.Add('  "values": [')
        for ($i = 0; $i -lt $members.Count; $i++) {
            $comma = if ($i -lt $members.Count - 1) { ',' } else { '' }
            $tag.Add("    `"$($members[$i])`"$comma")
        }
        $tag.Add('  ]')
    }
    $tag.Add('}')
    Write-Json "nbidal18/tags/worldgen/biome/climate/$($b.name).json" $tag

    # the environment that uses it
    $env = New-Object 'System.Collections.Generic.List[string]'
    $env.Add('{')
    $env.Add('  "__comment": [')
    $env.Add('    "GENERATED by scripts/Build-ClimateTags.ps1 - do not hand-edit.",')
    $env.Add("    `"Priority $PACK_PRIORITY, below the mods' default of 1000, so this pack's answer is applied last and`",")
    $env.Add('    "wins the base wherever a mod convention tag also claims one of these biomes. Altitude and",')
    $env.Add('    "shelter are lower still and shift on top of whatever won."')
    $env.Add('  ],')
    $env.Add("  `"biomes`": `"#nbidal18:climate/$($b.name)`",")
    $env.Add("  `"priority`": $PACK_PRIORITY,")

    if ($null -eq $b.provider) {
        # temperate: stated outright, because neither mod defines a usable full year for it
        $env.Add('  "provider": {')
        $env.Add('    "type": "thermoo:modify",')
        $env.Add("    `"modifiers`": `"$($b.modifiers)`",")
        $env.Add('    "base": {')
        $env.Add('      "type": "thermoo:seasonal/temperate",')
        $env.Add('      "fallback_season": "spring",')
        $env.Add('      "seasons": {')
        $seasons = @('spring', 'summer', 'autumn', 'winter')
        for ($i = 0; $i -lt $seasons.Count; $i++) {
            $s = $seasons[$i]
            $comma = if ($i -lt $seasons.Count - 1) { ',' } else { '' }
            $env.Add("        `"$s`": {")
            $env.Add('          "type": "thermoo:constant",')
            $env.Add('          "components": {')
            $env.Add("            `"thermoo:temperature`": $($temperateSeasons[$s])")
            $env.Add('          }')
            $env.Add("        }$comma")
        }
        $env.Add('      }')
        $env.Add('    }')
        $env.Add('  }')
    }
    elseif ($null -eq $b.modifiers) {
        # Scorchful's providers already wrap themselves in thermoo:modify with their own modifiers
        $env.Add("  `"provider`": `"$($b.provider)`"")
    }
    else {
        $env.Add('  "provider": {')
        $env.Add('    "type": "thermoo:modify",')
        $env.Add("    `"modifiers`": `"$($b.modifiers)`",")
        $env.Add("    `"base`": `"$($b.provider)`"")
        $env.Add('  }')
    }
    $env.Add('}')
    Write-Json "nbidal18/thermoo/environment/climate/$($b.name).json" $env
}

<#
    v4.4.3 fed the mods' own extension tags. Those files are no longer generated, so any left over
    from an earlier build would keep claiming biomes this script has since moved. Remove them.
#>
$retired = @(
    'frostiful/tags/worldgen/biome/freezing_biomes.json'
    'frostiful/tags/worldgen/biome/cold_biomes.json'
    'frostiful/tags/worldgen/biome/cool_biomes.json'
    'c/tags/worldgen/biome/is_temperate/overworld.json'
    'scorchful/tags/worldgen/biome/warm_biomes.json'
    'scorchful/tags/worldgen/biome/scorching_biomes.json'
    'frostiful/tags/worldgen/biome/is_not_climate/freezing.json'
    'frostiful/tags/worldgen/biome/is_not_climate/cold.json'
    'frostiful/tags/worldgen/biome/is_not_climate/cool.json'
    'frostiful/tags/worldgen/biome/is_not_climate/temperate.json'
    'scorchful/tags/worldgen/biome/is_not_climate/temperate.json'
    'scorchful/tags/worldgen/biome/is_not_climate/warm.json'
    'scorchful/tags/worldgen/biome/is_not_climate/scorching.json'
)
foreach ($r in $retired) {
    $p = Join-Path $datapackRoot ($r -replace '/', '\')
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
foreach ($d in @('c', 'frostiful')) {
    $dir = Join-Path $datapackRoot $d
    if (Test-Path -LiteralPath $dir) {
        $left = @(Get-ChildItem -LiteralPath $dir -Recurse -File)
        if ($left.Count -eq 0) { Remove-Item -LiteralPath $dir -Recurse -Force }
    }
}

# --- report -----------------------------------------------------------------------------------

$total = 0
foreach ($b in $bands) {
    $c = $byBand[$b.name].Count
    $total += $c
    Write-Host ("  {0,-10} {1,3}" -f $b.name, $c)
}
Write-Host "Climate tags generated: $total modded overworld biomes, $($bands.Count) bands, own environments at priority $PACK_PRIORITY." -ForegroundColor Green
