; ============================================================================
; OMNIX — installer.iss (Inno Setup 6.3+)
; Spec compliance: Section 4.1 (detection), 4.2 (install steps), 4.4 (honest notes),
; Phase 2 milestone, Phase 19 (three-host installer), Phase 21 (clean uninstall).
;
; Key properties:
;   * Per-user install, NO Administrator required for the main flow
;     (only the VSTO Runtime bootstrap may raise a transparent UAC).
;   * Detects the REAL Office bitness (ClickToRun Platform value, MSI path fallback).
;   * Registers add-ins ONLY for hosts that actually exist on this system
;     and for every Office version found (16.0 and/or 15.0).
;   * Cleans previous installs + Office Resiliency/DisabledItems BEFORE writing anything.
;   * Imports the manifest signing certificate into CurrentUser\TrustedPublisher
;     (and CurrentUser\Root for self-signed chains) — no admin needed.
;   * Writes every step to %LOCALAPPDATA%\OMNIX\logs\install-debug.log and verifies
;     the registry values by reading them back (spec 4.2 step 6).
; ============================================================================

#define MyAppName "OMNIX"
#define MyAppVersion "1.0.0"
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
; Payload: the VSTO build outputs of all three hosts merged into one folder.
Source: "payload\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion; Excludes: "vstor_redist.exe"
; Manifest signing certificate (staged by the build scripts; optional for local dev builds)
#if FileExists(AddBackslash(SourcePath) + "payload\OMNIX.cer")
Source: "payload\OMNIX.cer"; DestDir: "{app}"; Flags: ignoreversion
; Also stage it to {tmp} (dontcopy = extracted at Setup startup, not permanently
; installed) so CurStepChanged/ssInstall can find it there BEFORE {app} files
; exist — [Files] entries only land in {app} at file-copy time, which happens
; AFTER CurStepChanged(ssInstall) runs, not before.
Source: "payload\OMNIX.cer"; DestDir: "{tmp}"; Flags: dontcopy
#endif
; Bundled VSTO Runtime redistributable (fetched at CI build time from the
; official Microsoft URL — see .github/workflows/build.yml). Staged to {tmp}
; only (dontcopy): it is a one-time installer for a system-wide prerequisite,
; not something OMNIX itself needs permanently in {app}.
#if FileExists(AddBackslash(SourcePath) + "payload\vstor_redist.exe")
Source: "payload\vstor_redist.exe"; DestDir: "{tmp}"; Flags: dontcopy
#endif

[Icons]
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
// ============================================================
//  Constants / state
// ============================================================
const
  RegAddinsFmt    = 'Software\Microsoft\Office\%0:s\%1:s\Addins\OMNIX';
  TrustedPubStore = 'TrustedPublisher';
  RootStore       = 'Root';

var
  DetectedPlatform: String;    // 'x64' or 'x86'
  HostList:    TStringList;    // hosts actually installed: Excel, Word, PowerPoint
  VersionList: TStringList;    // Office versions present: 16.0 and/or 15.0
  NeedVstoX64: Boolean;
  NeedVstoX86: Boolean;

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
    // never let logging break the install
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
  for I := 0 to HostList.Count - 1 do
  begin
    if I > 0 then Result := Result + ', ';
    Result := Result + HostList[I];
  end;
end;

// ============================================================
//  Office detection (spec 4.1) — real bitness, never a guess
// ============================================================
function DetectOfficePlatform: String;
var
  S: String;
begin
  Result := '';
  // 1) Click-to-Run (Office 2013+): HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration -> Platform
  if RegQueryStringValue(HKLM64, 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'Platform', S) then
    Result := S
  else if RegQueryStringValue(HKLM32, 'SOFTWARE\Microsoft\Office\ClickToRun\Configuration', 'Platform', S) then
    Result := S
  else begin
    // 2) MSI fallback: check real install folders
    if DirExists('C:\Program Files\Microsoft Office') or
       DirExists('C:\Program Files\Microsoft Office\root') then
      Result := 'x64'
    else if DirExists('C:\Program Files (x86)\Microsoft Office') then
      Result := 'x86';
  end;
  InstallLog('Office platform detected: ' + Result);
end;

