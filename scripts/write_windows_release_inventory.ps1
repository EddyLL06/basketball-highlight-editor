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
$inventory = [ordered]@{
    schema = 1
    version = $Version -replace '^v', ''
    files = @($items | Where-Object { !$_.PSIsContainer -and $_.FullName -ne (Join-Path $Root 'bhe-release.json') } |
        ForEach-Object { $_.FullName.Substring($Root.Length + 1).Replace('\', '/') } | Sort-Object)
    directories = @($items | Where-Object { $_.PSIsContainer } |
        ForEach-Object { $_.FullName.Substring($Root.Length + 1).Replace('\', '/') } | Sort-Object)
}
$json = $inventory | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $Root 'bhe-release.json'), $json, (New-Object Text.UTF8Encoding($false)))
