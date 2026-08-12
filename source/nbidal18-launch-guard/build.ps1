param(
    [string] $JavaHome,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)

function Resolve-JdkTool([string] $name) {
    $suffix = if ($env:OS -eq 'Windows_NT') { '.exe' } else { '' }
    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($JavaHome)) {
        $candidates.Add((Join-Path $JavaHome "bin\$name$suffix"))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $candidates.Add((Join-Path $env:JAVA_HOME "bin\$name$suffix"))
    }
    if ($env:APPDATA) {
        $candidates.Add((Join-Path $env:APPDATA "PrismLauncher\java\java-runtime-delta\bin\$name$suffix"))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    $command = Get-Command "$name$suffix" -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command $name -ErrorAction SilentlyContinue }
    if ($null -eq $command) { throw "Java 21 JDK tool not found: $name" }
    return $command.Source
}

$javac = Resolve-JdkTool 'javac'
$jar = Resolve-JdkTool 'jar'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot '..\..\tools\nbidal18-launch-guard.jar'
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

$sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'src') -Recurse -Filter '*.java' -File |
    Sort-Object FullName | ForEach-Object { $_.FullName })
if ($sourceFiles.Count -eq 0) { throw 'No Java source files were found.' }

$buildRoot = Join-Path $projectRoot 'build'
if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
New-Item -ItemType Directory -Path $buildRoot | Out-Null

function Invoke-Checked([string] $file, [string[]] $arguments) {
    & $file @arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code $LASTEXITCODE`: $file" }
}

function Build-Jar([string] $workRoot, [string] $jarPath) {
    $classes = Join-Path $workRoot 'classes'
    $stage = Join-Path $workRoot 'stage'
    New-Item -ItemType Directory -Path $classes, $stage | Out-Null
    Invoke-Checked $javac (@('--release', '21', '-encoding', 'UTF-8', '-d', $classes) + $sourceFiles)
    Get-ChildItem -LiteralPath $classes -Force | Copy-Item -Destination $stage -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination (Join-Path $stage 'LICENSE')
    $manifest = Join-Path $workRoot 'MANIFEST.MF'
    $manifestText = "Manifest-Version: 1.0`r`nMain-Class: dev.nbidal18.launchguard.LaunchGuard`r`nImplementation-Title: nbidal18-launch-guard`r`nImplementation-Version: 1.1.0`r`n`r`n"
    [IO.File]::WriteAllText($manifest, $manifestText, [Text.ASCIIEncoding]::new())
    Invoke-Checked $jar @('--create', '--file', $jarPath, '--date=1980-01-01T00:00:02Z', '--manifest', $manifest, '-C', $stage, '.')
}

try {
    $first = Join-Path $buildRoot 'first.jar'
    $second = Join-Path $buildRoot 'second.jar'
    Build-Jar (Join-Path $buildRoot 'first') $first
    Build-Jar (Join-Path $buildRoot 'second') $second
    $firstHash = (Get-FileHash -LiteralPath $first -Algorithm SHA256).Hash.ToLowerInvariant()
    $secondHash = (Get-FileHash -LiteralPath $second -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($firstHash -ne $secondHash) { throw "Reproducibility check failed: $firstHash != $secondHash" }
    $temporaryOutput = "$OutputPath.tmp-$([guid]::NewGuid().ToString('N'))"
    Copy-Item -LiteralPath $first -Destination $temporaryOutput
    Move-Item -LiteralPath $temporaryOutput -Destination $OutputPath -Force
    Write-Host "Built reproducible JAR: $OutputPath"
    Write-Host "SHA-256: $firstHash"
}
finally {
    if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force }
}
