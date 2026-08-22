<#
.SYNOPSIS
    Deploys the built release to the live server as a file-level overlay.

.DESCRIPTION
    Replaces the hand-adapted Deploy-431/432/433/434/440/441 scripts. Those were six copies of one
    script with strings swapped, and the copying cost real minutes during the one part of a release
    where the server is down. Worse, the channel verifier was once typed from scratch *during* a
    publish and shipped a bug that added ten minutes to the outage tail. Tooling used during an
    outage should be tooling that already existed.

    Everything version-specific is derived, not typed:

    - the release root and pack version come from PACK-VERSION.txt, via PackVersion.ps1
    - the expected manifest digest is read out of the built server policy, so this script and the
      build cannot disagree about what is being deployed
    - the MOTD is built from the pack version

    **Never a folder sync.** Only files this pack owns server-side are considered, and of those only
    the ones whose hash actually differs are written. World, playerdata, whitelist, ops, ports, logs,
    provider files and the many configs the mods rewrite themselves are outside the candidate list
    entirely.

.PARAMETER DryRun
    Compare and report without writing. Safe while the server is running, and the way to find out
    how long the window needs to be *before* asking anyone to stop anything.

.PARAMETER SkipPing
    Skip the liveness check. Only for a dry run, or when the ping has already been done in this
    sequence and the server has demonstrably not been restarted since.

.NOTES
    The server must be stopped for anything except a policy-only change. Reading logs is not a
    liveness test: the pack runs Server Pause, so an idle server writes nothing for hours, and its
    timestamps are UTC while the local clock is UTC+2. Only a refused connection or a timeout proves
    the server is down, which is what Test-ServerDown below performs.
#>
param(
    [switch] $DryRun,
    [switch] $SkipPing,
    [string] $ServerHost = '64.31.39.186',
    [int] $ServerPort = 27050,
    [string] $LiveRoot = 'Z:'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PackVersion.ps1')

function Get-Sha([string] $path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
}

<#
    A Minecraft Server List Ping. Returns $true only when the connection is refused or times out.

    Deliberately not a log read, and deliberately not cached: the result is re-checked immediately
    before the first write every time, because "it was off a minute ago" has been wrong here before
    and the server's own saves then overwrote the deploy.
#>
function Test-ServerDown([string] $serverHost, [int] $port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($serverHost, $port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(5000)) { return $true }
        $client.EndConnect($connect)
    }
    catch {
        return $true
    }
    finally {
        $client.Close()
    }
    return $false
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$packVersion = Get-PackVersion $repoRoot
$releaseRoot = Get-ReleaseRoot $repoRoot
$src = Join-Path $releaseRoot '4. server\2. online-hosting'
$backup = Join-Path $LiveRoot ".nbidal18-deploy-backups\$(Get-Date -Format 'yyyy-MM-dd')-v$packVersion"
$motd = "v$packVersion - @nbidal18 on Discord"

foreach ($required in @($src, $LiveRoot)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Deploy input is missing: $required" }
}

# The digest is read from what the build produced rather than passed in, so the two cannot drift.
$policySource = Join-Path $src 'config\nbidal18-integrity.properties'
$policyText = [IO.File]::ReadAllText($policySource, [Text.Encoding]::UTF8)
if ($policyText -notmatch '(?m)^expected-manifest-sha256=([0-9a-f]{64})$') {
    throw "Could not read the expected manifest digest from $policySource"
}
$expectedDigest = $Matches[1]

Write-Host ""
Write-Host "nbidal18 live deploy - v$packVersion" -ForegroundColor Cyan
Write-Host "  release  : $releaseRoot"
Write-Host "  digest   : $expectedDigest"
Write-Host "  target   : $LiveRoot"

<#
    Everything this pack owns server-side, derived from the release payload rather than described.

    This used to be a hand-written list: mods\nbidal18-*.jar, licenses\*.txt, seven named configs and
    the nbidal18_ datapacks. It was written when every server-side change this pack made was a
    first-party artefact, and it silently could not see anything else. That cost three releases in a
    row, each differently: v4.4.4 added Voxy, Voxy-Server and Sodium and the dry run reported four
    files while three new mods sat undeployed; v4.4.5 removed those same three and swapped
    DoubleSlabs, and none of it was visible either. Every time, the fix was a human noticing the file
    count looked wrong.

    So the rule is now the obvious one: **the release payload is the list.** Whatever
    3. modpack\server holds is what the live server should hold, for these roots, and a mod's author
    has nothing to do with it. Adding or removing anything from the payload is picked up with no
    change here.

    The roots are deliberately enumerated rather than sweeping the payload whole, because the live
    server also holds things this pack must never touch: world, playerdata, whitelist, ops,
    server.properties beyond its MOTD line, provider files, logs and backups.
#>
$ownedRoots = @('mods', 'config', 'licenses', 'datapacks')

$candidates = @()
foreach ($root in $ownedRoots) {
    $rootPath = Join-Path $src $root
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $rootPath -File -Recurse) {
        $candidates += $file.FullName.Substring($src.Length + 1)
    }
}

