[CmdletBinding()]
param([string]$PackageDir=$PSScriptRoot,[string]$ReportDir='C:\UV1780-Acceptance')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(-not $PackageDir){$PackageDir=$PSScriptRoot}
New-Item -ItemType Directory -Path $ReportDir -Force|Out-Null
$report=[ordered]@{Status='running';OS=[Environment]::OSVersion.VersionString;Is64BitOS=[Environment]::Is64BitOperatingSystem;Checks=@();Errors=@()}
$machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
try {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if(-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run this acceptance test as administrator inside a NEW Windows VM or Windows Sandbox.'}
    foreach($keyName in @('SOFTWARE\Shimadzu\UVProbe','SOFTWARE\Shimadzu\AttestServer','SOFTWARE\Classes\UVControl.UV178X.1')) {
        $key=$machine.OpenSubKey($keyName)
        if($key){$key.Dispose();throw ('Not a clean test machine: '+$keyName+' already exists. No installation was attempted.')}
    }
    $pf=if([Environment]::Is64BitOperatingSystem){${env:ProgramFiles(x86)}}else{$env:ProgramFiles}
    $program=Join-Path $pf 'Shimadzu\UVProbe'
    if(Test-Path -LiteralPath $program){throw 'UVProbe program directory already exists. Use a fresh VM.'}
    $report.Checks+='No previous Shimadzu installation or component registrations'
    $report.GlobalMfcBefore=@(Get-ChildItem -Path (Join-Path $env:windir 'WinSxS\x86_microsoft.vc80.mfc_*') -Filter mfc80.dll -ErrorAction SilentlyContinue|ForEach-Object {$_.FullName})
    # This script is intentionally offline. The .wsb also disables networking.
    $env:PATH="$env:windir\System32;$env:windir"
    $exe=Join-Path $PackageDir 'UV1780_UVProbe270_Setup.exe'
    $hashLine=([IO.File]::ReadAllLines((Join-Path $PackageDir 'SHA256.txt')))[0]
    $expected=($hashLine -split '\s+')[0]
    if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $expected){throw 'Setup hash mismatch.'}
    foreach($pass in @('fresh','repair')) {
        $setupLog=Join-Path $ReportDir ($pass+'-setup.log')
        $p=Start-Process -FilePath $exe -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/PREINSTALL=1',('/LOG="'+$setupLog+'"')) -WindowStyle Hidden -PassThru -Wait
        if($p.ExitCode -notin @(0,3010)){throw ($pass+' installation failed: '+$p.ExitCode)}
        $installed=Get-Content -LiteralPath (Join-Path $env:ProgramData 'UV1780Deployment\Install-result.json') -Raw -Encoding UTF8|ConvertFrom-Json
        if($installed.Status -ne 'success' -or $installed.Registered -ne 56 -or $installed.NativeCheck.Status -ne 'success'){throw ($pass+' installation did not pass native component acceptance.')}
        $report.Checks+=($pass+': installation, 56 COM registrations, file hashes and native loading passed')
        if($pass -eq 'fresh') {
            # A user-created data file must survive a repair installation.
            $sentinel=Join-Path $env:SystemDrive 'LabSolutions\UVProbe-Data\DATA\acceptance-preserve.txt'
            'preserve-user-data'|Set-Content -LiteralPath $sentinel -Encoding UTF8
        } elseif((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'preserve-user-data'){throw 'Repair changed user data.'}
    }
    $report.Checks+='Repair preserves user data'
    $powerShell=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $powerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $program 'Deployment\UV1780-Deploy.ps1') -Mode Check -ProgramDir $program -ReportPath (Join-Path $ReportDir 'installed-check.json') | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Installed independent check failed.'}
    $report.Checks+='Installed diagnostic shortcut script passes independently of temporary payload'
    $report.Status='passed'
}catch {$report.Status='failed';$report.Errors+=$_.Exception.Message}
finally {
    $machine.Dispose()
    $report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $ReportDir 'clean-windows-result.json') -Encoding UTF8
    $logs=Join-Path $env:ProgramData 'UV1780Deployment'
    if(Test-Path -LiteralPath $logs){Copy-Item -LiteralPath $logs -Destination $ReportDir -Recurse -Force}
}
if($report.Status -ne 'passed'){exit 1}
exit 0
