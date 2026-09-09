; ============================================================================
; OMNIX — per-user native Office installer
;
; Microsoft-documented VSTO discovery path used by this installer:
;   HKCU\Software\Microsoft\Office\<Application>\Addins\OMNIX
;
; IMPORTANT:
;   * Do NOT put VSTO registration under Office\16.0\... or Office\15.0\...
;   * Detect actual Excel/Word/PowerPoint executables before registration.
;   * Register only OMNIX-owned keys.
;   * Never clear Office Resiliency/DisabledItems/CrashingAddinList.
;   * Never change Trust Center or bypass Office policy.
; ============================================================================

#define MyAppName "OMNIX"
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0-dev"
#endif
#define MyAppPublisher "Mr Ali"

[Setup]
AppId={{D5F28A04-617E-4C29-8F5D-A014E8C6B537}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\OMNIX
DisableDirPage=yes
DefaultGroupName=OMNIX
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=OMNIX-Setup-{#MyAppVersion}
SetupIconFile=..\build\omni.ico
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=no
UninstallDisplayIcon={app}\OMNIX.Excel.dll
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "payload\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "vstor_redist.exe"
#if FileExists(AddBackslash(SourcePath) + "payload\vstor_redist.exe")
Source: "payload\vstor_redist.exe"; DestDir: "{tmp}"; Flags: dontcopy
#endif

[Icons]
Name: "{group}\Rescan Office Integration"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -File ""{app}\office-registration-maintenance.ps1"" -InstallDir ""{app}"""; WorkingDir: "{app}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  CanonicalRegAddinsFmt = 'Software\Microsoft\Office\%0:s\Addins\OMNIX';
  LegacyRegAddinsFmt    = 'Software\Microsoft\Office\%0:s\%1:s\Addins\OMNIX';
  TrustedPubStore       = 'TrustedPublisher';
  RootStore             = 'Root';
  MaintenanceTaskName   = 'OMNIX Office Registration Maintenance';

var
  HostList: TStringList;
  PrerequisiteFailed: Boolean;
  VstoRestartNeeded: Boolean;
  MaintenanceTaskInstalled: Boolean;

procedure InstallLog(const Line: String);
var
  LogDir, Full: String;
begin
  try
    LogDir := ExpandConstant('{localappdata}') + '\OMNIX\logs';
    ForceDirectories(LogDir);
    Full := LogDir + '\install-debug.log';
    SaveStringToFile(Full, GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + '  ' + Line + #13#10, True);
  except
  end;
end;

function B2S(B: Boolean): String;
begin
  if B then Result := 'yes' else Result := 'no';
end;

function HostExeName(const Host: String): String;
begin
  if CompareText(Host, 'Excel') = 0 then Result := 'EXCEL.EXE'
  else if CompareText(Host, 'Word') = 0 then Result := 'WINWORD.EXE'
  else if CompareText(Host, 'PowerPoint') = 0 then Result := 'POWERPNT.EXE'
  else Result := '';
end;

function HostsSummary(): String;
var I: Integer;
begin
  Result := '';
  if HostList = nil then exit;
  for I := 0 to HostList.Count - 1 do
  begin
    if I > 0 then Result := Result + ', ';
    Result := Result + HostList[I];
  end;
end;

function IsProcessRunning(const ImageName: String): Boolean;
var ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'),
       '/C tasklist /FI "IMAGENAME eq ' + ImageName + '" | find /I "' + ImageName + '" >nul',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0);
end;

function RegistryAppPathExists(const Exe: String): Boolean;
var P: String;
begin
  Result := False;
  if RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + Exe, '', P) or
     RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + Exe, '', P) or
     RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\App Paths\' + Exe, '', P) then
    Result := FileExists(RemoveQuotes(P));
end;

function IsHostInstalled(const Host: String): Boolean;
var Exe: String;
begin
  Exe := HostExeName(Host);
  Result := False;
  if Exe = '' then exit;

  if RegistryAppPathExists(Exe) then
  begin
    Result := True;
    exit;
  end;

  Result :=
    FileExists(ExpandConstant('{pf64}\Microsoft Office\root\Office16\' + Exe)) or
    FileExists(ExpandConstant('{pf32}\Microsoft Office\root\Office16\' + Exe)) or
    FileExists(ExpandConstant('{pf64}\Microsoft Office\Office16\' + Exe)) or
    FileExists(ExpandConstant('{pf32}\Microsoft Office\Office16\' + Exe)) or
    FileExists(ExpandConstant('{pf64}\Microsoft Office\Office15\' + Exe)) or
    FileExists(ExpandConstant('{pf32}\Microsoft Office\Office15\' + Exe));
end;

procedure DetectHosts();
begin
  if HostList <> nil then HostList.Free;
  HostList := TStringList.Create;
  if IsHostInstalled('Excel') then HostList.Add('Excel');
  if IsHostInstalled('Word') then HostList.Add('Word');
  if IsHostInstalled('PowerPoint') then HostList.Add('PowerPoint');
  InstallLog('Detected supported Office hosts: ' + HostsSummary());
end;

function VstoRuntimeInstalled(): Boolean;
var Ver: String;
begin
  Result :=
    RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\VSTO Runtime Setup\v4R', 'Version', Ver) or
    RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\VSTO Runtime Setup\v4R', 'Version', Ver);
  InstallLog('VSTO Runtime present=' + B2S(Result));
end;

procedure PreserveOfficeResiliencyState();
begin
  InstallLog('Office Resiliency state preserved unchanged.');
end;

procedure RemoveHostRegistration(const Host: String);
var Key: String;
begin
  Key := Format(CanonicalRegAddinsFmt, [Host]);
  if RegKeyExists(HKCU, Key) then
  begin
    RegDeleteKeyIncludingSubkeys(HKCU, Key);
    InstallLog('Removed canonical OMNIX key: HKCU\' + Key);
  end;

  Key := Format(LegacyRegAddinsFmt, ['16.0', Host]);
  if RegKeyExists(HKCU, Key) then RegDeleteKeyIncludingSubkeys(HKCU, Key);
  Key := Format(LegacyRegAddinsFmt, ['15.0', Host]);
  if RegKeyExists(HKCU, Key) then RegDeleteKeyIncludingSubkeys(HKCU, Key);
end;

procedure RemoveAddinRegistry();
begin
  RemoveHostRegistration('Excel');
  RemoveHostRegistration('Word');
  RemoveHostRegistration('PowerPoint');
end;

function ManifestUri(const Host: String): String;
var P: String;
begin
  P := ExpandConstant('{app}') + '\OMNIX.' + Host + '.vsto';
  StringChange(P, '\', '/');
  Result := 'file:///' + P + '|vstolocal';
end;

function RegisterHost(const Host: String): Boolean;
var Key, Manifest, ReadBack: String; LoadReadBack: Cardinal;
begin
  Result := False;
  if not IsHostInstalled(Host) then exit;
  if not FileExists(ExpandConstant('{app}') + '\OMNIX.' + Host + '.vsto') then
  begin
    InstallLog('REGISTRATION_ERROR [' + Host + ']: deployment manifest is missing.');
    exit;
  end;

  RemoveHostRegistration(Host);
  Key := Format(CanonicalRegAddinsFmt, [Host]);
  Manifest := ManifestUri(Host);

  RegWriteStringValue(HKCU, Key, 'Description', 'OMNIX AI Office');
  RegWriteStringValue(HKCU, Key, 'FriendlyName', 'OMNIX');
  RegWriteDWordValue(HKCU, Key, 'LoadBehavior', 3);
  RegWriteStringValue(HKCU, Key, 'Manifest', Manifest);

  if not RegQueryStringValue(HKCU, Key, 'Manifest', ReadBack) then exit;
  if not RegQueryDWordValue(HKCU, Key, 'LoadBehavior', LoadReadBack) then exit;

  Result := (CompareText(ReadBack, Manifest) = 0) and (LoadReadBack = 3);
  InstallLog('Canonical VSTO registration [' + Host + '] path=HKCU\' + Key + ' manifest=' + ReadBack + ' load=' + IntToStr(LoadReadBack) + ' pass=' + B2S(Result));
end;

procedure RemoveMaintenanceTask();
var ResultCode: Integer; Helper: String;
begin
  Helper := ExpandConstant('{app}') + '\install-maintenance-task.ps1';
  if FileExists(Helper) then
  begin
    Exec('powershell.exe', '-NoProfile -NonInteractive -File "' + Helper + '" -InstallDir "' + ExpandConstant('{app}') + '" -Remove', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if ResultCode = 0 then exit;
  end;
  Exec(ExpandConstant('{sys}') + '\schtasks.exe', '/Delete /TN "' + MaintenanceTaskName + '" /F', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

function InstallMaintenanceTask(): Boolean;
var ResultCode: Integer; Helper: String;
begin
  Result := False;
  Helper := ExpandConstant('{app}') + '\install-maintenance-task.ps1';
  if not FileExists(Helper) then exit;
  Exec('powershell.exe', '-NoProfile -NonInteractive -File "' + Helper + '" -InstallDir "' + ExpandConstant('{app}') + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0);
  InstallLog('Maintenance task install exit=' + IntToStr(ResultCode));
end;

function RunRegistrationMaintenance(): Boolean;
var ResultCode: Integer; ScriptPath: String;
begin
  Result := False;
  ScriptPath := ExpandConstant('{app}') + '\office-registration-maintenance.ps1';
  if not FileExists(ScriptPath) then exit;
  Exec('powershell.exe', '-NoProfile -NonInteractive -File "' + ScriptPath + '" -InstallDir "' + ExpandConstant('{app}') + '" -Quiet', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0);
  InstallLog('Immediate registration maintenance exit=' + IntToStr(ResultCode));
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  HostList := nil;
  PrerequisiteFailed := False;
  VstoRestartNeeded := False;
  MaintenanceTaskInstalled := False;

  ForceDirectories(ExpandConstant('{localappdata}') + '\OMNIX\logs');
  InstallLog('=== OMNIX setup initialized ({#MyAppVersion}) ===');

  if IsProcessRunning('excel.exe') or IsProcessRunning('winword.exe') or IsProcessRunning('powerpnt.exe') then
  begin
    if MsgBox('Close Excel, Word and PowerPoint before installing OMNIX, then press OK.', mbInformation, MB_OKCANCEL) = IDCANCEL then
      Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  try
    DetectHosts();
    if HostList.Count = 0 then
    begin
      Result := 'No supported desktop Excel, Word or PowerPoint installation was detected.';
      exit;
    end;
    InstallLog('PrepareToInstall hosts=[' + HostsSummary() + ']');
  except
    Result := 'OMNIX could not detect Microsoft Office: ' + GetExceptionMessage;
    InstallLog('OFFICE_DETECTION_ERROR: ' + GetExceptionMessage);
  end;
end;

function UpdateReadyMemo(const Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := 'Office hosts detected: ' + HostsSummary() + NewLine +
            'VSTO registration: HKCU\Software\Microsoft\Office\<Host>\Addins\OMNIX' + NewLine +
            'Install folder: ' + ExpandConstant('{localappdata}') + '\Programs\OMNIX' + NewLine + NewLine +
            'OMNIX modifies only its own add-in registration. Office Trust Center and Resiliency remain unchanged.' + NewLine;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  I, ResultCode, CertClassResult: Integer;
  AllOk: Boolean;
  VstoExe, CertPath, CertClassifier, CertMarker, DevThumbprintText: String;
  DevThumbprintRaw: AnsiString;
begin
  if CurStep = ssInstall then
  begin
    InstallLog('=== OMNIX install begin ===');
    RemoveMaintenanceTask();
    RemoveAddinRegistry();
    PreserveOfficeResiliencyState();

    if DirExists(ExpandConstant('{app}')) then DelTree(ExpandConstant('{app}'), True, True, True);

    if not VstoRuntimeInstalled() then
    begin
      try ExtractTemporaryFile('vstor_redist.exe'); except end;
      VstoExe := ExpandConstant('{tmp}') + '\vstor_redist.exe';
      if FileExists(VstoExe) then
      begin
        if not ShellExec('runas', VstoExe, '/q /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
        begin
          PrerequisiteFailed := True;
          InstallLog('VSTO Runtime UAC/install launch failed.');
        end
        else
        begin
          InstallLog('VSTO Runtime installer exit=' + IntToStr(ResultCode));
          if (ResultCode <> 0) and (ResultCode <> 3010) then PrerequisiteFailed := True;
          if ResultCode = 3010 then VstoRestartNeeded := True;
        end;
      end
      else
      begin
        PrerequisiteFailed := True;
        InstallLog('PREREQUISITE_ERROR: bundled vstor_redist.exe missing.');
      end;
    end;
  end;

  if CurStep = ssPostInstall then
  begin
    AllOk := not PrerequisiteFailed;

    CertPath := ExpandConstant('{app}') + '\OMNIX.cer';
    CertClassifier := ExpandConstant('{app}') + '\classify-dev-cert.ps1';
    CertMarker := ExpandConstant('{app}') + '\dev-cert-thumbprint.txt';
    DeleteFile(CertMarker);

    if FileExists(CertPath) and FileExists(CertClassifier) then
    begin
      Exec('powershell.exe', '-NoProfile -File "' + CertClassifier + '" -CertPath "' + CertPath + '" -OutputPath "' + CertMarker + '"', '', SW_HIDE, ewWaitUntilTerminated, CertClassResult);
      if CertClassResult = 0 then
      begin
        DevThumbprintRaw := '';
        if LoadStringFromFile(CertMarker, DevThumbprintRaw) then DevThumbprintText := Trim(DevThumbprintRaw) else DevThumbprintText := '';
        if DevThumbprintText = '' then AllOk := False
        else
        begin
          Exec(ExpandConstant('{cmd}'), '/C certutil -f -user -addstore ' + TrustedPubStore + ' "' + CertPath + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
          if ResultCode <> 0 then AllOk := False;
          Exec(ExpandConstant('{cmd}'), '/C certutil -f -user -addstore ' + RootStore + ' "' + CertPath + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
          if ResultCode <> 0 then AllOk := False;
        end;
      end
      else if CertClassResult = 2 then
        InstallLog('CA/non-self-signed publisher certificate detected: no OMNIX trust-store modification performed.')
      else
        AllOk := False;
    end
    else
    begin
      InstallLog('CERTIFICATE_ERROR: OMNIX.cer/classifier missing.');
      AllOk := False;
    end;

    for I := 0 to HostList.Count - 1 do
      if not RegisterHost(HostList[I]) then AllOk := False;

    if not RunRegistrationMaintenance() then AllOk := False;

    MaintenanceTaskInstalled := InstallMaintenanceTask();
    if not MaintenanceTaskInstalled then
      InstallLog('MAINTENANCE_WARNING: optional current-user re-scan task was not installed.');

    if AllOk and (not VstoRestartNeeded) then
    begin
      if FileExists(ExpandConstant('{app}') + '\post-install-verify.ps1') then
      begin
        Exec('powershell.exe', '-NoProfile -File "' + ExpandConstant('{app}') + '\post-install-verify.ps1"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
        InstallLog('post-install-verify exit=' + IntToStr(ResultCode));
        if ResultCode <> 0 then AllOk := False;
      end;
    end;

    InstallLog('=== OMNIX install end verified=' + B2S(AllOk) + ' restart=' + B2S(VstoRestartNeeded) + ' ===');

    if not AllOk then
      MsgBox('OMNIX files were installed, but Office add-in verification FAILED.' #13#10#13#10 +
             'See ' + ExpandConstant('{localappdata}') + '\OMNIX\logs\install-debug.log', mbError, MB_OK)
    else if VstoRestartNeeded then
      MsgBox('OMNIX was installed. Restart Windows before the first Office test because the Microsoft VSTO Runtime requested a restart.', mbInformation, MB_OK)
    else
      MsgBox('OMNIX was installed and registered for: ' + HostsSummary() + #13#10#13#10 +
             'Open Excel, Word or PowerPoint. The OMNIX Ribbon tab should load automatically.', mbInformation, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  CertMarker, DevThumbprintText: String;
  DevThumbprintRaw: AnsiString;
begin
  if CurUninstallStep = usUninstall then
  begin
    RemoveMaintenanceTask();
    RemoveAddinRegistry();
    PreserveOfficeResiliencyState();

    CertMarker := ExpandConstant('{app}') + '\dev-cert-thumbprint.txt';
    DevThumbprintRaw := '';
    DevThumbprintText := '';
    if FileExists(CertMarker) and LoadStringFromFile(CertMarker, DevThumbprintRaw) then
    begin
      DevThumbprintText := Trim(DevThumbprintRaw);
      if DevThumbprintText <> '' then
      begin
        Exec(ExpandConstant('{cmd}'), '/C certutil -user -delstore ' + TrustedPubStore + ' "' + DevThumbprintText + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
        Exec(ExpandConstant('{cmd}'), '/C certutil -user -delstore ' + RootStore + ' "' + DevThumbprintText + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      end;
    end;

    InstallLog('=== OMNIX uninstall: canonical + legacy OMNIX registration removed; Office Resiliency preserved ===');
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    if MsgBox('Also remove OMNIX settings and chat history (' + ExpandConstant('{localappdata}') + '\OMNIX)?' + #13#10 +
              'Choose Yes only if you do NOT plan to reinstall.', mbConfirmation, MB_YESNO) = IDYES then
      DelTree(ExpandConstant('{localappdata}') + '\OMNIX', True, True, True);
  end;
end;
