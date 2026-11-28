@echo off
setlocal EnableExtensions

rem ============================================================================
rem  Turns the addresses in a crashinfo.txt into function names and file:line,
rem  using the debug symbols the builder keeps for every build in symbols\.
rem
rem  Drag the crashinfo.txt onto this file, or double-click it and type the path.
rem  The result is shown and saved next to the crash report as
rem  crashinfo-symbolized.txt.
rem ============================================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\symbolize.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

echo.
pause
exit /b %EXITCODE%
