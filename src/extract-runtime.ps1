[CmdletBinding()]
param([string]$Msi,[string]$Destination)
$ErrorActionPreference='Stop'
if(-not $Msi){$Msi=Join-Path $PSScriptRoot 'payload\runtime\vcredist.msi'}
if(-not $Destination){$Destination=Join-Path $PSScriptRoot 'private-runtime'}
# Read the signed redistributable as a database; never install it on the build PC.
if(-not ('UV1780.MsiStreams' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
namespace UV1780 {
  public static class MsiStreams {
    [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiOpenDatabase(string path, IntPtr persist, out uint db);
    [DllImport("msi.dll", CharSet=CharSet.Unicode)] static extern uint MsiDatabaseOpenView(uint db, string query, out uint view);
    [DllImport("msi.dll")] static extern uint MsiViewExecute(uint view, uint record);
    [DllImport("msi.dll")] static extern uint MsiViewFetch(uint view, out uint record);
    [DllImport("msi.dll")] static extern uint MsiRecordReadStream(uint record, uint field, byte[] data, ref uint size);
    [DllImport("msi.dll")] static extern uint MsiCloseHandle(uint handle);
    static void Check(uint code) { if(code != 0) throw new IOException("MSI read failed: " + code); }
    public static void Extract(string msi, string name, string output) {
      uint db=0, view=0, row=0;
      try {
        Check(MsiOpenDatabase(msi, IntPtr.Zero, out db));
        Check(MsiDatabaseOpenView(db, "SELECT `Data` FROM `_Streams` WHERE `Name`='" + name.Replace("'", "''") + "'", out view));
        Check(MsiViewExecute(view, 0)); Check(MsiViewFetch(view, out row));
        using(var f=File.Create(output)) {
          byte[] bytes=new byte[65536];
          while(true) { uint size=(uint)bytes.Length; Check(MsiRecordReadStream(row,1,bytes,ref size));
            if(size==0) break; f.Write(bytes,0,(int)size); }
        }
      } finally { if(row!=0) MsiCloseHandle(row); if(view!=0) MsiCloseHandle(view); if(db!=0) MsiCloseHandle(db); }
    }
  }
}
'@
}
$Msi=[IO.Path]::GetFullPath($Msi)
$signature=Get-AuthenticodeSignature -LiteralPath $Msi
if(-not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {throw 'Unexpected redistributable signer.'}
$installer=New-Object -ComObject WindowsInstaller.Installer
$db=$installer.OpenDatabase($Msi,0)
$view=$db.OpenView('SELECT `File`, `FileName` FROM `File`')
$view.Execute()
$names=@{}
while($row=$view.Fetch()) {$names[$row.StringData(1)]=($row.StringData(2) -split '\|')[-1]}
$scratch=Join-Path $PSScriptRoot ('runtime-extract-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force|Out-Null
foreach($assembly in @('CRT','MFC','MFCLOC')) {
    $cab=Join-Path $scratch ($assembly+'.cab')
    [UV1780.MsiStreams]::Extract($Msi,('_142'+@{CRT='41';MFC='48';MFCLOC='50'}[$assembly]+'_Microsoft_VC80_'+$assembly+'_x86.msm'),$cab)
    $expanded=Join-Path $scratch $assembly
    New-Item -ItemType Directory -Path $expanded -Force|Out-Null
    & "$env:windir\System32\expand.exe" '-F:*' $cab $expanded | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Cabinet extraction failed.'}
    $target=Join-Path $Destination ('Microsoft.VC80.'+$assembly)
    New-Item -ItemType Directory -Path $target -Force|Out-Null
    foreach($file in Get-ChildItem -LiteralPath $expanded -File) {
        $name=$names[$file.Name]
        if(-not $name){throw ('Missing MSI file mapping: '+$file.Name)}
        if($name -like '*.cat'){continue}
        if($name -like '*.manifest'){$name='Microsoft.VC80.'+$assembly+'.manifest'}
        $dest=Join-Path $target $name
        if(Test-Path -LiteralPath $dest) {
            if((Get-FileHash -LiteralPath $dest).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash){throw ('Conflicting runtime file: '+$name)}
        } else {Copy-Item -LiteralPath $file.FullName -Destination $dest}
    }
}
Get-ChildItem -LiteralPath $Destination -File -Recurse | Select-Object Name,Length
