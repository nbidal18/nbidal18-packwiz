<#
.SYNOPSIS
    Launches the client payload in a throwaway game directory and checks every mixin applies.

.DESCRIPTION
    This is the check that was missing when v4.2.3 and v4.2.4 both shipped a client that could not
    start. Test-LocalSync proves the updater installs the right files and Test-DedicatedServer proves
    the server boots, but nothing started a client, so a mixin targeting a field that did not exist
    reached players twice.

    Nothing here touches the real Prism instance. The classpath is rebuilt from Prism's own metadata
    rather than scraped from a running process, so the launcher does not need to be open and the
    libraries are exactly the ones players get.

    Two mods are deliberately removed from the throwaway copy:

    - The integrity helper, which enforces the published channel and the Prism instance layout. Neither
      exists here, and it throws before the main menu when they are missing. Reproducing Prism's
      pre-launch staging just to satisfy it would be testing the updater, which Test-LocalSync already
      covers end to end.
    - Crash Assistant, which raises desktop dialogs on exit and is pure noise on the build machine.

.NOTES
    Mixins apply on class load, so reaching the title screen proves every mixin that targets a class
    loaded during startup. Mixins into screens that open later - an atlas, a custom inventory tab -
    only apply when that screen is first opened, and this cannot reach them. Those still need a
    play-test, or a static check of the target with javap.
#>
param(
    [int] $BootTimeoutSeconds = 300,
    [string] $InstanceName = 'nbidal18-client',
    [switch] $KeepGameDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PackVersion.ps1')

# The client keeps latest.log open while it runs, so a plain read fails with a sharing violation.
function Read-SharedText([string] $path) {
    $stream = [IO.FileStream]::new(
        $path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $stream.Dispose() }
}

# group:artifact:version[:classifier] -> the path Prism stores it at.
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
$clientSource = Join-Path $releaseRoot '3. modpack\client'
$prismRoot = Join-Path $env:APPDATA 'PrismLauncher'
$instanceRoot = Join-Path $prismRoot "instances\$InstanceName"
$javaPath = Join-Path $prismRoot 'java\java-runtime-delta\bin\java.exe'

foreach ($required in @($clientSource, $prismRoot, $instanceRoot, $javaPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Client launch check input is missing: $required"
    }
}

# Short path on purpose: the deepest datapack function file passes MAX_PATH from a longer root.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) 'nbidal18-client-launch'

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
        # LWJGL declares natives for every platform. Prism only downloads this one, so whether the
        # file exists is a more reliable platform filter than reinterpreting Prism's rule engine.
        if ($coord -match 'natives-(linux|macos)') { continue }
        $path = Resolve-MavenPath $prismRoot $coord
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not $classpath.Contains($path)) {
            $classpath.Add($path)
        }
    }
}
if (-not $mainClass) { throw 'No mainClass was found in the Prism component metadata.' }
if ($classpath.Count -eq 0) { throw 'The classpath resolved to nothing; check the Prism libraries directory.' }

