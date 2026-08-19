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

$sourceRoot = Join-Path $ReleaseRoot '5. modpack source\custom mods\nbidal18-temperature'
$gradle = Join-Path $sourceRoot 'gradlew.bat'

# Derive the artifact name from gradle.properties so a version bump cannot desynchronise this script.
$props = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $sourceRoot 'gradle.properties')) {
    if ($line -match '^\s*([A-Za-z0-9_.]+)\s*=\s*(.+?)\s*$') { $props[$Matches[1]] = $Matches[2] }
}
foreach ($key in 'archives_base_name', 'mod_version') {
    if (-not $props.ContainsKey($key)) { throw "gradle.properties is missing '$key' for the temperature mod." }
}
$baseName = $props['archives_base_name']
$artifactName = "$baseName-$($props['mod_version']).jar"
$artifact = Join-Path $sourceRoot "build\libs\$artifactName"

# Installed on both sides. Temperature is resolved server-side, so the server copies are the ones
# that actually matter, but a single-player world runs its own integrated server too.
$destinations = @(
    [IO.Path]::GetFullPath((Join-Path $ReleaseRoot '3. modpack\client\mods'))
    [IO.Path]::GetFullPath((Join-Path $ReleaseRoot '3. modpack\server\mods'))
    [IO.Path]::GetFullPath((Join-Path $ReleaseRoot '4. server\2. online-hosting\mods'))
)

$previousJavaHome = $env:JAVA_HOME
try {
    $env:JAVA_HOME = $javaHome
    Push-Location $sourceRoot
    try {
        & $gradle clean test remapJar --no-daemon
        if ($LASTEXITCODE -ne 0) {
            throw "The temperature mod build failed with exit code $LASTEXITCODE"
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
    throw "The temperature mod artifact is missing: $artifact"
}

foreach ($destination in $destinations) {
    # Copy first, then remove superseded versions, so a failure never leaves the pack without the mod.
    Copy-Item -LiteralPath $artifact -Destination (Join-Path $destination $artifactName) -Force

    foreach ($stale in Get-ChildItem -LiteralPath $destination -File -Filter "$baseName-*.jar") {
        if ($stale.Name -eq $artifactName) { continue }
        $resolvedStale = [IO.Path]::GetFullPath($stale.FullName)
        if (-not $resolvedStale.StartsWith($destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "temperature mod cleanup escaped the mods directory: $resolvedStale"
        }
        Remove-Item -LiteralPath $resolvedStale -Force
    }

    $installed = @(Get-ChildItem -LiteralPath $destination -File -Filter "$baseName-*.jar")
    if ($installed.Count -ne 1 -or $installed[0].Name -ne $artifactName) {
        throw "The canonical pack does not contain exactly the expected temperature mod artifact in $destination."
    }
    Write-Host "Built and installed temperature mod: $(Join-Path $destination $artifactName)"
}

# The mod carries the insulation values; the datapack carries the sun-hat and food tags and the one
# line that switches Scorchful's tag path off. They are one design, so they are mirrored together:
# a server running the mod without the datapack would have insulation applied twice.
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

$datapackMaster = Join-Path $ReleaseRoot '3. modpack\client\datapacks\nbidal18_temperature'
if (-not (Test-Path -LiteralPath $datapackMaster -PathType Container)) {
    throw "The temperature datapack master is missing: $datapackMaster"
}
$datapackMirrors = @(
    (Join-Path $ReleaseRoot '3. modpack\server\datapacks\nbidal18_temperature'),
    (Join-Path $ReleaseRoot '4. server\2. online-hosting\datapacks\nbidal18_temperature')
)
foreach ($mirror in $datapackMirrors) {
    if (Test-Path -LiteralPath $mirror) { Remove-Item -LiteralPath $mirror -Recurse -Force }
    Copy-Item -LiteralPath $datapackMaster -Destination $mirror -Recurse -Force
}
$datapackFiles = @(Get-ChildItem -LiteralPath $datapackMaster -Recurse -File)
foreach ($mirror in $datapackMirrors) {
    foreach ($file in $datapackFiles) {
        $relative = $file.FullName.Substring($datapackMaster.Length).TrimStart('\')
        $copy = Join-Path $mirror $relative
        if (-not (Test-Path -LiteralPath $copy -PathType Leaf)) {
            throw "The mirrored temperature datapack at $mirror is missing $relative."
        }
        if ((Get-Sha256 $file.FullName) -ne (Get-Sha256 $copy)) {
            throw "The mirrored temperature datapack at $mirror differs from the master at $relative."
        }
    }
}
Write-Host "Temperature datapack mirrored: $($datapackFiles.Count) files in each of three copies." -ForegroundColor Green
