@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0pc_bridge.ps1" %*
if errorlevel 1 pause
