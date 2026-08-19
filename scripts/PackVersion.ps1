<#
.SYNOPSIS
    The single source of truth for which release the tooling is building.

.DESCRIPTION
    Dot-source this from any build or test script:

        . (Join-Path $PSScriptRoot 'PackVersion.ps1')
        $packVersion = Get-PackVersion $repoRoot
        $ReleaseRoot = Get-ReleaseRoot $repoRoot

    The version used to be written out by hand in about twenty-five places across eleven scripts.
    Missing one of them at the 4.1.3 -> 4.2.0 cut published a client whose integrity helper refused
    to parse its own manifest, and locked every player out at login. Now that every publish is its
    own version, that is a trap that would spring regularly, so nothing states the version except
    PACK-VERSION.txt and the build fails when anything disagrees with it.
#>

# Deliberately no Set-StrictMode here: this file is dot-sourced, so it would change the caller's
# scope. Every script that uses it sets its own.

function Get-PackVersion([string] $repoRoot) {
    $path = Join-Path $repoRoot 'PACK-VERSION.txt'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The pack version declaration is missing: $path"
    }
    $version = ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)).Trim()
    # The -packwiz suffix is retired from v4.3.0 on: packwiz is a known part of the pack, so the
    # number alone says everything. Both forms are still accepted because the older release folders
    # carry the suffix and a rollback should not fail here on spelling.
    if ($version -notmatch '^\d+\.\d+\.\d+(-packwiz)?$') {
        throw "PACK-VERSION.txt must hold a three-part version such as 1.2.3, not '$version'"
    }
    return $version
}

<#
    The release folder is named for its version and renamed at each cut. Resolving it from the
    declaration rather than a hardcoded literal means a cut cannot leave a script pointing at the
    previous release, and a rename that was forgotten fails here instead of building the wrong tree.
#>
function Get-ReleaseRoot([string] $repoRoot) {
    $version = Get-PackVersion $repoRoot
    $releaseRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot "..\nbidal18 v$version"))
    if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) {
        $siblings = @(
            Get-ChildItem -LiteralPath (Split-Path -Parent $releaseRoot) -Directory -ErrorAction SilentlyContinue |
                Where-Object Name -like 'nbidal18 v*' | ForEach-Object Name
        )
        throw ("The release folder for $version does not exist: $releaseRoot. " +
               "Rename the working folder to match PACK-VERSION.txt. Found: $($siblings -join ', ')")
    }
    return $releaseRoot
}

<#
    Confirms a caller-supplied -ReleaseRoot is the declared release rather than an older one. A cut
    is the moment stale paths do damage, so an explicit override is checked rather than trusted.
#>
function Assert-ReleaseRootMatchesVersion([string] $repoRoot, [string] $releaseRoot) {
    $version = Get-PackVersion $repoRoot
    $expected = "nbidal18 v$version"
    $actual = Split-Path $releaseRoot -Leaf
    if ($actual -cne $expected) {
        throw "The release folder '$actual' does not match PACK-VERSION.txt ($expected)."
    }
}
