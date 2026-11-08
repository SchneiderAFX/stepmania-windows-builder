@echo off
setlocal EnableExtensions

rem ============================================================================
rem  SETTINGS - edit the values below, save this file, then double-click it.
rem
rem  Anything you type after verify-toolchain.bat on the command line is added at
rem  the end and wins over these settings.
rem ============================================================================

rem Toolchain folder to check. Empty = .\toolchain
set "TOOLCHAIN_DIR="

rem Microsoft Defender scan at the end (it can take several minutes):
rem   ask  = when that step is reached, ask: "Continue" or "Skip" (skipping is less secure)
rem   scan = always scan, without asking
rem   skip = never scan, without asking (only the file hashes and signatures are checked)
set "DEFENDER=ask"

rem Keep the window open when finished (so you can read the result). 0 = close.
set "PAUSE_AT_END=1"

rem ============================================================================
rem  END OF SETTINGS - no need to edit below this line
rem ============================================================================

call :stripslash TOOLCHAIN_DIR

rem If the option is also typed on the command line, it replaces the setting above
rem (PowerShell does not accept the same option twice).
echo %* | findstr /i /c:"-ToolchainDir" >nul && set "TOOLCHAIN_DIR="
echo %* | findstr /i /c:"-SkipDefender" >nul && set "DEFENDER="
echo %* | findstr /i /c:"-Defender" >nul && set "DEFENDER="

set ARGS=
if defined DEFENDER set ARGS=%ARGS% -Defender %DEFENDER%
if defined TOOLCHAIN_DIR set ARGS=%ARGS% -ToolchainDir "%TOOLCHAIN_DIR%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\verify-toolchain.ps1" %ARGS% %*
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
