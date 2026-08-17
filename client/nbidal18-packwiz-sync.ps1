Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$PackUrl = if ([string]::IsNullOrWhiteSpace($env:NBIDAL18_PACK_URL)) {
    'https://nbidal18.github.io/nbidal18-packwiz/pack.toml'
} else { $env:NBIDAL18_PACK_URL }
$ManifestUrl = if ([string]::IsNullOrWhiteSpace($env:NBIDAL18_MANIFEST_URL)) {
    'https://nbidal18.github.io/nbidal18-packwiz/sync-manifest.json'
} else { $env:NBIDAL18_MANIFEST_URL }
$MinecraftRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$StateRoot = Join-Path $MinecraftRoot '.nbidal18-packwiz'
$LastManifestPath = Join-Path $StateRoot 'last-successful-manifest.json'
$BootstrapPath = Join-Path $MinecraftRoot 'packwiz-installer-bootstrap.jar'
$UpdaterForm = $null
$UpdaterLabel = $null

function Show-UpdaterWindow {
    if ($env:NBIDAL18_HEADLESS_TEST -eq '1') { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $script:UpdaterForm = [Windows.Forms.Form]::new()
        $script:UpdaterForm.Text = 'nbidal18 updater'
        $script:UpdaterForm.StartPosition = 'CenterScreen'
        $script:UpdaterForm.ClientSize = [Drawing.Size]::new(460, 112)
        $script:UpdaterForm.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
        $script:UpdaterForm.MaximizeBox = $false
        $script:UpdaterForm.MinimizeBox = $true
        $script:UpdaterForm.TopMost = $true

        $script:UpdaterLabel = [Windows.Forms.Label]::new()
        $script:UpdaterLabel.Location = [Drawing.Point]::new(18, 16)
        $script:UpdaterLabel.Size = [Drawing.Size]::new(424, 42)
        $script:UpdaterLabel.Text = 'Preparing the modpack update...'
        $script:UpdaterForm.Controls.Add($script:UpdaterLabel)

        $progress = [Windows.Forms.ProgressBar]::new()
        $progress.Location = [Drawing.Point]::new(18, 66)
        $progress.Size = [Drawing.Size]::new(424, 22)
        $progress.Style = [Windows.Forms.ProgressBarStyle]::Marquee
        $progress.MarqueeAnimationSpeed = 28
        $script:UpdaterForm.Controls.Add($progress)
        $script:UpdaterForm.Show()
        [Windows.Forms.Application]::DoEvents()
    }
    catch {
        $script:UpdaterForm = $null
        $script:UpdaterLabel = $null
    }
}

function Set-UpdaterStatus([string] $message) {
    if ($null -ne $script:UpdaterLabel) {
        $script:UpdaterLabel.Text = $message
        [Windows.Forms.Application]::DoEvents()
    }
}

function Close-UpdaterWindow {
    if ($null -ne $script:UpdaterForm) {
        $script:UpdaterForm.Close()
        $script:UpdaterForm.Dispose()
        $script:UpdaterForm = $null
        $script:UpdaterLabel = $null
    }
}

function Write-PackStatus([string] $message) {
    Write-Host "[nbidal18 packwiz] $message"
    Set-UpdaterStatus $message
}

function Get-RelativePath([string] $fullPath) {
    $root = $MinecraftRoot.TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($fullPath)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes the Minecraft directory: $full"
    }
    return $full.Substring($root.Length).Replace('\', '/')
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

function Read-SyncManifest([string] $path) {
    $manifest = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.packVersion -ne '4.1.2-packwiz') {
        throw "Unsupported sync manifest in $path"
    }
    return $manifest
}

function New-ManifestMap([object] $manifest) {
    $map = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($manifest.files)) {
        $relative = ([string] $file.path).Replace('\', '/').TrimStart('/')
        if ([string]::IsNullOrWhiteSpace($relative) -or
                $relative.Contains(':') -or
                $relative -match '(^|/)\.\.(/|$)' -or
                $map.ContainsKey($relative)) {
            throw "Invalid or duplicate manifest path: $relative"
        }
        $map.Add($relative, $file)
    }
    return $map
}

