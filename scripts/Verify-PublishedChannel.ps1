<#
.SYNOPSIS
    Waits for GitHub Pages to serve the built manifest, then verifies the published channel.

.DESCRIPTION
    Replaces the verifier that was typed from scratch during the v4.4.0 publish. That one had a
    Windows PowerShell 5.1 bug - Invoke-WebRequest's .Content is a decoded string for text
    responses, not bytes, so hashing it threw on every poll while the loop patiently retried - and
    it added roughly ten minutes to the outage tail before anyone noticed. This one exists ahead of
    time and downloads bytes.

    Downloading the manifest and hashing it is a stronger check than watching a workflow go green:
    it proves what a player's updater will actually receive. And because the manifest lists every
    published file with its hash, a byte-identical manifest is itself the guarantee that the file
    list is right - the per-file checks below are a cheap sanity pass on top, not the real proof.

    The expected digest is read from the local built site rather than passed in, so this cannot be
    pointed at the wrong release by a typo.

.PARAMETER Present
    Extra paths that must return 200, relative to the channel root. URL-encode a '+' as '%2B'.

.PARAMETER Retired
    Paths that must return 404 - files this release removed.

.EXAMPLE
    .\Verify-PublishedChannel.ps1 -Retired 'mods/nbidal18-wiki-1.4.0%2B1.21.1.jar'
#>
param(
    [string] $BaseUrl = 'https://nbidal18.github.io/nbidal18-packwiz',
    [string[]] $Present = @(),
    [string[]] $Retired = @(),
    [int] $TimeoutSeconds = 900,
    [int] $PollSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$localManifest = Join-Path $repoRoot 'site\sync-manifest.json'
if (-not (Test-Path -LiteralPath $localManifest -PathType Leaf)) {
    throw "The built manifest is missing: $localManifest. Run BUILD-UPDATE-SITE.bat first."
}
$expected = (Get-FileHash -LiteralPath $localManifest -Algorithm SHA256).Hash.ToLower()

<#
    Bytes, not Invoke-WebRequest.

    In Windows PowerShell 5.1 the .Content of a text response is a decoded string, and hashing a
    re-encoded string is not hashing what the server sent. The cache-busting query and headers are
    load-bearing too: Pages sits behind a CDN that will happily serve the previous manifest.
#>
function Get-PublishedBytes([string] $path) {
    $stamp = [Guid]::NewGuid().ToString('N')
    $client = New-Object Net.WebClient
    try {
        $client.Headers['Cache-Control'] = 'no-cache'
        $client.Headers['Pragma'] = 'no-cache'
        return $client.DownloadData("$BaseUrl/$path`?cb=$stamp")
    }
    finally { $client.Dispose() }
}

function Get-Sha256Bytes([byte[]] $bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

Write-Host ""
Write-Host "Waiting for the channel to serve $($expected.Substring(0, 16))..." -ForegroundColor Cyan
$started = Get-Date
$deadline = $started.AddSeconds($TimeoutSeconds)
$actual = $null
while ((Get-Date) -lt $deadline) {
    try {
        $actual = Get-Sha256Bytes (Get-PublishedBytes 'sync-manifest.json')
        if ($actual -eq $expected) { break }
        Write-Host "  still serving $($actual.Substring(0, 16))..." -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  not reachable yet: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Start-Sleep -Seconds $PollSeconds
}

if ($actual -ne $expected) {
    throw "The channel is still serving $actual after $TimeoutSeconds seconds; expected $expected."
}
$waited = [int] ((Get-Date) - $started).TotalSeconds
Write-Host "  manifest digest matches after ${waited}s: $expected" -ForegroundColor Green

if ($Present.Count -gt 0) {
    Write-Host "`nMust be present:" -ForegroundColor Cyan
    foreach ($path in $Present) {
        $bytes = Get-PublishedBytes $path
        if ($bytes.Length -le 0) { throw "$path served nothing" }
        Write-Host ("  200  {0,9:N0} bytes  {1}" -f $bytes.Length, $path) -ForegroundColor Green
    }
}

if ($Retired.Count -gt 0) {
    Write-Host "`nMust be gone:" -ForegroundColor Cyan
    foreach ($path in $Retired) {
        $code = 0
        try { $null = Get-PublishedBytes $path }
        catch [Net.WebException] {
            if ($_.Exception.Response) { $code = [int] $_.Exception.Response.StatusCode }
        }
        if ($code -eq 404) { Write-Host "  404  $path" -ForegroundColor Green }
        elseif ($code -eq 0) { throw "$path is still being served; it should be gone." }
        else { throw "$path returned $code, expected 404." }
    }
}

Write-Host "`nPublished channel verified." -ForegroundColor Green
Write-Host "Channel propagation took ${waited}s." -ForegroundColor DarkGray
