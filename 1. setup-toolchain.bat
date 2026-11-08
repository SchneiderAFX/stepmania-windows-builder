@echo off
setlocal EnableExtensions

rem ============================================================================
rem  SETTINGS - edit the values below, save this file, then double-click it.
rem
rem  Anything you type after "1. setup-toolchain.bat" on the command line is added at
rem  the end and wins over these settings, e.g.:   "1. setup-toolchain.bat" -Force
rem ============================================================================

rem Microsoft Defender scan at the end (it can take several minutes):
rem   ask  = when that step is reached, ask: "Continue" or "Skip" (skipping is less secure)
rem   scan = always scan, without asking
rem   skip = never scan, without asking
set "DEFENDER=ask"

rem --- On/off options: 1 = yes, 0 = no -----------------------------------------

rem Reinstall everything even if it is already present.
set "FORCE=0"

rem Keep the window open when finished (so you can read the result). 0 = close.
set "PAUSE_AT_END=1"

rem --- Advanced (leave empty to use the defaults) ------------------------------

rem Windows SDK build number to download. Empty = script default (currently 22621).
set "SDK_VERSION="

rem MSVC version, e.g. 14.44. Empty = the newest one in Microsoft's manifest.
set "MSVC_MINOR="

rem Folder where the toolchain is installed. Empty = .\toolchain
set "TOOLCHAIN_DIR="

rem ============================================================================
rem  END OF SETTINGS - no need to edit below this line
rem ============================================================================

call :stripslash TOOLCHAIN_DIR

rem If an option is also typed on the command line, it replaces the setting above
rem (PowerShell does not accept the same option twice).
echo %* | findstr /i /c:"-SkipDefender" >nul && set "DEFENDER="
echo %* | findstr /i /c:"-Defender" >nul && set "DEFENDER="
echo %* | findstr /i /c:"-Force" >nul && set "FORCE=0"
echo %* | findstr /i /c:"-SdkVersion" >nul && set "SDK_VERSION="
echo %* | findstr /i /c:"-MsvcMinor" >nul && set "MSVC_MINOR="
echo %* | findstr /i /c:"-ToolchainDir" >nul && set "TOOLCHAIN_DIR="

set ARGS=
if defined DEFENDER set ARGS=%ARGS% -Defender %DEFENDER%
if "%FORCE%"=="1" set ARGS=%ARGS% -Force
if defined SDK_VERSION set ARGS=%ARGS% -SdkVersion %SDK_VERSION%
if defined MSVC_MINOR set ARGS=%ARGS% -MsvcMinor %MSVC_MINOR%
if defined TOOLCHAIN_DIR set ARGS=%ARGS% -ToolchainDir "%TOOLCHAIN_DIR%"

echo Running: setup-toolchain.ps1%ARGS% %*
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup-toolchain.ps1" %ARGS% %*
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
