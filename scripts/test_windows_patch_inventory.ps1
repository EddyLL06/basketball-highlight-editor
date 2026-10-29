# Import only the strict helper functions; never run a real installer.
$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Temp = Join-Path ([IO.Path]::GetTempPath()) ('bhe-patch-inventory-' + [Guid]::NewGuid().ToString('N'))
try {
    foreach ($name in @('BHE.exe','flutter_windows.dll','data/app.so','data/icudtl.dat','runtime/python/python.exe')) {
        $path = Join-Path $Temp $name
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        [IO.File]::WriteAllText($path, 'test')
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'apps/desktop/assets/windows_update.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Helper parse failed' }
    foreach ($definition in $ast.EndBlock.Statements) {
        if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
            . ([scriptblock]::Create($definition.Extent.Text))
        }
    }
    & "$PSScriptRoot/write_windows_release_inventory.ps1" -Root $Temp -Version '0.1.13-windows.1'
    $inventory = Get-Content (Join-Path $Temp 'bhe-release.json') -Raw | ConvertFrom-Json
    if ($inventory.release_version -ne '0.1.13-windows.1') { throw 'Patch identity missing' }
    # This is the same request the already-shipped client sends from top-level version.
    Assert-ReleaseTree $Temp '0.1.13'
    $rejected = $false
    try { Assert-ReleaseTree $Temp '0.1.14' } catch { $rejected = $true }
    if (!$rejected) { throw 'Strict version protection was weakened' }
    Write-Output 'Windows patch inventory: old-client base request accepted; wrong base rejected.'
} finally { if (Test-Path $Temp) { Remove-Item -Recurse -Force $Temp } }