try {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    foreach ($directory in @('mods', 'config', 'datapacks', 'resourcepacks', 'shaderpacks')) {
        $source = Join-Path $clientSource $directory
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $testRoot $directory) -Recurse -Force
        }
    }
    foreach ($pattern in @('nbidal18-integrity-helper-*.jar', 'CrashAssistant-*.jar')) {
        foreach ($drop in Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -File -Filter $pattern) {
            Remove-Item -LiteralPath $drop.FullName -Force
        }
    }
    $stagedMods = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'mods') -File -Filter '*.jar').Count

    $arguments = @(
        '-Xms512m', '-Xmx2048m',
        '-cp', ($classpath -join ';'),
        $mainClass,
        '--username', 'LaunchCheck',
        '--version', '1.21.1',
        '--gameDir', $testRoot,
        '--assetsDir', (Join-Path $prismRoot 'assets'),
        '--assetIndex', '17',
        '--uuid', '00000000000000000000000000000000',
        '--accessToken', '0',
        '--userType', 'legacy',
        '--versionType', 'release'
    )

    # WorkingDirectory matters as much as --gameDir. Several mods write relative to the process
    # working directory rather than the game directory, and launching from the repo checkout once
    # scattered .mixin.out, config, logs and skin_overrides through it.
    $client = Start-Process -FilePath $javaPath -ArgumentList $arguments -PassThru `
        -WorkingDirectory $testRoot -WindowStyle Minimized `
        -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') `
        -RedirectStandardError (Join-Path $testRoot 'stderr.txt')

    $logPath = Join-Path $testRoot 'logs\latest.log'
    # Mixin spreads its throwables across three packages - mixin.throwables, injection.throwables and
    # transformer.throwables - so the wildcard between them is load-bearing. An earlier draft matched
    # only the first, which missed InvalidMixinException: that is what a @Shadow on a field the target
    # does not declare raises, and it is precisely the v4.2.3 fault. The check would have been unable
    # to catch the bug it was written for. Matching the packages beats listing exception names,
    # which would have to be kept in step with Mixin itself.
    $mixinFailure = '(?m)(org\.spongepowered\.asm\.mixin\..*throwables\.|Mixin apply failed|' +
                    'MixinApplyError|MixinTransformerError|Critical injection failure|' +
                    'Mixin transformation of .* failed)'
    try {
        $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
        $reachedMenu = $false
        while ((Get-Date) -lt $deadline -and -not $client.HasExited) {
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                # Logged once the client is fully initialised, just before the title screen draws.
                if ((Read-SharedText $logPath) -match 'Sound engine started') { $reachedMenu = $true; break }
            }
            # Deliberately no early exit on a mixin line. Mixin logs recoverable throwables during
            # startup, and breaking on the first one aborted the wait before the client had finished
            # booting - which failed a healthy client. A genuinely fatal mixin error kills the
            # process, and $client.HasExited above already ends the loop for that.
            Start-Sleep -Milliseconds 1000
        }

        $log = if (Test-Path -LiteralPath $logPath -PathType Leaf) { Read-SharedText $logPath } else { '' }
        $mixinLines = @($log -split "`r?`n" | Where-Object { $_ -match $mixinFailure })

        # Reaching the title screen is the pass condition, not the absence of scary log lines. Mixin
        # logs some throwables and recovers - a remappable-@Shadow notice on a third-party mixin is
        # one - and failing on those would make the check cry wolf until nobody ran it. They are
        # still surfaced, because a mixin that silently did not apply is a real bug even when the
        # game starts; it just is not this check's job to decide that.
        if (-not $reachedMenu) {
            $crash = @(Get-ChildItem -LiteralPath (Join-Path $testRoot 'crash-reports') -File -ErrorAction SilentlyContinue)
            $detail = if ($mixinLines.Count -ne 0) {
                "`nMixin trouble, most likely the cause:`n" + (($mixinLines | Select-Object -First 10) -join "`n")
            }
            elseif ($crash.Count -ne 0) { "`nCrash report: $($crash[0].FullName)" }
            else { "`nLog: $logPath" }
            throw "The client never reached the title screen within $BootTimeoutSeconds seconds.$detail"
        }

        if ($mixinLines.Count -ne 0) {
            Write-Warning ("The client started, but Mixin logged and recovered from these. Worth a " +
                           "look - a mixin that quietly did not apply still means a broken feature:`n" +
                           (($mixinLines | Select-Object -First 10) -join "`n"))
        }
        Write-Host "Client launch check passed: $stagedMods mods loaded, title screen reached." -ForegroundColor Green
    }
    finally {
        if (-not $client.HasExited) {
            $client.Kill()
            $client.WaitForExit(30000) | Out-Null
        }
        $client.Dispose()
    }
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $KeepGameDir -and
            $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
