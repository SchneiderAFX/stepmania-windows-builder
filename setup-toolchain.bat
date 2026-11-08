@echo off
rem Shortcut: double-click = download and verify the portable toolchain into .\toolchain
rem Arguments are passed to setup-toolchain.ps1, e.g.:  setup-toolchain.bat -SkipDefender
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-toolchain.ps1" %*
echo.
pause
