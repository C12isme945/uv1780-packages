$ErrorActionPreference='Stop'
$base=$PSScriptRoot
$reports=Join-Path $base 'clean-windows-reports'
New-Item -ItemType Directory -Path $reports -Force|Out-Null
$source=[Security.SecurityElement]::Escape($base)
$target=[Security.SecurityElement]::Escape($reports)
$configuration=@"
<Configuration>
  <Networking>Disable</Networking>
  <ClipboardRedirection>Disable</ClipboardRedirection>
  <MappedFolders>
    <MappedFolder><HostFolder>$source</HostFolder><SandboxFolder>C:\Package</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$target</HostFolder><SandboxFolder>C:\Reports</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Package\Test-CleanWindows.ps1 -PackageDir C:\Package -ReportDir C:\Reports</Command></LogonCommand>
</Configuration>
"@
$wsb=Join-Path $base 'UV1780-CleanWindows.wsb'
[IO.File]::WriteAllText($wsb,$configuration,(New-Object Text.UTF8Encoding($true)))
if(-not (Test-Path 'Registry::HKEY_CLASSES_ROOT\WindowsSandbox')) {
    $association=Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\.wsb' -ErrorAction SilentlyContinue
    if(-not $association){throw 'Windows Sandbox is not available. Enable it in Windows features, or run Test-CleanWindows.ps1 as administrator in a fresh VM. This script does not change Windows features.'}
}
Start-Process -FilePath $wsb
Write-Host ('Offline acceptance started. Results: '+$reports)
