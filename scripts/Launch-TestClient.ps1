<#
.SYNOPSIS
    Launches a playable client on the built payload, in a throwaway game directory, and leaves it
    running for a human to look at.

.DESCRIPTION
    Test-ClientLaunch.ps1 proves the client starts. It cannot open a screen, join a world, or notice
    that a slot is still there - and that gap is exactly how v4.3.3 shipped a glove-slot removal that
    did nothing. This is the same launch, without the automation: it opens a real window, does not
    kill the process, and keeps the game directory so a world survives between runs.

    Nothing here touches the real Prism instance. The classpath is rebuilt from Prism's own metadata,
    and the payload is copied to a temporary directory. Play in it as roughly as you like.

    Two mods are removed from the copy, exactly as the automated check removes them:

    - The integrity helper, which enforces the published channel and the Prism instance layout.
      Neither exists here and it refuses to start without them. This means the test client CANNOT
      join the live server, which is correct: the server is still on the published release.
    - Crash Assistant, which raises desktop dialogs and is noise on a throwaway.

    The keybind rows the updater normally seeds are written into options.txt on first run, so the
    bindings match what a player actually gets rather than the mods' raw defaults.

.PARAMETER Fresh
    Delete the game directory first. Use this when a test needs a world that has never run, or when
    a previous run left the instance in a state you no longer trust.

.PARAMETER Wait
    Block until the client exits, and report anything Mixin complained about. Without this the
    script returns as soon as the window is up.
