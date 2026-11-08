@echo off
setlocal EnableExtensions

rem ============================================================================
rem  SETTINGS - edit the values below, save this file, then double-click it.
rem
rem  Anything you type after "3. build.bat" on the command line is added at the end
rem  and wins over these settings, e.g.:   "3. build.bat" -Config Debug -Run
rem ============================================================================

rem Build configuration: Release | Debug | RelWithDebInfo | MinSizeRel
set "CONFIG=Release"

rem Name of the output folder: GAME-NAME (GAME is stepmania or itgmania, detected from the source).
rem Leave empty to use today's date in US format (e.g. itgmania-MMddyyyy).
set "NAME="

rem Folder with the StepMania/ITGmania source code. Leave empty to use .\source
set "SOURCE="

rem What to do when the source folder is EMPTY:
rem   (empty)   = show a menu and ask which game to download
rem   stepmania = download StepMania into the source folder without asking
rem   itgmania  = download ITGmania into the source folder without asking
rem It never downloads into a folder that already has files.
set "DOWNLOAD="

rem --- On/off options: 1 = yes, 0 = no -----------------------------------------

rem Launch the game when the build finishes.
set "RUN=0"

rem Rebuild everything from scratch (slow). Needed once after moving/renaming this folder.
set "CLEAN=0"

rem Only refresh the internal working copy of the source; do not compile.
set "SYNC_ONLY=0"

rem Compile, but do not create the clean stepmania-* output folder.
set "NO_PACKAGE=0"

rem Ignore .\toolchain and use an installed Visual Studio 2022 instead.
set "NO_PORTABLE=0"

rem Skip the quick integrity check of the portable toolchain before building.
set "SKIP_VERIFY=0"

rem Keep the window open when finished (so you can read the result). 0 = close.
set "PAUSE_AT_END=1"

rem ============================================================================
rem  END OF SETTINGS - no need to edit below this line
rem ============================================================================

call :stripslash SOURCE

rem If an option is also typed on the command line, it replaces the setting above
rem (PowerShell does not accept the same option twice).
echo %* | findstr /i /c:"-Config" >nul && set "CONFIG="
echo %* | findstr /i /c:"-Name" >nul && set "NAME="
echo %* | findstr /i /c:"-Source" >nul && set "SOURCE="
echo %* | findstr /i /c:"-Download" >nul && set "DOWNLOAD="
echo %* | findstr /i /c:"-Run" >nul && set "RUN=0"
echo %* | findstr /i /c:"-Clean" >nul && set "CLEAN=0"
echo %* | findstr /i /c:"-SyncOnly" >nul && set "SYNC_ONLY=0"
echo %* | findstr /i /c:"-NoPackage" >nul && set "NO_PACKAGE=0"
echo %* | findstr /i /c:"-NoPortable" >nul && set "NO_PORTABLE=0"
echo %* | findstr /i /c:"-SkipVerify" >nul && set "SKIP_VERIFY=0"

set ARGS=
if defined CONFIG set ARGS=%ARGS% -Config %CONFIG%
if defined NAME set ARGS=%ARGS% -Name "%NAME%"
if defined SOURCE set ARGS=%ARGS% -Source "%SOURCE%"
if defined DOWNLOAD set ARGS=%ARGS% -Download %DOWNLOAD%
if "%RUN%"=="1" set ARGS=%ARGS% -Run
if "%CLEAN%"=="1" set ARGS=%ARGS% -Clean
if "%SYNC_ONLY%"=="1" set ARGS=%ARGS% -SyncOnly
if "%NO_PACKAGE%"=="1" set ARGS=%ARGS% -NoPackage
if "%NO_PORTABLE%"=="1" set ARGS=%ARGS% -NoPortable
if "%SKIP_VERIFY%"=="1" set ARGS=%ARGS% -SkipVerify

echo Running: build.ps1 %ARGS% %*
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build.ps1" %ARGS% %*
set "EXITCODE=%ERRORLEVEL%"

echo.
if not "%PAUSE_AT_END%"=="0" pause
exit /b %EXITCODE%

rem Removes a trailing backslash from the variable whose name is passed in %1
rem (a path ending in \" would break the PowerShell command line).
:stripslash
if not defined %1 exit /b 0
call set "_v=%%%1%%"
if "%_v:~-1%"=="\" set "%1=%_v:~0,-1%"
exit /b 0
