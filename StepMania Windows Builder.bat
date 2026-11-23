@echo off
rem ============================================================================
rem  Opens StepMania Windows Builder (the window). This is all most people need.
rem
rem  The first time, it offers to install the toolchain; then download a source
rem  and press Build. Help (inside the window) explains every option, and can put
rem  a shortcut with an icon on your desktop.
rem
rem  Prefer a console? The same steps are in the cli folder as .bat files.
rem ============================================================================
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0scripts\gui.ps1"
