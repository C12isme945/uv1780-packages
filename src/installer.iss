#define AppVersion "2.70.2"
[Setup]
AppId={{10CCA6F8-7800-4701-BA18-DF03B34EE370}
AppName=UV-1780 一键部署（UVProbe 2.70）
AppVersion={#AppVersion}
AppPublisher=本地迁移部署包（非岛津官方安装程序）
DefaultDirName={autopf32}\Shimadzu\UVProbe
DefaultGroupName=UVProbe 2.70
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableReadyPage=yes
WizardStyle=modern
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline
MinVersion=10.0.10240
ArchitecturesAllowed=x86 x64os
Uninstallable=no
CreateUninstallRegKey=no
CloseApplications=no
RestartApplications=no
AlwaysRestart=no
Compression=lzma2
SolidCompression=yes
OutputDir=..\..\outputs\UV1780_一键安装包
OutputBaseFilename=UV1780_UVProbe270_Setup
SetupLogging=yes
InfoBeforeFile=install-notice.txt
VersionInfoDescription=UV1780 UVProbe 2.70 offline deployment
VersionInfoVersion=2.70.2.0
SetupMutex=UV1780DeploymentSetup

[Messages]
SetupWindowTitle=UV-1780 一键部署
SetupAppTitle=UV-1780 一键部署
ButtonBack=< 上一步
ButtonNext=下一步 >
ButtonInstall=安装
ButtonCancel=取消
ButtonFinish=完成
FinishedHeadingLabel=部署完成
FinishedLabel=UVProbe 2.70 程序已部署。选择预装时可以不接仪器。%n%n接上仪器并进入 PC Control 后，先运行桌面“UV1780 检测并配置设备”，再打开 UVProbe，按 F9 连接。软件安装成功不代表仪器已连接成功。
InfoBeforeLabel=这是您提供的软件副本的离线部署包，适用于有相应授权的电脑。
InfoBeforeClickLabel=请阅读下面的适用范围，然后点击“下一步”。
InstallingLabel=正在部署 UVProbe 2.70，请稍候…
StatusExtractFiles=正在安装程序文件…
StatusRunProgram=正在配置运行组件…
SetupLdrStartupMessage=正在准备 UV-1780 安装程序…

[Files]
Source: "payload\*"; DestDir: "{tmp}\UV1780Payload"; Flags: dontcopy recursesubdirs createallsubdirs
Source: "payload\program\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "UV1780-Deploy.ps1"; DestDir: "{app}\Deployment"; Flags: ignoreversion
Source: "Test-NativeRuntime.ps1"; DestDir: "{app}\Deployment"; Flags: ignoreversion
Source: "payload\components.json"; DestDir: "{app}\Deployment"; Flags: ignoreversion
Source: "payload\settings.json"; DestDir: "{app}\Deployment"; Flags: ignoreversion
Source: "使用说明.txt"; DestDir: "{app}\Deployment"; Flags: ignoreversion

[Icons]
Name: "{commondesktop}\UVProbe 2.70"; Filename: "{app}\UVProbe.exe"; WorkingDir: "{app}"
Name: "{commondesktop}\UV1780 检测并配置设备"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Deployment\UV1780-Deploy.ps1"" -Mode Configure -Interactive -ProgramDir ""{app}"""; WorkingDir: "{app}"; IconFilename: "{app}\UVProbe.exe"
Name: "{group}\UVProbe 2.70"; Filename: "{app}\UVProbe.exe"; WorkingDir: "{app}"
Name: "{group}\检测并配置设备"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Deployment\UV1780-Deploy.ps1"" -Mode Configure -Interactive -ProgramDir ""{app}"""; WorkingDir: "{app}"
Name: "{group}\检查程序完整性"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Deployment\UV1780-Deploy.ps1"" -Mode Check -Interactive -ProgramDir ""{app}"""; WorkingDir: "{app}"
Name: "{group}\使用说明"; Filename: "{app}\Deployment\使用说明.txt"

[Code]
var
  ModePage: TInputOptionWizardPage;
  Prepared: Boolean;
  VerifyExitCode: Integer;
  RebootPending: Boolean;

procedure DeploymentOutput(const S: String; const Error, FirstLine: Boolean);
begin
  Log('Deployment: ' + S);
end;

function NeedRestart: Boolean;
begin
  Result := RebootPending;
end;

function IsPreinstall: Boolean;
begin
  Result := ModePage.SelectedValueIndex = 0;
  if ExpandConstant('{param:PREINSTALL|}') = '1' then Result := True;
end;

function DeployParameters(Mode: String): String;
begin
  Result := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\UV1780Payload\UV1780-Deploy.ps1') + '" -Mode ' + Mode +
    ' -ProgramDir "' + ExpandConstant('{app}') + '" -PayloadRoot "' + ExpandConstant('{tmp}\UV1780Payload') + '"';
  if IsPreinstall then Result := Result + ' -Preinstall';
end;

procedure InitializeWizard;
begin
  Prepared := False;
  ModePage := CreateInputOptionPage(wpInfoBefore, '选择安装方式', '不插仪器，也可以先预装软件。',
    '本包适用于 UV-1780，默认仪器编号为 A11916031761。安装不会启动测量。', True, False);
  ModePage.Add('仅预装软件和驱动（无需连接仪器）');
  ModePage.Add('安装软件，并检测已连接的串口');
  ModePage.SelectedValueIndex := 0;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = ModePage.ID then WizardForm.NextButton.Caption := '安装';
end;

function InitializeSetup: Boolean;
var
  ExitCode: Integer;
  Params: String;
begin
  Result := True;
  if ExpandConstant('{param:VERIFYONLY|0}') = '1' then begin
    ExtractTemporaryFiles('{tmp}\UV1780Payload\*');
    Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\UV1780Payload\UV1780-Deploy.ps1') +
      '" -Mode Verify -PayloadRoot "' + ExpandConstant('{tmp}\UV1780Payload') + '"';
    if ExpandConstant('{param:VERIFYREPORT|}') <> '' then
      Params := Params + ' -ReportPath "' + ExpandConstant('{param:VERIFYREPORT|}') + '"';
    if ExecAndLogOutput(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), Params, '', SW_HIDE, ewWaitUntilTerminated, ExitCode, @DeploymentOutput) then
      VerifyExitCode := ExitCode
    else VerifyExitCode := 99;
    Result := False;
    exit;
  end;
  if GetEnv('PROCESSOR_ARCHITECTURE') = 'ARM64' then begin
    MsgBox('此包需要 Intel/AMD 的 Windows 10/11，不支持 ARM 版 Windows。', mbError, MB_OK);
    Result := False;
  end;
  if GetEnv('PROCESSOR_ARCHITEW6432') = 'ARM64' then begin
    MsgBox('此包不支持 ARM 版 Windows。', mbError, MB_OK);
    Result := False;
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := VerifyExitCode;
  if (Result = 0) and RebootPending then Result := 3010;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
begin
  Result := '';
  if Prepared then exit;
  WizardForm.StatusLabel.Caption := '正在检查文件并准备运行库、认证组件及串口驱动…';
  ExtractTemporaryFiles('{tmp}\UV1780Payload\*');
  if not ExecAndLogOutput(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), DeployParameters('Preflight'), '', SW_HIDE, ewWaitUntilTerminated, ExitCode, @DeploymentOutput) then begin
    Result := '无法启动系统安装组件。请确认此电脑带有系统自带的 Windows PowerShell 5.x。';
    exit;
  end;
  if ExitCode = 3010 then RebootPending := True;
  if (ExitCode <> 0) and (ExitCode <> 3010) then begin
    Result := '部署前检查未通过。请先关闭 UVProbe；详细原因见 ' + ExpandConstant('{commonappdata}\UV1780Deployment\Preflight-result.json') + '。修正原因后可重新运行安装包。';
    exit;
  end;
  Prepared := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
begin
  if CurStep = ssPostInstall then begin
    WizardForm.StatusLabel.Caption := '正在注册 UV-1780 控制组件并保存设置…';
    if not ExecAndLogOutput(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'), DeployParameters('Install'), '', SW_HIDE, ewWaitUntilTerminated, ExitCode, @DeploymentOutput) then
      RaiseException('无法运行部署组件。');
    if ExitCode = 3010 then RebootPending := True;
    if (ExitCode <> 0) and (ExitCode <> 3010) then
      RaiseException('组件配置未完成，请查看 ' + ExpandConstant('{commonappdata}\UV1780Deployment\Install-result.json') + '，修正原因后重新运行安装包修复。');
  end;
end;
