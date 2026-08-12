param(
    [string] $JavaHome,
    [string] $FixtureRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$updaterRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..\..'))
$guardJar = Join-Path $updaterRoot 'tools\nbidal18-launch-guard.jar'
if ([string]::IsNullOrWhiteSpace($FixtureRoot)) {
    $FixtureRoot = Join-Path $updaterRoot 'site'
}
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)

function Resolve-JdkTool([string] $name) {
    $suffix = if ($env:OS -eq 'Windows_NT') { '.exe' } else { '' }
    foreach ($jdkRoot in @($JavaHome, $env:JAVA_HOME, (Join-Path $env:APPDATA 'PrismLauncher\java\java-runtime-delta'))) {
        if ([string]::IsNullOrWhiteSpace($jdkRoot)) { continue }
        $candidate = Join-Path $jdkRoot "bin\$name$suffix"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command "$name$suffix" -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command $name -ErrorAction SilentlyContinue }
    if ($null -eq $command) { throw "Missing JDK tool: $name" }
    return $command.Source
}

if (-not (Test-Path -LiteralPath $guardJar -PathType Leaf)) { throw "Build the guard first: $guardJar" }
if (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot '.nbidal18\strict-manifest.tsv') -PathType Leaf)) {
    throw "Generated strict-policy fixture is missing: $FixtureRoot"
}
$java = Resolve-JdkTool 'java'
$javac = Resolve-JdkTool 'javac'
$jar = Resolve-JdkTool 'jar'
$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$temporaryPrefix = $temporaryBase + '\nbidal18-launch-guard-smoke-'
$temporary = $temporaryPrefix + [guid]::NewGuid().ToString('N')
if (-not $temporary.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe smoke-test path: $temporary"
}

