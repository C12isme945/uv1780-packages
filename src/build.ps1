$ErrorActionPreference='Stop'
$base=$PSScriptRoot
foreach($name in @('UV1780-Deploy.ps1','Test-NativeRuntime.ps1','使用说明.txt','install-notice.txt','prepare-payload.ps1','extract-runtime.ps1','Test-CleanWindows.ps1','Start-CleanWindowsTest.ps1','test-package.ps1')) {
    $p=Join-Path $base $name
    $t=[IO.File]::ReadAllText($p)
    [IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding($true)))
}
& (Join-Path $base 'prepare-payload.ps1')
Copy-Item -LiteralPath (Join-Path $base 'UV1780-Deploy.ps1') -Destination (Join-Path $base 'payload\UV1780-Deploy.ps1') -Force
$payload=Join-Path $base 'payload'
$manifest=@(Get-ChildItem -LiteralPath $payload -File -Recurse | Where-Object {$_.Name -ne 'payload-manifest.json'} | ForEach-Object {
    [ordered]@{file=$_.FullName.Substring($payload.Length+1);size=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
})
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $payload 'payload-manifest.json') -Encoding UTF8
foreach($name in @('UV1780-Deploy.ps1','Test-NativeRuntime.ps1','Test-CleanWindows.ps1','Start-CleanWindowsTest.ps1','prepare-payload.ps1','extract-runtime.ps1','test-package.ps1')) {
    $syntaxErrors=$null;$tokens=$null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $base $name),[ref]$tokens,[ref]$syntaxErrors)|Out-Null
    if($syntaxErrors.Count){throw ($syntaxErrors | Out-String)}
}
& (Join-Path $base 'compiler\ISCC.exe') /Q (Join-Path $base 'installer.iss')
if($LASTEXITCODE -ne 0){throw 'Installer compilation failed.'}
$output=Join-Path (Split-Path (Split-Path $base)) 'outputs\UV1780_一键安装包'
Copy-Item -LiteralPath (Join-Path $base '使用说明.txt') -Destination (Join-Path $output '使用说明.txt') -Force
foreach($name in @('Test-CleanWindows.ps1','Start-CleanWindowsTest.ps1')) {
    Copy-Item -LiteralPath (Join-Path $base $name) -Destination (Join-Path $output $name) -Force
}
Copy-Item -LiteralPath (Join-Path $base 'Start-CleanWindowsTest.cmd') -Destination (Join-Path $output '启动干净系统验收.cmd') -Force
$exe=Join-Path $output 'UV1780_UVProbe270_Setup.exe'
((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash+'  UV1780_UVProbe270_Setup.exe') | Set-Content -LiteralPath (Join-Path $output 'SHA256.txt') -Encoding ASCII
Get-Item -LiteralPath $exe | Select-Object FullName,Length
