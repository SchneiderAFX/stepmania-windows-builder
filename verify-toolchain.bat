@echo off
rem Shortcut: double-click = check that the portable toolchain was not modified since installation
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-toolchain.ps1" %*
echo.
pause
