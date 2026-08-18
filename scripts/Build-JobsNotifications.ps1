param(
    [string] $ReleaseRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

$sourceRoot = Join-Path $ReleaseRoot '5. modpack source\custom mods\nbidal18-jobs-chat-suppressor'
$gradle = Join-Path $ReleaseRoot '5. modpack source\custom mods\nbidal18-client-tweaks\gradlew.bat'
$artifact = Join-Path $sourceRoot 'build\libs\nbidal18-jobs-chat-suppressor-1.0.0+1.21.1.jar'
$previousJavaHome = $env:JAVA_HOME
try {
    $env:JAVA_HOME = $javaHome
    & $gradle -p $sourceRoot clean remapJar --no-daemon
    if ($LASTEXITCODE -ne 0) {
        throw "The Jobs+ compatibility helper build failed with exit code $LASTEXITCODE"
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
    throw "The Jobs+ compatibility helper artifact is missing: $artifact"
}

$destinations = @(
    (Join-Path $ReleaseRoot '3. modpack\client\mods\nbidal18-jobs-chat-suppressor-1.0.0+1.21.1.jar'),
    (Join-Path $ReleaseRoot '3. modpack\server\mods\nbidal18-jobs-chat-suppressor-1.0.0+1.21.1.jar'),
    (Join-Path $ReleaseRoot '4. server\2. online-hosting\mods\nbidal18-jobs-chat-suppressor-1.0.0+1.21.1.jar')
)
foreach ($destination in $destinations) {
    Copy-Item -LiteralPath $artifact -Destination $destination -Force
}
foreach ($retired in @(
    (Join-Path $ReleaseRoot '3. modpack\client\mods\nbidal18-jobs-chat-suppressor-1.1.0+1.21.1.jar'),
    (Join-Path $ReleaseRoot '3. modpack\server\mods\nbidal18-jobs-chat-suppressor-1.1.0+1.21.1.jar'),
    (Join-Path $ReleaseRoot '4. server\2. online-hosting\mods\nbidal18-jobs-chat-suppressor-1.1.0+1.21.1.jar')
)) {
    if (Test-Path -LiteralPath $retired -PathType Leaf) {
        Remove-Item -LiteralPath $retired -Force
    }
}
$hashes = @($destinations | ForEach-Object { Get-Sha256 $_ })
if (@($hashes | Select-Object -Unique).Count -ne 1) {
    throw 'The Jobs+ compatibility helper copies are not byte-identical.'
}
Write-Host "Built and copied Jobs+ compatibility helper: $($hashes[0])"
