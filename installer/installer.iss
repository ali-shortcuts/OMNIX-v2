; ============================================================================
; OMNIX — production-oriented per-user installer (Inno Setup 6.3+)
;
; Safety / correctness rules:
;   * Detect Office before registration; never guess a host that is not present.
;   * Register only OMNIX-owned add-in keys.
;   * NEVER clear Office Resiliency/DisabledItems/CrashingAddinList globally.
;   * Never bypass Office/Windows policy. User-authorized install only.
;   * Verify all installed Office hosts after registration and log exact failures.
;   * Trust-store changes are development-only: only an exact self-signed OMNIX
;     development certificate may be imported, and uninstall removes only its
;     recorded thumbprint. A CA-signed production cert is never root-imported.
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
; Three VSTO hosts + shared core + verification/trust-classifier scripts staged by the build pipeline.
Source: "payload\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "vstor_redist.exe"

#if FileExists(AddBackslash(SourcePath) + "payload\vstor_redist.exe")
Source: "payload\vstor_redist.exe"; DestDir: "{tmp}"; Flags: dontcopy
#endif

[Icons]
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  RegAddinsFmt    = 'Software\Microsoft\Office\%0:s\%1:s\Addins\OMNIX';
  TrustedPubStore = 'TrustedPublisher';
  RootStore       = 'Root';

var
  DetectedPlatform: String;
  DetectedOfficeVersion: String;
  HostList: TStringList;
  VersionList: TStringList;
  NeedVstoX64: Boolean;
  NeedVstoX86: Boolean;
  VstoRestartNeeded: Boolean;
  PrerequisiteFailed: Boolean;

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

function HostsSummary(): String;
var
  I: Integer;
begin
  Result := '';
  if HostList = nil then exit;
  for I := 0 to HostList.Count - 1 do
  begin
    if I > 0 then Result := Result + ', ';
    Result := Result + HostList[I];
  end;
end;

function HostExeName(const Host: String): String;
begin
  if CompareText(Host, 'Excel') = 0 then Result := 'EXCEL.EXE'
  else if CompareText(Host, 'Word') = 0 then Result := 'WINWORD.EXE'
  else if CompareText(Host, 'PowerPoint') = 0 then Result := 'POWERPNT.EXE'
  else Result := '';
end;

function DetectOfficePlatform: String;
var
  S: String;
begin
  Result := '';

  if RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'Platform', S) then
    Result := Lowercase(S)
  else if RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'Platform', S) then
    Result := Lowercase(S)
  else if FileExists(ExpandConstant('{pf64}\Microsoft Office\root\Office16\EXCEL.EXE')) or
          FileExists(ExpandConstant('{pf64}\Microsoft Office\root\Office16\WINWORD.EXE')) or
          FileExists(ExpandConstant('{pf64}\Microsoft Office\root\Office16\POWERPNT.EXE')) then
    Result := 'x64'
  else if FileExists(ExpandConstant('{pf32}\Microsoft Office\root\Office16\EXCEL.EXE')) or
          FileExists(ExpandConstant('{pf32}\Microsoft Office\root\Office16\WINWORD.EXE')) or
          FileExists(ExpandConstant('{pf32}\Microsoft Office\root\Office16\POWERPNT.EXE')) then
    Result := 'x86'
  else if DirExists(ExpandConstant('{pf64}\Microsoft Office')) then
    Result := 'x64'
  else if DirExists(ExpandConstant('{pf32}\Microsoft Office')) then
    Result := 'x86';

  InstallLog('Office platform detected: ' + Result);
end;

function VersionFromClientVersion(const S: String): String;
var
  P, Major: Integer;
  M: String;
begin
  Result := '';
  P := Pos('.', S);
  if P > 1 then M := Copy(S, 1, P - 1) else M := S;
  Major := StrToIntDef(M, 0);
  if Major = 16 then Result := '16.0'
  else if Major = 15 then Result := '15.0';
end;

function DetectOfficeVersion: String;
var
  S: String;
begin
  Result := '';

  if RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'ClientVersionToReport', S) then
    Result := VersionFromClientVersion(S)
  else if RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'ClientVersionToReport', S) then
    Result := VersionFromClientVersion(S);

  if Result = '' then
  begin
    if RegKeyExists(HKLM64, 'SOFTWARE\Microsoft\Office\16.0\Common') or
       RegKeyExists(HKLM32, 'SOFTWARE\Microsoft\Office\16.0\Common') or
       RegKeyExists(HKCU, 'Software\Microsoft\Office\16.0\Common') then
      Result := '16.0'
    else if RegKeyExists(HKLM64, 'SOFTWARE\Microsoft\Office\15.0\Common') or
            RegKeyExists(HKLM32, 'SOFTWARE\Microsoft\Office\15.0\Common') or
            RegKeyExists(HKCU, 'Software\Microsoft\Office\15.0\Common') then
      Result := '15.0';
  end;

  InstallLog('Office version detected: ' + Result);
