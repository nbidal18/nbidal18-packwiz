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

$sourceRoot = Join-Path $ReleaseRoot '5. modpack source\custom mods\nbidal18-client-tweaks'
$gradle = Join-Path $sourceRoot 'gradlew.bat'
$clientMods = [IO.Path]::GetFullPath((Join-Path $ReleaseRoot '3. modpack\client\mods'))
# Derive the artifact name from gradle.properties so a version bump cannot desynchronise this script.
$props = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $sourceRoot 'gradle.properties')) {
    if ($line -match '^\s*([A-Za-z0-9_.]+)\s*=\s*(.+?)\s*$') { $props[$Matches[1]] = $Matches[2] }
}
foreach ($key in 'archives_base_name', 'mod_version') {
    if (-not $props.ContainsKey($key)) { throw "gradle.properties is missing '$key' for client-tweaks." }
}
$artifactName = "$($props['archives_base_name'])-$($props['mod_version']).jar"
$artifact = Join-Path $sourceRoot "build\libs\$artifactName"

$previousJavaHome = $env:JAVA_HOME
try {
    $env:JAVA_HOME = $javaHome
    Push-Location $sourceRoot
    try {
        & $gradle clean test remapJar --no-daemon
        if ($LASTEXITCODE -ne 0) {
            throw "The client-tweaks build failed with exit code $LASTEXITCODE"
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
    throw "The client-tweaks artifact is missing: $artifact"
}
# Copy the new artifact in before retiring older ones, so a failure here cannot leave the
# client with no client-tweaks JAR at all.
$destination = Join-Path $clientMods $artifactName
Copy-Item -LiteralPath $artifact -Destination $destination -Force
foreach ($oldArtifact in Get-ChildItem -LiteralPath $clientMods -File -Filter 'nbidal18-client-tweaks-*.jar') {
    $resolvedOld = [IO.Path]::GetFullPath($oldArtifact.FullName)
    if (-not $resolvedOld.StartsWith($clientMods + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Client-tweaks cleanup escaped the client mods directory: $resolvedOld"
    }
    if ($resolvedOld -ne [IO.Path]::GetFullPath($destination)) {
        Remove-Item -LiteralPath $resolvedOld -Force
    }
}

$installed = @(Get-ChildItem -LiteralPath $clientMods -File -Filter 'nbidal18-client-tweaks-*.jar')
if ($installed.Count -ne 1 -or $installed[0].Name -ne $artifactName) {
    throw 'The canonical client does not contain exactly the expected client-tweaks artifact.'
}
Write-Host "Built and installed client tweaks: $destination"