#>
param(
    [string] $InstanceName = 'nbidal18-client',
    [switch] $Fresh,
    [switch] $Wait
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PackVersion.ps1')

function Resolve-MavenPath([string] $prismRoot, [string] $coord) {
    $parts = $coord -split ':'
    $groupPath = ($parts[0] -replace '\.', '\')
    $artifact = $parts[1]
    $version = $parts[2]
    $fileName = if ($parts.Count -ge 4) { "$artifact-$version-$($parts[3]).jar" } else { "$artifact-$version.jar" }
    return Join-Path $prismRoot "libraries\$groupPath\$artifact\$version\$fileName"
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseRoot = Get-ReleaseRoot $repoRoot
$packVersion = Get-PackVersion $repoRoot
$clientSource = Join-Path $releaseRoot '3. modpack\client'
$prismRoot = Join-Path $env:APPDATA 'PrismLauncher'
$instanceRoot = Join-Path $prismRoot "instances\$InstanceName"
$javaPath = Join-Path $prismRoot 'java\java-runtime-delta\bin\java.exe'

foreach ($required in @($clientSource, $prismRoot, $instanceRoot, $javaPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Test client input is missing: $required"
    }
}

# Short path on purpose: the deepest datapack function file passes MAX_PATH from a longer root.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) 'nbidal18-test-client'

$classpath = [Collections.Generic.List[string]]::new()
$mainClass = $null
$pack = Get-Content -LiteralPath (Join-Path $instanceRoot 'mmc-pack.json') -Raw | ConvertFrom-Json
foreach ($component in $pack.components) {
    $metaFile = Join-Path $prismRoot "meta\$($component.uid)\$($component.version).json"
    if (-not (Test-Path -LiteralPath $metaFile)) { continue }
    $meta = Get-Content -LiteralPath $metaFile -Raw | ConvertFrom-Json
    if (($meta.PSObject.Properties.Name -contains 'mainClass') -and $meta.mainClass) {
        $mainClass = $meta.mainClass
    }
    $coords = @()
    if (($meta.PSObject.Properties.Name -contains 'mainJar') -and $meta.mainJar) { $coords += $meta.mainJar.name }
    if (($meta.PSObject.Properties.Name -contains 'libraries') -and $meta.libraries) { $coords += $meta.libraries.name }
    foreach ($coord in $coords) {
        if ($coord -match 'natives-(linux|macos)') { continue }
        $path = Resolve-MavenPath $prismRoot $coord
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not $classpath.Contains($path)) {
            $classpath.Add($path)
        }
    }
}
if (-not $mainClass) { throw 'No mainClass was found in the Prism component metadata.' }
if ($classpath.Count -eq 0) { throw 'The classpath resolved to nothing; check the Prism libraries directory.' }

if ($Fresh -and (Test-Path -LiteralPath $testRoot)) {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
if (-not (Test-Path -LiteralPath $testRoot)) {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
}

# The payload is refreshed every launch so a rebuild is always what gets tested, but saves,
# options and screenshots are left alone so a world survives between runs.
foreach ($directory in @('mods', 'config', 'datapacks', 'resourcepacks', 'shaderpacks')) {
    $source = Join-Path $clientSource $directory
    $target = Join-Path $testRoot $directory
    if (-not (Test-Path -LiteralPath $source)) { continue }
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Copy-Item -LiteralPath $source -Destination $target -Recurse -Force
}
# LevelZ, and the two mods that depend on it, are dropped so a world can be created at all.
#
# LevelZ hard-crashes the create-world screen with "Missing skill with id 12" unless the pack's
# skill table is in the loaded datapacks. On the live server it always is, because a server sends
# its datapacks to the client. In singleplayer nothing reads the instance's own datapacks/ folder -
# the pack ships no global datapack loader - so the table never arrives and the screen throws before
# it can draw. That is a real fault in its own right and is recorded in NEXT-VERSION-PLAN.md; it is
# not something this harness can fix.
#
# Dropping them is safe for what this harness is for. Skills and jobs are unrelated to the client
# behaviour a play-test looks at here - aircraft controls, temperature, HUD and screens - and the
# client-tweaks mixins that target LevelZ simply do not apply when the classes are absent.
# jobsaddon depends on levelz and nbidal18-jobs-reset depends on jobsaddon, so Fabric refuses to
# start unless all three go together.
foreach ($pattern in @('nbidal18-integrity-helper-*.jar', 'CrashAssistant-*.jar',
                       'levelz-*.jar', 'jobsaddon-*.jar', 'nbidal18-jobs-reset-*.jar')) {
    foreach ($drop in Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -File -Filter $pattern) {
        Remove-Item -LiteralPath $drop.FullName -Force
    }
}

# The rows the updater seeds on a real instance. Written only when absent, so a binding changed
# inside the test client is not stamped back over on the next launch.
$optionsPath = Join-Path $testRoot 'options.txt'
$seedRows = @(
    'key_key.fieldguide.open:key.keyboard.u',
    'key_key.levelz.openskillscreen:key.keyboard.unknown'
)
if (-not (Test-Path -LiteralPath $optionsPath -PathType Leaf)) {
    [IO.File]::WriteAllText($optionsPath, (($seedRows -join "`n") + "`n"),
        (New-Object Text.UTF8Encoding($false)))
}

$stagedMods = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -File -Filter '*.jar').Count

$arguments = @(
    '-Xms1024m', '-Xmx4096m',
    '-cp', ($classpath -join ';'),
    $mainClass,
    '--username', 'PackTester',
    '--version', '1.21.1',
    '--gameDir', $testRoot,
    '--assetsDir', (Join-Path $prismRoot 'assets'),
    '--assetIndex', '17',
    '--uuid', '00000000000000000000000000000000',
    '--accessToken', '0',
    '--userType', 'legacy',
    '--versionType', 'release'
)

# WorkingDirectory matters as much as --gameDir: several mods write relative to the process working
# directory, and launching from the repo checkout once scattered files through it.
$client = Start-Process -FilePath $javaPath -ArgumentList $arguments -PassThru `
    -WorkingDirectory $testRoot `
    -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') `
    -RedirectStandardError (Join-Path $testRoot 'stderr.txt')

Write-Host ""
Write-Host "Test client launched for v$packVersion - $stagedMods mods, PID $($client.Id)" -ForegroundColor Green
Write-Host "  Game directory : $testRoot"
Write-Host "  Log            : $(Join-Path $testRoot 'logs\latest.log')"
Write-Host ""
Write-Host "  Offline account, so singleplayer only. It cannot join the live server, which is" -ForegroundColor DarkGray
Write-Host "  correct: the server is still on the published release." -ForegroundColor DarkGray
Write-Host ""

if ($Wait) {
    $client.WaitForExit()
    $logPath = Join-Path $testRoot 'logs\latest.log'
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $mixinFailure = '(?m)(org\.spongepowered\.asm\.mixin\..*throwables\.|Mixin apply failed|' +
                        'MixinApplyError|MixinTransformerError|Critical injection failure|' +
                        'Mixin transformation of .* failed)'
        $lines = @(Get-Content -LiteralPath $logPath | Where-Object { $_ -match $mixinFailure })
        if ($lines.Count -ne 0) {
            Write-Warning ("Mixin logged and recovered from these during the session:`n" +
                           (($lines | Select-Object -First 10) -join "`n"))
        }
    }
    Write-Host "Test client exited." -ForegroundColor Green
}