end;

function IsVersionPresent(const Version: String): Boolean;
begin
  Result :=
    (CompareText(DetectedOfficeVersion, Version) = 0) or
    RegKeyExists(HKCU, 'Software\Microsoft\Office\' + Version + '\Common') or
    RegKeyExists(HKLM64, 'SOFTWARE\Microsoft\Office\' + Version + '\Common') or
    RegKeyExists(HKLM32, 'SOFTWARE\Microsoft\Office\' + Version + '\Common');
end;

function IsHostInstalled(const Host: String; const Version: String): Boolean;
var
  Exe, S: String;
begin
  Result := False;

  if RegKeyExists(HKCU, 'Software\Microsoft\Office\' + Version + '\' + Host) or
     RegKeyExists(HKLM64, 'SOFTWARE\Microsoft\Office\' + Version + '\' + Host) or
     RegKeyExists(HKLM32, 'SOFTWARE\Microsoft\Office\' + Version + '\' + Host) then
  begin
    Result := True;
    exit;
  end;

  if CompareText(DetectedOfficeVersion, Version) <> 0 then exit;

  Exe := HostExeName(Host);
  if Exe = '' then exit;

  if RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + Exe, '', S) or
     RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + Exe, '', S) then
  begin
    if FileExists(S) then
    begin
      Result := True;
      exit;
    end;
  end;

  Result :=
    FileExists(ExpandConstant('{pf64}\Microsoft Office\root\Office16\' + Exe)) or
    FileExists(ExpandConstant('{pf32}\Microsoft Office\root\Office16\' + Exe)) or
    FileExists(ExpandConstant('{pf64}\Microsoft Office\Office16\' + Exe)) or
    FileExists(ExpandConstant('{pf32}\Microsoft Office\Office16\' + Exe)) or
    FileExists(ExpandConstant('{pf64}\Microsoft Office\Office15\' + Exe)) or
    FileExists(ExpandConstant('{pf32}\Microsoft Office\Office15\' + Exe));
end;

function HostDetected(const Host: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  if VersionList = nil then exit;
  for I := 0 to VersionList.Count - 1 do
  begin
    if IsHostInstalled(Host, VersionList[I]) then
    begin
      Result := True;
      exit;
    end;
  end;
end;

function VstoRuntimeInstalled(const BitView: Integer): Boolean;
var
  Ver: String;
begin
  Result := RegQueryStringValue(BitView, 'SOFTWARE\Microsoft\VSTO Runtime Setup\v4R', 'Version', Ver);
  InstallLog('VSTO Runtime check (registry view ' + IntToStr(BitView) + '): found=' + B2S(Result) + ' version=' + Ver);
end;

procedure RemoveAddinRegistry();
var
  I, J: Integer;
  Key: String;
  Versions, Hosts: array of String;
begin
  SetArrayLength(Versions, 2); Versions[0] := '16.0'; Versions[1] := '15.0';
  SetArrayLength(Hosts, 3); Hosts[0] := 'Excel'; Hosts[1] := 'Word'; Hosts[2] := 'PowerPoint';

  for I := 0 to GetArrayLength(Versions) - 1 do
    for J := 0 to GetArrayLength(Hosts) - 1 do
    begin
      Key := Format(RegAddinsFmt, [Versions[I], Hosts[J]]);
      if RegKeyExists(HKCU, Key) then
      begin
        RegDeleteKeyIncludingSubkeys(HKCU, Key);
        InstallLog('Removed OMNIX-owned registry key: HKCU\' + Key);
      end;
    end;
end;

procedure PreserveOfficeResiliencyState();
begin
  InstallLog('Office Resiliency state preserved unchanged (no global DisabledItems cleanup).');
end;

function IsProcessRunning(const ImageName: String): Boolean;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'),
       '/C tasklist /FI "IMAGENAME eq ' + ImageName + '" | find /I "' + ImageName + '" >nul',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0);
end;

function NeedRestart(): Boolean;
begin
  Result := VstoRestartNeeded;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  PrerequisiteFailed := False;
  VstoRestartNeeded := False;

  ForceDirectories(ExpandConstant('{localappdata}') + '\OMNIX\logs');
  InstallLog('=== OMNIX setup initialized (version {#MyAppVersion}) ===');

  try
    if IsProcessRunning('excel.exe') or IsProcessRunning('winword.exe') or IsProcessRunning('powerpnt.exe') then
    begin
      if MsgBox('Microsoft Office is currently running.' #13#10#13#10 +
                'Please close Excel, Word and PowerPoint before installing OMNIX, then press OK to continue.',
                mbInformation, MB_OKCANCEL) = IDCANCEL then
        Result := False;
    end;
  except
    InstallLog('WARNING: Office running-state check failed: ' + GetExceptionMessage);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Hosts, Versions: String;
  I: Integer;
begin
  Result := '';
  try
    DetectedPlatform := DetectOfficePlatform;
    DetectedOfficeVersion := DetectOfficeVersion;

    if DetectedPlatform = '' then
    begin
      InstallLog('OFFICE_DETECTION_ERROR: Office platform could not be detected.');
      Result := 'Microsoft Office (Excel, Word or PowerPoint) was not detected on this system.';
      exit;
    end;

    HostList := TStringList.Create;
    VersionList := TStringList.Create;

    if IsVersionPresent('16.0') then VersionList.Add('16.0');
    if IsVersionPresent('15.0') then VersionList.Add('15.0');
    if (VersionList.Count = 0) and (DetectedOfficeVersion <> '') then VersionList.Add(DetectedOfficeVersion);

    if HostDetected('Excel') then HostList.Add('Excel');
    if HostDetected('Word') then HostList.Add('Word');
    if HostDetected('PowerPoint') then HostList.Add('PowerPoint');

    InstallLog('Hosts found: ' + HostsSummary() +
               ' | versions: 16.0=' + B2S(VersionList.IndexOf('16.0') >= 0) +
               ' 15.0=' + B2S(VersionList.IndexOf('15.0') >= 0));

    if HostList.Count = 0 then
    begin
      InstallLog('OFFICE_DETECTION_ERROR: no supported Office host application found.');
      Result := 'No supported Excel, Word or PowerPoint installation was found.';
      exit;
    end;

    NeedVstoX86 := not VstoRuntimeInstalled(HKLM32);
    if IsWin64 and (DetectedPlatform = 'x64') then
      NeedVstoX64 := not VstoRuntimeInstalled(HKLM64)
    else
      NeedVstoX64 := False;

    InstallLog('VSTO runtime needed: x86=' + B2S(NeedVstoX86) + ' x64=' + B2S(NeedVstoX64));

    Hosts := '';
    for I := 0 to HostList.Count - 1 do Hosts := Hosts + HostList[I] + ' ';
    Versions := '';
    for I := 0 to VersionList.Count - 1 do Versions := Versions + VersionList[I] + ' ';
    InstallLog('PrepareToInstall summary: hosts=[' + Hosts + '] versions=[' + Versions + ']');
  except
    InstallLog('EXCEPTION in PrepareToInstall: ' + GetExceptionMessage);
    Result := 'OMNIX setup encountered an internal error while preparing to install: ' + GetExceptionMessage;
  end;
end;

function UpdateReadyMemo(const Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := '';
  Result := Result + 'Office platform: ' + DetectedPlatform + NewLine;
  Result := Result + 'Office generation: ' + DetectedOfficeVersion + NewLine;
  Result := Result + 'Hosts to register: ' + HostsSummary() + NewLine;
  if NeedVstoX86 or NeedVstoX64 then
    Result := Result + NewLine +
      'The Microsoft VSTO Runtime prerequisite appears missing and the bundled Microsoft redistributable will be attempted.' + NewLine +
      'Windows may request Administrator approval for that Microsoft prerequisite only.' + NewLine;
  Result := Result + NewLine +
    'Installation folder: ' + ExpandConstant('{localappdata}') + '\Programs\OMNIX' + NewLine;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  I, J: Integer;
  Key, Manifest, ReadBack, AppPathForward: String;
  AllOk: Boolean;
  ResultCode, CertClassResult: Integer;
  VstoExe, CertPath, CertClassifier, CertMarker, DevThumbprint: String;
  RuntimeStillMissing: Boolean;
begin
  if CurStep = ssInstall then
  begin
    InstallLog('=== OMNIX install begin (version {#MyAppVersion}) ===');

    try
      ExtractTemporaryFile('vstor_redist.exe');
    except
      InstallLog('NOTE: vstor_redist.exe was not extracted/bundled: ' + GetExceptionMessage);
    end;

    RemoveAddinRegistry();
    PreserveOfficeResiliencyState();

    if DirExists(ExpandConstant('{app}')) then
    begin
      InstallLog('Removing previous OMNIX application folder before clean reinstall: ' + ExpandConstant('{app}'));
      DelTree(ExpandConstant('{app}'), True, True, True);
    end;

    if NeedVstoX86 or NeedVstoX64 then
    begin
      VstoExe := ExpandConstant('{tmp}') + '\vstor_redist.exe';
      if FileExists(VstoExe) then
      begin
        InstallLog('Installing Microsoft VSTO Runtime prerequisite (/q /norestart) with normal UAC approval...');
        if not ShellExec('runas', VstoExe, '/q /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
        begin
          ResultCode := -1;
          PrerequisiteFailed := True;
          InstallLog('VSTO prerequisite could not be launched (UAC may have been declined).');
        end
        else
        begin
          InstallLog('VSTO Runtime installer exit code: ' + IntToStr(ResultCode));
          if (ResultCode <> 0) and (ResultCode <> 3010) then PrerequisiteFailed := True;
          if ResultCode = 3010 then VstoRestartNeeded := True;
        end;

        RuntimeStillMissing := False;
        if NeedVstoX86 and (not VstoRuntimeInstalled(HKLM32)) then RuntimeStillMissing := True;
        if NeedVstoX64 and (not VstoRuntimeInstalled(HKLM64)) then RuntimeStillMissing := True;

        if ((ResultCode = 0) or (ResultCode = 3010)) and RuntimeStillMissing then
        begin
          VstoRestartNeeded := True;
          InstallLog('VSTO installer completed but runtime marker is not visible yet; restart requested before final runtime acceptance.');
        end;
      end
      else
      begin
        PrerequisiteFailed := True;
        InstallLog('PREREQUISITE_ERROR: vstor_redist.exe is required but missing from the installer payload.');
      end;
    end;
  end;

  if CurStep = ssPostInstall then
  begin
    AllOk := not PrerequisiteFailed;

    ; Development certificate trust is allowed only after files have been copied and only when
    ; the bundled public certificate is actually self-signed. A CA-signed production publisher
    ; certificate relies on the normal Windows chain and is never inserted into CurrentUser Root.
    CertPath := ExpandConstant('{app}') + '\OMNIX.cer';
    CertClassifier := ExpandConstant('{app}') + '\classify-dev-cert.ps1';
    CertMarker := ExpandConstant('{app}') + '\dev-cert-thumbprint.txt';
    DeleteFile(CertMarker);

    if FileExists(CertPath) and FileExists(CertClassifier) then
    begin
      Exec('powershell.exe',
           '-NoProfile -ExecutionPolicy Bypass -File "' + CertClassifier + '" -CertPath "' + CertPath + '" -OutputPath "' + CertMarker + '"',
           '', SW_HIDE, ewWaitUntilTerminated, CertClassResult);

      if CertClassResult = 0 then
      begin
        DevThumbprint := '';
        if LoadStringFromFile(CertMarker, DevThumbprint) then DevThumbprint := Trim(DevThumbprint);
        if DevThumbprint = '' then
        begin
          InstallLog('CERTIFICATE_ERROR: self-signed development certificate classifier returned no thumbprint.');
          AllOk := False;
        end
        else
        begin
          Exec(ExpandConstant('{cmd}'), '/C certutil -f -user -addstore ' + TrustedPubStore + ' "' + CertPath + '"',
               '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
          InstallLog('Development TrustedPublisher import exit code: ' + IntToStr(ResultCode) + ' thumbprint=' + DevThumbprint);
          if ResultCode <> 0 then AllOk := False;

          Exec(ExpandConstant('{cmd}'), '/C certutil -f -user -addstore ' + RootStore + ' "' + CertPath + '"',
               '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
          InstallLog('Development CurrentUser Root import exit code: ' + IntToStr(ResultCode) + ' thumbprint=' + DevThumbprint);
          if ResultCode <> 0 then AllOk := False;
        end;
      end
      else if CertClassResult = 2 then
      begin
        DeleteFile(CertMarker);
        InstallLog('CA/non-self-signed publisher certificate detected: no OMNIX trust-store modification performed.');
      end
      else
      begin
        InstallLog('CERTIFICATE_ERROR: could not classify bundled OMNIX.cer (exit ' + IntToStr(CertClassResult) + ').');
        AllOk := False;
      end;
    end
    else
    begin
      InstallLog('CERTIFICATE_ERROR: OMNIX.cer or classify-dev-cert.ps1 missing from installed payload.');
      AllOk := False;
    end;

    AppPathForward := ExpandConstant('{app}');
    StringChange(AppPathForward, '\', '/');

    for I := 0 to VersionList.Count - 1 do
      for J := 0 to HostList.Count - 1 do
      begin
        if IsHostInstalled(HostList[J], VersionList[I]) then
        begin
          Key := Format(RegAddinsFmt, [VersionList[I], HostList[J]]);
          Manifest := 'file:///' + AppPathForward + '/OMNIX.' + HostList[J] + '.vsto|vstolocal';

          RegWriteStringValue(HKCU, Key, 'Description', 'OMNIX AI Office');
          RegWriteStringValue(HKCU, Key, 'FriendlyName', 'OMNIX');
          RegWriteDWordValue(HKCU, Key, 'LoadBehavior', 3);
          RegWriteStringValue(HKCU, Key, 'Manifest', Manifest);
          InstallLog('Wrote HKCU\' + Key + ' Manifest=' + Manifest);

          if RegQueryStringValue(HKCU, Key, 'Manifest', ReadBack) then
            InstallLog('REGISTRATION VERIFIED (' + VersionList[I] + ' / ' + HostList[J] + '): ' + ReadBack)
          else
          begin
            InstallLog('REGISTRATION_ERROR: could not read back ' + Key);
            AllOk := False;
          end;
        end;
      end;

    if AllOk and (not VstoRestartNeeded) then
    begin
      try
        InstallLog('Launching automatic Excel/Word/PowerPoint post-install verification...');
        Exec('powershell.exe',
             '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}') + '\post-install-verify.ps1"',
             '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
        InstallLog('post-install-verify.ps1 exit code: ' + IntToStr(ResultCode));
        if ResultCode <> 0 then AllOk := False;
      except
        InstallLog('POST_INSTALL_VERIFY_ERROR: ' + GetExceptionMessage);
        AllOk := False;
      end;
    end
    else if VstoRestartNeeded then
      InstallLog('Post-install COM verification deferred because a Windows restart is required first.');

    InstallLog('=== OMNIX install end (verified=' + B2S(AllOk) + ', restart=' + B2S(VstoRestartNeeded) + ') ===');

    if not AllOk then
      MsgBox('OMNIX installation completed but runtime verification FAILED.' #13#10#13#10 +
             'Do not treat this build as ready. See logs in ' + ExpandConstant('{localappdata}') + '\OMNIX\logs.',
             mbError, MB_OK);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
  CertMarker, DevThumbprint: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    RemoveAddinRegistry();
    PreserveOfficeResiliencyState();
    InstallLog('=== OMNIX uninstall: OMNIX-owned registration removed; Office Resiliency preserved ===');

    ; Remove only the exact self-signed development certificate thumbprint recorded by this
    ; installer. Production/CA certificates are never root-imported by OMNIX and are never removed.
    CertMarker := ExpandConstant('{app}') + '\dev-cert-thumbprint.txt';
    DevThumbprint := '';
    if FileExists(CertMarker) and LoadStringFromFile(CertMarker, DevThumbprint) then
    begin
      DevThumbprint := Trim(DevThumbprint);
      if DevThumbprint <> '' then
      begin
        Exec(ExpandConstant('{cmd}'), '/C certutil -user -delstore ' + TrustedPubStore + ' "' + DevThumbprint + '"',
             '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
        InstallLog('Development TrustedPublisher removal exit code: ' + IntToStr(ResultCode));
        Exec(ExpandConstant('{cmd}'), '/C certutil -user -delstore ' + RootStore + ' "' + DevThumbprint + '"',
             '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
        InstallLog('Development CurrentUser Root removal exit code: ' + IntToStr(ResultCode));
      end;
    end
    else
      InstallLog('No development certificate marker found; no trust-store removal performed.');
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    if MsgBox('Also remove OMNIX settings and chat history (' +
              ExpandConstant('{localappdata}') + '\OMNIX)?' + #13#10 +
              'Choose Yes only if you do NOT plan to reinstall.', mbConfirmation, MB_YESNO) = IDYES then
    begin
      DelTree(ExpandConstant('{localappdata}') + '\OMNIX', True, True, True);
      InstallLog('User data tree removed.');
    end;
  end;
end;
