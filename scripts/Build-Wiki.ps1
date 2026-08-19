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
}

$javaHome = $env:JAVA_HOME
if ([string]::IsNullOrWhiteSpace($javaHome)) {
    $prismJava = 'C:\Users\nizar\AppData\Roaming\PrismLauncher\java\java-runtime-delta'
    if (Test-Path -LiteralPath (Join-Path $prismJava 'bin\javac.exe') -PathType Leaf) {
        $javaHome = $prismJava
    }
}
if ([string]::IsNullOrWhiteSpace($javaHome)) {
    throw 'Java 21 JDK was not found. Set JAVA_HOME before building.'
}

$sourceRoot = Join-Path $ReleaseRoot '5. modpack source\custom mods\nbidal18-wiki'
$gradle = Join-Path $sourceRoot 'gradlew.bat'

# Derive the artifact name from gradle.properties so a version bump cannot desynchronise this script.
$props = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $sourceRoot 'gradle.properties')) {
    if ($line -match '^\s*([A-Za-z0-9_.]+)\s*=\s*(.+?)\s*$') { $props[$Matches[1]] = $Matches[2] }
}
foreach ($key in 'archives_base_name', 'mod_version') {
    if (-not $props.ContainsKey($key)) { throw "gradle.properties is missing '$key' for the wiki mod." }
}
$baseName = $props['archives_base_name']
$artifactName = "$baseName-$($props['mod_version']).jar"
$artifact = Join-Path $sourceRoot "build\libs\$artifactName"

# Client only. The wiki is a screen and a pile of text; a server has no use for either, and putting
# it in the server payload would make the two mod lists disagree for nothing.
$destinations = @(
    [IO.Path]::GetFullPath((Join-Path $ReleaseRoot '3. modpack\client\mods'))
)

$previousJavaHome = $env:JAVA_HOME
try {
    $env:JAVA_HOME = $javaHome
    Push-Location $sourceRoot
    try {
        & $gradle clean test remapJar --no-daemon
        if ($LASTEXITCODE -ne 0) {
            throw "The wiki mod build failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($null -eq $previousJavaHome) {
        Remove-Item Env:JAVA_HOME -ErrorAction SilentlyContinue
    }
    else {
        $env:JAVA_HOME = $previousJavaHome
    }
}

if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
    throw "The wiki mod artifact is missing: $artifact"
}

foreach ($destination in $destinations) {
    # Copy first, then remove superseded versions, so a failure never leaves the pack without the mod.
    Copy-Item -LiteralPath $artifact -Destination (Join-Path $destination $artifactName) -Force

    foreach ($stale in Get-ChildItem -LiteralPath $destination -File -Filter "$baseName-*.jar") {
        if ($stale.Name -eq $artifactName) { continue }
        $resolvedStale = [IO.Path]::GetFullPath($stale.FullName)
        if (-not $resolvedStale.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "wiki mod cleanup escaped the mods directory: $resolvedStale"
        }
        Remove-Item -LiteralPath $resolvedStale -Force
    }

    $installed = @(Get-ChildItem -LiteralPath $destination -File -Filter "$baseName-*.jar")
    if ($installed.Count -ne 1 -or $installed[0].Name -ne $artifactName) {
        throw "The canonical pack does not contain exactly the expected wiki mod artifact in $destination."
    }
    Write-Host "Built and installed wiki mod: $(Join-Path $destination $artifactName)"
}
