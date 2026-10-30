[CmdletBinding()]
param(
    [ValidateSet('Preflight','Install','Configure','Check','Verify')][string]$Mode='Check',
    [string]$ProgramDir,
    [string]$PayloadRoot,
    [switch]$Preinstall,
    [switch]$Interactive,
    [int]$Port=0,
    [string]$InstrumentSerial='A11916031761',
    [string]$ReportPath
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(-not $PayloadRoot){$PayloadRoot=$PSScriptRoot}
if (-not $ProgramDir) {
    $pf=if([Environment]::Is64BitOperatingSystem){${env:ProgramFiles(x86)}}else{$env:ProgramFiles}
    $ProgramDir=Join-Path $pf 'Shimadzu\UVProbe'
}
$ProgramDir=[IO.Path]::GetFullPath($ProgramDir).TrimEnd('\')
$nativeSystem=if([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess){Join-Path $env:windir 'Sysnative'}else{Join-Path $env:windir 'System32'}
$system32=if([Environment]::Is64BitOperatingSystem){Join-Path $env:windir 'SysWOW64'}else{Join-Path $env:windir 'System32'}
$machine=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry32)
$uvKey='SOFTWARE\Shimadzu\UVProbe'
$dataRoot=Join-Path $env:SystemDrive 'LabSolutions\UVProbe-Data'
$configRoot=Join-Path $env:SystemDrive 'LabSolutions\UVProbe'
$logRoot=Join-Path $env:ProgramData 'UV1780Deployment'
$logFile=$null
$result=[ordered]@{Mode=$Mode;Status='running';ProgramDir=$ProgramDir;OS=[Environment]::OSVersion.VersionString;Architecture=$env:PROCESSOR_ARCHITECTURE;Preinstall=[bool]$Preinstall;RebootRequired=$false;Ports=@();Registered=0;Warnings=@();Errors=@()}
function Is-Administrator {
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Log([string]$Message) {
    $line=('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date),$Message)
    if($logFile){Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8}
    Write-Output $line
}
function Show-Message([string]$Text,[bool]$ErrorMessage=$false) {
    Add-Type -AssemblyName System.Windows.Forms
    $icon=if($ErrorMessage){[Windows.Forms.MessageBoxIcon]::Error}else{[Windows.Forms.MessageBoxIcon]::Information}
    [Windows.Forms.MessageBox]::Show($Text,'UV-1780 部署工具',[Windows.Forms.MessageBoxButtons]::OK,$icon)|Out-Null
}
function Assert-Closed {
    if(Get-Process UVProbe -ErrorAction SilentlyContinue){throw '请先关闭 UVProbe，再运行安装或串口配置。正在打开的软件不会被强制结束。'}
}
function Get-SerialDevices {
    $found=@()
    # WMI is available on the targeted Windows 10/11 systems; ConfigManagerErrorCode
    # filters out unplugged devices retained in the registry.
    try {$entities=@(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Ports'" -ErrorAction Stop)}
    catch {
        $result.Warnings+='Windows 串口枚举暂不可用。软件仍可预装；恢复 Windows WMI 服务后重新检测设备。'
        return @()
    }
    foreach($d in $entities) {
        if($d.ConfigManagerErrorCode -ne 0 -or $d.Name -notmatch '\(COM(\d+)\)'){continue}
        $number=[int]$Matches[1]
        $id=[string]$d.PNPDeviceID
        $isCandidate=$id -match '(?i)^USB\\VID_(1A86|4348)&PID_5523'
        $found += [pscustomobject]@{Port=$number;Name=[string]$d.Name;Id=$id;Candidate=[bool]$isCandidate}
    }
    @($found | Sort-Object Port)
}
function Select-AutomaticPort($Devices) {
    $candidates=@($Devices | Where-Object {$_.Candidate})
    if($candidates.Count -eq 1){return [int]$candidates[0].Port}
    return 0
}
function Set-UvValue([string]$Relative,[string]$Name,$Value,[Microsoft.Win32.RegistryValueKind]$Kind=[Microsoft.Win32.RegistryValueKind]::String) {
    $subkey=if($Relative){$uvKey+'\'+$Relative}else{$uvKey}
    $key=$machine.CreateSubKey($subkey)
    try{$key.SetValue($Name,$Value,$Kind)}finally{$key.Dispose()}
}
function Set-InstrumentPort([int]$Number,[string]$Serial) {
    if($Number -lt 1 -or $Number -gt 4096){throw '串口号不在支持范围 COM1–COM4096 内。'}
    if($Serial -notmatch '^[A-Za-z0-9\-]{1,40}$'){throw '请填写仪器铭牌上的出厂编号（英文字母、数字或短横线）。'}
    Set-UvValue 'InstrumentManager\仪器 1' 'ComName' 'UVControl.UV178X.1'
    Set-UvValue 'InstrumentManager\仪器 1\Serial Port Settings' 'Port' ([int]$Number) DWord
    Set-UvValue 'InstrumentManager\仪器 1\serial_nos' 'UV-1780' $Serial
    # Registry default value is an empty string, not the display name '(default)'.
    Set-UvValue 'InstrumentBar' '' 'SpectroInstrumentBar'
    Set-UvValue 'InstrumentBar' 'ActiveInstrument' '仪器 1'
    Log "Instrument configured on COM$Number; device connection has not been tested."
}
function Copy-IfMissing([string]$Source,[string]$Destination) {
    foreach($file in @(Get-ChildItem -LiteralPath $Source -File -Recurse)) {
        $relative=$file.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
        $target=Join-Path $Destination $relative
        if(-not(Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($target)) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target
        }
    }
}
function Invoke-Hidden([string]$File,[string[]]$Arguments,[int[]]$Allowed=@(0)) {
    $p=Start-Process -FilePath $File -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    if($p.ExitCode -notin $Allowed){throw "组件安装失败：$([IO.Path]::GetFileName($File))，返回码 $($p.ExitCode)。详见 $logRoot"}
    if($p.ExitCode -eq 3010){$result.RebootRequired=$true;$result.Warnings += 'Windows 要求重新启动；安装完成后请自行重启电脑。'}
    return $p.ExitCode
}
function Assert-Payload {
    $entries=Get-Content -LiteralPath (Join-Path $PayloadRoot 'payload-manifest.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    foreach($entry in $entries) {
        $file=[IO.Path]::GetFullPath((Join-Path $PayloadRoot $entry.file))
        if(-not $file.StartsWith([IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw '安装文件路径校验失败。'}
        if(-not(Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.sha256){throw "安装文件损坏：$($entry.file)"}
    }
    Log ('Payload verified: '+@($entries).Count+' files.')
}
function Grant-AppDataAccess([string]$Path) {
    $acl=Get-Acl -LiteralPath $Path
    $sid=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($sid,'Modify','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Invoke-NativeCheck([string]$Directory,[switch]$RuntimeOnly) {
    $probeReport=Join-Path ([IO.Path]::GetTempPath()) ('UV1780-native-'+[guid]::NewGuid().ToString('N')+'.json')
    $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PayloadRoot 'Test-NativeRuntime.ps1')+'"'),
        '-ProgramDir',('"'+$Directory+'"'),'-ComponentsPath',('"'+(Join-Path $PayloadRoot 'components.json')+'"'),'-ReportPath',('"'+$probeReport+'"'))
    if($RuntimeOnly){$args+='-RuntimeOnly'}
    else {$args+=@('-AuthenticationPath',('"'+(Join-Path $system32 'SmzAtst.ocx')+'"'))}
    try {
        $p=Start-Process -FilePath (Join-Path $system32 'WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -WindowStyle Hidden -Wait -PassThru
        if(-not(Test-Path -LiteralPath $probeReport)){throw '无法生成 32 位组件加载报告。'}
        $result.NativeCheck=Get-Content -LiteralPath $probeReport -Raw -Encoding UTF8 | ConvertFrom-Json
        if($p.ExitCode -ne 0 -or $result.NativeCheck.Status -ne 'success') {
            throw ('32 位运行库或组件无法加载：'+(($result.NativeCheck.Failures|ForEach-Object {$_.File+': '+$_.Error}) -join '; '))
        }
    } finally {if(Test-Path -LiteralPath $probeReport){Remove-Item -LiteralPath $probeReport -Force}}
}
function Get-DriverArguments([int]$Build,[string]$InfPath) {
    if($Build -ge 14393){return @('/add-driver',$InfPath,'/install')}
    return @('-i','-a',$InfPath)
}
function Install-Prerequisites {
    # Complete private CRT/MFC assemblies travel with the program. No prior
    # software, global VC runtime, MSI service or internet connection is needed.
    Invoke-NativeCheck (Join-Path $PayloadRoot 'program') -RuntimeOnly
    Log 'Bundled VC80 x86 CRT and MFC assemblies activated and loaded successfully.'
    $auth=Join-Path $system32 'SmzAtst.ocx'
    if(Test-Path -LiteralPath $auth) {
        if((Get-Item -LiteralPath $auth).VersionInfo.FileVersionRaw -lt [version]'2.3.2.0'){throw '检测到较旧的岛津共享认证组件。请先通过原厂安装程序升级，避免影响其他岛津软件。'}
        Log 'Existing Shimadzu authentication component and databases preserved.'
    }
    Log 'Repairing missing authentication files and registering the 32-bit authentication component.'
    Copy-IfMissing (Join-Path $PayloadRoot 'authentication') $system32
    Invoke-Hidden (Join-Path $system32 'regsvr32.exe') @('/s',('"'+$auth+'"')) | Out-Null
        $at=$machine.CreateSubKey('SOFTWARE\Shimadzu\AttestServer')
        try {
            if(-not $at.GetValue('Server')){$at.SetValue('Server',(Join-Path $system32 'SMZATST.MDB'));$at.SetValue('DBKind','0');$at.SetValue('Version','1.09')}
        } finally {$at.Dispose()}
        $machine.CreateSubKey('SOFTWARE\Shimadzu\SMZATST\1.09').Dispose()
        $machine.CreateSubKey('SOFTWARE\Shimadzu\SMZATST\2.32').Dispose()
    $devices=@(Get-SerialDevices)
    $result.Ports=$devices
    if(@($devices | Where-Object {$_.Candidate}).Count -gt 0){Log 'Working CH341 device already present; existing driver preserved.'}
    else {
        Log 'Staging signed CH341 driver for connected or future devices.'
        $driverLog=Join-Path $logRoot 'CH341-driver.log'
        $driverArgs=Get-DriverArguments ([Environment]::OSVersion.Version.Build) (Join-Path $PayloadRoot 'driver\CH341SER.INF')
        & (Join-Path $nativeSystem 'pnputil.exe') @driverArgs 2>&1 | Out-File -LiteralPath $driverLog -Encoding UTF8
        if($LASTEXITCODE -notin @(0,3010)){throw "串口驱动预装失败（$LASTEXITCODE），请查看 $driverLog。"}
        if($LASTEXITCODE -eq 3010){$result.RebootRequired=$true;$result.Warnings += '串口驱动需要重新启动电脑。'}
    }
}
function Import-Settings {
    $settings=Get-Content -LiteralPath (Join-Path $PayloadRoot 'settings.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    foreach($entry in $settings) {
        foreach($property in $entry.values.PSObject.Properties) {
            $name=if($property.Name -eq '(default)'){''}else{$property.Name}
            $value=$property.Value
            $kind=[Microsoft.Win32.RegistryValueKind][int]$entry.types.($property.Name)
            if($value -is [string]){$value=$value.Replace('@PROGRAM@',$ProgramDir).Replace('@DATA@',$dataRoot)}
            if($kind -eq [Microsoft.Win32.RegistryValueKind]::DWord){$value=[BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$value),0)}
            elseif($kind -eq [Microsoft.Win32.RegistryValueKind]::Binary){$hex=$value.hex;$value=[byte[]]@(for($i=0;$i -lt $hex.Length;$i+=2){[Convert]::ToByte($hex.Substring($i,2),16)})}
            Set-UvValue $entry.key $name $value $kind
        }
    }
}
function Show-PortDialog($Devices) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form=New-Object Windows.Forms.Form
    $form.Text='UV-1780 检测并配置设备';$form.ClientSize=New-Object Drawing.Size(580,285)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false;$form.MinimizeBox=$false
    $form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
    $label=New-Object Windows.Forms.Label;$label.SetBounds(20,15,540,55);$label.Text='请先让仪器进入 PC Control，再选择连接线对应的串口。CH341 接口会优先选中；检测到接口不代表仪器已连接成功。';$form.Controls.Add($label)
    $combo=New-Object Windows.Forms.ComboBox;$combo.SetBounds(20,80,540,30);$combo.DropDownStyle='DropDownList'
    foreach($d in $Devices){[void]$combo.Items.Add($d.Name)}
    $selected=Select-AutomaticPort $Devices
    for($i=0;$i -lt $Devices.Count;$i++){if($Devices[$i].Port -eq $selected){$combo.SelectedIndex=$i}}
    $form.Controls.Add($combo)
    $l2=New-Object Windows.Forms.Label;$l2.SetBounds(20,130,540,25);$l2.Text='仪器出厂编号（请与铭牌核对）：';$form.Controls.Add($l2)
    $serialText=New-Object Windows.Forms.TextBox;$serialText.SetBounds(20,160,540,30);$serialText.Text=$InstrumentSerial;$form.Controls.Add($serialText)
    $ok=New-Object Windows.Forms.Button;$ok.SetBounds(325,225,115,35);$ok.Text='保存设置';$ok.DialogResult='OK';$form.AcceptButton=$ok;$form.Controls.Add($ok)
    $cancel=New-Object Windows.Forms.Button;$cancel.SetBounds(450,225,110,35);$cancel.Text='取消';$cancel.DialogResult='Cancel';$form.CancelButton=$cancel;$form.Controls.Add($cancel)
    if($form.ShowDialog() -ne 'OK'){return $null}
    if($combo.SelectedIndex -lt 0){throw '未选择串口。接好连接线后重新运行此工具。'}
    [pscustomobject]@{Port=[int]$Devices[$combo.SelectedIndex].Port;Serial=$serialText.Text.Trim()}
}
function Check-Installation {
    $files=Get-Content -LiteralPath (Join-Path $PayloadRoot 'components.json') -Encoding UTF8 -Raw | ConvertFrom-Json
    $bad=@()
    foreach($f in $files){$path=Join-Path $ProgramDir $f.file;if(-not(Test-Path -LiteralPath $path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $f.sha256){$bad += $f.file}}
    $result.FileCount=@($files).Count;$result.FileErrors=$bad
    $result.Ports=@(Get-SerialDevices)
    $key=$machine.OpenSubKey($uvKey+'\InstrumentManager\仪器 1\Serial Port Settings')
    $result.ConfiguredPort=if($key){try{$key.GetValue('Port')}finally{$key.Dispose()}}else{$null}
    $cls=$machine.OpenSubKey('SOFTWARE\Classes\UVControl.UV178X.1\CLSID')
    $result.UV178XClass=if($cls){try{$cls.GetValue('')}finally{$cls.Dispose()}}else{$null}
    if($bad.Count -gt 0){throw ('程序文件不完整或与安装包不同：'+($bad -join ', '))}
    if(-not $result.UV178XClass){throw 'UV178X 控制组件尚未注册。请重新安装修复。'}
    $classKey=$machine.OpenSubKey('SOFTWARE\Classes\CLSID\'+$result.UV178XClass+'\InprocServer32')
    try {
        if(-not $classKey -or $classKey.GetValue('') -ne (Join-Path $ProgramDir 'UV178X.dll')){throw 'UV178X 的组件注册路径不正确，请重新安装修复。'}
    }finally{if($classKey){$classKey.Dispose()}}
    Invoke-NativeCheck $ProgramDir
    Log 'Read-only file and component checks passed. No instrument commands were sent.'
}

try {
    if($Mode -notin @('Check','Verify') -and -not(Is-Administrator)) {
        if($Mode -eq 'Configure' -and $Interactive) {
            $elevatedArguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-Mode','Configure','-Interactive','-ProgramDir',('"'+$ProgramDir+'"'))
            $p=Start-Process -FilePath (Join-Path $system32 'WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $elevatedArguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
            exit $p.ExitCode
        }
        throw '安装或配置需要管理员权限，请允许 Windows 的管理员提示。'
    }
    if($Mode -notin @('Check','Verify')) {
        New-Item -ItemType Directory -Path $logRoot -Force|Out-Null
        $logFile=Join-Path $logRoot ('{0}-{1:yyyyMMdd-HHmmss}.log' -f $Mode,(Get-Date))
    }
    if($Mode -eq 'Verify') {
        Assert-Payload
        $components=Get-Content -LiteralPath (Join-Path $PayloadRoot 'components.json') -Encoding UTF8 -Raw|ConvertFrom-Json
        $result.FileCount=@($components).Count
        $result.RegisteredComponentCount=@($components|Where-Object {$_.PSObject.Properties.Name -contains 'register' -and $_.register -and $_.file -notlike 'Chs_*' -and $_.file -ne 'SkyPDFWriterLib.dll'}).Count
        $result.NoDevicePort=Select-AutomaticPort @()
        $result.MultipleDevicePort=Select-AutomaticPort @([pscustomobject]@{Port=3;Candidate=$true},[pscustomobject]@{Port=5;Candidate=$true})
        $result.SingleDevicePort=Select-AutomaticPort @([pscustomobject]@{Port=5;Candidate=$true},[pscustomobject]@{Port=7;Candidate=$false})
        if($result.NoDevicePort -ne 0 -or $result.MultipleDevicePort -ne 0 -or $result.SingleDevicePort -ne 5){throw '串口选择逻辑验证失败。'}
        $result.Warnings+='此检查验证安装包内容与串口选择逻辑，不等同于干净系统实装或仪器通信测试。'
    }
    elseif($Mode -eq 'Preflight') {
        Assert-Closed
        if($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64'){throw '此包不支持 Windows ARM；请使用 Intel/AMD 的 Windows 10/11。'}
        if([Environment]::OSVersion.Version.Major -lt 10 -or $PSVersionTable.PSVersion.Major -lt 5){throw '此包需要 Windows 10/11 与系统自带的 Windows PowerShell 5.x。'}
        Assert-Payload
        $existing=$machine.OpenSubKey($uvKey+'\AmbientProps')
        if($existing){try{if($existing.GetValue('SecurityEnable',0) -ne 0 -or $existing.GetValue('GLPCompliant',0) -ne 0){throw '此电脑的 UVProbe 已启用受管理模式，不能用本包覆盖；请联系软件管理员。'}}finally{$existing.Dispose()}}
        Install-Prerequisites
        $regRoot=if([Environment]::Is64BitOperatingSystem){'HKLM\SOFTWARE\WOW6432Node\Shimadzu\UVProbe'}else{'HKLM\SOFTWARE\Shimadzu\UVProbe'}
        $priorKey=$machine.OpenSubKey($uvKey)
        if($priorKey){$priorKey.Dispose();& (Join-Path $nativeSystem 'reg.exe') export $regRoot (Join-Path $logRoot ('BeforeInstall-{0:yyyyMMdd-HHmmss}.reg' -f (Get-Date))) /y | Out-Null}
    }
    elseif($Mode -eq 'Install') {
        Assert-Closed
        foreach($dir in @($dataRoot,$configRoot,(Join-Path $dataRoot 'DATA'))){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
        Copy-IfMissing (Join-Path $PayloadRoot 'templates') $dataRoot
        Grant-AppDataAccess $dataRoot;Grant-AppDataAccess $configRoot
        $files=Get-Content -LiteralPath (Join-Path $PayloadRoot 'components.json') -Encoding UTF8 -Raw | ConvertFrom-Json
        foreach($f in $files){$path=Join-Path $ProgramDir $f.file;if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $f.sha256){throw "程序文件校验失败：$($f.file)"}}
        foreach($f in @($files | Where-Object {$_.PSObject.Properties.Name -contains 'register' -and $_.register -and $_.file -notlike 'Chs_*' -and $_.file -ne 'SkyPDFWriterLib.dll'})) {
            Log ('Registering '+$f.file)
            Invoke-Hidden (Join-Path $system32 'regsvr32.exe') @('/s',('"'+(Join-Path $ProgramDir $f.file)+'"')) | Out-Null
            $result.Registered++
        }
        Import-Settings
        Set-UvValue 'Modules\Spectrum\Settings' 'DEFAULTDATADIR' (Join-Path $dataRoot 'DATA')
        Set-UvValue 'Modules\Kinetics\Settings' 'DEFDIR' (Join-Path $dataRoot 'DATA')
        Set-UvValue 'Modules\Photometric\Settings' 'Data Directory' (Join-Path $dataRoot 'DATA')
        # Own application key permissions are scoped to UVProbe only.
        $key=$machine.CreateSubKey($uvKey)
        try {
            $acl=$key.GetAccessControl();$sid=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
            $rule=New-Object Security.AccessControl.RegistryAccessRule($sid,'ReadKey,WriteKey','ContainerInherit','None','Allow')
            $acl.AddAccessRule($rule);$key.SetAccessControl($acl)
        }finally{$key.Dispose()}
        if(-not $Preinstall) {
            $result.Ports=@(Get-SerialDevices);$detected=Select-AutomaticPort $result.Ports
            if($detected){Set-InstrumentPort $detected $InstrumentSerial;$result.ConfiguredPort=$detected}
            else{$result.Warnings+='没有找到唯一的 CH341 接口。软件已预装，接好仪器后运行“UV1780 检测并配置设备”。'}
        }
        else {$result.Warnings+='已按“仅预装软件”完成。接好仪器后运行“UV1780 检测并配置设备”。'}
        Check-Installation
    }
    elseif($Mode -eq 'Configure') {
        Assert-Closed
        $result.Ports=@(Get-SerialDevices)
        if($Interactive){$choice=Show-PortDialog $result.Ports;if(-not $choice){$result.Status='cancelled'}else{$Port=$choice.Port;$InstrumentSerial=$choice.Serial}}
        elseif(-not $Port){$Port=Select-AutomaticPort $result.Ports}
        if($result.Status -ne 'cancelled') {
            if(-not $Port){throw '没有找到唯一的 CH341 接口。请接好仪器，再运行检测工具选择串口。'}
            if($Port -notin @($result.Ports | ForEach-Object {$_.Port})){throw "COM$Port 当前未连接或存在设备故障，请检查连接线。"}
            Set-InstrumentPort $Port $InstrumentSerial;$result.ConfiguredPort=$Port
            if($Interactive){Show-Message "已设为 COM$Port。`r`n请打开 UVProbe 2.70，并按 F9 连接。`r`n本工具未启动测量；能否连接需在 UVProbe 中确认。"}
        }
    }
    else {Check-Installation;if($Interactive){Show-Message ('文件检查通过，共 '+$result.FileCount+' 个。当前设置：COM'+$result.ConfiguredPort+'。未发送仪器控制命令。')}}
    if($result.Status -eq 'running'){$result.Status='success'}
}
catch {
    $result.Status='error';$result.Errors += $_.Exception.Message
    Log ('ERROR: '+$_.Exception.Message)
    if($Interactive){Show-Message $_.Exception.Message $true}
}
finally {
    $machine.Dispose()
    $json=$result | ConvertTo-Json -Depth 6
    if($ReportPath){$json | Set-Content -LiteralPath $ReportPath -Encoding UTF8}
    elseif($Mode -notin @('Check','Verify') -and (Test-Path -LiteralPath $logRoot)){$json|Set-Content -LiteralPath (Join-Path $logRoot ($Mode+'-result.json')) -Encoding UTF8}
    Write-Output $json
}
if($result.Status -eq 'error'){exit 1}
if($result.RebootRequired){exit 3010}
exit 0
