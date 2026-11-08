@echo off
setlocal EnableExtensions

rem ============================================================================
rem  SETTINGS - edit the values below, save this file, then double-click it.
rem
rem  Downloads the StepMania or ITGmania source code (with all submodules) into
rem  .\source. You do NOT need git installed: if it is missing, a portable one is
rem  downloaded and verified automatically. The target folder must be empty.
rem
rem  Anything you type after "2. get-source.bat" on the command line is added at the end
rem  and wins over these settings, e.g.:   "2. get-source.bat" -Game itgmania
rem ============================================================================

rem Which game to download:
rem   (empty)   = show a menu and ask
rem   stepmania = https://github.com/stepmania/stepmania
rem   itgmania  = https://github.com/itgmania/itgmania
set "GAME="

rem Folder to download into. Empty = .\source
set "TARGET="

rem --- On/off options: 1 = yes, 0 = no -----------------------------------------

rem Download the whole git history too (slower and larger). 0 = latest commit only,
rem which is all you need to build.
set "FULL_HISTORY=0"

rem Ignore any installed git and use the portable one.
set "USE_MINGIT=0"

rem Keep the window open when finished (so you can read the result). 0 = close.
set "PAUSE_AT_END=1"

rem ============================================================================
rem  END OF SETTINGS - no need to edit below this line
rem ============================================================================

call :stripslash TARGET

rem If an option is also typed on the command line, it replaces the setting above
rem (PowerShell does not accept the same option twice).
echo %* | findstr /i /c:"-Game" >nul && set "GAME="
echo %* | findstr /i /c:"-Target" >nul && set "TARGET="
echo %* | findstr /i /c:"-FullHistory" >nul && set "FULL_HISTORY=0"
echo %* | findstr /i /c:"-UseMinGit" >nul && set "USE_MINGIT=0"

set ARGS=
if defined GAME set ARGS=%ARGS% -Game %GAME%
if defined TARGET set ARGS=%ARGS% -Target "%TARGET%"
if "%FULL_HISTORY%"=="1" set ARGS=%ARGS% -FullHistory
if "%USE_MINGIT%"=="1" set ARGS=%ARGS% -UseMinGit

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\get-source.ps1" %ARGS% %*
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
