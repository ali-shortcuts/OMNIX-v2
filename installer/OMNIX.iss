#ifndef AppVersion
  #define AppVersion "4.0.0-preview.1"
#endif
[Setup]
AppId={{9DD278A1-E1A8-4D77-99B7-34A11A65252A}
AppName=OMNIX
AppVersion={#AppVersion}
AppPublisher=ali-shortcuts
DefaultDirName={localappdata}\Programs\OMNIX-Native
DefaultGroupName=OMNIX
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
MinVersion=10.0
ArchitecturesAllowed=x86compatible x64compatible
OutputDir=..\artifacts\release
OutputBaseFilename=OMNIX-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
InfoBeforeFile=NOTICE.txt
UninstallDisplayIcon={app}\setup\Omnix.Setup.exe

[Files]
Source: "..\artifacts\payload\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\artifacts\payload\setup\Omnix.Setup.exe"; Flags: dontcopy
Source: "..\artifacts\payload\setup\Omnix.Contracts.dll"; Flags: dontcopy
Source: "..\artifacts\prerequisites\vstor_redist.exe"; Flags: dontcopy

[Icons]
Name: "{group}\OMNIX Diagnostics"; Filename: "{app}\setup\Omnix.Setup.exe"; Parameters: "diagnose"
Name: "{group}\Uninstall OMNIX"; Filename: "{uninstallexe}"

[UninstallRun]
Filename: "{app}\setup\Omnix.Setup.exe"; Parameters: "unregister ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: "UnregisterOwnAddins"

[Code]
var
  FinalFailure: Boolean;

function RunHelper(const Action, HelperPath: String): Integer;
var Code: Integer;
begin
  if not Exec(HelperPath, Action + ' "' + ExpandConstant('{app}') + '"', '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Result := 10
  else
    Result := Code;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var ReleaseNumber: Cardinal; Code: Integer; Helper: String;
begin
  Result := '';
  if (not RegQueryDWordValue(HKLM32, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', ReleaseNumber)) or (ReleaseNumber < 528040) then begin
    Result := 'Microsoft .NET Framework 4.8 is required. Install it using Windows Update, then run OMNIX Setup again.';
    Exit;
  end;
  ExtractTemporaryFile('Omnix.Setup.exe');
  ExtractTemporaryFile('Omnix.Contracts.dll');
  Helper := ExpandConstant('{tmp}\Omnix.Setup.exe');
  Code := RunHelper('probe', Helper);
  if Code = 20 then begin Result := 'No supported desktop Excel, Word, or PowerPoint installation was found.'; Exit; end;
  if Code = 21 then begin Result := 'Close Excel, Word, and PowerPoint before installing OMNIX.'; Exit; end;
  if Code = 23 then begin
    ExtractTemporaryFile('vstor_redist.exe');
    if not ShellExec('runas', ExpandConstant('{tmp}\vstor_redist.exe'), '/install /passive /norestart', '', SW_SHOW, ewWaitUntilTerminated, Code) then begin
      Result := 'The required Microsoft VSTO Runtime was not installed.'; Exit;
    end;
    if Code = 3010 then begin NeedsRestart := True; Result := 'Restart Windows to finish installing the Microsoft VSTO Runtime, then run OMNIX Setup again.'; Exit; end;
    if Code <> 0 then begin Result := 'Microsoft VSTO Runtime installation failed. Exit code: ' + IntToStr(Code); Exit; end;
    Code := RunHelper('probe', Helper);
  end;
  if Code <> 0 then Result := 'OMNIX preflight failed. Open the installation report in %LOCALAPPDATA%\OMNIX\v4.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var Code: Integer; Action: String;
begin
  if CurStep = ssPostInstall then begin
    Action := 'trust';
    if WizardSilent then Action := 'trust-silent';
    Code := RunHelper(Action, ExpandConstant('{app}\setup\Omnix.Setup.exe'));
    if Code = 0 then Code := RunHelper('register', ExpandConstant('{app}\setup\Omnix.Setup.exe'));
    if Code <> 0 then begin
      FinalFailure := True;
      SuppressibleMsgBox('Office integration could not be completed. Run OMNIX Diagnostics from the Start menu. The Microsoft VSTO error is recorded in %LOCALAPPDATA%\OMNIX\v4\installation-error.txt.', mbError, MB_OK, IDOK);
    end;
  end;
end;

function GetCustomSetupExitCode(): Integer;
begin
  if FinalFailure then Result := 10 else Result := 0;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and FinalFailure then begin
    WizardForm.FinishedHeadingLabel.Caption := 'Office integration needs attention';
    WizardForm.FinishedLabel.Caption := 'OMNIX files were copied, but Office integration failed. Open OMNIX Diagnostics for the installation error.';
  end;
end;
