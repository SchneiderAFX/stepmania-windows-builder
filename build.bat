@echo off
rem Shortcut: double-click = Release build. Arguments are passed to build.ps1, e.g.:  build.bat -Config Debug -Run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
echo.
pause
