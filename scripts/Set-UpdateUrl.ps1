[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $UpdateUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$updaterRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputPath = Join-Path $updaterRoot 'UPDATE-URL.txt'
$uri = $null

if (-not [Uri]::TryCreate($UpdateUrl, [UriKind]::Absolute, [ref] $uri)) {
    throw "Invalid URL: $UpdateUrl"
}
if ($uri.Scheme -ne 'https') { throw 'The player update URL must use HTTPS.' }
if (-not $uri.AbsolutePath.EndsWith('/pack.toml', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The player update URL must end in /pack.toml.'
}
if ($uri.Host -in @('localhost', '127.0.0.1', '::1') -or $UpdateUrl -match 'OWNER|REPOSITORY|YOUR[_-]?|example\.com') {
    throw 'The player update URL must be the real public host, not a placeholder or localhost.'
}

[IO.File]::WriteAllText($outputPath, $UpdateUrl.Trim() + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "Saved update URL: $outputPath"
