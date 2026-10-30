$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$base=$PSScriptRoot
$backup=Join-Path (Split-Path (Split-Path $base)) 'outputs\UV1780_旧电脑软件备份'
$payload=Join-Path $base 'payload'
function Copy-Tree([string]$From,[string]$To) {
    if(-not(Test-Path -LiteralPath $From -PathType Container)){throw ('Missing source: '+$From)}
    New-Item -ItemType Directory -Path $To -Force|Out-Null
    Get-ChildItem -LiteralPath $From -Force | Copy-Item -Destination $To -Recurse -Force
}
Copy-Tree (Join-Path $backup 'uv软件') (Join-Path $payload 'program')
Copy-Tree (Join-Path (Split-Path $base) 'uvprobe\vc2005-extracted') (Join-Path $payload 'runtime')
Copy-Tree (Join-Path $base 'wch-full\CH341SER\WIN 1X') (Join-Path $payload 'driver')
foreach($name in @('METHODS','REPORTS')) {Copy-Tree (Join-Path $backup ('UVProbe-Data\'+$name)) (Join-Path $payload ('templates\'+$name))}
foreach($group in @('Program_Files_Us','Program_Files_Us_2','Program_Selfreg_Files_US')) {
    Copy-Tree (Join-Path $base ('auth-extracted\'+$group)) (Join-Path $payload 'authentication')
}
& (Join-Path $base 'extract-runtime.ps1') -Msi (Join-Path $payload 'runtime\vcredist.msi') | Out-Null
foreach($assembly in @('CRT','MFC','MFCLOC')) {
    Copy-Tree (Join-Path $base ('private-runtime\Microsoft.VC80.'+$assembly)) (Join-Path $payload ('program\Microsoft.VC80.'+$assembly))
}
$original=Get-Content -LiteralPath (Join-Path $backup 'UVProbe原电脑设置.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$settings=@(foreach($entry in $original) {
    $relative=$entry.key -replace '^ROOT\\WOW6432Node\\Shimadzu\\UVProbe',''
    $relative=$relative.TrimStart('\')
    if(($relative -split '\\')[0] -notin @('','2.70','AmbientProps','Configuration','InstalledInstrumentDrivers','RegisteredInfo','Report','Settings')){continue}
    # Printer identities and ports belong to the destination PC, never the source.
    if($relative -eq 'Report\Default Printer' -or $relative.StartsWith('Report\Default Printer\')){continue}
    $entry.key=$relative
    foreach($property in @($entry.values.PSObject.Properties)) {
        if($property.Value -is [string]) {
            if($property.Value -match '(?i)\\uv软件\\'){$property.Value='@PROGRAM@\'+[IO.Path]::GetFileName($property.Value)}
            elseif($property.Value -match '(?i)\\UVProbe-Data\\'){$property.Value='@DATA@\'+($property.Value -split '(?i)\\UVProbe-Data\\',2)[1]}
        }
    }
    $entry
})
$settings|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $payload 'settings.json') -Encoding UTF8
$components=Get-Content -LiteralPath (Join-Path $backup '软件文件校验清单.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach($file in Get-ChildItem -LiteralPath (Join-Path $base 'private-runtime') -Recurse -File) {
    $relative=$file.FullName.Substring((Join-Path $base 'private-runtime').Length+1)
    $components += [pscustomobject]@{file=$relative;size=$file.Length;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash;register=$false}
}
$components|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $payload 'components.json') -Encoding UTF8
foreach($name in @('UV1780-Deploy.ps1','Test-NativeRuntime.ps1')) {
    Copy-Item -LiteralPath (Join-Path $base $name) -Destination (Join-Path $payload $name) -Force
}
Write-Output ('Prepared '+$components.Count+' program files using Windows PowerShell only.')
