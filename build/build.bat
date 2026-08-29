@echo off
REM ============================================================================
REM build.bat — local Windows build (no CI needed).
REM Produces: bin outputs + installer/payload + installer/Output/OMNIX-Setup-1.0.0.exe
REM Requirements: Visual Studio 2022 with ".NET desktop development" + "Office
REM development" workloads (build\ensure-vsto-sdk.ps1 verifies this for you).
REM Run from a normal command prompt (the script locates MSBuild itself).
REM ============================================================================
setlocal enabledelayedexpansion
cd /d "%~dp0.."
echo === OMNIX local build ===

REM ---- 1) locate MSBuild ----
set MSBUILD=
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" 2^>nul`) do (
    set MSBUILD=%%i
)
if "%MSBUILD%"=="" (
    echo ERROR: MSBuild not found. Install Visual Studio 2022 first.
    exit /b 1
)
echo MSBuild: %MSBUILD%

REM ---- 2) verify VSTO SDK / install if missing ----
powershell -NoProfile -ExecutionPolicy Bypass -File build\ensure-vsto-sdk.ps1
if errorlevel 1 (
    echo ERROR: VSTO SDK could not be prepared. See messages above.
    exit /b 1
)

REM ---- 3) signing certificate (temporary self-signed; see spec 10.2 honesty note) ----
powershell -NoProfile -ExecutionPolicy Bypass -File build\create-signing-cert.ps1
set THUMB=
for /f "usebackq" %%t in ("build\cert\thumbprint.txt") do set THUMB=%%t
echo Signing thumbprint: %THUMB%

REM ---- 4) NuGet restore ----
if not exist "build\nuget.exe" (
    echo Downloading nuget.exe…
    powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile 'build\nuget.exe'"
)
"build\nuget.exe" restore OMNIX.sln
if errorlevel 1 exit /b 1

REM ---- 5) build the solution (Release, signed manifests) ----
"%MSBUILD%" OMNIX.sln /p:Configuration=Release /p:Platform="Any CPU" ^
  /p:SignManifests=true /p:ManifestCertificateThumbprint=%THUMB% ^
  /p:ManifestTimestampUrl=http://timestamp.digicert.com ^
  /bl:build\logs\build.binlog /m
if errorlevel 1 (
    echo BUILD FAILED — open build\logs\build.binlog with MSBuild Structured Log Viewer.
    exit /b 1
)
echo Build OK.

REM ---- 6) stage payload + compile the installer ----
powershell -NoProfile -ExecutionPolicy Bypass -File build\package.ps1
if errorlevel 1 exit /b 1

set ISCC="C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
if not exist %ISCC% (
    echo WARNING: Inno Setup 6 not found — skipping exe packaging.
    echo Install it from https://jrsoftware.org/isdl.php and re-run to get the single exe.
    exit /b 0
)
%ISCC% installer\installer.iss
if errorlevel 1 exit /b 1

echo.
echo === DONE: installer\Output\OMNIX-Setup-1.0.0.exe ===
echo Run it, open Excel/Word/PowerPoint and look for the OMNIX tab.
endlocal
