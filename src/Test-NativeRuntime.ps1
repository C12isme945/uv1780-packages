[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ProgramDir,
      [Parameter(Mandatory=$true)][string]$ReportPath,
      [string]$ComponentsPath,
      [string]$AuthenticationPath,
      [switch]$RuntimeOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(-not $ComponentsPath){$ComponentsPath=Join-Path $PSScriptRoot 'components.json'}
$report=[ordered]@{Status='running';Is64BitProcess=[Environment]::Is64BitProcess;RuntimeOnly=[bool]$RuntimeOnly;Loaded=@();Resolved=@();Failures=@()}
try {
    if([Environment]::Is64BitProcess){throw 'This probe must run in 32-bit Windows PowerShell.'}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Text;
using System.Runtime.InteropServices;
namespace UV1780 {
 public static class NativeLoader {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct ACTCTX {
   public int cbSize; public uint flags; public string source;
   public ushort arch; public ushort lang; public string assemblyDir;
   public IntPtr resource; public string application; public IntPtr module;
  }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateActCtx(ref ACTCTX context);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool ActivateActCtx(IntPtr context,out UIntPtr cookie);
  [DllImport("kernel32.dll")] static extern bool DeactivateActCtx(uint flags,UIntPtr cookie);
  [DllImport("kernel32.dll")] static extern void ReleaseActCtx(IntPtr context);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibrary(string path);
  [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern uint GetModuleFileName(IntPtr module,StringBuilder path,int size);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool SetDllDirectory(string path);
  [DllImport("kernel32.dll")] static extern uint SetErrorMode(uint mode);
  static IntPtr context; static UIntPtr cookie;
  public static void Begin(string exe,string directory) {
   SetErrorMode(0x8003);
   if(!SetDllDirectory(directory)) throw new Win32Exception(Marshal.GetLastWin32Error());
   ACTCTX a=new ACTCTX(); a.cbSize=Marshal.SizeOf(typeof(ACTCTX));
   a.flags=12; a.source=exe; a.assemblyDir=directory; a.resource=new IntPtr(1);
   context=CreateActCtx(ref a);
   if(context==new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Application manifest activation failed");
   if(!ActivateActCtx(context,out cookie)) throw new Win32Exception(Marshal.GetLastWin32Error());
  }
  public static string Load(string path) {
   IntPtr module=LoadLibrary(path);
   if(module==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),path);
   try {var resolved=new StringBuilder(32768); GetModuleFileName(module,resolved,resolved.Capacity); return resolved.ToString();}
   finally {FreeLibrary(module);}
  }
  public static void End() {
   if(cookie!=UIntPtr.Zero) DeactivateActCtx(0,cookie);
   if(context!=IntPtr.Zero && context!=new IntPtr(-1)) ReleaseActCtx(context);
   SetDllDirectory(null);
  }
 }
}
'@
    $ProgramDir=[IO.Path]::GetFullPath($ProgramDir)
    foreach($assembly in @('CRT','MFC','MFCLOC')) {
        $assemblyDir=Join-Path $ProgramDir ('Microsoft.VC80.'+$assembly)
        [xml]$manifest=Get-Content -LiteralPath (Join-Path $assemblyDir ('Microsoft.VC80.'+$assembly+'.manifest')) -Raw
        foreach($member in $manifest.assembly.file) {
            if(-not(Test-Path -LiteralPath (Join-Path $assemblyDir $member.name))){throw ('Bundled runtime file is missing: '+$member.name)}
        }
    }
    [UV1780.NativeLoader]::Begin((Join-Path $ProgramDir 'UVProbe.exe'),$ProgramDir)
    $libraries=@('Microsoft.VC80.CRT\msvcr80.dll','Microsoft.VC80.CRT\msvcp80.dll','Microsoft.VC80.MFC\mfc80.dll','Microsoft.VC80.MFC\mfc80u.dll') | ForEach-Object {Join-Path $ProgramDir $_}
    if(-not $RuntimeOnly) {
        $components=Get-Content -LiteralPath $ComponentsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $libraries+=@($components | Where-Object {$_.file -notmatch '\\' -and [IO.Path]::GetExtension($_.file) -in @('.dll','.ocx') -and $_.file -ne 'SkyPDFWriterLib.dll'} | ForEach-Object {Join-Path $ProgramDir $_.file})
        if($AuthenticationPath){$libraries+=$AuthenticationPath}
    }
    foreach($library in $libraries) {
        try {$resolved=[UV1780.NativeLoader]::Load($library);$report.Loaded+=$library;$report.Resolved += [ordered]@{Requested=$library;Path=$resolved}}
        catch {$report.Failures += [ordered]@{File=$library;Error=$_.Exception.GetBaseException().Message}}
    }
    if($report.Failures.Count){throw ('Native dependency checks failed for '+$report.Failures.Count+' libraries.')}
    $report.Status='success'
} catch {$report.Status='error';$report.Failures += [ordered]@{File='probe';Error=$_.Exception.GetBaseException().Message}}
finally {
    if('UV1780.NativeLoader' -as [type]){[UV1780.NativeLoader]::End()}
    $report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $ReportPath -Encoding UTF8
}
if($report.Status -ne 'success'){exit 1}
exit 0
