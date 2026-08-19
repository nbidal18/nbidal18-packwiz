<#
.SYNOPSIS
    Regenerates the nbidal18_progression datapack and mirrors it to the server copies.

.DESCRIPTION
    Two jobs, in this order:

      1. Regenerate data/nbidal18_progression/advancement/. LevelZ fires levelz:level and
         levelz:skill, JobsAddon fires jobsaddon:job_up, and Advancement Plaques renders any
         advancement - so level-up plaques need no code, only advancements on those criteria.
         These are milestones rather than every level: one advancement per level would be about
         1,100 files and would nearly triple the pack's managed file count for a popup.

      2. Mirror the whole datapack to the server and managed-host copies, then verify every file
         by hash. The three copies must be byte-identical; a drift between them is how a server
         ends up enforcing a different skill table than the client was told about.

    The skill table itself (data/levelz/skill/nbidal18.json) is authored content, not generated.
    This script copies it but never rewrites it. See the datapack's README for what it changes
    and why.
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

$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Write-JsonFile([string] $path, $value) {
    $json = $value | ConvertTo-Json -Depth 12
    # ConvertTo-Json escapes non-ASCII and forward slashes inconsistently across PowerShell
    # editions; the datapack contains neither, so a plain write is safe and stays byte-stable.
    [IO.File]::WriteAllText($path, $json + "`n", $utf8NoBom)
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

# Skill key -> icon and the name shown on the plaque.
#
# Eleven, not LevelZ's twelve: Constitution is removed in v4.3.1 and hearts go back to vanilla. Its
# id had to be closed up rather than left as a gap, because LevelZ's SkillLoader walks ids 0..n-1
# and throws on a missing one. Keep this list in step with data/levelz/skill/nbidal18.json.
$skills = [ordered]@{
    melee        = @{ icon = 'minecraft:iron_sword';    name = 'Melee' }
    defense      = @{ icon = 'minecraft:shield';        name = 'Defense' }
    archery      = @{ icon = 'minecraft:bow';           name = 'Archery' }
    agility      = @{ icon = 'minecraft:feather';       name = 'Agility' }
    magic        = @{ icon = 'minecraft:ender_pearl';   name = 'Magic' }
    mining       = @{ icon = 'minecraft:iron_pickaxe';  name = 'Mining' }
    smithing     = @{ icon = 'minecraft:anvil';         name = 'Smithing' }
    farming      = @{ icon = 'minecraft:wheat';         name = 'Farming' }
    cooking      = @{ icon = 'minecraft:cooked_beef';   name = 'Cooking' }
    bartering    = @{ icon = 'minecraft:emerald';       name = 'Bartering' }
    luck         = @{ icon = 'minecraft:rabbit_foot';   name = 'Luck' }
}

# Job key -> icon and display name. Eight jobs; JobsAddon's ninth "restriction" entry is not a job.
$jobs = [ordered]@{
    lumberjack = @{ icon = 'minecraft:iron_axe';        name = 'Lumberjack' }
    miner      = @{ icon = 'minecraft:iron_pickaxe';    name = 'Miner' }
    farmer     = @{ icon = 'minecraft:iron_hoe';        name = 'Farmer' }
    warrior    = @{ icon = 'minecraft:iron_sword';      name = 'Warrior' }
    builder    = @{ icon = 'minecraft:bricks';          name = 'Builder' }
    smith      = @{ icon = 'minecraft:smithing_table';  name = 'Smith' }
    fisher     = @{ icon = 'minecraft:fishing_rod';     name = 'Fisher' }
    brewer     = @{ icon = 'minecraft:brewing_stand';   name = 'Brewer' }
}

$skillMilestones = @(10, 20)
$jobMilestones = @(25, 50, 75, 100)
$levelMilestones = @(25, 50, 75, 100)

$masterDatapack = Join-Path $ReleaseRoot '3. modpack\client\datapacks\nbidal18_progression'
if (-not (Test-Path -LiteralPath $masterDatapack -PathType Container)) {
    throw "The progression datapack master is missing: $masterDatapack"
}
$skillTable = Join-Path $masterDatapack 'data\levelz\skill\nbidal18.json'
if (-not (Test-Path -LiteralPath $skillTable -PathType Leaf)) {
    throw "The skill table is missing: $skillTable. It is authored, not generated."
}

$advancementRoot = Join-Path $masterDatapack 'data\nbidal18_progression\advancement'
if (Test-Path -LiteralPath $advancementRoot) {
    Remove-Item -LiteralPath $advancementRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $advancementRoot -Force | Out-Null

# Its own tab rather than children of minecraft:adventure/root. Sixty milestones dropped into the
# vanilla Adventure tree would bury the vanilla ones; a tab of our own keeps both readable.
Write-JsonFile (Join-Path $advancementRoot 'root.json') ([ordered]@{
    display = [ordered]@{
        icon = [ordered]@{ id = 'minecraft:experience_bottle' }
        title = [ordered]@{ text = 'Progression' }
        description = [ordered]@{ text = 'Skills, jobs and the levels behind them' }
        # A plain resource location, not an {id} object. The icon beside it IS an {id} object,
        # because that one is an item stack - mixing the two forms up loads the root, fails, and
        # takes every child advancement down with it.
        background = 'minecraft:textures/gui/advancements/backgrounds/adventure.png'
        frame = 'task'
        show_toast = $false
        announce_to_chat = $false
        hidden = $false
    }
    criteria = [ordered]@{
        joined = [ordered]@{ trigger = 'minecraft:tick' }
    }
    requirements = @(, @('joined'))
})

$written = 1

function New-Milestone(
        [string] $file, [string] $icon, [string] $title, [string] $description,
        [string] $criterionName, [hashtable] $criterion) {
    Write-JsonFile $file ([ordered]@{
        parent = 'nbidal18_progression:root'
        display = [ordered]@{
            icon = [ordered]@{ id = $icon }
            title = [ordered]@{ text = $title }
            description = [ordered]@{ text = $description }
            frame = 'goal'
            show_toast = $true
            announce_to_chat = $false
            hidden = $false
        }
        criteria = [ordered]@{ $criterionName = $criterion }
        requirements = @(, @($criterionName))
    })
}

foreach ($skill in $skills.Keys) {
    $meta = $skills[$skill]
    foreach ($level in $skillMilestones) {
        New-Milestone `
            (Join-Path $advancementRoot "skill_${skill}_$level.json") `
            $meta.icon `
            "$($meta.name) $level" `
            "$($meta.name) reached level $level" `
            "${skill}_$level" `
            @{ trigger = 'levelz:skill'; conditions = [ordered]@{ skill_name = $skill; skill_level = $level } }
        $written++
    }
}

foreach ($job in $jobs.Keys) {
    $meta = $jobs[$job]
    foreach ($level in $jobMilestones) {
        New-Milestone `
            (Join-Path $advancementRoot "job_${job}_$level.json") `
            $meta.icon `
            "$($meta.name) $level" `
            "$($meta.name) reached job level $level" `
            "${job}_$level" `
            @{ trigger = 'jobsaddon:job_up'; conditions = [ordered]@{ job_name = $job; job_level = $level } }
        $written++
    }
}

foreach ($level in $levelMilestones) {
    New-Milestone `
        (Join-Path $advancementRoot "level_$level.json") `
        'minecraft:experience_bottle' `
        "Level $level" `
        "Reached overall level $level" `
        "level_$level" `
        @{ trigger = 'levelz:level'; conditions = [ordered]@{ level = $level } }
    $written++
}

Write-Host "Generated $written advancement files."

# Mirror to the server payloads. Both must match the client byte for byte: the skill table is
# server-authoritative, so a stale copy silently gives players a different set of numbers than
# the one the release was tested with.
$mirrors = @(
    (Join-Path $ReleaseRoot '3. modpack\server\datapacks\nbidal18_progression'),
    (Join-Path $ReleaseRoot '4. server\2. online-hosting\datapacks\nbidal18_progression')
)
foreach ($mirror in $mirrors) {
    if (Test-Path -LiteralPath $mirror) {
        Remove-Item -LiteralPath $mirror -Recurse -Force
    }
    Copy-Item -LiteralPath $masterDatapack -Destination $mirror -Recurse -Force
}

$masterFiles = @(Get-ChildItem -LiteralPath $masterDatapack -Recurse -File)
foreach ($mirror in $mirrors) {
    $mirrorFiles = @(Get-ChildItem -LiteralPath $mirror -Recurse -File)
    if ($mirrorFiles.Count -ne $masterFiles.Count) {
        throw "The mirrored datapack at $mirror has $($mirrorFiles.Count) files, not $($masterFiles.Count)."
    }
    foreach ($file in $masterFiles) {
        $relative = $file.FullName.Substring($masterDatapack.Length).TrimStart('\')
        $copy = Join-Path $mirror $relative
        if (-not (Test-Path -LiteralPath $copy -PathType Leaf)) {
            throw "The mirrored datapack at $mirror is missing $relative."
        }
        if ((Get-Sha256 $file.FullName) -ne (Get-Sha256 $copy)) {
            throw "The mirrored datapack at $mirror differs from the master at $relative."
        }
    }
}

Write-Host "Progression datapack built and mirrored: $($masterFiles.Count) files in each of three copies." -ForegroundColor Green
