# Inventory app-owned files so the updater can refuse mixed app/project folders.
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Version
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
$items = @(Get-ChildItem -LiteralPath $Root -Recurse -Force)
foreach ($item in $items) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Release contains a linked file or directory: $($item.FullName)"
    }
}
# Preserve the base version expected by already-installed Windows helpers.
# The archive hash identifies the exact release; keep its tag separately for publishing.
$releaseVersion = $Version -replace '^v', ''
$inventoryVersion = $releaseVersion -replace '-windows\.[1-9][0-9]*$', ''
$inventory = [ordered]@{
    schema = 1
    version = $inventoryVersion
    release_version = $releaseVersion
    files = @($items | Where-Object { !$_.PSIsContainer -and $_.FullName -ne (Join-Path $Root 'bhe-release.json') } |
        ForEach-Object { $_.FullName.Substring($Root.Length + 1).Replace('\', '/') } | Sort-Object)
    directories = @($items | Where-Object { $_.PSIsContainer } |
        ForEach-Object { $_.FullName.Substring($Root.Length + 1).Replace('\', '/') } | Sort-Object)
}
$json = $inventory | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $Root 'bhe-release.json'), $json, (New-Object Text.UTF8Encoding($false)))