function Invoke-Checked([string] $file, [string[]] $arguments, [string] $workingDirectory) {
    Push-Location $workingDirectory
    try {
        & $file @arguments
        if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code $LASTEXITCODE`: $file" }
    }
    finally { Pop-Location }
}

try {
    New-Item -ItemType Directory -Path $temporary | Out-Null
    Copy-Item -LiteralPath $guardJar -Destination (Join-Path $temporary 'nbidal18-launch-guard.jar')

    $fakeClasses = Join-Path $temporary '.fake-classes'
    New-Item -ItemType Directory -Path $fakeClasses | Out-Null
    Invoke-Checked $javac @('--release', '21', '-cp', $guardJar, '-d', $fakeClasses,
        (Join-Path $projectRoot 'test\FakeBootstrap.java'),
        (Join-Path $projectRoot 'test\dev\nbidal18\launchguard\ManifestProbe.java'),
        (Join-Path $projectRoot 'test\dev\nbidal18\launchguard\PackUrlProbe.java')) $temporary
    Invoke-Checked $java @('-cp', "$guardJar;$fakeClasses", 'dev.nbidal18.launchguard.ManifestProbe',
        (Join-Path $FixtureRoot '.nbidal18\strict-manifest.tsv')) $temporary
    foreach ($allowedUrl in @(
            'https://packs.example.invalid/nbidal18/pack.toml',
            'http://localhost:8080/smoke/pack.toml',
            'http://127.42.3.4:8080/smoke/pack.toml',
            'http://[::1]:8080/smoke/pack.toml')) {
        Invoke-Checked $java @('-cp', "$guardJar;$fakeClasses", 'dev.nbidal18.launchguard.PackUrlProbe', 'allow', $allowedUrl) $temporary
    }
    foreach ($rejectedUrl in @(
            'http://example.com/pack.toml',
            'http://localhost.example.com/pack.toml',
            'http://127.0.0.1.example.com/pack.toml',
            'http://localhost@example.com/pack.toml',
            'http://example.com@127.0.0.1/pack.toml',
            'http://[::2]/pack.toml',
            'https://user@example.com/pack.toml')) {
        Invoke-Checked $java @('-cp', "$guardJar;$fakeClasses", 'dev.nbidal18.launchguard.PackUrlProbe', 'reject', $rejectedUrl) $temporary
    }
    Invoke-Checked $jar @('--create', '--file', (Join-Path $temporary 'packwiz-installer-bootstrap.jar'),
        '--main-class', 'FakeBootstrap', '-C', $fakeClasses, '.') $temporary
    Remove-Item -LiteralPath $fakeClasses -Recurse -Force

    foreach ($directory in @('mods', 'resourcepacks', 'shaderpacks', 'datapacks', 'config', 'moonlight-global-datapacks',
            'config\spark\tmp', '.nbidal18\defaults\config')) {
        New-Item -ItemType Directory -Path (Join-Path $temporary $directory) -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $temporary 'mods\managed-smoke.jar'), 'managed mod')
    [IO.File]::WriteAllText((Join-Path $temporary '.nbidal18\defaults\options.txt'),
        "resourcePacks:[`"vanilla`"]`nincompatibleResourcePacks:[]`nfov:0.5`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temporary '.nbidal18\defaults\config\iris.properties'),
        "allowUnknownShaders=true`nshaderPack=ComplementaryUnbound_r5.8.1.zip`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temporary '.nbidal18\defaults\config\transition-setting.txt'), 'pack default')
    [IO.File]::WriteAllText((Join-Path $temporary '.nbidal18\defaults\config\first-run.txt'), 'first-run default')
    [IO.File]::WriteAllText((Join-Path $temporary 'config\transition-setting.txt'), 'player customization')
    [IO.File]::WriteAllText((Join-Path $temporary 'config\runtime-state.txt'), 'runtime state')
    $managedModHash = (Get-FileHash -LiteralPath (Join-Path $temporary 'mods\managed-smoke.jar') -Algorithm SHA256).Hash.ToLowerInvariant()
    $optionsHash = (Get-FileHash -LiteralPath (Join-Path $temporary '.nbidal18\defaults\options.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
    $irisHash = (Get-FileHash -LiteralPath (Join-Path $temporary '.nbidal18\defaults\config\iris.properties') -Algorithm SHA256).Hash.ToLowerInvariant()
    $transitionHash = (Get-FileHash -LiteralPath (Join-Path $temporary '.nbidal18\defaults\config\transition-setting.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
    $firstRunHash = (Get-FileHash -LiteralPath (Join-Path $temporary '.nbidal18\defaults\config\first-run.txt') -Algorithm SHA256).Hash.ToLowerInvariant()
    $privateHash = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash(
        [Text.Encoding]::UTF8.GetBytes('approved private bytes')))).Replace('-', '').ToLowerInvariant()
    $manifestText = @(
        "nbidal18-strict-manifest`t1",
        "strict-dir`tmods",
        "strict-dir`tresourcepacks",
        "strict-dir`tshaderpacks",
        "strict-dir`tdatapacks",
        "strict-dir`tconfig",
        "strict-dir`tmoonlight-global-datapacks",
        "managed`t$managedModHash`tmods/managed-smoke.jar",
        "managed`t$optionsHash`t.nbidal18/defaults/options.txt",
        "managed`t$irisHash`t.nbidal18/defaults/config/iris.properties",
        "managed`t$transitionHash`t.nbidal18/defaults/config/transition-setting.txt",
        "managed`t$firstRunHash`t.nbidal18/defaults/config/first-run.txt",
        "optional`t$privateHash`tdatapacks/Still_Life-1.0-beta1.zip",
        "personal`tconfig/controlify.json",
        "runtime`tconfig/runtime-state.txt",
        "runtime-prefix`tconfig/spark/tmp",
        "regenerate-prefix`tshaderpacks/ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3",
        "seed`t.nbidal18/defaults/options.txt`toptions.txt",
        "seed`t.nbidal18/defaults/config/iris.properties`tconfig/iris.properties",
        "seed`t.nbidal18/defaults/config/transition-setting.txt`tconfig/transition-setting.txt",
        "seed`t.nbidal18/defaults/config/first-run.txt`tconfig/first-run.txt"
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $temporary '.nbidal18\strict-manifest.tsv'),
        $manifestText + "`n", [Text.UTF8Encoding]::new($false))

    [IO.File]::WriteAllText((Join-Path $temporary 'mods\unauthorized-smoke.jar'), 'unapproved')
    [IO.File]::WriteAllText((Join-Path $temporary 'moonlight-global-datapacks\unknown-pack.zip'), 'unapproved global datapack')
    [IO.File]::WriteAllText((Join-Path $temporary 'datapacks\Still_Life-1.0-beta1.zip'), 'wrong private hash')
    $regenerated = Join-Path $temporary 'shaderpacks\ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3'
    New-Item -ItemType Directory -Path $regenerated -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $regenerated 'stale.txt'), 'stale generated content')
    $runtimePrefix = Join-Path $temporary 'config\spark\tmp'
    [IO.File]::WriteAllText((Join-Path $runtimePrefix 'preserve.txt'), 'runtime state')
    [IO.File]::WriteAllText((Join-Path $temporary 'config\controlify.json'),
        "{`n  `"global`": { `"reach_around`": `"ON`" }`n}`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temporary 'options.txt'),
        "resourcePacks:[`"unapproved`"]`nincompatibleResourcePacks:[`"unapproved`"]`nfov:0.9`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $temporary 'config\iris.properties'),
        "allowUnknownShaders=true`nshaderPack=UnapprovedShader.zip`ncustomPlayerSetting=keep`n", [Text.UTF8Encoding]::new($false))
    foreach ($cacheRoot in @('.fabric\processedMods', '.fabric\remappedJars\nested', '.fabric\tmp')) {
        New-Item -ItemType Directory -Path (Join-Path $temporary $cacheRoot) -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $temporary "$cacheRoot\purge-canary.txt"), 'generated cache canary')
    }
    New-Item -ItemType Directory -Path (Join-Path $temporary '.fabric\preserved-state') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $temporary '.fabric\preserved-state\keep-canary.txt'), 'preserve me')
    New-Item -ItemType Directory -Path (Join-Path $temporary 'dynamic-resource-pack-cache\nested') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $temporary 'dynamic-resource-pack-cache\nested\purge-canary.txt'), 'generated Moonlight cache')
    New-Item -ItemType Directory -Path (Join-Path $temporary 'dynamic-resource-pack-cache-player') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $temporary 'dynamic-resource-pack-cache-player\keep-canary.txt'), 'unrelated root')

    Invoke-Checked $java @('-jar', 'nbidal18-launch-guard.jar', 'http://localhost/smoke/pack.toml') $temporary

    if ((Get-Content -LiteralPath (Join-Path $temporary 'fake-bootstrap-count.txt') -Raw).Trim() -ne '2') {
        throw 'Guard did not execute exactly two Packwiz passes.'
    }
    if (Test-Path -LiteralPath (Join-Path $temporary 'mods\unauthorized-smoke.jar')) {
        throw 'Unauthorized strict file was not quarantined.'
    }
    $globalDatapackCanary = Join-Path $temporary 'moonlight-global-datapacks\unknown-pack.zip'
    if (Test-Path -LiteralPath $globalDatapackCanary) {
        throw 'Unknown global datapack was not removed from its exact-empty strict root.'
    }
    $globalDatapackBackup = @(Get-ChildItem -LiteralPath (Join-Path $temporary '.nbidal18\quarantine') -Recurse -File |
        Where-Object { $_.FullName.Replace('\', '/').EndsWith('/moonlight-global-datapacks/unknown-pack.zip') })
    if ($globalDatapackBackup.Count -ne 1 -or (Get-Content -LiteralPath $globalDatapackBackup[0].FullName -Raw) -ne 'unapproved global datapack') {
        throw 'Unknown global datapack was not recoverable from quarantine.'
    }
    if (Test-Path -LiteralPath (Join-Path $temporary 'datapacks\Still_Life-1.0-beta1.zip')) {
        throw 'Wrong-hash optional file was not quarantined.'
    }
    if (Test-Path -LiteralPath $regenerated) { throw 'regenerate-prefix was not absent at attestation.' }
    $regenerateQuarantineEntries = @(Get-ChildItem -LiteralPath (Join-Path $temporary '.nbidal18\quarantine') -Recurse -Force |
        Where-Object { $_.FullName.Replace('\', '/').Contains('/shaderpacks/ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3') })
    if ($regenerateQuarantineEntries.Count -ne 0) {
        throw 'Disposable regenerate-prefix content accumulated in quarantine.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $runtimePrefix 'preserve.txt') -PathType Leaf)) {
        throw 'runtime-prefix content was not preserved.'
    }
    if (-not (Select-String -LiteralPath (Join-Path $temporary 'config\controlify.json') -SimpleMatch '"reach_around": "OFF"')) {
        throw 'Controlify reach-around policy was not enforced.'
    }
    if (-not (Select-String -LiteralPath (Join-Path $temporary 'config\iris.properties') -Pattern '^allowUnknownShaders=false$')) {
        throw 'Iris unknown-shader policy was not enforced.'
    }
    if (-not (Select-String -LiteralPath (Join-Path $temporary 'config\iris.properties') -Pattern '^shaderPack=ComplementaryUnbound_r5\.8\.1\.zip$') -or
            -not (Select-String -LiteralPath (Join-Path $temporary 'config\iris.properties') -Pattern '^customPlayerSetting=keep$')) {
        throw 'Iris shader policy reset too much or failed to reset an unapproved shader.'
    }

    $approvedGeneratedShader = 'ComplementaryUnbound_r5.8.1 + EuphoriaPatches_1.9.3'
    [IO.File]::WriteAllText((Join-Path $temporary 'config\iris.properties'),
        "allowUnknownShaders=false`nshaderPack=$approvedGeneratedShader`ncustomPlayerSetting=keep`n", [Text.UTF8Encoding]::new($false))
    Invoke-Checked $java @('-jar', 'nbidal18-launch-guard.jar', 'http://localhost/smoke/pack.toml') $temporary
    if (-not (Select-String -LiteralPath (Join-Path $temporary 'config\iris.properties') -SimpleMatch "shaderPack=$approvedGeneratedShader") -or
            -not (Select-String -LiteralPath (Join-Path $temporary 'config\iris.properties') -Pattern '^allowUnknownShaders=false$') -or
            -not (Select-String -LiteralPath (Join-Path $temporary 'config\iris.properties') -Pattern '^customPlayerSetting=keep$')) {
        throw 'The exact reviewed Euphoria-generated shader selection was not preserved.'
    }
    if (-not (Select-String -LiteralPath (Join-Path $temporary 'options.txt') -SimpleMatch 'resourcePacks:["vanilla"]') -or
            -not (Select-String -LiteralPath (Join-Path $temporary 'options.txt') -Pattern '^fov:0\.9$')) {
        throw 'options.txt mixed policy did not preserve player settings while enforcing managed packs.'
    }
    if ((Get-Content -LiteralPath (Join-Path $temporary 'config\transition-setting.txt') -Raw) -ne 'player customization') {
        throw 'A declared seed target did not survive the simulated manifest transition.'
    }
    if ((Get-Content -LiteralPath (Join-Path $temporary 'config\first-run.txt') -Raw) -ne 'first-run default') {
        throw 'An absent player setting was not seeded from its managed template.'
    }
    foreach ($cacheRoot in @('.fabric\processedMods', '.fabric\remappedJars', '.fabric\tmp')) {
        if (Test-Path -LiteralPath (Join-Path $temporary $cacheRoot)) {
            throw "Generated Fabric cache survived purge: $cacheRoot"
        }
    }
    $preservedFabricCanary = Join-Path $temporary '.fabric\preserved-state\keep-canary.txt'
    if (-not (Test-Path -LiteralPath $preservedFabricCanary -PathType Leaf) -or
            (Get-Content -LiteralPath $preservedFabricCanary -Raw) -ne 'preserve me') {
        throw 'Unrelated .fabric content was changed during generated-cache purge.'
    }
    if (Test-Path -LiteralPath (Join-Path $temporary 'dynamic-resource-pack-cache')) {
        throw 'Moonlight dynamic resource-pack cache survived purge.'
    }
    $unrelatedRootCanary = Join-Path $temporary 'dynamic-resource-pack-cache-player\keep-canary.txt'
    if (-not (Test-Path -LiteralPath $unrelatedRootCanary -PathType Leaf) -or
            (Get-Content -LiteralPath $unrelatedRootCanary -Raw) -ne 'unrelated root') {
        throw 'A similarly named unrelated root was changed during generated-cache purge.'
    }
    $manifestHash = (Get-FileHash -LiteralPath (Join-Path $temporary '.nbidal18\strict-manifest.tsv') -Algorithm SHA256).Hash.ToLowerInvariant()
    $attestation = Get-Content -LiteralPath (Join-Path $temporary '.nbidal18\integrity-attestation.tsv')
    if ($attestation.Count -ne 3 -or
            $attestation[0] -ne "nbidal18-integrity-attestation`t1" -or
            $attestation[1] -ne "manifest-sha256`t$manifestHash" -or
            $attestation[2] -notmatch '^verified-at-utc\t\d{4}-\d{2}-\d{2}T') {
        throw 'Integrity attestation did not match the v1 protocol.'
    }

    $bootstrapCountBeforeMalformed = (Get-Content -LiteralPath (Join-Path $temporary 'fake-bootstrap-count.txt') -Raw).Trim()
    [IO.File]::WriteAllText((Join-Path $temporary '.nbidal18\strict-manifest.tsv'),
        "nbidal18-strict-manifest`t1`nstrict-dir`t../outside`n", [Text.UTF8Encoding]::new($false))
    Push-Location $temporary
    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $negativeOutput = @(& $java -jar 'nbidal18-launch-guard.jar' 'http://localhost/smoke/pack.toml' 2>&1 | ForEach-Object { "$_" })
        $negativeExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
        Pop-Location
    }
    if ($negativeExit -eq 0 -or ($negativeOutput -join "`n") -notmatch 'path traversal is forbidden') {
        throw 'Malformed traversal manifest did not fail closed before Packwiz.'
    }
    if ((Get-Content -LiteralPath (Join-Path $temporary 'fake-bootstrap-count.txt') -Raw).Trim() -ne $bootstrapCountBeforeMalformed) {
        throw 'Packwiz ran despite a malformed pre-existing manifest.'
    }
    Write-Host 'Launch-guard smoke test passed.'
}
finally {
    if (Test-Path -LiteralPath $temporary) {
        $resolved = [IO.Path]::GetFullPath($temporary)
        if (-not $resolved.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean unsafe smoke-test path: $temporary"
        }
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}