Write-Host "`n=== comparing $($candidates.Count) candidate files ===" -ForegroundColor Cyan
$changed = @()
foreach ($relative in $candidates) {
    $from = Join-Path $src $relative
    $to = Join-Path $LiveRoot $relative
    if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { continue }
    if (-not (Test-Path -LiteralPath $to -PathType Leaf)) { $changed += $relative; continue }
    if ((Get-Sha $from) -ne (Get-Sha $to)) { $changed += $relative }
}
Write-Host "  $($changed.Count) differ and will be written; $($candidates.Count - $changed.Count) already match."

<#
    Anything under an owned root that the payload no longer contains. Two versions of one mod is a
    broken server, and a retired datapack still applies its content, so this is not optional.

    It used to sweep only mods\nbidal18-*.jar, which meant a third-party mod could be removed from
    the payload and stay on the server forever - and that is precisely what happened to Voxy,
    Voxy-Server, Sodium and DoubleSlabs 0.3.0, all of which had to be deleted by hand.

    **config is deliberately excluded.** Mods write their own files there during startup, exactly as
    they do on a client, so sweeping it would delete files the server recreates seconds later. That
    is the same reasoning that makes config a tolerant root in the client's integrity policy.
#>
$sweptRoots = @('mods', 'datapacks', 'licenses')
$wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($relative in $candidates) { [void] $wanted.Add($relative) }

$stale = @()
foreach ($root in $sweptRoots) {
    $rootPath = Join-Path $LiveRoot $root
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $rootPath -File -Recurse) {
        $relative = $file.FullName.Substring($LiveRoot.Length).TrimStart('\')
        if (-not $wanted.Contains($relative)) { $stale += $relative }
    }
}

$propsPath = Join-Path $LiveRoot 'server.properties'
$propsText = [IO.File]::ReadAllText($propsPath, [Text.Encoding]::UTF8)
if (([regex]::Matches($propsText, '(?m)^motd=.*$')).Count -ne 1) { throw 'Expected exactly one motd line.' }
$oldMotd = [regex]::Match($propsText, '(?m)^motd=(.*)$').Groups[1].Value.TrimEnd("`r")
$motdNeedsWrite = $oldMotd -ne $motd

foreach ($relative in $changed) { Write-Host "    write   $relative" }
foreach ($name in $stale) { Write-Host "    remove  $name" -ForegroundColor Yellow }
if ($motdNeedsWrite) { Write-Host "    motd    '$oldMotd' -> '$motd'" }

# Only the policy is hot-reloadable; the helper re-reads it per login. Anything else is a JAR or a
# datapack the server read at startup, so it needs the server stopped.
$policyOnly = ($stale.Count -eq 0) -and (-not $motdNeedsWrite) -and
    (@($changed | Where-Object { $_ -ne 'config\nbidal18-integrity.properties' }).Count -eq 0)
$nothingToDo = ($changed.Count -eq 0) -and ($stale.Count -eq 0) -and (-not $motdNeedsWrite)
if ($nothingToDo) {
    Write-Host "`n  nothing to do - the live server already matches this release." -ForegroundColor Green
}
else {
    Write-Host ("`n  server must be stopped: {0}" -f $(if ($policyOnly) { 'no - policy only, the helper re-reads it per login' } else { 'YES' })) -ForegroundColor $(if ($policyOnly) { 'Green' } else { 'Yellow' })
}

if ($DryRun) {
    Write-Host "`nDry run - nothing was written." -ForegroundColor Yellow
    return
}

if ($nothingToDo) { return }

if (-not $SkipPing -and -not $policyOnly) {
    Write-Host "`n=== confirming the server is down ===" -ForegroundColor Cyan
    if (-not (Test-ServerDown $ServerHost $ServerPort)) {
        throw ("$ServerHost`:$ServerPort answered a status ping, so the server is RUNNING. Stop it " +
               'from the provider panel and run this again. Writing now would be overwritten by ' +
               "the server's own saves.")
    }
    Write-Host "  connection refused - the server is down." -ForegroundColor Green
}

New-Item -ItemType Directory -Force -Path $backup | Out-Null