function IsHostInstalled(const Host: String; const Version: String): Boolean;
begin
  Result := RegKeyExists(HKCU, 'Software\Microsoft\Office\' + Version + '\' + Host);
end;

function VstoRuntimeInstalled(const BitView: Integer): Boolean;
var
  Ver: String;
begin
  // HKLM\SOFTWARE\Microsoft\VSTO Runtime Setup\v4R -> Version
  Result := RegQueryStringValue(BitView, 'SOFTWARE\Microsoft\VSTO Runtime Setup\v4R', 'Version', Ver);
  InstallLog('VSTO Runtime check (registry view ' + IntToStr(BitView) + '): found=' + B2S(Result) + ' version=' + Ver);
end;

// ============================================================
//  Cleanup of previous installs (spec 4.2 step 2 + 4.4 DisabledItems)
// ============================================================
procedure RemoveAddinRegistry();
var
  I, J: Integer;
  Key: String;
begin
  if HostList = nil then exit;
  for I := 0 to VersionList.Count - 1 do
    for J := 0 to HostList.Count - 1 do
    begin
      Key := Format(RegAddinsFmt, [VersionList[I], HostList[J]]);
      if RegKeyExists(HKCU, Key) then
      begin
        RegDeleteKeyIncludingSubkeys(HKCU, Key);
        InstallLog('Removed old registry key: HKCU\' + Key);
      end;
    end;
end;

procedure CleanResiliencyDisabledItems();
var
  I, J, K: Integer;
  Versions, Hosts: array of String;
  Root, Key: String;
  Names: TArrayOfString;
begin
  SetArrayLength(Versions, 2); Versions[0] := '16.0'; Versions[1] := '15.0';
  SetArrayLength(Hosts, 3); Hosts[0] := 'Excel'; Hosts[1] := 'Word'; Hosts[2] := 'PowerPoint';

  for I := 0 to GetArrayLength(Versions) - 1 do
    for J := 0 to GetArrayLength(Hosts) - 1 do
    begin
      Root := 'Software\Microsoft\Office\' + Versions[I] + '\' + Hosts[J] + '\Resiliency';
      Key := Root + '\DisabledItems';
      if RegKeyExists(HKCU, Key) then
      begin
        // Delete every binary blob Office stored for a previously disabled add-in.
        if RegGetValueNames(HKCU, Key, Names) then
        begin
          for K := 0 to GetArrayLength(Names) - 1 do
            RegDeleteValue(HKCU, Key, Names[K]);
        end;
        InstallLog('Cleaned Resiliency\DisabledItems for ' + Hosts[J] + ' ' + Versions[I]);
      end;
      Key := Root + '\CrashingAddinList';
      if RegKeyExists(HKCU, Key) then RegDeleteKeyIncludingSubkeys(HKCU, Key);
      Key := Root + '\DoNotDisableAddinList';
      if RegKeyExists(HKCU, Key) then RegDeleteKeyIncludingSubkeys(HKCU, Key);
    end;
end;

// ============================================================
//  Setup init: Office must be closed while files are replaced
// ============================================================
function IsProcessRunning(const ImageName: String): Boolean;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{cmd}'),
       '/C tasklist /FI "IMAGENAME eq ' + ImageName + '" | find /I "' + ImageName + '" >nul',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := (ResultCode = 0);
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
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
    InstallLog('WARNING: the "is Office running" check failed and was skipped: ' + GetExceptionMessage);
  end;
end;

// ============================================================
//  Detection happens BEFORE installing anything (spec 4.1)
// ============================================================
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Hosts, Versions: String;
  I: Integer;
begin
  Result := '';
  DetectedPlatform := DetectOfficePlatform;
  if DetectedPlatform = '' then
  begin
    InstallLog('OFFICE_DETECTION_ERROR: Office could not be detected.');
    Result := 'Microsoft Office (Excel, Word or PowerPoint) was not detected on this system.';
    exit;
  end;

  HostList := TStringList.Create;
  VersionList := TStringList.Create;
  if IsHostInstalled('Excel', '16.0') or IsHostInstalled('Excel', '15.0') then HostList.Add('Excel');
  if IsHostInstalled('Word', '16.0') or IsHostInstalled('Word', '15.0') then HostList.Add('Word');
  if IsHostInstalled('PowerPoint', '16.0') or IsHostInstalled('PowerPoint', '15.0') then HostList.Add('PowerPoint');
  if IsHostInstalled('Excel', '16.0') or IsHostInstalled('Word', '16.0') or IsHostInstalled('PowerPoint', '16.0') then VersionList.Add('16.0');
  if IsHostInstalled('Excel', '15.0') or IsHostInstalled('Word', '15.0') or IsHostInstalled('PowerPoint', '15.0') then VersionList.Add('15.0');

  InstallLog('Hosts found: ' + HostsSummary() + ' | Versions found: 16.0=' + B2S(VersionList.IndexOf('16.0') >= 0) + ' 15.0=' + B2S(VersionList.IndexOf('15.0') >= 0));

  if HostList.Count = 0 then
  begin
    InstallLog('OFFICE_DETECTION_ERROR: no Office host application found.');
    Result := 'No Excel, Word or PowerPoint installation was found.';
    exit;
  end;

  // VSTO Runtime bitness check (spec 4.1 step 3): Office x64 needs x64 VSTO runtime too.
  NeedVstoX86 := not VstoRuntimeInstalled(HKLM32);
  if IsWin64 and (DetectedPlatform = 'x64') then
    NeedVstoX64 := not VstoRuntimeInstalled(HKLM64)
  else
    NeedVstoX64 := False;
  InstallLog('VSTO runtime needed: x86=' + B2S(NeedVstoX86) + ' x64=' + B2S(NeedVstoX64));
  // Note: the actual redistributable (vstor_redist.exe) is bundled directly in
  // the payload (fetched from the official Microsoft URL at CI build time) and
  // is installed later, in CurStepChanged, with Exec — no in-wizard download
  // page is used, which avoids that whole (fragile, harder-to-diagnose-remotely)
  // code path entirely.

  Hosts := '';
  for I := 0 to HostList.Count - 1 do Hosts := Hosts + HostList[I] + ' ';
  Versions := '';
  for I := 0 to VersionList.Count - 1 do Versions := Versions + VersionList[I] + ' ';
  InstallLog('PrepareToInstall summary: hosts=[' + Hosts + '] versions=[' + Versions + ']');
end;

function UpdateReadyMemo(const Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := '';
  Result := Result + 'Office platform:  ' + DetectedPlatform + NewLine;
  Result := Result + 'Hosts to register: ' + HostsSummary() + NewLine;
  if NeedVstoX86 or NeedVstoX64 then
    Result := Result + NewLine +
      'The Microsoft VSTO Runtime is missing and will be installed from the bundled redistributable.' + NewLine +
      'This is the ONLY step that may ask for Administrator permission (transparent UAC).' + NewLine;
  Result := Result + NewLine +
    'Installation folder: ' + ExpandConstant('{localappdata}') + '\Programs\OMNIX (per-user, no admin needed).' + NewLine;
end;


// ============================================================
//  Install steps — exact order of spec 4.2
// ============================================================
procedure CurStepChanged(CurStep: TSetupStep);
var
  I, J: Integer;
  Key, Manifest, ReadBack, AppPathForward: String;
  AllOk: Boolean;
  ResultCode: Integer;
  VstoExe: String;
  CertPath: String;
begin
  if CurStep = ssInstall then
  begin
    InstallLog('=== OMNIX install begin (version {#MyAppVersion}) ===');

    // --- 4.2 step 2: clean previous install + DisabledItems BEFORE writing anything new ---
    RemoveAddinRegistry();
    CleanResiliencyDisabledItems();

    // --- 4.2 step 3: VSTO runtime if missing — the only step that may raise UAC ---
    if NeedVstoX86 or NeedVstoX64 then
    begin
      VstoExe := ExpandConstant('{tmp}') + '\vstor_redist.exe';
      if FileExists(VstoExe) then
      begin
        InstallLog('Installing VSTO Runtime (vstor_redist.exe /q /norestart)…');
        Exec(VstoExe, '/q /norestart', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
        InstallLog('VSTO Runtime installer exit code: ' + IntToStr(ResultCode));
        if NeedVstoX64 and (not VstoRuntimeInstalled(HKLM64)) then
          InstallLog('WARNING: x64 VSTO Runtime verification after install did not succeed.');
      end
      else
        InstallLog('WARNING: vstor_redist.exe missing from temp — download step did not run.');
    end;

    // --- 4.2 step 4: trust the manifest signing certificate (CurrentUser — no admin) ---
    CertPath := ExpandConstant('{tmp}') + '\OMNIX.cer';
    if not FileExists(CertPath) then
      CertPath := ExpandConstant('{app}') + '\OMNIX.cer';
    if FileExists(CertPath) then
    begin
      Exec(ExpandConstant('{cmd}'), '/C certutil -user -addstore ' + TrustedPubStore + ' "' + CertPath + '"',
           '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      InstallLog('certutil -user -addstore TrustedPublisher exit code: ' + IntToStr(ResultCode));
      // Self-signed chains also need the CurrentUser ROOT store (one confirmation dialog, no admin).
      Exec(ExpandConstant('{cmd}'), '/C certutil -user -addstore ' + RootStore + ' "' + CertPath + '"',
           '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      InstallLog('certutil -user -addstore Root exit code: ' + IntToStr(ResultCode));
    end
    else
      InstallLog('NOTE: no OMNIX.cer found — manifests are UNSIGNED for this build. ' +
                 'Office may silently reject the add-in (spec 4.4).');
  end;

  if CurStep = ssPostInstall then
  begin
    // --- 4.2 step 5: write the Addins registry per real host and per real version ---
    AllOk := True;
    AppPathForward := ExpandConstant('{app}');
    StringChange(AppPathForward, '\', '/');
    for I := 0 to VersionList.Count - 1 do
      for J := 0 to HostList.Count - 1 do
      begin
        Key := Format(RegAddinsFmt, [VersionList[I], HostList[J]]);
        Manifest := 'file:///' + AppPathForward + '/OMNIX.' + HostList[J] + '.vsto|vstolocal';

        RegWriteStringValue(HKCU, Key, 'Description', 'OMNIX AI Office');
        RegWriteStringValue(HKCU, Key, 'FriendlyName', 'OMNIX');
        RegWriteDWordValue(HKCU, Key, 'LoadBehavior', 3);
        RegWriteStringValue(HKCU, Key, 'Manifest', Manifest);
        InstallLog('Wrote HKCU\' + Key + '  Manifest=' + Manifest);

        // --- 4.2 step 6: verification — read back immediately and log ---
        if RegQueryStringValue(HKCU, Key, 'Manifest', ReadBack) then
          InstallLog('  VERIFIED (' + VersionList[I] + ' / ' + HostList[J] + '): ' + ReadBack)
        else begin
          InstallLog('  REGISTRATION_ERROR: could not read back ' + Key);
          AllOk := False;
        end;
      end;

    // --- 4.2 step 7: Start Menu uninstall shortcut is created via [Icons] ---
    InstallLog('=== OMNIX install end (registration OK: ' + B2S(AllOk) + ') ===');

    if not AllOk then
      MsgBox('Some registry keys could not be verified. Please check install-debug.log in ' +
             ExpandConstant('{localappdata}') + '\OMNIX\logs.', mbError, MB_OK);
  end;
end;

// ============================================================
//  Uninstall (spec Phase 21: nothing left behind)
// ============================================================
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    RemoveAddinRegistry();
    CleanResiliencyDisabledItems();
    InstallLog('=== OMNIX uninstall: registry cleaned ===');

    // Remove the trusted certificate we added (leave the machine as it was).
    Exec(ExpandConstant('{cmd}'), '/C certutil -user -delstore ' + TrustedPubStore + ' OMNIX', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec(ExpandConstant('{cmd}'), '/C certutil -user -delstore ' + RootStore + ' OMNIX', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    InstallLog('Certificate removal attempted (best effort).');
  end;

  if CurUninstallStep = usPostUninstall then
  begin
    if MsgBox('Also remove OMNIX settings and chat history ' +
              '(' + ExpandConstant('{localappdata}') + '\OMNIX)?' + #13#10 +
              'Choose Yes only if you do NOT plan to reinstall.', mbConfirmation, MB_YESNO) = IDYES then
    begin
      DelTree(ExpandConstant('{localappdata}') + '\OMNIX', True, True, True);
      InstallLog('User data tree removed.');
    end;
  end;
end;
