$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$base=$PSScriptRoot
$source=Join-Path $base 'UV1780-Deploy.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'PowerShell syntax error.'}
foreach($fn in $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){
    . ([scriptblock]::Create($fn.Extent.Text))
}
$checks=New-Object Collections.Generic.List[string]
function Assert([bool]$Condition,[string]$Label){if(-not $Condition){throw ('FAILED: '+$Label)};$checks.Add($Label)}
$PayloadRoot=Join-Path $base 'payload'
$ProgramDir='C:\TestPrograms\Shimadzu\UVProbe'
$dataRoot='D:\TestData\UVProbe-Data'
$logFile=$null
$result=[ordered]@{Warnings=@();RebootRequired=$false}
$uvKey='SOFTWARE\UV1780DeploymentTests\'+[guid]::NewGuid().ToString('N')
if($uvKey -notmatch '^SOFTWARE\\UV1780DeploymentTests\\[0-9a-f]{32}$'){throw 'Invalid test registry root.'}
$machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry32)
try{
    Assert-Payload
    $checks.Add('All bundled payload hashes match the manifest')
    Assert ((Select-AutomaticPort @()) -eq 0) 'No attached device requires no selected port'
    Assert ((Select-AutomaticPort @([pscustomobject]@{Port=3;Candidate=$true},[pscustomobject]@{Port=5;Candidate=$true})) -eq 0) 'Multiple CH341 interfaces are not silently selected'
    Assert ((Select-AutomaticPort @([pscustomobject]@{Port=5;Candidate=$true},[pscustomobject]@{Port=7;Candidate=$false})) -eq 5) 'One CH341 is preferred over unrelated serial ports'
    Assert ((Select-AutomaticPort @([pscustomobject]@{Port=7;Candidate=$false})) -eq 0) 'An unrelated port is not automatically selected'
    Import-Settings
    $key=$machine.OpenSubKey($uvKey+'\Configuration\Settings')
    try{Assert ($key.GetValue('HelpFile') -eq 'C:\TestPrograms\Shimadzu\UVProbe\UVProbe.chm') 'Help path is relocated to the target computer'}finally{$key.Dispose()}
    $key=$machine.OpenSubKey($uvKey+'\AmbientProps')
    try{Assert ($key.GetValueKind('AUTOSAVE') -eq [Microsoft.Win32.RegistryValueKind]::DWord) 'Registry DWORD type is preserved'}finally{$key.Dispose()}
    $key=$machine.OpenSubKey($uvKey+'\RegisteredInfo')
    try{Assert ($null -ne $key) 'Original registration information migrates through normal settings'}finally{if($key){$key.Dispose()}}
    Set-InstrumentPort 37 'A11916031761'
    $key=$machine.OpenSubKey($uvKey+'\InstrumentManager\仪器 1\Serial Port Settings')
    try{Assert ($key.GetValue('Port') -eq 37) 'Two digit COM ports are written correctly'}finally{$key.Dispose()}
    $key=$machine.OpenSubKey($uvKey+'\InstrumentBar')
    try{Assert ($key.GetValue('') -eq 'SpectroInstrumentBar') 'Instrument bar default registry value is correct'}finally{$key.Dispose()}
    $failed=$false;try{Set-InstrumentPort 0 'A11916031761'}catch{$failed=$true}
    Assert $failed 'Invalid port numbers are rejected'
    $scratch=Join-Path $base ('test-data-'+[guid]::NewGuid().ToString('N'))
    $src=Join-Path $scratch 'source';$dst=Join-Path $scratch 'destination'
    New-Item -ItemType Directory -Path $src,$dst -Force|Out-Null
    'default template' | Set-Content (Join-Path $src 'same.rpt')
    'user customized' | Set-Content (Join-Path $dst 'same.rpt')
    'new template' | Set-Content (Join-Path $src 'new.rpt')
    Copy-IfMissing $src $dst
    Assert ((Get-Content (Join-Path $dst 'same.rpt') -Raw).Trim() -eq 'user customized') 'Existing local methods and report templates are preserved'
    Assert (Test-Path -LiteralPath (Join-Path $dst 'new.rpt')) 'Missing default templates are installed'
    $settingsText=Get-Content -LiteralPath (Join-Path $PayloadRoot 'settings.json') -Raw -Encoding UTF8
    Assert ($settingsText -notmatch '(?i)[A-Z]:\\\\|华工.*\\\\Desktop') 'Portable configuration has no old-computer absolute paths'
    Assert ($settingsText -notmatch 'Default Printer|HP LaserJet|WSD-') 'Old computer printer names and ports are excluded'
    Assert (-not(Test-Path -LiteralPath (Join-Path $PayloadRoot 'templates\DATA'))) 'Measurement data is excluded from the package'
    $manifest=Get-Content -LiteralPath (Join-Path $PayloadRoot 'components.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $count=@($manifest|Where-Object {$_.PSObject.Properties.Name -contains 'register' -and $_.register -and $_.file -notlike 'Chs_*' -and $_.file -ne 'SkyPDFWriterLib.dll'}).Count
    Assert ($count -eq 56) 'The same 56 verified native modules will be registered'
    Assert (@($manifest).Count -eq 184) 'All 165 source files and 19 private runtime files are accounted for'
    foreach($assembly in @('CRT','MFC','MFCLOC')) {
        $dir=Join-Path $PayloadRoot ('program\Microsoft.VC80.'+$assembly)
        [xml]$xml=Get-Content -LiteralPath (Join-Path $dir ('Microsoft.VC80.'+$assembly+'.manifest')) -Raw
        Assert ($xml.assembly.assemblyIdentity.version -eq '8.0.50727.6195' -and $xml.assembly.assemblyIdentity.processorArchitecture -eq 'x86') ('Exact x86 '+$assembly+' assembly identity is bundled')
        foreach($f in $xml.assembly.file) {Assert (Test-Path -LiteralPath (Join-Path $dir $f.name)) ('Assembly member is present: '+$f.name)}
    }
    $legacy=Get-DriverArguments 10240 'C:\中文 空格\CH341SER.INF'
    $modern=Get-DriverArguments 14393 'C:\中文 空格\CH341SER.INF'
    Assert (($legacy -join '|') -eq '-i|-a|C:\中文 空格\CH341SER.INF') 'Initial Windows 10 uses the supported legacy driver command'
    Assert (($modern -join '|') -eq '/add-driver|C:\中文 空格\CH341SER.INF|/install') 'Windows 10 1607 and Windows 11 use the modern driver command'
    $probe=Join-Path $base 'Test-NativeRuntime.ps1'
    $probeExe=Join-Path $env:windir 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if(-not [Environment]::Is64BitOperatingSystem){$probeExe=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'}
    $reportPath=Join-Path $scratch 'native.json'
    & $probeExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe -ProgramDir (Join-Path $PayloadRoot 'program') -ComponentsPath (Join-Path $PayloadRoot 'components.json') -AuthenticationPath (Join-Path $PayloadRoot 'authentication\SmzAtst.ocx') -ReportPath $reportPath
    $native=Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0 -and $native.Status -eq 'success' -and -not $native.Is64BitProcess) 'Native x86 components load under the application activation context'
    Assert ($native.Loaded.Count -eq 148) 'All 148 required runtime, native and authentication libraries load'
    $broken=Join-Path $scratch '中文 空格 缺失依赖'
    New-Item -ItemType Directory -Path $broken -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $PayloadRoot 'program\UVProbe.exe') -Destination $broken
    Copy-Item -LiteralPath (Join-Path $PayloadRoot 'program\Microsoft.VC80.CRT') -Destination $broken -Recurse
    $badReport=Join-Path $scratch 'broken-native.json'
    & $probeExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe -ProgramDir $broken -ComponentsPath (Join-Path $PayloadRoot 'components.json') -ReportPath $badReport -RuntimeOnly
    $brokenResult=Get-Content -LiteralPath $badReport -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($LASTEXITCODE -ne 0 -and $brokenResult.Status -eq 'error') 'A missing MFC assembly is rejected, including paths with Unicode and spaces'
    [ordered]@{Status='passed';Checks=$checks;Count=$checks.Count;Limitations='This is package and isolated configuration testing, not a clean Windows installation.'}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $base 'test-results.json') -Encoding UTF8
    $checks
}finally{
    $machine.DeleteSubKeyTree($uvKey,$false)
    $machine.Dispose()
}