Write-Host "`n=== writing ===" -ForegroundColor Cyan
foreach ($relative in $changed) {
    $from = Join-Path $src $relative
    $to = Join-Path $LiveRoot $relative

    if (Test-Path -LiteralPath $to -PathType Leaf) {
        $target = Join-Path $backup $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        # Byte read and write rather than Copy-Item: this mount has served a cached copy of what
        # this tooling wrote in an earlier deploy instead of the file as it currently stands.
        [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($to))
        Start-Sleep -Milliseconds 200
        if ((Get-Sha $to) -ne (Get-Sha $target)) {
            throw "Backup of $relative did not verify. Re-read it before trusting anything here."
        }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    Copy-Item -LiteralPath $from -Destination $to -Force
    Start-Sleep -Milliseconds 200
    $hash = Get-Sha $from
    if ($hash -ne (Get-Sha $to)) { throw "Hash mismatch after copying $relative" }
    Write-Host ("  {0}  {1}" -f $hash.Substring(0, 12), $relative)
}

foreach ($name in $stale) {
    $path = Join-Path $LiveRoot $name
    $target = Join-Path $backup $name
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    # Back up BEFORE deleting, and verify the backup, because a delete cannot be undone. Doing this
    # by hand on 2026-08-22 removed five files whose backup step had been skipped by an earlier
    # failure - recoverable from elsewhere, but not backed up, which is not the same thing.
    [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($path))
    Start-Sleep -Milliseconds 200
    if ((Get-Sha $path) -ne (Get-Sha $target)) {
        throw "Backup of $name did not verify; refusing to remove it."
    }
    # Remove-Item fails on this mount with "Incorrect function".
    [IO.File]::Delete($path)
    Start-Sleep -Milliseconds 200
    if (Test-Path -LiteralPath $path -PathType Leaf) { throw "Could not remove superseded $name" }
    Write-Host "  removed  $name"
}

<#
    Sweeping files leaves the directories that held them. An empty datapack subdirectory contributes
    nothing, but it makes the live tree stop matching the payload and it makes the next person wonder
    whether something was missed. Deepest-first so a nested chain collapses in one pass.
#>
foreach ($root in $sweptRoots) {
    $rootPath = Join-Path $LiveRoot $root
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) { continue }
    $dirs = @(Get-ChildItem -LiteralPath $rootPath -Directory -Recurse |
            Sort-Object { $_.FullName.Length } -Descending)
    foreach ($dir in $dirs) {
        if (@(Get-ChildItem -LiteralPath $dir.FullName -Recurse -File).Count -ne 0) { continue }
        try {
            [IO.Directory]::Delete($dir.FullName)
            Write-Host ("  pruned   {0}" -f $dir.FullName.Substring($LiveRoot.Length).TrimStart('\'))
        }
        catch {
            # Not worth failing a deploy over: an empty directory changes nothing the game reads.
            Write-Host ("  could not prune {0}" -f $dir.FullName) -ForegroundColor DarkYellow
        }
    }
}

if ($motdNeedsWrite) {
    $target = Join-Path $backup 'server.properties'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($propsPath))
    $updated = [regex]::Replace($propsText, '(?m)^motd=.*$', "motd=$motd")
    # Explicitly truncating: shell redirection does not truncate on this mount and would leave the
    # old tail dangling past the new content.
    [IO.File]::WriteAllText($propsPath, $updated, (New-Object Text.UTF8Encoding($false)))
    Start-Sleep -Milliseconds 300
    if ([IO.File]::ReadAllText($propsPath, [Text.Encoding]::UTF8) -ne $updated) {
        throw 'server.properties did not read back as written.'
    }
    Write-Host "  motd: '$oldMotd' -> '$motd'"
}

Write-Host "`n=== verifying the live policy ===" -ForegroundColor Cyan
# Byte read, not Get-Item.Length: this mount serves stale file metadata, and a wrong size here once
# looked exactly like the dangling-tail corruption the truncating write above exists to prevent.
$liveBytes = [IO.File]::ReadAllBytes((Join-Path $LiveRoot 'config\nbidal18-integrity.properties'))
$livePolicy = [Text.Encoding]::UTF8.GetString($liveBytes)
if ($livePolicy -notmatch [regex]::Escape("expected-manifest-sha256=$expectedDigest")) {
    throw 'The live policy does not expect this release digest.'
}
if ($livePolicy -match '(?m)^accepted-manifest-sha256=\S') {
    throw 'An accepted-digest list is present; only the current release may join.'
}
Write-Host "  expects $($expectedDigest.Substring(0, 16))..., no accepted list ($($liveBytes.Length) bytes)" -ForegroundColor Green

Write-Host "`nOverlay complete. Backups under $backup" -ForegroundColor Green
if (-not $policyOnly) {
    Write-Host "RESTART THE SERVER NOW." -ForegroundColor Cyan
}
