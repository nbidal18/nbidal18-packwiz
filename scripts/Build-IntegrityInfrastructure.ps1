param(
    [string] $ReleaseRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($ReleaseRoot)) {
    $ReleaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '..\nbidal18 v4.2.0-packwiz'))
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

$javac = Join-Path $javaHome 'bin\javac.exe'
$jarTool = Join-Path $javaHome 'bin\jar.exe'
foreach ($tool in @($javac, $jarTool)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "The Java 21 JDK tool is missing: $tool"
    }
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

$supervisorSource = Join-Path $repoRoot 'client\Nbidal18PackwizSupervisor.java'
$updaterSource = Join-Path $repoRoot 'client\Nbidal18PackwizSync.java'
$updaterBuild = Join-Path $repoRoot 'client\java-build'
$supervisorJar = Join-Path $repoRoot 'client\nbidal18-packwiz-sync.jar'
$updaterJar = Join-Path $repoRoot 'client\nbidal18-packwiz-updater.jar'
if (Test-Path -LiteralPath $updaterBuild) {
    Remove-Item -LiteralPath $updaterBuild -Recurse -Force
}
New-Item -ItemType Directory -Path $updaterBuild | Out-Null
& $javac --release 21 -encoding UTF-8 -d $updaterBuild $supervisorSource $updaterSource
if ($LASTEXITCODE -ne 0) {
    throw "The Packwiz updater compilation failed with exit code $LASTEXITCODE"
}
foreach ($jar in @($supervisorJar, $updaterJar)) {
    if (Test-Path -LiteralPath $jar) {
        Remove-Item -LiteralPath $jar -Force
    }
}
& $jarTool --create --file $supervisorJar --main-class Nbidal18PackwizSupervisor `
    --date=1980-01-01T00:00:02Z -C $updaterBuild 'Nbidal18PackwizSupervisor.class' `
    -C $updaterBuild 'Nbidal18PackwizSupervisor$Promotion.class'
if ($LASTEXITCODE -ne 0) {
    throw "The Packwiz supervisor JAR build failed with exit code $LASTEXITCODE"
}
& $jarTool --create --file $updaterJar --main-class Nbidal18PackwizSync `
    --date=1980-01-01T00:00:02Z -C $updaterBuild 'Nbidal18PackwizSync.class' `
    -C $updaterBuild 'Nbidal18PackwizSync$FileEntry.class' `
    -C $updaterBuild 'Nbidal18PackwizSync$PropertyRule.class' `
    -C $updaterBuild 'Nbidal18PackwizSync$SyncManifest.class'
if ($LASTEXITCODE -ne 0) {
    throw "The Packwiz update-engine JAR build failed with exit code $LASTEXITCODE"
}

$helperRoot = Join-Path $ReleaseRoot '5. modpack source\custom mods\nbidal18-integrity-helper'
$gradle = Join-Path $helperRoot 'gradlew.bat'

# The client refuses to parse a manifest whose packVersion differs from the helper's compiled
# PACK_VERSION, so a version bump that misses this constant locks every player out at login with
# "Modpack integrity change detected". That happened on the 4.1.3 -> 4.2.0 cut; assert it here.
$constantsPath = Join-Path $helperRoot 'src\main\java\dev\nbidal18\integrity\IntegrityConstants.java'
$constantsText = [IO.File]::ReadAllText($constantsPath)
if ($constantsText -notmatch '(?m)^\s*static final String PACK_VERSION = "([^"]+)";') {
    throw "Could not read PACK_VERSION from $constantsPath"
}
$helperPackVersion = $Matches[1]
# Derived from the release folder so it follows a version cut automatically.
if ((Split-Path $ReleaseRoot -Leaf) -notmatch '^nbidal18 v(.+)$') {
    throw "Could not derive the pack version from the release folder name: $ReleaseRoot"
}
$sitePackVersion = $Matches[1]
if ($helperPackVersion -ne $sitePackVersion) {
    throw ("The integrity helper is compiled for pack version '$helperPackVersion' but this release " +
           "publishes '$sitePackVersion'. Update PACK_VERSION in IntegrityConstants.java; leaving it " +
           'behind rejects every client at login.')
}
$previousJavaHome = $env:JAVA_HOME
try {
    $env:JAVA_HOME = $javaHome
    Push-Location $helperRoot
    try {
        & $gradle clean test remapJar --no-daemon
        if ($LASTEXITCODE -ne 0) {
            throw "The integrity helper build failed with exit code $LASTEXITCODE"
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

$helperJar = Join-Path $helperRoot 'build\libs\nbidal18-integrity-helper-1.0.0+1.21.1.jar'
if (-not (Test-Path -LiteralPath $helperJar -PathType Leaf)) {
    throw "The integrity helper artifact is missing: $helperJar"
}
$destinations = @(
    (Join-Path $ReleaseRoot '3. modpack\client\mods\nbidal18-integrity-helper-1.0.0+1.21.1.jar'),
    (Join-Path $ReleaseRoot '3. modpack\server\mods\nbidal18-integrity-helper-1.0.0+1.21.1.jar'),
    (Join-Path $ReleaseRoot '4. server\2. online-hosting\mods\nbidal18-integrity-helper-1.0.0+1.21.1.jar'),
    (Join-Path $ReleaseRoot '4. server\4.2.0-transition-overlay\mods\nbidal18-integrity-helper-1.0.0+1.21.1.jar')
)
foreach ($destination in $destinations) {
    Copy-Item -LiteralPath $helperJar -Destination $destination -Force
}
$hashes = @($destinations | ForEach-Object {
    Get-Sha256 $_
} | Select-Object -Unique)
if ($hashes.Count -ne 1) {
    throw 'The client and server integrity-helper copies are not byte-identical.'
}

Write-Host "Built stable Packwiz supervisor: $supervisorJar"
Write-Host "Built Packwiz update engine: $updaterJar"
Write-Host "Built and copied integrity helper: $($hashes[0])"
