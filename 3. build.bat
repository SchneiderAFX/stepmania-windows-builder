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

rem Name of the output folder: SOURCE-NAME (SOURCE is the name of the source folder,
rem e.g. stepmania, itgmania or your fork's name).
rem Leave empty to use the date (US format) and time (24 h) of the build,
rem e.g. itgmania-11142026-1530. Every build then gets a new folder.
rem With a NAME, the same folder is refreshed on every build (Save, Cache and Logs are kept).
set "NAME="

rem Which source to build: the name of a folder inside source\ (e.g. itgmania or
rem stepmania-fixes), or a full path. Leave empty to build the only one there or, when
rem there are several, to choose from a menu (Enter = the last one you built).
set "SOURCE="

rem What to do when there is NO source at all:
rem   (empty)   = show a menu and ask what to download
rem   stepmania = download StepMania into source\stepmania without asking
rem   itgmania  = download ITGmania into source\itgmania without asking
set "DOWNLOAD="

rem --- On/off options: 1 = yes, 0 = no -----------------------------------------

rem Launch the game when the build finishes.
set "RUN=0"

rem After a successful build, delete the internal _work folder (working copy + build cache)?
rem   ask = ask at the end (Enter = keep it)
rem   yes = delete it without asking: tidier, but the NEXT build is slower because it
rem         compiles everything again (a few minutes)
rem   no  = keep it without asking: the next build only recompiles what you changed
rem         (much faster while you are testing changes in the code)
set "DELETE_WORK=ask"

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
echo %* | findstr /i /c:"-KeepWork" >nul && set "DELETE_WORK="
echo %* | findstr /i /c:"-DeleteWork" >nul && set "DELETE_WORK="

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
if defined DELETE_WORK set ARGS=%ARGS% -DeleteWork %DELETE_WORK%

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
