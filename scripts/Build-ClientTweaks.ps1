param(
    [string] $ReleaseRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '..\nbidal18 v4.1.3-packwiz'))
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
$artifact = Join-Path $sourceRoot 'build\libs\nbidal18-client-tweaks-1.3.2+1.21.1.jar'

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
foreach ($oldArtifact in Get-ChildItem -LiteralPath $clientMods -File -Filter 'nbidal18-client-tweaks-*.jar') {
    $resolvedOld = [IO.Path]::GetFullPath($oldArtifact.FullName)
    if (-not $resolvedOld.StartsWith($clientMods + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Client-tweaks cleanup escaped the client mods directory: $resolvedOld"
    }
    Remove-Item -LiteralPath $resolvedOld -Force
}
$destination = Join-Path $clientMods 'nbidal18-client-tweaks-1.3.2+1.21.1.jar'
Copy-Item -LiteralPath $artifact -Destination $destination

$installed = @(Get-ChildItem -LiteralPath $clientMods -File -Filter 'nbidal18-client-tweaks-*.jar')
if ($installed.Count -ne 1 -or $installed[0].Name -ne 'nbidal18-client-tweaks-1.3.2+1.21.1.jar') {
    throw 'The canonical client does not contain exactly the expected client-tweaks artifact.'
}
Write-Host "Built and installed client tweaks: $destination"