function Test-LocalAllowed([string] $relativePath, [object] $manifest) {
    foreach ($allowed in @($manifest.localAllowed)) {
        if ($relativePath.Equals([string] $allowed, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Move-OutOfLoadPath([string] $path, [string] $reason) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $relative = Get-RelativePath $path
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destination = Join-Path $StateRoot ("removed-local-files\$stamp\" + $relative.Replace('/', '\'))
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    if (Test-Path -LiteralPath $destination) {
        $destination += '.' + [guid]::NewGuid().ToString('N')
    }
    Move-Item -LiteralPath $path -Destination $destination
    Write-PackStatus "Moved $relative out of the load path ($reason)."
}

function Find-SyncProblems(
        [object] $manifest,
        [switch] $CleanExtras,
        [switch] $PrepareRepair
) {
    $problems = [Collections.Generic.List[string]]::new()
    $map = New-ManifestMap $manifest

    foreach ($entry in $map.GetEnumerator()) {
        $relative = $entry.Key
        if (Test-LocalAllowed $relative $manifest) { continue }
        $target = Join-Path $MinecraftRoot $relative.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $problems.Add("missing:$relative")
            continue
        }
        $actual = Get-Sha256 $target
        $expected = ([string] $entry.Value.sha256).ToLowerInvariant()
        if ($actual -ne $expected) {
            $problems.Add("modified:$relative")
            if ($PrepareRepair) {
                Move-OutOfLoadPath $target 'modified managed file'
            }
        }
    }

    foreach ($rootName in @($manifest.exactRoots)) {
        $rootPath = Join-Path $MinecraftRoot ([string] $rootName).Replace('/', '\')
        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $rootPath -Recurse -File -Force) {
            $relative = Get-RelativePath $file.FullName
            if ($map.ContainsKey($relative) -or (Test-LocalAllowed $relative $manifest)) { continue }
            $problems.Add("extra:$relative")
            if ($CleanExtras) {
                Move-OutOfLoadPath $file.FullName 'not present in the official pack'
            }
        }
    }
    return @($problems)
}

function Invoke-PackwizInstaller {
    if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
        throw "Packwiz bootstrap is missing: $BootstrapPath"
    }
    if ([string]::IsNullOrWhiteSpace($env:INST_JAVA) -or
            -not (Test-Path -LiteralPath $env:INST_JAVA -PathType Leaf)) {
        throw 'Prism did not provide a valid INST_JAVA path.'
    }

    $javaPath = $env:INST_JAVA
    if ([IO.Path]::GetFileName($javaPath).Equals('javaw.exe', [StringComparison]::OrdinalIgnoreCase)) {
        $consoleJava = Join-Path (Split-Path -Parent $javaPath) 'java.exe'
        if (Test-Path -LiteralPath $consoleJava -PathType Leaf) { $javaPath = $consoleJava }
    }

    Write-PackStatus 'Checking GitHub for pack updates...'
    # Use Packwiz's officially supported bootstrap in non-GUI mode. The ZIP also
    # contains a tested installer JAR, so a failed self-update check can fall back.
    $installerArguments = '-jar "' + $BootstrapPath.Replace('"', '\"') + '" -g "' + $PackUrl.Replace('"', '\"') + '"'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $javaPath
    $startInfo.Arguments = $installerArguments
    $startInfo.WorkingDirectory = $MinecraftRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $installerProcess = [Diagnostics.Process]::new()
    $installerProcess.StartInfo = $startInfo
    if (-not $installerProcess.Start()) { throw 'Packwiz could not be started.' }
    if ($null -eq $installerProcess) { throw 'Packwiz could not be started.' }
    try {
        $stdoutTask = $installerProcess.StandardOutput.ReadToEndAsync()
        $stderrTask = $installerProcess.StandardError.ReadToEndAsync()
        while (-not $installerProcess.WaitForExit(100)) {
            if ($null -ne $script:UpdaterForm) {
                [Windows.Forms.Application]::DoEvents()
            }
        }
        $standardOutput = $stdoutTask.GetAwaiter().GetResult()
        $standardError = $stderrTask.GetAwaiter().GetResult()
        if (-not [string]::IsNullOrWhiteSpace($standardOutput)) { Write-Host $standardOutput.TrimEnd() }
        if (-not [string]::IsNullOrWhiteSpace($standardError)) { [Console]::Error.WriteLine($standardError.TrimEnd()) }
        return [int] $installerProcess.ExitCode
    }
    finally {
        $installerProcess.Dispose()
    }
}

function Download-CurrentManifest([string] $destination) {
    Invoke-WebRequest -Uri $ManifestUrl -OutFile $destination -UseBasicParsing -TimeoutSec 30
    [void] (Read-SyncManifest $destination)
}

New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
$downloadedManifest = Join-Path $StateRoot ('manifest-' + [guid]::NewGuid().ToString('N') + '.tmp')
$updateSucceeded = $false
Show-UpdaterWindow

try {
    try {
        $installerResult = Invoke-PackwizInstaller
        if ($installerResult -ne 0) {
            Write-PackStatus 'The first update check failed; retrying once...'
            $installerResult = Invoke-PackwizInstaller
        }
        $updateSucceeded = $installerResult -eq 0
        if ($updateSucceeded) {
            Download-CurrentManifest $downloadedManifest
        }
    }
    catch {
        Write-Warning "The online update check failed: $($_.Exception.Message)"
        $updateSucceeded = $false
    }

    if ($updateSucceeded) {
        $current = Read-SyncManifest $downloadedManifest
        $repairProblems = @(Find-SyncProblems $current -CleanExtras -PrepareRepair)
        if (@($repairProblems | Where-Object { $_ -notlike 'extra:*' }).Count -gt 0) {
            Write-PackStatus 'Repairing missing or modified official files...'
            if ((Invoke-PackwizInstaller) -ne 0) {
                throw 'Packwiz could not repair the official files.'
            }
        }

        $remaining = @(Find-SyncProblems $current -CleanExtras)
        if ($remaining.Count -ne 0) {
            throw "The instance could not be synchronized: $($remaining -join ', ')"
        }

        Move-Item -LiteralPath $downloadedManifest -Destination $LastManifestPath -Force
        Write-PackStatus 'The instance matches v4.1.2-packwiz.'
        exit 0
    }

    if (-not (Test-Path -LiteralPath $LastManifestPath -PathType Leaf)) {
        throw 'GitHub is unavailable and this instance has never completed its first installation.'
    }

    $lastKnown = Read-SyncManifest $LastManifestPath
    $offlineProblems = @(Find-SyncProblems $lastKnown -CleanExtras)
    if ($offlineProblems.Count -ne 0) {
        throw "GitHub is unavailable and the last installed release is incomplete: $($offlineProblems -join ', ')"
    }

    Write-Warning 'GitHub is unavailable. Starting the last complete installed release; the server will apply its current compatibility policy.'
    exit 0
}
catch {
    [Console]::Error.WriteLine("[nbidal18 packwiz] " + $_.Exception.Message)
    exit 1
}
finally {
    if (Test-Path -LiteralPath $downloadedManifest -PathType Leaf) {
        Remove-Item -LiteralPath $downloadedManifest -Force
    }
    Close-UpdaterWindow
}
