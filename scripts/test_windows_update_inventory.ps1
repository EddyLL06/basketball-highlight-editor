# Exercise the real inventory writer/reader at packaged-Python scale.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Repo = Split-Path -Parent $PSScriptRoot
$Helper = Join-Path $Repo 'apps/desktop/assets/windows_update.ps1'
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('bhe-inventory-test-' + [Guid]::NewGuid().ToString('N'))
$Root = Join-Path $Temp 'BHE'
$Utf8 = New-Object Text.UTF8Encoding($false)
[void][IO.Directory]::CreateDirectory($Root)
try {
    $generation = [Diagnostics.Stopwatch]::StartNew()
    foreach ($name in @('BHE.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'runtime/python/python.exe')) {
        $path = Join-Path $Root $name
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, '', $Utf8)
    }
    for ($directory = 0; $directory -lt 5000; $directory++) {
        $relative = 'runtime/python/Lib/site-packages/torch/include/generated_headers/department_{0:d4}' -f $directory
        $path = Join-Path $Root $relative
        [void][IO.Directory]::CreateDirectory($path)
        for ($file = 0; $file -lt 8; $file++) {
            $name = 'operator_{0:d5}_schema.generated.pyi' -f ($directory * 8 + $file)
            [IO.File]::WriteAllText((Join-Path $path $name), '', $Utf8)
        }
    }
    & "$PSScriptRoot/write_windows_release_inventory.ps1" -Root $Root -Version '2.0.0'
    $generation.Stop()
    $inventoryPath = Join-Path $Root 'bhe-release.json'
    $json = Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8
    if ($json.Length -lt 4MB) { throw 'Fixture must exceed four million JSON characters.' }
    $parse = [Diagnostics.Stopwatch]::StartNew()
    $inventory = $json | ConvertFrom-Json
    $parse.Stop()
    if ($inventory.files.Count -ne 40005) { throw 'Large inventory lost file entries.' }

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Helper, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Helper has syntax errors.' }
    foreach ($definition in $ast.EndBlock.Statements) {
        if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }
    $times = @()
    for ($pass = 1; $pass -le 3; $pass++) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        Assert-ReleaseTree $Root '2.0.0'
        $watch.Stop()
        $times += [Math]::Round($watch.Elapsed.TotalSeconds, 3)
        Write-Host "Assert-ReleaseTree pass ${pass}: $($watch.Elapsed.TotalSeconds) seconds"
    }
    $result = [ordered]@{
        powershell = $PSVersionTable.PSVersion.ToString()
        edition = $PSVersionTable.PSEdition
        os = [Environment]::OSVersion.VersionString
        files = $inventory.files.Count
        directories = $inventory.directories.Count
        json_characters = $json.Length
        json_bytes = (Get-Item -LiteralPath $inventoryPath).Length
        fixture_seconds = [Math]::Round($generation.Elapsed.TotalSeconds, 3)
        parse_seconds = [Math]::Round($parse.Elapsed.TotalSeconds, 3)
        scan_seconds = $times
        three_scans_seconds = ($times | Measure-Object -Sum).Sum
    }
    $report = $result | ConvertTo-Json -Compress
    Write-Host "LARGE_INVENTORY_RESULT=$report"
    if ($env:GITHUB_STEP_SUMMARY) {
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $report -Encoding UTF8
    }
    if ($result.three_scans_seconds -ge 900) {
        throw 'Three inventory scans exceed the fifteen-minute preparation deadline.'
    }
} finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
